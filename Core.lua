local addonName, DQT = ...

-- Dyre's Quest Targeting: keeps the macro "! Target (DQT)" up to
-- date with the mobs and NPCs your focused quest needs, plus names you add.
-- This file owns saved settings, the login banner, install and API checks,
-- slash conflict reporting, the hit list, refresh scheduling, and startup.
local DEFAULT_TITLE = "Dyre's Quest Targeting"
local READY_MESSAGE = "  Ready. Put the \"! Target (DQT)\" macro on a bar; /dqt list shows what it targets, /dqt opens the settings."
local SLASH_KEY = "DYRESQUESTTARGETING"
local PRIMARY_SLASH = "/dqt"
local BACKUP_SLASH = "/questtargeting"
local MAX_SLASH_ALIASES = 10
-- Dyre's Toolkit: the shared settings home, minimap menu, and widgets for
-- Dyre's AddOns (its AGENTS.md, "The interface" and "Widgets"). Required in
-- the TOC; with an older one, the macro still works, without the box.
-- Contract 2 has the widgets the Quest Target box needs.
local TOOLKIT_CONTRACT = 2
local TOOLKIT_HINT = "The Quest Target box needs Dyre's Toolkit 2.0 or later: install or update it from CurseForge."
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

-- Dyre's Toolkit when installed with the contract DQT uses, else nil (also
-- for a newer, incompatible one: DQT then keeps its own top-level page).
function DQT.Toolkit()
    local toolkit = DyresToolkit
    if type(toolkit) ~= "table" or type(toolkit.RequireContract) ~= "function" then
        return nil
    end
    local required = toolkit.RequireContract(TOOLKIT_CONTRACT)
    if type(required) == "table" then
        return required
    end
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

-- Joins the toolkit's minimap menu; without a toolkit DQT can use, says
-- once (at login) where to get it.
local function JoinToolkit()
    local toolkit = DQT.Toolkit()
    if toolkit then
        if type(toolkit.RegisterAddOn) == "function" then
            toolkit.RegisterAddOn({addon = addonName, title = DEFAULT_TITLE, openSettings = DQT.OpenSettings})
        end
    else
        DQT.Report(TOOLKIT_HINT)
    end
end

-- /dqt unlock and /dqt lock: the toolkit's one layout mode for every Dyre's
-- AddOn; the toolkit says the one line. /dqt reset_box: the box's first place.
local function WithToolkit(action)
    local toolkit = DQT.Toolkit()
    if not toolkit then
        DQT.Report(TOOLKIT_HINT)
        return
    end
    action(toolkit)
end

function DQT.Unlock()
    WithToolkit(function(toolkit) toolkit.Unlock() end)
end

function DQT.Lock()
    WithToolkit(function(toolkit) toolkit.Lock() end)
end

function DQT.ResetBox()
    WithToolkit(function(toolkit)
        toolkit.ResetWidgets(addonName)
        DQT.Report("The Quest Target box is back in its first place.")
    end)
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
    "WorldEntered", "HookQuestieFocus", "QuestieFocusAvailable", "SyncFocus", "PointTomTom",
    "ReportQuestDebug", "BuildMacro",
    "WriteMacro", "FlushMacro", "ReportMacroDebug", "CreateBox", "UpdateBox", "InitializeOptions", "OpenSettings"}
