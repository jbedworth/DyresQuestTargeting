local _, DQT = ...

-- Names for the focused (super-tracked) quest. The client gives each
-- objective's text, type, and progress, but no creature, item, or object IDs
-- (QuestObjectiveInfo in the pinned QuestLogDocumentation.lua). So a kill
-- objective's name comes from its text, and, when QuestieDB is loaded, from
-- QuestieDB's public API: the NPCs behind each kill objective, the mobs that
-- drop each quest item, and the NPC you turn the quest in to.
local DB_CONTRACT = 4
-- Mobs per quest item (the best droppers, when Questie knows drop rates)
-- and per shared kill objective; more would crowd the other objectives out
-- of the macro, which drops the least wanted names first when full.
local MAX_DROPPERS = 6
local MAX_KILL_CREDIT = 3
local MAX_TURN_IN = 2
-- QuestieDB objective lists by index (its Types/General.t.lua).
local DB_CREATURES, DB_ITEMS, DB_KILL_CREDIT = 1, 3, 5

-- QuestieDB's reads, or nil and the reason it cannot be used.
local function Database()
    local lib = _G.LibQuestieDB
    if type(lib) ~= "table" or type(lib.RequireContract) ~= "function" then
        return nil, "not loaded"
    end
    if not lib.RequireContract(DB_CONTRACT) then
        return nil, "installed, but it does not support contract " .. DB_CONTRACT .. "; update it"
    end
    local quest, npc, item = lib.Quest, lib.Npc, lib.Item
    if type(quest) ~= "table" or type(quest.objectives) ~= "function" or type(quest.finishedBy) ~= "function"
            or type(npc) ~= "table" or type(npc.name) ~= "function" or type(item) ~= "table"
            or type(item.name) ~= "function" or type(item.npcDrops) ~= "function" then
        return nil, "installed, but its reads are missing"
    end
    return {quest = quest, npc = npc, item = item}
end

-- Questie's tracker modules, through its loader; nil without Questie. An
-- unknown module comes back as an empty table, so callers check each function.
local function QuestieModule(name)
    local loader = _G.QuestieLoader
    if type(_G.Questie) ~= "table" or type(loader) ~= "table" or type(loader.ImportModule) ~= "function" then
        return nil
    end
    local module = loader:ImportModule(name)
    if type(module) == "table" then
        return module
    end
end

local function Contains(text, fragment)
    return type(fragment) == "string" and fragment ~= "" and text:lower():find(fragment:lower(), 1, true) ~= nil
end

-- "Dire Condor slain: 0/8" or "0/8 Dire Condor slain" to "Dire Condor".
-- English wording only; other text is kept as it is, which at worst targets nothing.
function DQT.ObjectiveName(text)
    if type(text) ~= "string" or DQT.IsSecret(text) then
        return nil
    end
    local name = text:gsub("^%s*%d+%s*/%s*%d+%s+", ""):gsub("%s*:%s*%d+%s*/%s*%d+%s*$", "")
    name = name:gsub("%s+slain$", ""):gsub("%s+killed$", "")
    return DQT.CheckName(name)
end

-- QuestieDB keeps some placeholder NPCs, such as "Shambling Skeleton UNUSED".
local function NpcName(db, id)
    local name = DQT.CheckName(db.npc.name(id))
    if name and not name:find("UNUSED", 1, true) then
        return name
    end
end

