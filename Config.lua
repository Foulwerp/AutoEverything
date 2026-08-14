----------------------------------------------------------------------
-- Config.lua - default settings for every AutoEverything module.
--
-- These values seed a character's profile the first time it is seen.
-- After that the profile lives in that character's saved variables and
-- is edited in-game via /ae (or the minimap button) - this file is not
-- read for rules again, so anything you change or delete in the UI stays
-- changed. Every option here has an explanation in the settings window.
----------------------------------------------------------------------

-- General: convenience automation handled by Core.
AutoCoreConfig = {
    autoAcceptLFGRoleCheck = false,
    lfgAutoRole = "current",             -- current, tank, healer, or damage
    autoAcceptLFGProposal = false,
    autoAcceptBattlegroundPop = false,
    autoLeaveCompletedBattleground = false,
    autoExitCompletedDungeon = false,
    activityLeaveDelay = 3,
    trackEnemyFlagCarrier = true,
    dropAuraSpellID = 0,
    autoAcceptReadyCheck = false,
    autoConfirmSummon = false,
    summonAcceptMode = "delayed",
    summonAcceptSeconds = 3,
    autoSelectSingleGossip = true,
    autoGossipVendor = false,
    autoGossipTrainer = false,
    autoGossipTaxi = false,
    autoGossipBanker = false,
    autoGossipBattlemaster = false,
    autoGossipInnkeeper = false,
    cameraDistanceMax = 50,
    setCameraDistance = true,
    showLoginSummary = true,
    showMinimapButton = true,
    showPlayerItemLevel = true,
    verbose = false,

    -- Convenience bundle (each event handler reads its own flag live).
    autoAcceptResurrect = false,
    autoAcceptResurrectInstancesOnly = true,
    autoAcceptResurrectOutOfCombatOnly = true,
    autoAcceptResurrectVisibleOffererOnly = true,
    autoReleaseInBattleground = false,   -- off: some players want to accept a battle-rez instead
    autoDeclineDuels = false,
    autoDeclineDuelsShiftBypass = true,
    autoAcceptGroupInvite = false,
    autoAcceptInviteFriendsOnly = true,  -- when accepting invites, only from friends/guildmates
    autoAcceptInviteWhileQueued = false,
    skipCinematics = false,              -- off: also skips first-time story cinematics

    -- Auto-invite on whisper. The keyword is matched as a case-insensitive
    -- substring, so "inv" also fires on "invite", "invite me warrior", etc.
    autoInviteOnWhisper = false,
    autoInviteKeyword = "inv",
    autoInviteFriendsOnly = false,       -- keyword invites are usually pugs; default open to anyone

    -- Auto-learn trainer spells. Spends gold, so it defaults off. Purchases
    -- cheapest-first and stops once the next spell is unaffordable.
    autoLearnTrainerSpells = false,

    -- Session tracker: show this session's gold/items totals on the minimap
    -- button tooltip (also available via /ae session).
    showSessionInTooltip = true,

    -- ElvUI action-bar cooldown visuals. Ascension's older cooldown widget
    -- lacks the modern SetDrawSwipe/SetDrawBling API, so these are emulated.
    disableActionBarSwipe = false,
    disableActionBarBling = false,
}

-- AutoJunk: deletes matching items to keep bag space free.
AutoJunkConfig = {
    deleteMode = "target",
    enabled = false,
    maxQuality = 0,
    printMessages = true,
    targetFreeSlots = 1,
    commonRules = {},
}

-- AutoLoot: fast-loots corpses from an allow-list. Items matching any rule are
-- taken; unmatched items stay on the corpse. Money and currency are always
-- taken. Blizzard's own auto-loot and modifier key are left unchanged by
-- default; players can explicitly let this module disable either one. Shift
-- still provides an explicit per-loot pause inside AutoEverything.
AutoLootConfig = {
    enabled = false,
    fasterLooting = false,          -- loot matching slots instantly on LOOT_OPENED
    printMessages = false,
    disableBlizzardAutoLoot = false, -- when enabled, set autoLootDefault to 0
    disableAutoLootKey = false,      -- when enabled, set autoLootKey to NONE
    disableOnShift = true,          -- holding Shift leaves the loot window untouched
    commonRules = {},               -- only items matching a rule are looted
}

