-- Evaluator.lua: candidate filter, scoring and slot resolution. Pure Lua: no
-- WoW API calls, so it can be tested outside the game with hand-built item
-- descriptors.
local _, ns = ...

local Evaluator = {}
ns.Evaluator = Evaluator

-- Gains at or below this count as ties. Scores are floating point.
local EPSILON = 1e-6

-- Used when settings leave a key out. Must match Core.lua's DEFAULT_SETTINGS.
Evaluator.DEFAULTS = {
    minGain = 0,
    minGainPct = 2,
    allowLowerArmor = true, -- stats win over armor type unless the user opts in
    suggestBoE = true,
}

----------------------------------------------------------------------------
-- Slot tables. Numbers are INVSLOT_* values; this file can't read those
-- globals. Source: https://warcraft.wiki.gg/wiki/InventorySlotId.
----------------------------------------------------------------------------

local SLOT_MAINHAND, SLOT_OFFHAND, SLOT_RANGED = 16, 17, 18

-- Equip location -> comparison group. Shirts, tabards, ammo, quivers and bags
-- are deliberately absent: they're never suggested.
local SINGLE = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_CHEST = 5,
    INVTYPE_ROBE = 5, INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8,
    INVTYPE_WRIST = 9, INVTYPE_HAND = 10, INVTYPE_CLOAK = 15,
    -- The ranged slot also holds wands and relics.
    INVTYPE_RANGED = SLOT_RANGED, INVTYPE_RANGEDRIGHT = SLOT_RANGED,
    INVTYPE_THROWN = SLOT_RANGED, INVTYPE_RELIC = SLOT_RANGED,
}
local PAIRS = {
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
}
local WEAPON_LOCS = {
    INVTYPE_2HWEAPON = true, INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true,
}

-- Enum.ItemClass.Armor, and the Cloth..Plate range of Enum.ItemArmorSubclass
-- (https://warcraft.wiki.gg/wiki/Enum.ItemArmorSubclass; 1..4 in increasing
-- armor order).
local CLASS_ARMOR = 4
local ARMOR_CLOTH, ARMOR_PLATE = 1, 4

-- Returns "single", slot | "pair", {slots} | "weapons" | nil.
local function groupOf(equipLoc)
    if SINGLE[equipLoc] then
        return "single", SINGLE[equipLoc]
    elseif PAIRS[equipLoc] then
        return "pair", PAIRS[equipLoc]
    elseif WEAPON_LOCS[equipLoc] then
        return "weapons"
    end
    return nil
end

Evaluator.GroupOf = groupOf

local function setting(settings, key)
    local v = settings and settings[key]
    if v == nil then
        return Evaluator.DEFAULTS[key]
    end
    return v
end

----------------------------------------------------------------------------
-- Candidate filter
----------------------------------------------------------------------------

local function ignoreKey(item)
    return item.guid or item.link
end

-- Returns ok, reason. Slot ignores are handled during resolution (an
-- ignored slot's item can't change), not here, so a ring can still go into
-- the other, non-ignored ring slot.
function Evaluator.IsCandidate(item, player, settings, ignore)
    if not groupOf(item.equipLoc) then
        return false, "not gear"
    end
    if item.weaponType == "FISHING_POLE" then
        return false, "profession tool"
    end
    -- Level before usable: CanUseItem is also false for a too-high-level
    -- item, and "level" tells the player more than "unusable".
    if (item.reqLevel or 1) > (player.level or 1) then
        return false, "level"
    end
    if item.usable == false then
        return false, "unusable"
    end
    if not setting(settings, "allowLowerArmor")
        and item.classID == CLASS_ARMOR
        and item.equipLoc ~= "INVTYPE_CLOAK"
        and item.subclassID and item.subclassID >= ARMOR_CLOTH and item.subclassID <= ARMOR_PLATE
        and player.preferredArmorSubclass
        and item.subclassID < player.preferredArmorSubclass
    then
        return false, "armor type"
    end
    if ignore and ignore.items and ignore.items[ignoreKey(item)] then
        return false, "ignored"
    end
    if item.bindsOnEquip and not setting(settings, "suggestBoE") then
        return false, "BoE"
    end
    return true
end

----------------------------------------------------------------------------
-- Scoring
----------------------------------------------------------------------------

