local _, ns = ...
local DyresToolkit = ns.toolkit

-- Widgets (contract 2, author-approved 2026-10-20: "all the widget layout,
-- snapping, modifier key move rules, etc., centralized in Dyre's Tools, so
-- the individual packs do not have to worry about it"). An AddOn asks for a
-- widget, puts its own content inside, and never places, drags, scales, or
-- saves it itself. The toolkit owns:
--   - placement from the AddOn's saved table, and its default place;
--   - the gold outline and hint while frames are unlocked, and dragging with
--     every Layout.lua rule (magnetic snapping, the grid, Shift-drag groups,
--     Ctrl for an exact place, a drop in combat waits);
--   - scale, width, height, and opacity, each a setting with a gold default
--     mark and "Reset size", applied from the center (ResizeFromCenter);
--   - the mouse: a widget takes clicks only while unlocked, unless the AddOn
--     says it needs them (a visible bar of buttons) or manages them itself;
--   - combat: a protected widget (secure, or holding secure frames) moves,
--     resizes, and changes its mouse only out of combat; asked in combat, it
--     waits for PLAYER_REGEN_ENABLED. Opacity applies at once.
-- The AddOn's saved table holds the place as {point, relativePoint, x, y}
-- and the numbers as plain values, under keys it may rename for old saves.

local DEFAULT_KEYS = {position = "position", scale = "scale", width = "width", height = "height",
    opacity = "opacity"}
local LABELS = {scale = "Size", width = "Width", height = "Height", opacity = "Opacity"}
local PERCENT = {scale = true, opacity = true}
local DEFAULT_SCALE = {min = 50, max = 150, step = 5, default = 100}
local DEFAULT_OPACITY = {min = 10, max = 100, step = 5, default = 100}
local MOVER_INSET = 4
local MOVER_EDGE = 14
local GOLD = {1, 0.82, 0}

local widgets, byAddOn = {}, {}
local waiting = {}

local function IsProtected(frame)
    return type(frame.IsProtected) == "function" and frame:IsProtected() == true
end

-- Rounds to the step and clamps; anything else becomes the default.
local function Clamp(spec, value)
    if type(value) ~= "number" or value ~= value then
        return spec.default
    end
    value = spec.min + math.floor((value - spec.min) / spec.step + 0.5) * spec.step
    return math.max(spec.min, math.min(spec.max, value))
end

local function SizeSpecs(spec)
    local sizes = {}
    local wanted = spec.sizes or {}
    if wanted.scale then
        sizes.scale = type(wanted.scale) == "table" and wanted.scale or DEFAULT_SCALE
    end
    for _, name in ipairs({"width", "height"}) do
        local range = wanted[name]
        if type(range) == "table" then
            sizes[name] = {min = range.min, max = range.max, step = range.step or 1,
                default = range.default or spec[name]}
        end
    end
    if wanted.opacity then
        sizes.opacity = type(wanted.opacity) == "table" and wanted.opacity or DEFAULT_OPACITY
    end
    -- The AddOn's own size settings (a bar's line height, its text size):
    -- spec.measure turns them into the frame's width and height.
    local custom = {}
    for name, range in pairs(wanted) do
        if not sizes[name] and type(range) == "table" then
            sizes[name] = range
            custom[#custom + 1] = name
        end
    end
    table.sort(custom)
    local order = {}
    for _, name in ipairs(spec.sizeOrder or {}) do
        if sizes[name] then order[#order + 1] = name end
    end
    local listed = {}
    for _, name in ipairs(order) do listed[name] = true end
    for _, name in ipairs({"scale", "width", "height"}) do
        if sizes[name] and not listed[name] then order[#order + 1] = name; listed[name] = true end
    end
    for _, name in ipairs(custom) do
        if not listed[name] then order[#order + 1] = name; listed[name] = true end
    end
    if sizes.opacity and not listed.opacity then order[#order + 1] = "opacity" end
    sizes.order = order
    for _, name in ipairs(order) do
        local range = sizes[name]
        assert(type(range.min) == "number" and type(range.max) == "number" and range.min < range.max
            and type(range.step) == "number" and range.step > 0 and type(range.default) == "number",
            "DyresToolkit.CreateWidget: bad " .. name .. " range")
    end
    return sizes
end

local function Value(widget, name)
    return widget.dyre.store[widget.dyre.keys[name]]
end

-- The widget's scale and size now, from its settings and content.
local function Wanted(widget)
    local scale = widget.dyre.sizes.scale and Value(widget, "scale") / 100 or 1
    if widget.dyre.measure then
        local width, height = widget.dyre.measure(widget)
        return scale, width, height
    end
    local width = widget.dyre.sizes.width and Value(widget, "width") or widget.dyre.contentWidth
    local height = widget.dyre.sizes.height and Value(widget, "height") or widget.dyre.contentHeight
    return scale, width, height
end

local function MouseWanted(widget)
    if widget.dyre.mouseMode == "always" then
        return true
    end
    return not ns.db.locked
end

local function Wait(widget)
    waiting[widget] = true
    ns.widgetEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
end

-- Size, scale, and mouse; a protected widget only out of combat.
local function Apply(widget)
    if InCombatLockdown() and IsProtected(widget) then
        Wait(widget)
        return false
    end
    local scale, width, height = Wanted(widget)
    DyresToolkit.ResizeFromCenter(widget, scale, width, height, widget.dyre.growAnchor)
    -- The edge holds for this content change only; settings resize from the center.
    widget.dyre.growAnchor = nil
    if widget.dyre.mouseMode ~= "client" then
        widget:EnableMouse(MouseWanted(widget))
    end
    if widget.dyre.onLayout then
        widget.dyre.onLayout(widget, width, height, scale)
    end
    return true
end

local function ApplyOpacity(widget)
    if not widget.dyre.sizes.opacity then
        return
    end
    local alpha = Value(widget, "opacity") / 100
    widget:SetAlpha(alpha)
    if widget.dyre.onOpacity then
        widget.dyre.onOpacity(widget, alpha)
    end
end

local function Place(widget)
    local position = Value(widget, "position")
    local default = widget.dyre.point
    widget:ClearAllPoints()
    if type(position) == "table" and type(position.x) == "number" and type(position.y) == "number" then
        widget:SetPoint(position.point or "CENTER", UIParent, position.relativePoint or "BOTTOMLEFT",
            position.x, position.y)
    else
        widget:SetPoint(default.point, UIParent, default.relativePoint, default.x, default.y)
    end
end

-- The first placement: scale and size first, so a saved place (in the
-- widget's own scaled units, as it was saved) lands where it was.
local function Setup(widget)
    if InCombatLockdown() and IsProtected(widget) then
        widget.dyre.needsSetup = true
        Wait(widget)
        return
    end
    widget.dyre.needsSetup = nil
    local scale, width, height = Wanted(widget)
    widget:SetScale(scale)
    -- A widget that grows from an edge was saved at its size then; its
    -- size now can differ (content not in yet), so it goes back at the saved
    -- size and resizes keeping that edge, or it would drift on each reload.
    local position = Value(widget, "position")
    if type(position) == "table" and type(position.anchor) == "string" and type(position.width) == "number"
            and type(position.height) == "number" then
        widget:SetSize(position.width, position.height)
        Place(widget)
        widget.dyre.lastAnchor = position.anchor
        DyresToolkit.ResizeFromCenter(widget, nil, width, height, position.anchor)
    else
        widget:SetSize(width, height)
        Place(widget)
    end
    if widget.dyre.mouseMode ~= "client" then
        widget:EnableMouse(MouseWanted(widget))
    end
    ApplyOpacity(widget)
    if widget.dyre.onLayout then
        widget.dyre.onLayout(widget, width, height, scale)
    end
end

local function CreateMover(widget)
    local mover = CreateFrame("Frame", nil, widget, "BackdropTemplate")
    mover:SetPoint("TOPLEFT", -MOVER_INSET, MOVER_INSET)
    mover:SetPoint("BOTTOMRIGHT", MOVER_INSET, -MOVER_INSET)
    if mover.SetBackdrop then
        mover:SetBackdrop({edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = MOVER_EDGE})
        mover:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3])
    end
    mover:EnableMouse(false)
    mover.hint = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mover.hint:SetPoint("BOTTOM", mover, "TOP", 0, 2)
    mover.hint:SetText(widget.dyre.hint or (widget.dyre.title .. " · drag to move · /dyre lock when done"))
    return mover
end

-- The lock changed: outlines, the AddOn's samples, and the mouse.
function ns.RefreshWidgets()
    local unlocked = not ns.db.locked
    for _, widget in ipairs(widgets) do
        widget.dyre.mover:SetShown(unlocked)
        if widget.dyre.onUnlock then
            widget.dyre.onUnlock(widget, unlocked)
        end
        if widget.dyre.mouseMode ~= "client" then
            if InCombatLockdown() and IsProtected(widget) then
                Wait(widget)
            else
                widget:EnableMouse(MouseWanted(widget))
            end
        end
    end
end

ns.widgetEvents = CreateFrame("Frame")
ns.widgetEvents:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    local pending = waiting
    waiting = {}
    for _, widget in ipairs(widgets) do
        if pending[widget] then
            if widget.dyre.needsSetup then
                Setup(widget)
            else
                Apply(widget)
            end
        end
    end
end)

local WidgetMethods = {}

-- A size that comes from the content (a bar holding as many buttons as
-- spells you know), not from a setting. Applied from the center.
-- anchor: "LEFT", "RIGHT", "TOP", "BOTTOM", or a corner ("TOPLEFT") keeps
-- that edge or corner fixed (a bar growing left to right, a box collapsing
-- toward its top); "CENTER" (the default) keeps the center.
function WidgetMethods.SetContentSize(widget, width, height, anchor)
    widget.dyre.contentWidth, widget.dyre.contentHeight = width, height
    widget.dyre.growAnchor = anchor
    if anchor and anchor ~= "CENTER" then
        widget.dyre.lastAnchor = anchor
    end
    Apply(widget)
end

-- One of scale, width, height, opacity: clamped, saved, and applied.
function WidgetMethods.SetSetting(widget, name, value)
    local range = name ~= "order" and widget.dyre.sizes[name]
    if not range then
        return
    end
    widget.dyre.store[widget.dyre.keys[name]] = Clamp(range, value)
    if name == "opacity" then
        ApplyOpacity(widget)
    else
        Apply(widget)
    end
end

function WidgetMethods.GetSetting(widget, name)
    return name ~= "order" and widget.dyre.sizes[name] and Value(widget, name) or nil
end

-- Back to the default scale, width, and height; opacity stays (as MTF's and
-- WTF's "Reset size").
function WidgetMethods.ResetSize(widget)
    for _, name in ipairs(widget.dyre.resetSizes or widget.dyre.sizes.order) do
        local range = widget.dyre.sizes[name]
        if range and name ~= "order" and (widget.dyre.resetSizes or name ~= "opacity") then
            widget.dyre.store[widget.dyre.keys[name]] = range.default
        end
    end
    Apply(widget)
end

-- A child the player may drag the widget by (a bar's buttons, which leave
-- only a thin edge of the bar itself). Clicks still reach the child.
function WidgetMethods.AddDragHandle(widget, child)
    child:RegisterForDrag("LeftButton")
    child:SetScript("OnDragStart", function() DyresToolkit.BeginDrag(widget) end)
    child:SetScript("OnDragStop", function() DyresToolkit.EndDrag(widget) end)
end

function WidgetMethods.ResetPosition(widget)
    widget.dyre.store[widget.dyre.keys.position] = nil
    if InCombatLockdown() and IsProtected(widget) then
        widget.dyre.needsSetup = true
        Wait(widget)
        return
    end
    Place(widget)
end

-- spec: addon, key, title, store (the AddOn's saved table), width, height
-- (the size at 100%), point {point, relativePoint, x, y} from UIParent
-- (default its center); optional frame (the AddOn's own frame, such as a
-- named secure button), name, keys (renamed save keys), sizes {scale = true
-- or a range, width/height = ranges, opacity = true or a range, and any
-- AddOn setting = a range with label (and percent = true)}, sizeOrder (the
-- sliders' order; opacity last), measure(widget) -> width, height (the frame
-- size from the settings, for sizes such as a bar's line height),
-- resetSizes (what "Reset size" restores; default every size but opacity),
-- hint (the outline's text while unlocked), mouse
-- ("unlocked", the default; "always"; "client"), and callbacks
-- onLayout(widget, width, height, scale), onOpacity(widget, alpha),
-- onUnlock(widget, unlocked).
function DyresToolkit.CreateWidget(spec)
    assert(type(spec) == "table", "DyresToolkit.CreateWidget: spec table expected")
    assert(type(spec.addon) == "string" and type(spec.key) == "string", "DyresToolkit.CreateWidget: addon and key")
    assert(type(spec.store) == "table", "DyresToolkit.CreateWidget: store must be the AddOn's saved table")
    assert(type(spec.width) == "number" and type(spec.height) == "number", "DyresToolkit.CreateWidget: width, height")
    local widget = spec.frame or CreateFrame("Frame", spec.name, UIParent)
    assert(widget.dyre == nil, "DyresToolkit.CreateWidget: this frame is a widget already")
    -- All the toolkit's state lives here, so it never clashes with the AddOn's own fields.
    widget.dyre = {}
    widget.dyre.addon, widget.dyre.widgetKey = spec.addon, spec.key
    widget.dyre.title = spec.title or spec.key
    widget.dyre.store = spec.store
    widget.dyre.keys = {}
    widget.dyre.sizes = SizeSpecs(spec)
    for name, key in pairs(DEFAULT_KEYS) do
        widget.dyre.keys[name] = spec.keys and spec.keys[name] or key
    end
    for _, name in ipairs(widget.dyre.sizes.order) do
        widget.dyre.keys[name] = widget.dyre.keys[name] or (spec.keys and spec.keys[name]) or name
    end
    widget.dyre.measure = spec.measure
    widget.dyre.resetSizes = spec.resetSizes
    widget.dyre.hint = spec.hint
    widget.dyre.contentWidth, widget.dyre.contentHeight = spec.width, spec.height
    local point = spec.point or {}
    widget.dyre.point = {point = point.point or point[1] or "CENTER", relativePoint = point.relativePoint or point[2]
        or "CENTER", x = point.x or point[3] or 0, y = point.y or point[4] or 0}
    widget.dyre.mouseMode = spec.mouse or "unlocked"
    widget.dyre.onLayout, widget.dyre.onOpacity, widget.dyre.onUnlock = spec.onLayout, spec.onOpacity, spec.onUnlock
    -- Repair the saved numbers.
    for _, name in ipairs(widget.dyre.sizes.order) do
        local key = widget.dyre.keys[name]
        widget.dyre.store[key] = Clamp(widget.dyre.sizes[name], widget.dyre.store[key])
    end
    for name, method in pairs(WidgetMethods) do
        widget[name] = method
    end
    widget:SetMovable(true)
    widget:SetClampedToScreen(true)
    widget:RegisterForDrag("LeftButton")
    widget:SetScript("OnDragStart", DyresToolkit.BeginDrag)
    widget:SetScript("OnDragStop", DyresToolkit.EndDrag)
    DyresToolkit.RegisterMovable(widget, function(position)
        -- The size and grow edge too, so Setup can restore the place exactly.
        if widget.dyre.lastAnchor then
            position.anchor = widget.dyre.lastAnchor
            position.width, position.height = widget:GetWidth(), widget:GetHeight()
        end
        widget.dyre.store[widget.dyre.keys.position] = position
    end)
    widget.dyre.mover = CreateMover(widget)
    widget.dyre.mover:SetShown(not ns.db.locked)
    widgets[#widgets + 1] = widget
    byAddOn[spec.addon] = byAddOn[spec.addon] or {}
    byAddOn[spec.addon][#byAddOn[spec.addon] + 1] = widget
    Setup(widget)
    if widget.dyre.onUnlock and not ns.db.locked then
        widget.dyre.onUnlock(widget, true)
    end
    return widget
end

-- An AddOn's reset command: every widget of it back to its default place.
function DyresToolkit.ResetWidgets(addon)
    for _, widget in ipairs(byAddOn[addon] or {}) do
        widget:ResetPosition()
    end
end

function DyresToolkit.Widgets(addon)
    local list = {}
    for _, widget in ipairs(byAddOn[addon] or {}) do
        list[#list + 1] = widget
    end
    return list
end

-- Settings: a slider per size the widget has, each with a gold mark at its
-- default, then "Reset size". The settings panel reuses slider frames, so the
-- mark is drawn when this setting's frame is set up and hidden on release.
local TICK_WIDTH, TICK_HEIGHT = 2, 12

local function PlaceTick(slider)
    local tick = slider.dyreDefaultTick
    local info = tick.info
    local thumb = slider:GetThumbTexture()
    local half = thumb and thumb:GetWidth() / 2 or 0
    local fraction = (info.default - info.min) / (info.max - info.min)
    tick:ClearAllPoints()
    tick:SetPoint("CENTER", slider, "LEFT", half + fraction * (slider:GetWidth() - 2 * half), 0)
end

function ns.AddDefaultTick(initializer, range)
    if type(initializer) ~= "table" or type(initializer.InitFrame) ~= "function" then
        return
    end
    initializer.dyreDefault = range
    local baseInitFrame = initializer.InitFrame
    initializer.InitFrame = function(self, frame)
        baseInitFrame(self, frame)
        local slider = frame.SliderWithSteppers and frame.SliderWithSteppers.Slider
        if not slider then
            return
        end
        local tick = slider.dyreDefaultTick
        if not tick then
            tick = slider:CreateTexture(nil, "BORDER")
            tick:SetSize(TICK_WIDTH, TICK_HEIGHT)
            tick:SetColorTexture(GOLD[1], GOLD[2], GOLD[3])
            slider.dyreDefaultTick = tick
            slider:HookScript("OnSizeChanged", function()
                if tick:IsShown() then
                    PlaceTick(slider)
                end
            end)
            hooksecurefunc(frame, "Release", function()
                tick:Hide()
            end)
        end
        tick.info = initializer.dyreDefault
        PlaceTick(slider)
        tick:Show()
    end
end

-- For an AddOn's own sliders (2.2.0): range = {min, max, default}.
DyresToolkit.AddDefaultTick = ns.AddDefaultTick

local function SliderOptions(name, range)
    local options = Settings.CreateSliderOptions(range.min, range.max, range.step)
    if type(MinimalSliderWithSteppersMixin) == "table" and type(options.SetLabelFormatter) == "function" then
        local formatter = (PERCENT[name] or range.percent) and function(value) return string.format("%d%%", value) end or nil
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
    end
    return options
end

local function VariableName(widget, name)
    return ("DYRE_" .. widget.dyre.addon .. "_" .. widget.dyre.widgetKey .. "_" .. name):upper():gsub("[^%w_]", "_")
end

-- opts: labels (name -> text), tooltips (name -> text), resetLabel, resetTooltip.
function DyresToolkit.AddWidgetSettings(category, layout, widget, opts)
    if type(Settings) ~= "table" or type(category) ~= "table" or type(widget) ~= "table" or not widget.dyre.sizes then
        return false
    end
    opts = opts or {}
    local labels, tooltips = opts.labels or {}, opts.tooltips or {}
    local variables = {}
    for _, name in ipairs(widget.dyre.sizes.order) do
        local range = widget.dyre.sizes[name]
        if range then
            local variable = VariableName(widget, name)
            variables[#variables + 1] = variable
            local label = labels[name] or range.label or LABELS[name] or name
            local setting = Settings.RegisterProxySetting(category, variable, Settings.VarType.Number, label,
                range.default, function() return widget:GetSetting(name) end,
                function(value) widget:SetSetting(name, value) end)
            local tooltip = tooltips[name] or (name == "opacity"
                and "How solid it is. It fades at once, also in combat."
                or ("Its " .. label:lower():gsub(" %(%%%)", "") .. ". A change in combat applies when combat ends."))
            ns.AddDefaultTick(Settings.CreateSlider(category, setting, SliderOptions(name, range), tooltip), range)
        end
    end
    local resizable = #widget.dyre.sizes.order > (widget.dyre.sizes.opacity and 1 or 0)
    if resizable and type(CreateSettingsButtonInitializer) == "function" and type(layout) == "table"
            and type(layout.AddInitializer) == "function" then
        layout:AddInitializer(CreateSettingsButtonInitializer(widget.dyre.title, opts.resetLabel or "Reset size",
            function()
                widget:ResetSize()
                for _, variable in ipairs(variables) do
                    Settings.NotifyUpdate(variable)
                end
            end, opts.resetTooltip or "Back to its own size. Opacity stays as it is.", true))
    end
    return true
end
