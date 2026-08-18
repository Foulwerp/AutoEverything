----------------------------------------------------------------------
-- AutoRoll.lua
-- ============
-- AutoRoll module for the combined addon. Uses AutoCore (Core.lua)
-- for all shared logic (tooltip scanning, filter matching, config
-- profile resolution, quest protection, AutoBindClear).
--
-- Automatically rolls on group loot based on the priority lists in
-- AutoRollConfig.lua (WoW 3.3.5a / Ascension APIs only).
--
-- Modes:
--   * Normal (/autoroll on)      – actually rolls
--   * Notify  (/autoroll notify) – only prints what it would roll
--   * Off     (/autoroll off)    – does nothing
--
-- How it works:
--   1. The START_LOOT_ROLL event fires with a rollId.
--   2. GetLootRollItemLink(rollId) gives the item link directly.
--   3. GetLootRollItemInfo(rollId) gives name, quality, and
--      canNeed / canGreed / canDisenchant flags.
--   4. GetItemInfo(link) gives the extended fields (iLevel, reqLevel,
--      itemType, subType, equipSlot, vendorPrice).
--   5. A tooltip scan (SetHyperlink + exact red color check) tells
--      us whether the item is "unusable" for our class, and detects
--      the binding type (bop/boe/bou/unbound).
--   6. The item is matched against the active rules (commonRules +
--      the current character's profile from AutoRollConfig.lua).
--      The FIRST matching rule wins.
--   7. The rule's rollPriority list is walked IN ORDER. The first
--      roll type the game allows is queued for execution.
--   8. Queued rolls are processed one at a time with a 0.5 second
--      delay between each, using the native RollOnLoot() API.
--   9. For disenchant and BoP rolls, AutoCore.TrackPendingRoll is
--      called so AutoBindClear auto-accepts the confirmation via
--      ConfirmLootRoll() (or Button1 / ConfirmBindOnUse fallback).
--  10. If NONE of the priority types can be done, we do NOTHING and
--      leave the roll window open for a manual pick. We never
--      auto-pass unless "pass" is explicitly in the list.
--  11. Active quest items (Quest/QuestDB.lua via AutoCore) are never
--      auto-rolled.
--  12. In notify-only mode every roll is dry-run: chat output only.
----------------------------------------------------------------------

-- Namespace
AutoRoll = AutoRoll or {}
local AR = AutoRoll

-- Saved variables (per character)
AR.db = {}

if AR.db.enabled == nil then
    AR.db.enabled = false
end
if AR.db.notifyOnly == nil then
    AR.db.notifyOnly = false
end

-- Tracks roll IDs we have already processed
AR.processed = AR.processed or {}

-- Tracks roll IDs that are currently active (for test/debug commands)
local activeRolls = {}

-- Roll queue: processed one at a time with a 0.5s delay
local rollQueue = {}

-- Roll IDs already queued/submitted by this module. This prevents a
-- recommendation link from being double-clicked before the game closes it.
local committedRolls = {}

local ROLL_METHOD = {
    need       = 1,
    greed      = 2,
    disenchant = 3,
    pass       = 0,
}

local ROLL_DISPLAY_NAME = {
    need       = "Need",
    greed      = "Greed",
    disenchant = "Disenchant",
    pass       = "Pass",
}

local ROLL_ACTION_COLOR = {
    need       = "|cff00ff00", -- green
    greed      = "|cffff4040", -- red
    disenchant = "|cffff69b4", -- pink
    pass       = "|cffaaaaaa", -- gray
}

local function FormatRollAction(rollName, rollId, clickable)
    local action = string.upper(ROLL_DISPLAY_NAME[rollName] or rollName or "ROLL")
    local text = action
    if clickable and rollId and ROLL_METHOD[rollName] ~= nil then
        text = "|Hautoeverything-roll:" .. tostring(rollId) .. ":" .. rollName .. "|h" .. action .. "|h"
    end
    return (ROLL_ACTION_COLOR[rollName] or "|cffffffff") .. text .. "|r"
end

local function GetRollItemText(data)
    return data.link or data.name or "item"
end

----------------------------------------------------------------------
-- Per-character config resolution (delegated to Core)
----------------------------------------------------------------------
local activeConfig = nil
local upgradeConfigCache = nil

local function GetActiveConfig()
    if not activeConfig then
        activeConfig = AutoCore.BuildActiveConfig(AutoRollConfig)
    end
    return activeConfig
end

function AR.ClearConfigCache()
    activeConfig = nil
    upgradeConfigCache = nil
end

function AR.ApplyProfile()
    if AutoCore and AutoCore.GetProfileSection then
        AR.db = AutoCore.GetProfileSection("roll", true)
    end
    if AR.db.enabled == nil then AR.db.enabled = (AutoRollConfig or {}).enabled == true end
    if AR.db.notifyOnly == nil then AR.db.notifyOnly = false end
end

----------------------------------------------------------------------
-- Upgrade weight/threshold resolution (falls back to AutoUpgradeConfig)
----------------------------------------------------------------------
local function GetUpgradeConfig()
    if not upgradeConfigCache then
        local config = AutoUpgradeConfig
        if config then
            local profile = AutoCore.GetProfile(config)
            if not profile then
                profile = config.default or {}
            end

            local weights = profile.weights
            if weights == nil then weights = config.weights end
            if weights == nil then weights = {} end

            local threshold = profile.upgradeThreshold
            if threshold == nil then threshold = config.upgradeThreshold end
            if threshold == nil then threshold = 5 end

            local armorTypes = profile.armorTypes
            if armorTypes == nil then armorTypes = config.armorTypes end
            if armorTypes == nil then armorTypes = {} end

            local mainHandTypes = profile.mainHandTypes
            if mainHandTypes == nil then mainHandTypes = config.mainHandTypes end
            if mainHandTypes == nil then mainHandTypes = {} end

            local offHandTypes = profile.offHandTypes
            if offHandTypes == nil then offHandTypes = config.offHandTypes end
            if offHandTypes == nil then offHandTypes = {} end

            local rangedTypes = profile.rangedTypes
            if rangedTypes == nil then rangedTypes = config.rangedTypes end
            if rangedTypes == nil then rangedTypes = {} end

            local canOffHandWithTwoHand = AutoCore.InferCanOffHandWithTwoHand(mainHandTypes, offHandTypes)

            upgradeConfigCache = {
                weights = weights,
                threshold = threshold,
                armorTypes = armorTypes,
                mainHandTypes = mainHandTypes,
                offHandTypes = offHandTypes,
                rangedTypes = rangedTypes,
                canOffHandWithTwoHand = canOffHandWithTwoHand,
            }
        else
            upgradeConfigCache = { weights = {}, threshold = 5, armorTypes = {}, mainHandTypes = {}, offHandTypes = {}, rangedTypes = {}, canOffHandWithTwoHand = false }
        end
    end
    return upgradeConfigCache
end

local function GetUpgradeWeights()
    local cfg = GetActiveConfig()
    if cfg and cfg.weights and next(cfg.weights) then
        return cfg.weights
    end
    return GetUpgradeConfig().weights
end

local function GetUpgradeThreshold()
    local cfg = GetActiveConfig()
    if cfg and cfg.upgradeThreshold then
        return cfg.upgradeThreshold
    end
    return GetUpgradeConfig().threshold
end

local function GetMainHandTypes()
    return GetUpgradeConfig().mainHandTypes
end

local function GetOffHandTypes()
    return GetUpgradeConfig().offHandTypes
end

local function GetRangedTypes()
    return GetUpgradeConfig().rangedTypes or {}
end

local function GetArmorTypes()
    return GetUpgradeConfig().armorTypes or {}
end

local function CanOffHandWithTwoHand()
    return GetUpgradeConfig().canOffHandWithTwoHand == true
end

----------------------------------------------------------------------
-- Helper: Build the item data table for a loot roll
----------------------------------------------------------------------
local function BuildItemData(rollId)
    local itemLink = GetLootRollItemLink(rollId)
    if not itemLink then
        return nil
    end

    local texture, name, quantity, quality, bindOnPickup, canNeed, canGreed, canDisenchant = GetLootRollItemInfo(rollId)
    if not name then
        return nil
    end

    local data = {
        id            = tonumber(itemLink:match("|Hitem:(%d+):")),
        name          = name,
        quality       = quality,
        iLevel        = nil,
        reqLevel      = nil,
        itemType      = nil,
        subType       = nil,
        maxStack      = quantity,
        equipSlot     = nil,
        texture       = texture,
        vendorPrice   = nil,
        link          = itemLink,
        rollId        = rollId,
        bindOnPickup  = bindOnPickup,
        bound         = "unbound",
        usable        = true,
        canNeed       = canNeed,
        canGreed      = canGreed,
        canDisenchant = canDisenchant,
    }

    local _, _, linkQuality, iLevel, reqLevel, itemType, subType, _, equipSlot, _, sellPrice = GetItemInfo(itemLink)
    -- GetLootRollItemInfo returns quality = -1 on Ascension; GetItemInfo on
    -- the link is authoritative, so prefer it whenever the item is cached.
    if linkQuality and linkQuality >= 0 then
        data.quality = linkQuality
    end
    if iLevel then
        data.iLevel      = iLevel
        data.reqLevel    = reqLevel
        data.itemType    = itemType
        data.subType     = subType
        data.equipSlot   = equipSlot
        data.vendorPrice = sellPrice
    end

    local tooltipReq = AutoCore.GetTooltipReqLevel(itemLink, { rollID = rollId })
    if tooltipReq then
        data.reqLevel = tooltipReq
    end

    local boundStatus, usable = AutoCore.ScanTooltip(itemLink, nil, { rollID = rollId })
    data.bound  = boundStatus
    data.usable = usable

    return data
end

----------------------------------------------------------------------
-- Helper: Can we perform a given roll type on this item?
----------------------------------------------------------------------
local function CanDo(data, rollName)
    if rollName == "need" then
        return data.canNeed
    elseif rollName == "greed" then
        return data.canGreed
    elseif rollName == "disenchant" then
        return data.canDisenchant
    elseif rollName == "pass" then
        return true
    end
    return false
end

----------------------------------------------------------------------
-- Helper: Decide what to do with an item
----------------------------------------------------------------------
local function DecideRoll(data, debug)
    local config = GetActiveConfig()
    if not config or not config.rules then
        return nil, "no config", nil
    end

    local playerLevel = UnitLevel("player")

    -- Independent automation ceiling: broader rules can never roll above it.
    if config.maxQuality ~= nil
        and (data.quality == nil or data.quality > config.maxQuality)
    then
        return nil, "quality is above max roll quality", debug and {} or nil
    end

    local details = debug and {} or nil
    local function AddDetail(kind, entry, matched, why, extraSupported)
        if details then
            local unsupported = AutoCore.GetUnsupportedEntryFields(entry, extraSupported)
            table.insert(details, {
                kind = kind,
                entryText = AutoCore.FormatEntry(entry),
                matched = matched,
                why = why,
                unsupported = unsupported,
            })
        end
    end

    -- isUpgrade is NOT one of Core.EntryMatches' fields (it depends on
    -- weights/equipped gear, not just static item data), so it can't be
    -- evaluated inside AutoCore.EntryMatchDebug. We compute it here -
    -- once, lazily, since it's the same regardless of which rule asks -
    -- and treat a rule's isUpgrade as a real match condition. This is
    -- what makes an isUpgrade=true rule and an isUpgrade=false rule
    -- mutually exclusive instead of the first one in the list always
    -- winning regardless of its isUpgrade setting.
    local isUpgradeResult, isUpgradeComputed, upgradeUnknownReason
    local function GetIsUpgrade()
        if not isUpgradeComputed then
            isUpgradeComputed = true
            local weights = GetUpgradeWeights()
            if not AutoCore.HasStatWeights(weights) then
                isUpgradeResult = nil
                upgradeUnknownReason = "upgrade status is unknown because no non-zero stat weights are configured"
            else
                local upgradeDebugInfo = debug and {} or nil
                isUpgradeResult = AutoCore.IsUpgrade(
                    data.link, weights, GetUpgradeThreshold(), nil,
                    {
                        armorTypes    = GetArmorTypes(),
                        mainHandTypes = GetMainHandTypes(),
                        offHandTypes  = GetOffHandTypes(),
                        rangedTypes   = GetRangedTypes(),
                        canOffHandWithTwoHand = CanOffHandWithTwoHand(),
                        usable        = data.usable,
                        rollID        = data.rollId
                    },
                    upgradeDebugInfo
                )
            end
        end
        return isUpgradeResult, upgradeUnknownReason
    end

    for _, rule in ipairs(config.rules) do
        local exceptionMatch = false
        if rule.exceptions then
            for _, exc in ipairs(rule.exceptions) do
                local m, why = AutoCore.EntryMatchDebug(exc, data, data.bound, data.usable, playerLevel)
                local unsupported = AutoCore.GetUnsupportedEntryFields(exc, { isUpgrade = true })
                local invalidException = #unsupported > 0
                    or (why == "entry has no supported filter fields" and exc.isUpgrade == nil)
                if not m and why == "entry has no supported filter fields"
                    and exc.isUpgrade ~= nil and #unsupported == 0
                then
                    m = true
                end
                if m and exc.isUpgrade ~= nil then
                    local upgrade = GetIsUpgrade()
                    if upgrade == nil then
                        invalidException = true
                        m = false
                    else
                        m = upgrade == exc.isUpgrade
                    end
                end
                if m or invalidException then
                    exceptionMatch = true
                    break
                end
            end
        end
        if exceptionMatch then
            AddDetail("rule", rule, false, "SKIPPED (exception matched)", {
                isUpgrade = true,
                rollPriority = true,
            })
        else
            local m, why = AutoCore.EntryMatchDebug(rule, data, data.bound, data.usable, playerLevel)
            local unsupported = AutoCore.GetUnsupportedEntryFields(rule, {
                isUpgrade = true, rollPriority = true,
            })

            -- Permit an isUpgrade-only rule, but never permit unknown fields
            -- to broaden an automatic roll rule.
            if not m and why == "entry has no supported filter fields"
                and rule.isUpgrade ~= nil and #unsupported == 0
            then
                m, why = true, nil
            end
            if #unsupported > 0 then
                m = false
                why = "rule has unsupported field(s): " .. table.concat(unsupported, ", ")
            end

            if m and rule.isUpgrade ~= nil then
                local upgrade, unknownReason = GetIsUpgrade()
                if upgrade == nil then
                    m = false
                    why = unknownReason or "upgrade status is unknown"
                elseif upgrade ~= rule.isUpgrade then
                    m = false
                    why = rule.isUpgrade
                        and "item is not an upgrade (this rule requires isUpgrade=true)"
                        or "item IS an upgrade (this rule requires isUpgrade=false)"
                end
            end

            AddDetail("rule", rule, m, why, {
                isUpgrade = true,
                rollPriority = true,
            })
            if m then
                if debug then
                    return rule.rollPriority or config.rollPriority or { "greed" }, rule, details
                end
                return rule.rollPriority or config.rollPriority or { "greed" }, rule
            end
        end
    end

    if debug then
        return nil, "no matching rule", details
    end

    return nil, "no matching rule"
