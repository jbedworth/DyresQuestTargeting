local _, DQT = ...

-- The Quest Target box (author-approved, 1.1.0): a Dyre's Toolkit widget
-- with the focused quest, the macro's names most wanted first, the names
-- left out, and the hit list, with buttons to change it. Plain frames and
-- buttons, no secure templates, so nothing here is protected: the box moves
-- and redraws in combat, and its buttons work as /dqt add and /dqt remove do
-- (the hit list changes at once; the macro waits for combat to end). The
-- toolkit owns the place, dragging, size, opacity, and the mouse: the box
-- itself takes clicks only while unlocked. Its footer icons, the header, and the
-- section titles take clicks; the other rows take only the mouse-over, for
-- the tooltip on cut text, so clicks pass through them to the world.

local TITLE = "Quest Targets"
local ADDON_TITLE = "Dyre's Quest Targeting"
local WIDGET_KEY = "box"
local DEFAULT_POINT = {"TOPRIGHT", "TOPRIGHT", -240, -220}
-- The box size and the text size are independent (author): a bigger box
-- shows more rows, bigger text fewer.
local SIZES = {
    width = {min = 180, max = 400, step = 10, default = 240},
    height = {min = 120, max = 600, step = 5, default = 235},
    opacity = true,
    textSize = {min = 80, max = 150, step = 5, default = 100, label = "Text size (%)", percent = true},
}
local SIZE_ORDER = {"width", "height", "textSize", "opacity"}
-- "Reset size" keeps opacity, as every Dyre's AddOn does.
local RESET_SIZES = {"width", "height", "textSize"}

