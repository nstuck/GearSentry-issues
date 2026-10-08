-- Tooltip.lua: the "Upgrade" line on item tooltips. Reuses the last scan's
-- verdict for bag items (Scanner.last.upgrades, built by Scanner.Run) and
-- evaluates everything else (vendor, loot, chat links, auction house, bank)
-- on demand through Scanner.EvaluateLink, the same way /gs eval does. The
-- hook is TooltipDataProcessor.AddTooltipPostCall.
local _, ns = ...

local L = ns.L
local Tooltip = {}
ns.Tooltip = Tooltip

-- Tooltip:AddLine colors (0-1 floats, not the |cff hex strings used in chat
-- text): green for a real upgrade line, grey for the /gs debug "no upgrade
-- (reason)" line.
local GREEN = { 0.1, 1.0, 0.1 }
local GREY = { 0.6, 0.6, 0.6 }

----------------------------------------------------------------------------
-- Per-scan state: equipped-link set + the on-demand cache
----------------------------------------------------------------------------

-- Both rebuilt whenever Scanner.last changes identity (a fresh table every
-- successful Scanner.Run - see that file's comment). Comparing the table
-- itself, rather than a version counter, means this file needs no signal
-- from Scanner beyond reading Scanner.last.
local cacheScan -- the Scanner.last table the state below was built against
local equippedLinks = {} -- link -> true
-- link -> { suggestion = suggestion } | { reason = reason }. Never holds a
-- "pending" result: item data still loading means no line and no caching.
local onDemandCache = {}

local function refreshForScan(last)
    if cacheScan == last then
        return
    end
    cacheScan = last
    onDemandCache = {}
    equippedLinks = {}
    for _, item in pairs(last.equipped or {}) do
        if item.link then
            equippedLinks[item.link] = true
        end
    end
end

----------------------------------------------------------------------------
-- Text
----------------------------------------------------------------------------

-- "GearSentry: upgrade for Ring 2 +6.5 (+15.9%)", with "(by item
-- level)" appended when the suggestion was scored by ilvl fallback (no
-- active weight scale).
local function upgradeLineText(suggestion, slot)
    local text = L["TOOLTIP_UPGRADE"]:format(ns.ADDON_TITLE, ns.Report.SlotName(slot), ns.Report.Gain(suggestion))
    if suggestion.basis == "ilvl" then
        text = text .. " (" .. L["BY_ITEM_LEVEL"] .. ")"
    end
    return text, GREEN[1], GREEN[2], GREEN[3]
end

-- Only shown with /gs debug on; nil otherwise, same as "no line".
local function debugLine(reason)
    local db = ns.DB()
    if not (db and db.settings and db.settings.debug) then
        return nil
    end
    return L["TOOLTIP_NO_UPGRADE"]:format(ns.ADDON_TITLE, reason), GREY[1], GREY[2], GREY[3]
end

----------------------------------------------------------------------------
-- Bag-item reason lookup (for the debug line only - the index above
-- already covers the "is it an upgrade" case)
----------------------------------------------------------------------------

local function matches(item, guid, link)
    return (guid and item.guid == guid) or item.link == link
end

-- Finds why a *scanned bag item* (not an upgrade, per Scanner.UpgradeFor)
-- has no line: the reason Evaluator.IsCandidate rejected it, "not better"
-- if it passed the candidate filter but didn't win its slot, or nil if
-- this link/guid wasn't a scanned bag item at all (so the caller should
-- fall through to on-demand evaluation).
local function bagReason(last, guid, link)
    for _, r in ipairs(last.rejected or {}) do
        if matches(r.item, guid, link) then
            return r.reason
        end
    end
    for _, item in ipairs(last.bagItems or {}) do
        if matches(item, guid, link) then
            return "not better"
        end
    end
    return nil
end

----------------------------------------------------------------------------
-- On-demand evaluation (vendor, loot, chat links, auction house, bank)
----------------------------------------------------------------------------

