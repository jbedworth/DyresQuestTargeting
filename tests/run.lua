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
local RUNTIME_FILES = {"Commands.lua", "Core.lua", "Quest.lua", "Macro.lua", "Options.lua"}
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
        Quest = {objectives = reader(data.quests, "objectives"), finishedBy = reader(data.quests, "finishedBy")},
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
                return {Objectives = objectives}
            end,
            -- {rate, source}, as Questie's DropDB answers.
            GetItemDroprate = function(itemID, npcID)
                local rates = options.questie.rates and options.questie.rates[itemID]
                if rates and rates[npcID] then return {rates[npcID], "wowhead"} end
            end},
            -- An NPC's spawns here are one point and its distance from you.
            DistanceUtils = {GetNearestObjective = function(list) return list.spawn, list.zone, list.name end,
                GetNearestSpawn = function(spawns) return spawns.at, spawns.zone, spawns.far end},
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
    env.UnitExists = function(unit) equal(unit, "target") return state.target ~= nil end
    env.UnitName = function(unit) equal(unit, "target") return state.target end

    -- Settings: proxy settings with getters and setters, as the client builds them.
    if not options.noSettings then
        local function initializer(category, setting, extra, tooltip)
            local object = {setting = setting, options = extra, tooltip = tooltip}
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
            RegisterProxySetting = function(category, variable, variableType, name, default, getValue, setValue)
                equal(state.settings[variable], nil, "setting variables are unique")
                local setting = {variable = variable, type = variableType, name = name, default = default}
                function setting:GetValue() return getValue() end
                function setting:SetValue(value) setValue(value) end
                state.settings[variable] = setting
                return setting
            end,
            RegisterAddOnCategory = function(category) state.registered = category end,
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

    env.CreateFrame = function(kind)
        local frame = {kind = kind, events = {}, scripts = {}}
        function frame:RegisterEvent(event)
            if event == "COMBAT_LOG_EVENT_UNFILTERED" then
                error("COMBAT_LOG_EVENT_UNFILTERED is restricted")
            end
            self.events[event] = true
        end
        function frame:UnregisterEvent(event) self.events[event] = nil end
        function frame:RegisterUnitEvent(event, unit)
            equal(unit, "player")
            self.events[event] = true
        end
        function frame:SetScript(script, callback) self.scripts[script] = callback end
        state.frames[#state.frames + 1] = frame
        return frame
    end
    function state.emit(event, ...)
        for _, frame in ipairs(state.frames) do
            if frame.events[event] and frame.scripts.OnEvent then
                frame.scripts.OnEvent(frame, event, ...)
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
    env.DyresQuestTargetingDB = options.saved
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
    contains(state.messages[1], "DQT: Dyre's Quest Targeting 0.1.0-beta by Dyre")
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

test("the Questie settings sit under an experimental section heading", function()
    local state = fixture()
    local list = state.registered.initializers
    local heading
    for index, object in ipairs(list) do
        if object.header then heading = index end
    end
    equal(list[heading].header, "Questie Synchronization (Experimental)")
    equal(list[heading + 1].setting.variable, "DQT_SYNC_FOCUS")
    equal(list[heading + 2].setting.variable, "DQT_TOMTOM")
    contains(list[heading + 1].setting.name, "(experimental)")
    contains(list[heading + 2].tooltip, "Use with caution.")
    local bare = fixture({noSectionHeaders = true})
    equal(bare.settings.DQT_SYNC_FOCUS.name, "Keep Questie's and the game's focus in sync (experimental)",
        "without headings, the settings are still there")
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
    local choices = state.settings.DQT_MOB_MARKER and state.registered.initializers[4].options()
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

test("the opener lists every spellbook spell and rank, and casts the one picked", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101, globals = spellbookGlobals()})
    local opener = state.registered.initializers[6]
    equal(opener.setting.variable, "DQT_OPENER")
    local labels = {}
    for _, choice in ipairs(opener.options()) do labels[#labels + 1] = choice.label end
    equal(table.concat(labels, ","), "Nothing,Start attacking (/startattack),Attack,Auto Shot,"
        .. "Entangling Roots(Rank 1),Moonfire(Rank 1),Moonfire(Rank 2),Moonfire(Rank 3)",
        "harmful spells of 1 second or less only: no Wrath (1.5 s), no Mark of the Wild (helpful)")
    opener.setting:SetValue("Moonfire(Rank 1)")
    local body = lines(state.macro())
    equal(body[#body], "/cast [harm,nodead] Moonfire(Rank 1)")
    opener.setting:SetValue("startattack")
    body = lines(state.macro())
    equal(body[#body], "/startattack [harm,nodead]")
    opener.setting:SetValue("Bad; Spell")
    equal(state.env.DyresQuestTargetingDB.opener, "startattack", "an unsafe name is refused")
    opener.setting:SetValue("")
    lacks(state.macro(), "/startattack")
    lacks(state.macro(), "/cast")
end)

test("each dropdown sets its own label function, so a pooled frame's stale one is replaced", function()
    local state = fixture()
    for _, index in ipairs({4, 5, 6}) do
        local dropdown = state.registered.initializers[index]
        equal(type(dropdown.getSelectionTextFunc), "function", dropdown.setting.variable)
        equal(dropdown.getSelectionTextFunc(), nil, "nil keeps the chosen option's own text")
    end
end)

test("without the spell info API, the opener lists every spell, as before", function()
    local state = fixture({globals = spellbookGlobals(true)})
    local labels = {}
    for _, choice in ipairs(state.registered.initializers[6].options()) do labels[#labels + 1] = choice.label end
    contains(table.concat(labels, ","), "Wrath(Rank 1)")
    contains(table.concat(labels, ","), "Mark of the Wild(Rank 1)")
end)

test("a spell picked earlier stays in the list after the spellbook loses it", function()
    local state = fixture({globals = spellbookGlobals(), saved = {opener = "Rake(Rank 2)"}})
    local choices = state.registered.initializers[6].options()
    equal(choices[#choices].label, "Rake(Rank 2)")
    local bare = fixture({saved = {opener = "Rake(Rank 2)"}})
    choices = bare.registered.initializers[6].options()
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
    equal(state.opened, "id:Dyre's Quest Targeting")
end)

test("/dqt alone opens the settings, out of combat only; /dqt list lists", function()
    local state = fixture({quests = CONDOR_QUEST, focus = 101})
    state.slash("")
    equal(state.opened, "id:Dyre's Quest Targeting")
    state.opened = nil
    state.combat = true
    state.slash("")
    equal(state.opened, nil, "no panel in combat")
    contains(state.last(), "The settings open out of combat.")
    state.slash("list")
    equal(state.said("The macro looks for, most wanted first:"), true, "the list works in combat")
    state.combat = false
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
