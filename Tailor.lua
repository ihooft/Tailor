local ADDON_NAME = ...
local Tailor = CreateFrame("Frame")

TailorDB = TailorDB or {}

local promptedItems = {}
local upgradeQueue = {}
local queuedIdentities = {}
local currentUpgrade
local scanQueued = false
local scanning = false
local scanGeneration = 0

local ARMOR_CLASS_ID = 4
local WEAPON_CLASS_ID = 2

local WEIGHTS = {
    {"armor", "Armor", 1},
    {"dps", "Weapon DPS", 1},
    {"stamina", "Stamina", 0},
    {"strength", "Strength", 0},
    {"intellect", "Intellect", 0},
    {"agility", "Agility", 0},
    {"crit", "Critical Strike", 0},
    {"haste", "Haste", 0},
    {"spirit", "Spirit", 0},
    {"mp5", "MP5", 0},
    {"spellDamage", "Spell Damage", 0},
    {"spellHealing", "Spell Healing", 0},
}

TailorDB.weights = TailorDB.weights or {}
for _, entry in ipairs(WEIGHTS) do
    local value = tonumber(TailorDB.weights[entry[1]])
    TailorDB.weights[entry[1]] = value and math.max(0, math.min(1, value)) or entry[3]
end

local ARMOR_EQUIP_LOCS = {
    INVTYPE_HEAD = true,
    INVTYPE_SHOULDER = true,
    INVTYPE_CHEST = true,
    INVTYPE_ROBE = true,
    INVTYPE_WRIST = true,
    INVTYPE_HAND = true,
    INVTYPE_WAIST = true,
    INVTYPE_LEGS = true,
    INVTYPE_FEET = true,
}

-- Cloth = 1, leather = 2, mail = 3, plate = 4. Classes can also
-- equip lower tiers, but cannot equip a tier above their proficiency.
local MAX_ARMOR_SUBCLASS_BY_CLASS = {
    WARRIOR = 4, PALADIN = 4, DEATHKNIGHT = 4,
    HUNTER = 3, SHAMAN = 3, EVOKER = 3,
    ROGUE = 2, DRUID = 2, MONK = 2, DEMONHUNTER = 2,
    PRIEST = 1, MAGE = 1, WARLOCK = 1,
}

local function CanWearArmor(candidate)
    if candidate.classID ~= ARMOR_CLASS_ID
        or not ARMOR_EQUIP_LOCS[candidate.equipLoc] then
        return true
    end

    local subclass = candidate.subclassID
    if subclass == 0 then return true end -- Generic/cosmetic armor.
    local _, classToken = UnitClass("player")
    local maxSubclass = MAX_ARMOR_SUBCLASS_BY_CLASS[classToken]
    return type(subclass) == "number" and subclass >= 1
        and subclass <= 4 and maxSubclass ~= nil and subclass <= maxSubclass
end

local function CanEquipWeapon(candidate)
    -- IsEquippableItem checks that the item fits equipment slots. CanUseItem
    -- checks whether this character meets the item's equip requirements,
    -- including its weapon or shield proficiency.
    return C_Item.IsEquippableItem(candidate.link)
        and C_PlayerInfo.CanUseItem(candidate.itemID)
end

