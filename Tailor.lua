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

local ARMOR_EQUIP_LOCS = {
    INVTYPE_HEAD = true,
    INVTYPE_SHOULDER = true,
    INVTYPE_CLOAK = true,
    INVTYPE_CHEST = true,
    INVTYPE_ROBE = true,
    INVTYPE_WRIST = true,
    INVTYPE_HAND = true,
    INVTYPE_WAIST = true,
    INVTYPE_LEGS = true,
    INVTYPE_FEET = true,
    INVTYPE_SHIELD = true,
}

local WEAPON_EQUIP_LOCS = {
    INVTYPE_WEAPON = true,
    INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Tailor|r: " .. msg)
end

local function GetItemIdentity(itemLink, itemID)
    return itemLink or ("item:" .. tostring(itemID))
end

local function GetArmorValue(itemLink)
    local stats = C_Item.GetItemStats(itemLink)
    if stats then
        return tonumber(stats.RESISTANCE0_NAME) or 0
    end
    return 0
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
    elseif equipLoc == "INVTYPE_SHIELD" then
        return {17}
    elseif equipLoc == "INVTYPE_CLOAK" then
        return {15}
    elseif equipLoc == "INVTYPE_HEAD" then
        return {1}
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
        link = actualLink or link,
        itemID = itemID,
        equipLoc = actualEquipLoc or equipLoc,
        classID = classID,
        armor = (classID == ARMOR_CLASS_ID) and GetArmorValue(actualLink or link) or 0,
        dps = (classID == WEAPON_CLASS_ID) and GetWeaponDPS(actualLink or link) or nil,
    }
end

local function MakeUpgrade(candidate, equipped, bag, bagSlot, equipSlot)
    local result

    if candidate.classID == ARMOR_CLASS_ID
        and ARMOR_EQUIP_LOCS[candidate.equipLoc]
        and C_Item.IsEquippableItem(candidate.link)
    then
        local candidateArmor = GetArmorValue(candidate.link)
        local equippedArmor = equipped and equipped.armor or 0

        if candidateArmor > equippedArmor then
            result = {
                kind = "Armor",
                candidateValue = candidateArmor,
                equippedValue = equippedArmor,
            }
        end

    elseif candidate.classID == WEAPON_CLASS_ID
        and WEAPON_EQUIP_LOCS[candidate.equipLoc]
        and C_Item.IsEquippableItem(candidate.link)
    then
        local candidateDPS = GetWeaponDPS(candidate.link)
        local equippedDPS = equipped and equipped.dps or nil

        if candidateDPS and (not equippedDPS or candidateDPS > equippedDPS) then
            result = {
                kind = "Weapon",
                candidateValue = candidateDPS,
                equippedValue = equippedDPS or 0,
            }
        end
    end

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
    local identity = GetItemIdentity(upgrade.item.link, upgrade.item.itemID) .. ":" .. upgrade.equipSlot

    if promptedItems[identity] or queuedIdentities[identity] then
        return
    end

    queuedIdentities[identity] = true
    upgrade.identity = identity
    upgradeQueue[#upgradeQueue + 1] = upgrade
end

local function ShowNextUpgrade()
    if currentUpgrade or #upgradeQueue == 0 then
        return
    end

    currentUpgrade = table.remove(upgradeQueue, 1)
    queuedIdentities[currentUpgrade.identity] = nil
    promptedItems[currentUpgrade.identity] = true

    local upgrade = currentUpgrade
    local currentName = upgrade.equipped and upgrade.equipped.name or "Nothing equipped"

    if upgrade.kind == "Armor" then
        StaticPopupDialogs["BAG_UPGRADE_FOUND"].text = string.format(
            "Bag Upgrade Found!\n\n%s\n\nArmor: %d -> %d\nCurrent: %s",
            upgrade.item.name,
            upgrade.equippedValue,
            upgrade.candidateValue,
            currentName
        )
    else
        StaticPopupDialogs["BAG_UPGRADE_FOUND"].text = string.format(
            "Bag Upgrade Found!\n\n%s\n\nDPS: %.1f -> %.1f\nCurrent: %s",
            upgrade.item.name,
            upgrade.equippedValue,
            upgrade.candidateValue,
            currentName
        )
    end

    StaticPopup_Show("BAG_UPGRADE_FOUND")
end

StaticPopupDialogs["BAG_UPGRADE_FOUND"] = {
    text = "Bag Upgrade Found!",
    button1 = "Equip",
    button2 = "Ignore",

    OnAccept = function()
        local upgrade = currentUpgrade
        currentUpgrade = nil

        if upgrade then
            C_Item.EquipItemByName(upgrade.item.link, upgrade.equipSlot)
        end

        C_Timer.After(0.1, ShowNextUpgrade)
    end,

    OnCancel = function()
        currentUpgrade = nil
        C_Timer.After(0.1, ShowNextUpgrade)
    end,

    timeout = 0,
    whileDead = false,
    hideOnEscape = true,
    preferredIndex = 3,
}

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
                        and (not itemLink or current.hyperlink == itemLink) then
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
                                -- Compare the absolute armor/DPS value for this slot.
                                if not previous or bestForItem.candidateValue > previous.candidateValue then
                                    bestBySlot[equipSlot] = bestForItem
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
    else
        Print("Scanning bags for armor and weapon upgrades...")
        QueueScan()
    end
end

Tailor:RegisterEvent("PLAYER_LOGIN")
Tailor:RegisterEvent("BAG_UPDATE_DELAYED")

Tailor:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1.0, ScanBags)
    elseif event == "BAG_UPDATE_DELAYED" then
        QueueScan()
    end
end)
