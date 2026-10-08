-- Locale table. enUS is the base locale and the fallback for every other
-- locale: if a future locale file is missing a key, the metatable below
-- returns the key itself rather than nil, so a forgotten translation shows
-- an ugly-but-readable string instead of a Lua error.
--
-- Every user-facing string in the addon should be a L["SOME_KEY"] lookup,
-- never a literal, so a translation only ever needs to touch this file.
local _, ns = ...

local L = setmetatable({}, {
    __index = function(_, key)
        return key
    end,
})
ns.L = L

-- Slash command help (/gs help, and shown on an unrecognised sub-command).
L["HELP_HEADER"] = "%s %s commands:" -- addon title, version (e.g. "v0.1.0" or "dev")
L["HELP_DEBUG"] = "/gs debug - toggle debug output"
L["HELP_SCAN"] = "/gs scan - scan bags for upgrades"
L["HELP_HELP"] = "/gs help - show this list"
L["UNKNOWN_COMMAND"] = "Unknown command: %s"

L["DEBUG_ON"] = "Debug output enabled."
L["DEBUG_OFF"] = "Debug output disabled."

L["SCANNER_NOT_IMPLEMENTED"] = "Scanner not implemented yet."
L["HELP_EVAL"] = "/gs eval <item link or ID> - is this item an upgrade, and why"
L["HELP_SCALE"] = "/gs profile [name|default] - show or pick this character's stat weight profile"

-- Scanner / test commands (Scanner.lua). Format args are noted per line.
L["UPGRADE_FOUND"] = "Upgrade: %s" -- suggestion line
L["NO_UPGRADES"] = "No upgrades in your bags."
L["SCAN_COUNTS"] = "Bag gear checked: %d (still loading: %d)"
L["REJECTED"] = "  skipped %s: %s" -- item link, reason
L["EQUIPPED_LOADING"] = "Equipped item data still loading (%d items). Try again in a moment."
-- class, level, scale name, scale choices, can dual wield
L["PLAYER_LINE"] = "%s level %s, profile: %s (choices: %s), can dual wield: %s"
-- weapon skills, preferred armor, spec ID
L["PLAYER_LINE2"] = "  weapon skills: %s, best armor: %s, spec: %s"
L["NONE_ILVL"] = "none (item level)"
L["YES"] = "yes"
L["NO"] = "no"

L["EVAL_USAGE"] = "Usage: /gs eval <shift-click an item, or an item ID>"
L["EVAL_LOADING"] = "Loading item data, the result will follow..."
L["EVAL_UNKNOWN"] = "Unknown item: %s"
-- link, equip location, item level, required level, usable
L["EVAL_HEADER"] = "%s  %s, ilvl %s, requires level %s, usable: %s"
L["EVAL_NOT_GEAR"] = "  Not gear this addon compares (shirt, tabard, bag, ammo...)."
L["EVAL_SCORE"] = "  score %s"
L["EVAL_EQUIPPED"] = "  %s: %s score %s" -- slot, link, score line
L["EVAL_EMPTY"] = "  %s: empty"
L["EVAL_REJECTED"] = "  => not considered: %s"
L["EVAL_NOT_UPGRADE"] = "  => not an upgrade"
L["EVAL_VERDICT"] = "  => upgrade: %s"
L["ILVL"] = "ilvl %s"

L["HELP_ARMORFILTER"] = "/gs armorfilter - toggle skipping armor below your best type (off by default)"
L["ARMOR_FILTER_ON"] = "Armor filter on: items below your best armor type are skipped."
L["ARMOR_FILTER_OFF"] = "Armor filter off: stats decide, whatever the armor type."

-- Tooltip.lua: the "Upgrade" tooltip line and its toggle command.
L["HELP_TOOLTIP"] = "/gs tooltip - toggle the upgrade line on item tooltips"
L["TOOLTIP_LINE_ON"] = "Tooltip upgrade line enabled."
L["TOOLTIP_LINE_OFF"] = "Tooltip upgrade line disabled."
L["TOOLTIP_UPGRADE"] = "%s: upgrade for %s %s" -- addon title, slot name, gain
L["TOOLTIP_NO_UPGRADE"] = "%s: no upgrade (%s)" -- addon title, reason

-- BagArrows.lua: the bag-slot arrow and its toggle command.
L["HELP_ARROWS"] = "/gs arrows - toggle the upgrade arrow on bag item buttons"
L["BAG_ARROWS_ON"] = "Bag upgrade arrows enabled."
L["BAG_ARROWS_OFF"] = "Bag upgrade arrows disabled."

