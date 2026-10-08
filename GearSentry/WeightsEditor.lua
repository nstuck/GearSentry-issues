-- WeightsEditor.lua: the "Stat Weights" canvas subcategory under the
-- GearSentry Settings category, `/gs weights`, and every profile
-- create/copy/rename/delete/import/export flow.
--
-- Profiles.lua is the pure data layer this file is a thin UI over: every
-- read/write goes through it, never GearSentryDB.profiles directly (except
-- through Scanner.lua's Active*Profile* helpers, which already wrap
-- Profiles.lua the same way).
--
-- Built at PLAYER_LOGIN, after Options.lua's own PLAYER_LOGIN handler
-- (TOC order: Options.lua loads before this file, and ns:RegisterEvent
-- dispatches handlers for one event in registration order - Core.lua
-- "Event dispatch"), so Options.GetCategory() already has the parent
-- category by the time this runs.
--
-- The canvas-subcategory, dropdown-menu and StaticPopup APIs this file relies
-- on follow Blizzard's own UI code on the `forever` branch of wow-ui-source
-- (https://github.com/Gethe/wow-ui-source).
local _, ns = ...

local L = ns.L
local Profiles = ns.Profiles

local WeightsEditor = {}
ns.WeightsEditor = WeightsEditor

----------------------------------------------------------------------------
-- Module state. `rows`/`otherRowPool` are built once in BuildRows() and only
-- ever updated in place by Refresh(): frames are never rebuilt on a redraw.
----------------------------------------------------------------------------

local subcategory -- Settings.RegisterCanvasLayoutSubcategory's return, or nil
local canvas -- the subcategory's own frame
local dropdown -- WowStyle1DropdownTemplate button
local noteText -- "Default profiles are read-only..." line
local errorText -- last Profiles error, or cleared
local statusText -- "In use" / "Not applied yet" next to Apply
local buttons = {} -- "new"/"copy"/"rename"/"delete"/"import"/"export" -> Button; also WeightsEditor.Buttons for tests

local rows = {} -- "stat:<key>" / "field:<name>" / "school:<name>" -> row
local rowOrder = {} -- same keys, in catalog display order (for layout)
local otherRowPool = {} -- grows on demand; index -> row, never shrinks
local groupHeaders = {} -- group name -> header fontstring (built once)
local otherHeader -- "Other" group header, shown only when a profile has such keys
-- Display order for Layout(): { kind = "header"|"row"|"school", ... }, built
-- once in BuildRows. "Other" rows are laid out after these.
local layoutItems = {}

-- List geometry (pixels). The canvas fills the Settings panel; these fit
-- its ~600 px content width with room for the scroll bar.
local ROW_HEIGHT = 24
local HEADER_HEIGHT = 28
local LABEL_WIDTH = 230
local BOX_WIDTH = 70
local LIST_WIDTH = 520

local importExportFrame

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

local function ClassFile()
    local _, classFile = UnitClass("player")
    return classFile
end

local function DB()
    return ns.DB()
end

-- Display name for a stat key: its GlobalStrings value ("Strength") if the
-- client has one, else the raw key. Same convention as Scanner.lua's
-- local StatName (test commands), duplicated rather than exported since
-- it's a one-line lookup and Scanner.lua's copy is intentionally private
-- to its own test-command section.
local function StatLabel(key)
    local name = _G[key]
    if type(name) == "string" then
        return name
    end
    return key
end

local function ShowError(errKey)
    if errorText then
        errorText:SetText(errKey and ns.L[errKey] or "")
    end
end

-- What the panel shows and edits: `draft` is an unsaved working copy of one
-- profile,
-- { id = profile id, scale = Profiles.Get copy }. Edits change only the
-- draft; SavedVariables changes on Save. `viewedId` is the profile picked
-- in the dropdown (nil = the character's active one).
local viewedId
local draft

-- Returns the draft scale and its id, (re)loading the draft from the saved
-- profile when the shown profile changed. A dirty draft is never replaced
-- here: every path that changes the shown profile goes through Guard()
-- first, which saves or discards it.
local function CurrentProfile()
    local db, classFile = DB(), ClassFile()
    if draft and not Profiles.Get(db, classFile, draft.id) then
        draft = nil -- its profile was deleted
    end
    if viewedId and not Profiles.Get(db, classFile, viewedId) then
        viewedId = nil
    end
    local wanted = viewedId or ns.Scanner.ActiveProfileId()
    if not (draft and draft.id == wanted) then
        local scale = wanted and Profiles.Get(db, classFile, wanted)
        draft = scale and { id = wanted, scale = scale } or nil
    end
    if draft then
        -- Pin the view to the draft, so /gs profile switching the active
        -- profile never swaps an open draft out from under the user.
        viewedId = draft.id
        return draft.scale, draft.id
    end
    return nil, wanted
end

-- The draft differs from the saved profile.
local function IsDirty()
    if not draft or draft.scale.isDefault then
        return false
    end
    local saved = Profiles.Get(DB(), ClassFile(), draft.id)
    return saved ~= nil and not Profiles.Equal(draft.scale, saved)
end

-- Runs `edit(scale)` on the draft unless it's a read-only default.
local function EditDraft(edit)
    local scale = CurrentProfile()
    if not scale then
        return false, "PROFILE_ERR_NOT_FOUND"
    end
    if scale.isDefault then
        return false, "PROFILE_ERR_READONLY"
    end
    return edit(scale)
end

local UpdateButtons -- defined with the top row below
-- Commit function of the edit box that has focus, if any. Closing the panel
-- fires our OnHide *before* the box's OnEditFocusLost, so a value typed
-- without Enter wasn't in the draft yet and the close went through with no
-- prompt (seen in game). OnPanelHide commits it first.
local focusedCommit
-- True while the focused box holds text that differs from the draft, so
-- Save/Discard light up as soon as the user types.
local focusedChanged
local FlushTyping -- defined with Save below
-- Guard(fn): runs fn now, or after the user saves or discards unsaved
-- edits (or never, on Cancel). Defined with the dialogs below.
local Guard

-- Flattened set of every catalog stat key, used to decide what counts as
-- "Other": a profile key outside this catalog is listed under Other.
local CATALOG_STAT_SET = {}
for _, group in ipairs(Profiles.CATALOG) do
    for _, key in ipairs(group.stats or {}) do
        CATALOG_STAT_SET[key] = true
    end
end

----------------------------------------------------------------------------
-- Committing/reverting edit boxes
----------------------------------------------------------------------------

-- `getter(scale)` reads the row's value from the draft; `setter(scale,
-- value)` is Profiles.SetStatIn/SetFieldIn pre-bound to the row's key or
-- field. Edits only change the draft (see "Save and discard").
local function MakeNumberRow(editBox, getter, setter)
    local function StoredText()
        local profile = CurrentProfile()
        local value = profile and getter(profile) or 0
        return Profiles.FormatNumber(value or 0)
    end

    local function Show(text)
        editBox:SetText(text)
        editBox:SetCursorPosition(0)
    end

    local function Commit()
        -- Focus leaving an unchanged box isn't an edit.
        if editBox:GetText() == StoredText() then
            return
        end
        local text = editBox:GetText()
        local ok, err = EditDraft(function(scale)
            return setter(scale, text)
        end)
        if ok then
            ShowError(nil)
            UpdateButtons()
        else
            ShowError(err)
        end
        -- Show the draft's value as stored (rounded, or reverted).
        Show(StoredText())
    end

    editBox:SetScript("OnEnterPressed", function(self)
        Commit()
        self:ClearFocus()
    end)
    -- HookScript for focus gained keeps InputBoxScriptTemplate's own
    -- EditBox_HighlightText handler (Blizzard_SharedXML/Shared/InputBox/
    -- InputBoxTemplates.xml l.4-10, `forever` branch).
    local function Changed()
        return editBox:GetText() ~= StoredText()
    end
    editBox:HookScript("OnEditFocusGained", function()
        focusedCommit, focusedChanged = Commit, Changed
    end)
    editBox:SetScript("OnEditFocusLost", function()
        focusedCommit, focusedChanged = nil, nil
        Commit()
    end)
    editBox:HookScript("OnTextChanged", function(_, userInput)
        if userInput then
            UpdateButtons()
        end
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        Show(StoredText())
        self:ClearFocus()
    end)

    return { editBox = editBox, refresh = function() Show(StoredText()) end }
end

local function StatSetter(key)
    return function(scale, value)
        return Profiles.SetStatIn(scale, key, value)
    end
end

local function FieldSetter(field)
    return function(scale, value)
        return Profiles.SetFieldIn(scale, field, value)
    end
end

-- Schools are checkboxes, not edit boxes: `row.on` is this module's own
-- record of the checked state (never read back from the widget - see the
-- comment on SchoolRow below), flipped optimistically and reverted if
-- Profiles.SetSchool refuses it.
local function MakeSchoolRow(checkbox, school)
    local row = { button = checkbox, school = school, on = false }

    local function Apply()
        checkbox:SetChecked(row.on)
    end

    checkbox:SetScript("OnClick", function()
        local want = not row.on
        local ok, err = EditDraft(function(scale)
            return Profiles.SetSchoolIn(scale, school, want)
        end)
        if ok then
            row.on = want
            ShowError(nil)
            UpdateButtons()
        else
            ShowError(err)
        end
        Apply()
    end)

    row.refresh = function()
        local profile = CurrentProfile()
        row.on = profile and profile.schools[school] or false
        Apply()
    end
    return row
end

----------------------------------------------------------------------------
-- Frame construction (once)
----------------------------------------------------------------------------

-- A plain labelled numeric edit box + its own fontstring label, parented
-- to `scrollChild`. Returns the editBox; caller wraps it with MakeNumberRow.
local function CreateFieldRow(scrollChild, labelText, tooltipText)
    local label = scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetText(labelText)

    local editBox = CreateFrame("EditBox", nil, scrollChild, "InputBoxTemplate")
    -- Sized now, not first in Layout(): text set into a zero-width edit box
    -- is scrolled out of view and stays invisible until set again (seen in
    -- game: every box empty on first open).
    editBox:SetSize(BOX_WIDTH, 20)
    editBox:SetAutoFocus(false)
    editBox:SetNumeric(false) -- values can be negative/decimal; Profiles.ParseValue validates
    if tooltipText and editBox.SetScript then
        editBox:SetScript("OnEnter", function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(labelText, 1, 1, 1)
                GameTooltip:AddLine(tooltipText, nil, nil, nil, true)
                GameTooltip:Show()
            end
        end)
        editBox:HookScript("OnLeave", function()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
    end
    return editBox, label
end

local function CreateSchoolCheckbox(scrollChild, school)
    local checkbox = CreateFrame("CheckButton", nil, scrollChild, "UICheckButtonTemplate")
    -- Unverified: no confirmed GlobalString for school display names;
    -- falls back to a title-cased school token ("Fire", "Shadow", ...).
    local label = _G["SPELL_SCHOOL" .. school]
    if type(label) ~= "string" then
        label = school:sub(1, 1) .. school:sub(2):lower()
    end
    -- UICheckButtonTemplate provides a `.Text` FontString region in the
    -- real client; this always creates our own label instead of relying
    -- on that, since a fake client's generic widget fallback would hand
    -- back a no-op function for an unset `.Text` field rather than nil.
    local checkboxLabel = scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    checkboxLabel:SetText(label)
    checkboxLabel:SetPoint("LEFT", checkbox, "RIGHT", 4, 0)
    return checkbox
end

-- Builds every row the catalog needs, once. "Other" rows are a pool grown
-- on demand by EnsureOtherRow (below), not built here, since their count
-- varies per profile.
local function BuildRows(scrollChild)
    for _, group in ipairs(Profiles.CATALOG) do
        groupHeaders[group.group] = scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        groupHeaders[group.group]:SetText(ns.L["WEIGHTSEDITOR_GROUP_" .. group.group] or group.group)
        layoutItems[#layoutItems + 1] = { kind = "header", header = groupHeaders[group.group] }

        for _, key in ipairs(group.stats or {}) do
            local editBox, label = CreateFieldRow(scrollChild, StatLabel(key),
                ns.L["WEIGHTSEDITOR_STAT_DESC"]:format(StatLabel(key)))
            layoutItems[#layoutItems + 1] = { kind = "row", label = label, editBox = editBox }
            local rowKey = "stat:" .. key
            rows[rowKey] = MakeNumberRow(editBox, function(profile) return profile.stats[key] end, StatSetter(key))
            rowOrder[#rowOrder + 1] = rowKey
        end

        for _, field in ipairs(group.fields or {}) do
            local nameKey = "WEIGHTSEDITOR_FIELD_" .. field:upper()
            local editBox, label = CreateFieldRow(scrollChild, ns.L[nameKey], ns.L[nameKey .. "_DESC"])
            layoutItems[#layoutItems + 1] = { kind = "row", label = label, editBox = editBox }
            local rowKey = "field:" .. field
            rows[rowKey] = MakeNumberRow(editBox, function(profile) return profile[field] end, FieldSetter(field))
            rowOrder[#rowOrder + 1] = rowKey
        end

        if group.schools then
            for _, school in ipairs(Profiles.SCHOOLS) do
                local checkbox = CreateSchoolCheckbox(scrollChild, school)
                layoutItems[#layoutItems + 1] = { kind = "school", checkbox = checkbox }
                local rowKey = "school:" .. school
                rows[rowKey] = MakeSchoolRow(checkbox, school)
                rowOrder[#rowOrder + 1] = rowKey
            end
        end
    end
    otherHeader = scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    otherHeader:SetText(L["WEIGHTSEDITOR_GROUP_OTHER"])
end

-- Positions every list element top to bottom and sizes the scroll child
-- so UIPanelScrollFrameTemplate knows how far to scroll (a scroll child
-- with no size shows nothing). Runs after each Refresh because the number
-- of "Other" rows varies per profile.
local function PlaceRow(scrollChild, label, editBox, y)
    label:ClearAllPoints()
    label:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 8, -y - 4)
    label:SetWidth(LABEL_WIDTH)
    label:SetJustifyH("LEFT")
    editBox:ClearAllPoints()
    -- InputBoxTemplate draws its border a few pixels left of the text area.
    editBox:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", LABEL_WIDTH + 20, -y)
    editBox:SetSize(BOX_WIDTH, 20)
end

local function Layout(otherCount)
    local scrollChild = canvas.scrollChild
    local y = 0
    for i, item in ipairs(layoutItems) do
        if item.kind == "header" then
            if i > 1 then
                y = y + 8
            end
            item.header:ClearAllPoints()
            item.header:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -y)
            y = y + HEADER_HEIGHT
        elseif item.kind == "row" then
            PlaceRow(scrollChild, item.label, item.editBox, y)
            y = y + ROW_HEIGHT
        else
            item.checkbox:ClearAllPoints()
            item.checkbox:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -y + 2)
            y = y + ROW_HEIGHT
        end
    end
    otherHeader:SetShown(otherCount > 0)
    if otherCount > 0 then
        y = y + 8
        otherHeader:ClearAllPoints()
        otherHeader:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -y)
        y = y + HEADER_HEIGHT
        for i = 1, otherCount do
            local row = otherRowPool[i]
            PlaceRow(scrollChild, row.label, row.editBox, y)
            y = y + ROW_HEIGHT
        end
    end
    scrollChild:SetSize(LIST_WIDTH, y + 8)
end

-- Returns the Nth "Other" row (1-based), creating it the first time that
-- index is needed and reusing it on every later refresh. Never destroyed,
-- only hidden when a profile has fewer "Other" keys than the high-water mark:
-- no per-refresh churn.
local function EnsureOtherRow(scrollChild, index)
    local row = otherRowPool[index]
    if row then
        return row
    end
    local editBox, label = CreateFieldRow(scrollChild, "", ns.L["WEIGHTSEDITOR_OTHER_DESC"])
    row = { editBox = editBox, label = label, key = nil }
    row.wrapper = MakeNumberRow(editBox,
        function(profile) return row.key and profile.stats[row.key] end,
        function(scale, value)
            return Profiles.SetStatIn(scale, row.key, value)
        end)
    otherRowPool[index] = row
    return row
end

----------------------------------------------------------------------------
-- Dropdown (profile picker)
----------------------------------------------------------------------------

-- Rebuilds the dropdown's menu from Profiles.List and sets its displayed
-- text to the active profile's name. MenuUtil.CreateRadioMenu calls
-- dropdown:SetupMenu(...) under the hood (confirmed by reading
-- Interface/AddOns/Blizzard_Menu/MenuUtil.lua on the `forever` branch:
-- https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_Menu/MenuUtil.lua
-- - CreateDropdownMenuUsingInserter's body is exactly
-- `dropdown:SetupMenu(function(dropdown, rootDescription) ... end)`), so
-- calling it again each refresh with a fresh entry list is the supported
-- way to pick up a just-created/renamed/deleted profile - the menu itself
-- is only generated lazily when the dropdown opens, per
-- Blizzard_ImplementationReadme.lua's 11.0 MenuSystem notes.
local function RefreshDropdown()
    if not dropdown or type(MenuUtil) ~= "table" then
        return
    end
    local db, classFile = DB(), ClassFile()
    local list = Profiles.List(db, classFile)
    local activeId = ns.Scanner.ActiveProfileId()
    local _, shownId = CurrentProfile()

    -- The active profile is marked, so viewing another one is never
    -- mistaken for using it.
    local entries = {}
    for _, entry in ipairs(list) do
        local label = entry.id == activeId and L["WEIGHTSEDITOR_ACTIVE_SUFFIX"]:format(entry.name) or entry.name
        entries[#entries + 1] = { label, entry.id }
    end

    local function IsSelected(id)
        return id == shownId
    end
    -- Only shows the profile; nothing is applied until Apply. Leaving a
    -- profile with unsaved edits asks first.
    local function SetSelected(id)
        Guard(function()
            viewedId = id
            draft = nil
            WeightsEditor.Refresh()
        end)
        -- On Cancel (or while the question is open) the dropdown must
        -- still show the profile being edited.
        WeightsEditor.Refresh()
    end

    -- `unpack` (not `table.unpack`) is correct here: this ships in the
    -- client's Lua 5.1, where `unpack` is still the global.
    MenuUtil.CreateRadioMenu(dropdown, IsSelected, SetSelected, unpack(entries))

    -- No SetText needed: WowStyle1DropdownTemplate's DropdownSelectionTextMixin
    -- shows the selected radio's text whenever the menu is generated
    -- (Blizzard_Menu/MenuTemplates.lua l.813, `forever` branch), and
    -- SetupMenu generates it at once while the dropdown is shown, else on
    -- OnShow (Blizzard_Menu/DropdownButton.lua l.237).
end

----------------------------------------------------------------------------
-- Redraw (OnRefresh, and after any profile change)
----------------------------------------------------------------------------

function WeightsEditor.Refresh()
    if not canvas then
        return
    end
    local profile = CurrentProfile()
    local isDefault = profile and profile.isDefault

    RefreshDropdown()
    ShowError(nil)
    UpdateButtons()

    if noteText then
        noteText:SetShown(isDefault and true or false)
    end
    if buttons.rename then
        buttons.rename:SetEnabled(not isDefault)
    end
    if buttons.delete then
        buttons.delete:SetEnabled(not isDefault)
    end

    for _, key in ipairs(rowOrder) do
        local row = rows[key]
        row.refresh()
        local widget = row.editBox or row.button
        if widget and widget.SetEnabled then
            widget:SetEnabled(not isDefault)
        end
    end

    -- "Other": any stats key on the profile that isn't in the catalog sorted
    -- for a stable order.
    local others = {}
    if profile then
        for key in pairs(profile.stats) do
            if not CATALOG_STAT_SET[key] then
                others[#others + 1] = key
            end
        end
        table.sort(others)
    end
    for i, key in ipairs(others) do
        local row = EnsureOtherRow(canvas.scrollChild, i)
        row.key = key
        row.label:SetText(StatLabel(key))
        row.wrapper.refresh()
        row.editBox:SetEnabled(not isDefault)
        row.editBox:Show()
        row.label:Show()
    end
    for i = #others + 1, #otherRowPool do
        local row = otherRowPool[i]
        row.editBox:Hide()
        row.label:Hide()
    end
    Layout(#others)
end

-- So /gs profile, a rename/delete, or another open client action refreshes an
-- already-open panel.
ns.Scanner.OnProfileChanged(function()
    WeightsEditor.Refresh()
end)

----------------------------------------------------------------------------
-- New / Copy / Rename (one popup, three modes) and Delete
----------------------------------------------------------------------------

-- Feature-detected like every other Blizzard global this addon reads:
-- StaticPopup is FrameXML, present on the `forever` branch. Guarding it here
-- means loading this file never fails, even on a client without it or in a
-- test harness that doesn't fake StaticPopupDialogs.
local haveStaticPopup = type(StaticPopupDialogs) == "table" and type(StaticPopup_Show) == "function"
    and type(StaticPopup_OnClick) == "function"

----------------------------------------------------------------------------
-- Save and discard: saved profiles only ever hold values the user confirmed.
----------------------------------------------------------------------------

-- A value still being typed (no Enter yet) counts as an edit: commit it to
-- the draft before Save, Guard or the close prompt look at IsDirty(). See
-- focusedCommit for why focus-lost alone isn't enough.
function FlushTyping()
    if focusedCommit then
        local commit = focusedCommit
        focusedCommit, focusedChanged = nil, nil
        commit()
    end
end

-- Writes the draft to SavedVariables; rescans if it's the active profile.
function WeightsEditor.Save()
    FlushTyping()
    if not IsDirty() then
        return
    end
    local ok, err = Profiles.Save(DB(), ClassFile(), draft.id, draft.scale)
    if not ok then
        ShowError(err)
        return
    end
    local id = draft.id
    draft = nil -- reload the saved (normalised) values
    ns.Scanner.ProfileSaved(id)
    WeightsEditor.Refresh()
end

function WeightsEditor.Discard()
    draft = nil
    WeightsEditor.Refresh()
end

-- Three-button dialog: Save / Discard / Cancel. Uses StaticPopup's
-- selectCallbackByIndex mode, where button N calls OnButtonN and a falsy
-- return hides the dialog (Blizzard_StaticPopup/StaticPopup.lua l.701-720,
-- `forever` branch). OnHide runs on every close (l.626-640), so a close
-- without a choice (Escape, the dialog bumped by another popup) is
-- handled there: Cancel while the panel is open, Discard after it closed.
-- Never Save: unconfirmed values must not become the source of truth.
local function ChoiceHandler(choice)
    return function(_dialog, data)
        ns:Debug("WeightsEditor: dialog answered", choice)
        data.handled = true
        if choice == "save" then
            WeightsEditor.Save()
        elseif choice == "discard" then
            WeightsEditor.Discard()
        end
        if choice ~= "cancel" and data.continue then
            data.continue()
        elseif choice == "cancel" then
            WeightsEditor.Refresh()
        end
    end
end

local function UnhandledClose(dialog, data)
    ns:Debug("WeightsEditor: dialog hidden", dialog and dialog.which,
        "handled=" .. tostring(data and data.handled), "closing=" .. tostring(data and data.closing))
    if data and not data.handled then
        data.handled = true
        if data.closing then
            WeightsEditor.Discard()
        else
            WeightsEditor.Refresh()
        end
    end
end

if haveStaticPopup then
StaticPopupDialogs["GEARSENTRY_UNSAVED"] = {
    text = L["WEIGHTSEDITOR_UNSAVED"],
    button1 = L["WEIGHTSEDITOR_SAVE"],
    button2 = L["WEIGHTSEDITOR_DISCARD"],
    button3 = CANCEL,
    selectCallbackByIndex = true,
    OnButton1 = ChoiceHandler("save"),
    OnButton2 = ChoiceHandler("discard"),
    OnButton3 = ChoiceHandler("cancel"),
    OnShow = function(dialog) ns:Debug("WeightsEditor: dialog shown", dialog.which) end,
    OnHide = UnhandledClose,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Same question after the panel closed: no Cancel, there's nothing to go back
-- to. No hideOnEscape: the Options Close button hides the panel and then
-- calls ToggleGameMenu (SettingsPanelMixin:TransitionBackOpeningPanel,
-- Blizzard_Settings_Shared/Blizzard_SettingsPanel.lua l.295-303), which runs
-- the Esc handlers first; StaticPopup_EscapePressed (StaticPopup.lua
-- l.842-856, registered in Blizzard_StaticPopup_Game/GameDialog.lua l.3)
-- hides every shown hideOnEscape dialog. So this prompt was closed the moment
-- it opened and counted as Discard (seen in game).
StaticPopupDialogs["GEARSENTRY_UNSAVED_CLOSE"] = {
    text = L["WEIGHTSEDITOR_UNSAVED"],
    button1 = L["WEIGHTSEDITOR_SAVE"],
    button2 = L["WEIGHTSEDITOR_DISCARD"],
    selectCallbackByIndex = true,
    OnButton1 = ChoiceHandler("save"),
    OnButton2 = ChoiceHandler("discard"),
    OnShow = function(dialog) ns:Debug("WeightsEditor: dialog shown", dialog.which) end,
    OnHide = UnhandledClose,
    timeout = 0,
    whileDead = true,
    hideOnEscape = false,
}
end -- haveStaticPopup (unsaved-changes dialogs)

function Guard(continue)
    local flushed = focusedCommit ~= nil
    FlushTyping()
    ns:Debug("WeightsEditor: Guard", "flushed=" .. tostring(flushed), "dirty=" .. tostring(IsDirty()))
    if not IsDirty() then
        continue()
        return
    end
    if not haveStaticPopup then
        -- No way to ask: keep the edits and do nothing.
        ShowError("PROFILE_ERR_UNSAVED")
        return
    end
    StaticPopup_Show("GEARSENTRY_UNSAVED", draft.scale.name, nil, { continue = continue })
end

-- Panel closed (or another settings page picked) with unsaved edits.
local function OnPanelHide()
    local flushed = focusedCommit ~= nil
    FlushTyping()
    ns:Debug("WeightsEditor: panel hidden", "flushed=" .. tostring(flushed), "dirty=" .. tostring(IsDirty()))
    if not IsDirty() then
        return
    end
    if haveStaticPopup then
        StaticPopup_Show("GEARSENTRY_UNSAVED_CLOSE", draft.scale.name, nil, { closing = true })
    else
        WeightsEditor.Discard()
    end
end

if haveStaticPopup then
-- Shared by New/Copy/Rename: `data.mode` picks the Profiles.lua call,
-- `data.fromId`/`data.renameId` carry the extra argument each mode needs.
-- One dialog definition instead of three keeps the OnAccept logic (and the
-- "select the result" step) in exactly one place.
-- `text = ""` + the prompt as text_arg1: Forever's dialog code formats
-- dialogInfo.text unless it is exactly "", in which case it shows
-- text_arg1 as-is (Blizzard_StaticPopup_Game/GameDialog.lua l.120-124,
-- `forever` branch). A missing `text` errors in SetFormattedText.
StaticPopupDialogs["GEARSENTRY_PROFILE_NAME"] = {
    text = "",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 40,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(dialog, data)
        local editBox = dialog:GetEditBox()
        editBox:SetText((data and data.prefill) or "")
        editBox:HighlightText()
        editBox:SetFocus()
    end,
    -- Default StaticPopup edit boxes don't accept Enter on their own
    -- (StaticPopupEditBoxMixin:OnEnterPressed only fires a dialog's
    -- EditBoxOnEnterPressed if that dialog defines one - confirmed by reading
    -- SharedTemplates.lua on the `forever` branch), so this mirrors the
    -- common StaticPopup idiom of clicking button1 (StaticPopup_OnClick is
    -- defined in StaticPopup.lua on the same branch).
    EditBoxOnEnterPressed = function(editBox)
        local dialog = editBox:GetParent()
        if not dialog.button1 or dialog.button1:IsEnabled() then
            StaticPopup_OnClick(dialog, 1)
        end
    end,
    EditBoxOnEscapePressed = function(editBox)
        editBox:GetParent():Hide()
    end,
    OnAccept = function(dialog, data)
        -- dialog:GetEditBox() (not the older `dialog.editBox`) is the
        -- accessor used throughout StaticPopup.lua on the `forever` branch
        -- (e.g. StaticPopup_HideInsertedFrames reads it the same way).
        local text = dialog:GetEditBox():GetText()
        local db, classFile = DB(), ClassFile()
        local ok, result
        if data.mode == "rename" then
            ok, result = Profiles.Rename(db, classFile, data.id, text)
        else
            ok, result = Profiles.Create(db, classFile, text, data.fromId)
        end
        if ok then
            -- Show the result; it's used only after Apply.
            viewedId = result
            draft = nil
            if data.mode == "rename" then
                ns.Scanner.ProfileRenamed()
            end
            WeightsEditor.Refresh()
        else
            ShowError(result)
            -- Returning true keeps the dialog open so the name can be fixed:
            -- StaticPopup.lua (`forever` branch) hides only when OnAccept
            -- returns a falsy value (`hide = not OnAccept(...)`).
            return true
        end
    end,
}

StaticPopupDialogs["GEARSENTRY_PROFILE_DELETE"] = {
    text = L["WEIGHTSEDITOR_DELETE_CONFIRM"],
    button1 = YES,
    button2 = NO,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_dialog, data)
        -- Deleting discards any unsaved edits too, so no Guard here.
        local wasActive = data.id == ns.Scanner.ActiveProfileId()
        local ok, err = Profiles.Delete(DB(), ClassFile(), data.id)
        if ok then
            viewedId = nil
            draft = nil
            ns.Scanner.ProfileDeleted(wasActive)
            WeightsEditor.Refresh()
        else
            ShowError(err)
        end
    end,
}
end -- haveStaticPopup (New/Copy/Rename/Delete dialog defs)

function WeightsEditor.ShowNewDialog()
    if not haveStaticPopup then
        ns:Debug("WeightsEditor: StaticPopup not available; can't show New dialog")
        return
    end
    StaticPopup_Show("GEARSENTRY_PROFILE_NAME", L["WEIGHTSEDITOR_PROMPT_NEW"], nil, { mode = "new", prefill = "" })
end

function WeightsEditor.ShowCopyDialog()
    if not haveStaticPopup then
        ns:Debug("WeightsEditor: StaticPopup not available; can't show Copy dialog")
        return
    end
    local profile, id = CurrentProfile()
    local suggested = profile and Profiles.SuggestName(DB(), ClassFile(), profile.name) or ""
    StaticPopup_Show("GEARSENTRY_PROFILE_NAME", L["WEIGHTSEDITOR_PROMPT_COPY"], nil,
        { mode = "copy", fromId = id, prefill = suggested })
end

function WeightsEditor.ShowRenameDialog()
    if not haveStaticPopup then
        ns:Debug("WeightsEditor: StaticPopup not available; can't show Rename dialog")
        return
    end
    local profile, id = CurrentProfile()
    if not profile or profile.isDefault then
        return
    end
    StaticPopup_Show("GEARSENTRY_PROFILE_NAME", L["WEIGHTSEDITOR_PROMPT_RENAME"], nil,
        { mode = "rename", id = id, prefill = profile.name })
end

function WeightsEditor.ShowDeleteDialog()
    if not haveStaticPopup then
        ns:Debug("WeightsEditor: StaticPopup not available; can't show Delete dialog")
        return
    end
    local profile, id = CurrentProfile()
    if not profile or profile.isDefault then
        return
    end
    StaticPopup_Show("GEARSENTRY_PROFILE_DELETE", profile.name, nil, { id = id })
end

----------------------------------------------------------------------------
-- Import / Export dialog (own frame: CopyToClipboard is
-- {{restrictedapi|protected}} per the wiki page https://warcraft.wiki.gg/wiki/API_CopyToClipboard,
-- so export is "select + focus the text, tell the owner to press Ctrl+C"
-- instead, same as every other WoW addon's share-string box)
----------------------------------------------------------------------------

-- Built lazily on first Import/Export click, not at BuildPanel time: it's the
-- one piece of this panel that isn't part of the Settings canvas (it's our
-- own dialog frame), so there's no reason to pay for it before it's needed.
local function EnsureImportExportFrame()
    if importExportFrame then
        return importExportFrame
    end
    local f = CreateFrame("Frame", "GearSentryImportExportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(420, 320)
    f:SetPoint("CENTER")
    -- SettingsPanel is frameStrata="HIGH" (Blizzard_Settings_Shared/
    -- Blizzard_SettingsPanel.xml, `forever` branch); on UIParent's default
    -- MEDIUM strata this window opened behind it. DIALOG is where
    -- StaticPopups draw, so it sits above the panel like they do.
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    -- Lets Escape close it like any other floating dialog (UISpecialFrames is
    -- a plain global array read by Blizzard_UIParentPanelManager/Shared/
    -- UIParentPanelManager.lua on the `forever` branch). The frame needs a
    -- global name for this to work (UISpecialFrames stores name strings,
    -- resolved via _G), which is why it's named above instead of left
    -- anonymous.
    if type(_G.UISpecialFrames) == "table" then
        table.insert(_G.UISpecialFrames, "GearSentryImportExportFrame")
    end

    f.title = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -8)

    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 16, -32)
    scrollFrame:SetPoint("BOTTOMRIGHT", -32, 56)

    -- A plain multi-line EditBox as the scroll child of
    -- UIPanelScrollFrameTemplate. Not ScrollingEditBoxTemplate: that one is
    -- a *Frame* template with its own ScrollBox and edit box inside
    -- (Blizzard_SharedXML/Shared/Scroll/ScrollTemplates.xml l.21 on the
    -- `forever` branch), so it can't be the template of an EditBox.
    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetWidth(360)
    editBox:SetScript("OnEscapePressed", function()
        f:Hide()
    end)
    scrollFrame:SetScrollChild(editBox)
    -- Clicking the empty area below short text should still focus the box.
    scrollFrame:SetScript("OnMouseDown", function()
        editBox:SetFocus()
    end)
    f.editBox = editBox

    f.hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    f.hint:SetPoint("BOTTOMLEFT", 16, 32)

    f.importButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.importButton:SetSize(90, 22)
    f.importButton:SetPoint("BOTTOMRIGHT", -16, 12)
    f.importButton:SetText(L["WEIGHTSEDITOR_IMPORT_BUTTON"])
    f.importButton:SetScript("OnClick", function()
        -- The panel stays editable behind this window, so ask again here.
        local text = editBox:GetText()
        Guard(function()
            WeightsEditor.DoImport(text)
        end)
    end)

    importExportFrame = f
    return f
end

-- One dialog for a name clash during import: Profiles.Import refuses a
-- taken name, so this re-prompts with Profiles.SuggestName the same way
-- Copy does.
if haveStaticPopup then
StaticPopupDialogs["GEARSENTRY_PROFILE_IMPORT_NAME"] = {
    text = L["WEIGHTSEDITOR_PROMPT_IMPORT"],
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 40,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(dialog, data)
        local editBox = dialog:GetEditBox()
        editBox:SetText((data and data.prefill) or "")
        editBox:HighlightText()
        editBox:SetFocus()
    end,
    EditBoxOnEnterPressed = function(editBox)
        local dialog = editBox:GetParent()
        if not dialog.button1 or dialog.button1:IsEnabled() then
            StaticPopup_OnClick(dialog, 1)
        end
    end,
    EditBoxOnEscapePressed = function(editBox)
        editBox:GetParent():Hide()
    end,
    OnAccept = function(dialog, data)
        local name = dialog:GetEditBox():GetText()
        local ok, result = Profiles.Import(DB(), ClassFile(), data.parsed, name)
        if ok then
            viewedId = result
            draft = nil
            WeightsEditor.Refresh()
            if importExportFrame then
                importExportFrame:Hide()
            end
        else
            ShowError(result)
            return true -- keep the dialog open (see GEARSENTRY_PROFILE_NAME)
        end
    end,
}
end -- haveStaticPopup (import-name-clash dialog def)

function WeightsEditor.ShowExportDialog()
    local f = EnsureImportExportFrame()
    local profile, id = CurrentProfile()
    f.title:SetText(L["WEIGHTSEDITOR_EXPORT_TITLE"])
    f.hint:SetText(L["WEIGHTSEDITOR_EXPORT_HINT"])
    f.importButton:Hide()
    local text = profile and Profiles.Export(DB(), ClassFile(), id) or ""
    f.editBox:SetText(text)
    f.editBox:SetFocus()
    f.editBox:HighlightText()
    f:Show()
end

function WeightsEditor.ShowImportDialog()
    local f = EnsureImportExportFrame()
    f.title:SetText(L["WEIGHTSEDITOR_IMPORT_TITLE"])
    f.hint:SetText(L["WEIGHTSEDITOR_IMPORT_HINT"])
    f.importButton:Show()
    f.editBox:SetText("")
    f.editBox:SetFocus()
    f:Show()
end

-- Exposed on its own (not just the Import button's OnClick) so tests can
-- drive it directly without needing a real multi-line edit box. Import errors
-- go in the import window's own hint line: the panel's error line sits behind
-- that window, where it can't be seen.
local function ImportError(message)
    if importExportFrame and importExportFrame.hint then
        importExportFrame.hint:SetText("|cffff2020" .. message .. "|r")
    end
end

function WeightsEditor.DoImport(text)
    local parsed, err = Profiles.Parse(text)
    if not parsed then
        ShowError(err)
        ImportError(L[err])
        return false, err
    end
    local classFile = ClassFile()
    if parsed.classFile ~= classFile then
        -- Another class's profile is refused with a message naming the class.
        -- PROFILE_ERR_CLASS's two %s are (that profile's class, this
        -- character's class) per the string's own comment in enUS.lua.
        local className = ns.ClassName and ns.ClassName(parsed.classFile) or parsed.classFile
        local hereName = ns.ClassName and ns.ClassName(classFile) or classFile
        local message = L["PROFILE_ERR_CLASS"]:format(className, hereName)
        if errorText then
            errorText:SetText(message)
        end
        ImportError(message)
        return false, "PROFILE_ERR_CLASS"
    end
    local ok, result = Profiles.Import(DB(), classFile, parsed)
    if ok then
        viewedId = result
        draft = nil
        WeightsEditor.Refresh()
        if importExportFrame then
            importExportFrame:Hide()
        end
        return true, result
    end
    if result == "PROFILE_ERR_NAME_TAKEN" and haveStaticPopup then
        local suggested = Profiles.SuggestName(DB(), classFile, parsed.name)
        StaticPopup_Show("GEARSENTRY_PROFILE_IMPORT_NAME", nil, nil, { parsed = parsed, prefill = suggested })
        return false, result
    end
    ShowError(result)
    ImportError(L[result])
    return false, result
end

----------------------------------------------------------------------------
-- Panel construction
----------------------------------------------------------------------------

-- Makes the shown profile active and applies its current values: one
-- alert reset + rescan (Scanner.SetActiveProfile), then a redraw via the
-- OnProfileChanged listener.
-- Makes the shown profile the character's active one (saving or
-- discarding unsaved edits first): one alert reset + rescan.
function WeightsEditor.Apply()
    Guard(function()
        local _, id = CurrentProfile()
        ns.Scanner.SetActiveProfile(id)
    end)
end

function UpdateButtons()
    local scale, shownId = CurrentProfile()
    local dirty = IsDirty()
        or (focusedChanged ~= nil and scale ~= nil and not scale.isDefault and focusedChanged())
    local inUse = shownId == ns.Scanner.ActiveProfileId()
    if buttons.apply then
        buttons.apply:SetEnabled(not inUse)
    end
    if buttons.save then
        buttons.save:SetEnabled(dirty)
        buttons.discard:SetEnabled(dirty)
    end
    if statusText then
        local status
        if dirty then
            status = L["WEIGHTSEDITOR_STATUS_UNSAVED"]
        elseif inUse then
            status = L["WEIGHTSEDITOR_STATUS_ACTIVE"]
        else
            status = L["WEIGHTSEDITOR_STATUS_PENDING"]
        end
        statusText:SetText(status)
    end
end

local function BuildTopRow(frame)
    -- Dropdown on its own line, the six buttons on the next: in one row
    -- they'd overflow the Settings panel's ~600 px content width.
    dropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("TOPLEFT", 16, -16)
    dropdown:SetWidth(280)

    local previous
    local function MakeButton(labelKey, onClick, first)
        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize(84, 22)
        if first then
            button:SetPoint(unpack(first))
        else
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        end
        button:SetText(L[labelKey])
        button:SetScript("OnClick", onClick)
        previous = button
        return button
    end
    -- Leaving a profile with unsaved edits asks Save / Discard / Cancel
    -- first.
    local function Guarded(fn)
        return function()
            Guard(fn)
        end
    end

    -- Row 1: Apply (use the shown profile; the only control besides Save that
    -- rescans), Save and Discard (the draft).
    buttons.apply = MakeButton("WEIGHTSEDITOR_APPLY", WeightsEditor.Apply, { "LEFT", dropdown, "RIGHT", 12, 0 })
    buttons.save = MakeButton("WEIGHTSEDITOR_SAVE", WeightsEditor.Save)
    buttons.discard = MakeButton("WEIGHTSEDITOR_DISCARD", WeightsEditor.Discard)

    -- Row 2: profile management. Delete needs no guard: it drops the
    -- profile's edits along with the profile.
    buttons.new = MakeButton("WEIGHTSEDITOR_NEW", Guarded(WeightsEditor.ShowNewDialog),
        { "TOPLEFT", dropdown, "BOTTOMLEFT", 0, -8 })
    buttons.copy = MakeButton("WEIGHTSEDITOR_COPY", Guarded(WeightsEditor.ShowCopyDialog))
    buttons.rename = MakeButton("WEIGHTSEDITOR_RENAME", Guarded(WeightsEditor.ShowRenameDialog))
    buttons.delete = MakeButton("WEIGHTSEDITOR_DELETE", WeightsEditor.ShowDeleteDialog)
    buttons.import = MakeButton("WEIGHTSEDITOR_IMPORT", Guarded(WeightsEditor.ShowImportDialog))
    buttons.export = MakeButton("WEIGHTSEDITOR_EXPORT", Guarded(WeightsEditor.ShowExportDialog))

    statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", buttons.new, "BOTTOMLEFT", 0, -8)
    -- Exposed for tests (same pattern as the rest of this file's
    -- ns.WeightsEditor surface).
    WeightsEditor.Buttons = buttons

    noteText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    noteText:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -4)
    noteText:SetText(L["PROFILE_ERR_READONLY"])

    errorText = frame:CreateFontString(nil, "ARTWORK", "GameFontRedSmall")
    errorText:SetPoint("TOPLEFT", noteText, "BOTTOMLEFT", 0, -4)
end

-- Settings.RegisterCanvasLayoutSubcategory(parentCategory, frame, name)
-- (Blizzard_Settings.lua on the forever branch) returns (subcategory,
-- layout); OnRefresh/OnCommit/OnDefault are optional functions read directly
-- off `frame` (Blizzard_ImplementationReadme.lua, same path, "*** Canvas ***"
-- section), and `layout:AddAnchorPoint` sets the frame's anchors inside the
-- panel (defaults to filling it if omitted
-- - same readme file).
function WeightsEditor.BuildPanel()
    local parent = ns.Options and ns.Options.GetCategory and ns.Options.GetCategory()
    if not parent or type(Settings) ~= "table"
        or type(Settings.RegisterCanvasLayoutSubcategory) ~= "function" then
        ns:Debug("WeightsEditor: canvas subcategory API or parent category not available; skipping")
        return
    end

    canvas = CreateFrame("Frame", "GearSentryWeightsEditorFrame")
    canvas.scrollFrame = CreateFrame("ScrollFrame", nil, canvas, "UIPanelScrollFrameTemplate")
    canvas.scrollChild = CreateFrame("Frame", nil, canvas.scrollFrame)
    canvas.scrollFrame:SetScrollChild(canvas.scrollChild)

    BuildTopRow(canvas)
    canvas.scrollFrame:SetPoint("TOPLEFT", 16, -150)
    canvas.scrollFrame:SetPoint("BOTTOMRIGHT", -32, 16)

    BuildRows(canvas.scrollChild)

    canvas.OnRefresh = WeightsEditor.Refresh
    -- Also redraw on show: the boxes must be filled while visible, and
    -- OnRefresh alone left them empty on the first open (seen in game).
    canvas:HookScript("OnShow", function()
        -- Each visit starts on the profile in use, unless edits are still
        -- waiting for the Save/Discard answer from the last close.
        if not IsDirty() then
            viewedId = nil
            draft = nil
        end
        WeightsEditor.Refresh()
    end)
    -- Closing the panel (or picking another settings page) with unsaved
    -- edits asks Save or Discard; it never saves on its own.
    canvas:HookScript("OnHide", OnPanelHide)

    local result, layout = Settings.RegisterCanvasLayoutSubcategory(parent, canvas, L["WEIGHTSEDITOR_TITLE"])
    subcategory = result
    if layout and layout.AddAnchorPoint then
        layout:AddAnchorPoint("TOPLEFT", 0, 0)
        layout:AddAnchorPoint("BOTTOMRIGHT", 0, 0)
    end

    WeightsEditor.Refresh()
end

function WeightsEditor.GetSubcategory()
    return subcategory
end

-- Test-only accessors, same pattern as Options.lua's Options.GetCategory(): a
-- few plain getters onto otherwise module-local state, rather than exposing
-- the state itself.
function WeightsEditor.GetDropdown()
    return dropdown
end

function WeightsEditor.GetRow(key)
    return rows[key]
end

function WeightsEditor.GetOtherRow(index)
    return otherRowPool[index]
end

function WeightsEditor.GetCanvas()
    return canvas
end

function WeightsEditor.GetShownId()
    local _, id = CurrentProfile()
    return id
end

function WeightsEditor.GetStatusText()
    return statusText
end

function WeightsEditor.GetErrorText()
    return errorText
end

function WeightsEditor.GetNoteText()
    return noteText
end

-- /gs weights - opens the Stat Weights subcategory directly. Mirrors
-- Options.Open()'s pattern (Settings.OpenToCategory(category:GetID())).
local function OpenWeights()
    if not subcategory then
        ns:Print(L["OPTIONS_NOT_AVAILABLE"])
        return
    end
    Settings.OpenToCategory(subcategory:GetID())
end

ns.slashCommands["weights"] = OpenWeights

ns:RegisterEvent("PLAYER_LOGIN", WeightsEditor.BuildPanel)
