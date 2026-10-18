local _, DQT = ...

-- One settings page in Blizzard's vertical layout, with proxy settings that
-- read and write DyresQuestTargetingDB directly.
local TITLE = "Dyre's Quest Targeting"
local UNAVAILABLE = "The AddOn settings page is unavailable on this client. Use /dqt on and /dqt off."

local REQUIRED_SETTINGS = {
    "RegisterVerticalLayoutCategory", "RegisterProxySetting", "RegisterAddOnCategory", "CreateCheckbox",
    "CreateDropdown", "CreateControlTextContainer", "OpenToCategory",
}

-- Raid target markers by index, 0 for none.
local MARKERS = {
    [0] = "None", "Star", "Circle", "Diamond", "Triangle (green)", "Moon", "Square", "Cross", "Skull",
}

local category

-- Your spellbook's active spells, as the macro casts them: "Name(Rank N)",
-- each rank up to the one the spellbook shows (it may list only the highest),
-- or "Name" for a spell without ranks. The spellbook APIs return no secrets
-- (SpellBookDocumentation.lua); read when the dropdown opens.
local function SpellbookSpells()
    local spells, seen = {}, {}
    local book = C_SpellBook
    local enum = type(Enum) == "table" and Enum
    if type(book) ~= "table" or type(book.GetNumSpellBookSkillLines) ~= "function"
            or type(book.GetSpellBookSkillLineInfo) ~= "function" or type(book.GetSpellBookItemInfo) ~= "function"
            or not (enum and enum.SpellBookSpellBank and enum.SpellBookItemType) then
        return spells
    end
    local function Add(name)
        name = DQT.CheckOpener(name)
        if name and name ~= "" and name ~= DQT.OPENER_ATTACK and not seen[name] then
            seen[name] = true
            spells[#spells + 1] = name
        end
    end
    for line = 1, book.GetNumSpellBookSkillLines() do
        local info = book.GetSpellBookSkillLineInfo(line)
        if type(info) == "table" and not info.shouldHide and not info.isGuild then
            for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local item = book.GetSpellBookItemInfo(slot, enum.SpellBookSpellBank.Player)
                if type(item) == "table" and item.itemType == enum.SpellBookItemType.Spell and not item.isPassive
                        and not item.isOffSpec and type(item.name) == "string" then
                    local rank = type(item.subName) == "string" and tonumber(item.subName:match("^Rank (%d+)$"))
                    if rank then
                        for each = 1, rank do
                            Add(item.name .. "(Rank " .. each .. ")")
                        end
                    else
                        Add(item.name)
                    end
                end
            end
        end
    end
    table.sort(spells)
    return spells
end

local function OpenerChoices()
    local container = Settings.CreateControlTextContainer()
    container:Add(DQT.OPENER_NONE, "Nothing")
    container:Add(DQT.OPENER_ATTACK, "Start attacking (/startattack)")
    local spells = SpellbookSpells()
    local current = DQT.db.opener
    local listed = current == DQT.OPENER_NONE or current == DQT.OPENER_ATTACK
    for _, name in ipairs(spells) do
        container:Add(name, name)
        listed = listed or name == current
    end
    -- A spell chosen earlier that the spellbook no longer shows stays selectable.
    if not listed then
        container:Add(current, current)
    end
    return container:GetData()
end

local function HasSettingsAPI()
    if type(Settings) ~= "table" or type(Settings.VarType) ~= "table" then
        return false
    end
    for _, name in ipairs(REQUIRED_SETTINGS) do
        if type(Settings[name]) ~= "function" then
            return false
        end
    end
    return true
end

local function Proxy(variable, variableType, name, default, getValue, setValue)
    return Settings.RegisterProxySetting(category, variable, variableType, name, default, getValue, setValue)
end

local function Flag(variable, name, key, default, tooltip)
    local setting = Proxy(variable, Settings.VarType.Boolean, name, default,
        function() return DQT.db[key] end,
        function(value)
            DQT.db[key] = value == true
            DQT.Refresh()
        end)
    return Settings.CreateCheckbox(category, setting, tooltip)
end

local function MarkerChoices()
    local container = Settings.CreateControlTextContainer()
    for index = DQT.MARKER_MIN, DQT.MARKER_MAX do
        container:Add(index, MARKERS[index])
    end
    return container:GetData()
end

local function Marker(variable, name, key, default, tooltip)
    local setting = Proxy(variable, Settings.VarType.Number, name, default,
        function() return DQT.db[key] end,
        function(value)
            if MARKERS[value] then
                DQT.db[key] = value
                DQT.Refresh()
            end
        end)
    return Settings.CreateDropdown(category, setting, MarkerChoices, tooltip)
end

function DQT.InitializeOptions()
    if not HasSettingsAPI() then
        return
    end
    category = Settings.RegisterVerticalLayoutCategory(TITLE)
    Flag("DQT_ENABLED", "Keep the macro up to date", "enabled", true,
        "Rewrite the character macro \"" .. DQT.MACRO_NAME .. "\" with the mobs and NPCs your focused quest "
            .. "needs, out of combat. Off leaves the macro as it is. /dqt on and /dqt off do the same.")
    Flag("DQT_QUESTIE_FOCUS", "Follow Questie's tracker focus", "questieFocus", true,
        "With Questie installed, also follow the quest (or objective) you focus in Questie's tracker; "
            .. "whichever focus you set last wins. Off: only the game's quest log and map focus count.")
    Flag("DQT_MARK", "Mark what the macro finds", "mark", true,
        "Put a raid marker on the mob or NPC the macro finds, so it is easy to spot.")
    Marker("DQT_MOB_MARKER", "Marker for mobs", "mobMarker", DQT.DEFAULT_MOB_MARKER,
        "The raid marker the macro puts on a mob it finds. In a raid, only leaders and assistants can mark.")
    Marker("DQT_NPC_MARKER", "Marker for NPCs", "npcMarker", DQT.DEFAULT_NPC_MARKER,
        "The raid marker the macro puts on an NPC it finds (anything you cannot attack), such as the one "
            .. "you turn the quest in to.")
    local opener = Proxy("DQT_OPENER", Settings.VarType.String, "On a mob, also", DQT.OPENER_NONE,
        function() return DQT.db.opener end,
        function(value)
            local checked = DQT.CheckOpener(value)
            if checked then
                DQT.db.opener = checked
                DQT.Refresh()
            end
        end)
    Settings.CreateDropdown(category, opener, OpenerChoices,
        "What the macro does to a mob it finds: nothing, start attacking, or cast one of your spells, such as "
            .. "a low rank you tag mobs with. Never on an NPC.")
    Settings.RegisterAddOnCategory(category)
end

function DQT.OpenSettings()
    if not category then
        DQT.Report(UNAVAILABLE)
        return
    end
    Settings.OpenToCategory(category:GetID())
end
