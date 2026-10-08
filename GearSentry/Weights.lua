-- Weights.lua: per-class stat-weight presets ("scales") and the rules that
-- turn a GetItemStats key into a weight. Pure Lua: no WoW API calls, so it
-- loads under plain `lua` for tests. The stat keys are the ones the Forever
-- client's C_Item.GetItemStats returns.
--
-- The numbers are hand-set starting points, not simulated. Item Hit/Crit on
-- Forever are ratings budgeted about 1:1 with primary stats, so rating
-- weights sit on the same scale as primary stats. The ratios were
-- sanity-checked against Pawn's Classic/BC scales as a reference only (Pawn
-- is CC BY-NC-ND: its tables are never copied).
local _, ns = ...

local Weights = {}
ns.Weights = Weights

-- Builds a stats table from short names: S{ STRENGTH = 1 } becomes
-- { ITEM_MOD_STRENGTH_SHORT = 1 }. Keeps the preset tables readable.
local function S(short)
    local stats = {}
    for name, weight in pairs(short) do
        stats["ITEM_MOD_" .. name .. "_SHORT"] = weight
    end
    return stats
end

local function set(list)
    local t = {}
    for _, v in ipairs(list) do
        t[v] = true
    end
    return t
end

----------------------------------------------------------------------------
-- Key families (Forever-only stats). Token lists come from the client's
-- GlobalStrings (the ITEM_MOD_* entries).
----------------------------------------------------------------------------

local SCHOOLS = set({ "PHYSICAL", "HOLY", "FIRE", "NATURE", "FROST", "SHADOW", "ARCANE" })

-- Also the tokens ItemData uses for descriptor.weaponType and Player uses
-- for player.weaponSkills, so an "ITEM_MOD_DAGGERS_SHORT" stat can be
-- matched against the dagger the player actually wields.
local WEAPON_SKILLS = set({
    "TWOHANDED_AXES", "TWOHANDED_MACES", "TWOHANDED_SWORDS", "AXES", "BOWS", "CROSSBOWS",
    "DAGGERS", "DUAL_WIELD", "FIST_WEAPONS", "GUNS", "MACES", "POLEARMS", "STAVES", "SWORDS",
    "THROWN", "WANDS",
})

local PROFESSIONS = set({
    "ALCHEMY", "BLACKSMITHING", "ENCHANTING", "ENGINEERING", "JEWELCRAFTING", "LEATHERWORKING",
    "HERBALISM", "MINING", "SKINNING", "COOKING", "FIRST_AID", "FISHING", "TAILORING",
})

Weights.SCHOOLS = SCHOOLS
Weights.WEAPON_SKILLS = WEAPON_SKILLS
Weights.PROFESSIONS = PROFESSIONS

local KEY_SPELL_DAMAGE = "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT"
local KEY_SPELL_PEN = "ITEM_MOD_SPELL_PENETRATION_SHORT"
local KEY_AP = "ITEM_MOD_ATTACK_POWER_SHORT"

-- Defaults for scale fields a preset leaves out.
local SCALE_DEFAULTS = {
    armor = 0,
    dps = 0,
    offhandDps = 0,
    rangedDps = 0,
    weaponSkill = 0,
    situational = 0.1,
    resistance = 0,
}
-- Profiles.lua builds complete user profiles from these.
Weights.SCALE_DEFAULTS = SCALE_DEFAULTS

----------------------------------------------------------------------------
-- Presets (provisional, see header)
----------------------------------------------------------------------------

local MELEE_SECONDARY = { HIT_RATING = 1, CRIT_RATING = 0.9, HASTE_RATING = 0.6, EXPERTISE_RATING = 0.9 }

local function merge(...)
    local out = {}
    for i = 1, select("#", ...) do
        for k, v in pairs((select(i, ...))) do
            out[k] = v
        end
    end
    return out
end

