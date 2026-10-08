-- Equip.lua: carries out a suggestion's actions in order when the player
-- clicks the toast's Equip button (ns.Equip.Run(suggestion)). Never called
-- automatically - only from Alerts.lua's button handler. Never auto-equip.
--
-- APIs used: C_Item.EquipItemByName with an explicit dstSlot, the paper
-- doll's PickupInventoryItem move pattern, the bind-confirm events, and
-- PLAYER_EQUIPMENT_CHANGED as the completion signal.
local _, ns = ...

local L = ns.L
local Equip = {}
ns.Equip = Equip

-- Same bag/equip-slot ranges Scanner.lua scans: backpack + 4 bags,
-- INVSLOT_HEAD..INVSLOT_TABARD.
local BAG_FIRST, BAG_LAST = 0, 4
local EQUIP_FIRST, EQUIP_LAST = 1, 19

local STEP_TIMEOUT = 3
-- Safety net only (see the bind-popup section below): CancelPendingEquip
-- fires on both explicit cancel and the popup simply being hidden (the stock
-- EQUIP_BIND popup's OnCancel and OnHide both call it), so this cap should in
-- practice never fire. It exists only in case some future client change
-- removes that guarantee.
local BIND_CAP = 60

----------------------------------------------------------------------------
-- Run state
----------------------------------------------------------------------------

-- True from Run() until the suggestion finishes (success, failure, or
-- cancel). One run at a time: a click while a run is in progress prints
-- "busy" and does nothing.
local busy = false

-- Bumped once per Run() call. Every pending callback (timers, event
-- handlers) captured `gen` at the time it was scheduled; if `gen ~=
-- runGen` by the time it fires, that callback belongs to an abandoned run
-- and is a no-op. C_Timer.After can't be cancelled (Scanner.lua uses the
-- same generation-counter trick), so this is how stale timers are dropped.
local runGen = 0

-- Bumped once per step that starts waiting for confirmation. Lets a stale
-- timeout (scheduled for an earlier step of the *same* run, e.g. a step
-- that already succeeded or failed) recognise it's no longer current.
local stepGen = 0

-- Non-nil only while a step is waiting for PLAYER_EQUIPMENT_CHANGED (or a
-- bind-popup decision) to confirm it landed:
--   { runGen, stepGen, slot, guid, link, actions, index, bindWaiting }
-- `slot`/`guid`/`link` describe the item we expect to find in `slot` once the
-- step completes (guid preferred, else link - the same precedence used for
-- finding the item in the first place).
local waiting

----------------------------------------------------------------------------
-- Finding an item "right now" (the descriptor's `key` is only a hint - bags
-- may have changed since the scan)
----------------------------------------------------------------------------

