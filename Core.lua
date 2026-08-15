----------------------------------------------------------------------
-- Core.lua
-- ========
-- Shared logic for the AutoSell and AutoRoll modules.
--
--   * Hidden tooltip + exact "unusable" red (255,32,32) scan
--   * Item data builder from a link (optional bag/inv location)
--   * Binding + usability tooltip scan
--   * Rule filter matching
--   * Per-character profile config resolution
--   * Active quest item protection (Quest/QuestDB.lua)
--   * Appearance/vanity learning (Ascension/retail only, guarded)
--   * AutoBindClear – single place for binding-confirmation popups
--   * Upgrade scoring via tooltip (bag/inventory location for
--     Ascension scaled items; last "Requires Level" line wins)
--
-- WoW 3.3.5a compatible.
----------------------------------------------------------------------
-- Auto-accept Dungeon Finder role check
----------------------------------------------------------------
-- Confirms whatever roles the Dungeon Finder auto-assigned you.

local coreConfig = AutoCoreConfig or {}

local function ConfigEnabled(key)
    if AutoCore and AutoCore.GetSetting then
        return AutoCore.GetSetting("core", key, coreConfig[key]) == true
    end
    return coreConfig[key] == true
end

local roleCheckFrame = CreateFrame("Frame")
roleCheckFrame:RegisterEvent("LFG_ROLE_CHECK_SHOW")

roleCheckFrame:SetScript("OnEvent", function(self, event)
    if event == "LFG_ROLE_CHECK_SHOW" and ConfigEnabled("autoAcceptLFGRoleCheck") and CompleteLFGRoleCheck then
        local role = AutoCore and AutoCore.GetSetting
            and AutoCore.GetSetting("core", "lfgAutoRole", coreConfig.lfgAutoRole)
            or coreConfig.lfgAutoRole
        if role and role ~= "current" and SetLFGRoles then
            SetLFGRoles(false, role == "tank", role == "healer", role == "damage")
        end
        CompleteLFGRoleCheck(true)
    end
end)

-- Case-insensitive "is this player a friend or guildmate?" test, shared by the
-- party-invite and whisper-invite conveniences.
local function IsFriendOrGuild(name)
    if not name or name == "" then return false end
    local target = string.lower(name)
    if GetNumFriends then
        if ShowFriends then ShowFriends() end
        for i = 1, (GetNumFriends() or 0) do
            local friendName = GetFriendInfo(i)
            if friendName and string.lower(friendName) == target then return true end
        end
    end
    if IsInGuild and IsInGuild() and GetNumGuildMembers then
        for i = 1, (GetNumGuildMembers() or 0) do
            local memberName = GetGuildRosterInfo(i)
            if memberName and string.lower(memberName) == target then return true end
        end
    end
    return false
end

----------------------------------------------------------------------
-- Group/dialog convenience automation
----------------------------------------------------------------------
local dialogFrame = CreateFrame("Frame")
dialogFrame:RegisterEvent("READY_CHECK")
dialogFrame:RegisterEvent("CONFIRM_SUMMON")
dialogFrame:RegisterEvent("GOSSIP_SHOW")
dialogFrame:RegisterEvent("RESURRECT_REQUEST")
dialogFrame:RegisterEvent("DUEL_REQUESTED")
dialogFrame:RegisterEvent("PARTY_INVITE_REQUEST")
dialogFrame:RegisterEvent("UI_ERROR_MESSAGE")

local function GossipHasQuests()
    return (GetGossipActiveQuests and select(1, GetGossipActiveQuests()) ~= nil)
        or (GetGossipAvailableQuests and select(1, GetGossipAvailableQuests()) ~= nil)
end

local function SelectOnlySafeGossipOption()
    if not GetGossipOptions or not SelectGossipOption or GossipHasQuests() then
        return
    end

    local options = { GetGossipOptions() }
    -- GetGossipOptions returns text/type pairs. Only act when there is exactly
    -- one choice; typed services remain individually opt-in.
    if #options ~= 2 then return end
    local optionType = options[2]
    local settingByType = {
        gossip = "autoSelectSingleGossip",
        vendor = "autoGossipVendor",
        trainer = "autoGossipTrainer",
        taxi = "autoGossipTaxi",
        banker = "autoGossipBanker",
        battlemaster = "autoGossipBattlemaster",
        binder = "autoGossipInnkeeper",
    }
    local setting = settingByType[optionType]
    if setting and ConfigEnabled(setting) then
        if optionType == "taxi" and ConfigEnabled("autoDismount")
            and IsMounted and IsMounted() and Dismount
        then
            Dismount()
        end
        SelectGossipOption(1)
    end
end

local function IsMountedActionError(message)
    if not message then return false end
    if (ERR_NOT_WHILE_MOUNTED and message == ERR_NOT_WHILE_MOUNTED)
        or (ERR_ATTACK_MOUNTED and message == ERR_ATTACK_MOUNTED)
        or (ERR_TAXIPLAYERALREADYMOUNTED and message == ERR_TAXIPLAYERALREADYMOUNTED)
    then
        return true
    end
    -- Ascension adds custom mounted-action errors. The IsMounted guard below
    -- keeps this localized fallback from reacting after the player dismounts.
    return string.find(string.lower(message), "mount", 1, true) ~= nil
end

local function TryAutoDismount(message)
    if not ConfigEnabled("autoDismount") or not Dismount or not IsMounted or not IsMounted() then return end
    if IsMountedActionError(message) then Dismount() end
end

local function NormalizePlayerName(name)
    if not name then return nil end
    return string.lower((string.gsub(name, "%-.*$", "")))
end

local function FindGroupUnitByName(name)
    local wanted = NormalizePlayerName(name)
    if not wanted then return nil end
    if NormalizePlayerName(UnitName("player")) == wanted then return "player" end
    for i = 1, (GetNumRaidMembers and GetNumRaidMembers() or 0) do
        local unit = "raid" .. i
        if NormalizePlayerName(UnitName(unit)) == wanted then return unit end
    end
    for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
        local unit = "party" .. i
        if NormalizePlayerName(UnitName(unit)) == wanted then return unit end
    end
    return nil
end

local function IsQueuedForActivity()
    if GetBattlefieldStatus then
        for i = 1, (MAX_BATTLEFIELD_QUEUES or 3) do
            local status = GetBattlefieldStatus(i)
            if status == "queued" or status == "confirm" then return true end
        end
    end
    if GetLFGMode then
        local mode, submode = GetLFGMode()
        local value = string.lower(tostring(mode or "") .. " " .. tostring(submode or ""))
        if string.find(value, "queue", 1, true)
            or string.find(value, "proposal", 1, true)
            or string.find(value, "rolecheck", 1, true)
        then
            return true
        end
    end
    return false
end

local function CanAutoAcceptResurrect()
    if ConfigEnabled("autoAcceptResurrectInstancesOnly") then
        local inInstance, instanceType = IsInInstance()
        if not inInstance or (instanceType ~= "party" and instanceType ~= "raid" and instanceType ~= "pvp") then
            return false
        end
    end
    if ConfigEnabled("autoAcceptResurrectOutOfCombatOnly") and UnitAffectingCombat("player") then
        return false
    end
    if ConfigEnabled("autoAcceptResurrectVisibleOffererOnly") then
        local offerer = ResurrectGetOfferer and ResurrectGetOfferer() or nil
        local unit = FindGroupUnitByName(offerer)
        if not unit or (UnitIsVisible and not UnitIsVisible(unit)) then return false end
        if UnitAffectingCombat and UnitAffectingCombat(unit) then return false end
    end
    return true
end

local summonPending = false
local summonTimerFrame = CreateFrame("Frame")
local function ClearPendingSummon()
    summonPending = false
    summonTimerFrame:SetScript("OnUpdate", nil)
end

local function AcceptPendingSummon()
    if ConfirmSummon then ConfirmSummon() end
    if StaticPopup_Hide then StaticPopup_Hide("CONFIRM_SUMMON") end
    ClearPendingSummon()
end

local function ScheduleSummonAcceptance()
    if not ConfigEnabled("autoConfirmSummon") then return end
    local mode = AutoCore and AutoCore.GetSetting
        and AutoCore.GetSetting("core", "summonAcceptMode", coreConfig.summonAcceptMode)
        or coreConfig.summonAcceptMode
    if mode == "immediate" or not GetSummonConfirmTimeLeft then
        AcceptPendingSummon()
        return
    end
    summonPending = true
    summonTimerFrame:SetScript("OnUpdate", function()
        if not summonPending or not ConfigEnabled("autoConfirmSummon") then
            ClearPendingSummon()
            return
        end
        local remaining = GetSummonConfirmTimeLeft() or 0
        if remaining <= 0 then ClearPendingSummon(); return end
        local threshold = AutoCore and AutoCore.GetSetting
            and AutoCore.GetSetting("core", "summonAcceptSeconds", coreConfig.summonAcceptSeconds)
            or coreConfig.summonAcceptSeconds
        if remaining <= (tonumber(threshold) or 3) then AcceptPendingSummon() end
    end)
end

dialogFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "READY_CHECK" and ConfigEnabled("autoAcceptReadyCheck") then
        if ConfirmReadyCheck then
            ConfirmReadyCheck(1)
        elseif ReadyCheckFrameYesButton and ReadyCheckFrameYesButton:IsShown() then
            ReadyCheckFrameYesButton:Click()
        end
    elseif event == "CONFIRM_SUMMON" then
        ScheduleSummonAcceptance()
    elseif event == "GOSSIP_SHOW" then
        SelectOnlySafeGossipOption()
    elseif event == "RESURRECT_REQUEST" and ConfigEnabled("autoAcceptResurrect") and CanAutoAcceptResurrect() then
        if AcceptResurrect then AcceptResurrect() end
        if StaticPopup_Hide then
            StaticPopup_Hide("RESURRECT_NO_TIMER")
            StaticPopup_Hide("RESURRECT")
        end
    elseif event == "DUEL_REQUESTED" and ConfigEnabled("autoDeclineDuels")
        and not (ConfigEnabled("autoDeclineDuelsShiftBypass") and IsShiftKeyDown and IsShiftKeyDown())
    then
        if CancelDuel then CancelDuel() end
        if StaticPopup_Hide then StaticPopup_Hide("DUEL_REQUESTED") end
    elseif event == "PARTY_INVITE_REQUEST" and ConfigEnabled("autoAcceptGroupInvite") then
        local queueAllowed = ConfigEnabled("autoAcceptInviteWhileQueued") or not IsQueuedForActivity()
        if queueAllowed and (not ConfigEnabled("autoAcceptInviteFriendsOnly") or IsFriendOrGuild(arg1)) then
            if AcceptGroup then AcceptGroup() end
            if StaticPopup_Hide then StaticPopup_Hide("PARTY_INVITE") end
        end
    elseif event == "UI_ERROR_MESSAGE" then
        TryAutoDismount(arg1)
    end
end)

local cvarFrame = CreateFrame("Frame")
cvarFrame:RegisterEvent("PLAYER_LOGIN")

cvarFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        -- Config.lua supplies every default. WoW builds an addon's file list
        -- when the client starts, so a newly added file is skipped until the
        -- game is fully restarted - a /reload is not enough. Say so plainly
        -- rather than letting each module fail on a nil config in turn.
        if not AutoSellConfig or not AutoRollConfig or not AutoUpgradeConfig
            or not AutoJunkConfig or not AutoLootConfig or not AutoCoreConfig or not AutoQuestConfig or not AutoBuffConfig
        then
            print("|cffff4040Automation:|r Config.lua did not load, so no defaults are available.")
            print("  Fully exit and restart the game client (a /reload will not pick up a new file).")
            print("  Settings are left untouched until it loads, so nothing is lost.")
            return
        end
        if AutoCore.InitSession then AutoCore.InitSession() end
        if ConfigEnabled("setCameraDistance") then
            local cameraDistance = AutoCore and AutoCore.GetSetting
                and AutoCore.GetSetting("core", "cameraDistanceMax", coreConfig.cameraDistanceMax)
                or coreConfig.cameraDistanceMax
            SetCVar("CameraDistanceMax", tostring(cameraDistance or 50))
        end
        local showSummary = AutoCore and AutoCore.GetSetting
            and AutoCore.GetSetting("core", "showLoginSummary", coreConfig.showLoginSummary)
            or coreConfig.showLoginSummary
        if showSummary ~= false and AutoCore and AutoCore.PrintStatus then
            AutoCore.PrintStatus("Loaded")
        end
        if AutoCore and AutoCore.ValidateAllConfigs then
            local issues = AutoCore.ValidateAllConfigs(false)
            if issues > 0 then
                AutoCore.Warn(nil, "Configuration validation found " .. issues .. " issue(s); run /ae validate for details.")
            end
        end
    end
end)

AutoCore = AutoCore or {}
local Core = AutoCore

----------------------------------------------------------------------
-- Shared output and combined module status
----------------------------------------------------------------------
local LOG_COLORS = {
    info = "|cff00ff00",
    warn = "|cffffcc00",
    error = "|cffff4040",
}

function Core.Log(moduleName, message, level)
    local color = LOG_COLORS[level or "info"] or LOG_COLORS.info
    local label = moduleName and ("Automation/" .. moduleName) or "Automation"
    print(color .. label .. ":|r " .. tostring(message))
end

function Core.Info(moduleName, message)
    Core.Log(moduleName, message, "info")
end

function Core.Warn(moduleName, message)
    Core.Log(moduleName, message, "warn")
end

function Core.Debug(moduleName, message)
    if Core.GetSetting and Core.GetSetting("core", "verbose", coreConfig.verbose) then
        Core.Log(moduleName, message, "info")
    end
end

----------------------------------------------------------------------
-- Battleground auto-release
----------------------------------------------------------------------
local deathFrame = CreateFrame("Frame")
deathFrame:RegisterEvent("PLAYER_DEAD")
deathFrame:SetScript("OnEvent", function()
    if not ConfigEnabled("autoReleaseInBattleground") then return end
    -- Only in battlegrounds: arenas resurrect you automatically, and world or
    -- dungeon deaths usually want a manual corpse run or a healer's rez.
    local _, instanceType = IsInInstance()
    if instanceType == "pvp" and RepopMe then RepopMe() end
end)

----------------------------------------------------------------------
-- Skip cinematics and in-game movies
----------------------------------------------------------------------
local cinematicFrame = CreateFrame("Frame")
cinematicFrame:RegisterEvent("CINEMATIC_START")
cinematicFrame:RegisterEvent("PLAY_MOVIE")
cinematicFrame:SetScript("OnEvent", function(_, event)
    if not ConfigEnabled("skipCinematics") then return end
    if event == "CINEMATIC_START" then
        if StopCinematic then StopCinematic() end
    elseif event == "PLAY_MOVIE" then
        if GameMovieFinished then GameMovieFinished() end
    end
end)

----------------------------------------------------------------------
-- Auto-invite on whisper keyword
----------------------------------------------------------------------
local inviteThrottle = {}
local INVITE_THROTTLE = 10   -- seconds; ignore repeat keywords from the same sender
local whisperFrame = CreateFrame("Frame")
whisperFrame:RegisterEvent("CHAT_MSG_WHISPER")
whisperFrame:SetScript("OnEvent", function(_, _, message, sender)
    if not ConfigEnabled("autoInviteOnWhisper") or not sender or not message then return end
    local keyword = Core.GetSetting("core", "autoInviteKeyword", coreConfig.autoInviteKeyword)
    if not keyword or keyword == "" then return end
    -- Plain (non-pattern) substring match, so "inv" also fires on "invite me".
    if not string.find(string.lower(message), string.lower(keyword), 1, true) then return end

    -- Only invite when we are able to: solo, or leading a party that has room.
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then return end
    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    if party > 0 then
        if not (IsPartyLeader and IsPartyLeader()) then return end
        if party >= 4 then return end
    end

    if ConfigEnabled("autoInviteFriendsOnly") and not IsFriendOrGuild(sender) then return end

    local now = GetTime()
    -- Sender names only need to survive for the throttle window. Without
    -- pruning, every unique whisper sender remained referenced until logout.
    for name, invitedAt in pairs(inviteThrottle) do
        if now - invitedAt >= INVITE_THROTTLE then inviteThrottle[name] = nil end
    end
    if inviteThrottle[sender] and (now - inviteThrottle[sender]) < INVITE_THROTTLE then return end
    inviteThrottle[sender] = now
    if InviteUnit then InviteUnit(sender) end
end)