end

----------------------------------------------------------------------
-- Helper: Print a compact summary of a roll decision
----------------------------------------------------------------------
local function DebugPrint(data, priority, rule, reason)
    local typeStr = data.itemType or "?"
    local subStr  = data.subType or "?"
    local iLvlStr = data.iLevel and ("ilvl " .. data.iLevel) or "ilvl ?"
    print("|cff00ff00AutoRoll:|r " .. data.name .. " (" .. typeStr .. "/" .. subStr .. ", " .. iLvlStr .. ")")
    print("  quality=" .. tostring(data.quality) .. " reqLevel=" .. tostring(data.reqLevel))
    print("  bound=" .. tostring(data.bound) .. " usable=" .. tostring(data.usable))
    print("  canNeed=" .. tostring(data.canNeed) .. " canGreed=" .. tostring(data.canGreed) .. " canDisenchant=" .. tostring(data.canDisenchant))

    if reason then
        print("  => " .. reason)
        return
    end

    local parts = {}
    for _, rollName in ipairs(priority) do
        local status = "OK"
        if not CanDo(data, rollName) then
            if rollName == "need" then
                status = "cannot need"
            elseif rollName == "greed" then
                status = "cannot greed"
            elseif rollName == "disenchant" then
                status = "cannot disenchant"
            elseif rollName == "pass" then
                status = "always OK"
            else
                status = "unknown type"
            end
        end
        table.insert(parts, rollName .. " (" .. status .. ")")
    end
    print("  priority: " .. table.concat(parts, " -> "))
