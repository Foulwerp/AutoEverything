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
local castReadyAt = nil
local window, castButton, statusText
local roleRows = {}
local roleOverflowText
local roleScrollSlider
local roleFirstIndex = 1
local roleScrollUpdating = false
local PaintRoleRows
local ScrollRoleRows

local MAX_WINDOW_ROLES = 8
local BASE_WINDOW_HEIGHT = 88
local ROLE_ROW_HEIGHT = 24
-- Blizzard character names are capped at 12 characters. The compact side
-- window shows only the character portion (not the realm), so 118 px leaves
-- enough room at the addon's narrow UI font while keeping all five role
-- buttons beside a narrow raid-roster scrollbar.
local WINDOW_WIDTH = 298
local WINDOW_INSET = 8
local ROLE_SCROLLBAR_WIDTH = 14
local ROLE_SCROLLBAR_GAP = 4
local WINDOW_CONTENT_WIDTH = WINDOW_WIDTH - (WINDOW_INSET * 2)
    - ROLE_SCROLLBAR_WIDTH - ROLE_SCROLLBAR_GAP
local ROLE_NAME_WIDTH = 118
local ROLE_BUTTON_SIZE = 24
local ROLE_BUTTON_GAP = 4
local CAST_DELAY_SECONDS = 1
local TRIVIAL_ERROR_WINDOW_SECONDS = 0.75

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
local TARGET_ORDER = { "all", "self", "group", "caster", "melee", "tank", "healer" }
local ASSIGNMENT_TARGET_ORDER = { "self", "caster", "tank", "healer", "melee" }
local ASSIGNMENT_TARGETS = {
    self = true, caster = true, tank = true, healer = true, melee = true,
}

