-- ItemData.lua: turns an item location (bag/slot, or an equipped inventory
-- slot) or a bare item link into the item descriptor the rest of the addon
-- works with. Talks to the WoW API, unlike Weights.lua/Evaluator.lua.
--
-- Async contract: this file only ever hands out a *complete* descriptor. If
-- the item's data isn't cached yet, it requests the load and returns `nil,
-- "pending"` instead of a partial table. Scanner.lua (not this file) is
-- responsible for retrying on GET_ITEM_INFO_RECEIVED/ITEM_DATA_LOAD_RESULT.
local _, ns = ...

local ItemData = {}
ns.ItemData = ItemData

----------------------------------------------------------------------------
-- Weapon subclass -> weapon-skill token
----------------------------------------------------------------------------

-- Enum.ItemWeaponSubclass field names, from
-- https://warcraft.wiki.gg/wiki/Enum.ItemWeaponSubclass. Built by *field
-- name*, not hard-coded numeric subclassIDs (feature-detect, don't
-- version-gate), and only mapped to tokens that actually exist in
-- Weights.WEAPON_SKILLS (the Forever-only weapon-skill stats in the client's
-- GlobalStrings). FISHING_POLE is this file's own token (not a weapon-skill
-- stat key); the candidate filter uses it to exclude fishing poles.
--
-- Deliberately absent (no Weights.WEAPON_SKILLS token, and not
-- FISHING_POLE): Warglaive (no classic-style skill line), Bearclaw/Catclaw
-- (feral forms don't use weapon damage - see Weights.lua DRUID.feral
-- comment), Generic, Obsolete3.
local function BuildWeaponTypeMap()
    local sub = Enum and Enum.ItemWeaponSubclass
    if not sub then
        return {}
    end
    return {
        [sub.Axe1H] = "AXES",
        [sub.Axe2H] = "TWOHANDED_AXES",
        [sub.Bows] = "BOWS",
        [sub.Guns] = "GUNS",
        [sub.Mace1H] = "MACES",
        [sub.Mace2H] = "TWOHANDED_MACES",
        [sub.Polearm] = "POLEARMS",
        [sub.Sword1H] = "SWORDS",
        [sub.Sword2H] = "TWOHANDED_SWORDS",
        [sub.Staff] = "STAVES",
        [sub.Unarmed] = "FIST_WEAPONS",
        [sub.Dagger] = "DAGGERS",
        [sub.Thrown] = "THROWN",
        [sub.Crossbow] = "CROSSBOWS",
        [sub.Wand] = "WANDS",
        [sub.Fishingpole] = "FISHING_POLE",
    }
end

-- Built once at load time: Enum is static client data, always present by the
-- time any addon file runs (unlike item/tooltip data, which is async). Tests
-- stub a fake global `Enum` before loading this file to exercise this map
-- without the real client.
local WEAPON_TYPE_MAP = BuildWeaponTypeMap()

-- Public so it's independently testable:
-- ItemData.WeaponTypeToken(Enum.ItemWeaponSubclass.Dagger) == "DAGGERS".
function ItemData.WeaponTypeToken(subclassID)
    return WEAPON_TYPE_MAP[subclassID]
end

----------------------------------------------------------------------------
-- Weapon damage/speed/DPS tooltip parsing (pure - no WoW API calls)
----------------------------------------------------------------------------
-- The tooltip layout (one line vs. shared leftText/rightText) is inferred
-- from GlobalStrings and only partly verified in game, so this is written
-- tolerant of either layout: it scans every line's leftText *and* rightText
-- for each kind of content independently, rather than assuming a fixed line
-- structure.

-- Escapes every Lua pattern-magic character in `s` so it can be used as a
-- literal substring inside a pattern.
local function EscapeLiteral(s)
    return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0"))
end

