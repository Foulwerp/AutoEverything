----------------------------------------------------------------------
-- AutoUpgrade.lua
-- ============
-- AutoUpgrade module for the combined addon (WoW 3.3.5a APIs only).
-- Scans your bags for upgrades and auto-equips them based on the
-- settings in AutoUpgradeConfig.lua.
--
--   * BAG_UPDATE (coalesced with a short trailing-edge debounce) +
--     PLAYER_ENTERING_WORLD +
--     /autoupgrade scan trigger a bag scan.
--   * Each item is scored with AutoCore.GetItemScore (tooltip stat
--     parser + weights) and compared to what's equipped in its slot
--     via AutoCore.IsUpgrade. Candidate items are scored via
--     SetBagItem (bag/slot) and equipped items via SetInventoryItem
--     so Ascension scaled stats are read correctly.
--   * Hand slots are optimized as a complete set. Every legal combination
--     of eligible bag weapons/off-hands and currently equipped hand items
--     is scored, allowing one-hand + off-hand pairs to beat two-handers.
--     Only weapon subTypes listed in mainHandTypes/offHandTypes are used;
--     selecting the same family for both hands declares dual-wield capability.
--   * Unusable items (wrong class/level) get score 0 and are never
--     upgrades - they are not even evaluated.
--   * Items whose required level is ABOVE the player's current level
--     are skipped entirely and never attempted for equip - checked
--     explicitly against data.reqLevel, since ScanTooltip's "usable"
--     flag deliberately ignores "Requires Level" lines.
--   * Items that pass the minQuality / minItemLevel / reqLevel gates
--     and are upgrades are auto-equipped via AutoCore.EquipItem - but
--     ONLY if the autoEquip config is enabled. When autoEquip is false
--     (or during a /autoupgrade test), upgrades are reported without
--     equipping.
--   * Active auto-equip scans are deferred during combat and resumed after
--     PLAYER_REGEN_ENABLED. Notify-only and dry-run scans remain read-only
--     and may still evaluate/report upgrades during combat.
--   * EQUIP_BIND / AUTOEQUIP_BIND are auto-accepted only if the item's
--     quality is in autoConfirmBind. Loot-roll confirmations are scoped
--     to rolls initiated by AutoRoll. All of this is handled by
--     AutoBindClear in Core.lua.
----------------------------------------------------------------------

-- Namespace
AutoUpgrade = AutoUpgrade or {}
local AU = AutoUpgrade

-- Saved variables (per character)
AU.db = {}

-- Default settings if not present (fallback; corrected at ADDON_LOADED)
if AU.db.enabled == nil then
    AU.db.enabled = false
end
if AU.db.notifyOnly == nil then
    AU.db.notifyOnly = false
end

function AU.ApplyProfile()
    if AutoCore and AutoCore.GetProfileSection then
        AU.db = AutoCore.GetProfileSection("upgrade", true)
    end
    if AU.db.enabled == nil then AU.db.enabled = (AutoUpgradeConfig or {}).enabled == true end
    if AU.db.notifyOnly == nil then AU.db.notifyOnly = false end
end

-- Trailing-edge scheduler. Every bag update moves the due time forward,
-- so one scan runs after the burst becomes quiet instead of suppressing
-- later updates and potentially missing the final bag state.
local SCAN_DEBOUNCE = 0.3
local scanDueAt = nil
local scanDirty = false
local scanInProgress = false
local scanDeferredForCombat = false
local scanTimerFrame = CreateFrame("Frame")
local GetActiveConfig
local ScheduleScan
local AnalyzeSetCandidate
local pendingEquip = nil
local equipVerifyFrame = CreateFrame("Frame")

-- Reusable one-shot scheduler for diagnostics. WoW frames cannot be destroyed,
-- so creating a fresh timer frame for every debug command permanently grew the
-- UI object count even after its OnUpdate handler was removed.
local delayedCallbacks = {}
local delayedCallbackFrame = CreateFrame("Frame")
local function ScheduleDelayedCallback(delay, callback)
    table.insert(delayedCallbacks, { dueAt = GetTime() + delay, callback = callback })
    delayedCallbackFrame:SetScript("OnUpdate", function(self)
        local now = GetTime()
        for index = #delayedCallbacks, 1, -1 do
            local entry = delayedCallbacks[index]
            if now >= entry.dueAt then
                table.remove(delayedCallbacks, index)
                entry.callback()
            end
        end
        if #delayedCallbacks == 0 then self:SetScript("OnUpdate", nil) end
    end)
end

-- A weapon-set swap can look immediately reversible on the very next scan:
-- Ascension scores an item slightly differently while it's bagged (SetBagItem)
-- than while it's equipped (SetInventoryItem), so the item just displaced can
-- appear to "beat" the one that just replaced it. Without a cooldown this
-- flips back and forth forever. Hold off on any further hand-slot swap for a
-- few seconds after one happens so the state settles.
local WEAPON_EQUIP_SETTLE_DELAY = 5
local lastWeaponSetChangeAt = 0

local function PrintUpgradeAction(info, actionText)
    if not info or not info.printMessages then return end
    print("|cff00ff00AutoUpgrade:|r " .. info.link
        .. " | " .. string.format("%.1f", info.newScore)
        .. " vs " .. string.format("%.1f", info.equippedScore)
        .. " (|cff00ff00+" .. string.format("%.1f", info.gain) .. "|r) | "
        .. actionText .. ".")
end

local GetItemId = AutoCore.GetItemId

local function StartEquipVerification(info)
    pendingEquip = info
    info.expiresAt = GetTime() + (AutoCore.EQUIP_PENDING_TIMEOUT or 2)
    equipVerifyFrame:SetScript("OnUpdate", function(self)
        if not pendingEquip then
            self:SetScript("OnUpdate", nil)
            return
        end

        local equippedLink = GetInventoryItemLink("player", pendingEquip.targetSlotId)
        if GetItemId(equippedLink) == GetItemId(pendingEquip.link) then
            PrintUpgradeAction(pendingEquip, "equipped")
            pendingEquip = nil
            self:SetScript("OnUpdate", nil)
            ScheduleScan(SCAN_DEBOUNCE)
        elseif GetTime() >= pendingEquip.expiresAt then
            if pendingEquip.printMessages then
                print("|cffffcc00AutoUpgrade:|r Could not equip " .. pendingEquip.link
                    .. "; its bind confirmation was not completed.")
            end
            pendingEquip = nil
            self:SetScript("OnUpdate", nil)
        end
    end)
end

local function StopScanTimerIfIdle()
    if not scanDirty and not scanInProgress then
        scanDueAt = nil
        scanTimerFrame:SetScript("OnUpdate", nil)
    end
end

local function IsCombatLocked()
    return InCombatLockdown and InCombatLockdown()
end

local function IsActiveEquipScan(cfg, dryRun)
    return not dryRun and not AU.db.notifyOnly and cfg and cfg.autoEquip
end

local function DeferScanUntilCombatEnds()
    local firstDefer = not scanDeferredForCombat
    scanDeferredForCombat = true
    scanDirty = true
    scanDueAt = nil
    -- Do not leave the scheduler polling every frame throughout combat.
    -- PLAYER_REGEN_ENABLED will restart one settled, debounced scan.
    scanTimerFrame:SetScript("OnUpdate", nil)
    if firstDefer then
        AutoCore.Debug("Upgrade", "Auto-equip scan deferred until combat ends.")
    end
end

ScheduleScan = function(delay)
    scanDirty = true
    scanDueAt = GetTime() + (delay or SCAN_DEBOUNCE)
    if not scanTimerFrame:GetScript("OnUpdate") then
        scanTimerFrame:SetScript("OnUpdate", function()
            if scanInProgress or not scanDirty or not scanDueAt or GetTime() < scanDueAt then
                return
            end

            local cfg = GetActiveConfig()
            if not AU.db.enabled or not cfg or not cfg.enabled then
                scanDirty = false
                scanDeferredForCombat = false
                StopScanTimerIfIdle()
                return
            end

            if IsActiveEquipScan(cfg, false) and IsCombatLocked() then
                DeferScanUntilCombatEnds()
                return
            end

            -- Clear dirty before scanning. BAG_UPDATE events caused by an
            -- equip will set it again and schedule one final settled scan.
            scanDeferredForCombat = false
            scanDirty = false
            scanDueAt = nil
            scanInProgress = true
            AU.ScanBags(false)
            scanInProgress = false
            StopScanTimerIfIdle()
        end)
    end
end

----------------------------------------------------------------------
-- Per-character config resolution
-- AutoUpgradeConfig.lua defines global settings + a "characters"
-- table keyed by "Name-Realm" + a "default" profile. A profile may
-- override any global setting. Cached after first build.
----------------------------------------------------------------------
local activeConfig = nil
local setRecordCache = nil
local pvpSetCache = nil

GetActiveConfig = function()
    if not activeConfig then
        local config = AutoUpgradeConfig
        if not config then
            return nil
        end

        local charKey = AutoCore.GetCharKey()
        local profile = AutoCore.GetProfile(config)
        if not profile then
            profile = config.default or {}
        end

        -- Resolve each setting: profile override, else global, else default
        local function resolve(key, fallback)
            local v = profile[key]
            if v == nil then
                v = config[key]
            end
            if v == nil then
                v = fallback
            end
            return v
        end

        -- autoConfirmBind: profile list REPLACES global if provided
        local autoConfirmBind = profile.autoConfirmBind
        if autoConfirmBind == nil then
            autoConfirmBind = config.autoConfirmBind
        end
        if autoConfirmBind == nil then
            autoConfirmBind = {}
        end
        -- Build a fast lookup set
        local bindSet = {}
        for _, q in ipairs(autoConfirmBind) do
            bindSet[q] = true
        end

        local armorTypes = resolve("armorTypes", {})
        local mainHandTypes = resolve("mainHandTypes", {})
        local offHandTypes = resolve("offHandTypes", {})
        local rangedTypes = resolve("rangedTypes", {})
        activeConfig = {
            enabled          = resolve("enabled", true),
            autoEquip        = resolve("autoEquip", true),
            notifyOnly       = resolve("notifyOnly", false),
            minQuality       = tonumber(resolve("minQuality", 0)) or 0,
            minItemLevel     = tonumber(resolve("minItemLevel", nil)),
            upgradeThreshold = tonumber(resolve("upgradeThreshold", 0)) or 0,
            printMessages    = resolve("printMessages", true),
            verbose          = resolve("verbose", false),
            showTooltipScores = resolve("showTooltipScores", true),
            pvpGearToggle    = resolve("pvpGearToggle", false),
            weights          = resolve("weights", {}),
            autoConfirmBind  = bindSet,
            armorTypes       = armorTypes,
            mainHandTypes    = mainHandTypes,
            offHandTypes     = offHandTypes,
            rangedTypes      = rangedTypes,
            canOffHandWithTwoHand = AutoCore.InferCanOffHandWithTwoHand(mainHandTypes, offHandTypes),
            charKey          = charKey,
        }
    end
    return activeConfig