-- Client APIs the macro needs; checked, never the client version. An entry
-- with several APIs needs any one of them (Classic Era and Anniversary have
-- the older quest log functions instead of C_QuestLog's).
local REQUIRED_APIS = {
    {{"C_QuestLog", "GetQuestObjectives"}},
    {{"C_QuestLog", "GetLogIndexForQuestID"}, {nil, "GetQuestLogIndexByID"}},
    {{"C_QuestLog", "GetTitleForQuestID"}, {nil, "GetQuestLogTitle"}},
    {{"C_QuestLog", "IsComplete"}, {nil, "GetQuestLogTitle"}},
    {{nil, "GetMacroInfo"}}, {{nil, "GetMacroBody"}}, {{nil, "GetNumMacros"}}, {{nil, "CreateMacro"}},
    {{nil, "EditMacro"}}, {{nil, "InCombatLockdown"}}, {{nil, "UnitExists"}}, {{nil, "UnitName"}},
    {{"C_Timer", "After"}},
}
-- Without any quest focus (Classic without Questie), DQT still keeps your hit
-- list in the macro (author); only quest targeting is off.
local NO_FOCUS = "This client has no quest focus of its own, and Questie is not loaded, so quest targeting is "
    .. "off; the macro keeps your hit list. Install Questie from CurseForge to target your quests."

-- owner nil: a global function. Never "owner and _G[owner] or _G": with the
-- namespace missing, that looks up a global of the same name instead (Classic
-- Era has GetSuperTrackedQuestID as a global but no C_SuperTrack).
local function API(owner, name)
    local scope = _G
    if owner then
        scope = _G[owner]
    end
    return type(scope) == "table" and type(scope[name]) == "function"
end

-- The game's own quest focus (super-tracking): Forever has it; Classic Era
-- and Anniversary do not, so DQT follows Questie's tracker focus there.
function DQT.HasGameFocus()
    return API("C_SuperTrack", "GetSuperTrackedQuestID")
end

-- A quest focus to follow: the game's, or Questie's tracker focus.
function DQT.CanFollowQuests()
    return DQT.HasGameFocus() or DQT.QuestieFocusAvailable()
end

-- The quest log, through C_QuestLog where the client has it, else the older
-- functions (GetQuestLogIndexByID gives 0 for a quest not in the log; the
-- sixth return of GetQuestLogTitle is 1 for a complete quest).
function DQT.QuestLogIndex(questID)
    if API("C_QuestLog", "GetLogIndexForQuestID") then
        return C_QuestLog.GetLogIndexForQuestID(questID)
    end
    local index = GetQuestLogIndexByID(questID)
    if type(index) == "number" and index > 0 then
        return index
    end
end

function DQT.QuestTitle(questID)
    if API("C_QuestLog", "GetTitleForQuestID") then
        return C_QuestLog.GetTitleForQuestID(questID)
    end
    local index = DQT.QuestLogIndex(questID)
    local title = index and GetQuestLogTitle(index)
    if type(title) == "string" then
        return title
    end
end

function DQT.QuestComplete(questID)
    if API("C_QuestLog", "IsComplete") then
        return C_QuestLog.IsComplete(questID) == true
    end
    local index = DQT.QuestLogIndex(questID)
    if not index then
        return false
    end
    local complete = select(6, GetQuestLogTitle(index))
    return complete == 1 or complete == true
end

local function CheckInstalledFiles()
    for _, name in ipairs(REQUIRED_NAMESPACE) do
        if type(DQT[name]) ~= "function" then
            return false, "AddOn files are from different versions (missing " .. name
                .. "). Reinstall every Dyre's Quest Targeting file, then restart the client."
        end
    end
    for _, choices in ipairs(REQUIRED_APIS) do
        local found = false
        for _, api in ipairs(choices) do
            found = found or API(api[1], api[2])
        end
        if not found then
            local first = choices[1]
            local name = first[1] and (first[1] .. "." .. first[2]) or first[2]
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
    -- Both change other AddOns' state, so they are opt-in.
    if type(db.syncFocus) ~= "boolean" then
        db.syncFocus = false
    end
    if type(db.tomtom) ~= "boolean" then
        db.tomtom = false
    end
    if type(db.accountMacro) ~= "boolean" then
        db.accountMacro = false
    end
    if type(db.mark) ~= "boolean" then
        db.mark = true
    end
    db.opener = DQT.CheckOpener(db.opener) or DQT.OPENER_NONE
    db.mobMarker = SanitizeMarker(db.mobMarker, DQT.DEFAULT_MOB_MARKER)
    db.npcMarker = SanitizeMarker(db.npcMarker, DQT.DEFAULT_NPC_MARKER)
    db.added = SanitizeAdded(db.added)
    if type(db.showBox) ~= "boolean" then
        db.showBox = true
    end
    -- At login: the quest's part open, the hit list folded (author). A 1.1.0
    -- test build's one "Start folded" becomes the quest's.
    if type(db.startQuestFolded) ~= "boolean" then
        db.startQuestFolded = db.startFolded == true
    end
    if type(db.startHitListFolded) ~= "boolean" then
        db.startHitListFolded = true
    end
    db.startFolded = nil
    if not DQT.BOX_STYLES[db.boxStyle] then
        db.boxStyle = DQT.DEFAULT_BOX_STYLE
    end
    -- The Quest Target box's place and sizes; the toolkit repairs the numbers.
    if type(db.box) ~= "table" then
        db.box = {}
    end
    -- Which sections are folded (by key); "folded" was a 1.1.0 test build's.
    db.box.folded = nil
    if type(db.box.foldedSections) ~= "table" then
        db.box.foldedSections = {}
    end
    for key, value in pairs(db.box.foldedSections) do
        if value ~= true then
            db.box.foldedSections[key] = nil
        end
    end
    -- Sizes from a 1.1.0 test build: the box is now Width and Height.
    db.box.scale, db.box.lines = nil, nil
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
    local wait = DQT.MacroPending() and " after combat" or ""
    if not quest then
        local first = built.kept[#built.kept]
        DQT.Report("No focused quest; " .. (first and ("targeting updated to " .. first.name) or "targeting nothing")
            .. wait .. ".")
        return
    end
    -- The quest's own first mob, so a hit list name (which wins) does not
    -- hide the change; the hit list is said apart (author-approved).
    local questFirst, listFirst
    for index = #built.kept, 1, -1 do
        local target = built.kept[index]
        if target.source == "added" then
            listFirst = listFirst or target
        else
            questFirst = questFirst or target
        end
    end
    local targeting = questFirst and ("targeting updated to " .. questFirst.name) or "targeting nothing from the quest"
    local via = quest.via == "Questie" and "Questie" or "Quest Focus"
    DQT.Report("Focused quest changed via " .. via .. " (" .. quest.title .. "), " .. targeting .. wait .. "."
        .. (listFirst and (" Your hit list comes first: " .. listFirst.name .. ".") or ""))
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
        DQT.UpdateBox()
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
    -- After the macro, so a change in Questie's private code cannot stop it.
    DQT.SyncFocus()
    DQT.PointTomTom(quest, built.kept)
    DQT.UpdateBox()
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

-- A hit list name to a new place, counted as the box shows the list: 1 is
-- the most wanted, which db.added keeps last (the last line wins).
function DQT.MoveAdded(name, position)
    local index = FindAdded(name)
    if not index then
        return
    end
    local entry = table.remove(DQT.db.added, index)
    local count = #DQT.db.added
    position = math.max(1, math.min(count + 1, position))
    table.insert(DQT.db.added, count + 2 - position, entry)
    DQT.Refresh()
    if InCombatLockdown() then
        DQT.Report("Moved " .. entry.name .. " in your hit list. The macro updates after combat.")
    end
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

function DQT.SourceText(target)
    return SOURCE_TEXT[target.source] or target.source
end

local function Describe(target)
    local text = target.name .. " (" .. DQT.SourceText(target)
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
        DQT.Report(DQT.CanFollowQuests() and "No focused quest. Focus one in the quest log, on the map, or in "
            .. "Questie's tracker." or "No quest focus on this client without Questie: the macro uses your hit list.")
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
-- SUPER_TRACKING_CHANGED only where the game has its focus: registering an
-- event the client does not know is an error.
local QUEST_EVENTS = {"QUEST_LOG_UPDATE", "QUEST_WATCH_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED",
    "QUEST_TURNED_IN"}
local FOCUS_EVENT = "SUPER_TRACKING_CHANGED"

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
        if event == FOCUS_EVENT then
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
    -- The box first: its size settings go on the settings page.
    DQT.CreateBox()
    DQT.InitializeOptions()
    JoinToolkit()
    if not DQT.CanFollowQuests() then
        DQT.Report(NO_FOCUS)
    end
    for _, name in ipairs(QUEST_EVENTS) do
        self:RegisterEvent(name)
    end
    if DQT.HasGameFocus() then
        self:RegisterEvent(FOCUS_EVENT)
    end
    self:RegisterUnitEvent("UNIT_QUEST_LOG_CHANGED", "player")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_LEAVING_WORLD")
    DQT.WorldLoading()
    DQT.HookQuestieFocus(DQT.RequestRefresh)
    DQT.RequestRefresh()
end)