end

----------------------------------------------------------------------
-- Roll queue: one roll every 0.5 seconds via RollOnLoot()
----------------------------------------------------------------------
local rollTimerFrame = CreateFrame("Frame")
local rollTimerElapsed = 0
local rollTimerActive = false

local function StartRollTimer()
    if not rollTimerActive then
        rollTimerActive = true
        rollTimerElapsed = 0
        rollTimerFrame:SetScript("OnUpdate", function(self, elapsed)
            rollTimerElapsed = rollTimerElapsed + elapsed
            if rollTimerElapsed >= 0.5 then
                rollTimerElapsed = 0
                local nextRoll = table.remove(rollQueue, 1)
                if nextRoll then
                    local data = activeRolls[nextRoll.rollId] and BuildItemData(nextRoll.rollId)
                    if data and CanDo(data, nextRoll.rollName) and not AutoCore.IsActiveQuestItem(data.id) then
                        -- Tell AutoBindClear we initiated this roll
                        AutoCore.TrackPendingRoll(nextRoll.rollId, nextRoll.rollMethod)
                        RollOnLoot(nextRoll.rollId, nextRoll.rollMethod)
                    else
                        committedRolls[nextRoll.rollId] = nil
                        AutoCore.Warn("Roll", "Roll " .. tostring(nextRoll.rollId) .. " is no longer available.")
                    end
                end
                if #rollQueue == 0 then
                    rollTimerActive = false
                    self:SetScript("OnUpdate", nil)
                end
            end
        end)
    end