-- AutoSell: sells matching items at a merchant.
AutoSellConfig = {
    activationMode = "automatic",  -- automatic, shift, or manual button
    enabled = false,
    learnVanity = false,
    maxQuality = 0,
    printMessages = true,
    protectWeaponBench = true,
    autoRepair = { enabled = false, printMessages = true, useGuildBank = true },
    commonRules = {
        { title = "Sell Junk", quality = 0 },
    },
    disabledRules = { [1] = true }, -- example rule; explicitly enable it in Sell Rules
    neverSell = {
        { title = "Protect Quest Items", itemType = "Quest" },
        { title = "Protect Hearthstone", itemID = 6948 },
        { title = "Protect Keys", itemType = "Key" },
    },
}

-- AutoRoll: rolls on group loot.
AutoRollConfig = {
    enabled = false,
    maxQuality = 6,
    commonRules = {},
    neverRoll = {
        { title = "Leave Quest Items Manual", itemType = "Quest" },
    },
    rollPriority = {},
    weights = {},
}

-- AutoAuction: scans commodity and exact equipment-variant markets, then
-- posts auctionable bag items selected by rules after a live safety check.
-- Market observations and shopping lists live in AutoEverythingAuctionDB.
AutoAuctionConfig = {
    enabled = false,
    postingMode = "queue",       -- "queue" previews; "auto" posts after a scan
    undercutPercent = 1,
    bidPercent = 95,
    duration = 2,                -- Blizzard API: 1=12h, 2=24h, 3=48h
    maxPriceDropPercent = 40,
    shoppingDefaultPercent = 10,
    shoppingMaxSpend = 100000,   -- 10 gold session safety default
    printMessages = true,
    showTooltipPrices = true,
    commonRules = {},
    neverAuction = {
        { title = "Protect Quest Items", itemType = "Quest" },
        { title = "Protect Keys", itemType = "Key" },
        { title = "Protect Hearthstone", itemID = 6948 },
    },
}

-- AutoUpgrade: scores bag items and equips upgrades.
AutoUpgradeConfig = {
    autoEquip = false,
    enabled = false,
    minQuality = 0,
    printMessages = true,
    verbose = false,
    showTooltipScores = true,
    upgradeThreshold = 0,
    armorTypes = {},
    autoConfirmBind = { 2, 3 },
    mainHandTypes = { "Any" },
    offHandTypes = {},
    rangedTypes = {},
    weights = {},
    pvpGearToggle = false,   -- Set to true to allow upgrading PvP gear (e.g., from Battlegrounds)
}

-- AutoQuest: accepts/turns in quests and shows objective icons.
AutoQuestConfig = {
    acceptDailyQuests = true,
    acceptPvPQuests = false,
    acceptQuests = true,
    autoSelectRewards = false,
    disableOnShift = true,
    enabled = true,
    mapPins = true,
    acceptTrivialQuests = true,
    quickAbandonKeepComplete = true,
    quickAbandonKeepDaily = true,
    quickAbandonKeepDungeon = true,
    quickAbandonKeepTrivialDungeon = false,
    quickAbandonKeepTrivialComplete = false,
    quickAbandonKeepPathToAscension = true,
    quickAbandonKeepPartialProgress = false,
    quickAbandonKeepTrivialPartialProgress = false,
    quickAbandonWhitelist = {},
    maxMinimapPins = 150,
    maxWorldPins = 500,
    minimapPinRadiusPercent = 95,
    minimapPinSize = 16,
    nameplateMarkers = true,
    useElvUIQuestMarkers = false,
    turnInDailyQuests = false,
    turnInPvPQuests = false,
    turnInQuests = false,
    worldPinSize = 24,
    highRiskQuests = { "^Bloody Expedition:", "^Ill Gotten Goods:", "^High[- ]Risk", "^War in", "High[- ]Risk%)$" },

    -- Group questing uses invisible PARTY/RAID addon messages and stays opt-in.
    -- Visible objective and quest-completion announcements default to party
    -- chat. Raid announcements remain off unless the player explicitly enables
    -- raid group support; emote and say stay opt-in.
    groupQuestSync = false,
    groupQuestSyncRaid = false,
    autoShareQuests = false,
    autoAcceptSharedQuests = false,
    showGroupQuestTooltips = true,
    announceQuestCompletion = true,
    announceObjectiveCompletion = true,
    questAnnouncementChannel = "GROUP",
    cheerQuestCompletion = false,
}

-- AutoBuff: scans configured learned helpful spells and prepares one secure
-- click-to-cast action for the next missing party/raid buff. Ascension is
-- classless, so spell choices are profile-owned rather than hard-coded by
-- Blizzard class.
AutoBuffConfig = {
    enabled = false,
    showWindow = true,
    hideWhenComplete = false,
    includeSelf = true,
    includeParty = true,
    includeRaid = true,
    rebuffSeconds = 60,
    buffs = {},
    playerRoles = {},
}
