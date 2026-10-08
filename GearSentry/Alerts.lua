-- Alerts.lua: the "upgrade found, equip it?" toast. Owns the alert queue,
-- session dedupe, the login quiet window, and the Equip/Ignore/Close
-- buttons. Scanner.lua hands it a scan result after every successful scan
-- (Alerts.Offer); it never scans or evaluates anything itself.
local _, ns = ...

local L = ns.L
local Alerts = {}
ns.Alerts = Alerts

-- Nothing is shown this soon after login/reload. What a scan finds in the
-- window is held back, not marked seen, and a rescan just after the window
-- offers it, unless the player turned `alertAtLogin` off: then it's marked
-- seen and never shown. The rescan is scheduled when the window opens, not
-- when a quiet scan finds something: right after a reload those scans often
-- can't complete (item data still loading), and the pop-up would then wait
-- for an unrelated later event (about 30 s, seen in game).
local QUIET_AFTER_LOGIN = 10
local quietUntil = math.huge
-- Whether this window's end-of-window rescan has been scheduled. One per
-- window; PLAYER_ENTERING_WORLD clears it when a new window starts.
local rescanAfterQuiet = false

----------------------------------------------------------------------------
-- Session state: dedupe + queue
----------------------------------------------------------------------------

-- SuggestionID -> true. Monotonic for the session: once a suggestion has been
-- queued, shown, or marked seen during the quiet window, it is never
-- queued/shown again even if a later scan finds it once more. Alerts.Reset()
-- (called by /gs scale) and /gs alerts (which bypasses this table directly)
-- are the only ways around it.
local seen = {}

-- Suggestions waiting behind the one on screen, oldest first.
local queue = {}

-- The suggestion currently rendered on the toast, or nil if nothing is
-- shown right now.
local shown

-- Whether our frame is currently visible, tracked separately from `shown`
-- so showFrame() knows whether a fresh "it just appeared" sound is due.
local toastVisible = false

local frame
-- Toast layout: offset of the body text from the top (title + icon), and
-- space reserved below it for the buttons.
local BODY_TOP, BUTTON_ROOM = 66, 40

----------------------------------------------------------------------------
-- Inspection (also used by tests: the queue/dedupe/ reconcile logic and the
-- button actions below are plain functions on Alerts, kept separate from
-- frame construction, specifically so they can be driven and inspected
-- without a real WoW client)
----------------------------------------------------------------------------

-- The suggestion currently on the toast, or nil.
function Alerts.Current()
    return shown
end

-- How many suggestions are waiting behind the current one.
function Alerts.QueueLength()
    return #queue
end

-- Whether the toast frame is currently visible.
function Alerts.IsVisible()
    return toastVisible
end

-- Forward declarations: ensureFrame() builds the toast the first time it's
-- needed; ensureShown() decides what (if anything) belongs on screen after
-- every Offer(), button click, or combat transition. Everything below that
-- calls them is defined before their bodies are assigned further down, so a
-- plain forward declaration is enough - Lua closures capture the variable,
-- not its value at definition time.
local ensureFrame
local ensureShown

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

local function isEquipMove(item)
    return item.key and item.key:sub(1, 6) == "equip:"
end

-- The suggestion's own actual bag item: the first action that isn't a move of
-- an already-equipped item. Falls back to actions[1] so a (should-never-
-- happen) all-moves suggestion still renders something rather than nil.
local function firstBagAction(s)
    for _, action in ipairs(s.actions) do
        if not isEquipMove(action.item) then
            return action
        end
    end
    return s.actions[1]
end

local function charEntry()
    local db = ns.DB()
    return db and ns.charKey and db.chars[ns.charKey]
end

----------------------------------------------------------------------------
-- Frame position (account-wide, saved in db.settings.alertPos)
----------------------------------------------------------------------------

local function saveFramePosition()
    if not frame then
        return
    end
    local point, relativePoint, x, y
    point, _, relativePoint, x, y = frame:GetPoint()
    if not point then
        return
    end
    local db = ns.DB()
    if db and db.settings then
        -- Anchored to UIParent only (GetPoint() can name a relative frame
        -- that won't exist next reload), so there's nothing to save but the
        -- point names and offsets.
        db.settings.alertPos = { point = point, relativePoint = relativePoint, x = x, y = y }
    end
end

local function restoreFramePosition()
    local db = ns.DB()
    local pos = db and db.settings and db.settings.alertPos
    frame:ClearAllPoints()
    if pos then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -200)
    end
end

-- Options panel "Reset pop-up position": forget the dragged position and
-- move a toast that's already built back to the default spot (for a toast
-- dragged off-screen).
function Alerts.ResetPosition()
    local db = ns.DB()
    if db and db.settings then
        db.settings.alertPos = nil
    end
    if frame then
        restoreFramePosition()
    end
