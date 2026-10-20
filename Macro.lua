local _, DQT = ...

-- The macro "! Target (DQT)" ("!" sorts it first; macro names hold at most
-- 16 letters). By default a character macro, so each character has its own:
-- RXP's one account macro, shared by every character, is what this avoids.
-- "Use an account-wide macro" (db.accountMacro, author-approved) is for
-- players short of character slots who do not play two characters at once:
-- one account macro, rewritten for whichever character is logged in.
DQT.MACRO_NAME = "! Target (DQT)"
-- Icon file ID 132177, "Hunter Marksman".
local MACRO_ICON = 132177
local ICONS = {[DQT.MACRO_NAME] = MACRO_ICON}
-- The name in pre-release builds. A character macro of that name is renamed
-- in place, so it stays on the player's action bars.
local OLD_NAMES = {[DQT.MACRO_NAME] = "! Quest Targets"}
local MACRO_LIMIT = 255
-- Constants.MacroConsts (MacroConstantsDocumentation.lua); the MAX_*_MACROS
-- globals exist only once Blizzard's Macro window has loaded.
local DEFAULT_ACCOUNT_MACROS, DEFAULT_CHARACTER_MACROS = 120, 30

-- A mob that is already dead is skipped: /targetlasttarget [dead] goes back.
-- /tm's "!" leaves a marker that is already there (a second press would
-- toggle it off), in one line with a clause per kind (SecureCmdOptionParse
-- takes the first clause whose conditions match).
local CLEAR_LINE = "/cleartarget"
local DEAD_LINE = "/targetlasttarget [dead]"
local ATTACK_LINE = "/startattack [harm,nodead]"
-- /use rather than /cast: one letter shorter. With no item of that name, it
-- casts the spell (SlashCommands.lua, SLASH_COMMAND.USE: CastSpellByName).
local CAST_PREFIX = "/use [harm,nodead] "
local EXACT_PREFIX = "/targetexact "
local SIMILAR_PREFIX = "/tar "
local NOTHING_BODY = "// Dyre's Quest Targeting: nothing to target. /dqt add <name> adds one."

local pending = {}
local warned = {}