-- NPCs as {name, id}, up to limit.
local function Npcs(db, ids, limit)
    local npcs = {}
    if type(ids) ~= "table" then
        return npcs
    end
    for _, id in ipairs(ids) do
        local name = NpcName(db, id)
        if name then
            npcs[#npcs + 1] = {name = name, id = id}
            if #npcs >= limit then
                break
            end
        end
    end
    return npcs
end

local function NpcNames(db, ids, limit)
    local names = {}
    for _, npc in ipairs(Npcs(db, ids, limit)) do
        names[#names + 1] = npc.name
    end
    return names
end

-- npc.detail, when set, replaces detail for that one.
local function AddNpcs(group, npcs, source, detail)
    for _, npc in ipairs(npcs) do
        group[#group + 1] = {name = npc.name, id = npc.id, exact = true, source = source,
            detail = npc.detail or detail, rate = npc.rate, item = source == "drop" and detail or nil}
    end
end

-- The NPCs behind one kill objective: QuestieDB entries whose NPC name or
-- own text appears in the objective's text.
local function KillNames(db, entries, text)
    if not db or type(entries) ~= "table" then
        return {}
    end
    for _, entry in ipairs(entries[DB_CREATURES] or {}) do
        local name = NpcName(db, entry[1])
        if name and (Contains(text, name) or Contains(text, entry[2])) then
            return {{name = name, id = entry[1]}}
        end
    end
    for _, entry in ipairs(entries[DB_KILL_CREDIT] or {}) do
        local npcs = Npcs(db, entry[1], MAX_KILL_CREDIT)
        local matched = Contains(text, entry[3]) or Contains(text, db.npc.name(entry[2]))
        for _, npc in ipairs(npcs) do
            matched = matched or Contains(text, npc.name)
        end
        if matched and #npcs > 0 then
            return npcs
        end
    end
    return {}
end

-- A dropper's rate in percent from Questie (QuestieDB.GetItemDroprate, its
-- tooltip's "[12.3%]": a Questie correction, then private-server, then
-- Wowhead data; on Forever, Questie loads the Classic tables). Questie's own
-- code, not a public API; nil without Questie or without data.
local function DropRate(itemID, npcID)
    local questieDB = QuestieModule("QuestieDB")
    if not questieDB or type(questieDB.GetItemDroprate) ~= "function" then
        return nil
    end
    local data = questieDB.GetItemDroprate(itemID, npcID)
    local rate = type(data) == "table" and data[1]
    if type(rate) == "number" and rate ~= 0 then
        return math.abs(rate)
    end
end

-- An item's droppers, best first: by drop rate, then QuestieDB's order.
local function SortDroppers(itemID, itemName, npcs)
    for index, npc in ipairs(npcs) do
        npc.order = index
        npc.rate = DropRate(itemID, npc.id)
        if npc.rate then
            npc.detail = itemName .. ", " .. string.format("%.1f", npc.rate) .. "% drop rate"
        end
    end
    table.sort(npcs, function(a, b)
        if (a.rate or -1) ~= (b.rate or -1) then
            return (a.rate or -1) > (b.rate or -1)
        end
        return a.order < b.order
    end)
    return npcs
end

-- The best droppers of one item, ordered for the macro: the best last, so it
-- wins and is the last to be left out. Without rates, QuestieDB's order.
local function RankDroppers(itemID, itemName, npcs)
    SortDroppers(itemID, itemName, npcs)
    local best = {}
    for index = math.min(#npcs, MAX_DROPPERS), 1, -1 do
        best[#best + 1] = npcs[index]
    end
    return best
end

-- The mobs that drop one item objective's item, and the item's name.
local function DropNames(db, entries, text)
    if not db or type(entries) ~= "table" then
        return {}
    end
    for _, entry in ipairs(entries[DB_ITEMS] or {}) do
        local itemName = db.item.name(entry[1])
        if Contains(text, itemName) then
            return RankDroppers(entry[1], itemName, Npcs(db, db.item.npcDrops(entry[1]), math.huge)), itemName
        end
    end
    return {}
end

-- With onlyIndex, that one objective (Questie's objective focus).
local function ObjectiveTargets(db, questID, onlyIndex)
    local objectives = C_QuestLog.GetQuestObjectives(questID)
    local entries = db and db.quest.objectives(questID)
    local groups = {}
    for index, objective in ipairs(type(objectives) == "table" and objectives or {}) do
        local text = objective.text
        if not objective.finished and type(text) == "string" and not DQT.IsSecret(text)
                and (not onlyIndex or onlyIndex == index) then
            local group = {}
            if objective.type == "monster" then
                local npcs = KillNames(db, entries, text)
                local parsed = DQT.ObjectiveName(text)
                if #npcs == 0 and parsed then
                    npcs = {{name = parsed}}
                end
                AddNpcs(group, npcs, "kill", text)
            elseif objective.type == "item" then
                local npcs, itemName = DropNames(db, entries, text)
                AddNpcs(group, npcs, "drop", itemName)
            end
            groups[index] = group
        end
    end
    -- The first objective matters most, and the macro's last line wins.
    local targets = {}
    for index = table.maxn(groups), 1, -1 do
        for _, target in ipairs(groups[index] or {}) do
            targets[#targets + 1] = target
        end
    end
    return targets
end

-- Two focuses can be set (author-approved: read both): the game's
-- (super-tracking, from the quest log and map) and Questie's tracker focus,
-- its own per-character setting, a quest ID or "questID objectiveIndex"
-- (Questie's TrackerUtils.lua). The most recent change wins; at login,
-- Questie's, since Questie hides the game's quest tracker by default. Questie
-- fires no event, so its focus functions are hooked.
local QUESTIE_FOCUS_FUNCTIONS = {"FocusQuest", "FocusObjective", "UnFocus"}
-- While the world loads (login, /reload, a loading screen), the game restores
-- its focus and may fire SUPER_TRACKING_CHANGED; that is not you choosing it
-- (a guard; not confirmed in client). Changes count from this long after
-- PLAYER_ENTERING_WORLD.
local LOADING_GRACE = 2
local focusSource = "questie"
local loading = true
local lastGameID
-- A guide's step is a focus too (author-approved, 1.3.0): "zygor" or "rxp" when
-- that guide changed last, nil when a quest focus did. A guide step wins when
-- it names someone. At login either may ("login"), Zygor's first: Zygor
-- restores its step but does not set the game's focus then (found in client).
local guideFocus = "login"
local lastZygorKey
local lastRxpKey
-- The first step of a session is the one the guide restores, perhaps well
-- after login: TomTom is not pointed at it, so a waypoint of your own stays.
local restoring = {Zygor = true, RestedXP = true}
-- The side you changed last ("questie" or "game"), until SyncFocus copies it
-- to the other; and the quest both last agreed on.
local syncFrom
local syncedID

local function InLog(questID)
    return not DQT.IsSecret(questID) and type(questID) == "number" and questID > 0
        and DQT.QuestLogIndex(questID) ~= nil
end

-- The game's focus; none on a client without super-tracking.
local function GameFocus()
    if not DQT.HasGameFocus() then
        return nil
    end
    local questID = C_SuperTrack.GetSuperTrackedQuestID()
    if InLog(questID) then
        return questID
    end
end

-- Questie's focus: the quest ID and, for an objective focus, its index.
-- Without the game's focus, it is the only one, so "Follow Questie's tracker
-- focus" cannot turn it off.
local function QuestieFocus()
    if not DQT.db.questieFocus and DQT.HasGameFocus() then
        return nil
    end
    local questie = _G.Questie
    local char = type(questie) == "table" and type(questie.db) == "table" and questie.db.char
    local focus = type(char) == "table" and char.TrackerFocus
    local questID, objectiveIndex
    if type(focus) == "number" then
        questID = focus
    elseif type(focus) == "string" then
        local quest, objective = focus:match("^(%d+) (%d+)$")
        questID, objectiveIndex = tonumber(quest), tonumber(objective)
    end
    if InLog(questID) then
        return questID, objectiveIndex
    end
end

-- Zygor Guides Viewer's current step (ZygorGuidesViewer.lua: ZGV:FocusStep
-- sets ZGV.CurrentStep; its goals are CurrentStep.goals), and the sticky
-- steps it shows with it (ZGV.CurrentStickies). Zygor's private fields, not a
-- public API: each is checked, and without them DQT follows the quest focus.
local ZYGOR_MESSAGES = {"ZGV_STEP_CHANGED", "ZGV_GOAL_COMPLETED", "ZGV_GOAL_UNCOMPLETED", "ZGV_GOAL_PROGRESS",
    "ZGV_GUIDE_LOADED", "ZGV_STEP_WAYPOINT_CHANGED"}
-- Goal:GetStatus (Goal.lua). "passive" goals cannot complete on their own,
-- such as "kill Timber Wolf, Young Wolf" beside "collect 8 Tough Wolf Meat";
-- they count while their step is shown. Complete, hidden, impossible,
-- obsolete, and warning goals do not.
local ZYGOR_OPEN = {incomplete = true, passive = true}
-- Goals that name an NPC to talk to or click (Goal.lua sets goal.npc).
local ZYGOR_NPC_ACTIONS = {talk = true, clicknpc = true, accept = true, turnin = true}

local function Zygor()
    local zgv = _G.ZygorGuidesViewer
    if type(zgv) == "table" then
        return zgv
    end
end

function DQT.ZygorAvailable()
    local zgv = Zygor()
    return zgv ~= nil and type(zgv.AddMessageHandler) == "function"
end

local function ZygorStep()
    local zgv = Zygor()
    if not zgv or not DQT.db.zygorFocus then
        return nil
    end
    local step = zgv.CurrentStep
    if type(step) == "table" and type(step.goals) == "table" then
        return step, zgv
    end
end

local function ZygorKey(step, zgv)
    local guide = type(zgv.CurrentGuide) == "table" and zgv.CurrentGuide.title
    return tostring(guide) .. "#" .. tostring(step.num)
end

local function GoalOpen(goal)
    local status = goal.status
    if type(goal.GetStatus) == "function" then
        status = goal:GetStatus()
    end
    return ZYGOR_OPEN[status] == true
end

-- Zygor makes a plural name plural ("kill Kobold Vermin##6+"), so for that
-- one the name is QuestieDB's for its NPC ID, or none.
local function ZygorName(db, name, id, plural)
    if plural then
        name = db and type(id) == "number" and db.npc.name(id)
    end
    return DQT.CheckName(name)
end

-- One goal's names, as {name, id, source}.
local function GoalNames(db, goal)
    local names = {}
    local function Add(name, id, plural, source)
        name = ZygorName(db, name, id, plural)
        if name then
            names[#names + 1] = {name = name, id = type(id) == "number" and id or nil, source = source}
        end
    end
    if goal.action == "kill" then
        if type(goal.targets) == "table" and #goal.targets > 0 then
            for _, entry in ipairs(goal.targets) do
                if type(entry) == "table" then
                    Add(entry[1], entry[2], goal.plural, "kill")
                end
            end
        else
            Add(goal.target, goal.targetid, goal.plural, "kill")
        end
    end
    -- "from" lines, and "|from" on a collect line (Parser.lua: goal.mobs);
    -- "avoid" lists mobs to stay away from.
    if goal.action ~= "avoid" and type(goal.mobs) == "table" then
        for _, mob in ipairs(goal.mobs) do
            if type(mob) == "table" then
                Add(mob.name, mob.id, false, "kill")
            end
        end
    end
    if ZYGOR_NPC_ACTIONS[goal.action] then
        Add(goal.npc, goal.npcid, goal.plural, "talk")
    end
    return names
end

-- A step's names, least important first: its goals from last to first, so
-- the guide's first goal wins, as a quest's first objective does.
local function StepNames(db, step, names)
    for index = #step.goals, 1, -1 do
        local goal = step.goals[index]
        if type(goal) == "table" and GoalOpen(goal) then
            for _, entry in ipairs(GoalNames(db, goal)) do
                names[#names + 1] = entry
            end
        end
    end
end

-- The current step and the sticky steps shown with it.
local function ShownSteps()
    local step, zgv = ZygorStep()
    if not step then
        return {}
    end
    local steps = {}
    if type(zgv.CurrentStickies) == "table" then
        for _, sticky in ipairs(zgv.CurrentStickies) do
            if type(sticky) == "table" and sticky ~= step and type(sticky.goals) == "table" then
                steps[#steps + 1] = sticky
            end
        end
    end
    steps[#steps + 1] = step
    return steps
end

local function ZygorHasQuest(questID)
    for _, step in ipairs(ShownSteps()) do
        for _, goal in ipairs(step.goals) do
            if type(goal) == "table" and goal.questid == questID then
                return true
            end
        end
    end
    return false
end

-- RestedXP's active steps (GuideWindow.lua: RXPFrame.activeSteps, its sticky
-- steps first, then the current step, then perhaps a tip window). Found through
-- AceAddon: the global RXP is marked "debug purposes", and the global RXPGuides
-- is another table. RestedXP's private fields, not a public API: each is
-- checked, and without them DQT follows the quest focus.
local function Rxp()
    local stub = _G.LibStub
    if type(stub) ~= "table" or type(stub.GetLibrary) ~= "function" then
        return nil
    end
    local ace = stub:GetLibrary("AceAddon-3.0", true)
    if type(ace) ~= "table" or type(ace.GetAddon) ~= "function" then
        return nil
    end
    local addon = ace:GetAddon("RXPGuides", true)
    if type(addon) == "table" then
        return addon
    end
end

local function RxpActiveSteps(addon)
    local frame = addon and addon.RXPFrame
    local active = type(frame) == "table" and frame.activeSteps
    return type(active) == "table" and active or nil
end

function DQT.RxpAvailable()
    return RxpActiveSteps(Rxp()) ~= nil
end

-- The active steps that have elements, in RestedXP's order, and the current
-- one: the last with a step number. Only steps with a number count as current
-- (a tip window has none in the guide's list).
local function RxpSteps()
    local addon = DQT.db.rxpFocus and Rxp()
    local steps, current = {}, nil
    for _, step in ipairs(RxpActiveSteps(addon) or {}) do
        if type(step) == "table" and type(step.elements) == "table" then
            steps[#steps + 1] = step
            if type(step.index) == "number" then
                current = step
            end
        end
    end
    if current then
        return steps, current, addon
    end
    return {}
end

local function RxpKey(step, addon)
    local guide = type(addon.currentGuide) == "table" and addon.currentGuide.name
    return tostring(guide) .. "#" .. tostring(step.index)
end

local function CurrentRxpKey()
    local _, current, addon = RxpSteps()
    return current and RxpKey(current, addon)
end

-- The quests of the active steps (accept, turnin, and complete elements have
-- element.questId), the current step's first. Each once.
local function RxpQuests()
    local steps = RxpSteps()
    local quests, seen = {}, {}
    for index = #steps, 1, -1 do
        for _, element in ipairs(steps[index].elements) do
            local questID = type(element) == "table" and element.questId
            if type(questID) == "number" and not seen[questID] then
                seen[questID] = true
                quests[#quests + 1] = {id = questID, open = not element.completed and not element.skip}
            end
        end
    end
    return quests
end

-- SUPER_TRACKING_CHANGED: the game's focus wins only when you focus a
-- different quest; the event also fires for map pins and other changes. A
-- game focus on Questie's own quest keeps Questie's, so an objective focus
-- survives SyncFocus copying it to the game. A game focus on a quest of a
-- guide's shown steps changes nothing: the guide sets it itself, Zygor from
-- ZGV:TrackQuest, RestedXP from its complete and turnin tags, again and again.
local function GuideHasQuest(questID)
    if ZygorHasQuest(questID) then
        return true
    end
    for _, quest in ipairs(RxpQuests()) do
        if quest.id == questID then
            return true
        end
    end
    return false
end

function DQT.GameFocusChanged()
    local questID = GameFocus()
    if questID ~= lastGameID and questID and not loading and questID ~= QuestieFocus()
            and not GuideHasQuest(questID) then
        focusSource = "game"
        syncFrom = "game"
        guideFocus = nil
    end
    lastGameID = questID
end

local function CurrentZygorKey()
    local step, zgv = ZygorStep()
    return step and ZygorKey(step, zgv)
end

-- A Zygor message: a new step (not while the world loads) makes Zygor's the
-- latest focus; goal progress on the same step only rebuilds.
local function ZygorChanged()
    local key = CurrentZygorKey()
    if key and key ~= lastZygorKey and not loading then
        guideFocus = "zygor"
    end
    if key and lastZygorKey and key ~= lastZygorKey then
        restoring.Zygor = false
    end
    lastZygorKey = key or lastZygorKey
end

-- Zygor's messages (ZGV:AddMessageHandler calls handler(self, event, ...)).
-- Zygor calls its handlers unprotected, so this one only notes the change
-- and asks for a rebuild. Returns true when hooked.
function DQT.HookZygor(onChange)
    if not DQT.ZygorAvailable() then
        return false
    end
    local zgv = Zygor()
    for _, message in ipairs(ZYGOR_MESSAGES) do
        zgv:AddMessageHandler(message, function()
            ZygorChanged()
            onChange()
        end)
    end
    return true
end

-- A new current RestedXP step (not while the world loads) makes it the latest
-- focus. Read at each rebuild, so it does not matter which signal asked for it.
local function NoteRxpStep()
    local key = CurrentRxpKey()
    if key and key ~= lastRxpKey then
        if not loading then
            guideFocus = "rxp"
        end
        if lastRxpKey then
            restoring.RestedXP = false
        end
        lastRxpKey = key
    end
end

-- RestedXP runs UpdateUnitList when its target list changes (Targeting.lua).
-- Only asks for a rebuild. Its RXP_STEP_ messages would need AceEvent, which DQT
-- does not embed; this hook and the quest events are enough. Returns true when
-- hooked.
function DQT.HookRxp(onChange)
    local addon = Rxp()
    local targeting = addon and addon.targeting
    if type(hooksecurefunc) ~= "function" or type(targeting) ~= "table"
            or type(targeting.UpdateUnitList) ~= "function" then
        return false
    end
    hooksecurefunc(targeting, "UpdateUnitList", function() onChange() end)
    -- UpdateMap(true) rebuilds activeWaypoints, the arrow's list: a waypoint
    -- reached within a step ends here (UpdateGotoSteps only sets a flag for it).
    -- UpdateMap() alone sets that flag and changes nothing yet.
    if type(addon.UpdateMap) == "function" then
        hooksecurefunc(addon, "UpdateMap", function(resetPins)
            if resetPins and DQT.db.tomtom then
                onChange()
            end
        end)
    end
    return true
end

function DQT.WorldLoading()
    loading = true
end

function DQT.WorldEntered()
    C_Timer.After(LOADING_GRACE, function()
        loading = false
        lastGameID = GameFocus()
        lastZygorKey = CurrentZygorKey() or lastZygorKey
        lastRxpKey = CurrentRxpKey() or lastRxpKey
    end)
end

-- Questie's tracker focus can be followed: Questie and its TrackerUtils
-- focus functions are loaded.
function DQT.QuestieFocusAvailable()
    local loader = _G.QuestieLoader
    if type(loader) ~= "table" or type(loader.ImportModule) ~= "function" or type(_G.Questie) ~= "table" then
        return false
    end
    local utils = loader:ImportModule("TrackerUtils")
    return type(utils) == "table" and type(utils.FocusQuest) == "function"
end

-- Hooks Questie's focus changes, once Questie has loaded. Returns true when hooked.
function DQT.HookQuestieFocus(onChange)
    local loader = _G.QuestieLoader
    if type(hooksecurefunc) ~= "function" or type(loader) ~= "table" or type(loader.ImportModule) ~= "function"
            or type(_G.Questie) ~= "table" then
        return false
    end
    local utils = loader:ImportModule("TrackerUtils")
    local hooked = false
    for _, name in ipairs(QUESTIE_FOCUS_FUNCTIONS) do
        if type(utils) == "table" and type(utils[name]) == "function" then
            hooksecurefunc(utils, name, function()
                focusSource = "questie"
                syncFrom = "questie"
                guideFocus = nil
                onChange()
            end)
            hooked = true
        end
    end
    return hooked
end

local function ChooseFocus()
    local gameID = GameFocus()
    local questieID, objectiveIndex = QuestieFocus()
    if questieID and (focusSource == "questie" or not gameID) then
        return questieID, "Questie", objectiveIndex
    end
    if gameID then
        return gameID, "game"
    end
end

-- One line per name, at its most important place (the last), all /targetexact.
local function UniqueTargets(names)
    local targets, seen = {}, {}
    for index = #names, 1, -1 do
        local entry = names[index]
        local key = entry.name:lower()
        if not seen[key] then
            seen[key] = true
            table.insert(targets, 1, {name = entry.name, id = entry.id, exact = true, source = entry.source})
        end
    end
    return targets
end

-- Zygor's step as a focused "quest": the names of its open goals and of the
-- sticky steps shown with it (less important), all /targetexact. Its title is
-- the step's first open quest. Nil when the step names no one (a goto or a
-- text step), so the quest focus counts.
local function ZygorQuest(db)
    local step, zgv = ZygorStep()
    if not step then
        return nil
    end
    local names = {}
    for _, shown in ipairs(ShownSteps()) do
        StepNames(db, shown, names)
    end
    local targets = UniqueTargets(names)
    if #targets == 0 then
        return nil
    end
    -- logQuest: the step's first open quest in your log, the only real quest
    -- ID Questie's waypoint can take (id below is DQT's own key).
    local title, logQuest
    for _, goal in ipairs(step.goals) do
        if type(goal) == "table" and type(goal.questid) == "number" and GoalOpen(goal) then
            title = title or DQT.QuestTitle(goal.questid) or (type(goal.quest) == "string" and goal.quest or nil)
            logQuest = logQuest or (InLog(goal.questid) and goal.questid or nil)
        end
    end
    local guide = type(zgv.CurrentGuide) == "table" and zgv.CurrentGuide or {}
    local guideTitle = type(guide.title_short) == "string" and guide.title_short
        or type(guide.title) == "string" and guide.title or nil
    local stepText = "step " .. (type(step.num) == "number" and step.num or "?")
        .. (guideTitle and (" of " .. guideTitle) or "")
    return {
        id = "zygor " .. ZygorKey(step, zgv),
        via = "Zygor",
        title = title or ("Guide " .. stepText),
        logQuest = logQuest,
        stepText = stepText,
        complete = false,
        database = true,
        open = {},
        targets = targets,
    }
end

-- RestedXP's tag lists, as its UpdateUnitList reads them: unitscan and mobs are
-- enemies, targets friendly NPCs. A "+" tag's list is nil once its parent is
-- complete (functions.lua: UpdateTargets), so what is left is open; a tag
-- without "+" stays until its step ends. A bare ID RestedXP has not resolved
-- stays a number string: QuestieDB's name, or none.
local RXP_LISTS = {{"unitscan", "kill"}, {"mobs", "kill"}, {"targets", "talk"}}

local function RxpName(addon, db, raw)
    if type(raw) ~= "string" then
        return nil
    end
    local id = tonumber(raw)
    if id then
        return db and NpcName(db, id), id
    end
    local translated = type(addon.GetCreatureName) == "function" and addon.GetCreatureName(raw)
    return DQT.CheckName(type(translated) == "string" and translated or raw)
end

-- The tags name mobs but give no IDs, and TomTom's point needs one: the NPCs
-- QuestieDB knows for a quest (its objectives, their droppers, who starts and
-- finishes it), by lower-case name. Its data does not change, so kept per quest.
local rxpQuestNpcs = {}

local function QuestNpcs(db, questID)
    local known = rxpQuestNpcs[questID]
    if known then
        return known
    end
    known = {}
    local function Add(ids)
        for _, npc in ipairs(Npcs(db, ids, math.huge)) do
            known[npc.name:lower()] = known[npc.name:lower()] or npc.id
        end
    end
    local entries = db.quest.objectives(questID)
    if type(entries) == "table" then
        for _, entry in ipairs(entries[DB_CREATURES] or {}) do
            Add({entry[1]})
        end
        for _, entry in ipairs(entries[DB_KILL_CREDIT] or {}) do
            Add(entry[1])
        end
        for _, entry in ipairs(entries[DB_ITEMS] or {}) do
            Add(db.item.npcDrops(entry[1]))
        end
    end
    local readers = {db.quest.startedBy, db.quest.finishedBy}
    for index = 1, 2 do
        local people = type(readers[index]) == "function" and readers[index](questID)
        if type(people) == "table" then
            Add(people[1])
        end
    end
    rxpQuestNpcs[questID] = known
    return known
end

-- RestedXP's steps as a focused "quest": the names on its active steps, the
-- current step's last, its elements from last to first. Nil when no one is named.
local function RxpQuest(db)
    local steps, current, addon = RxpSteps()
    if not current then
        return nil
    end
    local names = {}
    -- The current step wins over a sticky step or tip window after it.
    local ordered = {}
    for _, step in ipairs(steps) do
        if step ~= current then
            ordered[#ordered + 1] = step
        end
    end
    ordered[#ordered + 1] = current
    for _, step in ipairs(ordered) do
        for index = #step.elements, 1, -1 do
            local element = step.elements[index]
            for _, list in ipairs(type(element) == "table" and RXP_LISTS or {}) do
                local tags = element[list[1]]
                for _, raw in ipairs(type(tags) == "table" and tags or {}) do
                    local name, id = RxpName(addon, db, raw)
                    if name then
                        names[#names + 1] = {name = name, id = id, source = list[2]}
                    end
                end
            end
        end
    end
    local targets = UniqueTargets(names)
    if #targets == 0 then
        return nil
    end
    local quests = RxpQuests()
    for _, target in ipairs(db and targets or {}) do
        for _, quest in ipairs(target.id and {} or quests) do
            target.id = target.id or QuestNpcs(db, quest.id)[target.name:lower()]
        end
    end
    -- The title is the current step's first open quest; RxpQuests lists those first.
    local title, logQuest
    for _, quest in ipairs(quests) do
        if quest.open then
            title = title or DQT.QuestTitle(quest.id)
            logQuest = logQuest or (InLog(quest.id) and quest.id or nil)
        end
    end
    local guide = type(addon.currentGuide) == "table" and addon.currentGuide or {}
    local guideName = type(guide.displayName) == "string" and guide.displayName
        or type(guide.name) == "string" and guide.name or nil
    local stepText = "step " .. current.index .. (guideName and (" of " .. guideName) or "")
    return {
        id = "rxp " .. RxpKey(current, addon),
        via = "RestedXP",
        title = title or ("Guide " .. stepText),
        logQuest = logQuest,
        stepText = stepText,
        complete = false,
        database = true,
        open = {},
        targets = targets,
    }
end

-- The focused quest and its targets, ordered least to most important, or nil.
function DQT.FocusedQuest()
    local db = Database()
    NoteRxpStep()
    if guideFocus == "zygor" or guideFocus == "login" then
        local zygor = ZygorQuest(db)
        if zygor then
            return zygor
        end
    end
    if guideFocus == "rxp" or guideFocus == "login" then
        local rxp = RxpQuest(db)
        if rxp then
            return rxp
        end
    end
    local questID, via, objectiveIndex = ChooseFocus()
    if not questID then
        return nil
    end
    local quest = {
        id = questID,
        via = via,
        objective = objectiveIndex,
        title = DQT.QuestTitle(questID) or ("quest " .. questID),
        complete = DQT.QuestComplete(questID),
        database = db ~= nil,
        targets = {},
    }
    -- Unfinished objectives by index, for the TomTom waypoint.
    local open = {}
    local objectives = C_QuestLog.GetQuestObjectives(questID)
    for index, objective in ipairs(type(objectives) == "table" and objectives or {}) do
        if not objective.finished then
            open[#open + 1] = index
        end
    end
    quest.open = open
    local focused = objectiveIndex and type(objectives) == "table" and objectives[objectiveIndex]
    if type(focused) == "table" and type(focused.text) == "string" and focused.text ~= "" then
        quest.objectiveText = focused.text
    end
    if quest.complete then
        local finishers = db and db.quest.finishedBy(questID)
        if type(finishers) == "table" then
            AddNpcs(quest.targets, Npcs(db, finishers[1], MAX_TURN_IN), "turnin")
        end
    else
        quest.targets = ObjectiveTargets(db, questID, objectiveIndex)
    end
    return quest
end

-- Questie's tracker menu calls this after a focus change (TrackerMenu.lua):
-- it fades the other quests' map icons.
local function QuestieNotes()
    local notes = QuestieModule("QuestieQuest")
    if notes and type(notes.ToggleNotes) == "function" then
        notes:ToggleNotes(false)
    end
end

-- "Keep Questie's and the game's focus in sync" (db.syncFocus, author-
-- approved): copies the focus you changed last to the other side. Questie's
-- focus is set as its tracker menu sets it (TrackerUtils:FocusQuest, then
-- QuestieQuest:ToggleNotes), which is Questie's private code, not a public
-- API. The game has no objective focus, so a Questie objective focus gives
-- the game its quest. Unfocusing in Questie clears the game's focus when it
-- is still the synced quest.
function DQT.SyncFocus()
    local from = syncFrom
    syncFrom = nil
    local questieID = QuestieFocus()
    local gameID = GameFocus()
    if from and DQT.db.syncFocus and DQT.db.questieFocus and DQT.HasGameFocus() then
        local utils = QuestieModule("TrackerUtils")
        if not utils or type(C_SuperTrack.SetSuperTrackedQuestID) ~= "function" then
            return
        end
        if from == "questie" and questieID and questieID ~= gameID then
            C_SuperTrack.SetSuperTrackedQuestID(questieID)
        elseif from == "questie" and not questieID and gameID and gameID == syncedID then
            C_SuperTrack.SetSuperTrackedQuestID(0)
        elseif from == "game" and gameID and gameID ~= questieID and type(utils.FocusQuest) == "function" then
            if utils:FocusQuest(gameID) then
                QuestieNotes()
            end
        end
        questieID, gameID = QuestieFocus(), GameFocus()
    end
    if questieID and questieID == gameID then
        syncedID = questieID
    end
end

-- "Point TomTom at the focused quest" (db.tomtom, author-approved): what
-- Questie's tracker menu does for "Set TomTom Target", done for you. A quest
-- focus points at the nearest spawn of any unfinished objective, or at the
-- turn-in once the quest is complete (TrackerUtils.SetQuestTomTomTarget); an
-- objective focus at that objective's nearest spawn (DistanceUtils and
-- TrackerUtils:SetTomTomTarget, as the objective menu does). Needs Questie
-- (its spawn data and its private functions) and TomTom. Pointed again when
-- the focus changes, an objective is finished, or the quest is complete; not
-- at login, so a waypoint of your own stays. While the quest is not complete,
-- it points at the nearest spawn of the quest mobs the macro lists (author-
-- approved: Questie's own target can be a dropper the macro leaves out), and
-- falls back to Questie's choice when none has spawn data. A guide step
-- (author, 1.3.0: the guides set no TomTom waypoint, so an old one stayed)
-- with a location points there; else as above, at its mobs and NPCs; with no
-- spawn data, at its first open quest in your log; with none, the waypoint stays.
local lastWaypointKey
-- Without Questie, the waypoint DQT last set; with it, Questie's own field holds
-- it, so whichever sets the next one removes the last.
local ownWaypoint

-- A guide step's own location (author, 1.3.0: "if sync is enabled and the active
-- step has a location, we use it"), chosen as that guide's arrow chooses, so
-- TomTom's arrow goes where the guide's goes. Zygor: the step's current
-- waypoint goal, else the next it can point at (Step:CycleWaypoint); goal.map is
-- a map ID, goal.x and goal.y are 0 to 1.
local function ZygorGoalUsable(goal)
    if type(goal) ~= "table" or type(goal.map) ~= "number" or type(goal.x) ~= "number" or type(goal.y) ~= "number"
            or goal.force_noway or goal.action == "mapmarker" then
        return false
    end
    return type(goal.IsVisible) ~= "function" or goal:IsVisible() == true
end

local function ZygorLocation()
    local step, zgv = ZygorStep()
    if not step then
        return nil
    end
    local start = type(step.current_waypoint_goal_num) == "number" and step.current_waypoint_goal_num or 1
    for index = start, #step.goals do
        local goal = step.goals[index]
        if ZygorGoalUsable(goal) then
            return {
                via = "Zygor",
                step = ZygorKey(step, zgv),
                title = "Zygor: step " .. tostring(step.num),
                map = goal.map,
                x = goal.x,
                y = goal.y,
            }
        end
    end
end

-- RestedXP: as updateArrowData (map.lua), the first element of
-- addon.activeWaypoints that the arrow may take, a low-priority one only when
-- no other is left. activeWaypoints lists the active steps in RestedXP's order,
-- so a sticky step's location comes first, as on its arrow. An element's x and
-- y are 0 to 100 in the map element.zone. A ".goto" with radius 0 has no
-- element.arrow unless a fifth value makes it low priority (functions.lua).
local function RxpWaypointUsable(element)
    if type(element) ~= "table" or element.hidden or element.skip or type(element.step) ~= "table"
            or not element.step.active or type(element.zone) ~= "number" or type(element.x) ~= "number"
            or type(element.y) ~= "number" then
        return false
    end
    local parent = element.parent
    if type(parent) == "table" and (parent.completed or parent.skip) then
        return false
    end
    if type(element.generated) == "number" and element.generated % 2 == 1 then
        return true
    end
    return element.arrow and not (element.text and element.completed) and true or false
end

local function RxpLocation()
    local _, current, addon = RxpSteps()
    local waypoints = addon and addon.activeWaypoints
    if not current or type(waypoints) ~= "table" then
        return nil
    end
    local chosen
    for _, element in ipairs(waypoints) do
        if RxpWaypointUsable(element) then
            if not element.lowPrio then
                chosen = element
                break
            end
            chosen = chosen or element
        end
    end
    if chosen then
        return {
            via = "RestedXP",
            step = RxpKey(current, addon),
            title = "RestedXP: step " .. tostring(current.index),
            map = chosen.zone,
            x = chosen.x / 100,
            y = chosen.y / 100,
        }
    end
end

-- The latest guide's location, or nil. It counts while that guide is the latest
-- focus, also on a step that names no one (a travel step), when the macro
-- follows the quest focus.
local function GuideLocation()
    local location
    if guideFocus == "zygor" or guideFocus == "login" then
        location = ZygorLocation()
    end
    if not location and (guideFocus == "rxp" or guideFocus == "login") then
        location = RxpLocation()
    end
    return location
end

-- RestedXP's list is empty until its first UpdateMap(true), after login.
local function RxpMapPending()
    local addon = Rxp()
    local waypoints = addon and addon.activeWaypoints
    return type(waypoints) == "table" and #waypoints == 0
end

-- Through TomTom itself: Questie's SetTomTomTarget takes an area ID, and turning
-- a map ID into one can raise an error (ZoneDB:GetAreaIdByUiMapId). False when
-- TomTom lacks the call, so the old path counts.
local function PointAtLocation(location)
    local tomtom = _G.TomTom
    if type(tomtom.AddWaypoint) ~= "function" then
        return false
    end
    local questie = _G.Questie
    local char = type(questie) == "table" and type(questie.db) == "table" and questie.db.char
    char = type(char) == "table" and char or nil
    local old = ownWaypoint
    if char then
        old = char._tom_waypoint
    end
    if type(old) == "table" and type(tomtom.RemoveWaypoint) == "function" then
        tomtom:RemoveWaypoint(old)
    end
    -- Without Questie nothing remembers the waypoint across a /reload, so it is
    -- not saved; it would stay on the map for good.
    local options = {title = location.title, crazy = true, from = "DyresQuestTargeting"}
    if not char then
        options.persistent = false
    end
    local waypoint = tomtom:AddWaypoint(location.map, location.x, location.y, options)
    if char then
        char._tom_waypoint = waypoint
    else
        ownWaypoint = waypoint
    end
    return true
end

local function MacroNpcIDs(kept)
    local ids = {}
    for _, target in ipairs(kept or {}) do
        if target.id and (target.source == "kill" or target.source == "drop" or target.source == "talk") then
            ids[#ids + 1] = target.id
        end
    end
    return ids
end

local function WaypointKey(quest, kept)
    return quest.id .. " " .. tostring(quest.objective) .. " " .. tostring(quest.complete) .. " "
        .. table.concat(quest.open, ",") .. " " .. table.concat(MacroNpcIDs(kept), ",")
end

-- The nearest spawn of the macro's quest mobs, as Questie measures it
-- (QuestieDB:GetNPC spawns, DistanceUtils.GetNearestSpawn).
local function MacroWaypoint(utils, kept)
    local questieDB, distance = QuestieModule("QuestieDB"), QuestieModule("DistanceUtils")
    if not (questieDB and distance and type(questieDB.GetNPC) == "function"
            and type(distance.GetNearestSpawn) == "function" and type(utils.SetTomTomTarget) == "function") then
        return false
    end
    local best
    for _, id in ipairs(MacroNpcIDs(kept)) do
        local npc = questieDB:GetNPC(id)
        if type(npc) == "table" and type(npc.spawns) == "table" then
            local spawn, zone, howFar = distance.GetNearestSpawn(npc.spawns)
            if type(spawn) == "table" and type(howFar) == "number" and (not best or howFar < best.howFar) then
                best = {spawn = spawn, zone = zone, howFar = howFar, name = npc.name}
            end
        end
    end
    if not best then
        return false
    end
    utils:SetTomTomTarget(best.name, best.zone, best.spawn[1], best.spawn[2])
    return true
end

local function ObjectiveWaypoint(utils, quest)
    local questieDB, distance = QuestieModule("QuestieDB"), QuestieModule("DistanceUtils")
    if not (questieDB and distance and type(questieDB.GetQuest) == "function"
            and type(distance.GetNearestObjective) == "function" and type(utils.SetTomTomTarget) == "function") then
        return false
    end
    local data = questieDB.GetQuest(quest.id)
    local objective = type(data) == "table" and type(data.Objectives) == "table" and data.Objectives[quest.objective]
    if type(objective) ~= "table" then
        return false
    end
    local spawn, zone, name = distance.GetNearestObjective(objective.spawnList)
    if type(spawn) ~= "table" then
        return false
    end
    utils:SetTomTomTarget(name, zone, spawn[1], spawn[2])
    return true
end

local function IsOpen(quest, index)
    for _, open in ipairs(quest.open) do
        if open == index then
            return true
        end
    end
    return false
end

-- kept: the macro's targets. force: point now, even if nothing changed (the
-- setting was just turned on).
function DQT.PointTomTom(quest, kept, force)
    local location = GuideLocation()
    if not quest and not location then
        return
    end
    local via = location and location.via or quest.via
    local key
    if location then
        key = "guide " .. location.step .. " " .. location.map .. " " .. location.x .. "," .. location.y
    else
        key = WaypointKey(quest, kept)
    end
    local first = lastWaypointKey == nil
    if restoring[via] ~= nil then
        first = restoring[via]
        -- Not yet while RestedXP's list is empty: its location appears a moment
        -- after login, and that is not a change.
        if via ~= "RestedXP" or not RxpMapPending() then
            restoring[via] = false
        end
    end
    if key == lastWaypointKey and not force then
        return
    end
    lastWaypointKey = key
    if (first and not force) or not DQT.db.tomtom or type(_G.TomTom) ~= "table" then
        return
    end
    if location and PointAtLocation(location) then
        return
    end
    local utils = QuestieModule("TrackerUtils")
    if not utils or not quest then
        return
    end
    if not quest.complete and MacroWaypoint(utils, kept) then
        return
    end
    if quest.objective and not quest.complete and IsOpen(quest, quest.objective)
            and ObjectiveWaypoint(utils, quest) then
        return
    end
    -- A guide step's id is DQT's own key; only its logQuest is a real quest.
    local questID = quest.id
    if restoring[quest.via] ~= nil then
        questID = quest.logQuest
    end
    if questID and type(utils.SetQuestTomTomTarget) == "function" then
        utils.SetQuestTomTomTarget(questID)
    end
end

function DQT.ReportQuestDebug()
    local db, reason = Database()
    DQT.Report("debug QuestieDB: " .. (db and "loaded" or reason))
    local questieID, questieObjective = QuestieFocus()
    local gameFocus = DQT.HasGameFocus() and DQT.Describe(C_SuperTrack.GetSuperTrackedQuestID()) or "none on this client"
    DQT.Report("debug game focus=" .. gameFocus .. " Questie focus="
        .. tostring(questieID) .. (questieObjective and (" objective " .. questieObjective) or "")
        .. " latest=" .. focusSource .. " followQuestie=" .. tostring(DQT.db.questieFocus))
    local step, zgv = ZygorStep()
    DQT.Report("debug Zygor: " .. (not Zygor() and "not loaded" or not DQT.db.zygorFocus and "not followed"
        or not step and "no step" or ("step " .. ZygorKey(step, zgv))) .. " guide latest=" .. tostring(guideFocus))
    local rxpSteps, rxpCurrent, rxp = RxpSteps()
    DQT.Report("debug RestedXP: " .. (not Rxp() and "not loaded" or not DQT.db.rxpFocus and "not followed"
        or not rxpCurrent and "no step" or ("step " .. RxpKey(rxpCurrent, rxp) .. ", " .. #rxpSteps .. " active")))
    local location = GuideLocation()
    DQT.Report("debug guide location: " .. (location and (location.title .. " map " .. location.map .. " "
        .. location.x .. "," .. location.y) or "none"))
    local questID = ChooseFocus()
    if not questID then
        return
    end
    local logIndex = DQT.QuestLogIndex(questID)
    local complete = DQT.QuestComplete(questID)
    DQT.Report("debug logIndex=" .. DQT.Describe(logIndex) .. " complete=" .. DQT.Describe(complete)
        .. " title=" .. DQT.Describe(DQT.QuestTitle(questID)))
    local objectives = C_QuestLog.GetQuestObjectives(questID)
    for index, objective in ipairs(type(objectives) == "table" and objectives or {}) do
        DQT.Report(string.format("debug objective %d type=%s finished=%s %s/%s text=%s", index,
            DQT.Describe(objective.type), DQT.Describe(objective.finished), DQT.Describe(objective.numFulfilled),
            DQT.Describe(objective.numRequired), DQT.Describe(objective.text)))
    end
    if db then
        local entries = db.quest.objectives(questID)
        if type(entries) == "table" then
            for _, entry in ipairs(entries[DB_CREATURES] or {}) do
                DQT.Report("debug QuestieDB kill npc=" .. DQT.Describe(entry[1]) .. " "
                    .. DQT.Describe(db.npc.name(entry[1])))
            end
            for _, entry in ipairs(entries[DB_ITEMS] or {}) do
                -- Every dropper, best first, with Questie's drop rate when it has
                -- one, so droppers past the macro's limit show too.
                local itemName = db.item.name(entry[1])
                local npcs = SortDroppers(entry[1], tostring(itemName),
                    Npcs(db, db.item.npcDrops(entry[1]), math.huge))
                local names = {}
                for _, npc in ipairs(npcs) do
                    names[#names + 1] = npc.name
                        .. (npc.rate and (" " .. string.format("%.1f", npc.rate) .. "%") or "")
                end
                DQT.Report("debug QuestieDB item=" .. DQT.Describe(entry[1]) .. " "
                    .. DQT.Describe(db.item.name(entry[1])) .. " dropped by " .. table.concat(names, ", ")
                    .. " (" .. #names .. "; the macro uses the best " .. MAX_DROPPERS .. ")")
            end
            for _, entry in ipairs(entries[DB_KILL_CREDIT] or {}) do
                DQT.Report("debug QuestieDB shared kill: "
                    .. table.concat(NpcNames(db, entry[1], MAX_KILL_CREDIT), ", "))
            end
        end
        local finishers = db.quest.finishedBy(questID)
        if type(finishers) == "table" then
            DQT.Report("debug QuestieDB turn-in: "
                .. table.concat(NpcNames(db, finishers[1], MAX_TURN_IN), ", "))
        end
    end
end