-- BetterBags.lua: one-time hint telling the player to pick us in BetterBags'
-- own "Upgrade Icon Provider" dropdown. %s is ns.ADDON_TITLE, so it renames
-- itself with the addon.
L["BETTERBAGS_HINT"] = "BetterBags detected. To see upgrade arrows in your "
    .. "bags, open BetterBags' settings and pick \"%s\" in the "
    .. "\"Upgrade Icon Provider\" dropdown (General section)."

-- Alerts.lua: the toast, and its two test/debug slash commands.
L["HELP_ALERTS"] = "/gs alerts - show the current suggestions again (ignores this session's dedupe)"
L["HELP_UNIGNORE"] = "/gs unignore - clear this character's ignored items and slots"
L["ALERTS_NONE"] = "No current suggestions to show."
L["ALERTS_REOFFERED"] = "Re-showing %d suggestion(s)."
L["UNIGNORE_DONE"] = "Cleared ignored items and slots for this character."
L["ALERT_TITLE"] = "Upgrade found"
L["ALERT_COUNT"] = "%d of %d"
L["ALERT_EQUIP"] = "Equip"
L["ALERT_IGNORE"] = "Ignore"
L["EQUIP_DISABLED_NO_MODULE"] = "Equipping isn't wired up yet."
L["EQUIP_DISABLED_COMBAT"] = "Can't equip in combat. Try again once combat ends."

-- Equip.lua: click-to-equip run reporting.
L["HELP_EQUIP"] = "/gs equip - show whether an equip run is in progress"
L["EQUIP_BUSY"] = "Still carrying out the last suggestion; wait for it to finish."
L["EQUIP_REFUSED_COMBAT"] = "Can't equip in combat."
L["EQUIP_STOPPED_COMBAT"] = "Stopped equipping %s: combat started."
L["EQUIP_NOT_FOUND"] = "Stopped: %s wasn't found anymore (moved, sold, or already gone)."
L["EQUIP_TIMEOUT"] = "Stopped: %s didn't land in %s in time. If a two-hander "
    .. "needed to clear the off hand, check your bag space."
L["EQUIP_STUCK_CURSOR"] = "Stopped: the item swap into %s didn't complete."
L["EQUIP_CANCELLED"] = "Equip cancelled."
L["EQUIP_DONE"] = "Equipped."
L["EQUIP_DONE_ITEMS"] = "Equipped %s" -- item link(s), comma-separated
L["EQUIP_STATUS_BUSY"] = "Equipping: waiting on %s."
L["EQUIP_STATUS_IDLE"] = "Not equipping anything right now."

-- Options.lua: the options panel, /gs options|config, and the
-- addon-compartment entry.
L["HELP_OPTIONS"] = "/gs options - open the options panel (alias: /gs config)"
L["OPTIONS_NOT_AVAILABLE"] = "The options panel isn't available on this client."

L["OPTIONS_SECTION_ALERTS"] = "Alerts"
L["OPTIONS_TOOLTIP_LINE"] = "Tooltip upgrade line"
L["OPTIONS_TOOLTIP_LINE_DESC"] = "Show an \"Upgrade\" line on item tooltips."
L["OPTIONS_BAG_ARROWS"] = "Bag upgrade arrows"
L["OPTIONS_BAG_ARROWS_DESC"] = "Show an arrow on bag items that are upgrades."

L["OPTIONS_SECTION_UPGRADE"] = "What counts as an upgrade"
L["OPTIONS_SUGGEST_BOE"] = "Suggest Bind-on-Equip items"
L["OPTIONS_SUGGEST_BOE_DESC"] = "Include items that bind when equipped. The alert and tooltip still warn you."
L["OPTIONS_ARMOR_FILTER"] = "Only suggest my best armor type"
L["OPTIONS_ARMOR_FILTER_DESC"] = "Skip armor below your best armor type (cloth/leather/mail/plate), "
    .. "even if its stats are better."
L["OPTIONS_MIN_GAIN_PCT"] = "Minimum gain (%)"
L["OPTIONS_MIN_GAIN_PCT_DESC"] = "Don't suggest an item unless it's at least this much better, as a percentage."
L["OPTIONS_MIN_GAIN"] = "Minimum gain (score)"
L["OPTIONS_MIN_GAIN_DESC"] = "Don't suggest an item unless it's at least this much better, in absolute score."

L["OPTIONS_RESET_IGNORED"] = "Reset ignored items"
L["OPTIONS_RESET_BUTTON"] = "Reset"
L["OPTIONS_ALERT_SOUND"] = "Sound for new upgrades"
L["OPTIONS_ALERT_SOUND_DESC"] = "Play a chime when the upgrade pop-up appears."
L["OPTIONS_ALERT_AT_LOGIN"] = "Alert for upgrades already in bags at login"
L["OPTIONS_ALERT_AT_LOGIN_DESC"] = "Show the pop-up for upgrades that were already in your bags when you "
    .. "logged in or reloaded, a few seconds after you enter the world. Turn off if you keep spare gear in your bags."
