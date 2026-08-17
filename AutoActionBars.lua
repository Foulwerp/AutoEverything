----------------------------------------------------------------------
-- AutoActionBars.lua
-- Saves and restores action-bar layouts, with optional Ascension
-- specialization switching. WoW 3.3.5a / Lua 5.1 compatible.
----------------------------------------------------------------------
AutoActionBars = AutoActionBars or {}
local AAB = AutoActionBars

local MAX_ACTION_SLOTS = 144
local POSSESSION_FIRST, POSSESSION_LAST = 121, 132
local MAX_MACRO_SLOTS = 72
local restoreErrors = {}
local spellCache, macroBodyCache, macroNameCache = {}, {}, {}
local pendingRestoreAt
local specChanged = false

local function Trim(text)
    text = tostring(text or "")
    if strtrim then return strtrim(text) end
    return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function Print(message, level)
    if AutoCore and AutoCore.Log then
        AutoCore.Log("ActionBars", message, level)
    else
        print("|cff26bff2AutoActionBars:|r " .. tostring(message))
    end
end

local function ClassToken()
    return select(2, UnitClass("player")) or "UNKNOWN"
end

local function GetDB()
    AutoEverythingDB = AutoEverythingDB or {}
    AutoEverythingDB.actionBars = type(AutoEverythingDB.actionBars) == "table" and AutoEverythingDB.actionBars or {}
    local db = AutoEverythingDB.actionBars
    db.profiles = type(db.profiles) == "table" and db.profiles or {}
    db.options = type(db.options) == "table" and db.options or {}
    if db.options.enabled == nil then db.options.enabled = true end
    if db.options.restoreMacros == nil then db.options.restoreMacros = false end
    if db.options.restoreHighestRank == nil then db.options.restoreHighestRank = true end
    local class = ClassToken()
    db.profiles[class] = type(db.profiles[class]) == "table" and db.profiles[class] or {}
    return db
end

local function GetCharDB()
    AutoEverythingCharDB = AutoEverythingCharDB or {}
    AutoEverythingCharDB.actionBars = type(AutoEverythingCharDB.actionBars) == "table"
        and AutoEverythingCharDB.actionBars or {}
    local db = AutoEverythingCharDB.actionBars
    db.specs = type(db.specs) == "table" and db.specs or {}
    db.specProfiles = type(db.specProfiles) == "table" and db.specProfiles or {}
    return db
end

local function Profiles()
    return GetDB().profiles[ClassToken()]
end

local function SortedProfileNames()
    local names = {}
    for name in pairs(Profiles()) do table.insert(names, name) end
    table.sort(names)
    return names
end

local function ActiveSpecID()
    if SpecializationUtil and SpecializationUtil.GetActiveSpecialization then
        return SpecializationUtil.GetActiveSpecialization()
    end
    if GetActiveTalentGroup then return GetActiveTalentGroup() end
    return 1
end

local function CleanSpecName(value)
    if type(value) ~= "string" then return nil end
    local name = value:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or tonumber(name) then return nil end
    local suffix = name:match("^[Ss]peciali[sz]ation%s*:%s*(.+)$")
    if suffix and suffix ~= "" then return suffix end
    if name:match("^[Ss]peciali[sz]ation%s*:?%s*%d*%s*$") then return nil end
    if name:find("Interface\\", 1, true) or #name > 80 then return nil end
    return name
end

local function NameFromSpecResults(...)
    for index = 1, select("#", ...) do
        local name = CleanSpecName((select(index, ...)))
        if name then return name end
    end
end

local function SpecName(id)
    if SpecializationUtil and SpecializationUtil.GetSpecializationInfo then
        local ok, first, second, third, fourth, fifth, sixth =
            pcall(SpecializationUtil.GetSpecializationInfo, id)
        if ok then
            local name = NameFromSpecResults(first, second, third, fourth, fifth, sixth)
            if name then return name end
        end
    end
    if GetSpecializationInfo then
        local ok, first, second, third, fourth, fifth, sixth = pcall(GetSpecializationInfo, id)
        if ok then
            local name = NameFromSpecResults(first, second, third, fourth, fifth, sixth)
            if name then return name end
        end
    end
    return "Specialization " .. tostring(id or 1)
