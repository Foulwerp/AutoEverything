# Utility Addon for Ascension WoW

> **This is an AI-coded addon for Ascension WoW. It is provided as-is, without any warranty or guarantee. Bug fixes, maintenance, and future changes will also be made with AI.**

This addon is an all-in-one collection of configurable automation and quality-of-life tools for the Ascension World of Warcraft 3.3.5a client. Most automation that takes actions, spends gold, interacts socially, or destroys items is disabled by default. Review each module's rules and safety settings before enabling it.

Open the settings with `/ae` or the minimap button. Changes are saved immediately to the active profile.

## Modules

### Loot

Loot is an allow-list-based looter. It takes money and currency automatically, but only takes items that match an enabled Loot rule; unmatched items remain on the corpse.

- Match items by properties such as name, item ID, quality, type, subtype, equipment slot, bind status, usability, and vendor value.
- Optionally loot matching slots immediately when the loot window opens.
- Optionally manage Blizzard's auto-loot setting and auto-loot modifier so the addon's rules remain authoritative.
- Hold Shift to pause the module for an individual loot window when that safety option is enabled.
- Import, export, duplicate, reorder, and temporarily deactivate individual rules.

### Junk

Junk deletes items that match its rules. It can either maintain a chosen number of free bag slots or delete matching items immediately after bag updates.

- Uses the shared detailed rule matcher for precise item selection.
- Enforces a configurable maximum-quality safety ceiling even when a rule matches.
- Protects active quest items from deletion.
- Shows an optional message for each deleted item.
- Starts disabled and with no deletion rules.

### Sell

Sell processes matching bag items when a merchant opens and includes separate protection rules that take priority over selling rules.

- Ships with inactive example behavior for selling poor-quality items rather than silently enabling it.
- Includes default protections for quest items, keys, and the Hearthstone.
- Can protect useful weapon-bench items and enforce a maximum sell-quality ceiling.
- Can automatically learn eligible vanity items before selling them.
- Optional automatic repair supports personal funds or the guild bank, subject to normal game permissions.
- Supports reusable rule import/export and a dedicated Never Sell rule list.

### Auction

Auction adds a themed Auction House workspace for collecting prices, shopping, reviewing inventory, finding upgrades, and safely posting matched items.

- Performs full-market scans when supported and falls back to reliable page-by-page scans when necessary.
- Stores bounded market history in the companion auction database, including exact equipment variants where the client exposes their stats.
- Adds scanned vendor, per-item, and stack auction values to item tooltips, with age and confidence information.
- Uses independent-seller support, scan history, live checks, price-drop limits, configurable undercutting, bid percentage, duration, and spend limits to reduce unsafe purchases or listings.
- Provides fixed-price and percentage-limited shopping lists, owned-auction views, manual selling tools, and equipment-upgrade searches.
- Can preview a posting queue for confirmation or, when explicitly selected, post automatically after a successful scan.
- Supports Auction and Never Auction rules; quest items, keys, and the Hearthstone are protected by default.

### Roll

Roll handles group-loot prompts according to ordered rules and roll priorities.

- Rules can choose and prioritize Need, Greed, Disenchant, or Pass behavior for matched items.
- Can evaluate whether equipment is an upgrade using the same stat weights and equipment restrictions as the Upgrade module.
- Enforces a maximum-quality safety ceiling.
- Provides a separate Never Roll rule list, with quest items left for manual decisions by default.
- Leaves unmatched or protected rolls for the player instead of making an unconfigured choice.

### Quest

Quest automates selected quest interactions and adds navigation information from the bundled Ascension quest and spawn database.

- Can automatically accept and turn in normal, trivial, daily, and PvP quests using separate controls.
- Can select quest rewards when enabled and can be paused by holding Shift.
- Adds active-objective and service-NPC markers to nameplates, the minimap, and world map, including patrol paths where data is available. Quest starters and turn-ins remain handled by the game.
- Includes configurable map-pin sizes, limits, radius, icon categories, and optional ElvUI-style quest markers.
- Offers a reviewed Quick Abandon window with filters and a whitelist; nothing is abandoned until confirmed.
- Optional group synchronization shares quest/objective progress through hidden party or raid addon messages and can show member progress in tooltips and map pins.
- Optional quest sharing, shared-quest acceptance, completion announcements, objective announcements, and cheers have individual controls.
- High-risk quest patterns and daily/PvP turn-ins have conservative safeguards.

### Buff

Buff watches the player, party, or raid for missing profile-configured helpful spells and prepares the next cast.

- Ascension is classless, so each profile chooses its own learned buff spells and intended target roles.
- Can include or exclude the player, party, and raid and can refresh buffs before they expire.
- Presents a compact status window and one secure click-to-cast button for the next valid target.
- Never casts automatically, and secure button attributes are only changed out of combat.
- Can hide the window when everyone is fully buffed.

### Upgrade

Upgrade scores equippable bag items against currently equipped gear using editable stat weights.

- Includes starter and Ascension class/specialization weight templates plus manual weight editing.
- Supports weight import/export and optional item-score details in tooltips.
- Filters by minimum quality, allowed armor classes, main-hand types, off-hand types, ranged/relic types, and optional PvP gear.
- Supports dual-wield and two-handed configurations through the weapon-type selectors.
- Lets individual equipment slots be locked so automatic upgrades cannot replace them.
- Uses a configurable score-improvement threshold and notification cooldown.
- Can notify only, or automatically equip upgrades and confirm selected bind types when explicitly enabled.

## Additional Features

### Master-loot award assistant

The award assistant tracks MS/OS rolls for a selected master-loot item. It validates rolls, handles roll timers, grace periods and tied rerolls, displays the result, and keeps automatic assignment opt-in. Failed or ambiguous situations stop safely for manual resolution.

### Action-bar profiles

Action-bar tools save and restore up to 144 action slots for Ascension specialization changes. Profiles can restore spells, items, equipment sets, and uniquely named macros; optionally choose the highest learned spell rank; share a default layout; and automatically capture the current layout when a specialization change begins.

### Groups, queues, and activity tools

- A compact, chat-driven LFG board gathers recent requests without hiding or rewriting chat, groups them into activity categories, and provides configurable join messages with role, specialization, and item-level placeholders.
- Optional automation can accept LFG proposals and role checks, requeue or leave completed dungeons, and leave completed battlegrounds using visible cancellable countdowns.
- Optional queue conveniences include ready-check responses, delayed summon acceptance, and enemy flag-carrier tracking.

### General conveniences

Individual opt-in settings cover resurrection acceptance with instance/combat/visibility safeguards, battleground release, duel decline with a Shift bypass, trusted group invitations, whisper-keyword invitations, trainer purchases, dismounting, and cinematic skipping. Single-option gossip automation can also open selected services such as vendors, trainers, taxis, banks, battleground masters, and innkeepers.

### Interface and information

- A draggable minimap button opens settings and exposes module status and common controls; its tooltip can show session gold and item totals.
- Player item level can be shown in supported character and inspection views.
- Camera distance can be applied at login.
- Ascension-compatible controls can hide action-bar cooldown swipe and bling effects while preserving countdown text.
- Profiles keep different configurations and rules, and the global automation switch pauses all automation without changing individual module settings.

## Installation

Extract the release ZIP into `Interface/AddOns`. The release installs the main addon and its companion auction database. Enable both from the character-selection AddOns screen.

The addon targets the Ascension WoW 3.3.5a client and is not intended for modern retail World of Warcraft.
