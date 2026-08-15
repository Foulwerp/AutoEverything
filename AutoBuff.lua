----------------------------------------------------------------------
-- AutoBuff.lua
-- ============
-- Tracks profile-configured helpful spells across the player, party, or raid
-- and prepares one secure click-to-cast action for the next missing buff.
-- Spell casting is never attempted automatically. Secure attributes are only
-- changed out of combat. WoW 3.3.5a / Ascension, Lua 5.1 compatible.
----------------------------------------------------------------------

AutoBuff = AutoBuff or {}
local AB = AutoBuff

AB.db = {}

local scanAt = nil
local settingsRefreshAt = nil
local periodicElapsed = 0
local availableBuffs = nil
local currentMissing = {}
local currentCandidate = nil
local rejectedTrivialTargets = {}
local lastBuffAttempt = nil
local window, castButton, statusText
local roleRows = {}
local roleOverflowText

local MAX_WINDOW_ROLES = 8
local BASE_WINDOW_HEIGHT = 88
local ROLE_ROW_HEIGHT = 24
-- Blizzard character names are capped at 12 characters. The compact side
-- window shows only the character portion (not the realm), so 118 px leaves
-- enough room at the addon's narrow UI font while keeping all five role
-- buttons inside a 278 px-wide panel.
local WINDOW_WIDTH = 278
local WINDOW_INSET = 8
local WINDOW_CONTENT_WIDTH = WINDOW_WIDTH - (WINDOW_INSET * 2)
local ROLE_NAME_WIDTH = 118
local ROLE_BUTTON_SIZE = 24
local ROLE_BUTTON_GAP = 4

local function Default(key, fallback)
    local value = AutoBuffConfig and AutoBuffConfig[key]
    if value == nil then value = fallback end
    return value
end

local function Setting(key, fallback)
    local value = AutoCore and AutoCore.GetSetting and AutoCore.GetSetting("buff", key, nil)
    if value == nil then value = Default(key, fallback) end
    return value
end

local function BuffList()
    local list = Setting("buffs", Default("buffs", {}))
    return type(list) == "table" and list or {}
end

local VALID_TARGETS = {
    all = true, self = true, group = true,
    caster = true, melee = true, tank = true, healer = true,
}

local function NormalizeName(name)
    name = strtrim(tostring(name or ""))
    if name == "" then return nil end
    return string.lower(name)
end

local function PlayerRoles()
    local roles = Setting("playerRoles", Default("playerRoles", {}))
    return type(roles) == "table" and roles or {}
end

local function UnitIdentity(unit)
    local guid = UnitGUID and UnitGUID(unit)
    if guid and guid ~= "" then return guid end
    local name, realm = UnitName(unit)
    if realm and realm ~= "" then name = tostring(name or "") .. "-" .. realm end
    return NormalizeName(name)
end

local function IsTrivialTargetError(message)
    if type(message) ~= "string" then return false end
    return string.find(string.lower(message), "target trivial", 1, true) ~= nil
end

local function InCombat()
    return InCombatLockdown and InCombatLockdown()
end

local function ScheduleScan(delay)
    scanAt = GetTime() + (delay or 0.15)
end

----------------------------------------------------------------------
-- Learned helpful spells
----------------------------------------------------------------------
local function SpellBookType()
    return BOOKTYPE_SPELL or "spell"
end

local function SafeSpellFlag(func, index)
    if type(func) ~= "function" then return nil end
    local ok, value = pcall(func, index, SpellBookType())
    if not ok then return nil end
    return value
end

