----------------------------------------------------------------------
-- LFGWindow.lua - compact chat-driven group request bulletin board.
-- Requests are session-only and never hide or rewrite the player's chat.
----------------------------------------------------------------------

AutoCore = AutoCore or {}
AutoCore.LFG = AutoCore.LFG or {}
local LFG = AutoCore.LFG
local UI = AutoCore.UI

local REQUEST_LIFETIME = 300
local MAX_REQUESTS = 200
local ROW_HEIGHT = 31
local VISIBLE_ROWS = 10

local categories = {
    { key = "all",     label = "All" },
    { key = "mythic", label = "Mythic+" },
    { key = "dungeon", label = "Dungeons" },
    { key = "raid",    label = "Raids" },
    { key = "world",   label = "World" },
    { key = "pvp",     label = "PvP" },
    { key = "quest",   label = "Quests" },
    { key = "other",   label = "Other" },
}

-- Longer names make the short abbreviations less likely to misclassify
-- ordinary conversation. Realm-specific activities still appear under Other.
local categoryKeywords = {
    mythic = {
        "mythic+", "mythic plus", "mythic key", "keystone", "m+", "key level",
    },
    raid = {
        "molten core", "blackwing lair", "zul'gurub", "aq20", "aq40", "naxxramas",
        "karazhan", "gruul", "magtheridon", "serpentshrine", "tempest keep", "hyjal",
        "black temple", "zul'aman", "sunwell", "vault of archavon", "obsidian sanctum",
        "eye of eternity", "ulduar", "trial of the crusader", "toc10", "toc25",
        "icecrown citadel", "icc10", "icc25", "ruby sanctum", "rs10", "rs25",
        "the radiant spring",
    },
    dungeon = {
        "dungeon", "heroic", "ragefire", "deadmines", "wailing caverns",
        "shadowfang", "stockade", "blackfathom", "gnomeregan", "razorfen", "scarlet monastery",
        "uldaman", "zul'farrak", "maraudon", "sunken temple", "blackrock depths", "dire maul",
        "stratholme", "scholomance", "blackrock spire", "ramparts", "blood furnace",
        "slave pens", "underbog", "mana tombs", "auchenai", "sethekk", "black morass",
        "mechanar", "shattered halls", "botanica", "shadow labyrinth", "steamvault",
        "arcatraz", "magisters' terrace", "utgarde", "nexus", "oculus", "ahn'kahet",
        "azjol", "drak'tharon", "violet hold", "gundrak", "halls of stone",
        "halls of lightning", "culling of stratholme", "trial of the champion",
        "forge of souls", "pit of saron", "halls of reflection", "rdf", "random heroic",
        "glittermurk", "karazhan crypt", "vault of the inquisition", "road to de' other side",
        "tor'watha", "temple of embers", "shadowbone depths", "manastorm",
    },
    world = {
        "world boss", "worldboss", "world tour", "azuregos", "kazzak", "doomwalker",
        "emeriss", "lethon", "taerar", "ysondre", "soggoth", "snowgrave", "atal'zul",
    },
    pvp = {
        "arena", "battleground", "wintergrasp", "warsong", "alterac", "arathi",
        "2v2", "3v3", "5v5", "premade", "pvp",
    },
    quest = { "quest", "elite quest", "daily", "group quest", "wanted:" },
}

local categoryTokens = {
    raid = { "mc", "bwl", "zg", "aq20", "aq40", "kara", "ssc", "tk", "bt", "za",
        "swp", "naxx", "voa", "eoe", "uld", "toc", "icc", "rs", "trs" },
    dungeon = { "rfc", "dm", "wc", "sfk", "bfd", "rfk", "rfd", "zf", "mara", "brd",
        "strat", "scholo", "lbrs", "ubrs", "fos", "pos", "hor", "rhc", "rdf" },
    world = { "wb" },
    pvp = { "bg", "wsg", "ab", "av", "eots", "wg" },
}

local requests = {}
local filtered = {}
local selectedCategory = "all"
local scrollOffset = 0
local nextCleanup = 0
local frame, scrollbar, searchBox, statusText, channelButton
local categoryButtons, rows = {}, {}
local knownChannels = {}

local function LowerPlain(text)
    text = tostring(text or ""):lower()
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("|H.-|h", ""):gsub("|h", "")
    return text
end

local function ContainsAny(text, words)
    for _, word in ipairs(words) do
        if text:find(word, 1, true) then return true end
    end
    return false
end

local function NormalizeChannelName(name)
    local normalized = LowerPlain(name)
    normalized = normalized:gsub("^%s*%[?%d+%.?%s*", "")
    normalized = normalized:gsub("%]?%s*$", "")
    normalized = normalized:gsub("^%s+", ""):gsub("%s+$", "")
    return normalized
