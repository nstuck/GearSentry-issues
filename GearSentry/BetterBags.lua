-- BetterBags.lua: registers GearSentry as a BetterBags upgrade-icon provider,
-- so BetterBags' own bag item buttons can show our arrow the same way
-- BagArrows.lua draws it on Blizzard's default bags. The BetterBags side
-- (handle, provider contract, selection rules, refresh message) follows
-- BetterBags' own source.
--
-- We never write into BetterBags' own tables or settings: only its public
-- Items:RegisterUpgradeProvider and Events:SendMessage are called. The player
-- picks the active provider in BetterBags' own settings.
local _, ns = ...

local BetterBags = {}
ns.BetterBags = BetterBags

-- The two BetterBags AceModules we need, once found. Both nil until
-- TryAcquire() succeeds (BetterBags not installed, or not loaded yet).
local itemsModule, eventsModule = nil, nil

-- Set true the first time RegisterUpgradeProvider succeeds, so a second
-- ADDON_LOADED("BetterBags") (or PLAYER_LOGIN after it) never registers
-- twice.
local registered = false

-- The signature of the upgrade set as of the last bags/FullRefreshAll we
-- actually sent. nil means "never sent", so the first scan after acquiring
-- BetterBags is free to send once (still only if our provider is the active
-- one).
local lastSentSignature = nil

local function settings()
    local db = ns.DB()
    return db and db.settings
end

----------------------------------------------------------------------------
-- 1. Getting a handle
----------------------------------------------------------------------------

-- Mirrors BetterBags_Forever/main.lua:5's own file-scope lookup
-- (`LibStub('AceAddon-3.0'):GetAddon("BetterBags")`), except guarded
-- end-to-end rather than called at file scope: `LibStub` may not even be a
-- global yet if BetterBags (or no other Ace3 addon) has loaded; `GetAddon`'s
-- second ("silent") argument returns nil instead of erroring when BetterBags
-- itself isn't installed or hasn't loaded yet; `GetModule`'s own silent
-- argument does the same for a renamed/missing module. Every step is also
-- pcall-wrapped: this is a young, undocumented upstream API, and a
-- misbehaving outside object must never be able to break our own load.
local function TryAcquire()
    if itemsModule and eventsModule then
        return true
    end
    if type(_G.LibStub) ~= "table" then
        return false
    end
    local ok, AceAddon = pcall(_G.LibStub, "AceAddon-3.0", true)
    if not ok or type(AceAddon) ~= "table" or type(AceAddon.GetAddon) ~= "function" then
        return false
    end
    local okAddon, BB = pcall(AceAddon.GetAddon, AceAddon, "BetterBags", true)
    if not okAddon or type(BB) ~= "table" or type(BB.GetModule) ~= "function" then
        return false
    end
    local okItems, items = pcall(BB.GetModule, BB, "Items", true)
    local okEvents, events = pcall(BB.GetModule, BB, "Events", true)
    if not (okItems and type(items) == "table" and okEvents and type(events) == "table") then
        return false
    end
    itemsModule, eventsModule = items, events
    return true
end

----------------------------------------------------------------------------
-- 2. The provider contract
----------------------------------------------------------------------------

-- The function BetterBags calls synchronously, once per bag item, during its
-- own data sweep (`Phase6_EnrichData`). It must never error and must never
-- block: this does one synchronous table lookup against the same upgrade
-- index BagArrows.lua reads (`Scanner.last.upgrades.byKey`), plus the same
-- staleness check BagArrows.ShouldShow uses (does the *current* link still
-- match the one the index was built from) - here, `data.itemInfo .itemLink`
-- is BetterBags' own already-current read of that same slot, so the check is
-- just "does it equal the indexed item's link".
function BetterBags.IsUpgrade(data)
    local ok, result = pcall(function()
        local s = settings()
        if not (s and s.bagArrows) then
            return false
        end
        if type(data) ~= "table" then
            return false
        end
        local last = ns.Scanner and ns.Scanner.last
        local index = last and last.upgrades
        if not (index and index.byKey) then
            return false
        end
        local bagid, slotid = data.bagid, data.slotid
        if bagid == nil or slotid == nil then
            return false
        end
        local entry = index.byKey["bag:" .. tostring(bagid) .. ":" .. tostring(slotid)]
        if not (entry and entry.item and entry.item.link) then
            return false
        end
        local itemInfo = data.itemInfo
        local link = itemInfo and itemInfo.itemLink
        return link ~= nil and link == entry.item.link
    end)
    if not ok then
        ns:Debug("BetterBags: provider error:", result)
        return false
    end
    return result and true or false