local function RebuildAvailableBuffs()
    local byName = {}
    local tabs = GetNumSpellTabs and (GetNumSpellTabs() or 0) or 0
    for tab = 1, tabs do
        local _, _, offset, count = GetSpellTabInfo(tab)
        for index = (offset or 0) + 1, (offset or 0) + (count or 0) do
            local name, rank = GetSpellName(index, SpellBookType())
            local helpful = SafeSpellFlag(IsHelpfulSpell, index)
            local passive = SafeSpellFlag(IsPassiveSpell, index)
            if name and helpful and not passive then
                local icon = GetSpellTexture and GetSpellTexture(index, SpellBookType()) or nil
                -- Later spell-book entries are normally higher ranks. The
                -- secure action uses the unranked name so the client selects
                -- the highest currently learned rank at click time.
                byName[name] = { name = name, rank = rank or "", icon = icon, index = index }
            end
        end
    end

    availableBuffs = {}
    for _, record in pairs(byName) do table.insert(availableBuffs, record) end
    table.sort(availableBuffs, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
end

function AB.GetAvailableBuffs()
    if not availableBuffs then RebuildAvailableBuffs() end
    return availableBuffs
end

local function LearnedSpell(name)
    for _, record in ipairs(AB.GetAvailableBuffs()) do
        if record.name == name then return record end
    end
    return nil
end

----------------------------------------------------------------------
-- Profile editing
----------------------------------------------------------------------
function AB.GetBuffs()
    return BuffList()
end

function AB.AddBuff(spell, target)
    spell = strtrim(tostring(spell or ""))
    if spell == "" then return false, "Choose a learned helpful spell." end
    if not LearnedSpell(spell) then return false, "That spell is not a learned helpful spell." end

    local list = AutoCore.DeepCopy(BuffList())
    if #list >= 8 then return false, "AutoBuff supports up to eight configured buffs per profile." end
    for _, entry in ipairs(list) do
        if entry.spell == spell then return false, "That buff is already configured." end
    end
    table.insert(list, { spell = spell, target = target or "all" })
    AutoCore.SetSetting("buff", "buffs", list)
    return true
end

function AB.RemoveBuff(index)
    local list = AutoCore.DeepCopy(BuffList())
    if not list[index] then return false, "That buff no longer exists." end
    table.remove(list, index)
    AutoCore.SetSetting("buff", "buffs", list)
    return true
end

function AB.SetBuffTarget(index, target)
    if not VALID_TARGETS[target] then
        return false, "Unknown target policy."
    end
    local list = AutoCore.DeepCopy(BuffList())
    if not list[index] then return false, "That buff no longer exists." end
    list[index].target = target
    AutoCore.SetSetting("buff", "buffs", list)
    return true
end


function AB.GetInferredRole(unit)
    local inspection = AutoCore and AutoCore.PlayerInspection
    local result = inspection and unit and inspection.Request and inspection.Request(unit)
    return (result and result.role) or "unknown"
end

function AB.GetPlayerRole(name, unit)
    local key = NormalizeName(name)
    local manual = key and PlayerRoles()[key]
    if manual then return manual end
    return AB.GetInferredRole(unit)
end

function AB.GetPlayerRoleSetting(name)
    local key = NormalizeName(name)
    return (key and PlayerRoles()[key]) or "auto"
end

function AB.SetPlayerRole(name, role)
    local key = NormalizeName(name)
    if not key then return false, "Missing player name." end
    if role ~= "auto" and role ~= "none" and role ~= "caster" and role ~= "melee" and role ~= "tank" and role ~= "healer" then
        return false, "Unknown group role."
    end
    local roles = AutoCore.DeepCopy(PlayerRoles())
    if role == "auto" then roles[key] = nil else roles[key] = role end
    AutoCore.SetSetting("buff", "playerRoles", roles)
    return true
end

function AB.ApplyProfile()
    if AutoCore and AutoCore.GetProfileSection then
        AB.db = AutoCore.GetProfileSection("buff", true)
    end
    if AB.db.enabled == nil then AB.db.enabled = Default("enabled", false) == true end
    ScheduleScan(0)
end

----------------------------------------------------------------------
-- Group/aura scanning
----------------------------------------------------------------------
local function UnitRecord(unit, isSelf)
    if not UnitExists or not UnitExists(unit) then return nil end
    local name, realm = UnitName(unit)
    name = name or unit
    local fullName = realm and realm ~= "" and (name .. "-" .. realm) or name
    local inferredRole = AB.GetInferredRole(unit)
    return {
        unit = unit,
        name = name,
        fullName = fullName,
        isSelf = isSelf,
        role = PlayerRoles()[NormalizeName(fullName)] or inferredRole,
        inferredRole = inferredRole,
        roleSetting = AB.GetPlayerRoleSetting(fullName),
    }
end

local function IsTrivialGroupMember(unit, isSelf)
    if isSelf then return false end
    local identity = UnitIdentity(unit)
    if identity and rejectedTrivialTargets[identity] then return true end
    if UnitIsTrivial and UnitIsTrivial(unit) then return true end
    return UnitClassification and UnitClassification(unit) == "trivial"
end

local function AddUnit(units, unit, isSelf)
    if UnitIsConnected and not UnitIsConnected(unit) then return end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then return end
    if IsTrivialGroupMember(unit, isSelf) then return end
    if UnitCanAssist and not UnitCanAssist("player", unit) then return end
    local record = UnitRecord(unit, isSelf)
    if record then table.insert(units, record) end
end

local function AddRosterUnit(units, unit, isSelf)
    local record = UnitRecord(unit, isSelf)
    if record then table.insert(units, record) end
end

local function RosterUnits()
    local units = {}
    AddRosterUnit(units, "player", true)
    local raidCount = GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
    if raidCount > 0 then
        for index = 1, raidCount do
            local unit = "raid" .. index
            if not UnitIsUnit or not UnitIsUnit(unit, "player") then AddRosterUnit(units, unit, false) end
        end
    else
        local partyCount = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
        for index = 1, partyCount do AddRosterUnit(units, "party" .. index, false) end
    end
    table.sort(units, function(a, b)
        if a.isSelf ~= b.isSelf then return a.isSelf end
        return string.lower(a.name) < string.lower(b.name)
    end)
    return units
end

function AB.GetGroupMembers()
    return RosterUnits()
end

function AB.OnInspectionUpdated()
    ScheduleScan(0)
    settingsRefreshAt = GetTime() + 0.1
end

local function GroupUnits()
    local units = {}
    if Setting("includeSelf", true) then AddUnit(units, "player", true) end

    local raidCount = GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
    if raidCount > 0 then
        if Setting("includeRaid", true) then
            for index = 1, raidCount do
                local unit = "raid" .. index
                if not UnitIsUnit or not UnitIsUnit(unit, "player") then AddUnit(units, unit, false) end
            end
        end
    elseif Setting("includeParty", true) then
        local partyCount = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
        for index = 1, partyCount do AddUnit(units, "party" .. index, false) end
    end
    return units
end

local function TargetAllowed(entry, unit)
    local policy = entry.target or "all"
    if policy == "self" then return unit.isSelf end
    if policy == "group" then return not unit.isSelf end
    if policy == "caster" or policy == "melee" or policy == "tank" or policy == "healer" then
        return unit.role == policy
    end
    return true
end

local function ReadAuraTimers(unit)
    local timers = {}
    if not UnitAura then return timers end
    for index = 1, 40 do
        local name, _, _, _, _, duration, expires = UnitAura(unit, index, "HELPFUL")
        if not name then break end
        if not duration or duration <= 0 or not expires or expires <= 0 then
            timers[name] = math.huge
        else
            timers[name] = math.max(0, expires - GetTime())
        end
    end
    return timers
end

local function NeedsBuff(timers, spell)
    local remaining = timers and timers[spell]
    if remaining == nil then return true, nil end
    local threshold = tonumber(Setting("rebuffSeconds", 60)) or 60
    return remaining <= threshold, remaining
end

local function InSpellRange(spell, unit)
    if not IsSpellInRange then return true end
    local ok, value = pcall(IsSpellInRange, spell, unit)
    if not ok or value == nil then return true end
    return value == 1 or value == true
end

local function BuildMissing()
    local missing = {}
    local units = GroupUnits()
    local auraTimers = {}
    for _, unit in ipairs(units) do auraTimers[unit.unit] = ReadAuraTimers(unit.unit) end
    for _, entry in ipairs(BuffList()) do
        local learned = type(entry) == "table" and LearnedSpell(entry.spell)
        if learned then
            for _, unit in ipairs(units) do
                if TargetAllowed(entry, unit) then
                    local needed, remaining = NeedsBuff(auraTimers[unit.unit], learned.name)
                    if needed then
                        table.insert(missing, {
                            spell = learned.name,
                            icon = learned.icon,
                            unit = unit.unit,
                            name = unit.name,
                            remaining = remaining,
                            inRange = InSpellRange(learned.name, unit.unit),
                        })
                    end
                end
            end
        end
    end
    return missing
end

local function FirstCastable(missing)
    for _, entry in ipairs(missing) do
        if entry.inRange then return entry end
    end
    return nil
end

----------------------------------------------------------------------
-- Compact status/cast window
----------------------------------------------------------------------
local function SaveWindowPosition()
    if not window then return end
    local point, _, relativePoint, x, y = window:GetPoint(1)
    AutoEverythingCharDB = AutoEverythingCharDB or {}
    AutoEverythingCharDB.buffWindow = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function ApplyRoleButtonSkin(button)
    local UI = AutoCore and AutoCore.UI
    if not UI then return end
    UI.StripTemplateArt(button)
    UI.Backdrop(button, UI.Colors.control, 1)
    if button.SetNormalFontObject then
        button:SetNormalFontObject("GameFontHighlightSmall")
        button:SetHighlightFontObject("GameFontHighlightSmall")
        if button.SetDisabledFontObject then button:SetDisabledFontObject("GameFontDisableSmall") end
    end
end

local function RoleTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:AddLine(button.roleTitle or "AutoBuff role")
    GameTooltip:AddLine(button.roleHelp or "", nil, nil, nil, true)
    GameTooltip:Show()
end

local function CreateRoleRow(index)
    local row = CreateFrame("Frame", nil, window)
    row:SetSize(WINDOW_CONTENT_WIDTH, ROLE_ROW_HEIGHT - 2)
    row:SetPoint("TOPLEFT", WINDOW_INSET, -80 - ((index - 1) * ROLE_ROW_HEIGHT))

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 2, 0)
    row.name:SetWidth(ROLE_NAME_WIDTH)
    row.name:SetJustifyH("LEFT")
    if AutoCore and AutoCore.UI and AutoCore.UI.ApplyFont then AutoCore.UI.ApplyFont(row.name, 11) end

    local roles = {
        { "A", "auto", "Automatic", "Infer this player's role from inspected gear." },
        { "C", "caster", "Caster", "Always treat this player as a caster." },
        { "M", "melee", "Melee", "Always treat this player as physical melee/ranged." },
        { "T", "tank", "Tank", "Always treat this player as a tank." },
        { "H", "healer", "Healer", "Always treat this player as a healer." },
    }
    row.buttons = {}
    for roleIndex, definition in ipairs(roles) do
        local roleValue = definition[2]
        local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        button:SetSize(ROLE_BUTTON_SIZE, 20)
        button:SetPoint("LEFT", ROLE_NAME_WIDTH + 2
            + ((roleIndex - 1) * (ROLE_BUTTON_SIZE + ROLE_BUTTON_GAP)), 0)
        button:SetText(definition[1])
        button.roleValue = roleValue
        button.roleTitle = definition[3]
        button.roleHelp = definition[4]
        ApplyRoleButtonSkin(button)
        button:SetScript("OnEnter", RoleTooltip)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        button:SetScript("OnClick", function(self)
            if not row.memberName then return end
            local ok, err = AB.SetPlayerRole(row.memberName, roleValue)
            if not ok and AutoCore and AutoCore.Warn then AutoCore.Warn("Buff", err) end
        end)
        row.buttons[roleValue] = button
    end
    roleRows[index] = row
    return row