end

local function RememberChannel(name)
    local key = NormalizeChannelName(name)
    if key ~= "" then knownChannels[key] = tostring(name) end
    return key
end

local function RefreshKnownChannels()
    if not GetChannelList then return end
    local values = { GetChannelList() }
    -- Wrath returns repeating channel-number, channel-name, disabled triples.
    for index = 1, #values, 3 do
        local name = values[index + 1]
        if type(name) == "string" and name ~= "" then RememberChannel(name) end
    end
end

local function IsStandardPublicChannel(channelKey)
    return channelKey:find("lookingforgroup", 1, true)
        or channelKey:find("looking for group", 1, true)
        or channelKey:find("%f[%w]lfg%f[%W]")
        or channelKey:find("%f[%w]world%f[%W]")
        or channelKey:find("%f[%w]global%f[%W]")
        or channelKey:match("^general")
        or channelKey:match("^trade")
end

local function ChannelMode()
    return AutoCore.GetSetting("core", "lfgChannelMode",
        AutoCoreConfig and AutoCoreConfig.lfgChannelMode or "standard")
end

local function IsChannelEnabled(channelKey)
    if channelKey == "" then return false end
    local mode = ChannelMode()
    if mode == "all" then return true end
    if mode == "custom" then
        local enabled = AutoCore.GetSetting("core", "lfgEnabledChannels",
            AutoCoreConfig and AutoCoreConfig.lfgEnabledChannels or {})
        return type(enabled) == "table" and enabled[channelKey] == true
    end
    return IsStandardPublicChannel(channelKey) and true or false
end

local function ContainsToken(text, words)
    for _, word in ipairs(words or {}) do
        if text:find("%f[%w]" .. word .. "%f[%W]") then return true end
    end
    return false
end

local function HasGroupIntent(text)
    return text:find("lfg", 1, true)
        or text:find("lfm", 1, true)
        or text:find("lfr", 1, true)
        or text:find("looking for group", 1, true)
        or text:find("looking for more", 1, true)
        or text:find("looking for member", 1, true)
        or text:find("group for", 1, true)
        or text:find("forming for", 1, true)
        or text:match("lf%d+%s*m")
        or text:match("need%s+%d*%s*tank")
        or text:match("need%s+%d*%s*heal")
        or text:match("need%s+%d*%s*dps")
end

local function Classify(text)
    if ContainsAny(text, categoryKeywords.mythic)
        or text:match("%f[%w]m%d+%f[%W]")
        or text:match("%f[%w]key%s*%+?%d+")
    then
        return "mythic"
    end
    if ContainsAny(text, categoryKeywords.world) or ContainsToken(text, categoryTokens.world) then return "world" end
    if ContainsAny(text, categoryKeywords.raid) or ContainsToken(text, categoryTokens.raid) then return "raid" end
    if ContainsAny(text, categoryKeywords.dungeon) or ContainsToken(text, categoryTokens.dungeon) then return "dungeon" end
    if ContainsAny(text, categoryKeywords.pvp) or ContainsToken(text, categoryTokens.pvp) then return "pvp" end
    if ContainsAny(text, categoryKeywords.quest) then return "quest" end
    return "other"
end

local function ShortName(name)
    return (tostring(name or "Unknown"):match("^([^%-]+)") or tostring(name or "Unknown"))
end

local function FormatAge(when)
    local seconds = math.max(0, math.floor(GetTime() - when))
    if seconds < 60 then return seconds .. "s" end
    return math.floor(seconds / 60) .. "m"
end