end

local function QueueRoll(rollId, rollName, itemLink)
    local method = ROLL_METHOD[rollName]
    if method == nil or not activeRolls[rollId] or committedRolls[rollId] then
        return false
    end
    committedRolls[rollId] = true
    table.insert(rollQueue, {
        rollId = rollId,
        rollName = rollName,
        rollMethod = method,
        itemLink = itemLink,
    })
    StartRollTimer()
    return true
end

----------------------------------------------------------------------
-- Clickable notify-mode roll actions
----------------------------------------------------------------------
local function HandleRollActionLink(rollId, rollName)
    rollId = tonumber(rollId)
    if not rollId or ROLL_METHOD[rollName] == nil then
        return
    end

    if not activeRolls[rollId] then
        AutoCore.Warn("Roll", "That loot roll is no longer active.")
        return
    end

    if committedRolls[rollId] then
        AutoCore.Warn("Roll", "A choice has already been submitted for that loot roll.")
        return
    end

    AutoCore.RebuildQuestItems()
    local data = BuildItemData(rollId)
    if not data then
        AutoCore.Warn("Roll", "That loot roll is no longer available.")
        return
    end
    if AutoCore.IsActiveQuestItem(data.id) then
        AutoCore.Warn("Roll", "That item is protected as an active quest item.")
        return
    end
    if not CanDo(data, rollName) then
        AutoCore.Warn("Roll", string.upper(ROLL_DISPLAY_NAME[rollName]) .. " is not available for that item.")
        return
    end

    if QueueRoll(rollId, rollName, data.link) then
        print("|cff00ff00AutoRoll:|r Selected " .. FormatRollAction(rollName) .. " on " .. GetRollItemText(data) .. ".")
    end
