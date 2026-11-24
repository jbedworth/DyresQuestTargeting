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
-- A rare mob comes first by default (author: "I always go for the rarer mobs
-- first"). QuestieDB gives no order for a quest's objectives, only the quest's
-- own; but each NPC has a rank (Enum.npcRanks, cmangos creature_template: 2 rare
-- elite, 3 boss, 4 rare) and its spawn points ({[zone] = {{x, y}, ...}}). A
-- named mob with one spawn, such as a quest's leader, is rare in the same way.
local RARE_RANKS = {[2] = true, [3] = true, [4] = true}
local RARE_SPAWN_POINTS = 3

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

-- The client's formats for objective text, in its language, most specific first:
-- "%s slain: %d/%d" (Classic), "%2$d/%3$d %1$s slain" (mainline enUS),
-- "%1$s : %2$d/%3$d |4personnage tué:personnages tués;" (mainline frFR).
local OBJECTIVE_FORMATS = {"QUEST_MONSTERS_KILLED", "QUEST_OBJECTS_FOUND"}
-- French puts a no-break space (UTF-8 C2 A0) before ":"; it counts as a space.
local NO_BREAK_SPACE = "\194\160"
local SPACE = "%s*"
local formatPatterns = {}

local function LiteralPattern(text)
    local pattern = ""
    for word, gap in text:gsub(NO_BREAK_SPACE, " "):gmatch("(%S*)(%s*)") do
        pattern = pattern .. word:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. (gap ~= "" and SPACE or "")
    end
    return pattern
end

-- Lua patterns for one format, the name (argument 1) captured. "|4one:many;"
-- picks a word by number, so each word gives its own pattern.
local function FormatPatterns(format)
    local patterns = formatPatterns[format]
    if patterns then
        return patterns
    end
    patterns = {}
    local first, last, words = format:find("|4([^;]*);")
    if first then
        for word in (words .. ":"):gmatch("([^:]*):") do
            for _, each in ipairs(FormatPatterns(format:sub(1, first - 1) .. word .. format:sub(last + 1))) do
                patterns[#patterns + 1] = each
            end
        end
    else
        local pattern, position, nextArgument, named = "", 1, 1, false
        while position <= #format do
            local from, to, index, kind = format:find("%%(%d*)%$?([sd])", position)
            if not from then
                from, to = #format + 1, #format
            end
            pattern = pattern .. LiteralPattern(format:sub(position, from - 1))
            if kind then
                local argument = tonumber(index) or nextArgument
                nextArgument = argument + 1
                if kind == "d" then
                    pattern = pattern .. "%d+"
                elseif argument == 1 and not named then
                    pattern, named = pattern .. "(.-)", true
                else
                    pattern = pattern .. ".-"
                end
            end
            position = to + 1
        end
        if named then
            patterns[1] = "^" .. SPACE .. pattern .. SPACE .. "$"
        end
    end
    formatPatterns[format] = patterns
    return patterns
end

-- The client's own format, as in "Dire Condor slain: 0/8", "0/8 Dire Condor
-- slain", or "Condor : 0/8 personnages tués", gives "Dire Condor".
local function FormattedName(text)
    text = text:gsub(NO_BREAK_SPACE, " ")
    for _, key in ipairs(OBJECTIVE_FORMATS) do
        local format = _G[key]
        if type(format) == "string" then
            for _, pattern in ipairs(FormatPatterns(format)) do
                local name = text:match(pattern)
                if name and name ~= "" then
                    return name
                end
            end
        end
    end
end

-- Without the client's formats, or text in none of them: the English wording
-- is stripped; other text is kept as it is, which at worst targets nothing.
function DQT.ObjectiveName(text)
    if type(text) ~= "string" or DQT.IsSecret(text) then
        return nil
    end
    local formatted = FormattedName(text)
    if formatted then
        return DQT.CheckName(formatted)
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

-- Rare by QuestieDB's rank or spawn points (an NPC with none known is not).
local function IsRare(db, id)
    if not db or type(id) ~= "number" then
        return false
    end
    local rank = type(db.npc.rank) == "function" and db.npc.rank(id)
    if type(rank) == "number" and RARE_RANKS[rank] then
        return true
    end
    local spawns = type(db.npc.spawns) == "function" and db.npc.spawns(id)
    local points = 0
    for _, zone in pairs(type(spawns) == "table" and spawns or {}) do
        points = points + (type(zone) == "table" and #zone or 0)
    end
    return points > 0 and points <= RARE_SPAWN_POINTS
end

-- "Smart targeting mode" (db.smartOrder, author-approved, default on), most wanted
-- first: 1, rare or named mobs; 2, the mobs that drop the quest's items, by drop
-- rate, highest first (no known rate after them); 3, the mobs to kill; 4, anything
-- else. Ties keep the quest's own order. Off: the quest's own order, each item's
-- droppers by rate. A player's drag in the box wins over both (ApplyTargetOrder).
local SMART_RARE, SMART_DROP, SMART_KILL, SMART_OTHER = 1, 2, 3, 4

-- Targets, most wanted first, in the quest's own order: the objectives in order,
-- and each objective's targets (kept least wanted first) from its last.
local function QuestOrder(groups)
    local list = {}
    for index = 1, table.maxn(groups) do
        local group = groups[index] or {}
        for position = #group, 1, -1 do
            list[#list + 1] = group[position]
        end
    end
    return list
end

local function SmartOrder(db, list)
    local class, place = {}, {}
    for index, target in ipairs(list) do
        place[target] = index
        if IsRare(db, target.id) then
            class[target] = SMART_RARE
        elseif target.source == "drop" then
            class[target] = SMART_DROP
        elseif target.source == "kill" then
            class[target] = SMART_KILL
        else
            class[target] = SMART_OTHER
        end
    end
    table.sort(list, function(a, b)
        if class[a] ~= class[b] then
            return class[a] < class[b]
        end
        if class[a] == SMART_DROP and (a.rate or -1) ~= (b.rate or -1) then
            return (a.rate or -1) > (b.rate or -1)
        end
        return place[a] < place[b]
    end)
    return list
end

-- A guide step keeps its guide's order, but in smart mode its rare or named mobs
-- go first (author, 1.7.1). targets: least wanted first, as the macro lists them.
local function RareFirst(db, targets)
    if not (db and DQT.db and DQT.db.smartOrder) then
        return targets
    end
    local ordered, rares = {}, {}
    for _, target in ipairs(targets) do
        if IsRare(db, target.id) then
            rares[#rares + 1] = target
        else
            ordered[#ordered + 1] = target
        end
    end
    for _, target in ipairs(rares) do
        ordered[#ordered + 1] = target
    end
    return ordered
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
    local wanted = QuestOrder(groups)
    if DQT.db and DQT.db.smartOrder then
        SmartOrder(db, wanted)
    end
    -- The macro's last line wins, so the most wanted target goes last.
    local targets = {}
    for index = #wanted, 1, -1 do
        targets[#targets + 1] = wanted[index]
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
-- A guide's step is a focus too (author-approved, 1.3.0): "zygor", "rxp", "oxp", or
-- "qtr" when that guide changed last, nil when a quest focus did. A guide step wins
-- when it names someone. At login any may ("login"), Zygor's first: Zygor
-- restores its step but does not set the game's focus then (found in client).
local guideFocus = "login"
local lastZygorKey
local lastRxpKeys = {}
local lastQtrKey
-- The first step of a session is the one the guide restores, perhaps well
-- after login: TomTom is not pointed at it, so a waypoint of your own stays.
local restoring = {Zygor = true, RestedXP = true, OpenXP = true, QuestTrail = true}
-- The side you changed last ("questie" or "game"), until SyncFocus copies it
-- to the other; and the quest both last agreed on.
local syncFrom
local syncedID
-- With a guide chosen as the active guide (db.activeGuide), a Questie or game focus
-- change is decided at the next rebuild, not at once: the game focuses a quest you
-- accept when nothing else is focused (QuestUtil.CheckAutoSuperTrackQuest, from
-- Blizzard_QuestSuperTracking.lua's QUEST_ACCEPTED handler), and Questie's "Follow
-- Blizzard Super Tracking" then focuses it in its tracker, in the same frame, perhaps
-- before DQT sees QUEST_ACCEPTED. A change this close to QUEST_ACCEPTED is that
-- automatic focus, not yours (author-approved: about 1 s; the source shows 0 s).
local AUTO_FOCUS_WINDOW = 1
local pendingFocus
local acceptedAt
-- The chosen guide's step whose quest DQT last focused in Questie's tracker.
local pushedKey

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

-- RestedXP's step engine, in RestedXP itself and in OpenXP (author-approved, 1.8.0),
-- a fork of RestedXP (its NOTICE.md) that keeps the engine and every field DQT reads
-- under its own AceAddon name. Each is its own guide: its own setting, step, and
-- "Active guide" choice. In login order.
local RXP_ENGINES = {
    rxp = {ace = "RXPGuides", via = "RestedXP", setting = "rxpFocus"},
    oxp = {ace = "OpenXP", via = "OpenXP", setting = "oxpFocus"},
}
local RXP_ORDER = {"rxp", "oxp"}

-- An engine's active steps (GuideWindow.lua: RXPFrame.activeSteps, its sticky
-- steps first, then the current step, then perhaps a tip window). Found through
-- AceAddon: RestedXP's global RXP is marked "debug purposes", and the global
-- RXPGuides is another table. Private fields, not a public API: each is
-- checked, and without them DQT follows the quest focus.
local function Rxp(engine)
    local stub = _G.LibStub
    if type(stub) ~= "table" or type(stub.GetLibrary) ~= "function" then
        return nil
    end
    local ace = stub:GetLibrary("AceAddon-3.0", true)
    if type(ace) ~= "table" or type(ace.GetAddon) ~= "function" then
        return nil
    end
    local addon = ace:GetAddon(RXP_ENGINES[engine].ace, true)
    if type(addon) == "table" then
        return addon
    end
end

local function RxpActiveSteps(addon)
    local frame = addon and addon.RXPFrame
    local active = type(frame) == "table" and frame.activeSteps
    return type(active) == "table" and active or nil
end

-- RestedXP ("rxp", the default) or OpenXP ("oxp") is loaded with its step engine.
function DQT.RxpAvailable(engine)
    return RxpActiveSteps(Rxp(engine or "rxp")) ~= nil
end

function DQT.OxpAvailable()
    return DQT.RxpAvailable("oxp")
end

-- The active steps that have elements, in the engine's order, and the current
-- one: the last with a step number. Only steps with a number count as current
-- (a tip window has none in the guide's list).
local function RxpSteps(engine)
    local addon = DQT.db[RXP_ENGINES[engine].setting] and Rxp(engine)
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

local function CurrentRxpKey(engine)
    local _, current, addon = RxpSteps(engine)
    return current and RxpKey(current, addon)
end

-- The quests of the active steps (accept, turnin, and complete elements have
-- element.questId), the current step's first. Each once.
local function RxpQuests(engine)
    local steps = RxpSteps(engine)
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

-- QuestTrail's plan step (author-approved, 1.4.1; source verified in QuestTrail
-- 4.2.0): its compass's target, ns.Arrow.current, with a kind, a quest (q), and
-- perhaps an objective (oi). QuestTrail gives its modules its namespace through
-- LibStub("QuestTrail-Modules").ns (Core/QuestTrail_API.lua); private fields,
-- not a public API: each is checked, and without them DQT follows the quest focus.
-- Other kinds (the hearthstone, the map pin, a corpse) are not quest steps.
local QTR_STEP_TEXT = {start = "take step", dropstart = "take step", progress = "objective step",
    finish = "turn-in step"}
-- QuestTrail's functions that set or move on its target (Planner/QuestTrail_Planner.lua and
-- _Compass.lua): SavePlan runs after each new plan sets it; Focus.Set when the plan's quest
-- changes. Not its update, which runs 20 times a second.
local QTR_HOOKS = {"SavePlan", "Advance", "AdvanceDone", "FocusNow", "Skip", "ResetRoute", "RestorePlan"}

local function QuestTrail()
    local stub = _G.LibStub
    if type(stub) ~= "table" or type(stub.GetLibrary) ~= "function" then
        return nil
    end
    local hub = stub:GetLibrary("QuestTrail-Modules", true)
    local ns = type(hub) == "table" and hub.ns
    if type(ns) == "table" and type(ns.Arrow) == "table" then
        return ns
    end
end

function DQT.QuestTrailAvailable()
    return QuestTrail() ~= nil
end

local function QtrStep()
    local ns = DQT.db.qtrFocus and QuestTrail()
    local step = ns and ns.Arrow.current
    if type(step) == "table" and QTR_STEP_TEXT[step.kind] and not DQT.IsSecret(step.q) and type(step.q) == "number"
            and step.q > 0 then
        return step
    end
end

local function QtrKey(step)
    return step.kind .. ":" .. step.q .. ":" .. tostring(type(step.oi) == "number" and step.oi or "")
end

local function CurrentQtrKey()
    local step = QtrStep()
    return step and QtrKey(step)
end

local GUIDE_NAMES = {zygor = "Zygor", rxp = "RestedXP", oxp = "OpenXP", qtr = "QuestTrail"}

-- A choice of "Active guide" is offered while its AddOn is installed and followed.
function DQT.ActiveGuideOn(key)
    local db = DQT.db
    if key == "recent" then
        return true
    elseif key == "questie" then
        return DQT.QuestieFocusAvailable() and (db.questieFocus or not DQT.HasGameFocus())
    elseif key == "zygor" then
        return DQT.ZygorAvailable() and db.zygorFocus
    elseif RXP_ENGINES[key] then
        return DQT.RxpAvailable(key) and db[RXP_ENGINES[key].setting]
    elseif key == "qtr" then
        return DQT.QuestTrailAvailable() and db.qtrFocus
    end
    return false
end

-- The choice in effect: a saved choice whose AddOn is missing or not followed
-- counts as "recent" (its saved value stays).
function DQT.ActiveGuide()
    local key = DQT.db.activeGuide
    if key ~= "recent" and DQT.ActiveGuideOn(key) then
        return key
    end
    return "recent"
end

-- The chosen guide (Zygor, RestedXP, OpenXP, or QuestTrail), or nil.
local function ChosenGuide()
    local key = DQT.ActiveGuide()
    return GUIDE_NAMES[key] and key or nil
end

-- A guide's step can drive DQT: with "recent", any guide's; with a guide chosen, only
-- that guide's; with Questie chosen, none.
local function GuideAllowed(name)
    local key = DQT.ActiveGuide()
    return key == "recent" or key == name
end

-- That guide's step counts now: it changed last (or it is login), and it may drive.
local function GuideCounts(name)
    return (guideFocus == name or guideFocus == "login") and GuideAllowed(name)
end

function DQT.QuestAccepted()
    acceptedAt = GetTime()
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
    for _, engine in ipairs(RXP_ORDER) do
        for _, quest in ipairs(RxpQuests(engine)) do
            if quest.id == questID then
                return true
            end
        end
    end
    -- QuestTrail sets the game's focus to its step's quest (ns.Focus.Set).
    local step = QtrStep()
    return step ~= nil and step.q == questID
end

function DQT.GameFocusChanged()
    local questID = GameFocus()
    if questID ~= lastGameID and questID and not loading and questID ~= QuestieFocus()
            and not GuideHasQuest(questID) then
        focusSource = "game"
        syncFrom = "game"
        if ChosenGuide() then
            pendingFocus = {at = GetTime(), source = "game"}
        else
            guideFocus = nil
        end
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
    if key and key ~= lastZygorKey and not loading and GuideAllowed("zygor") then
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

-- A new current RestedXP or OpenXP step (not while the world loads) makes it the
-- latest focus: the newest step of any guide wins (author, 1.8.0), unless another
-- guide is chosen as the active guide. Read at each rebuild, so it does not matter
-- which signal asked for it.
local function NoteRxpStep(engine)
    local key = CurrentRxpKey(engine)
    local last = lastRxpKeys[engine]
    if key and key ~= last then
        if not loading and GuideAllowed(engine) then
            guideFocus = engine
        end
        if last then
            restoring[RXP_ENGINES[engine].via] = false
        end
        lastRxpKeys[engine] = key
    end
end

-- A new QuestTrail step (not while the world loads) makes it the latest focus.
local function NoteQtrStep()
    local key = CurrentQtrKey()
    if key and key ~= lastQtrKey then
        if not loading and GuideAllowed("qtr") then
            guideFocus = "qtr"
        end
        if lastQtrKey then
            restoring.QuestTrail = false
        end
        lastQtrKey = key
    end
end

-- Only asks for a rebuild. Returns true when hooked.
function DQT.HookQuestTrail(onChange)
    local ns = QuestTrail()
    if type(hooksecurefunc) ~= "function" or not ns then
        return false
    end
    local hooked = false
    for _, name in ipairs(QTR_HOOKS) do
        if type(ns.Arrow[name]) == "function" then
            hooksecurefunc(ns.Arrow, name, function() onChange() end)
            hooked = true
        end
    end
    if type(ns.Focus) == "table" and type(ns.Focus.Set) == "function" then
        hooksecurefunc(ns.Focus, "Set", function() onChange() end)
        hooked = true
    end
    return hooked
end

-- RestedXP and OpenXP run UpdateUnitList when their target list changes
-- (Targeting.lua). Only asks for a rebuild. Their RXP_STEP_ messages would need
-- AceEvent, which DQT does not embed; this hook and the quest events are enough.
-- Returns true when either is hooked.
local function HookEngine(engine, onChange)
    local addon = Rxp(engine)
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

function DQT.HookRxp(onChange)
    local hooked = false
    for _, engine in ipairs(RXP_ORDER) do
        hooked = HookEngine(engine, onChange) or hooked
    end
    return hooked
end

function DQT.WorldLoading()
    loading = true
end

function DQT.WorldEntered()
    C_Timer.After(LOADING_GRACE, function()
        loading = false
        lastGameID = GameFocus()
        lastZygorKey = CurrentZygorKey() or lastZygorKey
        for _, engine in ipairs(RXP_ORDER) do
            lastRxpKeys[engine] = CurrentRxpKey(engine) or lastRxpKeys[engine]
        end
        lastQtrKey = CurrentQtrKey() or lastQtrKey
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
                if ChosenGuide() then
                    pendingFocus = {at = GetTime(), source = "questie", loading = loading}
                else
                    guideFocus = nil
                end
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
-- sticky steps shown with it (more important, the first sticky most; author,
-- 1.7.1: "Sticky steps should be higher priority"), all /targetexact. Its title is
-- the step's first open quest. Nil when the step names no one (a goto or a
-- text step), so the quest focus counts.
local function ZygorQuest(db)
    local step, zgv = ZygorStep()
    if not step then
        return nil
    end
    local names = {}
    local shown = ShownSteps()
    for index = #shown, 1, -1 do
        StepNames(db, shown[index], names)
    end
    local targets = RareFirst(db, UniqueTargets(names))
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

-- RestedXP's steps as a focused "quest": the names on its active steps, each
-- step's elements from last to first. The sticky steps (before the current one in
-- activeSteps) win over the current step, the first sticky most (author, 1.7.1);
-- a tip window (after it) wins over nothing. Nil when no one is named.
local function RxpQuest(db, engine)
    local steps, current, addon = RxpSteps(engine)
    if not current then
        return nil
    end
    local names = {}
    local place
    for index, step in ipairs(steps) do
        if step == current then
            place = index
        end
    end
    local ordered = {}
    for index = #steps, place, -1 do
        ordered[#ordered + 1] = steps[index]
    end
    for index = place - 1, 1, -1 do
        ordered[#ordered + 1] = steps[index]
    end
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
    local quests = RxpQuests(engine)
    for _, target in ipairs(db and targets or {}) do
        for _, quest in ipairs(target.id and {} or quests) do
            target.id = target.id or QuestNpcs(db, quest.id)[target.name:lower()]
        end
    end
    targets = RareFirst(db, targets)
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
        id = engine .. " " .. RxpKey(current, addon),
        via = RXP_ENGINES[engine].via,
        title = title or ("Guide " .. stepText),
        logQuest = logQuest,
        stepText = stepText,
        complete = false,
        database = true,
        open = {},
        targets = targets,
    }
end

-- QuestTrail's "on the way" (Planner/QuestTrail_OnTheWay.lua, A.onTheWay, made with
-- each plan): objectives of quests in your log whose camps the plan's walk crosses, to
-- kill in passing, as {q, i (objective index), full, ...}, all on the route first. Their
-- targets, less important than the step's (author: a player asked for them; they were
-- adding them to the hit list by hand). The fully crossed ones are wanted more.
local function OnTheWayTargets(db, ns)
    local targets = {}
    local list = ns.Arrow.onTheWay
    if type(list) ~= "table" then
        return targets
    end
    for index = #list, 1, -1 do
        local entry = list[index]
        local questID = type(entry) == "table" and entry.q
        if not DQT.IsSecret(questID) and InLog(questID) and type(entry.i) == "number" then
            for _, target in ipairs(ObjectiveTargets(db, questID, entry.i)) do
                targets[#targets + 1] = target
            end
        end
    end
    return targets
end

-- QuestTrail's step as a focused "quest": an objective step targets that objective
-- (or every open one), a turn-in step the turn-in, a take step who gives the quest
-- (QuestieDB's startedBy), and for a quest an item starts, that item's droppers; and
-- before them, its "on the way" objectives. Nil when it names no one, so the quest
-- focus counts.
local function QtrQuest(db)
    local step = QtrStep()
    if not step then
        return nil
    end
    local ns = QuestTrail()
    local questID = step.q
    local targets = {}
    if step.kind == "progress" then
        if not InLog(questID) then
            return nil
        end
        targets = ObjectiveTargets(db, questID, type(step.oi) == "number" and step.oi or nil)
        if #targets == 0 then
            return nil
        end
    elseif step.kind == "finish" then
        local finishers = db and db.quest.finishedBy(questID)
        if type(finishers) == "table" then
            AddNpcs(targets, Npcs(db, finishers[1], MAX_TURN_IN), "turnin")
        end
    else
        local starters = db and type(db.quest.startedBy) == "function" and db.quest.startedBy(questID)
        if type(starters) == "table" then
            for _, item in ipairs(type(starters[3]) == "table" and starters[3] or {}) do
                AddNpcs(targets, Npcs(db, db.item.npcDrops(item), MAX_DROPPERS), "drop", DQT.CheckName(db.item.name(item)))
            end
            AddNpcs(targets, Npcs(db, starters[1], MAX_TURN_IN), "talk")
        end
    end
    if #targets == 0 then
        return nil
    end
    -- A name in both keeps its place as the step's: BuildMacro keeps each name once,
    -- at its most important place.
    local passing = OnTheWayTargets(db, ns)
    for _, target in ipairs(targets) do
        passing[#passing + 1] = target
    end
    targets = RareFirst(db, passing)
    local named = db and type(db.quest.name) == "function" and db.quest.name(questID)
    return {
        id = "qtr " .. QtrKey(step),
        via = "QuestTrail",
        title = DQT.QuestTitle(questID) or DQT.CheckName(named) or ("quest " .. questID),
        logQuest = InLog(questID) and questID or nil,
        stepText = QTR_STEP_TEXT[step.kind],
        complete = step.kind == "finish",
        database = db ~= nil,
        open = {},
        targets = targets,
    }
end

-- A Questie or game focus change made while a guide is chosen (author-approved): yours
-- wins until the guide's next step or a re-sync; Questie restoring its focus while the
-- world loads, the game's and Questie's automatic focus on a quest you accept, a focus
-- on a quest of a guide's step (the guides, and DQT, set it), and an unfocus do not.
-- The automatic focus is undone: the guide's quest goes back to Questie's tracker.
local function DecidePendingFocus()
    local change = pendingFocus
    pendingFocus = nil
    local guide = ChosenGuide()
    if not change then
        return
    end
    if not guide then
        guideFocus = nil
        return
    end
    if change.loading then
        return
    end
    if acceptedAt and math.abs(change.at - acceptedAt) <= AUTO_FOCUS_WINDOW then
        syncFrom = nil
        if guideFocus == guide or guideFocus == "login" then
            pushedKey = nil
        end
        return
    end
    local questID
    if change.source == "questie" then
        questID = QuestieFocus()
    else
        questID = GameFocus()
    end
    if questID and not GuideHasQuest(questID) then
        guideFocus = nil
    end
end

-- The focused quest and its targets, ordered least to most important, or nil.
local function BuildFocusedQuest()
    local db = Database()
    for _, engine in ipairs(RXP_ORDER) do
        NoteRxpStep(engine)
    end
    NoteQtrStep()
    DecidePendingFocus()
    if GuideCounts("zygor") then
        local zygor = ZygorQuest(db)
        if zygor then
            return zygor
        end
    end
    for _, engine in ipairs(RXP_ORDER) do
        local rxp = GuideCounts(engine) and RxpQuest(db, engine)
        if rxp then
            return rxp
        end
    end
    if GuideCounts("qtr") then
        local qtr = QtrQuest(db)
        if qtr then
            return qtr
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

-- The key a player's order is saved under: the quest ID, or a guide step's own key.
function DQT.TargetOrderKey(quest)
    return type(quest) == "table" and quest.id ~= nil and tostring(quest.id) or nil
end

-- A player's order for this quest (author: drag the target rows, "allowing the user
-- to set whatever order they want"; it wins over the default and the loot-first
-- setting). db.targetOrder[key] lists names most wanted first; those go last, in
-- that order, and names it does not list keep their place before them.
local function ApplyTargetOrder(quest)
    local key = DQT.TargetOrderKey(quest)
    local order = key and DQT.db and DQT.db.targetOrder[key]
    if not order then
        return quest
    end
    local rank = {}
    for index, name in ipairs(order) do
        rank[name:lower()] = rank[name:lower()] or index
    end
    local unlisted, listed = {}, {}
    for index, target in ipairs(quest.targets) do
        target.listIndex = index
        if rank[target.name:lower()] then
            listed[#listed + 1] = target
        else
            unlisted[#unlisted + 1] = target
        end
    end
    table.sort(listed, function(a, b)
        local rankA, rankB = rank[a.name:lower()], rank[b.name:lower()]
        if rankA ~= rankB then
            return rankA > rankB
        end
        return a.listIndex < b.listIndex
    end)
    for _, target in ipairs(listed) do
        unlisted[#unlisted + 1] = target
    end
    quest.targets = unlisted
    return quest
end

function DQT.FocusedQuest()
    local quest = BuildFocusedQuest()
    return quest and ApplyTargetOrder(quest)
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
-- The chosen guide's current step, as its own key.
local function GuideKey(guide)
    if guide == "zygor" then
        return CurrentZygorKey()
    elseif RXP_ENGINES[guide] then
        return CurrentRxpKey(guide)
    elseif guide == "qtr" then
        return CurrentQtrKey()
    end
end

-- With a guide chosen (author-approved): each new step of it, while it drives DQT,
-- focuses the step's quest in your log in Questie's tracker, as its tracker menu does.
-- Questie's FocusQuest also sets the game's focus (Questie 12.9.0, TrackerUtils.lua),
-- so both agree. Not without Questie, and not for a step with no quest in your log.
local function DriveQuestie(quest)
    local guide = ChosenGuide()
    if not guide or not GuideCounts(guide) or type(quest) ~= "table" or quest.via ~= GUIDE_NAMES[guide] then
        return
    end
    local key = GuideKey(guide)
    local questID = quest.logQuest
    if not key or key == pushedKey or not questID then
        return
    end
    pushedKey = key
    local utils = DQT.QuestieFocusAvailable() and QuestieModule("TrackerUtils")
    if not utils or (questID == QuestieFocus() and questID == (GameFocus() or questID)) then
        return
    end
    if utils:FocusQuest(questID) then
        QuestieNotes()
    end
end

-- Re-sync is offered while a guide is chosen (the box's button, /dqt resync, and a key
-- binding).
function DQT.ResyncAvailable()
    return ChosenGuide() ~= nil
end

-- Back to the chosen guide's current step: the macro follows it, and its quest goes to
-- Questie's tracker again. No message from SelectGuide.
local function BackToGuide(guide)
    guideFocus = guide
    pendingFocus = nil
    pushedKey = nil
    DQT.Refresh()
end

function DQT.Resync()
    local guide = ChosenGuide()
    if not guide then
        DQT.Report("Re-sync needs an active guide: choose Zygor, RestedXP, OpenXP, or QuestTrail under \"Active guide\" "
            .. "in the settings (/dqt).")
        return
    end
    BackToGuide(guide)
    DQT.Report("Re-synced with " .. GUIDE_NAMES[guide] .. "'s current step."
        .. (InCombatLockdown() and " The macro updates after combat." or ""))
end

-- The "Active guide" setting. Choosing a guide puts it in charge at once; choosing
-- Questie hands the macro to the quest focus.
function DQT.SelectGuide(key)
    if not DQT.ACTIVE_GUIDE_LABELS[key] then
        return
    end
    DQT.db.activeGuide = key
    local guide = ChosenGuide()
    if guide then
        BackToGuide(guide)
        return
    end
    if key == "questie" then
        guideFocus = nil
    end
    pendingFocus = nil
    DQT.Refresh()
end

function DQT.SyncFocus(quest)
    DriveQuestie(quest)
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

-- RestedXP and OpenXP: as updateArrowData (map.lua), the first element of
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

local function RxpLocation(engine)
    local _, current, addon = RxpSteps(engine)
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
            via = RXP_ENGINES[engine].via,
            step = RxpKey(current, addon),
            title = RXP_ENGINES[engine].via .. ": step " .. tostring(current.index),
            map = chosen.zone,
            x = chosen.x / 100,
            y = chosen.y / 100,
        }
    end
end

-- QuestTrail: its compass's target, where the plan sent you (ax, ay; its marker
-- tour moves mx, my from there), on the map cm, 0 to 1.
local function QtrLocation()
    local step = QtrStep()
    if not step then
        return nil
    end
    local x = type(step.ax) == "number" and step.ax or step.mx
    local y = type(step.ay) == "number" and step.ay or step.my
    if type(step.cm) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    return {
        via = "QuestTrail",
        step = QtrKey(step),
        title = "QuestTrail: " .. (DQT.QuestTitle(step.q) or ("quest " .. step.q)),
        map = step.cm,
        x = x,
        y = y,
    }
end

-- The latest guide's location, or nil. It counts while that guide is the latest
-- focus, also on a step that names no one (a travel step), when the macro
-- follows the quest focus.
local function GuideLocation()
    local location
    if GuideCounts("zygor") then
        location = ZygorLocation()
    end
    for _, engine in ipairs(RXP_ORDER) do
        if not location and GuideCounts(engine) then
            location = RxpLocation(engine)
        end
    end
    if not location and GuideCounts("qtr") then
        location = QtrLocation()
    end
    return location
end

-- RestedXP's (or OpenXP's) list is empty until its first UpdateMap(true), after
-- login. via: the engine's name.
local function RxpMapPending(via)
    local engine
    for key, entry in pairs(RXP_ENGINES) do
        if entry.via == via then
            engine = key
        end
    end
    if not engine then
        return false
    end
    local addon = Rxp(engine)
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
    -- QuestTrail follows every TomTom waypoint as its own map pin, and its plan waits
    -- (Planner/QuestTrail_Way.lua); it leaves a silent one alone.
    local options = {title = location.title, crazy = true, from = "DyresQuestTargeting",
        silent = QuestTrail() and true or nil}
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

-- A point from Questie's spawn data (an area ID, x and y 0 to 100): through Questie,
-- or, with QuestTrail loaded, silently through TomTom (Questie's call is not silent).
local function SetTarget(utils, name, zone, x, y)
    if not QuestTrail() then
        utils:SetTomTomTarget(name, zone, x, y)
        return true
    end
    local zones = QuestieModule("ZoneDB")
    local map = zones and type(zones.GetUiMapIdByAreaId) == "function" and zones:GetUiMapIdByAreaId(zone)
    if type(map) ~= "number" then
        return false
    end
    return PointAtLocation({map = map, x = x / 100, y = y / 100, title = name})
end

-- A quest's nearest objective or turn-in, as Questie's "Set TomTom Target"
-- (TrackerUtils.SetQuestTomTomTarget); with QuestTrail loaded, its same steps here.
local function QuestTarget(utils, questID)
    if not QuestTrail() then
        if type(utils.SetQuestTomTomTarget) == "function" then
            utils.SetQuestTomTomTarget(questID)
        end
        return
    end
    local questieDB, distance = QuestieModule("QuestieDB"), QuestieModule("DistanceUtils")
    if not (questieDB and distance and type(questieDB.GetQuest) == "function"
            and type(distance.GetNearestSpawnForQuest) == "function") then
        return
    end
    local data = questieDB.GetQuest(questID)
    if type(data) ~= "table" then
        return
    end
    local spawn, zone, name = distance.GetNearestSpawnForQuest(data)
    if type(spawn) == "table" then
        SetTarget(utils, name, zone, spawn[1], spawn[2])
    end
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
    return SetTarget(utils, best.name, best.zone, best.spawn[1], best.spawn[2])
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
    return SetTarget(utils, name, zone, spawn[1], spawn[2])
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
        -- Not yet while RestedXP's (or OpenXP's) list is empty: its location
        -- appears a moment after login, and that is not a change.
        if not RxpMapPending(via) then
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
    if questID then
        QuestTarget(utils, questID)
    end
end

function DQT.ReportQuestDebug()
    local db, reason = Database()
    DQT.Report("debug QuestieDB: " .. (db and "loaded" or reason))
    -- The client's language, and the one QuestieDB gives names in (its
    -- LibQuestieDB.l10n, private: shown only, type-checked).
    local locale
    if type(GetLocale) == "function" then
        locale = GetLocale()
    end
    local l10n = type(_G.LibQuestieDB) == "table" and _G.LibQuestieDB.l10n
    local names = "no translation layer (English names)"
    if type(l10n) == "table" and type(l10n.currentLocale) == "string" then
        local available = type(l10n.IsAvailable) == "function" and l10n.IsAvailable()
        names = l10n.currentLocale .. (available and "" or " (no translations loaded: English names)")
    end
    DQT.Report("debug client locale=" .. (locale ~= nil and DQT.Describe(locale) or "unknown") .. " QuestieDB names=" .. (db and names or "none"))
    local questieID, questieObjective = QuestieFocus()
    local gameFocus = DQT.HasGameFocus() and DQT.Describe(C_SuperTrack.GetSuperTrackedQuestID()) or "none on this client"
    DQT.Report("debug game focus=" .. gameFocus .. " Questie focus="
        .. tostring(questieID) .. (questieObjective and (" objective " .. questieObjective) or "")
        .. " latest=" .. focusSource .. " followQuestie=" .. tostring(DQT.db.questieFocus))
    DQT.Report("debug active guide=" .. DQT.ActiveGuide() .. " (saved " .. tostring(DQT.db.activeGuide)
        .. ") pushed step=" .. tostring(pushedKey))
    local step, zgv = ZygorStep()
    DQT.Report("debug Zygor: " .. (not Zygor() and "not loaded" or not DQT.db.zygorFocus and "not followed"
        or not step and "no step" or ("step " .. ZygorKey(step, zgv))) .. " guide latest=" .. tostring(guideFocus))
    for _, engine in ipairs(RXP_ORDER) do
        local entry = RXP_ENGINES[engine]
        local rxpSteps, rxpCurrent, rxp = RxpSteps(engine)
        DQT.Report("debug " .. entry.via .. ": " .. (not Rxp(engine) and "not loaded"
            or not DQT.db[entry.setting] and "not followed" or not rxpCurrent and "no step"
            or ("step " .. RxpKey(rxpCurrent, rxp) .. ", " .. #rxpSteps .. " active")))
    end
    local qtrStep = QtrStep()
    DQT.Report("debug QuestTrail: " .. (not QuestTrail() and "not loaded" or not DQT.db.qtrFocus and "not followed"
        or not qtrStep and "no quest step" or ("step " .. QtrKey(qtrStep))))
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
