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
-- The side you changed last ("questie" or "game"), until SyncFocus copies it
-- to the other; and the quest both last agreed on.
local syncFrom
local syncedID

local function InLog(questID)
    return not DQT.IsSecret(questID) and type(questID) == "number" and questID > 0
        and C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
end

local function GameFocus()
    local questID = C_SuperTrack.GetSuperTrackedQuestID()
    if InLog(questID) then
        return questID
    end
end

-- Questie's focus: the quest ID and, for an objective focus, its index.
local function QuestieFocus()
    if not DQT.db.questieFocus then
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

-- SUPER_TRACKING_CHANGED: the game's focus wins only when you focus a
-- different quest; the event also fires for map pins and other changes. A
-- game focus on Questie's own quest keeps Questie's, so an objective focus
-- survives SyncFocus copying it to the game.
function DQT.GameFocusChanged()
    local questID = GameFocus()
    if questID ~= lastGameID and questID and not loading and questID ~= QuestieFocus() then
        focusSource = "game"
        syncFrom = "game"
    end
    lastGameID = questID
end

function DQT.WorldLoading()
    loading = true
end

function DQT.WorldEntered()
    C_Timer.After(LOADING_GRACE, function()
        loading = false
        lastGameID = GameFocus()
    end)
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

-- The focused quest and its targets, ordered least to most important, or nil.
function DQT.FocusedQuest()
    local questID, via, objectiveIndex = ChooseFocus()
    if not questID then
        return nil
    end
    local db = Database()
    local quest = {
        id = questID,
        via = via,
        objective = objectiveIndex,
        title = C_QuestLog.GetTitleForQuestID(questID) or ("quest " .. questID),
        complete = C_QuestLog.IsComplete(questID) == true,
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
    if from and DQT.db.syncFocus and DQT.db.questieFocus then
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
-- falls back to Questie's choice when none has spawn data.
local lastWaypointKey

local function MacroNpcIDs(kept)
    local ids = {}
    for _, target in ipairs(kept or {}) do
        if target.id and (target.source == "kill" or target.source == "drop") then
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
    if not quest then
        return
    end
    local key = WaypointKey(quest, kept)
    local first = lastWaypointKey == nil
    if key == lastWaypointKey and not force then
        return
    end
    lastWaypointKey = key
    if (first and not force) or not DQT.db.tomtom or type(_G.TomTom) ~= "table" then
        return
    end
    local utils = QuestieModule("TrackerUtils")
    if not utils then
        return
    end
    if not quest.complete and MacroWaypoint(utils, kept) then
        return
    end
    if quest.objective and not quest.complete and IsOpen(quest, quest.objective)
            and ObjectiveWaypoint(utils, quest) then
        return
    end
    if type(utils.SetQuestTomTomTarget) == "function" then
        utils.SetQuestTomTomTarget(quest.id)
    end
end

function DQT.ReportQuestDebug()
    local db, reason = Database()
    DQT.Report("debug QuestieDB: " .. (db and "loaded" or reason))
    local questieID, questieObjective = QuestieFocus()
    DQT.Report("debug game focus=" .. DQT.Describe(C_SuperTrack.GetSuperTrackedQuestID()) .. " Questie focus="
        .. tostring(questieID) .. (questieObjective and (" objective " .. questieObjective) or "")
        .. " latest=" .. focusSource .. " followQuestie=" .. tostring(DQT.db.questieFocus))
    local questID = ChooseFocus()
    if not questID then
        return
    end
    local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
    local complete = C_QuestLog.IsComplete(questID)
    DQT.Report("debug logIndex=" .. DQT.Describe(logIndex) .. " complete=" .. DQT.Describe(complete)
        .. " title=" .. DQT.Describe(C_QuestLog.GetTitleForQuestID(questID)))
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
