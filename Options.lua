local _, DQT = ...

-- One settings page in Blizzard's vertical layout, with proxy settings that
-- read and write DyresQuestTargetingDB directly: under Dyre's Toolkit's
-- "Dyre's AddOns" when the toolkit is installed, else at the top level.
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

local category, layout

-- "On a mob, also" lists only harmful spells (C_Spell.IsSpellHarmful: "can be
-- cast on hostile targets") that cast in this long or less (author-approved);
-- SpellInfo.castTime is in milliseconds, 0 for instant. Checked per rank, as
-- "Name(Rank N)": a low rank often casts faster than the top one.
local MAX_OPENER_CAST_MS = 1000
-- Shown in both Questie settings' tooltips, under their own section heading.
local EXPERIMENTAL = " Experimental: it uses Questie's own code, not a public API. Use with caution."
local QUESTIE_HEADING = "Questie Synchronization (Experimental)"
local NEEDS_QUESTIE = " Needs Questie: greyed out until it is installed and on."
local NEEDS_QUESTIE_TOMTOM = " Needs Questie and TomTom: greyed out until both are installed and on."
local BOX_HEADING = "Quest Target Box"

-- Harmful and fast enough to open with. Without the spell APIs, every spell
-- counts, as before; a value that may be secret never counts.
local function IsOpenerSpell(name)
    local spell = C_Spell
    if type(spell) ~= "table" or type(spell.IsSpellHarmful) ~= "function"
            or type(spell.GetSpellInfo) ~= "function" then
        return true
    end
    local harmful = spell.IsSpellHarmful(name)
    if DQT.IsSecret(harmful) or harmful ~= true then
        return false
    end
    local info = spell.GetSpellInfo(name)
    if DQT.IsSecret(info) or type(info) ~= "table" then
        return false
    end
    local castTime = info.castTime
    return not DQT.IsSecret(castTime) and type(castTime) == "number" and castTime <= MAX_OPENER_CAST_MS
end

-- Your spellbook's active spells, as the macro casts them: "Name(Rank N)",
-- each rank up to the one the spellbook shows (it may list only the highest),
-- or "Name" for a spell without ranks; only openers (IsOpenerSpell). The
-- spellbook APIs return no secrets (SpellBookDocumentation.lua); read when
-- the dropdown opens.
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
        if name and name ~= "" and name ~= DQT.OPENER_ATTACK and not seen[name] and IsOpenerSpell(name) then
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

-- Settings dropdown frames are pooled across AddOns, and Blizzard sets a
-- frame's selection-text function only when an initializer has one, never
-- clearing it (Blizzard_SettingControls.lua, InitDropdown). Another AddOn's
-- function (found in client: Dyre's Sounds' sound labels) then labels our
-- dropdown. Ours returns nil, which replaces a stale one and keeps the
-- default label, the chosen option's text.
local function Dropdown(setting, choices, tooltip)
    local initializer = Settings.CreateDropdown(category, setting, choices, tooltip)
    if type(initializer) == "table" then
        initializer.getSelectionTextFunc = function() return nil end
    end
    return initializer
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
    return Dropdown(setting, MarkerChoices, tooltip)
end

-- Settings that need another AddOn are greyed out without it (author), not
-- hidden; their saved values stay, so they work once it is installed. The
-- settings list asks each time it draws the row (an initializer's modify
-- predicates, Blizzard_SettingControls.lua), so an AddOn that loads after
-- this page is built counts too. The same globals the features use.
local function QuestieLoaded()
    return type(QuestieLoader) == "table"
end

local function QuestieAndTomTomLoaded()
    return QuestieLoaded() and type(TomTom) == "table"
end

local function Needs(initializer, loaded)
    if type(initializer) == "table" and type(initializer.AddModifyPredicate) == "function" then
        initializer:AddModifyPredicate(loaded)
    end
    return initializer
end

-- A section heading, as Blizzard's Controls page adds them
-- (Blizzard_SettingControls.lua); without it the names still say what they are.
local function Heading(text)
    if type(CreateSettingsListSectionHeaderInitializer) == "function" and type(layout) == "table"
            and type(layout.AddInitializer) == "function" then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
    end
end

function DQT.InitializeOptions()
    if not HasSettingsAPI() then
        return
    end
    local toolkit = DQT.Toolkit()
    if toolkit and type(toolkit.RegisterSettingsCategory) == "function" then
        category, layout = toolkit.RegisterSettingsCategory(TITLE)
    end
    local topLevel = not category
    if topLevel then
        category, layout = Settings.RegisterVerticalLayoutCategory(TITLE)
    end
    Flag("DQT_ENABLED", "Keep the macro up to date", "enabled", true,
        "Rewrite the macro \"" .. DQT.MACRO_NAME .. "\" with the mobs and NPCs your focused quest "
            .. "needs, out of combat. Off leaves the macro as it is. /dqt on and /dqt off do the same.")
    Needs(Flag("DQT_QUESTIE_FOCUS", "Follow Questie's tracker focus", "questieFocus", true,
        "With Questie installed, also follow the quest (or objective) you focus in Questie's tracker; "
            .. "whichever focus you set last wins. Off: only the game's quest log and map focus count."
            .. NEEDS_QUESTIE), QuestieLoaded)
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
    Dropdown(opener, OpenerChoices,
        "What the macro does to a mob it finds: nothing, start attacking, or cast one of your spells, such as "
            .. "a low rank you tag mobs with. Only harmful spells with a cast time of 1 second or less are "
            .. "listed. Never on an NPC.")
    Flag("DQT_ACCOUNT_MACRO", "Use an account-wide macro", "accountMacro", false,
        "Off (the default): each character has its own macro, in its character macro slots. On: one "
            .. "account-wide macro, for when character slots run short; DQT rewrites it for whichever character "
            .. "is logged in. Not for playing two characters at once: they would rewrite it in turn. After "
            .. "switching, put the new macro on your bars and delete the old one.")
    -- Without headings, the names still say experimental.
    Heading(QUESTIE_HEADING)
    Needs(Flag("DQT_SYNC_FOCUS", "Keep Questie's and the game's focus in sync (experimental)", "syncFocus", false,
        "With Questie installed: focusing a quest in Questie's tracker also focuses it in the game's quest "
            .. "log and map, and the other way round. A Questie objective focus gives the game its quest. "
            .. "Needs \"Follow Questie's tracker focus\"." .. EXPERIMENTAL .. NEEDS_QUESTIE), QuestieLoaded)
    local tomtom = Proxy("DQT_TOMTOM", Settings.VarType.Boolean, "Point TomTom at the focused quest (experimental)", false,
        function() return DQT.db.tomtom end,
        function(value)
            DQT.db.tomtom = value == true
            DQT.Refresh()
            if DQT.db.tomtom and DQT.current then
                DQT.PointTomTom(DQT.current.quest, DQT.current.kept, true)
            end
        end)
    Needs(Settings.CreateCheckbox(category, tomtom,
        "With Questie and TomTom installed: points the TomTom arrow at the nearest of the quest mobs "
            .. "the macro looks for (the best droppers, for a quest item), or at the turn-in once the quest is "
            .. "done. It moves when the focused quest or objective changes, an objective is done, or the quest "
            .. "is ready to turn in." .. EXPERIMENTAL .. NEEDS_QUESTIE_TOMTOM), QuestieAndTomTomLoaded)
    Heading(BOX_HEADING)
    Flag("DQT_SHOW_BOX", "Show the Quest Target Box", "showBox", true,
        "A box with your focused quest, what the macro looks for (with drop rates), the names left out, and your "
            .. "hit list, with buttons to add your target or remove names. It hides when there is nothing to show. "
            .. "Move it with /dqt unlock.")
    Flag("DQT_START_QUEST_FOLDED", "Start the quest targets folded", "startQuestFolded", false,
        "At login, the quest's part of the box (its targets) starts folded under the quest's name. During "
            .. "play, a click on the quest's name folds or opens it.")
    Flag("DQT_START_HIT_LIST_FOLDED", "Start the hit list folded", "startHitListFolded", true,
        "At login, the hit list starts folded: only its \"Hit list\" bar shows. During play, a click on "
            .. "that bar folds or opens it. The button at the header's right folds or opens all.")
    local style = Proxy("DQT_BOX_STYLE", Settings.VarType.String, "Style", DQT.DEFAULT_BOX_STYLE,
        function() return DQT.db.boxStyle end,
        function(value)
            if DQT.BOX_STYLES[value] then
                DQT.db.boxStyle = value
                DQT.ApplyBoxStyle()
            end
        end)
    Dropdown(style, function()
        local container = Settings.CreateControlTextContainer()
        for _, key in ipairs(DQT.BOX_STYLE_ORDER) do
            container:Add(key, DQT.BOX_STYLES[key].label)
        end
        return container:GetData()
    end, "The box's colors: a brown or a near-black panel, both with a gold edge and gold titles.")
    local toolkit = DQT.Toolkit()
    if DQT.box and toolkit and type(toolkit.AddWidgetSettings) == "function" then
        toolkit.AddWidgetSettings(category, layout, DQT.box, {
            labels = {height = "Max height"},
            tooltips = {
                height = "The most the box grows to. It grows and shrinks with what it shows; a longer list is "
                    .. "cut, and its last row says how many more (/dqt list shows all).",
                textSize = "The size of the text only; the box keeps its size, and fewer rows fit at bigger text."},
            resetTooltip = "Back to its own width, height, and text size. Opacity stays as it is."})
    end
    if topLevel then
        Settings.RegisterAddOnCategory(category)
    end
end

-- Never opened in combat (no panels in combat); /dqt list still works then.
function DQT.OpenSettings()
    if not category then
        DQT.Report(UNAVAILABLE)
        return
    end
    if InCombatLockdown() then
        DQT.Report("The settings open out of combat. /dqt list shows what the macro targets.")
        return
    end
    Settings.OpenToCategory(category:GetID())
end
