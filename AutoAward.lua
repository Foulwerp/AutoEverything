----------------------------------------------------------------------
-- AutoAward.lua
-- Safe master-loot MS/OS roll tracking and assignment.
-- WoW 3.3.5a / Lua 5.1 compatible.
----------------------------------------------------------------------

-- Ascension's LootFrame may omit this stock 3.3.5 constant while its
-- master-loot callback still compares item quality against it.
if MASTER_LOOT_THREHOLD == nil then
    MASTER_LOOT_THREHOLD = 4
end

AutoAward = AutoAward or {}
local AA = AutoAward

local defaults = AutoAwardConfig or {
    autoAward = false,
    rollSeconds = 15,
    graceSeconds = 1,
    tieRollSeconds = 10,
}

local STATE_IDLE = "IDLE"
local STATE_ROLLING = "ROLLING"
local STATE_GRACE = "GRACE"
local STATE_TIE = "TIE_ROLLING"
local STATE_READY = "READY_TO_AWARD"
local STATE_PENDING = "AWARD_PENDING"
local STATE_AWARDED = "AWARDED"
local STATE_CANCELLED = "CANCELLED"
local STATE_FAILED = "FAILED_SAFE"

local LOOT_ASSIGNMENT_TIMEOUT = 5
local BIND_CONFIRM_TIMEOUT = 30
local TRADE_OPEN_TIMEOUT = 5
local TRADE_CLOSE_TIMEOUT = 3

local roundSerial = 0
local lootSessionID = 0
local lootOpen = false
local selectedSlot
local selectedBag
local selectedBagSlot
local frame
local ui = {}
local Theme = AutoCore and AutoCore.UI

local current = {
    id = 0,
    state = STATE_IDLE,
    rollsByPlayer = {},
    rejectedRolls = {},
}
AA.current = current

local function RoundActive()
    return current.state == STATE_ROLLING or current.state == STATE_TIE
        or current.state == STATE_GRACE or current.state == STATE_READY
        or current.state == STATE_PENDING
end

local function Log(message, level)
    if AutoCore and AutoCore.Log then
        AutoCore.Log("Award", message, level)
    else
        local color = level == "error" and "|cffff4040" or (level == "warn" and "|cffffcc00" or "|cff00ff00")
        print(color .. "Award:|r " .. tostring(message))
    end
end

local function Setting(key)
    if AutoCore and AutoCore.GetSetting then
        return AutoCore.GetSetting("award", key, defaults[key])
    end
    return defaults[key]
end

local function SetSetting(key, value)
    if AutoCore and AutoCore.SetSetting then
        AutoCore.SetSetting("award", key, value)
    else
        defaults[key] = value
    end
end

local function NormalizeName(name)
    if not name or name == "" then return nil end
    name = string.gsub(name, "|c%x%x%x%x%x%x%x%x", "")
    name = string.gsub(name, "|r", "")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    return string.lower(name)
end

local function ShortName(name)
    return name and string.gsub(name, "%-.*$", "") or name
end

local function SamePlayer(a, b)
    local na, nb = NormalizeName(a), NormalizeName(b)
    if not na or not nb then return false end
    if na == nb then return true end
    return string.lower(ShortName(a)) == string.lower(ShortName(b))
end

local function GroupChannel()
    if GetNumRaidMembers and (GetNumRaidMembers() or 0) > 0 then
        local canRaidWarn = (IsRaidLeader and IsRaidLeader()) or (IsRaidOfficer and IsRaidOfficer())
        return canRaidWarn and "RAID_WARNING" or "RAID"
    end
    if GetNumPartyMembers and (GetNumPartyMembers() or 0) > 0 then return "PARTY" end
    return nil
end

local function Announce(message)
    local channel = GroupChannel()
    if channel and SendChatMessage then SendChatMessage(message, channel) end
    Log(message)
end

local function Broadcast(message)
    local channel = GroupChannel()
    if channel and SendChatMessage then SendChatMessage(message, channel) end
end

local function GetRoster()
    local byName = {}
    local function Add(name)
        local key = NormalizeName(name)
        if not key then return end
        byName[key] = byName[key] or {}
        table.insert(byName[key], name)
    end

    local raidCount = GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
    if raidCount > 0 then
        for i = 1, raidCount do Add(UnitName("raid" .. i)) end
    else
        Add(UnitName("player"))
        local partyCount = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
        for i = 1, partyCount do Add(UnitName("party" .. i)) end
    end
    return byName
end

local function ResolveRosterName(roster, rolledName)
    local exact = roster[NormalizeName(rolledName)]
    if exact and #exact == 1 then return exact[1] end
    if exact and #exact > 1 then return nil, "ambiguous name" end

    local short = string.lower(ShortName(rolledName or ""))
    local found
    for _, names in pairs(roster) do
        for _, canonical in ipairs(names) do
            if string.lower(ShortName(canonical)) == short then
                if found and found ~= canonical then return nil, "ambiguous name" end
                found = canonical
            end
        end
    end
    if found then return found end
    return nil, "not in group"
end

local function IsCurrentMember(canonical)
    local roster = GetRoster()
    local resolved = ResolveRosterName(roster, canonical)
    return resolved ~= nil
end

local function PlayerIsMasterLooter()
    if not GetLootMethod then return false, "loot API unavailable" end
    local method, partyMaster, raidMaster = GetLootMethod()
    if method ~= "master" then return false, "loot method is not Master Loot" end

    local raidCount = GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
    if raidCount > 0 then
        local index = tonumber(raidMaster)
        if not index or index <= 0 then return false, "master looter is unknown" end
        local unit = "raid" .. index
        if UnitIsUnit then
            local same = UnitIsUnit(unit, "player")
            return same == true or same == 1, "you are not the master looter"
        end
        return SamePlayer(UnitName(unit), UnitName("player")), "you are not the master looter"
    end

    -- In parties, zero designates the player and 1..4 designate party units.
    if tonumber(partyMaster) == 0 then return true end
    local unit = "party" .. tostring(partyMaster or "")
    if UnitIsUnit then
        local same = UnitIsUnit(unit, "player")
        return same == true or same == 1, "you are not the master looter"
    end
    return SamePlayer(UnitName(unit), UnitName("player")), "you are not the master looter"
end

local function LootSlotData(slot)
    if not lootOpen or not slot or not GetLootSlotInfo or not GetLootSlotLink then return nil end
    local texture, name, quantity, quality, locked = GetLootSlotInfo(slot)
    local link = GetLootSlotLink(slot)
    if not link then return nil end
    return {
        slot = slot,
        texture = texture,
        name = name,
        quantity = quantity,
        quality = quality,
        locked = locked,
        link = link,
        itemID = tonumber(string.match(link, "item:([%-]?%d+)")),
    }
end