local CASTER_BASE = {
    INTELLECT = 0.45, SPIRIT = 0.3, STAMINA = 0.25,
    SPELL_POWER = 1, SPELL_DAMAGE_DONE = 0.95, SPELL_PENETRATION = 0.2,
    HIT_RATING = 1, CRIT_RATING = 0.6, HASTE_RATING = 0.6, MANA_REGENERATION = 0.5,
}

-- Caster and healer scales weight armor just enough to break ties: a mail
-- piece with the same stats as a cloth one is an upgrade, but ~150 armor
-- (cloth vs mail chest around level 20) is still worth less than one point of
-- Intellect (0.45), so stats keep winning over armor type. With armor at 0
-- those items tied, and ties never alert.
local CASTER_ARMOR = 0.002

local HEALER_BASE = {
    INTELLECT = 1, SPIRIT = 0.5, STAMINA = 0.2,
    SPELL_POWER = 0.9, SPELL_HEALING_DONE = 0.9,
    CRIT_RATING = 0.5, HASTE_RATING = 0.5, MANA_REGENERATION = 1,
}

Weights.presets = {
    WARRIOR = {
        default = "dps",
        scales = {
            dps = {
                stats = S(merge(MELEE_SECONDARY, {
                    STRENGTH = 1, AGILITY = 0.6, STAMINA = 0.25, ATTACK_POWER = 0.45,
                    HEALTH_REGEN = 0.3, DEFENSE_SKILL_RATING = 0.1,
                })),
                armor = 0.01, dps = 5, offhandDps = 1.5, rangedDps = 0.3, weaponSkill = 1,
            },
            tank = {
                stats = S({
                    STAMINA = 1, STRENGTH = 0.5, AGILITY = 0.5, DEFENSE_SKILL_RATING = 1,
                    DODGE_RATING = 1, PARRY_RATING = 0.9, BLOCK_RATING = 0.6, BLOCK_VALUE = 0.3,
                    EXTRA_ARMOR = 0.05, HIT_RATING = 0.5, EXPERTISE_RATING = 0.5, ATTACK_POWER = 0.1,
                }),
                armor = 0.05, dps = 1, rangedDps = 0.1, weaponSkill = 0.5,
            },
        },
    },
    PALADIN = {
        default = "dps",
        scales = {
            dps = {
                stats = S(merge(MELEE_SECONDARY, {
                    STRENGTH = 1, AGILITY = 0.6, STAMINA = 0.25, INTELLECT = 0.35, SPIRIT = 0.1,
                    ATTACK_POWER = 0.45, SPELL_POWER = 0.3, MANA_REGENERATION = 0.3,
                })),
                armor = 0.01, dps = 5, weaponSkill = 1, schools = set({ "HOLY" }),
            },
            tank = {
                stats = S({
                    STAMINA = 1, STRENGTH = 0.5, AGILITY = 0.4, INTELLECT = 0.3,
                    DEFENSE_SKILL_RATING = 1, DODGE_RATING = 1, PARRY_RATING = 0.9,
                    BLOCK_RATING = 0.6, BLOCK_VALUE = 0.4, EXTRA_ARMOR = 0.05,
                    SPELL_POWER = 0.4, SPELL_DAMAGE_DONE = 0.4, HIT_RATING = 0.5,
                }),
                armor = 0.05, dps = 1, weaponSkill = 0.5, schools = set({ "HOLY" }),
            },
            healer = { stats = S(HEALER_BASE), armor = CASTER_ARMOR, dps = 0.2, schools = set({ "HOLY" }) },
        },
    },
    HUNTER = {
        default = "dps",
        scales = {
            dps = {
                stats = S(merge(MELEE_SECONDARY, {
                    AGILITY = 1, STRENGTH = 0.1, STAMINA = 0.25, INTELLECT = 0.5, SPIRIT = 0.1,
                    ATTACK_POWER = 0.4, RANGED_ATTACK_POWER = 0.45, MANA_REGENERATION = 0.2,
                })),
                armor = 0.01, dps = 0.8, offhandDps = 0.4, rangedDps = 3, weaponSkill = 1,
            },
        },
    },
    ROGUE = {
        default = "dps",
        scales = {
            dps = {
                stats = S(merge(MELEE_SECONDARY, {
                    AGILITY = 1, STRENGTH = 0.5, STAMINA = 0.25, ATTACK_POWER = 0.45,
                })),
                armor = 0.01, dps = 3, offhandDps = 2, rangedDps = 0.3, weaponSkill = 1,
            },
        },
    },
    PRIEST = {
        default = "caster",
        scales = {
            caster = {
                stats = S(merge(CASTER_BASE, { INTELLECT = 0.4, SPIRIT = 0.4 })),
                armor = CASTER_ARMOR, dps = 0.1, rangedDps = 0.6, schools = set({ "SHADOW", "HOLY" }),
            },
            healer = { stats = S(HEALER_BASE), armor = CASTER_ARMOR, rangedDps = 0.3, schools = set({ "HOLY" }) },
        },
    },
    SHAMAN = {
        default = "melee",
        scales = {
            melee = {
                stats = S(merge(MELEE_SECONDARY, {
                    STRENGTH = 1, AGILITY = 0.85, STAMINA = 0.25, INTELLECT = 0.3,
                    ATTACK_POWER = 0.45, SPELL_DAMAGE_DONE = 0.2, SPELL_POWER = 0.2,
                })),
                armor = 0.01, dps = 3, offhandDps = 1.5, weaponSkill = 1,
                schools = set({ "NATURE", "FIRE", "FROST" }),
            },
            caster = {
                stats = S(CASTER_BASE), armor = CASTER_ARMOR, dps = 0.3, schools = set({ "NATURE", "FIRE", "FROST" }),
            },
            healer = { stats = S(HEALER_BASE), armor = CASTER_ARMOR, dps = 0.2, schools = set({ "NATURE" }) },
        },
    },
    MAGE = {
        default = "caster",
        scales = {
            caster = {
                stats = S(merge(CASTER_BASE, { MANA_REGENERATION = 0.4 })),
                armor = CASTER_ARMOR, dps = 0.1, rangedDps = 0.6, schools = set({ "FIRE", "FROST", "ARCANE" }),
            },
        },
    },
    WARLOCK = {
        default = "caster",
        scales = {
            caster = {
                stats = S(merge(CASTER_BASE, { STAMINA = 0.35, INTELLECT = 0.4, CRIT_RATING = 0.5 })),
                armor = CASTER_ARMOR, dps = 0.1, rangedDps = 0.6, schools = set({ "SHADOW", "FIRE" }),
            },
        },
    },
    DRUID = {
        default = "feral",
        scales = {
            -- Feral forms don't use the weapon's damage, so weapon DPS is
            -- nearly worthless here (vanilla behaviour; unverified on Forever).
            feral = {
                stats = S(merge(MELEE_SECONDARY, {
                    AGILITY = 1, STRENGTH = 0.9, STAMINA = 0.3, INTELLECT = 0.2, ATTACK_POWER = 0.45,
                    DEFENSE_SKILL_RATING = 0.3, DODGE_RATING = 0.3,
                })),
                armor = 0.02, dps = 0.3,
            },
            caster = { stats = S(CASTER_BASE), armor = CASTER_ARMOR, dps = 0.1, schools = set({ "NATURE", "ARCANE" }) },
            healer = { stats = S(HEALER_BASE), armor = CASTER_ARMOR, dps = 0.1, schools = set({ "NATURE" }) },
        },
    },
}