end

function AU.ClearConfigCache()
    activeConfig = nil
    setRecordCache = nil
    pvpSetCache = nil
end

----------------------------------------------------------------------
-- Best PvP set protection
----------------------------------------------------------------------
local PVP_SLOT_GROUPS = {
    INVTYPE_HEAD="head", INVTYPE_NECK="neck", INVTYPE_SHOULDER="shoulder",
    INVTYPE_CHEST="chest", INVTYPE_ROBE="chest", INVTYPE_WAIST="waist",
    INVTYPE_LEGS="legs", INVTYPE_FEET="feet", INVTYPE_WRIST="wrist",
    INVTYPE_HAND="hands", INVTYPE_CLOAK="back", INVTYPE_FINGER="finger",
    INVTYPE_TRINKET="trinket", INVTYPE_WEAPON="onehand",
    INVTYPE_WEAPONMAINHAND="mainhand", INVTYPE_WEAPONOFFHAND="offhand",
    INVTYPE_2HWEAPON="twohand", INVTYPE_SHIELD="offhand",
    INVTYPE_HOLDABLE="offhand", INVTYPE_RANGED="ranged",
    INVTYPE_RANGEDRIGHT="ranged", INVTYPE_THROWN="ranged",
    INVTYPE_RELIC="ranged",
}

local PVP_GROUP_CAPACITY = { finger=2, trinket=2, onehand=2 }

local function PvPLocationKey(location)
    if location and location.bag ~= nil and location.slot then
        return "bag:" .. tostring(location.bag) .. ":" .. tostring(location.slot)
    elseif location and location.invSlot then
        return "inv:" .. tostring(location.invSlot)
    end
end

local function MakePvPSetRecord(link, location, cfg)
    if not link then return nil end
    local _, _, _, iLevel, _, _, _, _, equipSlot = GetItemInfo(link)
    local group = equipSlot and PVP_SLOT_GROUPS[equipSlot]
    if not group then return nil end

    local weights = cfg and cfg.weights or {}
    local snapshot = AutoCore.GetTooltipSnapshot(link, location, weights)
    local pvp = AutoCore.GetPvPItemInfo(link, location, snapshot)
    if not pvp.isPvPGear or snapshot.usable == false then return nil end

    local score = 0
    for statName, value in pairs(snapshot.stats or {}) do
        score = score + value * (weights[statName] or 0)
    end
    return {
        link=link, location=location, locationKey=PvPLocationKey(location),
        group=group, equipSlot=equipSlot, score=score,
        pvpPower=pvp.pvpPower or 0, pvePower=pvp.pvePower or 0,
        bloodforged=pvp.bloodforged, iLevel=tonumber(iLevel) or 0,
    }
end