end

local function IsManagedSlot(slot)
    return slot < POSSESSION_FIRST or slot > POSSESSION_LAST
end

local function SaveLayout(set)
    for key in pairs(set) do set[key] = nil end
    for slot = 1, MAX_ACTION_SLOTS do
        if IsManagedSlot(slot) then
            local actionType, id, subType, extraID = GetActionInfo(slot)
            if actionType and id then
                if actionType == "spell" and id > 0 then
                    local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
                    if not name and GetSpellInfo then name, rank = GetSpellInfo(id) end
                    if name then
                        set[slot] = { type = "spell", name = name, rank = rank or "", extraID = extraID }
                    end
                elseif actionType == "item" then
                    set[slot] = { type = "item", id = id, name = (GetItemInfo(id)) or "" }
                elseif actionType == "macro" then
                    local name, icon, body = GetMacroInfo(id)
                    if name and body then
                        set[slot] = { type = "macro", name = name, icon = icon, body = body }
                    end
                elseif actionType == "equipmentset" then
                    set[slot] = { type = "equipmentset", name = id }
                elseif actionType == "companion" then
                    set[slot] = { type = "companion", id = id, subType = subType, extraID = extraID }
                end
            end
        end
    end
end

function AAB.GetProfileNames()
    return SortedProfileNames()
end

function AAB.GetSelectedProfile()
    local names = SortedProfileNames()
    if AAB.selectedProfile and Profiles()[AAB.selectedProfile] then return AAB.selectedProfile end
    AAB.selectedProfile = names[1]
    return AAB.selectedProfile
end

function AAB.SetSelectedProfile(name)
    if name and Profiles()[name] then AAB.selectedProfile = name end
end

function AAB.SaveProfile(name, quiet)
    name = Trim(name)
    if name == "" then return false, "Enter a profile name." end
    if #name > 40 then return false, "Profile names may not exceed 40 characters." end
    if string.find(name, "[%c]") then return false, "Profile names may not contain control characters." end
    local profiles = Profiles()
    profiles[name] = profiles[name] or {}
    SaveLayout(profiles[name])
    AAB.selectedProfile = name
    if not quiet then Print("Saved profile " .. name .. ".") end
    return true
end

function AAB.DeleteProfile(name)
    name = Trim(name)
    if not Profiles()[name] then return false, "No profile called '" .. name .. "'." end
    Profiles()[name] = nil
    local charDB = GetCharDB()
    for _, assignment in pairs(charDB.specs) do
        if assignment.profile == name then assignment.profile = nil end
    end
    if AAB.selectedProfile == name then AAB.selectedProfile = nil end
    Print("Deleted profile " .. name .. ".")
    return true
end

function AAB.RenameProfile(oldName, newName)
    oldName, newName = Trim(oldName), Trim(newName)
    if not Profiles()[oldName] then return false, "No profile called '" .. oldName .. "'." end
    if newName == "" then return false, "Enter a new profile name." end
    if #newName > 40 or string.find(newName, "[%c]") then return false, "That profile name is not valid." end
    if oldName ~= newName and Profiles()[newName] then return false, "A profile called that already exists." end
    if oldName == newName then return true end
    Profiles()[newName], Profiles()[oldName] = Profiles()[oldName], nil
    for _, assignment in pairs(GetCharDB().specs) do
        if assignment.profile == oldName then assignment.profile = newName end
    end
    AAB.selectedProfile = newName
    Print("Renamed " .. oldName .. " to " .. newName .. ".")
    return true
end

