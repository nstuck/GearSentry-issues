-- BagArrows.lua: draws GearSentry's own upgrade arrow on Blizzard's default
-- bag item buttons. BetterBags' arrow (BetterBags.lua) shares the same
-- Scanner upgrade index.
--
-- Forever has no Camelot override for the item-button code, so this follows
-- the Mainline ContainerFrame.lua on the `forever` branch of wow-ui-source
-- (Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua,
-- https://github.com/Gethe/wow-ui-source).
local _, ns = ...

local BagArrows = {}
ns.BagArrows = BagArrows

-- Atlas Blizzard's own (unused) UpgradeIcon region on the item-button
-- template uses (ItemButtonTemplate XML). We draw our own texture with the
-- same atlas; we never touch that region.
local ATLAS = "bags-greenarrow"

-- Set once at load: whether this atlas actually exists on this client.
-- Feature-detect, don't version-gate: if a future client renames or removes
-- it, arrows are silently skipped rather than drawing a blank texture.
local atlasAvailable = C_Texture ~= nil and type(C_Texture.GetAtlasInfo) == "function"
    and C_Texture.GetAtlasInfo(ATLAS) ~= nil

-- Bag item button -> the texture region we created for it. The only place
-- this file keeps any per-button state; nothing is ever written onto a
-- Blizzard button or frame table itself, which would taint it.
local overlays = {}

local function settings()
    local db = ns.DB()
    return db and db.settings
end

----------------------------------------------------------------------------
-- Should this bag slot show the arrow right now?
----------------------------------------------------------------------------

-- `bag`/`slot` are a container item button's own GetBagID()/GetID(). Uses the
-- upgrade index Scanner.Run builds (Scanner.last.upgrades.byKey, keyed
-- "bag:B:S" the same way Tooltip.lua's index lookups are). Bags 0-4 only,
-- because that's the only range Scanner ever builds a "bag:B:S" key for -
-- bank buttons never match.
function BagArrows.ShouldShow(bag, slot)
    local s = settings()
    if not (s and s.bagArrows) then
        return false
    end
    local last = ns.Scanner and ns.Scanner.last
    local index = last and last.upgrades
    if not index then
        return false
    end
    local entry = index.byKey["bag:" .. bag .. ":" .. slot]
    if not (entry and entry.item and entry.item.link) then
        return false
    end
    if not (C_Container and C_Container.GetContainerItemInfo) then
        return false
    end
    -- The key can be stale for the debounce window after items move (scans
    -- are debounced): only draw if the slot's current item is still the one
    -- the index was built from.
    local info = C_Container.GetContainerItemInfo(bag, slot)
    return info ~= nil and info.hyperlink == entry.item.link
end

----------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------

-- Returns this button's overlay texture, creating it on first need OVERLAY
-- layer, sublevel 2, TOPLEFT - the same stacking/anchor Blizzard's own
-- (unused) UpgradeIcon region uses, but our own texture object, kept in
-- `overlays`, never Blizzard's region.
local function textureFor(button)
    local tex = overlays[button]
    if not tex then
        tex = button:CreateTexture(nil, "OVERLAY", nil, 2)
        -- useAtlasSize = true, as Blizzard's own UpgradeIcon XML does
        -- (useAtlasSize="true"). Without a size, a texture with one anchor
        -- rendered as a huge stretched blob below the bag (seen in game). The
        -- explicit SetSize is a second guard in case the flag is ignored.
        tex:SetAtlas(ATLAS, true)
        local info = C_Texture.GetAtlasInfo(ATLAS)
        if info and info.width and info.width > 0 then
            tex:SetSize(info.width, info.height)
        end
        tex:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
        overlays[button] = tex
    end
    return tex
end

-- Repaints every button of one container frame (combined bags, or one of
-- the per-bag frames). Safe to call on a hidden frame (nobody sees the
-- result) or on something that isn't a real container frame at all -
-- feature-detected below, degrades to a no-op either way.
function BagArrows.RepaintFrame(frame)
    if not atlasAvailable then
        return
    end
    if not (frame and type(frame.EnumerateValidItems) == "function") then
        return
    end
    for _, button in frame:EnumerateValidItems() do
        if button and type(button.GetBagID) == "function" and type(button.GetID) == "function" then
            local bag, slot = button:GetBagID(), button:GetID()
            textureFor(button):SetShown(BagArrows.ShouldShow(bag, slot))
        end
    end
end

----------------------------------------------------------------------------
-- Hiding everything (setting turned off)
----------------------------------------------------------------------------

-- Hides (never destroys) every texture this file has ever created, no matter
-- whether its button's slot is currently an upgrade. Used when
-- settings.bagArrows is turned off.
function BagArrows.HideAll()
    for _, tex in pairs(overlays) do
        tex:Hide()
    end
end

----------------------------------------------------------------------------
-- The full set of container frame instances
----------------------------------------------------------------------------

-- ContainerFrameContainer.ContainerFrames[1..NUM_CONTAINER_FRAMES] plus
-- ContainerFrameCombinedBags. Built fresh each call rather than cached: this
-- only runs after a scan or a setting toggle, and which frames exist can
-- change (more bag slots). Feature-detected: an absent global just means
-- fewer/no frames, not an error.
local function allContainerFrames()
    local frames = {}
    if ContainerFrameContainer and ContainerFrameContainer.ContainerFrames then
        for i = 1, NUM_CONTAINER_FRAMES or 0 do
            local frame = ContainerFrameContainer.ContainerFrames[i]
            if frame then
                frames[#frames + 1] = frame
            end
        end
    end
    if ContainerFrameCombinedBags then
        frames[#frames + 1] = ContainerFrameCombinedBags
    end
    return frames
end

-- Repaints only *shown* frames. A hidden frame is left alone; if/when it's
-- opened, Blizzard's own UpdateItems runs for real and our hook (below)
-- repaints it then.
function BagArrows.RepaintShownFrames()
    for _, frame in ipairs(allContainerFrames()) do
        if frame.IsShown and frame:IsShown() then
            BagArrows.RepaintFrame(frame)
        end
    end
end

----------------------------------------------------------------------------
-- Hook installation (PLAYER_LOGIN) + scan callback
----------------------------------------------------------------------------

-- hooksecurefunc(frame, "UpdateItems", fn) on every container frame at
-- PLAYER_LOGIN. The frames are created by XML before any addon loads
-- (Blizzard_UIPanels_Game.toc has no LoadOnDemand), so they already exist by
-- login. Hooking the mixin table would miss them (every frame already has its
-- own copy of the method), so each frame instance is hooked individually.
local function installHooks()
    if not (hooksecurefunc and ContainerFrameContainer and ContainerFrameContainer.ContainerFrames) then
        ns:Debug("BagArrows: ContainerFrameContainer not available; bag arrows disabled")
        return
    end
    for _, frame in ipairs(allContainerFrames()) do
        if type(frame.UpdateItems) == "function" then
            hooksecurefunc(frame, "UpdateItems", BagArrows.RepaintFrame)
        end
    end
end

ns:RegisterEvent("PLAYER_LOGIN", installHooks)

-- After every successful scan, repaint every shown container frame ourselves
-- (not via Blizzard's UpdateItems). The BetterBags provider registers its own
-- callback the same way.
if ns.Scanner and ns.Scanner.RegisterCallback then
    ns.Scanner.RegisterCallback(BagArrows.RepaintShownFrames)
end

-- React to bagArrows, however it was changed (/gs arrows or the options
-- panel's checkbox; both go through ns.SetSetting), by repainting right away
-- or hiding every arrow we drew.
if ns.OnSettingChanged then
    ns.OnSettingChanged("bagArrows", function(value)
        if value then
            BagArrows.RepaintShownFrames()
        else
            BagArrows.HideAll()
        end
    end)
end