local function NormalizeTargets(value)
    local selected = {}
    if type(value) == "table" then
        for key, child in pairs(value) do
            local target = type(key) == "number" and child or (child and key or nil)
            if VALID_TARGETS[target] then selected[target] = true end
        end
    elseif VALID_TARGETS[value] then
        selected[value] = true
    end
    local result = {}
    for _, target in ipairs(TARGET_ORDER) do
        if selected[target] then result[#result + 1] = target end
    end
    return result
end

-- Older profiles could store broad "all" and "group" policies. The
-- role-first editor expands those policies into its five explicit rows so a
-- profile keeps the same visible selections when it is next edited.
local function ExpandAssignmentTargets(value)
    local expanded = {}
    for _, target in ipairs(NormalizeTargets(value)) do
        if target == "all" then
            for _, assignmentTarget in ipairs(ASSIGNMENT_TARGET_ORDER) do
                expanded[assignmentTarget] = true
            end
        elseif target == "group" then
            expanded.caster = true
            expanded.tank = true
            expanded.healer = true
            expanded.melee = true
        elseif ASSIGNMENT_TARGETS[target] then
            expanded[target] = true
        end
    end
    return expanded
end

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

function AB.GetBuffTargets(entry)
    if type(entry) ~= "table" then return {} end
    return NormalizeTargets(entry.targets or entry.target or "all")
end

function AB.GetAssignedBuffs(target)
    if not ASSIGNMENT_TARGETS[target] then return {} end
    local assigned = {}
    for _, entry in ipairs(BuffList()) do
        if type(entry) == "table" and entry.spell then
            local targets = ExpandAssignmentTargets(entry.targets or entry.target or "all")
            if targets[target] then table.insert(assigned, entry.spell) end
        end
    end
    return assigned
end

local function SelectedSpellSet(spells)
    local selected = {}
    if type(spells) == "table" then
        for key, value in pairs(spells) do
            local spell = type(key) == "number" and value or (value and key or nil)
            if type(spell) == "string" and spell ~= "" then selected[spell] = true end
        end
    elseif type(spells) == "string" and spells ~= "" then
        selected[spells] = true
    end
    return selected
end

function AB.BuildAssignedBuffs(target, spells)
    if not ASSIGNMENT_TARGETS[target] then return nil, "Unknown buff target group." end
    local selected = SelectedSpellSet(spells)
    local orderedSpells, targetsBySpell, seen = {}, {}, {}

    for _, entry in ipairs(BuffList()) do
        if type(entry) == "table" and type(entry.spell) == "string" and entry.spell ~= "" then
            if not seen[entry.spell] then
                seen[entry.spell] = true
                table.insert(orderedSpells, entry.spell)
            end
            local expanded = ExpandAssignmentTargets(entry.targets or entry.target or "all")
            local spellTargets = targetsBySpell[entry.spell] or {}
            targetsBySpell[entry.spell] = spellTargets
            for assignmentTarget in pairs(expanded) do spellTargets[assignmentTarget] = true end
        end
    end

    local selectedSpells = {}
    for spell in pairs(selected) do table.insert(selectedSpells, spell) end
    table.sort(selectedSpells, function(a, b) return string.lower(a) < string.lower(b) end)
    for _, spell in ipairs(selectedSpells) do
        if not seen[spell] then
            seen[spell] = true
            table.insert(orderedSpells, spell)
            targetsBySpell[spell] = {}
        end
    end
    for spell, spellTargets in pairs(targetsBySpell) do
        spellTargets[target] = selected[spell] or nil
    end

    local list = {}
    for _, spell in ipairs(orderedSpells) do
        local targets = {}
        local spellTargets = targetsBySpell[spell] or {}
        for _, assignmentTarget in ipairs(ASSIGNMENT_TARGET_ORDER) do
            if spellTargets[assignmentTarget] then table.insert(targets, assignmentTarget) end
        end
        if #targets > 0 then table.insert(list, { spell = spell, targets = targets }) end
    end
    return list
end

function AB.SetAssignedBuffs(target, spells)
    local list, err = AB.BuildAssignedBuffs(target, spells)
    if not list then return false, err end
    AutoCore.SetSetting("buff", "buffs", list)
    return true
end

function AB.AddBuff(spell, target)
    spell = strtrim(tostring(spell or ""))
    if spell == "" then return false, "Choose a learned helpful spell." end
    if not LearnedSpell(spell) then return false, "That spell is not a learned helpful spell." end

    local targets = NormalizeTargets(target or "all")
    if #targets == 0 then return false, "Choose at least one target category." end
    local list = AutoCore.DeepCopy(BuffList())
    for _, entry in ipairs(list) do
        if entry.spell == spell then
            return false, "That buff is already configured; edit it in the role assignment rows."
        end
    end
    table.insert(list, { spell = spell, targets = targets })
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
    return AB.SetBuffTargets(index, target)
end

function AB.SetBuffTargets(index, targets)
    targets = NormalizeTargets(targets)
    local list = AutoCore.DeepCopy(BuffList())
    if not list[index] then return false, "That buff no longer exists." end
    list[index].target = nil
    list[index].targets = targets
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
    for _, policy in ipairs(NormalizeTargets(entry.targets or entry.target or "all")) do
        if policy == "all" then return true end
        if policy == "self" and unit.isSelf then return true end
        if policy == "group" and not unit.isSelf then return true end
        if not unit.isSelf
            and (policy == "caster" or policy == "melee" or policy == "tank" or policy == "healer")
            and unit.role == policy
        then
            return true
        end
    end
    return false
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

local function SpellCooldown(learned)
    if not GetSpellCooldown or not learned then return 0, 0 end
    local ok, start, duration, enabled = pcall(GetSpellCooldown, learned.index, SpellBookType())
    if not ok then
        ok, start, duration, enabled = pcall(GetSpellCooldown, learned.name)
    end
    if not ok or enabled == 0 or type(start) ~= "number" or type(duration) ~= "number"
        or start <= 0 or duration <= 0
    then
        return 0, 0
    end
    return math.max(0, start + duration - GetTime()), duration
end

local function BuildMissing()
    local missing = {}
    local units = GroupUnits()
    local auraTimers = {}
    for _, unit in ipairs(units) do auraTimers[unit.unit] = ReadAuraTimers(unit.unit) end
    for _, entry in ipairs(BuffList()) do
        local learned = type(entry) == "table" and LearnedSpell(entry.spell)
        if learned then
            local cooldown, cooldownDuration = SpellCooldown(learned)
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
                            cooldown = cooldown,
                            cooldownDuration = cooldownDuration,
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
        if entry.inRange and (entry.cooldown or 0) <= 0 then return entry end
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
    row:EnableMouse(true)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta)
        if ScrollRoleRows then ScrollRoleRows(delta > 0 and -1 or 1) end
    end)

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
        button:EnableMouseWheel(true)
        button:SetScript("OnMouseWheel", function(_, delta)
            if ScrollRoleRows then ScrollRoleRows(delta > 0 and -1 or 1) end
        end)
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

