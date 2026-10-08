-- Player.lua: builds the *player context* table the Evaluator reads (class,
-- level, dual wield, weapon skills, preferred armor type, active weight
-- scale). Talks to the WoW API; Evaluator/Weights never do.
local _, ns = ...

local Player = {}
ns.Player = Player

-- Weapon slots whose equipped weapon types make up player.weaponSkills
-- (INVSLOT_MAINHAND/OFFHAND/RANGED;
-- https://warcraft.wiki.gg/wiki/InventorySlotId).
local WEAPON_SLOTS = { 16, 17, 18 }

-- Enum.ItemArmorSubclass values (https://warcraft.wiki.gg/wiki/Enum.ItemArmorSubclass).
local CLOTH, LEATHER, MAIL, PLATE = 1, 2, 3, 4

-- Best armor type per class: { below level 40, from level 40 }. These are the
-- classic rules; Forever appears to keep them, but they aren't confirmed per
-- class. The beta's level cap (30) keeps the 40 gate out of reach for now.
-- Wearing a higher type than this table says (see PreferredArmor) wins, so a
-- wrong gate can only make the armor-type filter looser, never stricter.
local ARMOR_BY_CLASS = {
    WARRIOR = { MAIL, PLATE },
    PALADIN = { MAIL, PLATE },
    HUNTER = { LEATHER, MAIL },
    SHAMAN = { LEATHER, MAIL },
    ROGUE = { LEATHER, LEATHER },
    DRUID = { LEATHER, LEATHER },
    MAGE = { CLOTH, CLOTH },
    PRIEST = { CLOTH, CLOTH },
    WARLOCK = { CLOTH, CLOTH },
}
local ARMOR_GATE_LEVEL = 40

-- Pure: the class/level table above, raised to the best armor type the
-- player already has equipped. `equippedArmor` is a list of subclassIDs.
function Player.PreferredArmor(classFile, level, equippedArmor)
    local entry = ARMOR_BY_CLASS[classFile]
    local best
    if entry then
        best = (level or 1) >= ARMOR_GATE_LEVEL and entry[2] or entry[1]
    end
    for _, sub in ipairs(equippedArmor or {}) do
        if sub >= CLOTH and sub <= PLATE and (not best or sub > best) then
            best = sub
        end
    end
    return best
end

-- Per-character weight profile id ("default:tank", "user:My Ret"), or nil for
-- the class default. Stored in db.chars[charKey].profile (set by the Stat
-- Weights panel or /gs profile; see Profiles.lua).
function Player.ChosenProfile()
    local db = ns.DB()
    local char = db and ns.charKey and db.chars and db.chars[ns.charKey]
    return char and char.profile
end

-- Localized class name for Profiles.DefaultName ("Paladin DPS - Default").
-- LOCALIZED_CLASS_NAMES_MALE is a FrameXML global keyed by class file,
-- set on Forever by Blizzard_FrameXMLBase/Constants.lua (`forever` branch,
-- l.37: LocalizedClassList(false)). Nil offline, where Profiles falls back
-- to the class file.
function ns.ClassName(classFile)
    return LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
end

-- `equipped` is the Scanner's [slotID] = descriptor table, so this reads the
-- weapon types and armor types already resolved by ItemData instead of
-- calling the item APIs again.
function Player.Build(equipped)
    equipped = equipped or {}
    local _, classFile = UnitClass("player")
    local level = UnitLevel("player")

    local weaponSkills = {}
    for _, slot in ipairs(WEAPON_SLOTS) do
        local item = equipped[slot]
        if item and item.weaponType and item.weaponType ~= "FISHING_POLE" then
            weaponSkills[item.weaponType] = true
        end
    end
    -- IsDualWielding is the live "two weapons equipped now" state; the
    -- DUAL_WIELD skill stat only helps while that's true.
    if IsDualWielding and IsDualWielding() then
        weaponSkills.DUAL_WIELD = true
    end

    local equippedArmor = {}
    for slot, item in pairs(equipped) do
        -- Cloaks are always cloth and say nothing about proficiency.
        if item.classID == 4 and slot ~= 15 then
            equippedArmor[#equippedArmor + 1] = item.subclassID
        end
    end

    -- What a "spec" means under Forever's 3-tree talents isn't settled; this
    -- is recorded for debug output only and nothing reads it yet.
    local specID
    local specAPI = C_SpecializationInfo
    if specAPI and specAPI.GetSpecialization and specAPI.GetSpecializationInfo then
        local index = specAPI.GetSpecialization()
        if index and index > 0 then
            specID = specAPI.GetSpecializationInfo(index)
        end
    end

    return {
        classFile = classFile,
        level = level,
        specID = specID,
        -- CanDualWield is the capability check (can this character dual wield
        -- at all).
        canDualWield = CanDualWield and CanDualWield() or false,
        -- Proficiency comes from ItemData's per-item `usable`
        -- (C_PlayerInfo.CanUseItem), so these stay empty for now.
        armorProf = {},
        weaponProf = {},
        preferredArmorSubclass = Player.PreferredArmor(classFile, level, equippedArmor),
        weaponSkills = weaponSkills,
        profile = Player.ChosenProfile(),
    }
end