local function Cleanup()
    local now = GetTime()
    local kept = {}
    for _, request in ipairs(requests) do
        if now - request.updated < REQUEST_LIFETIME then kept[#kept + 1] = request end
    end
    requests = kept
    nextCleanup = now + 15
end

local function RebuildFiltered()
    if GetTime() >= nextCleanup then Cleanup() end
    filtered = {}
    local search = searchBox and LowerPlain(searchBox:GetText()) or ""
    for _, request in ipairs(requests) do
        if (selectedCategory == "all" or request.category == selectedCategory)
            and (search == "" or request.lower:find(search, 1, true)
                or request.senderLower:find(search, 1, true))
        then
            filtered[#filtered + 1] = request
        end
    end
    table.sort(filtered, function(a, b) return a.updated > b.updated end)
end

local function CategoryCount(key)
    local count = 0
    for _, request in ipairs(requests) do
        if key == "all" or request.category == key then count = count + 1 end
    end
    return count
end

local function RefreshCategoryButtons()
    for _, info in ipairs(categories) do
        local button = categoryButtons[info.key]
        if button then
            button:SetText(info.label .. "  " .. CategoryCount(info.key))
            button.themeAccentColor = info.key == selectedCategory and UI.Colors.brand or nil
            UI.RefreshButtonTheme(button)
        end
    end
end

local function Refresh()
    if not frame then return end
    RebuildFiltered()
    local maximum = math.max(0, #filtered - VISIBLE_ROWS)
    scrollOffset = math.max(0, math.min(scrollOffset, maximum))
    scrollbar:SetScrollRange(maximum, scrollOffset)
    for index, row in ipairs(rows) do
        local request = filtered[scrollOffset + index]
        if request then
            row.request = request
            row.name:SetText(ShortName(request.sender))
            row.age:SetText(FormatAge(request.updated))
            row.message:SetText(request.message)
            row:Show()
        else
            row.request = nil
            row:Hide()
        end
    end
    statusText:SetText(#filtered .. (#filtered == 1 and " request" or " requests") .. " - expires after 5 minutes")
    RefreshCategoryButtons()
    if AutoCore.MinimapButton and AutoCore.MinimapButton.RefreshLFG then
        AutoCore.MinimapButton.RefreshLFG()
    end
end

local function RefreshChannelButton()
    if not channelButton then return end
    local labels = { standard = "Public", custom = "Custom", all = "All" }
    channelButton:SetText("Channels: " .. (labels[ChannelMode()] or "Public"))
end

local function PruneDisabledChannels()
    local kept = {}
    for _, request in ipairs(requests) do
        if IsChannelEnabled(request.channelKey or "") then kept[#kept + 1] = request end
    end
    requests = kept
end

local function ApplyChannelMode(mode)
    AutoCore.SetSetting("core", "lfgChannelMode", mode)
    PruneDisabledChannels()
    scrollOffset = 0
    RefreshChannelButton()
    Refresh()
end

local channelMenu = CreateFrame("Frame", "AutoGroupFinderChannelMenu", UIParent, "UIDropDownMenuTemplate")
local function OpenChannelMenu(anchor)
    RefreshKnownChannels()
    local mode = ChannelMode()
    local enabled = AutoCore.GetSetting("core", "lfgEnabledChannels",
        AutoCoreConfig and AutoCoreConfig.lfgEnabledChannels or {})
    if type(enabled) ~= "table" then enabled = {} end

    local entries = {
        { text = "Listen to channels", isTitle = true, notCheckable = true },
        {
            text = "Standard public channels",
            checked = mode == "standard",
            tooltipTitle = "Standard public channels",
            tooltipText = "General, Trade, World, Global, LFG, and LookingForGroup channels only.",
            func = function() ApplyChannelMode("standard") end,
        },
        {
            text = "All numbered channels",
            checked = mode == "all",
            tooltipTitle = "All numbered channels",
            tooltipText = "Includes private and custom channels. Protocol messages beginning with lc<number>: remain blocked.",
            func = function() ApplyChannelMode("all") end,
        },
        {
            text = "Saved custom selection",
            checked = mode == "custom",
            tooltipTitle = "Saved custom selection",
            tooltipText = "Listen only to the channels checked below.",
            func = function() ApplyChannelMode("custom") end,
        },
        { text = " ", disabled = true, notCheckable = true },
        { text = "Custom selection", isTitle = true, notCheckable = true },
    }

    local keys = {}
    for key in pairs(knownChannels) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return knownChannels[a]:lower() < knownChannels[b]:lower() end)
    if #keys == 0 then
        entries[#entries + 1] = { text = "No channels detected", disabled = true, notCheckable = true }
    else
        for _, rawKey in ipairs(keys) do
            -- Per-entry locals keep callbacks correct on Lua 5.1.
            local key, label = rawKey, knownChannels[rawKey]
            entries[#entries + 1] = {
                text = label,
                checked = enabled[key] == true,
                func = function()
                    local nextEnabled = {}
                    for savedKey, value in pairs(enabled) do nextEnabled[savedKey] = value end
                    if nextEnabled[key] then nextEnabled[key] = nil else nextEnabled[key] = true end
                    AutoCore.SetSetting("core", "lfgEnabledChannels", nextEnabled)
                    ApplyChannelMode("custom")
                end,
            }
        end
    end
    EasyMenu(entries, channelMenu, anchor, 0, 0, "MENU", 0.15)
end

local function AddRequest(message, sender, channelKey, channelLabel)
    local lower = LowerPlain(message)
    if lower == "" or lower:match("^%s*lc%d*:") or not HasGroupIntent(lower) then return end
    local senderLower = LowerPlain(sender)
    local category = Classify(lower)
    local now = GetTime()
    for _, request in ipairs(requests) do
        if request.senderLower == senderLower and request.category == category then
            request.message = message
            request.lower = lower
            request.channelKey = channelKey
            request.channelLabel = channelLabel
            request.updated = now
            Refresh()
            return
        end
    end
    table.insert(requests, 1, {
        message = message,
        lower = lower,
        sender = sender,
        senderLower = senderLower,
        channelKey = channelKey,
        channelLabel = channelLabel,
        category = category,
        updated = now,
    })
    if #requests > MAX_REQUESTS then table.remove(requests) end
    Refresh()
end

local function Whisper(name)
    if ChatFrame_SendTell then
        ChatFrame_SendTell(name)
    elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox then
        DEFAULT_CHAT_FRAME.editBox:SetText("/w " .. name .. " ")
        ChatEdit_ActivateChat(DEFAULT_CHAT_FRAME.editBox)
    end
end

local function CreateWindow()
    frame = CreateFrame("Frame", "AutoGroupFinderWindow", UIParent)
    frame:SetSize(680, 438)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end
    UI.ModalSurface(frame)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("Group Finder")
    UI.ApplyFont(title, 16)
    title:SetTextColor(UI.Unpack(UI.Colors.text))

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("LEFT", title, "RIGHT", 12, -1)
    subtitle:SetText("Live requests from public chat")
    UI.ApplyFont(subtitle, 11)
    subtitle:SetTextColor(UI.Unpack(UI.Colors.textMuted))

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(26, 24)
    close:SetPoint("TOPRIGHT", -12, -12)
    close:SetText("X")
    UI.SkinButton(close)
    close:SetScript("OnClick", function() frame:Hide() end)

    channelButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    channelButton:SetSize(112, 24)
    channelButton:SetPoint("RIGHT", close, "LEFT", -8, 0)
    UI.SkinButton(channelButton)
    channelButton:SetScript("OnClick", function(self) OpenChannelMenu(self) end)
    channelButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("LFG chat channels")
        GameTooltip:AddLine("Choose which numbered chat channels may add requests.", 0.75, 0.78, 0.82, true)
        GameTooltip:Show()
    end)
    channelButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    RefreshChannelButton()

    local drag = CreateFrame("Frame", nil, frame)
    drag:SetPoint("TOPLEFT", 4, -4)
    drag:SetPoint("TOPRIGHT", -174, -4)
    drag:SetHeight(42)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() frame:StartMoving() end)
    drag:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

    local sidebar = CreateFrame("Frame", nil, frame)
    sidebar:SetPoint("TOPLEFT", 14, -58)
    sidebar:SetPoint("BOTTOMLEFT", 14, 42)
    sidebar:SetWidth(132)
    UI.Backdrop(sidebar, UI.Colors.sidebar, 1)

    for index, info in ipairs(categories) do
        local button = CreateFrame("Button", nil, sidebar, "UIPanelButtonTemplate")
        button:SetSize(116, 30)
        button:SetPoint("TOPLEFT", 8, -8 - (index - 1) * 35)
        UI.SkinButton(button)
        button:SetScript("OnClick", function()
            selectedCategory = info.key
            scrollOffset = 0
            Refresh()
        end)
        categoryButtons[info.key] = button
    end

    local columns = CreateFrame("Frame", nil, frame)
    columns:SetPoint("TOPLEFT", 158, -58)
    columns:SetPoint("TOPRIGHT", -18, -58)
    columns:SetHeight(24)
    UI.Backdrop(columns, UI.Colors.surface, 1)
    local nameHeader = columns:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameHeader:SetPoint("LEFT", 8, 0)
    nameHeader:SetText("Player")
    nameHeader:SetTextColor(UI.Unpack(UI.Colors.textMuted))
    local messageHeader = columns:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    messageHeader:SetPoint("LEFT", 122, 0)
    messageHeader:SetText("Request")
    messageHeader:SetTextColor(UI.Unpack(UI.Colors.textMuted))
    local ageHeader = columns:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ageHeader:SetPoint("RIGHT", -8, 0)
    ageHeader:SetText("Age")
    ageHeader:SetTextColor(UI.Unpack(UI.Colors.textMuted))

    local list = CreateFrame("Frame", nil, frame)
    list:SetPoint("TOPLEFT", columns, "BOTTOMLEFT", 0, -5)
    list:SetSize(486, ROW_HEIGHT * VISIBLE_ROWS)
    for index = 1, VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(470, ROW_HEIGHT - 2)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
        UI.Backdrop(row, index % 2 == 0 and UI.Colors.sidebar or UI.Colors.window, 0.9)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 8, 0)
        row.name:SetWidth(108)
        row.name:SetJustifyH("LEFT")
        row.name:SetTextColor(UI.Unpack(UI.Colors.brand))
        row.message = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.message:SetPoint("LEFT", 122, 0)
        row.message:SetWidth(300)
        row.message:SetJustifyH("LEFT")
        row.message:SetWordWrap(false)
        row.message:SetTextColor(UI.Unpack(UI.Colors.text))
        row.age = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.age:SetPoint("RIGHT", -8, 0)
        row.age:SetWidth(34)
        row.age:SetJustifyH("RIGHT")
        row.age:SetTextColor(UI.Unpack(UI.Colors.textMuted))
        row:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(UI.Unpack(UI.Colors.brand))
            if not self.request then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.request.message, 1, 1, 1, true)
            GameTooltip:AddLine("Left-click: whisper", 0.75, 0.78, 0.82)
            GameTooltip:AddLine("Ctrl-left-click: invite", 0.75, 0.78, 0.82)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(UI.Unpack(UI.Colors.border))
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function(self)
            if not self.request then return end
            if IsControlKeyDown and IsControlKeyDown() and InviteUnit then
                InviteUnit(self.request.sender)
            else
                Whisper(self.request.sender)
            end
        end)
        rows[index] = row
    end

    scrollbar = UI.CreateVerticalScrollbar(frame, ROW_HEIGHT * VISIBLE_ROWS, function(value)
        scrollOffset = math.floor(value + 0.5)
        Refresh()
    end, 1)
    scrollbar:SetPoint("TOPRIGHT", columns, "BOTTOMRIGHT", 0, -5)
    scrollbar:BindMouseWheel(list, 1)

    searchBox = CreateFrame("EditBox", nil, frame)
    searchBox:SetSize(248, 24)
    searchBox:SetPoint("BOTTOMLEFT", 158, 11)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(60)
    UI.Backdrop(searchBox, UI.Colors.control, 1)
    searchBox:SetFontObject("ChatFontNormal")
    searchBox:SetTextInsets(8, 8, 0, 0)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function() scrollOffset = 0; Refresh() end)
    local searchHint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchHint:SetPoint("RIGHT", searchBox, "LEFT", -8, 0)
    searchHint:SetText("Search")
    searchHint:SetTextColor(UI.Unpack(UI.Colors.textMuted))

    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetSize(70, 24)
    clear:SetPoint("BOTTOMRIGHT", -18, 11)
    clear:SetText("Clear")
    UI.SkinButton(clear)
    clear:SetScript("OnClick", function() requests = {}; scrollOffset = 0; Refresh() end)

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("RIGHT", clear, "LEFT", -12, 0)
    statusText:SetWidth(160)
    statusText:SetJustifyH("RIGHT")
    statusText:SetTextColor(UI.Unpack(UI.Colors.textMuted))

    frame:SetScript("OnShow", Refresh)
    frame:Hide()
    Refresh()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_CHANNEL")