local function PaintRoleButton(button, state)
    local UI = AutoCore and AutoCore.UI
    if not UI or not button then return end
    local font = button:GetFontString()
    if state == "inferred" then
        button:SetBackdropColor(UI.Colors.brandDim[1], UI.Colors.brandDim[2], UI.Colors.brandDim[3], 0.9)
        button:SetBackdropBorderColor(UI.Unpack(UI.Colors.brand))
        if font then font:SetTextColor(UI.Unpack(UI.Colors.text)) end
    elseif state == "automatic" then
        button:SetBackdropColor(UI.Colors.surfaceRaised[1], UI.Colors.surfaceRaised[2], UI.Colors.surfaceRaised[3], 1)
        button:SetBackdropBorderColor(UI.Unpack(UI.Colors.textMuted))
        if font then font:SetTextColor(UI.Unpack(UI.Colors.textMuted)) end
    elseif state == "selected" then
        button:SetBackdropColor(UI.Colors.selected[1], UI.Colors.selected[2], UI.Colors.selected[3], 1)
        button:SetBackdropBorderColor(UI.Unpack(UI.Colors.brand))
        if font then font:SetTextColor(UI.Unpack(UI.Colors.text)) end
    else
        button:SetBackdropColor(UI.Colors.control[1], UI.Colors.control[2], UI.Colors.control[3], 1)
        button:SetBackdropBorderColor(UI.Unpack(UI.Colors.border))
        if font then font:SetTextColor(UI.Unpack(UI.Colors.textMuted)) end
    end
end