local function BuildPvPSetCache()
    local cfg = GetActiveConfig() or { weights={} }
    local groups, records = {}, {}
    local function Add(link, location)
        local record = MakePvPSetRecord(link, location, cfg)
        if not record then return end
        groups[record.group] = groups[record.group] or {}
        table.insert(groups[record.group], record)
        table.insert(records, record)
    end

    for invSlot = 1, 19 do
        Add(GetInventoryItemLink("player", invSlot), { invSlot=invSlot })
    end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, GetContainerNumSlots(bag) do
            local _, count, locked, _, _, _, link = GetContainerItemInfo(bag, slot)
            if link and not locked and (tonumber(count) or 0) > 0 then
                Add(link, { bag=bag, slot=slot })
            end
        end
    end

    local hasWeights = AutoCore.HasStatWeights and AutoCore.HasStatWeights(cfg.weights)
    local protected, best = {}, {}
    local function Better(a, b)
        if hasWeights and a.score ~= b.score then return a.score > b.score end
        if a.pvpPower ~= b.pvpPower then return a.pvpPower > b.pvpPower end
        if a.iLevel ~= b.iLevel then return a.iLevel > b.iLevel end
        if a.bloodforged ~= b.bloodforged then return a.bloodforged end
        local aEquipped = a.location and a.location.invSlot ~= nil
        local bEquipped = b.location and b.location.invSlot ~= nil
        if aEquipped ~= bEquipped then return aEquipped end
        return tostring(a.locationKey or a.link) < tostring(b.locationKey or b.link)
    end
    for group, candidates in pairs(groups) do
        table.sort(candidates, Better)
        local capacity = PVP_GROUP_CAPACITY[group] or 1
        for index = 1, math.min(capacity, #candidates) do
            local record = candidates[index]
            best[#best + 1] = record
            if record.locationKey then protected[record.locationKey] = true end
        end
    end
    table.sort(best, function(a, b)
        if a.group == b.group then return Better(a, b) end
        return a.group < b.group
    end)
    pvpSetCache = { protected=protected, best=best, records=records }
    return pvpSetCache
end

function AU.GetBestPvPSet()
    return (pvpSetCache or BuildPvPSetCache()).best
end

function AU.IsBestPvPSetItem(link, location)
    local key = PvPLocationKey(location)
    if not link or not key then return false end
    local cache = pvpSetCache or BuildPvPSetCache()
    return cache.protected[key] == true
end

function AU.GetMode()
    local cfg = GetActiveConfig()
    if not AU.db.enabled or not cfg or not cfg.enabled then
        return "off"
    end
    if AU.db.notifyOnly or not cfg.autoEquip then
        return "notify"
    end
    return "active"
end

-- Evaluate an arbitrary item link with the active upgrade profile. This is
-- intentionally read-only and is shared with AutoQuest reward selection.
function AU.EvaluateItem(link, location, evaluation)
    local cfg = GetActiveConfig()
    if not link or not cfg or cfg.enabled == false
        or not AutoCore.HasStatWeights(cfg.weights)
    then
        return false, 0, 0, nil, "upgrade scoring is not configured"
    end

    local snapshot = evaluation and evaluation.tooltipSnapshot
    local itemScore = evaluation and evaluation.itemScore

    -- PvP gear toggle: respect the user's setting for whether to allow equipping PvP gear.
    snapshot = snapshot or AutoCore.GetTooltipSnapshot(link, location, cfg.weights)
    local pvpInfo = AutoCore.GetPvPItemInfo(link, location, snapshot)
    if pvpInfo.isPvPGear then
        local score = itemScore or AutoCore.GetItemScore(link, cfg.weights, location) or 0
        if not cfg.pvpGearToggle then
            return false, score, 0, nil, "PvP gear is excluded from auto-equip (toggle disabled)"
        end
    end

    local data = AutoCore.GetItemData(link, location, snapshot)
    if not data or not data.equipSlot or data.equipSlot == "" then
        return false, 0, 0, nil, "item is not equippable"
    end
    if data.quality and data.quality < cfg.minQuality then
        return false, 0, 0, nil, "item is below minQuality"
    end
    if cfg.minItemLevel and (not data.iLevel or data.iLevel < cfg.minItemLevel) then
        return false, 0, 0, nil, "item is below minItemLevel"
    end
    if data.reqLevel and data.reqLevel > UnitLevel("player") then
        return false, 0, 0, nil, "required level is too high"
    end

    local usable
    if snapshot then
        usable = snapshot.usable
    else
        _, usable = AutoCore.ScanTooltip(link, nil, location)
    end
    local debugInfo = {}
    local isUpgrade, newScore, equippedScore, _, targetSlotId = AutoCore.IsUpgrade(
        link, cfg.weights, cfg.upgradeThreshold, nil,
        {
            armorTypes = cfg.armorTypes,
            mainHandTypes = cfg.mainHandTypes,
            offHandTypes = cfg.offHandTypes,
            rangedTypes = cfg.rangedTypes,
            canOffHandWithTwoHand = cfg.canOffHandWithTwoHand,
            usable = usable,
            itemScore = itemScore,
            -- Preserve the complete source location so GetItemScore can use
            -- the same authoritative tooltip setter that produced the item.
            location = location,
            -- Legacy fields remain for callers that invoke Core.IsUpgrade.
            bag = location and location.bag,
            slot = location and location.slot,
            rollID = location and location.rollID,
            questType = location and location.questType,
            questIndex = location and location.questIndex,
        },
        debugInfo
    )
    return isUpgrade, newScore, equippedScore, targetSlotId, debugInfo.reason, nil, debugInfo
end

----------------------------------------------------------------------
-- Item tooltip scores
-- Uses active profile weights and real item locations for scaled stats.
-- Named setters preserve Ascension's scaled-item context. OnTooltipSetItem is
-- a next-frame fallback for uncommon UI paths and tooltip addons which bypass
-- or replace those setters; the named hook always gets first chance.
----------------------------------------------------------------------
local TOOLTIP_SLOT_LABELS = {
    [11] = "Ring 1", [12] = "Ring 2",
    [13] = "Trinket 1", [14] = "Trinket 2",
    [16] = "Main Hand", [17] = "Off Hand",
}

local function TooltipCompareSlot(targetSlotId, comparisonInfo)
    if comparisonInfo and comparisonInfo.combinedComparison then
        return "Main + Off Hand"
    end
    return TOOLTIP_SLOT_LABELS[targetSlotId] or "Equipped Item"
end

local function AddComparisonBreakdown(tooltip, comparisonInfo)
    local rows = comparisonInfo and comparisonInfo.comparisons
    if not rows or #rows < 2 then return end
    for _, row in ipairs(rows) do
        local label = TOOLTIP_SLOT_LABELS[row.slot] or "Equipped Item"
        local value = string.format("%.1f", row.score or 0)
        if not comparisonInfo.combinedComparison and row.slot == comparisonInfo.targetSlotId then
            value = value .. "  (replace)"
            tooltip:AddDoubleLine("Equipped " .. label, value, 0.7, 0.7, 0.7, 1, 0.82, 0.2)
        else
            if not comparisonInfo.combinedComparison then value = value .. "  (keep)" end
            tooltip:AddDoubleLine("Equipped " .. label, value, 0.7, 0.7, 0.7, 1, 1, 1)
        end
    end
end

local function AddUpgradeTooltipLines(tooltip, link, location)
    local cfg = GetActiveConfig()
    if not tooltip or not link or not cfg or cfg.showTooltipScores == false
        or not cfg.weights or not next(cfg.weights)
    then return end

    local _, _, _, _, _, _, _, _, equipSlot = GetItemInfo(link)
    if not equipSlot or equipSlot == "" then return end

    -- Several tooltip setters call another item setter internally. Append the
    -- block only once per tooltip fill, and cancel its generic fallback once a
    -- location-aware hook has handled the item.
    if tooltip.__autoUpgradeScoredLink == link then
        tooltip.__autoUpgradePendingLink = nil
        return
    end
    tooltip.__autoUpgradeScoredLink = link
    tooltip.__autoUpgradePendingLink = nil

    local snapshot = AutoCore.GetTooltipSnapshot(link, location, cfg.weights)
    local score = 0
    for statName, value in pairs(snapshot.stats) do
        score = score + value * (cfg.weights[statName] or 0)
    end
    tooltip:AddDoubleLine("AutoUpgrade Score", string.format("%.1f", score), 0.35, 0.85, 1, 1, 1, 1)

    do
        local isUpgrade, newScore, equippedScore, targetSlotId, _, _, comparisonInfo = AU.EvaluateItem(
            link, location, { tooltipSnapshot = snapshot, itemScore = score })
        if targetSlotId and not (location and location.invSlot) then
            AddComparisonBreakdown(tooltip, comparisonInfo)
            local compareLabel = TooltipCompareSlot(targetSlotId, comparisonInfo)
            tooltip:AddDoubleLine("Compared Against " .. compareLabel, string.format("%.1f", equippedScore),
                0.7, 0.7, 0.7, 1, 1, 1)
            local gain = newScore - equippedScore
            local valueText = equippedScore > 0
                and string.format("%+.1f (%+.1f%%)", gain, gain / equippedScore * 100)
                or string.format("%+.1f (empty slot)", gain)
            if isUpgrade then
                tooltip:AddDoubleLine("Upgrade", valueText, 0.35, 1, 0.35, 0.35, 1, 0.35)
            elseif gain > 0 then
                tooltip:AddDoubleLine("Better, Below Threshold", valueText, 1, 0.82, 0.2, 1, 0.82, 0.2)
            elseif gain < 0 then
                tooltip:AddDoubleLine("Downgrade", valueText, 1, 0.3, 0.3, 1, 0.3, 0.3)
            else
                tooltip:AddDoubleLine("No Change", valueText, 0.75, 0.75, 0.75, 1, 1, 1)
            end
        end
    end

    tooltip:Show()
end

local function HookItemTooltip(tooltip)
    if not tooltip or tooltip.__autoUpgradeTooltipHooked then return end
    tooltip.__autoUpgradeTooltipHooked = true

    if tooltip.HookScript then
        tooltip:HookScript("OnTooltipCleared", function(self)
            self.__autoUpgradeScoredLink = nil
            self.__autoUpgradePendingLink = nil
        end)
        tooltip:HookScript("OnTooltipSetItem", function(self)
            local _, link = self:GetItem()
            self.__autoUpgradePendingLink = link
        end)
        tooltip:HookScript("OnUpdate", function(self)
            local link = self.__autoUpgradePendingLink
            if not link then return end
            self.__autoUpgradePendingLink = nil
            AddUpgradeTooltipLines(self, link, nil)
        end)
    end

    if tooltip.SetBagItem then hooksecurefunc(tooltip, "SetBagItem", function(self, bag, slot)
        AddUpgradeTooltipLines(self, GetContainerItemLink(bag, slot), { bag = bag, slot = slot }) end) end
    if tooltip.SetInventoryItem then hooksecurefunc(tooltip, "SetInventoryItem", function(self, unit, invSlot)
        if unit == "player" then AddUpgradeTooltipLines(self, GetInventoryItemLink(unit, invSlot), { invSlot = invSlot }) end end) end
    if tooltip.SetLootRollItem then hooksecurefunc(tooltip, "SetLootRollItem", function(self, rollID)
        AddUpgradeTooltipLines(self, GetLootRollItemLink and GetLootRollItemLink(rollID), { rollID = rollID }) end) end
    if tooltip.SetQuestItem then hooksecurefunc(tooltip, "SetQuestItem", function(self, questType, questIndex)
        AddUpgradeTooltipLines(self, GetQuestItemLink(questType, questIndex), { questType = questType, questIndex = questIndex }) end) end
    if tooltip.SetQuestLogItem then hooksecurefunc(tooltip, "SetQuestLogItem", function(self, itemType, questIndex)
        AddUpgradeTooltipLines(self, GetQuestLogItemLink(itemType, questIndex),
            { questLogItemType = itemType, questLogIndex = questIndex }) end) end
    if tooltip.SetMerchantItem then hooksecurefunc(tooltip, "SetMerchantItem", function(self, merchantIndex)
        AddUpgradeTooltipLines(self, GetMerchantItemLink(merchantIndex), { merchantIndex = merchantIndex }) end) end
    if tooltip.SetMerchantCostItem then hooksecurefunc(tooltip, "SetMerchantCostItem", function(self)
        local _, link = self:GetItem()
        AddUpgradeTooltipLines(self, link, nil) end) end
    if tooltip.SetBuybackItem then hooksecurefunc(tooltip, "SetBuybackItem", function(self, buybackIndex)
        local _, link = self:GetItem()
        AddUpgradeTooltipLines(self, link, { buybackIndex = buybackIndex }) end) end
    if tooltip.SetInboxItem then hooksecurefunc(tooltip, "SetInboxItem", function(self, inboxIndex, attachmentIndex)
        local _, link = self:GetItem()
        AddUpgradeTooltipLines(self, link, { inboxIndex = inboxIndex, attachmentIndex = attachmentIndex }) end) end
    if tooltip.SetSendMailItem then hooksecurefunc(tooltip, "SetSendMailItem", function(self, sendMailIndex)
        local _, link = self:GetItem()
        AddUpgradeTooltipLines(self, link, { sendMailIndex = sendMailIndex }) end) end
    if tooltip.SetTradePlayerItem then hooksecurefunc(tooltip, "SetTradePlayerItem", function(self, tradePlayerIndex)
        local _, link = self:GetItem()
        AddUpgradeTooltipLines(self, link, { tradePlayerIndex = tradePlayerIndex }) end) end
    if tooltip.SetTradeTargetItem then hooksecurefunc(tooltip, "SetTradeTargetItem", function(self, tradeTargetIndex)
        local _, link = self:GetItem()
        AddUpgradeTooltipLines(self, link, { tradeTargetIndex = tradeTargetIndex }) end) end
    if tooltip.SetAuctionItem then hooksecurefunc(tooltip, "SetAuctionItem", function(self, auctionType, auctionIndex)
        AddUpgradeTooltipLines(self, GetAuctionItemLink(auctionType, auctionIndex),
            { auctionType = auctionType, auctionIndex = auctionIndex }) end) end
    if tooltip.SetLootItem then hooksecurefunc(tooltip, "SetLootItem", function(self, lootSlot)
        AddUpgradeTooltipLines(self, GetLootSlotLink(lootSlot), { lootSlot = lootSlot }) end) end
    if tooltip.SetTradeSkillItem then hooksecurefunc(tooltip, "SetTradeSkillItem", function(self, skillIndex)
        AddUpgradeTooltipLines(self, GetTradeSkillItemLink and GetTradeSkillItemLink(skillIndex),
            { tradeSkillIndex = skillIndex }) end) end
    if tooltip.SetTradeSkillReagent then hooksecurefunc(tooltip, "SetTradeSkillReagent", function(self, skillIndex, reagentIndex)
        AddUpgradeTooltipLines(self, GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(skillIndex, reagentIndex),
            { tradeSkillIndex = skillIndex, reagentIndex = reagentIndex }) end) end
    if tooltip.SetCraftItem then hooksecurefunc(tooltip, "SetCraftItem", function(self, craftIndex)
        AddUpgradeTooltipLines(self, GetCraftItemLink and GetCraftItemLink(craftIndex),
            { craftIndex = craftIndex }) end) end
    if tooltip.SetCraftReagent then hooksecurefunc(tooltip, "SetCraftReagent", function(self, craftIndex, reagentIndex)
        AddUpgradeTooltipLines(self, GetCraftReagentItemLink and GetCraftReagentItemLink(craftIndex, reagentIndex),
            { craftIndex = craftIndex, reagentIndex = reagentIndex }) end) end
    if tooltip.SetGuildBankItem then hooksecurefunc(tooltip, "SetGuildBankItem", function(self, tab, slot)
        AddUpgradeTooltipLines(self, GetGuildBankItemLink and GetGuildBankItemLink(tab, slot),
            { guildBankTab = tab, guildBankSlot = slot }) end) end
    if tooltip.SetAuctionSellItem then hooksecurefunc(tooltip, "SetAuctionSellItem", function(self)
        local _, link = self:GetItem()
        AddUpgradeTooltipLines(self, link, { auctionSellItem = true }) end) end
    if tooltip.SetHyperlinkCompareItem then hooksecurefunc(tooltip, "SetHyperlinkCompareItem", function(self)
        -- The method argument is the hovered candidate used to build the
        -- comparison, not the equipped item displayed in this panel.
        local _, displayedLink = self:GetItem()
        local location
        for invSlot = 1, 19 do
            if displayedLink and GetInventoryItemLink("player", invSlot) == displayedLink then
                location = { invSlot = invSlot }
                break
            end
        end
        AddUpgradeTooltipLines(self, displayedLink, location) end) end
    if tooltip.SetHyperlink then hooksecurefunc(tooltip, "SetHyperlink", function(self, link)
        AddUpgradeTooltipLines(self, link, nil) end) end
end

local function HookUpgradeTooltips()
    HookItemTooltip(GameTooltip)
    HookItemTooltip(ItemRefTooltip)
    HookItemTooltip(ShoppingTooltip1)
    HookItemTooltip(ShoppingTooltip2)
    HookItemTooltip(ShoppingTooltip3)
    HookItemTooltip(ItemRefShoppingTooltip1)
    HookItemTooltip(ItemRefShoppingTooltip2)
    HookItemTooltip(ItemRefShoppingTooltip3)
end

HookUpgradeTooltips()

-- GameTooltip has Blizzard's comparison OnUpdate handler, but ItemRefTooltip
-- does not on this client.  Item links from chat and other hyperlink sources
-- are displayed in ItemRefTooltip, so give it the same modifier/CVar-driven
-- equipped-item comparison behavior as ordinary hovered item tooltips.
local function HideTooltipComparisons(tooltip)
    if not tooltip or not tooltip.shoppingTooltips then return end
    for _, frame in pairs(tooltip.shoppingTooltips) do
        if frame then frame:Hide() end
    end
end

local function EnableLinkTooltipComparison(tooltip)
    if not tooltip or not tooltip.HookScript or tooltip.__autoUpgradeLinkCompareHooked then return end
    tooltip.__autoUpgradeLinkCompareHooked = true

    tooltip:HookScript("OnUpdate", function(self, elapsed)
        self.__autoUpgradeLinkCompareElapsed = (self.__autoUpgradeLinkCompareElapsed or 0) + elapsed
        if self.__autoUpgradeLinkCompareElapsed < 0.05 then return end
        self.__autoUpgradeLinkCompareElapsed = 0

        local link
        if self.GetItem then
            link = select(2, self:GetItem())
        end
        local compareItems = IsModifiedClick and IsModifiedClick("COMPAREITEMS")
        if not compareItems and GetCVarBool then
            compareItems = GetCVarBool("alwaysCompareItems")
        end

        if link and compareItems then
            if self.__autoUpgradeLinkComparing ~= link and GameTooltip_ShowCompareItem then
                HideTooltipComparisons(self)
                GameTooltip_ShowCompareItem(self)
                self.__autoUpgradeLinkComparing = link
            end
        elseif self.__autoUpgradeLinkComparing then
            HideTooltipComparisons(self)
            self.__autoUpgradeLinkComparing = nil
        end
    end)
    tooltip:HookScript("OnHide", function(self)
        HideTooltipComparisons(self)
        self.__autoUpgradeLinkComparing = nil
        self.__autoUpgradeLinkCompareElapsed = 0
    end)
end

EnableLinkTooltipComparison(ItemRefTooltip)

-- ElvUI 7.27 uses GameTooltip.comparing for its Shift-to-compare handler.
-- Blizzard uses that same field for always-compare, so ElvUI hides Blizzard's
-- panel every 0.2 seconds. Install the fix at runtime rather than changing
-- ElvUI's files, which Ascension's launcher verifies and restores.
local function FixElvUIAlwaysCompareFlicker()
    local engine = _G.ElvUI and _G.ElvUI[1]
    if not engine or not engine.GetModule then return end
    local ok, actionBars = pcall(engine.GetModule, engine, "ActionBars")
    if not ok or not actionBars then return end

    if not actionBars.__autoEverythingCompareFix then
        actionBars.Tooltip_OnUpdate = function(_, tooltip, elapsed)
            tooltip.__autoEverythingCompareElapsed = (tooltip.__autoEverythingCompareElapsed or 0) + elapsed
            if tooltip.__autoEverythingCompareElapsed < 0.2 then return end
            tooltip.__autoEverythingCompareElapsed = 0

            local compareItems = IsModifiedClick and IsModifiedClick("COMPAREITEMS")
            if not tooltip.elvuiModifierComparing and compareItems and tooltip:GetItem() then
                GameTooltip_ShowCompareItem(tooltip)
                tooltip.elvuiModifierComparing = true
            elseif tooltip.elvuiModifierComparing and not compareItems then
                for _, frame in pairs(tooltip.shoppingTooltips or {}) do frame:Hide() end
                tooltip.elvuiModifierComparing = false
            end
        end
        actionBars.__autoEverythingCompareFix = true
    end

    -- AceHook may have captured ElvUI's original method before AutoEverything
    -- loaded. Reinstall only this script hook so it calls the replacement.
    if actionBars.IsHooked and actionBars.Unhook and actionBars.HookScript
        and actionBars:IsHooked(GameTooltip, "OnUpdate")
    then
        actionBars:Unhook(GameTooltip, "OnUpdate")
        actionBars:HookScript(GameTooltip, "OnUpdate", "Tooltip_OnUpdate")
    end
end
FixElvUIAlwaysCompareFlicker()

local elvUIFixFrame = CreateFrame("Frame")
elvUIFixFrame:RegisterEvent("PLAYER_LOGIN")
elvUIFixFrame:SetScript("OnEvent", function(self)
    -- Comparison frames and tooltip replacements supplied by other addons are
    -- guaranteed to exist by login.
    HookUpgradeTooltips()
    EnableLinkTooltipComparison(ItemRefTooltip)
    FixElvUIAlwaysCompareFlicker()
    self:UnregisterEvent("PLAYER_LOGIN")
end)
----------------------------------------------------------------------
-- Helper: Is a quality in the autoConfirmBind set?
----------------------------------------------------------------------
local function ShouldAutoConfirmBind(quality)
    local cfg = GetActiveConfig()
    if not cfg then return false end
    return cfg.autoConfirmBind[quality] == true
end

----------------------------------------------------------------------
-- Weapon-set optimization
-- Evaluating hand items independently misses upgrades where neither a
-- one-hander nor an off-hand beats a staff by itself, but their combined
-- score does. Build every legal set from eligible bag items plus the items
-- already equipped in their current slots, then compare complete sets. This
-- owned-set analysis is retained for weapon-bench protection and explicit
-- callers; actual upgrade decisions compare the item with what it replaces.
----------------------------------------------------------------------
local TypeInList = AutoCore.TypeInList

local function IsOptimizedHandSlot(equipSlot)
    return equipSlot == "INVTYPE_WEAPON"
        or equipSlot == "INVTYPE_WEAPONMAINHAND"
        or equipSlot == "INVTYPE_WEAPONOFFHAND"
        or equipSlot == "INVTYPE_2HWEAPON"
        or equipSlot == "INVTYPE_SHIELD"
        or equipSlot == "INVTYPE_HOLDABLE"
end

-- Single source of truth for "which hand-slot role(s) can this equipSlot/
-- subType combination fill" - {main=true, off=true} either/both/neither.
-- Shared by weapon-set candidate collection,
-- and exposed publicly so AutoRoll can classify a loot-roll item the same
-- way without duplicating this mapping.
local function HandSlotKindsFor(equipSlot, subType, cfg)
    local kinds = {}
    if equipSlot == "INVTYPE_2HWEAPON" then
        if TypeInList(subType, cfg.mainHandTypes) then kinds.main = true end
        if cfg.canOffHandWithTwoHand and TypeInList(subType, cfg.offHandTypes) then kinds.off = true end
    elseif equipSlot == "INVTYPE_WEAPON" then
        if TypeInList(subType, cfg.mainHandTypes) then kinds.main = true end
        if TypeInList(subType, cfg.offHandTypes) then kinds.off = true end
    elseif equipSlot == "INVTYPE_WEAPONMAINHAND" then
        if TypeInList(subType, cfg.mainHandTypes) then kinds.main = true end
    elseif equipSlot == "INVTYPE_WEAPONOFFHAND" then
        if TypeInList(subType, cfg.offHandTypes) then kinds.off = true end
    elseif equipSlot == "INVTYPE_SHIELD" then
        if TypeInList("Shields", cfg.offHandTypes) then kinds.off = true end
    elseif equipSlot == "INVTYPE_HOLDABLE" then
        if TypeInList("Held In Off-hand", cfg.offHandTypes) then kinds.off = true end
    end
    return kinds
end

local function AddWeaponSetCandidate(record, mainCandidates, offCandidates, cfg)
    local kinds = HandSlotKindsFor(record.equipSlot, record.subType, cfg)
    if kinds.main then
        record.canMain = true
        table.insert(mainCandidates, record)
    end
    if kinds.off then
        record.canOff = true
        table.insert(offCandidates, record)
    end
end

local function SameBagItem(a, b)
    return a and b and a.bag ~= nil and b.bag ~= nil
        and a.bag == b.bag and a.slot == b.slot
end

local function IsCurrentSlot(record, invSlot)
    return record and record.invSlot == invSlot
end

local function SameRecord(a, b)
    if not a or not b then return false end
    if a == b then return true end
    if a.invSlot and b.invSlot then return a.invSlot == b.invSlot end
    if a.bag ~= nil and b.bag ~= nil then return SameBagItem(a, b) end
    return a.isVirtual and b.isVirtual and a.isVirtual == b.isVirtual
end

local function MakeSetRecord(link, location, cfg, evaluation)
    if not link then return nil end
    local _, _, _, _, _, _, _, _, equipSlot = GetItemInfo(link)
    if not equipSlot or equipSlot == "" then return nil end
    local snapshot = evaluation and evaluation.tooltipSnapshot
        or AutoCore.GetTooltipSnapshot(link, location, cfg.weights)
    -- Only exclude PvP items while they are candidates in bags. If one is
    -- already equipped, keep it in the current-set score
    -- so comparisons remain accurate and AutoUpgrade can still replace it.
    if location and location.bag ~= nil
        and AutoCore.GetPvPItemInfo(link, location, snapshot).isPvPGear
    then
        if not cfg.pvpGearToggle then return nil end
    end
    local data = AutoCore.GetItemData(link, location, snapshot)
    if not data or not data.equipSlot or data.equipSlot == "" then return nil end
    if data.quality and data.quality < cfg.minQuality then return nil end
    if cfg.minItemLevel and (not data.iLevel or data.iLevel < cfg.minItemLevel) then return nil end
    if data.reqLevel and data.reqLevel > UnitLevel("player") then return nil end
    if snapshot.usable == false then return nil end
    local score = evaluation and evaluation.itemScore
    if type(score) ~= "number" then
        score = 0
        for statName, value in pairs(snapshot.stats) do
            score = score + value * (cfg.weights[statName] or 0)
        end
    end
    return {
        link = link,
        equipSlot = data.equipSlot,
        subType = data.subType,
        score = score,
        bag = location and location.bag,
        slot = location and location.slot,
        invSlot = location and location.invSlot,
        isVirtual = location and location.questIndex
            and (tostring(location.questType or "quest") .. ":" .. tostring(location.questIndex)) or nil,
    }
end

local function CollectSetRecords(cfg, extra)
    if not setRecordCache or setRecordCache.cfg ~= cfg then
        local cachedRecords = {}
        for invSlot = 11, 17 do
            if invSlot <= 14 or invSlot >= 16 then
                local link = GetInventoryItemLink("player", invSlot)
                local record = MakeSetRecord(link, { invSlot = invSlot }, cfg)
                if record then table.insert(cachedRecords, record) end
            end
        end
        for bag = 0, 4 do
            for slot = 1, GetContainerNumSlots(bag) do
                local _, count, locked, quality, _, _, link = GetContainerItemInfo(bag, slot)
                if link and not locked and count and count > 0 then
                    local record = MakeSetRecord(link, { bag = bag, slot = slot }, cfg)
                    if record then table.insert(cachedRecords, record) end
                end
            end
        end
        setRecordCache = { cfg = cfg, records = cachedRecords }
    end
    local records = {}
    for _, record in ipairs(setRecordCache.records) do table.insert(records, record) end
    if extra then
        local found = false
        for _, record in ipairs(records) do
            if SameRecord(record, extra) then found = true; break end
        end
        if not found then table.insert(records, extra) end
    end
    return records
end

local function AnalyzeRingCandidate(candidate, records, cfg)
    local currentA, currentB
    local rings = {}
    for _, record in ipairs(records) do
        if record.equipSlot == "INVTYPE_FINGER" then
            table.insert(rings, record)
            if record.invSlot == 11 then currentA = record end
            if record.invSlot == 12 then currentB = record end
        end
    end
    local currentScore = (currentA and currentA.score or 0) + (currentB and currentB.score or 0)
    local best, bestEquipped
    local function Consider(partner)
        if SameRecord(candidate, partner) then return end
        local set = { first = candidate, second = partner, score = candidate.score + (partner and partner.score or 0) }
        if not best or set.score > best.score then best = set end
        if (not partner or partner.invSlot) and (not bestEquipped or set.score > bestEquipped.score) then
            bestEquipped = set
        end
    end
    Consider(nil)
    for _, ring in ipairs(rings) do Consider(ring) end
    local bestScore = best and best.score or candidate.score
    local thresholdScore = currentScore * (1 + cfg.upgradeThreshold / 100)
    local targetSlotId = 11
    if candidate.invSlot then
        targetSlotId = candidate.invSlot
    elseif best and best.second and best.second.invSlot == 11 then
        targetSlotId = 12
    elseif best and best.second and best.second.invSlot == 12 then
        targetSlotId = 11
    elseif (currentA and currentA.score or 0) > (currentB and currentB.score or 0) then
        targetSlotId = 12
    end
    return {
        kind = "ring", itemScore = candidate.score, currentScore = currentScore,
        currentSet = { first = currentA, second = currentB, score = currentScore },
        equippedSet = bestEquipped, equippedPartner = bestEquipped and bestEquipped.second,
        bestSet = best, bestPartner = best and best.second, bestScore = bestScore,
        isUpgrade = bestScore > currentScore and bestScore >= thresholdScore,
        gain = bestScore - currentScore, targetSlotId = targetSlotId,
        reason = "best ring pair " .. string.format("%.2f", bestScore)
            .. " vs current pair " .. string.format("%.2f", currentScore),
    }
end

local function AnalyzeWeaponCandidate(candidate, records, cfg)
    local mains, offs = {}, {}
    local currentMain, currentOff
    for _, record in ipairs(records) do
        if IsOptimizedHandSlot(record.equipSlot) then
            AddWeaponSetCandidate(record, mains, offs, cfg)
            if record.invSlot == 16 then currentMain = record end
            if record.invSlot == 17 then currentOff = record end
        end
    end
    local currentScore = (currentMain and currentMain.score or 0)
    if not (currentMain and currentMain.equipSlot == "INVTYPE_2HWEAPON" and not cfg.canOffHandWithTwoHand) then
        currentScore = currentScore + (currentOff and currentOff.score or 0)
    end

    local best, bestEquipped
    local function Consider(main, off)
        if not main or SameRecord(main, off) then return end
        if not SameRecord(main, candidate) and not SameRecord(off, candidate) then return end
        if main.equipSlot == "INVTYPE_2HWEAPON" and off and not cfg.canOffHandWithTwoHand then return end
        local set = { main = main, off = off, score = main.score + (off and off.score or 0) }
        if not best or set.score > best.score then best = set end
        local partner = SameRecord(main, candidate) and off or main
        if (not partner or partner.invSlot) and (not bestEquipped or set.score > bestEquipped.score) then
            bestEquipped = set
        end
    end
    for _, main in ipairs(mains) do
        Consider(main, nil)
        for _, off in ipairs(offs) do Consider(main, off) end
    end
    if not best then return nil end
    local function PartnerIn(set)
        if not set then return nil end
        if SameRecord(set.main, candidate) then return set.off end
        if SameRecord(set.off, candidate) then return set.main end
        return nil
    end
    local thresholdScore = currentScore * (1 + cfg.upgradeThreshold / 100)
    return {
        kind = "weapon", itemScore = candidate.score, currentScore = currentScore,
        currentSet = { main = currentMain, off = currentOff, score = currentScore },
        equippedSet = bestEquipped, equippedPartner = PartnerIn(bestEquipped),
        bestSet = best, bestPartner = PartnerIn(best), bestScore = best.score,
        isUpgrade = best.score > currentScore and best.score >= thresholdScore,
        gain = best.score - currentScore,
        targetSlotId = SameRecord(best.main, candidate) and 16 or 17,
        reason = "best weapon set " .. string.format("%.2f", best.score)
            .. " vs current set " .. string.format("%.2f", currentScore),
    }
end

AnalyzeSetCandidate = function(link, location, cfg, evaluation)
    cfg = cfg or GetActiveConfig()
    if not cfg then return nil end
    local candidate = MakeSetRecord(link, location, cfg, evaluation)
    if not candidate then return nil end
    local isRing = candidate.equipSlot == "INVTYPE_FINGER"
    local isWeapon = IsOptimizedHandSlot(candidate.equipSlot)
    if not isRing and not isWeapon then return nil end
    local records = CollectSetRecords(cfg, candidate)
    if isRing then return AnalyzeRingCandidate(candidate, records, cfg) end
    return AnalyzeWeaponCandidate(candidate, records, cfg)
end

function AU.AnalyzeItemSet(link, location)
    return AnalyzeSetCandidate(link, location, GetActiveConfig())
end

-- AutoSell uses this small weapon bench to avoid deleting the first half of
-- a future one-hand/off-hand set merely because a two-hander currently wins.
function AU.IsWeaponBenchItem(link, location)
    local cfg = GetActiveConfig()
    if not cfg or cfg.enabled == false or not link then return false end
    local data = AutoCore.GetItemData(link, location)
    if not data or not IsOptimizedHandSlot(data.equipSlot) then return false end
    local candidate = MakeSetRecord(link, location, cfg)
    if not candidate then return false end
    local records = CollectSetRecords(cfg, candidate)
    local mains, offs, flex, twoHands = {}, {}, {}, {}
    for _, record in ipairs(records) do
        if IsOptimizedHandSlot(record.equipSlot) then
            local recordMains, recordOffs = {}, {}
            AddWeaponSetCandidate(record, recordMains, recordOffs, cfg)
            if not record.invSlot then
                if #recordMains > 0 and record.equipSlot ~= "INVTYPE_2HWEAPON" then table.insert(mains, record) end
                if #recordOffs > 0 then table.insert(offs, record) end
                if record.equipSlot == "INVTYPE_WEAPON" and record.canMain and record.canOff then
                    table.insert(flex, record)
                end
                if record.equipSlot == "INVTYPE_2HWEAPON" then table.insert(twoHands, record) end
            end
        end
    end
    local function SortScore(list)
        table.sort(list, function(a, b)
            if a.score == b.score then return tostring(a.link) < tostring(b.link) end
            return a.score > b.score
        end)
    end
    SortScore(mains); SortScore(offs); SortScore(flex); SortScore(twoHands)
    local protected = { mains[1], offs[1], flex[1], flex[2], twoHands[1] }
    for _, record in ipairs(protected) do
        if SameRecord(record, candidate) then return true end
    end
    local analysis = AnalyzeWeaponCandidate(candidate, records, cfg)
    return analysis and analysis.isUpgrade or false
end

local function DescribeWeaponSet(set)
    local mainText = set.main and set.main.link or "empty main hand"
    local offText = set.off and set.off.link or "empty off hand"
    return mainText .. " + " .. offText
end

-- Reads the two hand slots currently equipped. Called once per scan, before
-- the single bag pass in AU.ScanBags collects bag-side hand-slot candidates.
local function BuildEquippedHandRecords(cfg)
    local function MakeEquippedRecord(invSlot)
        local link = GetInventoryItemLink("player", invSlot)
        if not link then return nil end
        local data = AutoCore.GetItemData(link, { invSlot = invSlot })
        if not data or not IsOptimizedHandSlot(data.equipSlot) then return nil end
        return {
            link = link,
            equipSlot = data.equipSlot,
            subType = data.subType,
            score = AutoCore.GetItemScore(link, cfg.weights, { invSlot = invSlot }),
            invSlot = invSlot,
        }
    end
    return MakeEquippedRecord(16), MakeEquippedRecord(17)
end

-- Given the equipped hand records and the bag-side candidates already
-- collected by AU.ScanBags's single bag pass, pick and (optionally) equip the
-- best weapon set. Kept separate from candidate collection so ScanBags does
-- not need a second full bag sweep just to build these candidate lists.
local function FinalizeWeaponSet(cfg, actualDryRun, mainCandidates, offCandidates, currentMain, currentOff)
    -- Give a swap time to settle before proposing another one (see
    -- WEAPON_EQUIP_SETTLE_DELAY above) - skip evaluation entirely rather than
    -- just skipping the equip, so a dry-run/notify pass doesn't nag about an
    -- "upgrade" that's really just settle-delay jitter.
    if not actualDryRun and GetTime() - lastWeaponSetChangeAt < WEAPON_EQUIP_SETTLE_DELAY then
        return false
    end

    local currentScore = (currentMain and currentMain.score or 0) + (currentOff and currentOff.score or 0)
    local bestSet = { main = currentMain, off = currentOff, score = currentScore }

    local function ConsiderSet(main, off)
        if not main or SameBagItem(main, off) then return end
        local mainIsTwoHanded = main.equipSlot == "INVTYPE_2HWEAPON"
        if mainIsTwoHanded and off and not cfg.canOffHandWithTwoHand then return end
        local score = main.score + (off and off.score or 0)
        if score > bestSet.score then
            bestSet = { main = main, off = off, score = score }
        end
    end

    for _, main in ipairs(mainCandidates) do
        ConsiderSet(main, nil)
        for _, off in ipairs(offCandidates) do
            ConsiderSet(main, off)
        end
    end

    local thresholdScore = currentScore * (1 + cfg.upgradeThreshold / 100)
    if bestSet.score <= currentScore or bestSet.score < thresholdScore then
        return false
    end

    local gain = bestSet.score - currentScore
    if cfg.printMessages then
        print("|cff00ff00AutoUpgrade:|r Best weapon set: " .. DescribeWeaponSet(bestSet)
            .. " | " .. string.format("%.1f", bestSet.score)
            .. " vs " .. string.format("%.1f", currentScore)
            .. " (|cff00ff00+" .. string.format("%.1f", gain) .. "|r) | "
            .. (actualDryRun and "would equip." or "selected."))
    end
    if actualDryRun then return false, true end

    -- Equip the main hand first. Re-scanning after each operation safely
    -- handles a staff becoming a one-hander, displaced items moving to bags,
    -- and bind confirmations before the off-hand is equipped.
    local desired = nil
    local targetSlotId = nil
    if not IsCurrentSlot(bestSet.main, 16) then
        desired = bestSet.main
        targetSlotId = 16
    elseif bestSet.off and not IsCurrentSlot(bestSet.off, 17) then
        desired = bestSet.off
        targetSlotId = 17
    end
    if not desired or desired.bag == nil then return false, true end

    lastWeaponSetChangeAt = GetTime()

    local equipped, reason = AutoCore.EquipItem(desired.bag, desired.slot, targetSlotId, desired.link)
    if equipped then
        ScheduleScan(SCAN_DEBOUNCE)
    elseif reason == "pending_bind" then
        StartEquipVerification({
            link = desired.link, newScore = bestSet.score, equippedScore = currentScore,
            gain = gain, targetSlotId = targetSlotId, printMessages = cfg.printMessages,
        })
    elseif reason == "in_combat" then
        DeferScanUntilCombatEnds()
    elseif cfg.printMessages then
        print("|cffffcc00AutoUpgrade:|r Could not equip weapon-set item " .. desired.link .. ".")
    end
    return true, true
end

----------------------------------------------------------------------
-- Main: Scan bags and handle upgrades.
-- Modes:
--   0 = Disabled (do nothing)
--   1 = Notify only (report but don't equip)
--   2 = Auto equip (equip automatically)
-- dryRun = true will only print what would be equipped, not equip.
----------------------------------------------------------------------
-- manual = true when the player explicitly ran /ae upgrade scan|test, which
-- always reports its outcome. Automatic scans (BAG_UPDATE, etc.) leave it nil
-- and stay quiet about "nothing to upgrade" unless verbose logging is on.
function AU.ScanBags(dryRun, manual)
    -- Never start another bag/cursor operation while a bind-confirmed equip
    -- is still being resolved.
    if pendingEquip then return end

    local cfg = GetActiveConfig()
    if not cfg then
        print("|cff00ff00AutoUpgrade:|r AutoUpgradeConfig not loaded - cannot scan.")
        return
    end

    -- Mode 0 is disabled - do nothing
    if cfg.enabled == false then
        return
    end

    -- Scoring and reporting are read-only, so notify-only and explicit dry
    -- runs remain available in combat. Only a scan that could equip is held.
    if IsActiveEquipScan(cfg, dryRun) and IsCombatLocked() then
        DeferScanUntilCombatEnds()
        return
    end

    if not AutoCore.HasStatWeights(cfg.weights) then
        print("|cffffcc00AutoUpgrade:|r No non-zero stat weights are configured for " .. cfg.charKey .. "; scan skipped for safety.")
        return
    end

    -- Mode 1 is notify only - always treat as dry run
    local actualDryRun = dryRun or AU.db.notifyOnly or not cfg.autoEquip

    -- Single bag pass: collect hand-slot (weapon/off-hand) candidates and
    -- non-hand-slot candidates together, instead of scanning all 5 bags
    -- twice (once for the weapon set, once for everything else).
    local currentMain, currentOff = BuildEquippedHandRecords(cfg)
    local mainCandidates, offCandidates = {}, {}
    -- Keep equipped items fixed to their current hands. Bag items may fill
    -- any hand allowed by their type; this avoids proposing an equipped-item
    -- hand swap that cannot be performed directly by EquipItem.
    if currentMain then table.insert(mainCandidates, currentMain) end
    if currentOff then table.insert(offCandidates, currentOff) end

    local armorCandidates = {}
    local playerLevel = UnitLevel("player")

    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local texture, count, locked, quality, readable, lootable, link = GetContainerItemInfo(bag, slot)
            if texture and link and not locked and count and count > 0 then
                -- Quality gate. GetContainerItemInfo's `quality` returns -1
                -- for custom/scaled Ascension gear even when the item is
                -- cached, which wrongly skips it, so read the authoritative
                -- quality from GetItemInfo on the link instead.
                local itemQuality = select(3, GetItemInfo(link))
                if itemQuality and itemQuality >= cfg.minQuality then
                    -- Pass bag/slot so reqLevel is read from the real,
                    -- scaled tooltip (SetBagItem) rather than the base
                    -- item template (SetHyperlink) - on Ascension the
                    -- hyperlink tooltip can show a much lower base
                    -- level (e.g. 28) than the actual scaled
                    -- requirement (e.g. 46).
                    local data = AutoCore.GetItemData(link, { bag = bag, slot = slot })
                    if data then
                        local location = { bag = bag, slot = slot }
                        local excludedPvP = not cfg.pvpGearToggle
                            and AutoCore.GetPvPItemInfo(link, location).isPvPGear
                        if excludedPvP then
                            -- Leave Bloodforged/pure-PvP bag items manual unless the
                            -- player explicitly enables PvP gear upgrades.
                        elseif IsOptimizedHandSlot(data.equipSlot) then
                            -- Hand-slot items are evaluated globally as a
                            -- weapon set below, not one at a time.
                            if (not data.reqLevel or data.reqLevel <= playerLevel)
                                and (not cfg.minItemLevel or (data.iLevel and data.iLevel >= cfg.minItemLevel))
                            then
                                local _, usable = AutoCore.ScanTooltip(link, nil, location)
                                if usable ~= false then
                                    local record = {
                                        link = link,
                                        equipSlot = data.equipSlot,
                                        subType = data.subType,
                                        score = AutoCore.GetItemScore(link, cfg.weights, location),
                                        bag = bag,
                                        slot = slot,
                                    }
                                    AddWeaponSetCandidate(record, mainCandidates, offCandidates, cfg)
                                end
                            end
                        -- Required level gate: never attempt to equip
                        -- an item whose required level is above the
                        -- player's current level. Checked explicitly
                        -- here (rather than relying on ScanTooltip's
                        -- "usable" flag) because ScanTooltip
                        -- deliberately ignores "Requires Level" lines
                        -- when computing usable.
                        -- Item level gate (optional)
                        elseif data.reqLevel and data.reqLevel > playerLevel then
                            -- skip: required level too high for the player
                        elseif not cfg.minItemLevel or (data.iLevel and data.iLevel >= cfg.minItemLevel) then
                            table.insert(armorCandidates, { bag = bag, slot = slot, link = link })
                        end
                    end
                end
            end
        end
    end

    -- Optimize the two hand slots as one complete gear set before evaluating
    -- independent armor/jewelry slots. In active mode, perform at most one
    -- hand-slot operation and let the settled follow-up scan continue.
    local weaponEquipStarted, weaponUpgradeFound = FinalizeWeaponSet(cfg, actualDryRun, mainCandidates, offCandidates, currentMain, currentOff)
    if weaponEquipStarted then
        return
    end

    local equippedCount = weaponUpgradeFound and 1 or 0
    local checkedCount = 0

    for _, item in ipairs(armorCandidates) do
        local bag, slot, link = item.bag, item.slot, item.link
        checkedCount = checkedCount + 1
        -- Check usability: unusable items get score 0
        -- and are never upgrades.
        local boundStatus, usable = AutoCore.ScanTooltip(link, nil, { bag = bag, slot = slot })
        -- Evaluate rings as complete two-item sets; other
        -- slots retain the normal single-slot comparison.
        local isUpgrade, newScore, equippedScore, targetSlotId = AU.EvaluateItem(
            link, { bag = bag, slot = slot }
        )
        if isUpgrade then
            equippedCount = equippedCount + 1
            -- Calculate gain for messaging
            local gain = newScore - equippedScore
            local messageInfo = {
                link = link,
                newScore = newScore,
                equippedScore = equippedScore,
                gain = gain,
                targetSlotId = targetSlotId,
                printMessages = cfg.printMessages,
            }

            -- Equip or notify based on mode and dryRun
            if actualDryRun == false then
                -- Auto-equip (Mode 2)
                -- Equip to the target slot (e.g. the
                -- weaker ring slot, or the correct
                -- weapon slot for dual-wield 2H).
                local equipped, reason = AutoCore.EquipItem(bag, slot, targetSlotId, link)
                if equipped then
                    PrintUpgradeAction(messageInfo, "equipped")
                elseif reason == "pending_bind" then
                    StartEquipVerification(messageInfo)
                elseif reason == "in_combat" then
                    DeferScanUntilCombatEnds()
                elseif cfg.printMessages then
                    print("|cffffcc00AutoUpgrade:|r Could not equip " .. link .. ".")
                end
                -- Bag indices and cursor state may have changed. Equip
                -- at most one item per scan; BAG_UPDATE or verification
                -- schedules the next settled scan.
                return
            else
                PrintUpgradeAction(messageInfo, "would equip")
            end
        end
    end

    -- "Nothing to do" outcomes are noise during automatic scans - they fire on
    -- every bag change - so they are silent unless the scan was run by hand or
    -- verbose logging is on. Actual upgrades are always reported on their own
    -- compact line above, regardless of this. (The dry-run and live branches
    -- printed identical text, so they share one path now.)
    if equippedCount == 0 and (manual or cfg.verbose) then
        if checkedCount == 0 then
            print("|cff00ff00AutoUpgrade:|r No items passed quality/ilevel gates.")
        else
            print("|cff00ff00AutoUpgrade:|r Scan complete - no upgrades found (" .. checkedCount .. " item(s) checked).")
        end
    end
end

----------------------------------------------------------------------
-- Event frame
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("ADDON_LOADED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...
    if event == "BAG_UPDATE" or event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "PLAYER_LEVEL_UP" or event == "PLAYER_ENTERING_WORLD"
    then
        setRecordCache = nil
        pvpSetCache = nil
    end
    if event == "ADDON_LOADED" then
        if arg1 == "AutoEverything" then
            AU.db = AutoCore.GetProfileSection("upgrade", true)
            if AU.db.enabled == nil then
                AU.db.enabled = (AutoUpgradeConfig or {}).enabled == true
            end
            if AU.db.notifyOnly == nil then
                AU.db.notifyOnly = false
            end
            AutoCore.Debug("Upgrade", "Saved state loaded.")
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if scanDeferredForCombat then
            scanDeferredForCombat = false
            local cfg = GetActiveConfig()
            if AU.db.enabled and cfg and cfg.enabled then
                ScheduleScan(SCAN_DEBOUNCE)
            else
                scanDirty = false
                StopScanTimerIfIdle()
            end
        end
    elseif event == "BAG_UPDATE" or event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "PLAYER_LEVEL_UP" or event == "PLAYER_ENTERING_WORLD"
    then
        local cfg = GetActiveConfig()
        if AU.db.enabled and cfg and cfg.enabled then
            ScheduleScan(SCAN_DEBOUNCE)
        end
    end
end)

-- Quality-gated bind confirmations for equipping. Handled by
-- AutoBindClear in Core.lua (one shared OnUpdate + event handlers).
AutoCore.RegisterAutoAcceptPopup("EQUIP_BIND", function(quality)
    return ShouldAutoConfirmBind(quality)
end)
AutoCore.RegisterAutoAcceptPopup("AUTOEQUIP_BIND", function(quality)
    return ShouldAutoConfirmBind(quality)
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_AUTOUPGRADE1 = "/autoupgrade"
SLASH_AUTOUPGRADE2 = "/au"

SlashCmdList["AUTOUPGRADE"] = function(msg)
    msg = string.lower(strtrim(msg or ""))

    if msg == "on" then
        AU.db.enabled = true
        AU.db.notifyOnly = false
        AutoCore.NotifyProfileChanged("upgrade")
        ScheduleScan(0)
        print("|cff00ff00AutoUpgrade:|r Auto-upgrade enabled (saved - will persist on reload).")
    elseif msg == "off" then
        AU.db.enabled = false
        AutoCore.NotifyProfileChanged("upgrade")
        scanDirty = false
        scanDeferredForCombat = false
        StopScanTimerIfIdle()
        print("|cff00ff00AutoUpgrade:|r Auto-upgrade disabled (saved - will persist on reload).")
    elseif msg == "notify on" or msg == "notify" then
        AU.db.enabled = true
        AU.db.notifyOnly = true
        AutoCore.NotifyProfileChanged("upgrade")
        ScheduleScan(0)
        print("|cff00ff00AutoUpgrade:|r Notify-only mode enabled (will report but not equip).")
    elseif msg == "notify off" then
        AU.db.notifyOnly = false
        AutoCore.NotifyProfileChanged("upgrade")
        print("|cff00ff00AutoUpgrade:|r Notify-only mode disabled.")
        if AU.db.enabled then
            print("  Auto-upgrade is still on - will auto-equip upgrades.")
        end
    elseif msg == "scan" then
        AU.ScanBags(false, true)
    elseif msg == "test" then
        AU.ScanBags(true, true)
    elseif msg == "pvp" then
        pvpSetCache = nil
        local best = AU.GetBestPvPSet()
        print("|cff00ff00AutoUpgrade PvP Set:|r " .. #best .. " protected piece(s)")
        for _, record in ipairs(best) do
            local location = record.location and record.location.invSlot
                and ("equipped slot " .. record.location.invSlot)
                or ("bag " .. tostring(record.location and record.location.bag)
                    .. " slot " .. tostring(record.location and record.location.slot))
            print("  " .. record.group .. ": " .. record.link
                .. " |cff8b949e(" .. location
                .. ", PvP " .. tostring(record.pvpPower)
                .. ", PvE " .. tostring(record.pvePower)
                .. ", score " .. string.format("%.1f", record.score) .. ")|r")
        end
        if #best == 0 then
            print("  No usable Bloodforged or pure-PvP-Power equipment was found.")
        end
    elseif msg == "debug" then
        -- Debug: scan every bag item and show exactly why each is or
        -- isn't an upgrade (quality gate, item level gate, required
        -- level gate, usability, weapon type, or score below threshold).
        local cfg = GetActiveConfig()
        if not cfg then
            print("|cff00ff00AutoUpgrade:|r AutoUpgradeConfig not loaded.")
            return
        end
        local itemCount = 0
        local upgradeCount = 0
        local skipCount = 0

        for bag = 0, 4 do
            local numSlots = GetContainerNumSlots(bag)
            for slot = 1, numSlots do
                local texture, count, locked, quality, readable, lootable, link = GetContainerItemInfo(bag, slot)
                if texture and link and not locked and count and count > 0 then
                    -- Pass bag/slot so reqLevel reflects the real,
                    -- scaled tooltip rather than the base item template.
                    local data = AutoCore.GetItemData(link, { bag = bag, slot = slot })
                    if data then
                        itemCount = itemCount + 1
                        print("|cff00ff00AutoUpgrade Debug:|r " .. data.name .. " x" .. count)
                        print("  itemType=" .. tostring(data.itemType) .. " subType=" .. tostring(data.subType) .. " quality=" .. tostring(data.quality) .. " reqLevel=" .. tostring(data.reqLevel))
                        print("  iLevel=" .. tostring(data.iLevel) .. " equipSlot=" .. tostring(data.equipSlot))

                        local parsedStats = AutoCore.GetItemStats(link, cfg.weights, { bag = bag, slot = slot })
                        local statParts = {}
                        for statName, value in pairs(parsedStats) do
                            local weight = cfg.weights[statName] or 0
                            table.insert(statParts, statName .. "=" .. tostring(value)
                                .. " x " .. tostring(weight)
                                .. " (" .. string.format("%.2f", value * weight) .. ")")
                        end
                        table.sort(statParts)
                        print("  parsedStats=" .. (#statParts > 0 and table.concat(statParts, "; ") or "none"))

                        local reason = nil
                        local isUpgrade = false
                        local playerLevel = UnitLevel("player")

                        -- Quality gate. Use data.quality (GetItemInfo); the
                        -- GetContainerItemInfo `quality` local is -1 for
                        -- custom/scaled Ascension gear even when cached.
                        if not data.quality or data.quality < cfg.minQuality then
                            reason = "quality " .. tostring(data.quality) .. " is below minQuality " .. tostring(cfg.minQuality)
                        -- Item level gate
                        elseif cfg.minItemLevel and (not data.iLevel or data.iLevel < cfg.minItemLevel) then
                            reason = "item level " .. tostring(data.iLevel) .. " is below minItemLevel " .. tostring(cfg.minItemLevel)
                        -- Required level gate
                        elseif data.reqLevel and data.reqLevel > playerLevel then
                            reason = "required level " .. tostring(data.reqLevel) .. " is above your level " .. tostring(playerLevel)
                        else
                            -- Check usability and run the upgrade check
                            -- with bag/slot so Ascension scaled stats
                            -- are read from the real item instance.
                            local boundStatus, usable = AutoCore.ScanTooltip(link, nil, { bag = bag, slot = slot })
                            local debugInfo = {}
                            local u, newScore, equippedScore, equippedLink, targetSlotId = AutoCore.IsUpgrade(
                                link, cfg.weights, cfg.upgradeThreshold, nil,
                                {
                                    armorTypes    = cfg.armorTypes,
                                    mainHandTypes = cfg.mainHandTypes,
                                    offHandTypes  = cfg.offHandTypes,
                                    rangedTypes   = cfg.rangedTypes,
                                    canOffHandWithTwoHand = cfg.canOffHandWithTwoHand,
                                    usable        = usable,
                                    bag           = bag,
                                    slot          = slot,
                                },
                                debugInfo
                            )
                            isUpgrade = u
                            if not isUpgrade then
                                reason = debugInfo.reason or "not an upgrade"
                            else
                                reason = "upgrade! score " .. string.format("%.2f", newScore) .. " vs equipped " .. string.format("%.2f", equippedScore)
                            end
                        end

                        if isUpgrade then
                            upgradeCount = upgradeCount + 1
                            print("  => |cff00ff00UPGRADE|r (" .. reason .. ")")
                        else
                            skipCount = skipCount + 1
                            print("  => |cffff0000SKIP|r (" .. (reason or "no reason") .. ")")
                        end
                    end
                end
            end
        end

        print("|cff00ff00AutoUpgrade Debug:|r Scanned " .. itemCount .. " item(s): " .. upgradeCount .. " upgrade(s), " .. skipCount .. " skipped.")
        if itemCount == 0 then
            print("|cff00ff00AutoUpgrade:|r No items found in bags.")
        end
    elseif msg == "whoami" then
        local cfg = GetActiveConfig()
        if not cfg then
            print("|cff00ff00AutoUpgrade:|r AutoUpgradeConfig not loaded.")
        else
            print("|cff00ff00AutoUpgrade:|r Character key: " .. cfg.charKey)
            -- Mode: 0=Disabled, 1=Notify only, 2=Auto equip
            local mode = "Auto-equip"
            if not AU.db.enabled or not cfg.enabled then
                mode = "Disabled"
            elseif AU.db.notifyOnly or not cfg.autoEquip then
                mode = "Notify-only (report but don't equip)"
            end
            print("  Mode: " .. tostring(mode))
            print("  minQuality: " .. tostring(cfg.minQuality))
            print("  minItemLevel: " .. tostring(cfg.minItemLevel or "none"))
            print("  upgradeThreshold: " .. tostring(cfg.upgradeThreshold) .. "%")
            print("  armorTypes: " .. (#cfg.armorTypes > 0 and table.concat(cfg.armorTypes, ", ") or "any usable armor"))
            print("  pvpGearToggle (allow PvP gear): " .. tostring(cfg.pvpGearToggle))
            print("  mainHandTypes: " .. (#cfg.mainHandTypes > 0 and table.concat(cfg.mainHandTypes, ", ") or "none"))
            print("  offHandTypes: " .. (#cfg.offHandTypes > 0 and table.concat(cfg.offHandTypes, ", ") or "none"))
            print("  rangedTypes: " .. (#cfg.rangedTypes > 0 and table.concat(cfg.rangedTypes, ", ") or "none"))
            print("  inferred dual two-hand: " .. tostring(cfg.canOffHandWithTwoHand))
            local bindList = {}
            for q in pairs(cfg.autoConfirmBind) do
                table.insert(bindList, tostring(q))
            end
            table.sort(bindList)
            print("  autoConfirmBind qualities: " .. (#bindList > 0 and table.concat(bindList, ", ") or "none"))
        end
    elseif msg == "stats" then
        -- Compares every way we know of to read an item's stats, for the
        -- first backpack slot (bag 0, slot 1). Point it at a weapon to check
        -- Weapon Damage/Min Damage/Max Damage/Weapon Speed parsing specifically.
        local bag, slot = 0, 1
        local link = GetContainerItemLink(bag, slot)
        if not link then
            print("|cff00ff00AutoUpgrade:|r No item in bag " .. bag .. " slot " .. slot .. ".")
            return
        end
        print("|cff00ff00AutoUpgrade Stats Debug:|r " .. link .. " (bag " .. bag .. " slot " .. slot .. ")")

        print("|cffffcc00Raw tooltip lines:|r")
        local lines = AutoCore.DumpTooltipLines(link, { bag = bag, slot = slot })
        if #lines == 0 then
            print("  (tooltip returned no lines)")
        end
        for i, line in ipairs(lines) do
            local text = line.left or ""
            if line.right and line.right ~= "" then text = text .. "   |   " .. line.right end
            print("  [" .. i .. "] " .. text)
        end

        print("|cffffcc00Parsed stats via SetBagItem (Core.ParseStatLine, what scoring actually uses):|r")
        local cfg = GetActiveConfig()
        local stats = AutoCore.GetItemStats(link, cfg and cfg.weights or {}, { bag = bag, slot = slot })
        local anyStat = false
        for statName, value in pairs(stats) do
            anyStat = true
            print("  " .. statName .. " = " .. tostring(value))
        end
        if not anyStat then print("  (none matched)") end

        -- Same parser, but via SetHyperlink instead of SetBagItem, to check
        -- whether every stat agrees, not just reqLevel. Grabbed twice - once
        -- instantly, once after a 0.3s delay - to tell apart a caching-lag
        -- artifact (matches on retry) from a genuine, persistent SetHyperlink
        -- limitation (still wrong on retry).
        local function CompareHyperlinkStats(label)
            print("|cffffcc00Parsed stats via SetHyperlink (" .. label .. "):|r")
            local hyperlinkStats = AutoCore.GetItemStats(link, cfg and cfg.weights or {}, nil)
            local anyHyperlinkStat = false
            local allMatch = true
            local statNames = {}
            for statName in pairs(stats) do statNames[statName] = true end
            for statName in pairs(hyperlinkStats) do statNames[statName] = true end
            for statName in pairs(statNames) do
                anyHyperlinkStat = anyHyperlinkStat or hyperlinkStats[statName] ~= nil
                local bagValue = stats[statName]
                local linkValue = hyperlinkStats[statName]
                local matched = bagValue == linkValue
                if not matched then allMatch = false end
                print("  " .. statName .. " = " .. tostring(linkValue)
                    .. (matched and " |cff00ff00(matches)|r" or (" |cffff4040(bag item says " .. tostring(bagValue) .. ")|r")))
            end
            if not anyHyperlinkStat and not anyStat then
                print("  (none matched)")
            elseif allMatch then
                print("  |cff00ff00All stats match between SetBagItem and SetHyperlink.|r")
            end
        end

        CompareHyperlinkStats("1st grab, instant")
        ScheduleDelayedCallback(0.3, function()
            CompareHyperlinkStats("2nd grab, +0.3s")
        end)

        -- GetItemStats() is a Blizzard API added well after 3.3.5 on retail;
        -- some private-server clients backport it. Even where present, it
        -- never exposes raw weapon min/max damage or speed - those are
        -- tooltip-only fields on every WoW client version - but it is a
        -- useful cross-check for rating/stat-point values like Hit Rating.
        if type(GetItemStats) == "function" then
            print("|cffffcc00GetItemStats() API:|r")
            local ok, apiStats = pcall(GetItemStats, link)
            if ok and apiStats and next(apiStats) then
                for statKey, value in pairs(apiStats) do
                    print("  " .. statKey .. " = " .. tostring(value))
                end
            else
                print("  (returned nothing for this item)")
            end
        else
            print("|cffffcc00GetItemStats() API:|r not available on this client.")
        end

        local pvpSnapshot = AutoCore.GetTooltipSnapshot(link, { bag=bag, slot=slot }, cfg and cfg.weights or {})
        local pvpInfo = AutoCore.GetPvPItemInfo(link, { bag=bag, slot=slot }, pvpSnapshot)
        print("|cffffcc00PvP-set classification:|r bloodforged=" .. tostring(pvpInfo.bloodforged)
            .. " pvpPower=" .. tostring(pvpInfo.pvpPower)
            .. " pvePower=" .. tostring(pvpInfo.pvePower)
            .. " purePvPOrBloodforged=" .. tostring(pvpInfo.isPvPGear))

        -- UnitDamage("player") reflects your live, fully-scaled damage
        -- (buffs/attack power included) - only meaningful when this exact
        -- item is the one currently equipped in that hand, and only as a
        -- sanity check against the tooltip's base numbers, not a general
        -- way to read an arbitrary bag item's stats.
        local mainHandLink = GetInventoryItemLink("player", 16)
        local offHandLink = GetInventoryItemLink("player", 17)
        if link == mainHandLink or link == offHandLink then
            local lowMain, highMain, lowOff, highOff = UnitDamage("player")
            print("|cffffcc00UnitDamage(\"player\") [live, scaled, includes buffs/AP]:|r")
            if link == mainHandLink then
                print(string.format("  Main hand: %.1f - %.1f", lowMain or 0, highMain or 0))
            end
            if link == offHandLink then
                print(string.format("  Off hand: %.1f - %.1f", lowOff or 0, highOff or 0))
            end
        else
            print("|cffffcc00UnitDamage(\"player\"):|r not applicable - this item isn't currently equipped.")
        end

        -- Hyperlink retry test: SetBagItem/SetInventoryItem are used
        -- everywhere in this addon instead of the simpler SetHyperlink
        -- because a hyperlink tooltip has been observed to show a stale/
        -- unscaled value (e.g. reqLevel 28 when the real scaled requirement
        -- is 46). But AutoRoll had the exact same "first read is wrong,
        -- a moment later it's right" pattern for GetItemInfo, which turned
        -- out to just be client-side caching lag, not a hyperlink-specific
        -- limitation. This checks whether that's true here too: an instant
        -- SetHyperlink grab vs. one retried after 0.3s, both against the
        -- SetBagItem value already trusted as correct.
        print("|cffffcc00Hyperlink req-level retry test:|r")
        local bagReqLevel = AutoCore.GetTooltipReqLevel(link, { bag = bag, slot = slot })
        local hyperlinkReqLevel1 = AutoCore.GetTooltipReqLevel(link, nil)
        print("  SetBagItem (trusted): " .. tostring(bagReqLevel))
        print("  SetHyperlink (1st grab, instant): " .. tostring(hyperlinkReqLevel1))
        ScheduleDelayedCallback(0.3, function()
            local hyperlinkReqLevel2 = AutoCore.GetTooltipReqLevel(link, nil)
            local matched = hyperlinkReqLevel2 == bagReqLevel
            print("  SetHyperlink (2nd grab, +0.3s): " .. tostring(hyperlinkReqLevel2)
                .. (matched and " |cff00ff00(matches SetBagItem!)|r" or " |cffff4040(still differs)|r"))
        end)
    else
        if not AU.db.enabled then
            print("|cff00ff00AutoUpgrade:|r Auto-upgrade disabled.")
        elseif AU.db.notifyOnly then
            print("|cff00ff00AutoUpgrade:|r Notify-only mode (will report but not equip).")
        else
            print("|cff00ff00AutoUpgrade:|r Auto-equip mode enabled.")
        end
        print("|cff00ff00AutoUpgrade:|r Commands:")
        print("  /autoupgrade on         - Enable auto-equip mode")
        print("  /autoupgrade off        - Disable auto-upgrade")
        print("  /autoupgrade notify on  - Enable notify-only mode")
        print("  /autoupgrade notify off - Disable notify-only mode")
        print("  /autoupgrade scan       - Scan bags now")
        print("  /autoupgrade test       - Dry run")
        print("  /autoupgrade pvp        - List the protected best PvP set")
        print("  /autoupgrade whoami     - Show profile and mode")
        print("  /autoupgrade debug      - Show detailed item decisions")
        print("  /autoupgrade stats      - Compare stat-reading methods for bag 0 slot 1")
    end
end
