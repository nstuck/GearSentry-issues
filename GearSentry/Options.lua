-- Options.lua: the Blizzard Settings panel, `/gs options` (alias `/gs
-- config`), and the addon-compartment entry that opens it. The Settings API
-- calls follow Blizzard_Settings on the `forever` branch of wow-ui-source
-- (https://github.com/Gethe/wow-ui-source).
--
-- One write path: every control here is a Settings.RegisterProxySetting whose
-- getter reads settings[key] and whose setter calls ns.SetSetting(key, value)
-- (Core.lua) - the same function the slash commands in Core.lua/Alerts.lua
-- call. Neither side invents its own side effect; Scanner.lua, BagArrows.lua
-- and BetterBags.lua each register their reaction via ns.OnSettingChanged.
-- This file's own ns.OnSettingChanged registrations (below, in RegisterProxy)
-- exist only to call Settings.NotifyUpdate so an *open* panel reflects a
-- value a slash command just changed.
local addonName, ns = ...

local L = ns.L
local Options = {}
ns.Options = Options

-- The registered category, or nil if the Settings API wasn't available.
-- Options.Open() and the compartment click both check this before calling
-- Settings.OpenToCategory.
local category

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

-- Settings.RegisterProxySetting's `variable` is a separate identifier used
-- to look the setting back up (Settings.NotifyUpdate, Settings.GetSetting)
-- - it's global in Blizzard's own registry, so every variable name is
-- prefixed with the addon name.
local function Variable(key)
    return "GearSentry_" .. key
end

local function settings()
    return ns.DB().settings
end

-- Registers a settings[key] proxy setting and wires Settings.NotifyUpdate so
-- an already-open panel picks up a value changed from outside it (a slash
-- command, or /gs scale's Alerts.Reset path never touches these keys, but the
-- pattern is the same for any future outside writer). `getValue`/`setValue`
-- default to a plain settings[key] round-trip through ns.SetSetting; the
-- armor-filter checkbox below passes its own pair to invert the value.
local function RegisterProxy(key, varType, name, defaultValue, getValue, setValue)
    getValue = getValue or function()
        return settings()[key]
    end
    setValue = setValue or function(value)
        ns.SetSetting(key, value)
    end
    local setting = Settings.RegisterProxySetting(category, Variable(key), varType,
        name, defaultValue, getValue, setValue)
    ns.OnSettingChanged(key, function()
        Settings.NotifyUpdate(Variable(key))
    end)
    return setting
end

local function RegisterCheckbox(key, name, tooltip, defaultValue, getValue, setValue)
    local setting = RegisterProxy(key, Settings.VarType.Boolean, name, defaultValue, getValue, setValue)
    Settings.CreateCheckbox(category, setting, tooltip)
end

-- `formatter(value)` labels the slider's current value (one decimal for
-- minGain, integer + "%" for minGainPct). Feature-detected:
-- MinimalSliderWithSteppersMixin is the same mixin Forever's own
-- Camelot/ControlsOverrides.lua uses for this; if it's ever missing, the
-- slider still works, just without a custom label.
local function RegisterSlider(key, name, tooltip, defaultValue, minValue, maxValue, step, formatter)
    local setting = RegisterProxy(key, Settings.VarType.Number, name, defaultValue)
    local options = Settings.CreateSliderOptions(minValue, maxValue, step)
    if MinimalSliderWithSteppersMixin and formatter then
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
    end
    Settings.CreateSlider(category, setting, options, tooltip)
end

local function PercentFormatter(value)
    return string.format("%d%%", value)
end

local function OneDecimalFormatter(value)
    return string.format("%.1f", value)
end

----------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------