-- A rounded panel with a thin gold edge (author: "really, just round the
-- rectangle"), and the header as its own rounded inset panel. Built-in
-- textures only: the tooltip's rounded border and background. The style
-- (author: try both) colors the panel and the header; gold stays.
local GOLD = {1, 0.82, 0}
local HEADER_EDGE_ALPHA = 0.6
DQT.BOX_STYLES = {
    brown = {label = "Brown and gold", panel = {0.28, 0.16, 0.07, 0.85}, header = {0.10, 0.06, 0.02, 0.95}},
    black = {label = "Black and gold", panel = {0.05, 0.05, 0.06, 0.9}, header = {0.13, 0.13, 0.14, 0.95}},
}
DQT.BOX_STYLE_ORDER = {"brown", "black"}
DQT.DEFAULT_BOX_STYLE = "brown"
local BACKDROP = {bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
    insets = {left = 4, right = 4, top = 4, bottom = 4}}
local HEADER_BACKDROP = {bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
    insets = {left = 3, right = 3, top = 3, bottom = 3}}
local STRIP_BACKDROP = {bgFile = "Interface\\Tooltips\\UI-Tooltip-Background"}
local BORDER_INSET = 5
local PADDING = 12
local HEADER_PAD = 3
local BASE_FONT = 12
local LINE_GAP = 3
-- The plus, minus, and X textures have a clear margin, so an icon of 1.4
-- text sizes shows a mark just under the title's letters (author: "slightly
-- smaller than the title text").
local ICON_FACTOR = 1.4
local ADD_TIP = "Add your target to the hit list. Shift-click to match the exact name."
local CLEAR_TIP = "Clear the hit list."
local HIT_LIST_TIP = "Show or hide the hit list."
-- The empty strip above the footer (room to drop a dragged name last), in
-- bar heights (author: "a little extra space at the bottom").
local STRIP_FACTOR = 0.5
local BUTTON_GAP = 4
-- Room for "100.0%" in the rate column, in text sizes.
local RATE_WIDTH = 3.4
-- The game font has no "✕", so the remove button and the section toggles
-- are textures (the quest log's plus and minus).
local REMOVE_TEXTURE = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
local EXPAND_TEXTURE = "Interface\\Buttons\\UI-PlusButton-Up"
local COLLAPSE_TEXTURE = "Interface\\Buttons\\UI-MinusButton-Up"
-- No drop rate known, so "no data" and "cut off" differ.
local NO_RATE = "-"
local DEFAULT_FONT = "Fonts\\FRIZQT__.TTF"
local GREY_CODE = "|cff9d9d9d"
local GOLD_CODE = "|cffffd100"

local box, header, objectiveRow, rows, footer, insertLine, strip
-- The hit list rows shown, top to bottom, each with its offset from the
-- box's top (for the drop place); hitRows.line is the row height.
local hitRows = {}
local DRAG_ALPHA = 0.5
local INSERT_HEIGHT = 2

local function Metrics(widget)
    local size = BASE_FONT * widget:GetSetting("textSize") / 100
    local line = math.floor(size + LINE_GAP + 0.5)
    -- size, row height, bar height (the header's and the footer's), icon size
    return size, line, line + HEADER_PAD * 2, math.floor(size * ICON_FACTOR + 0.5)
end

local function Quest()
    return DQT.db.enabled and DQT.current and DQT.current.quest or nil
end

-- Folding (author): the header (the quest's title) folds the quest's part,
-- the hit list bar folds the hit list, and the fold button folds or opens
-- all. Saved by key in db.box.foldedSections: quest, targets, dropped, added.
local function SectionFolded(key)
    return DQT.db.box.foldedSections[key] == true
end

local function ToggleSection(key)
    local folded = DQT.db.box.foldedSections
    folded[key] = not folded[key] or nil
    DQT.UpdateBox()
end

-- All folded: the quest's part and the hit list.
local function AllFolded()
    return SectionFolded("quest") and SectionFolded("added")
end

local function SetAllFolded(fold)
    local folded = DQT.db.box.foldedSections
    if fold then
        folded.quest, folded.added = true, true
    else
        for key in pairs(folded) do
            folded[key] = nil
        end
    end
end

local function StripHeight(bar)
    return math.floor(bar * STRIP_FACTOR + 0.5)
end

-- Where the section rows start: under the header bar and the objective line.
local function RowsTop(widget)
    local _, line, bar = Metrics(widget)
    local quest = Quest()
    return BORDER_INSET + bar + LINE_GAP + (quest and quest.objectiveText and line or 0)
end

local function SetFontSize(fontString, size)
    fontString:SetFont(STANDARD_TEXT_FONT or DEFAULT_FONT, size, "")
end

local function Truncated(fontString)
    if type(fontString.IsTruncated) == "function" then
        return fontString:IsTruncated() == true
    end
    return fontString:GetStringWidth() > fontString:GetWidth() + 0.5
end

-- The whole text of a row whose text is cut ("..."), on mouse-over.
local function ShowFull(self)
    if not self.full or type(GameTooltip) ~= "table" or not Truncated(self.label) then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.full, 1, 1, 1, 1, true)
    GameTooltip:Show()
end

-- The header's tooltip names the AddOn (author: instead of a title bar,
-- to keep the box clean), then the whole header line, cut or not.
local function ShowHeader(self)
    if not self.full or type(GameTooltip) ~= "table" then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(ADDON_TITLE, GOLD[1], GOLD[2], GOLD[3])
    GameTooltip:AddLine(self.full, 1, 1, 1, true)
    GameTooltip:Show()
end

local function HideFull(self)
    if type(GameTooltip) == "table" and GameTooltip:GetOwner() == self then
        GameTooltip:Hide()
    end
end

-- Reordering the hit list (author): drag a hit list row up or down. The
-- gap the cursor is over: 0 anywhere above the first row (the bar, the
-- quest rows, the header too) to #hitRows anywhere below the last, or nil
-- only when the cursor leaves the box (a drop there cancels).
local function DropSlot()
    if #hitRows == 0 then
        return nil
    end
    local scale = box:GetEffectiveScale()
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    local left, right, top = box:GetLeft(), box:GetRight(), box:GetTop()
    if not (left and right and top) or x < left or x > right then
        return nil
    end
    local offset, line = top - y, hitRows.line
    if offset < 0 or offset > box:GetHeight() then
        return nil
    end
    local slot = 0
    for _, row in ipairs(hitRows) do
        if row.offset + line / 2 < offset then
            slot = slot + 1
        end
    end
    return slot
end

-- While a row is dragged only (set on the drag's start, cleared on its
-- stop; never idle): a gold line where the row would drop.
local function PlaceInsertLine()
    local slot = DropSlot()
    if not slot then
        insertLine:Hide()
        return
    end
    local y = slot < #hitRows and hitRows[slot + 1].offset or hitRows[#hitRows].offset + hitRows.line
    insertLine:ClearAllPoints()
    insertLine:SetPoint("TOPLEFT", box, "TOPLEFT", PADDING, -(y - INSERT_HEIGHT / 2))
    insertLine:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PADDING, -(y - INSERT_HEIGHT / 2))
    insertLine:Show()