L["OPTIONS_RESET_POSITION"] = "Reset pop-up position"
L["COMPARTMENT_HINT"] = "Click to open options."

L["OPTIONS_SECTION_BETTERBAGS"] = "BetterBags"
L["OPTIONS_SECTION_ADVANCED"] = "Advanced"

L["OPTIONS_DEBUG"] = "Debug output"
L["OPTIONS_DEBUG_DESC"] = "Print extra detail to chat about scans and decisions."

L["SCALE_CURRENT"] = "Stat weight profile: %s (choices: %s)"
L["SCALE_SET"] = "Stat weight profile now: %s"
L["SCALE_UNKNOWN"] = "Unknown profile '%s'. Choices: %s"

-- Profiles.lua: weight profiles
L["PROFILE_DEFAULT_NAME"] = "%s %s - Default" -- class name, scale label: "Paladin DPS - Default"
L["SCALE_LABEL_dps"] = "DPS"
L["SCALE_LABEL_tank"] = "Tank"
L["SCALE_LABEL_healer"] = "Healer"
L["SCALE_LABEL_caster"] = "Caster"
L["SCALE_LABEL_melee"] = "Melee"
L["SCALE_LABEL_feral"] = "Feral"
L["PROFILE_ERR_NAME_EMPTY"] = "Enter a name."
L["PROFILE_ERR_NAME_LONG"] = "Names can be at most 40 characters."
L["PROFILE_ERR_NAME_CHARS"] = "Names can't contain \" or :."
L["PROFILE_ERR_NAME_TAKEN"] = "That name is already used."
L["PROFILE_ERR_READONLY"] = "Default profiles are read-only. Copy it to make your own."
L["PROFILE_ERR_NOT_FOUND"] = "That profile no longer exists."
L["PROFILE_ERR_VALUE"] = "Enter a number from -100 to 100."
L["PROFILE_ERR_FIELD"] = "Unknown field."
L["PROFILE_ERR_PARSE"] = "That isn't a GearSentry profile string."
L["PROFILE_ERR_VERSION"] = "That profile string is from a newer GearSentry. Update the addon to import it."
L["PROFILE_ERR_CLASS"] = "That is a %s profile. Log in on a %s to import it." -- class name, class name

-- WeightsEditor.lua: the "Stat Weights" canvas subcategory.
L["HELP_WEIGHTS"] = "/gs weights - open the Stat Weights panel"
L["WEIGHTSEDITOR_TITLE"] = "Stat Weights"
L["WEIGHTSEDITOR_NEW"] = "New"
L["WEIGHTSEDITOR_COPY"] = "Copy"
L["WEIGHTSEDITOR_RENAME"] = "Rename"
L["WEIGHTSEDITOR_DELETE"] = "Delete"
L["WEIGHTSEDITOR_IMPORT"] = "Import"
L["WEIGHTSEDITOR_EXPORT"] = "Export"
L["WEIGHTSEDITOR_PROMPT_NEW"] = "Name for the new (empty) profile:"
L["WEIGHTSEDITOR_PROMPT_COPY"] = "Name for the copy:"
L["WEIGHTSEDITOR_PROMPT_RENAME"] = "New name for this profile:"
L["WEIGHTSEDITOR_PROMPT_IMPORT"] = "A profile with that name exists. Name for the imported profile:"
L["WEIGHTSEDITOR_APPLY"] = "Apply"
L["WEIGHTSEDITOR_ACTIVE_SUFFIX"] = "%s (active)" -- profile name in the dropdown
L["WEIGHTSEDITOR_STATUS_ACTIVE"] = "In use by this character."
L["WEIGHTSEDITOR_STATUS_PENDING"] = "Not in use by this character. Click Apply to use it."
L["WEIGHTSEDITOR_STATUS_UNSAVED"] = "|cffffd100Unsaved changes. Click Save to keep them.|r"
L["WEIGHTSEDITOR_SAVE"] = "Save"
L["WEIGHTSEDITOR_DISCARD"] = "Discard"
L["WEIGHTSEDITOR_UNSAVED"] = "You have unsaved changes to \"%s\"." -- profile name
L["PROFILE_ERR_UNSAVED"] = "Save or discard your changes first."
L["WEIGHTSEDITOR_DELETE_CONFIRM"] = "Delete profile \"%s\"?"
L["WEIGHTSEDITOR_EXPORT_TITLE"] = "Export profile"
L["WEIGHTSEDITOR_EXPORT_HINT"] = "Press Ctrl+C to copy."
L["WEIGHTSEDITOR_IMPORT_TITLE"] = "Import profile"
L["WEIGHTSEDITOR_IMPORT_HINT"] = "Paste a GearSentry profile string, then click Import."
L["WEIGHTSEDITOR_IMPORT_BUTTON"] = "Import"

