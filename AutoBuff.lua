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
local periodicElapsed = 0
local availableBuffs = nil
local currentMissing = {}
local currentCandidate = nil
local rejectedTrivialTargets = {}
local rejectedPowerfulBuffs = {}
local lastBuffAttempt = nil
local castReadyAt = nil
local combatHider, window, castButton, statusText
local windowHidesInCombat = false

local BASE_WINDOW_HEIGHT = 88
local WINDOW_WIDTH = 180
local WINDOW_INSET = 8
local WINDOW_CONTENT_WIDTH = WINDOW_WIDTH - (WINDOW_INSET * 2)
local CAST_DELAY_SECONDS = 1
local TRIVIAL_ERROR_WINDOW_SECONDS = 0.75
local POWERFUL_BUFF_RETRY_SECONDS = 30 * 60
local PERIODIC_SCAN_INTERVAL = 5

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

local function IsMorePowerfulBuffError(message)
    if type(message) ~= "string" then return false end
    if type(SPELL_FAILED_AURA_BOUNCED) == "string" and message == SPELL_FAILED_AURA_BOUNCED then return true end
    local lowered = string.lower(message)
    return string.find(lowered, "more powerful", 1, true) ~= nil
        and string.find(lowered, "already active", 1, true) ~= nil
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
    local name = UnitName(unit)
    name = name or unit
    return {
        unit = unit,
        name = name,
        isSelf = isSelf,
        role = AB.GetInferredRole(unit),
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

function AB.OnInspectionUpdated()
    ScheduleScan(0)
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

local function HasSelfAssignments()
    for _, entry in ipairs(BuffList()) do
        if type(entry) == "table" then
            local targets = ExpandAssignmentTargets(entry.targets or entry.target or "all")
            if targets.self then return true end
        end
    end
    return false
end

local function TargetAllowed(entry, unit, hasSelfAssignments)
    for _, policy in ipairs(NormalizeTargets(entry.targets or entry.target or "all")) do
        if policy == "all" then return true end
        if policy == "self" and unit.isSelf then return true end
        if policy == "group" and not unit.isSelf then return true end
        if (not unit.isSelf or not hasSelfAssignments)
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

local function HasRejectedPowerfulBuff(identity, spell)
    local bySpell = identity and rejectedPowerfulBuffs[identity]
    local expiresAt = bySpell and bySpell[spell]
    if not expiresAt then return false end
    if expiresAt <= GetTime() then
        bySpell[spell] = nil
        return false
    end
    return true
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
    local hasSelfAssignments = HasSelfAssignments()
    local auraTimers = {}
    for _, unit in ipairs(units) do
        auraTimers[unit.unit] = ReadAuraTimers(unit.unit)
    end
    for _, entry in ipairs(BuffList()) do
        local learned = type(entry) == "table" and LearnedSpell(entry.spell)
        if learned then
            local cooldown, cooldownDuration = SpellCooldown(learned)
            for _, unit in ipairs(units) do
                if TargetAllowed(entry, unit, hasSelfAssignments) then
                    local needed, remaining = NeedsBuff(auraTimers[unit.unit], learned.name)
                    local identity = UnitIdentity(unit.unit)
                    if needed and not HasRejectedPowerfulBuff(identity, learned.name)
                        and InSpellRange(learned.name, unit.unit)
                    then
                        table.insert(missing, {
                            spell = learned.name,
                            icon = learned.icon,
                            unit = unit.unit,
                            name = unit.name,
                            remaining = remaining,
                            inRange = true,
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

local function HasGlobalCooldownWait(missing)
    for _, entry in ipairs(missing) do
        if entry.inRange and (entry.cooldown or 0) > 0 and (entry.cooldownDuration or 0) <= 2 then
            return true
        end
    end
    return false
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

local function CreateWindow()
    if window then return end
    -- Keep secure combat visibility separate from availability visibility.
    -- A "[combat] hide; show" driver attached directly to the window would
    -- force it shown out of combat and fight PaintWindow's manual Hide calls.
    combatHider = CreateFrame("Frame", nil, UIParent)
    window = CreateFrame("Frame", "AutoEverythingBuffWindow", combatHider)
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
            unit = currentCandidate.unit,
            spell = currentCandidate.spell,
            name = currentCandidate.name,
            at = GetTime(),
        }
        castReadyAt = GetTime() + CAST_DELAY_SECONDS
    end)
    castButton:SetScript("PostClick", function(self)
        self:Disable()
        ScheduleScan(0)
    end)

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

local function UpdateCombatVisibility(hideInCombat)
    if InCombat() then return end
    if hideInCombat and not windowHidesInCombat and RegisterStateDriver then
        local ok = pcall(RegisterStateDriver, combatHider, "visibility", "[combat] hide; show")
        if ok then windowHidesInCombat = true end
    elseif not hideInCombat and windowHidesInCombat and UnregisterStateDriver then
        local ok = pcall(UnregisterStateDriver, combatHider, "visibility")
        if ok then
            windowHidesInCombat = false
            combatHider:Show()
        end
    end
end

local function PaintWindow()
    CreateWindow()
    local enabled = AB.db and AB.db.enabled == true
    local hideWhenUnavailable = Setting("hideWhenComplete", false) == true
    UpdateCombatVisibility(hideWhenUnavailable)
    local shouldShow = enabled and Setting("showWindow", true) ~= false
        and #currentMissing > 0
    if shouldShow and hideWhenUnavailable then
        local postCastDelay = castReadyAt and GetTime() < castReadyAt
        local keepVisible = currentCandidate or postCastDelay or HasGlobalCooldownWait(currentMissing)
        if InCombat() or not keepVisible then shouldShow = false end
    end

    if not InCombat() then
        if shouldShow then window:Show() else window:Hide() end
    end
    if not shouldShow then return end

    if InCombat() then
        statusText:SetText("Paused in combat")
        return
    end

    if currentCandidate then
        statusText:SetText(currentCandidate.name .. " > " .. currentCandidate.spell)
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
                statusText:SetText(waitingCooldown.name .. " > " .. waitingCooldown.spell)
                castButton:SetText("Waiting " .. string.format("%.1f", seconds) .. "s")
            else
                local waiting = currentMissing[1]
                statusText:SetText(waiting.name .. " > " .. waiting.spell)
                castButton:SetText("No target in range")
            end
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
            elseif lastBuffAttempt.identity and lastBuffAttempt.spell and IsMorePowerfulBuffError(arg1) then
                rejectedPowerfulBuffs[lastBuffAttempt.identity] = rejectedPowerfulBuffs[lastBuffAttempt.identity] or {}
                rejectedPowerfulBuffs[lastBuffAttempt.identity][lastBuffAttempt.spell]
                    = GetTime() + POWERFUL_BUFF_RETRY_SECONDS
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
            rejectedPowerfulBuffs = {}
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
        if periodicElapsed >= PERIODIC_SCAN_INTERVAL then
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