-- Turns a GlobalStrings template containing literal "%s" placeholders
-- (e.g. DAMAGE_TEMPLATE = "%s - %s Damage") into an anchored Lua pattern
-- with one capture group per placeholder. Uses plain (non-pattern) find
-- for the literal "%s" markers so the template's own text never needs
-- pattern-escaping gymnastics.
local function TemplateToPattern(template)
    local parts = {}
    local pos = 1
    while true do
        local s, e = template:find("%s", pos, true)
        if not s then
            parts[#parts + 1] = EscapeLiteral(template:sub(pos))
            break
        end
        parts[#parts + 1] = EscapeLiteral(template:sub(pos, s - 1))
        parts[#parts + 1] = "(.-)"
        pos = e + 1
    end
    return "^" .. table.concat(parts) .. "$"
end

-- Strips WoW's inline color escape codes (|cAARRGGBB ... |r), e.g. the
-- pre-colored ITEM_UPGRADE_BONUS_DAMAGE_TEMPLATE text, so the templates
-- above can match plain text.
local function StripColorCodes(text)
    if not text then
        return nil
    end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    return text
end

-- Numbers in these templates can carry LARGE_NUMBER_SEPERATOR ("," for enUS).
-- Only enUS ships (ns.L), so "," is hardcoded here rather than read live off
-- the global; other locales would need it read live.
local function ParseNumber(text)
    if not text then
        return nil
    end
    return tonumber((text:gsub(",", "")))
end

local function MatchSpeedLabel(text, label)
    if not text or not label or label == "" then
        return nil
    end
    if text:sub(1, #label) == label then
        return (text:sub(#label + 1):gsub("^%s+", ""))
    end
    return nil
end

-- Looks for a "Speed"/"Attack Speed" label on either side of one tooltip
-- line, handling both a combined "Speed 2.60" string and a split
-- leftText="Speed" / rightText="2.60" layout (both unverified - see the
-- doc section above).
local function MatchSpeed(left, right, templates)
    for _, label in ipairs({ templates.speed, templates.speedAlt }) do
        local rest = MatchSpeedLabel(left, label)
        if rest then
            if rest ~= "" then
                local n = ParseNumber(rest)
                if n then
                    return n
                end
            elseif right then
                local n = ParseNumber(right)
                if n then
                    return n
                end
            end
        end
        rest = MatchSpeedLabel(right, label)
        if rest and rest ~= "" then
            local n = ParseNumber(rest)
            if n then
                return n
            end
        end
    end
    return nil
end

-- Pure function: parses a weapon tooltip's lines for min/max damage, speed
-- and DPS. No WoW API calls - takes the already-fetched `lines` array
-- (Structure TooltipData's `lines` field: each entry has
-- `leftText`/`rightText`) and the live GlobalStrings values as `templates`:
--   { damage, singleDamage, damageSchool, singleDamageSchool, dps,
--     speed, speedAlt }
-- (damageSchool/singleDamageSchool/speedAlt may be nil/omitted).
--
-- Deliberately does NOT filter by `line.type`: damage/speed/DPS lines are all
-- `Enum.TooltipDataLineType.None`, indistinguishable from any other plain
-- text line except by matching against the templates (confirmed from
-- Blizzard's source), so filtering by type would just be a no-op here.
--
-- PLUS_* bonus-damage lines (from an enchant/buff) and the pre-colored
-- ITEM_UPGRADE_BONUS_DAMAGE_TEMPLATE are not in `templates` and so are
-- never matched as the base damage line; the anchored ("^...$") patterns
-- also reject the "+ " prefix those lines carry.
--
-- Returns { minDmg, maxDmg, speed, dps } or nil if no damage line matched.
function ItemData.ParseWeaponTooltip(lines, templates)
    if not lines then
        return nil
    end

    local damagePattern = TemplateToPattern(templates.damage)
    local singlePattern = TemplateToPattern(templates.singleDamage)
    local damageSchoolPattern = templates.damageSchool and TemplateToPattern(templates.damageSchool)
    local singleSchoolPattern = templates.singleDamageSchool and TemplateToPattern(templates.singleDamageSchool)
    local dpsPattern = TemplateToPattern(templates.dps)

    local minDmg, maxDmg, speed, dps

    local function tryDamage(text)
        if minDmg or not text then
            return
        end
        -- Try the _WITH_SCHOOL variants first: a wand's "5 Frost Damage"
        -- would otherwise satisfy the plain SINGLE_DAMAGE_TEMPLATE pattern
        -- too, with the lazy capture swallowing the school word along with
        -- the number (then failing to parse as a number) - the school
        -- pattern's extra trailing word requirement only matches text that
        -- actually has a school word, so trying it first is safe for plain
        -- (non-wand) damage lines, which never satisfy it.
        local a, b
        if damageSchoolPattern then
            a, b = text:match(damageSchoolPattern)
        end
        if not (a and b) then
            a, b = text:match(damagePattern)
        end
        if a and b then
            minDmg, maxDmg = ParseNumber(a), ParseNumber(b)
            return
        end
        a = nil
        if singleSchoolPattern then
            a = text:match(singleSchoolPattern)
        end
        if not a then
            a = text:match(singlePattern)
        end
        if a then
            minDmg, maxDmg = ParseNumber(a), ParseNumber(a)
        end
    end

    local function tryDps(text)
        if dps or not text then
            return
        end
        local a = text:match(dpsPattern)
        if a then
            dps = ParseNumber(a)
        end
    end

    for _, line in ipairs(lines) do
        local left = StripColorCodes(line.leftText)
        local right = StripColorCodes(line.rightText)
        tryDamage(left)
        tryDamage(right)
        tryDps(left)
        tryDps(right)
        if not speed then
            speed = MatchSpeed(left, right, templates)
        end
    end

    if not minDmg then
        return nil
    end
    if speed and not dps then
        -- Same formula as PaperDollFrame_CalculateDPS (Camelot
        -- PaperDollFrameStats.lua) when the DPS line is absent.
        dps = (minDmg + maxDmg) / (2 * speed)
    end
    return { minDmg = minDmg, maxDmg = maxDmg, speed = speed, dps = dps }
end

-- Reads the live GlobalStrings templates. Kept as its own tiny function so
-- ParseWeaponTooltip above never touches a global directly, which keeps the
-- parser testable outside the game with hand-written templates.
local function LiveTemplates()
    return {
        damage = DAMAGE_TEMPLATE,
        singleDamage = SINGLE_DAMAGE_TEMPLATE,
        damageSchool = DAMAGE_TEMPLATE_WITH_SCHOOL,
        singleDamageSchool = SINGLE_DAMAGE_TEMPLATE_WITH_SCHOOL,
        dps = DPS_TEMPLATE,
        speed = SPEED,
        speedAlt = WEAPON_SPEED,
    }
end

----------------------------------------------------------------------------
-- hasSpecialEffect: tooltip has a Use:/Equip:/Chance on hit: line
----------------------------------------------------------------------------
-- Labels confirmed as real GlobalStrings on build 1.60.1.70235 via the
-- wago.tools GlobalStrings table: IDs 10753
-- ITEM_SPELL_TRIGGER_ONEQUIP = "Equip:", 11086 ITEM_SPELL_TRIGGER_ONUSE =
-- "Use:", 12730 ITEM_SPELL_TRIGGER_ONPROC = "Chance on hit:". Plain
-- FrameXML globals (not in the wiki compat tool, which only covers C_*/
-- global *functions* - these are strings), loaded automatically by the
-- client like any other GlobalString.
local function HasTriggerLabel(text)
    if not text then
        return false
    end
    text = StripColorCodes(text)
    local labels = { ITEM_SPELL_TRIGGER_ONEQUIP, ITEM_SPELL_TRIGGER_ONUSE, ITEM_SPELL_TRIGGER_ONPROC }
    for _, label in ipairs(labels) do
        if label and text:sub(1, #label) == label then
            return true
        end
    end
    return false
end

local function HasSpecialEffect(lines)
    if not lines then
        return false
    end
    for _, line in ipairs(lines) do
        if HasTriggerLabel(line.leftText) then
            return true
        end
    end
    return false
end

----------------------------------------------------------------------------
-- usable: can the player use/equip this item right now
----------------------------------------------------------------------------
-- C_PlayerInfo.CanUseItem is the single source of truth for
-- level/class/proficiency: no hand-rolled armor-type-vs-class or
-- weapon-skill-vs-class tables. Kept in its own function so it's easy to swap
-- if it turns out not to reflect proficiency correctly.
local function IsUsable(itemID)
    if not (C_PlayerInfo and C_PlayerInfo.CanUseItem) then
        return true
    end
    return C_PlayerInfo.CanUseItem(itemID) == true
end

----------------------------------------------------------------------------
-- Location helpers
----------------------------------------------------------------------------

-- `loc` is one of:
--   { bag = bagID, slot = slotIndex, link = link }
--   { equipSlot = invSlotId, link = link }
--   { link = link }  -- link-only, no location (/gs eval <link>)
local function LocationKey(loc)
    if loc.bag ~= nil then
        return "bag:" .. loc.bag .. ":" .. loc.slot
    elseif loc.equipSlot ~= nil then
        return "equip:" .. loc.equipSlot
    end
    return "link"
end

local function LocationObject(loc)
    if loc.bag ~= nil and ItemLocation then
        return ItemLocation:CreateFromBagAndSlot(loc.bag, loc.slot)
    elseif loc.equipSlot ~= nil and ItemLocation then
        return ItemLocation:CreateFromEquipmentSlot(loc.equipSlot)
    end
    return nil
end

local function TooltipLines(loc)
    if not C_TooltipInfo then
        return nil
    end
    local data
    if loc.bag ~= nil then
        data = C_TooltipInfo.GetBagItem(loc.bag, loc.slot)
    elseif loc.equipSlot ~= nil then
        data = C_TooltipInfo.GetInventoryItem("player", loc.equipSlot)
    elseif loc.link then
        data = C_TooltipInfo.GetHyperlink(loc.link)
    end
    return data and data.lines
end

-- bindType is the 14th return of C_Item.GetItemInfo (Enum.ItemBind; see
-- https://warcraft.wiki.gg/wiki/Enum.ItemBind). `locObj` is nil for a
-- link-only descriptor, in which case there's no way to check C_Item.IsBound
-- (it takes an ItemLocation, not a link) - the best this file can do without
-- a location is "would this bind if equipped", not "is it already bound".
local function ComputeBindsOnEquip(bindType, locObj)
    if not (Enum and Enum.ItemBind) or bindType ~= Enum.ItemBind.OnEquip then
        return false
    end
    if locObj and locObj.IsValid and locObj:IsValid() and C_Item.IsBound(locObj) then
        return false -- already bound; re-equipping binds nothing new
    end
    return true
end

----------------------------------------------------------------------------
-- Descriptor assembly
----------------------------------------------------------------------------

local function BuildDescriptor(loc)
    local link = loc.link

    -- Synchronous, always available for a valid link - classification/slot
    -- never blocks on the cache.
    local itemID, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
    if not itemID then
        return nil, "pending"
    end

    -- Everything else needs the item to be cached (async). A nil name is the
    -- "not cached yet" signal; kick off a load and let the caller (Scanner)
    -- retry rather than handing out a partial descriptor.
    local name, _, quality, ilvl, reqLevel, _, _, _, _, _, _, _, _, bindType = C_Item.GetItemInfo(link)
    if not name then
        -- ByID, not RequestLoadItemData: on Forever that one only takes an
        -- ItemLocation and errors on a link ("Usage:
        -- C_Item.RequestLoadItemData(itemLocation)", seen in game).
        -- RequestLoadItemDataByID takes ItemInfo (ID, link or name); both
        -- checked in the forever branch's generated ItemDocumentation.lua.
        C_Item.RequestLoadItemDataByID(link)
        return nil, "pending"
    end

    local stats = {}
    for k, v in pairs(C_Item.GetItemStats(link) or {}) do
        stats[k] = v
    end
    -- Armor rides along in the stats table as RESISTANCE0_NAME; move it into
    -- its own field so Weights never double-counts it.
    local armor = stats.RESISTANCE0_NAME
    stats.RESISTANCE0_NAME = nil
    -- Weapons also carry their DPS as a stat on Forever (seen in game as an
    -- "unscored: damage per second" line; GlobalStrings ID 19881). It's
    -- scored through descriptor.dps, so take it out of stats and keep it as
    -- the fallback when the tooltip parse finds no DPS.
    local statDps = stats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT
    stats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT = nil

    local weaponType
    if Enum and Enum.ItemClass and classID == Enum.ItemClass.Weapon then
        weaponType = WEAPON_TYPE_MAP[subclassID]
    end

    local lines = TooltipLines(loc)

    local dps, speed
    if Enum and Enum.ItemClass and classID == Enum.ItemClass.Weapon then
        local parsed = ItemData.ParseWeaponTooltip(lines, LiveTemplates())
        if parsed then
            dps, speed = parsed.dps, parsed.speed
        end
        dps = dps or statDps
    end

    -- GetItemUniquenessByID returns isUnique plus an optional limit category
    -- (name, count, ID): a shared "Unique-Equipped: <category>" group becomes
    -- "cat:<ID>" with its count, a plain unique item becomes "item:<id>", max
    -- 1. Returns are from the generated ItemDocumentation.lua on the forever
    -- branch; Blizzard's AuctionHouseUtil.lua reads them the same way. Which
    -- tooltip wording ("Unique" vs "Unique-Equipped") sets isUnique is
    -- unverified in game.
    local isUnique, _, limitCount, limitCategoryID = C_Item.GetItemUniquenessByID(link)
    local unique
    if limitCategoryID and limitCategoryID ~= 0 then
        unique = { key = "cat:" .. tostring(limitCategoryID), max = limitCount or 1 }
    elseif isUnique then
        unique = { key = "item:" .. tostring(itemID), max = 1 }
    end

    local locObj = LocationObject(loc)
    local guid
    if locObj and locObj.IsValid and locObj:IsValid() then
        guid = C_Item.GetItemGUID(locObj)
    end

    return {
        key = LocationKey(loc),
        link = link,
        itemID = itemID,
        guid = guid,
        equipLoc = equipLoc,
        classID = classID,
        subclassID = subclassID,
        weaponType = weaponType,
        ilvl = ilvl,
        quality = quality,
        stats = stats,
        armor = armor,
        dps = dps,
        speed = speed,
        reqLevel = reqLevel,
        unique = unique,
        bindsOnEquip = ComputeBindsOnEquip(bindType, locObj),
        hasSpecialEffect = HasSpecialEffect(lines),
        usable = IsUsable(itemID),
    }
end

----------------------------------------------------------------------------
-- Public entry points
----------------------------------------------------------------------------

-- Builds a descriptor for a bag slot (bag/slot) or an equipped inventory
-- slot (invSlotId), given as `loc = { bag = bagID, slot = slotIndex }` or
-- `loc = { equipSlot = invSlotId }`. Returns:
--   descriptor              on success
--   nil, "empty"            if there's no item in that bag/equip slot
--   nil, "pending"          if the item exists but isn't cached yet
--                           (a load has been requested; Scanner retries)
function ItemData.FromLocation(loc)
    local link
    if loc.bag ~= nil then
        local info = C_Container.GetContainerItemInfo(loc.bag, loc.slot)
        link = info and info.hyperlink
    elseif loc.equipSlot ~= nil then
        link = GetInventoryItemLink("player", loc.equipSlot)
    end
    if not link then
        return nil, "empty"
    end
    return BuildDescriptor({ bag = loc.bag, slot = loc.slot, equipSlot = loc.equipSlot, link = link })
end

-- Builds a descriptor from a bare item link (or a minimal "item:%d" link,
-- which loses enchant/gem data). Used by `/gs eval <link>` and the tooltip
-- line. Returns the same (descriptor) / (nil, "pending") shape as
-- FromLocation; never "empty" since a link either resolves or doesn't exist
-- at all.
--
-- Contract note: without a location, `guid` is always nil (C_Item.GetItemGUID
-- needs an ItemLocation) and `bindsOnEquip` reflects only "would this bind
-- type equip-bind" rather than "is it already bound" (C_Item.IsBound also
-- needs a location) - see ComputeBindsOnEquip above.
function ItemData.FromLink(link)
    if not link then
        return nil, "pending"
    end
    return BuildDescriptor({ link = link })
end