-- Group headers (Profiles.CATALOG group names).
L["WEIGHTSEDITOR_GROUP_PRIMARY"] = "Primary Stats"
L["WEIGHTSEDITOR_GROUP_PHYSICAL"] = "Physical"
L["WEIGHTSEDITOR_GROUP_SPELL"] = "Spell"
L["WEIGHTSEDITOR_GROUP_DEFENSE"] = "Defense"
L["WEIGHTSEDITOR_GROUP_ITEM"] = "Item"
L["WEIGHTSEDITOR_GROUP_RULES"] = "Rules"
L["WEIGHTSEDITOR_GROUP_OTHER"] = "Other"

-- Field rows (Profiles.FIELDS). Each has a label and a tooltip ("_DESC").
L["WEIGHTSEDITOR_FIELD_ARMOR"] = "Armor"
L["WEIGHTSEDITOR_FIELD_ARMOR_DESC"] = "Weight per point of armor."
L["WEIGHTSEDITOR_FIELD_DPS"] = "Main-hand / Two-hand DPS"
L["WEIGHTSEDITOR_FIELD_DPS_DESC"] =
    "Weight per point of weapon DPS: main-hand for dual-wield, or the only weapon for a two-hander."
L["WEIGHTSEDITOR_FIELD_OFFHANDDPS"] = "Off-hand DPS"
L["WEIGHTSEDITOR_FIELD_OFFHANDDPS_DESC"] = "Weight per point of off-hand weapon DPS (dual-wield only)."
L["WEIGHTSEDITOR_FIELD_RANGEDDPS"] = "Ranged DPS"
L["WEIGHTSEDITOR_FIELD_RANGEDDPS_DESC"] = "Weight per point of ranged weapon DPS."
L["WEIGHTSEDITOR_FIELD_WEAPONSKILL"] = "Weapon Skill"
L["WEIGHTSEDITOR_FIELD_WEAPONSKILL_DESC"] = "Weight per point of weapon skill."
L["WEIGHTSEDITOR_FIELD_SITUATIONAL"] = "Situational Multiplier"
L["WEIGHTSEDITOR_FIELD_SITUATIONAL_DESC"] =
    "Multiplier applied to stats that only help against certain creature types."
L["WEIGHTSEDITOR_FIELD_RESISTANCE"] = "Resistance"
L["WEIGHTSEDITOR_FIELD_RESISTANCE_DESC"] =
    "Weight per point of resistance, for the spell schools checked below."

L["WEIGHTSEDITOR_STAT_DESC"] = "Weight per point of %s."
L["WEIGHTSEDITOR_OTHER_DESC"] = "A stat from an imported profile that isn't in this panel's catalog."

-- Report.lua
L["EQUIP_TO"] = "%s to %s" -- item, slot
L["MOVE_TO"] = "move %s to %s"
L["REPLACES"] = "replacing %s"
L["BY_ITEM_LEVEL"] = "by item level"
L["FLAG_BOE"] = "binds when equipped"
L["FLAG_SPECIAL"] = "has a special effect (not scored)"
L["UNSCORED"] = "unscored: %s"
L["STAT_ARMOR"] = "Armor"
L["STAT_DPS"] = "DPS"

L["ARMOR_1"] = "Cloth"
L["ARMOR_2"] = "Leather"
L["ARMOR_3"] = "Mail"
L["ARMOR_4"] = "Plate"

-- Inventory slot names by INVSLOT_* number
-- (https://warcraft.wiki.gg/wiki/InventorySlotId).
L["SLOT_1"] = "Head"
L["SLOT_2"] = "Neck"
L["SLOT_3"] = "Shoulder"
L["SLOT_4"] = "Shirt"
L["SLOT_5"] = "Chest"
L["SLOT_6"] = "Waist"
L["SLOT_7"] = "Legs"
L["SLOT_8"] = "Feet"
L["SLOT_9"] = "Wrist"
L["SLOT_10"] = "Hands"
L["SLOT_11"] = "Ring 1"
L["SLOT_12"] = "Ring 2"
L["SLOT_13"] = "Trinket 1"
L["SLOT_14"] = "Trinket 2"
L["SLOT_15"] = "Back"
L["SLOT_16"] = "Main Hand"
L["SLOT_17"] = "Off Hand"
L["SLOT_18"] = "Ranged"
L["SLOT_19"] = "Tabard"
