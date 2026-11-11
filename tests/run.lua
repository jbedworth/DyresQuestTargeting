-- Run from the repository root: lua tests/run.lua
-- These mocks test AddOn logic, not Forever compatibility, protected actions,
-- secret-value behavior, or taint.
-- Every test gets its own globals, clock, event frames, and namespace.
if _VERSION ~= "Lua 5.1" then
    io.stderr:write("This suite requires Lua 5.1; found " .. tostring(_VERSION) .. "\n")
    os.exit(1)
end

local tests = {}
local function test(name, body)
    tests[#tests + 1] = {name = name, body = body}
end
local function equal(actual, expected, context)
    if actual ~= expected then
        error((context or "value") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end
local function contains(actual, fragment, context)
    if type(actual) ~= "string" or not actual:find(fragment, 1, true) then
        error((context or "text") .. ": expected text containing " .. fragment
            .. ", got " .. tostring(actual), 2)
    end
end
local function lacks(actual, fragment, context)
    if type(actual) == "string" and actual:find(fragment, 1, true) then
        error((context or "text") .. ": expected no " .. fragment .. " in " .. actual, 2)
    end
end

local ADDON = "DyresQuestTargeting"
local RUNTIME_FILES = {"Commands.lua", "Core.lua", "Quest.lua", "Macro.lua", "Box.lua", "Options.lua"}
-- Dyre's Toolkit's files the tests load: the real toolkit in ../DyresToolkit
-- when that folder is there, else the copy in tests/toolkit (as in CI). Not
-- the minimap, which needs the embedded libraries.
local TOOLKIT_FILES = {"Core.lua", "Layout.lua", "Widgets.lua", "Settings.lua"}
local TOOLKIT_DIR = "tests/toolkit/"
do
    local real = io.open("../DyresToolkit/Core.lua", "rb")
    if real then
        real:close()
        TOOLKIT_DIR = "../DyresToolkit/"
    end
end
print("Dyre's Toolkit from " .. TOOLKIT_DIR)
local PAGE = "Dyre's Quest Targeting"
-- Under "Dyre's AddOns", the toolkit says "Dyre's " once (its ShortName).
local SHORT_PAGE = "Quest Targeting"
local MACRO = "! Target (DQT)"
local OLD_MACRO = "! Quest Targets"
local ACCOUNT_SLOTS, CHARACTER_SLOTS = 120, 30

-- A secret stands in for the client's opaque values; tests mark them with
-- issecretvalue, and any comparison or concatenation with one raises an error.
local function secret()
    return setmetatable({}, {
        __eq = function() error("compared a secret value") end,
        __lt = function() error("compared a secret value") end,
        __le = function() error("compared a secret value") end,
        __concat = function() error("concatenated a secret value") end,
        __tostring = function() error("printed a secret value") end,
        __index = function() error("indexed a secret value") end,
    })
end

-- QuestieDB's public reads (contract 4), from a small table of quests,
-- NPCs, and items.
local function questieDB(data, contract)
    local function reader(rows, field)
        return function(id) return rows[id] and rows[id][field] end
    end
    return {
        RequireContract = function(required) return required <= (contract or 4) end,
        Quest = {objectives = reader(data.quests, "objectives"), finishedBy = reader(data.quests, "finishedBy"),
            startedBy = reader(data.quests, "startedBy")},
        Npc = {name = function(id) return data.npcs[id] end},
        Item = {name = reader(data.items, "name"), npcDrops = reader(data.items, "drops")},
    }
end

local function fixture(options)
    options = options or {}
    local state = {frames = {}, messages = {}, now = 100, combat = false, secrets = {}, settings = {},
        timers = {}, quests = options.quests or {}, focus = options.focus, writes = 0,
        account = options.accountMacros or {}, character = options.characterMacros or {}}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.SlashCmdList = options.slashCmdList or {}
    for key, value in pairs(options.globals or {}) do env[key] = value end
    env.DEFAULT_CHAT_FRAME = {AddMessage = function(_, message)
        state.messages[#state.messages + 1] = message
    end}
    state.toc = {}
    for text in io.lines(ADDON .. ".toc") do
        local key, value = text:match("^##%s*([^:]+):%s*(.-)%s*$")
        if key then state.toc[key] = value end
    end
    env.C_AddOns = {GetAddOnMetadata = function(name, field)
        equal(name, ADDON, "metadata uses the AddOn folder name")
        return state.toc[field] or ""
    end}
    env.GetTime = function() return state.now end
    env.InCombatLockdown = function() return state.combat end
    env.issecretvalue = function(value) return state.secrets[value] == true end
    env.C_Timer = {After = function(seconds, callback)
        state.timers[#state.timers + 1] = {at = state.now + seconds, callback = callback}
    end}
    function state.advance(seconds)
        state.now = state.now + (seconds or 1)
        local due = {}
        for index = #state.timers, 1, -1 do
            if state.timers[index].at <= state.now then
                due[#due + 1] = table.remove(state.timers, index)
            end
        end
        for _, timer in ipairs(due) do timer.callback() end
    end
    if not options.noConstants then
        env.Constants = {MacroConsts = {MAX_ACCOUNT_MACROS = ACCOUNT_SLOTS, MAX_CHARACTER_MACROS = CHARACTER_SLOTS}}
    end

    -- Quests: the super-tracked one and each quest's objectives.
    env.C_SuperTrack = {GetSuperTrackedQuestID = function() return state.focus end}
    -- Setting the focus fires SUPER_TRACKING_CHANGED, here at once.
    function env.C_SuperTrack.SetSuperTrackedQuestID(questID)
        state.focusSets = (state.focusSets or 0) + 1
        state.focus = questID
        state.emit("SUPER_TRACKING_CHANGED")
    end
    env.C_QuestLog = {
        GetQuestObjectives = function(id) return state.quests[id] and state.quests[id].objectives end,
        GetLogIndexForQuestID = function(id) if state.quests[id] then return 1 end end,
        IsComplete = function(id) return state.quests[id] and state.quests[id].complete == true end,
        GetTitleForQuestID = function(id) return state.quests[id] and state.quests[id].title end,
    }
    if options.missingObjectives then
        env.C_QuestLog.GetQuestObjectives = nil
    end
    -- Classic Era and Anniversary: no C_SuperTrack, and the older quest log
    -- functions (an index from 1, 0 for a quest not in the log; the sixth
    -- return of GetQuestLogTitle is 1 for a complete quest).
    if options.classic then
        env.C_SuperTrack = nil
        -- Found in client: Classic Era has a global of this name, which must
        -- not pass for C_SuperTrack's function.
        env.GetSuperTrackedQuestID = function() return nil end
        -- As in client: registering an event the client does not know fails.
        state.unknownEvents = {SUPER_TRACKING_CHANGED = true}
        env.C_QuestLog.GetLogIndexForQuestID = nil
        env.C_QuestLog.IsComplete = nil
        env.C_QuestLog.GetTitleForQuestID = nil
        local function ordered()
            local ids = {}
            for id in pairs(state.quests) do ids[#ids + 1] = id end
            table.sort(ids)
            return ids
        end
        env.GetQuestLogIndexByID = function(id)
            for index, each in ipairs(ordered()) do
                if each == id then return index end
            end
            return 0
        end
        env.GetQuestLogTitle = function(index)
            local id = ordered()[index]
            local quest = id and state.quests[id]
            if not quest then return nil end
            return quest.title, 10, 0, false, false, quest.complete and 1 or nil, 0, id
        end
    end
    if options.db then
        env.LibQuestieDB = questieDB(options.db, options.dbContract)
    end
    -- The game's macro option parser, for [mod:shift] only: the first clause
    -- whose conditions match, or nil.
    if not options.noOptionParse then
        env.SecureCmdOptionParse = function(text)
            for clause in (text .. ";"):gmatch("%s*(.-)%s*;") do
                local conditions, action = clause:match("^%[(.-)%]%s*(.*)$")
                if not conditions then
                    return clause
                end
                if (conditions == "mod:shift") == (state.shift == true) then
                    return action
                end
            end
        end
    end
    -- hooksecurefunc as the client's: runs the hook after the original.
    env.hooksecurefunc = function(owner, name, hook)
        local original = owner[name]
        owner[name] = function(...)
            local results = {original(...)}
            hook(...)
            return unpack(results)
        end
    end
    -- Questie: its tracker focus in its per-character saved data, set by
    -- TrackerUtils, a module reached through the global QuestieLoader.
    if options.questie then
        local char = {TrackerFocus = options.questie.focus}
        env.Questie = {db = {char = char}}
        local utils = {}
        function utils:FocusQuest(questID) char.TrackerFocus = questID return true end
        function utils:FocusObjective(questID, index) char.TrackerFocus = questID .. " " .. index return true end
        function utils:UnFocus() char.TrackerFocus = nil end
        -- TomTom targets as Questie sets them: the quest's nearest spawn, or a point.
        state.waypoints = {}
        function utils.SetQuestTomTomTarget(questID)
            state.waypoints[#state.waypoints + 1] = "quest " .. questID
            return true
        end
        function utils:SetTomTomTarget(title, zone, x, y)
            state.waypoints[#state.waypoints + 1] = title .. " " .. zone .. " " .. x .. "," .. y
        end
        state.questieUtils = utils
        state.notes = 0
        local modules = {
            TrackerUtils = utils,
            QuestieQuest = {ToggleNotes = function(_, show)
                equal(show, false)
                state.notes = state.notes + 1
            end},
            -- Questie's quest objects: objectives by index, each with its spawns.
            QuestieDB = {GetQuest = function(questID)
                local spawns = options.questie.spawns and options.questie.spawns[questID]
                local objectives = {}
                for index, spawn in pairs(spawns or {}) do objectives[index] = {spawnList = spawn} end
                local nearest = options.questie.questSpawns and options.questie.questSpawns[questID] or {}
                return {Objectives = objectives, spawn = nearest.spawn, zone = nearest.zone, name = nearest.name}
            end,
            -- {rate, source}, as Questie's DropDB answers.
            GetItemDroprate = function(itemID, npcID)
                local rates = options.questie.rates and options.questie.rates[itemID]
                if rates and rates[npcID] then return {rates[npcID], "wowhead"} end
            end},
            -- An NPC's spawns here are one point and its distance from you.
            DistanceUtils = {GetNearestObjective = function(list) return list.spawn, list.zone, list.name end,
                GetNearestSpawn = function(spawns) return spawns.at, spawns.zone, spawns.far end,
                GetNearestSpawnForQuest = function(quest) return quest.spawn, quest.zone, quest.name end},
            -- Area IDs to map IDs: area 141 is map 1438 here.
            ZoneDB = {GetUiMapIdByAreaId = function(_, area) return ({[141] = 1438})[area] end},
        }
        function modules.QuestieDB:GetNPC(npcID)
            local npc = options.questie.npcs and options.questie.npcs[npcID]
            return npc and {name = npc.name, spawns = npc}
        end
        env.QuestieLoader = {ImportModule = function(_, name)
            -- As Questie's loader: an unknown module is an empty table.
            return modules[name] or {}
        end}
    end
    if options.tomtom then
        env.TomTom = {}
    end
    -- TomTom's own calls, as a guide step's location uses them. options.tomtomApi.
    if options.tomtomApi then
        state.tomtomPoints, state.tomtomRemoved = {}, {}
        env.TomTom = {}
        function env.TomTom:AddWaypoint(map, x, y, opts)
            local point = {map = map, x = x, y = y, opts = opts, text = map .. " " .. x .. "," .. y}
            state.tomtomPoints[#state.tomtomPoints + 1] = point
            return point
        end
        function env.TomTom:RemoveWaypoint(uid)
            state.tomtomRemoved[#state.tomtomRemoved + 1] = uid
        end
    end
    -- LibStub's libraries, as the AddOns below register them.
    state.libraries = {}
    if options.rxp or options.questtrail then
        env.LibStub = {GetLibrary = function(_, name, silent)
            equal(silent, true, "asks silently")
            return state.libraries[name]
        end}
    end
    -- QuestTrail: only the fields DQT reads, as its source names them, through its
    -- modules' library (LibStub "QuestTrail-Modules").ns. options.questtrail.current is
    -- the compass's target; options.questtrail.noFocus leaves out ns.Focus.
    if options.questtrail then
        local ns = {Arrow = {current = options.questtrail.current}}
        state.qtrHooks = 0
        for _, name in ipairs({"SavePlan", "Advance", "AdvanceDone"}) do
            ns.Arrow[name] = function() state.qtrHooks = state.qtrHooks + 1 end
        end
        if not options.questtrail.noFocus then
            -- As Focus.Set: the game's focus on a quest in the log, else none.
            ns.Focus = {Set = function(questID)
                local quest = options.quests and options.quests[questID]
                env.C_SuperTrack.SetSuperTrackedQuestID(quest and questID or 0)
            end}
        end
        state.libraries["QuestTrail-Modules"] = {ns = ns}
        -- As a new plan: the target set, the game's focus moved to its quest, then SavePlan.
        function state.qtrStep(current)
            ns.Arrow.current = current
            if ns.Focus and current and current.q then ns.Focus.Set(current.q, "plan") end
            ns.Arrow.SavePlan(current)
        end
        state.qtr = ns
    end
    -- Zygor Guides Viewer: only the fields DQT reads, as its source names
    -- them (a paid AddOn: none of its code is here). options.zygor.step and
    -- .stickies are the shown steps; options.zygor.noMessages leaves out
    -- AddMessageHandler.
    -- RestedXP: only the fields DQT reads, as its source names them, through
    -- AceAddon. options.rxp.steps are the active steps in RestedXP's order.
    if options.rxp then
        local addon = {RXPFrame = not options.rxp.noFrame and {activeSteps = options.rxp.steps or {}} or nil,
            currentGuide = {name = "1-10 Teldrassil"}, targeting = {}, activeWaypoints = options.rxp.waypoints}
        state.mapUpdates = 0
        function addon.UpdateMap(resetPins)
            if resetPins then state.mapUpdates = state.mapUpdates + 1 end
        end
        -- As UpdateMap(true): a new arrow list. UpdateMap() only sets a flag.
        function state.rxpMap(waypoints)
            addon.activeWaypoints = waypoints
            addon.UpdateMap(true)
        end
        state.unitListUpdates = 0
        function addon.targeting:UpdateUnitList() state.unitListUpdates = state.unitListUpdates + 1 end
        local ace = {GetAddon = function(_, name, silent)
            equal(silent, true, "asks silently")
            if name == "RXPGuides" then return addon end
        end}
        state.libraries["AceAddon-3.0"] = ace
        -- As SetStep: the new active steps; RestedXP then updates its list.
        function state.rxpSteps(steps)
            local active = addon.RXPFrame.activeSteps
            for index = #active, 1, -1 do active[index] = nil end
            for index, step in ipairs(steps) do active[index] = step end
            addon.targeting:UpdateUnitList()
        end
        state.rxp = addon
    end
    if options.zygor then
        local zgv = {CurrentGuide = {title = "Leveling Guides\\Elwynn Forest (1-13)",
            title_short = "Elwynn Forest (1-13)"}, CurrentStep = options.zygor.step,
            CurrentStickies = options.zygor.stickies}
        local handlers = {}
        if not options.zygor.noMessages then
            -- As Zygor's: handler(self, message, ...), unprotected.
            function zgv:AddMessageHandler(message, handler)
                handlers[#handlers + 1] = {message = message, handler = handler}
            end
        end
        function state.zygorSend(message, ...)
            for _, entry in ipairs(handlers) do
                if entry.message == message then entry.handler(zgv, message, ...) end
            end
        end
        -- As ZGV:FocusStep: the new step, with track Zygor's own game focus
        -- on the step's first quest (ZGV:TrackQuest), then ZGV_STEP_CHANGED.
        function state.zygorStep(step, stickies, track)
            zgv.CurrentStep, zgv.CurrentStickies = step, stickies
            for _, each in ipairs(track and step.goals or {}) do
                if each.questid then
                    env.C_SuperTrack.SetSuperTrackedQuestID(each.questid)
                    break
                end
            end
            state.zygorSend("ZGV_STEP_CHANGED", step.num)
        end
        state.zygor = zgv
        env.ZygorGuidesViewer = zgv
    end

    -- Macros: account slots 1-120, character slots from 121, as the client
    -- numbers them. Writing in combat is refused, as the client does.
    local function allMacros()
        local list = {}
        for index, macro in ipairs(state.account) do list[index] = macro end
        for index, macro in ipairs(state.character) do list[ACCOUNT_SLOTS + index] = macro end
        return list
    end
    env.GetMacroIndexByName = function(name)
        for index, macro in pairs(allMacros()) do
            if macro.name == name then return index end
        end
        return 0
    end
    env.GetMacroBody = function(index) return allMacros()[index].body end
    env.GetMacroInfo = function(index)
        local macro = allMacros()[index]
        if macro then return macro.name, macro.icon, macro.body end
    end
    env.GetNumMacros = function() return #state.account, #state.character end
    env.CreateMacro = function(name, icon, body, perCharacter)
        if state.combat then error("CreateMacro in combat") end
        equal(#name <= 16, true, "macro names hold at most 16 letters")
        equal(#body <= 255, true, "macro bodies hold at most 255 letters")
        local list = perCharacter and state.character or state.account
        list[#list + 1] = {name = name, icon = icon, body = body}
        state.writes = state.writes + 1
    end
    env.EditMacro = function(index, name, icon, body)
        if state.combat then error("EditMacro in combat") end
        equal(#body <= 255, true, "macro bodies hold at most 255 letters")
        local macro = allMacros()[index]
        macro.name, macro.icon, macro.body = name, icon, body
        state.writes = state.writes + 1
    end
    function state.macro()
        for _, macro in ipairs(state.character) do
            if macro.name == MACRO then return macro.body end
        end
    end
    function state.accountMacro()
        for _, macro in ipairs(state.account) do
            if macro.name == MACRO then return macro.body end
        end
    end

    -- The player's target.
    env.IsShiftKeyDown = function() return state.shift == true end
    env.GetCursorPosition = function() return state.cursorX or 0, state.cursorY or 0 end
    env.UnitExists = function(unit) equal(unit, "target") return state.target ~= nil end
    env.UnitName = function(unit) equal(unit, "target") return state.target end

    -- Settings: proxy settings with getters and setters, as the client builds them.
    if not options.noSettings then
        local function initializer(category, setting, extra, tooltip)
            local object = {setting = setting, options = extra, tooltip = tooltip}
            -- As the client's: the row is greyed out while a predicate is false.
            function object:AddModifyPredicate(func)
                self.predicates = self.predicates or {}
                self.predicates[#self.predicates + 1] = func
            end
            function object:Enabled()
                for _, func in ipairs(self.predicates or {}) do
                    if not func() then return false end
                end
                return true
            end
            category.initializers[#category.initializers + 1] = object
            return object
        end
        env.Settings = {
            VarType = {Boolean = "boolean", Number = "number", String = "string"},
            -- Returns the category and its layout, as the client does.
            RegisterVerticalLayoutCategory = function(name)
                local category = {name = name, initializers = {}}
                function category:GetID() return "id:" .. name end
                local layout = {}
                function layout:AddInitializer(object)
                    category.initializers[#category.initializers + 1] = object
                end
                return category, layout
            end,
            -- DQT's page under Dyre's Toolkit's home; state.registered is DQT's page either way.
            RegisterVerticalLayoutSubcategory = function(parent, name)
                local category, layout = env.Settings.RegisterVerticalLayoutCategory(name)
                category.parent = parent
                if name == PAGE or name == SHORT_PAGE then state.registered = category end
                return category, layout
            end,
            NotifyUpdate = function(variable) state.notified = variable end,
            CreateSlider = function(category, setting, sliderOptions, tooltip)
                return initializer(category, setting, sliderOptions, tooltip)
            end,
            CreateSliderOptions = function(minValue, maxValue, step)
                return {minValue = minValue, maxValue = maxValue, step = step}
            end,
            RegisterProxySetting = function(category, variable, variableType, name, default, getValue, setValue)
                equal(state.settings[variable], nil, "setting variables are unique")
                local setting = {variable = variable, type = variableType, name = name, default = default}
                function setting:GetValue() return getValue() end
                function setting:SetValue(value) setValue(value) end
                state.settings[variable] = setting
                return setting
            end,
            RegisterAddOnCategory = function(category)
                if category.name == PAGE then state.registered = category else state.home = category end
            end,
            CreateCheckbox = function(category, setting, tooltip) return initializer(category, setting, nil, tooltip) end,
            CreateDropdown = function(category, setting, choices, tooltip)
                return initializer(category, setting, choices, tooltip)
            end,
            CreateControlTextContainer = function()
                local data = {}
                return {Add = function(_, value, label) data[#data + 1] = {value = value, label = label} end,
                    GetData = function() return data end}
            end,
            OpenToCategory = function(id) state.opened = id end,
        }
    end

    if not options.noSettings and not options.noSectionHeaders then
        env.CreateSettingsListSectionHeaderInitializer = function(name) return {header = name} end
    end
    if not options.noSettings then
        env.CreateSettingsButtonInitializer = function(name, label, onClick, tooltip)
            return {button = label, onClick = onClick, tooltip = tooltip}
        end
    end

    -- Frames, as far as DQT, its box, and Dyre's Toolkit use them. Unknown
    -- methods (layout and colors) do nothing.
    local SPOTS = {CENTER = {0.5, 0.5}, BOTTOMLEFT = {0, 0}, BOTTOMRIGHT = {1, 0}, TOPLEFT = {0, 1},
        TOPRIGHT = {1, 1}, TOP = {0.5, 1}, BOTTOM = {0.5, 0}, LEFT = {0, 0.5}, RIGHT = {1, 0.5}}
    local function newFrame(kind, frameName, parent, template)
        local frame = {kind = kind, name = frameName, parent = parent, template = template, events = {},
            scripts = {}, points = {}, shown = true, enabled = true, children = {}}
        if parent and parent.children then parent.children[#parent.children + 1] = frame end
        if kind == "Button" then frame.mouse = true end
        function frame:RegisterEvent(event)
            if event == "COMBAT_LOG_EVENT_UNFILTERED" then
                error("COMBAT_LOG_EVENT_UNFILTERED is restricted")
            end
            if state.unknownEvents and state.unknownEvents[event] then
                error('Attempt to register unknown event "' .. event .. '"')
            end
            self.events[event] = true
        end
        function frame:UnregisterEvent(event) self.events[event] = nil end
        function frame:RegisterUnitEvent(event, unit)
            equal(unit, "player")
            self.events[event] = true
        end
        function frame:SetScript(script, callback) self.scripts[script] = callback end
        function frame:GetScript(script) return self.scripts[script] end
        function frame:StartMoving() self.moving = true end
        function frame:StopMovingOrSizing() self.moving = false end
        function frame:HookScript(script, hook)
            local original = self.scripts[script]
            self.scripts[script] = function(...)
                if original then original(...) end
                hook(...)
            end
        end
        function frame:SetBackdrop(backdrop) self.backdrop = backdrop end
        function frame:SetBackdropColor(...) self.backdropColor = {...} end
        function frame:SetBackdropBorderColor(...) self.backdropBorder = {...} end
        function frame:EnableMouse(value) self.mouse = value == true end
        function frame:SetAlpha(value) self.alpha = value end
        function frame:GetAlpha() return self.alpha or 1 end
        function frame:SetScale(value) self.scale = value end
        function frame:GetScale() return self.scale or 1 end
        function frame:GetTop() local _, y = self:GetCenter() return y + (self.height or 0) / 2 end
        function frame:GetLeft() local x = self:GetCenter() return x - (self.width or 0) / 2 end
        function frame:GetRight() local x = self:GetCenter() return x + (self.width or 0) / 2 end
        function frame:GetEffectiveScale()
            local parentScale = self.parent and self.parent.GetEffectiveScale and self.parent:GetEffectiveScale() or 1
            return (self.scale or 1) * parentScale
        end
        function frame:GetNumPoints() return #self.points end
        function frame:GetWidth() return self.width or 0 end
        function frame:GetHeight() return self.height or 0 end
        function frame:SetWidth(width) self.width = width end
        function frame:SetHeight(height) self.height = height end
        function frame:SetSize(width, height) self.width, self.height = width, height end
        function frame:GetCenter()
            local x, y = state.absCenter(self)
            local scale = self:GetEffectiveScale()
            return x / scale, y / scale
        end
        function frame:Show() self.shown = true end
        function frame:Hide() self.shown = false end
        function frame:SetShown(value) self.shown = value == true end
        function frame:IsShown() return self.shown end
        function frame:IsProtected() return false end
        function frame:SetPoint(...) self.points[#self.points + 1] = {...} end
        function frame:ClearAllPoints() self.points = {} end
        function frame:SetText(text) self.text = text end
        function frame:GetText() return self.text end
        function frame:SetFont(file, size, flags) self.font = {file, size, flags} end
        function frame:SetEnabled(value) self.enabled = value == true end
        function frame:IsEnabled() return self.enabled end
        function frame:SetNormalTexture(texture) self.normalTexture = texture end
        function frame:SetTexture(texture) self.texture = texture end
        function frame:SetColorTexture(...) self.color = {...} end
        function frame:SetMouseClickEnabled(value) self.mouseClicks = value == true end
        function frame:SetDesaturated(value) self.desaturated = value == true end
        function frame:SetFocus() self.focused = true end
        function frame:ClearFocus() self.focused = false end
        function frame:SetFrameLevel(level) self.level = level end
        function frame:GetFrameLevel()
            if self.level then return self.level end
            return self.parent and self.parent.GetFrameLevel and self.parent:GetFrameLevel() + 1 or 1
        end
        function frame:SetMouseMotionEnabled(value) self.mouseMotion = value == true end
        -- Text cut with "...": a test sets truncated.
        function frame:IsTruncated() return self.truncated == true end
        function frame:CreateFontString() return newFrame("FontString", nil, self) end
        function frame:CreateTexture() return newFrame("Texture", nil, self) end
        function frame:GetFontString()
            self.label = self.label or newFrame("FontString", nil, self)
            return self.label
        end
        -- A click as the client sends it: nothing on a disabled button.
        function frame:Click()
            if self.enabled and self.scripts.OnClick then self.scripts.OnClick(self, "LeftButton") end
        end
        return setmetatable(frame, {__index = function(_, key)
            if type(key) == "string" and key:match("^%u") then return function() end end
        end})
    end
    env.CreateFrame = function(kind, frameName, parent, template)
        local frame = newFrame(kind, frameName, parent, template)
        if frameName then env[frameName] = frame end
        state.frames[#state.frames + 1] = frame
        return frame
    end
    env.UIParent = newFrame("Frame", "UIParent")
    env.UIParent.width, env.UIParent.height = 1000, 800
    -- Screen position of a frame's center, from its last point.
    function state.absCenter(frame)
        if frame == env.UIParent or frame == nil then return 500, 400 end
        local point = frame.points[#frame.points]
        if not point then return 500, 400 end
        local relative = type(point[2]) == "table" and point[2] or env.UIParent
        local rx, ry = state.absCenter(relative)
        local spot = SPOTS[point[3]] or SPOTS.CENTER
        local width, height = relative.width or 0, relative.height or 0
        local scale = frame:GetEffectiveScale()
        return rx + (spot[1] - 0.5) * width + (point[4] or 0) * scale, ry + (spot[2] - 0.5) * height
            + (point[5] or 0) * scale
    end
    function state.emit(event, ...)
        for _, frame in ipairs(state.frames) do
            if frame.events[event] and frame.scripts.OnEvent then
                frame.scripts.OnEvent(frame, event, ...)
            end
        end
    end

    -- Dyre's Toolkit, its real files: DQT requires it. options.noToolkit
    -- leaves it out; options.oldToolkit offers contract 1 only.
    if not options.noToolkit then
        state.toolkitNS = {InitializeMinimap = function() end}
        for _, path in ipairs(TOOLKIT_FILES) do
            local chunk = assert(loadfile(TOOLKIT_DIR .. path))
            setfenv(chunk, env)
            chunk("DyresToolkit", state.toolkitNS)
        end
        state.toolkit = env.DyresToolkit
        if options.oldToolkit then
            env.DyresToolkit.RequireContract = function(n)
                if n == 1 then return env.DyresToolkit end
            end
        end
    end
    local namespace = {}
    for _, file in ipairs(RUNTIME_FILES) do
        local chunk = assert(loadfile(file))
        setfenv(chunk, env)
        chunk(ADDON, namespace)
    end
    state.dqt, state.env = namespace, env
    -- Most tests look at an open hit list; options.realDefaults keeps DQT's
    -- own default (the hit list starts folded).
    local saved = options.saved
    if not options.realDefaults and (saved == nil or type(saved) == "table") then
        saved = saved or {}
        if saved.startHitListFolded == nil then saved.startHitListFolded = false end
    end
    env.DyresQuestTargetingDB = saved
    state.emit("ADDON_LOADED", "DyresToolkit")
    state.emit("ADDON_LOADED", ADDON)
    state.emit("PLAYER_LOGIN")
    -- As in client, the game restores its focus while the world loads.
    state.emit("SUPER_TRACKING_CHANGED")
    state.emit("PLAYER_ENTERING_WORLD")
    state.advance(3)

    function state.slash(text)
        env.SlashCmdList.DYRESQUESTTARGETING(text)
    end
    function state.last() return state.messages[#state.messages] end
    function state.said(fragment)
        for _, message in ipairs(state.messages) do
            if message:find(fragment, 1, true) then return true end
        end
        return false
    end
    function state.clear() state.messages = {} end
    return state
end

local function objective(text, kind, finished)
    return {text = text, type = kind or "monster", finished = finished == true, numFulfilled = 0, numRequired = 8}
end

local function lines(body)
    local list = {}
    for line in (body .. "\n"):gmatch("(.-)\n") do list[#list + 1] = line end
    return list
end

local CONDOR_QUEST = {[101] = {title = "The Condor Hunt", objectives = {
    objective("0/8 Dire Condor slain"), objective("Tarantula slain: 2/5")}}}

test("logs in with a banner and makes the character macro", function()
    local state = fixture()
    contains(state.messages[1], "DQT: Dyre's Quest Targeting 1.4.1 by Dyre")
    equal(state.said("Ready."), true)
    equal(state.dqt.available, true)
    contains(state.macro(), "nothing to target")
    equal(state.said("Made the character macro"), true)
end)

test("kill objectives become /targetexact lines, the first objective last", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    local body = lines(state.macro())
    equal(body[1], "/cleartarget")
    equal(body[2], "/targetexact Tarantula")
    equal(body[3], "/targetexact Dire Condor")
    equal(body[4], "/targetlasttarget [dead]")
    equal(body[5], "/tm [harm,nodead] !8; [exists,noharm,nodead] !4",
        "the NPC clause needs a target: with none, noharm is true")
    equal(body[6], nil, "no opener by default")
end)

test("finished objectives and other objective kinds are left out", function()
    local state = fixture({focus = 7, quests = {[7] = {title = "Mixed", objectives = {
        objective("Dire Condor slain: 8/8", "monster", true), objective("Tarantula Silk: 0/6", "item"),
        objective("Shredder Parts: 0/1", "object"), objective("Kobold slain: 0/4")}}}})
    local body = state.macro()
    lacks(body, "Dire Condor")
    lacks(body, "Silk")
    lacks(body, "Shredder")
    contains(body, "/targetexact Kobold\n")
end)

test("the focused quest changing rebuilds the macro after one short wait", function()
    local quests = {[1] = {title = "One", objectives = {objective("Boar slain: 0/5")}},
        [2] = {title = "Two", objectives = {objective("Wolf slain: 0/5")}}}
    local state = fixture({quests = quests, focus = 1})
    contains(state.macro(), "/targetexact Boar")
    state.focus = 2
    state.emit("SUPER_TRACKING_CHANGED")
    state.emit("QUEST_LOG_UPDATE")
    contains(state.macro(), "Boar", "nothing changes before the wait")
    state.advance()
    contains(state.macro(), "/targetexact Wolf")
    lacks(state.macro(), "Boar")
    local writes = state.writes
    state.emit("QUEST_LOG_UPDATE")
    state.advance()
    equal(state.writes, writes, "an unchanged body is not written again")
end)

local TWO_QUESTS = {[1] = {title = "Boars", objectives = {objective("Boar slain: 0/5")}},
    [2] = {title = "Wolves", objectives = {objective("Wolf slain: 0/5"), objective("Bear slain: 0/2")}}}

test("Questie's tracker focus counts, and wins at login", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {focus = 2}})
    contains(state.macro(), "/targetexact Wolf")
    lacks(state.macro(), "Boar")
    state.slash("list")
    equal(state.said("Focused quest: Wolves (Questie's focus)"), true)
    local gameOnly = fixture({quests = TWO_QUESTS, focus = 1, questie = {}})
    contains(gameOnly.macro(), "/targetexact Boar", "with no Questie focus, the game's")
end)

local THREE_QUESTS = {[1] = TWO_QUESTS[1], [2] = TWO_QUESTS[2],
    [3] = {title = "Kobolds", objectives = {objective("Kobold slain: 0/5")}}}

test("the most recent focus wins, game or Questie", function()
    local state = fixture({quests = THREE_QUESTS, focus = 1, questie = {focus = 2}})
    contains(state.macro(), "/targetexact Wolf", "Questie's at login")
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    contains(state.macro(), "/targetexact Wolf", "the event without a new quest (a map pin) changes nothing")
    state.focus = 3
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    contains(state.macro(), "/targetexact Kobold", "focusing another quest in the game wins")
    state.questieUtils:FocusQuest(2)
    state.advance()
    contains(state.macro(), "/targetexact Wolf", "focusing in Questie's tracker wins")
    state.questieUtils:UnFocus()
    state.advance()
    contains(state.macro(), "/targetexact Kobold", "Questie unfocused: the game's focus again")
end)


test("the game restoring its focus on a loading screen does not beat Questie's", function()
    local state = fixture({quests = THREE_QUESTS, focus = 1, questie = {focus = 2}})
    state.emit("PLAYER_LEAVING_WORLD")
    state.focus = 3
    state.emit("SUPER_TRACKING_CHANGED")
    state.emit("PLAYER_ENTERING_WORLD")
    state.advance(3)
    contains(state.macro(), "/targetexact Wolf")
    state.focus = 1
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    contains(state.macro(), "/targetexact Boar", "after loading, a new game focus wins again")
end)

test("a new focused quest is announced with what the macro now looks for first", function()
    local state = fixture({quests = THREE_QUESTS, focus = 1, questie = {}})
    equal(state.said("Focused quest changed"), false, "not at login")
    state.focus = 3
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(state.last(), "DQT: Focused quest changed via Quest Focus (Kobolds), targeting updated to Kobold.")
    state.questieUtils:FocusQuest(2)
    state.advance()
    equal(state.last(), "DQT: Focused quest changed via Questie (Wolves), targeting updated to Wolf.")
    state.clear()
    state.emit("QUEST_LOG_UPDATE")
    state.advance()
    equal(#state.messages, 0, "progress on the same quest is not announced")
    state.combat = true
    state.questieUtils:FocusObjective(2, 2)
    state.advance()
    equal(state.last(), "DQT: Focused quest changed via Questie (Wolves), targeting updated to Bear after combat.")
    state.combat = false
    state.questieUtils:UnFocus()
    state.focus = nil
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(state.last(), "DQT: No focused quest; targeting nothing.")
end)

test("the announcement names the quest's own first mob, and the hit list apart", function()
    local state = fixture({quests = THREE_QUESTS, focus = 1, questie = {}})
    state.slash("add Skeletal Mage")
    state.focus = 3
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(state.last(), "DQT: Focused quest changed via Quest Focus (Kobolds), targeting updated to Kobold. "
        .. "Your hit list comes first: Skeletal Mage.")
    state.focus = nil
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(state.last(), "DQT: No focused quest; targeting updated to Skeletal Mage.")
end)

test("a finished objective's names leave the macro, with a word in chat", function()
    local quest = {title = "Assessing the Threat", objectives = {objective("9/10 Redridge Mongrel slain"),
        objective("0/6 Redridge Poacher slain")}}
    local state = fixture({quests = {[246] = quest}, focus = 246})
    contains(state.macro(), "/targetexact Redridge Mongrel")
    state.combat = true
    quest.objectives[1] = objective("10/10 Redridge Mongrel slain", "monster", true)
    state.emit("QUEST_WATCH_UPDATE", 246)
    state.advance()
    equal(state.last(), "DQT: Redridge Mongrel removed: Quest Assessing the Threat objective completed. "
        .. "Use /dqt add if you want to keep targeting them. The macro updates after combat.")
    contains(state.macro(), "Redridge Mongrel", "nothing is written in combat")
    state.combat = false
    state.emit("PLAYER_REGEN_ENABLED")
    lacks(state.macro(), "Redridge Mongrel")
    contains(state.macro(), "/targetexact Redridge Poacher")
    state.clear()
    state.advance()
    equal(#state.messages, 0, "said once")
    quest.objectives[2] = objective("6/6 Redridge Poacher slain", "monster", true)
    state.emit("UNIT_QUEST_LOG_CHANGED", "player")
    state.advance()
    equal(state.last(), "DQT: Redridge Poacher removed: Quest Assessing the Threat objective completed. "
        .. "Use /dqt add if you want to keep targeting them.")
    contains(state.macro(), "nothing to target")
end)

test("turning off Follow Questie's tracker focus leaves only the game's", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {focus = 2}})
    contains(state.macro(), "/targetexact Wolf")
    state.settings.DQT_QUESTIE_FOCUS:SetValue(false)
    contains(state.macro(), "/targetexact Boar")
    state.questieUtils:FocusQuest(2)
    state.advance()
    contains(state.macro(), "/targetexact Boar", "Questie's focus is ignored while off")
    state.settings.DQT_QUESTIE_FOCUS:SetValue(true)
    contains(state.macro(), "/targetexact Wolf")
end)

test("syncing the two focuses is off by default", function()
    local state = fixture({quests = THREE_QUESTS, focus = 1, questie = {}})
    state.questieUtils:FocusQuest(2)
    state.advance()
    equal(state.focus, 1, "the game's focus stays")
    state.focus = 3
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(state.env.Questie.db.char.TrackerFocus, 2, "Questie's focus stays")
end)

test("with sync on, a Questie focus sets the game's, and the game's sets Questie's", function()
    local state = fixture({quests = THREE_QUESTS, focus = 1, questie = {}, saved = {syncFocus = true}})
    state.questieUtils:FocusQuest(2)
    state.advance()
    equal(state.focus, 2, "the game focuses Questie's quest")
    contains(state.macro(), "/targetexact Wolf")
    equal(state.notes, 0)
    state.focus = 3
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(state.env.Questie.db.char.TrackerFocus, 3, "Questie focuses the game's quest")
    equal(state.notes, 1, "Questie's map icons follow, as its menu does")
    contains(state.macro(), "/targetexact Kobold")
    state.advance(5)
    equal(state.focus, 3, "no back and forth")
    equal(state.env.Questie.db.char.TrackerFocus, 3)
end)

test("with sync on, a Questie objective focus gives the game its quest and stays an objective focus", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {}, saved = {syncFocus = true}})
    state.questieUtils:FocusObjective(2, 2)
    state.advance()
    equal(state.focus, 2)
    equal(state.env.Questie.db.char.TrackerFocus, "2 2")
    contains(state.macro(), "/targetexact Bear")
    lacks(state.macro(), "Wolf")
end)

test("with sync on, unfocusing in Questie clears the game's focus on the same quest", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {}, saved = {syncFocus = true}})
    state.questieUtils:FocusQuest(2)
    state.advance()
    state.questieUtils:UnFocus()
    state.advance()
    equal(state.focus, 0, "cleared, as Blizzard clears it")
    state.advance()
    contains(state.macro(), "nothing to target", "the next rebuild follows")
end)

test("sync does nothing while Follow Questie's tracker focus is off, or without Questie", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {focus = 2},
        saved = {syncFocus = true, questieFocus = false}})
    state.questieUtils:FocusQuest(2)
    state.advance()
    equal(state.focus, 1)
    local bare = fixture({quests = THREE_QUESTS, focus = 1, saved = {syncFocus = true}})
    bare.focus = 3
    bare.emit("SUPER_TRACKING_CHANGED")
    bare.advance()
    contains(bare.macro(), "/targetexact Kobold")
    equal(bare.focusSets, nil, "the game's focus is left alone")
end)

test("every integration setting sits under the experimental Integrations heading", function()
    local state = fixture()
    local list = state.registered.initializers
    local heading
    for index, object in ipairs(list) do
        if object.header == "Integrations (Experimental)" then heading = index end
    end
    local INTEGRATIONS = {"DQT_QUESTIE_FOCUS", "DQT_ZYGOR_FOCUS", "DQT_RXP_FOCUS", "DQT_QTR_FOCUS", "DQT_SYNC_FOCUS",
        "DQT_TOMTOM"}
    for offset, variable in ipairs(INTEGRATIONS) do
        equal(list[heading + offset].setting.variable, variable)
    end
    for index = 1, heading - 1 do
        local variable = list[index].setting and list[index].setting.variable
        equal(variable == "DQT_QUESTIE_FOCUS" or variable == "DQT_ZYGOR_FOCUS" or variable == "DQT_RXP_FOCUS"
            or variable == "DQT_QTR_FOCUS", false,
            "the main section keeps only the macro's own settings")
    end
    for offset = 1, #INTEGRATIONS do
        lacks(list[heading + offset].setting.name, "xperimental", "the heading says it")
    end
    equal(list[heading + 2].setting.name, "Follow Zygor's current step")
    contains(list[heading + 5].tooltip, "Use with caution.")
    equal(list[heading + 3].setting.name, "Follow RestedXP's current step")
    local bare = fixture({noSectionHeaders = true})
    equal(bare.settings.DQT_SYNC_FOCUS.name, "Keep Questie's and the game's focus in sync",
        "without headings, the settings are still there, with the same names")
    equal(bare.settings.DQT_ZYGOR_FOCUS.name, "Follow Zygor's current step")
    equal(bare.settings.DQT_TOMTOM.name, "Point TomTom at the focused quest")
end)

-- The settings row for a variable.
local function settingRow(state, variable)
    for _, object in ipairs(state.registered.initializers) do
        if object.setting and object.setting.variable == variable then return object end
    end
end

test("Questie and TomTom settings are greyed out without their AddOns; saved values stay", function()
    local QUESTIE_ROWS = {"DQT_QUESTIE_FOCUS", "DQT_SYNC_FOCUS", "DQT_TOMTOM"}
    local saved = {questieFocus = true, syncFocus = true, tomtom = true}
    local none = fixture({quests = TWO_QUESTS, focus = 1, saved = saved})
    for _, variable in ipairs(QUESTIE_ROWS) do
        equal(settingRow(none, variable):Enabled(), false, variable .. ": greyed out without Questie")
    end
    contains(settingRow(none, "DQT_QUESTIE_FOCUS").tooltip, "Needs Questie: greyed out until it is installed")
    contains(settingRow(none, "DQT_SYNC_FOCUS").tooltip, "Needs Questie:")
    contains(settingRow(none, "DQT_TOMTOM").tooltip, "Needs TomTom, with Questie, Zygor, RestedXP, or QuestTrail:")
    equal(settingRow(none, "DQT_MARK"):Enabled(), true, "other settings stay on")
    local db = none.env.DyresQuestTargetingDB
    equal(db.syncFocus and db.tomtom and db.questieFocus, true, "the saved values stay as they were")
    local questie = fixture({quests = TWO_QUESTS, focus = 1, questie = {}})
    equal(settingRow(questie, "DQT_QUESTIE_FOCUS"):Enabled(), true, "Questie: on")
    equal(settingRow(questie, "DQT_SYNC_FOCUS"):Enabled(), true)
    equal(settingRow(questie, "DQT_TOMTOM"):Enabled(), false, "Questie without TomTom: TomTom greyed out")
    local both = fixture({quests = TWO_QUESTS, focus = 1, questie = {}, tomtom = true})
    for _, variable in ipairs(QUESTIE_ROWS) do
        equal(settingRow(both, variable):Enabled(), true, variable .. ": on with both")
    end
    -- Asked each time the row is drawn: an AddOn that loads later counts.
    none.env.QuestieLoader = {ImportModule = function() return {} end}
    none.env.TomTom = {}
    equal(settingRow(none, "DQT_TOMTOM"):Enabled(), true, "loaded after the page was built")
    local guide = fixture({quests = TWO_QUESTS, focus = 1, tomtom = true, rxp = {steps = {}}})
    equal(settingRow(guide, "DQT_TOMTOM"):Enabled(), true, "TomTom and a guide, no Questie")
    equal(settingRow(guide, "DQT_SYNC_FOCUS"):Enabled(), false, "the sync still needs Questie")
    local guideOnly = fixture({quests = TWO_QUESTS, focus = 1, rxp = {steps = {}}})
    equal(settingRow(guideOnly, "DQT_TOMTOM"):Enabled(), false, "a guide, no TomTom")
end)

test("classic: without the game's focus, DQT follows Questie's; the focus settings are greyed", function()
    local state = fixture({classic = true, quests = TWO_QUESTS, questie = {focus = 2},
        saved = {questieFocus = false, syncFocus = true}})
    equal(state.dqt.available, true, "Questie's focus is enough to start")
    contains(state.macro(), "/targetexact Wolf", "follows Questie's focus, also with its switch saved off")
    equal(state.said("lacks"), false)
    state.questieUtils:FocusQuest(1)
    state.advance()
    contains(state.macro(), "/targetexact Boar")
    lacks(state.macro(), "Wolf")
    local follow, sync = settingRow(state, "DQT_QUESTIE_FOCUS"), settingRow(state, "DQT_SYNC_FOCUS")
    equal(follow:Enabled(), false, "greyed: it cannot be turned off")
    equal(follow.setting:GetValue(), true, "shown on")
    contains(follow.tooltip, "no quest focus of its own, so DQT always follows Questie's")
    equal(sync:Enabled(), false, "nothing to sync")
    contains(sync.tooltip, "nothing to sync")
    equal(state.focusSets, nil, "the sync never touches a game focus")
    for _, frame in ipairs(state.frames) do
        equal(frame.events.SUPER_TRACKING_CHANGED, nil, "an event this client does not know is not registered")
    end
    state.slash("debug")
    equal(state.said("game focus=none on this client"), true)
end)

test("classic: titles and completion come from the older quest log", function()
    local quests = {[101] = {title = "Silk", complete = true, objectives = {objective("Dire Condor slain: 8/8",
        "monster", true)}}}
    local db = {quests = {[101] = {finishedBy = {{30}}}}, npcs = {[30] = "Guard Parker"}, items = {}}
    local state = fixture({classic = true, db = db, quests = quests, questie = {focus = 101}})
    contains(state.macro(), "/targetexact Guard Parker", "complete: the turn-in NPC, from QuestieDB")
    state.slash("list")
    equal(state.said("Focused quest: Silk (Questie's focus) (ready to turn in)"), true)
end)

test("classic: without any quest focus, DQT keeps the hit list in the macro; quest targeting is off", function()
    local state = fixture({classic = true, quests = TWO_QUESTS})
    equal(state.dqt.available, true, "not disabled: the hit list still works")
    equal(state.said("Ready."), true)
    equal(state.said("This client has no quest focus of its own, and Questie is not loaded, so quest targeting is "
        .. "off; the macro keeps your hit list. Install Questie from CurseForge to target your quests."), true)
    contains(state.macro(), "nothing to target", "no quest names")
    state.target = "Goretusk"
    state.slash("add")
    contains(state.macro(), "/tar Goretusk", "the hit list goes into the macro")
    equal(state.dqt.box.shown, true, "the box shows the hit list")
    local header
    for _, child in ipairs(state.dqt.box.children) do
        if child.kind == "Button" and child.rate and child.full then header = header or child end
    end
    equal(header.full, "No quest focus: install Questie")
    state.clear()
    state.slash("list")
    equal(state.said("No quest focus on this client without Questie: the macro uses your hit list."), true)
end)

test("classic: a fresh character with no focus and no hit list gets the macro at login", function()
    for _, options in ipairs({{classic = true, questie = {}}, {classic = true}}) do
        options.quests, options.realDefaults = TWO_QUESTS, true
        local state = fixture(options)
        equal(#state.character, 1, "the character macro is made at login")
        equal(state.character[1].name, "! Target (DQT)")
        equal(state.character[1].icon, 132177, "Hunter Marksman, by file ID as Era's Macro window passes it")
        equal(state.character[1].body, "// Dyre's Quest Targeting: nothing to target. /dqt add <name> adds one.")
        equal(#state.account, 0)
        equal(state.said("Made the character macro"), true)
    end
end)

test("forever: the game's focus and Questie's together, unchanged", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {}})
    equal(state.dqt.available, true)
    equal(settingRow(state, "DQT_QUESTIE_FOCUS"):Enabled(), true)
    equal(settingRow(state, "DQT_SYNC_FOCUS"):Enabled(), true)
    contains(settingRow(state, "DQT_QUESTIE_FOCUS").tooltip, "Needs Questie:")
    local registered = false
    for _, frame in ipairs(state.frames) do
        registered = registered or frame.events.SUPER_TRACKING_CHANGED == true
    end
    equal(registered, true)
end)

local SPAWNS = {[2] = {[2] = {spawn = {40, 60}, zone = 12, name = "Bear"}}}

test("TomTom is off by default, and not pointed at login", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {}, tomtom = true})
    state.focus = 2
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(#state.waypoints, 0, "off")
    local on = fixture({quests = TWO_QUESTS, focus = 1, questie = {}, tomtom = true, saved = {tomtom = true}})
    equal(#on.waypoints, 0, "a waypoint of your own stays at login")
end)

test("TomTom points at the focused quest, its objective, and again as objectives finish", function()
    local quests = {[1] = TWO_QUESTS[1], [2] = {title = "Wolves", objectives = {
        objective("Wolf slain: 0/5"), objective("Bear slain: 0/2")}}}
    local state = fixture({quests = quests, focus = 1, questie = {spawns = SPAWNS}, tomtom = true})
    state.settings.DQT_TOMTOM:SetValue(true)
    equal(state.waypoints[1], "quest 1", "turning it on points now")
    state.focus = 2
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(state.waypoints[2], "quest 2")
    state.emit("QUEST_LOG_UPDATE")
    state.advance()
    equal(#state.waypoints, 2, "no change, no new waypoint")
    state.questieUtils:FocusObjective(2, 2)
    state.advance()
    equal(state.waypoints[3], "Bear 12 40,60", "an objective focus points at that objective")
    quests[2].objectives[2] = objective("Bear slain: 2/2", "monster", true)
    state.emit("QUEST_LOG_UPDATE")
    state.advance()
    equal(state.waypoints[4], "quest 2", "its objective done: the quest's nearest objective")
    quests[2].complete = true
    quests[2].objectives[1] = objective("Wolf slain: 5/5", "monster", true)
    state.emit("QUEST_LOG_UPDATE")
    state.advance()
    equal(state.waypoints[5], "quest 2", "complete: Questie points at the turn-in")
end)

test("TomTom is left alone without TomTom or Questie", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {}, saved = {tomtom = true}})
    state.focus = 2
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(#state.waypoints, 0, "no TomTom")
    local bare = fixture({quests = TWO_QUESTS, focus = 1, tomtom = true, saved = {tomtom = true}})
    bare.settings.DQT_TOMTOM:SetValue(true)
    bare.focus = 2
    bare.emit("SUPER_TRACKING_CHANGED")
    bare.advance()
    contains(bare.macro(), "/targetexact Wolf", "no Questie: the macro still works")
end)

test("Questie's objective focus targets that objective only", function()
    local state = fixture({quests = TWO_QUESTS, questie = {}})
    state.questieUtils:FocusObjective(2, 2)
    state.advance()
    contains(state.macro(), "/targetexact Bear")
    lacks(state.macro(), "Wolf")
    state.slash("list")
    equal(state.said("Focused quest: Wolves (Questie's focus, objective 2)"), true)
end)

test("a Questie focus on a quest not in the log, or odd saved data, is ignored", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, questie = {focus = 999}})
    contains(state.macro(), "/targetexact Boar")
    local odd = fixture({quests = TWO_QUESTS, focus = 1, questie = {focus = "two"}})
    contains(odd.macro(), "/targetexact Boar")
end)

test("no focused quest, an unknown quest, or a secret ID target nothing", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 999})
    contains(state.macro(), "nothing to target")
    state.focus = secret()
    state.secrets[state.focus] = true
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    contains(state.macro(), "nothing to target")
end)

local DB = {
    quests = {
        [101] = {objectives = {{{1, nil, 8}}, nil, {{50, nil, 6}}}, finishedBy = {{30}}},
        [102] = {objectives = {nil, nil, nil, nil, {{{11, 12, 13, 14}, 11, "Bloodfeather Harpy", 6}}}},
    },
    npcs = {[1] = "Dire Condor", [11] = "Bloodfeather Harpy", [12] = "Bloodfeather Sorceress",
        [13] = "Bloodfeather Wind Witch", [14] = "Bloodfeather Matriarch", [20] = "Tarantula",
        [21] = "Giant Tarantula", [22] = "Cave Tarantula", [23] = "Venomous Tarantula", [30] = "Guard Parker"},
    items = {[50] = {name = "Tarantula Silk", drops = {20, 21, 22, 23}}},
}

test("with QuestieDB, item objectives target the mobs that drop the item", function()
    local state = fixture({db = DB, focus = 101, quests = {[101] = {title = "Silk", objectives = {
        objective("Dire Condor slain: 0/8"), objective("Tarantula Silk: 0/6", "item")}}}})
    local body = state.macro()
    contains(body, "/targetexact Venomous Tarantula\n/targetexact Cave Tarantula\n/targetexact Giant Tarantula\n"
        .. "/targetexact Tarantula\n/targetexact Dire Condor\n",
        "without drop rates, QuestieDB's order, its first dropper last (most wanted)")
    state.clear()
    state.slash("list")
    equal(state.said("Dire Condor (kill objective"), true)
    equal(state.said("Tarantula (drops a quest item: Tarantula Silk)"), true)
    state.slash("debug")
    equal(state.said("dropped by Tarantula, Giant Tarantula, Cave Tarantula, Venomous Tarantula "
        .. "(4; the macro uses the best 6)"), true, "debug lists every dropper")
end)

local SILK = {[101] = {title = "Silk", objectives = {objective("Tarantula Silk: 0/6", "item")}}}

test("with Questie's drop rates, the best droppers come first, and /dqt shows the rates", function()
    local state = fixture({db = DB, focus = 101, quests = SILK,
        questie = {rates = {[50] = {[20] = 4, [21] = 30.3, [22] = -12, [23] = 18}}}})
    contains(state.macro(), "/cleartarget\n/targetexact Tarantula\n/targetexact Cave Tarantula\n"
        .. "/targetexact Venomous Tarantula\n/targetexact Giant Tarantula\n", "the best rate last, so it wins")
    state.clear()
    state.slash("list")
    equal(state.said("Giant Tarantula (drops a quest item: Tarantula Silk, 30.3% drop rate)"), true)
    state.slash("debug")
    equal(state.said("dropped by Giant Tarantula 30.3%, Venomous Tarantula 18.0%, Cave Tarantula 12.0%, "
        .. "Tarantula 4.0%"), true, "debug lists droppers best first")
end)

test("droppers past six are left out, worst first, and UNUSED placeholders never count", function()
    local db = {quests = {[101] = {objectives = {nil, nil, {{60, nil, 6}}}}},
        npcs = {[1] = "Ghoul A", [2] = "Ghoul B", [3] = "Ghoul C", [4] = "Ghoul D", [5] = "Ghoul E",
            [6] = "Ghoul F", [7] = "Ghoul G", [8] = "Shambling Skeleton UNUSED"},
        items = {[60] = {name = "Ghoul Fang", drops = {8, 1, 2, 3, 4, 5, 6, 7}}}}
    local state = fixture({db = db, focus = 101, quests = {[101] = {title = "Fangs", objectives = {
        objective("0/10 Ghoul Fang", "item")}}},
        questie = {rates = {[60] = {[1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6, [7] = 7, [8] = 99}}}})
    local body = state.macro()
    lacks(body, "UNUSED")
    lacks(body, "Ghoul A", "the seventh best is left out")
    contains(body, "/targetexact Ghoul B\n/targetexact Ghoul C\n/targetexact Ghoul D\n/targetexact Ghoul E\n"
        .. "/targetexact Ghoul F\n/targetexact Ghoul G\n")
end)

test("TomTom points at the nearest spawn of a mob the macro lists", function()
    local state = fixture({db = DB, focus = 101, quests = SILK, tomtom = true, saved = {tomtom = true},
        questie = {rates = {[50] = {[20] = 4, [21] = 30, [22] = 12, [23] = 18}},
            npcs = {[20] = {name = "Tarantula", at = {10, 10}, zone = 40, far = 50},
                [22] = {name = "Cave Tarantula", at = {20, 30}, zone = 40, far = 5},
                [21] = {name = "Giant Tarantula", at = {70, 80}, zone = 40, far = 90}}}})
    state.settings.DQT_TOMTOM:SetValue(true)
    equal(state.waypoints[#state.waypoints], "Cave Tarantula 40 20,30", "the nearest of the macro's mobs")
    SILK[101].complete = true
    state.emit("QUEST_LOG_UPDATE")
    state.advance()
    equal(state.waypoints[#state.waypoints], "quest 101", "complete: Questie points at the turn-in")
    SILK[101].complete = nil
end)

test("with QuestieDB, a shared kill objective targets each of its mobs", function()
    local state = fixture({db = DB, focus = 102, quests = {[102] = {title = "Harpies", objectives = {
        objective("Bloodfeather Harpy slain: 0/6")}}}})
    local body = state.macro()
    contains(body, "/targetexact Bloodfeather Harpy\n/targetexact Bloodfeather Sorceress\n"
        .. "/targetexact Bloodfeather Wind Witch\n")
    lacks(body, "Matriarch")
end)

test("a quest ready to turn in targets its turn-in NPC, with QuestieDB only", function()
    local quests = {[101] = {title = "Silk", complete = true, objectives = {objective("Dire Condor slain: 8/8",
        "monster", true)}}}
    local state = fixture({db = DB, focus = 101, quests = quests})
    contains(state.macro(), "/cleartarget\n/targetexact Guard Parker\n")
    local bare = fixture({focus = 101, quests = quests})
    contains(bare.macro(), "nothing to target")
    bare.slash("list")
    equal(bare.said("QuestieDB is not loaded"), true)
end)

test("an older QuestieDB contract is not used", function()
    local state = fixture({db = DB, dbContract = 3, focus = 101, quests = {[101] = {title = "Silk",
        objectives = {objective("Tarantula Silk: 0/6", "item")}}}})
    contains(state.macro(), "nothing to target")
    state.clear()
    state.slash("debug")
    equal(state.said("does not support contract 4"), true)
end)

test("when the macro is full, the least important names are left out", function()
    local list = {}
    for index = 1, 12 do
        list[index] = objective("Very Long Named Creature Number " .. index .. " slain: 0/1")
    end
    local state = fixture({focus = 5, quests = {[5] = {title = "Many", objectives = list}}})
    local body = state.macro()
    equal(#body <= 255, true)
    contains(body, "Number 1\n", "the first objective is kept")
    lacks(body, "Number 12", "the last objective is left out")
    contains(body, "/targetlasttarget [dead]")
    state.clear()
    state.slash("list")
    equal(state.said("No room in the macro for Very Long Named Creature Number 12"), true)
end)

test("in combat the macro waits, then is written when combat ends", function()
    local state = fixture({quests = CONDOR_QUEST})
    state.combat = true
    state.focus = 101
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    contains(state.macro(), "nothing to target", "nothing is written in combat")
    state.combat = false
    state.emit("PLAYER_REGEN_ENABLED")
    contains(state.macro(), "/targetexact Dire Condor")
end)

test("/dqt add uses a similar-name /tar line, add_exact /targetexact, both after quest names", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    state.slash("add Goretusk")
    equal(state.last(), "DQT: Added Goretusk to your hit list (any name containing it).")
    state.slash("ADD_EXACT  Great Goretusk ")
    equal(state.last(), "DQT: Added Great Goretusk to your hit list (exact name).")
    local body = lines(state.macro())
    equal(body[4], "/tar Goretusk")
    equal(body[5], "/targetexact Great Goretusk")
    equal(body[6], "/targetlasttarget [dead]")
    state.slash("add_exact goretusk")
    contains(state.macro(), "/targetexact Great Goretusk\n/targetexact goretusk\n", "adding again switches kind")
    lacks(state.macro(), "/tar Goretusk")
end)

test("added names are saved per character and repaired on load", function()
    local saved = {enabled = "yes", mark = 0, opener = "Bad; Spell", mobMarker = 12, npcMarker = 2.5, added = {
        {name = "  Wolf  "}, {name = "wolf", exact = true}, {name = "Bad;Name"}, "junk", {name = ""},
        {name = "Boar", exact = true}}}
    local state = fixture({saved = saved})
    local db = state.env.DyresQuestTargetingDB
    equal(db.enabled, true)
    equal(db.mark, true)
    equal(db.opener, "")
    equal(db.mobMarker, 8)
    equal(db.npcMarker, 4)
    equal(#db.added, 2)
    equal(db.added[1].name, "Wolf")
    equal(db.added[1].exact, false)
    equal(db.added[2].name, "Boar")
    contains(state.macro(), "/tar Wolf\n/targetexact Boar\n")
    equal(fixture({saved = "junk"}).env.DyresQuestTargetingDB.enabled, true)
end)

test("/dqt add with no name adds your target, or says to target something", function()
    local state = fixture()
    state.slash("add")
    equal(state.last(), "DQT: Target a mob or type a name.")
    state.target = "Mangy Wolf"
    state.slash("add_exact   ")
    contains(state.macro(), "/targetexact Mangy Wolf\n")
    state.target = secret()
    state.secrets[state.target] = true
    state.slash("add")
    contains(state.last(), "cannot be read right now")
end)

-- Bindings.xml's bindings, as {name, header, body}; the game runs each body as Lua.
local function bindings()
    local text = assert(io.open("Bindings.xml", "rb")):read("*a")
    local found = {}
    for attributes, body in text:gmatch("<Binding%s+(.-)>(.-)</Binding>") do
        found[#found + 1] = {name = attributes:match('name="([^"]+)"'),
            header = attributes:match('header="([^"]+)"'), body = body}
    end
    return found
end

test("key bindings: add, add exact, and remove the target, through /dqt; each is named", function()
    local found = bindings()
    equal(#found, 3)
    equal(found[1].header, "DYRESQUESTTARGETING", "one header, on the first")
    local state = fixture()
    equal(state.env.BINDING_HEADER_DYRESQUESTTARGETING, "Dyre's Quest Targeting")
    local run = {}
    for _, binding in ipairs(found) do
        equal(type(state.env["BINDING_NAME_" .. binding.name]), "string", binding.name .. " has a name to show")
        local chunk = assert(loadstring(binding.body))
        setfenv(chunk, state.env)
        run[binding.name] = chunk
    end
    run.DQT_ADD_TARGET()
    equal(state.last(), "DQT: Target a mob or type a name.", "no target: as /dqt add")
    state.target = "Mangy Wolf"
    run.DQT_ADD_TARGET()
    contains(state.macro(), "/tar Mangy Wolf\n")
    state.target = "Boar"
    run.DQT_ADD_TARGET_EXACT()
    contains(state.macro(), "/targetexact Boar\n")
    run.DQT_REMOVE_TARGET()
    lacks(state.macro(), "Boar")
    contains(state.macro(), "/tar Mangy Wolf\n", "only the target goes")
    state.combat = true
    state.target = "Kobold"
    run.DQT_ADD_TARGET()
    equal(state.env.DyresQuestTargetingDB.added[2].name, "Kobold", "in combat the hit list changes at once")
    lacks(state.macro(), "Kobold", "the macro waits for the end of combat")
end)

test("names with ; or too long to fit are refused", function()
    local state = fixture()
    state.slash("add Wolf; Boar")
    equal(state.last(), "DQT: A name cannot contain \";\" or a line break.")
    state.slash("add " .. string.rep("x", 200))
    contains(state.last(), "is too long to fit in the macro.")
    equal(#state.env.DyresQuestTargetingDB.added, 0)
    local longest = string.rep("y", state.dqt.MaxNameLength())
    state.env.DyresQuestTargetingDB.opener = string.rep("z", state.dqt.MAX_OPENER_LENGTH)
    state.slash("add_exact " .. longest)
    contains(state.macro(), longest, "the longest allowed name fits with every line on")
    contains(state.macro(), "/use [harm,nodead] " .. string.rep("z", state.dqt.MAX_OPENER_LENGTH))
    equal(#state.macro(), 255, "the limit follows the opener's prefix exactly")
end)

test("/dqt remove and /dqt reset take names off the hit list only", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    state.slash("add Goretusk")
    state.slash("add Boar")
    state.slash("remove goretusk")
    equal(state.last(), "DQT: Removed Goretusk from your hit list.")
    lacks(state.macro(), "Goretusk")
    state.slash("remove Goretusk")
    equal(state.last(), "DQT: Goretusk is not on your hit list.")
    state.target = "Boar"
    state.slash("remove")
    equal(state.last(), "DQT: Removed Boar from your hit list.")
    state.slash("add Wolf")
    state.slash("add Bear")
    state.slash("reset")
    equal(state.last(), "DQT: Cleared your hit list (2 names).")
    lacks(state.macro(), "/tar ")
    contains(state.macro(), "/targetexact Dire Condor", "quest names stay")
end)

test("macro conditions pick the command: add, or remove with Shift", function()
    local state = fixture({quests = THREE_QUESTS, focus = 2})
    state.target = "Mangy Wolf"
    state.slash("[mod:shift] remove; add")
    contains(state.macro(), "/tar Mangy Wolf")
    state.shift = true
    state.slash("[mod:shift] remove; add")
    lacks(state.macro(), "Mangy Wolf")
    state.target = "Bear"
    state.slash("[mod:shift] remove; add")
    equal(state.last(), "DQT: Bear is not on your hit list.", "quest names cannot be removed")
    contains(state.macro(), "/targetexact Bear")
    equal(#state.character, 1, "only the targeting macro is made")
end)

test("without the option parser, a bracketed command shows the usage", function()
    local state = fixture({noOptionParse = true})
    state.slash("[mod:shift] remove; add")
    contains(state.last(), "Use /dqt")
end)

test("adding past the limit drops the oldest added name", function()
    local state = fixture()
    for index = 1, state.dqt.MAX_ADDED + 1 do
        state.slash("add Mob" .. index)
    end
    contains(state.last(), "Removed the oldest, Mob1.")
    equal(#state.env.DyresQuestTargetingDB.added, state.dqt.MAX_ADDED)
end)

test("an added name in combat waits for combat to end", function()
    local state = fixture()
    state.combat = true
    state.slash("add Wolf")
    equal(state.last(), "DQT: Added Wolf to your hit list (any name containing it). The macro updates after combat.")
    lacks(state.macro(), "Wolf")
    state.combat = false
    state.emit("PLAYER_REGEN_ENABLED")
    contains(state.macro(), "/tar Wolf")
end)

test("markers follow the settings, and the mark switch turns them off", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    state.settings.DQT_MOB_MARKER:SetValue(7)
    state.settings.DQT_NPC_MARKER:SetValue(0)
    contains(state.macro(), "\n/tm [harm,nodead] !7")
    lacks(state.macro(), "noharm")
    state.settings.DQT_MOB_MARKER:SetValue(42)
    equal(state.env.DyresQuestTargetingDB.mobMarker, 7, "a marker outside 0-8 is refused")
    state.settings.DQT_MOB_MARKER:SetValue(0)
    lacks(state.macro(), "/tm")
    state.settings.DQT_MOB_MARKER:SetValue(8)
    state.settings.DQT_MARK:SetValue(false)
    lacks(state.macro(), "/tm", "marking off for purists")
    local choices = state.settings.DQT_MOB_MARKER and state.registered.initializers[3].options()
    equal(choices[1].label, "None")
    equal(choices[5].label, "Triangle (green)")
    equal(choices[9].label, "Skull")
end)

local SPELLBOOK = {
    {name = "General", offset = 0, items = {
        {name = "Auto Shot", subName = "", itemType = 1},
        {name = "Attack", subName = "", itemType = 1},
        {name = "Dodge", subName = "", itemType = 1, isPassive = true},
    }},
    {name = "Balance", offset = 3, items = {
        {name = "Moonfire", subName = "Rank 3", itemType = 1},
        {name = "Wrath", subName = "Rank 1", itemType = 1},
        {name = "Entangling Roots", subName = "Rank 1", itemType = 1},
        {name = "Mark of the Wild", subName = "Rank 1", itemType = 1},
        {name = "Hidden Flyout", subName = "", itemType = 2},
    }},
    {name = "Guild", offset = 8, isGuild = true, items = {{name = "Guild Perk", subName = "", itemType = 1}}},
}

-- C_Spell's answers by "Name(Rank N)": harmful, and the cast time in ms.
local SPELL_INFO = {
    ["Auto Shot"] = {harmful = true, castTime = 0},
    ["Attack"] = {harmful = true, castTime = 0},
    ["Moonfire(Rank 1)"] = {harmful = true, castTime = 0},
    ["Moonfire(Rank 2)"] = {harmful = true, castTime = 0},
    ["Moonfire(Rank 3)"] = {harmful = true, castTime = 0},
    ["Wrath(Rank 1)"] = {harmful = true, castTime = 1500},
    ["Entangling Roots(Rank 1)"] = {harmful = true, castTime = 1000},
    ["Mark of the Wild(Rank 1)"] = {harmful = false, castTime = 0},
}

local function spellbookGlobals(noSpellInfo)
    local function item(slot)
        for _, line in ipairs(SPELLBOOK) do
            local entry = line.items[slot - line.offset]
            if entry then return entry end
        end
    end
    return {
        Enum = {SpellBookSpellBank = {Player = 0, Pet = 1}, SpellBookItemType = {None = 0, Spell = 1, Flyout = 2}},
        C_SpellBook = {
            GetNumSpellBookSkillLines = function() return #SPELLBOOK end,
            GetSpellBookSkillLineInfo = function(index)
                local line = SPELLBOOK[index]
                return {name = line.name, itemIndexOffset = line.offset, numSpellBookItems = #line.items,
                    isGuild = line.isGuild == true, shouldHide = false}
            end,
            GetSpellBookItemInfo = function(slot, bank)
                equal(bank, 0, "the player's spellbook")
                local entry = item(slot)
                return {name = entry.name, subName = entry.subName, itemType = entry.itemType,
                    isPassive = entry.isPassive == true, isOffSpec = false}
            end,
        },
        C_Spell = not noSpellInfo and {
            IsSpellHarmful = function(name) return SPELL_INFO[name] ~= nil and SPELL_INFO[name].harmful end,
            GetSpellInfo = function(name)
                local info = SPELL_INFO[name]
                return info and {name = name, castTime = info.castTime}
            end,
        } or nil,
    }
end

-- Classic Era and Anniversary's spellbook: the older tab API only.
local function oldSpellbookGlobals()
    local globals = spellbookGlobals()
    globals.C_SpellBook = nil
    local function item(slot)
        for _, line in ipairs(SPELLBOOK) do
            local entry = line.items[slot - line.offset]
            if entry then return entry end
        end
    end
    globals.GetNumSpellTabs = function() return #SPELLBOOK end
    globals.GetSpellTabInfo = function(tab)
        local line = SPELLBOOK[tab]
        return line.name, nil, line.offset, #line.items
    end
    globals.GetSpellBookItemName = function(slot, book)
        equal(book, "spell", "the player's spellbook")
        local entry = item(slot)
        return entry.name, entry.subName
    end
    globals.IsPassiveSpell = function(slot) return item(slot).isPassive == true end
    return globals
end

test("classic: the opener lists the spellbook through the older tab API", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101, globals = oldSpellbookGlobals()})
    local labels = {}
    for _, object in ipairs(state.registered.initializers) do
        if object.setting and object.setting.variable == "DQT_OPENER" then
            for _, choice in ipairs(object.options()) do labels[#labels + 1] = choice.label end
        end
    end
    equal(table.concat(labels, ","), "Nothing,Start attacking (/startattack),Attack,Auto Shot,"
        .. "Entangling Roots(Rank 1),Moonfire(Rank 1),Moonfire(Rank 2),Moonfire(Rank 3)",
        "each rank, harmful spells of 1 second or less, no passives")
end)

test("the opener lists every spellbook spell and rank, and casts the one picked", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101, globals = spellbookGlobals()})
    local opener = state.registered.initializers[5]
    equal(opener.setting.variable, "DQT_OPENER")
    local labels = {}
    for _, choice in ipairs(opener.options()) do labels[#labels + 1] = choice.label end
    equal(table.concat(labels, ","), "Nothing,Start attacking (/startattack),Attack,Auto Shot,"
        .. "Entangling Roots(Rank 1),Moonfire(Rank 1),Moonfire(Rank 2),Moonfire(Rank 3)",
        "harmful spells of 1 second or less only: no Wrath (1.5 s), no Mark of the Wild (helpful)")
    opener.setting:SetValue("Moonfire(Rank 1)")
    local body = lines(state.macro())
    equal(body[#body], "/use [harm,nodead] Moonfire(Rank 1)")
    opener.setting:SetValue("startattack")
    body = lines(state.macro())
    equal(body[#body], "/startattack [harm,nodead]")
    opener.setting:SetValue("Bad; Spell")
    equal(state.env.DyresQuestTargetingDB.opener, "startattack", "an unsafe name is refused")
    opener.setting:SetValue("")
    lacks(state.macro(), "/startattack")
    lacks(state.macro(), "/use")
end)

test("each dropdown sets its own label function, so a pooled frame's stale one is replaced", function()
    local state = fixture()
    for _, index in ipairs({3, 4, 5}) do
        local dropdown = state.registered.initializers[index]
        equal(type(dropdown.getSelectionTextFunc), "function", dropdown.setting.variable)
        equal(dropdown.getSelectionTextFunc(), nil, "nil keeps the chosen option's own text")
    end
end)

test("without the spell info API, the opener lists every spell, as before", function()
    local state = fixture({globals = spellbookGlobals(true)})
    local labels = {}
    for _, choice in ipairs(state.registered.initializers[5].options()) do labels[#labels + 1] = choice.label end
    contains(table.concat(labels, ","), "Wrath(Rank 1)")
    contains(table.concat(labels, ","), "Mark of the Wild(Rank 1)")
end)

test("a spell picked earlier stays in the list after the spellbook loses it", function()
    local state = fixture({globals = spellbookGlobals(), saved = {opener = "Rake(Rank 2)"}})
    local choices = state.registered.initializers[5].options()
    equal(choices[#choices].label, "Rake(Rank 2)")
    local bare = fixture({saved = {opener = "Rake(Rank 2)"}})
    choices = bare.registered.initializers[5].options()
    equal(#choices, 3, "without the spellbook API, the saved spell and the two fixed choices")
end)

test("/dqt off leaves the macro as it is; /dqt on rebuilds it", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    state.slash("off")
    contains(state.last(), "Off:")
    local before = state.macro()
    state.slash("add Wolf")
    state.focus = nil
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    equal(state.macro(), before)
    state.slash("list")
    contains(state.last(), "Off:")
    state.slash("on")
    contains(state.macro(), "/tar Wolf")
    lacks(state.macro(), "Condor")
end)

test("the macro uses the Hunter Marksman icon", function()
    local state = fixture()
    equal(state.character[1].name, MACRO)
    equal(state.character[1].icon, 132177)
end)

test("a character macro with the old name is renamed in place, not made again", function()
    local state = fixture({characterMacros = {{name = "mine", body = "/say hi"},
        {name = OLD_MACRO, icon = "Ability_Hunter_SniperShot", body = "/say old"}}, quests = CONDOR_QUEST, focus = 101})
    equal(#state.character, 2, "no second macro")
    equal(state.character[2].name, MACRO)
    equal(state.character[2].icon, 132177)
    contains(state.macro(), "/targetexact Dire Condor")
    equal(state.character[1].body, "/say hi")
    equal(state.said("Renamed the character macro"), true)
    equal(state.said("Made the character macro"), false)
end)

test("an account macro with the old name is left alone", function()
    local state = fixture({accountMacros = {{name = OLD_MACRO, body = "/say mine"}}})
    equal(state.account[1].name, OLD_MACRO)
    equal(state.account[1].body, "/say mine")
    contains(state.macro(), "nothing to target")
end)

test("an account macro of the same name is left alone, with a warning", function()
    local state = fixture({accountMacros = {{name = MACRO, body = "/say mine"}}, quests = CONDOR_QUEST, focus = 101})
    equal(state.account[1].body, "/say mine")
    contains(state.macro(), "/targetexact Dire Condor", "the character macro is made and kept up to date")
    equal(state.said("The account-wide macro \"" .. MACRO .. "\" is not updated now"), true)
end)

test("the macro is a character macro by default", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    equal(state.dqt.db.accountMacro, false)
    contains(state.macro(), "/targetexact Dire Condor")
    equal(state.accountMacro(), nil)
    equal(state.settings.DQT_ACCOUNT_MACRO.default, false)
end)

test("Use an account-wide macro makes and updates one account macro, and leaves the character one", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    local before = state.macro()
    state.settings.DQT_ACCOUNT_MACRO:SetValue(true)
    contains(state.accountMacro(), "/targetexact Dire Condor")
    equal(state.account[1].icon, 132177)
    equal(state.said("Made the account-wide macro"), true)
    equal(state.said("The character macro \"" .. MACRO .. "\" is not updated now"), true)
    state.slash("add Wolf")
    contains(state.accountMacro(), "/tar Wolf")
    equal(state.macro(), before, "the character macro is left as it was")
    state.slash("debug")
    equal(state.said("debug macro account-wide index=1"), true)
    state.settings.DQT_ACCOUNT_MACRO:SetValue(false)
    contains(state.macro(), "/tar Wolf", "switched back: the character macro again")
end)

test("with no free account macro slot, DQT says so", function()
    local full = {}
    for index = 1, ACCOUNT_SLOTS do full[index] = {name = "a" .. index, body = ""} end
    local state = fixture({accountMacros = full, saved = {accountMacro = true}})
    equal(state.said("No free account-wide macro slot"), true)
    equal(state.accountMacro(), nil)
end)

test("with no free character slot, DQT says so once", function()
    local full = {}
    for index = 1, CHARACTER_SLOTS do full[index] = {name = "m" .. index, body = ""} end
    local state = fixture({characterMacros = full, noConstants = true})
    equal(state.said("No free character macro slot"), true)
    state.clear()
    state.slash("add Wolf")
    equal(state.said("No free character macro slot"), false)
end)

test("a client without a needed API turns DQT off, and debug still runs", function()
    local state = fixture({missingObjectives = true})
    equal(state.dqt.available, false)
    equal(state.said("This client lacks C_QuestLog.GetQuestObjectives"), true)
    equal(#state.character, 0)
    state.slash("add Wolf")
    equal(state.last(), "DQT: Dyre's Quest Targeting is unavailable. Check the DQT login message.")
    state.slash("debug")
    equal(state.said("debug: available=false"), true)
end)

test("bad commands show the usage; commands are not case sensitive", function()
    local state = fixture()
    state.slash("frobnicate")
    contains(state.last(), "Use /dqt (settings), /dqt list, /dqt add [name]")
    state.slash("on please")
    contains(state.last(), "Use /dqt")
    state.slash("OPTIONS")
    equal(state.opened, state.registered:GetID())
end)

test("/dqt alone opens the settings, out of combat only; /dqt list lists", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    state.slash("")
    equal(state.opened, state.registered:GetID())
    state.opened = nil
    state.combat = true
    state.slash("")
    equal(state.opened, nil, "no panel in combat")
    contains(state.last(), "The settings open out of combat.")
    state.slash("list")
    equal(state.said("The macro looks for, most wanted first:"), true, "the list works in combat")
    state.combat = false
end)

-- The Quest Target box -------------------------------------------------------------------------

local function strip(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The box's shown text rows (the header first), top to bottom.
local function boxRows(state)
    local list = {}
    for _, child in ipairs(state.dqt.box.children) do
        if child.kind == "Button" and child.rate and child.shown then list[#list + 1] = child end
    end
    table.sort(list, function(a, b) return a.points[1][5] > b.points[1][5] end)
    return list
end

-- Each row as text, with " | <rate>" when it has a rate column.
local function boxLines(state)
    local list = {}
    for _, row in ipairs(boxRows(state)) do
        local text = strip(row.label.text)
        if row.rate.shown then text = text .. " | " .. row.rate.text end
        list[#list + 1] = text
    end
    return list
end

local function boxRow(state, fragment)
    for _, row in ipairs(boxRows(state)) do
        if strip(row.label.text):find(fragment, 1, true) then return row end
    end
end

local FOOTER_TEXTURES = {add = "Interface\\Buttons\\UI-PlusButton-Up",
    clear = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"}

-- A footer icon: "add" or "clear".
-- The footer bar: the box's inset panel that holds the icons.
local function footerBar(state)
    for _, child in ipairs(state.dqt.box.children) do
        if child.kind == "Frame" and child.template == "BackdropTemplate" then
            for _, inner in ipairs(child.children) do
                if inner.tip then return child end
            end
        end
    end
end

-- The footer's middle: the hit list's title, which folds it.
local function footerTitle(state)
    for _, child in ipairs(footerBar(state).children) do
        if child.kind == "Button" and child.tip == "Show or hide the hit list." then return child end
    end
end

local function footerCount(state)
    for _, child in ipairs(footerTitle(state).children) do
        if child.kind == "FontString" then return strip(child.text) end
    end
end

local function footerIcon(state, which)
    for _, child in ipairs(footerBar(state).children) do
        if child.kind == "Button" and child.tip and child.icon and child.icon.texture == FOOTER_TEXTURES[which] then
            return child
        end
    end
end

-- Add your target: a click, or a Shift-click for the exact name.
local function addTarget(state, exact)
    state.shift = exact == true
    footerIcon(state, "add"):Click()
    state.shift = false
end

-- The red X on the row that shows a hit list name.
local function removeButton(state, name)
    for _, row in ipairs(boxRows(state)) do
        if row.remove.shown and row.remove.name == name then return row.remove end
    end
end

-- The box's top edge on screen.
local function boxTop(state)
    local _, y = state.absCenter(state.dqt.box)
    return y + state.dqt.box.height * state.dqt.box:GetEffectiveScale() / 2
end

local SILK_RATES = {db = DB, focus = 101, quests = {[101] = {title = "Silk", objectives = {
    objective("Dire Condor slain: 0/8"), objective("Tarantula Silk: 0/6", "item")}}},
    questie = {rates = {[50] = {[20] = 4, [21] = 30.3}}}}

test("box: a toolkit widget, a rounded panel with a thin gold edge and a rounded header inset", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    local box = state.dqt.box
    equal(state.toolkit.Widgets(ADDON)[1], box)
    equal(box.name, "DyresQuestTargetingBox")
    equal(box.backdrop.edgeFile, "Interface\\Tooltips\\UI-Tooltip-Border", "the tooltip's rounded edge")
    equal(box.backdrop.edgeSize, 14, "thin")
    equal(box.backdropColor[1], 0.28, "brown and gold by default")
    equal(box.backdropBorder[2], 0.82, "gold")
    local header = boxRows(state)[1]
    equal(header.template, "BackdropTemplate", "the header is its own panel")
    equal(header.backdrop.edgeFile, "Interface\\Tooltips\\UI-Tooltip-Border", "rounded too")
    equal(header.backdropColor[1] < box.backdropColor[1], true, "a darker inset")
    equal(header.backdropBorder[2], 0.82, "a gold edge")
    for _, child in ipairs(box.children) do
        equal(child.template ~= "UIPanelCloseButtonNoScripts" and child.template ~= "UIPanelCloseButton", true,
            "no close button")
    end
    for _, child in ipairs(header.children) do
        if child.kind == "Button" then
            equal(child == header.fold or child == header.remove, true, "the header's one button: fold")
        end
    end
    equal(box.shown, true)
    equal(box.width, 240)
    equal(box:GetSetting("height"), 235, "Max height")
    equal(box.height < 235, true, "a short list: a shorter box")
end)

test("box: Style re-colors the box at once, also in combat; a bad saved style is repaired", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    local box = state.dqt.box
    local header = boxRows(state)[1]
    local labels, dropdown = {}, nil
    for _, object in ipairs(state.registered.initializers) do
        if object.setting and object.setting.variable == "DQT_BOX_STYLE" then dropdown = object end
    end
    for _, choice in ipairs(dropdown.options()) do
        labels[#labels + 1] = choice.label
    end
    equal(table.concat(labels, ","), "Brown and gold,Black and gold")
    state.combat = true
    state.settings.DQT_BOX_STYLE:SetValue("black")
    equal(state.env.DyresQuestTargetingDB.boxStyle, "black")
    equal(box.backdropColor[1], 0.05, "near black, at once")
    equal(box.backdropColor[4], 0.9)
    equal(box.backdropBorder[2], 0.82, "the same gold edge")
    equal(header.backdropColor[1] > box.backdropColor[1], true, "the header a little lighter, so it reads")
    state.settings.DQT_BOX_STYLE:SetValue("pink")
    equal(state.env.DyresQuestTargetingDB.boxStyle, "black", "an unknown style is refused")
    state.settings.DQT_BOX_STYLE:SetValue("brown")
    equal(box.backdropColor[1], 0.28)
    state.combat = false
    local repaired = fixture({saved = {boxStyle = "pink"}})
    equal(repaired.env.DyresQuestTargetingDB.boxStyle, "brown")
    local black = fixture({quests = CONDOR_QUEST, focus = 101, saved = {boxStyle = "black"}})
    equal(black.dqt.box.backdropColor[1], 0.05, "a saved style applies at login")
end)

test("box: clicks pass through all but the buttons, the header, and the section titles", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101, saved = {added = {{name = "Goretusk"}}}})
    local box = state.dqt.box
    equal(box.mouse, false, "the box itself lets clicks through while locked")
    equal(footerIcon(state, "add").mouse, true, "its footer icons take clicks")
    equal(footerIcon(state, "clear").mouse, true)
    equal(footerIcon(state, "add").template, nil, "plain buttons, nothing secure")
    for _, child in ipairs(box.children) do
        equal(child.template ~= "UIPanelButtonTemplate", true, "no text buttons")
    end
    equal(boxRows(state)[1].mouseClicks, nil, "the header takes clicks (to fold)")
    local title = boxRow(state, "Targets, most wanted first")
    equal(title.mouseClicks, true, "a section title takes clicks")
    local target = boxRow(state, "Dire Condor")
    equal(target.mouseClicks, false, "a target row: clicks pass through to the world")
    equal(target.mouseMotion, true, "the mouse-over shows cut text")
    local hit = boxRow(state, "Goretusk")
    equal(hit.mouseClicks, true, "a hit list row takes clicks, to drag it")
    equal(hit.mouseMotion, true)
    equal(removeButton(state, "Goretusk").mouse, true, "the red X takes clicks")
    state.toolkit.Unlock()
    equal(box.mouse, true, "unlocked: the box drags")
    equal(box.dyre.mover.shown, true, "the toolkit's outline")
    state.toolkit.Lock()
    equal(box.mouse, false)
end)

test("box: the header, then the targets most wanted first, with a rate column", function()
    local state = fixture(SILK_RATES)
    local lines = boxLines(state)
    equal(lines[1], "Silk (Focus)")
    equal(lines[2], "Targets, most wanted first (5)")
    equal(lines[3], "Dire Condor kill objective | -", "the first objective is most wanted; no rate")
    equal(lines[4], "Giant Tarantula drops Tarantula Silk | 30.3%")
    equal(lines[5], "Tarantula drops Tarantula Silk | 4.0%")
    equal(lines[6], "Cave Tarantula drops Tarantula Silk | -", "no rate known: a dash, never cut off")
end)

test("box: a Questie objective focus, a complete quest, and no focus", function()
    local state = fixture({quests = TWO_QUESTS, questie = {}})
    state.questieUtils:FocusObjective(2, 2)
    state.advance()
    local lines = boxLines(state)
    equal(lines[1], "Wolves (Questie)")
    equal(lines[2], "Objective: Bear slain: 0/2")
    equal(lines[4], "Bear kill objective | -")
    local quests = {[101] = {title = "Silk", complete = true, objectives = {objective("Dire Condor slain: 8/8",
        "monster", true)}}}
    local done = fixture({db = DB, focus = 101, quests = quests})
    lines = boxLines(done)
    equal(lines[1], "Silk (Focus) · ready to turn in")
    equal(lines[3], "Guard Parker turn-in | -")
    local none = fixture()
    equal(none.dqt.box.shown, true, "no focused quest: shown, for the hit list")
    lines = boxLines(none)
    equal(lines[1], "No focused quest")
    equal(lines[2], "Focus a quest in the quest log or on the map.", "how to focus one")
end)

test("box: with no focused quest it shows a hint, and the hit list stays usable", function()
    local forever = fixture({quests = TWO_QUESTS, questie = {}})
    equal(boxLines(forever)[2], "Focus a quest in the quest log, on the map, or in Questie's tracker.")
    local classic = fixture({classic = true, quests = TWO_QUESTS, questie = {}})
    equal(classic.dqt.box.shown, true)
    equal(boxLines(classic)[1], "No focused quest")
    equal(boxLines(classic)[2], "Focus a quest in Questie's tracker (right-click a quest).")
    -- The hit list starts folded on John's characters: it can still be reached.
    local state = fixture({classic = true, quests = TWO_QUESTS, questie = {}, realDefaults = true})
    equal(state.env.DyresQuestTargetingDB.startHitListFolded, true)
    equal(state.dqt.box.shown, true)
    state.target = "Goretusk"
    addTarget(state)
    contains(state.macro(), "/tar Goretusk", "the macro targets the hit list with no quest")
    equal(footerCount(state), "Hit list: 1 (hidden)", "folded, but there")
    footerTitle(state):Click()
    equal(type(boxRow(state, "Goretusk")), "table", "opened, it shows the name")
    removeButton(state, "Goretusk"):Click()
    lacks(state.macro(), "Goretusk")
    equal(state.dqt.box.shown, true, "an empty hit list and no quest: still shown")
    -- A focus that comes later fills the quest's part and drops the hint.
    state.questieUtils:FocusQuest(2)
    state.advance()
    local lines = boxLines(state)
    equal(lines[1], "Wolves (Questie)")
    equal(lines[2], "Targets, most wanted first (2)", "the hint is gone")
    -- DQT off: only while frames are unlocked, as before.
    state.slash("off")
    equal(state.dqt.box.shown, false)
end)

test("box: names left out of the macro are listed apart", function()
    local list = {}
    for index = 1, 12 do
        list[index] = objective("Very Long Named Creature Number " .. index .. " slain: 0/1")
    end
    local state = fixture({focus = 5, quests = {[5] = {title = "Many", objectives = list}},
        saved = {box = {height = 600}}})
    local lines = boxLines(state)
    local heading
    for index, line in ipairs(lines) do
        if line:find("^Not in the macro") then heading = index end
    end
    contains(lines[heading], "Not in the macro (255-letter limit) (")
    contains(lines[heading + 1], "Very Long Named Creature Number ")
    contains(lines[#lines], "Number 12 · kill objective | -", "the least important is left out first")
end)

test("box: the hit list, newest first, with its kind, and the X, Clear, and Add buttons", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    state.target = "Goretusk"
    addTarget(state)
    state.target = "Defias Bandit"
    addTarget(state, true)
    contains(state.last(), "Added Defias Bandit to your hit list (exact name).")
    local lines = boxLines(state)
    equal(lines[#lines - 1], "Defias Bandit exact", "no title row: the footer is the hit list's title")
    equal(lines[#lines], "Goretusk similar")
    equal(footerCount(state), "Hit list: 2")
    contains(state.macro(), "/targetexact Defias Bandit")
    removeButton(state, "Goretusk"):Click()
    equal(state.last(), "DQT: Removed Goretusk from your hit list.")
    equal(removeButton(state, "Goretusk"), nil)
    lacks(state.macro(), "Goretusk")
    equal(footerIcon(state, "clear").enabled, true)
    equal(footerIcon(state, "clear").icon.desaturated, false)
    footerIcon(state, "clear"):Click()
    equal(state.last(), "DQT: Cleared your hit list (1 name).")
    equal(#state.env.DyresQuestTargetingDB.added, 0)
    equal(footerIcon(state, "clear").enabled, false, "nothing to clear")
    equal(footerIcon(state, "clear").icon.desaturated, true, "greyed out")
    state.target = nil
    addTarget(state)
    equal(state.dqt.box.input.shown, true, "no target: the name input opens instead")
    state.dqt.box.input.edit.scripts.OnEscapePressed(state.dqt.box.input.edit)
    state.target = secret()
    state.secrets[state.target] = true
    addTarget(state, true)
    contains(state.last(), "cannot be read right now")
    equal(#state.env.DyresQuestTargetingDB.added, 0, "a secret name is never kept")
end)

test("box: the plus with no target opens a name input under the box", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    local input = state.dqt.box.input
    equal(input.shown, false, "closed at first")
    equal(input.points[1][2], state.dqt.box, "anchored to the box, not the middle of the screen")
    equal(input.edit.template, "InputBoxTemplate", "a one-line edit box")
    -- No target: it opens with the edit box focused; Enter adds the trimmed name.
    addTarget(state)
    equal(input.shown, true)
    equal(input.edit.focused, true, "typing goes straight into it")
    equal(strip(input.prompt.text), "Mob name to add")
    input.edit:SetText("  Defias Bandit  ")
    input.edit.scripts.OnEnterPressed(input.edit)
    equal(input.shown, false, "closed after adding")
    equal(state.env.DyresQuestTargetingDB.added[1].name, "Defias Bandit", "trimmed")
    equal(state.env.DyresQuestTargetingDB.added[1].exact, false, "a click: similar names, as /dqt add")
    contains(state.macro(), "/tar Defias Bandit")
    equal(state.last(), "DQT: Added Defias Bandit to your hit list (any name containing it).")
    -- Shift-click: the exact name; the Add button works as Enter.
    addTarget(state, true)
    equal(strip(input.prompt.text), "Mob name to add (exact name)")
    input.edit:SetText("Goretusk")
    input.add:Click()
    equal(state.env.DyresQuestTargetingDB.added[2].exact, true, "Shift-click: the exact name, as /dqt add_exact")
    -- Escape, Cancel, and an empty name close it without adding.
    addTarget(state)
    input.edit:SetText("Kobold")
    input.edit.scripts.OnEscapePressed(input.edit)
    equal(input.shown, false)
    addTarget(state)
    input.edit:SetText("Kobold")
    input.cancel:Click()
    addTarget(state)
    input.edit:SetText("   ")
    input.edit.scripts.OnEnterPressed(input.edit)
    equal(input.shown, false)
    equal(#state.env.DyresQuestTargetingDB.added, 2, "nothing added by Escape, Cancel, or an empty name")
    -- A name already there moves to the top; a bad name gets the usual message.
    addTarget(state)
    input.edit:SetText("defias bandit")
    input.edit.scripts.OnEnterPressed(input.edit)
    equal(#state.env.DyresQuestTargetingDB.added, 2, "no duplicate")
    addTarget(state)
    input.edit:SetText("Wolf; Boar")
    input.edit.scripts.OnEnterPressed(input.edit)
    equal(state.last(), "DQT: A name cannot contain \";\" or a line break.")
    -- With a target, the plus adds the target as before; no input.
    state.target = "Goretusk"
    addTarget(state)
    equal(input.shown, false)
end)

test("box: the name input respects the 20-name limit, never opens in combat, and combat closes it", function()
    local saved = {added = {}}
    for index = 1, 20 do
        saved.added[index] = {name = "Mob " .. index, exact = false}
    end
    local state = fixture({quests = CONDOR_QUEST, focus = 101, saved = saved})
    local input = state.dqt.box.input
    addTarget(state)
    input.edit:SetText("Newcomer")
    input.edit.scripts.OnEnterPressed(input.edit)
    equal(#state.env.DyresQuestTargetingDB.added, 20)
    contains(state.last(), "Removed the oldest, Mob 1.", "the limit's usual message")
    -- In combat: no input; the chat line as before.
    state.combat = true
    addTarget(state)
    equal(input.shown, false, "no popups in combat")
    equal(state.last(), "DQT: Target a mob or type a name.")
    state.combat = false
    -- Combat starting while it is open closes it.
    addTarget(state)
    equal(input.shown, true)
    state.combat = true
    state.emit("PLAYER_REGEN_DISABLED")
    equal(input.shown, false, "closed when combat starts")
    equal(input.edit.focused, false)
end)

test("box: in combat the buttons change the hit list at once, and the macro waits", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    state.combat = true
    state.target = "Goretusk"
    addTarget(state)
    equal(state.last(), "DQT: Added Goretusk to your hit list (any name containing it). The macro updates "
        .. "after combat.")
    local lines = boxLines(state)
    equal(lines[#lines], "Goretusk similar", "the box shows it at once")
    lacks(state.macro(), "Goretusk", "the macro waits")
    removeButton(state, "Goretusk"):Click()
    contains(state.last(), "The macro updates after combat.")
    state.combat = false
    state.emit("PLAYER_REGEN_ENABLED")
    state.advance()
    lacks(state.macro(), "Goretusk")
end)

test("box: box size and text size are independent; a long list is cut with \"+N more\"", function()
    local saved = {added = {}}
    for index = 1, 10 do
        saved.added[index] = {name = "Mob " .. index, exact = false}
    end
    local state = fixture({quests = TWO_QUESTS, focus = 2, saved = saved})
    local box = state.dqt.box
    local lines = boxLines(state)
    equal(lines[1], "Wolves (Focus)")
    equal(lines[2], "Targets, most wanted first (2)")
    equal(lines[5], "Mob 10 similar", "rows are shared: both targets, then the hit list, newest first")
    contains(lines[#lines], " more: /dqt list shows all")
    equal(box.height <= 235 and box.height > 235 - 15, true, "a long list: the last whole row under Max height")
    local rowsAtDefault = #lines
    box:SetSetting("textSize", 150)
    equal(box.height <= 235 and box.height > 235 - 21, true, "bigger text: still up to Max height")
    equal(box.width, 240)
    equal(boxRows(state)[2].label.font[2], 18, "150% of 12")
    equal(#boxLines(state) < rowsAtDefault, true, "bigger text: fewer rows")
    box:SetSetting("textSize", 100)
    box:SetSetting("height", 400)
    equal(boxRows(state)[2].label.font[2], 12, "a bigger box does not resize the text")
    equal(#boxLines(state) > rowsAtDefault, true, "a bigger box: more rows")
    equal(box.height <= 400, true)
    box:SetSetting("opacity", 50)
    box:ResetSize()
    equal(box:GetSetting("height"), 235)
    equal(box:GetSetting("textSize"), 100)
    equal(box:GetSetting("opacity"), 50, "Reset size keeps opacity")
end)

-- The empty strip: the backdrop frame without an edge.
local function boxStrip(state)
    for _, child in ipairs(state.dqt.box.children) do
        if child.kind == "Frame" and child.backdrop and child.backdrop.bgFile and not child.backdrop.edgeFile then
            return child
        end
    end
end

-- A frame's top, as an offset from the box's top.
local function topOffset(frame)
    return -frame.points[1][5]
end

test("box: the hit list bar sits over its names; it grows and shrinks; the empty strip", function()
    local state = fixture({quests = TWO_QUESTS, focus = 2})
    local box = state.dqt.box
    local top, height = boxTop(state), box.height
    local bar, stripFrame = footerBar(state), boxStrip(state)
    equal(stripFrame.shown, true, "open: the strip shows")
    equal(stripFrame.height, 11, "half a bar")
    equal(stripFrame.backdropColor[1], bar.backdropColor[1], "the bars' fill, no edge, no text")
    -- No hit list names: the quest rows, the bar, then the strip in its section.
    equal(topOffset(stripFrame) > topOffset(bar), true, "no names: the strip under the bar, in its section")
    equal(height, 5 + 21 + 3 + 3 * 15 + 3 * 2 + 11 + 21 + 5, "its content's height")
    state.target = "Goretusk"
    addTarget(state)
    -- With names: the quest rows, the bar (the hit list's title), its names, the strip.
    local name = boxRow(state, "Goretusk")
    local lastTarget = boxRow(state, "Bear")
    equal(topOffset(bar) > lastTarget.offset, true, "the bar under the targets")
    equal(name.offset > topOffset(bar), true, "the name under its bar")
    equal(topOffset(stripFrame) > name.offset, true, "the strip under the names")
    equal(box.height, height + 15 + 3, "one more row (and its gap): it grows")
    equal(math.abs(boxTop(state) - top) < 0.01, true, "the top edge stays")
    footerTitle(state):Click()
    equal(boxRow(state, "Goretusk"), nil, "hidden")
    equal(stripFrame.shown, false, "hidden: no strip")
    equal(box.height, height - 11 - 3, "the bar right under the targets")
    footerTitle(state):Click()
    removeButton(state, "Goretusk"):Click()
    equal(box.height, height, "it shrinks again")
    boxRows(state)[1].fold:Click()
    equal(stripFrame.shown, false, "all folded: no strip")
end)

test("box: a row whose text is cut shows the whole text on mouse-over", function()
    local state = fixture(SILK_RATES)
    state.env.GameTooltip = {}
    local tip = state.env.GameTooltip
    function tip:SetOwner(owner) self.owner = owner end
    function tip:GetOwner() return self.owner end
    function tip:SetText(text) self.text = text end
    function tip:Show() self.shown = true end
    function tip:Hide() self.shown = false end
    local row = boxRow(state, "Giant Tarantula")
    row.scripts.OnEnter(row)
    equal(tip.shown, nil, "not cut: no tooltip")
    row.label.truncated = true
    row.scripts.OnEnter(row)
    equal(tip.shown, true)
    equal(tip.text, "Giant Tarantula · drops Tarantula Silk, 30.3% drop rate")
    row.scripts.OnLeave(row)
    equal(tip.shown, false)
    local unknown = boxRow(state, "Cave Tarantula")
    unknown.label.truncated = true
    unknown.scripts.OnEnter(unknown)
    equal(tip.text, "Cave Tarantula · drops Tarantula Silk, drop rate unknown", "words, not the column's \"-\"")
    equal(unknown.rate.text, "-", "the column keeps the dash")
    local kill = boxRow(state, "Dire Condor")
    kill.label.truncated = true
    kill.scripts.OnEnter(kill)
    equal(tip.text, "Dire Condor · kill objective", "a kill has no drop rate")
    function tip:AddLine(text) self.lines = self.lines or {} self.lines[#self.lines + 1] = text end
    local header = boxRows(state)[1]
    header.scripts.OnEnter(header)
    equal(tip.text, "Dyre's Quest Targeting", "the header's tooltip names the AddOn, cut or not")
    equal(tip.lines[1], "Silk (Focus)", "then the whole header line")
    header.scripts.OnLeave(header)
    equal(tip.shown, false)
end)

test("box: each title folds its part, keeping the top edge; the folds are saved", function()
    local state = fixture({quests = TWO_QUESTS, questie = {}, saved = {added = {{name = "Goretusk"}}}})
    state.questieUtils:FocusObjective(2, 2)
    state.advance()
    local box = state.dqt.box
    local folded = state.env.DyresQuestTargetingDB.box.foldedSections
    local top, height = boxTop(state), box.height
    -- The quest's name (the header) folds the quest's part; the hit list stays.
    boxRows(state)[1]:Click()
    equal(folded.quest, true, "saved")
    equal(boxRow(state, "Targets, most wanted first"), nil, "the quest's rows hide")
    equal(boxRow(state, "Objective: Bear slain: 0/2") ~= nil, true, "the objective line stays")
    equal(type(boxRow(state, "Goretusk")), "table", "the hit list stays open")
    equal(box.height < height, true, "it shrinks")
    equal(math.abs(boxTop(state) - top) < 0.01, true, "the top edge stays")
    boxRows(state)[1]:Click()
    equal(folded.quest, nil)
    equal(box.height, height, "open again: its content's height")
    equal(math.abs(boxTop(state) - top) < 0.01, true, "the top edge stays")
    -- A section title folds that section.
    boxRow(state, "Targets, most wanted first"):Click()
    equal(folded.targets, true, "saved")
    equal(box.height < height, true, "a folded section shrinks the box")
    equal(boxRow(state, "Bear kill objective"), nil, "its rows are hidden")
    contains(strip(boxRow(state, "Targets, most wanted first").label.text), "(1)", "the title keeps its count")
    -- "Hit list" in the bar folds the hit list.
    footerTitle(state):Click()
    equal(folded.added, true)
    equal(boxRow(state, "Goretusk"), nil, "the bar's title folds the hit list")
    equal(footerCount(state), "Hit list: 1 (hidden)")
    boxRow(state, "Targets, most wanted first"):Click()
    equal(type(boxRow(state, "Bear kill objective")), "table")
    local again = fixture({quests = TWO_QUESTS, focus = 2,
        saved = {added = {{name = "Goretusk"}}, box = {foldedSections = {targets = true}}}})
    equal(boxRow(again, "Bear kill objective"), nil, "section folds are saved")
end)

test("box: a fold button at the header's right folds and opens, keeping the top edge", function()
    local state = fixture({quests = TWO_QUESTS, focus = 2})
    local header = boxRows(state)[1]
    local fold = header.fold
    equal(fold.kind, "Button")
    equal(fold.mouse, true, "it takes clicks")
    equal(fold.points[1][1], "RIGHT")
    equal(fold.points[1][3], "RIGHT", "at the header's right end")
    equal(fold.width, 17, "the same size as the footer icons")
    local right = header.label.points[#header.label.points]
    equal(right[1], "RIGHT")
    equal(right[2], fold, "the header text stops before the button")
    equal(fold.normalTexture, "Interface\\Buttons\\UI-MinusButton-Up", "open: minus")
    local top, height = boxTop(state), state.dqt.box.height
    local folded = state.env.DyresQuestTargetingDB.box.foldedSections
    folded.targets = true
    fold:Click()
    equal(folded.quest and folded.added, true, "the button folds all")
    equal(#boxLines(state), 1, "the header only")
    equal(state.dqt.box.height < height, true)
    equal(math.abs(boxTop(state) - top) < 0.01, true, "the top edge stays")
    equal(fold.normalTexture, "Interface\\Buttons\\UI-PlusButton-Up", "all folded: plus")
    fold:Click()
    equal(next(folded), nil, "and opens all, the sections too")
    equal(fold.normalTexture, "Interface\\Buttons\\UI-MinusButton-Up")
    equal(state.dqt.box.height, height)
    equal(math.abs(boxTop(state) - top) < 0.01, true)
    -- With only the quest's part folded, the button folds the rest.
    boxRows(state)[1]:Click()
    equal(fold.normalTexture, "Interface\\Buttons\\UI-MinusButton-Up", "the hit list still open: minus")
end)

test("box: two footer icons, bottom right, with tooltips; they drag the box and click safely", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    local add, clear = footerIcon(state, "add"), footerIcon(state, "clear")
    equal(add.width, 17, "1.4 text sizes: the mark just under the title's letters")
    equal(clear.points[1][1], "RIGHT", "clear at the footer bar's right end")
    equal(clear.points[1][2], footerBar(state))
    equal(clear.points[1][4], -7, "inset as the fold button")
    equal(add.points[1][1], "LEFT", "add at the left end")
    equal(add.points[1][2], footerBar(state))
    equal(add.points[1][4], 7)
    state.env.GameTooltip = {}
    local tip = state.env.GameTooltip
    function tip:SetOwner(owner) self.owner = owner end
    function tip:GetOwner() return self.owner end
    function tip:SetText(text) self.text = text end
    function tip:Show() self.shown = true end
    function tip:Hide() self.shown = false end
    add.scripts.OnEnter(add)
    equal(tip.text, "Add your target to the hit list. Shift-click to match the exact name. With no target, type a "
        .. "name.")
    add.scripts.OnLeave(add)
    equal(tip.shown, false)
    clear.scripts.OnEnter(clear)
    equal(tip.text, "Clear the hit list.")
    -- Ctrl-drag on an icon moves the box, and does not also add.
    state.target = "Goretusk"
    state.env.IsControlKeyDown = function() return true end
    add.scripts.OnMouseDown(add)
    add.scripts.OnDragStart(add)
    equal(state.dqt.box.moving, true, "a drag handle")
    add.scripts.OnDragStop(add)
    add.scripts.OnClick(add, "LeftButton")
    equal(#state.env.DyresQuestTargetingDB.added, 0, "a drag is not a click")
    state.env.IsControlKeyDown = function() return false end
    add.scripts.OnMouseDown(add)
    add:Click()
    equal(state.env.DyresQuestTargetingDB.added[1].name, "Goretusk")
    equal(state.env.DyresQuestTargetingDB.added[1].exact, false, "a click: similar names")
    state.shift = true
    add.scripts.OnMouseDown(add)
    add:Click()
    state.shift = false
    equal(state.env.DyresQuestTargetingDB.added[1].exact, true, "Shift-click: the exact name")
end)

test("box: a footer bar like the header, click-through, with the count; icons follow Text size", function()
    local state = fixture({quests = TWO_QUESTS, questie = {}, saved = {added = {{name = "Goretusk"},
        {name = "Boar"}}}})
    state.questieUtils:FocusObjective(2, 2)
    state.advance()
    local box, bar = state.dqt.box, footerBar(state)
    local header = boxRows(state)[1]
    equal(bar.backdrop.edgeFile, "Interface\\Tooltips\\UI-Tooltip-Border", "the header's rounded inset")
    equal(bar.backdrop.edgeSize, header.backdrop.edgeSize)
    equal(bar.backdropColor[1], header.backdropColor[1], "the same dark fill")
    equal(bar.backdropBorder[4], header.backdropBorder[4], "the same softer gold edge")
    equal(bar.height, header.height, "as tall as the header bar")
    equal(bar.points[1][1], "TOPLEFT", "placed from the top, as the content grows")
    local title = footerTitle(state)
    equal(title.points[1][1], "TOPLEFT", "the hit list's title: the whole bar")
    equal(title.points[1][2], bar)
    equal(title.points[2][1], "BOTTOMRIGHT")
    equal(footerIcon(state, "add").level > title:GetFrameLevel(), true, "the icons above it, so they keep their clicks")
    equal(footerIcon(state, "clear").level > title:GetFrameLevel(), true)
    equal(footerCount(state), "Hit list: 2")
    for _, child in ipairs(bar.children) do
        if child.kind == "FontString" then equal(child.points[1][1], "CENTER", "the count in the middle") end
    end
    state.settings.DQT_BOX_STYLE:SetValue("black")
    equal(bar.backdropColor[1], header.backdropColor[1], "the style colors both bars")
    -- All folded: header, objective, bar, top to bottom, evenly spaced, at each text size.
    header.fold:Click()
    for _, percent in ipairs({80, 100, 150}) do
        box:SetSetting("textSize", percent)
        local size = 12 * percent / 100
        local line = math.floor(size + 3 + 0.5)
        local barHeight = line + 6
        local icon = math.floor(size * 1.4 + 0.5)
        equal(footerIcon(state, "add").width, icon, percent .. "%: the icon follows Text size")
        equal(header.fold.width, icon, percent .. "%: the fold button too")
        equal(icon < barHeight, true, percent .. "%: the icons fit their bar")
        equal(box.height, 5 * 2 + barHeight * 2 + line + 3 * 2, percent .. "%: a compact card")
        local objective = boxRow(state, "Objective:")
        equal(objective.points[1][5], -(5 + barHeight + 3), percent .. "%: one gap under the header")
    end
end)

-- The cursor over the box, at an offset from its top (in the box's units).
local function cursorAt(state, offset)
    local box = state.dqt.box
    local scale = box:GetEffectiveScale()
    local x = box:GetCenter()
    state.cursorX, state.cursorY = x * scale, (box:GetTop() - offset) * scale
end

-- Drags a hit list row and drops it at an offset from the box's top.
local function dragRow(state, name, offset)
    local row = boxRow(state, name)
    row.scripts.OnDragStart(row)
    equal(row.alpha, 0.5, "the dragged row dims")
    equal(type(row.scripts.OnUpdate), "function", "the insertion line follows the cursor while dragging")
    cursorAt(state, offset)
    row.scripts.OnUpdate(row)
    local line
    for _, child in ipairs(state.dqt.box.children) do
        if child.kind == "Texture" and child.height == 2 then line = child end
    end
    local shown = line.shown
    row.scripts.OnDragStop(row)
    equal(line.shown, false, "the insertion line hides on the drop")
    equal(row.scripts.OnUpdate, nil, "no OnUpdate after the drag")
    equal(row.alpha, 1)
    return shown
end

local function hitNames(state)
    local list = {}
    for index = #state.env.DyresQuestTargetingDB.added, 1, -1 do
        list[#list + 1] = state.env.DyresQuestTargetingDB.added[index].name
    end
    return table.concat(list, ",")
end

test("box: drag a hit list row to reorder it; the macro follows the new priority", function()
    -- Saved newest last: the box shows Wolfie, Boar, Goretusk (most wanted first).
    local saved = {added = {{name = "Goretusk"}, {name = "Boar"}, {name = "Wolfie"}}}
    local state = fixture({quests = CONDOR_QUEST, focus = 101, saved = saved})
    equal(hitNames(state), "Wolfie,Boar,Goretusk")
    local first = boxRow(state, "Wolfie")
    -- Goretusk (3rd) to the top: dropped above the first row's middle.
    equal(dragRow(state, "Goretusk", first.offset + 1), true, "a gold insertion line while over the list")
    equal(hitNames(state), "Goretusk,Wolfie,Boar", "db.added: newest (most wanted) last")
    local macro = state.macro()
    equal(macro:find("/tar Goretusk", 1, true) > macro:find("/tar Boar", 1, true), true,
        "the macro: the most wanted line last, so it wins")
    equal(boxLines(state)[#boxLines(state) - 2], "Goretusk similar")
    -- Wolfie (2nd) to the bottom: below the last row.
    local last = boxRow(state, "Boar")
    dragRow(state, "Wolfie", last.offset + last.height * 1.2)
    equal(hitNames(state), "Goretusk,Boar,Wolfie")
    -- The drop area: the whole box. Above the first name (the bar, the
    -- targets, the header too) is the top; below the last name the bottom.
    local box = state.dqt.box
    local bottom = box.height - 5
    local barTop = topOffset(footerBar(state))
    dragRow(state, "Goretusk", bottom - 1)
    equal(hitNames(state), "Boar,Wolfie,Goretusk", "over the strip, just above the border: the bottom")
    dragRow(state, "Goretusk", barTop + footerBar(state).height + 1)
    equal(hitNames(state), "Goretusk,Boar,Wolfie", "just under the bar: the top")
    dragRow(state, "Wolfie", barTop + 3)
    equal(hitNames(state), "Wolfie,Goretusk,Boar", "on the hit list bar: the top")
    dragRow(state, "Boar", boxRow(state, "Dire Condor").offset + 2)
    equal(hitNames(state), "Boar,Wolfie,Goretusk", "over a target row: the top")
    equal(dragRow(state, "Goretusk", 2), true, "over the header: the insertion line stays at the top")
    equal(hitNames(state), "Goretusk,Boar,Wolfie", "on the header: the top")
    dragRow(state, "Wolfie", box.height - 1)
    equal(hitNames(state), "Goretusk,Boar,Wolfie", "on the bottom border: the bottom")
    equal(dragRow(state, "Boar", -3), false, "above the box: no line")
    equal(hitNames(state), "Goretusk,Boar,Wolfie", "above the box: cancelled")
    -- A drop next to itself changes nothing; a drop off the hit list cancels.
    dragRow(state, "Boar", boxRow(state, "Boar").offset + 2)
    equal(hitNames(state), "Goretusk,Boar,Wolfie")
    local row = boxRow(state, "Boar")
    row.scripts.OnDragStart(row)
    state.cursorX = -1000
    row.scripts.OnDragStop(row)
    equal(hitNames(state), "Goretusk,Boar,Wolfie", "a drop outside the box cancels")
    -- The X still removes; a target row does not reorder.
    removeButton(state, "Boar"):Click()
    equal(hitNames(state), "Goretusk,Wolfie")
    local target = boxRow(state, "Dire Condor")
    target.scripts.OnDragStart(target)
    equal(target.scripts.OnUpdate, nil, "a target row is not dragged")
end)

test("box: a reorder in combat changes the list at once; the macro waits", function()
    local saved = {added = {{name = "Goretusk"}, {name = "Boar"}}}
    local state = fixture({quests = CONDOR_QUEST, focus = 101, saved = saved})
    local before = state.macro()
    state.combat = true
    dragRow(state, "Goretusk", boxRow(state, "Boar").offset + 1)
    equal(hitNames(state), "Goretusk,Boar")
    equal(state.last(), "DQT: Moved Goretusk in your hit list. The macro updates after combat.")
    equal(state.macro(), before, "the macro waits")
    state.combat = false
    state.emit("PLAYER_REGEN_ENABLED")
    state.advance()
    local macro = state.macro()
    equal(macro:find("/tar Goretusk", 1, true) > macro:find("/tar Boar", 1, true), true)
end)

test("box: Ctrl-drag on the header moves the box while locked; a plain click folds", function()
    local state = fixture({quests = TWO_QUESTS, focus = 2})
    local box, header = state.dqt.box, boxRows(state)[1]
    equal(state.toolkit.IsLocked(), true)
    -- A press, a drag without Ctrl: nothing moves, nothing folds.
    header.scripts.OnMouseDown(header)
    header.scripts.OnDragStart(header)
    equal(box.moving, nil, "locked, no Ctrl: no move")
    -- A press, a drag with Ctrl, a drop somewhere else.
    state.env.IsControlKeyDown = function() return true end
    header.scripts.OnMouseDown(header)
    header.scripts.OnDragStart(header)
    equal(box.moving, true, "locked with Ctrl: it moves")
    box:ClearAllPoints()
    box:SetPoint("CENTER", state.env.UIParent, "BOTTOMLEFT", 300, 300)
    header.scripts.OnDragStop(header)
    header.scripts.OnClick(header)
    equal(state.env.DyresQuestTargetingDB.box.foldedSections.quest, nil, "a drag does not also fold")
    local saved = state.env.DyresQuestTargetingDB.box.position
    equal(math.abs(saved.x - 300) < 1 and math.abs(saved.y - 300) < 1, true, "the free drop is saved")
    state.env.IsControlKeyDown = function() return false end
    header.scripts.OnMouseDown(header)
    header:Click()
    equal(state.env.DyresQuestTargetingDB.box.foldedSections.quest, true, "a plain click folds the quest's part")
end)

test("box: two settings fold the quest's part and the hit list at login", function()
    local defaults = fixture({quests = TWO_QUESTS, focus = 2, realDefaults = true,
        saved = {added = {{name = "Goretusk"}}}})
    local db = defaults.env.DyresQuestTargetingDB
    equal(db.startQuestFolded, false, "the quest's part opens by default")
    equal(db.startHitListFolded, true, "the hit list starts folded by default")
    equal(type(boxRow(defaults, "Targets, most wanted first")), "table")
    equal(boxRow(defaults, "Goretusk"), nil)
    equal(footerCount(defaults), "Hit list: 1 (hidden)")
    equal(defaults.settings.DQT_START_QUEST_FOLDED.default, false)
    equal(defaults.settings.DQT_START_HIT_LIST_FOLDED.default, true)
    local saved = {startQuestFolded = true, startHitListFolded = true, added = {{name = "Goretusk"}},
        box = {foldedSections = {targets = true}}}
    local state = fixture({quests = TWO_QUESTS, focus = 2, saved = saved})
    local folded = state.env.DyresQuestTargetingDB.box.foldedSections
    equal(folded.quest and folded.added, true, "both on: all folded at login")
    equal(#boxLines(state), 1, "the header only")
    local open = fixture({quests = TWO_QUESTS, focus = 2, saved = {startQuestFolded = false,
        startHitListFolded = false, added = {{name = "Goretusk"}},
        box = {foldedSections = {quest = true, added = true, targets = true}}}})
    local openFolds = open.env.DyresQuestTargetingDB.box.foldedSections
    equal(openFolds.quest or openFolds.added, nil, "both off: both open, whatever was saved")
    equal(openFolds.targets, true, "the targets keep their saved fold")
    equal(type(boxRow(open, "Goretusk")), "table")
    local old = fixture({saved = {startFolded = true}, realDefaults = true})
    equal(old.env.DyresQuestTargetingDB.startQuestFolded, true, "a test build's \"Start folded\" becomes the quest's")
    equal(old.env.DyresQuestTargetingDB.startFolded, nil)
end)

test("box: its settings, the show switch, and the off state", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    local list = state.registered.initializers
    local heading
    for index, object in ipairs(list) do
        if object.header == "Quest Target Box" then heading = index end
    end
    equal(list[heading + 1].setting.variable, "DQT_SHOW_BOX", "the show switch first")
    equal(list[heading + 1].setting.name, "Show the Quest Target Box")
    equal(list[heading + 2].setting.variable, "DQT_START_QUEST_FOLDED", "then the two fold switches")
    equal(list[heading + 3].setting.variable, "DQT_START_HIT_LIST_FOLDED")
    equal(list[heading + 4].setting.variable, "DQT_BOX_STYLE", "then the style")
    for _, name in ipairs({"WIDTH", "HEIGHT", "TEXTSIZE", "OPACITY"}) do
        equal(type(state.settings["DYRE_DYRESQUESTTARGETING_BOX_" .. name]), "table", name)
    end
    equal(state.settings.DYRE_DYRESQUESTTARGETING_BOX_TEXTSIZE.name, "Text size", "no \"(%)\": the value shows it")
    equal(state.settings.DYRE_DYRESQUESTTARGETING_BOX_SCALE, nil, "no Size: it scaled the text too")
    equal(state.settings.DYRE_DYRESQUESTTARGETING_BOX_LINES, nil, "rows follow the height and text size")
    equal(list[#list].button, "Reset size")
    state.settings.DYRE_DYRESQUESTTARGETING_BOX_OPACITY:SetValue(50)
    equal(state.dqt.box.alpha, 0.5, "opacity fades the whole box")
    list[#list].onClick()
    equal(state.dqt.box:GetSetting("opacity"), 50, "Reset size keeps opacity")
    state.settings.DQT_SHOW_BOX:SetValue(false)
    equal(state.dqt.box.shown, false)
    state.toolkit.Unlock()
    equal(state.dqt.box.shown, false, "off: hidden, also unlocked")
    state.toolkit.Lock()
    state.settings.DQT_SHOW_BOX:SetValue(true)
    equal(state.dqt.box.shown, true)
    state.slash("off")
    equal(state.dqt.box.shown, false, "DQT off: hidden")
    state.toolkit.Unlock()
    contains(boxLines(state)[1], "Macro off: /dqt on turns it back on")
end)

test("box: /dqt unlock and lock ask the toolkit, /dqt reset_box puts the box back, on and off stay", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    local box = state.dqt.box
    state.clear()
    state.slash("unlock")
    equal(state.toolkit.IsLocked(), false)
    equal(#state.messages, 1, "one line, the toolkit's")
    contains(state.messages[1], "Dyre: ")
    equal(box.dyre.mover.shown, true, "the box's outline follows")
    state.clear()
    state.slash("LOCK")
    equal(state.toolkit.IsLocked(), true)
    equal(#state.messages, 1)
    contains(state.messages[1], "Dyre: ")
    equal(box.dyre.mover.shown, false)
    box.dyre.store.position = {point = "CENTER", relativePoint = "BOTTOMLEFT", x = 100, y = 100}
    state.slash("reset_box")
    equal(box.dyre.store.position, nil, "the saved place is gone")
    equal(box.points[1][1], "TOPRIGHT", "back in its first place")
    equal(state.last(), "DQT: The Quest Target box is back in its first place.")
    state.slash("off")
    equal(state.env.DyresQuestTargetingDB.enabled, false, "/dqt off is still the macro switch")
    equal(state.toolkit.IsLocked(), true)
    state.slash("on")
    equal(state.env.DyresQuestTargetingDB.enabled, true)
    local old = fixture({oldToolkit = true})
    old.slash("unlock")
    contains(old.last(), "needs Dyre's Toolkit 2.0 or later")
end)

local TOOLKIT_HINT = "The Quest Target box needs Dyre's Toolkit 2.0 or later"

test("toolkit: the TOC lists it as optional and nests under it; Box.lua loads before Options.lua", function()
    local state = fixture()
    equal(state.toc.Dependencies, nil, "no Dependencies line: DQT loads without it and says what to install")
    contains(state.toc.OptionalDeps, "DyresToolkit")
    contains(state.toc.OptionalDeps, "QuestieDB")
    equal(state.toc.Group, "DyresToolkit")
    local text = assert(io.open(ADDON .. ".toc")):read("*a")
    contains(text, "Macro.lua\nBox.lua\nOptions.lua")
end)

test("toolkit: the settings page sits under Dyre's AddOns and DQT joins its menu", function()
    local state = fixture()
    equal(state.registered.name, "Quest Targeting", "the toolkit says \"Dyre's \" once, in its heading")
    equal(state.registered.parent, state.home)
    equal(state.home.name, "Dyre's AddOns")
    local heading
    for index, object in ipairs(state.registered.initializers) do
        if object.header == "Integrations (Experimental)" then heading = index end
    end
    equal(type(heading), "number", "the Integrations heading is on the toolkit's page")
    local member
    for _, info in ipairs(state.toolkit.AddOns()) do
        if info.addon == ADDON then member = info end
    end
    equal(member.title, "Dyre's Quest Targeting")
    member.openSettings()
    equal(state.opened, state.registered:GetID())
    state.opened = nil
    state.slash("")
    equal(state.opened, state.registered:GetID(), "/dqt opens DQT's own page")
    equal(state.said(TOOLKIT_HINT), false, "no hint with the toolkit")
end)

test("toolkit: without Dyre's Toolkit 2, the macro works, with its own page, no box, and one hint", function()
    for _, options in ipairs({{noToolkit = true}, {oldToolkit = true}}) do
        options.quests, options.focus = CONDOR_QUEST, 101
        local state = fixture(options)
        equal(state.registered.name, PAGE)
        equal(state.registered.parent, nil, "a top-level page")
        equal(state.dqt.box, nil, "no box")
        contains(state.macro(), "/targetexact Dire Condor")
        local count = 0
        for _, message in ipairs(state.messages) do
            if message:find(TOOLKIT_HINT, 1, true) then count = count + 1 end
        end
        equal(count, 1)
        contains(state.messages[3], "install or update it from CurseForge")
        state.clear()
        state.emit("PLAYER_ENTERING_WORLD")
        state.advance()
        equal(state.said(TOOLKIT_HINT), false, "said at login only")
    end
end)

test("toolkit: the loaded toolkit offers contract 2 and every function DQT calls", function()
    local state = fixture()
    local toolkit = state.toolkit.RequireContract(2)
    equal(type(toolkit), "table", "contract 2")
    for _, name in ipairs({"RegisterAddOn", "RegisterSettingsCategory", "CreateWidget", "AddWidgetSettings",
            "ResetWidgets", "Widgets", "Unlock", "Lock", "IsLocked", "AddOns"}) do
        equal(type(toolkit[name]), "function", name)
    end
    equal(type(state.dqt.box.SetContentSize), "function", "widgets have SetContentSize")
    equal(type(state.dqt.box.AddDragHandle), "function", "and AddDragHandle")
end)

test("a clash on /dqt is reported, with the backup command", function()
    local globals = {SLASH_OTHER1 = "/dqt"}
    local state = fixture({slashCmdList = {OTHER = function() end}, globals = globals})
    equal(state.said("Another AddOn (OTHER) also uses /dqt. Use /questtargeting instead."), true)
end)

test("without the settings API, /dqt options explains", function()
    local state = fixture({noSettings = true})
    state.slash("options")
    contains(state.last(), "settings page is unavailable")
end)

test("objective names come from English kill text in either order", function()
    local state = fixture()
    local name = state.dqt.ObjectiveName
    equal(name("Dire Condor slain: 0/8"), "Dire Condor")
    equal(name("0/8 Dire Condor slain"), "Dire Condor")
    equal(name("Defias Bandit killed: 1/10"), "Defias Bandit")
    equal(name("Kill the Ogre"), "Kill the Ogre")
    local hidden = secret()
    state.secrets[hidden] = true
    equal(name(hidden), nil)
end)

-- A Zygor goal: its status through GetStatus, as Goal:GetStatus answers.
local function zgoal(fields, status)
    fields.fakeStatus = status or "incomplete"
    function fields:GetStatus() return self.fakeStatus end
    return fields
end

local function zstep(num, goals)
    return {num = num, goals = goals}
end

-- Each name's line comes after the one before it in the macro.
local function inOrder(body, names)
    local last = 0
    for _, name in ipairs(names) do
        local at = body:find("/targetexact " .. name .. "\n", 1, true)
        equal(at ~= nil, true, name .. " is in the macro")
        equal(at > last, true, name .. " comes after the name before it")
        last = at
    end
end

local function zygorStepThree()
    return zstep(3, {
        zgoal({action = "talk", npc = "Marshal McBride", npcid = 197}, "passive"),
        zgoal({action = "kill", target = "Gnoll Runt", targetid = 40, questid = 2}),
        zgoal({action = "kill", targets = {{"Timber Wolf", 69}, {"Young Wolf", 299}}}, "passive"),
        zgoal({action = "collect", mobs = {{name = "Forest Spider", id = 30, pl = false}}}),
        zgoal({action = "avoid", mobs = {{name = "Hogger", id = 448, pl = false}}}),
        zgoal({action = "kill", target = "Done Mob"}, "complete"),
        zgoal({action = "kill", target = "Hidden Mob"}, "hidden"),
        zgoal({action = "kill", target = "Defias Thugs", targetid = 38, plural = true}),
    })
end

local ZYGOR_STICKY = zstep(9, {zgoal({action = "kill", target = "Gnoll Runt"}),
    zgoal({action = "kill", target = "Sticky Boar"})})

test("zygor: the step's open goals and its sticky steps become /targetexact lines, the first goal last", function()
    local state = fixture({quests = TWO_QUESTS, questie = {focus = 1},
        zygor = {step = zygorStepThree(), stickies = {ZYGOR_STICKY}}})
    local body = state.macro()
    inOrder(body, {"Sticky Boar", "Forest Spider", "Timber Wolf", "Young Wolf", "Gnoll Runt", "Marshal McBride"})
    local _, count = body:gsub("Gnoll Runt", "")
    equal(count, 1, "a name on two steps is one line, at its most important place")
    for _, name in ipairs({"Hogger", "Done Mob", "Hidden Mob", "Defias"}) do
        lacks(body, name, "avoid, complete, hidden, and a plural name without QuestieDB are left out")
    end
    lacks(body, "/targetexact Boar", "Zygor's step wins over Questie's focus at login")
    local lines = boxLines(state)
    equal(lines[1], "Wolves (Zygor)", "the step's first open quest, and the source")
    equal(lines[2], "Zygor: step 3 of Elwynn Forest (1-13)")
    equal(boxRow(state, "Marshal McBride talk to") ~= nil, true)
    state.slash("list")
    equal(state.said("Focused quest: Wolves (Zygor's step 3 of Elwynn Forest (1-13))"), true)
    equal(state.said("Marshal McBride (talk to)"), true)
    state.slash("add Hogger")
    inOrder(state.macro(), {"Marshal McBride"})
    contains(state.macro(), "/tar Hogger\n/targetlasttarget", "the hit list still goes last")
end)

test("zygor: a plural name is QuestieDB's name for its NPC; raw status fields count too", function()
    local db = {quests = {}, items = {}, npcs = {[38] = "Defias Thug"}}
    local step = zstep(5, {{action = "kill", target = "Defias Thugs", targetid = 38, plural = true,
        status = "incomplete"}, {action = "talk", npc = "Old Done", status = "complete"}})
    local state = fixture({quests = TWO_QUESTS, db = db, zygor = {step = step}})
    contains(state.macro(), "/targetexact Defias Thug\n")
    lacks(state.macro(), "Thugs")
    lacks(state.macro(), "Old Done")
    equal(boxLines(state)[1], "Guide step 5 of Elwynn Forest (1-13) (Zygor)", "no quest in the step")
end)

test("zygor: the latest focus wins among Zygor, Questie, and the game", function()
    local state = fixture({quests = THREE_QUESTS, questie = {}, zygor = {step = zygorStepThree()}})
    contains(state.macro(), "/targetexact Marshal McBride", "Zygor's step at login")
    state.questieUtils:FocusQuest(1)
    state.advance()
    contains(state.macro(), "/targetexact Boar", "focusing in Questie's tracker wins")
    lacks(state.macro(), "Gnoll")
    state.zygorSend("ZGV_GOAL_PROGRESS", 3, 2)
    state.advance()
    contains(state.macro(), "/targetexact Boar", "goal progress is not a focus change")
    state.clear()
    local four = zstep(4, {zgoal({action = "kill", target = "Murloc Forager", questid = 2}),
        zgoal({action = "kill", target = "Murloc Streamrunner", questid = 2})})
    state.zygorStep(four, nil, true)
    state.advance()
    contains(state.macro(), "/targetexact Murloc Forager", "a new step wins, also with Zygor's own game focus")
    lacks(state.macro(), "Boar")
    state.env.C_SuperTrack.SetSuperTrackedQuestID(0)
    state.env.C_SuperTrack.SetSuperTrackedQuestID(2)
    state.advance()
    contains(state.macro(), "/targetexact Murloc Forager", "a game focus on the step's quest keeps Zygor's")
    equal(state.said("Focused quest changed via Zygor (Wolves), targeting updated to Murloc Forager."), true)
    state.clear()
    four.goals[2].fakeStatus = "complete"
    state.zygorSend("ZGV_GOAL_COMPLETED", 4, 2)
    state.advance()
    lacks(state.macro(), "Streamrunner")
    equal(state.said("Murloc Streamrunner removed: Quest Wolves objective completed."), true)
    state.focus = 3
    state.emit("SUPER_TRACKING_CHANGED")
    state.advance()
    contains(state.macro(), "/targetexact Kobold", "focusing another quest in the game wins")
    state.zygorSend("ZGV_STEP_CHANGED", 4)
    state.advance()
    contains(state.macro(), "/targetexact Kobold", "the same step again (Zygor's sticky update) is no change")
end)

test("zygor: a step that names no one, the switch off, and a step while the world loads", function()
    local state = fixture({quests = TWO_QUESTS, questie = {focus = 1}, zygor = {step = zygorStepThree()}})
    equal(state.env.DyresQuestTargetingDB.zygorFocus, true, "on by default")
    state.zygorStep(zstep(6, {zgoal({action = "goto"}), zgoal({action = "text"})}))
    state.advance()
    contains(state.macro(), "/targetexact Boar", "a travel step leaves the quest focus in charge")
    state.zygorStep(zygorStepThree())
    state.advance()
    contains(state.macro(), "/targetexact Gnoll Runt")
    state.settings.DQT_ZYGOR_FOCUS:SetValue(false)
    contains(state.macro(), "/targetexact Boar", "off: Zygor's step is ignored")
    state.settings.DQT_ZYGOR_FOCUS:SetValue(true)
    state.questieUtils:FocusQuest(1)
    state.advance()
    state.emit("PLAYER_LEAVING_WORLD")
    state.zygorStep(zstep(7, {zgoal({action = "kill", target = "Loading Mob"})}))
    state.emit("PLAYER_ENTERING_WORLD")
    state.advance(3)
    contains(state.macro(), "/targetexact Boar", "a step Zygor restores while the world loads is no change")
end)

test("zygor: changed or missing fields fall back to the quest focus; the setting is greyed out without it", function()
    local broken = fixture({quests = TWO_QUESTS, focus = 1, zygor = {step = "broken", stickies = 5}})
    contains(broken.macro(), "/targetexact Boar")
    broken.zygor.CurrentStep = {num = "x", goals = {"goal", 7, {action = "kill", target = 5},
        {action = "kill", targets = "none"}, {action = "from", mobs = {"bad", {name = {}}}},
        {action = "kill", target = "No Status"}, {action = "talk", npc = "Bad;Name", status = "incomplete"}}}
    broken.zygor.CurrentStickies = {"sticky", {goals = 3}}
    broken.zygorSend("ZGV_STEP_CHANGED", 1)
    broken.advance()
    contains(broken.macro(), "/targetexact Boar", "nothing usable: the quest focus")
    local none = fixture({quests = TWO_QUESTS, focus = 1, saved = {zygorFocus = true}})
    equal(settingRow(none, "DQT_ZYGOR_FOCUS"):Enabled(), false, "greyed out without Zygor")
    contains(settingRow(none, "DQT_ZYGOR_FOCUS").tooltip, "Needs Zygor Guides Viewer: greyed out")
    equal(none.env.DyresQuestTargetingDB.zygorFocus, true, "the saved value stays")
    local silent = fixture({quests = TWO_QUESTS, focus = 1, zygor = {step = zygorStepThree(), noMessages = true}})
    equal(settingRow(silent, "DQT_ZYGOR_FOCUS"):Enabled(), false, "without its message handlers")
    local zygor = fixture({quests = TWO_QUESTS, focus = 1, zygor = {}})
    equal(settingRow(zygor, "DQT_ZYGOR_FOCUS"):Enabled(), true)
end)

-- A RestedXP step: its number and elements (as its .mob, .target, .unitscan,
-- .complete, .turnin, .accept tags leave them).
local function rstep(index, elements, sticky)
    return {index = index, elements = elements, sticky = sticky, active = true}
end

local RXP_DB = {items = {[60] = {name = "Wolf Fang", drops = {41}}}, npcs = {[40] = "Gnoll Runt", [41] = "Timber Wolf",
    [42] = "Zenn Foulhoof", [43] = "Tenaron Stormgrip", [70] = "Name From ID"},
    quests = {[2] = {objectives = {{{40, "Gnoll Runt slain"}}, nil, {{60}}}, finishedBy = {{42}}, startedBy = {{43}}}}}
local RXP_SPAWNS = {[40] = {name = "Gnoll Runt", at = {10, 20}, zone = 141, far = 50},
    [41] = {name = "Timber Wolf", at = {30, 40}, zone = 141, far = 5},
    [42] = {name = "Zenn Foulhoof", at = {50, 60}, zone = 141, far = 9},
    [43] = {name = "Tenaron Stormgrip", at = {70, 80}, zone = 141, far = 7}}

local function rxpStepThree()
    return rstep(3, {{questId = 2}, {mobs = {"Gnoll Runt"}}, {unitscan = {"Rare Boar"}},
        {targets = {"Zenn Foulhoof", "70"}}, {mobs = nil, parent = {completed = true}}})
end

test("rxp: the active steps' tags become /targetexact lines, the current step and its first tag last", function()
    local sticky = rstep(1, {{mobs = {"Sticky Spider", "Gnoll Runt"}}})
    local state = fixture({quests = TWO_QUESTS, questie = {focus = 1}, db = RXP_DB,
        rxp = {steps = {sticky, rxpStepThree()}}})
    inOrder(state.macro(), {"Sticky Spider", "Zenn Foulhoof", "Name From ID", "Rare Boar", "Gnoll Runt"})
    local _, count = state.macro():gsub("Gnoll Runt", "")
    equal(count, 1, "one line per name, at its most important place")
    lacks(state.macro(), "/targetexact Boar", "RestedXP's step wins at login, over Questie's focus")
    lacks(state.macro(), "/targetexact 70", "a bare ID is QuestieDB's name")
    local lines = boxLines(state)
    equal(lines[1], "Wolves (RestedXP)")
    equal(lines[2], "RestedXP: step 3 of 1-10 Teldrassil")
    equal(boxRow(state, "Zenn Foulhoof talk to") ~= nil, true)
    state.slash("list")
    equal(state.said("Focused quest: Wolves (RestedXP's step 3 of 1-10 Teldrassil)"), true)
    state.clear()
    state.slash("debug")
    equal(state.said("debug RestedXP: step 1-10 Teldrassil#3, 2 active"), true)
    local bare = fixture({quests = TWO_QUESTS, rxp = {steps = {rstep(4, {{mobs = {"99"}}, {targets = {"Named"}}})}}})
    lacks(bare.macro(), "99", "a bare ID without QuestieDB is left out")
    contains(bare.macro(), "/targetexact Named")
    equal(boxLines(bare)[1], "Guide step 4 of 1-10 Teldrassil (RestedXP)", "no quest in the step")
end)

test("rxp: a new step wins; progress does not; its own game focus does not; a finished + tag leaves", function()
    local mobTag = {mobs = {"Gnoll Runt"}, parent = {completed = false}}
    local three = rstep(3, {{questId = 2}, mobTag, {targets = {"Zenn Foulhoof"}}})
    local state = fixture({quests = THREE_QUESTS, questie = {}, rxp = {steps = {three}}})
    contains(state.macro(), "/targetexact Gnoll Runt", "at login")
    equal(state.unitListUpdates, 0)
    state.questieUtils:FocusQuest(1)
    state.advance()
    contains(state.macro(), "/targetexact Boar", "focusing in Questie's tracker wins")
    state.env.C_SuperTrack.SetSuperTrackedQuestID(2)
    state.advance()
    contains(state.macro(), "/targetexact Boar", "RestedXP's own game focus on its quest does not beat Questie's")
    state.rxp.targeting:UpdateUnitList()
    state.advance()
    contains(state.macro(), "/targetexact Boar", "the same step again is no change")
    state.clear()
    state.rxpSteps({rstep(4, {{questId = 2}, {mobs = {"Murloc Forager"}}})})
    state.advance()
    contains(state.macro(), "/targetexact Murloc Forager", "a new step wins, through the hook")
    equal(state.said("Focused quest changed via RestedXP (Wolves), targeting updated to Murloc Forager."), true)
    state.env.C_SuperTrack.SetSuperTrackedQuestID(0)
    state.env.C_SuperTrack.SetSuperTrackedQuestID(2)
    state.advance()
    contains(state.macro(), "/targetexact Murloc Forager", "a game focus on the step's quest keeps RestedXP's")
    state.env.C_SuperTrack.SetSuperTrackedQuestID(3)
    state.advance()
    contains(state.macro(), "/targetexact Kobold", "focusing another quest in the game wins")
    state.clear()
    state.rxpSteps({three})
    state.advance()
    contains(state.macro(), "/targetexact Gnoll Runt")
    mobTag.mobs = nil
    state.rxp.targeting:UpdateUnitList()
    state.advance()
    lacks(state.macro(), "Gnoll")
    equal(state.said("Gnoll Runt removed: Quest Wolves objective completed."), true)
end)

test("rxp: a step that names no one, the switch off, a step while the world loads, changed fields", function()
    local state = fixture({quests = TWO_QUESTS, focus = 1, rxp = {steps = {rxpStepThree()}}})
    equal(state.env.DyresQuestTargetingDB.rxpFocus, true, "on by default")
    state.rxpSteps({rstep(5, {{text = "Go north"}})})
    state.advance()
    contains(state.macro(), "/targetexact Boar", "no one named: the quest focus")
    state.rxpSteps({rxpStepThree()})
    state.advance()
    contains(state.macro(), "/targetexact Gnoll Runt")
    state.settings.DQT_RXP_FOCUS:SetValue(false)
    contains(state.macro(), "/targetexact Boar", "off: ignored")
    state.settings.DQT_RXP_FOCUS:SetValue(true)
    contains(state.macro(), "/targetexact Gnoll Runt", "on again: still the latest")
    state.env.C_SuperTrack.SetSuperTrackedQuestID(2)
    state.advance()
    contains(state.macro(), "/targetexact Gnoll Runt", "its own quest does not beat it")
    state.env.C_SuperTrack.SetSuperTrackedQuestID(1)
    state.advance()
    contains(state.macro(), "/targetexact Boar", "another quest does")
    local quest = fixture({quests = THREE_QUESTS, focus = 1, rxp = {steps = {rxpStepThree()}}})
    quest.env.C_SuperTrack.SetSuperTrackedQuestID(3)
    quest.advance()
    contains(quest.macro(), "/targetexact Kobold")
    quest.emit("PLAYER_LEAVING_WORLD")
    quest.rxpSteps({rstep(7, {{mobs = {"Loading Mob"}}})})
    quest.emit("PLAYER_ENTERING_WORLD")
    quest.advance(3)
    contains(quest.macro(), "/targetexact Kobold", "a step restored while the world loads is no change")
    local broken = fixture({quests = TWO_QUESTS, focus = 1, rxp = {steps = {"step", 5, {index = 1, elements = "none"},
        rstep(2, {"element", {mobs = "none"}, {mobs = {7, {}}}, {targets = {"Bad;Name"}}, {questId = "x"}})}}})
    contains(broken.macro(), "/targetexact Boar", "nothing usable: the quest focus")
    broken.rxp.RXPFrame.activeSteps = "gone"
    broken.emit("QUEST_LOG_UPDATE")
    broken.advance()
    contains(broken.macro(), "/targetexact Boar")
    broken.rxp.RXPFrame = nil
    broken.emit("QUEST_LOG_UPDATE")
    broken.advance()
    contains(broken.macro(), "/targetexact Boar")
end)

test("rxp: the setting is greyed out without it, and without its fields; it hooks only what exists", function()
    local none = fixture({quests = TWO_QUESTS, focus = 1, saved = {rxpFocus = true}})
    equal(settingRow(none, "DQT_RXP_FOCUS"):Enabled(), false, "no RestedXP")
    contains(settingRow(none, "DQT_RXP_FOCUS").tooltip, "Needs RestedXP: greyed out")
    equal(none.env.DyresQuestTargetingDB.rxpFocus, true, "the saved value stays")
    local noFrame = fixture({quests = TWO_QUESTS, focus = 1, rxp = {noFrame = true}})
    equal(settingRow(noFrame, "DQT_RXP_FOCUS"):Enabled(), false)
    local rxp = fixture({quests = TWO_QUESTS, focus = 1, rxp = {}})
    equal(settingRow(rxp, "DQT_RXP_FOCUS"):Enabled(), true)
    equal(rxp.dqt.HookRxp(function() end), true)
    rxp.rxp.targeting.UpdateUnitList = nil
    equal(rxp.dqt.HookRxp(function() end), false)
    local macro = {name = "RXPTargeting", icon = 1, body = "/run RXP"}
    local leftAlone = fixture({quests = TWO_QUESTS, characterMacros = {macro}, rxp = {steps = {rxpStepThree()}}})
    equal(macro.body, "/run RXP", "RestedXP's own macro is left alone")
    contains(leftAlone.macro(), "/targetexact Gnoll Runt")
end)

test("rxp: with Zygor too, Zygor's step wins at login, then the latest new step", function()
    local state = fixture({quests = TWO_QUESTS, zygor = {step = zstep(3, {zgoal({action = "kill", target = "Zygor Mob"})})},
        rxp = {steps = {rstep(3, {{mobs = {"RestedXP Mob"}}})}}})
    contains(state.macro(), "/targetexact Zygor Mob")
    lacks(state.macro(), "RestedXP Mob")
    state.rxpSteps({rstep(4, {{mobs = {"New RestedXP Mob"}}})})
    state.advance()
    contains(state.macro(), "/targetexact New RestedXP Mob")
    state.zygorStep(zstep(4, {zgoal({action = "kill", target = "New Zygor Mob"})}))
    state.advance()
    contains(state.macro(), "/targetexact New Zygor Mob")
    local only = fixture({quests = TWO_QUESTS, zygor = {step = zstep(3, {zgoal({action = "goto"})})},
        rxp = {steps = {rstep(3, {{mobs = {"RestedXP Mob"}}})}}})
    contains(only.macro(), "/targetexact RestedXP Mob", "Zygor names no one: RestedXP's")
end)

test("rxp: classic without Questie follows RestedXP's step, with no line about a missing focus", function()
    local state = fixture({quests = TWO_QUESTS, classic = true, rxp = {steps = {rxpStepThree()}}})
    equal(state.dqt.available, true)
    contains(state.macro(), "/targetexact Gnoll Runt")
    equal(state.said("no quest focus of its own"), false)
    equal(boxLines(state)[1], "Wolves (RestedXP)")
end)

test("rxp: TomTom finds IDs through QuestieDB; never at login; no match uses a real quest or stays", function()
    local function rxpTomTom(steps)
        return fixture({quests = TWO_QUESTS, db = RXP_DB, questie = {npcs = RXP_SPAWNS}, tomtom = true,
            saved = {tomtom = true}, rxp = {steps = steps}})
    end
    local state = rxpTomTom({rstep(3, {{questId = 2}, {mobs = {"Gnoll Runt"}}})})
    equal(#state.waypoints, 0, "the step RestedXP restores at login leaves your waypoint alone")
    state.rxpSteps({rstep(4, {{questId = 2}, {mobs = {"Gnoll Runt", "Timber Wolf"}}})})
    state.advance()
    equal(state.waypoints[#state.waypoints], "Timber Wolf 141 30,40", "a dropper of the quest's item, the nearest")
    state.rxpSteps({rstep(5, {{questId = 2}, {targets = {"Zenn Foulhoof"}}})})
    state.advance()
    equal(state.waypoints[#state.waypoints], "Zenn Foulhoof 141 50,60", "who finishes the quest")
    state.rxpSteps({rstep(6, {{questId = 2}, {targets = {"Tenaron Stormgrip"}}})})
    state.advance()
    equal(state.waypoints[#state.waypoints], "Tenaron Stormgrip 141 70,80", "who starts the quest")
    state.rxpSteps({rstep(7, {{questId = 2}, {mobs = {"Unknown Mob"}}})})
    state.advance()
    equal(state.waypoints[#state.waypoints], "quest 2", "no match: a real quest of the step")
    local count = #state.waypoints
    state.rxpSteps({rstep(8, {{mobs = {"Other Mob"}}})})
    state.advance()
    state.rxpSteps({rstep(9, {{questId = 999}, {mobs = {"Third Mob"}}})})
    state.advance()
    equal(#state.waypoints, count, "no quest in your log: the waypoint stays")
    for _, waypoint in ipairs(state.waypoints) do
        lacks(waypoint, "rxp", "DQT's key never reaches Questie")
    end
end)

local ZYGOR_NPCS = {[40] = {name = "Gnoll Runt", at = {10, 20}, zone = 12, far = 50},
    [41] = {name = "Murloc Forager", at = {30, 40}, zone = 12, far = 5},
    [42] = {name = "Zenn Foulhoof", at = {50, 60}, zone = 141, far = 9}}

local function zygorTomTom(options)
    options.quests = options.quests or TWO_QUESTS
    options.questie = options.questie or {npcs = ZYGOR_NPCS}
    options.tomtom, options.saved = true, {tomtom = true}
    return fixture(options)
end

local function zkill(name, id, questid)
    return zgoal({action = "kill", target = name, targetid = id, questid = questid})
end

test("zygor: TomTom points at the step's mobs and NPCs, and again when they change, not at login", function()
    local gnolls = zstep(3, {zkill("Gnoll Runt", 40, 2)})
    local state = zygorTomTom({zygor = {step = gnolls}})
    equal(#state.waypoints, 0, "the step Zygor restores at login leaves your waypoint alone")
    state.zygorSend("ZGV_GOAL_PROGRESS", 3, 1)
    state.advance()
    equal(#state.waypoints, 0, "progress changes nothing")
    state.zygorStep(zstep(4, {zkill("Murloc Forager", 41), zkill("Gnoll Runt", 40)}))
    state.advance()
    equal(state.waypoints[#state.waypoints], "Murloc Forager 12 30,40", "a new step: its nearest mob")
    local count = #state.waypoints
    state.zygor.CurrentStep.goals[1].fakeStatus = "complete"
    state.zygorSend("ZGV_GOAL_COMPLETED", 4, 1)
    state.advance()
    equal(#state.waypoints, count + 1, "the macro's mobs changed")
    equal(state.waypoints[#state.waypoints], "Gnoll Runt 12 10,20")
    state.zygorStep(zstep(5, {zgoal({action = "talk", npc = "Zenn Foulhoof", npcid = 42}, "passive")}))
    state.advance()
    equal(state.waypoints[#state.waypoints], "Zenn Foulhoof 141 50,60", "an NPC to talk to, too")
end)

test("zygor: without spawn data, TomTom uses the step's quest in your log, or stays; never DQT's own key", function()
    local state = zygorTomTom({zygor = {step = zstep(3, {zkill("Gnoll Runt", 40)})}})
    state.zygorStep(zstep(4, {zkill("Forever Mob", 261306, 2)}))
    state.advance()
    equal(state.waypoints[#state.waypoints], "quest 2", "the step's quest, a real ID")
    local count = #state.waypoints
    state.zygorStep(zstep(5, {zkill("Forever Mob", 261306, 999), zkill("Other Mob", 261307)}))
    state.advance()
    state.zygorStep(zstep(6, {zgoal({action = "kill", target = "No ID Mob"})}))
    state.advance()
    equal(#state.waypoints, count, "no quest in your log: the waypoint stays")
    for _, waypoint in ipairs(state.waypoints) do
        lacks(waypoint, "zygor", "DQT's key never reaches Questie")
    end
end)

test("zygor: a step Zygor restores after login does not point TomTom; a travel step counts as the first", function()
    local late = zygorTomTom({focus = 1, zygor = {}})
    equal(#late.waypoints, 0)
    late.zygorStep(zstep(3, {zkill("Gnoll Runt", 40)}))
    late.advance()
    contains(late.macro(), "/targetexact Gnoll Runt", "Zygor's step wins")
    equal(#late.waypoints, 0, "the restored step, seconds after login")
    late.zygorStep(zstep(4, {zkill("Murloc Forager", 41)}))
    late.advance()
    equal(late.waypoints[#late.waypoints], "Murloc Forager 12 30,40")
    local travel = zygorTomTom({zygor = {step = zstep(3, {zgoal({action = "goto"})})}})
    equal(#travel.waypoints, 0)
    travel.zygorStep(zstep(4, {zkill("Murloc Forager", 41)}))
    travel.advance()
    equal(travel.waypoints[#travel.waypoints], "Murloc Forager 12 30,40", "a real step change")
end)

local function rxpLocationState(options)
    options.quests = options.quests or TWO_QUESTS
    options.db = options.db or RXP_DB
    options.tomtomApi, options.saved = true, options.saved or {tomtom = true}
    return fixture(options)
end

-- An element of RestedXP's arrow list: x and y are 0 to 100.
local function rway(step, x, y, fields)
    local element = fields or {}
    element.step, element.zone, element.x, element.y = step, 1438, x, y
    if element.arrow == nil then
        element.arrow = true
    end
    return element
end

test("rxp location: the arrow's choice, in RestedXP's order, a low-priority one last", function()
    local step = rstep(3, {{mobs = {"Gnoll Runt"}}})
    local state = rxpLocationState({questie = {npcs = RXP_SPAWNS}, rxp = {steps = {step}, waypoints = {rway(step, 10, 20)}}})
    equal(#state.tomtomPoints, 0, "the step RestedXP restores at login does not point")
    local nextStep = rstep(4, {{mobs = {"Gnoll Runt"}}})
    local sticky = rstep(nil, {{text = "sticky"}})
    state.rxpSteps({sticky, nextStep})
    state.rxpMap({
        rway(nextStep, 1, 1, {hidden = true}),
        rway(nextStep, 2, 2, {skip = true}),
        rway(nextStep, 3, 3, {parent = {completed = true}}),
        rway(nextStep, 4, 4, {arrow = false}),
        rway(nextStep, 5, 5, {text = "done", completed = true}),
        rway(rstep(9, {}), 6, 6),
        rway(nextStep, 7, 7, {lowPrio = true}),
        rway(sticky, 62, 42),
        rway(nextStep, 50, 60),
    })
    state.rxp.activeWaypoints[6].step.active = false
    state.advance()
    equal(state.tomtomPoints[#state.tomtomPoints].text, "1438 0.62,0.42", "the first it may take; a sticky step first")
    equal(#state.waypoints, 0, "not the mob's spawn: the step has a location")
    state.rxpMap({rway(nextStep, 7, 7, {lowPrio = true})})
    state.advance()
    equal(state.tomtomPoints[#state.tomtomPoints].text, "1438 0.07,0.07", "low priority, when no other is left")
    equal(state.tomtomPoints[#state.tomtomPoints].opts.crazy, true, "the arrow goes there")
    state.rxpMap({rway(nextStep, 3, 3, {generated = 1, arrow = false})})
    state.advance()
    equal(state.tomtomPoints[#state.tomtomPoints].text, "1438 0.03,0.03", "a generated point")
end)

test("rxp location: a waypoint reached within a step moves the arrow; no change does not", function()
    local step = rstep(3, {{mobs = {"Gnoll Runt"}}})
    local state = rxpLocationState({questie = {npcs = RXP_SPAWNS}, rxp = {steps = {step}, waypoints = {rway(step, 10, 20)}}})
    state.advance()
    local nextStep = rstep(4, {{mobs = {"Gnoll Runt"}}})
    local first, second = rway(nextStep, 30, 40), rway(nextStep, 50, 60)
    state.rxpSteps({nextStep})
    state.rxpMap({first, second})
    state.advance()
    equal(#state.tomtomPoints, 1)
    equal(state.tomtomPoints[1].text, "1438 0.3,0.4")
    state.rxp.activeWaypoints = {second}
    state.rxp.UpdateMap()
    state.advance()
    equal(#state.tomtomPoints, 1, "UpdateMap() only sets RestedXP's flag: no rebuild yet")
    first.skip = true
    state.rxpMap({second})
    state.advance()
    equal(#state.tomtomPoints, 2, "the signal alone moves it")
    equal(state.tomtomPoints[2].text, "1438 0.5,0.6")
    equal(state.tomtomRemoved[1], state.tomtomPoints[1], "the earlier waypoint goes")
    equal(state.env.Questie.db.char._tom_waypoint, state.tomtomPoints[2], "Questie's next waypoint replaces this one")
    state.rxpMap({second})
    state.advance()
    equal(#state.tomtomPoints, 2, "the same location is not set again")
end)

test("rxp location: appearing after login is not a change; a step that names no one points; old path without one", function()
    local step = rstep(3, {{mobs = {"Gnoll Runt"}}})
    local late = rxpLocationState({questie = {npcs = RXP_SPAWNS}, focus = 1, rxp = {steps = {step}, waypoints = {}}})
    late.advance()
    late.rxpMap({rway(step, 10, 20)})
    late.advance()
    equal(#late.tomtomPoints, 0, "RestedXP's list fills a moment after login")
    equal(#late.waypoints, 0)

    local travel = rstep(4, {{text = "Go north"}})
    late.rxpSteps({travel})
    late.rxpMap({rway(travel, 70, 80)})
    late.advance()
    equal(late.tomtomPoints[#late.tomtomPoints].text, "1438 0.7,0.8", "the guide is the latest focus")
    contains(late.macro(), "/targetexact Boar", "the macro follows the quest focus")
    lacks(late.macro(), "Go north")

    local noWay = rstep(5, {{mobs = {"Gnoll Runt", "Timber Wolf"}}, {questId = 2}})
    local count = #late.tomtomPoints
    late.rxpSteps({noWay})
    late.rxpMap({})
    late.advance()
    equal(#late.tomtomPoints, count, "no location")
    equal(late.waypoints[#late.waypoints], "Timber Wolf 141 30,40", "today's path: the nearest spawn")
end)

test("rxp location: without Questie it still points, unsaved; the switch and TomTom's calls gate it", function()
    local step = rstep(3, {{mobs = {"Gnoll Runt"}}})
    local state = rxpLocationState({rxp = {steps = {step}, waypoints = {rway(step, 10, 20)}}})
    state.advance()
    local nextStep = rstep(4, {{mobs = {"Gnoll Runt"}}})
    state.rxpSteps({nextStep})
    state.rxpMap({rway(nextStep, 30, 40)})
    state.advance()
    equal(state.tomtomPoints[1].text, "1438 0.3,0.4")
    equal(state.tomtomPoints[1].opts.persistent, false, "nothing would remove it after a /reload")
    local thirdStep = rstep(5, {{mobs = {"Gnoll Runt"}}})
    state.rxpSteps({thirdStep})
    state.rxpMap({rway(thirdStep, 50, 60)})
    state.advance()
    equal(state.tomtomRemoved[1], state.tomtomPoints[1], "DQT removes its own")

    local off = rxpLocationState({saved = {tomtom = false}, rxp = {steps = {step}, waypoints = {}}})
    off.advance()
    off.rxpSteps({nextStep})
    off.rxpMap({rway(nextStep, 30, 40)})
    off.advance()
    equal(#off.tomtomPoints, 0, "the setting is off")
    equal(off.mapUpdates, 1)

    local notFollowed = rxpLocationState({saved = {tomtom = true, rxpFocus = false}, focus = 1,
        rxp = {steps = {step}, waypoints = {}}})
    notFollowed.advance()
    notFollowed.rxpSteps({nextStep})
    notFollowed.rxpMap({rway(nextStep, 30, 40)})
    notFollowed.advance()
    equal(#notFollowed.tomtomPoints, 0, "RestedXP is not followed")

    local oldTomTom = fixture({quests = TWO_QUESTS, db = RXP_DB, questie = {npcs = RXP_SPAWNS}, tomtom = true,
        saved = {tomtom = true}, rxp = {steps = {step}, waypoints = {rway(step, 10, 20)}}})
    oldTomTom.advance()
    local killStep = rstep(6, {{questId = 2}, {mobs = {"Gnoll Runt"}}})
    oldTomTom.rxpSteps({killStep})
    oldTomTom.rxpMap({rway(killStep, 30, 40)})
    oldTomTom.advance()
    equal(oldTomTom.waypoints[#oldTomTom.waypoints], "Gnoll Runt 141 10,20", "no AddWaypoint: the old path")
    local noQuest = fixture({quests = TWO_QUESTS, questie = {npcs = RXP_SPAWNS}, tomtom = true, saved = {tomtom = true},
        rxp = {steps = {step}, waypoints = {rway(step, 10, 20)}}})
    noQuest.advance()
    local travelStep = rstep(7, {{text = "Go north"}})
    noQuest.rxpSteps({travelStep})
    noQuest.rxpMap({rway(travelStep, 30, 40)})
    noQuest.advance()
    equal(#noQuest.waypoints, 0, "no AddWaypoint and no focused quest: nothing to do, and no error")
end)

test("rxp location: a quest focus chosen after the step takes the arrow back", function()
    local step = rstep(3, {{mobs = {"Gnoll Runt"}}})
    local state = rxpLocationState({questie = {npcs = RXP_SPAWNS}, focus = 1,
        rxp = {steps = {step}, waypoints = {rway(step, 10, 20)}}})
    state.advance()
    local nextStep = rstep(4, {{mobs = {"Gnoll Runt"}}})
    state.rxpSteps({nextStep})
    state.rxpMap({rway(nextStep, 30, 40)})
    state.advance()
    equal(#state.tomtomPoints, 1)
    local before = #state.waypoints
    state.questieUtils:FocusQuest(2)
    state.advance()
    equal(#state.tomtomPoints, 1, "not the step's location")
    equal(#state.waypoints, before + 1, "the quest's own path, unchanged")
end)

local QTR_QUESTS = {[1] = TWO_QUESTS[1], [2] = TWO_QUESTS[2],
    [5] = {title = "Done Deal", complete = true, objectives = {objective("Thing: 1/1", true)}}}
local QTR_DB = {items = {[60] = {name = "Wolf Fang", drops = {41}}, [61] = {name = "Strange Note", drops = {44}}},
    npcs = {[40] = "Gnoll Runt", [41] = "Timber Wolf", [42] = "Zenn Foulhoof", [43] = "Tenaron Stormgrip",
        [44] = "Note Carrier"},
    quests = {[2] = {objectives = {{{41, "Wolf slain"}}}},
        [5] = {finishedBy = {{42}}},
        [7] = {startedBy = {{43}}}, [8] = {startedBy = {nil, nil, {61}}}}}

local function qtrState(options)
    options.quests = options.quests or QTR_QUESTS
    options.db = options.db or QTR_DB
    options.questtrail = options.questtrail or {}
    return fixture(options)
end

test("questtrail: an objective step targets that objective; the game focus it sets is not a change", function()
    local state = qtrState({focus = 1})
    contains(state.macro(), "/targetexact Boar", "no step yet: the quest focus")
    state.qtrStep({kind = "progress", q = 2, oi = 2, key = "x"})
    state.advance()
    contains(state.macro(), "/targetexact Bear")
    lacks(state.macro(), "Wolf", "only the step's objective")
    equal(boxLines(state)[1], "Wolves (QuestTrail)")
    equal(state.said("Focused quest changed via QuestTrail (Wolves)"), true)
    state.slash("list")
    equal(state.said("QuestTrail's objective step"), true)
    state.qtrStep({kind = "progress", q = 2, key = "y"})
    state.advance()
    contains(state.macro(), "/targetexact Timber Wolf", "no objective: every open one")
    contains(state.macro(), "/targetexact Bear")
    state.qtr.Arrow.current = {kind = "progress", q = 2, oi = 1}
    state.qtr.Arrow.AdvanceDone()
    state.advance()
    lacks(state.macro(), "Bear", "its compass moves on within the quest")
end)

test("questtrail: a take step targets who gives the quest, or an item's droppers; a turn-in step the turn-in", function()
    local state = qtrState({focus = 1})
    state.qtrStep({kind = "start", q = 7})
    state.advance()
    contains(state.macro(), "/targetexact Tenaron Stormgrip")
    lacks(state.macro(), "Boar", "a quest not in the log: the game's focus cleared, the step counts")
    equal(boxLines(state)[1], "quest 7 (QuestTrail)")
    state.qtrStep({kind = "dropstart", q = 8})
    state.advance()
    contains(state.macro(), "/targetexact Note Carrier", "the item that starts it")
    state.qtrStep({kind = "finish", q = 5})
    state.advance()
    contains(state.macro(), "/targetexact Zenn Foulhoof")
    contains(boxLines(state)[1], "ready to turn in")
end)

test("questtrail: Questie's focus changed last wins; its next step wins back; other kinds and bad fields do not", function()
    local state = qtrState({focus = 1, questie = {}})
    state.qtrStep({kind = "progress", q = 2, oi = 1})
    state.advance()
    contains(state.macro(), "/targetexact Timber Wolf")
    state.questieUtils:FocusQuest(1)
    state.advance()
    contains(state.macro(), "/targetexact Boar")
    state.qtrStep({kind = "progress", q = 2, oi = 2})
    state.advance()
    contains(state.macro(), "/targetexact Bear", "a new step")
    for _, current in ipairs({{kind = "hearth", q = 0}, {kind = "progress", q = "2"}, {kind = "start", q = 99}}) do
        state.qtrStep(current)
        state.advance()
        contains(state.macro(), "/targetexact Boar", "no step to follow: the quest focus")
    end
end)

test("questtrail: the game focus it sets is not copied to Questie; its first plan, late, does not point TomTom", function()
    local state = qtrState({focus = 1, questie = {}, saved = {syncFocus = true}})
    state.qtrStep({kind = "progress", q = 2, oi = 2})
    state.advance()
    contains(state.macro(), "/targetexact Bear")
    equal(state.env.Questie.db.char.TrackerFocus, nil, "the sync leaves Questie's focus alone, as for a guide")

    local late = qtrState({focus = 1, tomtomApi = true, saved = {tomtom = true}, questie = {npcs = RXP_SPAWNS}})
    late.advance()
    late.qtrStep({kind = "progress", q = 2, oi = 2, cm = 1438, mx = 0.7, my = 0.8})
    late.advance()
    equal(#late.tomtomPoints, 0, "QuestTrail's first plan comes well after login")
    late.qtrStep({kind = "progress", q = 2, oi = 1, cm = 1438, mx = 0.1, my = 0.2})
    late.advance()
    equal(late.tomtomPoints[1].text, "1438 0.1,0.2", "its next step")
end)

test("questtrail: off or missing, the game focus it sets counts as before; the setting is greyed without it", function()
    local off = qtrState({focus = 1, saved = {qtrFocus = false}})
    off.qtrStep({kind = "progress", q = 2, oi = 2})
    off.advance()
    contains(off.macro(), "/targetexact Timber Wolf", "the game's focus, all objectives")
    equal(boxLines(off)[1], "Wolves (Focus)")
    equal(settingRow(off, "DQT_QTR_FOCUS"):Enabled(), true)
    local none = fixture({quests = QTR_QUESTS, focus = 1})
    equal(settingRow(none, "DQT_QTR_FOCUS"):Enabled(), false)
    contains(settingRow(none, "DQT_QTR_FOCUS").tooltip, "Needs QuestTrail")
    local noArrow = fixture({quests = QTR_QUESTS, focus = 1})
    noArrow.env.LibStub = {GetLibrary = function() return {ns = {}} end}
    equal(settingRow(noArrow, "DQT_QTR_FOCUS"):Enabled(), false, "a namespace without its Arrow")
    equal(qtrState({}).qtrHooks, 0)
end)

test("questtrail: TomTom points silently at its step, never at login; Questie's points are silent too", function()
    local step = {kind = "progress", q = 2, oi = 1, cm = 1438, mx = 0.5, my = 0.6, ax = 0.4, ay = 0.3}
    local state = qtrState({tomtomApi = true, saved = {tomtom = true}, questie = {npcs = RXP_SPAWNS},
        questtrail = {current = step}})
    state.advance()
    equal(#state.tomtomPoints, 0, "the plan QuestTrail restores at login")
    state.qtrStep({kind = "progress", q = 2, oi = 2, cm = 1438, mx = 0.7, my = 0.8})
    state.advance()
    equal(state.tomtomPoints[1].text, "1438 0.7,0.8")
    equal(state.tomtomPoints[1].opts.silent, true, "QuestTrail's compass keeps its plan")
    state.qtrStep({kind = "progress", q = 2, oi = 1, cm = 1438, mx = 0.9, my = 0.9, ax = 0.2, ay = 0.1})
    state.advance()
    equal(state.tomtomPoints[2].text, "1438 0.2,0.1", "where the plan sent you, not the marker tour")
    state.questieUtils:FocusQuest(2)
    state.advance()
    equal(state.tomtomPoints[3].text, "1438 0.3,0.4", "a quest focus: Questie's spawn, through TomTom")
    equal(state.tomtomPoints[3].opts.silent, true)
    equal(#state.waypoints, 0, "not Questie's own call, which is not silent")
end)

test("questtrail: \"on the way\" objectives come before the step's, all on the route last; each name once", function()
    local quests = {[1] = TWO_QUESTS[1], [2] = TWO_QUESTS[2],
        [3] = {title = "Kobolds", objectives = {objective("Kobold slain: 0/5"), objective("Rat slain: 0/5")}}}
    local state = qtrState({quests = quests, focus = 1})
    state.qtr.Arrow.onTheWay = {
        {q = 3, i = 2, full = true},
        {q = 1, i = 1, full = false},
        {q = 2, i = 2, full = false, step = true},
        {q = 99, i = 1, full = true},
        {q = 3, i = "1"},
    }
    state.qtrStep({kind = "progress", q = 2, oi = 2})
    state.advance()
    inOrder(state.macro(), {"Boar", "Rat", "Bear"})
    lacks(state.macro(), "Kobold", "only the objective that is on the way")
    local _, count = state.macro():gsub("/targetexact Bear\n", "")
    equal(count, 1, "the step's objective once, as the step's")
    state.qtr.Arrow.onTheWay = nil
    state.qtrStep({kind = "progress", q = 2, oi = 1})
    state.advance()
    lacks(state.macro(), "Boar", "a new plan with nothing on the way")
    state.qtr.Arrow.onTheWay = {{q = 1, i = 1, full = true}}
    state.qtr.Arrow.current = {kind = "progress", q = 99, oi = 1}
    state.qtr.Arrow.SavePlan()
    state.advance()
    lacks(state.macro(), "Boar", "a step DQT cannot follow brings no \"on the way\" names alone")
end)

local function zway(x, y, fields)
    local goal = zgoal(fields or {})
    goal.action, goal.map, goal.x, goal.y = goal.action or "goto", 1429, x, y
    return goal
end

test("zygor location: the current waypoint goal, or the next it can point at; not sticky steps", function()
    local state = fixture({quests = TWO_QUESTS, questie = {npcs = ZYGOR_NPCS}, tomtomApi = true, saved = {tomtom = true},
        zygor = {step = zstep(3, {zway(0.1, 0.2)})}})
    equal(#state.tomtomPoints, 0, "not the step Zygor restores at login")
    state.advance()
    local hidden = zway(0.3, 0.3)
    function hidden:IsVisible() return false end
    state.zygorStep(zstep(4, {
        hidden,
        zway(0.4, 0.4, {force_noway = true}),
        zway(0.5, 0.5, {action = "mapmarker"}),
        zgoal({action = "kill", target = "Gnoll Runt", targetid = 40}),
        zway(0.6, 0.7),
        zway(0.8, 0.9),
    }))
    state.advance()
    equal(state.tomtomPoints[#state.tomtomPoints].text, "1429 0.6,0.7", "the first it can point at")
    equal(#state.waypoints, 0, "not the mob's spawn")
    local count = #state.tomtomPoints
    local step = zstep(5, {zway(0.11, 0.12), zway(0.13, 0.14)})
    step.current_waypoint_goal_num = 2
    state.zygorStep(step)
    state.advance()
    equal(#state.tomtomPoints, count + 1)
    equal(state.tomtomPoints[#state.tomtomPoints].text, "1429 0.13,0.14", "Zygor's current waypoint goal")
    step.current_waypoint_goal_num = 1
    state.zygorSend("ZGV_STEP_WAYPOINT_CHANGED", step, 1)
    state.advance()
    equal(state.tomtomPoints[#state.tomtomPoints].text, "1429 0.11,0.12", "its own message moves the arrow")
    equal(state.tomtomRemoved[#state.tomtomRemoved], state.tomtomPoints[#state.tomtomPoints - 1], "the earlier one goes")
    local sticky = zstep(90, {zway(0.5, 0.5)})
    state.env.ZygorGuidesViewer.CurrentStickies = {sticky}
    count = #state.tomtomPoints
    state.zygorSend("ZGV_GOAL_PROGRESS", 5, 1)
    state.advance()
    equal(#state.tomtomPoints, count, "a sticky step does not take Zygor's arrow, nor this one")
end)

test("zygor location: without one, today's path; bad fields count as none; a quest focus takes it back", function()
    local state = fixture({quests = TWO_QUESTS, questie = {npcs = ZYGOR_NPCS}, tomtomApi = true, saved = {tomtom = true},
        zygor = {step = zstep(3, {zway(0.1, 0.2)})}})
    state.advance()
    state.zygorStep(zstep(4, {zkill("Murloc Forager", 41)}))
    state.advance()
    equal(state.waypoints[#state.waypoints], "Murloc Forager 12 30,40", "no location")
    equal(#state.tomtomPoints, 0)
    local stringMap = zway(0.2, 0.2)
    stringMap.map = "Elwynn Forest"
    state.zygorStep(zstep(5, {stringMap, zkill("Gnoll Runt", 40)}))
    state.advance()
    equal(#state.tomtomPoints, 0, "a map that is no number")
    equal(state.waypoints[#state.waypoints], "Gnoll Runt 12 10,20")
    state.zygorStep(zstep(6, {zway(0.3, 0.4)}))
    state.advance()
    equal(state.tomtomPoints[#state.tomtomPoints].text, "1429 0.3,0.4", "a travel step that names no one")
    local count, before = #state.tomtomPoints, #state.waypoints
    state.questieUtils:FocusQuest(1)
    state.advance()
    equal(#state.tomtomPoints, count, "Questie's focus changed last")
    equal(#state.waypoints, before + 1)
end)

test("zygor: TomTom needs its switch, TomTom, and Questie", function()
    local off = fixture({quests = TWO_QUESTS, questie = {npcs = ZYGOR_NPCS}, tomtom = true,
        zygor = {step = zstep(3, {zkill("Gnoll Runt", 40)})}})
    off.zygorStep(zstep(4, {zkill("Murloc Forager", 41)}))
    off.advance()
    equal(#off.waypoints, 0, "off by default")
    off.settings.DQT_TOMTOM:SetValue(true)
    equal(off.waypoints[#off.waypoints], "Murloc Forager 12 30,40", "turning it on points now")
    local none = fixture({quests = TWO_QUESTS, questie = {npcs = ZYGOR_NPCS}, saved = {tomtom = true},
        zygor = {step = zstep(3, {zkill("Gnoll Runt", 40)})}})
    none.zygorStep(zstep(4, {zkill("Murloc Forager", 41)}))
    none.advance()
    equal(#none.waypoints, 0, "no TomTom")
    local bare = fixture({quests = TWO_QUESTS, tomtom = true, saved = {tomtom = true},
        zygor = {step = zstep(3, {zkill("Gnoll Runt", 40)})}})
    bare.zygorStep(zstep(4, {zkill("Murloc Forager", 41)}))
    bare.advance()
    contains(bare.macro(), "/targetexact Murloc Forager", "no Questie: the macro still follows")
end)

local failed = 0
for index, entry in ipairs(tests) do
    local ok, message = xpcall(entry.body, debug.traceback)
    if ok then
        io.write("ok ", index, " - ", entry.name, "\n")
    else
        failed = failed + 1
        io.write("not ok ", index, " - ", entry.name, "\n", tostring(message), "\n")
    end
end
io.write(string.format("\n%d tests: %d passed, %d failed\n", #tests, #tests - failed, failed))
io.write("Mock results do not establish in-client compatibility.\n")
os.exit(failed == 0 and 0 or 1)