local function dpsWeight(scale, slotRole)
    if slotRole == "offhand" then
        return scale.offhandDps
    elseif slotRole == "ranged" then
        return scale.rangedDps
    end
    return scale.dps
end

-- Weighted score of one item. Returns total, breakdown where breakdown maps
-- each contributing key (plus "armor"/"dps") to its points and holds a
-- sorted `unscored` list of keys no weight rule recognised.
function Evaluator.Score(item, scale, player, slotRole)
    local breakdown = { unscored = {} }
    local total = 0
    for key, value in pairs(item.stats or {}) do
        local weight, known = ns.Weights.StatWeight(scale, key, player, item)
        if not known then
            table.insert(breakdown.unscored, key)
        elseif weight ~= 0 then
            breakdown[key] = weight * value
            total = total + weight * value
        end
    end
    table.sort(breakdown.unscored)
    if item.armor and scale.armor ~= 0 then
        breakdown.armor = scale.armor * item.armor
        total = total + breakdown.armor
    end
    if item.dps then
        local w = dpsWeight(scale, slotRole)
        if w ~= 0 then
            breakdown.dps = w * item.dps
            total = total + breakdown.dps
        end
    end
    return total, breakdown
end

local function ilvlScore(item)
    -- Quality only breaks item level ties.
    return (item.ilvl or 0) + (item.quality or 0) / 10
end

-- One scorer per comparison group, so every item in the group is scored on
-- the same basis. `items` is a list of { item, role } to probe.
local function makeScorer(probes, scale, player)
    local basis = "ilvl"
    if scale then
        for _, p in ipairs(probes) do
            if Evaluator.Score(p[1], scale, player, p[2]) > EPSILON then
                basis = "weights"
                break
            end
        end
    end
    local function score(item, role)
        if not item then
            return 0
        end
        if basis == "weights" then
            return (Evaluator.Score(item, scale, player, role))
        end
        return ilvlScore(item)
    end
    return score, basis
end

----------------------------------------------------------------------------
-- Suggestion building and thresholds
----------------------------------------------------------------------------

local function isEquipped(item)
    return item.key and item.key:sub(1, 6) == "equip:"
end

local function passesThreshold(before, after, settings)
    local gain = after - before
    if gain <= EPSILON then
        return false
    end
    if gain < setting(settings, "minGain") then
        return false
    end
    if before > EPSILON and gain / before * 100 < setting(settings, "minGainPct") then
        return false
    end
    return true
end

local function makeSuggestion(group, actions, removed, before, after, basis)
    local flags = {}
    for _, action in ipairs(actions) do
        if not isEquipped(action.item) then
            if action.item.bindsOnEquip then
                flags.bindsOnEquip = true
            end
            if action.item.hasSpecialEffect then
                flags.specialEffect = true
            end
        end
    end
    local gainPct
    if before > EPSILON then
        gainPct = (after - before) / before * 100
    end
    return {
        group = group,
        actions = actions,
        removed = removed,
        before = before,
        after = after,
        gain = after - before,
        gainPct = gainPct,
        basis = basis,
        flags = flags,
    }
end

-- Counts unique keys across `items` and returns false if any exceeds its
-- max (unique-equipped; same item or same limit category).
local function uniqueOk(items)
    local counts, limits = {}, {}
    for _, item in pairs(items) do
        local u = item.unique
        if u and u.key then
            counts[u.key] = (counts[u.key] or 0) + 1
            limits[u.key] = u.max or 1
            if counts[u.key] > limits[u.key] then
                return false
            end
        end
    end
    return true
end

----------------------------------------------------------------------------
-- Slot resolution
----------------------------------------------------------------------------