end

local function StartReorder(self)
    if not self.entry then
        return
    end
    self.reordering = true
    self:SetAlpha(DRAG_ALPHA)
    self:SetScript("OnUpdate", PlaceInsertLine)
end

-- The gap counts the dragged row itself; a drop next to it changes nothing.
local function StopReorder(self)
    if not self.reordering then
        return
    end
    self.reordering = nil
    self:SetScript("OnUpdate", nil)
    self:SetAlpha(1)
    insertLine:Hide()
    local slot = DropSlot()
    if not slot then
        return
    end
    local from = self.position
    if slot >= from then
        slot = slot - 1
    end
    if slot + 1 ~= from then
        DQT.MoveAdded(self.entry, slot + 1)
    end
end

local function Row(parent, template)
    local row = CreateFrame("Button", nil, parent, template)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.rate = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.rate:SetJustifyH("RIGHT")
    row.toggle = row:CreateTexture(nil, "ARTWORK")
    row.remove = CreateFrame("Button", nil, row)
    row.remove:SetNormalTexture(REMOVE_TEXTURE)
    row.remove:SetScript("OnClick", function(self)
        if self.name then
            DQT.RemoveName(self.name)
        end
    end)
    row:SetScript("OnEnter", ShowFull)
    row:SetScript("OnLeave", HideFull)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", StartReorder)
    row:SetScript("OnDragStop", StopReorder)
    row:SetScript("OnClick", function(self)
        if self.section then
            ToggleSection(self.section)
        end
    end)
    return row
end

-- Fills a row: text on the left (cut with "..." when long), then the rate
-- column or the red X on the right; a section title gets its toggle.
local function Fill(row, item, size, line)
    row:SetHeight(line)
    row.full = item.full
    row.section = item.section
    row.entry, row.position = item.remove, item.position
    -- Titles take clicks, and hit list rows (to drag them); other rows take
    -- the mouse-over only, so clicks pass through them to the world.
    row:SetMouseClickEnabled(item.section ~= nil or item.remove ~= nil)
    row:SetMouseMotionEnabled(true)
    SetFontSize(row.label, size)
    SetFontSize(row.rate, size)
    row.label:SetText(item.text)
    row.label:ClearAllPoints()
    local left = 0
    if item.section then
        row.toggle:SetTexture(item.folded and EXPAND_TEXTURE or COLLAPSE_TEXTURE)
        row.toggle:SetSize(size, size)
        row.toggle:ClearAllPoints()
        row.toggle:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.toggle:Show()
        left = size + BUTTON_GAP
    else
        row.toggle:Hide()
    end
    row.label:SetPoint("LEFT", row, "LEFT", left, 0)
    local right = row
    local rightPoint = "RIGHT"
    row.remove.name = item.remove
    if item.remove then
        row.remove:SetSize(size + 2, size + 2)
        row.remove:ClearAllPoints()
        row.remove:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.remove:Show()
        right, rightPoint = row.remove, "LEFT"
    else
        row.remove:Hide()
    end
    if item.rate then
        row.rate:SetText(item.rate)
        row.rate:SetWidth(size * RATE_WIDTH)
        row.rate:ClearAllPoints()
        row.rate:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.rate:Show()
        right, rightPoint = row.rate, "LEFT"
    else
        row.rate:Hide()
    end
    row.label:SetPoint("RIGHT", right, rightPoint, right == row and 0 or -BUTTON_GAP, 0)
    row:Show()
end

local function RateText(target)
    if type(target.rate) == "number" then
        return string.format("%.1f%%", target.rate)
    end
    return NO_RATE
end

-- A dropper shows its item; a kill objective's detail is its own text,
-- which the box does not repeat.
local function Detail(target)
    if target.source == "drop" then
        return "drops " .. (target.item or "a quest item")
    end
    return DQT.SourceText(target)
end

