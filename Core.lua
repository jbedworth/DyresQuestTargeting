local addonName, DQT = ...

-- Dyre's Quest Targeting: keeps the character macro "! Quest Targets" up to
-- date with the mobs and NPCs your focused quest needs, plus names you add.
-- This file owns saved settings, the login banner, install and API checks,
-- slash conflict reporting, the hit list, refresh scheduling, and startup.
local DEFAULT_TITLE = "Dyre's Quest Targeting"
local READY_MESSAGE = "  Ready. Put the \"! Quest Targets\" macro on a bar; /dqt lists what it targets."
local SLASH_KEY = "DYRESQUESTTARGETING"
local PRIMARY_SLASH = "/dqt"
local BACKUP_SLASH = "/questtargeting"
local MAX_SLASH_ALIASES = 10
-- Quest events come in bursts (QUEST_LOG_UPDATE fires several times a
-- second while you fight); one rebuild covers each burst.
local REFRESH_DELAY = 0.2
-- The hit list: names you add (db.added). Far more than the macro can hold;
-- a name past this drops the oldest.
DQT.MAX_ADDED = 20
DQT.MARKER_MIN, DQT.MARKER_MAX = 0, 8
DQT.DEFAULT_MOB_MARKER = 8
DQT.DEFAULT_NPC_MARKER = 4
DQT.available = false

function DQT.Report(message)
    DEFAULT_CHAT_FRAME:AddMessage("DQT: " .. tostring(message))
end

function DQT.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) == true
end

-- Text for diagnostics that never touches a secret value's contents.
function DQT.Describe(value)
    if DQT.IsSecret(value) then
        return "secret"
    end
    return tostring(value)
end

-- Reads TOC fields so the banner follows the packaged version; never gates operations.
local function Metadata(field)
    if type(C_AddOns) ~= "table" or type(C_AddOns.GetAddOnMetadata) ~= "function" then
        return nil
    end
    local value = C_AddOns.GetAddOnMetadata(addonName, field)
    if type(value) == "string" and value:find("%S") then
        return value
    end
end

local function ReportLoaded(available)
    local banner = Metadata("Title") or DEFAULT_TITLE
    local version, author = Metadata("Version"), Metadata("Author")
    if version then
        banner = banner .. " " .. version
    end
    if author then
        banner = banner .. " by " .. author
    end
    DQT.Report(banner)
    if available then
        DQT.Report(READY_MESSAGE)
    end
end

-- Functions other runtime files must define. A mixed install of old and new
-- files otherwise fails silently, because the client hides Lua errors by default.
local REQUIRED_NAMESPACE = {"ParseCommand", "HandleCommand", "FocusedQuest", "GameFocusChanged", "WorldLoading",
    "WorldEntered", "HookQuestieFocus",
    "ReportQuestDebug", "BuildMacro",
    "WriteMacro", "FlushMacro", "ReportMacroDebug", "InitializeOptions", "OpenSettings"}
-- Client APIs the macro needs; checked, never the client version.
local REQUIRED_APIS = {
    {"C_SuperTrack", "GetSuperTrackedQuestID"}, {"C_QuestLog", "GetQuestObjectives"},
    {"C_QuestLog", "GetLogIndexForQuestID"}, {"C_QuestLog", "IsComplete"}, {"C_QuestLog", "GetTitleForQuestID"},
    {nil, "GetMacroIndexByName"}, {nil, "GetMacroBody"}, {nil, "GetNumMacros"}, {nil, "CreateMacro"},
    {nil, "EditMacro"}, {nil, "InCombatLockdown"}, {nil, "UnitExists"}, {nil, "UnitName"},
    {"C_Timer", "After"},
}

local function CheckInstalledFiles()
    for _, name in ipairs(REQUIRED_NAMESPACE) do
        if type(DQT[name]) ~= "function" then
            return false, "AddOn files are from different versions (missing " .. name
                .. "). Reinstall every Dyre's Quest Targeting file, then restart the client."
        end
    end
    for _, api in ipairs(REQUIRED_APIS) do
        local owner = api[1] and _G[api[1]] or _G
        if type(owner) ~= "table" or type(owner[api[2]]) ~= "function" then
            local name = api[1] and (api[1] .. "." .. api[2]) or api[2]
            return false, "This client lacks " .. name .. ", which the quest macro needs. DQT stays off."
        end
    end
    return true
end

local function SanitizeMarker(value, default)
    if type(value) ~= "number" or value ~= math.floor(value) or value < DQT.MARKER_MIN
            or value > DQT.MARKER_MAX then
        return default
    end
    return value