local function BuildPanel()
    if type(Settings) ~= "table" or type(Settings.RegisterVerticalLayoutCategory) ~= "function" then
        ns:Debug("Options: Settings API not available; skipping options panel")
        return
    end
    -- SettingsPanel is the named global frame the section header/button
    -- initializers below attach to (SettingsPanelMixin:GetLayout);
    -- feature-detected too, since it's a different global than Settings.*
    -- itself.
    local haveLayout = type(SettingsPanel) == "table" and type(SettingsPanel.GetLayout) == "function"

    category = Settings.RegisterVerticalLayoutCategory(ns.ADDON_TITLE)
    local layout = haveLayout and SettingsPanel:GetLayout(category) or nil

    local function AddHeader(name, tooltip)
        if layout and type(CreateSettingsListSectionHeaderInitializer) == "function" then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(name, tooltip))
        end
    end

    -- 1. Alerts
    AddHeader(L["OPTIONS_SECTION_ALERTS"])
    RegisterCheckbox("tooltipLine", L["OPTIONS_TOOLTIP_LINE"], L["OPTIONS_TOOLTIP_LINE_DESC"], true)
    RegisterCheckbox("bagArrows", L["OPTIONS_BAG_ARROWS"], L["OPTIONS_BAG_ARROWS_DESC"], true)
    RegisterCheckbox("alertSound", L["OPTIONS_ALERT_SOUND"], L["OPTIONS_ALERT_SOUND_DESC"], true)
    RegisterCheckbox("alertAtLogin", L["OPTIONS_ALERT_AT_LOGIN"], L["OPTIONS_ALERT_AT_LOGIN_DESC"], true)
    if layout and type(CreateSettingsButtonInitializer) == "function" then
        layout:AddInitializer(CreateSettingsButtonInitializer(
            L["OPTIONS_RESET_POSITION"], L["OPTIONS_RESET_BUTTON"], ns.Alerts.ResetPosition, nil, true))
    end

    -- 2. What counts as an upgrade
    AddHeader(L["OPTIONS_SECTION_UPGRADE"])
    RegisterCheckbox("suggestBoE", L["OPTIONS_SUGGEST_BOE"], L["OPTIONS_SUGGEST_BOE_DESC"], true)
    -- "Only suggest my best armor type" is the *inverse* of allowLowerArmor
    -- (allowLowerArmor = true means "stats win", i.e. the filter is off), so
    -- the getter/setter negate it - the label reads naturally while the
    -- underlying setting (and Scanner's listener on it) stays
    -- allowLowerArmor.
    RegisterCheckbox("allowLowerArmor", L["OPTIONS_ARMOR_FILTER"], L["OPTIONS_ARMOR_FILTER_DESC"], false,
        function()
            return not settings().allowLowerArmor
        end,
        function(value)
            ns.SetSetting("allowLowerArmor", not value)
        end)
    RegisterSlider("minGainPct", L["OPTIONS_MIN_GAIN_PCT"], L["OPTIONS_MIN_GAIN_PCT_DESC"], 2,
        0, 20, 1, PercentFormatter)
    RegisterSlider("minGain", L["OPTIONS_MIN_GAIN"], L["OPTIONS_MIN_GAIN_DESC"], 0,
        0, 10, 0.1, OneDecimalFormatter)

    -- 3. Reset ignored items - same function /gs unignore calls
    -- (Alerts.ResetIgnored, moved out of that slash command's body in
    -- Alerts.lua for exactly this sharing).
    if layout and type(CreateSettingsButtonInitializer) == "function" then
        layout:AddInitializer(CreateSettingsButtonInitializer(
            L["OPTIONS_RESET_IGNORED"], L["OPTIONS_RESET_BUTTON"], ns.Alerts.ResetIgnored, nil, true))
    end

    -- 4. Advanced: debug. It needs its own header: a header groups every
    -- control after it, so without one debug looked like part of the section
    -- above.
    AddHeader(L["OPTIONS_SECTION_ADVANCED"])
    RegisterCheckbox("debug", L["OPTIONS_DEBUG"], L["OPTIONS_DEBUG_DESC"], false)

    -- 5. BetterBags, last - only if it's loaded right now (D7's note lives
    -- in the header's tooltip, never as a setting we write into BetterBags
    -- itself). Last because it has no controls under it.
    if ns.BetterBags and ns.BetterBags.IsLoaded and ns.BetterBags.IsLoaded() then
        AddHeader(L["OPTIONS_SECTION_BETTERBAGS"], L["BETTERBAGS_HINT"]:format(ns.ADDON_TITLE))
    end

    Settings.RegisterAddOnCategory(category)
end

----------------------------------------------------------------------------
-- Opening
----------------------------------------------------------------------------

-- No combat gate: the settings panel isn't a protected frame on Forever
-- (Blizzard_Settings*.lua on the `forever` branch has no
-- InCombatLockdown/protected checks).
function Options.Open()
    if not category then
        ns:Print(L["OPTIONS_NOT_AVAILABLE"])
        return
    end
    Settings.OpenToCategory(category:GetID())
end

-- The registered parent category, or nil if the Settings API wasn't
-- available. WeightsEditor.lua reads this to attach its "Stat Weights" canvas
-- subcategory - loaded after Options.lua in the TOC and built from its own
-- PLAYER_LOGIN handler, which Core.lua's event dispatch runs after this
-- file's (handlers for one event run in registration order; see Core.lua
-- "Event dispatch"), so `category` is already set (or confirmed unavailable)
-- by the time WeightsEditor needs it.
function Options.GetCategory()
    return category
end

ns.slashCommands["options"] = Options.Open
ns.slashCommands["config"] = Options.Open

----------------------------------------------------------------------------
-- Addon compartment
----------------------------------------------------------------------------

-- TOC `## AddonCompartmentFunc: GearSentry_OnAddonCompartmentClick` (the dev
-- copy's TOC says GearSentryDev_..., so the name is built from addonName).
-- Receives (addonName, buttonName) - not the raw menuInputData table
-- (CallAddonGlobalFunc unwraps it before calling this global). Runs
-- insecurely (CallAddonGlobalFunc calls forceinsecure() first), which is fine
-- here: opening Settings isn't a protected action.
_G[addonName .. "_OnAddonCompartmentClick"] = function(_addonName, _buttonName)
    Options.Open()
end

-- TOC `## AddonCompartmentFuncOnEnter/OnLeave`: Forever's
-- Blizzard_Minimap/Mainline/AddonCompartment.lua calls these through the
-- same CallAddonGlobalFunc as the click, with (addonName, menuButton).
_G[addonName .. "_OnAddonCompartmentEnter"] = function(_addonName, button)
    if not (GameTooltip and button) then
        return
    end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText(ns.ADDON_TITLE .. " " .. ns.Version())
    GameTooltip:AddLine(L["COMPARTMENT_HINT"], 1, 1, 1)
    GameTooltip:Show()
end

_G[addonName .. "_OnAddonCompartmentLeave"] = function(_addonName, _button)
    if GameTooltip then
        GameTooltip:Hide()
    end
end

ns:RegisterEvent("PLAYER_LOGIN", BuildPanel)