end

-- WoW routes chat hyperlink clicks through SetItemRef. Handle only our
-- namespaced link type and delegate every native/addon link unchanged.
local OriginalSetItemRef = SetItemRef
SetItemRef = function(link, text, button, chatFrame)
    local rollId, rollName = tostring(link or ""):match("^autoeverything%-roll:(%d+):([a-z]+)$")
    if rollId and rollName then
        HandleRollActionLink(rollId, rollName)
        return
    end
    return OriginalSetItemRef(link, text, button, chatFrame)
end

----------------------------------------------------------------------
-- Main: Process a single loot roll
-- dryRun = true -> print only, do not roll (used by test + notify mode)
----------------------------------------------------------------------
local function ProcessRoll(rollId, dryRun, debug)
    AutoCore.RebuildQuestItems()

    local data = BuildItemData(rollId)
    if not data then
        if debug then
            print("|cff00ff00AutoRoll:|r Roll " .. tostring(rollId) .. " is no longer valid.")
        end
        return
    end

    if AutoCore.IsActiveQuestItem(data.id) then
        if debug or dryRun then
            print("|cff00ff00AutoRoll:|r " .. data.name .. " is an active quest item - leaving it alone.")
        end
        return
    end

    local priority, rule, rollDetails = DecideRoll(data, debug)

    if debug and rollDetails then
        for _, d in ipairs(rollDetails) do
            if d.unsupported and #d.unsupported > 0 then
                print("  |cffffcc00WARNING:|r " .. d.kind .. " " .. d.entryText
                    .. " has unsupported field(s): " .. table.concat(d.unsupported, ", "))
            end
            if d.matched then
                print(string.format("  Rule %s: MATCH", d.entryText))
            else
                print(string.format("  Rule %s: no (%s)", d.entryText, d.why or "?"))
            end
        end
    end

    if debug then
        DebugPrint(data, priority, rule, not priority and rule)
    end

    if not priority then
        if dryRun and not debug then
            print("|cff00ff00AutoRoll:|r " .. data.name .. " - no matching rule (leave manual).")
        end
        return
    end

    -- Upgrade check (roll link via SetHyperlink; equipped via SetInventoryItem)
    if rule and rule.isUpgrade then
        local debugInfo = {}
        local isUpgrade, newScore, equippedScore = AutoCore.IsUpgrade(
            data.link, GetUpgradeWeights(), GetUpgradeThreshold(), nil,
            {
                armorTypes    = GetArmorTypes(),
                mainHandTypes = GetMainHandTypes(),
                offHandTypes  = GetOffHandTypes(),
                rangedTypes   = GetRangedTypes(),
                canOffHandWithTwoHand = CanOffHandWithTwoHand(),
                usable        = data.usable,
                rollID        = data.rollId
            },
            debugInfo
        )
        if debug then
            print("|cff00ff00AutoRoll:|r Upgrade check: " .. data.name .. " score " .. string.format("%.2f", newScore) .. " vs equipped " .. string.format("%.2f", equippedScore) .. " -> " .. tostring(isUpgrade))
            if not isUpgrade then
                print("  why: " .. (debugInfo.reason or "not an upgrade"))
            end
        end
        if not isUpgrade then
            if dryRun or debug then
                print("|cff00ff00AutoRoll:|r " .. data.name .. " is not an upgrade - leaving for manual selection.")
            end
            return
        end
    end

    for _, rollName in ipairs(priority) do
        if CanDo(data, rollName) then
            if dryRun then
                print("|cff00ff00AutoRoll:|r You should " .. FormatRollAction(rollName, rollId, true) .. " on " .. GetRollItemText(data) .. ".")
            else
                if QueueRoll(rollId, rollName, data.link) then
                    print("|cff00ff00AutoRoll:|r Rolling " .. FormatRollAction(rollName) .. " on " .. GetRollItemText(data) .. ".")
                end
            end
            return
        end
    end

    if dryRun or debug then
        print("|cff00ff00AutoRoll:|r No available roll for " .. data.name .. " - leaving for manual selection.")
    end
