-- Core.lua: namespace, event dispatch, SavedVariables defaults/migration,
-- debug/print helpers, and the /gs slash command.
local addonName, ns = ...

-- The SavedVariables global follows the folder name: GearSentryDB here, and
-- GearSentryDevDB in a development copy (its TOC declares that name). Code
-- reaches it through ns.DB(), never by name.
ns.DB_NAME = addonName .. "DB"

-- Every display string that should rename itself if the addon is ever renamed
-- goes through this one constant, never a literal.
ns.ADDON_TITLE = "GearSentry"

local L = ns.L

-- Current SavedVariables schema version. Bump this and add a migration step
-- in MIGRATIONS (below) whenever the shape of GearSentryDB changes.
local CURRENT_VERSION = 2

-- Ordered migration steps, keyed by the version a save is currently *at*.
-- MIGRATIONS[1] upgrades a version-1 db to version 2, and so on. Defaults
-- only fill missing keys and never clobber user values.
local MIGRATIONS = {
    -- v0.1.0 -> weight profiles: a per-character scale name becomes a
    -- default-profile id, and the never-written settings.weightOverrides goes
    -- away.
    [1] = function(db)
        for _, char in pairs(type(db.chars) == "table" and db.chars or {}) do
            if type(char) == "table" and type(char.scale) == "string" then
                char.profile = "default:" .. char.scale
                char.scale = nil
            end
        end
        if type(db.settings) == "table" then
            db.settings.weightOverrides = nil
        end
        db.version = 2
    end,
}

----------------------------------------------------------------------------
-- Event dispatch
----------------------------------------------------------------------------

-- One shared frame for every event this addon cares about. Other modules
-- call ns:RegisterEvent(event, handler) instead of creating their own
-- frames, so there's a single OnEvent dispatch point to reason about.
local eventFrame = CreateFrame("Frame")
local handlers = {} -- event -> { handler, handler, ... }

function ns:RegisterEvent(event, handler)
    if not handlers[event] then
        handlers[event] = {}
        eventFrame:RegisterEvent(event)
    end
    table.insert(handlers[event], handler)
end

eventFrame:SetScript("OnEvent", function(_self, event, ...)
    local list = handlers[event]
    if not list then
        return
    end
    for _, handler in ipairs(list) do
        handler(event, ...)
    end
end)

----------------------------------------------------------------------------
-- Print / debug helpers
----------------------------------------------------------------------------

function ns:Print(...)
    print("|cff33ff99[" .. ns.ADDON_TITLE .. "]|r", ...)
end

-- Only prints when settings.debug is true. Safe to call before
-- GearSentryDB exists (e.g. from code paths that race ADDON_LOADED);
-- it just stays silent until defaults are applied.
function ns:Debug(...)
    local db = ns.DB()
    if db and db.settings and db.settings.debug then
        print("|cff888888[" .. ns.ADDON_TITLE .. " debug]|r", ...)
    end
end

----------------------------------------------------------------------------
-- SavedVariables: defaults, migration, per-character table
----------------------------------------------------------------------------

-- Fills in `defaults` wherever `t` is missing a key, recursing into nested
-- tables. Never overwrites a key the user already set, including a value
-- explicitly set to `false`. Recursive because `settings` and `chars` both
-- need it.
local function ApplyDefaults(t, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(t[key]) ~= "table" then
                t[key] = {}
            end
            ApplyDefaults(t[key], value)
        elseif t[key] == nil then
            t[key] = value
        end
    end
end

local DEFAULT_SETTINGS = {
    debug = false,
    -- Stats decide, even if that means a lower armor type. `/gs armorfilter`
    -- (or the options panel) turns the "never below my best armor type"
    -- filter on.
    allowLowerArmor = true,
    -- The "Upgrade" tooltip line is on by default; `/gs tooltip` toggles it.
    tooltipLine = true,
    -- The bag-slot arrow is on by default; `/gs arrows` toggles it.
    bagArrows = true,
    -- The pop-up itself can't be turned off (it's the core feature), only its
    -- chime.
    alertSound = true,
    -- Upgrades already in the bags at login/reload get a pop-up once the
    -- quiet window ends. Off: they're never shown as a pop-up.
    alertAtLogin = true,
    -- Whether the one-time "pick GearSentry in BetterBags' Upgrade Icon
    -- Provider dropdown" chat hint has already been shown this account.
    betterBagsHintShown = false,
    -- The following three must match Evaluator.DEFAULTS exactly, so the
    -- options panel has a real settings[key] to read and write. Suggest Bind
    -- on Equip items by default (with a warning).
    suggestBoE = true,
    -- Minimum absolute score gain required to suggest an item (scores are
    -- weight x stat, primary stats ~= 1 per point).
    minGain = 0,
    -- Minimum percentage gain required to suggest an item.
    minGainPct = 2,
}

-- Defaults for one character's entry in db.chars["Name-Realm"]. Per-character
-- because ignored items/slots are tied to that character's gear and GUIDs.
local DEFAULT_CHAR = {
    ignoredItems = {},
    ignoredSlots = {},
}