end

----------------------------------------------------------------------------
-- Sound
----------------------------------------------------------------------------

-- One SOUNDKIT constant for "a toast just appeared". IG_PLAYER_INVITE is an
-- incoming-offer chime Blizzard's own invite popups use the same way; on the
-- `forever` branch of wow-ui-source it's defined in
-- Blizzard_SharedXML/Mainline/SoundKitConstants.lua and used by
-- LFGInvitePopup.xml. Feature-detected in case the constant or PlaySound
-- itself is ever missing.
local function playAlertSound()
    local db = ns.DB()
    if db and db.settings and db.settings.alertSound == false then
        return
    end
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE then
        PlaySound(SOUNDKIT.IG_PLAYER_INVITE)
    end
end

----------------------------------------------------------------------------
-- Equip button state (combat, Equip.lua missing)
----------------------------------------------------------------------------

-- Disabled, with a tooltip saying why, if Equip.lua isn't loaded or while
-- InCombatLockdown() is true. Re-checked at click time too (HandleEquip), not
-- just when the button is drawn.
local function updateEquipButton()
    if not frame then
        return
    end
    local reason
    if not (ns.Equip and ns.Equip.Run) then
        reason = L["EQUIP_DISABLED_NO_MODULE"]
    elseif InCombatLockdown() then
        reason = L["EQUIP_DISABLED_COMBAT"]
    end
    frame.EquipButton.disabledReason = reason
    if reason then
        frame.EquipButton:Disable()
    else
        frame.EquipButton:Enable()
    end
end

----------------------------------------------------------------------------
-- Show / hide
----------------------------------------------------------------------------

local function hideFrame()
    toastVisible = false
    if frame then
        frame:Hide()
    end
end

local function renderShown()
    if not shown or not frame then
        return
    end
    local action = firstBagAction(shown)
    local item = action and action.item
    local icon = item and item.itemID and C_Item and C_Item.GetItemIconByID
        and C_Item.GetItemIconByID(item.itemID)
    frame.Icon:SetTexture(icon)
    frame.Title:SetText(L["ALERT_TITLE"])
    frame.Count:SetText(#queue > 0 and L["ALERT_COUNT"]:format(1, #queue + 1) or "")
    frame.ItemLine:SetText((item and item.link or "?")
        .. (action and ("  " .. ns.Report.SlotName(action.slot)) or ""))
    -- Report.SuggestionLine already carries the gain, what it replaces,
    -- BoE/special-effect/by-item-level notes, and every step in order for a
    -- multi-action suggestion - reuse it rather than re-deriving the same
    -- wording here.
    frame.Body:SetText(ns.Report.SuggestionLine(shown))
    -- Multi-step suggestions wrap to several lines; grow the frame so the
    -- text never runs under the buttons (BODY_TOP above the text, room for
    -- the button row below it).
    frame:SetHeight(BODY_TOP + (frame.Body:GetStringHeight() or 0) + BUTTON_ROOM)
    updateEquipButton()
end

local function showFrame()
    ensureFrame()
    if not toastVisible then
        playAlertSound()
    end
    toastVisible = true
    frame:Show()
end

ensureShown = function()
    if shown then
        -- Already on screen (or about to be): just keep its content fresh and
        -- make sure it's shown. Showing/hiding a plain, UIParent-rooted frame
        -- in combat is fine (it isn't protected); only the Equip button
        -- itself is combat-gated.
        renderShown()
        showFrame()
        return
    end
    if #queue == 0 then
        hideFrame()
        return
    end
    if InCombatLockdown() then
        -- New suggestions queue in combat; PLAYER_REGEN_ENABLED re-runs this.
        -- Hide in case the toast still shows a suggestion that reconcile just
        -- dropped.
        hideFrame()
        return
    end
    shown = table.remove(queue, 1)
    ensureFrame()
    renderShown()
    showFrame()
end

----------------------------------------------------------------------------
-- Button actions
----------------------------------------------------------------------------

local function advance()
    shown = nil
    ensureShown()
end

-- Button actions, public so tests can drive them without going through
-- frame scripts (see "Inspection" above). The toast's own buttons just call
-- these directly.

-- Ignore adds every bag item in the current suggestion's actions (not the
-- "equip:" moves of an already-equipped item) to this character's
-- ignoredItems, then rescans.
function Alerts.Ignore()
    if not shown then
        return
    end
    local char = charEntry()
    if char then
        for _, action in ipairs(shown.actions) do
            if not isEquipMove(action.item) then
                -- Same key Evaluator.lua's candidate filter uses (guid,
                -- else link), so an ignored item is actually filtered out
                -- next scan.
                char.ignoredItems[action.item.guid or action.item.link] = true
            end
        end
    end
    advance()
    if ns.Scanner and ns.Scanner.Request then
        ns.Scanner.Request()
    end