end

----------------------------------------------------------------------
-- Generic one-shot delayed callback (3.3.5 has no C_Timer). Used both to
-- retry a roll once its item info has finished caching, and to give /autoroll
-- debug a delayed recheck to show against its instant one.
----------------------------------------------------------------------
local afterQueue = {}
local afterFrame = CreateFrame("Frame")
afterFrame:SetScript("OnUpdate", function(self, elapsed)
    if #afterQueue == 0 then return end
    local index = 1
    while index <= #afterQueue do
        local entry = afterQueue[index]
        entry.elapsed = entry.elapsed + elapsed
        if entry.elapsed >= entry.delay then
            table.remove(afterQueue, index)
            entry.callback()
        else
            index = index + 1
        end
    end
end)

local function After(delay, callback)
    table.insert(afterQueue, { elapsed = 0, delay = delay, callback = callback })
end

----------------------------------------------------------------------
-- Some items are not yet in the client's local item cache the instant a
-- loot roll starts (e.g. the first time you've seen that item this
-- session). GetItemInfo returns nil for iLevel/reqLevel/itemType/etc.
-- until the server responds, which would score the item as if it had none
-- of those - retry briefly rather than deciding on incomplete data. A loot
-- roll's decision window is much longer than this short retry budget, so
-- there is no risk of missing the roll by waiting.
--
-- Separately, Ascension scales equippable loot to the player's level at the
-- moment it's picked up - that scale is then permanent for that item
-- instance, it does not track your level afterward. For a roll on a fresh
-- drop, "picked up at" is always "right now", so reqLevel should equal your
-- current level. It is never legitimate for reqLevel to be ABOVE your
-- current level (loot cannot be scaled to a level you haven't reached yet),
-- so that always means stale/incomplete data worth a retry. The one
-- legitimate exception is reqLevel being exactly 1 BELOW your current level:
-- if you ding right as the roll appears, the item was scaled to your
-- previous level a moment earlier, and that should still count as correct
-- rather than being treated as bad data forever.
----------------------------------------------------------------------
local function LevelLooksSane(data)
    if not data.equipSlot or data.equipSlot == "" then return true end
    if not data.reqLevel then return true end
    local playerLevel = UnitLevel("player")
    return playerLevel and data.reqLevel <= playerLevel and data.reqLevel >= playerLevel - 1
end

-- 4 attempts * 0.25s = 1 second total retry budget. A loot roll's decision
-- window is far longer than this, so there is no risk of missing the roll.
local RETRY_INTERVAL = 0.25
local MAX_RETRY_ATTEMPTS = 4

local function ProcessRollWhenReady(rollId, dryRun, debug, attemptsLeft)
    attemptsLeft = attemptsLeft or MAX_RETRY_ATTEMPTS
    if not activeRolls[rollId] then return end
    local data = BuildItemData(rollId)
    if data and attemptsLeft > 0 then
        if data.iLevel == nil or not LevelLooksSane(data) then
            After(RETRY_INTERVAL, function() ProcessRollWhenReady(rollId, dryRun, debug, attemptsLeft - 1) end)
            return
        end
    elseif data and data.reqLevel and not LevelLooksSane(data) then
        -- Out of retries and still mismatched: warn once, then proceed with
        -- whatever data we have rather than silently deciding on bad stats.
        -- Only reqLevel mismatches warn here - a still-nil iLevel after all
        -- retries falls through silently, same as it always has.
        AutoCore.Warn("Roll", data.name .. " required level " .. tostring(data.reqLevel)
            .. " is above your level, or more than 1 below it (" .. tostring(UnitLevel("player"))
            .. ") even after retrying; proceeding with its current stats.")
    end
    ProcessRoll(rollId, dryRun, debug)
end

----------------------------------------------------------------------
-- Event frame
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("START_LOOT_ROLL")
eventFrame:RegisterEvent("CANCEL_LOOT_ROLL")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    local arg1, arg2 = ...
    if event == "ADDON_LOADED" then
        if arg1 == "AutoEverything" then
            AR.db = AutoCore.GetProfileSection("roll", true)
            if AR.db.enabled == nil then
                AR.db.enabled = (AutoRollConfig or {}).enabled == true
            end
            if AR.db.notifyOnly == nil then
                AR.db.notifyOnly = false
            end
            local mode
            if not AR.db.enabled then
                mode = "disabled"
            elseif AR.db.notifyOnly then
                mode = "notify-only (chat only)"
            else
                mode = "enabled (will roll)"
            end
            AutoCore.Debug("Roll", "Saved state loaded; mode is " .. mode .. ".")
        end
    elseif event == "START_LOOT_ROLL" then
        activeRolls[arg1] = true
        local activeCfg = GetActiveConfig()
        if arg1 and AR.db.enabled and activeCfg and activeCfg.enabled then
            if not AR.processed[arg1] then
                AR.processed[arg1] = true
                -- notifyOnly = dry-run (chat only); otherwise actually roll
                ProcessRollWhenReady(arg1, AR.db.notifyOnly == true, false)
            end
        end
    elseif event == "CANCEL_LOOT_ROLL" then
        if arg1 then
            AR.processed[arg1] = nil
            activeRolls[arg1] = nil
            committedRolls[arg1] = nil
            -- Do NOT clear AutoCore.pendingRolls here (confirm comes after cancel)
            for i = #rollQueue, 1, -1 do
                if rollQueue[i].rollId == arg1 then
                    table.remove(rollQueue, i)
                end
            end
        end
    end
end)

