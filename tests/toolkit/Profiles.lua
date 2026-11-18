local _, ns = ...
local DyresToolkit = ns.toolkit

-- The Dyre's Toolkit profile (2.10.0; John, 2026-11-15; docs/PROFILES.md).
-- A player asked for "some kind of profile options so I don't have to set
-- it up separately for each character". John: "what I want is profiles to be
-- entirely owned by the Toolkit. Settings for every Dyre addon, positions of
-- every widget and visual, sound selections, everything. Each character has
-- it's own "Dyre's Toolkit Profile" that they can copy, export, etc."
--
-- So each character has one profile, its own, named "Name - Realm". It holds
-- one part per Dyre's AddOn. No switching: a character copies another
-- character's profile, or the Defaults, or imports a text line. An AddOn
-- cannot write or read files, so export and import are text.
--
-- Each AddOn keeps its live settings in its own SavedVariables (John chose
-- this over the toolkit storing them): an AddOn without the toolkit still
-- works, nothing moves, and the minimum toolkit version stays low. Each
-- registers its part:
--   DyresToolkit.RegisterProfilePart{
--       addon = "DyresShieldsUp",          -- folder name; export lines carry it
--       title = "Dyre's Shields Up",       -- optional, for messages
--       current = function() return DyresShieldsUpDB end,  -- the live table
--       sanitize = function(settings) return ns.SanitizeDB(settings) end,
--       characterKeys = {"ownedMacros"},   -- optional: never copied, exported, or imported
--       refresh = function() ... end,      -- optional: apply live (else a reload is asked)
--   }
-- Register after the SavedVariables load and before the frames are built: a
-- part waiting for this AddOn (copied or imported while it was not loaded on
-- this character) is written then, with no refresh.
--
-- The toolkit keeps a copy of each character's profile in DyresToolkitDB:
--   profiles["Name - Realm"] = {class, seen, parts = {[addon] = settings},
--                               pending = {[addon] = settings}}
-- written at login, after a copy or import, and at PLAYER_LOGOUT (the client
-- writes SavedVariables after it). A part of an AddOn not loaded now stays.
--
-- A copy or import is all or nothing: every loaded part is checked first
-- (through its own sanitize), then each is written into its live table IN
-- PLACE (cleared and filled, nested tables too), so widgets, trackers, and
-- settings that hold the table see the new values. Then each part's refresh
-- runs (the toolkit's own sets its widgets again with ReapplyWidgets), and
-- every Dyre's settings page reads its values again. A part with no refresh,
-- or whose refresh fails, is saved, and the player is asked to reload. Never
-- in combat. The account-wide settings (lock, grid, snap, minimap) are not in
-- a profile (John: "they are user-centric, not per character").
--
-- Export format: DYRE2:profile:<data>:<checksum>, one line of printable
-- ASCII with no "|" (an edit box reads "|" as an escape code) and no ":"
-- inside the data. Data: "{" key value ... "}" for a table, "S<text>;" for a
-- string (bytes outside [A-Za-z0-9_.-] as ~XX), "N<number>;", "B1"/"B0". The
-- top table maps each AddOn folder to its part. Import parses it here; it
-- never runs any part of the text.

local FORMAT = 2
local PREFIX = "DYRE"
local KIND = "profile"
local DEFAULTS = "\1defaults"
local MAX_TEXT = 60000
local MAX_DEPTH = 20
local MAX_ITEMS = 20000
local SAFE = "[%w_%.%-]"

DyresToolkit.PROFILE_DEFAULTS = DEFAULTS

local function IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) == true
end

local function Readable(value)
    return type(value) == "string" and not IsSecret(value) and value ~= ""
end

-- "Name - Realm", or nil while the client cannot say.
function ns.CharacterKey()
    if type(UnitName) ~= "function" or type(GetRealmName) ~= "function" then
        return nil
    end
    local name, realm = UnitName("player"), GetRealmName()
    if not Readable(name) or not Readable(realm) then
        return nil
    end
    return name .. " - " .. realm
end

