-- Profiles.lua: named stat-weight profiles. Default profiles are generated
-- from Weights.presets and are read-only; user profiles are full copies
-- stored account-wide in GearSentryDB.profiles[classFile][name]. Pure Lua:
-- every function takes the db table as an argument and makes no WoW API
-- calls, so it can be tested outside the game.
--
-- Every mutator returns `ok, result`: on failure `result` is an ns.L key
-- (PROFILE_ERR_*), so the editor and the slash commands show the same
-- messages. Profile ids are "default:<scale>" or "user:<name>".
local _, ns = ...

local Weights = ns.Weights
local Profiles = {}
ns.Profiles = Profiles

local DEFAULT_PREFIX = "default:"
local USER_PREFIX = "user:"
local MAX_NAME = 40
local MIN_VALUE, MAX_VALUE = -100, 100
local SHARE_TAG = "GearSentry"
local SHARE_VERSION = "1"

-- Spell schools a profile can tick. PHYSICAL is left out on purpose: its
-- school-damage stat is always worth 0.
Profiles.SCHOOLS = { "HOLY", "FIRE", "NATURE", "FROST", "SHADOW", "ARCANE" }

-- The numeric scale fields besides `stats`.
Profiles.FIELDS = { "armor", "dps", "offhandDps", "rangedDps", "weaponSkill", "situational", "resistance" }
local IS_FIELD = {}
for _, f in ipairs(Profiles.FIELDS) do
    IS_FIELD[f] = true
end
local IS_SCHOOL = {}
for _, s in ipairs(Profiles.SCHOOLS) do
    IS_SCHOOL[s] = true
end

local function K(short)
    return "ITEM_MOD_" .. short .. "_SHORT"
end

-- Editor layout. Stat keys are the exact C_Item.GetItemStats keys on Forever;
-- the UI labels them with the client's own _G[key] strings.
Profiles.CATALOG = {
    { group = "PRIMARY", stats = { K("STRENGTH"), K("AGILITY"), K("STAMINA"), K("INTELLECT"), K("SPIRIT") } },
    { group = "PHYSICAL", stats = { K("ATTACK_POWER"), K("RANGED_ATTACK_POWER"), K("HIT_RATING"),
        K("CRIT_RATING"), K("HASTE_RATING"), K("EXPERTISE_RATING") } },
    { group = "SPELL", stats = { K("SPELL_POWER"), K("SPELL_DAMAGE_DONE"), K("SPELL_HEALING_DONE"),
        K("SPELL_PENETRATION"), K("MANA_REGENERATION") } },
    { group = "DEFENSE", stats = { K("DEFENSE_SKILL_RATING"), K("DODGE_RATING"), K("PARRY_RATING"),
        K("BLOCK_RATING"), K("BLOCK_VALUE"), K("EXTRA_ARMOR"), K("HEALTH"), K("HEALTH_REGEN") } },
    { group = "ITEM", fields = { "armor", "dps", "offhandDps", "rangedDps", "weaponSkill" } },
    { group = "RULES", fields = { "situational", "resistance" }, schools = true },
}

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do
        out[k] = v
    end
    return out
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Rounds to 3 decimals, symmetric for negatives.
local function round3(v)
    if v < 0 then
        return -math.floor(-v * 1000 + 0.5) / 1000
    end
    return math.floor(v * 1000 + 0.5) / 1000
end

-- Shortest decimal for a rounded value: 1, 0.6, 0.002, -0.25.
local function formatNumber(v)
    local s = string.format("%.3f", round3(v)):gsub("0+$", ""):gsub("%.$", "")
    if s == "-0" then
        s = "0"
    end
    return s
end
Profiles.FormatNumber = formatNumber

-- Parses a user-typed value. Empty means 0. Returns the rounded number, or
-- nil for anything non-numeric, NaN/inf, or outside -100..100.
function Profiles.ParseValue(text)
    text = trim(tostring(text or ""))
    if text == "" then
        return 0
    end
    local v = tonumber(text)
    if not v or v ~= v or v < MIN_VALUE or v > MAX_VALUE then
        return nil
    end
    return round3(v)
end

local function userTable(db, classFile, create)
    if create then
        db.profiles = db.profiles or {}
        db.profiles[classFile] = db.profiles[classFile] or {}
    end
    return db.profiles and db.profiles[classFile]
end