local function ClearCaches()
    for key in pairs(spellCache) do spellCache[key] = nil end
    for key in pairs(macroBodyCache) do macroBodyCache[key] = nil end
    for key in pairs(macroNameCache) do macroNameCache[key] = nil end
end

local function CacheSpells()
    local tabs = (GetNumSpellTabs and GetNumSpellTabs()) or MAX_SKILLLINE_TABS or 0
    for tab = 1, tabs do
        local _, _, offset, count = GetSpellTabInfo(tab)
        for index = (offset or 0) + 1, (offset or 0) + (count or 0) do
            local name, rank = GetSpellName(index, BOOKTYPE_SPELL)
            if name then
                spellCache[name] = index
                spellCache[string.lower(name)] = index
                if rank and rank ~= "" then spellCache[name .. rank] = index end
            end
        end
    end
end

local function CacheMacros()
    local duplicateNames = {}
    for index = 1, MAX_MACRO_SLOTS do
        local name, _, body = GetMacroInfo(index)
        if name then
            if macroNameCache[name] then
                duplicateNames[name] = true
                macroNameCache[name] = nil
            elseif not duplicateNames[name] then
                macroNameCache[name] = index
            end
            if body then macroBodyCache[body] = index end
        end
    end
end

local function FindMacro(action, requireSavedBody)
    local bodyID = macroBodyCache[action.body or ""]
    if bodyID then return bodyID end
    if requireSavedBody and action.body ~= nil then return nil end
    return macroNameCache[action.name or ""]
end

local function MacroIconIndex(icon)
    if type(icon) == "number" then return icon end
    if not GetNumMacroIcons or not GetMacroIconInfo then return 1 end
    for index = 1, GetNumMacroIcons() do
        if GetMacroIconInfo(index) == icon then return index end
    end
    return 1
end

local function RestoreMacros(set)
    local bodiesByName = {}
    for _, action in pairs(set) do
        if action.type == "macro" and action.name then
            local bodies = bodiesByName[action.name] or {}
            bodiesByName[action.name] = bodies
            bodies[action.body or ""] = true
        end
    end

    for _, action in pairs(set) do
        if action.type == "macro" and not FindMacro(action, true) then
            local name = action.name ~= "" and action.name or " "
            local icon = MacroIconIndex(action.icon)
            local nameID = macroNameCache[action.name or ""]
            local bodies = bodiesByName[action.name or ""]
            local bodyCount = 0
            for _ in pairs(bodies or {}) do bodyCount = bodyCount + 1 end

            -- A uniquely named macro is the same logical macro saved by the
            -- profile. Update its saved definition instead of accepting the
            -- current (usually other-specialization) body as a match.
            if nameID and bodyCount == 1 and EditMacro then
                pcall(EditMacro, nameID, name, icon, action.body or "")
                ClearCaches()
                CacheSpells()
                CacheMacros()
            end

            if not FindMacro(action, true) and CreateMacro then
                local _, charCount = GetNumMacros()
                local perCharacter = (charCount or 0) < 36
                local ok = pcall(CreateMacro, name, icon, action.body or "", nil, perCharacter)
                if not ok then pcall(CreateMacro, name, icon, action.body or "", perCharacter) end
                ClearCaches()
                CacheSpells()
                CacheMacros()
            end
        end
    end
end

local function AddRestoreError(message)
    table.insert(restoreErrors, message)
end

