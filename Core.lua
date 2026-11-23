-- SpellTips
-- Hold a key over a spell tooltip to see the numbers behind it and which talents change it.
-- With the default keys:
--   Alt          your numbers, plus the talents you have picked
--   Alt+Shift    also the talents you could still take, and the locked ones
--   Alt+wheel    step through the listed talents; release Alt to open that talent in the talent window
-- The keys, what shows without a key, and the colors are set in /spelltips.
-- Spell data comes from Data.lua (generated from game data). Everything about the player is read live.

local ADDON_NAME = ...

-- Everything Data.lua defines lives in the one SpellTipsData table.
local Data = SpellTipsData or {}

-- Attack power per 1 weapon damage per second comes from the game itself (ATTACK_POWER_MAGIC_NUMBER).

local COLOR = {
    header     = "66ccff",  -- stat row titles
    result     = "00ff00",  -- the total on a row
    pickedName = "c8c8c8",
    pickedVal  = "707070",  -- the working under a row: base, spellpower, subtotal, picked talents' amounts
    availName  = "808080",
    lockedName = "555555",
    need       = "a05050",  -- "needs N more"
    section    = "9a8a60",  -- LOCKED / tree names
    note       = "808080",
    bar        = "555555",
    dim        = "666666",
    sel        = "ffd100",  -- the talent selected with Alt+wheel
    selNote    = "c8a840",
}

-- Game ids the rules below key on. Spell effect types and aura types are numbers in the game files with
-- no Lua enum; the weapon slots and the dagger subclass are looked up from the game where it provides them.
local EFFECT = { SCHOOL_DAMAGE = 2, APPLY_AURA = 6, HEAL = 10, WEAPON_PERCENT = 31, WEAPON_DAMAGE = 58,
                 WEAPON_DAMAGE_NO_SCHOOL = 17, NORMALIZED_WEAPON = 121 }
-- Forever shrinks the spell-power bonus of healing ranks far below your level: the bonus is multiplied by
-- 1 - 0.05 * (level - maxLevel - 12), kept between 0 and 1, where maxLevel is the rank's own "MaxLevel" from the
-- game data. Measured on a level 27 druid (Healing Touch, Rejuvenation, Regrowth); Blizzard has not published it.
-- Damage spells showed no penalty in the game's own descriptions, so it is not applied to them.
local RANK_PENALTY_STEP, RANK_PENALTY_GRACE = 0.05, 12
local AURA = { PERIODIC_DAMAGE = 3, HEAL_OVER_TIME = 8, MOD_THREAT = 10, PERCENT_DAMAGE = 79, FLAT_MOD = 107, PERCENT_MOD = 108 }
local SLOT_MAINHAND, SLOT_RANGED = 16, 18
local DAGGER = (Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Dagger) or 15
-- Normalized attacks (effect 121) count attack power at a fixed speed by weapon type, in seconds.
local NORMALIZED_SPEED = { dagger = 1.7, twoHand = 3.3, other = 2.4 }

local COLOR_DEFAULT = {}
for key, hex in pairs(COLOR) do COLOR_DEFAULT[key] = hex end

-- Saved between sessions in SpellTipsDB (declared in the .toc). Until it loads, these defaults apply.
--   holdKey / moreKey   the key that shows talents, and the key that adds the locked ones
--   alwaysLevel         what shows with no key held: 0 nothing, 1 numbers, 2 + talents, 3 + locked talents
local DEFAULTS = { holdKey = "ALT", moreKey = "SHIFT", alwaysLevel = 0, minimapAngle = 215, minimapHide = false }
local db = { holdKey = DEFAULTS.holdKey, moreKey = DEFAULTS.moreKey, alwaysLevel = DEFAULTS.alwaysLevel, colors = {} }

local KEY_ORDER = { "ALT", "CTRL", "SHIFT" }
local KEY_NAMES = { ALT = "Alt", CTRL = "Ctrl", SHIFT = "Shift", NONE = "None" }
local KEY_DOWN = { ALT = IsAltKeyDown, CTRL = IsControlKeyDown, SHIFT = IsShiftKeyDown }

local S = {
    level = 0, hold = false,      -- what is showing now (0-3, see alwaysLevel), and whether holdKey is down
    debug = false,
    order = {}, seen = {},        -- talents drawn in the tooltip, in order (for Alt+wheel)
    selID = nil, selSpell = nil,  -- selected talent, and the spell it was selected on
    sources = {},                 -- [talentID] = { source, text, rank } for the tooltip being drawn (for /spelltips report)
}

-- The settings window shows a live tooltip beside it. It is drawn by the same code as a hovered one,
-- but always at full detail, so every color can be seen while it is changed.
local preview = { tooltip = nil, spell = nil, level = 3, asked = {} }

local function KeyHeld(key)
    local down = KEY_DOWN[key]
    return down and down() and true or false
end

-- 0 nothing, 1 numbers, 2 + talents, 3 + locked talents; and whether holdKey is down
local function CurrentLevel()
    local hold = KeyHeld(db.holdKey)
    local level = db.alwaysLevel
    if hold and level < 2 then level = 2 end
    if level >= 2 and KeyHeld(db.moreKey) then level = 3 end
    return level, hold
end

---------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------
local function Color(hex, text) return "|cff" .. hex .. text .. "|r" end
local function Fmt(x) return (string.format("%.1f", x):gsub("%.0$", "")) end

local function Try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
end

local function TryTable(fn, ...)
    local result = Try(fn, ...)
    return type(result) == "table" and result or {}
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function D(...)
    if S.debug then print(Color(COLOR.header, "[tt]"), ...) end
end

local function DevDebug()
    S.debug = not S.debug
    print("[spelltips debug]", S.debug and "ON" or "OFF")
end

local function PlayerClassSet()
    local _, _, classID = UnitClass("player")
    return (Data.ClassSets and Data.ClassSets[classID]) or 0, classID
end

---------------------------------------------------------------------
-- Live talent state (C_Traits)
---------------------------------------------------------------------
local spellToNode   -- [talentSpellID] = { nodeID, entryID, groupID }
local treeGroups    -- [groupID] = { name, order }: the game's own talent tree list
local cachedConfigID

local function BuildMaps(cfg)
    local map, groups, count = {}, {}, 0
    local config = TryTable(C_Traits.GetConfigInfo, cfg)
    for _, treeID in ipairs(config.treeIDs or {}) do
        for _, gi in ipairs(TryTable(C_Traits.GetGroupDisplayInfoByTreeID, treeID)) do
            if gi.groupID then
                groups[gi.groupID] = { name = gi.displayName or ("Tree " .. gi.groupID), order = gi.orderIndex or 0 }
            end
        end
        for _, nodeID in ipairs(TryTable(C_Traits.GetTreeNodes, treeID)) do
            local node = TryTable(C_Traits.GetNodeInfo, cfg, nodeID)
            local groupID
            for _, gid in ipairs(node.groupIDs or {}) do
                if groups[gid] then groupID = gid break end
            end
            for _, entryID in ipairs(node.entryIDs or {}) do
                local entry = TryTable(C_Traits.GetEntryInfo, cfg, entryID)
                local def = entry.definitionID and TryTable(C_Traits.GetDefinitionInfo, entry.definitionID)
                if def and def.spellID then
                    map[def.spellID] = { nodeID = nodeID, entryID = entryID, groupID = groupID, definitionID = entry.definitionID }
                    count = count + 1
                end
            end
        end
    end
    if count > 0 then return map, groups end
end

local function EnsureNodeMap()
    local cfg = C_ClassTalents.GetActiveConfigID()
    if not cfg then return false end
    if cfg ~= cachedConfigID or not spellToNode then
        local map, groups = BuildMaps(cfg)
        if not map then return false end
        spellToNode, treeGroups, cachedConfigID = map, groups, cfg
    end
    return true
end

-- { rank, max, entryID, available, need, groupID }, or nil if the spell isn't a talent in the active tree.
-- need = further points required in that tree before the node unlocks (nil when nothing is unmet).
local function GetTalentState(spellID)
    if not EnsureNodeMap() then return nil end
    local entry = spellToNode[spellID]
    if not entry then return nil end
    local node = Try(C_Traits.GetNodeInfo, cachedConfigID, entry.nodeID)
    if type(node) ~= "table" then return nil end

    local rank = node.currentRank or 0
    local active = node.activeEntry and node.activeEntry.entryID  -- choice nodes: only the chosen entry has rank
    if active and active ~= entry.entryID then rank = 0 end

    local need
    for _, cid in ipairs(node.conditionIDs or {}) do
        local c = Try(C_Traits.GetConditionInfo, cachedConfigID, cid)
        if type(c) == "table" and not c.isMet and (c.spentAmountRequired or 0) > 0 then
            need = math.max(need or 0, c.spentAmountRequired)
        end
    end

    return {
        rank = rank,
        max = node.maxRanks or node.totalMaxRanks or 0,
        entryID = entry.entryID,
        available = node.isAvailable and true or false,
        need = need,
        groupID = entry.groupID,
        definitionID = entry.definitionID,
    }
end

-- The game's own per-rank text. Rank 0 returns the rank-1 text on this client.
local function GetTalentText(entryID, rank)
    local text = Try(C_Traits.GetTraitDescription, entryID, rank)
    if type(text) == "string" and text ~= "" then return text end
end

---------------------------------------------------------------------
-- The spell's own numbers
---------------------------------------------------------------------
-- base + (min(level, maxLevel) - baseLevel) * perLevel
local function ScaledBase(spellData, line)
    local steps = 0
    if spellData.baseLevel then
        local level = UnitLevel("player") or 1
        local maxLevel = spellData.maxLevel or 0
        if maxLevel > 0 and level > maxLevel then level = maxLevel end
        steps = math.max(0, level - spellData.baseLevel)
    end
    return (line.base or 0) + steps * (line.per or 0)
end

-- In combat the client can return "secret" numbers that addon code may not compare or do arithmetic on.
-- ReadLive calls a stat function and, if any result is secret, returns the last readable result instead
-- (nil when there has been none), so a tooltip never errors and never shows a number it could not read.
local unpackValues = table.unpack or unpack
local lastLive = {}
local function ReadLive(key, fn, ...)
    if not fn then return nil end
    local function pack(ok, ...) return ok, { n = select("#", ...), ... } end
    local ok, values = pack(pcall(fn, ...))
    local secret = not ok
    if ok and issecretvalue then
        for i = 1, values.n do
            if issecretvalue(values[i]) then secret = true break end
        end
    end
    if secret then
        local kept = lastLive[key]
        if kept then return unpackValues(kept, 1, kept.n) end
        return nil
    end
    lastLive[key] = values
    return unpackValues(values, 1, values.n)
end

local function SpellPowerFor(spellData, line)
    if line.type == EFFECT.HEAL or line.aura == AURA.HEAL_OVER_TIME then
        return ReadLive("healing", GetSpellBonusHealing) or 0
    end
    local school = spellData.si or 1
    return ReadLive("damage" .. school, GetSpellBonusDamage, school) or 0
end

-- Share of the spell-power bonus a healing rank keeps at your level (1 = all of it).
local function RankFactor(spellData, line)
    local maxLevel = spellData.maxLevel or 0
    if maxLevel <= 0 or not (line.type == EFFECT.HEAL or line.aura == AURA.HEAL_OVER_TIME) then return 1 end
    local over = (UnitLevel("player") or 1) - maxLevel - RANK_PENALTY_GRACE
    -- never below 10%: Healing Wave ranks 1 and 2 at level 42 get 10% where the 5%-per-level slope reaches 0% and 5%
    -- (ranks 3-6 match the slope: 35%, 65%, 95%, 100%). Damage spells get no penalty (Earth Shock rank 3, 28 levels
    -- below, gets its full bonus).
    return math.min(1, math.max(0.1, 1 - over * RANK_PENALTY_STEP))
end

-- spell damage: scaled base * (1 +/- variance/2) + coefficient * spellpower * rank factor
local function PredictRange(spellData, line)
    local scaled = ScaledBase(spellData, line)
    local sp = SpellPowerFor(spellData, line)
    local factor = RankFactor(spellData, line)
    return {
        scaled = scaled,
        half = scaled * (line.var or 0) / 2,
        sp = sp,
        factor = factor,
        bonus = (line.coeff or 0) * sp * factor,
    }
end

-- Effect 121 takes attack power at a fixed "normalized" speed: dagger 1.7, other one-hand 2.4, two-hand 3.3.
local function NormalizedSpeed()
    local itemID = GetInventoryItemID and GetInventoryItemID("player", SLOT_MAINHAND)
    if not itemID then return nil, "no main-hand item" end
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInfo then return nil, "no GetItemInfoInstant" end
    local _, _, _, equipLoc, _, classID, subclassID = getInfo(itemID)
    if classID ~= 2 then return nil, "main hand is not a weapon" end
    if equipLoc == "INVTYPE_2HWEAPON" then return NORMALIZED_SPEED.twoHand, "two-hander" end
    if subclassID == DAGGER then return NORMALIZED_SPEED.dagger, "dagger" end
    return NORMALIZED_SPEED.other, "one-hander (" .. tostring(equipLoc) .. ", subclass " .. tostring(subclassID) .. ")"
end

-- Weapon abilities: ability flat + weapon swing. UnitDamage already includes attack power at your real
-- weapon speed, so that part is backed out and redone at the speed the ability uses.
-- Armor and crits are not applied. Returns { {l=label, v=value, n=note}, ... }, "lo-hi"
local function RangedWeaponIsWand()
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local wand = Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Wand
    local weapon = Enum and Enum.ItemClass and Enum.ItemClass.Weapon
    if not (getInfo and GetInventoryItemID and wand and weapon) then return false end
    local itemID = GetInventoryItemID("player", SLOT_RANGED)   -- the ranged slot
    if not itemID then return false end
    local _, _, _, _, _, classID, subclassID = getInfo(itemID)
    return classID == weapon and subclassID == wand
end

