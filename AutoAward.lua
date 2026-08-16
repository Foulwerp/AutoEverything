----------------------------------------------------------------------
-- AutoAward.lua
-- Safe master-loot MS/OS roll tracking and assignment.
-- WoW 3.3.5a / Lua 5.1 compatible.
----------------------------------------------------------------------

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

local roundSerial = 0
local lootSessionID = 0
local lootOpen = false
local selectedSlot
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
    if GetNumRaidMembers and (GetNumRaidMembers() or 0) > 0 then return "RAID" end
    if GetNumPartyMembers and (GetNumPartyMembers() or 0) > 0 then return "PARTY" end
    return nil
end

local function Announce(message)
    local channel = GroupChannel()
    if channel and SendChatMessage then SendChatMessage(message, channel) end
    Log(message)
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

    local matches = {}
    for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
        local data = LootSlotData(slot)
        if data and data.link == current.itemLink then table.insert(matches, slot) end
    end
    if #matches == 1 then
        local data = LootSlotData(matches[1])
        if data.locked then return nil, "the matching loot slot is locked" end
        if current.itemQuantity and data.quantity ~= current.itemQuantity then
            return nil, "the matching loot quantity changed"
        end
        return matches[1]
    end
    if #matches > 1 then return nil, "multiple identical items make the slot ambiguous" end
    return nil, "the selected item is no longer in the loot window"
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
    local shown = LootSlotData(selectedSlot)
    local activeData = current.itemLink and { link = current.itemLink, texture = current.itemTexture } or shown
    ui.item:SetText(activeData and activeData.link or "Select an item in the loot window")
    ui.icon:SetTexture(activeData and activeData.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    ui.state:SetText("State: " .. tostring(current.state))
    ui.rolls:SetText("MS: " .. CountRolls("MS") .. "    OS: " .. CountRolls("OS") .. "    Rejected: " .. #(current.rejectedRolls or {}))
    ui.winner:SetText("Leader: " .. PredictedWinnerText())
    ui.auto:SetText(Setting("autoAward") and "Auto: ON" or "Auto: OFF")
    if Theme then
        ui.auto.themeAccentColor = Setting("autoAward") and Theme.Colors.brand or nil
        if Theme.RefreshButtonTheme then Theme.RefreshButtonTheme(ui.auto) end
    end
    local autoText = ui.auto.GetFontString and ui.auto:GetFontString()
    if Theme and autoText and autoText.SetTextColor then
        if Setting("autoAward") then autoText:SetTextColor(Theme.Unpack(Theme.Colors.text))
        else autoText:SetTextColor(Theme.Unpack(Theme.Colors.textMuted)) end
    end

    local now = GetTime and GetTime() or 0
    local remaining = current.deadline and math.max(0, current.deadline - now) or 0
    ui.timer:SetText((current.state == STATE_ROLLING or current.state == STATE_TIE or current.state == STATE_GRACE)
        and string.format("%.1fs", remaining) or "")
    ui.start:Enable()
    if current.state == STATE_ROLLING or current.state == STATE_TIE or current.state == STATE_GRACE or current.state == STATE_PENDING then ui.start:Disable() end
    if current.state == STATE_READY then ui.award:Enable() else ui.award:Disable() end
end

local function FailSafe(reason)
    SetState(STATE_FAILED, reason)
    current.deadline = nil
    Log(reason .. "; no item was assigned.", "error")
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
    SetState(STATE_TIE)
    Announce("Tie between " .. table.concat(names, ", ") .. ". Tied players reroll " .. (bracket == "MS" and "/roll 100" or "/roll 99") .. ".")
    RefreshUI()
end

local function ResolveRound()
    if current.state ~= STATE_GRACE and current.state ~= STATE_ROLLING and current.state ~= STATE_TIE then return end
    local slot, reason = FindVerifiedSlot()
    if not slot then FailSafe(reason); return end

    local result, winner, tied, bracket = WinnerFromRolls(current.rollsByPlayer)
    if result == "NO_ROLLS" then FailSafe("no valid rolls were received"); return end
    if result == "TIE" then BeginTieRound(tied, bracket); return end
    current.winner = winner
    current.verifiedSlot = slot
    current.deadline = nil
    SetState(STATE_READY)
    Announce(winner.player .. " wins " .. winner.bracket .. " with " .. winner.value .. ".")
    RefreshUI()
    if Setting("autoAward") then AA.Award() end
end

local function BeginGrace()
    if current.state ~= STATE_ROLLING and current.state ~= STATE_TIE then return end
    local grace = math.max(0, math.min(1, tonumber(Setting("graceSeconds")) or 1))
    SetState(STATE_GRACE)
    current.deadline = GetTime() + grace
    if grace == 0 then ResolveRound() end
    RefreshUI()
end

function AA.Start(slot)
    slot = tonumber(slot or selectedSlot)
    if current.state == STATE_ROLLING or current.state == STATE_TIE or current.state == STATE_GRACE or current.state == STATE_PENDING then
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
    RefreshUI()
    return true
end

function AA.Stop()
    if current.state ~= STATE_ROLLING and current.state ~= STATE_TIE and current.state ~= STATE_GRACE then
        Log("There is no active roll to stop.", "warn")
        return
    end
    ResolveRound()
end

function AA.Cancel(reason)
    if current.state == STATE_IDLE or current.state == STATE_AWARDED then return end
    SetState(STATE_CANCELLED, reason or "cancelled by master looter")
    current.deadline = nil
    current.pendingAward = nil
    Log(reason or "Round cancelled.", "warn")
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

function AA.Award()
    if current.state ~= STATE_READY or current.awardAttempted then
        Log("No validated winner is ready to receive the item.", "warn")
        return false
    end
    local result, winner = WinnerFromRolls(current.rollsByPlayer)
    if result ~= "WINNER" or not winner or not current.winner or winner.normalizedPlayer ~= current.winner.normalizedPlayer then
        FailSafe("the winner changed during final validation")
        return false
    end
    if not IsCurrentMember(winner.player) then FailSafe("the winner is no longer in the group"); return false end
    local isMaster, reason = PlayerIsMasterLooter()
    if not isMaster then FailSafe(reason); return false end
    local slot
    slot, reason = FindVerifiedSlot()
    if not slot then FailSafe(reason); return false end
    local candidate
    candidate, reason = CandidateForName(slot, winner.player)
    if not candidate then FailSafe(reason); return false end
    if not GiveMasterLoot then FailSafe("assignment API unavailable"); return false end

    current.awardAttempted = true
    current.pendingAward = {
        sessionID = lootSessionID,
        slot = slot,
        itemLink = current.itemLink,
        winner = winner.player,
        candidate = candidate,
        startedAt = GetTime(),
    }
    SetState(STATE_PENDING)
    RefreshUI()
    GiveMasterLoot(slot, candidate)
    return true
end

local function AcceptRoll(message)
    if current.state ~= STATE_ROLLING and current.state ~= STATE_TIE and current.state ~= STATE_GRACE then return end
    if not current.deadline or GetTime() > current.deadline then return end
    local rolledName, value, minimum, maximum = ParseRoll(message)
    if not rolledName then return end
    local activeSlot, activeReason = FindVerifiedSlot()
    if not activeSlot then FailSafe(activeReason); return end

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

local function SelectFirstLootItem()
    selectedSlot = nil
    for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
        if LootSlotData(slot) then selectedSlot = slot break end
    end
end

local function SelectAdjacent(direction)
    local count = GetNumLootItems and GetNumLootItems() or 0
    if count <= 0 then return end
    local start = selectedSlot or (direction > 0 and 0 or count + 1)
    for offset = 1, count do
        local slot = ((start - 1 + direction * offset) % count) + 1
        if LootSlotData(slot) then selectedSlot = slot; RefreshUI(); return end
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

-- Compact code-drawn chevrons avoid stock gold navigation art while remaining
-- readable on clients whose bundled font lacks Unicode arrow glyphs.
local function MakeArrowButton(parent, direction, callback)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(28, 22)
    button:SetScript("OnClick", callback)
    if Theme and Theme.SkinButton then Theme.SkinButton(button, Theme.Colors.brand) end

    local color = Theme and Theme.Colors.brand or { 0.35, 0.65, 1 }
    local points = {
        { direction * 5, 0 },
        { direction * 2, 3 },
        { direction * 2, -3 },
        { -direction, 6 },
        { -direction, -6 },
    }
    for _, point in ipairs(points) do
        local pixel = button:CreateTexture(nil, "ARTWORK")
        pixel:SetTexture(Theme and Theme.Textures.white or "Interface\\Buttons\\WHITE8X8")
        pixel:SetSize(3, 3)
        pixel:SetPoint("CENTER", button, "CENTER", point[1], point[2])
        pixel:SetVertexColor(color[1], color[2], color[3], 1)
    end
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
    frame:SetWidth(390)
    frame:SetHeight(190)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if Theme and Theme.ModalSurface then Theme.ModalSurface(frame) end
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Master Loot Awards")
    if Theme then Theme.ApplyFont(title, 16); title:SetTextColor(Theme.Unpack(Theme.Colors.text)) end
    ui.state = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.state:SetPoint("TOPLEFT", 18, -40)
    if Theme then Theme.ApplyFont(ui.state, 11); ui.state:SetTextColor(Theme.Unpack(Theme.Colors.textMuted)) end
    ui.timer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.timer:SetPoint("TOP", 0, -40)
    if Theme then Theme.ApplyFont(ui.timer, 12); ui.timer:SetTextColor(Theme.Unpack(Theme.Colors.brand)) end

    local iconFrame = CreateFrame("Frame", nil, frame)
    iconFrame:SetSize(36, 36); iconFrame:SetPoint("TOPLEFT", 18, -57)
    if Theme then Theme.Backdrop(iconFrame, Theme.Colors.surface, 1) end
    ui.icon = iconFrame:CreateTexture(nil, "ARTWORK")
    ui.icon:SetPoint("TOPLEFT", 2, -2); ui.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    ui.item = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.item:SetPoint("LEFT", iconFrame, "RIGHT", 10, 0); ui.item:SetWidth(309); ui.item:SetJustifyH("LEFT")
    if Theme then Theme.ApplyFont(ui.item, 12) end
    ui.rolls = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.rolls:SetPoint("TOPLEFT", 18, -96)
    if Theme then Theme.ApplyFont(ui.rolls, 11); ui.rolls:SetTextColor(Theme.Unpack(Theme.Colors.textMuted)) end
    ui.winner = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.winner:SetPoint("TOPLEFT", 18, -113)
    if Theme then Theme.ApplyFont(ui.winner, 11); ui.winner:SetTextColor(Theme.Unpack(Theme.Colors.text)) end

    local controlWidth = 71
    local previous = MakeArrowButton(frame, -1, function() SelectAdjacent(-1) end)
    previous:SetPoint("BOTTOMLEFT", 16, 16)
    AddTooltip(previous, "Previous loot slot", "Selects the previous item in the current loot window.")
    local nextButton = MakeArrowButton(frame, 1, function() SelectAdjacent(1) end)
    nextButton:SetPoint("LEFT", previous, "RIGHT", 2, 0)
    AddTooltip(nextButton, "Next loot slot", "Selects the next item in the current loot window.")
    ui.start = MakeButton(frame, "Start", controlWidth, function() AA.Start() end, Theme and Theme.Colors.brand)
    ui.start:SetPoint("LEFT", nextButton, "RIGHT", 8, 0)
    AddTooltip(ui.start, "Start roll", "Snapshots the current group and starts MS /roll 100 and OS /roll 99 tracking for the selected item.")
    local stop = MakeButton(frame, "Stop", controlWidth, function() AA.Stop() end)
    stop:SetPoint("LEFT", ui.start, "RIGHT", 2, 0)
    AddTooltip(stop, "Stop roll", "Ends the timer now and resolves the accepted rolls.")
    ui.award = MakeButton(frame, "Award", controlWidth, function() AA.Award() end, Theme and Theme.Colors.success)
    ui.award:SetPoint("LEFT", stop, "RIGHT", 2, 0)
    AddTooltip(ui.award, "Validated award", "Rechecks the loot item, group, master looter, winner, and candidate immediately before assigning once.")
    local cancel = MakeButton(frame, "Cancel", controlWidth, function() AA.Cancel() end, Theme and Theme.Colors.danger)
    cancel:SetPoint("LEFT", ui.award, "RIGHT", 2, 0)
    AddTooltip(cancel, "Cancel", "Stops without assigning the item.")
    ui.auto = MakeButton(frame, "Auto: OFF", controlWidth, function()
        SetSetting("autoAward", not Setting("autoAward"))
        RefreshUI()
    end)
    ui.auto:SetPoint("TOPRIGHT", -42, -32)
    AddTooltip(ui.auto, "Automatic assignment", "Off by default. When armed, a unique validated winner is assigned after the timer and grace period. Ambiguity always stops safely.")

    local close = MakeButton(frame, "x", 22, function() frame:Hide() end)
    close:SetHeight(20)
    close:SetPoint("TOPRIGHT", -10, -10)
    AddTooltip(close, "Close", "Hides this window. Use /aa to show it again.")
    RefreshUI()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("LOOT_SLOT_CLEARED")
eventFrame:RegisterEvent("LOOT_SLOT_CHANGED")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("UI_ERROR_MESSAGE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("LOOT_BIND_CONFIRM")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "AutoEverything" then
        CreateWindow()
    elseif event == "LOOT_OPENED" then
        lootSessionID = lootSessionID + 1
        lootOpen = true
        SelectFirstLootItem()
        if frame then frame:Show(); RefreshUI() end
    elseif event == "LOOT_CLOSED" then
        lootOpen = false
        selectedSlot = nil
        if current.state == STATE_PENDING then FailSafe("loot closed before assignment was confirmed")
        elseif current.state == STATE_ROLLING or current.state == STATE_TIE or current.state == STATE_GRACE or current.state == STATE_READY then
            AA.Cancel("loot window closed")
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        AcceptRoll(arg1)
    elseif event == "LOOT_SLOT_CLEARED" and current.state == STATE_PENDING and current.pendingAward then
        if tonumber(arg1) == current.pendingAward.slot then
            SetState(STATE_AWARDED)
            current.pendingAward = nil
            Log("Item assignment confirmed.")
            RefreshUI()
        end
    elseif event == "UI_ERROR_MESSAGE" and current.state == STATE_PENDING then
        FailSafe("the server rejected or could not confirm the assignment: " .. tostring(arg1 or "unknown error"))
    elseif event == "LOOT_SLOT_CHANGED" then
        RefreshUI()
    elseif (event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE") and current.state == STATE_PENDING then
        FailSafe("the group changed while assignment was pending")
    elseif event == "PLAYER_ENTERING_WORLD" and current.state ~= STATE_IDLE and current.state ~= STATE_AWARDED then
        AA.Cancel("world changed")
    elseif event == "LOOT_BIND_CONFIRM" and current.state == STATE_PENDING then
        current.pendingAward.awaitingBindConfirmation = true
        Log("Bind confirmation requires a manual click until target-server behavior is verified.", "warn")
    end
end)

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if frame and frame:IsShown() then RefreshUI() end
    if (current.state == STATE_ROLLING or current.state == STATE_TIE) and current.deadline and GetTime() >= current.deadline then
        BeginGrace()
    elseif current.state == STATE_GRACE and current.deadline and GetTime() >= current.deadline then
        ResolveRound()
    elseif current.state == STATE_PENDING and current.pendingAward
        and GetTime() - current.pendingAward.startedAt >= (current.pendingAward.awaitingBindConfirmation and 15 or 2)
    then
        local slot = current.pendingAward.slot
        local data = LootSlotData(slot)
        if data and data.link == current.pendingAward.itemLink then
            FailSafe("assignment timed out and the item still appears in the loot slot")
        else
            FailSafe("assignment result is uncertain because no success event arrived")
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
        if frame:IsShown() then frame:Hide() else frame:Show(); RefreshUI() end
    elseif command == "start" then AA.Start(argument ~= "" and argument or nil)
    elseif command == "stop" then AA.Stop()
    elseif command == "cancel" then AA.Cancel()
    elseif command == "award" then AA.Award()
    elseif command == "clear" and argument ~= "" then AA.Clear(argument)
    elseif command == "status" then
        Log("State " .. current.state .. ", selected slot " .. tostring(selectedSlot or "none")
            .. ", auto award " .. (Setting("autoAward") and "ON" or "OFF") .. ".")
        if current.statusReason then Log(current.statusReason, "warn") end
    else
        Log("Commands: /aa, /aa start <slot>, /aa stop, /aa cancel, /aa award, /aa clear <name>, /aa status")
    end
end