PaintRoleRows = function()
    local members = RosterUnits()
    local shown = math.min(#members, MAX_WINDOW_ROLES)
    local maximumFirst = math.max(1, #members - shown + 1)
    roleFirstIndex = math.max(1, math.min(roleFirstIndex, maximumFirst))
    for index = 1, MAX_WINDOW_ROLES do
        local row = roleRows[index] or CreateRoleRow(index)
        local member = members[roleFirstIndex + index - 1]
        if member then
            row.memberName = member.fullName or member.name
            local inferred = member.inferredRole and member.inferredRole ~= "unknown"
                and member.inferredRole or "inspecting"
            row.name:SetText(member.name)
            row.buttons.auto.roleTitle = "Automatic (" .. inferred .. ")"
            for role, button in pairs(row.buttons) do
                local state
                if member.roleSetting == "auto" then
                    if role == "auto" then state = "automatic"
                    elseif role == member.inferredRole then state = "inferred" end
                elseif role == member.roleSetting then
                    state = "selected"
                end
                PaintRoleButton(button, state)
            end
            row:Show()
        else
            row.memberName = nil
            row:Hide()
        end
    end

    if #members > shown then
        local lastIndex = math.min(#members, roleFirstIndex + shown - 1)
        roleOverflowText:SetText(roleFirstIndex .. "-" .. lastIndex .. " of " .. #members)
        roleOverflowText:Show()
        roleScrollSlider:SetHeight(math.max(24, (shown * ROLE_ROW_HEIGHT) - 4))
        roleScrollUpdating = true
        roleScrollSlider:SetScrollRange(maximumFirst - 1, roleFirstIndex - 1)
        roleScrollUpdating = false
    else
        roleOverflowText:Hide()
        roleScrollSlider:SetScrollRange(0, 0)
    end
    local overflowHeight = #members > shown and 18 or 0
    window:SetHeight(BASE_WINDOW_HEIGHT + shown * ROLE_ROW_HEIGHT + overflowHeight)
end

ScrollRoleRows = function(delta)
    local members = RosterUnits()
    local shown = math.min(#members, MAX_WINDOW_ROLES)
    local maximumFirst = math.max(1, #members - shown + 1)
    local nextIndex = math.max(1, math.min(roleFirstIndex + delta, maximumFirst))
    if nextIndex == roleFirstIndex then return end
    roleFirstIndex = nextIndex
    PaintRoleRows()
end

local function CreateWindow()
    if window then return end
    window = CreateFrame("Frame", "AutoEverythingBuffWindow", UIParent)
    window:SetSize(WINDOW_WIDTH, BASE_WINDOW_HEIGHT)
    window:SetFrameStrata("MEDIUM")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:EnableMouseWheel(true)
    window:RegisterForDrag("LeftButton")
    window:SetClampedToScreen(true)
    window:SetScript("OnDragStart", function(self) if not InCombat() then self:StartMoving() end end)
    window:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SaveWindowPosition() end)
    window:SetScript("OnMouseWheel", function(_, delta)
        if ScrollRoleRows then ScrollRoleRows(delta > 0 and -1 or 1) end
    end)

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
        castReadyAt = GetTime() + CAST_DELAY_SECONDS
    end)
    castButton:SetScript("PostClick", function(self)
        self:Disable()
        ScheduleScan(0)
    end)

    roleOverflowText = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    roleOverflowText:SetPoint("BOTTOMLEFT", WINDOW_INSET + 2, 6)
    roleOverflowText:SetWidth(WINDOW_CONTENT_WIDTH - 4)
    roleOverflowText:SetJustifyH("LEFT")
    roleOverflowText:Hide()

    roleScrollSlider = UI.CreateVerticalScrollbar(window, 24, function(value)
        if roleScrollUpdating then return end
        local members = RosterUnits()
        local shown = math.min(#members, MAX_WINDOW_ROLES)
        local maximumFirst = math.max(1, #members - shown + 1)
        roleFirstIndex = math.max(1, math.min(math.floor(value + 0.5) + 1, maximumFirst))
        PaintRoleRows()
    end, 1)
    roleScrollSlider:SetWidth(ROLE_SCROLLBAR_WIDTH)
    roleScrollSlider:SetPoint("TOPLEFT", window, "TOPLEFT",
        WINDOW_INSET + WINDOW_CONTENT_WIDTH + ROLE_SCROLLBAR_GAP, -82)

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
        if castReadyAt and GetTime() < castReadyAt then
            castButton:SetText("Waiting for global cooldown")
            castButton:Disable()
        else
            castButton:SetText("Buff " .. currentCandidate.name)
            castButton:Enable()
        end
    else
        castButton:SetAttribute("type", nil)
        castButton:SetAttribute("spell", nil)
        castButton:SetAttribute("unit", nil)
        if #currentMissing > 0 then
            local waitingCooldown
            for _, missing in ipairs(currentMissing) do
                if missing.inRange and (missing.cooldown or 0) > 0
                    and (not waitingCooldown or missing.cooldown < waitingCooldown.cooldown)
                then
                    waitingCooldown = missing
                end
            end
            if waitingCooldown then
                local seconds = math.max(0, waitingCooldown.cooldown)
                local reason = (waitingCooldown.cooldownDuration or 0) <= 2
                    and "global cooldown" or "spell cooldown"
                statusText:SetText(waitingCooldown.spell .. "  -  " .. reason)
                castButton:SetText("Waiting " .. string.format("%.1f", seconds) .. "s")
            else
                local waiting = currentMissing[1]
                statusText:SetText(waiting.name .. ": " .. waiting.spell .. "  -  out of range")
                castButton:SetText("No target in range")
            end
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
    if not currentCandidate then
        local shortest
        for _, missing in ipairs(currentMissing) do
            if missing.inRange and (missing.cooldown or 0) > 0
                and (not shortest or missing.cooldown < shortest)
            then
                shortest = missing.cooldown
            end
        end
        if shortest then ScheduleScan(shortest + 0.05) end
    end
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
events:RegisterEvent("SPELL_UPDATE_COOLDOWN")
events:RegisterEvent("SPELL_UPDATE_USABLE")
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
    elseif event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_USABLE" then
        ScheduleScan(0)
    elseif event == "PLAYER_REGEN_DISABLED" then
        PaintWindow()
    elseif event == "PLAYER_REGEN_ENABLED" then
        ScheduleScan(0)
    elseif event == "UI_ERROR_MESSAGE" then
        local recentAttempt = lastBuffAttempt
            and (GetTime() - lastBuffAttempt.at) <= TRIVIAL_ERROR_WINDOW_SECONDS
        if recentAttempt then
            if lastBuffAttempt.identity and IsTrivialTargetError(arg1) then
                rejectedTrivialTargets[lastBuffAttempt.identity] = true
                if AutoCore and AutoCore.Info then
                    AutoCore.Info("Buff", "Skipping " .. tostring(lastBuffAttempt.name or "target")
                        .. " after the client rejected the buff as trivial.")
                end
                ScheduleScan(0)
            end
            lastBuffAttempt = nil
        end
    elseif event == "UNIT_AURA" then
        if arg1 == "player" or string.match(arg1 or "", "^party%d+$") or string.match(arg1 or "", "^raid%d+$") then
            if lastBuffAttempt and lastBuffAttempt.identity == UnitIdentity(arg1) then
                lastBuffAttempt = nil
            end
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
    if castReadyAt and GetTime() >= castReadyAt then
        castReadyAt = nil
        lastBuffAttempt = nil
        ScheduleScan(0)
    end
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