local function MarkerLine(mob, npc)
    local clauses = {}
    if mob > 0 then
        clauses[#clauses + 1] = "[harm,nodead] !" .. mob
    end
    -- With no target, noharm and nodead are both true, and /tm on nothing
    -- answers "You can't do that right now" (found in client); exists stops it.
    -- harm already needs a target.
    if npc > 0 then
        clauses[#clauses + 1] = "[exists,noharm,nodead] !" .. npc
    end
    if #clauses > 0 then
        return "/tm " .. table.concat(clauses, "; ")
    end
end

local function OpenerLine(opener)
    if opener == DQT.OPENER_ATTACK then
        return ATTACK_LINE
    elseif opener ~= DQT.OPENER_NONE then
        return CAST_PREFIX .. opener
    end
end

local function TrailerLines(settings)
    local lines = {DEAD_LINE}
    local marker = settings.mark and MarkerLine(settings.mobMarker, settings.npcMarker)
    if marker then
        lines[#lines + 1] = marker
    end
    lines[#lines + 1] = OpenerLine(settings.opener)
    return lines
end

-- The longest name that always fits, whatever the settings: every fixed line,
-- the longest opener, and one /targetexact line.
function DQT.MaxNameLength()
    local fixed = {CLEAR_LINE}
    local longest = {mark = true, mobMarker = DQT.MARKER_MAX, npcMarker = DQT.MARKER_MAX,
        opener = string.rep("x", DQT.MAX_OPENER_LENGTH)}
    for _, line in ipairs(TrailerLines(longest)) do
        fixed[#fixed + 1] = line
    end
    return MACRO_LIMIT - #table.concat(fixed, "\n") - #EXACT_PREFIX - 1
end

local function TargetLine(target)
    return (target.exact and EXACT_PREFIX or SIMILAR_PREFIX) .. target.name
end

-- Targets come least to most important; every /targetexact line runs and the
-- last one that finds a unit wins. A name listed twice keeps its more
-- important place. When the macro is full, the least important names are left out.
-- Returns {body, kept (in macro order), dropped}.
function DQT.BuildMacro(targets, settings)
    local byPriority, seen = {}, {}
    for index = #targets, 1, -1 do
        local key = targets[index].name:lower()
        if not seen[key] then
            seen[key] = true
            byPriority[#byPriority + 1] = targets[index]
        end
    end
    local trailer = TrailerLines(settings)
    local used = #CLEAR_LINE + 1 + #table.concat(trailer, "\n")
    local kept, dropped = {}, {}
    for _, target in ipairs(byPriority) do
        local cost = #TargetLine(target) + 1
        if used + cost <= MACRO_LIMIT then
            used = used + cost
            table.insert(kept, 1, target)
        else
            dropped[#dropped + 1] = target
        end
    end
    if #kept == 0 then
        return {body = NOTHING_BODY, kept = kept, dropped = dropped}
    end
    local lines = {CLEAR_LINE}
    for _, target in ipairs(kept) do
        lines[#lines + 1] = TargetLine(target)
    end
    for _, line in ipairs(trailer) do
        lines[#lines + 1] = line
    end
    return {body = table.concat(lines, "\n"), kept = kept, dropped = dropped}
end

local function MacroLimit(field, default)
    local constants = type(Constants) == "table" and Constants.MacroConsts
    if type(constants) == "table" and type(constants[field]) == "number" then
        return constants[field]
    end
    return default
end

local function WarnOnce(key, message)
    if not warned[key] then
        warned[key] = true
        DQT.Report(message)
    end
end

local function ScopeWord(account)
    return account and "account-wide" or "character"
end

-- The index of the macro called name among account macros (1 up) or this
-- character's (after MAX_ACCOUNT_MACROS), as Blizzard's Macro window numbers
-- them (Blizzard_MacroUI.lua), or nil. GetMacroIndexByName alone cannot tell
-- an account macro from a character one of the same name.
local function FindMacro(name, account)
    local accountSlots = MacroLimit("MAX_ACCOUNT_MACROS", DEFAULT_ACCOUNT_MACROS)
    local numAccount, numCharacter = GetNumMacros()
    local first = account and 1 or accountSlots + 1
    local count = account and numAccount or numCharacter
    if type(count) ~= "number" then
        return nil
    end
    for index = first, first + count - 1 do
        local macroName = GetMacroInfo(index)
        if macroName == name then
            return index
        end
    end
end

-- Macros change only out of combat; a body asked for in combat waits for
-- PLAYER_REGEN_ENABLED (FlushMacro). Written only when the body changes. A
-- macro of the same name in the other scope (the setting was switched, or
-- the player made one) is left alone, with a word in chat.
local function WriteNamed(name, body)
    if InCombatLockdown() then
        pending[name] = body
        return
    end
    pending[name] = nil
    local account = DQT.db.accountMacro == true
    local index = FindMacro(name, account)
    local oldName = OLD_NAMES[name]
    local oldIndex = not index and not account and oldName and FindMacro(oldName, false)
    if oldIndex then
        EditMacro(oldIndex, name, ICONS[name], body)
        WarnOnce("renamed " .. name, "Renamed the character macro \"" .. oldName .. "\" to \"" .. name .. "\".")
    elseif not index then
        local numAccount, numCharacter = GetNumMacros()
        local used = account and numAccount or numCharacter
        local limit = account and MacroLimit("MAX_ACCOUNT_MACROS", DEFAULT_ACCOUNT_MACROS)
            or MacroLimit("MAX_CHARACTER_MACROS", DEFAULT_CHARACTER_MACROS)
        if type(used) == "number" and used >= limit then
            WarnOnce("slots " .. tostring(account) .. name, "No free " .. ScopeWord(account) .. " macro slot for \""
                .. name .. "\"; free one and DQT adds it.")
            return
        end
        CreateMacro(name, ICONS[name], body, not account)
        WarnOnce("created " .. tostring(account) .. name, "Made the " .. ScopeWord(account) .. " macro \"" .. name
            .. "\". Put it on an action bar from the Macros window (/macro).")
    elseif GetMacroBody(index) ~= body then
        EditMacro(index, name, ICONS[name], body)
    end
    if FindMacro(name, not account) then
        WarnOnce("other " .. tostring(account) .. name, "The " .. ScopeWord(not account) .. " macro \"" .. name
            .. "\" is not updated now; DQT keeps the " .. ScopeWord(account) .. " one. Delete the "
            .. ScopeWord(not account) .. " one, and put the " .. ScopeWord(account) .. " one on your bars.")
    end
end

function DQT.WriteMacro(body)
    WriteNamed(DQT.MACRO_NAME, body)
end

function DQT.FlushMacro()
    if InCombatLockdown() then
        return
    end
    for name, body in pairs(pending) do
        WriteNamed(name, body)
    end
end

function DQT.MacroPending()
    return pending[DQT.MACRO_NAME] ~= nil
end

function DQT.ReportMacroDebug()
    local account = DQT.db.accountMacro == true
    local index = FindMacro(DQT.MACRO_NAME, account)
    local numAccount, numCharacter = GetNumMacros()
    DQT.Report("debug macro " .. ScopeWord(account) .. " index=" .. DQT.Describe(index)
        .. " account=" .. DQT.Describe(numAccount)
        .. " character=" .. DQT.Describe(numCharacter) .. "/"
        .. MacroLimit("MAX_CHARACTER_MACROS", DEFAULT_CHARACTER_MACROS) .. " pending=" .. tostring(DQT.MacroPending()))
    local current = DQT.current
    if current then
        DQT.Report("debug macro body (" .. #current.body .. " of " .. MACRO_LIMIT .. "): "
            .. current.body:gsub("\n", " | "))
    end
end
