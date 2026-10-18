local _, DQT = ...

-- Names for the focused (super-tracked) quest. The client gives each
-- objective's text, type, and progress, but no creature, item, or object IDs
-- (QuestObjectiveInfo in the pinned QuestLogDocumentation.lua). So a kill
-- objective's name comes from its text, and, when QuestieDB is loaded, from
-- QuestieDB's public API: the NPCs behind each kill objective, the mobs that
-- drop each quest item, and the NPC you turn the quest in to.
local DB_CONTRACT = 4
-- Mobs per quest item and per shared kill objective; more would crowd the
-- other objectives out of the macro.
local MAX_DROPPERS = 3
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

local function NpcNames(db, ids, limit)
    local names = {}
    if type(ids) ~= "table" then
        return names
    end
    for _, id in ipairs(ids) do
        local name = DQT.CheckName(db.npc.name(id))
        if name then
            names[#names + 1] = name
            if #names >= limit then
                break
            end
        end
    end
    return names
end

local function AddNames(group, names, source, detail)
    for _, name in ipairs(names) do
        group[#group + 1] = {name = name, exact = true, source = source, detail = detail}
    end
end

-- The NPCs behind one kill objective: QuestieDB entries whose NPC name or
-- own text appears in the objective's text.
local function KillNames(db, entries, text)
    if not db or type(entries) ~= "table" then
        return {}
    end
    for _, entry in ipairs(entries[DB_CREATURES] or {}) do
        local name = DQT.CheckName(db.npc.name(entry[1]))
        if name and (Contains(text, name) or Contains(text, entry[2])) then
            return {name}
        end
    end
    for _, entry in ipairs(entries[DB_KILL_CREDIT] or {}) do
        local names = NpcNames(db, entry[1], MAX_KILL_CREDIT)
        local matched = Contains(text, entry[3]) or Contains(text, db.npc.name(entry[2]))
        for _, name in ipairs(names) do
            matched = matched or Contains(text, name)
        end
        if matched and #names > 0 then
            return names
        end
    end
    return {}
end

-- The mobs that drop one item objective's item, and the item's name.
local function DropNames(db, entries, text)
    if not db or type(entries) ~= "table" then
        return {}
    end
    for _, entry in ipairs(entries[DB_ITEMS] or {}) do
        local itemName = db.item.name(entry[1])
        if Contains(text, itemName) then
            return NpcNames(db, db.item.npcDrops(entry[1]), MAX_DROPPERS), itemName
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
                local names = KillNames(db, entries, text)
                local parsed = DQT.ObjectiveName(text)
                if #names == 0 and parsed then
                    names = {parsed}
                end
                AddNames(group, names, "kill", text)
            elseif objective.type == "item" then
                local names, itemName = DropNames(db, entries, text)
                AddNames(group, names, "drop", itemName)
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
-- different quest; the event also fires for map pins and other changes.
function DQT.GameFocusChanged()
    local questID = GameFocus()
    if questID ~= lastGameID and questID and not loading then
        focusSource = "game"
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
    if quest.complete then
        local finishers = db and db.quest.finishedBy(questID)
        if type(finishers) == "table" then
            AddNames(quest.targets, NpcNames(db, finishers[1], MAX_TURN_IN), "turnin")
        end
    else
        quest.targets = ObjectiveTargets(db, questID, objectiveIndex)
    end
    return quest
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
                local names = NpcNames(db, db.item.npcDrops(entry[1]), MAX_DROPPERS)
                DQT.Report("debug QuestieDB item=" .. DQT.Describe(entry[1]) .. " "
                    .. DQT.Describe(db.item.name(entry[1])) .. " dropped by " .. table.concat(names, ", "))
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
