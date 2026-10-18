local _, DQT = ...

-- The character macro "! Quest Targets" ("!" sorts it first; macro names
-- hold at most 16 letters). Each character has its own: RXP's one account
-- macro, shared by every character, is what this avoids.
DQT.MACRO_NAME = "! Quest Targets"
local MACRO_ICON = "Ability_Hunter_SniperShot"
local ICONS = {[DQT.MACRO_NAME] = MACRO_ICON}
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
local CAST_PREFIX = "/cast [harm,nodead] "
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
    if npc > 0 then
        clauses[#clauses + 1] = "[noharm,nodead] !" .. npc
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

-- Macros change only out of combat; a body asked for in combat waits for
-- PLAYER_REGEN_ENABLED (FlushMacro). Written only when the body changes.
local function WriteNamed(name, body)
    if InCombatLockdown() then
        pending[name] = body
        return
    end
    pending[name] = nil
    local index = GetMacroIndexByName(name)
    if type(index) ~= "number" or index == 0 then
        local _, numCharacter = GetNumMacros()
        if type(numCharacter) == "number"
                and numCharacter >= MacroLimit("MAX_CHARACTER_MACROS", DEFAULT_CHARACTER_MACROS) then
            WarnOnce("slots " .. name, "No free character macro slot for \"" .. name
                .. "\"; free one and DQT adds it.")
            return
        end
        CreateMacro(name, ICONS[name], body, true)
        WarnOnce("created " .. name, "Made the character macro \"" .. name
            .. "\". Put it on an action bar from the Macros window (/macro).")
    elseif index <= MacroLimit("MAX_ACCOUNT_MACROS", DEFAULT_ACCOUNT_MACROS) then
        WarnOnce("account " .. name, "An account-wide macro is named \"" .. name
            .. "\". Rename or delete it, so each character can have its own.")
    elseif GetMacroBody(index) ~= body then
        EditMacro(index, name, ICONS[name], body)
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
    local index = GetMacroIndexByName(DQT.MACRO_NAME)
    local numAccount, numCharacter = GetNumMacros()
    DQT.Report("debug macro index=" .. DQT.Describe(index) .. " account=" .. DQT.Describe(numAccount)
        .. " character=" .. DQT.Describe(numCharacter) .. "/"
        .. MacroLimit("MAX_CHARACTER_MACROS", DEFAULT_CHARACTER_MACROS) .. " pending=" .. tostring(DQT.MacroPending()))
    local current = DQT.current
    if current then
        DQT.Report("debug macro body (" .. #current.body .. " of " .. MACRO_LIMIT .. "): "
            .. current.body:gsub("\n", " | "))
    end
end