-- The action in `suggestion` for this exact link/guid - needed because
-- Scanner.EvaluateLink's suggestion carries its own action list, unlike
-- Scanner.UpgradeFor which already hands back the slot directly.
local function slotFor(suggestion, guid, link)
    for _, action in ipairs(suggestion.actions) do
        if matches(action.item, guid, link) then
            return action.slot
        end
    end
    return suggestion.actions[1] and suggestion.actions[1].slot
end

local function onDemandLine(link, guid)
    local cached = onDemandCache[link]
    if cached then
        if cached.suggestion then
            return upgradeLineText(cached.suggestion, cached.slot)
        end
        return debugLine(cached.reason)
    end

    -- Against the last scan's equipped set and player context (cacheScan),
    -- not a fresh read: the cache is dropped with that scan anyway.
    local suggestion, reason = ns.Scanner.EvaluateLink(link, cacheScan)
    if suggestion then
        local slot = slotFor(suggestion, guid, link)
        onDemandCache[link] = { suggestion = suggestion, slot = slot }
        return upgradeLineText(suggestion, slot)
    end
    if reason == "pending" then
        -- Never cached: the next hover (once item/equipped data has
        -- loaded) should try again, not repeat a stale "pending" verdict.
        return nil
    end
    onDemandCache[link] = { reason = reason }
    return debugLine(reason)
end

----------------------------------------------------------------------------
-- Public entry point
----------------------------------------------------------------------------

-- The whole tooltip-line policy: returns text, r, g, b for AddLine, or nil
-- for "no line". Pure enough to be called directly from tests without a real
-- tooltip frame - everything it reads (settings, ns.Scanner.last,
-- ns.Scanner.UpgradeFor/EvaluateLink) is a plain table or function call.
function Tooltip.LineFor(link, guid)
    if not link then
        return nil
    end
    local db = ns.DB()
    local settings = db and db.settings
    if not (settings and settings.tooltipLine) then
        return nil
    end

    local last = ns.Scanner and ns.Scanner.last
    if not last then
        return debugLine("no scan")
    end
    refreshForScan(last)

    -- Bag items get the same verdict as the toast: guid first, then link,
    -- exactly like Scanner.UpgradeFor.
    local suggestion, slot = ns.Scanner.UpgradeFor(guid, link)
    if suggestion then
        return upgradeLineText(suggestion, slot)
    end

    local reason = bagReason(last, guid, link)
    if reason then
        return debugLine(reason)
    end

    if equippedLinks[link] then
        return debugLine("equipped")
    end

    return onDemandLine(link, guid)
end

----------------------------------------------------------------------------
-- Hook
----------------------------------------------------------------------------

-- AddTooltipPostCall's addon callbacks run through securecallfunction
-- (insecure path), receiving (tooltip, tooltipData) - confirmed on the
-- `forever` branch, Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua
-- (https://github.com/Gethe/wow-ui-source). Wrapped in pcall so a bug in our
-- code never breaks Blizzard's tooltip.
local function OnTooltipItem(tooltip, data)
    local ok, err = pcall(function()
        if not (tooltip and tooltip.GetItem) then
            return
        end
        local _, link = tooltip:GetItem()
        if not link then
            return
        end
        -- On Forever, item tooltipData carries a `guid` for owned items and
        -- none for vendor/chat-link items (verified in game). Fall back to
        -- the link, which every item tooltip has.
        local guid
        if type(data) == "table" and type(data.guid) == "string" and data.guid ~= "" then
            guid = data.guid
        end
        local text, r, g, b = Tooltip.LineFor(link, guid)
        if text then
            tooltip:AddLine(text, r, g, b)
        end
    end)
    if not ok then
        ns:Debug("Tooltip hook error:", err)
    end
end

-- Exposed (beyond just LineFor) so tests can drive the actual post-call
-- handler - including its pcall safety net - without a real tooltip frame or
-- a live TooltipDataProcessor.
Tooltip.HandlePostCall = OnTooltipItem

-- Feature-detect, don't version-gate: if TooltipDataProcessor or the Item
-- tooltip-data-type enum is missing, skip the hook entirely rather than
-- erroring at load.
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
else
    ns:Debug("TooltipDataProcessor.AddTooltipPostCall not available; upgrade tooltip line disabled")
end