end

-- Equip hands the current suggestion to Equip.lua. Combat is re-checked here
-- at click time, not just when the button was drawn.
function Alerts.Equip()
    if not shown or not ns.Equip or not ns.Equip.Run or InCombatLockdown() then
        return
    end
    ns.Equip.Run(shown)
    advance()
end

-- Close dismisses the current suggestion for this session only (it stays
-- in `seen`, so it won't come back unless Reset() or /gs alerts is used).
function Alerts.Close()
    advance()
end

----------------------------------------------------------------------------
-- Frame construction (lazy: nothing is created until the first toast)
----------------------------------------------------------------------------

ensureFrame = function()
    if frame then
        return
    end
    -- Plain Lua CreateFrame, no XML; BackdropTemplate for the
    -- background/border, DIALOG strata to sit above normal game UI, parented
    -- to UIParent only (never to a Blizzard protected frame) so it can't
    -- inherit taint.
    frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(260, 120)
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)

    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        saveFramePosition()
    end)
    restoreFramePosition()

    frame.CloseButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.CloseButton:SetPoint("TOPRIGHT", 0, 0)
    frame.CloseButton:SetScript("OnClick", Alerts.Close)

    frame.Title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    frame.Title:SetPoint("TOPLEFT", 10, -8)

    frame.Count = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    frame.Count:SetPoint("TOPRIGHT", frame.CloseButton, "TOPLEFT", -4, -4)

    frame.Icon = frame:CreateTexture(nil, "ARTWORK")
    frame.Icon:SetSize(32, 32)
    frame.Icon:SetPoint("TOPLEFT", 10, -28)
    frame.Icon:EnableMouse(true)
    -- Hovering the icon shows the item's own tooltip plus Blizzard's
    -- side-by-side "currently equipped" comparison: set the main tooltip via
    -- SetHyperlink, then call GameTooltip_ShowCompareItem, which reads the
    -- item already set on the tooltip and populates the two ShoppingTooltip
    -- frames itself. GameTooltip_ShowCompareItem is FrameXML, not a C_* API;
    -- on Forever it's in Blizzard_GameTooltip/Mainline/GameTooltip.lua.
    frame.Icon:SetScript("OnEnter", function(self)
        local action = shown and firstBagAction(shown)
        local link = action and action.item and action.item.link
        if not link then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(link)
        if GameTooltip_ShowCompareItem then
            GameTooltip_ShowCompareItem(GameTooltip)
        end
        GameTooltip:Show()
    end)
    frame.Icon:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    frame.ItemLine = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    frame.ItemLine:SetPoint("TOPLEFT", frame.Icon, "TOPRIGHT", 8, -2)
    frame.ItemLine:SetPoint("RIGHT", -10, 0)
    frame.ItemLine:SetJustifyH("LEFT")

    frame.Body = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    frame.Body:SetPoint("TOPLEFT", frame.Icon, "BOTTOMLEFT", 0, -6)
    frame.Body:SetPoint("RIGHT", -10, 0)
    frame.Body:SetJustifyH("LEFT")
    frame.Body:SetWordWrap(true)

    frame.EquipButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.EquipButton:SetSize(80, 22)
    frame.EquipButton:SetPoint("BOTTOMLEFT", 10, 8)
    frame.EquipButton:SetText(L["ALERT_EQUIP"])
    frame.EquipButton:SetScript("OnClick", Alerts.Equip)
    -- A disabled button gets no OnEnter/OnLeave by default, which hid the
    -- "why is this greyed out" tooltip. Documented in the forever branch's
    -- SimpleButtonAPIDocumentation.lua; see
    -- https://warcraft.wiki.gg/wiki/API_Button_SetMotionScriptsWhileDisabled
    frame.EquipButton:SetMotionScriptsWhileDisabled(true)
    frame.EquipButton:SetScript("OnEnter", function(self)
        if self.disabledReason then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.disabledReason)
            GameTooltip:Show()
        end
    end)
    frame.EquipButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    frame.IgnoreButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.IgnoreButton:SetSize(80, 22)
    frame.IgnoreButton:SetPoint("LEFT", frame.EquipButton, "RIGHT", 6, 0)
    frame.IgnoreButton:SetText(L["ALERT_IGNORE"])
    frame.IgnoreButton:SetScript("OnClick", Alerts.Ignore)

    frame:Hide()
end

----------------------------------------------------------------------------
-- Reconcile + public API
----------------------------------------------------------------------------