----------------------------------------------------------------------
-- Auto-learn available trainer spells (cheapest first)
----------------------------------------------------------------------
local trainerFrame = CreateFrame("Frame")
trainerFrame:RegisterEvent("TRAINER_SHOW")
trainerFrame:SetScript("OnEvent", function()
    if not ConfigEnabled("autoLearnTrainerSpells") then return end
    if not GetNumTrainerServices or not BuyTrainerService then return end
    if SetTrainerServiceTypeFilter then SetTrainerServiceTypeFilter("available", 1) end

    -- Collect every learnable service and buy them cheapest-first, so a limited
    -- purse learns as many spells as possible. Indices stay stable until the
    -- next TRAINER_UPDATE, so buying by stored index within one pass is safe.
    local services = {}
    for i = 1, (GetNumTrainerServices() or 0) do
        local name, _, category = GetTrainerServiceInfo(i)
        if name and category == "available" then
            local cost = (GetTrainerServiceCost and GetTrainerServiceCost(i)) or 0
            table.insert(services, { index = i, cost = cost or 0 })
        end
    end
    table.sort(services, function(a, b) return a.cost < b.cost end)

    local learned, spent = 0, 0
    for _, service in ipairs(services) do
        if GetMoney() < service.cost then break end
        BuyTrainerService(service.index)
        learned = learned + 1
        spent = spent + service.cost
    end
    if learned > 0 then
        Core.Info("Trainer", "Learned " .. learned .. " spell(s)"
            .. (spent > 0 and (" for " .. GetCoinTextureString(spent)) or "") .. ".")
    end
end)

local function BasicMode(db)
    -- ApplyProfile resolves the config default into the active profile section.
    -- Once present, that profile value is the runtime source of truth.
    return db and db.enabled and "active" or "off"
end

function Core.GetStatusSummary()
    local junkMode = BasicMode(AutoJunk and AutoJunk.db)
    local lootMode = BasicMode(AutoLoot and AutoLoot.db)
    local sellMode = BasicMode(AutoSell and AutoSell.db)
    local questMode = BasicMode(AutoQuest and AutoQuest.db)
    local buffMode = BasicMode(AutoBuff and AutoBuff.db)

    local rollMode = "off"
    if AutoRoll and AutoRoll.db and AutoRoll.db.enabled then
        rollMode = AutoRoll.db.notifyOnly and "notify" or "active"
    end

    local upgradeMode = AutoUpgrade and AutoUpgrade.GetMode and AutoUpgrade.GetMode() or "off"

    return "Junk " .. junkMode
        .. " | Loot " .. lootMode
        .. " | Sell " .. sellMode
        .. " | Roll " .. rollMode
        .. " | Quest " .. questMode
        .. " | Buff " .. buffMode
        .. " | Upgrade " .. upgradeMode
end


function Core.PrintStatus(prefix)
    local message = Core.GetStatusSummary()
    if prefix and prefix ~= "" then
        message = prefix .. " - " .. message
    end
    Core.Info(nil, message)
end

----------------------------------------------------------------------
-- Session tracker
----------------------------------------------------------------------
-- Runtime only (never saved): totals since this login, surfaced on the minimap
-- button tooltip and via /ae session. Modules call Core.SessionAdd as they act.
Core.Session = Core.Session or { startMoney = 0, sold = 0, soldCopper = 0, junk = 0, repairCopper = 0 }

function Core.InitSession()
    Core.Session = { startMoney = GetMoney() or 0, sold = 0, soldCopper = 0, junk = 0, repairCopper = 0 }
end

function Core.SessionAdd(field, amount)
    if not Core.Session or not field or type(amount) ~= "number" then return end
    Core.Session[field] = (Core.Session[field] or 0) + amount
end

-- Returns display lines for the tooltip / slash command.
function Core.GetSessionSummary()
    local s = Core.Session or {}
    local net = (GetMoney() or 0) - (s.startMoney or 0)
    local netText = net >= 0
        and ("|cff40ff40+" .. GetCoinTextureString(net) .. "|r")
        or ("|cffff4040-" .. GetCoinTextureString(-net) .. "|r")
    return {
        "Net gold: " .. netText,
        "Sold: " .. (s.sold or 0) .. " for " .. GetCoinTextureString(s.soldCopper or 0),
        "Junked: " .. (s.junk or 0) .. " item(s)",
        "Repairs: " .. GetCoinTextureString(s.repairCopper or 0),
    }
end

SLASH_AUTOEVERYTHING1 = "/autoeverything"
SLASH_AUTOEVERYTHING2 = "/ae"
SlashCmdList["AUTOEVERYTHING"] = function(msg)
    msg = string.lower(strtrim(msg or ""))
    if msg == "" or msg == "config" or msg == "settings" or msg == "options" then
        if Core.Settings and Core.Settings.Open then Core.Settings.Open()
        else Core.Warn(nil, "Settings are not available yet.") end
    elseif msg == "auction" or msg == "ah" then
        if AutoAuction and AutoAuction.Open then AutoAuction.Open()
        else Core.Warn(nil, "Auction panel is not available yet.") end
    elseif msg == "actionbars" or msg == "bars" then
        if Core.Settings and Core.Settings.Open then Core.Settings.Open("Action Bars")
        else Core.Warn(nil, "AutoActionBars settings are not available yet.") end
    elseif msg == "buff" or msg == "buffs" then
        if Core.Settings and Core.Settings.Open then Core.Settings.Open("Buff")
        else Core.Warn(nil, "AutoBuff settings are not available yet.") end
    elseif msg == "status" then
        Core.PrintStatus()
    elseif msg == "session" then
        Core.Info(nil, "This session:")
        for _, line in ipairs(Core.GetSessionSummary()) do print("  " .. line) end
    elseif msg == "validate" then
        Core.ValidateAllConfigs(true)
    elseif string.sub(msg, 1, 7) == "profile" then
        local wanted = strtrim(string.sub(msg, 8))
        local names = Core.GetProfileNames()
        if wanted == "" then
            Core.Info(nil, "Current profile: " .. tostring(Core.GetProfileName()))
            print("  Available: " .. table.concat(names, ", "))
            print("  Switch with /ae profile <name>")
        else
            local match
            for _, name in ipairs(names) do
                if string.lower(name) == wanted then match = name end
            end
            if match then Core.SetProfile(match)
            else Core.Warn(nil, "No profile called '" .. wanted .. "'. Available: " .. table.concat(names, ", ")) end
        end
    elseif msg == "verbose" then
        local on = Core.GetSetting("core", "verbose", coreConfig.verbose) ~= true
        Core.SetSetting("core", "verbose", on)
        Core.Info(nil, "Verbose diagnostic messages " .. (on and "enabled." or "disabled."))
    else
        Core.Info(nil, "Commands: /ae config | /ae auction | /ae actionbars | /ae buff | /ae status | /ae session | /ae profile [name] | /ae validate | /ae verbose")
        print("  Module controls remain available through /autoactionbars, /autobuff, /autojunk, /autosell, /autoroll, /autoquest, and /autoupgrade.")
    end
end

Core.tooltip = CreateFrame("GameTooltip", "AutoCoreTooltip", nil, "GameTooltipTemplate")
Core.tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

local SOULBOUND_STR = SOULBOUND or "Soulbound"
local BOP_STR = ITEM_BIND_ON_PICKUP or "Binds when picked up"
local BOE_STR = ITEM_BIND_ON_EQUIP or "Binds when equipped"
local BOU_STR = ITEM_BIND_ON_USE or "Binds when used"
local QUEST_ITEM_STR = ITEM_QUEST_ITEM_TEMPLATE or "Quest Item"

----------------------------------------------------------------------
-- Fill the shared tooltip from link and/or location.
-- Prefer the source-specific setter whenever a real item location is known.
-- Ascension resolves rolled/scaled values through these setters; SetHyperlink
-- may expose only the base template and is therefore strictly the fallback.
-- Returns false if none of the methods work.
----------------------------------------------------------------------
local function SetTooltipItem(link, location)
    local tooltip = Core.tooltip
    tooltip:ClearLines()
    if location and location.rollID and tooltip.SetLootRollItem then
        tooltip:SetLootRollItem(location.rollID)
        return true
    elseif location and location.questType and location.questIndex and tooltip.SetQuestItem then
        tooltip:SetQuestItem(location.questType, location.questIndex)
        return true
    elseif location and location.questLogItemType and location.questLogIndex and tooltip.SetQuestLogItem then
        tooltip:SetQuestLogItem(location.questLogItemType, location.questLogIndex)
        return true
    elseif location and location.invSlot and tooltip.SetInventoryItem then
        tooltip:SetInventoryItem("player", location.invSlot)
        return true
    elseif location and location.bag ~= nil and location.slot ~= nil and tooltip.SetBagItem then
        tooltip:SetBagItem(location.bag, location.slot)
        return true
    elseif location and location.merchantIndex and tooltip.SetMerchantItem then
        tooltip:SetMerchantItem(location.merchantIndex)
        return true
    elseif location and location.buybackIndex and tooltip.SetBuybackItem then
        tooltip:SetBuybackItem(location.buybackIndex)
        return true
    elseif location and location.inboxIndex and location.attachmentIndex and tooltip.SetInboxItem then
        tooltip:SetInboxItem(location.inboxIndex, location.attachmentIndex)
        return true
    elseif location and location.sendMailIndex and tooltip.SetSendMailItem then
        tooltip:SetSendMailItem(location.sendMailIndex)
        return true
    elseif location and location.tradePlayerIndex and tooltip.SetTradePlayerItem then
        tooltip:SetTradePlayerItem(location.tradePlayerIndex)
        return true
    elseif location and location.tradeTargetIndex and tooltip.SetTradeTargetItem then
        tooltip:SetTradeTargetItem(location.tradeTargetIndex)
        return true
    elseif location and location.auctionType and location.auctionIndex and tooltip.SetAuctionItem then
        tooltip:SetAuctionItem(location.auctionType, location.auctionIndex)
        return true
    elseif location and location.auctionSellItem and tooltip.SetAuctionSellItem then
        tooltip:SetAuctionSellItem()
        return true
    elseif location and location.lootSlot and tooltip.SetLootItem then
        tooltip:SetLootItem(location.lootSlot)
        return true
    elseif location and location.tradeSkillIndex and location.reagentIndex and tooltip.SetTradeSkillReagent then
        tooltip:SetTradeSkillReagent(location.tradeSkillIndex, location.reagentIndex)
        return true
    elseif location and location.tradeSkillIndex and tooltip.SetTradeSkillItem then
        tooltip:SetTradeSkillItem(location.tradeSkillIndex)
        return true
    elseif location and location.craftIndex and location.reagentIndex and tooltip.SetCraftReagent then
        tooltip:SetCraftReagent(location.craftIndex, location.reagentIndex)
        return true
    elseif location and location.craftIndex and tooltip.SetCraftItem then
        tooltip:SetCraftItem(location.craftIndex)
        return true
    elseif location and location.guildBankTab and location.guildBankSlot and tooltip.SetGuildBankItem then
        tooltip:SetGuildBankItem(location.guildBankTab, location.guildBankSlot)
        return true
    elseif link then
        tooltip:SetHyperlink(link)
        return true
    end
    return false
end

