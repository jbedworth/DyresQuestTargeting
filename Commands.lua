local _, DQT = ...

local USAGE = "Use /dqt, /dqt add [name], /dqt add_exact [name], /dqt remove [name], /dqt reset, /dqt on, "
    .. "/dqt off, /dqt options, or /dqt debug."
local UNAVAILABLE = "Dyre's Quest Targeting is unavailable. Check the DQT login message."

-- The first word is the command; add, add_exact, and remove take the rest of
-- the line as a name, as typed. Handlers live in Core and Options.
-- Diagnostics also run when DQT is unavailable, to help explain why.
local COMMANDS = {
    [""] = {handler = "ListTargets"},
    options = {handler = "OpenSettings"},
    add = {handler = "AddSimilar", takesName = true},
    add_exact = {handler = "AddExact", takesName = true},
    remove = {handler = "RemoveName", takesName = true},
    reset = {handler = "ResetAdded"},
    on = {handler = "TurnOn"},
    off = {handler = "TurnOff"},
    debug = {handler = "ReportDebug", always = true},
}

function DQT.ParseCommand(message)
    if type(message) ~= "string" then
        return nil, USAGE
    end
    local trimmed = message:match("^%s*(.-)%s*$")
    local command, rest = trimmed:match("^(%S*)%s*(.-)$")
    command = command:lower()
    local entry = COMMANDS[command]
    if not entry or (rest ~= "" and not entry.takesName) then
        return nil, USAGE
    end
    return command, rest
end

-- Macro conditions, as in "/dqt [mod:shift] remove; add" in your own
-- macro: the game's own parser picks the first clause whose conditions
-- match, and none matching does nothing, as a macro line would.
local function ChooseClause(message)
    if type(message) ~= "string" or not message:find("[", 1, true) or type(SecureCmdOptionParse) ~= "function" then
        return message
    end
    return SecureCmdOptionParse(message)
end

function DQT.HandleCommand(message)
    message = ChooseClause(message)
    if message == nil then
        return
    end
    local command, argument = DQT.ParseCommand(message)
    if not command then
        DQT.Report(argument)
        return
    end
    local entry = COMMANDS[command]
    if not DQT.available and not entry.always then
        DQT.Report(UNAVAILABLE)
        return
    end
    DQT[entry.handler](argument)
end