-- Runs every ordered migration from db.version up to CURRENT_VERSION, then
-- stamps the new version. Each step is responsible for leaving the db in a
-- shape the *next* step (or ApplyDefaults, if there are no more steps)
-- expects.
local function RunMigrations(db)
    while db.version < CURRENT_VERSION do
        local step = MIGRATIONS[db.version]
        if not step then
            -- No migration registered for this version: nothing we know how
            -- to do, so stop rather than loop forever. This shouldn't
            -- happen in practice (CURRENT_VERSION and MIGRATIONS are
            -- maintained together), but fail safe instead of hanging.
            break
        end
        step(db)
    end
end

-- The account-wide SavedVariables table (global ns.DB_NAME), or nil before
-- ADDON_LOADED.
function ns.DB()
    return _G[ns.DB_NAME]
end

-- Applies defaults/migrations to the account-wide SavedVariables table. Safe
-- to call only after ADDON_LOADED for this addon (that's the earliest point
-- the saved global is populated).
local function InitializeDB()
    if _G[ns.DB_NAME] == nil then
        _G[ns.DB_NAME] = {}
    end
    local db = _G[ns.DB_NAME]

    if db.version == nil then
        db.version = CURRENT_VERSION
    end
    RunMigrations(db)

    if type(db.settings) ~= "table" then
        db.settings = {}
    end
    ApplyDefaults(db.settings, DEFAULT_SETTINGS)

    if type(db.chars) ~= "table" then
        db.chars = {}
    end
    -- User weight profiles, [classFile][name] = scale (Profiles.lua).
    if type(db.profiles) ~= "table" then
        db.profiles = {}
    end
end