end

-- Registers our provider once BetterBags' Items module is in hand.
-- Feature-detected (RegisterUpgradeProvider must be a function before we call
-- it) and guarded by `registered` so a second
-- ADDON_LOADED("BetterBags")/PLAYER_LOGIN never re-registers.
local function RegisterProvider()
    if registered then
        return
    end
    if type(itemsModule.RegisterUpgradeProvider) ~= "function" then
        ns:Debug("BetterBags: Items module has no RegisterUpgradeProvider; skipping")
        return
    end
    itemsModule:RegisterUpgradeProvider(ns.ADDON_TITLE, BetterBags.IsUpgrade)
    registered = true
    ns:Debug("BetterBags: registered as upgrade provider", ns.ADDON_TITLE)
end

----------------------------------------------------------------------------
-- 3. Refresh
----------------------------------------------------------------------------

-- A deterministic signature of the whole upgrade set: sorted "key=link"
-- pairs, joined. Comparable with == across scans, so the scan callback can
-- tell "nothing changed" (BetterBags already redraws itself on real bag
-- changes; no extra FullRefreshAll needed) from "the set actually
-- changed" (design doc "Refresh": "send... only when the signature
-- changed since the last send").
function BetterBags.Signature(index)
    if not (index and index.byKey) then
        return ""
    end
    local keys = {}
    for key, entry in pairs(index.byKey) do
        if entry and entry.item and entry.item.link then
            keys[#keys + 1] = key .. "=" .. entry.item.link
        end
    end
    table.sort(keys)
    return table.concat(keys, "|")
end

-- `events:SendMessage("bags/FullRefreshAll")` - the "just the message
-- name" call shape (skill flavors/forever/ui-and-settings.md "#2...": SendMessage accepts either
-- a Context object first or just the message name, building its own
-- context when the first argument isn't one; confirmed directly against
-- the installed `core/events.lua`'s `if type(ctx) ~= 'table' or not
-- ctx.Event then event = ctx; ctx = context:New(...) end`). We never build
-- or need a BetterBags Context object ourselves.
local function SendFullRefresh()
    if type(eventsModule.SendMessage) ~= "function" then
        return false
    end
    local ok = pcall(eventsModule.SendMessage, eventsModule, "bags/FullRefreshAll")
    return ok
end

-- Scanner.RegisterCallback hook: after every successful scan, send
-- bags/FullRefreshAll only if the upgrade set actually changed since our last
-- send *and* our provider is the one BetterBags is currently drawing arrows
-- from (`items:GetActiveUpgradeProvider() == ns.ADDON_TITLE`). Resending for
-- an unchanged set, or while some other provider (Pawn, "None", ...) is
-- active, would just be a pointless extra full redraw: BetterBags already
-- redraws on bag changes by itself.
local function OnScan(result)
    if not (itemsModule and eventsModule) then
        return
    end
    local signature = BetterBags.Signature(result and result.upgrades)
    if signature == lastSentSignature then
        return
    end
    if type(itemsModule.GetActiveUpgradeProvider) ~= "function" then
        return
    end
    local okActive, active = pcall(itemsModule.GetActiveUpgradeProvider, itemsModule)
    if not (okActive and active == ns.ADDON_TITLE) then
        return
    end
    if SendFullRefresh() then
        lastSentSignature = signature
    end
end

-- `/gs arrows` (Core.lua) forces a refresh in both directions, since the
-- provider function itself re-checks settings.bagArrows on BetterBags' next
-- call - the only thing toggling the setting needs is BetterBags re-running
-- its sweep *right now* instead of waiting for the next real bag change.
-- Unlike OnScan, this is a direct user action, so it always sends (if we have
-- a handle at all) regardless of whether the signature changed or which
-- provider is currently active.
function BetterBags.ForceRefresh()
    if not (itemsModule and eventsModule) then
        return false
    end
    local sent = SendFullRefresh()
    if sent then
        local last = ns.Scanner and ns.Scanner.last
        lastSentSignature = BetterBags.Signature(last and last.upgrades)
    end
    return sent
end

----------------------------------------------------------------------------
-- 4. The one-time hint
----------------------------------------------------------------------------

-- Tells the user once, in chat, that they need to pick ns.ADDON_TITLE in
-- BetterBags' own "Upgrade Icon Provider" dropdown (BetterBags Settings ->
-- General) if they want our arrows instead of whatever's currently active.
-- Never writes BetterBags' own settings/database (GetActiveUpgradeProvider is
-- a read-only query). Gated by settings.betterBagsHintShown so it only ever
-- prints once per account.
local function MaybeHint()
    local s = settings()
    if not (s and not s.betterBagsHintShown) then
        return
    end
    if not (itemsModule and type(itemsModule.GetActiveUpgradeProvider) == "function") then
        return
    end
    local ok, active = pcall(itemsModule.GetActiveUpgradeProvider, itemsModule)
    if not ok then
        return
    end
    if active == ns.ADDON_TITLE then
        return
    end
    s.betterBagsHintShown = true
    ns:Print(ns.L["BETTERBAGS_HINT"]:format(ns.ADDON_TITLE))
end

----------------------------------------------------------------------------
-- 5. Wiring: PLAYER_LOGIN, and ADDON_LOADED retry
----------------------------------------------------------------------------

-- Tries to acquire the handle and register, if not already done. Safe to
-- call repeatedly: TryAcquire short-circuits once itemsModule/eventsModule
-- are set, and RegisterProvider short-circuits once `registered` is true.
local function TryInit()
    if not (itemsModule and eventsModule) then
        TryAcquire()
    end
    if not (itemsModule and eventsModule) then
        return
    end
    RegisterProvider()
end

-- Retried on every call on purpose, even after we're already registered:
-- if BetterBags' own ADDON_LOADED happens to fire before ours (plain
-- alphabetical load order can go either way), settings() isn't ready yet
-- at that point and the hint would otherwise be silently lost forever.
-- PLAYER_LOGIN always runs after every ADDON_LOADED, so retrying there is
-- enough to catch that ordering without a dedicated event for it.
local function OnLoadAttempt()
    TryInit()
    MaybeHint()
end

ns:RegisterEvent("PLAYER_LOGIN", OnLoadAttempt)
ns:RegisterEvent("ADDON_LOADED", function(_event, loadedAddonName)
    if loadedAddonName == "BetterBags" then
        OnLoadAttempt()
    end
end)

if ns.Scanner and ns.Scanner.RegisterCallback then
    ns.Scanner.RegisterCallback(OnScan)
end

-- React to bagArrows changing (either /gs arrows or the options panel, both
-- through ns.SetSetting): a toggle in either direction just needs BetterBags
-- to re-run its sweep right now, since the provider function itself re-checks
-- settings.bagArrows on its own next call either way.
if ns.OnSettingChanged then
    ns.OnSettingChanged("bagArrows", BetterBags.ForceRefresh)
end

-- Whether we're currently registered as a BetterBags upgrade provider - i.e.
-- BetterBags was found and loaded. Options.lua uses this at PLAYER_LOGIN to
-- decide whether to build the "BetterBags" section at all (only if BetterBags
-- is loaded when the panel is built). Options.lua's own PLAYER_LOGIN handler
-- runs after this file's (TOC order: BetterBags.lua loads before Options.lua,
-- and ns:RegisterEvent dispatches handlers in registration order), so this is
-- already settled by the time the panel is built.
function BetterBags.IsLoaded()
    return registered
end