-- Roll confirmations are handled by AutoBindClear via TrackPendingRoll.
-- LOOT_BIND is intentionally left for the player: globally accepting it
-- could also confirm an unrelated manual bind-on-pickup action.

----------------------------------------------------------------------
-- Helper: Enumerate currently active roll IDs
----------------------------------------------------------------------
local function EnumerateActiveRolls()
    local rolls = {}
    for rollId in pairs(activeRolls) do
        table.insert(rolls, rollId)
    end
    return rolls
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_AUTOROLL1 = "/autoroll"

SlashCmdList["AUTOROLL"] = function(msg)
    msg = string.lower(strtrim(msg or ""))

    if msg == "on" then
        AR.db.enabled = true
        AR.db.notifyOnly = false
        AutoCore.NotifyProfileChanged("roll")
        print("|cff00ff00AutoRoll:|r Auto-roll enabled (will roll).")
    elseif msg == "off" then
        AR.db.enabled = false
        AutoCore.NotifyProfileChanged("roll")
        print("|cff00ff00AutoRoll:|r Auto-roll disabled.")
    elseif msg == "notify on" or msg == "notify" then
        AR.db.enabled = true
        AR.db.notifyOnly = true
        AutoCore.NotifyProfileChanged("roll")
        print("|cff00ff00AutoRoll:|r Notify-only mode enabled (click a suggested action to roll).")
    elseif msg == "notify off" then
        AR.db.notifyOnly = false
        AutoCore.NotifyProfileChanged("roll")
        print("|cff00ff00AutoRoll:|r Notify-only mode disabled.")
        if AR.db.enabled then
            print("  Auto-roll is still on - will roll on matching items.")
        end
    elseif msg == "test" then
        local rolls = EnumerateActiveRolls()
        if #rolls == 0 then
            print("|cff00ff00AutoRoll:|r No active loot rolls found.")
            return
        end
        for _, rollId in ipairs(rolls) do
            ProcessRoll(rollId, true, false)
        end
    elseif msg == "debug" then
        local rolls = EnumerateActiveRolls()
        if #rolls == 0 then
            print("|cff00ff00AutoRoll:|r No active loot rolls found.")
            return
        end
        -- Item info (iLevel, stats, etc.) sometimes has not finished caching
        -- the instant a roll appears, which can make the very first check
        -- look wrong (e.g. an item level of 0). Print an instant check, then
        -- an automatic recheck a second later, so both are visible together
        -- instead of needing to run /autoroll debug twice by hand.
        print("|cff00ff00AutoRoll:|r Instant check:")
        for _, rollId in ipairs(rolls) do
            ProcessRoll(rollId, true, true)
        end
        print("|cff00ff00AutoRoll:|r Instant check complete; rechecking in 1s (item info may still be caching)...")
        After(1.0, function()
            print("|cff00ff00AutoRoll:|r Recheck after 1s:")
            for _, rollId in ipairs(rolls) do
                if activeRolls[rollId] then
                    ProcessRoll(rollId, true, true)
                else
                    print("  Roll " .. tostring(rollId) .. " is no longer active.")
                end
            end
            print("|cff00ff00AutoRoll:|r Debug scan complete.")
        end)
    elseif msg == "whoami" then
        AutoCore.RebuildQuestItems()
        local cfg = GetActiveConfig()
        if not cfg then
            print("|cff00ff00AutoRoll:|r AutoRollConfig not loaded.")
        else
            print("|cff00ff00AutoRoll:|r Character key: " .. cfg.charKey)
            print("  Active rules: " .. #cfg.rules .. " (active profile order)")
            print("  Never-roll entries: " .. #cfg.never)
            print("  Maximum roll quality: " .. tostring(cfg.maxQuality ~= nil and cfg.maxQuality or "none"))
        end
    else
        if not AR.db.enabled then
            print("|cff00ff00AutoRoll:|r Auto-roll disabled.")
        elseif AR.db.notifyOnly then
            print("|cff00ff00AutoRoll:|r Notify-only mode (click a suggested action to roll).")
        else
            print("|cff00ff00AutoRoll:|r Auto-roll enabled (will roll).")
        end
        print("|cff00ff00AutoRoll:|r Commands:")
        print("  /autoroll on         - Enable auto-roll (actually rolls)")
        print("  /autoroll off        - Disable auto-roll")
        print("  /autoroll notify on  - Recommend a roll; click its action to submit")
        print("  /autoroll notify off - Turn off notify-only")
        print("  /autoroll test       - Dry run on current open rolls")
        print("  /autoroll whoami     - Show config profile")
        print("  /autoroll debug      - Debug: full decision path")
    end
end