end

local function PaintRoleButton(button, selected)
    local UI = AutoCore and AutoCore.UI
    if not UI or not button then return end
    if selected then
        button:SetBackdropColor(UI.Colors.selected[1], UI.Colors.selected[2], UI.Colors.selected[3], 1)
        button:SetBackdropBorderColor(UI.Unpack(UI.Colors.brand))
    else
        button:SetBackdropColor(UI.Colors.control[1], UI.Colors.control[2], UI.Colors.control[3], 1)
        button:SetBackdropBorderColor(UI.Unpack(UI.Colors.border))
    end
end

local function PaintRoleRows()
    local members = RosterUnits()
    local shown = math.min(#members, MAX_WINDOW_ROLES)
    for index = 1, MAX_WINDOW_ROLES do
        local row = roleRows[index] or CreateRoleRow(index)
        local member = members[index]
        if member then
            row.memberName = member.fullName or member.name
            local inferred = member.inferredRole and member.inferredRole ~= "unknown"
                and member.inferredRole or "inspecting"
            row.name:SetText(member.name)
            row.buttons.auto.roleTitle = "Automatic (" .. inferred .. ")"
            for role, button in pairs(row.buttons) do PaintRoleButton(button, role == member.roleSetting) end
            row:Show()
        else
            row.memberName = nil
            row:Hide()
        end
    end

    if #members > shown then
        roleOverflowText:SetText("+" .. (#members - shown) .. " more in /ae > Auto Buff > Group Assignments")
        roleOverflowText:Show()
    else
        roleOverflowText:Hide()
    end
    local overflowHeight = #members > shown and 18 or 0
    window:SetHeight(BASE_WINDOW_HEIGHT + shown * ROLE_ROW_HEIGHT + overflowHeight)
end

local function CreateWindow()
    if window then return end
    window = CreateFrame("Frame", "AutoEverythingBuffWindow", UIParent)
    window:SetSize(WINDOW_WIDTH, BASE_WINDOW_HEIGHT)
    window:SetFrameStrata("MEDIUM")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetClampedToScreen(true)
    window:SetScript("OnDragStart", function(self) if not InCombat() then self:StartMoving() end end)
    window:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SaveWindowPosition() end)

    local UI = AutoCore and AutoCore.UI
    if UI and UI.Backdrop then UI.Backdrop(window, UI.Colors.window, 0.96) end

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", WINDOW_INSET, -10)
    title:SetText("AutoBuff")
    if UI and UI.Colors then title:SetTextColor(UI.Unpack(UI.Colors.brand)) end

    statusText = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statusText:SetPoint("TOPLEFT", WINDOW_INSET, -31)
    statusText:SetWidth(WINDOW_CONTENT_WIDTH)
    statusText:SetJustifyH("LEFT")

    castButton = CreateFrame("Button", "AutoEverythingBuffNextButton", window,
        "SecureActionButtonTemplate,UIPanelButtonTemplate")
    castButton:SetSize(WINDOW_CONTENT_WIDTH, 26)
    castButton:SetPoint("TOPLEFT", WINDOW_INSET, -48)
    castButton:RegisterForClicks("LeftButtonUp")
    if UI then
        UI.StripTemplateArt(castButton)
        UI.Backdrop(castButton, UI.Colors.control, 1)
        if castButton.SetNormalFontObject then
            castButton:SetNormalFontObject("GameFontHighlight")
            castButton:SetHighlightFontObject("GameFontHighlight")
            if castButton.SetDisabledFontObject then castButton:SetDisabledFontObject("GameFontDisable") end
        end
        castButton:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(UI.Unpack(UI.Colors.brand)) end)
        castButton:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(UI.Unpack(UI.Colors.border)) end)
    end
    castButton:SetScript("PreClick", function()
        if not currentCandidate then
            lastBuffAttempt = nil
            return
        end
        lastBuffAttempt = {
            identity = UnitIdentity(currentCandidate.unit),
            name = currentCandidate.name,
            at = GetTime(),
        }
    end)
    castButton:SetScript("PostClick", function() ScheduleScan(0.2) end)

    roleOverflowText = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    roleOverflowText:SetPoint("BOTTOMLEFT", WINDOW_INSET + 2, 6)
    roleOverflowText:SetWidth(WINDOW_CONTENT_WIDTH - 4)
    roleOverflowText:SetJustifyH("LEFT")
    roleOverflowText:Hide()

    if RegisterStateDriver then
        pcall(RegisterStateDriver, castButton, "visibility", "[combat] hide; show")
    end

    AutoEverythingCharDB = AutoEverythingCharDB or {}
    local saved = AutoEverythingCharDB.buffWindow
    if type(saved) == "table" and saved.point and saved.relativePoint then
        window:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x or 0, saved.y or 0)
    else
        window:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
    end