local function RestoreAction(slot, action, options)
    if action.type == "spell" then
        local index
        if not options.restoreHighestRank and action.rank and action.rank ~= "" then
            index = spellCache[action.name .. action.rank]
        end
        index = index or spellCache[action.name] or spellCache[string.lower(action.name or "")]
        if index then PickupSpell(index, BOOKTYPE_SPELL) end
    elseif action.type == "item" then
        if PickupItem then PickupItem(action.id) end
    elseif action.type == "macro" then
        local macroID = FindMacro(action, options.restoreMacros)
        if macroID then PickupMacro(macroID) end
    elseif action.type == "equipmentset" and GetNumEquipmentSets and PickupEquipmentSet then
        local setIndex
        for index = 1, GetNumEquipmentSets() do
            if GetEquipmentSetInfo(index) == action.name then setIndex = index; break end
        end
        if setIndex then PickupEquipmentSet(setIndex) end
    elseif action.type == "companion" and PickupCompanion then
        PickupCompanion(action.subType, action.id)
    end

    local cursorType = GetCursorInfo()
    if cursorType == action.type then
        PlaceAction(slot)
        return
    end
    ClearCursor()
    local label = action.name or action.id or action.type
    AddRestoreError("Unable to restore " .. tostring(label) .. " to slot " .. slot .. ".")
end