-- "Name-Realm" key for db.chars. Player name and realm aren't reliably
-- available at ADDON_LOADED time: the Forever 1.60.1 beta had a bug (fixed by
-- build 70170) where UnitName("player") returned "Unknown", nil before
-- PLAYER_LOGIN. To be safe on any build, this is only ever called from a
-- PLAYER_LOGIN (or later) handler, never from ADDON_LOADED.
local function CurrentCharKey()
    local name = UnitName("player")
    -- GetNormalizedRealmName strips spaces/punctuation from the realm name,
    -- unlike GetRealmName, so connected-realm names stay a stable,
    -- collision-free key. It's typed string? and can be nil during loading
    -- screens (https://warcraft.wiki.gg/wiki/API_GetNormalizedRealmName), so
    -- fall back to GetRealmName() with the same characters stripped rather
    -- than erroring.
    local realm = GetNormalizedRealmName()
    if not realm then
        realm = (GetRealmName() or ""):gsub("[%s%-%.]", "")
    end
    return (name or "Unknown") .. "-" .. realm
end

-- Ensures db.chars[CurrentCharKey()] exists with defaults filled in. Called
-- from PLAYER_LOGIN, once player identity is reliable.
local function EnsureCharEntry()
    local db = ns.DB()
    local key = CurrentCharKey()
    if type(db.chars[key]) ~= "table" then
        db.chars[key] = {}
    end
    ApplyDefaults(db.chars[key], DEFAULT_CHAR)
    -- Profiles.Rename/Delete only touch characters of the profile's class
    -- (profiles are per class), so each entry records its class.
    local _, classFile = UnitClass("player")
    db.chars[key].classFile = classFile
    ns.charKey = key
    return db.chars[key]
end

ns:RegisterEvent("ADDON_LOADED", function(_event, loadedAddonName)
    if loadedAddonName ~= addonName then
        return
    end
    -- Deliberately stays registered: other modules may hook ADDON_LOADED
    -- through ns:RegisterEvent (e.g. to wait for a load-on-demand Blizzard
    -- addon), and unregistering here would silently drop their handlers.
    InitializeDB()
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
    EnsureCharEntry()
    ns:Debug("Initialized character entry for", ns.charKey)
end)

----------------------------------------------------------------------------
-- Settings: one write path
----------------------------------------------------------------------------

-- key -> { fn, fn, ... }. Other modules call ns.OnSettingChanged(key, fn)
-- to react to a setting changing, without Core needing to know they exist
-- (Scanner reacts to allowLowerArmor/suggestBoE/minGain/minGainPct by
-- rescanning; BagArrows and BetterBags react to bagArrows; Options reacts
-- to every key it put on the panel, to call Settings.NotifyUpdate so an
-- open panel shows a value a slash command just changed).
local settingListeners = {}

function ns.OnSettingChanged(key, fn)
    if not settingListeners[key] then
        settingListeners[key] = {}
    end
    table.insert(settingListeners[key], fn)
end

-- The only place GearSentryDB.settings[key] is written, besides
-- ApplyDefaults filling in a missing key. Both the slash commands below and
-- Options.lua's Settings.RegisterProxySetting setters call this, so the
-- panel and the slash commands can never drift out of sync with each
-- other's side effects. Listeners only run when the value actually
-- changes (so e.g. re-picking the same slider position doesn't re-trigger
-- a rescan).
function ns.SetSetting(key, value)
    local settings = ns.DB().settings
    if settings[key] == value then
        return
    end
    settings[key] = value
    local list = settingListeners[key]
    if list then
        for _, fn in ipairs(list) do
            fn(value)
        end
    end
end

----------------------------------------------------------------------------
-- Slash command: /gs, /gearsentry
----------------------------------------------------------------------------

-- Small dispatch table keyed by sub-command, so later modules (Scanner,
-- Options, ...) can add their own entries without touching this file:
--   ns.slashCommands["foo"] = function(rest) ... end
ns.slashCommands = {}

-- Every toggle below writes through ns.SetSetting, then prints its chat line.
-- Any side effect beyond the chat line (rescanning, repainting bag arrows,
-- nudging BetterBags) lives in a listener registered by the module that owns
-- it (Scanner.lua, BagArrows.lua, BetterBags.lua), via ns.OnSettingChanged.
-- That keeps the slash command and the options panel's proxy setting
-- (Options.lua) sharing one path instead of each re-implementing the side
-- effect.
ns.slashCommands["debug"] = function()
    local settings = ns.DB().settings
    ns.SetSetting("debug", not settings.debug)
    if settings.debug then
        ns:Print(L["DEBUG_ON"])
    else
        ns:Print(L["DEBUG_OFF"])
    end
end

ns.slashCommands["armorfilter"] = function()
    local settings = ns.DB().settings
    ns.SetSetting("allowLowerArmor", not settings.allowLowerArmor)
    if settings.allowLowerArmor then
        ns:Print(L["ARMOR_FILTER_OFF"])
    else
        ns:Print(L["ARMOR_FILTER_ON"])
    end
end

-- Toggles the "Upgrade" line Tooltip.lua adds to item tooltips. No listener
-- needed - the line is computed fresh from Scanner.last on every hover.
ns.slashCommands["tooltip"] = function()
    local settings = ns.DB().settings
    ns.SetSetting("tooltipLine", not settings.tooltipLine)
    if settings.tooltipLine then
        ns:Print(L["TOOLTIP_LINE_ON"])
    else
        ns:Print(L["TOOLTIP_LINE_OFF"])
    end
end

-- Toggles the arrow BagArrows.lua draws on Blizzard bag item buttons.
-- BagArrows.lua and BetterBags.lua each register an
-- ns.OnSettingChanged("bagArrows", ...) listener to repaint/hide/refresh
-- right away, rather than waiting for the next scan, since toggling the
-- setting doesn't change what's an upgrade - only whether it's drawn.
ns.slashCommands["arrows"] = function()
    local settings = ns.DB().settings
    ns.SetSetting("bagArrows", not settings.bagArrows)
    if settings.bagArrows then
        ns:Print(L["BAG_ARROWS_ON"])
    else
        ns:Print(L["BAG_ARROWS_OFF"])
    end
end

ns.slashCommands["scan"] = function()
    if ns.Scanner and ns.Scanner.ScanNow then
        ns.Scanner.ScanNow()
    else
        ns:Print(L["SCANNER_NOT_IMPLEMENTED"])
    end
end

-- The packaged TOC carries the git tag (the packager replaces
-- v0.3.1); an unpackaged development copy still has the
-- placeholder, so call that "dev" instead of printing the raw token.
function ns.Version()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata
    local version = get and get(addonName, "Version")
    if not version or version:find("@", 1, true) then
        return "dev"
    end
    return version
end

-- Help lines in display order. A module that adds a slash command can append
-- its locale key (before HELP_HELP, which stays last):
--   table.insert(ns.helpLines, #ns.helpLines, "HELP_FOO")
-- The existing commands are listed here so the order stays the one players know.
ns.helpLines = {
    "HELP_DEBUG",
    "HELP_SCAN",
    "HELP_EVAL",
    "HELP_SCALE",
    "HELP_ARMORFILTER",
    "HELP_TOOLTIP",
    "HELP_ARROWS",
    "HELP_ALERTS",
    "HELP_UNIGNORE",
    "HELP_EQUIP",
    "HELP_OPTIONS",
    "HELP_WEIGHTS",
    "HELP_HELP",
}

local function PrintHelp()
    ns:Print(L["HELP_HEADER"]:format(ns.ADDON_TITLE, ns.Version()))
    for _, key in ipairs(ns.helpLines) do
        print(L[key])
    end
end

ns.slashCommands["help"] = PrintHelp

local function HandleSlashCommand(msg)
    -- First whitespace-separated word is the sub-command; everything after
    -- it is passed through as `rest` for sub-commands that take arguments.
    local command, rest = msg:match("^(%S*)%s*(.-)$")
    command = (command or ""):lower()

    if command == "" then
        PrintHelp()
        return
    end

    local handler = ns.slashCommands[command]
    if handler then
        handler(rest)
    else
        ns:Print(L["UNKNOWN_COMMAND"]:format(command))
        PrintHelp()
    end
end

SLASH_GEARSENTRY1 = "/gs"
SLASH_GEARSENTRY2 = "/gearsentry"
SlashCmdList["GEARSENTRY"] = HandleSlashCommand