local function resolveSingle(slot, candidates, equipped, ctx)
    if ctx.ignoredSlots[slot] then
        return nil
    end
    local role = slot == SLOT_RANGED and "ranged" or nil
    local current = equipped[slot]
    local probes = { { current, role } }
    for _, c in ipairs(candidates) do
        probes[#probes + 1] = { c, role }
    end
    if not current then
        table.remove(probes, 1)
    end
    local score, basis = makeScorer(probes, ctx.scale, ctx.player)

    local best, bestScore
    for _, c in ipairs(candidates) do
        local s = score(c, role)
        if not bestScore or s > bestScore + EPSILON then
            best, bestScore = c, s
        end
    end
    local before = score(current, role)
    if not best or not passesThreshold(before, bestScore, ctx.settings) then
        return nil
    end
    return makeSuggestion("single", { { item = best, slot = slot } }, { current }, before, bestScore, basis)
end

-- Best pair for two identical slots (rings, trinkets) from equipped ∪
-- candidates. Kept equipped items stay in their slot; new items fill the
-- slots that free up. Ignored slots keep their current item.
local function resolvePair(slots, candidates, equipped, ctx)
    local s1, s2 = slots[1], slots[2]
    local pool = {}
    for _, slot in ipairs(slots) do
        if equipped[slot] then
            pool[#pool + 1] = equipped[slot]
        end
    end
    for _, c in ipairs(candidates) do
        pool[#pool + 1] = c
    end

    local probes = {}
    for _, item in ipairs(pool) do
        probes[#probes + 1] = { item }
    end
    local score, basis = makeScorer(probes, ctx.scale, ctx.player)

    local slotOf = {} -- equipped item -> its slot
    for _, slot in ipairs(slots) do
        if equipped[slot] then
            slotOf[equipped[slot]] = slot
        end
    end

    -- Tries one set of items; returns an assignment { [slot] = item } or nil.
    local function assign(set)
        if not uniqueOk(set) then
            return nil
        end
        local result, newItems = {}, {}
        for _, item in ipairs(set) do
            if slotOf[item] then
                result[slotOf[item]] = item
            else
                newItems[#newItems + 1] = item
            end
        end
        for _, slot in ipairs(slots) do
            if ctx.ignoredSlots[slot] and result[slot] ~= equipped[slot] then
                return nil
            end
        end
        for _, item in ipairs(newItems) do
            local target
            for _, slot in ipairs(slots) do
                if not result[slot] and not ctx.ignoredSlots[slot] then
                    target = slot
                    break
                end
            end
            if not target then
                return nil
            end
            result[target] = item
        end
        return result
    end

    local before = score(equipped[s1]) + score(equipped[s2])
    local best, bestScore = nil, before
    local function try(set)
        local a = assign(set)
        if a then
            local total = score(a[s1]) + score(a[s2])
            if total > bestScore + EPSILON then
                best, bestScore = a, total
            end
        end
    end
    for i = 1, #pool do
        try({ pool[i] })
        for j = i + 1, #pool do
            try({ pool[i], pool[j] })
        end
    end

    if not best or not passesThreshold(before, bestScore, ctx.settings) then
        return nil
    end
    local actions, removed = {}, {}
    for _, slot in ipairs(slots) do
        if best[slot] and best[slot] ~= equipped[slot] then
            actions[#actions + 1] = { item = best[slot], slot = slot }
        end
        local old = equipped[slot]
        if old and best[s1] ~= old and best[s2] ~= old then
            removed[#removed + 1] = old
        end
    end
    return makeSuggestion("pair", actions, removed, before, bestScore, basis)
end

local function canMainHand(item)
    local loc = item.equipLoc
    return loc == "INVTYPE_2HWEAPON" or loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONMAINHAND"
end

local function canOffHand(item, player)
    local loc = item.equipLoc
    if loc == "INVTYPE_SHIELD" or loc == "INVTYPE_HOLDABLE" then
        return true
    end
    return player.canDualWield and (loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONOFFHAND")
end

-- Weapon loadouts: enumerate {2H} and {MH, OH?} from equipped ∪ candidates
-- and keep the best by score(MH) + score(OH).
local function resolveWeapons(candidates, equipped, ctx)
    local player = ctx.player
    local curMH, curOH = equipped[SLOT_MAINHAND], equipped[SLOT_OFFHAND]
    local pool = {}
    if curMH then
        pool[#pool + 1] = curMH
    end
    if curOH then
        pool[#pool + 1] = curOH
    end
    for _, c in ipairs(candidates) do
        pool[#pool + 1] = c
    end

    local probes = {}
    for _, item in ipairs(pool) do
        probes[#probes + 1] = { item, canMainHand(item) and "mainhand" or "offhand" }
    end
    local score, basis = makeScorer(probes, ctx.scale, player)

    local function loadoutScore(mh, oh)
        return score(mh, "mainhand") + score(oh, "offhand")
    end

    -- An equipped item may stay where it is even if the rules above would no
    -- longer allow it there (e.g. CanDualWield changed); we only judge moves.
    local function mhAllowed(item)
        return item == curMH or canMainHand(item)
    end
    local function ohAllowed(item)
        return item == curOH or canOffHand(item, player)
    end
    local function valid(mh, oh)
        if mh and oh and mh.equipLoc == "INVTYPE_2HWEAPON" then
            return false
        end
        if ctx.ignoredSlots[SLOT_MAINHAND] and mh ~= curMH then
            return false
        end
        if ctx.ignoredSlots[SLOT_OFFHAND] and oh ~= curOH then
            return false
        end
        return uniqueOk({ mh, oh })
    end

    local before = loadoutScore(curMH, curOH)
    local bestMH, bestOH, bestScore = curMH, curOH, before
    local mhOptions = { false }
    for _, item in ipairs(pool) do
        if mhAllowed(item) then
            mhOptions[#mhOptions + 1] = item
        end
    end
    for _, mh in ipairs(mhOptions) do
        mh = mh or nil
        local ohOptions = { false }
        for _, item in ipairs(pool) do
            if item ~= mh and ohAllowed(item) then
                ohOptions[#ohOptions + 1] = item
            end
        end
        for _, oh in ipairs(ohOptions) do
            oh = oh or nil
            if valid(mh, oh) then
                local total = loadoutScore(mh, oh)
                if total > bestScore + EPSILON then
                    bestMH, bestOH, bestScore = mh, oh, total
                end
            end
        end
    end

    if bestMH == curMH and bestOH == curOH then
        return nil
    end
    if not passesThreshold(before, bestScore, ctx.settings) then
        return nil
    end

    -- Moves of already-equipped items first, then new items. This order is a
    -- suggestion; Equip.lua owns the real sequence.
    local moves, news = {}, {}
    local function add(item, slot)
        if item and item ~= equipped[slot] then
            local list = isEquipped(item) and moves or news
            list[#list + 1] = { item = item, slot = slot }
        end
    end
    add(bestMH, SLOT_MAINHAND)
    add(bestOH, SLOT_OFFHAND)
    local actions = moves
    for _, a in ipairs(news) do
        actions[#actions + 1] = a
    end

    local removed = {}
    for _, old in ipairs({ curMH, curOH }) do
        if old ~= bestMH and old ~= bestOH then
            removed[#removed + 1] = old
        end
    end
    return makeSuggestion("weapons", actions, removed, before, bestScore, basis)
end

----------------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------------

-- input = { bagItems, equipped, player, scale, settings, ignore }.
-- Returns suggestions, rejected where rejected is a list of { item =
-- descriptor, reason = string } for debug output.
function Evaluator.Evaluate(input)
    local ignore = input.ignore or {}
    local ctx = {
        player = input.player,
        scale = input.scale,
        settings = input.settings or {},
        ignoredSlots = ignore.slots or {},
    }
    local equipped = input.equipped or {}

    local singles, pairsByLoc, weapons = {}, {}, {}
    local rejected = {}
    for _, item in ipairs(input.bagItems or {}) do
        local ok, reason = Evaluator.IsCandidate(item, ctx.player, ctx.settings, ignore)
        if not ok then
            rejected[#rejected + 1] = { item = item, reason = reason }
        else
            local group, slot = groupOf(item.equipLoc)
            if group == "single" then
                singles[slot] = singles[slot] or {}
                table.insert(singles[slot], item)
            elseif group == "pair" then
                pairsByLoc[item.equipLoc] = pairsByLoc[item.equipLoc] or {}
                table.insert(pairsByLoc[item.equipLoc], item)
            else
                weapons[#weapons + 1] = item
            end
        end
    end

    local suggestions = {}
    local function add(s)
        if s then
            suggestions[#suggestions + 1] = s
        end
    end

    -- Iterate slots in a fixed order so output (and tests) are deterministic.
    local singleSlots = {}
    for slot in pairs(singles) do
        singleSlots[#singleSlots + 1] = slot
    end
    table.sort(singleSlots)
    for _, slot in ipairs(singleSlots) do
        add(resolveSingle(slot, singles[slot], equipped, ctx))
    end
    for _, loc in ipairs({ "INVTYPE_FINGER", "INVTYPE_TRINKET" }) do
        if pairsByLoc[loc] then
            add(resolvePair(PAIRS[loc], pairsByLoc[loc], equipped, ctx))
        end
    end
    if #weapons > 0 then
        add(resolveWeapons(weapons, equipped, ctx))
    end
    return suggestions, rejected
end
