local _, ns = ...
local DyresToolkit = ns.toolkit

-- The settings home: one "Dyre's AddOns" entry in Options > AddOns with the
-- toolkit's own settings, and each Dyre's AddOn's page under it (the settings
-- list draws sub-pages to any depth: CreateSection in Blizzard's
-- CategoryList.lua). The category is made the first time anyone asks for it,
-- so it does not matter whose PLAYER_LOGIN runs first.

local HOME = "Dyre's AddOns"
local REQUIRED = {
    "RegisterVerticalLayoutCategory", "RegisterVerticalLayoutSubcategory", "RegisterProxySetting",
    "RegisterAddOnCategory", "CreateCheckbox", "CreateSlider", "CreateSliderOptions", "OpenToCategory",
}

local home, homeLayout

local function HasSettingsAPI()
    if type(Settings) ~= "table" or type(Settings.VarType) ~= "table" then
        return false
    end
    for _, name in ipairs(REQUIRED) do
        if type(Settings[name]) ~= "function" then
            return false
        end
    end
    return true
end

local function Home()
    if not home and HasSettingsAPI() then
        home, homeLayout = Settings.RegisterVerticalLayoutCategory(HOME)
        Settings.RegisterAddOnCategory(home)
    end
    return home, homeLayout
end

function DyresToolkit.SettingsCategory()
    return (Home())
end

-- Under the "Dyre's AddOns" heading, "Dyre's " is said once (author-approved):
-- "Dyre's Buff Reminders" shows as "Buff Reminders". Other names stay.
function ns.ShortName(name)
    local short = type(name) == "string" and name:match("^Dyre's%s+(%S.*)$")
    return short or name
end

-- A page under "Dyre's AddOns": the category and its layout, or nil without
-- the settings API (the AddOn then makes its own top-level page).
function DyresToolkit.RegisterSettingsCategory(name)
    if type(name) ~= "string" or not name:find("%S") then
        return nil
    end
    local parent = Home()
    if not parent then
        return nil
    end
    return Settings.RegisterVerticalLayoutSubcategory(parent, ns.ShortName(name))
end

-- No panels in combat.
function DyresToolkit.OpenSettings(category)
    local target = category or Home()
    if not target then
        ns.Report("The settings page is unavailable on this client. Use /dyre unlock and /dyre lock.")
        return false
    end
    if InCombatLockdown() then
        ns.Report("The settings open out of combat.")
        return false
    end
    Settings.OpenToCategory(target:GetID())
    return true
end

local function Member(addon)
    for _, info in ipairs(DyresToolkit.AddOns()) do
        if info.addon == addon then
            return info
        end
    end
end

-- A row on an AddOn's page that opens another Dyre's AddOn's page (2.3.0;
-- author-approved: a feature that moved to another AddOn is linked, not
-- mirrored). opts: addon (folder), name (the row's label), button (default
-- "Open settings"), tooltip, missing (said in chat, and the tooltip, while
-- that AddOn has not joined the toolkit: not installed or not enabled). The
-- button is greyed while it is missing; the check runs each time the page
-- draws, so an AddOn that joins later counts.
function DyresToolkit.AddSettingsLink(category, layout, opts)
    if type(opts) ~= "table" or type(opts.addon) ~= "string" or type(opts.name) ~= "string"
            or type(CreateSettingsButtonInitializer) ~= "function" or type(layout) ~= "table"
            or type(layout.AddInitializer) ~= "function" then
        return nil
    end
    local missing = opts.missing or ("Install " .. opts.addon .. " from CurseForge.")
    local function Open()
        local info = Member(opts.addon)
        if not info or type(info.openSettings) ~= "function" then
            ns.Report(missing)
            return
        end
        if InCombatLockdown() then
            ns.Report("The settings open out of combat.")
            return
        end
        info.openSettings()
    end
    local present = Member(opts.addon) ~= nil
    local initializer = CreateSettingsButtonInitializer(opts.name, opts.button or "Open settings", Open,
        present and opts.tooltip or missing, true)
    if type(initializer.AddModifyPredicate) == "function" then
        initializer:AddModifyPredicate(function() return Member(opts.addon) ~= nil end)
    end
    layout:AddInitializer(initializer)
    return initializer
end

local function Flag(variable, name, get, set, tooltip)
    local setting = Settings.RegisterProxySetting(home, variable, Settings.VarType.Boolean, name, false, get, set)
    return Settings.CreateCheckbox(home, setting, tooltip)
end

function ns.InitializeSettings()
    if not Home() then
        return
    end
    Flag("DYRE_UNLOCKED", "Unlock frames", function() return not ns.db.locked end,
        function(value) DyresToolkit.SetLocked(value ~= true) end,
        "Every Dyre's AddOn shows its frames to drag. Shift-drag moves a group of snapped frames. "
            .. "/dyre unlock and /dyre lock do the same.")
    Flag("DYRE_GRID", "Show the grid", function() return ns.db.grid end, ns.SetGrid,
        "While frames are unlocked, a grid across the screen with red lines through its center.")
    Flag("DYRE_SNAP_GRID", "Snap to the grid", function() return ns.db.snapToGrid end, ns.SetSnapToGrid,
        "A frame you drop near a red center line centers on it, or puts its nearer edge on it. Elsewhere, an "
            .. "edge within a quarter of the grid size of a grey line lines up with it; when both edges are that "
            .. "close, the one that moves the least wins, so check both corners. Snapping to another Dyre's frame "
            .. "comes first. Hold Ctrl as you drop to place a frame exactly.")
    local size = Settings.RegisterProxySetting(home, "DYRE_GRID_SIZE", Settings.VarType.Number, "Grid size",
        ns.DEFAULT_GRID, function() return ns.db.gridSize end, ns.SetGridSize)
    local options = Settings.CreateSliderOptions(ns.GRID_MIN, ns.GRID_MAX, ns.GRID_STEP)
    if type(options.SetLabelFormatter) == "function" and type(MinimalSliderWithSteppersMixin) == "table"
            and MinimalSliderWithSteppersMixin.Label then
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    end
    Settings.CreateSlider(home, size, options, "The space between grid lines.")
    Flag("DYRE_MINIMAP", "Minimap button", function() return not ns.db.minimap.hide end, ns.SetMinimapShown,
        "Left-click locks or unlocks frames; right-click opens a menu. /dyre minimap does the same.")
end