-- Finds the stored key of a user profile, case-insensitively.
local function findUserName(db, classFile, name)
    local profiles = userTable(db, classFile)
    if not profiles then
        return nil
    end
    local lower = name:lower()
    for stored in pairs(profiles) do
        if stored:lower() == lower then
            return stored
        end
    end
end

local function splitId(id)
    if type(id) ~= "string" then
        return nil
    end
    if id:sub(1, #DEFAULT_PREFIX) == DEFAULT_PREFIX then
        return "default", id:sub(#DEFAULT_PREFIX + 1)
    end
    if id:sub(1, #USER_PREFIX) == USER_PREFIX then
        return "user", id:sub(#USER_PREFIX + 1)
    end
end

function Profiles.IsDefault(id)
    return (splitId(id)) == "default"
end

function Profiles.DefaultId(scaleName)
    return DEFAULT_PREFIX .. scaleName
end

function Profiles.UserId(name)
    return USER_PREFIX .. name
end

----------------------------------------------------------------------------
-- Names
----------------------------------------------------------------------------

-- ns.ClassName (Player.lua) gives the client's localized class name; offline
-- it's absent and the class file is capitalised instead.
local function className(classFile)
    local name = ns.ClassName and ns.ClassName(classFile)
    if name then
        return name
    end
    return classFile:sub(1, 1) .. classFile:sub(2):lower()
end

local function scaleLabel(scaleName)
    local L = ns.L
    local key = "SCALE_LABEL_" .. scaleName
    local label = L and rawget(L, key)
    if label then
        return label
    end
    return scaleName:sub(1, 1):upper() .. scaleName:sub(2)
end

-- "Paladin DPS - Default"
function Profiles.DefaultName(classFile, scaleName)
    local fmt = ns.L and rawget(ns.L, "PROFILE_DEFAULT_NAME") or "%s %s - Default"
    return fmt:format(className(classFile), scaleLabel(scaleName))
end

-- Checks a proposed user profile name. `except` is the profile's current
-- name when renaming (so changing only its case is allowed).
-- Returns ok, errKey-or-trimmed-name.
function Profiles.ValidateName(db, classFile, name, except)
    name = trim(tostring(name or ""))
    if name == "" then
        return false, "PROFILE_ERR_NAME_EMPTY"
    end
    if #name > MAX_NAME then
        return false, "PROFILE_ERR_NAME_LONG"
    end
    -- '"' and ':' delimit the share string; "default" is /gs profile's
    -- keyword for "back to the class default".
    if name:find('[":]') or name:find("[%c]") then
        return false, "PROFILE_ERR_NAME_CHARS"
    end
    local lower = name:lower()
    if lower == "default" then
        return false, "PROFILE_ERR_NAME_TAKEN"
    end
    local preset = Weights.presets[classFile]
    if preset then
        for scaleName in pairs(preset.scales) do
            if Profiles.DefaultName(classFile, scaleName):lower() == lower then
                return false, "PROFILE_ERR_NAME_TAKEN"
            end
        end
    end
    local existing = findUserName(db, classFile, name)
    if existing and not (except and existing:lower() == except:lower()) then
        return false, "PROFILE_ERR_NAME_TAKEN"
    end
    return true, name
end

-- "<name> (2)", "(3)", … — the first that validates. For import clashes.
function Profiles.SuggestName(db, classFile, name)
    name = trim(tostring(name or ""))
    if Profiles.ValidateName(db, classFile, name) then
        return name
    end
    for n = 2, 99 do
        local suffix = " (" .. n .. ")"
        local candidate = name:sub(1, MAX_NAME - #suffix) .. suffix
        if Profiles.ValidateName(db, classFile, candidate) then
            return candidate
        end
    end
    return ""
end

----------------------------------------------------------------------------
-- Reading
----------------------------------------------------------------------------

-- Default profiles in preset order: the class default first, the rest
-- sorted (Weights.ScaleNames is sorted).
local function defaultScaleNames(classFile)
    local preset = Weights.presets[classFile]
    if not preset then
        return {}
    end
    local names = { preset.default }
    for _, name in ipairs(Weights.ScaleNames(classFile)) do
        if name ~= preset.default then
            names[#names + 1] = name
        end
    end
    return names
end

-- Every profile this class can use: { id, name, isDefault }, defaults first.
function Profiles.List(db, classFile)
    local list = {}
    for _, scaleName in ipairs(defaultScaleNames(classFile)) do
        list[#list + 1] = {
            id = Profiles.DefaultId(scaleName),
            name = Profiles.DefaultName(classFile, scaleName),
            isDefault = true,
            scaleName = scaleName,
        }
    end
    local users = {}
    for name in pairs(userTable(db, classFile) or {}) do
        users[#users + 1] = name
    end
    table.sort(users, function(a, b)
        return a:lower() < b:lower()
    end)
    for _, name in ipairs(users) do
        list[#list + 1] = { id = Profiles.UserId(name), name = name, isDefault = false }
    end
    return list
end

-- Fills the scale fields a stored profile might lack, so a hand-edited or
-- older SavedVariables entry still resolves to a complete scale.
local function complete(stored)
    local scale = copy(Weights.SCALE_DEFAULTS)
    for _, f in ipairs(Profiles.FIELDS) do
        if type(stored[f]) == "number" then
            scale[f] = stored[f]
        end
    end
    scale.stats = copy(stored.stats)
    scale.schools = copy(stored.schools)
    return scale
end

-- The full scale for a profile id (a fresh copy), with `name` = display
-- name and `id`. Nil if the id doesn't exist for this class.
function Profiles.Get(db, classFile, id)
    local kind, rest = splitId(id)
    if kind == "default" then
        local preset = Weights.presets[classFile]
        if not (preset and preset.scales[rest]) then
            return nil
        end
        local scale = Weights.Resolve(classFile, rest)
        scale.name = Profiles.DefaultName(classFile, rest)
        scale.id = id
        scale.isDefault = true
        return scale
    elseif kind == "user" then
        local stored = userTable(db, classFile) and userTable(db, classFile)[rest]
        if type(stored) ~= "table" then
            return nil
        end
        local scale = complete(stored)
        scale.name = rest
        scale.id = id
        scale.isDefault = false
        return scale
    end
end

-- The id a nil/unknown choice falls back to: the class's default scale.
function Profiles.FallbackId(classFile)
    local preset = Weights.presets[classFile]
    return preset and Profiles.DefaultId(preset.default) or nil
end

-- True when two resolved scales would score every item the same: same
-- fields, stats and schools (names and ids are ignored). Scanner uses it to
-- tell whether the panel's working copy has unsaved edits.
function Profiles.Equal(a, b)
    if a == nil or b == nil then
        return a == b
    end
    for _, f in ipairs(Profiles.FIELDS) do
        if a[f] ~= b[f] then
            return false
        end
    end
    for _, key in ipairs({ "stats", "schools" }) do
        local ta, tb = a[key] or {}, b[key] or {}
        for k, v in pairs(ta) do
            if tb[k] ~= v then
                return false
            end
        end
        for k, v in pairs(tb) do
            if ta[k] ~= v then
                return false
            end
        end
    end
    return true
end

-- Like Get, but an unknown or nil id falls back to the class default.
-- Nil only when the class has no preset and `id` isn't a user profile
-- (the Evaluator then falls back to item level).
function Profiles.Resolve(db, classFile, id)
    return Profiles.Get(db, classFile, id)
        or Profiles.Get(db, classFile, Profiles.FallbackId(classFile))
end

-- Matches what a user typed after /gs profile: a profile name
-- (case-insensitive) or a default's short scale name ("tank").
function Profiles.Find(db, classFile, text)
    text = trim(tostring(text or "")):lower()
    for _, entry in ipairs(Profiles.List(db, classFile)) do
        if entry.name:lower() == text or (entry.scaleName and entry.scaleName == text) then
            return entry.id
        end
    end
end

----------------------------------------------------------------------------
-- Writing
----------------------------------------------------------------------------

-- Characters store their choice as chars[key].profile plus the class they
-- were when they chose it (chars[key].classFile), so renaming PALADIN's
-- "Ret" never touches a MAGE's own "Ret".
local function eachCharOfClass(db, classFile, fn)
    for _, char in pairs(db.chars or {}) do
        if type(char) == "table" and char.classFile == classFile then
            fn(char)
        end
    end
end

local function blankScale()
    local scale = complete({})
    -- complete() starts from SCALE_DEFAULTS; "from scratch" means every
    -- weight is 0 except the two rule multipliers.
    for _, f in ipairs(Profiles.FIELDS) do
        if f ~= "situational" and f ~= "resistance" then
            scale[f] = 0
        end
    end
    return scale
end

local function storable(scale)
    local out = { stats = copy(scale.stats), schools = copy(scale.schools) }
    for _, f in ipairs(Profiles.FIELDS) do
        out[f] = scale[f]
    end
    return out
end

-- New user profile, blank when fromId is nil, else a copy of fromId.
-- Returns ok, newId-or-errKey.
function Profiles.Create(db, classFile, name, fromId)
    local ok, result = Profiles.ValidateName(db, classFile, name)
    if not ok then
        return false, result
    end
    local scale
    if fromId then
        scale = Profiles.Get(db, classFile, fromId)
        if not scale then
            return false, "PROFILE_ERR_NOT_FOUND"
        end
    else
        scale = blankScale()
    end
    userTable(db, classFile, true)[result] = storable(scale)
    return true, Profiles.UserId(result)
end

local function userEntry(db, classFile, id)
    local kind, name = splitId(id)
    if kind == "default" then
        return nil, "PROFILE_ERR_READONLY"
    end
    local profiles = userTable(db, classFile)
    if kind ~= "user" or not (profiles and type(profiles[name]) == "table") then
        return nil, "PROFILE_ERR_NOT_FOUND"
    end
    return profiles[name], name
end

function Profiles.Rename(db, classFile, id, newName)
    local stored, oldName = userEntry(db, classFile, id)
    if not stored then
        return false, oldName
    end
    local ok, result = Profiles.ValidateName(db, classFile, newName, oldName)
    if not ok then
        return false, result
    end
    local profiles = userTable(db, classFile)
    profiles[oldName] = nil
    profiles[result] = stored
    local newId = Profiles.UserId(result)
    eachCharOfClass(db, classFile, function(char)
        if char.profile == id then
            char.profile = newId
        end
    end)
    return true, newId
end

function Profiles.Delete(db, classFile, id)
    local stored, name = userEntry(db, classFile, id)
    if not stored then
        return false, name
    end
    userTable(db, classFile)[name] = nil
    eachCharOfClass(db, classFile, function(char)
        if char.profile == id then
            char.profile = nil
        end
    end)
    return true
end

-- value: a number (rounded here) or anything ParseValue accepts.
local function checkValue(value)
    if type(value) ~= "number" then
        return Profiles.ParseValue(value)
    end
    if value ~= value or value < MIN_VALUE or value > MAX_VALUE then
        return nil
    end
    return round3(value)
end

-- The *In variants edit a scale table directly (the Stat Weights panel's
-- unsaved working copy until Save); the db variants below write a saved user
-- profile through them, so both paths apply the same value rules.
function Profiles.SetStatIn(scale, key, value)
    local v = checkValue(value)
    if not v then
        return false, "PROFILE_ERR_VALUE"
    end
    scale.stats = scale.stats or {}
    -- 0 removes the key, so the profile (and its export) lists only the
    -- stats that matter.
    scale.stats[key] = (v ~= 0) and v or nil
    return true
end

function Profiles.SetFieldIn(scale, field, value)
    if not IS_FIELD[field] then
        return false, "PROFILE_ERR_FIELD"
    end
    local v = checkValue(value)
    if not v then
        return false, "PROFILE_ERR_VALUE"
    end
    scale[field] = v
    return true
end

function Profiles.SetSchoolIn(scale, school, on)
    if not IS_SCHOOL[school] then
        return false, "PROFILE_ERR_FIELD"
    end
    scale.schools = scale.schools or {}
    scale.schools[school] = on and true or nil
    return true
end

function Profiles.SetStat(db, classFile, id, key, value)
    local stored, err = userEntry(db, classFile, id)
    if not stored then
        return false, err
    end
    return Profiles.SetStatIn(stored, key, value)
end

function Profiles.SetField(db, classFile, id, field, value)
    if not IS_FIELD[field] then
        return false, "PROFILE_ERR_FIELD"
    end
    local stored, err = userEntry(db, classFile, id)
    if not stored then
        return false, err
    end
    return Profiles.SetFieldIn(stored, field, value)
end

function Profiles.SetSchool(db, classFile, id, school, on)
    if not IS_SCHOOL[school] then
        return false, "PROFILE_ERR_FIELD"
    end
    local stored, err = userEntry(db, classFile, id)
    if not stored then
        return false, err
    end
    return Profiles.SetSchoolIn(stored, school, on)
end

-- Replaces a user profile's saved values with `scale` (a working copy the
-- user confirmed with Save). Default profiles are refused.
function Profiles.Save(db, classFile, id, scale)
    local stored, name = userEntry(db, classFile, id)
    if not stored then
        return false, name
    end
    userTable(db, classFile)[name] = storable(scale)
    return true
end

----------------------------------------------------------------------------
-- Share string (format version 1)
--   GearSentry:1:PALADIN:My Ret:STRENGTH=1,AGILITY=0.6,armor=0.01,schools=HOLY+FIRE
----------------------------------------------------------------------------

function Profiles.Export(db, classFile, id)
    local scale = Profiles.Get(db, classFile, id)
    if not scale then
        return nil
    end
    local parts = {}
    local statKeys = {}
    for key, v in pairs(scale.stats) do
        local short = key:match("^ITEM_MOD_(.+)_SHORT$")
        if short and v ~= 0 then
            statKeys[#statKeys + 1] = short
        end
    end
    table.sort(statKeys)
    for _, short in ipairs(statKeys) do
        parts[#parts + 1] = short .. "=" .. formatNumber(scale.stats[K(short)])
    end
    for _, f in ipairs(Profiles.FIELDS) do
        if scale[f] and scale[f] ~= 0 then
            parts[#parts + 1] = f .. "=" .. formatNumber(scale[f])
        end
    end
    local schools = {}
    for _, s in ipairs(Profiles.SCHOOLS) do
        if scale.schools[s] then
            schools[#schools + 1] = s
        end
    end
    if #schools > 0 then
        parts[#parts + 1] = "schools=" .. table.concat(schools, "+")
    end
    return table.concat({ SHARE_TAG, SHARE_VERSION, classFile, scale.name, table.concat(parts, ",") }, ":")
end

-- Returns { classFile, name, scale } or nil, errKey. Doesn't touch the db.
-- A field missing from the string is 0 (that's how Export omits it), so an
-- imported profile is exactly what was exported.
function Profiles.Parse(text)
    text = trim(tostring(text or ""))
    text = trim(text:match("^%((.*)%)$") or text)
    local tag, version, classFile, name, body = text:match("^([^:]*):([^:]*):([^:]*):([^:]*):(.*)$")
    if not tag or trim(tag) ~= SHARE_TAG then
        return nil, "PROFILE_ERR_PARSE"
    end
    if trim(version) ~= SHARE_VERSION then
        return nil, "PROFILE_ERR_VERSION"
    end
    classFile = trim(classFile)
    if not classFile:match("^%u+$") then
        return nil, "PROFILE_ERR_PARSE"
    end
    local scale = blankScale()
    scale.situational = 0
    scale.resistance = 0
    for rawPair in body:gmatch("[^,]+") do
        local pair = trim(rawPair)
        if pair ~= "" then
            local key, value = pair:match("^([%w_]+)%s*=%s*(.-)$")
            if not key then
                return nil, "PROFILE_ERR_PARSE"
            end
            if key == "schools" then
                for rawSchool in value:gmatch("[^+]+") do
                    local school = trim(rawSchool):upper()
                    if IS_SCHOOL[school] then
                        scale.schools[school] = true
                    end
                end
            else
                local v = Profiles.ParseValue(value)
                if not v or trim(value) == "" then
                    return nil, "PROFILE_ERR_PARSE"
                end
                if key:match("^[%u%d_]+$") then
                    -- Any well-formed stat is kept, so a string from a
                    -- newer GearSentry with new stats still imports.
                    scale.stats[K(key)] = (v ~= 0) and v or nil
                elseif IS_FIELD[key] then
                    scale[key] = v
                end
                -- Unknown lowercase fields are ignored (forward compatible).
            end
        end
    end
    return { classFile = classFile, name = trim(name), scale = scale }
end

-- Adds a parsed profile for `classFile` (the current character's class)
-- under `name` (defaults to the parsed name). Returns ok, newId-or-errKey.
-- PROFILE_ERR_CLASS means the string is for another class; the caller
-- formats the message with parsed.classFile.
function Profiles.Import(db, classFile, parsed, name)
    if parsed.classFile ~= classFile then
        return false, "PROFILE_ERR_CLASS"
    end
    local ok, result = Profiles.ValidateName(db, classFile, name or parsed.name)
    if not ok then
        return false, result
    end
    userTable(db, classFile, true)[result] = storable(parsed.scale)
    return true, Profiles.UserId(result)
end