end

local function PaintWindow()
    CreateWindow()
    local enabled = AB.db and AB.db.enabled == true
    local shouldShow = enabled and Setting("showWindow", true) ~= false
    if shouldShow and Setting("hideWhenComplete", false) and #currentMissing == 0 then shouldShow = false end

    if not InCombat() then
        if shouldShow then window:Show() else window:Hide() end
    end
    if not shouldShow then return end

    if InCombat() then
        statusText:SetText("Paused in combat")
        return
    end


    PaintRoleRows()

    if currentCandidate then
        local timerText = currentCandidate.remaining == nil and "missing"
            or (currentCandidate.remaining == math.huge and "active"
                or ("expires in " .. math.max(0, math.floor(currentCandidate.remaining + 0.5)) .. "s"))
        statusText:SetText(currentCandidate.name .. ": " .. currentCandidate.spell .. "  -  " .. timerText)
        castButton:SetAttribute("type", "spell")
        castButton:SetAttribute("spell", currentCandidate.spell)
        castButton:SetAttribute("unit", currentCandidate.unit)
        castButton:SetText("Buff " .. currentCandidate.name)
        castButton:Enable()
    else
        castButton:SetAttribute("type", nil)
        castButton:SetAttribute("spell", nil)
        castButton:SetAttribute("unit", nil)
        if #currentMissing > 0 then
            local waiting = currentMissing[1]
            statusText:SetText(waiting.name .. ": " .. waiting.spell .. "  -  out of range")
            castButton:SetText("No target in range")
        else
            statusText:SetText("Everyone is buffed")
            castButton:SetText("Buffs complete")
        end
        castButton:Disable()
    end