-- Drops anything shown/queued whose ID isn't in the new scan's suggestion
-- list (equipped, sold, ignored, or no longer an upgrade), and refreshes the
-- surviving ones' data (e.g. an updated gain number) without disturbing
-- session dedupe or display order.
local function reconcileAgainst(suggestions)
    local byID = {}
    for _, s in ipairs(suggestions) do
        byID[ns.Report.SuggestionID(s)] = s
    end

    if shown then
        shown = byID[ns.Report.SuggestionID(shown)]
    end

    local kept = {}
    for _, s in ipairs(queue) do
        local fresh = byID[ns.Report.SuggestionID(s)]
        if fresh then
            kept[#kept + 1] = fresh
        end
    end
    queue = kept
end

local function inQueue(id)
    for _, s in ipairs(queue) do
        if ns.Report.SuggestionID(s) == id then
            return true
        end
    end
    return false
end

-- Upgrades already in the bags at login are offered once the quiet window
-- ends. Missing key counts as on.
local function alertAtLogin()
    local db = ns.DB()
    return not (db and db.settings and db.settings.alertAtLogin == false)
end

-- One timer per window: fires just after it ends and asks Scanner for a
-- fresh scan, whose Offer() is no longer quiet. The flag stays set until
-- the next window, so a rescan can never schedule another. Called from
-- PLAYER_ENTERING_WORLD; Offer() calls it too in case the setting was
-- turned on during the window.
local function scheduleRescanAfterQuiet()
    if rescanAfterQuiet or not (C_Timer and C_Timer.After) then
        return
    end
    rescanAfterQuiet = true
    C_Timer.After(math.max(0, quietUntil - GetTime()) + 0.1, function()
        ns:Debug("quiet window over, rescanning")
        if ns.Scanner and ns.Scanner.Request then
            ns.Scanner.Request()
        end
    end)
end

-- Called by Scanner after every successful scan. `force` (only /gs alerts)
-- skips the login quiet window.
function Alerts.Offer(result, force)
    local suggestions = (result and result.suggestions) or {}
    reconcileAgainst(suggestions)

    local quiet = not force and GetTime() < quietUntil
    local holdBack = quiet and alertAtLogin()
    local shownID = shown and ns.Report.SuggestionID(shown)
    for _, s in ipairs(suggestions) do
        local id = ns.Report.SuggestionID(s)
        if not seen[id] and id ~= shownID and not inQueue(id) then
            if holdBack then
                -- Not marked seen: the rescan after the window offers it.
                scheduleRescanAfterQuiet()
            else
                seen[id] = true
                if not quiet then
                    queue[#queue + 1] = s
                end
                -- With alertAtLogin off, quiet-window finds are marked
                -- seen (above) but never queued, so they never appear.
            end
        end
    end
    ensureShown()
end

-- /gs scale calls this: new weights change what counts as an upgrade, so
-- forget every dedupe/queue/display state and let the next scan announce
-- everything afresh.
function Alerts.Reset()
    seen = {}
    queue = {}
    shown = nil
    hideFrame()
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function(_event, isInitialLogin, isReloadingUi)
    if isInitialLogin or isReloadingUi then
        quietUntil = GetTime() + QUIET_AFTER_LOGIN
        rescanAfterQuiet = false
        if alertAtLogin() then
            scheduleRescanAfterQuiet()
        end
    end
end)

ns:RegisterEvent("PLAYER_REGEN_DISABLED", updateEquipButton)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    updateEquipButton()
    ensureShown()
end)

----------------------------------------------------------------------------
-- Test / debug commands
----------------------------------------------------------------------------

-- /gs alerts: scan now and offer everything found, ignoring this session's
-- dedupe and the login quiet window, so a player can see the toast on demand
-- (including right after a /reload) without waiting for a real upgrade to
-- appear.
ns.slashCommands["alerts"] = function()
    local result, pending = ns.Scanner.Run()
    if not result then
        ns:Print(L["EQUIPPED_LOADING"]:format(pending))
        return
    end
    if #result.suggestions == 0 then
        ns:Print(L["ALERTS_NONE"])
        return
    end
    for _, s in ipairs(result.suggestions) do
        seen[ns.Report.SuggestionID(s)] = nil
    end
    shown = nil
    queue = {}
    Alerts.Offer(result, true)
    ns:Print(L["ALERTS_REOFFERED"]:format(#result.suggestions))
end

-- Clears this character's ignored items and slots. Shared by /gs unignore and
-- the options panel's "Reset ignored items" button.
function Alerts.ResetIgnored()
    local char = charEntry()
    if not char then
        return
    end
    char.ignoredItems = {}
    char.ignoredSlots = {}
    ns:Print(L["UNIGNORE_DONE"])
    if ns.Scanner and ns.Scanner.Request then
        ns.Scanner.Request()
    end
end

-- /gs unignore: clear this character's ignored items and slots.
ns.slashCommands["unignore"] = Alerts.ResetIgnored