local function BagSlotData(bag, slot)
    if not GetContainerItemInfo or not GetContainerItemLink or bag == nil or not slot then return nil end
    local texture, quantity, locked, quality = GetContainerItemInfo(bag, slot)
    local link = GetContainerItemLink(bag, slot)
    if not link then return nil end
    return {
        bag = bag,
        slot = slot,
        texture = texture,
        quantity = quantity,
        locked = locked,
        quality = quality,
        link = link,
        itemID = tonumber(string.match(link, "item:([%-]?%d+)")),
    }
end

local function FindBagMatches(itemLink)
    local matches = {}
    if not itemLink or not GetContainerNumSlots then return matches end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local data = BagSlotData(bag, slot)
            if data and data.link == itemLink then table.insert(matches, data) end
        end
    end
    return matches
end

local function FindVerifiedBagItem()
    if current.source ~= "inventory" or not current.itemLink then return nil, nil, "this is not an inventory round" end
    local original = BagSlotData(current.inventoryBag, current.inventorySlot)
    if original and original.link == current.itemLink and original.quantity == current.itemQuantity then
        if original.locked then return nil, nil, "the inventory item is locked" end
        return original.bag, original.slot
    end

    local matches = FindBagMatches(current.itemLink)
    local exact = {}
    for _, data in ipairs(matches) do
        if data.quantity == current.itemQuantity then table.insert(exact, data) end
    end
    if #exact == 1 then
        if exact[1].locked then return nil, nil, "the matching inventory item is locked" end
        current.inventoryBag, current.inventorySlot = exact[1].bag, exact[1].slot
        return exact[1].bag, exact[1].slot
    end
    if #exact > 1 then return nil, nil, "multiple identical inventory items make the source ambiguous" end
    return nil, nil, "the selected item is no longer in your bags"
end

local function FindVerifiedSlot()
    if not current.itemLink or current.lootSessionID ~= lootSessionID or not lootOpen then
        return nil, "the original loot session is no longer open"
    end
    local original = LootSlotData(current.lootSlot)
    if original and original.link == current.itemLink then
        if original.locked then return nil, "the loot slot is locked" end
        if current.itemQuantity and original.quantity ~= current.itemQuantity then
            return nil, "the loot quantity changed"
        end
        return current.lootSlot
    end
    return nil, "the selected loot slot changed or is no longer available"
end

local function VerifyRoundItem()
    if current.source == "inventory" then
        local bag, slot, reason = FindVerifiedBagItem()
        return bag ~= nil and slot ~= nil, reason
    end
    local slot, reason = FindVerifiedSlot()
    return slot ~= nil, reason
end

local function EscapePatternCharacter(character)
    if string.find("^$()%.[]*+-?%", character, 1, true) then return "%" .. character end
    if string.match(character, "%s") then return "%s+" end
    return character
end

local function BuildRollPattern(format)
    if type(format) ~= "string" or format == "" then return nil end
    local output, order, sequential = { "^" }, {}, 0
    local index = 1
    while index <= string.len(format) do
        local character = string.sub(format, index, index)
        if character == "%" then
            if string.sub(format, index + 1, index + 1) == "%" then
                table.insert(output, "%%")
                index = index + 2
            else
                local tail = string.sub(format, index)
                local position, kind = string.match(tail, "^%%(%d+)%$([sd])")
                local consumed
                if position then
                    consumed = 3 + string.len(position)
                    table.insert(order, tonumber(position))
                else
                    kind = string.match(tail, "^%%([sd])")
                    if not kind then return nil end
                    sequential = sequential + 1
                    table.insert(order, sequential)
                    consumed = 2
                end
                table.insert(output, kind == "s" and "(.+)" or "([%-]?%d+)")
                index = index + consumed
            end
        else
            table.insert(output, EscapePatternCharacter(character))
            index = index + 1
        end
    end
    table.insert(output, "$")
    return table.concat(output), order
end

local rollPattern, rollOrder = BuildRollPattern(RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)")

local function ParseRoll(message)
    if not rollPattern then return nil end
    local captures = { string.match(message or "", rollPattern) }
    if #captures ~= 4 then return nil end
    local values = {}
    for captureIndex, argumentIndex in ipairs(rollOrder) do values[argumentIndex] = captures[captureIndex] end
    local result, minimum, maximum = tonumber(values[2]), tonumber(values[3]), tonumber(values[4])
    if not values[1] or not result or not minimum or not maximum then return nil end
    if result < minimum or result > maximum then return nil end
    return values[1], result, minimum, maximum
end
AA.ParseRoll = ParseRoll

local function WinnerFromRolls(rolls)
    local bracket
    for _, entry in pairs(rolls or {}) do
        if entry.bracket == "MS" then bracket = "MS" break end
        if entry.bracket == "OS" then bracket = "OS" end
    end
    if not bracket then return "NO_ROLLS" end

    local best, tied = -1, {}
    for _, entry in pairs(rolls) do
        if entry.bracket == bracket then
            if entry.value > best then
                best, tied = entry.value, { entry }
            elseif entry.value == best then
                table.insert(tied, entry)
            end
        end
    end
    table.sort(tied, function(a, b) return a.normalizedPlayer < b.normalizedPlayer end)
    if #tied > 1 then return "TIE", nil, tied, bracket end
    return "WINNER", tied[1], nil, bracket
end
AA.WinnerFromRolls = WinnerFromRolls

local function Rejected(name, reason)
    table.insert(current.rejectedRolls, { player = name or "?", reason = reason })
    Log((name or "Unknown player") .. " roll rejected: " .. reason .. ".", "warn")
end

local function SetState(state, reason)
    current.state = state
    if reason then current.statusReason = reason end
end

local function CountRolls(bracket)
    local count = 0
    for _, roll in pairs(current.rollsByPlayer or {}) do
        if not bracket or roll.bracket == bracket then count = count + 1 end
    end
    return count
end