local function Copy(value, skip, depth)
    depth = depth or 0
    if type(value) ~= "table" then
        return value
    end
    if depth > MAX_DEPTH then
        return nil
    end
    local result = {}
    for key, item in pairs(value) do
        if not (skip and skip[key]) and (type(key) == "string" or type(key) == "number") then
            result[key] = Copy(item, nil, depth + 1)
        end
    end
    return result
end
ns.DeepCopy = Copy

-- Serializing ------------------------------------------------------------------------

local function Escape(text)
    return (text:gsub("[^%w_%.%-]", function(char) return ("~%02X"):format(char:byte()) end))
end

local function Finite(number)
    return number == number and number ~= math.huge and number ~= -math.huge
end

local function KeyOrder(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
        return ta == "number"
    end
    return a < b
end

local function Encode(value, out, depth)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = "S" .. Escape(value) .. ";"
    elseif kind == "number" then
        out[#out + 1] = "N" .. ("%.17g"):format(value) .. ";"
    elseif kind == "boolean" then
        out[#out + 1] = value and "B1" or "B0"
    elseif kind == "table" and depth <= MAX_DEPTH then
        local keys = {}
        for key, item in pairs(value) do
            local keyKind, itemKind = type(key), type(item)
            if (keyKind == "string" or (keyKind == "number" and Finite(key)))
                    and (itemKind == "string" or itemKind == "boolean" or itemKind == "table"
                        or (itemKind == "number" and Finite(item))) then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys, KeyOrder)
        out[#out + 1] = "{"
        for _, key in ipairs(keys) do
            Encode(key, out, depth + 1)
            Encode(value[key], out, depth + 1)
        end
        out[#out + 1] = "}"
    end
end

-- Adler-32 (as zlib), as 8 hex digits.
local function Checksum(text)
    local a, b = 1, 0
    for index = 1, #text do
        a = (a + text:byte(index)) % 65521
        b = (b + a) % 65521
    end
    return ("%08x"):format(b * 65536 + a)
end

function ns.SerializeSettings(addon, settings)
    local out = {}
    Encode(settings, out, 0)
    local data = table.concat(out)
    return PREFIX .. FORMAT .. ":" .. addon .. ":" .. data .. ":" .. Checksum(data)
end

-- Parses the data part: the value and the next position, or nil and why.
local function Decode(data, position, depth, count)
    count.items = count.items + 1
    if count.items > MAX_ITEMS or depth > MAX_DEPTH then
        return nil, "too large"
    end
    local tag = data:sub(position, position)
    if tag == "S" then
        local stop = data:find(";", position + 1, true)
        if not stop then
            return nil, "damaged"
        end
        local raw = data:sub(position + 1, stop - 1)
        -- Only safe bytes and ~XX escapes.
        if raw:gsub("~%x%x", ""):find("[^%w_%.%-]") then
            return nil, "damaged"
        end
        local text = raw:gsub("~(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
        return text, stop + 1
    elseif tag == "N" then
        local stop = data:find(";", position + 1, true)
        local number = stop and tonumber(data:sub(position + 1, stop - 1))
        if not number or not Finite(number) then
            return nil, "damaged"
        end
        return number, stop + 1
    elseif tag == "B" then
        local flag = data:sub(position + 1, position + 1)
        if flag ~= "1" and flag ~= "0" then
            return nil, "damaged"
        end
        return flag == "1", position + 2
    elseif tag == "{" then
        local result = {}
        position = position + 1
        while data:sub(position, position) ~= "}" do
            if position > #data then
                return nil, "damaged"
            end
            local key, value
            key, position = Decode(data, position, depth + 1, count)
            if key == nil then
                return nil, position
            end
            if type(key) ~= "string" and type(key) ~= "number" then
                return nil, "damaged"
            end
            value, position = Decode(data, position, depth + 1, count)
            if value == nil then
                return nil, position
            end
            result[key] = value
        end
        return result, position + 1
    end
    return nil, "damaged"
end

-- The settings table from an export line, or nil and why (a sentence).
function ns.ParseSettings(addon, text)
    if type(text) ~= "string" or IsSecret(text) then
        return nil, "Paste an export line first."
    end
    if #text > MAX_TEXT then
        return nil, "That text is too long to be an export line."
    end
    -- Chat, forums, and mail may wrap a line or add spaces.
    text = text:gsub("%s", "")
    if text == "" then
        return nil, "Paste an export line first."
    end
    local version, from, data, sum = text:match("^" .. PREFIX .. "(%d+):([%w_]+):([^:]*):(%x+)$")
    if not version then
        return nil, "That is not a Dyre's AddOns export line."
    end
    if tonumber(version) > FORMAT then
        return nil, "That line comes from a newer version. Update the AddOns, then try again."
    end
    if tonumber(version) < FORMAT then
        return nil, "That line comes from a test version. Export it again."
    end
    if from ~= addon then
        return nil, "That line has " .. from .. " settings, not " .. addon .. " settings."
    end
    if sum:lower() ~= Checksum(data) then
        return nil, "That line is damaged or incomplete. Copy all of it again."
    end
    local settings, stop = Decode(data, 1, 0, {items = 0})
    if type(settings) ~= "table" or stop ~= #data + 1 then
        return nil, "That line is damaged or incomplete. Copy all of it again."
    end
    return settings
end

-- The profile ------------------------------------------------------------------------

local parts, order = {}, {}
local Profile = {DEFAULTS = DEFAULTS}
ns.profile = Profile

local function ValidAddOn(addon)
    return type(addon) == "string" and #addon <= 64 and addon:match("^[%w_]+$") ~= nil
end

local function SkipSet(list)
    local set = {}
    for _, key in ipairs(type(list) == "table" and list or {}) do
        set[key] = true
    end
    return set
end

local function Store()
    if type(ns.db.profiles) ~= "table" then
        ns.db.profiles = {}
    end
    return ns.db.profiles
end

-- A character's entry, made when create is true. An entry from a 2.10.0
-- test build held one AddOn's settings: it becomes the toolkit's part.
local function Entry(key, create)
    if type(key) ~= "string" then
        return nil
    end
    local store = Store()
    local entry = store[key]
    if type(entry) ~= "table" then
        if not create then
            return nil
        end
        entry = {}
        store[key] = entry
    end
    if type(entry.parts) ~= "table" then
        entry.parts = type(entry.settings) == "table" and {DyresToolkit = entry.settings} or {}
    end
    entry.settings = nil
    if type(entry.pending) ~= "table" then
        entry.pending = {}
    end
    return entry
end

local function ClassName()
    if type(UnitClass) ~= "function" then
        return nil
    end
    local name = UnitClass("player")
    return Readable(name) and name or nil
end

local function Now()
    return type(time) == "function" and time() or 0
end

local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function Title(part)
    return part.spec.title or part.spec.addon
end

-- A part's live settings without its per-character keys.
local function PartSettings(part)
    local current = part.spec.current()
    return type(current) == "table" and Copy(current, part.skip) or {}
end

-- The new settings for a part, repaired by its owner, with this character's
-- own keys kept; nil when the owner cannot take them.
local function Prepare(part, settings)
    local current = part.spec.current()
    if type(current) ~= "table" then
        return nil
    end
    local fresh = Copy(settings, part.skip) or {}
    for key in pairs(part.skip) do
        fresh[key] = Copy(current[key])
    end
    local ok, result = pcall(part.spec.sanitize, fresh)
    if not ok or type(result) ~= "table" then
        return nil
    end
    return result
end

-- target becomes source, keeping target's tables (and any key in skip).
local function WriteInPlace(target, source, skip)
    local gone = {}
    for key in pairs(target) do
        if source[key] == nil and not (skip and skip[key]) then
            gone[#gone + 1] = key
        end
    end
    for _, key in ipairs(gone) do
        target[key] = nil
    end
    for key, value in pairs(source) do
        if not (skip and skip[key]) then
            local old = target[key]
            if type(value) == "table" and type(old) == "table" and old ~= value then
                WriteInPlace(old, value)
            else
                target[key] = value
            end
        end
    end
end
ns.WriteInPlace = WriteInPlace

function Profile:Key()
    return ns.CharacterKey()
end

-- Copies every loaded part (and keeps the others) into this character's entry.
function Profile:Snapshot()
    local entry = Entry(ns.CharacterKey(), true)
    if not entry then
        return
    end
    for _, part in ipairs(order) do
        entry.parts[part.spec.addon] = PartSettings(part)
    end
    entry.class = ClassName() or entry.class
    entry.seen = Now()
end

-- The other characters with a saved profile, by name.
function Profile:Others()
    local key, list = ns.CharacterKey(), {}
    for other, entry in pairs(Store()) do
        if other ~= key and type(other) == "string" and type(entry) == "table"
                and (type(entry.parts) == "table" or type(entry.settings) == "table") then
            list[#list + 1] = other
        end
    end
    table.sort(list)
    return list
end

function Profile:Label(key)
    if key == DEFAULTS then
        return "Defaults (a clean slate)"
    end
    local entry = Store()[key]
    if type(entry) == "table" and Readable(entry.class) then
        return key .. " (" .. entry.class .. ")"
    end
    return tostring(key)
end

-- The settings pages read their values again (SettingMixin:NotifyUpdate,
-- Blizzard_Setting.lua: "the underlying value changed was a source other
-- than the setting object").
local function NotifySettings()
    for _, layout in ipairs(ns.settingsLayouts or {}) do
        local ok, list = false, nil
        if type(layout) == "table" and type(layout.GetInitializers) == "function" then
            ok, list = pcall(layout.GetInitializers, layout)
        end
        for _, initializer in ipairs(ok and type(list) == "table" and list or {}) do
            if type(initializer) == "table" and type(initializer.GetSetting) == "function" then
                local got, setting = pcall(initializer.GetSetting, initializer)
                if got and type(setting) == "table" and type(setting.NotifyUpdate) == "function" then
                    pcall(setting.NotifyUpdate, setting)
                end
            end
        end
    end
end

-- New parts for this character: sources maps AddOn folders to settings, or
-- is DEFAULTS. Gives true and the titles that need a reload, or nil and why.
function Profile:Apply(sources)
    if InCombat() then
        return nil, "Settings change out of combat."
    end
    local entry = Entry(ns.CharacterKey(), true)
    if not entry then
        return nil, "Your character is not ready yet. Try again in a moment."
    end
    local defaults = sources == DEFAULTS
    -- First check every loaded part: all or nothing.
    local prepared = {}
    for _, part in ipairs(order) do
        local settings = defaults and {} or sources[part.spec.addon]
        if settings ~= nil then
            local fresh = Prepare(part, settings)
            if not fresh then
                return nil, Title(part) .. " cannot take those settings. Nothing changed."
            end
            prepared[#prepared + 1] = {part = part, settings = fresh}
        end
    end
    for _, item in ipairs(prepared) do
        WriteInPlace(item.part.spec.current(), item.settings, item.part.skip)
    end
    -- AddOns not loaded on this character: their parts wait for their next load.
    if defaults then
        for addon in pairs(entry.parts) do
            if not parts[addon] then
                entry.parts[addon] = nil
                entry.pending[addon] = {}
            end
        end
    else
        for addon, settings in pairs(sources) do
            if not parts[addon] then
                entry.parts[addon] = Copy(settings)
                entry.pending[addon] = Copy(settings)
            end
        end
    end
    self:Snapshot()
    local reload = {}
    for _, item in ipairs(prepared) do
        local refresh = item.part.spec.refresh
        if type(refresh) ~= "function" or not pcall(refresh) then
            reload[#reload + 1] = Title(item.part)
        end
    end
    NotifySettings()
    return true, reload
end

function Profile:CopyFrom(key)
    if key == DEFAULTS then
        return self:Apply(DEFAULTS)
    end
    local entry = key ~= ns.CharacterKey() and Entry(key) or nil
    if not entry or next(entry.parts) == nil then
        return nil, "That character's settings are not saved."
    end
    return self:Apply(Copy(entry.parts))
end

function Profile:Export()
    local data = {}
    local entry = Entry(ns.CharacterKey())
    for addon, settings in pairs(entry and entry.parts or {}) do
        if ValidAddOn(addon) and type(settings) == "table" then
            data[addon] = settings
        end
    end
    for _, part in ipairs(order) do
        data[part.spec.addon] = PartSettings(part)
    end
    return ns.SerializeSettings(KIND, data)
end

function Profile:Import(text)
    local data, why = ns.ParseSettings(KIND, text)
    if not data then
        return nil, why
    end
    for addon, settings in pairs(data) do
        if not ValidAddOn(addon) or type(settings) ~= "table" then
            return nil, "That line is damaged or incomplete. Copy all of it again."
        end
    end
    return self:Apply(data)
end

-- An AddOn's part of the profile. Gives true, or nil for a bad spec.
function DyresToolkit.RegisterProfilePart(spec)
    if type(spec) ~= "table" or not ValidAddOn(spec.addon) or type(spec.current) ~= "function"
            or type(spec.sanitize) ~= "function" or (spec.refresh ~= nil and type(spec.refresh) ~= "function")
            or (spec.title ~= nil and type(spec.title) ~= "string") then
        return nil
    end
    local part = {spec = spec, skip = SkipSet(spec.characterKeys)}
    if parts[spec.addon] then
        for index, old in ipairs(order) do
            if old == parts[spec.addon] then
                order[index] = part
            end
        end
    else
        order[#order + 1] = part
    end
    parts[spec.addon] = part
    -- A part copied or imported while this AddOn was not loaded here.
    local entry = Entry(ns.CharacterKey())
    local waiting = entry and entry.pending[spec.addon]
    if waiting ~= nil then
        entry.pending[spec.addon] = nil
        local fresh = type(waiting) == "table" and Prepare(part, waiting)
        if fresh then
            WriteInPlace(spec.current(), fresh, part.skip)
        end
    end
    Profile:Snapshot()
    return true
end

function DyresToolkit.ProfileParts()
    local list = {}
    for _, part in ipairs(order) do
        list[#list + 1] = part.spec.addon
    end
    return list
end

-- The copies follow every change made since login.
local logout = CreateFrame("Frame")
logout:RegisterEvent("PLAYER_LOGOUT")
logout:SetScript("OnEvent", function()
    if #order > 0 then
        Profile:Snapshot()
    end
end)

-- The settings section ---------------------------------------------------------------

local WHAT = "this character's settings for every Dyre's AddOn (settings, places, sizes, and sounds)"

local function Reload()
    if type(ReloadUI) == "function" then
        ReloadUI()
    end
end

local Show

-- After a copy or import: a reload only for the AddOns that cannot change live.
local function Done(what, reload)
    if #reload == 0 then
        ns.Report(what .. ".")
        return
    end
    Show("DYRE_PROFILE_RELOAD", what .. ". Reload to finish " .. table.concat(reload, ", ") .. ".", {})
end

local function Popups()
    if type(StaticPopupDialogs) ~= "table" or StaticPopupDialogs.DYRE_PROFILE_COPY then
        return type(StaticPopupDialogs) == "table"
    end
    StaticPopupDialogs.DYRE_PROFILE_COPY = {
        text = "%s",
        button1 = "Copy",
        button2 = CANCEL or "Cancel",
        OnAccept = function(_, data)
            local ok, why = Profile:CopyFrom(data.key)
            if ok then
                Done("Profile copied", why)
            else
                ns.Report(why)
            end
        end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = 3,
    }
    StaticPopupDialogs.DYRE_PROFILE_EXPORT = {
        text = "%s",
        button1 = DONE or "Done",
        hasEditBox = 1,
        maxLetters = MAX_TEXT,
        editBoxWidth = 350,
        OnShow = function(dialog, data)
            local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
            if box then
                box:SetText(data.text)
                box:HighlightText()
                box:SetFocus()
            end
        end,
        -- Read only: any typing puts the line back.
        EditBoxOnTextChanged = function(box, data)
            if box:GetText() ~= data.text then
                box:SetText(data.text)
                box:HighlightText()
            end
        end,
        EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = 3,
    }
    StaticPopupDialogs.DYRE_PROFILE_IMPORT = {
        text = "%s",
        button1 = "Import",
        button2 = CANCEL or "Cancel",
        hasEditBox = 1,
        maxLetters = MAX_TEXT,
        editBoxWidth = 350,
        OnShow = function(dialog)
            local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
            if box then
                box:SetText("")
                box:SetFocus()
            end
        end,
        OnAccept = function(dialog)
            local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
            local ok, why = Profile:Import(box and box:GetText())
            if ok then
                Done("Profile imported", why)
                return
            end
            ns.Report(why)
            -- True keeps the popup open, so the player can paste again.
            return true
        end,
        EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = 3,
    }
    StaticPopupDialogs.DYRE_PROFILE_RELOAD = {
        text = "%s",
        button1 = "Reload now",
        button2 = "Later",
        OnAccept = Reload,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = 3,
    }
    return true
end

Show = function(which, text, data)
    if InCombat() then
        ns.Report("Settings change out of combat.")
        return
    end
    if not Popups() or type(StaticPopup_Show) ~= "function" then
        return
    end
    StaticPopup_Show(which, text, nil, data)
end

-- A button at the right of a settings row's control (John, 2026-11-15:
-- "Can we move the "Copy" button to the right of the select?"). The client
-- has no row with a dropdown and a button (Blizzard_SettingControls.lua), so
-- this wraps the row initializer's InitFrame and Resetter. The settings list
-- pools its row frames and calls the Resetter before a frame is reused
-- (Blizzard_SettingsList.lua SetElementResetter), so the button is shown only
-- while the frame draws this row, and hidden when another row takes the frame.
-- `enabled()` (optional) greys the button while it returns false; the
-- returned function checks it again (a change of the row's value does not
-- run InitFrame).
-- Returns nil without those methods or CreateFrame; the caller then adds a
-- button row as before.
local function AttachRowButton(initializer, text, onClick, tooltip, enabled)
    if type(initializer) ~= "table" or type(initializer.InitFrame) ~= "function"
            or type(initializer.Resetter) ~= "function" or type(CreateFrame) ~= "function" then
        return nil
    end
    local initFrame, resetter = initializer.InitFrame, initializer.Resetter
    local shown = {}
    local function Update()
        for button in pairs(shown) do
            if button.SetEnabled then
                button:SetEnabled(not enabled or enabled() and true or false)
            end
        end
    end
    function initializer:InitFrame(frame)
        initFrame(self, frame)
        local button = frame.dyreRowButton
        if not button then
            button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            button:SetSize(80, 22)
            button:SetScript("OnLeave", function()
                if GameTooltip then
                    GameTooltip:Hide()
                end
            end)
            frame.dyreRowButton = button
        end
        local control = frame.Control
        local after = control and (control.IncrementButton or control.Dropdown) or control
        button:ClearAllPoints()
        if after then
            button:SetPoint("LEFT", after, "RIGHT", 8, 0)
        else
            button:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
        end
        button:SetText(text)
        button:SetScript("OnClick", function()
            onClick()
        end)
        button:SetScript("OnEnter", function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(text, 1, 0.82, 0)
                GameTooltip:AddLine(type(tooltip) == "function" and tooltip() or tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        if button.SetMotionScriptsWhileDisabled then
            button:SetMotionScriptsWhileDisabled(true)
        end
        shown[button] = true
        Update()
        button:Show()
    end
    function initializer:Resetter(frame)
        if frame.dyreRowButton then
            shown[frame.dyreRowButton] = nil
            frame.dyreRowButton:Hide()
        end
        return resetter(self, frame)
    end
    return Update
end

-- The "Profile" section at the end of the toolkit's own page: this
-- character's name in the header (John, 2026-11-15: not seeing it "is
-- disconcerting"), "Copy settings from" (Defaults, then the other
-- characters) with Copy at its right, Export, and Import.
function ns.AddProfileSettings(category, layout)
    if type(layout) ~= "table" or type(layout.AddInitializer) ~= "function"
            or type(Settings) ~= "table" or type(CreateSettingsButtonInitializer) ~= "function" then
        return nil
    end
    local key = ns.CharacterKey()
    if type(CreateSettingsListSectionHeaderInitializer) == "function" then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
            key and ("Profile: " .. Profile:Label(key)) or "Profile",
            "Each character has one profile, its own: its settings for every Dyre's AddOn."))
    end
    -- This character's own profile is first in the list and chosen at first,
    -- and Copy is grey while it is chosen (John, 2026-11-15: "put my current
    -- character's profile in the list, fixed at the top, selected by default,
    -- with the "Copy" button disabled").
    local own = key or DEFAULTS
    local source = own
    local rows = {}
    if type(Settings.CreateDropdown) == "function" and type(Settings.CreateControlTextContainer) == "function"
            and type(Settings.RegisterProxySetting) == "function" then
        local updateCopy
        local function CanCopy()
            return source ~= own
        end
        local setting = Settings.RegisterProxySetting(category, "DYRE_PROFILE_SOURCE", Settings.VarType.String,
            "Copy settings from", own,
            function() return source end,
            function(value)
                local found = value == own or value == DEFAULTS
                for _, other in ipairs(Profile:Others()) do
                    if other == value then
                        found = true
                    end
                end
                if found then
                    source = value
                end
                if updateCopy then
                    updateCopy()
                end
            end)
        local function Options()
            local container = Settings.CreateControlTextContainer()
            if key then
                container:Add(key, Profile:Label(key) .. " (this character)")
            end
            container:Add(DEFAULTS, Profile:Label(DEFAULTS))
            for _, other in ipairs(Profile:Others()) do
                container:Add(other, Profile:Label(other))
            end
            return container:GetData()
        end
        rows.source = Settings.CreateDropdown(category, setting, Options,
            "Pick another character's profile, or Defaults for a clean slate, then press Copy. It covers "
            .. "every Dyre's AddOn.\n\nA character shows here after it logs in once with this version.")
        local function CopyChoice()
            if not CanCopy() then
                ns.Report("Pick another character's profile, or Defaults, to copy.")
                return
            end
            Show("DYRE_PROFILE_COPY", "Copy " .. Profile:Label(source) .. " to " .. (key and Profile:Label(key)
                or "this character") .. "?\n\nThis replaces " .. WHAT .. ".", {key = source})
        end
        local function CopyTooltip()
            if CanCopy() then
                return "Replaces " .. WHAT .. " with the choice."
            end
            return "Pick another character's profile, or Defaults, to copy."
        end
        updateCopy = AttachRowButton(rows.source, "Copy", CopyChoice, CopyTooltip, CanCopy)
        if updateCopy then
            rows.copyOnRow = true
        else
            rows.copy = CreateSettingsButtonInitializer("Copy the choice above", "Copy", CopyChoice,
                "Replaces " .. WHAT .. " with the choice.", true)
            if type(rows.copy) == "table" and type(rows.copy.AddModifyPredicate) == "function" then
                rows.copy:AddModifyPredicate(CanCopy)
            end
            layout:AddInitializer(rows.copy)
        end
    end
    rows.export = CreateSettingsButtonInitializer("Export profile", "Export", function()
        Show("DYRE_PROFILE_EXPORT", "Press Ctrl+C to copy " .. WHAT .. ".\nPaste it with Import on another "
            .. "character or account.", {text = Profile:Export()})
    end, "Shows " .. WHAT .. " as one line of text, to copy and keep or share.", true)
    layout:AddInitializer(rows.export)
    rows.import = CreateSettingsButtonInitializer("Import profile", "Import", function()
        Show("DYRE_PROFILE_IMPORT", "Paste an export line (Ctrl+V).\n\nThis replaces " .. WHAT .. ".", {})
    end, "Replaces " .. WHAT .. " with a pasted export line.", true)
    layout:AddInitializer(rows.import)
    return rows
end
