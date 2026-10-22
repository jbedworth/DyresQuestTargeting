local addonName, ns = ...

-- Dyre's Toolkit: what Dyre's AddOns share that is code, not sound (sounds
-- are Dyre's Sounds, apart for licensing). One layout mode for every
-- Dyre's AddOn's frames, the grid, snapping across AddOns, the minimap menu,
-- and the "Dyre's AddOns" settings home. Each AddOn keeps its own frames,
-- positions, and settings; it registers them here.
--
-- The interface (contract 1), reached with DyresToolkit.RequireContract(1):
--   RegisterAddOn(info)            info.addon (folder), info.title, and optional
--                                  info.setLocked(locked), info.openSettings()
--   AddOns()                       the registered AddOns, in order
--   IsLocked(), SetLocked(locked), Lock(), Unlock(), ToggleLock()
--   RegisterMovable(frame, save)   save(position) stores {point, relativePoint, x, y}
--   BeginDrag(frame), EndDrag(frame), ScaleKeepingCenter(frame, scale)
--   RegisterSettingsCategory(name) a page under "Dyre's AddOns": category, layout
--   SettingsCategory()             the "Dyre's AddOns" category
--   OpenSettings(category)         opens a page, never in combat
--   ResizeFromCenter(frame, scale, width, height)  keeps the center (1.1.0)
-- Contract 2 (2.0.0) adds widgets, which own all placement for an AddOn:
--   CreateWidget(spec), AddWidgetSettings(category, layout, widget, opts),
--   ResetWidgets(addon), Widgets(addon); see Widgets.lua.
local DyresToolkit = {}
_G.DyresToolkit = DyresToolkit
ns.toolkit = DyresToolkit

local CONTRACT = 2
ns.TITLE = "Dyre's Toolkit"
ns.PREFIX = "Dyre: "
-- Grid spacing, in UIParent units.
ns.GRID_MIN, ns.GRID_MAX, ns.GRID_STEP = 8, 128, 4
ns.DEFAULT_GRID = 32

function DyresToolkit.RequireContract(required)
    if type(required) == "number" and required >= 1 and required <= CONTRACT then
        return DyresToolkit
    end
end

function ns.Report(message)
    DEFAULT_CHAT_FRAME:AddMessage(ns.PREFIX .. tostring(message))
end

-- Saved settings (account-wide), repaired on load so a damaged or older
-- table cannot break the toolkit.
function ns.SanitizeDB(db)
    db = type(db) == "table" and db or {}
    if type(db.locked) ~= "boolean" then
        db.locked = true
    end
    if type(db.grid) ~= "boolean" then
        db.grid = true
    end
    if type(db.snapToGrid) ~= "boolean" then
        db.snapToGrid = true
    end
    local size = tonumber(db.gridSize)
    if not size or size ~= size then
        size = ns.DEFAULT_GRID
    end
    db.gridSize = math.max(ns.GRID_MIN, math.min(ns.GRID_MAX, math.floor(size + 0.5)))
    -- LibDBIcon's own table: hide, and the icon's angle.
    if type(db.minimap) ~= "table" then
        db.minimap = {}
    end
    if db.minimap.hide ~= nil and type(db.minimap.hide) ~= "boolean" then
        db.minimap.hide = nil
    end
    return db
end

-- Until SavedVariables load, a fresh table, so early calls are safe.
ns.db = ns.SanitizeDB(nil)

-- The AddOns that use the toolkit, by folder name, in the order they came.
local members, order = {}, {}

local function ValidName(value)
    return type(value) == "string" and value:find("%S") ~= nil
end

function DyresToolkit.RegisterAddOn(info)
    if type(info) ~= "table" or not ValidName(info.addon) or not ValidName(info.title) then
        return false
    end
    if not members[info.addon] then
        order[#order + 1] = info.addon
    end
    members[info.addon] = info
    -- Joining while frames are unlocked: show this AddOn's frames too.
    if not ns.db.locked and type(info.setLocked) == "function" then
        info.setLocked(false)
    end
    return true
end

function DyresToolkit.AddOns()
    local list = {}
    for _, name in ipairs(order) do
        list[#list + 1] = members[name]
    end
    -- By the name shown under "Dyre's AddOns" (ns.ShortName, in Settings.lua).
    table.sort(list, function(a, b) return ns.ShortName(a.title):lower() < ns.ShortName(b.title):lower() end)
    return list
end

function DyresToolkit.IsLocked()
    return ns.db.locked
end

-- One layout mode for every Dyre's AddOn. Each AddOn's own setLocked shows
-- or hides its samples and outlines; the toolkit says one line for all.
function DyresToolkit.SetLocked(locked)
    locked = locked == true
    ns.db.locked = locked
    for _, name in ipairs(order) do
        local info = members[name]
        if type(info.setLocked) == "function" then
            info.setLocked(locked)
        end
    end
    ns.RefreshGrid()
    if ns.RefreshWidgets then
        ns.RefreshWidgets()
    end
    if ns.RefreshMinimap then
        ns.RefreshMinimap()
    end
    if locked then
        ns.Report("Frames locked.")
    elseif InCombatLockdown() then
        ns.Report("Frames unlocked: they can be dragged after combat.")
    else
        ns.Report("Frames unlocked: drag them where you want (Shift-drag moves a snapped group), "
            .. "then type /dyre lock.")
    end
end

function DyresToolkit.Lock()
    DyresToolkit.SetLocked(true)
end

function DyresToolkit.Unlock()
    DyresToolkit.SetLocked(false)
end

function DyresToolkit.ToggleLock()
    DyresToolkit.SetLocked(not ns.db.locked)
end

function ns.SetGrid(shown)
    ns.db.grid = shown == true
    ns.RefreshGrid()
end

function ns.SetSnapToGrid(snap)
    ns.db.snapToGrid = snap == true
end

function ns.SetGridSize(size)
    ns.db.gridSize = ns.SanitizeDB({gridSize = size}).gridSize
    ns.RefreshGrid(true)
end

-- /dyre, and /dyretoolkit in case another AddOn uses /dyre.
local USAGE = "Use /dyre (settings), /dyre unlock, /dyre lock, /dyre grid, /dyre snap, or /dyre minimap."

function ns.HandleCommand(message)
    local command = type(message) == "string" and message:match("^%s*(%S*)%s*$")
    command = command and command:lower()
    if command == "" then
        DyresToolkit.OpenSettings()
    elseif command == "unlock" then
        DyresToolkit.Unlock()
    elseif command == "lock" then
        DyresToolkit.Lock()
    elseif command == "grid" then
        ns.SetGrid(not ns.db.grid)
        ns.Report(ns.db.grid and "The grid shows while frames are unlocked." or "The grid is hidden.")
    elseif command == "snap" then
        ns.SetSnapToGrid(not ns.db.snapToGrid)
        ns.Report(ns.db.snapToGrid and "Frames snap to the grid." or "Frames no longer snap to the grid.")
    elseif command == "minimap" then
        ns.SetMinimapShown(ns.db.minimap.hide == true)
    else
        ns.Report(USAGE)
    end
end

SLASH_DYRESTOOLKIT1 = "/dyre"
SLASH_DYRESTOOLKIT2 = "/dyretoolkit"
SlashCmdList.DYRESTOOLKIT = function(message) ns.HandleCommand(message) end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name == addonName then
            self:UnregisterEvent("ADDON_LOADED")
            DyresToolkitDB = ns.SanitizeDB(DyresToolkitDB)
            ns.db = DyresToolkitDB
            -- Frames always start locked: an unlocked layout from last time
            -- would leave every AddOn's samples on screen.
            ns.db.locked = true
        end
        return
    end
    self:UnregisterEvent("PLAYER_LOGIN")
    ns.InitializeSettings()
    ns.InitializeMinimap()
end)
