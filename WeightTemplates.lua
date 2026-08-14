----------------------------------------------------------------------
-- WeightTemplates.lua - shipped Ascension class/spec weight templates.
--
-- Templates are immutable source data. Settings.lua always DeepCopy()s a
-- selected template into the active profile before the player edits it.
----------------------------------------------------------------------

AutoEverythingWeightTemplates = {}
local Templates = AutoEverythingWeightTemplates

local STAT_NAMES = {
    "Strength", "Agility", "Stamina", "Intellect", "Spirit",
    "Critical Strike Rating", "Hit Rating", "Haste Rating", "Resilience Rating",
    "Mana Per 5", "Health Per 5", "Weapon DPS", "Ranged DPS", "Attack Power",
    "Ranged Attack Power", "Spell Power", "Spell Damage", "Healing Power",
    "Armor Penetration Rating", "Spell Penetration", "Expertise Rating", "Armor",
    "Defense Rating", "Dodge Rating", "Parry Rating", "Block Rating", "Block Value",
    "Shield Block", "Fire Resistance", "Arcane Resistance", "Shadow Resistance",
    "Frost Resistance", "Nature Resistance",
}
Templates.statNames = STAT_NAMES

-- Pipe-delimited to keep the large generated data set reviewable. Empty cells
-- and zeroes are both omitted from the resulting weight table.
local ROWS = {
"Barbarian|Brutality|2.188|2.195|0|0|0|0.761|0.5|0.6|0|0|0|14||1||0|||0.45|0|0.5||||||||0|0|0|0|0",
"Barbarian|Headhunting|0|1.473|0|0|0|0.65|0|0.6|0|0|0|14|14|1|1|0|||0.45|0|0||||||||0|0|0|0|0",
"Barbarian|Ancestry|1|1.387|0|0|0|0.5|0.5|0.55|0|0|0|14||1||0|||0.25|0|0.5||||||||0|0|0|0|0",
"Witch Doctor|Voodoo|0|0|0|0.173|1.504|1.238|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Witch Doctor|Brewing|0|0|0|0.07|0.3|0.5|0|0.65|0|0|0|||0||1|1|1|0|0|0||||||||0|0|0|0|0",
"Witch Doctor|Shadowhunting|0|2|0|1.2|0|0.672|0|0.5|0|0|0|0|14|1|1|0.2|0.2||0|0|0||||||||0|0|0|0|0",
"Felsworn|Slayer|1|2.5|0|0|0|0.734|0|0.6|0|0|0|14||1||0|||0.3|0|0.5||||||||0|0|0|0|0",
"Felsworn|Infernal|0|0|0|0.414|0.517|1.242|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Felsworn|Tyrant|1.135|2.817|2|0|0|0.35|0.5|0.35|0|0|0|14||1||0|||0.15|0|0.5|0.5|1.05|0.9|0.9|0|0|0|||||",
"Witch Hunter|Boltslinger|0|1.395|0|1.119|0|0.938|0|0.6|0|0|0|14|14|1|1|0.5|0.5||0.3|0|0||||||||0|0|0|0|0",
"Witch Hunter|Black Knight|1.225|3.326|1|0.27|0|0.35|0.5|0.35|0|0|0|14||1||0.75|0.75||0.15|0|0.5|0.4|1.05|0.9|0.9|0|0|0|||||",
"Witch Hunter|Houndmaster|0|1.375|0|0.336|0|0.891|0|0.6|0|0|0|14|14|1|1|0.5|0.5||0.3|0|0||||||||0|0|0|0|0",
"Witch Hunter|Inquisition|1|1.745|0|1.082|0|0.644|0|0.6|0|0|0|14||1||0.75|0.75||0.3|0|0.5||||||||0|0|0|0|0",
"Stormbringer|Lightning|0|0|0|0.209|0|1.563|0.5|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Stormbringer|Wind|0|0|0|0.067|0|0.5|0.5|0.55|0|0|0|0||0||1|1||0|0|0||||||||0|0|0|0|0",
"Stormbringer|Maelstrom|0|0|0|0.244|0|0.882|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Knight of Xoroth|Defiance|2.549|1.127|1.06|0.064|0|0.376|0.5|0.35|0|0|0|14||1||0.75|0.75||0.15|0|0.5|0.2|1.05|0.9|0.9|0.75|0.26|0.2|||||",
"Knight of Xoroth|Hellfire|2.2|0.585|0|1.163|0|0.831|0.5|0.6|0|0|0|14||0.75||1|1||0.3|0|0.5||||||||0|0|0|0|0",
"Knight of Xoroth|War|2.398|0.721|0|0|0|1.024|0|0.6|0|0|0|14||1||0|||0.45|0|0.5||||||||0|0|0|0|0",
"Guardian|Vanguard|2|1|3|0|0|0.35|0.5|0.35|0|0|0|14||1||0|||0.15|0|0.5|0.325|1.05|0.9|0.9|0.75|0.33|0.2|||||",
"Guardian|Inspiration|2.16|0.444|0|0|0|0.6|0.5|0.55|0|0|0|14||1||0|||0.25|0|0.5||||||||0|0|0|0|0",
"Guardian|Gladiator|2.464|0.617|0|0|0|0.796|0|0.6|0|0|0|14||1||0|||0.45|0|0.5||||||||0|0|0|0|0",
"Templar|Zealot|1.1|1.4|0|0.7|0|0.7|0|0.5|0|0|0|14||1||0.7|0.7||0.1|0|0.5||||||||0|0|0|0|0",
"Templar|Oathkeeper|1.333|2.872|1.05|0.2|0|0.35|0.5|0.35|0|0|0|14||1||0|||0.15|0|0.5|0.4|1.05|0.9|0.9|0|0|0|||||",
"Templar|Crusader|1.05|1.713|0|0.215|0|0.739|0|0.6|0|0|0|14||1||1|1||0.3|0|0.5||||||||0|0|0|0|0",
"Bloodmage|Sanguine|0|0|0.27|0.165|0.27|0.9|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Bloodmage|Accursed|1.404|1.947|0|0.119|0|0.653|0.5|0.6|0|0|0|14||1||0.75|0.75||0.3|0|0.5||||||||0|0|0|0|0",
"Bloodmage|Eternal|1.177|2.967|1.08|0.067|0|0.364|0.5|0.35|0|0|0|14||1||0.25|0.25||0.15|0|0.5|0.2|1.05|0.9|0.9|0|0|0|||||",
"Bloodmage|Fleshweaver|0|0|0|0.091|0.621|0.5|0|0.6|0|0|0|0||0||1|1|1|0|0|0||||||||0|0|0|0|0",
"Ranger|Archery|0|1.445|0|0.054|0|0.631|0|0.6|0|0|0|0|14|1|1|0.15|0.15||0.3|0|0||||||||0|0|0|0|0",
"Ranger|Brigand|1|1.567|0|0|0|0.705|0.5|0.6|0|0|0|14||1||0|||0.45|0|0.5||||||||0|0|0|0|0",
"Ranger|Farstrider|0|1.39|0|0|0|0.53|0.5|0.55|0|0|0|14||1|1|0|||0.2|0|0||||||||0|0|0|0|0",
"Chronomancer|Infinite|0|0|0|0.096|0.46|0.75|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Chronomancer|Time|0|0|0|0.064|0.575|0.5|0|0.65|0|0|0|||0||1|1|1|0|0|0||||||||0|0|0|0|0",
"Chronomancer|Artificer|0|1.1|0|0.1|1.5|0.7|0|0.9|0|0|0|0|14|1|1|0.7|0.7||0|0.5|0||||||||0|0|0|0|0",
"Necromancer|Death|0|0|0|0.054|0|0.63|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Necromancer|Rime|0|0|0|0.415|0|0.9|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Necromancer|Animation|0|0|0|0.051|0|0.6|0.5|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Pyromancer|Incineration|0|0|0|0.345|0|1.242|0.5|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Pyromancer|Flameweaving|0|0|0|0.129|2.182|0.9|0|0.65|0|0|0|||0||1|1|1|0|0|0||||||||0|0|0|0|0",
"Pyromancer|Draconic|0|0|0|0.218|0|1.614|0.5|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Cultist|Godblade|2.268|0|0|1.271|0|0.797|0.5|0.6|0|0|0|14||1||0.25|0.25||0.3|0|0.5||||||||0|0|0|0|0",
"Cultist|Corruption|0|0|0|0.507|0|0.9|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Cultist|Dreadnought|2.708|0|1.12|0.1|0|0.35|0.5|0.35|0|0|0|14||1||0.5|0.5||0.15|0|0.5|0.255|1.05|1.95|1.95|0.75|0.24|0.2|||||",
"Cultist|Heretic|1|0|0|0.104|0|3|0|0.4|0|0|0|14||1||0.4|0.4||0.2|0|0||||||||0|0|0|0|0",
"Starcaller|Moon Guard|2.041|2.147|1.1|0.721|0|0.354|0.5|0.35|0|0|0|14||0.75||1|1||0.15|0|0.5|0.2|1.05|0.9|0.9|0.75|0.26|0.2|||||",
"Starcaller|Sentinel|0|1.366|0|2.1|0|0.778|0|0.1|0|0|0|0|14|1|1|0.25|0.25||0.3|0|0||||||||0|0|0|0|0",
"Starcaller|Moon Priest|0|0|0|1|0|0.505|0|0.65|0|0|0|||0||1|1|1|0|0|0||||||||0|0|0|0|0",
"Starcaller|Warden|0.55|0.829|0|2|0|0.7|0|0.6|0|0|0|14||0.5||1|1||0.3|0.3|0||||||||0|0|0|0|0",
"Sun Cleric|Piety|0|0|0|0.21|0|1|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Sun Cleric|Blessings|0|0|0|0.436|0|0.5|0|0.65|0|0|0|||0||1|1|1|0|0|0||||||||0|0|0|0|0",
"Sun Cleric|Valkyrie|3.36|0.445|0|0.088|0|0.625|0|0.6|0|0|0|14||1.25||0.25|0.25||0.3|0|0.5||||||||0|0|0|0|0",
"Sun Cleric|Seraphim|3.053|1.32|1.15|1.089|0|0.363|0.5|0.35|0|0|0|14||0.5||1|1||0.15|0|0.5|0.256|1.05|0.9|0.9|0.75|0.2|0.2|||||",
"Tinker|Demolition|0|1.878|0|1.205|0|0.644|0|0.6|0|0|0|14|14|1|1|1|1||0.3|0|0||||||||0|0|0|0|0",
"Tinker|Invention|0|0|0|0.442|0|0.5|0|0.65|0|0|0||14|0||1|1|1|0|0|0||||||||0|0|0|0|0",
"Tinker|Mechanics|0|1.375|0|1.219|0|0.705|0|0.6|0|0|0|14|14|1|1|0.15|0.15||0.3|0|0||||||||0|0|0|0|0",
"Venomancer|Fortitude|0.8|2.529|1|0.05|0|0.357|0|0.35|0|0|0|14||0.5||1|1||0.15|0|0|0.34|1.05|0.9|0.9|0|0|0|||||",
"Venomancer|Rotweaver|0|0|0|0.575|0|1.2|0.5|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Venomancer|Stalking|0|0.4|0|1|0|1|0|0.8|0|0|0|0||0.2||1|1||0|0.5|0.5||||||||0|0|0|0|0",
"Venomancer|Vizier|0|0|0|0.4|0|0.5|0|0.65|0|0|0|||0||1|1|1|0|0|0||||||||0|0|0|0|0",
"Reaper|Harvest|2.347|0.471|0|0|0|0.67|0.5|0.6|0|0|0|14||1||0|||0.45|0|0.5||||||||0|0|0|0|0",
"Reaper|Soul|2.2|0.485|0|0|0|0.689|0|0.6|0|0|0|14||1||0|||0.45|0|0.5||||||||0|0|0|0|0",
"Reaper|Domination|2.596|1.53|1.2|0|0|0.35|0.5|0.35|0|0|0|14||1||0|||1.35|0|0.5|0.37|1.05|0.9|0.9||||||||",
"Primalist|Geomancy|0|0|0|0.397|0|0.654|0.5|0.6|0|0|0|||0||1|1||0.5|0.01|0||||||||0|0|0|0|0",
"Primalist|Grovekeeper|2.2|0.374|0|0.093|0|0.5|0|0.6|0|0|0|14||1||0.25|0.25|1|0.2|0|0||||||||0|0|0|0|0",
"Primalist|Mountain King|4|0.8|2|0|0|0.5|1.1|1.5|0|0|0|10||1||0.5|0.5||0|0|1.5|0|1.5|1.2|2|0|0|0|||||",
"Primalist|Wildwalker|2.2|0.486|0|0|0|0.65|0|0.6|0|0|0|14||1||0|||0.45|0|0.5||||||||0|0|0|0|0",
"Runemaster|Engravement|1.125|1.429|0|0.109|0|0.2|0|0.6|0|0|0|14||1||0.5|0.5||0|0|0.5||||||||0|0|0|0|0",
"Runemaster|Glyphic|0|0|0|0.239|0.33|0.69|0|0.6|0|0|0|||0||1|1||0|0.01|0||||||||0|0|0|0|0",
"Runemaster|Riftblade|1|1.643|0|0.144|0|0.2|0|0.6|0|0|0|14||1||0.25|0.25||0|0|0.5||||||||0|0|0|0|0",
}

local function Split(row)
    local fields, start = {}, 1
    while true do
        local stop = string.find(row, "|", start, true)
        if not stop then
            table.insert(fields, string.sub(row, start))
            return fields
        end
        table.insert(fields, string.sub(row, start, stop - 1))
        start = stop + 1
    end
end

Templates.list = {}
Templates.byKey = {}
for _, row in ipairs(ROWS) do
    local fields = Split(row)
    local className, specialization = fields[1], fields[2]
    local weights = {}
    for index, statName in ipairs(STAT_NAMES) do
        local value = tonumber(fields[index + 2])
        if value and value ~= 0 then weights[statName] = value end
    end
    local template = {
        class = className,
        specialization = specialization,
        name = className .. " - " .. specialization,
        weights = weights,
    }
    table.insert(Templates.list, template)
    Templates.byKey[className .. "\031" .. specialization] = template
end

ROWS = nil