----------------------------------------------------------------------
-- Search the shared hidden tooltip for plain text.
-- Used for Ascension-specific item flags that are only exposed in tooltip
-- text (for example Bloodforged). Checks both left and right columns and is
-- case-insensitive.
----------------------------------------------------------------------
function Core.TooltipContains(link, location, needle)
    if not needle or needle == "" then return false end
    if not SetTooltipItem(link, location) then return false end

    local wanted = string.lower(tostring(needle))
    local numLines = Core.tooltip:NumLines()
    for i = 1, numLines do
        local leftText = _G["AutoCoreTooltipTextLeft" .. i]
        local rightText = _G["AutoCoreTooltipTextRight" .. i]
        for _, text in ipairs({ leftText, rightText }) do
            if text then
                local str = text:GetText()
                if str and string.find(string.lower(str), wanted, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

function Core.IsBloodforgedItem(link, location)
    return Core.TooltipContains(link, location, "bloodforged")
end

----------------------------------------------------------------------
-- Color check: exact "unusable" red (255, 32, 32)
----------------------------------------------------------------------
function Core.IsUnusableRed(r, g, b, a)
    if not r or not g or not b or not a then
        return false
    end
    r = math.floor(r * 255 + 0.5)
    g = math.floor(g * 255 + 0.5)
    b = math.floor(b * 255 + 0.5)
    a = math.floor(a * 255 + 0.5)
    return (r == 255 and g == 32 and b == 32 and a == 255)
end

----------------------------------------------------------------------
-- Get "Requires Level N" from the tooltip.
-- On Ascension, tooltips can show a base level early and the real
-- scaled level later (e.g. line 9 = 46). We take the LAST match.
-- location optional: { bag=B, slot=S }, { invSlot=N }, or { rollID=R }
----------------------------------------------------------------------
function Core.GetTooltipReqLevel(link, location)
    if not SetTooltipItem(link, location) then
        return nil
    end

    local reqLevel = nil
    local numLines = Core.tooltip:NumLines()
    for i = 1, numLines do
        local leftText = _G["AutoCoreTooltipTextLeft" .. i]
        if leftText then
            local str = leftText:GetText()
            if str then
                local req = str:match("Requires Level (%d+)")
                if req then
                    reqLevel = tonumber(req)
                end
            end
        end
    end
    return reqLevel
end

----------------------------------------------------------------------
-- Get item info from a link (+ optional location for accurate reqLevel)
----------------------------------------------------------------------
function Core.GetItemData(link, location, tooltipSnapshot)
    local name, _, quality, iLevel, reqLevel, itemType, subType, maxStack, equipSlot, texture, vendorPrice = GetItemInfo(link)
    if not name then
        return nil
    end
    local id = tonumber(link:match("|Hitem:(%d+):"))
    local tooltipReq
    if tooltipSnapshot then
        tooltipReq = tooltipSnapshot.reqLevel
    else
        tooltipReq = Core.GetTooltipReqLevel(link, location)
    end
    if tooltipReq then
        reqLevel = tooltipReq
    end
    return {
        id = id,
        name = name,
        quality = quality,
        iLevel = iLevel,
        reqLevel = reqLevel,
        itemType = itemType,
        subType = subType,
        maxStack = maxStack,
        equipSlot = equipSlot,
        texture = texture,
        vendorPrice = vendorPrice,
    }
end

----------------------------------------------------------------------
-- Scan binding status + usability (exact red)
----------------------------------------------------------------------
function Core.ScanTooltip(link, guid, location)
    local tooltip = Core.tooltip
    if not SetTooltipItem(link, location) then
        return "unbound", true
    end

    local boundStatus = "unbound"
    local usable = true
    local numLines = tooltip:NumLines()

    local boundLocked = false
    if guid and C_Item and C_Item.IsBound then
        if C_Item.IsBound(guid) then
            boundStatus = "soulbound"
            boundLocked = true
        end
    end

    for i = 1, numLines do
        local leftText = _G["AutoCoreTooltipTextLeft" .. i]
        local rightText = _G["AutoCoreTooltipTextRight" .. i]

        for _, text in ipairs({ leftText, rightText }) do
            if text then
                local str = text:GetText()
                if str and str ~= "" then
                    if not boundLocked then
                        if str == SOULBOUND_STR then
                            boundStatus = "soulbound"
                        elseif str == BOP_STR then
                            boundStatus = "bop"
                        elseif str == BOE_STR then
                            boundStatus = "boe"
                        elseif str == BOU_STR then
                            boundStatus = "bou"
                        -- Ascension realm-bound items cannot be listed. The
                        -- client does not expose a standard localized constant
                        -- for this custom binding, so recognize its tooltip
                        -- wording before auction/sell modules accept it.
                        elseif str:lower():find("realm bound", 1, true)
                            or str:lower():find("realmbound", 1, true)
                            or str:lower():find("binds to realm", 1, true)
                            or str:lower():find("bind on realm", 1, true)
                        then
                            boundStatus = "realmbound"
                        end
                    end

                    if str ~= SOULBOUND_STR
                        and str ~= QUEST_ITEM_STR
                        and not str:match("^Requires Level")
                        and not str:match("^Requires ")
                    then
                        local r, g, b, a = text:GetTextColor()
                        if Core.IsUnusableRed(r, g, b, a) then
                            usable = false
                        end
                    end
                end
            end
        end
    end

    return boundStatus, usable
end

----------------------------------------------------------------------
-- Required level comparison
----------------------------------------------------------------------
local COMPARISON_OPERATORS = {
    lower = "lower", lowerOrEqual = "lowerOrEqual", equal = "equal",
    higherOrEqual = "higherOrEqual", higher = "higher",
}

function Core.CheckLevelComparison(comparison, actualLevel, playerLevel)
    if type(comparison) ~= "table" or actualLevel == nil then return false end
    local target
    if comparison.target == "player" then target = playerLevel
    elseif comparison.target == "value" then target = tonumber(comparison.value) end
    if target == nil then return false end

    local operator = comparison.operator
    if operator == "lower" then return actualLevel < target
    elseif operator == "lowerOrEqual" then return actualLevel <= target
    elseif operator == "equal" then return actualLevel == target
    elseif operator == "higherOrEqual" then return actualLevel >= target
    elseif operator == "higher" then return actualLevel > target end
    return false
end

function Core.CheckReqLevel(ruleReq, itemReq, playerLevel)
    if itemReq == nil or playerLevel == nil then
        return false
    end
    if type(ruleReq) == "number" then
        return itemReq == ruleReq
    end
    if ruleReq == "lower" then
        return itemReq < playerLevel
    elseif ruleReq == "higher" then
        return itemReq > playerLevel
    elseif ruleReq == "equal" then
        return itemReq == playerLevel
    elseif ruleReq == "lowerOrEqual" then
        return itemReq <= playerLevel
    elseif ruleReq == "higherOrEqual" then
        return itemReq >= playerLevel
    end
    return false
end

local function ComparisonDescription(comparison, playerLevel)
    if type(comparison) ~= "table" then return "invalid comparison" end
    local operators = {
        lower = "lower than", lowerOrEqual = "lower than or equal to", equal = "equal to",
        higherOrEqual = "higher than or equal to", higher = "higher than",
    }
    local target = comparison.target == "player" and ("player level " .. tostring(playerLevel))
        or ("entered level " .. tostring(comparison.value))
    return (operators[comparison.operator] or tostring(comparison.operator)) .. " " .. target
end

----------------------------------------------------------------------
-- Match single value or list
----------------------------------------------------------------------
function Core.MatchList(fieldValue, entryValue)
    if type(entryValue) == "table" then
        for _, v in ipairs(entryValue) do
            if fieldValue == v then
                return true
            end
        end
        return false
    else
        return fieldValue == entryValue
    end
end

function Core.FormatValue(v)
    if type(v) == "table" then
        local parts = {}
        for _, x in ipairs(v) do
            table.insert(parts, tostring(x))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

function Core.FormatEntry(entry)
    if type(entry) ~= "table" then
        return tostring(entry)
    end
    local parts = {}
    for k, v in pairs(entry) do
        if k ~= "exceptions" and k ~= "title" then
            table.insert(parts, k .. "=" .. Core.FormatValue(v))
        end
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

----------------------------------------------------------------------
-- Filter entry matching
----------------------------------------------------------------------
local function CheckEntryInternal(entry, data, boundStatus, usable, playerLevel, returnReason)
    local function fail(reason)
        if returnReason then
            return false, reason
        end
        return false
    end

    -- An empty table (or one containing only a misspelled/unsupported key)
    -- must never become a match-all rule. This is especially important for
    -- destructive consumers such as AutoSell.
    if type(entry) ~= "table"
        or (entry.itemID == nil
            and entry.itemType == nil
            and entry.subType == nil
            and entry.quality == nil
            and entry.reqLevel == nil
            and entry.reqLevelCompare == nil
            and entry.unusable == nil
            and entry.bound == nil
            and entry.minVendorPrice == nil
            and entry.maxVendorPrice == nil
            and entry.name == nil
            and entry.equipSlot == nil
            and entry.minItemLevel == nil
            and entry.maxItemLevel == nil
            and entry.itemLevelCompare == nil)
    then
        return fail("entry has no supported filter fields")
    end

    if entry.itemID ~= nil and not Core.MatchList(data.id, entry.itemID) then
        return fail("itemID (" .. tostring(data.id) .. ") is not " .. Core.FormatValue(entry.itemID))
    end

    if entry.itemType and not Core.MatchList(data.itemType, entry.itemType) then
        return fail("itemType (" .. tostring(data.itemType) .. ") is not " .. Core.FormatValue(entry.itemType))
    end

    if entry.subType and not Core.MatchList(data.subType, entry.subType) then
        return fail("subType (" .. tostring(data.subType) .. ") is not " .. Core.FormatValue(entry.subType))
    end

    if entry.quality ~= nil and not Core.MatchList(data.quality, entry.quality) then
        return fail("quality (" .. tostring(data.quality) .. ") is not " .. Core.FormatValue(entry.quality))
    end

    if entry.reqLevel and not Core.CheckReqLevel(entry.reqLevel, data.reqLevel, playerLevel) then
        local itemReq = data.reqLevel or "?"
        if entry.reqLevel == "lower" then
            return fail("required level " .. tostring(itemReq) .. " is not LOWER than player level " .. tostring(playerLevel))
        elseif entry.reqLevel == "higher" then
            return fail("required level " .. tostring(itemReq) .. " is not HIGHER than player level " .. tostring(playerLevel))
        elseif entry.reqLevel == "equal" then
            return fail("required level " .. tostring(itemReq) .. " is not EQUAL to player level " .. tostring(playerLevel))
        elseif entry.reqLevel == "lowerOrEqual" then
            return fail("required level " .. tostring(itemReq) .. " is not LOWER OR EQUAL to player level " .. tostring(playerLevel))
        elseif entry.reqLevel == "higherOrEqual" then
            return fail("required level " .. tostring(itemReq) .. " is not HIGHER OR EQUAL to player level " .. tostring(playerLevel))
        else
            return fail("required level " .. tostring(itemReq) .. " is not " .. tostring(entry.reqLevel))
        end
    end

    if entry.reqLevelCompare and not Core.CheckLevelComparison(entry.reqLevelCompare, data.reqLevel, playerLevel) then
        return fail("required level (" .. tostring(data.reqLevel) .. ") is not " .. ComparisonDescription(entry.reqLevelCompare, playerLevel))
    end

    if entry.unusable ~= nil and usable == entry.unusable then
        if entry.unusable then
            return fail("item is USABLE (no red tooltip) but entry requires unusable=true")
        else
            return fail("item is UNUSABLE (red tooltip) but entry requires unusable=false")
        end
    end

    if entry.bound and not Core.MatchList(boundStatus, entry.bound) then
        return fail("bound (" .. tostring(boundStatus) .. ") is not " .. Core.FormatValue(entry.bound))
    end

    if entry.minVendorPrice and (data.vendorPrice == nil or data.vendorPrice < entry.minVendorPrice) then
        return fail("vendorPrice (" .. tostring(data.vendorPrice) .. ") is missing or below minVendorPrice (" .. tostring(entry.minVendorPrice) .. ")")
    end

    if entry.maxVendorPrice and (data.vendorPrice == nil or data.vendorPrice > entry.maxVendorPrice) then
        return fail("vendorPrice (" .. tostring(data.vendorPrice) .. ") is missing or above maxVendorPrice (" .. tostring(entry.maxVendorPrice) .. ")")
    end

    if entry.name then
        if not string.find(string.lower(data.name), string.lower(entry.name), 1, true) then
            return fail("name (" .. tostring(data.name) .. ") does not contain '" .. entry.name .. "'")
        end
    end

    if entry.equipSlot and not Core.MatchList(data.equipSlot, entry.equipSlot) then
        return fail("equipSlot (" .. tostring(data.equipSlot) .. ") is not " .. Core.FormatValue(entry.equipSlot))
    end

    if entry.minItemLevel and (data.iLevel == nil or data.iLevel < entry.minItemLevel) then
        return fail("item level (" .. tostring(data.iLevel) .. ") is missing or below minItemLevel (" .. tostring(entry.minItemLevel) .. ")")
    end

    if entry.maxItemLevel and (data.iLevel == nil or data.iLevel > entry.maxItemLevel) then
        return fail("item level (" .. tostring(data.iLevel) .. ") is missing or above maxItemLevel (" .. tostring(entry.maxItemLevel) .. ")")
    end


    if entry.itemLevelCompare and not Core.CheckLevelComparison(entry.itemLevelCompare, data.iLevel, playerLevel) then
        return fail("item level (" .. tostring(data.iLevel) .. ") is not " .. ComparisonDescription(entry.itemLevelCompare, playerLevel))
    end

    if returnReason then
        return true, nil
    end
    return true
end

function Core.EntryMatches(entry, data, boundStatus, usable, playerLevel)
    return CheckEntryInternal(entry, data, boundStatus, usable, playerLevel, false)
end

function Core.EntryMatchDebug(entry, data, boundStatus, usable, playerLevel)
    return CheckEntryInternal(entry, data, boundStatus, usable, playerLevel, true)
end

-- Return configuration keys that are not understood by the shared matcher or
-- explicitly allowed by a consuming module. This is diagnostic-only: normal
-- matching remains backward compatible, while /debug commands can expose
-- misspellings that would otherwise be silently ignored.
function Core.GetUnsupportedEntryFields(entry, extraSupported)
    if type(entry) ~= "table" then return {} end

    local supported = {
        title = true,
        itemID = true, itemType = true, subType = true, quality = true,
        reqLevel = true, reqLevelCompare = true, unusable = true, bound = true,
        minVendorPrice = true, maxVendorPrice = true, name = true,
        equipSlot = true, minItemLevel = true, maxItemLevel = true, itemLevelCompare = true,
        exceptions = true,
    }
    for key, allowed in pairs(extraSupported or {}) do
        if allowed then supported[key] = true end
    end

    local unknown = {}
    for key in pairs(entry) do
        if not supported[key] then
            table.insert(unknown, tostring(key))
        end
    end
    table.sort(unknown)
    return unknown
end

----------------------------------------------------------------------
-- Configuration validation
----------------------------------------------------------------------
function Core.HasStatWeights(weights)
    if type(weights) ~= "table" then return false end
    for _, weight in pairs(weights) do
        if type(weight) == "number" and weight ~= 0 then
            return true
        end
    end
    return false
end

local VALID_REQ_LEVEL = {
    lower = true, higher = true, equal = true,
    lowerOrEqual = true, higherOrEqual = true,
}
local VALID_COMPARISON_TARGET = { player = true, value = true }
local VALID_ROLL_ACTION = { need = true, greed = true, disenchant = true, pass = true }

local function ValidateListOrScalar(value, path, validator, AddIssue)
    if type(value) == "table" then
        if #value == 0 then AddIssue(path .. " must not be an empty list") end
        for i, entry in ipairs(value) do
            if not validator(entry) then AddIssue(path .. "[" .. i .. "] has an invalid value: " .. tostring(entry)) end
        end
    elseif not validator(value) then
        AddIssue(path .. " has an invalid value: " .. tostring(value))
    end
end

local function ValidateRuleEntry(entry, path, extraSupported, AddIssue)
    if type(entry) ~= "table" then
        AddIssue(path .. " must be a table")
        return
    end

    local unknown = Core.GetUnsupportedEntryFields(entry, extraSupported)
    if #unknown > 0 then
        AddIssue(path .. " has unsupported field(s): " .. table.concat(unknown, ", "))
    end

    local hasCondition = entry.itemID ~= nil or entry.itemType ~= nil or entry.subType ~= nil
        or entry.quality ~= nil or entry.reqLevel ~= nil or entry.reqLevelCompare ~= nil or entry.unusable ~= nil
        or entry.bound ~= nil or entry.minVendorPrice ~= nil or entry.maxVendorPrice ~= nil
        or entry.name ~= nil or entry.equipSlot ~= nil or entry.minItemLevel ~= nil
        or entry.maxItemLevel ~= nil or entry.itemLevelCompare ~= nil
        or (extraSupported and extraSupported.isUpgrade and entry.isUpgrade ~= nil)
    if not hasCondition then AddIssue(path .. " has no supported filter conditions") end

    if entry.quality ~= nil then
        ValidateListOrScalar(entry.quality, path .. ".quality", function(v)
            return type(v) == "number" and v >= 0 and v <= 6 and v == math.floor(v)
        end, AddIssue)
    end
    if entry.reqLevel ~= nil and type(entry.reqLevel) ~= "number"
        and not VALID_REQ_LEVEL[entry.reqLevel]
    then
        AddIssue(path .. ".reqLevel has an invalid operator: " .. tostring(entry.reqLevel))
    end
    local function ValidateComparison(comparison, comparisonPath)
        if type(comparison) ~= "table" then
            AddIssue(comparisonPath .. " must be a comparison table")
            return
        end
        if not COMPARISON_OPERATORS[comparison.operator] then
            AddIssue(comparisonPath .. ".operator has an invalid value: " .. tostring(comparison.operator))
        end
        if not VALID_COMPARISON_TARGET[comparison.target] then
            AddIssue(comparisonPath .. ".target must be player or value")
        elseif comparison.target == "value" and type(comparison.value) ~= "number" then
            AddIssue(comparisonPath .. ".value must be a number when target is value")
        end
    end
    if entry.reqLevelCompare ~= nil then ValidateComparison(entry.reqLevelCompare, path .. ".reqLevelCompare") end
    if entry.itemLevelCompare ~= nil then ValidateComparison(entry.itemLevelCompare, path .. ".itemLevelCompare") end
    if entry.unusable ~= nil and type(entry.unusable) ~= "boolean" then
        AddIssue(path .. ".unusable must be true or false")
    end
    if entry.isUpgrade ~= nil and type(entry.isUpgrade) ~= "boolean" then
        AddIssue(path .. ".isUpgrade must be true or false")
    end
    if entry.exceptions ~= nil then
        if type(entry.exceptions) ~= "table" then
            AddIssue(path .. ".exceptions must be a list")
        else
            if #entry.exceptions == 0 then AddIssue(path .. ".exceptions must not be empty") end
            for i, exception in ipairs(entry.exceptions) do
                ValidateRuleEntry(exception, path .. ".exceptions[" .. i .. "]", extraSupported, AddIssue)
            end
        end
    end
    if entry.rollPriority ~= nil then
        if type(entry.rollPriority) ~= "table" or #entry.rollPriority == 0 then
            AddIssue(path .. ".rollPriority must be a non-empty list")
        else
            for i, action in ipairs(entry.rollPriority) do
                if not VALID_ROLL_ACTION[action] then
                    AddIssue(path .. ".rollPriority[" .. i .. "] has an invalid action: " .. tostring(action))
                end
            end
        end
    end
end

local function ActiveRulesUseUpgrade(config)
    if type(config) ~= "table" then return false end
    local profile = Core.GetProfile(config) or {}
    if type(profile) ~= "table" then profile = {} end
    local function EntryUsesUpgrade(entry)
        if type(entry) ~= "table" then return false end
        if entry.isUpgrade ~= nil then return true end
        for _, exception in ipairs(entry.exceptions or {}) do
            if EntryUsesUpgrade(exception) then return true end
        end
        return false
    end
    local disabled = profile.disabledProfileRules or {}
    for index, entry in ipairs(profile.rules or {}) do
        if not disabled[index] and EntryUsesUpgrade(entry) then return true end
    end
    return false
end

local function GetActiveWeights(config)
    if type(config) ~= "table" then return nil end
    local profile = Core.GetProfile(config) or config.default or {}
    if type(profile) ~= "table" then profile = {} end
    if profile.weights ~= nil then return profile.weights end
    return config.weights
end

function Core.ValidateAllConfigs(printResults)
    local issues = {}
    local function AddIssue(message) table.insert(issues, message) end

    local function ValidateRuleConfig(config, configName, neverKey, extraSupported)
        if type(config) ~= "table" then
            AddIssue(configName .. " is missing or is not a table")
            return
        end
        local function ValidateEntries(entries, path, extras)
            if entries == nil then return end
            if type(entries) ~= "table" then
                AddIssue(path .. " must be a list")
                return
            end
            for i, entry in ipairs(entries) do
                ValidateRuleEntry(entry, path .. "[" .. i .. "]", extras, AddIssue)
            end
        end
        ValidateEntries(config.commonRules, configName .. ".commonRules", extraSupported)
        if neverKey then ValidateEntries(config[neverKey], configName .. "." .. neverKey, nil) end

        if config.characters ~= nil and type(config.characters) ~= "table" then
            AddIssue(configName .. ".characters must be a table")
        else
            for profileKey, profile in pairs(config.characters or {}) do
                local base = configName .. ".characters[" .. tostring(profileKey) .. "]"
                if type(profileKey) ~= "string" or profileKey == "" then AddIssue(base .. " has an invalid profile key") end
                if type(profile) ~= "table" then
                    AddIssue(base .. " must be a table")
                else
                    ValidateEntries(profile.rules, base .. ".rules", extraSupported)
                    if neverKey then ValidateEntries(profile[neverKey], base .. "." .. neverKey, nil) end
                end
            end
        end
        if config.default ~= nil and type(config.default) ~= "table" then
            AddIssue(configName .. ".default must be a table")
        elseif type(config.default) == "table" then
            ValidateEntries(config.default.rules, configName .. ".default.rules", extraSupported)
        end

        local moduleName
        if config == AutoJunkConfig then moduleName = "junk"
        elseif config == AutoLootConfig then moduleName = "loot"
        elseif config == AutoSellConfig then moduleName = "sell"
        elseif config == AutoRollConfig then moduleName = "roll"
        elseif config == AutoAuctionConfig then moduleName = "auction" end
        for profileName, namedProfile in pairs(Core.EnsureProfileDB().profiles) do
            local section = type(namedProfile) == "table" and namedProfile[moduleName] or nil
            if type(section) == "table" then
                local base = "profiles[" .. tostring(profileName) .. "]." .. tostring(moduleName)
                ValidateEntries(section.rules, base .. ".rules", extraSupported)
                if neverKey then ValidateEntries(section[neverKey], base .. "." .. neverKey, nil) end
            end
        end
    end

    ValidateRuleConfig(AutoJunkConfig, "AutoJunkConfig", nil, nil)
    ValidateRuleConfig(AutoLootConfig, "AutoLootConfig", nil, nil)
    ValidateRuleConfig(AutoSellConfig, "AutoSellConfig", "neverSell", { isUpgrade = true })
    ValidateRuleConfig(AutoRollConfig, "AutoRollConfig", "neverRoll", { isUpgrade = true, rollPriority = true })
    ValidateRuleConfig(AutoAuctionConfig, "AutoAuctionConfig", "neverAuction", nil)

    if type(AutoRollConfig) == "table" and AutoRollConfig.rollPriority ~= nil then
        if type(AutoRollConfig.rollPriority) ~= "table" then
            AddIssue("AutoRollConfig.rollPriority must be a list")
        else
            for i, action in ipairs(AutoRollConfig.rollPriority) do
                if not VALID_ROLL_ACTION[action] then
                    AddIssue("AutoRollConfig.rollPriority[" .. i .. "] has an invalid action: " .. tostring(action))
                end
            end
        end
    end

    if type(AutoQuestConfig) == "table" then
        local function ValidatePatterns(patterns, path)
            if patterns ~= nil and type(patterns) ~= "table" then
                AddIssue(path .. " must be a list")
                return
            end
            for i, pattern in ipairs(patterns or {}) do
                if type(pattern) ~= "string" then
                    AddIssue(path .. "[" .. i .. "] must be a string")
                else
                    local ok = pcall(string.find, "", pattern)
                    if not ok then AddIssue(path .. "[" .. i .. "] is not a valid Lua pattern") end
                end
            end
        end
        ValidatePatterns(AutoQuestConfig.highRiskQuests, "AutoQuestConfig.highRiskQuests")
        if AutoQuestConfig.characters ~= nil and type(AutoQuestConfig.characters) ~= "table" then
            AddIssue("AutoQuestConfig.characters must be a table")
        else
            for profileKey, profile in pairs(AutoQuestConfig.characters or {}) do
                if type(profile) == "table" then
                    ValidatePatterns(profile.highRiskQuests, "AutoQuestConfig.characters[" .. tostring(profileKey) .. "].highRiskQuests")
                else
                    AddIssue("AutoQuestConfig.characters[" .. tostring(profileKey) .. "] must be a table")
                end
            end
        end
    else
        AddIssue("AutoQuestConfig is missing or is not a table")
    end

    local function ValidateWeights(weights, path)
        if weights == nil then return end
        if type(weights) ~= "table" then
            AddIssue(path .. " must be a table")
            return
        end
        for statName, weight in pairs(weights) do
            if type(statName) ~= "string" or statName == "" then
                AddIssue(path .. " has an invalid stat name: " .. tostring(statName))
            end
            if type(weight) ~= "number" or weight ~= weight then
                AddIssue(path .. "[" .. tostring(statName) .. "] must be a number")
            end
        end
    end

    if type(AutoUpgradeConfig) ~= "table" then
        AddIssue("AutoUpgradeConfig is missing or is not a table")
    else
        ValidateWeights(AutoUpgradeConfig.weights, "AutoUpgradeConfig.weights")
        if type(AutoUpgradeConfig.default) == "table" then
            ValidateWeights(AutoUpgradeConfig.default.weights, "AutoUpgradeConfig.default.weights")
        end
        if type(AutoUpgradeConfig.characters) == "table" then
            for profileKey, profile in pairs(AutoUpgradeConfig.characters) do
                if type(profile) == "table" then
                    ValidateWeights(profile.weights, "AutoUpgradeConfig.characters[" .. tostring(profileKey) .. "].weights")
                else
                    AddIssue("AutoUpgradeConfig.characters[" .. tostring(profileKey) .. "] must be a table")
                end
            end
        elseif AutoUpgradeConfig.characters ~= nil then
            AddIssue("AutoUpgradeConfig.characters must be a table")
        end
    end

    local upgradeWeights = GetActiveWeights(AutoUpgradeConfig)
    if ActiveRulesUseUpgrade(AutoSellConfig) and not Core.HasStatWeights(upgradeWeights) then
        AddIssue("AutoSell's active rules use isUpgrade, but this character has no non-zero AutoUpgrade weights; those rules will be skipped safely")
    end
    local rollWeights = GetActiveWeights(AutoRollConfig)
    if not Core.HasStatWeights(rollWeights) then rollWeights = upgradeWeights end
    if ActiveRulesUseUpgrade(AutoRollConfig) and not Core.HasStatWeights(rollWeights) then
        AddIssue("AutoRoll's active rules use isUpgrade, but this character has no non-zero upgrade weights; those rules will be skipped safely")
    end

    -- Verify that every loaded module is actually pointed at the active named
    -- profile section. This catches stale references after profile switches.
    local runtimeModules = {
        junk = AutoJunk, sell = AutoSell, roll = AutoRoll,
        quest = AutoQuest, buff = AutoBuff, upgrade = AutoUpgrade,
    }
    for moduleName, runtimeModule in pairs(runtimeModules) do
        local expected = Core.GetProfileSection(moduleName, true)
        if runtimeModule and runtimeModule.db and runtimeModule.db ~= expected then
            AddIssue("Auto" .. moduleName .. " is not connected to the active profile section")
        end
    end

    if printResults then
        if #issues == 0 then
            Core.Info(nil, "Configuration validation passed.")
        else
            Core.Warn(nil, "Configuration validation found " .. #issues .. " issue(s):")
            for i, issue in ipairs(issues) do print("  " .. i .. ". " .. issue) end
        end
    end
    return #issues, issues
end

----------------------------------------------------------------------
-- Character key / profile / config
----------------------------------------------------------------------
function Core.GetCharKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "UnknownRealm"
    return name .. "-" .. realm
end

----------------------------------------------------------------------
-- Account-wide named profiles
----------------------------------------------------------------------
local PROFILE_VERSION = 9
local MODULE_BY_CONFIG = {}

local function RefreshConfigMap()
    if AutoSellConfig then MODULE_BY_CONFIG[AutoSellConfig] = "sell" end
    if AutoRollConfig then MODULE_BY_CONFIG[AutoRollConfig] = "roll" end
    if AutoQuestConfig then MODULE_BY_CONFIG[AutoQuestConfig] = "quest" end
    if AutoUpgradeConfig then MODULE_BY_CONFIG[AutoUpgradeConfig] = "upgrade" end
    if AutoJunkConfig then MODULE_BY_CONFIG[AutoJunkConfig] = "junk" end
    if AutoLootConfig then MODULE_BY_CONFIG[AutoLootConfig] = "loot" end
    if AutoAuctionConfig then MODULE_BY_CONFIG[AutoAuctionConfig] = "auction" end
    if AutoCoreConfig then MODULE_BY_CONFIG[AutoCoreConfig] = "core" end
    if AutoBuffConfig then MODULE_BY_CONFIG[AutoBuffConfig] = "buff" end
end

function Core.DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do
        copy[Core.DeepCopy(key, seen)] = Core.DeepCopy(child, seen)
    end
    return copy
end

local function IsArray(value)
    if type(value) ~= "table" then return false end
    local count, maximum = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
        count = count + 1
        if key > maximum then maximum = key end
    end
    return count > 0 and maximum == count
end

-- Profile maps are merged recursively, while array-style values are replaced.
-- Empty tables intentionally replace their base value; this lets a profile
-- explicitly clear weights, allow-lists, rules, and other collection settings.
function Core.DeepMerge(base, overlay)
    local result = Core.DeepCopy(base or {})
    for key, value in pairs(overlay or {}) do
        if type(value) == "table" and next(value) == nil then
            result[key] = {}
        elseif type(value) == "table" and type(result[key]) == "table"
            and not IsArray(value) and not IsArray(result[key])
        then
            result[key] = Core.DeepMerge(result[key], value)
        else
            result[key] = Core.DeepCopy(value)
        end
    end
    return result
end

-- The whole profile is this character's own saved variables (declared
-- SavedVariablesPerCharacter), so nothing is shared between characters and
-- there is no profile list to manage. Config.lua seeds it once, the first
-- time this character is seen; after that the file is never consulted for
-- rules again, so a default rule you edit or delete in the UI stays that way.
local function SeedSection(config, ruleKey, neverKey)
    local section = {}
    section.rules = Core.DeepCopy((config and config[ruleKey]) or {})
    section.disabledProfileRules = Core.DeepCopy((config and config.disabledRules) or {})
    if neverKey then section[neverKey] = Core.DeepCopy((config and config[neverKey]) or {}) end
    return section
end

----------------------------------------------------------------------
-- Read the tooltip-only fields used by upgrade evaluation in one fill.
-- Ascension's location-aware setters can be relatively expensive for scaled
-- equipment, so callers rendering a visible tooltip can share this snapshot.
----------------------------------------------------------------------
function Core.GetTooltipSnapshot(link, location, weights)
    local snapshot = {
        boundStatus = "unbound",
        usable = true,
        bloodforged = false,
        pvpPower = 0,
        pvePower = 0,
        stats = {},
    }
    if not SetTooltipItem(link, location) then return snapshot end

    local numLines = Core.tooltip:NumLines()
    for i = 1, numLines do
        local leftText = _G["AutoCoreTooltipTextLeft" .. i]
        local rightText = _G["AutoCoreTooltipTextRight" .. i]
        for column = 1, 2 do
            local text = column == 1 and leftText or rightText
            if text then
                local str = text:GetText()
                if str and str ~= "" then
                    local lowered = str:lower()
                    if str == SOULBOUND_STR then
                        snapshot.boundStatus = "soulbound"
                    elseif str == BOP_STR then
                        snapshot.boundStatus = "bop"
                    elseif str == BOE_STR then
                        snapshot.boundStatus = "boe"
                    elseif str == BOU_STR then
                        snapshot.boundStatus = "bou"
                    elseif lowered:find("realm bound", 1, true)
                        or lowered:find("realmbound", 1, true)
                        or lowered:find("binds to realm", 1, true)
                        or lowered:find("bind on realm", 1, true)
                    then
                        snapshot.boundStatus = "realmbound"
                    end
                    if lowered:find("bloodforged", 1, true) then
                        snapshot.bloodforged = true
                    end
                    local powerText = lowered:match("([%d][%d,%.]*)") or ""
                    local powerValue = tonumber((powerText:gsub(",", "")))
                    if powerValue and lowered:find("pvp power", 1, true) then
                        snapshot.pvpPower = math.max(snapshot.pvpPower, powerValue)
                    elseif powerValue and lowered:find("pve power", 1, true) then
                        snapshot.pvePower = math.max(snapshot.pvePower, powerValue)
                    end
                    if column == 1 then
                        local req = str:match("Requires Level (%d+)")
                        if req then snapshot.reqLevel = tonumber(req) end
                    end
                    if str ~= SOULBOUND_STR
                        and str ~= QUEST_ITEM_STR
                        and not str:match("^Requires Level")
                        and not str:match("^Requires ")
                    then
                        local r, g, b, a = text:GetTextColor()
                        if Core.IsUnusableRed(r, g, b, a) then snapshot.usable = false end
                    end
                    if weights then Core.ParseStatLine(str, weights, nil, snapshot.stats) end
                end
            end
        end
    end
    return snapshot
end

-- Ascension's GetItemStats backport exposes PvP/PvE Power for item links,
-- while Bloodforged is tooltip-only. Combine both sources so destructive
-- modules share one conservative PvP-equipment classification.
function Core.GetPvPItemInfo(link, location, tooltipSnapshot)
    local snapshot = tooltipSnapshot or Core.GetTooltipSnapshot(link, location)
    local pvpPower = tonumber(snapshot.pvpPower) or 0
    local pvePower = tonumber(snapshot.pvePower) or 0

    if type(GetItemStats) == "function" and link then
        local supplied = {}
        local ok, returned = pcall(GetItemStats, link, supplied)
        local apiStats = ok and type(returned) == "table" and returned or supplied
        for statKey, rawValue in pairs(apiStats or {}) do
            local value = tonumber(rawValue)
            local normalized = tostring(statKey):upper():gsub("[^A-Z]", "")
            if value and value > 0 then
                if normalized:find("PVPPOWER", 1, true) then
                    pvpPower = math.max(pvpPower, value)
                elseif normalized:find("PVEPOWER", 1, true) then
                    pvePower = math.max(pvePower, value)
                end
            end
        end
    end

    local bloodforged = snapshot.bloodforged and true or false
    return {
        bloodforged = bloodforged,
        pvpPower = pvpPower,
        pvePower = pvePower,
        -- Pure PvP gear has PvP Power without PvE Power. Bloodforged remains
        -- authoritative even when a custom item omits either numeric stat.
        isPvPGear = bloodforged or (pvpPower > 0 and pvePower <= 0),
    }
end

local function BuildDefaultProfile()
    return {
        core    = {},
        junk    = SeedSection(AutoJunkConfig, "commonRules", nil),
        loot    = SeedSection(AutoLootConfig, "commonRules", nil),
        sell    = SeedSection(AutoSellConfig, "commonRules", "neverSell"),
        roll    = SeedSection(AutoRollConfig, "commonRules", "neverRoll"),
        quest   = {},
        buff    = {},
        upgrade = { weights = {} },
        auction = SeedSection(AutoAuctionConfig, "commonRules", "neverAuction"),
    }
end

-- Config.lua supplies every default. If it did not load, seeding would write
-- empty rule lists into saved variables permanently - and because seeding only
-- happens once, they would never fill in. So the profile is only stamped with
-- the current version when the configs were actually available; otherwise the
-- next login re-seeds.
local function ConfigsLoaded()
    return AutoCoreConfig and AutoJunkConfig and AutoLootConfig and AutoSellConfig
        and AutoRollConfig and AutoUpgradeConfig and AutoQuestConfig and AutoAuctionConfig and AutoBuffConfig
end

-- Profiles are account-wide and named; each character is assigned one via
-- profileKeys. Any number can exist, a character can switch at any time, and
-- two characters may share one. Switching swaps every module's rules and
-- settings at once, which is what makes a per-spec profile useful: a character
-- that plays melee and caster rolls and equips for whichever it is set to.
local MODULE_ORDER = { "core", "junk", "loot", "sell", "roll", "quest", "buff", "upgrade", "auction" }
Core.MODULE_ORDER = MODULE_ORDER

function Core.EnsureProfileDB()
    AutoEverythingDB = AutoEverythingDB or {}
    local db = AutoEverythingDB
    RefreshConfigMap()
    if type(db.profiles) ~= "table" then
        -- No pre-made "Default" profile: the block below names the first one
        -- after the character that creates it, so there is never an orphan
        -- profile sitting there that nobody uses.
        db.profiles = {}
        db.profileKeys = {}
    end
    -- Legacy pre-named-profile fields; nothing reads these any more.
    db.specs, db.profile, db.activeSpec = nil, nil, nil
    -- A version bump must never wipe existing profiles - that would delete
    -- every character's rules and settings on every addon update. Existing
    -- profiles are carried forward as-is: the per-module backfill loop below
    -- already adds any module table a newer version introduces, and
    -- Core.GetSetting already falls back to Config.lua's defaults for any
    -- scalar setting a profile doesn't have yet. Only the version stamp
    -- itself changes here.
    if db.version ~= PROFILE_VERSION and ConfigsLoaded() then
        db.version = PROFILE_VERSION
    end
    db.profileKeys = type(db.profileKeys) == "table" and db.profileKeys or {}
    -- Old scanner builds stored prices beside profile configuration. Market
    -- observations now live only in the dedicated AutoEverythingAuctionDB.
    db.auctionMarkets = nil

    -- A newly seen character gets its own profile rather than silently
    -- sharing another character's.
    local charKey = Core.GetCharKey()
    if type(db.profiles[db.profileKeys[charKey] or ""]) ~= "table" then
        if type(db.profiles[charKey]) ~= "table" then
            db.profiles[charKey] = BuildDefaultProfile()
        end
        db.profileKeys[charKey] = charKey
    end

    local profile = db.profiles[db.profileKeys[charKey]]
    for _, moduleName in ipairs(MODULE_ORDER) do
        if type(profile[moduleName]) ~= "table" then
            if moduleName == "auction" then
                profile[moduleName] = SeedSection(AutoAuctionConfig, "commonRules", "neverAuction")
            else
                profile[moduleName] = {}
            end
        end
    end
    return db
end

function Core.GetProfileName()
    local db = Core.EnsureProfileDB()
    return db.profileKeys[Core.GetCharKey()]
end

function Core.GetProfileNames()
    local db = Core.EnsureProfileDB()
    local names = {}
    for name in pairs(db.profiles) do table.insert(names, name) end
    table.sort(names)
    return names
end

-- Which characters currently use a profile, so the UI can warn before delete.
function Core.GetProfileUsers(name)
    local db = Core.EnsureProfileDB()
    local users = {}
    for charKey, profileName in pairs(db.profileKeys) do
        if profileName == name then table.insert(users, charKey) end
    end
    table.sort(users)
    return users
end

local function ValidateProfileName(name)
    name = strtrim(tostring(name or ""))
    if name == "" then return nil, "Enter a profile name." end
    if #name > 40 then return nil, "Profile names may not exceed 40 characters." end
    if string.find(name, "[%c]") then return nil, "Profile names may not contain control characters." end
    return name
end

-- copyFrom nil = start from the addon defaults; otherwise clone that profile.
function Core.CreateProfile(name, copyFrom)
    local clean, err = ValidateProfileName(name)
    if not clean then return false, err end
    local db = Core.EnsureProfileDB()
    if db.profiles[clean] then return false, "A profile called that already exists." end
    db.profiles[clean] = copyFrom and type(db.profiles[copyFrom]) == "table"
        and Core.DeepCopy(db.profiles[copyFrom]) or BuildDefaultProfile()
    db.profileKeys[Core.GetCharKey()] = clean
    Core.NotifyProfileChanged()
    return true
end

function Core.SetProfile(name)
    local db = Core.EnsureProfileDB()
    if type(db.profiles[name]) ~= "table" then return false, "That profile no longer exists." end
    if db.profileKeys[Core.GetCharKey()] == name then return true end
    db.profileKeys[Core.GetCharKey()] = name
    Core.NotifyProfileChanged()
    Core.Info(nil, "Switched to profile " .. name .. ".")
    return true
end

function Core.RenameProfile(oldName, newName)
    local clean, err = ValidateProfileName(newName)
    if not clean then return false, err end
    local db = Core.EnsureProfileDB()
    if type(db.profiles[oldName]) ~= "table" then return false, "That profile no longer exists." end
    if clean == oldName then return true end
    if db.profiles[clean] then return false, "A profile called that already exists." end
    db.profiles[clean] = db.profiles[oldName]
    db.profiles[oldName] = nil
    for charKey, profileName in pairs(db.profileKeys) do
        if profileName == oldName then db.profileKeys[charKey] = clean end
    end
    Core.NotifyProfileChanged()
    return true
end

function Core.DeleteProfile(name)
    local db = Core.EnsureProfileDB()
    if type(db.profiles[name]) ~= "table" then return false, "That profile no longer exists." end
    local count = 0
    for _ in pairs(db.profiles) do count = count + 1 end
    if count <= 1 then return false, "At least one profile must remain." end
    db.profiles[name] = nil
    -- Anyone left pointing at it falls back to a profile that still exists.
    local fallback = next(db.profiles)
    for charKey, profileName in pairs(db.profileKeys) do
        if profileName == name then db.profileKeys[charKey] = fallback end
    end
    Core.NotifyProfileChanged()
    return true
end

function Core.GetProfileSection(moduleName, create)
    local db = Core.EnsureProfileDB()
    local profile = db.profiles[db.profileKeys[Core.GetCharKey()]]
    if create and type(profile[moduleName]) ~= "table" then profile[moduleName] = {} end
    return profile[moduleName]
end

function Core.GetSetting(moduleName, key, fallback)
    local section = Core.GetProfileSection(moduleName, false)
    if section and section[key] ~= nil then return section[key] end
    return fallback
end

function Core.SetSetting(moduleName, key, value)
    Core.GetProfileSection(moduleName, true)[key] = Core.DeepCopy(value)
    Core.NotifyProfileChanged(moduleName)
end

function Core.ClearSetting(moduleName, key)
    local section = Core.GetProfileSection(moduleName, false)
    if section then section[key] = nil end
    Core.NotifyProfileChanged(moduleName)
end

function Core.NotifyProfileChanged(moduleName)
    if not moduleName or moduleName == "junk" then
        if AutoJunk and AutoJunk.ApplyProfile then AutoJunk.ApplyProfile() end
    end
    if not moduleName or moduleName == "loot" then
        if AutoLoot and AutoLoot.ApplyProfile then AutoLoot.ApplyProfile() end
    end
    if not moduleName or moduleName == "sell" then
        if AutoSell and AutoSell.ApplyProfile then AutoSell.ApplyProfile() end
    end
    if not moduleName or moduleName == "roll" then
        if AutoRoll and AutoRoll.ApplyProfile then AutoRoll.ApplyProfile() end
    end
    if not moduleName or moduleName == "quest" then
        if AutoQuest and AutoQuest.ApplyProfile then AutoQuest.ApplyProfile() end
    end
    if not moduleName or moduleName == "buff" then
        if AutoBuff and AutoBuff.ApplyProfile then AutoBuff.ApplyProfile() end
    end
    if not moduleName or moduleName == "upgrade" then
        if AutoUpgrade and AutoUpgrade.ApplyProfile then AutoUpgrade.ApplyProfile() end
    end
    if not moduleName or moduleName == "core" then
        -- Event-based conveniences read settings on every event. Camera
        -- distance and minimap visibility also have an immediate visual side
        -- effect, so apply those here rather than requiring another login.
        if ConfigEnabled("setCameraDistance") and SetCVar then
            SetCVar("CameraDistanceMax", tostring(Core.GetSetting("core", "cameraDistanceMax", coreConfig.cameraDistanceMax) or 50))
        end
        if Core.MinimapButton and Core.MinimapButton.Refresh then Core.MinimapButton.Refresh() end
        if Core.ActionBarEffects and Core.ActionBarEffects.Refresh then Core.ActionBarEffects.Refresh() end
    end
    if (not moduleName or moduleName == "junk") and AutoJunk and AutoJunk.ClearConfigCache then AutoJunk.ClearConfigCache() end
    if (not moduleName or moduleName == "loot") and AutoLoot and AutoLoot.ClearConfigCache then AutoLoot.ClearConfigCache() end
    if (not moduleName or moduleName == "sell" or moduleName == "upgrade") and AutoSell and AutoSell.ClearConfigCache then AutoSell.ClearConfigCache() end
    if (not moduleName or moduleName == "roll" or moduleName == "upgrade") and AutoRoll and AutoRoll.ClearConfigCache then AutoRoll.ClearConfigCache() end
    if (not moduleName or moduleName == "quest" or moduleName == "upgrade") and AutoQuest and AutoQuest.ClearConfigCache then AutoQuest.ClearConfigCache() end
    if (not moduleName or moduleName == "upgrade") and AutoUpgrade and AutoUpgrade.ClearConfigCache then AutoUpgrade.ClearConfigCache() end
    if (not moduleName or moduleName == "junk") and AutoJunk and AutoJunk.RefreshAfterSettingsChange then
        AutoJunk.RefreshAfterSettingsChange()
    end
    if (not moduleName or moduleName == "auction") and AutoAuction and AutoAuction.Refresh then AutoAuction.Refresh() end
    if Core.Settings and Core.Settings.Refresh then Core.Settings.Refresh(moduleName) end
end

function Core.ValidateRule(rule, moduleName, safetyRule)
    local issues = {}
    local extras = nil
    if not safetyRule and moduleName == "sell" then
        extras = { isUpgrade = true }
    elseif not safetyRule and moduleName == "roll" then
        extras = { isUpgrade = true, rollPriority = true }
    end
    ValidateRuleEntry(rule, "Rule", extras, function(message) table.insert(issues, message) end)
    return #issues == 0, issues
end

-- Restore every setting and rule to what Config.lua ships.
----------------------------------------------------------------------
-- Import / export
-- Settings and rules move between characters as a plain text string that
-- the player can copy out of, or paste into, the settings window.
----------------------------------------------------------------------
local EXPORT_PREFIX = "ProfileData:"
local LEGACY_EXPORT_PREFIX = "AutoEverything:"

local MODULE_LABELS = {
    core = "General", junk = "AutoJunk", loot = "AutoLoot", sell = "AutoSell",
    roll = "AutoRoll", quest = "AutoQuest", buff = "AutoBuff", upgrade = "AutoUpgrade", auction = "AutoAuction",
}
Core.MODULE_LABELS = MODULE_LABELS

local function SerializeValue(value)
    local valueType = type(value)
    if valueType == "string" then return string.format("%q", value) end
    if valueType == "number" or valueType == "boolean" then return tostring(value) end
    if valueType ~= "table" then return "nil" end

    local parts = {}
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    if count == #value then
        for _, item in ipairs(value) do table.insert(parts, SerializeValue(item)) end
    else
        -- Sorted so the same settings always produce the same string, which
        -- makes exports comparable and diffable.
        local keys = {}
        for key in pairs(value) do
            if type(key) == "string" or type(key) == "number" then table.insert(keys, key) end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do
            local name = type(key) == "string" and string.format("[%q]", key) or ("[" .. key .. "]")
            table.insert(parts, name .. "=" .. SerializeValue(value[key]))
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
Core.SerializeValue = SerializeValue

-- scope: "all" (whole active spec), "weights", a module name, or a rule table.
function Core.Export(scope)
    local payload
    if type(scope) == "table" then
        payload = { kind = "rule", data = Core.DeepCopy(scope) }
    elseif scope == nil or scope == "all" then
        payload = { kind = "profile", profile = Core.GetProfileName(),
                    data = Core.DeepCopy(Core.EnsureProfileDB().profiles[Core.GetProfileName()]) }
    elseif scope == "weights" then
        local upgrade = Core.GetProfileSection("upgrade", false) or {}
        payload = { kind = "weights", data = Core.DeepCopy(upgrade.weights or {}) }
    else
        local section = Core.GetProfileSection(scope, false)
        if type(section) ~= "table" then return nil, "That module has nothing to export." end
        payload = { kind = "module", module = scope, data = Core.DeepCopy(section) }
    end
    return EXPORT_PREFIX .. SerializeValue(payload)
end

-- Parses an export string. The chunk runs with an EMPTY environment, so a
-- pasted string can only ever build a table - it cannot reach any WoW API,
-- read globals, or call anything, no matter what someone put in it.
function Core.ParseImport(text)
    text = strtrim(tostring(text or ""))
    if text == "" then return nil, "Paste an export string first." end
    local prefix = nil
    if string.sub(text, 1, #EXPORT_PREFIX) == EXPORT_PREFIX then
        prefix = EXPORT_PREFIX
    elseif string.sub(text, 1, #LEGACY_EXPORT_PREFIX) == LEGACY_EXPORT_PREFIX then
        prefix = LEGACY_EXPORT_PREFIX
    else
        return nil, "That does not look like a settings export string."
    end
    local body = string.sub(text, #prefix + 1)
    local chunk, err = loadstring("return " .. body)
    if not chunk then return nil, "The export string is damaged or incomplete." end
    if setfenv then setfenv(chunk, {}) end
    local ok, payload = pcall(chunk)
    if not ok or type(payload) ~= "table" or type(payload.data) ~= "table" then
        return nil, "The export string is damaged or incomplete."
    end
    local known = { spec = true, profile = true, module = true, rule = true, weights = true }
    if not known[payload.kind] then return nil, "Unrecognised export type." end
    return payload
end

-- Adds an imported profile alongside the existing ones instead of overwriting
-- the current one, so importing a friend's setup cannot clobber yours.
function Core.ImportAsNewProfile(payload, name)
    if type(payload) ~= "table" or type(payload.data) ~= "table" then
        return false, "Nothing to import."
    end
    if payload.kind ~= "profile" and payload.kind ~= "spec" then
        return false, "That export is not a full profile."
    end
    local clean, err = ValidateProfileName(name or payload.profile or payload.spec or "Imported")
    if not clean then return false, err end
    local db = Core.EnsureProfileDB()
    if db.profiles[clean] then return false, "A profile called that already exists." end
    local profile = BuildDefaultProfile()
    for _, moduleName in ipairs(MODULE_ORDER) do
        if type(payload.data[moduleName]) == "table" then
            profile[moduleName] = Core.DeepCopy(payload.data[moduleName])
        end
    end
    db.profiles[clean] = profile
    db.profileKeys[Core.GetCharKey()] = clean
    Core.NotifyProfileChanged()
    return true
end

function Core.DescribeImport(payload)
    if payload.kind == "rule" then
        return "one rule (" .. tostring(payload.data.title or "untitled") .. ")"
    end
    if payload.kind == "weights" then
        local count = 0
        for _ in pairs(payload.data) do count = count + 1 end
        return "stat weights (" .. count .. " stat" .. (count == 1 and "" or "s") .. ")"
    end
    if payload.kind == "module" then
        return (MODULE_LABELS[payload.module] or payload.module) .. " settings and rules"
    end
    local names = {}
    for moduleName in pairs(payload.data) do
        table.insert(names, MODULE_LABELS[moduleName] or moduleName)
    end
    table.sort(names)
    return "every module (" .. table.concat(names, ", ") .. ")"
end

-- ruleTarget is only used for a single-rule import: the module and list
-- ("rules" or the never-key) the rule should be appended to.
function Core.Import(payload, ruleTarget)
    if type(payload) ~= "table" then return false, "Nothing to import." end
    local db = Core.EnsureProfileDB()
    local profile = db.profiles[db.profileKeys[Core.GetCharKey()]]

    if payload.kind == "weights" then
        Core.GetProfileSection("upgrade", true).weights = Core.DeepCopy(payload.data)
        Core.NotifyProfileChanged("upgrade")
        return true
    end

    if payload.kind == "spec" or payload.kind == "profile" then
        for moduleName in pairs(MODULE_LABELS) do
            if type(payload.data[moduleName]) == "table" then
                profile[moduleName] = Core.DeepCopy(payload.data[moduleName])
            end
        end
        Core.NotifyProfileChanged()
        return true
    end

    if payload.kind == "module" then
        local moduleName = payload.module
        if not MODULE_LABELS[moduleName] then return false, "Unknown module in export string." end
        profile[moduleName] = Core.DeepCopy(payload.data)
        Core.NotifyProfileChanged(moduleName)
        return true
    end

    if not ruleTarget or not MODULE_LABELS[ruleTarget.module] then
        return false, "Choose which list the rule should be added to."
    end
    local section = Core.GetProfileSection(ruleTarget.module, true)
    local listKey = ruleTarget.listKey or "rules"
    section[listKey] = type(section[listKey]) == "table" and section[listKey] or {}
    table.insert(section[listKey], Core.DeepCopy(payload.data))
    Core.NotifyProfileChanged(ruleTarget.module)
    return true
end

-- Resets the profile this character uses; other profiles are untouched.
function Core.ResetProfile()
    local db = Core.EnsureProfileDB()
    db.profiles[db.profileKeys[Core.GetCharKey()]] = BuildDefaultProfile()
    Core.NotifyProfileChanged()
    return true
end

-- The saved section for whichever module owns this config table.
function Core.GetProfile(config)
    if not config then return nil end
    RefreshConfigMap()
    local moduleName = MODULE_BY_CONFIG[config]
    return moduleName and Core.GetProfileSection(moduleName, false) or nil
end

function Core.BuildActiveConfig(config, neverKey, extraKeys)
    if not config then
        return nil
    end

    local charKey = Core.GetCharKey()
    local profile = Core.GetProfile(config) or {}

    -- Rules live entirely in the profile; Config.lua only seeded them.
    local rules = {}
    local disabledProfileRules = profile.disabledProfileRules or {}
    for index, rule in ipairs(profile.rules or {}) do
        if not disabledProfileRules[index] then table.insert(rules, rule) end
    end

    local never = {}
    local disabledProfileNever = profile.disabledProfileNever or {}
    for index, rule in ipairs(profile[neverKey] or {}) do
        if not disabledProfileNever[index] then table.insert(never, rule) end
    end

    local weights = profile.weights
    if weights == nil then weights = config.weights end
    local upgradeThreshold = profile.upgradeThreshold
    if upgradeThreshold == nil then upgradeThreshold = config.upgradeThreshold end

    local function Resolve(key)
        if profile[key] ~= nil then return profile[key] end
        return config[key]
    end

    local result = {
        enabled = Resolve("enabled"),
        learnVanity = Resolve("learnVanity"),
        protectWeaponBench = Resolve("protectWeaponBench"),
        maxQuality = tonumber(Resolve("maxQuality")),
        printMessages = Resolve("printMessages"),
        rollPriority = profile.rollPriority or config.rollPriority,
        weights = weights,
        upgradeThreshold = upgradeThreshold,
        autoRepair = Resolve("autoRepair"),
        rules = rules,
        never = never,
        charKey = charKey,
    }
    -- Extra module-specific settings (e.g. AutoJunk's "deleteMode") that
    -- don't belong in the shared shape above, resolved with the same
    -- profile-then-config fallback as everything else.
    if extraKeys then
        for _, key in ipairs(extraKeys) do
            result[key] = Resolve(key)
        end
    end
    return result
end

----------------------------------------------------------------------
-- Quest item protection
----------------------------------------------------------------------
local ActiveQuestItems = {}

function Core.IsActiveQuestItem(itemId)
    return ActiveQuestItems[itemId] ~= nil
end

function Core.RebuildQuestItems()
    wipe(ActiveQuestItems)

    for i = 1, GetNumQuestLogEntries() do
        local title, _, _, _, isHeader = GetQuestLogTitle(i)
        if not isHeader then
            local items = QuestByTitle and QuestByTitle[title]
            if items then
                for _, itemID in ipairs(items) do
                    ActiveQuestItems[itemID] = true
                end
            end
        end
    end
end

local questFrame = CreateFrame("Frame")
questFrame:RegisterEvent("QUEST_LOG_UPDATE")
questFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
questFrame:SetScript("OnEvent", function()
    Core.RebuildQuestItems()
end)

----------------------------------------------------------------------
-- Appearance / vanity learning
----------------------------------------------------------------------
function Core.LearnAppearance(itemId, guid)
    local learned = false

    if C_Appearance and C_Appearance.GetItemAppearanceID then
        local appearanceID = C_Appearance.GetItemAppearanceID(itemId)
        if appearanceID
            and C_AppearanceCollection
            and C_AppearanceCollection.IsAppearanceCollected
            and not C_AppearanceCollection.IsAppearanceCollected(appearanceID)
        then
            if C_AppearanceCollection.CollectItemAppearance then
                C_AppearanceCollection.CollectItemAppearance(guid)
                learned = true
            end
        end
    end

    if C_VanityCollection
        and C_VanityCollection.IsCollectionItemOwned
        and not C_VanityCollection.IsCollectionItemOwned(itemId)
        and C_VanityCollection.CollectItem then
        C_VanityCollection.CollectItem(itemId)
        learned = true
    end

    return learned
end

----------------------------------------------------------------------
-- Upgrade scoring
-- location: inventory, bag, loot-roll, quest-reward, or nil (hyperlink)
----------------------------------------------------------------------
function Core.GetItemScore(link, weights, location)
    if not weights then
        return 0
    end
    local stats = Core.GetItemStats(link, weights, location)
    local score = 0
    for statName, value in pairs(stats) do
        score = score + value * (weights[statName] or 0)
    end
    return score
end

function Core.GetItemStats(link, weights, location)
    local stats = {}
    if not SetTooltipItem(link, location) then
        return stats
    end
    local numLines = Core.tooltip:NumLines()

    for i = 1, numLines do
        local leftText = _G["AutoCoreTooltipTextLeft" .. i]
        local rightText = _G["AutoCoreTooltipTextRight" .. i]
        if leftText then
            local str = leftText:GetText()
            if str and str ~= "" then
                Core.ParseStatLine(str, weights, nil, stats)
            end
        end
        if rightText then
            local str = rightText:GetText()
            if str and str ~= "" then
                Core.ParseStatLine(str, weights, nil, stats)
            end
        end
    end

    -- The tooltip labels melee and ranged weapon damage identically. Keep the
    -- legacy Weapon DPS behavior unless this weight set explicitly distinguishes
    -- Ranged DPS, then route ranged-slot weapons to that separate stat.
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
    if stats["Weapon DPS"] and weights["Ranged DPS"] ~= nil
        and (equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" or equipLoc == "INVTYPE_THROWN")
    then
        stats["Ranged DPS"] = (stats["Ranged DPS"] or 0) + stats["Weapon DPS"]
        stats["Weapon DPS"] = nil
    end

    return stats
end

-- Returns every raw tooltip line (left and right columns) for a link/location,
-- exactly as shown to the player, with no parsing. Used by debug commands to
-- compare "what the tooltip actually says" against what Core.ParseStatLine
-- extracted from it.
function Core.DumpTooltipLines(link, location)
    local lines = {}
    if not SetTooltipItem(link, location) then
        return lines
    end
    local numLines = Core.tooltip:NumLines()
    for i = 1, numLines do
        local leftText = _G["AutoCoreTooltipTextLeft" .. i]
        local rightText = _G["AutoCoreTooltipTextRight" .. i]
        local left = leftText and leftText:GetText()
        local right = rightText and rightText:GetText()
        if (left and left ~= "") or (right and right ~= "") then
            table.insert(lines, { left = left, right = right })
        end
    end
    return lines
end

----------------------------------------------------------------------
-- Parse a single tooltip stat line into the stats table
-- Returns nil to continue or a value to skip further parsing
----------------------------------------------------------------------
local KNOWN_WEIGHT_STATS = {
    "Strength", "Agility", "Stamina", "Intellect", "Spirit",
    "Critical Strike Rating", "Hit Rating", "Haste Rating", "Resilience Rating",
    "Mana Per 5", "Health Per 5", "Weapon DPS", "Ranged DPS", "Weapon Damage",
    "Min Damage", "Max Damage", "Weapon Speed", "Attack Power", "Ranged Attack Power",
    "Spell Power", "Spell Damage", "Healing Power", "Armor Penetration Rating",
    "Spell Penetration", "Expertise Rating", "Armor", "Defense Rating", "Dodge Rating",
    "Parry Rating", "Block Rating", "Block Value", "Shield Block", "Fire Resistance",
    "Arcane Resistance", "Shadow Resistance", "Frost Resistance", "Nature Resistance",
}

function Core.ParseStatLine(text, weights, score, stats)
    score = score or 0
    stats = stats or nil

    local function AddValue(statName, value)
        value = tonumber(value)
        if not value then return end
        if stats then
            stats[statName] = (stats[statName] or 0) + value
        else
            score = score + value * (weights[statName] or 0)
        end
    end

    if not text then
        return score
    end

    -- Strip WoW formatting
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    text = text:gsub("|T.-|t", "")
    text = text:gsub("|H.-|h", "")
    text = text:gsub("|h", "")

    -- Convert real line endings and literal "\\r"/"\\n" sequences used
    -- by some Ascension custom-item fields into independent stat fragments.
    text = text:gsub("\\r\\n", "\n")
    text = text:gsub("\\r", "\n")
    text = text:gsub("\\n", "\n")
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")

    -- Split multiline tooltip fields
    if text:find("\n") then
        for line in text:gmatch("[^\n]+") do
            score = Core.ParseStatLine(line, weights, score, stats)
        end
        return score
    end

    -- Normalize spaces AFTER splitting
    text = text:gsub("\194\160", " ")
    text = text:gsub("%s+", " ")
    text = text:match("^%s*(.-)%s*$")

    -- Skip set-bonus lines ("(2) Set: Increases spell power by 6.",
    -- "(5): +10 Intellect", etc.). These belong to the item set, not the
    -- individual piece, and unearned tiers are shown greyed for sets you
    -- have not completed - scoring them wildly inflates a single item (e.g.
    -- a 1/5 set belt getting credited for all five bonuses).
    if text:match("^%(%d+%)") then
        return score
    end

    -- Step 6: Skip enchant/forge text entirely (Counterweight, Crusader, Berserking, etc.)
    -- These are player-applied and transferable to new weapons, shouldn't affect upgrade scoring
    local enchantPrefixes = {
        "Counterweight",
        "Crusader",
        "Berserking",
        "Executioner",
        "Catalystic",
        "Frostsfire",
        "Soul of the",
    }
    for _, prefix in ipairs(enchantPrefixes) do
        if text:find("^" .. prefix) then
            return score
        end
    end

    -- Skip percentage conversion lines; score only raw rating/stat values.
    if text:match("^%+%s*[%d%.]+%%") then
        return score
    end

    -- Recovery appears in several forms in Ascension's item data, including
    -- lowercase socket bonuses ("+2 mana per 5 sec."), random enchantments
    -- ("+10 mana every 5 sec."), and ordinary "Restores ..." lines. These are
    -- permanent item stats; Use: effects deliberately do not match the anchors.
    local manaPer5 = text:match("^%+(%d+)%s+[Mm]ana%s+per%s+5%s+[Ss]ec")
        or text:match("^%+(%d+)%s+[Mm]ana%s+every%s+5%s+[Ss]ec")
        or text:match("^[Rr]estores%s+(%d+)%s+[Mm]ana%s+per%s+5%s+[Ss]ec")
        or text:match("^[Ee]quip:%s*[Rr]estores%s+(%d+)%s+[Mm]ana%s+per%s+5%s+[Ss]ec")
    if manaPer5 then
        AddValue("Mana Per 5", manaPer5)
        return score
    end
    local healthPer5 = text:match("^%+(%d+)%s+[Hh]ealth%s+per%s+5%s+[Ss]ec")
        or text:match("^%+(%d+)%s+[Hh]ealth%s+every%s+5%s+[Ss]ec")
        or text:match("^[Rr]estores%s+(%d+)%s+[Hh]ealth%s+per%s+5%s+[Ss]ec")
        or text:match("^[Ee]quip:%s*[Rr]estores%s+(%d+)%s+[Hh]ealth%s+per%s+5%s+[Ss]ec")
    if healthPer5 then
        AddValue("Health Per 5", healthPer5)
        return score
    end

    -- Parse simple "+N Stat" lines, but reject unresolved slash-separated
    -- scaling values such as "+5/10/15/20 Hit Rating". Match known names even
    -- when their current weight is zero so an overlapping shorter name (Armor
    -- inside Armor Penetration Rating, for example) can never claim the line.
    local simpleAmount, simpleSuffix = text:match("^%+(%d+)(.*)$")
    local value = simpleAmount and not simpleSuffix:match("^%s*/") and tonumber(simpleAmount) or nil

    if value then
        local matchedStat = nil
        local function Consider(statName)
            if type(statName) == "string" and text:find(statName, 1, true) and (not matchedStat or #statName > #matchedStat) then
                matchedStat = statName
            end
        end
        for _, statName in ipairs(KNOWN_WEIGHT_STATS) do Consider(statName) end
        -- Preserve imports that use a custom stat name not present in the UI.
        for statName in pairs(weights) do Consider(statName) end
        if matchedStat then
            AddValue(matchedStat, value)
            return score
        end
    end

    -- Step 4: Parse Armor lines (doesn't start with +)
    local armorVal = text:match("^Armor:%s*(%d+)$")
        or text:match("^Armor%s+(%d+)$")
        or text:match("^(%d+)%s+Armor$")
    if armorVal then
        AddValue("Armor", armorVal)
        return score
    end

    -- Shields display their intrinsic block amount as an unlabelled line such
    -- as "40 Block". This is the database's Shield Block weight, distinct from
    -- Block Rating and from Equip effects that increase Block Value.
    local shieldBlockValue = text:match("^(%d+)%s+Block$")
    if shieldBlockValue then
        AddValue("Shield Block", shieldBlockValue)
        return score
    end

    -- Step 5: Parse Equip lines for various combat stats. Never score Use:
    -- effects: temporary/on-use bonuses are not continuously active and can
    -- otherwise make a trinket look much stronger than its equipped value.
    -- Ascension uses both "Increases" and "Improves" (and sometimes inserts
    -- "your"). Only accept one resolved value: template/scaling text such as
    -- "5/10/15/20" is ambiguous and must not make an item look upgraded.
    local equipText = text:match("^[Ee]quip:%s*(.+)$")
    local function MatchSingleEquipValue(statText)
        if not equipText then return nil end
        local verbs = { "[Ii]ncreases", "[Ii]mproves" }
        for _, verb in ipairs(verbs) do
            local amount, suffix = equipText:match(verb .. ".-" .. statText .. "%s+by%s+(%d+)(.*)$")
            if amount then
                if suffix:match("^%s*/") then
                    return nil
                end
                return amount
            end
        end
        return nil
    end

    -- Spell power and the older split spell-damage/healing wording used by
    -- custom Ascension items. Keep these as separate stats because shipped
    -- templates assign them independently.
    local sp = MatchSingleEquipValue("spell power")
        or (equipText and equipText:match("[Ii]ncreases damage and healing done by .-[Ss]pells.- by up to (%d+)$"))
    if sp then
        AddValue("Spell Power", sp)
        return score
    end
    local spellDamage = MatchSingleEquipValue("spell damage")
        or (equipText and equipText:match("[Ii]ncreases damage done by .-[Ss]pells.- by up to (%d+)$"))
    if spellDamage then
        AddValue("Spell Damage", spellDamage)
        return score
    end
    local healingPower = MatchSingleEquipValue("healing power")
        or (equipText and equipText:match("[Ii]ncreases healing done by .-[Ss]pells.- by up to (%d+)$"))
    if healingPower then
        AddValue("Healing Power", healingPower)
        return score
    end

    -- Ranged attack power must be checked before the overlapping generic
    -- "attack power" phrase.
    local rangedAP = MatchSingleEquipValue("ranged attack power")
    if rangedAP then
        AddValue("Ranged Attack Power", rangedAP)
        return score
    end
    local ap = MatchSingleEquipValue("attack power")
    if ap then
        AddValue("Attack Power", ap)
        return score
    end

    -- Hit Rating / Spell Hit Rating
    local hit = MatchSingleEquipValue("hit rating")
    if hit then
        AddValue("Hit Rating", hit)
        return score
    end

    -- Critical Strike Rating
    local cr = MatchSingleEquipValue("critical strike rating")
    if cr then
        AddValue("Critical Strike Rating", cr)
        return score
    end

    -- Haste Rating
    local haste = MatchSingleEquipValue("haste rating")
    if haste then
        AddValue("Haste Rating", haste)
        return score
    end

    -- Expertise Rating
    local ex = MatchSingleEquipValue("expertise rating")
    if ex then
        AddValue("Expertise Rating", ex)
        return score
    end

    -- Armor Penetration Rating
    local apen = MatchSingleEquipValue("armor penetration rating")
    if apen then
        AddValue("Armor Penetration Rating", apen)
        return score
    end

    -- Dodge Rating
    local dr = MatchSingleEquipValue("dodge rating")
    if dr then
        AddValue("Dodge Rating", dr)
        return score
    end

    -- Parry Rating
    local pr = MatchSingleEquipValue("parry rating")
    if pr then
        AddValue("Parry Rating", pr)
        return score
    end

    -- Block Rating / Block Value
    local br = MatchSingleEquipValue("block rating")
    if br then
        AddValue("Block Rating", br)
        return score
    end

    -- Block Value / Shield Block
    local bv = MatchSingleEquipValue("block value")
        or MatchSingleEquipValue("block value of your shield")
    if bv then
        AddValue("Block Value", bv)
        return score
    end
    local shieldBlock = MatchSingleEquipValue("shield block")
    if shieldBlock then
        AddValue("Shield Block", shieldBlock)
        return score
    end

    -- Mana Per 5
    local mps = MatchSingleEquipValue("mana per 5")
        or (equipText and equipText:match("[Rr]estores (%d+) mana per 5"))
    if mps then
        AddValue("Mana Per 5", mps)
        return score
    end

    local hp5 = equipText and equipText:match("[Rr]estores (%d+) health per 5")
    if hp5 then
        AddValue("Health Per 5", hp5)
        return score
    end

    local defense = MatchSingleEquipValue("defense rating")
    if defense then
        AddValue("Defense Rating", defense)
        return score
    end

    local resilience = MatchSingleEquipValue("resilience rating")
    if resilience then
        AddValue("Resilience Rating", resilience)
        return score
    end

    local spellPen = MatchSingleEquipValue("spell penetration")
    if spellPen then
        AddValue("Spell Penetration", spellPen)
        return score
    end

    -- Average weapon hit. Combined with Weapon DPS, this allows profiles
    -- such as slow two-handed melee builds to favor harder individual hits.
    -- Min/Max Damage are also captured separately for profiles that want to
    -- weight burst potential and consistency differently.
    local lowDamage, highDamage = text:match("^(%d+)%s*%-%s*(%d+)%s+[Dd]amage$")
    if lowDamage and highDamage then
        AddValue("Weapon Damage", (tonumber(lowDamage) + tonumber(highDamage)) / 2)
        AddValue("Min Damage", lowDamage)
        AddValue("Max Damage", highDamage)
        return score
    end

    -- Weapon DPS is commonly exposed as its own tooltip line on 3.3.5a.
    local dps = text:match("([%d%.]+)%s+[Dd]amage per second")
    if dps then
        AddValue("Weapon DPS", dps)
        return score
    end

    -- Weapon speed ("Speed 2.60"), its own unlabeled tooltip line.
    local speed = text:match("^[Ss]peed%s+([%d%.]+)$")
    if speed then
        AddValue("Weapon Speed", speed)
        return score
    end

    return score
end


-- Equip slot mapping
----------------------------------------------------------------------
local EquipSlotToInventorySlot = {
    INVTYPE_HEAD            = "HeadSlot",
    INVTYPE_NECK            = "NeckSlot",
    INVTYPE_SHOULDER        = "ShoulderSlot",
    INVTYPE_CHEST           = "ChestSlot",
    INVTYPE_ROBE            = "ChestSlot",
    INVTYPE_WAIST           = "WaistSlot",
    INVTYPE_LEGS            = "LegsSlot",
    INVTYPE_FEET            = "FeetSlot",
    INVTYPE_WRIST           = "WristSlot",
    INVTYPE_HAND            = "HandsSlot",
    INVTYPE_FINGER          = "Finger0Slot",
    INVTYPE_TRINKET         = "Trinket0Slot",
    INVTYPE_CLOAK           = "BackSlot",
    INVTYPE_WEAPON          = "MainHandSlot",
    INVTYPE_2HWEAPON        = "MainHandSlot",
    INVTYPE_WEAPONMAINHAND  = "MainHandSlot",
    INVTYPE_WEAPONOFFHAND   = "SecondaryHandSlot",
    INVTYPE_SHIELD          = "SecondaryHandSlot",
    INVTYPE_HOLDABLE        = "SecondaryHandSlot",
    INVTYPE_RANGED          = "RangedSlot",
    INVTYPE_RANGEDRIGHT     = "RangedSlot",
    INVTYPE_THROWN          = "RangedSlot",
    INVTYPE_RELIC           = "RangedSlot",
    INVTYPE_TABARD          = "TabardSlot",
    INVTYPE_BODY            = "ShirtSlot",
}

function Core.GetCompareSlot(link)
    local _, _, _, _, _, _, _, _, equipSlot = GetItemInfo(link)
    if not equipSlot then
        return nil
    end
    local slotName = EquipSlotToInventorySlot[equipSlot]
    if not slotName then
        return nil
    end
    return GetInventorySlotInfo(slotName)
end

function Core.IsTwoHandedWeapon(link)
    if not link then return false end
    local _, _, _, _, _, _, _, _, equipSlot = GetItemInfo(link)
    return equipSlot == "INVTYPE_2HWEAPON"
end

local function TypeInList(subType, list)
    if not subType or not list then return false end
    for _, t in ipairs(list) do
        if t == "Any" or t == subType then
            return true
        end
    end
    return false
end
Core.TypeInList = TypeInList

local TWO_HANDED_WEAPON_TYPES = {
    ["Two-Handed Axes"] = true, ["Two-Handed Maces"] = true,
    ["Two-Handed Swords"] = true, Polearms = true, Staves = true,
    ["Fishing Poles"] = true,
}

-- Everything that competes for the ranged/relic slot. Gated by its own
-- rangedTypes list, so a caster is not told a wand is an upgrade (and does not
-- roll on one) just because it out-scores an empty ranged slot.
local RANGED_EQUIP_SLOTS = {
    INVTYPE_RANGED      = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_THROWN      = true,
    INVTYPE_RELIC       = true,
}
Core.RANGED_EQUIP_SLOTS = RANGED_EQUIP_SLOTS

function Core.InferCanOffHandWithTwoHand(mainHandTypes, offHandTypes)
    local mainAllowsTwoHand, offAllowsTwoHand = false, false
    for _, weaponType in ipairs(mainHandTypes or {}) do
        if weaponType == "Any" or TWO_HANDED_WEAPON_TYPES[weaponType] then mainAllowsTwoHand = true; break end
    end
    for _, weaponType in ipairs(offHandTypes or {}) do
        if TWO_HANDED_WEAPON_TYPES[weaponType] then offAllowsTwoHand = true; break end
    end
    return mainAllowsTwoHand and offAllowsTwoHand
end

----------------------------------------------------------------------
-- IsUpgrade
-- options: armorTypes, mainHandTypes, offHandTypes, rangedTypes, canOffHandWithTwoHand,
--          usable, location (preferred), or legacy bag/slot/roll/quest fields
----------------------------------------------------------------------
local function RawIsUpgrade(link, weights, threshold, targetSlot, options, debugInfo)
    local function SetReason(msg)
        if debugInfo then
            debugInfo.reason = msg
        end
    end

    local function SetComparisons(rows, targetSlotId, combined)
        if debugInfo then
            debugInfo.comparisons = rows
            debugInfo.targetSlotId = targetSlotId
            debugInfo.combinedComparison = combined == true
        end
    end

    if options and options.usable == false then
        SetReason("item is unusable for your class (red tooltip)")
        return false, 0, 0, nil, nil
    end

    local candidateLoc = options and options.location or nil
    if not candidateLoc and options then
        if options.bag ~= nil and options.slot ~= nil then
            candidateLoc = { bag = options.bag, slot = options.slot }
        elseif options.rollID then
            candidateLoc = { rollID = options.rollID }
        elseif options.questType and options.questIndex then
            candidateLoc = { questType = options.questType, questIndex = options.questIndex }
        end
    end
    local newScore = options and options.itemScore
    if type(newScore) ~= "number" then
        newScore = Core.GetItemScore(link, weights, candidateLoc)
    end

    local slotId = targetSlot or Core.GetCompareSlot(link)
    if not slotId then
        SetReason("item is not equippable (no inventory slot)")
        return false, newScore, 0, nil, nil
    end

    local threshold = threshold or 5
    local armorTypes = options and options.armorTypes or {}
    local mainHandTypes = options and options.mainHandTypes or {}
    local offHandTypes = options and options.offHandTypes or {}
    local rangedTypes = options and options.rangedTypes or {}
    -- Selecting the same two-handed family for both hands is the capability
    -- declaration. One-handed dual wield is already inferred the same way.
    local canOffHandWithTwoHand = Core.InferCanOffHandWithTwoHand(mainHandTypes, offHandTypes)

    local _, _, _, _, _, newItemType, newSubType, _, newEquipSlot = GetItemInfo(link)

    local armorClassTypes = { Cloth = true, Leather = true, Mail = true, Plate = true }
    if newItemType == "Armor" and armorClassTypes[newSubType]
        and #armorTypes > 0 and not TypeInList(newSubType, armorTypes)
    then
        SetReason("armor type (" .. tostring(newSubType) .. ") is not in armorTypes")
        return false, newScore, 0, nil, nil
    end

    -- Ranged/relic slot. Like offHandTypes (and unlike armorTypes), an empty
    -- list means "nothing": these are opt-in, so a class that never uses the
    -- slot is never told a wand or thrown weapon is an upgrade.
    if RANGED_EQUIP_SLOTS[newEquipSlot] and not TypeInList(newSubType, rangedTypes) then
        SetReason("ranged type (" .. tostring(newSubType) .. ") is not in rangedTypes")
        return false, newScore, 0, nil, nil
    end

    local function MeetsUpgradeThreshold(candidateScore, currentScore)
        -- Even at a 0% configured threshold, an upgrade must be an actual
        -- gain. At positive thresholds, equality with the required target
        -- is accepted (for example exactly 5% better at a 5% threshold).
        return candidateScore > currentScore
            and candidateScore >= currentScore * (1 + threshold / 100)
    end

    local function IsTwoHanderInSlot(invSlot)
        local invLink = GetInventoryItemLink("player", invSlot)
        if not invLink then return false end
        local _, _, _, _, _, _, _, _, invEquipSlot = GetItemInfo(invLink)
        return invEquipSlot == "INVTYPE_2HWEAPON"
    end

    -- An actually equipped off-hand two-hander is authoritative proof that
    -- this Ascension character can dual-wield them, even if the current
    -- profile only allows the candidate's subtype in one hand.
    if IsTwoHanderInSlot(17) then
        canOffHandWithTwoHand = true
    end

    local function ScoreInvSlot(invSlot)
        local invLink = GetInventoryItemLink("player", invSlot)
        if not invLink then
            return 0, nil
        end
        return Core.GetItemScore(invLink, weights, { invSlot = invSlot }), invLink
    end

    local function CompareWeakerOfTwo(slotA, slotB)
        local scoreA, linkA = ScoreInvSlot(slotA)
        local scoreB, linkB = ScoreInvSlot(slotB)
        local equippedScore = math.min(scoreA, scoreB)
        local equippedLink, equipTargetSlot
        if scoreA <= scoreB then
            equippedLink, equipTargetSlot = linkA, slotA
        else
            equippedLink, equipTargetSlot = linkB, slotB
        end
        SetComparisons({
            { slot = slotA, score = scoreA },
            { slot = slotB, score = scoreB },
        }, equipTargetSlot, false)
        if equippedScore <= 0 then
            SetReason("both slots are empty but item has no weighted stats (score " .. string.format("%.2f", newScore) .. ")")
            return newScore > 0, newScore, equippedScore, equippedLink, equipTargetSlot
        end
        SetReason("score " .. string.format("%.2f", newScore) .. " is not at least " .. string.format("%.2f", equippedScore * (1 + threshold / 100)) .. " (" .. threshold .. "% over equipped " .. string.format("%.2f", equippedScore) .. ")")
        return MeetsUpgradeThreshold(newScore, equippedScore), newScore, equippedScore, equippedLink, equipTargetSlot
    end

    local function CompareSingleSlot(invSlot)
        local equippedScore, equippedLink = ScoreInvSlot(invSlot)
        SetComparisons({ { slot = invSlot, score = equippedScore } }, invSlot, false)
        if equippedScore <= 0 then
            SetReason("nothing is equipped in that slot but item has no weighted stats (score " .. string.format("%.2f", newScore) .. ")")
            return newScore > 0, newScore, equippedScore, equippedLink, invSlot
        end
        SetReason("score " .. string.format("%.2f", newScore) .. " is not at least " .. string.format("%.2f", equippedScore * (1 + threshold / 100)) .. " (" .. threshold .. "% over equipped " .. string.format("%.2f", equippedScore) .. ")")
        return MeetsUpgradeThreshold(newScore, equippedScore), newScore, equippedScore, equippedLink, invSlot
    end

    local function CompareEligibleHands(allowMain, allowOff)
        local scoreMain, linkMain = ScoreInvSlot(16)
        local scoreOff, linkOff = ScoreInvSlot(17)
        local equippedScore, equippedLink, equipTargetSlot
        if allowMain and allowOff then
            if scoreMain <= scoreOff then
                equippedScore, equippedLink, equipTargetSlot = scoreMain, linkMain, 16
            else
                equippedScore, equippedLink, equipTargetSlot = scoreOff, linkOff, 17
            end
        elseif allowMain then
            equippedScore, equippedLink, equipTargetSlot = scoreMain, linkMain, 16
        else
            equippedScore, equippedLink, equipTargetSlot = scoreOff, linkOff, 17
        end
        SetComparisons({
            { slot = 16, score = scoreMain, eligible = allowMain },
            { slot = 17, score = scoreOff, eligible = allowOff },
        }, equipTargetSlot, false)
        if equippedScore <= 0 then
            SetReason("the selected hand is empty but item has no weighted stats (score " .. string.format("%.2f", newScore) .. ")")
            return newScore > 0, newScore, equippedScore, equippedLink, equipTargetSlot
        end
        SetReason("score " .. string.format("%.2f", newScore) .. " is not at least "
            .. string.format("%.2f", equippedScore * (1 + threshold / 100)) .. " (" .. threshold
            .. "% over equipped " .. string.format("%.2f", equippedScore) .. ")")
        return MeetsUpgradeThreshold(newScore, equippedScore), newScore, equippedScore,
            equippedLink, equipTargetSlot
    end

    if slotId == 11 or slotId == 12 or slotId == 13 or slotId == 14 then
        local baseSlot = (slotId == 11 or slotId == 12) and 11 or 13
        local scoreA, linkA = ScoreInvSlot(baseSlot)
        local scoreB, linkB = ScoreInvSlot(baseSlot + 1)
        local equippedScore = math.min(scoreA, scoreB)
        local equippedLink, equipTargetSlot
        if scoreA <= scoreB then
            equippedLink, equipTargetSlot = linkA, baseSlot
        else
            equippedLink, equipTargetSlot = linkB, baseSlot + 1
        end
        SetComparisons({
            { slot = baseSlot, score = scoreA },
            { slot = baseSlot + 1, score = scoreB },
        }, equipTargetSlot, false)
        if equippedScore <= 0 then
            SetReason("both " .. ((baseSlot == 11) and "rings" or "trinkets") .. " are empty but item has no weighted stats (score " .. string.format("%.2f", newScore) .. ")")
            return newScore > 0, newScore, equippedScore, equippedLink, equipTargetSlot
        end
        SetReason("score " .. string.format("%.2f", newScore) .. " is not at least " .. string.format("%.2f", equippedScore * (1 + threshold / 100)) .. " (" .. threshold .. "% over weaker " .. ((baseSlot == 11) and "ring" or "trinket") .. " " .. string.format("%.2f", equippedScore) .. ")")
        return MeetsUpgradeThreshold(newScore, equippedScore), newScore, equippedScore, equippedLink, equipTargetSlot
    end

    if newEquipSlot == "INVTYPE_WEAPONMAINHAND" then
        if not TypeInList(newSubType, mainHandTypes) then
            SetReason("weapon type (" .. tostring(newSubType) .. ") is not in mainHandTypes")
            return false, newScore, 0, nil, nil
        end
        return CompareSingleSlot(16)
    end

    if newEquipSlot == "INVTYPE_WEAPONOFFHAND" then
        if not TypeInList(newSubType, offHandTypes) then
            SetReason("weapon type (" .. tostring(newSubType) .. ") is not in offHandTypes")
            return false, newScore, 0, nil, nil
        end
        if IsTwoHanderInSlot(16) and not canOffHandWithTwoHand then
            SetReason("main hand has a two-handed weapon equipped - can't equip an off-hand item")
            return false, newScore, 0, nil, nil
        end
        return CompareSingleSlot(17)
    end

    if newEquipSlot == "INVTYPE_WEAPON" and newItemType == "Weapon" then
        local inMain = TypeInList(newSubType, mainHandTypes)
        local inOff = TypeInList(newSubType, offHandTypes)
        if not inMain and not inOff then
            SetReason("weapon type (" .. tostring(newSubType) .. ") is not in mainHandTypes or offHandTypes")
            return false, newScore, 0, nil, nil
        end
        if inMain and inOff then
            -- A normal one-hander cannot fill the empty off-hand while a
            -- two-hander occupies the main hand; compare it as a main-hand
            -- replacement instead of treating the blocked off-hand as empty.
            if IsTwoHanderInSlot(16) and not canOffHandWithTwoHand then
                return CompareSingleSlot(16)
            end
            return CompareWeakerOfTwo(16, 17)
        elseif inMain then
            return CompareSingleSlot(16)
        else
            if IsTwoHanderInSlot(16) and not canOffHandWithTwoHand then
                SetReason("main hand has a two-handed weapon equipped - can't equip an off-hand item")
                return false, newScore, 0, nil, nil
            end
            return CompareSingleSlot(17)
        end
    end

    if newEquipSlot == "INVTYPE_2HWEAPON" then
        local inMain = TypeInList(newSubType, mainHandTypes)
        local inOff = TypeInList(newSubType, offHandTypes)
        if not inMain and not inOff then
            SetReason("two-handed weapon type (" .. tostring(newSubType) .. ") is not in mainHandTypes or offHandTypes")
            return false, newScore, 0, nil, nil
        end
        -- Standard two-handers replace the complete main+off set and must be
        -- main-hand eligible. Comparing only the weaker hand is valid solely
        -- for Ascension builds that explicitly permit a two-hander off-hand.
        if not canOffHandWithTwoHand and not inMain then
            SetReason("two-handed weapon type (" .. tostring(newSubType) .. ") is only in offHandTypes, but canOffHandWithTwoHand is false")
            return false, newScore, 0, nil, nil
        end
        if canOffHandWithTwoHand then
            return CompareEligibleHands(inMain, inOff)
        end
        local scoreMain, linkMain = ScoreInvSlot(16)
        local scoreOff, linkOff = ScoreInvSlot(17)
        local equippedScore = scoreMain + scoreOff
        local equippedLink = linkMain or linkOff
        SetComparisons({
            { slot = 16, score = scoreMain },
            { slot = 17, score = scoreOff },
        }, 16, true)
        if equippedScore <= 0 then
            SetReason("main hand and off hand are both empty but item has no weighted stats (score " .. string.format("%.2f", newScore) .. ")")
            return newScore > 0, newScore, equippedScore, equippedLink, 16
        end
        SetReason("score " .. string.format("%.2f", newScore) .. " is not at least " .. string.format("%.2f", equippedScore * (1 + threshold / 100)) .. " (" .. threshold .. "% over combined main+off " .. string.format("%.2f", equippedScore) .. ")")
        return MeetsUpgradeThreshold(newScore, equippedScore), newScore, equippedScore, equippedLink, 16
    end

    if newEquipSlot == "INVTYPE_SHIELD" or newEquipSlot == "INVTYPE_HOLDABLE" then
        local requiredType = newEquipSlot == "INVTYPE_SHIELD" and "Shields" or "Held In Off-hand"
        if not TypeInList(requiredType, offHandTypes) then
            SetReason(requiredType .. " is not enabled in offHandTypes")
            return false, newScore, 0, nil, nil
        end
        if IsTwoHanderInSlot(16) and not canOffHandWithTwoHand then
            SetReason("main hand has a two-handed weapon equipped - can't equip an off-hand item")
            return false, newScore, 0, nil, nil
        end
    end

    local equippedScore, equippedLink = ScoreInvSlot(slotId)
    SetComparisons({ { slot = slotId, score = equippedScore } }, slotId, false)
    if equippedScore <= 0 then
        SetReason("nothing is equipped in that slot but item has no weighted stats (score " .. string.format("%.2f", newScore) .. ")")
        return newScore > 0, newScore, equippedScore, equippedLink, slotId
    end

    SetReason("score " .. string.format("%.2f", newScore) .. " is not at least " .. string.format("%.2f", equippedScore * (1 + threshold / 100)) .. " (" .. threshold .. "% over equipped " .. string.format("%.2f", equippedScore) .. ")")
    return MeetsUpgradeThreshold(newScore, equippedScore), newScore, equippedScore, equippedLink, slotId
end

-- Shared by AutoSell, AutoRoll, and AutoUpgrade so every module answers
-- "is this an upgrade?" the same way.
function Core.IsUpgrade(link, weights, threshold, targetSlot, options, debugInfo)
    return RawIsUpgrade(link, weights, threshold, targetSlot, options, debugInfo)
end

----------------------------------------------------------------------
-- Equip from bag
----------------------------------------------------------------------
function Core.EquipItem(bag, slot, targetSlotId, link)
    -- Defense in depth: callers should normally defer their work before this
    -- point, but never begin bind tracking or touch the bag/cursor in combat.
    if InCombatLockdown and InCombatLockdown() then
        return false, "in_combat"
    end

    -- Restrict bind-popup handling to a short window following an equip
    -- initiated by this addon. Manual equip confirmations remain untouched.
    local trackingBind = Core.TrackPendingEquip(link, bag, slot)
    if not targetSlotId then
        UseContainerItem(bag, slot)
        return true
    end

    -- Always target the slot selected by IsUpgrade. UseContainerItem can
    -- choose the wrong ring/trinket slot or wrong hand.
    PickupContainerItem(bag, slot)
    EquipCursorItem(targetSlotId)
    local cursorType = GetCursorInfo()
    if cursorType == "item" then
        -- A bind-on-equip confirmation leaves the item on the cursor until
        -- the popup's accept handler finishes the equip. Putting it back in
        -- the bag here cancels that pending operation. Leave it alone only
        -- when this addon is actively watching for an allowed bind popup;
        -- otherwise restore it immediately after an ordinary equip failure.
        if trackingBind then
            return nil, "pending_bind"
        end
        PickupContainerItem(bag, slot)
        return false, "equip_failed"
    end
    return true
end

----------------------------------------------------------------------
-- AutoBindClear
----------------------------------------------------------------------
Core.autoAcceptPopups = Core.autoAcceptPopups or {}
Core.qualityCheckPopups = Core.qualityCheckPopups or {}
Core.pendingRolls = Core.pendingRolls or {}
Core.pendingRollExpires = Core.pendingRollExpires or {}

local popupFrame = CreateFrame("Frame")
local ROLL_PENDING_TIMEOUT = 5
local EQUIP_PENDING_TIMEOUT = 2
-- Exposed so callers polling for their own equip to land (e.g. AutoUpgrade's
-- StartEquipVerification) use the same window Core gives up watching the
-- bind popup after, instead of two independently-tuned timeouts drifting.
Core.EQUIP_PENDING_TIMEOUT = EQUIP_PENDING_TIMEOUT
local pendingEquipLink = nil
local pendingEquipExpires = nil
local pendingEquipBag = nil
local pendingEquipSlot = nil
local TryConfirmRoll

local function GetItemId(link)
    return type(link) == "string" and tonumber(link:match("|Hitem:(%d+):")) or nil
end
Core.GetItemId = GetItemId

local function ShouldTrackPendingEquip(link)
    local _, _, quality = GetItemInfo(link)
    if not quality then
        return false
    end
    local equipCheck = Core.qualityCheckPopups["EQUIP_BIND"]
    local autoEquipCheck = Core.qualityCheckPopups["AUTOEQUIP_BIND"]
    return (equipCheck and equipCheck(quality)) or (autoEquipCheck and autoEquipCheck(quality)) or false
end

local function HasPendingPopupAction()
    if pendingEquipExpires then
        return true
    end
    return next(Core.pendingRolls) ~= nil
end

local function StopPopupWatcherIfIdle()
    if not HasPendingPopupAction() then
        popupFrame:SetScript("OnUpdate", nil)
    end
end

local function StartPopupWatcher()
    if popupFrame:GetScript("OnUpdate") then
        return
    end

    popupFrame:SetScript("OnUpdate", function()
        local now = GetTime()
        if pendingEquipExpires and now >= pendingEquipExpires then
            -- If no eligible popup was accepted, safely return an item that
            -- is still being held from the addon's equip attempt.
            local cursorType = GetCursorInfo()
            if cursorType == "item" and pendingEquipBag ~= nil and pendingEquipSlot ~= nil then
                PickupContainerItem(pendingEquipBag, pendingEquipSlot)
            end
            pendingEquipLink = nil
            pendingEquipExpires = nil
            pendingEquipBag = nil
            pendingEquipSlot = nil
        end
        for rollId, expiresAt in pairs(Core.pendingRollExpires) do
            if now >= expiresAt then
                Core.pendingRollExpires[rollId] = nil
                Core.pendingRolls[rollId] = nil
            end
        end

        for i = 1, STATICPOPUP_NUMDIALOGS do
            local dialog = _G["StaticPopup" .. i]
            if dialog and dialog:IsShown() then
                local which = dialog.which
                local shouldAccept = false

                if Core.autoAcceptPopups[which] then
                    shouldAccept = true
                elseif Core.qualityCheckPopups[which] and pendingEquipExpires then
                    local quality = nil
                    local dialogLink = type(dialog.data) == "string" and dialog.data or nil
                    local dialogItemId = GetItemId(dialogLink)
                    local pendingItemId = GetItemId(pendingEquipLink)
                    local belongsToPendingEquip = not dialogLink
                        or (dialogItemId and pendingItemId and dialogItemId == pendingItemId)
                    local link = dialogLink or pendingEquipLink
                    if belongsToPendingEquip and link then
                        local _, _, q = GetItemInfo(link)
                        quality = q
                    end
                    if belongsToPendingEquip and not quality then
                        local cursorType, _, _, _, cursorQuality = GetCursorInfo()
                        if cursorType == "item" then
                            quality = cursorQuality
                        end
                    end
                    if quality and Core.qualityCheckPopups[which](quality) then
                        shouldAccept = true
                    end
                elseif (which == "CONFIRM_LOOT_ROLL" or which == "CONFIRM_DISENCHANT_ROLL")
                    and dialog.data and Core.pendingRolls[dialog.data] then
                    shouldAccept = true
                end

                if shouldAccept then
                    local button1 = _G[dialog:GetName() .. "Button1"]
                    if button1 and button1:IsEnabled() then
                        if which == "CONFIRM_LOOT_ROLL" or which == "CONFIRM_DISENCHANT_ROLL" then
                            local method = Core.pendingRolls[dialog.data]
                            if type(method) ~= "number" then method = 1 end
                            TryConfirmRoll(dialog.data, method)
                        elseif which == "LOOT_BIND" or which == "EQUIP_BIND" or which == "AUTOEQUIP_BIND" then
                            -- Use the popup's normal accept path so its own
                            -- handler and hide lifecycle always run together.
                            button1:Click()
                            pendingEquipLink = nil
                            pendingEquipExpires = nil
                            pendingEquipBag = nil
                            pendingEquipSlot = nil
                        else
                            button1:Click()
                        end
                    end
                end
            end
        end
        StopPopupWatcherIfIdle()
    end)
end

function Core.RegisterAutoAcceptPopup(which, qualityCheckFunc)
    if qualityCheckFunc then
        Core.qualityCheckPopups[which] = qualityCheckFunc
    else
        Core.autoAcceptPopups[which] = true
    end
end

function Core.TrackPendingEquip(link, bag, slot)
    if not link or not ShouldTrackPendingEquip(link) then
        pendingEquipLink = nil
        pendingEquipExpires = nil
        pendingEquipBag = nil
        pendingEquipSlot = nil
        StopPopupWatcherIfIdle()
        return false
    end
    pendingEquipLink = link
    pendingEquipExpires = GetTime() + EQUIP_PENDING_TIMEOUT
    pendingEquipBag = bag
    pendingEquipSlot = slot
    StartPopupWatcher()
    return true
end

function Core.TrackPendingRoll(rollId, rollMethod)
    if rollId then
        Core.pendingRolls[rollId] = rollMethod or true
        Core.pendingRollExpires[rollId] = GetTime() + ROLL_PENDING_TIMEOUT
        StartPopupWatcher()
    end
end

function Core.ClearPendingRoll(rollId)
    if rollId then
        Core.pendingRolls[rollId] = nil
        Core.pendingRollExpires[rollId] = nil
    end
    StopPopupWatcherIfIdle()
end

TryConfirmRoll = function(rollId, rollMethod)
    if not rollId then return false end
    ConfirmLootRoll(rollId, rollMethod or 1)
    StaticPopup_Hide("CONFIRM_LOOT_ROLL", rollId)
    StaticPopup_Hide("CONFIRM_DISENCHANT_ROLL", rollId)
    Core.ClearPendingRoll(rollId)
    return true
end

popupFrame:RegisterEvent("CONFIRM_LOOT_ROLL")
popupFrame:RegisterEvent("CONFIRM_DISENCHANT_ROLL")
popupFrame:SetScript("OnEvent", function(_, event, rollId, rollMethod)
    if Core.pendingRolls[rollId] then
        TryConfirmRoll(rollId, rollMethod)
    end
end)

return Core
