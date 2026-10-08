-- Scanner.lua: reads bags and equipped gear into descriptors, runs the
-- Evaluator, and keeps the latest result in Scanner.last. Also owns the
-- test commands /gs scan, /gs eval and /gs scale.
--
-- Alerts.lua owns everything about *announcing* a suggestion (toast, dedupe,
-- login quiet window, combat deferral of the display). This file only scans,
-- evaluates, and hands the result to ns.Alerts.Offer().
local _, ns = ...

local L = ns.L
local Scanner = {}
ns.Scanner = Scanner

-- Backpack and the four bag slots (Enum.BagIndex Backpack..Bag_4). Bank and
-- reagent bags are out of scope.
local BAG_FIRST, BAG_LAST = 0, 4
-- INVSLOT_HEAD (1) .. INVSLOT_TABARD (19);
-- https://warcraft.wiki.gg/wiki/InventorySlotId.
local EQUIP_FIRST, EQUIP_LAST = 1, 19
-- Shirt (4) and tabard (19) are cosmetic: no Evaluator group uses them. Not
-- reading them also means an equipped shirt whose data never loads can't hold
-- every scan in "equipped item pending" (seen in game with an uncached
-- Squire's Shirt).
local SKIP_EQUIP_SLOTS = { [4] = true, [19] = true }

local DEBOUNCE_SECONDS = 0.3

local scanGeneration = 0
local dirtyInCombat = false
local waitingForData = false

-- Scanner.RegisterCallback(fn): fn(result) runs after every successful
-- Scanner.Run, once Scanner.last has been set. BagArrows.lua registers here
-- to repaint shown container frames after each scan; the BetterBags provider
-- does the same. Each fn runs in its own pcall (below) so a bug in one
-- listener can't break scanning or any other listener.
local scanCallbacks = {}

function Scanner.RegisterCallback(fn)
    scanCallbacks[#scanCallbacks + 1] = fn
end

----------------------------------------------------------------------------
-- Reading
----------------------------------------------------------------------------

-- Returns [slot] = descriptor, pendingCount.
function Scanner.ReadEquipped()
    local equipped, pending = {}, 0
    for slot = EQUIP_FIRST, EQUIP_LAST do
        local item, why
        if not SKIP_EQUIP_SLOTS[slot] then
            item, why = ns.ItemData.FromLocation({ equipSlot = slot })
        end
        if item then
            equipped[slot] = item
        elseif why == "pending" then
            pending = pending + 1
        end
    end
    return equipped, pending
end

-- Only gear goes through ItemData (stats + tooltip read): everything else
-- is skipped using the synchronous GetItemInfoInstant equip location.
local function IsGearLink(link)
    local _, _, _, equipLoc = C_Item.GetItemInfoInstant(link)
    return equipLoc and ns.Evaluator.GroupOf(equipLoc) ~= nil
end

-- Returns list of descriptors, pendingCount.
function Scanner.ReadBags()
    local items, pending = {}, 0
    for bag = BAG_FIRST, BAG_LAST do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink and IsGearLink(info.hyperlink) then
                local item, why = ns.ItemData.FromLocation({ bag = bag, slot = slot })
                if item then
                    items[#items + 1] = item
                elseif why == "pending" then
                    pending = pending + 1
                end
            end
        end
    end
    return items, pending
end

local function CharEntry()
    local db = ns.DB()
    return db and ns.charKey and db.chars[ns.charKey]
end

local function IgnoreTable()
    local char = CharEntry()
    return {
        items = char and char.ignoredItems or {},
        slots = char and char.ignoredSlots or {},
    }
end

-- Everything /gs eval and the scan need besides the bag items. Returns
-- context, or nil if equipped items are still loading (scoring against a
-- half-read equipment set would invent upgrades for "empty" slots: never
-- evaluate partial data).
function Scanner.Context()
    local equipped, pending = Scanner.ReadEquipped()
    if pending > 0 then
        return nil, pending
    end
    local player = ns.Player.Build(equipped)
    local db = ns.DB()
    local settings = db and db.settings or {}
    return {
        equipped = equipped,
        player = player,
        scale = ns.Profiles.Resolve(db or {}, player.classFile, player.profile),
        settings = settings,
        ignore = IgnoreTable(),
    }
end

----------------------------------------------------------------------------
-- Upgrade index
----------------------------------------------------------------------------

-- An action whose item.key starts with "equip:" moves an already-equipped
-- item (e.g. old main hand into the off hand); it isn't a bag item and
-- never goes in the index (same rule Alerts.lua's firstBagAction/Ignore use).
local function isEquipMove(item)
    return item.key and item.key:sub(1, 6) == "equip:"
end

-- Every bag item named in a suggestion's actions, keyed by guid, link and key
-- (bag:B:S), each pointing at { suggestion, slot }. Tooltip.lua and the bag
-- arrows both need "is this bag item an upgrade, and for which slot", so it's
-- built once here, right after Evaluate, rather than twice.
local function BuildUpgradeIndex(suggestions)
    local index = { byGuid = {}, byLink = {}, byKey = {} }
    for _, s in ipairs(suggestions) do
        for _, action in ipairs(s.actions) do
            local item = action.item
            if not isEquipMove(item) then
                -- `item` is carried on the entry (not just its guid/link) so
                -- a consumer can check it's still the item currently in that
                -- slot - BagArrows.lua needs this to detect a stale index
                -- after items move within the debounce window.
                local entry = { suggestion = s, slot = action.slot, item = item }
                if item.guid then
                    index.byGuid[item.guid] = entry
                end
                if item.link then
                    index.byLink[item.link] = entry
                end
                if item.key then
                    index.byKey[item.key] = entry
                end
            end
        end
    end
    return index
end

-- Looks up guid first, then link, in the last scan's upgrade index. Returns
-- suggestion, slot or nil if this item (or there was no scan yet) isn't a
-- current upgrade.
function Scanner.UpgradeFor(guid, link)
    local index = Scanner.last and Scanner.last.upgrades
    if not index then
        return nil
    end
    local entry = (guid and index.byGuid[guid]) or (link and index.byLink[link])
    if not entry then
        return nil
    end
    return entry.suggestion, entry.slot
end

----------------------------------------------------------------------------
-- Scanning
----------------------------------------------------------------------------

-- Runs a full scan now. Returns the result table (also kept in
-- Scanner.last), or nil plus pending count while equipped data loads.
function Scanner.Run()
    local ctx, equippedPending = Scanner.Context()
    if not ctx then
        waitingForData = true
        return nil, equippedPending
    end
    local bagItems, pending = Scanner.ReadBags()
    waitingForData = pending > 0

    local suggestions, rejected = ns.Evaluator.Evaluate({
        bagItems = bagItems,
        equipped = ctx.equipped,
        player = ctx.player,
        scale = ctx.scale,
        settings = ctx.settings,
        ignore = ctx.ignore,
    })
    ctx.bagItems = bagItems
    ctx.pending = pending
    ctx.suggestions = suggestions
    ctx.rejected = rejected
    ctx.upgrades = BuildUpgradeIndex(suggestions)
    -- A fresh table every successful run, on purpose: Tooltip.lua drops its
    -- per-link on-demand cache by comparing this table's identity against the
    -- one it last saw, so it never has to be told explicitly that a rescan
    -- happened.
    Scanner.last = ctx
    for _, fn in ipairs(scanCallbacks) do
        local ok, err = pcall(fn, ctx)
        if not ok then
            ns:Debug("Scanner callback error:", err)
        end
    end
    return ctx
end

local function RunAndOffer()
    if InCombatLockdown() then
        -- Nothing here is protected, but Alerts won't display anything in
        -- combat anyway, so skip the work until combat ends.
        dirtyInCombat = true
        return
    end
    local result = Scanner.Run()
    if result then
        ns:Debug(("scan: %d bag gear, %d suggestions, %d rejected, %d loading"):format(
            #result.bagItems, #result.suggestions, #result.rejected, result.pending))
        ns.Alerts.Offer(result)
    else
        ns:Debug("scan: equipped items still loading, waiting")
    end
end

-- Debounced scan request. Every call within DEBOUNCE_SECONDS of the last one
-- collapses into a single scan (C_Timer.After can't be cancelled, so a
-- generation counter drops the stale timers).
function Scanner.Request()
    scanGeneration = scanGeneration + 1
    local generation = scanGeneration
    C_Timer.After(DEBOUNCE_SECONDS, function()
        if generation == scanGeneration then
            RunAndOffer()
        end
    end)
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function(_event, isInitialLogin, isReloadingUi)
    if isInitialLogin or isReloadingUi then
        Scanner.Request()
    end
end)

ns:RegisterEvent("BAG_UPDATE_DELAYED", Scanner.Request)
ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", Scanner.Request)
ns:RegisterEvent("PLAYER_LEVEL_UP", Scanner.Request)

-- Talents can grant dual wield or a proficiency. These are the events
-- Forever's own Camelot PaperDollFrame refreshes on, plus C_Traits' config
-- event. Which ones fire for a talent point on Forever is unverified; the
-- debounce collapses any burst into one scan.
ns:RegisterEvent("CHARACTER_POINTS_CHANGED", Scanner.Request)
ns:RegisterEvent("PLAYER_TALENT_UPDATE", Scanner.Request)
ns:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", Scanner.Request)
ns:RegisterEvent("TRAIT_CONFIG_UPDATED", Scanner.Request)

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if dirtyInCombat then
        dirtyInCombat = false
        Scanner.Request()
    end
end)

-- These four settings change what counts as an upgrade (armor-type filter,
-- BoE suggestions, minimum gain thresholds), so any write to them - whether
-- from a slash command or the options panel's proxy setting - needs a rescan.
-- ns.SetSetting (Core.lua) is the single place that calls these listeners,
-- and only when the value actually changed.
for _, key in ipairs({ "allowLowerArmor", "suggestBoE", "minGain", "minGainPct" }) do
    ns.OnSettingChanged(key, Scanner.Request)
end

-- Item data arriving only matters while a scan is waiting for it. Only a
-- successful load triggers a rescan: the server can refuse some items
-- forever, and rescanning on a failure would request the load again and loop.
local function OnItemData(_event, _itemID, success)
    if waitingForData and success then
        Scanner.Request()
    end
end
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", OnItemData)
ns:RegisterEvent("ITEM_DATA_LOAD_RESULT", OnItemData)

----------------------------------------------------------------------------
-- Test commands
----------------------------------------------------------------------------

-- Display name for a stat key: its GlobalStrings value ("Strength") if the
-- client has one, else the raw key.
local function StatName(key)
    local name = _G[key]
    if type(name) == "string" then
        return name
    end
    return key
end

local function YesNo(v)
    return v and L["YES"] or L["NO"]
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function PrintPlayer(ctx)
    local p = ctx.player
    local names = {}
    for _, entry in ipairs(ns.Profiles.List(ns.DB() or {}, p.classFile)) do
        names[#names + 1] = entry.name
    end
    ns:Print(L["PLAYER_LINE"]:format(
        tostring(p.classFile), tostring(p.level),
        ctx.scale and ctx.scale.name or L["NONE_ILVL"],
        #names > 0 and table.concat(names, ", ") or "-",
        YesNo(p.canDualWield)))
    local skills = SortedKeys(p.weaponSkills)
    print(L["PLAYER_LINE2"]:format(
        #skills > 0 and table.concat(skills, ", ") or "-",
        p.preferredArmorSubclass and L["ARMOR_" .. p.preferredArmorSubclass] or "-",
        tostring(p.specID or "-")))
end

local function PrintScan()
    local result, pending = Scanner.Run()
    if not result then
        ns:Print(L["EQUIPPED_LOADING"]:format(pending))
        return
    end
    PrintPlayer(result)
    print(L["SCAN_COUNTS"]:format(#result.bagItems, result.pending))
    if #result.suggestions == 0 then
        print(L["NO_UPGRADES"])
    end
    for _, s in ipairs(result.suggestions) do
        print(L["UPGRADE_FOUND"]:format(ns.Report.SuggestionLine(s)))
    end
    for _, r in ipairs(result.rejected) do
        print(L["REJECTED"]:format(r.item.link, r.reason))
    end
end

-- Core.lua's /gs scan calls this.
Scanner.ScanNow = PrintScan

-- Accepts a full item link (shift-click into the chat box), an item string
-- ("item:12345:...") or a bare item ID, and returns an item string. Taking
-- the item string out of the link avoids depending on the link's colour
-- prefix (|cffRRGGBB, or the |cnIQn: quality form retail uses;
-- unverified which one Forever's chat links carry).
local function ParseItemArg(text)
    local itemString = text:match("item:[%-%d:]+")
    if itemString then
        return itemString
    end
    local id = text:match("^%s*(%d+)%s*$")
    if id then
        return "item:" .. id
    end
    return nil
end

-- Score role used for display: same roles the Evaluator uses per group.
local function DisplayRole(item, slot)
    local group, groupSlot = ns.Evaluator.GroupOf(item.equipLoc)
    if group == "single" and groupSlot == 18 then
        return "ranged"
    elseif group == "weapons" then
        if slot == 17 then
            return "offhand"
        elseif slot == 16 then
            return "mainhand"
        end
        local loc = item.equipLoc
        if loc == "INVTYPE_2HWEAPON" or loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONMAINHAND" then
            return "mainhand"
        end
        return "offhand"
    end
    return nil
end

local function GroupSlots(item)
    local group, slots = ns.Evaluator.GroupOf(item.equipLoc)
    if group == "single" then
        return { slots }
    elseif group == "pair" then
        return slots
    elseif group == "weapons" then
        return { 16, 17 }
    end
    return {}
end

local function ScoreLine(item, slot, ctx)
    local text = L["ILVL"]:format(tostring(item.ilvl))
    if ctx.scale then
        local total, breakdown = ns.Evaluator.Score(item, ctx.scale, ctx.player, DisplayRole(item, slot))
        text = ns.Report.BreakdownLine(total, breakdown, StatName) .. "  (" .. text .. ")"
    end
    return text
end

-- Evaluates a single item link as if it were the only item in the bags,
-- against the current equipped set - the same logic /gs eval prints, and what
-- Tooltip.lua uses for everything that isn't a scanned bag item (vendor,
-- loot, chat links, auction house, bank). Returns:
--   suggestion          it's an upgrade
--   nil, reason         it isn't: "pending" (item or equipped data still
--                        loading - never worth caching, the next hover/call
--                        tries again), an Evaluator.IsCandidate reason
--                        ("level", "unusable", "armor type", "ignored",
--                        "BoE", "not gear", "profession tool"), or
--                        "not better" (a candidate, just not an upgrade)
-- `ctx` is optional: Tooltip.lua passes Scanner.last so a hover never
-- re-reads all 19 equipped slots (each one a tooltip-data read); /gs eval
-- passes nothing and gets a fresh context.
function Scanner.EvaluateLink(link, ctx)
    -- Cheap synchronous pre-check, so hovering potions or quest items never
    -- builds a full descriptor.
    if C_Item.GetItemInfoInstant(link) and not IsGearLink(link) then
        return nil, "not gear"
    end
    local item, why = ns.ItemData.FromLink(link)
    if not item then
        return nil, why or "pending" -- ItemData.FromLink's only failure is "pending"
    end
    ctx = ctx or Scanner.Context()
    if not ctx then
        return nil, "pending"
    end
    local ok, reason = ns.Evaluator.IsCandidate(item, ctx.player, ctx.settings, ctx.ignore)
    if not ok then
        return nil, reason
    end
    -- Treat the item as if it were in the bags, alone, so the verdict is
    -- exactly what a scan would say about it (same trick /gs eval used
    -- before this was pulled out into its own function).
    local suggestions = ns.Evaluator.Evaluate({
        bagItems = { item },
        equipped = ctx.equipped,
        player = ctx.player,
        scale = ctx.scale,
        settings = ctx.settings,
        ignore = ctx.ignore,
    })
    if #suggestions == 0 then
        return nil, "not better"
    end
    return suggestions[1]
end

local pendingEval -- item link waiting for GET_ITEM_INFO_RECEIVED

local function Eval(arg)
    local link = ParseItemArg(arg or "")
    if not link then
        ns:Print(L["EVAL_USAGE"])
        return
    end
    local item, why = ns.ItemData.FromLink(link)
    if not item then
        if why == "pending" and C_Item.GetItemInfoInstant(link) then
            pendingEval = link
            ns:Print(L["EVAL_LOADING"])
        else
            ns:Print(L["EVAL_UNKNOWN"]:format(arg))
        end
        return
    end
    -- A link-only descriptor carries the item string we built; swap in the
    -- client's full link so chat output shows the clickable item name.
    local _, fullLink = C_Item.GetItemInfo(link)
    item.link = fullLink or item.link

    local ctx, pending = Scanner.Context()
    if not ctx then
        ns:Print(L["EQUIPPED_LOADING"]:format(pending))
        return
    end

    PrintPlayer(ctx)
    ns:Print(L["EVAL_HEADER"]:format(item.link, tostring(item.equipLoc), tostring(item.ilvl),
        tostring(item.reqLevel), YesNo(item.usable)))
    if not ns.Evaluator.GroupOf(item.equipLoc) then
        print(L["EVAL_NOT_GEAR"])
        return
    end
    print(L["EVAL_SCORE"]:format(ScoreLine(item, nil, ctx)))
    for _, slot in ipairs(GroupSlots(item)) do
        local current = ctx.equipped[slot]
        if current then
            print(L["EVAL_EQUIPPED"]:format(ns.Report.SlotName(slot), current.link, ScoreLine(current, slot, ctx)))
        else
            print(L["EVAL_EMPTY"]:format(ns.Report.SlotName(slot)))
        end
    end

    -- Scanner.EvaluateLink does the candidate check and the alone-in-the-
    -- bags Evaluate call; shared with Tooltip.lua.
    local suggestion, reason = Scanner.EvaluateLink(item.link)
    if not suggestion then
        if reason == "not better" then
            print(L["EVAL_NOT_UPGRADE"])
        else
            print(L["EVAL_REJECTED"]:format(reason))
        end
        return
    end
    print(L["EVAL_VERDICT"]:format(ns.Report.SuggestionLine(suggestion)))
end

ns.slashCommands["eval"] = Eval

ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_event, itemID, success)
    if not pendingEval then
        return
    end
    local wanted = C_Item.GetItemInfoInstant(pendingEval)
    if itemID == wanted then
        local link = pendingEval
        pendingEval = nil
        if success then
            Eval(link)
        else
            ns:Print(L["EVAL_UNKNOWN"]:format(link))
        end
    end
end)

----------------------------------------------------------------------------
-- Active weight profile. Shared by /gs profile and the Stat Weights panel
-- (WeightsEditor.lua). Scans read the saved profile directly: the panel keeps
-- unsaved edits in its own working copy, so saved profiles only ever hold
-- values the user confirmed.
----------------------------------------------------------------------------

local profileListeners = {}

-- fn() runs after the active profile, its saved values, or the profile
-- list changes, e.g. so an open Stat Weights panel can redraw after
-- /gs profile.
function Scanner.OnProfileChanged(fn)
    profileListeners[#profileListeners + 1] = fn
end

local function NotifyProfileListeners()
    for _, fn in ipairs(profileListeners) do
        fn()
    end
end

-- New weights may change what counts as an upgrade: announce afresh and
-- rescan once.
local function Rescore()
    ns.Alerts.Reset()
    Scanner.Request()
    NotifyProfileListeners()
end

-- The active profile id for this character (nil = class default).
function Scanner.ActiveProfileId()
    local char = CharEntry()
    local _, classFile = UnitClass("player")
    local db = ns.DB() or {}
    local id = char and char.profile
    if id and ns.Profiles.Get(db, classFile, id) then
        return id
    end
    return ns.Profiles.FallbackId(classFile)
end

-- Makes `id` this character's profile (nil = class default) and rescans.
function Scanner.SetActiveProfile(id)
    local char = CharEntry()
    if not char then
        return
    end
    local _, classFile = UnitClass("player")
    char.classFile = classFile
    char.profile = id
    Rescore()
end

-- After Profiles.Save: rescans only if the saved profile is the active one.
function Scanner.ProfileSaved(id)
    if id == Scanner.ActiveProfileId() then
        Rescore()
    else
        NotifyProfileListeners()
    end
end

-- After Profiles.Rename: same weights, so no rescan.
function Scanner.ProfileRenamed()
    NotifyProfileListeners()
end

-- After Profiles.Delete. `wasActive` must be read before deleting, since
-- Profiles.Delete clears the character's reference; the class default
-- then takes over at once.
function Scanner.ProfileDeleted(wasActive)
    if wasActive then
        Rescore()
    else
        NotifyProfileListeners()
    end
end

-- /gs profile            list this class's profiles, active one marked
-- /gs profile <name>     use that profile on this character
-- /gs profile default    back to the class default
-- (/gs scale is an alias; its old short names like "tank" still match.)
local function ProfileCommand(arg)
    local _, classFile = UnitClass("player")
    local db = ns.DB() or {}
    arg = arg or ""
    local list = ns.Profiles.List(db, classFile)
    local names = {}
    for _, entry in ipairs(list) do
        names[#names + 1] = entry.name
    end
    if arg:match("^%s*$") then
        local active = ns.Profiles.Resolve(db, classFile, Scanner.ActiveProfileId())
        ns:Print(L["SCALE_CURRENT"]:format(active and active.name or L["NONE_ILVL"],
            #names > 0 and table.concat(names, ", ") or "-"))
        return
    end
    if not CharEntry() then
        return
    end
    local id
    if arg:lower():match("^%s*default%s*$") then
        id = nil
    else
        id = ns.Profiles.Find(db, classFile, arg)
        if not id then
            ns:Print(L["SCALE_UNKNOWN"]:format(arg, table.concat(names, ", ")))
            return
        end
    end
    Scanner.SetActiveProfile(id)
    local active = ns.Profiles.Resolve(db, classFile, Scanner.ActiveProfileId())
    ns:Print(L["SCALE_SET"]:format(active and active.name or L["NONE_ILVL"]))
end

ns.slashCommands["profile"] = ProfileCommand
ns.slashCommands["scale"] = ProfileCommand
