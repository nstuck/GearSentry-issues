-- Report.lua: turns Evaluator output (suggestions, score breakdowns) into
-- chat lines for /gs scan, /gs eval and the alert text. Pure Lua apart from
-- the ns.L lookups, so tests can check the wording outside the game. Stat
-- display names are passed in as a function (in-game: the GlobalStrings value
-- of the key, e.g. ITEM_MOD_STRENGTH_SHORT
-- -> "Strength") so this file never reads WoW globals itself.
local _, ns = ...

local Report = {}
ns.Report = Report

local function fmt(n)
    return string.format("%.1f", n or 0)
end
Report.Number = fmt

function Report.SlotName(slot)
    return ns.L["SLOT_" .. tostring(slot)]
end

local function itemText(item)
    return item and (item.link or tostring(item.itemID)) or "?"
end

-- "+6.5 (+15.9%)", or "+6.5" when the slot was empty (no percentage).
function Report.Gain(s)
    local text = "+" .. fmt(s.gain)
    if s.gainPct then
        text = text .. " (+" .. fmt(s.gainPct) .. "%)"
    end
    return text
end

-- One line per suggestion: what to equip where, what it replaces, the gain,
-- and the flags the alert shows (binds when equipped, special effect).
function Report.SuggestionLine(s)
    local L = ns.L
    local parts = {}
    for _, action in ipairs(s.actions) do
        local verb = (action.item.key or ""):sub(1, 6) == "equip:" and L["MOVE_TO"] or L["EQUIP_TO"]
        parts[#parts + 1] = verb:format(itemText(action.item), Report.SlotName(action.slot))
    end
    local line = table.concat(parts, ", ") .. " " .. Report.Gain(s)

    local removed = {}
    for _, old in ipairs(s.removed or {}) do
        if old then
            removed[#removed + 1] = itemText(old)
        end
    end
    if #removed > 0 then
        line = line .. " " .. L["REPLACES"]:format(table.concat(removed, ", "))
    end

    local notes = {}
    if s.basis == "ilvl" then
        notes[#notes + 1] = L["BY_ITEM_LEVEL"]
    end
    if s.flags and s.flags.bindsOnEquip then
        notes[#notes + 1] = L["FLAG_BOE"]
    end
    if s.flags and s.flags.specialEffect then
        notes[#notes + 1] = L["FLAG_SPECIAL"]
    end
    if #notes > 0 then
        line = line .. " [" .. table.concat(notes, "; ") .. "]"
    end
    return line
end

-- "41.0 = Strength 20.0, Stamina 15.0, DPS 6.0", largest first, then
-- "unscored: ..." if any keys had no weight rule. `nameOf(key)` returns a
-- display name for a stat key.
function Report.BreakdownLine(total, breakdown, nameOf)
    local L = ns.L
    nameOf = nameOf or function(key)
        return key
    end
    local entries = {}
    for key, points in pairs(breakdown) do
        if key ~= "unscored" then
            local name
            if key == "armor" then
                name = L["STAT_ARMOR"]
            elseif key == "dps" then
                name = L["STAT_DPS"]
            else
                name = nameOf(key)
            end
            entries[#entries + 1] = { name = name, points = points }
        end
    end
    table.sort(entries, function(a, b)
        if a.points ~= b.points then
            return a.points > b.points
        end
        return a.name < b.name
    end)
    local parts = {}
    for _, e in ipairs(entries) do
        parts[#parts + 1] = e.name .. " " .. fmt(e.points)
    end
    local line = fmt(total)
    if #parts > 0 then
        line = line .. " = " .. table.concat(parts, ", ")
    end
    local unscored = breakdown.unscored or {}
    if #unscored > 0 then
        local names = {}
        for i, key in ipairs(unscored) do
            names[i] = nameOf(key)
        end
        line = line .. "; " .. L["UNSCORED"]:format(table.concat(names, ", "))
    end
    return line
end

-- Stable identity for "have we already told the user about this one?".
function Report.SuggestionID(s)
    local parts = { s.group }
    for _, action in ipairs(s.actions) do
        parts[#parts + 1] = tostring(action.item.guid or action.item.link) .. ">" .. tostring(action.slot)
    end
    return table.concat(parts, "|")
end