-- The tooltip says the rate in words: "30.3% drop rate", or, for a dropper
-- with no rate, "drop rate unknown"; a kill or turn-in has no drop rate.
local function RateWords(target)
    if type(target.rate) == "number" then
        return ", " .. string.format("%.1f", target.rate) .. "% drop rate"
    end
    return target.source == "drop" and ", drop rate unknown" or ""
end

local function TargetItem(target, grey)
    local detail, rate = Detail(target), RateText(target)
    local text = grey and (GREY_CODE .. target.name .. " · " .. detail .. "|r")
        or (target.name .. " " .. GREY_CODE .. detail .. "|r")
    return {text = text, rate = rate, full = target.name .. " · " .. detail .. RateWords(target)}
end

-- The sections, most wanted first; a folded section keeps only its title.
local function Sections()
    local current = DQT.db.enabled and DQT.current
    local targets, dropped, added = {}, {}, {}
    for index = #(current and current.kept or {}), 1, -1 do
        local target = current.kept[index]
        if target.source ~= "added" then
            targets[#targets + 1] = TargetItem(target)
        end
    end
    for _, target in ipairs(current and current.dropped or {}) do
        dropped[#dropped + 1] = TargetItem(target, true)
    end
    if current then
        for index = #DQT.db.added, 1, -1 do
            local entry = DQT.db.added[index]
            local kind = entry.exact and "exact" or "similar"
            added[#added + 1] = {text = entry.name .. " " .. GREY_CODE .. kind .. "|r", remove = entry.name,
                full = entry.name .. " · " .. kind, position = #added + 1}
        end
    end
    local sections = {}
    local folded = DQT.db.box.foldedSections
    local function Add(key, title, items)
        if #items > 0 then
            sections[#sections + 1] = {key = key, title = title, items = items, folded = folded[key] == true}
        end
    end
    Add("targets", "Targets, most wanted first", targets)
    Add("dropped", "Not in the macro (255-letter limit)", dropped)
    -- The footer bar is the hit list's title (author), so it has no title row.
    Add("added", nil, added)
    return sections
end

-- Rows are shared out one at a time between open sections; a cut section's
-- last row says how many more.
local function Fit(sections, budget)
    local shown = {}
    for index, section in ipairs(sections) do
        shown[index] = 0
        if section.title then
            budget = budget - 1
        end
    end
    local progress = true
    while budget > 0 and progress do
        progress = false
        for index, section in ipairs(sections) do
            if budget > 0 and not section.folded and shown[index] < #section.items then
                shown[index] = shown[index] + 1
                budget = budget - 1
                progress = true
            end
        end
    end
    return shown
end

local function HeaderText()
    if not DQT.db.enabled then
        return GREY_CODE .. "Macro off: /dqt on turns it back on|r", "Macro off: /dqt on turns it back on"
    end
    local quest = Quest()
    if not quest then
        return GREY_CODE .. "No focused quest|r", "No focused quest"
    end
    local plain = quest.title .. " (" .. (quest.via == "Questie" and "Questie" or "Focus") .. ")"
        .. (quest.complete and " · ready to turn in" or "")
    return GOLD_CODE .. plain .. "|r", plain
end

-- The rows open sections show, within Max height: the quest's (targets,
-- left-out names) and the hit list's apart, since the hit list bar sits
-- between them. Measure and Render share it.
local function Plan(widget)
    local quest, hit = {}, {}
    local _, line, bar = Metrics(widget)
    local area = widget:GetSetting("height") - RowsTop(widget) - LINE_GAP * 3 - StripHeight(bar) - bar
        - BORDER_INSET
    -- The quest's part folded: only the hit list's rows.
    local sections = {}
    for _, section in ipairs(Sections()) do
        if section.key == "added" or not SectionFolded("quest") then
            sections[#sections + 1] = section
        end
    end
    local shown = Fit(sections, math.floor(area / line))
    for index, section in ipairs(sections) do
        local list = section.key == "added" and hit or quest
        if section.title then
            list[#list + 1] = {text = GOLD_CODE .. section.title .. " (" .. #section.items .. ")|r",
                full = section.title .. " (" .. #section.items .. ")", section = section.key,
                folded = section.folded}
        end
        local count = shown[index]
        local cut = not section.folded and count < #section.items
        for item = 1, cut and count - 1 or count do
            list[#list + 1] = section.items[item]
        end
        if cut and count > 0 then
            list[#list + 1] = {text = GREY_CODE .. "+" .. (#section.items - count + 1)
                .. " more: /dqt list shows all|r"}
        end
    end
    return quest, hit
end

-- Where each part goes, as offsets from the box's top, and the box height.
-- The box grows and shrinks with its content (author), keeping its top
-- edge, up to Max height. Open with hit list names: the header bar, the
-- objective line, the quest rows, the hit list bar (the hit list's title),
-- its names, and the empty strip under them; with no names, the strip right
-- under the bar (author: it shows that names could go there). Hit list
-- folded: the quest rows and the bar, no strip (nothing to drop on).
-- All folded (nothing under the header but the objective), a compact card:
-- the header bar, the objective line, and the bar, evenly spaced.
local function Layout(widget)
    local _, line, bar = Metrics(widget)
    local quest, hit = Plan(widget)
    local spots = {quest = quest, hit = hit, rowsTop = RowsTop(widget)}
    local y = spots.rowsTop + #quest * line
    if AllFolded() then
        local current = Quest()
        y = BORDER_INSET + bar + (current and current.objectiveText and (line + LINE_GAP * 2) or LINE_GAP)
        spots.barTop = y
        spots.height = y + bar + BORDER_INSET
        return spots
    end
    spots.barTop = y + LINE_GAP
    if SectionFolded("added") then
        spots.height = spots.barTop + bar + BORDER_INSET
        return spots
    end
    -- The hit list's own section: its names (maybe none), then the strip.
    spots.hitTop = spots.barTop + bar + LINE_GAP
    spots.stripTop = spots.hitTop + #hit * line + (#hit > 0 and LINE_GAP or 0)
    spots.height = spots.stripTop + StripHeight(bar) + BORDER_INSET
    return spots
end

local function Measure(widget)
    return widget:GetSetting("width"), Layout(widget).height
end

local function PlaceRows(list, first, top, size, line)
    for index, item in ipairs(list) do
        local row = rows[first + index] or Row(box)
        rows[first + index] = row
        row.offset = top + (index - 1) * line
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", box, "TOPLEFT", PADDING, -row.offset)
        row:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PADDING, -row.offset)
        Fill(row, item, size, line)
        if item.remove then
            hitRows[#hitRows + 1] = row
        end
    end
    return first + #list
end

local function Place(frame, top)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", box, "TOPLEFT", BORDER_INSET, -top)
    frame:SetPoint("TOPRIGHT", box, "TOPRIGHT", -BORDER_INSET, -top)
end

local function Render()
    local size, line, headerHeight, icon = Metrics(box)
    header:SetHeight(headerHeight)
    header.fold:SetSize(icon, icon)
    header.fold:SetNormalTexture(AllFolded() and EXPAND_TEXTURE or COLLAPSE_TEXTURE)
    local text, plain = HeaderText()
    header.full = plain
    SetFontSize(header.label, size)
    header.label:SetText(text)
    local quest = Quest()
    if quest and quest.objectiveText then
        local top = BORDER_INSET + headerHeight + LINE_GAP
        objectiveRow:ClearAllPoints()
        objectiveRow:SetPoint("TOPLEFT", box, "TOPLEFT", PADDING, -top)
        objectiveRow:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PADDING, -top)
        Fill(objectiveRow, {text = GREY_CODE .. "Objective: |r" .. quest.objectiveText,
            full = "Objective: " .. quest.objectiveText}, size, line)
    else
        objectiveRow:Hide()
    end
    local spots = Layout(box)
    hitRows = {line = line}
    local used = PlaceRows(spots.quest, 0, spots.rowsTop, size, line)
    used = PlaceRows(spots.hit, used, spots.hitTop or 0, size, line)
    for index = used + 1, #rows do
        rows[index]:Hide()
        rows[index].remove.name = nil
    end
    -- The empty strip: room to drop a dragged name last.
    strip:SetHeight(StripHeight(headerHeight))
    strip:SetShown(spots.stripTop ~= nil)
    if spots.stripTop then
        Place(strip, spots.stripTop)
    end
    -- The hit list bar, always shown, as tall as the header bar (author): add
    -- at the left end, clear at the right end, each inset as the header's
    -- fold button; between them the hit list's title, which folds it.
    Place(footer.bar, spots.barTop)
    footer.bar:SetHeight(headerHeight)
    SetFontSize(footer.count, size)
    local hidden = DQT.db.box.foldedSections.added and #DQT.db.added > 0
    footer.count:SetText(GOLD_CODE .. "Hit list: " .. #DQT.db.added .. (hidden and " (hidden)" or "") .. "|r")
    footer.add:SetSize(icon, icon)
    footer.add:ClearAllPoints()
    footer.add:SetPoint("LEFT", footer.bar, "LEFT", PADDING - BORDER_INSET, 0)
    footer.add:Show()
    footer.clear:SetSize(icon, icon)
    footer.clear:ClearAllPoints()
    footer.clear:SetPoint("RIGHT", footer.bar, "RIGHT", BORDER_INSET - PADDING, 0)
    footer.clear:Show()
    local empty = #DQT.db.added == 0
    footer.clear:SetEnabled(not empty)
    footer.clear.icon:SetDesaturated(empty)
end

-- Shown when on, and either frames are unlocked (to move it) or there is
-- something to show: a focused quest or a hit list.
local function Wanted()
    if not DQT.db.showBox then
        return false
    end
    local toolkit = DQT.Toolkit()
    if toolkit and not toolkit.IsLocked() then
        return true
    end
    return DQT.db.enabled and (Quest() ~= nil or #DQT.db.added > 0)
end

-- Colors only, so a change applies at once, also in combat.
function DQT.ApplyBoxStyle()
    if not box or not box.SetBackdropColor then
        return
    end
    local style = DQT.BOX_STYLES[DQT.db.boxStyle] or DQT.BOX_STYLES[DQT.DEFAULT_BOX_STYLE]
    box:SetBackdropColor(style.panel[1], style.panel[2], style.panel[3], style.panel[4])
    box:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3])
    -- The header and footer bars, the same inset panel; the strip, their fill.
    for _, bar in ipairs({header, footer.bar}) do
        if bar.SetBackdropColor then
            bar:SetBackdropColor(style.header[1], style.header[2], style.header[3], style.header[4])
            bar:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], HEADER_EDGE_ALPHA)
        end
    end
    if strip.SetBackdropColor then
        strip:SetBackdropColor(style.header[1], style.header[2], style.header[3], style.header[4])
    end
end

function DQT.UpdateBox()
    if not box then
        return
    end
    local wanted = Wanted()
    if wanted then
        -- Keeps the top edge while folding and unfolding; the toolkit then
        -- calls Render (onLayout).
        local width, height = Measure(box)
        box:SetContentSize(width, height, "TOP")
    end
    box:SetShown(wanted)
end

local function ShowTip(self)
    if type(GameTooltip) == "table" then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.tip, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end
end

-- A small icon button in the footer, with its tooltip. Plain, nothing secure.
local function Icon(texture, tip)
    local button = CreateFrame("Button", nil, footer.bar)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.icon:SetTexture(texture)
    button.tip = tip
    button:SetScript("OnEnter", ShowTip)
    button:SetScript("OnLeave", HideFull)
    return button
end

-- A drag handle (the toolkit's Ctrl-drag while locked) whose click runs only
-- when the press did not become a drag.
local function DragSafe(button, onClick)
    box:AddDragHandle(button)
    button:HookScript("OnMouseDown", function(self) self.dragged = nil end)
    button:HookScript("OnDragStart", function(self) self.dragged = true end)
    button:SetScript("OnClick", function(self, mouseButton)
        if not self.dragged then
            onClick(self, mouseButton)
        end
    end)
end

-- Needs Dyre's Toolkit 2 (widgets); without it, DQT has no box.
function DQT.CreateBox()
    local toolkit = DQT.Toolkit()
    if box or not toolkit or type(toolkit.CreateWidget) ~= "function" then
        return nil
    end
    local frame = CreateFrame("Frame", "DyresQuestTargetingBox", UIParent, "BackdropTemplate")
    if frame.SetBackdrop then
        frame:SetBackdrop(BACKDROP)
    end
    frame:Hide()
    box, rows = frame, {}
    -- Two settings decide at login (author): the quest's part and the hit
    -- list; the targets and left-out sections keep their saved folds.
    DQT.db.box.foldedSections.quest = DQT.db.startQuestFolded or nil
    DQT.db.box.foldedSections.added = DQT.db.startHitListFolded or nil
    -- The header: one line on its own dark, rounded inset panel, the
    -- quest's title: a click folds the quest's part. No close button.
    header = Row(frame, "BackdropTemplate")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", BORDER_INSET, -BORDER_INSET)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -BORDER_INSET, -BORDER_INSET)
    if header.SetBackdrop then
        header:SetBackdrop(HEADER_BACKDROP)
    end
    header:SetScript("OnEnter", ShowHeader)
    header.toggle:Hide()
    header.rate:Hide()
    header.remove:Hide()
    local function ToggleAll()
        SetAllFolded(not AllFolded())
        DQT.UpdateBox()
    end
    -- A visible fold button at the right end (author): folds or opens all;
    -- the header text stops before it, cut with a tooltip.
    header.fold = CreateFrame("Button", nil, header)
    header.fold:SetPoint("RIGHT", header, "RIGHT", BORDER_INSET - PADDING, 0)
    header.fold:SetScript("OnClick", ToggleAll)
    header.label:SetPoint("LEFT", header, "LEFT", PADDING - BORDER_INSET, 0)
    header.label:SetPoint("RIGHT", header.fold, "LEFT", -BUTTON_GAP, 0)
    objectiveRow = Row(frame)
    insertLine = frame:CreateTexture(nil, "OVERLAY")
    insertLine:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    insertLine:SetHeight(INSERT_HEIGHT)
    insertLine:Hide()
    -- The footer bar: a plain frame, so its empty part lets clicks through;
    -- only its icons take clicks. Add: your target, any name containing it;
    -- Shift-click: the exact name.
    footer = {bar = CreateFrame("Frame", nil, frame, "BackdropTemplate")}
    if footer.bar.SetBackdrop then
        footer.bar:SetBackdrop(HEADER_BACKDROP)
    end
    -- The hit list's title: the whole bar but its icons (author: a click
    -- anywhere in a section's title shows or hides it). The icons sit above it.
    footer.title = CreateFrame("Button", nil, footer.bar)
    footer.title:SetPoint("TOPLEFT", footer.bar, "TOPLEFT", 0, 0)
    footer.title:SetPoint("BOTTOMRIGHT", footer.bar, "BOTTOMRIGHT", 0, 0)
    footer.title.tip = HIT_LIST_TIP
    footer.title:SetScript("OnEnter", ShowTip)
    footer.title:SetScript("OnLeave", HideFull)
    footer.count = footer.title:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer.count:SetPoint("CENTER", footer.title, "CENTER", 0, 0)
    footer.add = Icon(EXPAND_TEXTURE, ADD_TIP)
    footer.clear = Icon(REMOVE_TEXTURE, CLEAR_TIP)
    footer.add:SetFrameLevel(footer.title:GetFrameLevel() + 1)
    footer.clear:SetFrameLevel(footer.title:GetFrameLevel() + 1)
    -- The strip: the bars' dark fill without an edge (an edge does not fit
    -- its half height), empty.
    strip = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    if strip.SetBackdrop then
        strip:SetBackdrop(STRIP_BACKDROP)
    end
    DQT.ApplyBoxStyle()
    toolkit.CreateWidget({
        addon = "DyresQuestTargeting", key = WIDGET_KEY, title = TITLE, frame = frame,
        store = DQT.db.box, width = SIZES.width.default, height = SIZES.height.default,
        point = DEFAULT_POINT, sizes = SIZES, sizeOrder = SIZE_ORDER, resetSizes = RESET_SIZES,
        measure = Measure,
        onLayout = Render,
        onUnlock = function() DQT.UpdateBox() end,
    })
    -- Dragging the header or a footer icon moves the box too (Ctrl-drag while
    -- locked); a press that became a drag is not a click.
    DragSafe(header, function() ToggleSection("quest") end)
    DragSafe(footer.add, function()
        if IsShiftKeyDown() then
            DQT.AddExact()
        else
            DQT.AddSimilar()
        end
    end)
    DragSafe(footer.clear, function() DQT.ResetAdded() end)
    DragSafe(footer.title, function() ToggleSection("added") end)
    DQT.box = frame
    return frame
end