-- steps: the spell's weapon effects in effect-index order, applied in that order the way classic servers do:
-- { lo = , hi = , base = , coeff = } adds the ability's flat amount (its base range × the effect's coefficient),
-- { mul = fraction } multiplies everything so far (weapon percent damage, effect 31: Backstab 150%,
-- Holy Strike 29%). A percent listed after a flat amount therefore multiplies that amount too, except a
-- flat amount with { after = true }: it is added on its own after all percents (see AddWeaponDamage).
local function WeaponLines(steps, normalized, ranged)
    local perDps = ATTACK_POWER_MAGIC_NUMBER
    if not perDps or perDps <= 0 then return nil end   -- the game does not say; show no weapon math
    local lo, hi, speed, posBonus, negBonus, pct, apBase, apPos, apNeg
    if ranged then   -- the spell uses the ranged weapon slot
        if not (UnitRangedDamage and UnitRangedAttackPower) then return nil end
        speed, lo, hi, posBonus, negBonus, pct = ReadLive("rangedDamage", UnitRangedDamage, "player")
        apBase, apPos, apNeg = ReadLive("rangedPower", UnitRangedAttackPower, "player")
        normalized = false
    else
        if not (UnitDamage and UnitAttackSpeed and UnitAttackPower) then return nil end
        lo, hi, _, _, posBonus, negBonus, pct = ReadLive("meleeDamage", UnitDamage, "player")
        speed = ReadLive("meleeSpeed", UnitAttackSpeed, "player")
        apBase, apPos, apNeg = ReadLive("meleePower", UnitAttackPower, "player")
    end
    if not (lo and hi and speed) or speed <= 0 then return nil end

    -- the step rows, and the steps run over a running low/high
    -- rows in the order the steps apply: the in-order steps first, then the amounts added after
    local function StepRows(out)
        local function Add(st)
            local v = st.lo == st.hi and Fmt(st.lo) or (Fmt(st.lo) .. "-" .. Fmt(st.hi))
            local n
            if st.coeff ~= 1 then
                n = (st.lo == st.hi and Fmt(st.base) or (Fmt(st.lo / st.coeff) .. "-" .. Fmt(st.hi / st.coeff)))
                    .. " × " .. st.coeff .. " effect coefficient" .. (st.after and ", not scaled by weapon percent" or "")
            end
            out[#out + 1] = { l = "ability", v = "+ " .. v, n = n }
        end
        for _, st in ipairs(steps) do
            if st.mul then
                out[#out + 1] = { l = "weapon percent", v = "× " .. Fmt(st.mul * 100) .. "%" }
            elseif not st.after then
                Add(st)
            end
        end
        for _, st in ipairs(steps) do
            if st.after then Add(st) end
        end
    end
    -- returns the in-order chain run over l/h, and the after amounts separately
    local function Run(l, h)
        local aLo, aHi = 0, 0
        for _, st in ipairs(steps) do
            if st.mul then l, h = l * st.mul, h * st.mul
            elseif st.after then aLo, aHi = aLo + st.lo, aHi + st.hi
            else l, h = l + st.lo, h + st.hi end
        end
        return l, h, aLo, aHi
    end

    -- A wand is the whole attack: no attack power and no bonus damage, just the wand's own damage
    -- (the game reports its range in the ranged-damage call). Checked on the item in the ranged slot.
    if ranged and RangedWeaponIsWand() then
        local scale = pct or 1
        local out = {}   -- with no steps the total is the wand's range; a breakdown row would only repeat it
        if #steps > 0 then
            out[1] = { l = "wand", v = Fmt(lo * scale) .. "-" .. Fmt(hi * scale) }
            StepRows(out)
        end
        local l, h, aLo, aHi = Run(lo, hi)
        return out, Fmt(l * scale + aLo) .. "-" .. Fmt(h * scale + aHi)
    end

    local bonus = (posBonus or 0) + (negBonus or 0)
    pct = pct or 1
    local ap = (apBase or 0) + (apPos or 0) + (apNeg or 0)
    local apPerSec = ap / perDps
    local apReal = apPerSec * speed
    local apUsed = apReal
    local swing = Fmt(speed) .. " sec swing"

    if normalized then
        local fixedSpeed, weapon = NormalizedSpeed()
        D("normalized weapon:", weapon, "speed", fixedSpeed, "real speed", speed)
        if fixedSpeed then
            apUsed = apPerSec * fixedSpeed
            swing = Fmt(fixedSpeed) .. " sec (" .. ((weapon or "weapon"):match("^[%a%-]+") or "weapon") .. ", fixed)"
        end
    end

    local weaponLo, weaponHi = lo - apReal, hi - apReal
    D("weapon live: UnitDamage", lo, hi, "bonus", posBonus, negBonus, "pct", pct, "speed", speed, "AP", ap, "AP at real speed", apReal)
    local out = {
        { l = "weapon", v = Fmt(weaponLo) .. "-" .. Fmt(weaponHi) },
        { l = "attack power", v = "+ " .. Fmt(apUsed),
          n = Fmt(ap) .. " AP at 1 dmg/sec per " .. perDps .. " AP, × " .. swing },
    }
    if math.abs(bonus) >= 0.05 then out[#out + 1] = { l = "bonus damage", v = "+ " .. Fmt(bonus) } end
    StepRows(out)
    if math.abs(pct - 1) >= 0.001 then out[#out + 1] = { l = "damage modifier", v = "× " .. string.format("%.2f", pct) } end

    local totalLo, totalHi, aLo, aHi = Run(weaponLo + apUsed + bonus, weaponHi + apUsed + bonus)
    return out, Fmt(totalLo * pct + aLo) .. "-" .. Fmt(totalHi * pct + aHi)
end

---------------------------------------------------------------------
-- Row order and labels
---------------------------------------------------------------------
-- The order rows are drawn in. Rows the data produces that are not listed still show, after these.
local ROW_ORDER = { "Damage", "Healing", "Cast time", "Cooldown", "Global cooldown", "Cost", "Range", "Radius",
                    "Hit", "Crit", "Crit bonus", "Pushback resist", "(auras)", "Duration", "Speed", "Threat" }

-- Aura rows (Stun, Slow, ...) come from Data.AuraKinds in Data.lua, so no ids are listed here.
local auraLabels
local function AuraLabels()
    if not auraLabels then
        auraLabels = {}
        local ids = {}
        for id in pairs(Data.AuraKinds or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do auraLabels[#auraLabels + 1] = Data.AuraKinds[id].label end
    end
    return auraLabels
end

-- "Cast time -0.5 sec, Hit +4%": what a locked talent would do
local function Summarize(effects)
    local bits = {}
    for _, f in ipairs(effects) do bits[#bits + 1] = f.row .. " " .. f.comp end
    return table.concat(bits, ", ")
end

---------------------------------------------------------------------
-- Building the rows
---------------------------------------------------------------------
-- rows[name] = { own = breakdown lines, mods = talents, values = the green totals, suffix = "(note)" }
local function GetRow(rows, name)
    local row = rows[name]
    if not row then
        row = { own = {}, mods = {}, values = {} }
        rows[name] = row
    end
    return row
end

-- One damage or healing effect, laid out as a sum then a product:
--   Base / Spellpower (and any flat talents), a line with the subtotal, then the picked talents that
--   multiply it, then the tick count for a periodic effect. The total on the row includes all of it.
-- Periodic effects (aura 3 damage, aura 8 healing) are per tick; ticks = duration / period, both in ms
-- from Data.lua (line.dur, line.period). Without them the row shows the per-tick amount.
-- tick: { period = ms, dur = ms } for an amount another spell repeats (Consecration hits with 1280345 every
-- second for 8 sec); the amount itself is a plain hit, so its talents are still the direct ones.
-- kindName: the block's heading when the row gets more than one block.
local function AddSpellDamage(rows, spellData, line, tick, kindName)
    local function R(x) return tostring(math.floor(x + 0.5)) end
    -- Final amounts are rounded down, the way the game does it; 0.0005 of slack keeps float noise like
    -- 830.9999996 from losing a point.
    local function F(x) return tostring(math.floor(x + 0.0005)) end
    -- the high end's +1 (spells with variance) comes after talents and rounding down, see below
    local hiPlus = 0
    local function Range(lo, hi)
        local l, h = F(lo), tostring(tonumber(F(hi)) + hiPlus)
        return l == h and l or (l .. "-" .. h)
    end
    local heal = line.type == EFFECT.HEAL or line.aura == AURA.HEAL_OVER_TIME
    local periodic = line.type == EFFECT.APPLY_AURA
    local ticking = periodic or tick ~= nil
    local each = ticking and " per tick" or ""

    local c = PredictRange(spellData, line)
    local talents = S.DamageTalents and S.DamageTalents(spellData) or {}
    local scope = talents[periodic and "periodic" or "direct"] or { mult = 1, flat = 0, ids = {} }
    local period = tick and tick.period or line.period
    local rawDur = tick and tick.dur or line.dur
    local dur = rawDur and talents.dur and (rawDur + talents.dur.flat) * talents.dur.mult or rawDur
    local ticks = ticking and (period or 0) > 0 and (dur or 0) > 0 and math.floor(dur / period + 0.0001) or nil
    -- The range, the game's way. Checked against the game's own descriptions (C_Spell.GetSpellDescription) for
    -- all 65 ranks of a level 46 shaman's Lightning Bolt, Chain Lightning, Earth Shock, Lava Burst, Frost Shock,
    -- Healing Wave, Lesser Healing Wave and Chain Heal, talents included, all exact:
    --   low end  = round(unscaled base x (1 - variance / 2))
    --   high end = round(unscaled base x (1 + variance / 2))
    --   both     + per-level step x levels, unrounded
    -- then the spellpower bonus is added unrounded, talents multiply, the result is rounded down (F), and only
    -- then the high end gets +1 when the spell has variance. (Adding the +1 before talents put Chain Lightning
    -- and some Lightning Bolt ranks 1 over.)
    local unscaled, var = line.base or 0, line.var or 0
    local levelBonus = c.scaled - unscaled
    local baseLo, baseHi = c.scaled, c.scaled
    if var > 0 then
        baseLo = math.floor(unscaled * (1 - var / 2) + 0.5) + levelBonus
        baseHi = math.floor(unscaled * (1 + var / 2) + 0.5) + levelBonus
        hiPlus = 1
    end
    local bonus = c.bonus

    local row = GetRow(rows, heal and "Healing" or "Damage")
    local own = row.own
    -- A spell with a hit and a DoT gets two blocks; name them so the two "Base" lines can be told apart.
    -- The first block is only named once a second one arrives.
    local kind = kindName or (ticking and "Over time" or "Immediate")
    if #own > 0 then
        if not row.named then
            table.insert(own, 1, { h = row.kind })
            row.named = true
        end
        own[#own + 1] = { h = kind }
    end
    row.kind = row.kind or kind
    row.joiner = " + "
    own[#own + 1] = { l = "Base", v = Range(baseLo, baseHi) .. each }
    if c.bonus >= 0.05 then
        own[#own + 1] = {
            l = (heal and "Healing power (" or "Spellpower (") .. Fmt(c.sp) .. " × " .. Fmt((line.coeff or 0) * 100) .. "%"
                .. (c.factor < 1 and (" × " .. Fmt(c.factor * 100) .. "% low rank") or "") .. ")",
            v = "+" .. R(bonus) .. each,
        }
    end
    if scope.flat ~= 0 then own[#own + 1] = { talents = { op = "+", ids = scope.ids }, combined = (scope.flat > 0 and "+" or "") .. R(scope.flat) .. each } end

    local lo = baseLo + bonus + scope.flat
    local hi = baseHi + bonus + scope.flat
    if math.abs(scope.mult - 1) >= 0.0005 then
        local pct = (scope.mult - 1) * 100
        own[#own + 1] = { sep = Range(lo, hi) .. each }
        own[#own + 1] = { talents = { op = "x", ids = scope.ids }, combined = (pct >= 0 and "+" or "-") .. Fmt(math.abs(pct)) .. "%" }
    end
    lo, hi = lo * scope.mult, hi * scope.mult

    if ticks then
        own[#own + 1] = { l = "Ticks", v = ticks .. ", every " .. Fmt(period / 1000) .. " sec" }
        row.values[#row.values + 1] = Range(lo * ticks, hi * ticks) .. " over " .. Fmt(dur / 1000) .. " sec"
    else
        row.values[#row.values + 1] = Range(lo, hi) .. each
    end
end

-- All of a spell's weapon effects make one Damage row: weapon damage (58, 17), normalized weapon damage (121)
-- and weapon percent damage (31), in effect order.
local function AddWeaponDamage(rows, spellData)
    local steps, normalized, any = {}, false, false
    for _, idx in ipairs(SortedKeys(spellData.lines)) do
        local line = spellData.lines[idx]
        local t = line.type
        if t == EFFECT.WEAPON_PERCENT then
            steps[#steps + 1] = { mul = ScaledBase(spellData, line) / 100 }
            any = true
        elseif t == EFFECT.WEAPON_DAMAGE_NO_SCHOOL or t == EFFECT.WEAPON_DAMAGE or t == EFFECT.NORMALIZED_WEAPON then
            -- the flat amount's range, by the same rule as spell amounts (see AddSpellDamage)
            local base, coeff = ScaledBase(spellData, line), line.coeff or 1
            local unscaled, var = line.base or 0, line.var or 0
            local lo, hi = base, base
            if var > 0 then
                lo = math.floor(unscaled * (1 - var / 2) + 0.5) + (base - unscaled)
                hi = math.floor(unscaled * (1 + var / 2) + 0.5) + 1 + (base - unscaled)
            end
            -- A coefficient other than 1 marks the flat as its own scaled amount, which the game's tooltip lists
            -- apart ("29% weapon damage plus an additional 6 to 9 as Holy damage"). A Holy Strike hit of 41
            -- fit adding it after the weapon percent (32.1-40.4), not under it (27.7-33.8).
            steps[#steps + 1] = { lo = lo * coeff, hi = hi * coeff, base = base, coeff = coeff, after = coeff ~= 1 }
            if t == EFFECT.NORMALIZED_WEAPON then normalized = true end
            any = true
        end
    end
    if not any then return end
    local lines, total = WeaponLines(steps, normalized, spellData.ranged)
    if not lines then return end
    local row = GetRow(rows, "Damage")
    row.suffix = "(before armor)"
    row.values[#row.values + 1] = total
    for _, l in ipairs(lines) do row.own[#row.own + 1] = l end
end

-- Stun / Root / Fear / Silence / Slow: one row per aura kind, "40% for 6 sec" or "4 sec"
local function AddAuras(rows, spellID)
    for _, aura in ipairs(Data.Auras and Data.Auras[spellID] or {}) do
        local kind = Data.AuraKinds and Data.AuraKinds[aura.aura]
        if kind then
            local amount = kind.value and (Fmt(aura.value) .. "%") or nil
            local seconds = aura.durationMs > 0 and (Fmt(aura.durationMs / 1000) .. " sec") or nil
            local text = (amount and seconds) and (amount .. " for " .. seconds) or amount or seconds
            if text then
                local row = GetRow(rows, kind.label)
                row.values[#row.values + 1] = text
                D("spell", spellID, kind.label, aura.value, "ms", aura.durationMs)
            end
        end
    end
end

-- the spell's own effects -> Damage / Healing / aura rows
local function AddOwnLines(rows, spellData, spellID)
    -- The melee auto-attack has no damage effect in the game's spell data, so ask the client whether this spell is
    -- the auto-attack. Kept inside this function: the file is at Lua's limit of 200 top-level locals.
    local function IsMeleeAutoAttack(spellID)
        if C_Spell and C_Spell.IsAutoAttackSpell then
            local ok, result = pcall(C_Spell.IsAutoAttackSpell, spellID)
            D("auto-attack check C_Spell.IsAutoAttackSpell", spellID, ok, tostring(result))
            if ok then return result and true or false end
        end
        if IsAttackSpell then
            local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
            local ok, result = pcall(IsAttackSpell, name or spellID)
            D("auto-attack check IsAttackSpell", spellID, name, ok, tostring(result))
            if ok then return result and true or false end
        end
        D("auto-attack check: client has neither IsAutoAttackSpell nor IsAttackSpell")
        return false
    end
    -- a spell-power damage or heal effect (direct or periodic) of spell sd: true when it was added
    local function SpellAmount(sd, line)
        local t = line.type
        local periodic = t == EFFECT.APPLY_AURA and (line.aura == AURA.PERIODIC_DAMAGE or line.aura == AURA.HEAL_OVER_TIME)
        local damage = t == EFFECT.SCHOOL_DAMAGE or line.aura == AURA.PERIODIC_DAMAGE
        if (t == EFFECT.SCHOOL_DAMAGE or t == EFFECT.HEAL or periodic) and (line.coeff or 0) > 0
            and not (damage and (sd.si or 1) == 1) then
            AddSpellDamage(rows, sd, line)
            return true
        end
    end

    for _, idx in ipairs(SortedKeys(spellData.lines)) do
        SpellAmount(spellData, spellData.lines[idx])
    end
    AddWeaponDamage(rows, spellData)
    -- Amounts that live in another spell, named by this spell's own description token ($26367s1 in Lightning
    -- Shield's text): the generator wrote them as shows = {{ id, idx }}. The math uses that spell's own entry
    -- (base, coefficient, level range, talents).
    -- A ref with a period is an amount this spell repeats with its own periodic aura (Consecration); it may
    -- have no coefficient (Consecration's 2 to every enemy), so it goes straight to AddSpellDamage.
    local ticking = {}
    for _, ref in ipairs(spellData.shows or {}) do
        if ref.period then ticking[#ticking + 1] = ref end
    end
    for _, ref in ipairs(spellData.shows or {}) do
        local sd = Data.AddonData[ref.id]
        local line = sd and sd.lines[ref.idx]
        if line and ref.period then
            local part = #ticking > 1 and ("Over time, part " .. (ref.idx + 1)) or nil
            AddSpellDamage(rows, sd, line, { period = ref.period, dur = ref.dur }, part)
        elseif line then
            SpellAmount(sd, line)
        end
    end
    if next(spellData.lines) == nil and not rows.Damage and IsMeleeAutoAttack(spellID) then
        local lines, total = WeaponLines({}, false, false)   -- the plain weapon swing, no ability bonus
        if lines then
            local row = GetRow(rows, "Damage")
            row.suffix = "(before armor)"
            row.values[#row.values + 1] = total
            for _, l in ipairs(lines) do row.own[#row.own + 1] = l end
        end
    end
    AddAuras(rows, spellID)
end

-- Live totals from the client for rows that talents touch. These already include picked talents.
-- Cast time also gets the spell's base time (Data.lua "cast", ms, from SpellCastTimes) and the player's
-- spell haste, the two things besides talents that set it: client time = base after talents / (1 + haste%).
local function AddApiValues(rows, spellID, spellData)
    local function put(row, value, unit)
        if rows[row] and value > 0 then
            local values = rows[row].values
            values[#values + 1] = Fmt(value) .. unit
        end
    end
    local info = C_Spell.GetSpellInfo(spellID) or {}
    local cast = rows["Cast time"]
    if cast and info.castTime then
        local ms = info.castTime
        -- two decimals: haste makes 2.94 sec, which one decimal would show as a 0.1 sec change
        cast.values[#cast.values + 1] = ms > 0 and ((string.format("%.2f", ms / 1000):gsub("0+$", ""):gsub("%.$", "")) .. " sec") or "Instant"
        local base = spellData and spellData.cast
        if base and base > 0 then
            cast.own[#cast.own + 1] = { l = "Base", v = Fmt(base / 1000) .. " sec" }
        end
        local haste = ms > 0 and ReadLive("spellHaste", UnitSpellHaste, "player")
        if haste and math.abs(haste) >= 0.05 then
            cast.own[#cast.own + 1] = { l = "Haste", v = (haste > 0 and "+" or "") .. Fmt(haste) .. "%" }
        end
    end
    put("Range", info.maxRange or 0, " yd")

    local cost = (C_Spell.GetSpellPowerCost(spellID) or {})[1]
    if cost then
        local resource = (cost.name or ""):lower()
        put("Cost", cost.cost or 0, " " .. resource:sub(1, 1):upper() .. resource:sub(2))
    end
    put("Cooldown", (GetSpellBaseCooldown and GetSpellBaseCooldown(spellID) or 0) / 1000, " sec")
end

-- Hit: the client reports gear only (talents are not included), so picked "+N%" talents are added.
-- Crit: the client's chance is school-wide; picked talents that add crit to this spell are added to it,
-- with the client's own figure shown as "Character sheet" so the sum can be checked.
local function AddHitCrit(rows, spellData)
    local melee = spellData.si == 1
    local hit = rows["Hit"]
    if hit then
        local getHit = melee and GetHitModifier or GetSpellHitModifier
        local gear = ReadLive(melee and "hitMelee" or "hitSpell", getHit) or 0
        local talents, any = 0, false
        for _, m in ipairs(hit.mods) do
            local n = m.picked and tonumber(m.comp:match("^%+(%d[%d%.]*)%%"))
            if n then talents, any = talents + n, true end
        end
        if any or gear > 0 then hit.values[#hit.values + 1] = "+" .. Fmt(gear + talents) .. "%" end
    end
    local crit = rows["Crit"]
    if crit then
        local getCrit = melee and GetCritChance or GetSpellCritChance
        local school = spellData.si or 1
        local chance = ReadLive("crit" .. (melee and "M" or "S") .. school, getCrit, school)
        if chance then
            local talents = S.DamageTalents and S.DamageTalents(spellData).crit or 0
            crit.values[#crit.values + 1] = Fmt(chance + talents) .. "%"
            if talents ~= 0 then crit.own[#crit.own + 1] = { l = "Character sheet", v = Fmt(chance) .. "%" } end
        end
    end
end

-- Talents that change duration (or, for Slow, target speed) attach to the spell's aura row,
-- one line per talent. Only done when the spell has exactly one aura row, so it is never ambiguous.
local function MergeAuraTalents(rows)
    local target
    for _, label in ipairs(AuraLabels()) do
        if rows[label] then
            if target then return end
            target = label
        end
    end
    if not target then return end
    local aura = rows[target]
    for _, from in ipairs({ "Duration", "Speed" }) do
        local source = rows[from]
        if source and (from == "Duration" or target == "Slow") then
            for _, m in ipairs(source.mods) do
                if from == "Speed" then
                    m.comp = m.comp:gsub("^%-", "+") .. " slow"
                else
                    m.comp = m.comp .. " duration"
                end
                aura.mods[#aura.mods + 1] = m
            end
            rows[from] = nil
        end
    end
    local merged, byName = {}, {}
    for _, m in ipairs(aura.mods) do
        local existing = byName[m.name]
        if existing then
            existing.comp = existing.comp .. ", " .. m.comp
        else
            byName[m.name] = m
            merged[#merged + 1] = m
        end
    end
    aura.mods = merged
end

-- An aura row (Stun, Slow, ...) only repeats what the game's own text says, so it shows only when a talent
-- changes it. One rule for every aura kind, no per-kind cases.
local function PruneAuraRows(rows)
    for _, kind in pairs(Data.AuraKinds or {}) do
        local row = rows[kind.label]
        if row and #row.mods == 0 then rows[kind.label] = nil end
    end
end

---------------------------------------------------------------------
-- Talent effects from the game data (Data.Mods)
---------------------------------------------------------------------
-- A talent's modifier effect names the spell property it changes. These ids were checked against the
-- game's own spell descriptions; an id that is not listed here is still shown, as its own "Property N" row.
-- unit: "ms" milliseconds shown as seconds, "yd" yards, "power" a resource cost (Rage is stored x10),
-- "pts" flat percentage points. effect: the modifier changes that effect of the spell instead (0 = all).
-- The one hand-made table that remains: which spell property a modifier's misc value names (and its
-- unit). Names follow the public SpellModOp list (ids 0-30); 32 is not on it and stays unmapped. The game keeps this list in its program code; no data table or Lua enum exposes it (checked:
-- SpellAuraNames, SpellEffectNames, EnumeratedString, the Enum global). Unknown properties fall back
-- to the talent's own text.
local MOD_PROPS = {
    [0]  = { row = "Damage", damage = true },       [22] = { row = "Damage", damage = true },   -- direct, periodic
    [1]  = { row = "Duration", unit = "ms" },
    [2]  = { row = "Threat" },
    [5]  = { row = "Range", unit = "yd" },
    [6]  = { row = "Radius", unit = "yd" },
    [7]  = { row = "Crit", unit = "pts" },
    [9]  = { row = "Pushback resist", unit = "pts" },
    [10] = { row = "Cast time", unit = "ms" },
    [11] = { row = "Cooldown", unit = "ms" },
    [14] = { row = "Cost", unit = "power" },
    [15] = { row = "Crit bonus" },
    [16] = { row = "Hit", unit = "pts" },
    [21] = { row = "Global cooldown", unit = "ms" },
    [4]  = { row = "Charges" },
    [17] = { row = "Jump targets" },
    [18] = { row = "Proc chance", unit = "pts" },    -- chance of success, flat points on proc spells
    [27] = { row = "Effect value" },                 -- "multiple value": percent change to the effect numbers
    [28] = { row = "Dispel resist", unit = "pts" },  -- resist dispel chance
    [3]  = { effect = 1 }, [12] = { effect = 2 }, [23] = { effect = 3 }, [8] = { effect = 0 },
}

local function Num(x)  -- up to two decimals, no trailing zeros
    return (string.format("%.2f", x):gsub("0+$", ""):gsub("%.$", ""))
end

local function Signed(x)
    return (x >= 0 and "+" or "-") .. Num(math.abs(x))
end

local function IsHealLine(line) return line.type == EFFECT.HEAL or line.aura == AURA.HEAL_OVER_TIME end

-- modifiers to "damage" also raise healing, so the row follows what the spell actually does
local function DamageRow(spellData)
    local heals, deals = false, false
    for _, line in pairs(spellData.lines) do
        if IsHealLine(line) then heals = true else deals = true end
    end
    return (heals and not deals) and "Healing" or "Damage"
end

-- the row of the spell's own effect #index (1-based); also returns its aura kind, if it is one
-- Row for a modifier that targets one of the spell's effects (index 0 = all of them).
-- Returns the row label, the aura kind if it is one, and whether the effect is something we know the
-- unit of (damage, healing, a listed aura). "Effects" / "Effect N" are placeholders and not known.
local function EffectRow(spellData, spellID, index)
    if index == 0 then return "Effects", nil, false end
    local line = spellData.lines[index - 1]
    if line then return IsHealLine(line) and "Healing" or "Damage", nil, true end
    for _, a in ipairs(Data.Auras and Data.Auras[spellID] or {}) do
        local kind = Data.AuraKinds and Data.AuraKinds[a.aura]
        if a.idx == index - 1 and kind then return kind.label, kind, true end
    end
    return "Effect " .. index, nil, false
end

-- The talent's amount at this rank. A talent can carry its own per-rank values (the game's override
-- curve for that effect); without them the effect's base value is multiplied by the rank.
-- defRanks = Data.Ranks[definitionID] for the talent entry in use (nil when it has none).
local function RanksOf(mod, defRanks)
    return defRanks and defRanks[mod.idx]
end

local function ModAmount(mod, rank, defRanks)
    local ranks = RanksOf(mod, defRanks)
    if ranks then return ranks[math.min(math.max(rank, 1), #ranks)] end
    return mod.base * rank
end

-- Aura 10 (mod threat) is keyed by school, not by a spell property: its misc value is a school mask.
local function PropInfo(mod)
    if mod.aura == AURA.MOD_THREAT then return { row = "Threat" } end
    return MOD_PROPS[mod.prop]
end

-- A per-rank curve that points the opposite way from the effect's own base value (a reduction stored
-- as a positive curve, say) cannot be given a sign without guessing, so that row shows only its size.
local function SignDisagrees(mod, defRanks)
    local ranks = RanksOf(mod, defRanks)
    local first = ranks and ranks[1]
    return first and first ~= 0 and mod.base ~= 0 and ((first < 0) ~= (mod.base < 0))
end

-- unsigned: the data does not say which way this amount points, so only its size is shown ("±10%")
local function ModText(mod, rank, powerType, defRanks, unsigned)
    local info = PropInfo(mod) or {}
    local amount = ModAmount(mod, rank, defRanks)
    local function sign(x) return unsigned and ("±" .. Num(math.abs(x))) or Signed(x) end
    if mod.aura == AURA.PERCENT_MOD or mod.aura == AURA.MOD_THREAT or mod.aura == AURA.PERCENT_DAMAGE then  -- percent
        if mod.prop == 10 and amount <= -100 and not unsigned then return "instant" end
        return sign(amount) .. "%"
    end
    if info.unit == "ms" then return sign(amount / 1000) .. " sec" end
    if info.unit == "yd" then return sign(amount) .. " yd" end
    if info.unit == "pts" then return sign(amount) .. "%" end
    if info.unit == "power" then
        -- stored power amounts are shown amounts x the power type's display modifier (Rage: 10)
        local scale = (Data.Power and powerType and Data.Power[powerType]) or 1
        return sign(amount / scale)
    end
    return sign(amount)
end

-- { {row, comp}, ... } straight from the talent's modifier effects at this rank, or nil when the
-- data has none for this spell (then the talent's description text is parsed instead)
local function StructuredEffects(t, rank, spellData, spellID, definitionID)
    local mods = Data.Mods and Data.Mods[t.id]
    if not mods or t.via or t.raw then return nil end
    local defRanks = Data.Ranks and definitionID and Data.Ranks[definitionID]
    local used = {}
    for _, i in ipairs(t.rows or SortedKeys(mods)) do used[#used + 1] = mods[i] end
    if #used == 0 then return nil end

    local cost = TryTable(C_Spell.GetSpellPowerCost, spellID)[1]
    local powerType = cost and cost.type
    local out, byRow = {}, {}
    for _, mod in ipairs(used) do
        local unsigned = SignDisagrees(mod, defRanks)
        local info = PropInfo(mod)
        local row, kind, known
        if not info then
            row = "Property " .. mod.prop
        elseif info.effect then
            row, kind, known = EffectRow(spellData, spellID, info.effect)
            -- a flat change to an effect that is neither damage/healing nor a known aura: its unit
            -- (Rage is stored x10, a duration in ms, ...) is not in the data, so use the game's text
            if mod.aura == AURA.FLAT_MOD and not known then return nil end
        elseif info.damage then
            row = DamageRow(spellData)
        else
            row = info.row
        end
        local comp
        if kind and kind.value then  -- a slow is stored negative: more negative means a stronger slow
            local amount = ModAmount(mod, rank, defRanks)
            comp = (unsigned and ("±" .. Num(math.abs(amount))) or Signed(mod.aura == AURA.PERCENT_MOD and amount or -amount)) .. "%"
        else
            comp = ModText(mod, rank, powerType, defRanks, unsigned)
        end
        local entry = byRow[row]
        if not entry then
            entry = { row = row, parts = {}, seen = {} }
            byRow[row] = entry
            out[#out + 1] = entry
        end
        if not entry.seen[comp] then  -- direct + periodic damage often say the same thing twice
            entry.seen[comp] = true
            entry.parts[#entry.parts + 1] = comp
        end
    end
    for _, entry in ipairs(out) do entry.comp = table.concat(entry.parts, ", ") end
    return out
end

-- What a talent does to this spell, from the game data's modifier effects at this rank. When the data
-- has nothing usable for it (no rows, a link made some other way, a unit or sign the data does not
-- settle), the result is empty and the game's own text for that rank is shown as it is.
-- Also returns that text.
local function TalentEffects(t, st, rank, spellData, spellID)
    local text = GetTalentText(st.entryID, rank)
    local effects = StructuredEffects(t, rank, spellData, spellID, st.definitionID)
    S.sources[t.id] = { source = effects and "game data" or "engine text", text = text, rank = rank }
    D("talent", t.name, "rank", rank, effects and Summarize(effects) or "-> engine text")
    return effects or {}, text
end

-- Picked talents that change this spell's damage or healing amount, from their modifier rows:
-- percent rows (aura 108) multiply, flat rows (aura 107) add. Property 0 is direct effects, 22 periodic.
-- Talents stack by multiplying (the game's Corruption total matches 1.1 x 1.1, not 1.2).
-- Runs at every tooltip level, so the total is right even when the talents are not drawn.
-- Kept on S: the file is at Lua's limit of 200 top-level locals.
-- Also sums flat crit-chance rows (aura 107, property 7): the client's GetSpellCritChance is the same for
-- every school (checked on a shaman: all schools 5.99% with Call of Thunder 1/1), so a talent that adds crit
-- to particular spells is not in it.
-- And duration rows (property 1: flat ms, or percent), which change how many times a periodic effect ticks
-- (Call of Flame: +9 sec on Flame Shock, 12 -> 21 sec, 4 -> 7 ticks, matching the game's text).
-- Returns { direct = { mult, flat, ids = { [talentID] = "x" | "+" } }, periodic = { ... }, crit = points,
--           dur = { flat = ms, mult = n } }
S.DamageTalents = function(spellData)
    local out = { direct = { mult = 1, flat = 0, ids = {} }, periodic = { mult = 1, flat = 0, ids = {} }, crit = 0,
                  dur = { flat = 0, mult = 1 } }
    local seen = {}
    for _, t in ipairs(spellData.talents or {}) do
        local mods = Data.Mods and Data.Mods[t.id]
        if mods and not seen[t.id] and not t.via and not t.raw then
            seen[t.id] = true
            local st = GetTalentState(t.id)
            if st and st.rank > 0 then
                local defRanks = Data.Ranks and st.definitionID and Data.Ranks[st.definitionID]
                for _, i in ipairs(t.rows or SortedKeys(mods)) do
                    local mod = mods[i]
                    local scope = mod and ((mod.prop == 0 and out.direct) or (mod.prop == 22 and out.periodic))
                    if mod and mod.prop == 7 and mod.aura == AURA.FLAT_MOD and not SignDisagrees(mod, defRanks) then
                        out.crit = out.crit + ModAmount(mod, st.rank, defRanks)
                    end
                    if mod and mod.prop == 1 and not SignDisagrees(mod, defRanks) then
                        local amount = ModAmount(mod, st.rank, defRanks)
                        if mod.aura == AURA.FLAT_MOD then
                            out.dur.flat = out.dur.flat + amount
                        elseif mod.aura == AURA.PERCENT_MOD then
                            out.dur.mult = out.dur.mult * (1 + amount / 100)
                        end
                    end
                    if scope and not SignDisagrees(mod, defRanks) then
                        local amount = ModAmount(mod, st.rank, defRanks)
                        if mod.aura == AURA.PERCENT_MOD then
                            scope.mult = scope.mult * (1 + amount / 100)
                            scope.ids[t.id] = "x"
                        elseif mod.aura == AURA.FLAT_MOD then
                            scope.flat = scope.flat + amount
                            scope.ids[t.id] = scope.ids[t.id] or "+"
                        end
                    end
                end
            end
        end
    end
    return out
end

-- /spelltips verify: for every talent with modifier rows in the data, at every rank, check that each number
-- the data produces appears among the numbers in the game's own text for that rank. Prints the misses.
-- (It compares numbers only; it does not read the words.)
local function TextNumbers(text)
    local found = {}
    for n in (text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gmatch("%d+%.?%d*") do
        found[tonumber(n)] = true
    end
    return found
end

local function Close(set, x)
    for n in pairs(set) do
        if math.abs(n - x) < 0.006 then return true end
    end
end

local function DevVerify(filter)
    if not EnsureNodeMap() then print("[spelltips verify] talent tree not available yet") return end
    filter = (filter or ""):lower()
    local checked, bad, noText, notInTree = 0, 0, {}, 0
    for _, talentID in ipairs(SortedKeys(Data.Mods or {})) do
        local st = spellToNode[talentID]
        local node = st and Try(C_Traits.GetNodeInfo, cachedConfigID, st.nodeID)
        local name = tostring((C_Spell.GetSpellName and C_Spell.GetSpellName(talentID)) or talentID)
        if type(node) ~= "table" then
            notInTree = notInTree + 1
        elseif filter ~= "" and not name:lower():find(filter, 1, true) then
            -- not the talent asked for
        else
            local maxRank = node.maxRanks or 1
            local defRanks = Data.Ranks and Data.Ranks[st.definitionID]
            for rank = 1, maxRank do
                local text = GetTalentText(st.entryID, rank)
                if not text then
                    noText[#noText + 1] = name
                    break
                end
                local nums = TextNumbers(text)
                local shown_text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", "||")
                for i, mod in ipairs(Data.Mods[talentID]) do
                    local amount = math.abs(ModAmount(mod, rank, defRanks))
                    local info = PropInfo(mod) or {}
                    local shown = (mod.aura == AURA.FLAT_MOD and info.unit == "ms") and amount / 1000 or amount
                    checked = checked + 1
                    if not (Close(nums, shown) or (info.unit == "power" and Close(nums, shown / 10))
                            or (info.unit == "ms" and Close(nums, shown / 60))) then  -- long times print as minutes
                        bad = bad + 1
                        print(string.format("[spelltips verify] %s r%d/%d row %d (aura %d prop %d) data %s%s | text: %s",
                            name, rank, maxRank, i, mod.aura, mod.prop, Num(shown),
                            RanksOf(mod, defRanks) and " curve" or " base*rank", shown_text))
                    end
                end
            end
        end
    end
    if #noText > 0 then
        print("[spelltips verify] no text returned by the game for: " .. table.concat(noText, ", "))
    end
    print(string.format("[spelltips verify] %d values checked, %d not found in the text, %d talents with no text, %d not in your tree",
        checked, bad, #noText, notInTree))
end

-- /spelltips ranks <name fragment>: for each matching talent, the game's text at every rank, then the data rows
-- behind it (spell effect index, aura, property, base value, and the per-rank curve when there is one).
local function DevRanks(filter)
    if not EnsureNodeMap() then print("[spelltips ranks] talent tree not available yet") return end
    filter = (filter or ""):lower()
    if filter == "" then print("[spelltips ranks] usage: /spelltips ranks <part of a talent name>") return end
    local shown = 0
    for _, talentID in ipairs(SortedKeys(spellToNode)) do
        local st = spellToNode[talentID]
        local name = tostring((C_Spell.GetSpellName and C_Spell.GetSpellName(talentID)) or talentID)
        if name:lower():find(filter, 1, true) then
            shown = shown + 1
            local node = Try(C_Traits.GetNodeInfo, cachedConfigID, st.nodeID)
            local maxRank = type(node) == "table" and node.maxRanks or 1
            print(string.format("[spelltips ranks] %s (spell %d, definition %s, max %d)", name, talentID, tostring(st.definitionID), maxRank))
            for rank = 1, maxRank do
                local text = GetTalentText(st.entryID, rank)
                print(string.format("   rank %d: %s", rank, text and text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", "||") or "(no text)"))
            end
            local defRanks = Data.Ranks and Data.Ranks[st.definitionID]
            for i, mod in ipairs(Data.Mods and Data.Mods[talentID] or {}) do
                local ranks = defRanks and defRanks[mod.idx]
                print(string.format("   data row %d: effect %d, aura %d, prop %d, base %s, per rank: %s", i, mod.idx, mod.aura, mod.prop,
                    Num(mod.base), ranks and table.concat(ranks, " / ") or "(base x rank)"))
            end
            if not (Data.Mods and Data.Mods[talentID]) then print("   (no modifier rows in the data)") end
        end
    end
    if shown == 0 then print("[spelltips ranks] no talent in your tree matches '" .. filter .. "'") end
end

---------------------------------------------------------------------
-- Collecting talents
---------------------------------------------------------------------
local function MaxRank(t, st)
    return st.max > 0 and st.max or (t.maxRank or 0)
end

local function Entry(t, st, max, extra)
    extra.id, extra.name, extra.rank, extra.max, extra.picked = t.id, t.name, st.rank, max, st.rank > 0
    return extra
end

-- picked talents, and available ones while Shift is held
local function AddUsableTalent(rows, others, t, st, spellData, spellID)
    local max = MaxRank(t, st)
    local picked = st.rank > 0
    local effects, text = TalentEffects(t, st, picked and st.rank or 1, spellData, spellID)
    if #effects == 0 then
        others[#others + 1] = Entry(t, st, max, { text = text })
        D("talent", t.name, picked and "picked" or "available", "-> Other")
        return
    end
    for _, f in ipairs(effects) do
        local mods = GetRow(rows, f.row).mods
        mods[#mods + 1] = Entry(t, st, max, { comp = f.comp })
        D("talent", t.name, picked and "picked" or "available", f.row, f.comp)
    end
end

local function AddLockedTalent(locked, t, st, spellData, spellID)
    local key = st.groupID or 0
    local group = locked.byKey[key]
    if not group then
        local info = treeGroups and treeGroups[key]
        group = { name = info and info.name or "Other", order = info and info.order or 99, list = {} }
        locked.byKey[key] = group
        locked.order[#locked.order + 1] = group
    end
    local effects, text = TalentEffects(t, st, 1, spellData, spellID)
    group.list[#group.list + 1] = {
        id = t.id, name = t.name, need = st.need, max = MaxRank(t, st),
        summary = #effects > 0 and Summarize(effects) or text,
    }
    D("talent", t.name, "locked", group.name, "need", tostring(st.need))
end

-- Sorts the spell's linked talents into rows / others / locked. Returns how many are hidden without Shift.
local function CollectTalents(spellData, spellID, rows, others, locked)
    local hidden = 0
    if not (spellData.talents and #spellData.talents > 0) then return hidden end   -- talents are only listed where the data linked them
    EnsureNodeMap()
    local seen = {}
    for _, t in ipairs(spellData.talents or {}) do
        if not seen[t.id] then
            seen[t.id] = true
            local st = GetTalentState(t.id)
            if not st then
                D("talent not in active tree:", t.name, t.id)
                if S.debug and spellToNode then   -- is the same talent in the tree under another spell ID?
                    local same, total = {}, 0
                    for sid, e in pairs(spellToNode) do
                        total = total + 1
                        if C_Spell.GetSpellName(sid) == t.name then same[#same + 1] = sid .. " (node " .. e.nodeID .. ")" end
                    end
                    D("  tree has", total, "talent spells; same name in tree:", #same > 0 and table.concat(same, ", ") or "none")
                end
            elseif st.rank == 0 and S.level < 3 then
                hidden = hidden + 1
            elseif st.rank > 0 or (st.available and not st.need) then
                AddUsableTalent(rows, others, t, st, spellData, spellID)
            else
                AddLockedTalent(locked, t, st, spellData, spellID)
            end
        end
    end
    return hidden
end

---------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------
-- Every line we add is marked so the next refresh can find and clear it.
-- Tooltip text written by the game can be a "secret" value in combat: it cannot be compared or searched.
-- Returns the text, or nil when it is secret or unreadable.
local function ReadText(fs)
    local ok, text = pcall(fs.GetText, fs)
    if not ok or (issecretvalue and issecretvalue(text)) then return nil end
    return text
end

-- Marks the line just added as ours, remembering the text we gave it (text lines are reused, so the
-- marker only counts while the line still says that). The text comes from us, never read back.
local function MarkCustom(tooltip, leftText, rightText)
    local n, name = tooltip:NumLines(), tooltip:GetName()
    local left, right = _G[name .. "TextLeft" .. n], _G[name .. "TextRight" .. n]
    if left then left.data = { isCustomTalentRow = true, text = leftText } end
    if right then right.data = { isCustomTalentRow = true, text = rightText or "" } end
end

local function Line(tooltip, text, wrap)
    tooltip:AddLine(text, 1, 1, 1, wrap)
    MarkCustom(tooltip, text)
end

local function Pair(tooltip, left, right, shade)
    shade = shade or 1
    tooltip:AddDoubleLine(left, right, shade, shade, shade, shade, shade, shade)
    MarkCustom(tooltip, left, right)
end

local function Header(tooltip, text, suffix, value)
    local left = Color(COLOR.header, text) .. (suffix and ("  " .. Color(COLOR.note, suffix)) or "")
    if value then
        Pair(tooltip, left, Color(COLOR.result, value))
    else
        Line(tooltip, left)
    end
end

-- Registers a talent in scroll order. Returns its color and bullet; the selected talent is gold with ">".
local function Pick(id, hex)
    if not id then return hex, "•" end
    if not S.seen[id] then
        S.seen[id] = true
        S.order[#S.order + 1] = id
    end
    if id == S.selID then return COLOR.sel, ">" end
    return hex, "•"
end

local function TalentLabel(bullet, e)
    return bullet .. " " .. e.name .. " [" .. e.rank .. "/" .. e.max .. "]"
end

local function Bar() return "   " end  -- between a talent and its effect

local function ByPickedThenName(a, b)
    if a.picked ~= b.picked then return a.picked end
    return a.name < b.name
end

local function ByNeedThenName(a, b)
    local na, nb = a.need or 1e9, b.need or 1e9
    if na ~= nb then return na < nb end
    return a.name < b.name
end

-- Talent values sit in the right column. Picked talents that add to or multiply a damage/healing amount are
-- drawn inside that amount's math ("+ name" above the subtotal line, "× name" below it); every other talent
-- follows the row's own lines. An unpicked talent shows its one-rank value, dimmed, marked "per rank".
local function DrawRow(tooltip, name, row)
    Header(tooltip, name, row.suffix, #row.values > 0 and table.concat(row.values, row.joiner or ", ") or nil)
    table.sort(row.mods, ByPickedThenName)
    -- The working under a row (base, spellpower, subtotal, talents) shares the right column with the green
    -- total, so its values are drawn dim: the total is the brightest thing on the edge.
    local function Work(left, right, shade, hex) Pair(tooltip, left, Color(hex or COLOR.pickedVal, right or ""), shade) end
    -- with named blocks (Immediate / Over time) each block's lines sit two spaces further in than its name
    local pad = row.named and "    " or "  "
    local drawn = {}
    local function Mod(m, op)
        drawn[m] = true
        local nameHex, bullet = Pick(m.id, m.picked and COLOR.pickedName or COLOR.availName)
        -- inside the math the × / + takes the bullet's place; the Alt+wheel selection marker still wins
        if bullet == "•" and op then bullet = op == "x" and "×" or "+" end
        local value = m.comp .. ((not m.picked and (m.max or 0) > 1) and " per rank" or "")
        Work((op and pad or "  ") .. Color(nameHex, TalentLabel(bullet, m)), value, nil, not m.picked and COLOR.dim or nil)
    end
    for _, s in ipairs(row.own) do
        if s.talents then
            local any = false
            for _, m in ipairs(row.mods) do
                if m.picked and s.talents.ids[m.id] == s.talents.op then
                    Mod(m, s.talents.op)
                    any = true
                end
            end
            -- talents not drawn at this level: still say what they did to the total
            if not any then Work(pad .. (s.talents.op == "x" and "× " or "+ ") .. "talents", s.combined, 0.6) end
        elseif s.h then
            Line(tooltip, "  " .. Color(COLOR.note, s.h))
        elseif s.sep then
            Work(pad .. Color(COLOR.bar, string.rep("-", 24)), s.sep, 0.6)
        else
            if s.l then Work(pad .. s.l, s.v, 0.6) end
            if s.n then Line(tooltip, pad .. Color(COLOR.note, s.n), true) end
        end
    end
    for _, m in ipairs(row.mods) do
        if not drawn[m] then Mod(m) end
    end
end

local function DrawOthers(tooltip, others)
    Header(tooltip, "Other")
    table.sort(others, ByPickedThenName)
    for _, o in ipairs(others) do
        local hex, bullet = Pick(o.id, o.picked and COLOR.pickedName or COLOR.availName)
        Line(tooltip, "  " .. Color(hex, TalentLabel(bullet, o))
            .. (o.text and (Bar() .. Color(COLOR.note, o.text)) or ""), true)
    end
end

local function DrawLocked(tooltip, groups)
    Line(tooltip, Color(COLOR.section, "LOCKED") .. "  " .. Color(COLOR.dim, "(points still needed)"))
    table.sort(groups, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)
    for _, g in ipairs(groups) do
        Line(tooltip, "  " .. Color(COLOR.section, g.name:upper()))
        table.sort(g.list, ByNeedThenName)
        for _, x in ipairs(g.list) do
            local hex, bullet = Pick(x.id, COLOR.lockedName)
            Pair(tooltip, "  " .. Color(hex, bullet .. " " .. x.name .. " [0/" .. x.max .. "]"),
                Color(COLOR.need, x.need and ("needs " .. x.need .. " more") or "locked"))
            if x.summary then
                Line(tooltip, "      " .. Color(x.id == S.selID and COLOR.selNote or COLOR.lockedName, x.summary), true)
            end
        end
    end
end

local function Draw(tooltip, rows, others, locked, hidden)
    S.order, S.seen = {}, {}
    local drew = false
    local function Gap()
        Line(tooltip, " ")
        drew = true
    end

    local drawn = {}
    local function Row(name)
        if rows[name] and not drawn[name] then
            drawn[name] = true
            if not drew then Gap() end
            DrawRow(tooltip, name, rows[name])
        end
    end
    for _, name in ipairs(ROW_ORDER) do
        if name == "(auras)" then
            for _, label in ipairs(AuraLabels()) do Row(label) end
        else
            Row(name)
        end
    end
    for _, name in ipairs(SortedKeys(rows)) do Row(name) end  -- anything the data produced that has no fixed place
    if #others > 0 then
        Gap()
        DrawOthers(tooltip, others)
    end
    if S.level >= 3 and #locked.order > 0 then
        Gap()
        DrawLocked(tooltip, locked.order)
    elseif S.level == 2 and hidden > 0 and db.moreKey ~= "NONE" then
        Gap()
        Line(tooltip, Color(COLOR.dim, "  hold " .. KEY_NAMES[db.moreKey] .. ": " .. hidden .. " more talent" .. (hidden == 1 and "" or "s")))
    elseif S.level == 1 and db.holdKey ~= "NONE" then
        Gap()
        Line(tooltip, Color(COLOR.dim, "  hold " .. KEY_NAMES[db.holdKey] .. ": talents"))
    end
    if drew then tooltip:SetPadding(1, 0) end
end

local function SweepCustomLines(tooltip)
    local name = tooltip:GetName()
    -- Text lines are reused from draw to draw, so a line that held one of ours earlier can carry our
    -- marker after the game or another addon wrote its own text there (the description, the game's
    -- own hint lines). A marker only counts while the line still says what we wrote.
    for i = tooltip:NumLines(), 1, -1 do
        for _, side in ipairs({ "TextLeft", "TextRight" }) do
            local fs = _G[name .. side .. i]
            local mark = fs and fs.data
            if mark and mark.isCustomTalentRow then
                local current = ReadText(fs)   -- nil: secret game text in combat, not ours
                if current ~= nil and (current == mark.text or (current == "" and mark.text == "")) then
                    fs:SetText("")
                end
                fs.data = nil
            end
        end
    end
end

---------------------------------------------------------------------
-- Tooltip hook
---------------------------------------------------------------------
local nameIndex  -- [spell name] = sorted spell IDs in Data.lua, built on first use

-- Data.lua entry for a spell ID; other ranks of a spell fall back to the same-named entry for the player's class.
local function SpellDataFor(spellID)
    local exact = Data.AddonData[spellID]
    if exact then return exact, "exact" end
    local name = C_Spell.GetSpellName(spellID)
    if not name then return nil end

    if not nameIndex then
        nameIndex = {}
        for id, sd in pairs(Data.AddonData) do
            if sd.name then
                nameIndex[sd.name] = nameIndex[sd.name] or {}
                table.insert(nameIndex[sd.name], id)
            end
        end
        for _, ids in pairs(nameIndex) do table.sort(ids) end
    end

    local classSet = PlayerClassSet()
    for _, id in ipairs(nameIndex[name] or {}) do
        local sd = Data.AddonData[id]
        if sd.classSet == 0 or sd.classSet == classSet then return sd, "name-fallback -> " .. id end
    end
end

-- A "Proc chance" row says how often something happens; say what happens, in the game's own words
-- (the spell its proc-trigger effect fires, from Data.lua)
local function AddProcNotes(rows, spellData)
    local row = rows["Proc chance"]
    if not (row and spellData.procs) then return end
    for _, proc in ipairs(spellData.procs) do
        local name = C_Spell.GetSpellName(proc.id)
        if name then
            local desc = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(proc.id)
            if desc and desc ~= "" then
                row.own[#row.own + 1] = { n = name .. ": " .. desc }
            else
                -- a hidden helper spell has no text of its own: give its name and length, then the
                -- game's own words from the talent that changes the chance
                local seconds = (proc.ms or 0) > 0 and (" (" .. Fmt(proc.ms / 1000) .. " sec)") or ""
                row.own[#row.own + 1] = { n = name .. seconds }
                local src = row.mods[1] and S.sources[row.mods[1].id]
                if src and src.text and src.text ~= "" then row.own[#row.own + 1] = { n = src.text } end
            end
        end
    end
end

-- Runs fn; on an error, remembers it for /spelltips report and returns nothing.
local function Guard(name, fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    S.hookError = name .. ": " .. tostring(result)
end

local function DrawSpellTips(tooltip, data)
    if not (Data.AddonData and data and data.id and data.lines) then return end
    local spellID = data.id
    local spellData, via = SpellDataFor(spellID)
    if not (spellData and spellData.lines) then return end
    D("spell", spellID, via, "talents:", spellData.talents and #spellData.talents or 0)

    if S.selSpell ~= spellID then S.selSpell, S.selID = spellID, nil end
    SweepCustomLines(tooltip)
    if S.level == 0 then
        S.selID = nil
        tooltip:SetPadding(0, 0)
        return
    end

    S.sources = {}
    local rows, others, locked = {}, {}, { byKey = {}, order = {} }
    -- each row source runs on its own, so one failing never loses the others (or the game's tooltip)
    Guard("own lines", AddOwnLines, rows, spellData, spellID)
    local hidden = 0
    if S.level >= 2 then
        hidden = Guard("talents", CollectTalents, spellData, spellID, rows, others, locked) or 0
        Guard("aura talents", MergeAuraTalents, rows)
    end
    Guard("aura rows", PruneAuraRows, rows)
    Guard("proc notes", AddProcNotes, rows, spellData)
    Guard("api values", AddApiValues, rows, spellID, spellData)
    Guard("hit and crit", AddHitCrit, rows, spellData)
    if tooltip ~= preview.tooltip then  -- the preview must not replace what /spelltips report describes
        S.last = { id = spellID, name = C_Spell.GetSpellName(spellID), via = via, level = S.level,
                   rows = rows, others = others, sources = S.sources }
    end
    Draw(tooltip, rows, others, locked, hidden)
end

local function ApplyInlineScaling(tooltip, data)
    if tooltip ~= preview.tooltip then return DrawSpellTips(tooltip, data) end
    local saved = S.level
    S.level = preview.level
    local ok, err = pcall(DrawSpellTips, tooltip, data)
    S.level = saved
    if not ok then error(err, 0) end
end

-- The registered hook: never lets an error reach the game's tooltip, and skips secret spell ids.
local function SafeApply(tooltip, data)
    if data and issecretvalue and issecretvalue(data.id) then return end
    local ok, err = pcall(ApplyInlineScaling, tooltip, data)
    if not ok then S.hookError = tostring(err) end
end

-- Re-sets the tooltip to the game's own content (which drops our lines); the hook then redraws ours.
local function RefreshTooltip(tooltip)
    local data = tooltip.GetTooltipData and tooltip:GetTooltipData()
    if not data then return end
    if data.id and tooltip.SetSpellByID then
        tooltip:SetSpellByID(data.id)
    else
        SafeApply(tooltip, data)
    end
end

---------------------------------------------------------------------
-- Jumping to a talent in the talent window
---------------------------------------------------------------------
local blink

local function BlinkButton(button)
    if not blink then
        blink = CreateFrame("Frame", nil, UIParent)
        blink:SetFrameStrata("TOOLTIP")
        local tex = blink:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetColorTexture(1, 0.82, 0, 0.55)
        blink.anim = blink:CreateAnimationGroup()
        blink.anim:SetLooping("BOUNCE")
        local alpha = blink.anim:CreateAnimation("Alpha")
        alpha:SetFromAlpha(1)
        alpha:SetToAlpha(0.15)
        alpha:SetDuration(0.35)
    end
    blink:ClearAllPoints()
    blink:SetPoint("TOPLEFT", button, "TOPLEFT", -6, 6)
    blink:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 6, -6)
    blink:Show()
    blink.anim:Play()

    blink.token = (blink.token or 0) + 1  -- a newer blink keeps an older blink's timer from cutting it short
    local token = blink.token
    C_Timer.After(3, function()
        if blink.token == token then
            blink.anim:Stop()
            blink:Hide()
        end
    end)
end

-- the on-screen button for a talent, if the talent window has been opened
local function TalentButton(spellID)
    local entry = spellToNode and spellToNode[spellID]
    local window = _G.PlayerSpellsFrame
    local talents = window and (window.TalentsFrame or window.ClassTalentsFrame)
    if not (entry and talents and talents.GetTalentButtonByNodeID) then return nil end
    local button = Try(talents.GetTalentButtonByNodeID, talents, entry.nodeID)
    return type(button) == "table" and button or nil
end

-- opens the talents tab and blinks that talent
local function OpenTalent(spellID)
    if not (EnsureNodeMap() and spellToNode[spellID]) then return false end
    if not (PlayerSpellsUtil and PlayerSpellsUtil.OpenToClassTalentsTab) then return false end
    pcall(PlayerSpellsUtil.OpenToClassTalentsTab)
    C_Timer.After(0.4, function()  -- the window builds its buttons after opening
        local button = TalentButton(spellID)
        if button then BlinkButton(button) end
    end)
    return true
end

local function DevTalent(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    if msg == "" then print("[spelltips talent] usage: /spelltips talent Frost Channeling   or   /spelltips talent 11160") return end
    if not EnsureNodeMap() then print("[spelltips talent] node map build FAILED") return end

    local spellID = tonumber(msg)
    if not spellID then
        local wanted = msg:lower()
        for id in pairs(spellToNode) do
            local name = C_Spell.GetSpellName(id)
            if name and name:lower() == wanted then spellID = id break end
        end
    end
    if not (spellID and spellToNode[spellID]) then print("[spelltips talent] no talent matches", msg) return end
    if not OpenTalent(spellID) then print("[spelltips talent] can't open the talent window on this client") end
end

---------------------------------------------------------------------
-- Alt+wheel selection
---------------------------------------------------------------------
local function StepTalent(direction)
    if not (S.hold and S.level >= 2) or #S.order == 0 then return end
    local index = 0
    for i, id in ipairs(S.order) do
        if id == S.selID then index = i break end
    end
    index = index + direction
    if index > #S.order then index = 1 elseif index < 1 then index = #S.order end
    S.selID = S.order[index]

    RefreshTooltip(GameTooltip)

    local window = _G.PlayerSpellsFrame
    local button = window and window:IsShown() and TalentButton(S.selID)
    if button then BlinkButton(button) end
end

local bindOwner = CreateFrame("Frame")
CreateFrame("Button", "SpellTipsPrev", UIParent):SetScript("OnClick", function() StepTalent(-1) end)
CreateFrame("Button", "SpellTipsNext", UIParent):SetScript("OnClick", function() StepTalent(1) end)

-- "ALT-CTRL-SHIFT-" in the order the game expects, for whichever of those keys are given
local function ModifierPrefix(...)
    local on = {}
    for _, key in ipairs({ ... }) do on[key] = true end
    return (on.ALT and "ALT-" or "") .. (on.CTRL and "CTRL-" or "") .. (on.SHIFT and "SHIFT-" or "")
end

-- The wheel steps through talents while holdKey is down. Bindings can't change in combat, so a change
-- made then is applied when combat ends. Without holdKey there is nothing to bind (the wheel would zoom).
-- Data.lua records which game build its numbers came from; say so when this client is a different one.
local function CheckDataBuild()
    local stamp = Data.Build
    if not (stamp and stamp.build and stamp.build ~= "") then return end
    local _, build = GetBuildInfo()
    if build and tostring(build) ~= tostring(stamp.build) then
        print("|cffff8000[spelltips]|r Data.lua was made from game build " .. tostring(stamp.build)
            .. " but this client is build " .. tostring(build) .. ". Numbers may be out of date until it is regenerated.")
    end
end

local function BindWheel()
    if InCombatLockdown() then S.rebind = true return end
    S.rebind = false
    ClearOverrideBindings(bindOwner)
    if db.holdKey == "NONE" then return end
    local prefixes = { ModifierPrefix(db.holdKey) }
    if db.moreKey ~= "NONE" then prefixes[2] = ModifierPrefix(db.holdKey, db.moreKey) end
    for _, prefix in ipairs(prefixes) do
        SetOverrideBindingClick(bindOwner, false, prefix .. "MOUSEWHEELUP", "SpellTipsPrev")
        SetOverrideBindingClick(bindOwner, false, prefix .. "MOUSEWHEELDOWN", "SpellTipsNext")
    end
end

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------
local function ApplyColors()
    for key, default in pairs(COLOR_DEFAULT) do
        local hex = db.colors[key]
        COLOR[key] = (type(hex) == "string" and hex:match("^%x%x%x%x%x%x$")) and hex or default
    end
end

-- moreKey must differ from holdKey; values that aren't recognised go back to the defaults
local function NormalizeSettings()
    if not (KEY_DOWN[db.holdKey] or db.holdKey == "NONE") then db.holdKey = DEFAULTS.holdKey end
    if not (KEY_DOWN[db.moreKey] or db.moreKey == "NONE") then db.moreKey = DEFAULTS.moreKey end
    if db.moreKey ~= "NONE" and db.moreKey == db.holdKey then
        db.moreKey = "NONE"
        for _, key in ipairs(KEY_ORDER) do
            if key ~= db.holdKey then db.moreKey = key break end
        end
    end
    db.alwaysLevel = math.max(0, math.min(3, math.floor(tonumber(db.alwaysLevel) or 0)))
    db.minimapAngle = tonumber(db.minimapAngle) or DEFAULTS.minimapAngle
    db.minimapHide = db.minimapHide and true or false
end

local RefreshMinimap  -- defined with the minimap button

local RefreshPreview  -- defined with the settings window

local function RefreshOpenTooltip()
    S.level = -1  -- the next frame recomputes the level and redraws
    if GameTooltip:IsShown() and GameTooltip:GetOwner() then RefreshTooltip(GameTooltip) end
    RefreshPreview()
end

local function ApplySettings()
    NormalizeSettings()
    if RefreshMinimap then RefreshMinimap() end
    ApplyColors()
    BindWheel()
    RefreshOpenTooltip()
end

local function LoadSettings()
    SpellTipsDB = type(SpellTipsDB) == "table" and SpellTipsDB or {}
    for key, value in pairs(DEFAULTS) do
        if SpellTipsDB[key] == nil then SpellTipsDB[key] = value end
    end
    SpellTipsDB.colors = type(SpellTipsDB.colors) == "table" and SpellTipsDB.colors or {}
    SpellTipsDB.heal = nil  -- settings of the removed heal-label test
    db = SpellTipsDB
    ApplySettings()
end

local function ResetSettings()
    for key, value in pairs(DEFAULTS) do db[key] = value end
    db.colors = {}
    ApplySettings()
end

---------------------------------------------------------------------
-- Windows: small widget helpers
---------------------------------------------------------------------
-- A template that this client doesn't have must not stop the window from being built.
local function NewFrame(kind, name, parent, template)
    local ok, f = pcall(CreateFrame, kind, name, parent, template)
    if ok and f then return f end
    return CreateFrame(kind, name, parent)
end

local PANEL_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local function NewPanel(name, width, height, title)
    local f = NewFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetBackdrop then f:SetBackdrop(PANEL_BACKDROP) end
    local heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOP", 0, -18)
    heading:SetText(title)
    f.heading = heading
    NewFrame("Button", nil, f, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -6, -6)
    f:Hide()
    table.insert(UISpecialFrames, name)  -- Esc closes it
    return f
end

local function NewButton(parent, text, width, onClick)
    local b = NewFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function KeyOptions(exclude)
    local list = {}
    for _, key in ipairs(KEY_ORDER) do
        if key ~= exclude then list[#list + 1] = { key, KEY_NAMES[key] } end
    end
    list[#list + 1] = { "NONE", KEY_NAMES.NONE }
    return list
end

local LEVEL_OPTIONS = { { 0, "Off (hold a key)" }, { 1, "Numbers only" }, { 2, "Numbers + talents" }, { 3, "Everything" } }

local COLOR_LABELS = {
    { "header", "Row names (Damage, Cost...)" },     { "result", "Row totals (right side)" },
    { "pickedName", "Talents you have picked" },     { "pickedVal", "Working under a row (base, talents...)" },
    { "availName", "Talents you could take" },       { "dim", "Amounts of talents not taken, hints" },
    { "lockedName", "Locked talents" },              { "need", "\"needs N more\"" },
    { "section", "Headings (LOCKED, tree names)" },  { "note", "Detail text under a row, Other" },
    { "sel", "Talent chosen with the wheel" },       { "selNote", "Chosen locked talent's text" },
}

local function HexToRGB(hex)
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

local function RGBToHex(r, g, b)
    return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function PickColor(key, paint)
    local before = db.colors[key]
    local r, g, b = HexToRGB(COLOR[key])
    local function chosen()
        db.colors[key] = RGBToHex(ColorPickerFrame:GetColorRGB())
        ApplyColors()
        paint()
        RefreshOpenTooltip()
    end
    local function cancelled()
        db.colors[key] = before
        ApplyColors()
        paint()
        RefreshOpenTooltip()
    end
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({ r = r, g = g, b = b, hasOpacity = false, swatchFunc = chosen, cancelFunc = cancelled })
    else  -- older picker
        ColorPickerFrame.func, ColorPickerFrame.cancelFunc, ColorPickerFrame.hasOpacity = chosen, cancelled, false
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Hide()
        ColorPickerFrame:Show()
    end
end

---------------------------------------------------------------------
-- Settings window
---------------------------------------------------------------------
local optionsPage, optionsCategory  -- the SpellTips page in the game's Options window
local ShowReport

-- Spells to preview: the ones on the action bars that have talent data, most talents first
-- (the same spells with other ranks count once). With empty bars, the player's class spells in the data.
local function PreviewCandidates()
    local found, byName = {}, {}
    local function consider(spellID)
        local data = spellID and SpellDataFor(spellID)
        local name = spellID and C_Spell.GetSpellName(spellID)
        if not (data and data.lines and next(data.lines) and data.talents and #data.talents > 0 and name) then return end
        if byName[name] then return end
        byName[name] = true
        found[#found + 1] = { id = spellID, name = name, score = #data.talents }
    end
    if GetActionInfo then
        for slot = 1, 180 do
            local kind, id = GetActionInfo(slot)
            if kind == "spell" then consider(id) end
        end
    end
    if #found == 0 and Data.AddonData then
        local classSet = PlayerClassSet()
        for id, data in pairs(Data.AddonData) do
            if data.classSet == classSet and data.talents and #data.talents > 0 then consider(id) end
        end
    end
    table.sort(found, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.id < b.id
    end)
    while #found > 8 do table.remove(found) end
    return found
end

local previewCandidates

local function HasCustomLines(tooltip)
    local name = tooltip:GetName()
    for i = 1, tooltip:NumLines() do
        local left = _G[name .. "TextLeft" .. i]
        if left and left.data and left.data.isCustomTalentRow then return true end
    end
end

-- (Re)draws the preview where tooltips normally appear, with one talent marked as the wheel's choice so those colors show too.
local function DrawPreview()
    local tooltip = preview.tooltip
    if not tooltip then
        tooltip = NewFrame("GameTooltip", "SpellTipsPreview", UIParent, "GameTooltipTemplate")
        preview.tooltip = tooltip
    end
    if not preview.spell then tooltip:Hide() return end
    -- a spell's description text arrives from the server after the first request; ask for it now and
    -- redraw when SPELL_DATA_LOAD_RESULT says it is here (a hovered tooltip refreshes itself, this one would not)
    -- (the result event can fire from inside the request itself, so ask once per spell and redraw only for that request)
    if C_Spell and C_Spell.RequestLoadSpellData and not preview.asked[preview.spell]
        and not (C_Spell.IsSpellDataCached and C_Spell.IsSpellDataCached(preview.spell)) then
        preview.asked[preview.spell] = true
        C_Spell.RequestLoadSpellData(preview.spell)
    end
    local docked = optionsPage and optionsPage.PlacePreview
    local function set()
        if docked then  -- inside the SpellTips Options page, where it can't cover the settings
            tooltip:SetOwner(optionsPage, "ANCHOR_NONE")
            optionsPage.PlacePreview(tooltip, false)
        elseif GameTooltip_SetDefaultAnchor then  -- where this player's tooltips normally appear
            GameTooltip_SetDefaultAnchor(tooltip, UIParent)
        else
            tooltip:SetOwner(UIParent, "ANCHOR_NONE")
            tooltip:ClearAllPoints()
            tooltip:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -100, 100)
        end
        tooltip:SetSpellByID(preview.spell)
        -- if this client does not run the tooltip hook for this frame, draw directly
        if not HasCustomLines(tooltip) and tooltip.GetTooltipData then
            local data = tooltip:GetTooltipData()
            if data then ApplyInlineScaling(tooltip, data) end
        end
        tooltip:Show()
    end
    S.selID = nil
    set()
    S.selID = S.order[#S.order]  -- the last one listed is a locked talent when there is one, which shows both selection colors
    if S.selID then set() end
    S.selID = nil  -- the choice is only for the picture; a real tooltip must not inherit it
    if docked then optionsPage.PlacePreview(tooltip, true) end  -- now that its size is known, make room for it
end

function RefreshPreview()
    if optionsPage and optionsPage:IsVisible() then DrawPreview() end
end

-- The SpellTips page in the game's Options window (Options > AddOns > SpellTips). Nothing has a fixed width or a fixed
-- y step: the page is a scroll frame whose content is as wide as the space the Options window gives it, every row is
-- pinned at both edges, text wraps, each row's height is measured from what it shows, and buttons are as wide as
-- their (widest) text. layout() runs on show and once more a frame later, when wrapped text knows its height.
-- The preview tooltip docks at the page's top right and the rows are narrowed by its measured width (labels wrap to
-- what is left). It always goes beside the rows: a preview is usually taller than the page, and below the rows the
-- game's clamp-to-screen pushed it back up over them.
local function BuildOptionsPage()
    local MARGIN, GAP, PAD, SWATCH = 16, 10, 32, 22   -- PAD: a button's end caps; SWATCH: a color button's size
    local page = NewFrame("Frame", nil, UIParent)
    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -4)
    -- the template hangs its scroll bar 6px outside the frame's right edge
    scroll:SetPoint("BOTTOMRIGHT", -(scroll.ScrollBar:GetWidth() + 6 + 4), 4)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    -- "there's more": the page's bottom edge fades out with a "Scroll for more" note while content continues below,
    -- the top edge fades once you've scrolled down, and the scroll bar only shows when there is something to scroll.
    -- Driven by the scroll frame's own events (range changed, scrolled); the fades sit on a frame above the rows.
    local edges = CreateFrame("Frame", nil, page)
    edges:SetAllPoints(scroll)
    edges:SetFrameLevel(scroll:GetFrameLevel() + 10)
    local moreText = edges:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moreText:SetPoint("BOTTOM", edges, "BOTTOM", 0, 2)
    moreText:SetText("Scroll for more")
    local function Fade(point, dark)  -- a strip along one edge, opaque at the edge, clear toward the middle
        local t = edges:CreateTexture(nil, "ARTWORK")
        t:SetPoint(point .. "LEFT", edges, point .. "LEFT", 0, 0)
        t:SetPoint(point .. "RIGHT", edges, point .. "RIGHT", 0, 0)
        local _, fontSize = moreText:GetFont()
        t:SetHeight(math.ceil(fontSize or 10) * 3)  -- three lines of the note's font
        t:SetColorTexture(1, 1, 1, 1)
        local opaque, clear = CreateColor(0, 0, 0, dark), CreateColor(0, 0, 0, 0)
        if point == "BOTTOM" then t:SetGradient("VERTICAL", opaque, clear) else t:SetGradient("VERTICAL", clear, opaque) end
        return t
    end
    local fadeBottom, fadeTop = Fade("BOTTOM", 0.9), Fade("TOP", 0.9)
    local function UpdateEdges()
        local range, at = scroll:GetVerticalScrollRange() or 0, scroll:GetVerticalScroll() or 0
        local below, above = at < range - 1, at > 1
        fadeBottom:SetShown(below)
        moreText:SetShown(below)
        fadeTop:SetShown(above)
        scroll.ScrollBar:SetShown(range > 1)
    end
    scroll:HookScript("OnScrollRangeChanged", UpdateEdges)
    scroll:HookScript("OnVerticalScroll", UpdateEdges)

    local refreshers, layout = {}, nil
    local function refreshAll()
        for _, fn in ipairs(refreshers) do fn() end
        if layout then layout() end
    end

    local rows = {}
    local rightInset = 0  -- room kept free on the right for the docked preview
    local function AnchorRow(i)
        local row, prev = rows[i], rows[i - 1]
        row:ClearAllPoints()
        if prev then
            row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -row.gap)
        else
            row:SetPoint("TOPLEFT", content, "TOPLEFT", MARGIN, -MARGIN)
        end
        row:SetPoint("RIGHT", content, "RIGHT", -(MARGIN + rightInset), 0)
    end
    local function AddRow(gapBefore)
        local row = CreateFrame("Frame", nil, content)
        row.gap = gapBefore or GAP
        rows[#rows + 1] = row
        AnchorRow(#rows)
        return row
    end

    local function AddText(text, font, justify, gapBefore)
        local row = AddRow(gapBefore)
        local fs = row:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        row.measure = function() return fs:GetStringHeight() end
        return fs
    end

    local function FitButton(b) b:SetWidth(math.ceil(b:GetFontString():GetStringWidth()) + PAD) end

    -- a label (wraps) on the left, a button on the right stepping through { { value, shown text }, ... }
    -- (left click: next, right click: previous); the button is as wide as its widest choice
    local function AddCycle(label, options, get, set, afterChange)
        local row = AddRow()
        local button
        local function refresh()
            for _, o in ipairs(options()) do
                if o[1] == get() then button:SetText(o[2]) return end
            end
        end
        button = NewButton(row, "", 1, function(_, mouse)
            local list, index = options(), 1
            for i, o in ipairs(list) do
                if o[1] == get() then index = i break end
            end
            index = (mouse == "RightButton") and ((index - 2) % #list + 1) or (index % #list + 1)
            set(list[index][1])
            ApplySettings()
            if afterChange then afterChange() end
        end)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("LEFT", row, "LEFT", 0, 0)
        text:SetPoint("RIGHT", button, "LEFT", -GAP, 0)
        text:SetJustifyH("LEFT")
        text:SetText(label)
        refreshers[#refreshers + 1] = function()
            local fs, widest = button:GetFontString(), 0
            for _, o in ipairs(options()) do
                button:SetText(o[2])
                widest = math.max(widest, fs:GetStringWidth())
            end
            button:SetWidth(math.ceil(widest) + PAD)
            refresh()
        end
        row.measure = function() return math.max(button:GetHeight(), text:GetStringHeight()) end
    end

    AddText("Hold a key over a spell to see the numbers behind it. Type /spelltips any time to come back here.",
        "GameFontHighlight")

    AddCycle("Key that shows talents", function() return KeyOptions() end,
        function() return db.holdKey end, function(v) db.holdKey = v end, refreshAll)
    AddCycle("Key that adds locked talents", function() return KeyOptions(db.holdKey) end,
        function() return db.moreKey end, function(v) db.moreKey = v end, refreshAll)
    AddCycle("Shown with no key held", function() return LEVEL_OPTIONS end,
        function() return db.alwaysLevel end, function(v) db.alwaysLevel = v end, refreshAll)
    AddCycle("Preview spell",
        function()
            local list = {}
            for _, c in ipairs(previewCandidates or {}) do list[#list + 1] = { c.id, c.name } end
            if #list == 0 then list[1] = { false, "none found" } end
            return list
        end,
        function() return preview.spell or false end,
        function(v) preview.spell = v or nil end, function() refreshAll() DrawPreview() end)

    AddText("Colors   (click to change, right-click to reset one; hover one to outline where it's used)", "GameFontNormal", "LEFT", 2 * GAP)

    -- Hovering a color outlines where the preview uses it, without changing any color (so the colors can still be
    -- judged). The spots are found once per preview, not per hover: the preview is drawn once with every color swapped
    -- for its own marker (several settings share the same gray by default, so only a swap tells them apart), each
    -- marker's lines are noted, and the preview is drawn again in the real colors. A hover then only moves outlines.
    -- The finding pass runs a frame after the preview changes, once however many changes came in that frame.
    local marking            -- the color key under the mouse
    local hitsByKey = {}     -- key -> { "TextLeft3", "TextRight7", ... } for the preview as drawn now
    local finding, findQueued = false, false
    local boxes = {}
    local function Outline(tip)
        local box = CreateFrame("Frame", nil, tip)
        -- { from, to, horizontal }: top, bottom, left, right
        for _, edge in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                                { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
            local t = box:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(1, 0, 1, 1)
            t:SetPoint(edge[1], box, edge[1], 0, 0)
            t:SetPoint(edge[2], box, edge[2], 0, 0)
            if edge[3] then t:SetHeight(1) else t:SetWidth(1) end
        end
        return box
    end
    local function MarkPreview()
        for _, box in ipairs(boxes) do box:Hide() end
        local tip = preview.tooltip
        local hits = marking and hitsByKey[marking]
        if not (hits and tip and tip:IsShown()) then return end
        local name = tip:GetName()
        for n, hit in ipairs(hits) do
            local fs = _G[name .. hit]
            if fs and fs:IsShown() then
                local box = boxes[n] or Outline(tip)
                boxes[n] = box
                box:ClearAllPoints()
                box:SetPoint("TOPLEFT", fs, "TOPLEFT", -2, 2)
                box:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 2, -2)
                box:Show()
            end
        end
    end
    local function FindAll()
        findQueued = false
        local tip = preview.tooltip
        if not (page:IsVisible() and tip and preview.spell) then return end
        local used, markers, n = {}, {}, 0
        for _, hex in pairs(COLOR) do used[hex:lower()] = true end
        for _, entry in ipairs(COLOR_LABELS) do
            local hex
            repeat
                n = n + 1
                hex = string.format("fe%04x", n)
            until not used[hex]
            markers[entry[1]] = hex
        end
        finding = true
        for key, hex in pairs(markers) do COLOR[key] = hex end
        DrawPreview()  -- the finding pass
        local found, name = {}, tip:GetName()
        for i = 1, tip:NumLines() do
            for _, side in ipairs({ "TextLeft", "TextRight" }) do
                local fs = _G[name .. side .. i]
                local text = fs and fs:IsShown() and fs:GetText()
                if type(text) == "string" and not (issecretvalue and issecretvalue(text)) then
                    text = text:lower()
                    for key, hex in pairs(markers) do
                        if text:find("|cff" .. hex, 1, true) then
                            found[key] = found[key] or {}
                            found[key][#found[key] + 1] = side .. i
                        end
                    end
                end
            end
        end
        ApplyColors()
        DrawPreview()  -- the real colors
        finding = false
        hitsByKey = found
        MarkPreview()
    end
    -- called after every preview draw
    page.MarkPreview = function()
        if not finding then
            hitsByKey = {}
            if not findQueued then
                findQueued = true
                C_Timer.After(0, FindAll)
            end
        end
        MarkPreview()
    end
    local function Mark(key)
        marking = key
        MarkPreview()
    end
    page.Unmark = function() Mark(nil) end

    for _, entry in ipairs(COLOR_LABELS) do
        local key, label = entry[1], entry[2]
        local row = AddRow(GAP / 2)
        local swatch = NewButton(row, "", SWATCH, nil)
        swatch:SetSize(SWATCH, SWATCH)
        swatch:SetPoint("LEFT", row, "LEFT", 0, 0)
        swatch.texture = swatch:CreateTexture(nil, "OVERLAY")
        swatch.texture:SetPoint("TOPLEFT", 4, -4)
        swatch.texture:SetPoint("BOTTOMRIGHT", -4, 4)
        local function paint() swatch.texture:SetColorTexture(HexToRGB(COLOR[key])) end
        refreshers[#refreshers + 1] = paint
        swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        swatch:SetScript("OnClick", function(_, mouse)
            if mouse == "RightButton" then
                db.colors[key] = nil
                ApplyColors()
                paint()
                RefreshOpenTooltip()
                DrawPreview()
            else
                PickColor(key, function() paint() DrawPreview() end)
            end
        end)
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
        text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        text:SetJustifyH("LEFT")
        text:SetText(label)
        row.measure = function() return math.max(SWATCH, text:GetStringHeight()) end
        local function enter() Mark(key) end
        local function leave() if not row:IsMouseOver() then Mark(nil) end end  -- moving onto the swatch is still inside the row
        row:EnableMouse(true)
        row:SetScript("OnEnter", enter)
        row:SetScript("OnLeave", leave)
        swatch:HookScript("OnEnter", enter)
        swatch:HookScript("OnLeave", leave)
    end

    AddText("Wheel through talents with the first key held. Right-click a button to go back.",
        "GameFontDisableSmall", "LEFT", 2 * GAP)

    local resetRow = AddRow(GAP)
    local resetButton = NewButton(resetRow, "Reset all", 1, function() ResetSettings() refreshAll() DrawPreview() end)
    resetButton:SetPoint("TOPLEFT", resetRow, "TOPLEFT", 0, 0)
    FitButton(resetButton)
    resetRow.measure = function() return resetButton:GetHeight() end

    local previewTip, scaledFor  -- scaledFor: the spell the preview's current scale was worked out for
    local function AnchorPreview()
        if not previewTip then return end
        previewTip:ClearAllPoints()
        previewTip:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -MARGIN, -MARGIN)  -- fixed to the visible page, not the scrolling rows
    end

    -- rescale: measure the preview again and resize it. Right after a redraw the tooltip has not finished sizing itself,
    -- so that pass keeps the current scale; the tooltip's own OnSizeChanged rescales once its size is final.
    layout = function(rescale)
        rightInset = 0
        if previewTip and previewTip:IsShown() then
            -- Shrink a preview taller than the page so it ends inside it. A tooltip re-wraps its text when its scale
            -- changes, so its height moves with every new scale; letting the scale go back up chased that and stretched
            -- it. So for one spell the scale only ever goes down: it settles, and never grows over the Close button.
            -- Heights are compared in screen units: the tooltip hangs off UIParent, the page has the Options window's scale.
            local base = previewTip:GetEffectiveScale() / previewTip:GetScale()  -- its scale without its own SetScale
            local scale = previewTip:GetScale()
            if rescale ~= false then
                local roomPx = (scroll:GetHeight() - 2 * MARGIN) * scroll:GetEffectiveScale()
                local tipPx = previewTip:GetHeight() * base
                local fit = (tipPx > 0 and roomPx > 0) and math.min(1, roomPx / tipPx) or 1
                if scaledFor == preview.spell then
                    scale = math.min(scale, fit)
                else
                    scale, scaledFor = fit, preview.spell
                end
                previewTip:SetScale(scale)
            end
            -- the room the rows leave for it, in the page's own units
            rightInset = math.ceil(previewTip:GetWidth() * base * scale / content:GetEffectiveScale()) + 2 * GAP
        end
        for i = 1, #rows do AnchorRow(i) end
        local total = MARGIN
        for i, row in ipairs(rows) do
            local h = math.max(1, math.ceil(row.measure() or 0))
            row:SetHeight(h)
            total = total + h + (i > 1 and row.gap or 0)
        end
        content:SetHeight(total + MARGIN)
        AnchorPreview()
    end
    -- DrawPreview hands the tooltip over before drawing (anchor only) and after (size known: lay out again)
    page.PlacePreview = function(tooltip, measured)
        previewTip = tooltip
        if not tooltip.stSizeHook then  -- the tooltip says when it has finished sizing itself
            tooltip.stSizeHook = true
            tooltip:HookScript("OnSizeChanged", function() if page:IsVisible() then layout() end end)
        end
        if measured then
            if page.MarkPreview then page.MarkPreview() end
            layout(false)
        else
            AnchorPreview()
        end
    end
    scroll:SetScript("OnSizeChanged", function(_, w)
        content:SetWidth(w)
        layout()
    end)
    page:SetScript("OnShow", function()
        scaledFor = nil  -- the Options window may have a new size: work the scale out afresh
        previewCandidates = PreviewCandidates()
        local listed = false
        for _, c in ipairs(previewCandidates) do if c.id == preview.spell then listed = true end end
        if not listed then preview.spell = previewCandidates[1] and previewCandidates[1].id end
        content:SetWidth(scroll:GetWidth())
        refreshAll()
        DrawPreview()
        -- wrapped text reports its final height only after it has been drawn at its width
        C_Timer.After(0, layout)
        UpdateEdges()
    end)
    page:SetScript("OnHide", function()
        page.Unmark()
        if preview.tooltip then preview.tooltip:Hide() end
    end)
    page.OnDefault = function() ResetSettings() refreshAll() end  -- the Options window's Defaults button
    return page
end

local function ShowSettings()
    if optionsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(optionsCategory:GetID())
    else
        print("[spelltips] this client has no Options page for addons")
    end
end

---------------------------------------------------------------------
---------------------------------------------------------------------
-- Settings shortcuts: a minimap button (drag it around the edge) and an entry in the addon list
---------------------------------------------------------------------
local ICON = "Interface\\Icons\\INV_Misc_Book_09"
local minimapButton

local function ToggleSettings()
    ShowSettings()  -- closing the Blizzard Options window from addon code taints the Game Menu it returns to
end

local function PlaceMinimapButton()
    local angle = math.rad(db.minimapAngle or DEFAULTS.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function RefreshMinimap()
    if not (Minimap and db) then return end
    if not minimapButton then
        local b = NewFrame("Button", "SpellTipsMinimapButton", Minimap)
        minimapButton = b
        b:SetSize(31, 31)
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(8)
        b:RegisterForClicks("LeftButtonUp")
        b:RegisterForDrag("LeftButton")
        local icon = b:CreateTexture(nil, "BACKGROUND")
        icon:SetTexture(ICON)
        icon:SetSize(20, 20)
        icon:SetPoint("CENTER", 0, 1)
        local border = b:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        b:SetScript("OnClick", ToggleSettings)
        b:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local cx, cy = GetCursorPosition()
                local scale = Minimap:GetEffectiveScale()
                db.minimapAngle = math.deg((math.atan2 or math.atan)(cy / scale - my, cx / scale - mx))
                PlaceMinimapButton()
            end)
        end)
        b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("SpellTips")
            GameTooltip:AddLine("Click: settings   Drag: move", 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    PlaceMinimapButton()
    if db.minimapHide then minimapButton:Hide() else minimapButton:Show() end
end

-- the entry in the addon list under the minimap, where this client has one
local function RegisterCompartment()
    if AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon then
        AddonCompartmentFrame:RegisterAddon({ text = "SpellTips", icon = ICON, notCheckable = true, func = ToggleSettings })
    end
end

-- Report window: what was on screen, in text to copy and send
---------------------------------------------------------------------
local function Plain(text)
    return ((text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " "))
end

local function BuildReport()
    local out = {}
    local function add(text) out[#out + 1] = text end
    local version, build = GetBuildInfo()
    local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local className = UnitClass("player")
    local spells = 0
    for _ in pairs(Data.AddonData or {}) do spells = spells + 1 end

    add("What looks wrong: ")
    add("")
    add("--- SpellTips report ---")
    add("addon " .. tostring(meta and Try(meta, ADDON_NAME, "Version") or "?") .. " | client " .. tostring(version) .. " build " .. tostring(build))
    add("player: " .. tostring(className) .. " level " .. tostring(UnitLevel("player")))
    add("data: " .. spells .. " spells")
    if S.hookError then add("last error: " .. S.hookError) end
    add("keys: show talents = " .. KEY_NAMES[db.holdKey] .. ", locked = " .. KEY_NAMES[db.moreKey] .. ", always shown level " .. db.alwaysLevel)

    local last = S.last
    if not last then
        add("")
        add("No spell has been drawn yet. Hold the key over the spell that looks wrong, move off it, then open this again.")
        return table.concat(out, "\n")
    end
    add("")
    add("spell " .. tostring(last.id) .. " " .. tostring(last.name) .. " (" .. tostring(last.via) .. ") shown at level " .. last.level)
    for _, name in ipairs(SortedKeys(last.rows)) do
        local row = last.rows[name]
        add(name .. ": " .. table.concat(row.values, ", ") .. (row.suffix and ("  " .. row.suffix) or ""))
        for _, own in ipairs(row.own) do
            add("    " .. Plain((own.l or "") .. " " .. (own.v or "") .. " " .. (own.n or "")))
        end
        for _, m in ipairs(row.mods) do
            local src = last.sources[m.id]
            add(string.format("    %s [%s/%s] %s   <%s>", m.name, tostring(m.rank), tostring(m.max), Plain(m.comp),
                src and src.source or "?"))
        end
    end
    for _, o in ipairs(last.others) do
        add("other: " .. o.name .. " [" .. tostring(o.rank) .. "/" .. tostring(o.max) .. "] " .. Plain(o.text))
    end
    add("")
    add("talent text the game gave for each talent shown:")
    for _, id in ipairs(SortedKeys(last.sources)) do
        local src = last.sources[id]
        add(string.format("  %d rank %s: %s", id, tostring(src.rank), Plain(src.text) ~= "" and Plain(src.text) or "(none)"))
    end
    return table.concat(out, "\n")
end

local reportWindow

-- one window for text the player copies out: the problem report, and the /spelltips enum listing
local function ShowCopyText(title, hint, text)
    if not reportWindow then
        local w = NewPanel("SpellTipsReport", 640, 480, title)
        reportWindow = w
        w.hint = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        w.hint:SetPoint("TOPLEFT", 24, -46)
        w.hint:SetWidth(590)
        w.hint:SetJustifyH("LEFT")
        local scroll = NewFrame("ScrollFrame", "SpellTipsReportScroll", w, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 24, -80)
        scroll:SetPoint("BOTTOMRIGHT", -44, 56)
        local box = NewFrame("EditBox", nil, scroll)
        box:SetMultiLine(true)
        box:SetFontObject(ChatFontNormal)
        box:SetWidth(560)
        box:SetHeight(400)
        box:SetAutoFocus(false)
        box:SetScript("OnEscapePressed", box.ClearFocus)
        scroll:SetScrollChild(box)
        w.box = box
        NewButton(w, "Select all", 110, function() box:SetFocus() box:HighlightText() end):SetPoint("BOTTOMLEFT", 24, 20)
    end
    reportWindow.heading:SetText(title)
    reportWindow.hint:SetText(hint)
    reportWindow.box:SetText(text)
    reportWindow:Show()
end

function ShowReport()
    ShowCopyText("SpellTips: report a problem",
        "Type what looks wrong on the first line. Then press Select all, Ctrl+C, and paste it to the developer.",
        BuildReport())
end

-- /spelltips enum            the names of the game's Lua enums, and a few constants the addon would like to read
-- /spelltips enum <text>     only the enums whose name contains <text>
-- /spelltips enum <Name>     that enum's names and values, in value order
-- /spelltips desc [spellID]: where a spell's description text is, as the game reports it
local function DescriptionListing(spellID)
    spellID = spellID or preview.spell
    local out = {}
    local function line(text) out[#out + 1] = text end
    if not spellID then return "No spell. Open /spelltips first, or give a spell ID." end
    line("spell " .. spellID .. " " .. tostring(C_Spell.GetSpellName(spellID)))
    line("IsSpellDataCached: " .. tostring(C_Spell.IsSpellDataCached and C_Spell.IsSpellDataCached(spellID)))
    local ok, desc = pcall(C_Spell.GetSpellDescription, spellID)
    line("GetSpellDescription: ok=" .. tostring(ok) .. " type=" .. type(desc) .. " length="
        .. tostring(type(desc) == "string" and #desc or "-"))
    if type(desc) == "string" and desc ~= "" then line("  text: " .. desc:sub(1, 160)) end
    local function dump(label, tip)
        line(label .. ": NumLines=" .. tip:NumLines())
        local name = tip:GetName()
        for i = 1, tip:NumLines() do
            local left = _G[name .. "TextLeft" .. i]
            local _, text = pcall(function() return left:GetText() end)
            line("  " .. i .. " " .. tostring(text):sub(1, 90))
        end
        local data = tip.GetTooltipData and tip:GetTooltipData()
        if data and data.lines then
            line(label .. " tooltip data lines: " .. #data.lines)
            for i, l in ipairs(data.lines) do
                line("  " .. i .. " type=" .. tostring(l.type) .. " " .. tostring(l.leftText):sub(1, 70))
            end
        else
            line(label .. ": no tooltip data")
        end
    end
    if preview.tooltip then dump("preview tooltip (as drawn now)", preview.tooltip) end
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    GameTooltip:SetSpellByID(spellID)
    dump("GameTooltip:SetSpellByID", GameTooltip)
    GameTooltip:Hide()
    return table.concat(out, "\n")
end

-- Every Data.lua entry with this spell's name that belongs to the player's class, lowest rank first.
-- Takes a name or a spell ID. Returns the IDs (possibly empty), or nil and a message.
local function RanksOfSpell(filter)
    local wantedName, wantedID = filter:lower(), tonumber(filter)
    if wantedID then
        local n = C_Spell.GetSpellName(wantedID)
        if not n then return nil, "No spell with ID " .. wantedID end
        wantedName = n:lower()
    end
    local classSet = PlayerClassSet()
    local ids = {}
    for id, sd in pairs(Data.AddonData or {}) do
        if sd.name and sd.name:lower() == wantedName and sd.lines
           and (sd.classSet == 0 or sd.classSet == classSet) then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids, function(a, b)
        local la, lb = Data.AddonData[a].baseLevel or 0, Data.AddonData[b].baseLevel or 0
        if la ~= lb then return la < lb end
        return a < b
    end)
    return ids
end

-- /spelltips probe <spell name or ID>: every rank of a spell, side by side: the level it is learned at, what the
-- addon computes without any downrank adjustment, and the numbers in the game's own description. For working out
-- how the game treats lower ranks. The first run asks the game to load the descriptions; run it again if any say
-- "not loaded".
local function ProbeListing(filter)
    filter = (filter or ""):match("^%s*(.-)%s*$")
    if filter == "" then return "Usage: /spelltips probe Healing Touch   (or a spell ID)" end
    local out = {}
    local function add(text) out[#out + 1] = text end

    local ids, message = RanksOfSpell(filter)
    if not ids then return message end
    if #ids == 0 then return "No ranks of '" .. filter .. "' for your class in Data.lua." end

    if C_Spell.RequestLoadSpellData then
        for _, id in ipairs(ids) do pcall(C_Spell.RequestLoadSpellData, id) end
    end

    local version, build = GetBuildInfo()
    local _, class = UnitClass("player")
    add(string.format("probe '%s'  client %s build %s  %s level %d", filter, tostring(version), tostring(build),
        tostring(class), UnitLevel("player") or 0))
    local power = {}
    for school = 1, 7 do power[#power + 1] = school .. "=" .. tostring(ReadLive("damage" .. school, GetSpellBonusDamage, school)) end
    add("spell power: healing " .. tostring(ReadLive("healing", GetSpellBonusHealing)) .. ", damage by school "
        .. table.concat(power, " "))
    add("")
    for _, id in ipairs(ids) do
        local sd = Data.AddonData[id]
        local okRank, rank = pcall(function() return (C_Spell.GetSpellSubtext or GetSpellSubtext)(id) end)
        add(string.format("spell %d  %s  learned at level %s (max level %s)  known=%s", id,
            okRank and tostring(rank) or "?", tostring(sd.baseLevel), tostring(sd.maxLevel), tostring(IsSpellKnown and IsSpellKnown(id))))
        local keys = {}
        for k in pairs(sd.lines) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local line = sd.lines[k]
            if (line.type == EFFECT.SCHOOL_DAMAGE or line.type == EFFECT.HEAL) and (line.coeff or 0) > 0 then
                local c = PredictRange(sd, line)
                add(string.format("  effect %d: base %.3f +/- %.3f, coefficient %.4f, spell power used %s, rank factor %.3f, "
                    .. "bonus %.3f, predicted range %.3f - %.3f", k, c.scaled, c.half, line.coeff or 0, tostring(c.sp), c.factor,
                    c.bonus, c.scaled - c.half + c.bonus, c.scaled + c.half + c.bonus))
            end
        end
        local okDesc, desc = pcall(C_Spell.GetSpellDescription, id)
        if okDesc and type(desc) == "string" and not (issecretvalue and issecretvalue(desc)) and desc ~= "" then
            desc = desc:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[\r\n]+", " ")
            add("  game: " .. desc:sub(1, 240))
        else
            add("  game: (not loaded, run the command again)")
        end
    end
    return table.concat(out, "\n")
end

local function EnumListing(filter)
    local out = {}
    local function add(text) out[#out + 1] = text end
    filter = filter or ""
    local lower = filter:lower()
    add("ATTACK_POWER_MAGIC_NUMBER = " .. tostring(_G.ATTACK_POWER_MAGIC_NUMBER))
    add("")
    if filter ~= "" and type(Enum) == "table" and type(Enum[filter]) == "table" then
        local pairs_ = {}
        for name, value in pairs(Enum[filter]) do pairs_[#pairs_ + 1] = { name = tostring(name), value = value } end
        table.sort(pairs_, function(a, b)
            if type(a.value) == "number" and type(b.value) == "number" and a.value ~= b.value then return a.value < b.value end
            return a.name < b.name
        end)
        add("Enum." .. filter .. ":")
        for _, e in ipairs(pairs_) do add("  " .. tostring(e.value) .. "  " .. e.name) end
        return table.concat(out, "\n")
    end
    local names = {}
    for name in pairs(Enum or {}) do
        if lower == "" or tostring(name):lower():find(lower, 1, true) then names[#names + 1] = tostring(name) end
    end
    table.sort(names)
    add((filter == "" and "all Enum names" or ("Enum names containing '" .. filter .. "'")) .. " (" .. #names .. "):")
    for _, name in ipairs(names) do add("  " .. name) end
    add("")
    add("To see one enum's values: /spelltips enum <exact name>")
    return table.concat(out, "\n")
end

-- registers the SpellTips page in the game's Options window, if this client has one
local function RegisterOptionsPage()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    optionsPage = BuildOptionsPage()
    optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsPage, "SpellTips")
    Settings.RegisterAddOnCategory(optionsCategory)
end

SLASH_SPELLTIPS1 = "/spelltips"
SLASH_SPELLTIPS2 = "/stips"
SlashCmdList["SPELLTIPS"] = function(msg)
    local word, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")  -- rest keeps its capitalisation (enum names)
    word = word:lower()
    if word == "enum" then
        ShowCopyText("SpellTips: enums", "Press Select all, Ctrl+C, and paste it to the developer.", EnumListing(rest))
    elseif word == "minimap" then
        db.minimapHide = not db.minimapHide
        RefreshMinimap()
        print("[spelltips] minimap button " .. (db.minimapHide and "hidden" or "shown"))
    elseif word == "desc" then
        ShowCopyText("SpellTips: description check", "Press Select all, Ctrl+C, and paste it to the developer.",
            DescriptionListing(tonumber(rest)))
    elseif word == "report" then
        ShowReport()
    elseif word == "probe" then
        ShowCopyText("SpellTips: rank probe", "Press Select all, Ctrl+C, and paste it to the developer.", ProbeListing(rest))
    elseif word == "debug" then
        DevDebug()
    elseif word == "verify" then
        DevVerify(rest)
    elseif word == "ranks" then
        DevRanks(rest)
    elseif word == "talent" then
        DevTalent(rest)
    elseif word == "reset" then
        ResetSettings()
        print("[spelltips] settings reset")
    else
        ShowSettings()
    end
end

---------------------------------------------------------------------
-- Events
---------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("SPELL_DATA_LOAD_RESULT")

frame:SetScript("OnEvent", function(self, event, addonName, success)
    if event == "SPELL_DATA_LOAD_RESULT" then
        -- (first argument is the spell ID here) redraw once, when the spell we asked for has arrived
        if addonName == preview.spell and preview.asked[addonName] == true then
            preview.asked[addonName] = "done"
            RefreshPreview()
        end
    elseif event == "PLAYER_LOGIN" then
        CheckDataBuild()
        BindWheel()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if S.rebind then BindWheel() end
    elseif addonName == ADDON_NAME then
        LoadSettings()
        pcall(RegisterOptionsPage)
        pcall(RegisterCompartment)
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, SafeApply)
        self:UnregisterEvent("ADDON_LOADED")
        local _, first = next(Data.AddonData or {})
        if first and first.si == nil then
            print("|cffff8000[spelltips]|r Data.lua came from an older generate_data.py "
                .. "(no level-scaling fields). Re-run the generator and copy Data.lua over.")
        end
    end
end)

-- Holding or releasing the keys redraws the tooltip. Releasing holdKey on a selected talent opens it in the talent window.
frame:SetScript("OnUpdate", function()
    local level, hold = CurrentLevel()
    if level == S.level and hold == S.hold then return end

    local released = S.hold and not hold
    local picked = S.selID
    S.level, S.hold = level, hold
    if released then
        S.selID = nil
        if picked and GameTooltip:IsShown() then OpenTalent(picked) end
    end
    if GameTooltip:IsShown() and GameTooltip:GetOwner() then RefreshTooltip(GameTooltip) end
end)