local WEAPON_EQUIP_LOCS = {
    INVTYPE_WEAPON = true,
    INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_RANGED = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_THROWN = true,
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Tailor|r: " .. msg)
end

local function GetItemIdentity(itemLink, itemID)
    return itemLink or ("item:" .. tostring(itemID))
end

local function ParseDPSNumber(s)
    if not s then return nil end
    -- Strip thousands separators while respecting decimal commas.
    s = s:gsub("%s", "")
    if s:find(",", 1, true) and s:find(".", 1, true) then
        if s:find(",") > s:find("%.") then
            s = s:gsub("%.", ""):gsub(",", ".")
        else
            s = s:gsub(",", "")
        end
    elseif s:find(",", 1, true) then
        s = s:gsub(",", ".")
    end
    return tonumber(s)
end

local function GetWeaponDPS(itemLink)
    local stats = C_Item.GetItemStats(itemLink)
    local statDPS = stats and tonumber(stats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT)
    if statDPS and statDPS > 0 then return statDPS end

    if not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
        return nil
    end

    local data = C_TooltipInfo.GetHyperlink(itemLink)
    if not data or not data.lines then
        return nil
    end

    -- Only parse a line labeled DPS; never infer speed from an arbitrary
    -- decimal elsewhere in the tooltip.
    local dpsLabel = type(DAMAGE_PER_SECOND) == "string"
        and DAMAGE_PER_SECOND:lower() or "damage per second"
    for _, line in ipairs(data.lines) do
        for _, text in ipairs({line.leftText or "", line.rightText or ""}) do
            local lower = text:lower()
            local labelStart, labelEnd = lower:find(dpsLabel, 1, true)
            if labelStart then
                local before = text:sub(1, labelStart - 1)
                local after = text:sub(labelEnd + 1)
                local raw = before:match("(%d[%d%.,]*)%D*$")
                    or after:match("^%D*(%d[%d%.,]*)")
                local dps = ParseDPSNumber(raw)
                if dps and dps > 0 then return dps end
            end
        end
    end

    return nil
end

local function GetWeightedValue(itemLink, classID)
    local stats = C_Item.GetItemStats(itemLink) or {}
    local w = TailorDB.weights
    local function Stat(key)
        return tonumber(stats[key]) or 0
    end
    local total = Stat("ITEM_MOD_STAMINA_SHORT") * w.stamina
        + Stat("ITEM_MOD_STRENGTH_SHORT") * w.strength
        + Stat("ITEM_MOD_INTELLECT_SHORT") * w.intellect
        + Stat("ITEM_MOD_AGILITY_SHORT") * w.agility
        + Stat("ITEM_MOD_CRIT_RATING_SHORT") * w.crit
        + Stat("ITEM_MOD_HASTE_RATING_SHORT") * w.haste
        + Stat("ITEM_MOD_SPIRIT_SHORT") * w.spirit
        + math.max(Stat("ITEM_MOD_POWER_REGEN0_SHORT"),
            Stat("ITEM_MOD_MANA_REGENERATION_SHORT")) * w.mp5

    -- Older items may have separate spell damage/healing. Retail spell power
    -- benefits both, so count that shared stat once at the larger weight.
    local sharedSpellPower = Stat("ITEM_MOD_SPELL_POWER_SHORT")
    if sharedSpellPower > 0 then
        total = total + sharedSpellPower * math.max(w.spellDamage, w.spellHealing)
    else
        total = total
            + math.max(Stat("ITEM_MOD_SPELL_DAMAGE_DONE_SHORT"),
                Stat("ITEM_MOD_SPELL_DAMAGE_DONE")) * w.spellDamage
            + math.max(Stat("ITEM_MOD_SPELL_HEALING_DONE_SHORT"),
                Stat("ITEM_MOD_SPELL_HEALING_DONE")) * w.spellHealing
    end

    if classID == ARMOR_CLASS_ID then
        total = total + (tonumber(stats.RESISTANCE0_NAME) or 0) * w.armor
    elseif classID == WEAPON_CLASS_ID and w.dps > 0 then
        local dps = GetWeaponDPS(itemLink)
        if not dps then return nil end
        total = total + dps * w.dps
    end
    return total
end

local function GetItemInfo(itemLink, itemID, callback)
    local name, link, quality, itemLevel, minLevel, itemType, itemSubType,
          stackCount, equipLoc, texture, sellPrice, classID, subclassID =
        C_Item.GetItemInfo(itemLink or itemID)

    if name and equipLoc then
        callback({
            name = name,
            link = link or itemLink,
            quality = quality,
            itemLevel = itemLevel,
            equipLoc = equipLoc,
            classID = classID,
            subclassID = subclassID,
            itemID = itemID,
        })
        return
    end

    -- C_Item.GetItemInfo() can return nil until server item data is cached.
    -- ContinueOnItemLoad lets the scan resume without dropping the item.
    local item = itemLink and Item:CreateFromItemLink(itemLink) or Item:CreateFromItemID(itemID)
    item:ContinueOnItemLoad(function()
        local n, l, q, ilvl, minLvl, typ, subtyp, stack, loc, icon,
              sell, cid, scid = C_Item.GetItemInfo(itemLink or itemID)

        if n and loc then
            callback({
                name = n,
                link = l or itemLink,
                quality = q,
                itemLevel = ilvl,
                equipLoc = loc,
                classID = cid,
                subclassID = scid,
                itemID = itemID,
            })
        end
    end)
end

local function GetCandidateSlots(equipLoc)
    if equipLoc == "INVTYPE_2HWEAPON" then
        return {16}
    elseif equipLoc == "INVTYPE_WEAPONMAINHAND" then
        return {16}
    elseif equipLoc == "INVTYPE_WEAPONOFFHAND" then
        return {17}
    elseif equipLoc == "INVTYPE_WEAPON" then
        return {16, 17}
    elseif equipLoc == "INVTYPE_RANGED"
        or equipLoc == "INVTYPE_RANGEDRIGHT"
        or equipLoc == "INVTYPE_THROWN" then
        return {16}
    elseif equipLoc == "INVTYPE_SHIELD"
        or equipLoc == "INVTYPE_HOLDABLE" then
        return {17}
    elseif equipLoc == "INVTYPE_CLOAK" then
        return {15}
    elseif equipLoc == "INVTYPE_HEAD" then
        return {1}
    elseif equipLoc == "INVTYPE_NECK" then
        return {2}
    elseif equipLoc == "INVTYPE_SHOULDER" then
        return {3}
    elseif equipLoc == "INVTYPE_CHEST" or equipLoc == "INVTYPE_ROBE" then
        return {5}
    elseif equipLoc == "INVTYPE_WAIST" then
        return {6}
    elseif equipLoc == "INVTYPE_LEGS" then
        return {7}
    elseif equipLoc == "INVTYPE_FEET" then
        return {8}
    elseif equipLoc == "INVTYPE_WRIST" then
        return {9}
    elseif equipLoc == "INVTYPE_HAND" then
        return {10}
    elseif equipLoc == "INVTYPE_FINGER" then
        return {11, 12}
    elseif equipLoc == "INVTYPE_TRINKET" then
        return {13, 14}
    end
end

local function GetEquippedItem(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then
        return nil
    end

    local itemID, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(link)
    local name, actualLink, quality, itemLevel, minLevel, itemType, itemSubType,
          stackCount, actualEquipLoc, texture, sellPrice, actualClassID =
        C_Item.GetItemInfo(link)

    if not name then
        return nil
    end

    classID = actualClassID or classID

    return {
        slot = slot,
        name = name,
        quality = quality,
        link = actualLink or link,
        itemID = itemID,
        equipLoc = actualEquipLoc or equipLoc,
        classID = classID,
        value = GetWeightedValue(link, classID),
    }
end

local function MakeUpgrade(candidate, equipped, bag, bagSlot, equipSlot)
    if not GetCandidateSlots(candidate.equipLoc)
        or not C_Item.IsEquippableItem(candidate.link)
        or not CanWearArmor(candidate) then return nil end

    local candidateValue = GetWeightedValue(candidate.link, candidate.classID)
    if not candidateValue then return nil end
    if equipped and equipped.value == nil then return nil end
    local equippedValue = equipped and equipped.value or 0
    if equipped and candidateValue <= equippedValue then return nil end
    local result = {candidateValue = candidateValue, equippedValue = equippedValue}

    if result then
        result.item = candidate
        result.equipped = equipped
        result.bag = bag
        result.bagSlot = bagSlot
        result.equipSlot = equipSlot
        return result
    end
end

local function QueueUpgrade(upgrade)
    local identity
    if upgrade.weaponLoadout or upgrade.pairedLoadout then
        identity = (upgrade.weaponLoadout and "weapon:" or "pair:")
            .. (upgrade.pairedLoadout and tostring(upgrade.firstSlot) .. ":" or "")
            .. (upgrade.main and upgrade.main.link or "")
            .. ":" .. (upgrade.off and upgrade.off.link or "")
    else
        identity = GetItemIdentity(upgrade.item.link, upgrade.item.itemID)
            .. ":" .. upgrade.equipSlot
    end

    if promptedItems[identity] or queuedIdentities[identity] then
        return
    end

    queuedIdentities[identity] = true
    upgrade.identity = identity
    upgradeQueue[#upgradeQueue + 1] = upgrade
end

local STAT_LABELS = {
    RESISTANCE0_NAME = "Armor",
    ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "Weapon DPS",
    ITEM_MOD_STAMINA_SHORT = "Stamina",
    ITEM_MOD_STRENGTH_SHORT = "Strength",
    ITEM_MOD_INTELLECT_SHORT = "Intellect",
    ITEM_MOD_AGILITY_SHORT = "Agility",
    ITEM_MOD_CRIT_RATING_SHORT = "Critical Strike",
    ITEM_MOD_HASTE_RATING_SHORT = "Haste",
    ITEM_MOD_SPIRIT_SHORT = "Spirit",
    ITEM_MOD_POWER_REGEN0_SHORT = "MP5",
    ITEM_MOD_MANA_REGENERATION_SHORT = "MP5",
    ITEM_MOD_SPELL_POWER_SHORT = "Spell Power",
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "Spell Damage",
    ITEM_MOD_SPELL_DAMAGE_DONE = "Spell Damage",
    ITEM_MOD_SPELL_HEALING_DONE_SHORT = "Spell Healing",
    ITEM_MOD_SPELL_HEALING_DONE = "Spell Healing",
}

local STAT_ORDER = {
    "Armor", "Weapon DPS", "Stamina", "Strength", "Intellect",
    "Agility", "Critical Strike", "Haste", "Spirit", "MP5",
    "Spell Damage", "Spell Healing", "Spell Power",
}

local function GetDisplayStats(item)
    local result = {}
    if not item then return result end
    for key, value in pairs(C_Item.GetItemStats(item.link) or {}) do
        if type(value) == "number" and value ~= 0 then
            local label = STAT_LABELS[key]
            if not label then
                label = key:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", "")
                    :gsub("_", " "):lower():gsub("^%l", string.upper)
            end
            -- Short and long aliases can describe the same stat.
            if result[label] == nil or value > result[label] then
                result[label] = value
            end
        end
    end
    if item.classID == WEAPON_CLASS_ID then
        local dps = GetWeaponDPS(item.link)
        if dps then result["Weapon DPS"] = dps end
    end
    return result
end

local prompt = CreateFrame("Frame", "TailorUpgradePrompt", UIParent, "BackdropTemplate")
prompt:SetSize(600, 300)
prompt:SetPoint("CENTER")
prompt:SetFrameStrata("DIALOG")
prompt:SetMovable(true)
prompt:SetClampedToScreen(true)
prompt:RegisterForDrag("LeftButton")
prompt:SetScript("OnDragStart", prompt.StartMoving)
prompt:SetScript("OnDragStop", prompt.StopMovingOrSizing)
prompt:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    edgeSize = 24,
    insets = {left = 7, right = 7, top = 7, bottom = 7},
})
prompt:EnableMouse(true)
prompt:Hide()
tinsert(UISpecialFrames, "TailorUpgradePrompt")
local promptTitle = prompt:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
promptTitle:SetPoint("TOP", 0, -20)
promptTitle:SetText("Tailor - Upgrade Found")
local scroll = CreateFrame("ScrollFrame", "TailorUpgradeScroll", prompt,
    "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 26, -80)
scroll:SetPoint("BOTTOMRIGHT", -48, 65)
local scrollChild = CreateFrame("Frame", nil, scroll)
scrollChild:SetWidth(500)
scrollChild:SetHeight(1)
scroll:SetScrollChild(scrollChild)
local equippedHeader = prompt:CreateFontString(nil, "ARTWORK", "GameFontNormal")
equippedHeader:SetPoint("BOTTOMLEFT", scroll, "TOPLEFT", 0, 5)
equippedHeader:SetText("Equipped Item(s)")
local upgradeHeader = prompt:CreateFontString(nil, "ARTWORK", "GameFontNormal")
upgradeHeader:SetPoint("LEFT", equippedHeader, 260, 0)
upgradeHeader:SetText("Upgrade Item(s)")
local rows = {}
local function SetRow(index, label, equippedText, upgradeText)
    local row = rows[index]
    if not row then
        row = {}
        for column = 1, 2 do
            local text = scrollChild:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            text:SetPoint("TOPLEFT", (column - 1) * 260, -(index - 1) * 23)
            text:SetSize(250, 21)
            text:SetJustifyH("LEFT")
            row[column] = text
        end
        rows[index] = row
    end
    row[1]:SetText(label .. ": " .. equippedText)
    row[1]:SetTextColor(1, 1, 1)
    row[2]:SetText(label .. ": " .. upgradeText)
    row[2]:SetTextColor(1, 1, 1)
    row[1]:Show()
    row[2]:Show()
end
local function FormatNumber(value, decimals)
    local formatted = string.format("%." .. decimals .. "f", value or 0)
    if decimals > 0 then
        formatted = formatted:gsub("0+$", ""):gsub("%.$", "")
    end
    return formatted
end
local function WithDifference(old, new, decimals)
    local difference = new - old
    local displayDifference = FormatNumber(difference, decimals)
    if tonumber(displayDifference) == 0 then
        return FormatNumber(new, decimals)
    end
    local sign = difference > 0 and "+" or ""
    local color = difference > 0 and "|cff33ff33" or "|cffff4444"
    return FormatNumber(new, decimals) .. " " .. color
        .. "(" .. sign .. displayDifference .. ")|r"
end
local function QualityName(item, fallback)
    if not item then return fallback end
    if item.quality then
        return string.format("|cnIQ%d:%s|r", item.quality, item.name)
    end
    return item.name
end
local function CombinedStats(main, off)
    local combined = GetDisplayStats(main)
    for name, value in pairs(GetDisplayStats(off)) do
        combined[name] = (combined[name] or 0) + value
    end
    return combined
end
local equipButton = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
equipButton:SetSize(110, 25)
equipButton:SetPoint("BOTTOM", -125, 22)
equipButton:SetText("Equip")
local optionsButton = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
optionsButton:SetSize(110, 25)
optionsButton:SetPoint("BOTTOM", 0, 22)
optionsButton:SetText("Options")
local ignoreButton = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
ignoreButton:SetSize(110, 25)
ignoreButton:SetPoint("BOTTOM", 125, 22)
ignoreButton:SetText("Ignore")

local function ShowNextUpgrade()
    if InCombatLockdown() or currentUpgrade or #upgradeQueue == 0 then
        return
    end

    currentUpgrade = table.remove(upgradeQueue, 1)
    queuedIdentities[currentUpgrade.identity] = nil
    promptedItems[currentUpgrade.identity] = true

    local upgrade = currentUpgrade
    local equippedStats = upgrade.weaponLoadout
        and CombinedStats(upgrade.equipped, upgrade.equippedOff)
        or upgrade.pairedLoadout
            and CombinedStats(upgrade.equipped, upgrade.equippedOff)
        or GetDisplayStats(upgrade.equipped)
    local upgradeStats = upgrade.weaponLoadout
        and CombinedStats(upgrade.main, upgrade.off)
        or upgrade.pairedLoadout
            and CombinedStats(upgrade.main, upgrade.off)
        or GetDisplayStats(upgrade.item)
    SetRow(1, "Item Name",
        QualityName(upgrade.equipped, "Nothing equipped"),
        QualityName((upgrade.weaponLoadout or upgrade.pairedLoadout)
            and upgrade.main or upgrade.item, "Empty"))
    local valueRow = 2
    if upgrade.weaponLoadout or upgrade.pairedLoadout then
        SetRow(2, upgrade.weaponLoadout and "Off Hand" or "Second Slot",
            QualityName(upgrade.equippedOff, "Empty"),
            QualityName(upgrade.off, "Empty"))
        valueRow = 3
    end
    SetRow(valueRow, "Weighted Value", FormatNumber(upgrade.equippedValue, 2),
        WithDifference(upgrade.equippedValue, upgrade.candidateValue, 2))
    local names, seen = {}, {}
    for _, name in ipairs(STAT_ORDER) do
        if equippedStats[name] or upgradeStats[name] then
            names[#names + 1] = name
            seen[name] = true
        end
    end
    local extras = {}
    for name in pairs(equippedStats) do
        if not seen[name] then extras[name] = true end
    end
    for name in pairs(upgradeStats) do
        if not seen[name] then extras[name] = true end
    end
    local sortedExtras = {}
    for name in pairs(extras) do sortedExtras[#sortedExtras + 1] = name end
    table.sort(sortedExtras)
    for _, name in ipairs(sortedExtras) do names[#names + 1] = name end
    for index, name in ipairs(names) do
        local old, new = equippedStats[name] or 0, upgradeStats[name] or 0
        SetRow(index + valueRow, name, FormatNumber(old, 1),
            WithDifference(old, new, 1))
    end
    for index = #names + valueRow + 1, #rows do
        rows[index][1]:Hide()
        rows[index][2]:Hide()
    end
    local rowCount = #names + valueRow
    local gap = 48 -- roughly half an inch at a typical UI scale
    local leftWidth, rightWidth = 220, 220
    for index = 1, rowCount do
        leftWidth = math.max(leftWidth, rows[index][1]:GetUnboundedStringWidth() + 8)
        rightWidth = math.max(rightWidth, rows[index][2]:GetUnboundedStringWidth() + 8)
    end
    local availableWidth = math.max(440, UIParent:GetWidth() - 130 - gap)
    local columnWidth = math.min(math.max(leftWidth, rightWidth),
        availableWidth / 2)
    scrollChild:SetWidth(columnWidth * 2 + gap)
    scrollChild:SetHeight(math.max(1, rowCount * 23))
    for index = 1, rowCount do
        for column = 1, 2 do
            local text = rows[index][column]
            text:ClearAllPoints()
            text:SetPoint("TOPLEFT", scrollChild, "TOPLEFT",
                (column - 1) * (columnWidth + gap), -(index - 1) * 23)
            text:SetWidth(columnWidth)
        end
    end
    upgradeHeader:ClearAllPoints()
    upgradeHeader:SetPoint("LEFT", equippedHeader, columnWidth + gap, 0)
    prompt:SetSize(columnWidth * 2 + gap + 74,
        math.min(math.max(220, rowCount * 23 + 145),
            math.max(220, UIParent:GetHeight() - 60)))
    scroll:SetVerticalScroll(0)
    prompt:Show()
end

equipButton:SetScript("OnClick", function()
    if InCombatLockdown() then return end
    local upgrade = currentUpgrade
    currentUpgrade = nil
    prompt:Hide()
    if upgrade then
        if upgrade.weaponLoadout or upgrade.pairedLoadout then
            local firstSlot = upgrade.pairedLoadout and upgrade.firstSlot or 16
            local secondSlot = upgrade.pairedLoadout and upgrade.secondSlot or 17
            if upgrade.main and upgrade.main.fromBag then
                C_Item.EquipItemByName(upgrade.main.link, firstSlot)
            end
            if upgrade.off and upgrade.off.fromBag then
                C_Item.EquipItemByName(upgrade.off.link, secondSlot)
            end
        else
            C_Item.EquipItemByName(upgrade.item.link, upgrade.equipSlot)
        end
    end
    C_Timer.After(0.1, ShowNextUpgrade)
end)

ignoreButton:SetScript("OnClick", function()
    currentUpgrade = nil
    prompt:Hide()
    C_Timer.After(0.1, ShowNextUpgrade)
end)

prompt:SetScript("OnHide", function()
    if currentUpgrade then
        currentUpgrade = nil
        C_Timer.After(0.1, ShowNextUpgrade)
    end
end)

local function FindBestWeaponLoadout(pool, equippedMain, equippedOff)
    local dualWield = CanDualWield and CanDualWield() or false
    -- A two-handed main hand occupies both slots. One-handed off-hand weapons
    -- need Dual Wield; shields remain eligible without it.
    local currentValue = (equippedMain and equippedMain.value or 0)
        + (equippedOff and equippedOff.value or 0)
    if (equippedMain and equippedMain.value == nil)
        or (equippedOff and equippedOff.value == nil) then
        return nil
    end

    local mainOptions, offOptions = {}, {false}
    if equippedMain then mainOptions[#mainOptions + 1] = equippedMain end
    if not equippedMain then mainOptions[#mainOptions + 1] = false end
    if equippedOff then offOptions[#offOptions + 1] = equippedOff end
    for _, item in ipairs(pool) do
        if item.value then
            local loc = item.equipLoc
            if loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONMAINHAND"
                or loc == "INVTYPE_2HWEAPON" or loc == "INVTYPE_RANGED"
                or loc == "INVTYPE_RANGEDRIGHT" or loc == "INVTYPE_THROWN" then
                mainOptions[#mainOptions + 1] = item
            end
            if loc == "INVTYPE_SHIELD" or loc == "INVTYPE_HOLDABLE"
                or (dualWield and (loc == "INVTYPE_WEAPON"
                    or loc == "INVTYPE_WEAPONOFFHAND")) then
                offOptions[#offOptions + 1] = item
            end
        end
    end

    local best
    for _, main in ipairs(mainOptions) do
        local twoHanded = main and (main.equipLoc == "INVTYPE_2HWEAPON"
            or main.equipLoc == "INVTYPE_RANGED"
            or main.equipLoc == "INVTYPE_RANGEDRIGHT")
        for _, off in ipairs(offOptions) do
            local valid = (not twoHanded or not off)
                and (off or not equippedOff or twoHanded)
                and (not off or dualWield or off.equipLoc == "INVTYPE_SHIELD"
                    or off.equipLoc == "INVTYPE_HOLDABLE"
                    or (off == equippedOff and off.classID ~= WEAPON_CLASS_ID))
                and (not off or not (main and main.fromBag and off.fromBag
                    and main.bag == off.bag and main.bagSlot == off.bagSlot))
                and ((main and main.fromBag) or (off and off.fromBag))
            if valid then
                local value = (main and main.value or 0) + (off and off.value or 0)
                local filled = (main and 1 or 0) + (off and 1 or 0)
                local currentFilled = (equippedMain and 1 or 0)
                    + (equippedOff and 1 or 0)
                if (value > currentValue
                    or (value == currentValue and filled > currentFilled))
                    and (not best or value > best.candidateValue
                        or (value == best.candidateValue and filled > best.filled)) then
                    best = {
                        weaponLoadout = true,
                        item = main and main.fromBag and main or off,
                        main = main or nil,
                        off = off or nil,
                        equipped = equippedMain,
                        equippedOff = equippedOff,
                        candidateValue = value,
                        equippedValue = currentValue,
                        filled = filled,
                    }
                end
            end
        end
    end
    return best
end

local function FindBestPairedLoadout(pool, firstSlot, secondSlot)
    local currentFirst = GetEquippedItem(firstSlot)
    local currentSecond = GetEquippedItem(secondSlot)
    if (currentFirst and currentFirst.value == nil)
        or (currentSecond and currentSecond.value == nil) then return nil end
    local baseline = (currentFirst and currentFirst.value or 0)
        + (currentSecond and currentSecond.value or 0)
    local baselineFilled = (currentFirst and 1 or 0)
        + (currentSecond and 1 or 0)
    local firstOptions, secondOptions = {}, {}
    if currentFirst then
        firstOptions[#firstOptions + 1] = currentFirst
    else
        firstOptions[#firstOptions + 1] = false
    end
    if currentSecond then
        secondOptions[#secondOptions + 1] = currentSecond
    else
        secondOptions[#secondOptions + 1] = false
    end
    for _, item in ipairs(pool) do
        if item.value ~= nil then
            firstOptions[#firstOptions + 1] = item
            secondOptions[#secondOptions + 1] = item
        end
    end
    local best
    for _, first in ipairs(firstOptions) do
        for _, second in ipairs(secondOptions) do
            if (not first or not second or not (first.fromBag and second.fromBag
                and first.bag == second.bag and first.bagSlot == second.bagSlot))
                and ((first and first.fromBag) or (second and second.fromBag)) then
                local value = (first and first.value or 0)
                    + (second and second.value or 0)
                local filled = (first and 1 or 0) + (second and 1 or 0)
                if (value > baseline or (value == baseline and filled > baselineFilled))
                    and (not best or value > best.candidateValue
                        or (value == best.candidateValue and filled > best.filled)) then
                    best = {
                        pairedLoadout = true,
                        firstSlot = firstSlot,
                        secondSlot = secondSlot,
                        item = first and first.fromBag and first or second,
                        main = first or nil,
                        off = second or nil,
                        equipped = currentFirst,
                        equippedOff = currentSecond,
                        candidateValue = value,
                        equippedValue = baseline,
                        filled = filled,
                    }
                end
            end
        end
    end
    return best
end

local questHighlightGeneration = 0
local questHighlightQueued = false

local function GetComparisonItem(slot)
    local item = GetEquippedItem(slot)
    if GetInventoryItemLink("player", slot) and not item then
        return nil, false -- Wait for the equipped item's data.
    end
    return item, true
end

local function IsQuestRewardUpgrade(candidate, rewardIndex)
    if not GetCandidateSlots(candidate.equipLoc)
        or not C_Item.IsEquippableItem(candidate.link)
        or not C_PlayerInfo.CanUseItem(candidate.itemID)
        or not CanWearArmor(candidate) then
        return false
    end

    candidate.value = GetWeightedValue(candidate.link, candidate.classID)
    if candidate.value == nil then return false end

    -- A reward is a single item: use a unique synthetic bag position so the
    -- loadout helpers cannot equip it twice in a paired slot.
    candidate.fromBag = true
    candidate.bag = -1
    candidate.bagSlot = rewardIndex

    if (candidate.classID == WEAPON_CLASS_ID
            and WEAPON_EQUIP_LOCS[candidate.equipLoc])
        or candidate.equipLoc == "INVTYPE_SHIELD"
        or candidate.equipLoc == "INVTYPE_HOLDABLE" then
        local main, mainReady = GetComparisonItem(16)
        local off, offReady = GetComparisonItem(17)
        return mainReady and offReady
            and FindBestWeaponLoadout({candidate}, main, off) ~= nil
    elseif candidate.equipLoc == "INVTYPE_FINGER" then
        local first, firstReady = GetComparisonItem(11)
        local second, secondReady = GetComparisonItem(12)
        return firstReady and secondReady
            and FindBestPairedLoadout({candidate}, 11, 12) ~= nil
    elseif candidate.equipLoc == "INVTYPE_TRINKET" then
        local first, firstReady = GetComparisonItem(13)
        local second, secondReady = GetComparisonItem(14)
        return firstReady and secondReady
            and FindBestPairedLoadout({candidate}, 13, 14) ~= nil
    end

    for _, slot in ipairs(GetCandidateSlots(candidate.equipLoc)) do
        local equipped, ready = GetComparisonItem(slot)
        if ready and (not equipped or (equipped.value ~= nil
            and candidate.value > equipped.value)) then
            return true
        end
    end
    return false
end

local function SetQuestRewardHighlight(button, visible)
    if not button.TailorUpgradeBorder and visible then
        local border = CreateFrame("Frame", nil, button)
        border:SetAllPoints(button)
        border:EnableMouse(false)
        local function Edge(point1, point2, width, height)
            local texture = border:CreateTexture(nil, "OVERLAY")
            texture:SetColorTexture(0.20, 1.0, 0.25, 0.95)
            texture:SetPoint(point1, border, point1)
            if point2 then texture:SetPoint(point2, border, point2) end
            if width then texture:SetWidth(width) end
            if height then texture:SetHeight(height) end
        end
        Edge("TOPLEFT", "TOPRIGHT", nil, 2)
        Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
        Edge("TOPLEFT", "BOTTOMLEFT", 2)
        Edge("TOPRIGHT", "BOTTOMRIGHT", 2)
        button.TailorUpgradeBorder = border
    end
    if button.TailorUpgradeBorder then
        button.TailorUpgradeBorder:SetShown(visible)
    end
end

local function ClearQuestRewardHighlights()
    local frame = QuestInfoFrame and QuestInfoFrame.rewardsFrame
    if frame and frame.RewardButtons then
        for _, button in ipairs(frame.RewardButtons) do
            SetQuestRewardHighlight(button, false)
        end
    end
end

local function RefreshQuestRewardHighlights()
    questHighlightGeneration = questHighlightGeneration + 1
    local generation = questHighlightGeneration
    ClearQuestRewardHighlights()
    if not QuestFrameRewardPanel or not QuestFrameRewardPanel:IsShown()
        or not QuestInfoFrame or QuestInfoFrame.questLog then return end

    local frame = QuestInfoFrame.rewardsFrame
    if not frame or not frame.RewardButtons then return end
    local questID = GetQuestID()
    for _, button in ipairs(frame.RewardButtons) do
        if button:IsShown() and button.objectType == "item"
            and (button.type == "choice" or button.type == "reward") then
            local rewardType, rewardIndex = button.type, button:GetID()
            local count = rewardType == "choice"
                and GetNumQuestChoices() or GetNumQuestRewards()
            local link = rewardIndex and rewardIndex >= 1
                and rewardIndex <= count
                and GetQuestItemLink(rewardType, rewardIndex)
            if link then
                local itemID = C_Item.GetItemInfoInstant(link)
                if itemID then
                    GetItemInfo(link, itemID, function(candidate)
                        if generation == questHighlightGeneration
                            and QuestFrameRewardPanel:IsShown()
                            and GetQuestID() == questID
                            and button:IsShown()
                            and button.type == rewardType
                            and button:GetID() == rewardIndex
                            and GetQuestItemLink(rewardType, rewardIndex) == link then
                            SetQuestRewardHighlight(button,
                                IsQuestRewardUpgrade(candidate, rewardIndex))
                        end
                    end)
                end
            end
        end
    end
end

local function ScheduleQuestRewardHighlights()
    if questHighlightQueued then return end
    questHighlightQueued = true
    C_Timer.After(0, function()
        questHighlightQueued = false
        RefreshQuestRewardHighlights()
    end)
end

local function ScanBags()
    if scanning then
        scanQueued = true
        return
    end

    scanning = true
    scanGeneration = scanGeneration + 1
    local generation = scanGeneration
    local pending = 1
    local bestBySlot = {}
    local equippedBySlot = {}
    local weaponPool = {}
    local fingerPool, trinketPool = {}, {}

    local function FinishItem()
        pending = pending - 1
        if pending ~= 0 then return end

        scanning = false
        if scanQueued then
            scanQueued = false
            C_Timer.After(0.15, ScanBags)
            return
        end

        -- Only publish results after every bag item's data has loaded.
        -- Replace stale waiting prompts with this scan's strongest item per slot.
        wipe(upgradeQueue)
        wipe(queuedIdentities)
        for slot = 1, 19 do
            local upgrade = bestBySlot[slot]
            if upgrade then QueueUpgrade(upgrade) end
        end
        local main = GetEquippedItem(16)
        local off = GetEquippedItem(17)
        local weaponUpgrade = FindBestWeaponLoadout(weaponPool, main, off)
        if weaponUpgrade then QueueUpgrade(weaponUpgrade) end
        local fingerUpgrade = FindBestPairedLoadout(fingerPool, 11, 12)
        if fingerUpgrade then QueueUpgrade(fingerUpgrade) end
        local trinketUpgrade = FindBestPairedLoadout(trinketPool, 13, 14)
        if trinketUpgrade then QueueUpgrade(trinketUpgrade) end
        ShowNextUpgrade()
    end

    for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
        local slots = C_Container.GetContainerNumSlots(bag) or 0

        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)

            if info and info.itemID then
                local bagIndex, bagSlot, itemID, itemLink = bag, slot, info.itemID, info.hyperlink
                pending = pending + 1
                GetItemInfo(itemLink, itemID, function(candidate)
                    if generation ~= scanGeneration then return end
                    local current = C_Container.GetContainerItemInfo(bagIndex, bagSlot)
                    if current and current.itemID == itemID
                        and (not itemLink or current.hyperlink == itemLink)
                        and CanWearArmor(candidate) then
                        if (candidate.classID == WEAPON_CLASS_ID
                                and WEAPON_EQUIP_LOCS[candidate.equipLoc])
                            or candidate.equipLoc == "INVTYPE_SHIELD"
                            or candidate.equipLoc == "INVTYPE_HOLDABLE" then
                            if CanEquipWeapon(candidate) then
                                candidate.value = GetWeightedValue(candidate.link,
                                    candidate.classID)
                                candidate.fromBag = true
                                candidate.bag = bagIndex
                                candidate.bagSlot = bagSlot
                                weaponPool[#weaponPool + 1] = candidate
                            end
                        elseif candidate.equipLoc == "INVTYPE_FINGER"
                            or candidate.equipLoc == "INVTYPE_TRINKET" then
                            if C_Item.IsEquippableItem(candidate.link) then
                                candidate.value = GetWeightedValue(candidate.link,
                                    candidate.classID)
                                candidate.fromBag = true
                                candidate.bag = bagIndex
                                candidate.bagSlot = bagSlot
                                local pool = candidate.equipLoc == "INVTYPE_FINGER"
                                    and fingerPool or trinketPool
                                pool[#pool + 1] = candidate
                            end
                        else
                            local slotsForItem = GetCandidateSlots(candidate.equipLoc)
                            if slotsForItem then
                                local bestForItem
                                for _, equipSlot in ipairs(slotsForItem) do
                                    if equippedBySlot[equipSlot] == nil then
                                        equippedBySlot[equipSlot] = GetEquippedItem(equipSlot) or false
                                    end
                                    local equipped = equippedBySlot[equipSlot]
                                    local upgrade = MakeUpgrade(candidate,
                                        equipped or nil, bagIndex, bagSlot, equipSlot)
                                    if upgrade and (not bestForItem
                                        or upgrade.candidateValue - upgrade.equippedValue
                                            > bestForItem.candidateValue - bestForItem.equippedValue) then
                                        bestForItem = upgrade
                                    end
                                end
                                if bestForItem then
                                    local equipSlot = bestForItem.equipSlot
                                    local previous = bestBySlot[equipSlot]
                                    if not previous or bestForItem.candidateValue > previous.candidateValue then
                                        bestBySlot[equipSlot] = bestForItem
                                    end
                                end
                            end
                        end
                    end
                    FinishItem()
                end)
            end
        end
    end

    FinishItem()
end

local function QueueScan()
    if scanQueued then
        return
    end

    scanQueued = true

    C_Timer.After(0.15, function()
        scanQueued = false
        ScanBags()
    end)
end

local optionsPanel = CreateFrame("Frame", "TailorOptionsPanel", UIParent)
optionsPanel.name = "Tailor"
optionsPanel:SetSize(520, 580)
local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 20, -20)
title:SetText("Tailor - Stat Weights")
local description = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
description:SetText("Weighted value = sum of each item's stats multiplied by these weights.")
local optionsDirty = false
local returnToScanFromOptions = false

for index, entry in ipairs(WEIGHTS) do
    local key, label = entry[1], entry[2]
    local slider = CreateFrame("Slider", "TailorWeightSlider" .. index,
        optionsPanel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 28, -88 - (index - 1) * 40)
    slider:SetSize(285, 17)
    slider:SetMinMaxValues(0, 1)
    slider:SetValueStep(0.01)
    slider:SetObeyStepOnDrag(true)
    local name = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    name:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 2)
    name:SetText(label)
    local number = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    number:SetPoint("LEFT", slider, "RIGHT", 18, 0)
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 100 + 0.5) / 100
        number:SetText(string.format("%.2f", value))
        if TailorDB.weights[key] ~= value then
            TailorDB.weights[key] = value
            optionsDirty = true
        end
    end)
    slider:SetValue(TailorDB.weights[key])
end

optionsPanel:SetScript("OnHide", function()
    if not optionsDirty and not returnToScanFromOptions then return end
    returnToScanFromOptions = false
    if optionsDirty then
        wipe(promptedItems)
    end
    optionsDirty = false
    wipe(upgradeQueue)
    wipe(queuedIdentities)
    if currentUpgrade then
        currentUpgrade = nil
        prompt:Hide()
    end
    QueueScan()
    ScheduleQuestRewardHighlights()
end)

local optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsPanel, "Tailor")
Settings.RegisterAddOnCategory(optionsCategory)
optionsButton:SetScript("OnClick", function()
    if currentUpgrade then
        promptedItems[currentUpgrade.identity] = nil
        currentUpgrade = nil
    end
    returnToScanFromOptions = true
    prompt:Hide()
    Settings.OpenToCategory(optionsCategory:GetID())
end)

SLASH_BAGUPGRADE1 = "/tailor"

SlashCmdList.BAGUPGRADE = function(msg)
    msg = (msg or ""):lower():trim()

    if msg == "reset" then
        wipe(promptedItems)
        wipe(upgradeQueue)
        wipe(queuedIdentities)
        currentUpgrade = nil
        Print("Prompt history reset.")
        QueueScan()
    elseif msg == "options" then
        Settings.OpenToCategory(optionsCategory:GetID())
    else
        Print("Scanning bags for weighted upgrades...")
        QueueScan()
    end
end

local rewardHooksInstalled = false
local rewardPanelHooked = false
local function InstallQuestRewardHooks()
    if not rewardHooksInstalled and QuestInfo_ShowRewards then
        hooksecurefunc("QuestInfo_ShowRewards", ScheduleQuestRewardHighlights)
        rewardHooksInstalled = true
    end
    if not rewardPanelHooked and QuestFrameRewardPanel then
        QuestFrameRewardPanel:HookScript("OnShow", ScheduleQuestRewardHighlights)
        QuestFrameRewardPanel:HookScript("OnHide", function()
            questHighlightGeneration = questHighlightGeneration + 1
            ClearQuestRewardHighlights()
        end)
        rewardPanelHooked = true
    end
end

Tailor:RegisterEvent("PLAYER_LOGIN")
Tailor:RegisterEvent("ADDON_LOADED")
Tailor:RegisterEvent("BAG_UPDATE_DELAYED")
Tailor:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
Tailor:RegisterEvent("PLAYER_REGEN_DISABLED")
Tailor:RegisterEvent("PLAYER_REGEN_ENABLED")
Tailor:RegisterEvent("QUEST_COMPLETE")
Tailor:RegisterEvent("QUEST_ITEM_UPDATE")
Tailor:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

Tailor:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_LOGIN" then
        InstallQuestRewardHooks()
        C_Timer.After(1.0, ScanBags)
    elseif event == "ADDON_LOADED" and unit == "Blizzard_UIPanels_Game" then
        InstallQuestRewardHooks()
    elseif event == "BAG_UPDATE_DELAYED" then
        QueueScan()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" and unit == "player" then
        wipe(promptedItems)
        QueueScan()
        ScheduleQuestRewardHighlights()
    elseif event == "QUEST_COMPLETE" or event == "QUEST_ITEM_UPDATE"
        or event == "PLAYER_EQUIPMENT_CHANGED" then
        ScheduleQuestRewardHighlights()
    elseif event == "PLAYER_REGEN_DISABLED" then
        if currentUpgrade then
            -- Put the interrupted prompt back before hiding it. Its identity
            -- must be eligible again when the post-combat scan finishes.
            local upgrade = currentUpgrade
            currentUpgrade = nil
            promptedItems[upgrade.identity] = nil
            queuedIdentities[upgrade.identity] = true
            table.insert(upgradeQueue, 1, upgrade)
            prompt:Hide()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        QueueScan()
    end
end)