local function BagSlotInfo(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.hyperlink then
        return nil
    end
    local guid
    if ItemLocation then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and loc.IsValid and loc:IsValid() then
            guid = C_Item.GetItemGUID(loc)
        end
    end
    return info.hyperlink, guid
end

local function EquipSlotInfo(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then
        return nil
    end
    local guid
    if ItemLocation then
        local loc = ItemLocation:CreateFromEquipmentSlot(slot)
        if loc and loc.IsValid and loc:IsValid() then
            guid = C_Item.GetItemGUID(loc)
        end
    end
    return link, guid
end

-- Searches equipped slots 1-19, then bags 0-4, for the item the action's
-- descriptor describes, matching by guid when the descriptor has one, else
-- by link. Returns { equipSlot = n, link, guid } or { bag = n, slot = n,
-- link, guid }, or nil if it isn't anywhere the addon looks.
local function FindItem(item)
    local function matches(link, guid)
        if item.guid then
            return guid ~= nil and guid == item.guid
        end
        return link == item.link
    end

    for slot = EQUIP_FIRST, EQUIP_LAST do
        local link, guid = EquipSlotInfo(slot)
        if link and matches(link, guid) then
            return { equipSlot = slot, link = link, guid = guid }
        end
    end
    for bag = BAG_FIRST, BAG_LAST do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local link, guid = BagSlotInfo(bag, slot)
            if link and matches(link, guid) then
                return { bag = bag, slot = slot, link = link, guid = guid }
            end
        end
    end
    return nil
end

----------------------------------------------------------------------------
-- Finishing a run (success, failure, or quiet cancel)
----------------------------------------------------------------------------

local function StepLabel(action)
    local item = action and action.item
    return (item and item.link) or (item and item.itemID and tostring(item.itemID)) or "?"
end

-- Every finisher is guarded by `gen == runGen and busy`: once a run has
-- finished once, a second stale callback for the same run (e.g. a timeout
-- that was already mooted by the bind-accept hook) must not print or
-- rescan twice.
local function Finish()
    busy = false
    waiting = nil
    -- Rescan either way, so the toast reconciles against whatever actually
    -- happened.
    ns.Scanner.Request()
end

local function Fail(gen, message)
    if gen ~= runGen or not busy then
        return
    end
    Finish()
    ns:Print(message)
end

-- Names the items the run put on: the ones that came from the bags. Moves
-- of already-equipped items (key "equip:<slot>", e.g. old main hand into
-- the off hand) are bookkeeping, not what the player clicked for.
local function EquippedLabels(actions)
    local labels = {}
    for _, action in ipairs(actions) do
        local key = action.item and action.item.key
        if not (key and key:sub(1, 6) == "equip:") then
            labels[#labels + 1] = StepLabel(action)
        end
    end
    return table.concat(labels, ", ")
end

local function Succeed(gen, actions)
    if gen ~= runGen or not busy then
        return
    end
    Finish()
    local labels = EquippedLabels(actions)
    if labels == "" then
        ns:Print(L["EQUIP_DONE"])
    else
        ns:Print(L["EQUIP_DONE_ITEMS"]:format(labels))
    end
end

-- If the player cancels the bind popup, no equipment change arrives; the
-- popup hiding without a change counts as "cancelled", reported with a short,
-- neutral line (not framed as an error).
local function CancelQuiet(gen)
    if gen ~= runGen or not busy then
        return
    end
    Finish()
    ns:Print(L["EQUIP_CANCELLED"])
end

----------------------------------------------------------------------------
-- Waiting for a step to land
----------------------------------------------------------------------------

local function BeginWait(actions, index, gen, found, action)
    stepGen = stepGen + 1
    waiting = {
        runGen = gen,
        stepGen = stepGen,
        slot = action.slot,
        guid = found.guid,
        link = found.link,
        actions = actions,
        index = index,
        bindWaiting = false,
    }
    return waiting
end

-- Schedules the 3s step timeout. A bind-popup confirmation pauses it
-- (checked when the timer actually fires, since C_Timer.After can't be
-- cancelled): if `waiting.bindWaiting` is still true when this runs, the
-- popup is open and this timeout simply does nothing - the bind-accept
-- hook below calls ScheduleTimeout again for the real equip once the
-- player decides.
local function ScheduleTimeout(sg)
    C_Timer.After(STEP_TIMEOUT, function()
        if not waiting or waiting.stepGen ~= sg or waiting.bindWaiting then
            return
        end
        -- Bag full is the common cause for a 2H push clearing the off hand to
        -- time out; hint at it generically rather than trying to detect that
        -- specific case.
        Fail(waiting.runGen, L["EQUIP_TIMEOUT"]:format(StepLabel(waiting.actions[waiting.index]),
            ns.Report.SlotName(waiting.slot)))
    end)
end

----------------------------------------------------------------------------
-- Running one action, then the next
----------------------------------------------------------------------------

local function RunStep(actions, index, gen)
    if gen ~= runGen then
        return
    end
    if index > #actions then
        Succeed(gen, actions)
        return
    end
    local action = actions[index]
    if InCombatLockdown() then
        Fail(gen, L["EQUIP_STOPPED_COMBAT"]:format(StepLabel(action)))
        return
    end

    local found = FindItem(action.item)
    if not found then
        Fail(gen, L["EQUIP_NOT_FOUND"]:format(StepLabel(action)))
        return
    end

    if found.equipSlot == action.slot then
        -- Already in the target slot, nothing to do.
        RunStep(actions, index + 1, gen)
        return
    end

    -- BeginWait() is called before issuing the API call (not after) so that
    -- `waiting` already describes this step if the equip call synchronously
    -- triggers a bind-popup event. In game the round trip is presumably async
    -- either way, so this ordering is strictly safer, never wrong.
    local step = BeginWait(actions, index, gen, found, action)

    if found.bag then
        -- EquipItemByName with dstSlot always passed, so an ambiguous
        -- destination (ring/trinket/off-hand) is never left to whatever the
        -- client picks by default.
        C_Item.EquipItemByName(found.link, action.slot)
    else
        -- Moving an already-equipped item (an "equip:" action - old main hand
        -- into the off hand, etc.): the paper-doll's own pickup/place pattern
        -- (PaperDollItemSlotButton's drag-and-drop).
        PickupInventoryItem(found.equipSlot)
        PickupInventoryItem(action.slot)
        if CursorHasItem and CursorHasItem() then
            ClearCursor()
            waiting = nil
            Fail(gen, L["EQUIP_STUCK_CURSOR"]:format(ns.Report.SlotName(action.slot)))
            return
        end
    end

    ScheduleTimeout(step.stepGen)
end

----------------------------------------------------------------------------
-- Public entry point
----------------------------------------------------------------------------

-- ns.Equip.Run(suggestion): performs suggestion.actions in order, one at a
-- time, reporting in chat and rescanning when it's done (success, failure, or
-- cancel). Called only from Alerts.lua's Equip button - never automatically.
function Equip.Run(suggestion)
    if busy then
        ns:Print(L["EQUIP_BUSY"])
        return
    end
    if not suggestion or not suggestion.actions or #suggestion.actions == 0 then
        return
    end
    -- Check combat again at click time, not just when the alert was shown:
    -- Alerts.Equip() already checks this, but Run() is public, so check again
    -- here.
    if InCombatLockdown() then
        ns:Print(L["EQUIP_REFUSED_COMBAT"])
        return
    end
    busy = true
    runGen = runGen + 1
    RunStep(suggestion.actions, 1, runGen)
end

----------------------------------------------------------------------------
-- Confirming a step
----------------------------------------------------------------------------

-- The paper-doll slot button itself filters PLAYER_EQUIPMENT_CHANGED by its
-- own slot, so this does the same: ignore the event for every slot except the
-- one we're waiting on.
ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function(_event, slot)
    if not waiting or slot ~= waiting.slot then
        return
    end
    local link, guid = EquipSlotInfo(slot)
    local landed
    if waiting.guid then
        landed = guid ~= nil and guid == waiting.guid
    else
        landed = link == waiting.link
    end
    if not landed then
        -- The slot changed to something else (shouldn't normally happen
        -- mid-step); keep waiting for our item or the timeout.
        return
    end
    local actions, index, gen = waiting.actions, waiting.index, waiting.runGen
    waiting = nil
    RunStep(actions, index + 1, gen)
end)

----------------------------------------------------------------------------
-- Bind-on-equip popup: pause the timeout, resume on accept, cancel quietly on
-- cancel/hide (the stock EQUIP_BIND popup in StaticPopup.lua on the `forever`
-- branch is the source for every claim below)
----------------------------------------------------------------------------

-- EQUIP_BIND_CONFIRM / _TRADEABLE_CONFIRM / _REFUNDABLE_CONFIRM all carry
-- `arg1 = slot` and mean "the stock EQUIP_BIND popup is now open for this
-- slot, equipping is on hold until the player decides". Never suppress or
-- hook the popup itself - this only tracks that it's open.
local function OnBindPending(_event, slot)
    if not waiting or slot ~= waiting.slot then
        return
    end
    waiting.bindWaiting = true
    -- 60s cap (see BIND_CAP's comment): if the player neither accepts nor
    -- cancels within a minute, give up rather than wait forever.
    local sg, gen = waiting.stepGen, waiting.runGen
    C_Timer.After(BIND_CAP, function()
        if waiting and waiting.stepGen == sg and waiting.bindWaiting then
            CancelQuiet(gen)
        end
    end)
end
ns:RegisterEvent("EQUIP_BIND_CONFIRM", OnBindPending)
ns:RegisterEvent("EQUIP_BIND_TRADEABLE_CONFIRM", OnBindPending)
ns:RegisterEvent("EQUIP_BIND_REFUNDABLE_CONFIRM", OnBindPending)

-- EquipPendingItem(slot)/CancelPendingEquip(slot) are what the stock
-- EQUIP_BIND popup's own OnAccept/OnCancel/OnHide call (OnCancel and OnHide
-- both call CancelPendingEquip). hooksecurefunc runs *after* the real
-- function without altering it or touching any Blizzard frame/table, so this
-- is a clean, taint-free way to learn the player's decision (or that the
-- popup was simply dismissed) without ever calling either function ourselves
-- or touching the popup.
if hooksecurefunc then
    hooksecurefunc("EquipPendingItem", function(slot)
        if waiting and slot == waiting.slot and waiting.bindWaiting then
            waiting.bindWaiting = false
            -- The actual equip (and its PLAYER_EQUIPMENT_CHANGED) happens
            -- now that the player accepted; give it a fresh timeout.
            ScheduleTimeout(waiting.stepGen)
        end
    end)
    -- OnHide calls CancelPendingEquip even after OnAccept (GameDialogDefs.lua
    -- on the forever branch), so a hide that follows an accept must not count
    -- as a cancel. The accept hook above has already cleared bindWaiting by
    -- then (StaticPopup runs OnAccept before hiding), and that is the guard.
    hooksecurefunc("CancelPendingEquip", function(slot)
        if waiting and slot == waiting.slot and waiting.bindWaiting then
            CancelQuiet(waiting.runGen)
        end
    end)
end

----------------------------------------------------------------------------
-- Combat mid-run
----------------------------------------------------------------------------

-- If PLAYER_REGEN_DISABLED fires mid-run, stop before the next step and say
-- so. RunStep already checks InCombatLockdown() at the top of each step; this
-- covers the window *between* steps, while a step is waiting on confirmation.
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
    if busy and waiting then
        Fail(waiting.runGen, L["EQUIP_STOPPED_COMBAT"]:format(StepLabel(waiting.actions[waiting.index])))
    end
end)

----------------------------------------------------------------------------
-- Debug command
----------------------------------------------------------------------------

-- /gs equip: prints whether a run is in progress and, if so, which slot it's
-- currently waiting on, so a player can report what the addon is doing.
ns.slashCommands["equip"] = function()
    if busy then
        ns:Print(L["EQUIP_STATUS_BUSY"]:format(waiting and ns.Report.SlotName(waiting.slot) or "?"))
    else
        ns:Print(L["EQUIP_STATUS_IDLE"])
    end
end