eventFrame:RegisterEvent("CHANNEL_UI_UPDATE")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "AutoEverything" then
            RefreshKnownChannels()
            if not frame then CreateWindow() end
        end
        return
    elseif event == "CHANNEL_UI_UPDATE" then
        RefreshKnownChannels()
        return
    end
    local message, sender = ...
    local channelString = select(4, ...)
    local channelName = select(9, ...)
    local channelLabel = type(channelName) == "string" and channelName ~= "" and channelName or channelString
    local channelKey = RememberChannel(channelLabel)
    if IsChannelEnabled(channelKey) then AddRequest(message, sender, channelKey, channelLabel) end
end)
eventFrame:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 1 then return end
    self.elapsed = 0
    if GetTime() < nextCleanup then return end
    local oldCount = #requests
    Cleanup()
    if frame and frame:IsShown() then
        Refresh()
    elseif oldCount ~= #requests and AutoCore.MinimapButton and AutoCore.MinimapButton.RefreshLFG then
        AutoCore.MinimapButton.RefreshLFG()
    end
end)

function LFG.Toggle()
    if not frame then CreateWindow() end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

function LFG.Open()
    if not frame then CreateWindow() end
    frame:Show()
end

function LFG.GetRequestCount()
    if GetTime() >= nextCleanup then Cleanup() end
    return #requests
end

SLASH_AUTOGROUPFINDER1 = "/lfgboard"
SlashCmdList["AUTOGROUPFINDER"] = function() LFG.Toggle() end