end

function AB.Scan()
    if not AB.db or AB.db.enabled ~= true then
        currentMissing, currentCandidate = {}, nil
        PaintWindow()
        return
    end
    currentMissing = BuildMissing()
    currentCandidate = FirstCastable(currentMissing)
    PaintWindow()
end

function AB.GetStatus()
    return #currentMissing, currentCandidate
end

function AB.ToggleWindow()
    AutoCore.SetSetting("buff", "showWindow", Setting("showWindow", true) == false)
end

----------------------------------------------------------------------
-- Events and slash commands
----------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("RAID_ROSTER_UPDATE")
events:RegisterEvent("UNIT_AURA")
events:RegisterEvent("UNIT_CLASSIFICATION_CHANGED")
events:RegisterEvent("UI_ERROR_MESSAGE")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")

events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "AutoEverything" then return end
        AB.ApplyProfile()
        CreateWindow()
    elseif event == "SPELLS_CHANGED" then
        availableBuffs = nil
        ScheduleScan(0.5)
    elseif event == "PLAYER_REGEN_DISABLED" then
        PaintWindow()
    elseif event == "PLAYER_REGEN_ENABLED" then
        ScheduleScan(0)
    elseif event == "UI_ERROR_MESSAGE" then
        local recentAttempt = lastBuffAttempt and (GetTime() - lastBuffAttempt.at) <= 2
        if recentAttempt and lastBuffAttempt.identity
            and IsTrivialTargetError(arg1)
        then
            rejectedTrivialTargets[lastBuffAttempt.identity] = true
            if AutoCore and AutoCore.Info then
                AutoCore.Info("Buff", "Skipping " .. tostring(lastBuffAttempt.name or "target")
                    .. " after the client rejected the buff as trivial.")
            end
            lastBuffAttempt = nil
            ScheduleScan(0)
        end
    elseif event == "UNIT_AURA" then
        if arg1 == "player" or string.match(arg1 or "", "^party%d+$") or string.match(arg1 or "", "^raid%d+$") then
            ScheduleScan()
        end
    else
        if event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED"
            or event == "RAID_ROSTER_UPDATE"
        then
            rejectedTrivialTargets = {}
            lastBuffAttempt = nil
        end
        ScheduleScan(0.4)
        if (event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE")
            and AutoCore and AutoCore.Settings and AutoCore.Settings.Refresh then
            AutoCore.Settings.Refresh("buff")
        end
    end
end)