----------------------------------------------------------------------------
-- Resolve: preset + defaults + user overrides -> one flat scale table
----------------------------------------------------------------------------

local function copyTable(t)
    local out = {}
    for k, v in pairs(t or {}) do
        out[k] = v
    end
    return out
end

-- Returns the scale names a class has, sorted, for the options dropdown.
function Weights.ScaleNames(classFile)
    local preset = Weights.presets[classFile]
    local names = {}
    if preset then
        for name in pairs(preset.scales) do
            names[#names + 1] = name
        end
        table.sort(names)
    end
    return names
end

-- Merges the class preset's scale with SCALE_DEFAULTS. An unknown or nil
-- scaleName falls back to the class default. Returns nil when the class has
-- no preset. User-made scales are profiles (Profiles.lua), which call this
-- for their read-only defaults. The returned table is a fresh copy; mutating
-- it never touches a preset.
function Weights.Resolve(classFile, scaleName)
    local preset = Weights.presets[classFile]
    if not preset then
        return nil
    end
    if not (scaleName and preset.scales[scaleName]) then
        scaleName = preset.default
    end
    local base = preset.scales[scaleName]

    local scale = copyTable(SCALE_DEFAULTS)
    for k, v in pairs(base) do
        scale[k] = v
    end
    scale.stats = copyTable(base.stats)
    scale.schools = copyTable(base.schools)
    scale.name = scaleName

    return scale
end

----------------------------------------------------------------------------
-- StatWeight: the per-key weight rules
----------------------------------------------------------------------------

-- Returns weight, known. `known` is false for keys no rule recognises; the
-- Evaluator lists those as "unscored" in its debug breakdown rather than
-- silently treating them as worthless.
-- `item` is the descriptor being scored (for its own weaponType); `player`
-- supplies weaponSkills. Both may be nil in callers that don't care.
function Weights.StatWeight(scale, key, player, item)
    local exact = scale.stats[key]
    if exact then
        return exact, true
    end

    -- Armor is descriptor.armor, scored separately; ItemData strips this key
    -- from stats, but never double-count it if one slips through.
    -- Same for weapon DPS (descriptor.dps).
    if key == "RESISTANCE0_NAME" or key == "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" then
        return 0, true
    end
    if key:match("^RESISTANCE%d+_NAME$") or key == "ITEM_MOD_SPELL_RESISTANCE_ALL_SCHOOLS_SHORT" then
        return scale.resistance, true
    end
    -- Per-school resistances surface as ITEM_MOD_<SCHOOL>_RESISTANCE_SHORT
    -- (seen in game: ITEM_MOD_FROST_RESISTANCE_SHORT on Avala's Binding), not
    -- RESISTANCEn_NAME as first guessed. Both forms are kept.
    local resToken = key:match("^ITEM_MOD_(%u+)_RESISTANCE_SHORT$")
    if resToken and SCHOOLS[resToken] then
        return scale.resistance, true
    end

    local token = key:match("^ITEM_MOD_(.+)_DAMAGE_DONE_SHORT$")
    if token and SCHOOLS[token] then
        if token ~= "PHYSICAL" and scale.schools[token] then
            return scale.stats[KEY_SPELL_DAMAGE] or 0, true
        end
        return 0, true
    end

    token = key:match("^ITEM_MOD_(.+)_PENETRATION_SHORT$")
    if token and SCHOOLS[token] then
        if scale.schools[token] then
            return scale.stats[KEY_SPELL_PEN] or 0, true
        end
        return 0, true
    end

    if key:match("^ITEM_MOD_ATTACK_POWER_VS_%u+_SHORT$") then
        return (scale.stats[KEY_AP] or 0) * scale.situational, true
    end
    if key:match("^ITEM_MOD_SPELL_DAMAGE_VS_%u+_SHORT$") then
        return (scale.stats[KEY_SPELL_DAMAGE] or 0) * scale.situational, true
    end

    token = key:match("^ITEM_MOD_(.+)_SHORT$")
    if token and PROFESSIONS[token] then
        return 0, true
    end
    if token and WEAPON_SKILLS[token] then
        local skills = player and player.weaponSkills
        if (skills and skills[token]) or (item and item.weaponType == token) then
            return scale.weaponSkill, true
        end
        return 0, true
    end

    return 0, false
end

