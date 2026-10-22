local _, ns = ...
local DyresToolkit = ns.toolkit

-- Magnetic frames for every Dyre's AddOn at once (from the Layout.lua that
-- Mage Tools Forever, Warlock Tools Forever, and Dyre's Buff Reminders each
-- copied): while frames are unlocked, a frame dropped near another snaps
-- beside it, GAP apart, lined up by their tops, centers, or bottoms (or lefts,
-- centers, or rights when stacked), whichever is nearest. Frames that far
-- apart and lined up are snapped; Shift-dragging one moves every frame
-- snapped to it, and the group snaps as one to the frames outside it. One
-- registry for all AddOns, so a frame snaps to another AddOn's frame too.
-- With "Snap to grid" on, a frame that snaps to no neighbor puts its center
-- on the nearest grid point. Each AddOn registers its frame with a function
-- that saves the frame's position; positions save as the frame's center from
-- UIParent's bottom left. Dragging happens only out of combat.

local GAP = 20
local SNAP_RANGE = 24
local SNAP_TOLERANCE = 1.5
local GRID_LINE = {1, 1, 1, 0.12}
local GRID_CENTER = {1, 0.15, 0.15, 0.6}

local layout = {saves = {}, order = {}, dragging = {}, pending = {}, free = {}}

function DyresToolkit.RegisterMovable(frame, save)
    if type(frame) ~= "table" or type(save) ~= "function" then
        return false
    end
    if not layout.saves[frame] then
        layout.order[#layout.order + 1] = frame
    end
    layout.saves[frame] = save
    return true
end

-- A frame's center in its own units. A frame placed by the toolkit (CENTER
-- on UIParent's bottom left) is read from its anchor: GetCenter makes the
-- client lay out pending frames now, inside our call, and a Blizzard frame
-- that changes size then (the objective tracker) runs its update tainted
-- (found in client, 2026-10-21: GetAuraDataByIndex blocked, "tainted by
-- DyresToolkit"). Anything else, such as a frame just dragged, uses GetCenter.
local function Center(frame)
    if frame:GetNumPoints() == 1 and type(frame.GetPoint) == "function" then
        local point, relative, relativePoint, x, y = frame:GetPoint(1)
        if point == "CENTER" and relative == UIParent and relativePoint == "BOTTOMLEFT" then
            return x, y
        end
    end
    return frame:GetCenter()
end

-- A frame's center and half size in UIParent units.
local function Box(frame)
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local x, y = Center(frame)
    return x * ratio, y * ratio, frame:GetWidth() * ratio / 2, frame:GetHeight() * ratio / 2
end

local function MoveTo(frame, x, y)
    local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    local position = {point = "CENTER", relativePoint = "BOTTOMLEFT", x = x * ratio, y = y * ratio}
    frame:ClearAllPoints()
    frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
    layout.saves[frame](position)
end

local function ShownFrames()
    local shown = {}
    for _, frame in ipairs(layout.order) do
        if frame:IsShown() then
            shown[#shown + 1] = frame
        end
    end
    return shown
end

-- Side by side (or stacked) the gap apart, and overlapping along the other axis.
local function Snapped(a, b)
    local ax, ay, aw, ah = Box(a)
    local bx, by, bw, bh = Box(b)
    local dx, dy = math.abs(ax - bx), math.abs(ay - by)
    return (math.abs(dx - (aw + bw + GAP)) <= SNAP_TOLERANCE and dy < ah + bh)
        or (math.abs(dy - (ah + bh + GAP)) <= SNAP_TOLERANCE and dx < aw + bw)
end

-- Every frame joined to this one through snapped neighbors.
local function SnappedGroup(frame)
    local group, seen, queue = {}, {[frame] = true}, {frame}
    local shown = ShownFrames()
    while #queue > 0 do
        local current = table.remove(queue, 1)
        group[#group + 1] = current
        for _, other in ipairs(shown) do
            if not seen[other] and Snapped(current, other) then
                seen[other] = true
                queue[#queue + 1] = other
            end
        end
    end
    return group
end

-- The nearest spot beside a frame outside skip, within reach, or nil.
local function SnapPoint(frame, skip)
    local x, y, width, height = Box(frame)
    local bestX, bestY, bestDistance
    local function Consider(spotX, spotY)
        local distance = math.sqrt((spotX - x) ^ 2 + (spotY - y) ^ 2)
        if distance <= SNAP_RANGE and (not bestDistance or distance < bestDistance) then
            bestX, bestY, bestDistance = spotX, spotY, distance
        end
    end
    for _, other in ipairs(ShownFrames()) do
        if not skip[other] then
            local ox, oy, otherWidth, otherHeight = Box(other)
            local alignY = {oy + otherHeight - height, oy, oy - otherHeight + height}
            local alignX = {ox - otherWidth + width, ox, ox + otherWidth - width}
            for _, side in ipairs({1, -1}) do
                for _, spotY in ipairs(alignY) do
                    Consider(ox + side * (otherWidth + width + GAP), spotY)
                end
                for _, spotX in ipairs(alignX) do
                    Consider(spotX, oy + side * (otherHeight + height + GAP))
                end
            end
        end
    end
    return bestX, bestY
end

-- Snapping to the grid, one axis at a time (author-approved after play
-- testing): the red center line comes first, and a box centers on it when
-- its center is in reach, else puts its nearer edge on it when an edge is in
-- reach. The grey lines only line up edges, and only when an edge is within a
-- quarter of the grid size of one (8 at 32); otherwise the box stays where it
-- was dropped. The lines run from the screen's center, ns.db.gridSize apart,
-- as drawn. Returns how far to move.
local GRID_EDGE_REACH = 1 / 4

local function Nearest(moves, reach)
    local best
    for _, move in ipairs(moves) do
        if math.abs(move) <= reach and (not best or math.abs(move) < math.abs(best)) then
            best = move
        end
    end
    return best
end

local function AxisShift(low, high, origin)
    local center = (low + high) / 2
    if math.abs(origin - center) <= SNAP_RANGE then
        return origin - center
    end
    local onCenterLine = Nearest({origin - low, origin - high}, SNAP_RANGE)
    if onCenterLine then
        return onCenterLine
    end
    local size = ns.db.gridSize
    local function ToLine(value)
        return origin + math.floor((value - origin) / size + 0.5) * size - value
    end
    return Nearest({ToLine(low), ToLine(high)}, size * GRID_EDGE_REACH) or 0
end

-- The box around one or more frames: left, right, bottom, top.
local function Bounds(frames)
    local left, right, bottom, top
    for _, frame in ipairs(frames) do
        local x, y, width, height = Box(frame)
        left = math.min(left or x - width, x - width)
        right = math.max(right or x + width, x + width)
        bottom = math.min(bottom or y - height, y - height)
        top = math.max(top or y + height, y + height)
    end
    return left, right, bottom, top
end

-- How far a group (or one frame) moves to sit on the grid.
function ns.GridShift(frames)
    local left, right, bottom, top = Bounds(frames)
    return AxisShift(left, right, UIParent:GetWidth() / 2), AxisShift(bottom, top, UIParent:GetHeight() / 2)
end

-- Changes a frame's scale and/or size without moving its center on screen. A
-- frame anchored CENTER to UIParent's corner moves when only SetScale changes,
-- because its offsets are in its own (scaled) units, so the center is read in
-- UIParent units first and the frame is anchored there again. Nothing happens
-- when nothing changes. A registered frame saves its new place; any other
-- frame is only re-anchored. Pass width and height together, or neither.
local SIZE_EPSILON = 0.01

-- anchor (2.1.0): "LEFT", "RIGHT", "TOP", "BOTTOM", or a corner such as
-- "TOPLEFT" keeps that edge (or both edges) where it is instead of the
-- center: a bar that grows left to right, a box that collapses toward its
-- top. The saved place is still the center.
function DyresToolkit.ResizeFromCenter(frame, scale, width, height, anchor)
    if scale and math.abs(frame:GetScale() - scale) < SIZE_EPSILON then
        scale = nil
    end
    if width and height and math.abs(frame:GetWidth() - width) < SIZE_EPSILON
            and math.abs(frame:GetHeight() - height) < SIZE_EPSILON then
        width, height = nil, nil
    end
    if not scale and not (width and height) then
        return
    end
    local placed = frame:GetNumPoints() > 0 and Center(frame) ~= nil
    local x, y, halfWidth, halfHeight
    if placed then
        x, y, halfWidth, halfHeight = Box(frame)
    end
    if scale then
        frame:SetScale(scale)
    end
    if width and height then
        frame:SetSize(width, height)
    end
    if not placed then
        return
    end
    if type(anchor) == "string" then
        local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
        local newHalfWidth, newHalfHeight = frame:GetWidth() * ratio / 2, frame:GetHeight() * ratio / 2
        if anchor:find("LEFT") then
            x = x - halfWidth + newHalfWidth
        elseif anchor:find("RIGHT") then
            x = x + halfWidth - newHalfWidth
        end
        if anchor:find("TOP") then
            y = y + halfHeight - newHalfHeight
        elseif anchor:find("BOTTOM") then
            y = y - halfHeight + newHalfHeight
        end
    end
    if layout.saves[frame] then
        MoveTo(frame, x, y)
    else
        local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * ratio, y * ratio)
    end
end

-- Contract 1's original name, kept for dependents that call it.
function DyresToolkit.ScaleKeepingCenter(frame, scale)
    DyresToolkit.ResizeFromCenter(frame, scale)
end

local function ControlDown()
    return type(IsControlKeyDown) == "function" and IsControlKeyDown() == true
end

-- While frames are locked, a drag started with Ctrl held moves that one
-- frame anyway (author-approved 2026-10-21, family-wide, as Questie's
-- tracker): no group, and the drop is free (no neighbors, no grid). It
-- can start only on a part that takes the mouse while locked (a button, a
-- box's header); the rest of a locked widget lets clicks through.
function DyresToolkit.BeginDrag(frame)
    if InCombatLockdown() or not layout.saves[frame] then
        return
    end
    local lockedDrag = ns.db.locked
    if lockedDrag and not ControlDown() then
        return
    end
    local group = {frame}
    layout.free[frame] = lockedDrag or nil
    -- Shift: the snapped group follows, anchored to the dragged frame.
    if not lockedDrag and IsShiftKeyDown() then
        group = SnappedGroup(frame)
        local scale = frame:GetEffectiveScale()
        local leadX, leadY = Center(frame)
        for index = 2, #group do
            local follower = group[index]
            local followerScale = follower:GetEffectiveScale()
            local x, y = Center(follower)
            follower:ClearAllPoints()
            follower:SetPoint("CENTER", frame, "CENTER", (x * followerScale - leadX * scale) / followerScale,
                (y * followerScale - leadY * scale) / followerScale)
        end
    end
    layout.dragging[frame] = group
    frame:StartMoving()
end

-- Snaps and saves a dropped frame and its group: to a neighbor if one is in
-- reach (that comes first, author-approved), else, when that is on, to the
-- grid, the whole group as one box. Ctrl held at the drop skips both, for a
-- pixel-perfect place (author-approved); a drop that waited out combat
-- snaps, since the key is long released.
local function FinishDrop(frame, group, free)
    local inGroup = {}
    for _, member in ipairs(group) do
        inGroup[member] = true
    end
    local shiftX, shiftY = 0, 0
    if not free then
        local x, y = Box(frame)
        local snapX, snapY = SnapPoint(frame, inGroup)
        shiftX, shiftY = (snapX or x) - x, (snapY or y) - y
        if not snapX and ns.db.snapToGrid then
            shiftX, shiftY = ns.GridShift(group)
        end
    end
    -- Every center first: followers are still anchored to the dragged frame,
    -- so moving it first would move them too, and the shift would apply twice.
    local centers = {}
    for index, member in ipairs(group) do
        local memberX, memberY = Box(member)
        centers[index] = {memberX + shiftX, memberY + shiftY}
    end
    for index, member in ipairs(group) do
        MoveTo(member, centers[index][1], centers[index][2])
    end
end

-- Combat began during a drag: secure frames cannot stop moving or move now,
-- so the drop (and a Shift-dragged group's followers, still anchored to the
-- dragged frame) waits, and finishes when combat ends.
local pendingEvents = CreateFrame("Frame")
pendingEvents:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    local pending = layout.pending
    layout.pending = {}
    for _, drop in ipairs(pending) do
        drop.frame:StopMovingOrSizing()
        FinishDrop(drop.frame, drop.group, drop.free)
    end
end)

function DyresToolkit.EndDrag(frame)
    local group = layout.dragging[frame]
    if not group then
        return
    end
    layout.dragging[frame] = nil
    local wasLocked = layout.free[frame] == true
    local free = wasLocked or ControlDown()
    layout.free[frame] = nil
    if InCombatLockdown() then
        local protected = type(frame.IsProtected) == "function" and frame:IsProtected()
        if not protected then
            frame:StopMovingOrSizing()
        end
        layout.pending[#layout.pending + 1] = {frame = frame, group = group, free = wasLocked}
        pendingEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    frame:StopMovingOrSizing()
    FinishDrop(frame, group, free)
end

-- The grid: lines ns.db.gridSize apart from the screen's center, and the two
-- center lines in red, while frames are unlocked and the grid is on.
local grid

local function GridLine(vertical, offset, color, thickness)
    local line = grid:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(color[1], color[2], color[3], color[4])
    if vertical then
        line:SetWidth(thickness)
        line:SetPoint("TOP", grid, "TOP", offset, 0)
        line:SetPoint("BOTTOM", grid, "BOTTOM", offset, 0)
    else
        line:SetHeight(thickness)
        line:SetPoint("LEFT", grid, "LEFT", 0, offset)
        line:SetPoint("RIGHT", grid, "RIGHT", 0, offset)
    end
    grid.lines[#grid.lines + 1] = line
end

local function BuildGrid()
    for _, line in ipairs(grid.lines) do
        line:Hide()
    end
    grid.lines = {}
    local size = ns.db.gridSize
    local halfWidth, halfHeight = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
    for step = 1, math.floor(halfWidth / size) do
        GridLine(true, step * size, GRID_LINE, 1)
        GridLine(true, -step * size, GRID_LINE, 1)
    end
    for step = 1, math.floor(halfHeight / size) do
        GridLine(false, step * size, GRID_LINE, 1)
        GridLine(false, -step * size, GRID_LINE, 1)
    end
    GridLine(true, 0, GRID_CENTER, 2)
    GridLine(false, 0, GRID_CENTER, 2)
    grid.built = true
end

-- rebuild: the spacing changed.
function ns.RefreshGrid(rebuild)
    local wanted = not ns.db.locked and ns.db.grid
    if not grid then
        if not wanted then
            return
        end
        grid = CreateFrame("Frame", nil, UIParent)
        grid:SetAllPoints(UIParent)
        grid:SetFrameStrata("BACKGROUND")
        grid:EnableMouse(false)
        grid.lines = {}
        grid:SetScript("OnEvent", function() grid.built = false; ns.RefreshGrid() end)
        grid:RegisterEvent("DISPLAY_SIZE_CHANGED")
        grid:RegisterEvent("UI_SCALE_CHANGED")
    end
    if rebuild then
        grid.built = false
    end
    if wanted and not grid.built then
        BuildGrid()
    end
    grid:SetShown(wanted)
    ns.grid = grid
end