events:SetScript("OnUpdate", function(self, elapsed)
    if AB.db and AB.db.enabled == true and not InCombat() then
        periodicElapsed = periodicElapsed + (elapsed or 0)
        if periodicElapsed >= 2 then
            periodicElapsed = 0
            ScheduleScan(0)
        end
    else
        periodicElapsed = 0
    end
    if scanAt and GetTime() >= scanAt and not InCombat() then
        scanAt = nil
        AB.Scan()
    end
    if settingsRefreshAt and GetTime() >= settingsRefreshAt then
        settingsRefreshAt = nil
        if AutoCore and AutoCore.Settings and AutoCore.Settings.Refresh then AutoCore.Settings.Refresh("buff") end
    end
end)

SLASH_AUTOBUFF1 = "/autobuff"
SLASH_AUTOBUFF2 = "/abuff"
SlashCmdList.AUTOBUFF = function(message)
    local command = string.lower(strtrim(message or ""))
    if command == "on" then
        AutoCore.SetSetting("buff", "enabled", true)
        AutoCore.Info("Buff", "AutoBuff enabled.")
    elseif command == "off" then
        AutoCore.SetSetting("buff", "enabled", false)
        AutoCore.Info("Buff", "AutoBuff disabled.")
    elseif command == "scan" then
        AB.Scan()
        AutoCore.Info("Buff", #currentMissing .. " missing configured buff" .. (#currentMissing == 1 and "" or "s") .. ".")
    elseif command == "show" then
        AutoCore.SetSetting("buff", "showWindow", true)
    elseif command == "hide" then
        AutoCore.SetSetting("buff", "showWindow", false)
    elseif AutoCore.Settings and AutoCore.Settings.Open then
        AutoCore.Settings.Open("Buff")
    end
end