local function PredictedWinnerText()
    local result, winner, tied = WinnerFromRolls(current.rollsByPlayer)
    if result == "WINNER" then return winner.player .. " (" .. winner.bracket .. " " .. winner.value .. ")" end
    if result == "TIE" then return "Tie: " .. tostring(#tied) .. " players" end
    return "None"
end

local function RefreshUI()
    if not frame then return end
    local shown = selectedBag ~= nil and BagSlotData(selectedBag, selectedBagSlot)
        or LootSlotData(selectedSlot)
    local activeData = RoundActive() and current.itemLink
        and { link = current.itemLink, texture = current.itemTexture } or shown
    ui.item:SetText(activeData and activeData.link or "")
    ui.icon:SetTexture(activeData and activeData.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    local stateText = tostring(current.state)
    if current.state == STATE_READY and current.awardDeferred then
        stateText = stateText .. " (waiting for combat)"
    end
    ui.state:SetText("State: " .. stateText)
    ui.rolls:SetText(string.format("MS:%2d  OS:%2d  Rejected:%2d",
        CountRolls("MS"), CountRolls("OS"), #(current.rejectedRolls or {})))
    ui.winner:SetText("Leader: " .. PredictedWinnerText())
    ui.award:SetText(current.source == "inventory" and "Trade" or "Award")
    ui.auto:SetChecked(Setting("autoAward"))

    local now = GetTime and GetTime() or 0
    local remaining = current.deadline and math.max(0, current.deadline - now) or 0
    ui.timer:SetText((current.state == STATE_ROLLING or current.state == STATE_TIE or current.state == STATE_GRACE)
        and string.format("%.1fs", remaining) or "")
    local canStart = shown ~= nil and not RoundActive()
    if canStart then ui.start:Enable() else ui.start:Disable() end

    local canStop = current.state == STATE_ROLLING or current.state == STATE_TIE
        or current.state == STATE_GRACE
    if canStop then ui.stop:Enable() else ui.stop:Disable() end
    if Theme and Theme.RefreshButtonTheme then
        ui.start.themeAccentColor = canStart and Theme.Colors.brand or nil
        ui.stop.themeAccentColor = canStop and Theme.Colors.warning or nil
        ui.award.themeAccentColor = current.state == STATE_READY and Theme.Colors.success or nil
        ui.cancel.themeAccentColor = Theme.Colors.danger
        Theme.RefreshButtonTheme(ui.start)
        Theme.RefreshButtonTheme(ui.stop)
        Theme.RefreshButtonTheme(ui.award)
        Theme.RefreshButtonTheme(ui.cancel)
    end
    if current.state == STATE_READY then ui.award:Enable() else ui.award:Disable() end
    if ui.cancel then ui.cancel:Enable() end
end

local function FailSafe(reason, assignmentUncertain)
    SetState(STATE_FAILED, reason)
    current.deadline = nil
    current.awardDeferred = nil
    current.awardDeferredAutomatic = nil
    current.pendingAward = nil
    if CloseDropDownMenus then CloseDropDownMenus() end
    if assignmentUncertain then
        Log(reason .. "; verify the loot before attempting another assignment.", "error")
    else
        Log(reason .. "; no item was assigned.", "error")
    end
    RefreshUI()
end

local function CombatLocked()
    return InCombatLockdown and InCombatLockdown()
end

local function DeferAwardUntilCombatEnds(automatic)
    local wasDeferred = current.awardDeferred
    current.awardAttempted = false
    current.pendingAward = nil
    current.awardDeferred = true
    current.awardDeferredAutomatic = automatic == true
    SetState(STATE_READY)
    if CloseDropDownMenus then CloseDropDownMenus() end
    if not wasDeferred then Log("Award deferred until combat ends.", "warn") end
    RefreshUI()
end

local function CandidateForName(slot, canonical)
    if not GetMasterLootCandidate then return nil, "candidate API unavailable" end
    local found
    for index = 1, 40 do
        -- Ascension's bundled API documents the 3.3.5 one-argument form. The
        -- candidate index is resolved fresh for every assignment attempt.
        local candidate = GetMasterLootCandidate(index)
        if candidate and SamePlayer(candidate, canonical) then
            if found then return nil, "multiple loot candidates match the winner" end
            found = index
        end
    end
    if not found then return nil, "the winner is not an eligible loot candidate" end
    return found
end

local function ActivateMasterLootSlot(slot)
    local data = LootSlotData(slot)
    if not data then return false, "the selected loot slot is no longer available" end
    if not LootSlot then return false, "loot-slot API unavailable" end

    -- ElvUI keeps the slot used by OPEN_MASTER_LOOT_LIST in a private local.
    -- Clicking its visible slot without a modifier updates that context before
    -- calling LootSlot. Stock FrameXML uses the public LootFrame fields below.
    local elvButton = _G["ElvLootSlot" .. slot]
    if elvButton and elvButton.IsShown and elvButton:IsShown() and elvButton.Click then
        elvButton:Click()
        return true
    end

    if LootFrame then
        LootFrame.selectedSlot = slot
        LootFrame.selectedQuality = data.quality
        LootFrame.selectedItemName = data.name
    end
    LootSlot(slot)
    return true
end

local function SubmitPendingLootAward()
    local pending = current.pendingAward
    if current.state ~= STATE_PENDING or not pending or pending.kind ~= "loot-ready" then return end
    if CombatLocked() then
        DeferAwardUntilCombatEnds(pending.automatic)
        return
    end

    local result, winner = WinnerFromRolls(current.rollsByPlayer)
    if result ~= "WINNER" or not winner or not current.winner
        or winner.normalizedPlayer ~= current.winner.normalizedPlayer
        or not SamePlayer(winner.player, pending.winner)
    then
        FailSafe("the winner changed before final assignment")
        return
    end
    if not IsCurrentMember(winner.player) then FailSafe("the winner left the group before final assignment"); return end

    local isMaster, reason = PlayerIsMasterLooter()
    if not isMaster then FailSafe(reason); return end
    local slot
    slot, reason = FindVerifiedSlot()
    if not slot or slot ~= pending.slot or pending.sessionID ~= lootSessionID then
        FailSafe(reason or "the prepared loot slot changed")
        return
    end

    local slotData = LootSlotData(slot)
    local threshold = GetLootThreshold and tonumber(GetLootThreshold()) or nil
    local quality = slotData and tonumber(slotData.quality) or nil
    if not threshold or not quality then FailSafe("the Master Loot threshold could not be reverified"); return end
    if quality < threshold then FailSafe("the item fell below the Master Loot threshold"); return end
    if not GiveMasterLoot then FailSafe("assignment API became unavailable"); return end

    local candidate
    candidate, reason = CandidateForName(slot, winner.player)
    if not candidate then FailSafe(reason); return end
    pending.candidate = candidate
    pending.kind = "loot"
    pending.startedAt = GetTime()
    GiveMasterLoot(slot, candidate)
    if CloseDropDownMenus then CloseDropDownMenus() end
end

local function GroupUnitForName(name)
    if SamePlayer(UnitName("player"), name) then return "player" end
    for i = 1, (GetNumRaidMembers and GetNumRaidMembers() or 0) do
        if SamePlayer(UnitName("raid" .. i), name) then return "raid" .. i end
    end
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        if SamePlayer(UnitName("party" .. i), name) then return "party" .. i end
    end
    return nil
end

local function CurrentTradePartner()
    local name = UnitName and UnitName("NPC") or nil
    if name and name ~= "" then return name end
    if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
        name = TradeFrameRecipientNameText:GetText()
        if name then return string.match(name, "^([^%s%(]+)") or name end
    end
    return nil
end

local function TradeContainsItem(itemLink)
    if not GetTradePlayerItemLink then return false end
    for tradeSlot = 1, (MAX_TRADE_ITEMS or MAX_TRADABLE_ITEMS or 6) do
        if GetTradePlayerItemLink(tradeSlot) == itemLink then return true, tradeSlot end
    end
    return false
end

local function PlacePendingTradeItem()
    local pending = current.pendingAward
    if current.state ~= STATE_PENDING or not pending or pending.kind ~= "trade" or pending.tradePlacementAttempted then return end
    local partner = CurrentTradePartner()
    if not partner or not SamePlayer(partner, pending.winner) then
        FailSafe("the trade opened with someone other than the winner")
        return
    end
    local bag, bagSlot, reason = FindVerifiedBagItem()
    if bag == nil or not bagSlot then FailSafe(reason); return end
    if not PickupContainerItem or not ClickTradeButton then FailSafe("trade placement API unavailable"); return end

    local emptySlot
    for tradeSlot = 1, (MAX_TRADE_ITEMS or MAX_TRADABLE_ITEMS or 6) do
        if not GetTradePlayerItemLink or not GetTradePlayerItemLink(tradeSlot) then emptySlot = tradeSlot break end
    end
    if not emptySlot then FailSafe("there is no empty trade slot"); return end
    if CursorHasItem and CursorHasItem() then FailSafe("clear the cursor before trading the item"); return end

    pending.tradePlacementAttempted = true
    PickupContainerItem(bag, bagSlot)
    if CursorHasItem and not CursorHasItem() then FailSafe("the inventory item could not be picked up for trade"); return end
    ClickTradeButton(emptySlot)
    if CursorHasItem and CursorHasItem() then
        if ClearCursor then ClearCursor() end
        FailSafe("the inventory item could not be placed in the trade window")
        return
    end
    pending.tradeSlot = emptySlot
    pending.tradePlaced = true
    pending.tradeCheckAt = GetTime() + 0.1
    Log("Placed the winner's item in the trade window; review it and accept manually.")
    RefreshUI()
end

local function CompletePendingTrade(message1, message2)
    local pending = current.pendingAward
    if current.state ~= STATE_PENDING or not pending or pending.kind ~= "trade" or not pending.tradePlaced then return false end
    if not ERR_TRADE_COMPLETE or (message1 ~= ERR_TRADE_COMPLETE and message2 ~= ERR_TRADE_COMPLETE) then return false end

    SetState(STATE_AWARDED)
    current.pendingAward = nil
    Announce("Gave " .. pending.itemLink .. " to " .. pending.winner .. ".")
    if frame then frame:Hide() end
    RefreshUI()
    return true
end

local function BeginTieRound(tied, bracket)
    current.tieRound = (current.tieRound or 0) + 1
    if current.tieRound > 3 then
        FailSafe("three tie rerolls ended without a unique winner")
        return
    end
    local allowed, names = {}, {}
    for _, entry in ipairs(tied) do
        allowed[entry.normalizedPlayer] = true
        table.insert(names, entry.player)
    end
    current.allowedTiePlayers = allowed
    current.requiredTieBracket = bracket
    current.rollsByPlayer = {}
    current.rejectedRolls = {}
    roundSerial = roundSerial + 1
    current.id = roundSerial
    current.deadline = GetTime() + math.max(1, tonumber(Setting("tieRollSeconds")) or 10)
    current.lastCountdown = nil
    SetState(STATE_TIE)
    Announce("Tie between " .. table.concat(names, ", ") .. ". Tied players reroll " .. (bracket == "MS" and "/roll 100" or "/roll 99") .. ".")
    RefreshUI()
end

local function ResolveRound()
    if current.state ~= STATE_GRACE and current.state ~= STATE_ROLLING and current.state ~= STATE_TIE then return end
    local reason
    if current.source == "inventory" then
        local bag, bagSlot
        bag, bagSlot, reason = FindVerifiedBagItem()
        if bag == nil or not bagSlot then FailSafe(reason); return end
        current.verifiedBag, current.verifiedBagSlot = bag, bagSlot
    else
        local slot
        slot, reason = FindVerifiedSlot()
        if not slot then FailSafe(reason); return end
        current.verifiedSlot = slot
    end

    local result, winner, tied, bracket = WinnerFromRolls(current.rollsByPlayer)
    if result == "NO_ROLLS" then FailSafe("no valid rolls were received"); return end
    if result == "TIE" then BeginTieRound(tied, bracket); return end
    current.winner = winner
    current.deadline = nil
    SetState(STATE_READY)
    Announce(winner.player .. " has won " .. current.itemLink .. " with a roll of " .. winner.value .. ".")
    RefreshUI()
    if Setting("autoAward") then AA.Award(true) end
end

local function BeginGrace()
    if current.state ~= STATE_ROLLING and current.state ~= STATE_TIE then return end
    local grace = math.max(0, math.min(1, tonumber(Setting("graceSeconds")) or 1))
    Broadcast("Rolling ended.")
    SetState(STATE_GRACE)
    current.deadline = GetTime() + grace
    if grace == 0 then ResolveRound() end
    RefreshUI()
end

local function UpdateRollCountdown(now)
    if current.state ~= STATE_ROLLING and current.state ~= STATE_TIE then return end
    if not current.deadline then return end
    local remaining = current.deadline - now
    if remaining <= 0 then return end
    local count = math.ceil(remaining)
    if count >= 1 and count <= 5 and current.lastCountdown ~= count then
        current.lastCountdown = count
        Broadcast("Rolling ends in " .. count .. ".")
    end
end

function AA.Start(slot)
    slot = tonumber(slot or selectedSlot)
    if RoundActive() then
        Log("Finish or cancel the current round first.", "warn")
        return false
    end
    local isMaster, reason = PlayerIsMasterLooter()
    if not isMaster then FailSafe(reason); return false end
    local data = LootSlotData(slot)
    if not data then FailSafe("select an item slot in the open loot window"); return false end
    if data.locked then FailSafe("the selected loot slot is locked"); return false end

    roundSerial = roundSerial + 1
    current = {
        id = roundSerial,
        state = STATE_ROLLING,
        source = "loot",
        lootSessionID = lootSessionID,
        lootSlot = slot,
        itemID = data.itemID,
        itemLink = data.link,
        itemTexture = data.texture,
        itemQuantity = data.quantity,
        deadline = GetTime() + math.max(1, tonumber(Setting("rollSeconds")) or 15),
        rosterAtStart = GetRoster(),
        rollsByPlayer = {},
        rejectedRolls = {},
        tieRound = 0,
        awardAttempted = false,
    }
    AA.current = current
    selectedSlot = slot
    Announce("Roll for " .. data.link .. ": MS /roll 100, OS /roll 99.")
    if frame then frame:Show() end
    RefreshUI()
    return true
end

function AA.StartInventory(bag, slot)
    bag, slot = tonumber(bag), tonumber(slot)
    if RoundActive() then
        Log("Finish or cancel the current round first.", "warn")
        return false
    end
    local isMaster, reason = PlayerIsMasterLooter()
    if not isMaster then FailSafe(reason); return false end
    local raidCount = GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
    local partyCount = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
    if raidCount == 0 and partyCount == 0 then FailSafe("inventory rolls require a party or raid"); return false end
    local data = BagSlotData(bag, slot)
    if not data then FailSafe("select an item in your bags"); return false end
    if data.locked then FailSafe("the selected inventory item is locked"); return false end

    roundSerial = roundSerial + 1
    current = {
        id = roundSerial,
        state = STATE_ROLLING,
        source = "inventory",
        inventoryBag = bag,
        inventorySlot = slot,
        itemID = data.itemID,
        itemLink = data.link,
        itemTexture = data.texture,
        itemQuantity = data.quantity,
        deadline = GetTime() + math.max(1, tonumber(Setting("rollSeconds")) or 15),
        rosterAtStart = GetRoster(),
        rollsByPlayer = {},
        rejectedRolls = {},
        tieRound = 0,
        awardAttempted = false,
    }
    AA.current = current
    Announce("Roll for " .. data.link .. ": MS /roll 100, OS /roll 99.")
    if frame then frame:Show() end
    RefreshUI()
    return true
end

function AA.StartSelected()
    if selectedBag ~= nil and selectedBagSlot then
        return AA.StartInventory(selectedBag, selectedBagSlot)
    end
    return AA.Start()
end

function AA.Stop()
    if current.state ~= STATE_ROLLING and current.state ~= STATE_TIE and current.state ~= STATE_GRACE then
        Log("There is no active roll to stop.", "warn")
        return
    end
    ResolveRound()
end

function AA.Cancel(reason)
    if current.state == STATE_IDLE or current.state == STATE_AWARDED
        or current.state == STATE_CANCELLED or current.state == STATE_FAILED
    then
        if frame then frame:Hide() end
        return
    end
    if not reason and current.state == STATE_PENDING then
        if frame then frame:Hide() end
        Log("Window closed; the assignment remains in progress.", "warn")
        return
    end
    local cancelledItem = current.itemLink
    SetState(STATE_CANCELLED, reason or "cancelled by user")
    current.deadline = nil
    current.pendingAward = nil
    current.awardDeferred = nil
    current.awardDeferredAutomatic = nil
    current.winner = nil
    current.rollsByPlayer = {}
    current.rejectedRolls = {}
    current.allowedTiePlayers = nil
    current.requiredTieBracket = nil
    local message = cancelledItem and ("Roll canceled for " .. cancelledItem) or "Roll canceled"
    if reason then message = message .. ": " .. reason end
    Announce(message .. ".")
    if frame then frame:Hide() end
    RefreshUI()
end

function AA.Clear(name)
    if current.state ~= STATE_ROLLING and current.state ~= STATE_TIE then
        Log("Rolls can only be cleared before the timer expires.", "warn")
        return
    end
    local canonical = ResolveRosterName(current.rosterAtStart, name)
    local key = canonical and NormalizeName(canonical) or NormalizeName(name)
    if key and current.rollsByPlayer[key] then
        current.rollsByPlayer[key] = nil
        Log("Cleared " .. tostring(canonical or name) .. "'s roll.", "warn")
    else
        Log("No accepted roll matched " .. tostring(name) .. ".", "warn")
    end
    RefreshUI()
end

function AA.Award(automatic)
    automatic = automatic == true
    if current.state ~= STATE_READY or current.awardAttempted then
        Log("No validated winner is ready to receive the item.", "warn")
        return false
    end
    if CombatLocked() then
        DeferAwardUntilCombatEnds(automatic)
        return true
    end
    current.awardDeferred = nil
    current.awardDeferredAutomatic = nil
    local result, winner = WinnerFromRolls(current.rollsByPlayer)
    if result ~= "WINNER" or not winner or not current.winner or winner.normalizedPlayer ~= current.winner.normalizedPlayer then
        FailSafe("the winner changed during final validation")
        return false
    end
    if not IsCurrentMember(winner.player) then FailSafe("the winner is no longer in the group"); return false end

    if current.source == "inventory" then
        local bag, bagSlot, reason = FindVerifiedBagItem()
        if bag == nil or not bagSlot then FailSafe(reason); return false end
        if SamePlayer(winner.player, UnitName("player")) then
            current.awardAttempted = true
            SetState(STATE_AWARDED)
            Log("You won; the item remains in your inventory.")
            if frame then frame:Hide() end
            RefreshUI()
            return true
        end
        local unit = GroupUnitForName(winner.player)
        if not unit then FailSafe("the winner has no current group unit"); return false end
        if not InitiateTrade then FailSafe("trade API unavailable"); return false end

        current.awardAttempted = true
        current.pendingAward = {
            kind = "trade",
            bag = bag,
            bagSlot = bagSlot,
            itemLink = current.itemLink,
            winner = winner.player,
            automatic = automatic,
            startedAt = GetTime(),
        }
        SetState(STATE_PENDING)
        RefreshUI()
        InitiateTrade(unit, winner.player)
        return true
    end

    local isMaster, reason = PlayerIsMasterLooter()
    if not isMaster then FailSafe(reason); return false end
    local slot
    slot, reason = FindVerifiedSlot()
    if not slot then FailSafe(reason); return false end
    local slotData = LootSlotData(slot)
    local threshold = GetLootThreshold and tonumber(GetLootThreshold()) or nil
    local quality = slotData and tonumber(slotData.quality) or nil
    if not threshold or not quality then
        FailSafe("the Master Loot threshold could not be verified")
        return false
    end
    if quality < threshold then
        FailSafe("the item is below the Master Loot threshold")
        return false
    end
    if not GiveMasterLoot then FailSafe("assignment API unavailable"); return false end

    current.awardAttempted = true
    current.pendingAward = {
        kind = "loot-context",
        sessionID = lootSessionID,
        slot = slot,
        itemLink = current.itemLink,
        winner = winner.player,
        automatic = automatic,
        startedAt = GetTime(),
    }
    SetState(STATE_PENDING)
    RefreshUI()
    local activated, activationReason = ActivateMasterLootSlot(slot)
    if not activated then FailSafe(activationReason); return false end
    return true
end

local function AcceptRoll(message)
    if current.state ~= STATE_ROLLING and current.state ~= STATE_TIE and current.state ~= STATE_GRACE then return end
    if not current.deadline or GetTime() > current.deadline then return end
    local rolledName, value, minimum, maximum = ParseRoll(message)
    if not rolledName then return end
    local itemValid, activeReason = VerifyRoundItem()
    if not itemValid then FailSafe(activeReason); return end

    local bracket
    if minimum == 1 and maximum == 100 then bracket = "MS"
    elseif minimum == 1 and maximum == 99 then bracket = "OS"
    else Rejected(rolledName, "unsupported range " .. minimum .. "-" .. maximum); return end

    local canonical, reason = ResolveRosterName(current.rosterAtStart, rolledName)
    if not canonical then Rejected(rolledName, reason); return end
    if not IsCurrentMember(canonical) then Rejected(canonical, "no longer in the group"); return end
    local key = NormalizeName(canonical)
    if current.allowedTiePlayers and not current.allowedTiePlayers[key] then Rejected(canonical, "not eligible for this tie reroll"); return end
    if current.requiredTieBracket and bracket ~= current.requiredTieBracket then Rejected(canonical, "wrong tie-reroll bracket"); return end
    if current.rollsByPlayer[key] then Rejected(canonical, "duplicate roll"); return end

    current.rollsByPlayer[key] = {
        player = canonical,
        normalizedPlayer = key,
        value = value,
        minimum = minimum,
        maximum = maximum,
        bracket = bracket,
        receivedAt = GetTime(),
    }
    Log(canonical .. ": " .. bracket .. " " .. value .. ".")
    RefreshUI()
end

local function BagPositionFromMouseFocus(itemLink)
    local focus = GetMouseFocus and GetMouseFocus() or nil
    if not focus then return nil end
    local bag = tonumber(focus.bagID)
    local slot = tonumber(focus.slotID)
    if bag == nil or not slot then
        local parent = focus.GetParent and focus:GetParent() or nil
        local name = focus.GetName and focus:GetName() or ""
        local parentName = parent and parent.GetName and parent:GetName() or ""
        if string.find(name or "", "ContainerFrame", 1, true)
            or string.find(parentName or "", "ContainerFrame", 1, true)
        then
            bag = parent and parent.GetID and tonumber(parent:GetID()) or nil
            slot = focus.GetID and tonumber(focus:GetID()) or nil
        end
    end
    local data = BagSlotData(bag, slot)
    if data and data.link == itemLink then return bag, slot end
    return nil
end

local function LootSlotFromMouseFocus(itemLink)
    if not lootOpen then return nil end
    local focus = GetMouseFocus and GetMouseFocus() or nil
    if not focus then return nil end
    local name = focus.GetName and focus:GetName() or ""
    local slot = tonumber(focus.slot)
    if not slot and (string.find(name or "", "Loot", 1, true)) then
        slot = focus.GetID and tonumber(focus:GetID()) or nil
    end
    local data = LootSlotData(slot)
    if data and data.link == itemLink then return slot end
    return nil
end

local function StartFromItemLink(itemLink)
    if not itemLink then return end
    if RoundActive() then
        Log("Finish or cancel the current round before selecting another item.", "warn")
        return
    end
    local isMaster, reason = PlayerIsMasterLooter()
    if not isMaster then
        Log("Master Loot Awards is only available to the current master looter: " .. reason .. ".", "warn")
        return
    end

    local function ShowSelection()
        if frame then frame:Show() end
        RefreshUI()
    end

    local bag, bagSlot = BagPositionFromMouseFocus(itemLink)
    if bag ~= nil and bagSlot then
        selectedSlot, selectedBag, selectedBagSlot = nil, bag, bagSlot
        ShowSelection()
        return
    end

    local lootSlot = LootSlotFromMouseFocus(itemLink)
    if lootSlot then
        selectedSlot, selectedBag, selectedBagSlot = lootSlot, nil, nil
        ShowSelection()
        return
    end

    local lootMatches = {}
    if lootOpen then
        for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
            local data = LootSlotData(slot)
            if data and data.link == itemLink then table.insert(lootMatches, slot) end
        end
    end
    local bagMatches = FindBagMatches(itemLink)
    if #lootMatches == 1 and #bagMatches == 0 then
        selectedSlot, selectedBag, selectedBagSlot = lootMatches[1], nil, nil
        ShowSelection()
    elseif #bagMatches == 1 and #lootMatches == 0 then
        selectedSlot, selectedBag, selectedBagSlot = nil, bagMatches[1].bag, bagMatches[1].slot
        ShowSelection()
    elseif #lootMatches + #bagMatches > 1 then
        Log("That item exists in multiple locations; Alt-click its exact loot or bag slot.", "warn")
    else
        Log("Alt-click an item in the open loot window or your bags to select it.", "warn")
    end
end

local function MakeButton(parent, text, width, callback, accentColor)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetWidth(width)
    button:SetHeight(22)
    button:SetText(text)
    button:SetScript("OnClick", callback)
    if Theme and Theme.SkinButton then Theme.SkinButton(button, accentColor) end
    return button
end

local function AddTooltip(object, title, body)
    object:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 0.82, 0)
        GameTooltip:AddLine(body, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    object:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function CreateWindow()
    frame = CreateFrame("Frame", "AutoEverythingAwardFrame", UIParent)
    frame:SetWidth(370)
    frame:SetHeight(118)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if Theme and Theme.ModalSurface then Theme.ModalSurface(frame) end
    if frame.themeHeader then frame.themeHeader:SetHeight(28) end
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -4)
    title:SetText("Master Loot Awards")
    if Theme then Theme.ApplyFont(title, 16); title:SetTextColor(Theme.Unpack(Theme.Colors.text)) end
    ui.state = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.state:SetPoint("TOPLEFT", 18, -33)
    if Theme then Theme.ApplyFont(ui.state, 11); ui.state:SetTextColor(Theme.Unpack(Theme.Colors.textMuted)) end
    ui.timer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.timer:SetPoint("TOP", 0, -33)
    if Theme then Theme.ApplyFont(ui.timer, 12); ui.timer:SetTextColor(Theme.Unpack(Theme.Colors.brand)) end

    local iconFrame = CreateFrame("Frame", nil, frame)
    iconFrame:SetSize(36, 36); iconFrame:SetPoint("TOPLEFT", 18, -47)
    if Theme then Theme.Backdrop(iconFrame, Theme.Colors.surface, 1) end
    ui.icon = iconFrame:CreateTexture(nil, "ARTWORK")
    ui.icon:SetPoint("TOPLEFT", 2, -2); ui.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    ui.item = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.item:SetPoint("TOPLEFT", 18, -84); ui.item:SetWidth(334); ui.item:SetHeight(14); ui.item:SetJustifyH("LEFT")
    if Theme then Theme.ApplyFont(ui.item, 12) end
    ui.rolls = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.rolls:SetPoint("TOPRIGHT", -18, -98); ui.rolls:SetWidth(150); ui.rolls:SetJustifyH("RIGHT")
    if Theme then Theme.ApplyFont(ui.rolls, 11); ui.rolls:SetTextColor(Theme.Unpack(Theme.Colors.textMuted)) end
    ui.winner = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.winner:SetPoint("TOPLEFT", 18, -98); ui.winner:SetWidth(180); ui.winner:SetJustifyH("LEFT")
    if Theme then Theme.ApplyFont(ui.winner, 11); ui.winner:SetTextColor(Theme.Unpack(Theme.Colors.text)) end

    local actionWidth = 69
    local actionGap = 4
    ui.start = MakeButton(frame, "Start", actionWidth, function() AA.StartSelected() end, Theme and Theme.Colors.brand)
    ui.start:SetPoint("LEFT", iconFrame, "RIGHT", 10, 0)
    AddTooltip(ui.start, "Start roll", "Snapshots the current group and starts MS /roll 100 and OS /roll 99 tracking for the selected item.")
    ui.stop = MakeButton(frame, "Stop", actionWidth, function() AA.Stop() end)
    ui.stop:SetPoint("LEFT", ui.start, "RIGHT", actionGap, 0)
    AddTooltip(ui.stop, "Stop roll", "Ends the timer now and resolves the accepted rolls.")
    ui.award = MakeButton(frame, "Award", actionWidth, function() AA.Award() end, Theme and Theme.Colors.success)
    ui.award:SetPoint("LEFT", ui.stop, "RIGHT", actionGap, 0)
    AddTooltip(ui.award, "Validated handoff", "Loot slots are assigned through Master Loot. Bag items open a trade to the winner and place the exact item for your manual confirmation.")
    ui.cancel = MakeButton(frame, "Cancel", actionWidth, function() AA.Cancel() end, Theme and Theme.Colors.danger)
    ui.cancel:SetPoint("LEFT", ui.award, "RIGHT", actionGap, 0)
    AddTooltip(ui.cancel, "Cancel", "Cancels an active roll and closes this window. If assignment has already begun, it only closes the window.")
    ui.auto = Theme.CreateToggle(frame, "Auto Award", Setting("autoAward"), function(enabled)
        SetSetting("autoAward", enabled)
        if not enabled and current.awardDeferred and current.awardDeferredAutomatic then
            current.awardDeferred = nil
            current.awardDeferredAutomatic = nil
            Log("Deferred automatic assignment canceled; use Award manually when ready.", "warn")
        end
        RefreshUI()
    end)
    ui.auto:SetPoint("TOPLEFT", 254, -30)
    AddTooltip(ui.auto, "Automatic assignment", "Off by default. When armed, a unique validated winner is assigned after the timer and grace period. Ambiguity always stops safely.")
    RefreshUI()
end

local function ShowWindowIfMaster(reportFailure)
    if not frame then return false end
    local isMaster, reason = PlayerIsMasterLooter()
    if not isMaster then
        frame:Hide()
        if reportFailure then Log("Master Loot Awards is only available to the current master looter: " .. reason .. ".", "warn") end
        return false
    end
    frame:Show()
    RefreshUI()
    return true
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("LOOT_SLOT_CLEARED")
eventFrame:RegisterEvent("LOOT_SLOT_CHANGED")
eventFrame:RegisterEvent("OPEN_MASTER_LOOT_LIST")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("UI_ERROR_MESSAGE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("LOOT_BIND_CONFIRM")
eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("TRADE_CLOSED")
eventFrame:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
eventFrame:RegisterEvent("UI_INFO_MESSAGE")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == "AutoEverything" then
        CreateWindow()
        if hooksecurefunc and HandleModifiedItemClick then
            hooksecurefunc("HandleModifiedItemClick", function(itemLink)
                local mouseButton = GetMouseButtonClicked and GetMouseButtonClicked() or nil
                if IsAltKeyDown and IsAltKeyDown()
                    and not (IsShiftKeyDown and IsShiftKeyDown())
                    and not (IsControlKeyDown and IsControlKeyDown())
                    and (not mouseButton or mouseButton == "LeftButton")
                then
                    StartFromItemLink(itemLink)
                end
            end)
        end
    elseif event == "LOOT_OPENED" then
        lootSessionID = lootSessionID + 1
        lootOpen = true
        selectedSlot = nil
    elseif event == "LOOT_CLOSED" then
        lootOpen = false
        selectedSlot = nil
        if current.source ~= "inventory" then
            if current.state == STATE_PENDING then
                local submitted = current.pendingAward and current.pendingAward.kind == "loot"
                FailSafe("loot closed before assignment was confirmed", submitted)
            elseif current.state == STATE_ROLLING or current.state == STATE_TIE or current.state == STATE_GRACE or current.state == STATE_READY then
                AA.Cancel("loot window closed")
            end
            if frame then frame:Hide() end
        end
    elseif event == "OPEN_MASTER_LOOT_LIST" and current.state == STATE_PENDING and current.pendingAward
        and current.pendingAward.kind == "loot-context"
    then
        local pending = current.pendingAward
        local slot, reason = FindVerifiedSlot()
        if not slot or slot ~= pending.slot or pending.sessionID ~= lootSessionID then
            FailSafe(reason or "the prepared loot slot changed")
            return
        end
        local candidate
        candidate, reason = CandidateForName(slot, pending.winner)
        if not candidate then FailSafe(reason); return end
        pending.kind = "loot-ready"
        pending.candidate = candidate
        pending.startedAt = GetTime()
    elseif event == "CHAT_MSG_SYSTEM" then
        if not CompletePendingTrade(arg1, arg2) then AcceptRoll(arg1) end
    elseif event == "LOOT_SLOT_CLEARED" and current.state == STATE_PENDING and current.pendingAward
        and current.pendingAward.kind == "loot"
    then
        if tonumber(arg1) == current.pendingAward.slot then
            SetState(STATE_AWARDED)
            current.pendingAward = nil
            Log("Item assignment confirmed.")
            if frame then frame:Hide() end
            RefreshUI()
        end
    elseif event == "LOOT_SLOT_CLEARED" and current.state == STATE_PENDING and current.pendingAward
        and (current.pendingAward.kind == "loot-context" or current.pendingAward.kind == "loot-ready")
        and tonumber(arg1) == current.pendingAward.slot
    then
        FailSafe("the loot slot cleared while preparing the assignment")
    elseif event == "LOOT_SLOT_CLEARED" and current.source == "loot"
        and (current.state == STATE_ROLLING or current.state == STATE_TIE
            or current.state == STATE_GRACE or current.state == STATE_READY)
        and tonumber(arg1) == current.lootSlot
    then
        AA.Cancel("the selected loot slot cleared before assignment")
    elseif event == "UI_ERROR_MESSAGE" and current.state == STATE_PENDING and current.pendingAward then
        -- Combat and unrelated raid actions can emit UI errors during the
        -- assignment window. Preserve the message for timeout diagnostics,
        -- but trust only loot/trade state changes as confirmation or failure.
        current.pendingAward.lastError = tostring(arg1 or arg2 or "unknown error")
    elseif event == "LOOT_SLOT_CHANGED" then
        RefreshUI()
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "PARTY_LOOT_METHOD_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        local isMaster = PlayerIsMasterLooter()
        if not isMaster then
            if frame then frame:Hide() end
            local tradeInProgress = current.state == STATE_PENDING and current.pendingAward
                and current.pendingAward.kind == "trade"
            if not tradeInProgress and current.state ~= STATE_IDLE and current.state ~= STATE_AWARDED
                and current.state ~= STATE_CANCELLED and current.state ~= STATE_FAILED
            then
                local submitted = current.state == STATE_PENDING and current.pendingAward
                    and current.pendingAward.kind == "loot"
                if submitted then FailSafe("you stopped being the master looter before assignment confirmation", true)
                else AA.Cancel("you are no longer the master looter") end
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if current.state ~= STATE_IDLE and current.state ~= STATE_AWARDED then
            local submitted = current.state == STATE_PENDING and current.pendingAward
                and current.pendingAward.kind == "loot"
            if submitted then FailSafe("world changed before assignment confirmation", true)
            else AA.Cancel("world changed") end
        end
        local isMaster = PlayerIsMasterLooter()
        if frame and not isMaster then frame:Hide() end
    elseif event == "PLAYER_REGEN_DISABLED" and current.state == STATE_PENDING and current.pendingAward
        and (current.pendingAward.kind == "loot-context" or current.pendingAward.kind == "loot-ready"
            or (current.pendingAward.kind == "trade" and not current.pendingAward.tradeShown))
    then
        DeferAwardUntilCombatEnds(current.pendingAward.automatic)
    elseif event == "PLAYER_REGEN_ENABLED" and current.state == STATE_READY and current.awardDeferred then
        local automatic = current.awardDeferredAutomatic
        current.awardDeferred = nil
        current.awardDeferredAutomatic = nil
        if automatic and not Setting("autoAward") then
            Log("Automatic assignment is off; use Award manually when ready.", "warn")
            RefreshUI()
        else
            AA.Award(automatic)
        end
    elseif event == "LOOT_BIND_CONFIRM" and current.state == STATE_PENDING and current.pendingAward
        and current.pendingAward.kind == "loot" and tonumber(arg1) == current.pendingAward.slot
    then
        current.pendingAward.awaitingBindConfirmation = true
        current.pendingAward.startedAt = GetTime()
        Log("Bind confirmation requires a manual click until target-server behavior is verified.", "warn")
    elseif event == "TRADE_SHOW" and current.state == STATE_PENDING and current.pendingAward
        and current.pendingAward.kind == "trade"
    then
        current.pendingAward.tradeShown = true
        current.pendingAward.tradePlaceAt = GetTime() + 0.1
    elseif event == "TRADE_CLOSED" and current.state == STATE_PENDING and current.pendingAward
        and current.pendingAward.kind == "trade"
    then
        current.pendingAward.tradeClosedAt = GetTime()
    elseif event == "TRADE_PLAYER_ITEM_CHANGED" and current.state == STATE_PENDING and current.pendingAward
        and current.pendingAward.kind == "trade" and current.pendingAward.tradePlaced
    then
        current.pendingAward.tradeCheckAt = GetTime() + 0.1
    elseif event == "UI_INFO_MESSAGE" then
        CompletePendingTrade(arg1, arg2)
    end
end)

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if frame and frame:IsShown() then RefreshUI() end
    local now = GetTime()
    UpdateRollCountdown(now)
    if (current.state == STATE_ROLLING or current.state == STATE_TIE) and current.deadline and now >= current.deadline then
        BeginGrace()
    elseif current.state == STATE_GRACE and current.deadline and now >= current.deadline then
        ResolveRound()
    elseif current.state == STATE_PENDING and current.pendingAward and current.pendingAward.kind == "loot-ready" then
        SubmitPendingLootAward()
    elseif current.state == STATE_PENDING and current.pendingAward and current.pendingAward.kind == "trade" then
        if not current.pendingAward.tradeShown and GetTime() - current.pendingAward.startedAt >= TRADE_OPEN_TIMEOUT then
            FailSafe("the trade window did not open for the winner")
        elseif current.pendingAward.tradePlaceAt and GetTime() >= current.pendingAward.tradePlaceAt then
            current.pendingAward.tradePlaceAt = nil
            PlacePendingTradeItem()
        elseif current.pendingAward.tradeCheckAt and GetTime() >= current.pendingAward.tradeCheckAt then
            current.pendingAward.tradeCheckAt = nil
            local present = TradeContainsItem(current.pendingAward.itemLink)
            if TradeFrame and TradeFrame:IsShown() and not present then
                FailSafe("the awarded item was removed from the trade window")
            end
        elseif current.pendingAward.tradeClosedAt and GetTime() - current.pendingAward.tradeClosedAt >= TRADE_CLOSE_TIMEOUT then
            local bag, bagSlot, bagReason = FindVerifiedBagItem()
            local errorDetail = current.pendingAward.lastError and ("; last error: " .. current.pendingAward.lastError) or ""
            if bag ~= nil and bagSlot then
                FailSafe("the trade closed without a success confirmation" .. errorDetail)
            else
                FailSafe("the trade closed and the item could not be reverified"
                    .. (bagReason and (": " .. bagReason) or "") .. errorDetail, true)
            end
        end
    elseif current.state == STATE_PENDING and current.pendingAward
        and GetTime() - current.pendingAward.startedAt
            >= (current.pendingAward.awaitingBindConfirmation and BIND_CONFIRM_TIMEOUT or LOOT_ASSIGNMENT_TIMEOUT)
    then
        local submitted = current.pendingAward.kind == "loot"
        local slot = current.pendingAward.slot
        local data = LootSlotData(slot)
        local errorDetail = current.pendingAward.lastError and ("; last error: " .. current.pendingAward.lastError) or ""
        if data and data.link == current.pendingAward.itemLink then
            FailSafe("assignment timed out and the item still appears in the loot slot" .. errorDetail, submitted)
        else
            FailSafe("assignment result is uncertain because no success event arrived" .. errorDetail, true)
        end
    end
end)

SLASH_AUTOEVERYTHINGAWARD1 = "/aa"
SLASH_AUTOEVERYTHINGAWARD2 = "/autoaward"
SlashCmdList["AUTOEVERYTHINGAWARD"] = function(message)
    local command, argument = string.match(strtrim(message or ""), "^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    if command == "" then
        if not frame then return end
        if frame:IsShown() then frame:Hide() else ShowWindowIfMaster(true) end
    elseif command == "start" then AA.Start(argument ~= "" and argument or nil)
    elseif command == "stop" then AA.Stop()
    elseif command == "cancel" then AA.Cancel()
    elseif command == "award" then AA.Award()
    elseif command == "clear" and argument ~= "" then AA.Clear(argument)
    elseif command == "status" then
        local source = current.source == "inventory"
            and ("bag " .. tostring(current.inventoryBag) .. ":" .. tostring(current.inventorySlot))
            or ("loot slot " .. tostring(selectedSlot or "none"))
        Log("State " .. current.state .. ", source " .. source
            .. ", auto award " .. (Setting("autoAward") and "ON" or "OFF") .. ".")
        if current.statusReason then Log(current.statusReason, "warn") end
    else
        Log("Alt-click loot or a bag item to select it, then press Start. Commands: /aa, /aa start <slot>, /aa stop, /aa cancel, /aa award, /aa clear <name>, /aa status")
    end
end