end

-- A name the macro can hold: one line, no ";" (which would split a macro
-- condition), and short enough to fit beside the macro's fixed lines.
function DQT.CheckName(name)
    if type(name) ~= "string" then
        return nil, "Target a mob or type a name."
    end
    name = name:match("^%s*(.-)%s*$")
    if name == "" then
        return nil, "Target a mob or type a name."
    end
    if name:find("[;\r\n]") then
        return nil, "A name cannot contain \";\" or a line break."
    end
    if #name > DQT.MaxNameLength() then
        return nil, "\"" .. name .. "\" is too long to fit in the macro."
    end
    return name
end

-- What the macro does to a mob it finds: nothing, /startattack, or one of
-- your spells, cast by name with its rank ("Moonfire(Rank 1)").
DQT.OPENER_NONE = ""
DQT.OPENER_ATTACK = "startattack"
DQT.MAX_OPENER_LENGTH = 40

function DQT.CheckOpener(opener)
    if type(opener) ~= "string" or opener:find("[;\r\n]") or #opener > DQT.MAX_OPENER_LENGTH then
        return nil
    end
    return opener
end

local function SanitizeAdded(list)
    local clean, seen = {}, {}
    if type(list) ~= "table" then
        return clean
    end
    for _, entry in ipairs(list) do
        local name = type(entry) == "table" and DQT.CheckName(entry.name)
        if name and not seen[name:lower()] then
            seen[name:lower()] = true
            clean[#clean + 1] = {name = name, exact = entry.exact == true}
        end
    end
    while #clean > DQT.MAX_ADDED do
        table.remove(clean, 1)
    end
    return clean
end

-- Per-character settings in DyresQuestTargetingDB (each character has its own
-- macro and its own hit list), repaired on load so a damaged or older
-- table can never break the AddOn.
function DQT.SanitizeDB(db)
    db = type(db) == "table" and db or {}
    if type(db.enabled) ~= "boolean" then
        db.enabled = true
    end
    if type(db.questieFocus) ~= "boolean" then
        db.questieFocus = true
    end
    if type(db.mark) ~= "boolean" then
        db.mark = true
    end
    db.opener = DQT.CheckOpener(db.opener) or DQT.OPENER_NONE
    db.mobMarker = SanitizeMarker(db.mobMarker, DQT.DEFAULT_MOB_MARKER)
    db.npcMarker = SanitizeMarker(db.npcMarker, DQT.DEFAULT_NPC_MARKER)
    db.added = SanitizeAdded(db.added)
    db.hidden = nil -- quest names hidden by a test build; hiding is on hold
    return db
end

-- Says in chat (author-approved) when the focused quest changes, with the
-- name the macro now looks for first, and when a name of the same quest drops
-- out because its objective is done. Not at login: nothing changed then.
local lastFocusKey
local lastQuestNames = {}

local function QuestNames(quest)
    local names = {}
    for _, target in ipairs(quest and quest.targets or {}) do
        if target.source ~= "turnin" then
            names[target.name:lower()] = target.name
        end
    end
    return names
end

local function AnnounceCompleted(quest, before, after)
    local gone = {}
    for key, name in pairs(before) do
        if not after[key] then
            gone[#gone + 1] = name
        end
    end
    table.sort(gone)
    local wait = DQT.MacroPending() and " The macro updates after combat." or ""
    for _, name in ipairs(gone) do
        DQT.Report(name .. " removed: Quest " .. quest.title .. " objective completed. Use /dqt add if you "
            .. "want to keep targeting them." .. wait)
    end
end

local function Announce(quest, built)
    local key = quest and (quest.id .. " " .. tostring(quest.objective)) or "none"
    local previous, previousNames = lastFocusKey, lastQuestNames
    lastFocusKey, lastQuestNames = key, QuestNames(quest)
    if previous == nil then
        return
    end
    if previous == key then
        if quest then
            AnnounceCompleted(quest, previousNames, lastQuestNames)
        end
        return
    end
    local first = built.kept[#built.kept]
    local targeting = first and ("targeting updated to " .. first.name) or "targeting nothing"
    if DQT.MacroPending() then
        targeting = targeting .. " after combat"
    end
    if not quest then
        DQT.Report("No focused quest; " .. targeting .. ".")
        return
    end
    local via = quest.via == "Questie" and "Questie" or "Quest Focus"
    DQT.Report("Focused quest changed via " .. via .. " (" .. quest.title .. "), " .. targeting .. ".")
end

-- Rebuilds the macro from the focused quest and the hit list. Out of
-- combat it writes at once; in combat the write waits for PLAYER_REGEN_ENABLED.
function DQT.Refresh()
    if not DQT.available then
        return
    end
    -- Off leaves the macro as it is.
    if not DQT.db.enabled then
        DQT.current = nil
        return
    end
    local quest = DQT.FocusedQuest()
    local targets = {}
    if quest then
        for _, target in ipairs(quest.targets) do
            targets[#targets + 1] = target
        end
    end
    -- The hit list goes last, so it wins over the quest's names.
    for _, entry in ipairs(DQT.db.added) do
        targets[#targets + 1] = {name = entry.name, exact = entry.exact, source = "added"}
    end
    local built = DQT.BuildMacro(targets, DQT.db)
    built.quest = quest
    DQT.current = built
    DQT.WriteMacro(built.body)
    Announce(quest, built)
end

local refreshScheduled = false

function DQT.RequestRefresh()
    if refreshScheduled then
        return
    end
    refreshScheduled = true
    C_Timer.After(REFRESH_DELAY, function()
        refreshScheduled = false
        DQT.Refresh()
    end)
end

local function AfterChange(message)
    DQT.Refresh()
    if InCombatLockdown() then
        message = message .. " The macro updates after combat."
    end
    DQT.Report(message)
end

-- With nothing typed, the name is your target's; it can be secret (unit
-- identity restrictions), so it is checked before it is kept.
local function NameFrom(argument)
    if argument and argument ~= "" then
        return DQT.CheckName(argument)
    end
    if not UnitExists("target") then
        return nil, "Target a mob or type a name."
    end
    local name = UnitName("target")
    if DQT.IsSecret(name) then
        return nil, "Your target's name cannot be read right now; type it, or try again out of combat."
    end
    return DQT.CheckName(name)
end

local function FindAdded(name)
    local wanted = name:lower()
    for index, entry in ipairs(DQT.db.added) do
        if entry.name:lower() == wanted then
            return index
        end
    end
end

local function Add(argument, exact)
    local name, problem = NameFrom(argument)
    if not name then
        DQT.Report(problem)
        return
    end
    local index = FindAdded(name)
    if index then
        table.remove(DQT.db.added, index)
    end
    table.insert(DQT.db.added, {name = name, exact = exact})
    local message = "Added " .. name .. " to your hit list"
        .. (exact and " (exact name)." or " (any name containing it).")
    if #DQT.db.added > DQT.MAX_ADDED then
        local oldest = table.remove(DQT.db.added, 1)
        message = message .. " Removed the oldest, " .. oldest.name .. "."
    end
    AfterChange(message)
end

function DQT.AddSimilar(argument)
    Add(argument, false)
end

function DQT.AddExact(argument)
    Add(argument, true)
end

function DQT.RemoveName(argument)
    local name, problem = NameFrom(argument)
    if not name then
        DQT.Report(problem)
        return
    end
    local index = FindAdded(name)
    if not index then
        DQT.Report(name .. " is not on your hit list.")
        return
    end
    local removed = table.remove(DQT.db.added, index)
    AfterChange("Removed " .. removed.name .. " from your hit list.")
end

function DQT.ResetAdded()
    local count = #DQT.db.added
    DQT.db.added = {}
    AfterChange("Cleared your hit list (" .. count .. (count == 1 and " name)." or " names)."))
end

function DQT.SetEnabled(enabled)
    DQT.db.enabled = enabled
    AfterChange(enabled and "On: the macro follows your focused quest."
        or "Off: the macro no longer changes. /dqt on turns it back on.")
end

function DQT.TurnOn()
    DQT.SetEnabled(true)
end

function DQT.TurnOff()
    DQT.SetEnabled(false)
end

local SOURCE_TEXT = {
    kill = "kill objective",
    drop = "drops a quest item",
    turnin = "turn-in",
    added = "hit list",
}

local function Describe(target)
    local text = target.name .. " (" .. (SOURCE_TEXT[target.source] or target.source)
    if target.detail then
        text = text .. ": " .. target.detail
    end
    if target.source == "added" then
        text = text .. (target.exact and ", exact" or ", similar names")
    end
    return text .. ")"
end

function DQT.ListTargets()
    if not DQT.db.enabled then
        DQT.Report("Off: the macro does not change. /dqt on turns it back on.")
        return
    end
    DQT.Refresh()
    local current = DQT.current
    local quest = current.quest
    if quest then
        local where = quest.via == "Questie" and " (Questie's focus" .. (quest.objective
            and (", objective " .. quest.objective) or "") .. ")" or ""
        DQT.Report("Focused quest: " .. quest.title .. where .. (quest.complete and " (ready to turn in)" or ""))
    else
        DQT.Report("No focused quest. Focus one in the quest log, on the map, or in Questie's tracker.")
    end
    if #current.kept == 0 then
        DQT.Report("The macro targets nothing yet. /dqt add <name> adds a mob.")
    else
        DQT.Report("The macro looks for, most wanted first:")
        for index = #current.kept, 1, -1 do
            DQT.Report("  " .. Describe(current.kept[index]))
        end
    end
    for _, target in ipairs(current.dropped) do
        DQT.Report("  No room in the macro for " .. Describe(target))
    end
    if quest and not quest.database then
        DQT.Report("QuestieDB is not loaded, so only kill objectives are targeted (no quest-item drops or "
            .. "turn-in NPCs).")
    end
    if DQT.MacroPending() then
        DQT.Report("The macro updates after combat.")
    end
end

function DQT.ReportDebug()
    DQT.Report("debug: available=" .. tostring(DQT.available) .. " combat=" .. tostring(InCombatLockdown()))
    DQT.ReportQuestDebug()
    DQT.ReportMacroDebug()
end

-- Another AddOn can register the same slash command; the last one loaded wins.
-- Returns the other command key, or nil when /dqt is ours alone.
local function FindSlashConflict()
    for key in pairs(SlashCmdList) do
        if key ~= SLASH_KEY then
            for index = 1, MAX_SLASH_ALIASES do
                local alias = _G["SLASH_" .. key .. index]
                if type(alias) == "string" and alias:lower() == PRIMARY_SLASH then
                    return key
                end
            end
        end
    end
end

SLASH_DYRESQUESTTARGETING1 = PRIMARY_SLASH
SLASH_DYRESQUESTTARGETING2 = BACKUP_SLASH
SlashCmdList[SLASH_KEY] = function(message) DQT.HandleCommand(message) end

local function LoadDB()
    DyresQuestTargetingDB = DQT.SanitizeDB(DyresQuestTargetingDB)
    DQT.db = DyresQuestTargetingDB
end

-- The focused quest changing, its progress, and quests leaving the log.
-- QUEST_LOG_UPDATE carries objective progress (Blizzard's tracker uses it);
-- QUEST_WATCH_UPDATE and UNIT_QUEST_LOG_CHANGED back it up.
local QUEST_EVENTS = {"SUPER_TRACKING_CHANGED", "QUEST_LOG_UPDATE", "QUEST_WATCH_UPDATE", "QUEST_ACCEPTED",
    "QUEST_REMOVED", "QUEST_TURNED_IN"}

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, firstArg)
    if event == "ADDON_LOADED" then
        if firstArg == addonName then
            self:UnregisterEvent("ADDON_LOADED")
            LoadDB()
        end
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        DQT.FlushMacro()
        DQT.RequestRefresh()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        DQT.WorldEntered()
    elseif event == "PLAYER_LEAVING_WORLD" then
        DQT.WorldLoading()
    end
    if event ~= "PLAYER_LOGIN" then
        if event == "SUPER_TRACKING_CHANGED" then
            DQT.GameFocusChanged()
        end
        DQT.RequestRefresh()
        return
    end
    self:UnregisterEvent("PLAYER_LOGIN")
    local available, message = CheckInstalledFiles()
    if available and not DQT.db then
        LoadDB()
    end
    DQT.available = available
    ReportLoaded(available)
    local conflict = FindSlashConflict()
    if conflict then
        DQT.Report("Another AddOn (" .. conflict .. ") also uses " .. PRIMARY_SLASH
            .. ". Use " .. BACKUP_SLASH .. " instead.")
    end
    if not available then
        DQT.Report(message)
        return
    end
    -- Called here rather than from each file's own PLAYER_LOGIN handler, so
    -- startup never depends on event handler order.
    DQT.InitializeOptions()
    for _, name in ipairs(QUEST_EVENTS) do
        self:RegisterEvent(name)
    end
    self:RegisterUnitEvent("UNIT_QUEST_LOG_CHANGED", "player")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_LEAVING_WORLD")
    DQT.WorldLoading()
    DQT.HookQuestieFocus(DQT.RequestRefresh)
    DQT.RequestRefresh()
end)