function AAB.RestoreProfile(name, quiet, explicitSet)
    name = Trim(name)
    local set = explicitSet or Profiles()[name]
    if not set then return false, "No profile called '" .. name .. "'." end
    if InCombatLockdown and InCombatLockdown() then return false, "Action bars cannot be restored in combat." end

    for index = #restoreErrors, 1, -1 do table.remove(restoreErrors, index) end
    ClearCaches()
    CacheSpells()
    CacheMacros()
    local options = GetDB().options
    if options.restoreMacros then RestoreMacros(set) end

    ClearCursor()
    local oldSound = GetCVar and GetCVar("Sound_EnableAllSound")
    if oldSound and SetCVar then SetCVar("Sound_EnableAllSound", "0") end
    for slot = 1, MAX_ACTION_SLOTS do
        if IsManagedSlot(slot) then
            local actionType, id = GetActionInfo(slot)
            if actionType or id then PickupAction(slot); ClearCursor() end
            if set[slot] then RestoreAction(slot, set[slot], options) end
        end
    end
    if oldSound and SetCVar then SetCVar("Sound_EnableAllSound", oldSound) end
    ClearCursor()

    if not quiet then
        if #restoreErrors == 0 then
            Print("Restored profile " .. name .. ".")
        else
            Print("Restored profile " .. name .. " with " .. #restoreErrors .. " missing action(s). Use /aab errors for details.", "warn")
        end
    end
    return true, #restoreErrors
end

function AAB.GetRestoreErrors()
    return restoreErrors
end

function AAB.GetOptions()
    return GetDB().options
end

function AAB.IsEnabled()
    return GetDB().options.enabled ~= false
end

function AAB.SetOption(key, value)
    if key == "enabled" or key == "restoreMacros" or key == "restoreHighestRank" then
        GetDB().options[key] = value == true
    end
end

function AAB.GetCurrentSpec()
    local id = ActiveSpecID() or 1
    return id, SpecName(id)
end

function AAB.GetSpecAssignment(id)
    id = id or ActiveSpecID() or 1
    local specs = GetCharDB().specs
    specs[id] = type(specs[id]) == "table" and specs[id] or {}
    return specs[id]
end

function AAB.SetSpecProfile(id, profile)
    local assignment = AAB.GetSpecAssignment(id)
    if profile == "default" or profile == nil or Profiles()[profile] then
        assignment.profile = profile
        return true
    end
    return false, "That action-bar profile no longer exists."
end

function AAB.SaveSpecDefault(id, quiet)
    id = id or ActiveSpecID() or 1
    local set = GetCharDB().specProfiles[id] or {}
    GetCharDB().specProfiles[id] = set
    SaveLayout(set)
    if not quiet then Print("Saved the default layout for " .. SpecName(id) .. ".") end
    return true
end

function AAB.RestoreSpecDefault(id, quiet)
    id = id or ActiveSpecID() or 1
    local set = GetCharDB().specProfiles[id]
    if not set then return false, "No default layout has been saved for " .. SpecName(id) .. "." end
    return AAB.RestoreProfile(SpecName(id) .. " default", quiet, set)
end

function AAB.ApplyCurrentSpec()
    local id = ActiveSpecID() or 1
    local assignment = AAB.GetSpecAssignment(id)
    if assignment.profile == "default" then
        local ok, err = AAB.RestoreSpecDefault(id, true)
        if not ok then Print(err, "warn") else Print("Restored the default layout for " .. SpecName(id) .. ".") end
    elseif assignment.profile then
        local ok, err = AAB.RestoreProfile(assignment.profile)
        if not ok then Print(err, "warn") end
    end
end

local eventFrame = CreateFrame("Frame")

local function ProcessPendingRestore(self)
    if not AAB.IsEnabled() then
        pendingRestoreAt = nil
        specChanged = false
        self:SetScript("OnUpdate", nil)
    elseif pendingRestoreAt and GetTime() >= pendingRestoreAt then
        pendingRestoreAt = nil
        specChanged = false
        self:SetScript("OnUpdate", nil)
        AAB.ApplyCurrentSpec()
    end
end

local function ScheduleSpecRestore()
    pendingRestoreAt = GetTime() + 2
    eventFrame:SetScript("OnUpdate", ProcessPendingRestore)
end
eventFrame:RegisterEvent("PLAYER_LOGIN")
if SpecializationUtil then eventFrame:RegisterEvent("ASCENSION_CA_SPECIALIZATION_ACTIVE_ID_CHANGED") end
eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:SetScript("OnEvent", function(_, event, unit, spell)
    if event == "PLAYER_LOGIN" then
        GetDB(); GetCharDB()
    elseif event == "UNIT_SPELLCAST_START" and AAB.IsEnabled()
        and unit == "player" and spell and string.find(spell, "Specialization", 1, true)
    then
        local id = ActiveSpecID() or 1
        local assignment = AAB.GetSpecAssignment(id)
        if assignment.autoSave then AAB.SaveSpecDefault(id, true) end
        specChanged = false
    elseif event == "ASCENSION_CA_SPECIALIZATION_ACTIVE_ID_CHANGED" and AAB.IsEnabled() then
        specChanged = true
        ScheduleSpecRestore()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and AAB.IsEnabled()
        and unit == "player" and spell == "Activate Mystic Enchant Preset" and specChanged
    then
        ScheduleSpecRestore()
    end
end)
local function Help()
    Print("Commands:")
    print("  /aab save <name> - save the current action bars")
    print("  /aab restore <name> - restore a saved layout")
    print("  /aab delete <name> | rename <old> <new> | list | errors")
    print("  /aab options - open the AutoActionBars settings page")
end

SLASH_AUTOACTIONBARS1 = "/autoactionbars"
SLASH_AUTOACTIONBARS2 = "/aab"
SlashCmdList.AUTOACTIONBARS = function(message)
    message = Trim(message)
    local command, rest = string.match(message, "^(%S+)%s*(.-)$")
    command = string.lower(command or "")
    if command == "save" then
        local ok, err = AAB.SaveProfile(rest); if not ok then Print(err, "warn") end
    elseif command == "restore" then
        local ok, err = AAB.RestoreProfile(rest); if not ok then Print(err, "warn") end
    elseif command == "delete" then
        local ok, err = AAB.DeleteProfile(rest); if not ok then Print(err, "warn") end
    elseif command == "rename" then
        local oldName, newName = string.match(rest, "^(%S+)%s+(.+)$")
        local ok, err = AAB.RenameProfile(oldName, newName); if not ok then Print(err, "warn") end
    elseif command == "list" then
        local names = SortedProfileNames()
        Print(#names > 0 and ("Profiles: " .. table.concat(names, ", ")) or "No profiles saved for this class.")
    elseif command == "errors" then
        if #restoreErrors == 0 then Print("No restore errors.")
        else for _, err in ipairs(restoreErrors) do print("  " .. err) end end
    elseif command == "options" or command == "config" then
        if AutoCore and AutoCore.Settings then AutoCore.Settings.Open("Action Bars") end
    else
        Help()
    end
end
