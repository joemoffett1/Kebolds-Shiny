-- Kebold's Shiny: disenchanting (what a piece of gear disenchants into, what that is worth, a log of your own
-- disenchants, and the Disenchant page that compares crafting gear to disenchant with selling it)
--
-- It only WATCHES and COUNTS. It never casts Disenchant, never uses, buys or posts anything: the log listens to
-- the game's events and reads the loot window, the scan only looks prices up.
--
-- ---- the outcome tables ---------------------------------------------------------------------------------------------
-- THE TABLES BELOW ARE THE ORIGINAL GAME'S, WRITTEN FROM MEMORY BY THE OWNER, AND ARE NOT CONFIRMED FOR FOREVER.
-- Every figure that comes from them is an estimate and is shown with "~". The log replaces them band by band:
-- once a band (quality + armour or weapon + item level band) has MIN_CASTS of your own disenchants, the rates seen
-- are used instead (est = false).
-- Assumed on top of the tables: a quantity "1-2" is 1.5 on average (every count equally likely); every green,
-- blue and epic armour or weapon piece can be disenchanted (the game has exceptions); green gear under item level
-- 5 or over 65 and epics under 40 cannot (the tables do not cover them).
--
-- ---- API ------------------------------------------------------------------------------------------------------------
-- NS.deOutcome(itemID) -> nil (not disenchantable, or the item's data is not loaded yet: it is asked for), or
--     { quality = 2|3|4, ilvl, kind = "armor"|"weapon", est = true|false, band = "2:armor:26", n = casts logged in
--       the band, lines = { { item, chance = 0..1, min, max, avg = average quantity }, ... } }   most likely first
-- NS.deValue(itemID [, ctx]) -> value, known, detail
--     value   what one disenchant gives on average, in copper: sum of chance * average quantity * the material's
--             sale value (the engine's AH sale: cheapest listing not below vendor value, less the cut, with at least
--             minListed listed: ctx.saleEach). nil when the item has no outcome.
--     known   false when any outcome material has no price (value then sums only the priced ones)
--     detail  { o = the outcome, lines = { { item, chance, min, max, avg, each = copper for one | nil, value }, ... } }
--     NOT applied (step 1): no sales cap on disenchant materials, however many you would put up.
-- NS.deFor(ctx, recipe) -> value of one product, seconds one disenchant takes: what the engine's env.deValue gets
--     (nil unless every outcome material has a price).
-- NS.deCast() -> seconds of one Disenchant cast: the one seen in game (cast start to success), else 3.0 (assumed).
-- NS.deScanIDs() -> every material a disenchant can give (the tables', plus anything the log has seen).
-- NS.deRows() -> the Disenchant page's rows, title.      NS.deDetail(recipeID) -> the pane's rows.
-- NS.deStatus() -> the page's one status line.           NS.deEvent(event, ...) -> the log's handler (tests).
--
-- ---- saved (account-wide) -----------------------------------------------------------------------------------------
-- KeboldsShinyDB.de = {
--   log = { "day;itemID;quality;ilvl;kind;lootItem:qty,lootItem:qty", ... },   newest last, 500 kept. A disenchant
--         whose item could not be told has empty fields 2 to 5 and counts for no band.
--   bands = { [band key] = { n = casts, got = { [itemID] = { casts it dropped in, total quantity, least, most } } } },
--   cast = seconds a Disenchant cast took the last time it was seen,
--   debug = { "<time> text", ... } (200 kept): what the watcher saw; read it first when the log looks wrong
-- }
-- Settings: S.deProf (the page's profession, nil = all), S.deMine, S.dePriced, S.deSort (column 1..9), S.deDesc;
-- S.sellPick[item] = "de"; S.opts.deGear = true (Count gear at disenchant value).
--
-- ---- the log: which signals (Blizzard's API documentation, warcraft.wiki.gg; NONE seen on Forever yet) -----------
-- cast      UNIT_SPELLCAST_START and UNIT_SPELLCAST_SUCCEEDED of the player for spell 13262 (or any spell with the
--           same name as 13262, should Forever have renumbered it); START to SUCCEEDED is the cast time.
-- item      the last bag item a spell was put on, noted by post-hooks (hooksecurefunc, nothing replaced) on
--           C_Container.UseContainerItem / PickupContainerItem (and the old globals when they exist) and on
--           SpellTargetItem / UseItemByName; or the target name of UNIT_SPELLCAST_SENT, when it names an item.
--           When none of these says which item it was, the loot is logged without an item.
-- loot      LOOT_READY / LOOT_OPENED within a few seconds of the cast: GetNumLootItems, GetLootSlotLink,
--           GetLootSlotInfo (the quantity is its third value).
--
--   /keboldde            a summary: casts logged, the bands and whether each is measured, the cast time
--   /keboldde log        the last lines of the log          /keboldde debug     what the watcher saw

local NS = KeboldsShinyNS
if type(NS) ~= "table" then return end
local UI = KeboldsShinyUI
local E = NS.E
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local DIM, RED, GOLD, GREEN = NS.DIM, NS.RED, NS.GOLD, NS.GREEN
local money, itemName, settings, try = NS.money, NS.itemName, NS.settings, NS.try

local SPELL = 13262        -- Disenchant
local MIN_CASTS = 20       -- logged disenchants a band needs before its own rates replace the table
local MAX_LOG = 500
local MAX_DEBUG = 200
local CAST_DEFAULT = 3.0   -- seconds, until a cast was seen (assumed)
local LOOT_WINDOW = 4      -- seconds after the cast in which a loot window counts as its loot
local TOUCH_WINDOW = 2     -- seconds before the cast starts in which a bag item counts as its target
local DAY_ZERO = NS.DAY_ZERO or 1577836800

-- ---- the tables (the original game's, UNCONFIRMED for Forever) ------------------------------------------------------
-- Green armour by item level: { from, to, dust, essence, shard }, each { item, chance, least, most }.
-- Green weapons: the same items and the same shard chance, with the dust's and the essence's chances swapped.
local GREEN_BANDS = {
  { 5, 15, { 10940, 0.80, 1, 2 }, { 10938, 0.20, 1, 2 } },                              -- Strange Dust, Lesser Magic Essence
  { 16, 20, { 10940, 0.75, 2, 3 }, { 10939, 0.20, 1, 2 }, { 10978, 0.05, 1, 1 } },      -- Strange Dust, Greater Magic Essence, Small Glimmering Shard
  { 21, 25, { 10940, 0.75, 4, 6 }, { 10998, 0.15, 1, 2 }, { 10978, 0.10, 1, 1 } },      -- Strange Dust, Lesser Astral Essence, Small Glimmering Shard
  { 26, 30, { 11083, 0.75, 1, 2 }, { 11082, 0.20, 1, 2 }, { 11084, 0.05, 1, 1 } },      -- Soul Dust, Greater Astral Essence, Large Glimmering Shard
  { 31, 35, { 11083, 0.75, 2, 5 }, { 11134, 0.20, 1, 2 }, { 11138, 0.05, 1, 1 } },      -- Soul Dust, Lesser Mystic Essence, Small Glowing Shard
  { 36, 40, { 11137, 0.75, 1, 2 }, { 11135, 0.20, 1, 2 }, { 11139, 0.05, 1, 1 } },      -- Vision Dust, Greater Mystic Essence, Large Glowing Shard
  { 41, 45, { 11137, 0.75, 2, 5 }, { 11174, 0.20, 1, 2 }, { 11177, 0.05, 1, 1 } },      -- Vision Dust, Lesser Nether Essence, Small Radiant Shard
  { 46, 50, { 11176, 0.75, 1, 2 }, { 11175, 0.20, 1, 2 }, { 11178, 0.05, 1, 1 } },      -- Dream Dust, Greater Nether Essence, Large Radiant Shard
  { 51, 55, { 11176, 0.75, 2, 5 }, { 16202, 0.20, 1, 2 }, { 14343, 0.05, 1, 1 } },      -- Dream Dust, Lesser Eternal Essence, Small Brilliant Shard
  { 56, 60, { 16204, 0.75, 1, 2 }, { 16203, 0.20, 1, 2 }, { 14344, 0.05, 1, 1 } },      -- Illusion Dust, Greater Eternal Essence, Large Brilliant Shard
  { 61, 65, { 16204, 0.75, 2, 5 }, { 16203, 0.20, 2, 3 }, { 14344, 0.05, 1, 1 } },      -- Illusion Dust, Greater Eternal Essence, Large Brilliant Shard
}
-- Blue, armour and weapons alike: always one shard. { from, to, item, least, most }
local BLUE_BANDS = {
  { 1, 25, 10978, 1, 1 }, { 26, 30, 11084, 1, 1 }, { 31, 35, 11138, 1, 1 }, { 36, 40, 11139, 1, 1 },
  { 41, 45, 11177, 1, 1 }, { 46, 50, 11178, 1, 1 }, { 51, 55, 14343, 1, 1 }, { 56, 999, 14344, 1, 1 },
}
-- Epic: shards, then Nexus Crystals.
local EPIC_BANDS = {
  { 40, 45, 11177, 2, 4 }, { 46, 50, 11178, 2, 4 }, { 51, 55, 14343, 2, 4 }, { 56, 60, 20725, 1, 1 }, { 61, 999, 20725, 1, 2 },
}
-- Every material of the tables, in the order they are scanned (checked against the names in Data.lua, 2026-11-11):
-- dusts, essences (lesser, greater), shards (small, large), Nexus Crystal.
local MATS = { 10940, 11083, 11137, 11176, 16204,
  10938, 10939, 10998, 11082, 11134, 11135, 11174, 11175, 16202, 16203,
  10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344, 20725 }
NS.DE_MATS = MATS
NS.DE_MIN_CASTS = MIN_CASTS

local function line(item, chance, lo, hi)
  return { item = item, chance = chance, min = lo, max = hi, avg = (lo + hi) / 2 }
end

-- The band an item falls in and the table's lines for it: key ("2:armor:26"), lines; nil when the tables have none.
local function bandOf(q, kind, ilvl)
  if type(q) ~= "number" or type(ilvl) ~= "number" or (kind ~= "armor" and kind ~= "weapon") then return nil end
  if q == 2 then
    for _, b in ipairs(GREEN_BANDS) do
      if ilvl >= b[1] and ilvl <= b[2] then
        local dust, ess, shard = b[3], b[4], b[5]
        local dc, ec = dust[2], ess[2]
        if kind == "weapon" then dc, ec = ec, dc end   -- weapons: mostly essence
        local lines = { line(dust[1], dc, dust[3], dust[4]), line(ess[1], ec, ess[3], ess[4]) }
        if shard then lines[3] = line(shard[1], shard[2], shard[3], shard[4]) end
        table.sort(lines, function(a, c) return a.chance > c.chance end)
        return "2:" .. kind .. ":" .. b[1], lines
      end
    end
    return nil
  end
  local list = q == 3 and BLUE_BANDS or (q == 4 and EPIC_BANDS or nil)
  for _, b in ipairs(list or {}) do
    if ilvl >= b[1] and ilvl <= b[2] then
      return q .. ":" .. kind .. ":" .. b[1], { line(b[3], 1, b[4], b[5]) }
    end
  end
  return nil
end
NS.deBandOf = bandOf

-- ---- saved ----------------------------------------------------------------------------------------------------------

local rev = 0   -- goes up when the log gains a cast: outcomes and the page's list are worked out again

local function store()
  if type(KeboldsShinyDB) ~= "table" then KeboldsShinyDB = {} end
  local d = KeboldsShinyDB.de
  if type(d) ~= "table" then
    d = {}
    KeboldsShinyDB.de = d
  end
  if type(d.log) ~= "table" then d.log = {} end
  if type(d.bands) ~= "table" then d.bands = {} end
  if type(d.debug) ~= "table" then d.debug = {} end
  return d
end

local function now()
  return try(GetTime) or 0
end

local function dlog(text)
  local ok, d = pcall(store)
  if not ok then return end
  local log = d.debug
  log[#log + 1] = tostring(try(time) or 0) .. " " .. tostring(text)
  while #log > MAX_DEBUG do table.remove(log, 1) end
end

function NS.deCast()
  local d = type(KeboldsShinyDB) == "table" and KeboldsShinyDB.de or nil
  local c = type(d) == "table" and tonumber(d.cast) or nil
  if c and c > 0 then return c, true end
  return CAST_DEFAULT, false
end

-- ---- what an item is --------------------------------------------------------------------------------------------------
-- Quality, item level and class are the game's own (C_Item.GetItemInfo: 3rd, 4th and 12th value; class 2 weapon,
-- 4 armour). They never change, so an answer is kept; an item whose data is not loaded yet is asked for once.
local static, asked, staticRev = {}, {}, 0

local function itemStatic(id)
  if type(id) ~= "number" or id <= 0 then return nil end
  local s = static[id]
  if s ~= nil then return s or nil end
  local CI = C_Item
  if type(CI) ~= "table" or type(CI.GetItemInfo) ~= "function" then return nil end
  local ok, name, _, q, ilvl, _, _, _, _, _, _, _, classID = pcall(CI.GetItemInfo, id)
  if not ok or name == nil or type(q) ~= "number" then   -- not loaded: ask the game for it, answer next time
    if not asked[id] then
      asked[id] = true
      if type(CI.RequestLoadItemDataByID) == "function" then pcall(CI.RequestLoadItemDataByID, id) end
    end
    return nil
  end
  local kind = classID == 2 and "weapon" or (classID == 4 and "armor" or nil)
  if kind and q >= 2 and q <= 4 and type(ilvl) == "number" then
    s = { q = q, ilvl = ilvl, kind = kind }
  else
    s = false
  end
  static[id] = s
  staticRev = staticRev + 1
  return s or nil
end

function NS.deForget()   -- for tests: what the game said about items is asked again
  static, asked = {}, {}
  staticRev = staticRev + 1
  rev = rev + 1
end

-- ---- outcomes ---------------------------------------------------------------------------------------------------------

local outCache = {}   -- [band key] = { rev, lines, est, n }

-- The rates of a band: the log's once it has MIN_CASTS casts, else the table's.
local function bandLines(key, tableLines)
  local c = outCache[key]
  if c and c.rev == rev then return c.lines, c.est, c.n end
  local b = store().bands[key]
  local n = type(b) == "table" and tonumber(b.n) or 0
  local lines, est = tableLines, true
  if n >= MIN_CASTS and type(b.got) == "table" then
    lines, est = {}, false
    for item, g in pairs(b.got) do
      local casts, qty = tonumber(g[1]) or 0, tonumber(g[2]) or 0
      if type(item) == "number" and casts > 0 then
        lines[#lines + 1] = { item = item, chance = casts / n, min = tonumber(g[3]) or 1, max = tonumber(g[4]) or 1, avg = qty / casts }
      end
    end
    table.sort(lines, function(a, c2)
      if a.chance ~= c2.chance then return a.chance > c2.chance end
      return a.item < c2.item
    end)
    if #lines == 0 then lines, est = tableLines, true end
  end
  outCache[key] = { rev = rev, lines = lines, est = est, n = n }
  return lines, est, n
end

function NS.deOutcome(itemID)
  local s = itemStatic(itemID)
  if not s then return nil end
  local key, tableLines = bandOf(s.q, s.kind, s.ilvl)
  if not key then return nil end
  local lines, est, n = bandLines(key, tableLines)
  return { quality = s.q, ilvl = s.ilvl, kind = s.kind, band = key, est = est, n = n, lines = lines }
end

-- ---- value --------------------------------------------------------------------------------------------------------

-- The vendor value of a material when the game has said it (the scans read it), else 0: the floor under an
-- AH price, as for a product.
local function gameSell(item)
  local g = type(KeboldsShinyDB) == "table" and KeboldsShinyDB.sell or nil
  local v = type(g) == "table" and tonumber(g[item]) or nil
  return (v and v > 0) and v or 0
end

local function anyCtx()
  local c = NS.state("Enchanting")
  return c and c.ctx or nil
end

-- What one unit of a disenchant material sells for: the engine's AH sale (ctx.saleEach), or its vendor value
-- when that is more or when too few are listed. nil when it was never scanned (or nothing counts).
local function matEach(ctx, item)
  local fl = gameSell(item)
  local net, ahp, listed = ctx.saleEach(item, fl)
  if fl > 0 and listed ~= nil and (net == nil or fl > net) then return fl, "vendor", ahp, listed end
  return net, net and "AH" or nil, ahp, listed
end

function NS.deValue(itemID, ctx)
  local o = NS.deOutcome(itemID)
  if not o then return nil, false, nil end
  ctx = ctx or anyCtx()
  if not (ctx and ctx.saleEach) then return 0, false, { o = o, lines = {} } end
  local total, known, lines = 0, true, {}
  for i, l in ipairs(o.lines) do
    local each, how, ahp, listed = matEach(ctx, l.item)
    local v = each and l.chance * l.avg * each or nil
    if v then total = total + v else known = false end
    lines[i] = { item = l.item, chance = l.chance, min = l.min, max = l.max, avg = l.avg, each = each, how = how, ahp = ahp, listed = listed, value = v }
  end
  return total, known, { o = o, lines = lines }
end

-- For the engine (env.deValue in Ledger.lua): the product's disenchant value and the seconds a disenchant takes
-- (the cast and the gap between casts), only when every outcome material has a price.
function NS.deFor(ctx, r)
  if not (r and r.made and r.made > 0) then return nil end
  local v, known = NS.deValue(r.made, ctx)
  if v == nil or not known then return nil end
  return v, (NS.deCast()) + (ctx.opts.gap or 0)
end

function NS.deScanIDs()
  local ids, seen = {}, {}
  for _, id in ipairs(MATS) do
    seen[id] = true
    ids[#ids + 1] = id
  end
  local extra = {}   -- a material Forever gives that the tables do not know
  local d = type(KeboldsShinyDB) == "table" and KeboldsShinyDB.de or nil
  for _, b in pairs(type(d) == "table" and type(d.bands) == "table" and d.bands or {}) do
    for item in pairs(type(b) == "table" and type(b.got) == "table" and b.got or {}) do
      if type(item) == "number" and not seen[item] then
        seen[item] = true
        extra[#extra + 1] = item
      end
    end
  end
  table.sort(extra)
  for _, id in ipairs(extra) do ids[#ids + 1] = id end
  return ids
end

-- ---- the log: watching your own disenchants ---------------------------------------------------------------------------

local pend = { start = false, target = false, done = false, item0 = false, cast = false, item = false, itemAt = 0, src = false, name = false, nameAt = 0 }
local byName   -- lower-case name -> item id, for the things recipes make

local function spellName(id)
  local n
  if type(C_Spell) == "table" then n = try(C_Spell.GetSpellName, id) end
  if type(n) ~= "string" and type(GetSpellInfo) == "function" then n = try(GetSpellInfo, id) end
  return type(n) == "string" and n or nil
end

local function isDisenchant(spellID)
  if spellID == SPELL then return true end
  if type(spellID) ~= "number" then return false end
  local a, b = spellName(spellID), spellName(SPELL) or "Disenchant"
  return a ~= nil and a == b
end

local function idOfName(name)
  if type(name) ~= "string" or name == "" then return nil end
  local id = tonumber(name:match("item:(%d+)"))   -- a link
  if id then return id end
  if type(C_Item) == "table" then
    local got = try(C_Item.GetItemInfoInstant, name)
    if type(got) == "number" and got > 0 then return got end
  end
  if not byName then
    byName = {}
    for _, r in ipairs(NS.data().recipes) do
      if r.made > 0 and r.name and not byName[r.name:lower()] then byName[r.name:lower()] = r.made end
    end
  end
  return byName[name:lower()]
end

-- A bag item something was just done to (a spell put on it, among other things): remembered for a moment.
local function touch(item, src)
  if type(item) == "number" and item > 0 then
    pend.item, pend.itemAt, pend.src = item, now(), src
  end
end

local function touchSlot(bag, slot, src)
  local C = C_Container
  local id
  if type(C) == "table" then id = try(C.GetContainerItemID, bag, slot) end
  if type(id) ~= "number" and type(GetContainerItemID) == "function" then id = try(GetContainerItemID, bag, slot) end
  touch(id, src)
end

local function recentTouch(window)
  if pend.item and now() - pend.itemAt <= window then return pend.item, pend.src end
  if pend.name and now() - pend.nameAt <= window then
    local id = idOfName(pend.name)
    if id then return id, "sent" end
  end
  return nil
end

-- One disenchant and what it gave: item = the id or nil, loot = { { id, qty }, ... }.
local function record(item, loot)
  local d = store()
  local s = item and itemStatic(item) or nil
  local parts, sum, order = {}, {}, {}
  for _, l in ipairs(loot) do
    if not sum[l[1]] then order[#order + 1] = l[1] end
    sum[l[1]] = (sum[l[1]] or 0) + l[2]
  end
  for _, id in ipairs(order) do parts[#parts + 1] = id .. ":" .. sum[id] end
  local day = floor(((try(time) or 0) - DAY_ZERO) / 86400)
  d.log[#d.log + 1] = table.concat({ day, item or "", s and s.q or "", s and s.ilvl or "", s and s.kind or "", table.concat(parts, ",") }, ";")
  while #d.log > MAX_LOG do table.remove(d.log, 1) end
  local key = s and bandOf(s.q, s.kind, s.ilvl) or nil
  if key then
    local b = d.bands[key]
    if type(b) ~= "table" then
      b = { n = 0, got = {} }
      d.bands[key] = b
    end
    if type(b.got) ~= "table" then b.got = {} end
    b.n = (tonumber(b.n) or 0) + 1
    for _, id in ipairs(order) do
      local g = b.got[id]
      if type(g) ~= "table" then
        g = { 0, 0, sum[id], sum[id] }
        b.got[id] = g
      end
      g[1], g[2] = (tonumber(g[1]) or 0) + 1, (tonumber(g[2]) or 0) + sum[id]
      g[3], g[4] = min(tonumber(g[3]) or sum[id], sum[id]), max(tonumber(g[4]) or sum[id], sum[id])
    end
    dlog("logged " .. item .. " band " .. key .. " n=" .. b.n .. " loot " .. table.concat(parts, ","))
  elseif item then
    dlog("logged " .. item .. " without a band (not loaded, or not in the tables) loot " .. table.concat(parts, ","))
  else
    dlog("logged a disenchant whose item is not known, loot " .. table.concat(parts, ","))
  end
  rev = rev + 1
  if NS.bump then NS.bump() end   -- values that came from the table may now come from the log
  if NS.refreshSoon then pcall(NS.refreshSoon, 1) end
  return key
end

local function readLoot()
  local n = type(GetNumLootItems) == "function" and try(GetNumLootItems) or 0
  local loot = {}
  for slot = 1, tonumber(n) or 0 do
    local link = type(GetLootSlotLink) == "function" and try(GetLootSlotLink, slot) or nil
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
    local qty = 1
    if type(GetLootSlotInfo) == "function" then
      local _, _, q = try(GetLootSlotInfo, slot)
      if type(q) == "number" and q > 0 then qty = q end
    end
    if id then loot[#loot + 1] = { id, qty } end
  end
  return loot
end

local function onEvent(event, a1, a2, a3, a4)
  if event == "UNIT_SPELLCAST_SENT" then            -- unit, target name, cast id, spell id
    if a1 == "player" and isDisenchant(a4) and type(a2) == "string" and a2 ~= "" then
      pend.name, pend.nameAt = a2, now()
      dlog("sent, target " .. a2)
    end
  elseif event == "UNIT_SPELLCAST_START" then       -- unit, cast id, spell id
    if a1 == "player" and isDisenchant(a3) then
      pend.start = now()
      local item, src = recentTouch(TOUCH_WINDOW)
      pend.target = item or false
      dlog("start, item " .. tostring(item) .. " by " .. tostring(src))
    end
  elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
    if a1 == "player" and isDisenchant(a3) and pend.start then
      pend.start, pend.target = false, false
      dlog(event)
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if a1 == "player" and isDisenchant(a3) then
      local t = now()
      if pend.start then
        local took = t - pend.start
        if took >= 0.5 and took <= 30 then
          took = floor(took * 10 + 0.5) / 10
          local d = store()
          if d.cast ~= took then
            d.cast = took
            if NS.bump then NS.bump() end
          end
          pend.cast = took
        end
      end
      local item = pend.target or recentTouch(TOUCH_WINDOW + 6) or false   -- no START seen: a bag item touched just before
      pend.done, pend.item0 = t, item
      pend.start, pend.target = false, false
      dlog("succeeded, item " .. tostring(item) .. " cast " .. tostring(pend.cast))
    end
  elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
    if pend.done and now() - pend.done <= LOOT_WINDOW then
      local loot = readLoot()
      if #loot == 0 then
        dlog(event .. " with no item in the loot window yet")
        return
      end
      local item = pend.item0 or nil
      pend.done, pend.item0 = false, false
      record(item, loot)
    elseif pend.done then
      pend.done, pend.item0 = false, false
      dlog(event .. " too long after the cast: not counted")
    end
  end
end

-- Never lets a mistake here reach the game.
function NS.deEvent(event, ...)
  local ok, err = pcall(onEvent, event, ...)
  if not ok then pcall(dlog, "error in " .. tostring(event) .. ": " .. tostring(err)) end
end

do
  local watcher = CreateFrame("Frame")
  watcher:SetScript("OnEvent", function(_, event, ...) NS.deEvent(event, ...) end)
  for _, event in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "LOOT_READY", "LOOT_OPENED" }) do
    pcall(watcher.RegisterEvent, watcher, event)
  end
  -- Which bag item a spell was put on: post-hooks only, on functions that exist; nothing is replaced or called.
  if type(hooksecurefunc) == "function" then
    local C = C_Container
    if type(C) == "table" then
      for _, name in ipairs({ "UseContainerItem", "PickupContainerItem" }) do
        if type(C[name]) == "function" then
          pcall(hooksecurefunc, C, name, function(bag, slot) pcall(touchSlot, bag, slot, name) end)
        end
      end
    end
    for _, name in ipairs({ "UseContainerItem", "PickupContainerItem" }) do
      if type(_G[name]) == "function" then
        pcall(hooksecurefunc, name, function(bag, slot) pcall(touchSlot, bag, slot, name) end)
      end
    end
    for _, name in ipairs({ "SpellTargetItem", "UseItemByName" }) do
      if type(_G[name]) == "function" then
        pcall(hooksecurefunc, name, function(what)
          pcall(function() touch(idOfName(what), name) end)
        end)
      end
    end
  end
  -- item data that arrived: the Disenchant page lists more recipes
  local loader = CreateFrame("Frame")
  loader:SetScript("OnEvent", function()
    local page = NS.currentPage and NS.currentPage() or nil
    if page and page.key == "disenchant" and NS.refreshSoon then pcall(NS.refreshSoon, 1) end
  end)
  pcall(loader.RegisterEvent, loader, "GET_ITEM_INFO_RECEIVED")
end

-- ---- /keboldde ----------------------------------------------------------------------------------------------------------

local function say(msg)
  if type(NS.say) == "function" then NS.say(msg) else print(msg) end
end

-- "2:armor:26" -> "green armor 26+"
local QUALITY = { [2] = "green", [3] = "blue", [4] = "epic" }
local function bandText(key)
  local q, kind, lo = tostring(key):match("^(%d):(%a+):(%d+)$")
  if not q then return tostring(key) end
  return (QUALITY[tonumber(q)] or q) .. " " .. kind .. " from item level " .. lo
end
NS.deBandText = bandText

function NS.deSummary()
  local d = store()
  local keys, casts, measured = {}, 0, 0
  for key, b in pairs(d.bands) do
    if type(b) == "table" then
      keys[#keys + 1] = key
      casts = casts + (tonumber(b.n) or 0)
      if (tonumber(b.n) or 0) >= MIN_CASTS then measured = measured + 1 end
    end
  end
  table.sort(keys)
  local cast, seen = NS.deCast()
  return { logged = #d.log, casts = casts, bands = keys, measured = measured, cast = cast, castSeen = seen }
end

SLASH_KEBOLDSSHINYDE1 = "/keboldde"
SLASH_KEBOLDSSHINYDE2 = "/ledgerde"   -- the name before the addon was renamed
SlashCmdList["KEBOLDSSHINYDE"] = function(msg)
  local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
  local d = store()
  if cmd == "log" then
    local n = #d.log
    if n == 0 then
      say("No disenchant logged yet. The log fills by itself when you disenchant something.")
      return
    end
    say("The last " .. min(15, n) .. " of " .. n .. " disenchants (day;item;quality;item level;kind;what it gave):")
    for i = max(1, n - 14), n do print(d.log[i]) end
  elseif cmd == "debug" then
    local n = #d.debug
    say("What the disenchant watcher saw (the last " .. min(30, n) .. " of " .. n .. " lines):")
    for i = max(1, n - 29), n do print(d.debug[i]) end
  elseif cmd == "" then
    local s = NS.deSummary()
    say(string.format("Disenchants logged: %d (%d with a known item). Disenchant cast: %.1f s%s.", s.logged, s.casts, s.cast, s.castSeen and ", seen in game" or ", assumed until one is seen"))
    if #s.bands == 0 then
      say("No band has a disenchant yet: every outcome is the original game's table (~), not confirmed for Forever.")
    end
    for _, key in ipairs(s.bands) do
      local b = d.bands[key]
      local n = tonumber(b.n) or 0
      local parts = {}
      for item, g in pairs(type(b.got) == "table" and b.got or {}) do
        parts[#parts + 1] = string.format("%s %.0f%% x%.1f", itemName(item), 100 * (tonumber(g[1]) or 0) / max(1, n), (tonumber(g[2]) or 0) / max(1, tonumber(g[1]) or 1))
      end
      table.sort(parts)
      say("  " .. bandText(key) .. ": " .. n .. " casts, " .. (n >= MIN_CASTS and "measured" or ("the table is used until " .. MIN_CASTS)) .. ". " .. table.concat(parts, ", "))
    end
  else
    say("Usage: /keboldde [log | debug]. It only watches your own disenchants; /keboldscan de reads the materials' prices.")
  end
end

-- ---- the scan -------------------------------------------------------------------------------------------------------

local SCAN_TIP = "Every dust, essence, shard and crystal a disenchant can give: the prices the Disenchant page values gear with."
if type(NS.scanPresetAdd) == "function" and not NS.dePresetAdded then
  NS.dePresetAdded = true
  if type(NS.SCAN_NAME) == "table" and not NS.SCAN_NAME.de then NS.SCAN_NAME.de = "Disenchant materials" end
  NS.scanPresetAdd(function()
    return { key = "de", word = "de", count = #NS.deScanIDs(), tip = SCAN_TIP }
  end)
end

-- ---- the Disenchant page: the model ---------------------------------------------------------------------------------------
-- Every gear recipe of the nine professions whose product has an outcome, with what disenchanting one craft's
-- product gives against what it costs to make. The cost and the cast time are the Craft page's figures
-- (NS.figures: the parts approach that earns the most per hour), taken from each profession's shared context.
--
-- Rows: { cols = { Recipe, Profession, Disenchants into, Value, Materials, Profit, Per hour, Vendor, AH }, item,
--   recipe, deRecipe = recipe id, action (a click selects it), menu = true (right click: the usual menu, with Sells
--   at), sellStep, value / known / cost / profit / ph / vend / ah (numbers or nil), est, band, best = "de" |
--   "vendor" | "ah" (the outlet that pays most), prof, tip }; or one row with `empty` (shown as the empty state).

local HEADS = { "Recipe", "Profession", "Disenchants into", "Value", "Materials", "Profit", "Per hour", "Vendor", "AH" }
local SHORT = { Alchemy = "Alchemy", Blacksmithing = "Smithing", Cooking = "Cooking", Enchanting = "Enchanting", Engineering = "Engineering",
  ["First Aid"] = "First Aid", Leatherworking = "Leather", Mining = "Mining", Tailoring = "Tailoring" }
local ICON = "Interface\\Icons\\INV_Enchant_Disenchant"
local search = ""
local selID = nil          -- the recipe whose outcomes the pane shows
local listCache = nil      -- { key, list }
local lastStatus = ""
local lastCounts = { shown = 0, all = 0, measured = 0, est = 0, loading = 0 }
local page

local function signed(v)
  if v == nil then return DIM .. "-|r" end
  if v >= 0 then return GREEN .. "+" .. money(v) .. "|r" end
  return RED .. "-" .. money(-v) .. "|r"
end

local function secsText(v)
  if v == nil then return "?" end
  if v >= 90 then return string.format("%.1f min", v / 60) end
  return string.format("%.1fs", v)
end

local function pct(x)
  local p = 100 * x
  if p > 0 and p < 1 then return "<1%" end
  return string.format("%.0f%%", p)
end

local function qtyText(l)
  if l.min == l.max then return tostring(l.min) end
  return l.min .. "-" .. l.max
end

local function anyMatPriced()
  local items = NS.realmItems()
  for _, id in ipairs(NS.deScanIDs()) do
    local L = E.parseLadder(items[id])
    if L and #L.tiers > 0 then return true end
  end
  return false
end

-- One recipe's figures for the page: nil when its product has no outcome (or its data is not loaded yet).
local function entryOf(c, r)
  local o = NS.deOutcome(r.made)
  if not o then return nil end
  local ctx = c.ctx
  local f = NS.figures(c, r)
  local x = f.x
  local dv, dknown, dd = NS.deValue(r.made, ctx)
  local e = { r = r, prof = r.prof, o = o, dd = dd, f = f, mk = f.mk, can = f.known and true or false, est = o.est, known = dknown }
  e.value = dv and dv * f.mk or nil
  e.cost = x.cost
  local dsecs = f.mk * ((NS.deCast()) + (ctx.opts.gap or 0))
  local craft = x.secs and (x.secs - (x.way == "DE" and (x.dsecs or 0) or 0)) or nil   -- the craft alone
  e.craftSecs, e.deSecs = craft, dsecs
  e.secs = craft and (craft + dsecs) or nil
  if dknown and e.value and e.cost then
    e.profit = e.value - e.cost
    e.ph = (e.secs and e.secs > 0) and e.profit / e.secs * 3600 or nil
  end
  e.vend = r.sell and r.sell * f.mk or nil
  local net, ahp, listed = ctx.saleEach(r.made, r.sell)
  e.ah, e.ahp, e.listed = net and net * f.mk or nil, ahp, listed
  local best, top = nil, nil
  for _, pair in ipairs({ { "de", dknown and e.value or nil }, { "vendor", e.vend }, { "ah", e.ah } }) do
    if pair[2] and (top == nil or pair[2] > top) then best, top = pair[1], pair[2] end
  end
  e.best = best
  e.into = o.lines[1] and itemName(o.lines[1].item) or ""
  return e
end

-- Every gear recipe with an outcome, of all nine professions; kept until a price, a plan or the log changes.
local function allEntries()
  local d = NS.data()
  local states, sig = {}, {}
  for _, prof in ipairs(d.profs) do
    local c = NS.state(prof)
    states[prof] = c
    sig[#sig + 1] = c.sig
  end
  local plans = table.concat(sig, "#")
  local function keyNow() return rev .. "#" .. staticRev .. "#" .. (NS.version and NS.version() or 0) .. "#" .. plans end
  if listCache and listCache.key == keyNow() then return listCache.list, listCache.gear, listCache.loading end
  local list, gear, loading = {}, 0, 0
  for _, prof in ipairs(d.profs) do
    local c = states[prof]
    for _, r in ipairs(d.byProf[prof] or {}) do
      if r.gear and r.made > 0 then
        gear = gear + 1
        local e = entryOf(c, r)
        if e then
          list[#list + 1] = e
        elseif static[r.made] == nil then
          loading = loading + 1
        end
      end
    end
  end
  -- the key is taken after the list was built: reading the items' data for it moved staticRev
  listCache = { key = keyNow(), list = list, gear = gear, loading = loading }
  return list, gear, loading
end

local SORT = {
  function(e) return e.r.name end,
  function(e) return e.prof end,
  function(e) return e.into end,
  function(e) return e.value end,
  function(e) return e.cost end,
  function(e) return e.profit end,
  function(e) return e.ph end,
  function(e) return e.vend end,
  function(e) return e.ah end,
}

function NS.deSortBy(k)
  local S = settings()
  if (S.deSort or 6) == k then S.deDesc = not (S.deDesc ~= false) else S.deSort, S.deDesc = k, k >= 4 end   -- numbers start high to low
  if NS.resetScroll then NS.resetScroll() end
  NS.refresh()
end

function NS.deSelect(recipeID)
  selID = recipeID
  if page and type(page.pane) == "table" and type(page.pane.list) == "table" then page.pane.list.offset = 0 end
  NS.refresh()
end
function NS.deSelected() return selID end

function NS.deFind(text)   -- the Find box (also for tests)
  search = tostring(text or "")
end

function NS.deStatus() return lastStatus end
function NS.deCounts() return lastCounts end

local function resetFilters()
  local S = settings()
  S.deProf, S.deMine, S.dePriced = nil, nil, nil
  search = ""
  if page and type(page.eFind) == "table" then pcall(page.eFind.SetText, page.eFind, "") end
  if NS.resetScroll then NS.resetScroll() end
  NS.refresh()
end

function NS.deRows()
  local S = settings()
  local SCAN = NS.scanLabel and NS.scanLabel("de") or "Scan disenchant materials"
  -- the quick scan (the whole auction house in one request), when the scanner has it
  local QUICK = (type(KeboldsShinyScan_HasQuick) == "function" and NS.scanLabel) and NS.scanLabel("quick") or nil
  local all, gear, loading = allEntries()
  local cast, castSeen = NS.deCast()
  local castNote = string.format("disenchant cast %.1f s%s", cast, castSeen and "" or " (assumed)")
  lastCounts = { shown = 0, all = #all, measured = 0, est = 0, loading = loading }

  if not anyMatPriced() then
    lastStatus = DIM .. "No disenchant material has a price yet: " .. SCAN .. " at the auction house.|r"
    return { { left = "No disenchant prices yet. " .. SCAN .. " at the auction house (a few seconds).",
      empty = { icon = ICON, title = "No disenchant prices yet",
        text = "What a disenchant is worth comes from the auction house prices of dusts, essences, shards and crystals. " .. SCAN .. " reads all "
          .. #NS.deScanIDs() .. " of them (a few seconds, at the auction house)."
          .. (QUICK and (" " .. QUICK .. " reads them too, with the gear itself.") or ""),
        button = SCAN, onClick = function() NS.scanButton("de") end,
        button2 = QUICK, onClick2 = QUICK and function() NS.scanButton("quick") end or nil } } }, "Disenchant"
  end
  if #all == 0 then
    lastStatus = DIM .. (loading > 0 and (loading .. " items are still being loaded by the game.") or "No gear recipe has a disenchant outcome.") .. "|r"
    return { { left = loading > 0 and "The game is still loading the items the recipes make. They appear here as they arrive."
        or "No gear recipe has a disenchant outcome.",
      empty = { icon = ICON, title = loading > 0 and "Loading items" or "Nothing to disenchant",
        text = loading > 0 and ("Quality and item level come from the game, which loads them when asked: " .. loading .. " of " .. gear .. " gear items are on their way. The list fills by itself.")
          or "None of the gear the recipes make is green, blue or epic armour or a weapon the tables cover." } } }, "Disenchant"
  end

  local needle = search:lower()
  local list = {}
  for _, e in ipairs(all) do
    local keep = true
    if S.deProf and e.prof ~= S.deProf then keep = false end
    if keep and S.deMine and not e.can then keep = false end
    if keep and S.dePriced and e.profit == nil then keep = false end
    if keep and needle ~= "" and not (e.r.name:lower():find(needle, 1, true) or e.into:lower():find(needle, 1, true)) then keep = false end
    if keep then list[#list + 1] = e end
  end
  if #list == 0 then
    local why = {}
    if needle ~= "" then why[#why + 1] = "Find: " .. search end
    if S.deProf then why[#why + 1] = S.deProf end
    if S.deMine then why[#why + 1] = "Only ones I can make" end
    if S.dePriced then why[#why + 1] = "Only priced" end
    lastStatus = DIM .. "0 of " .. #all .. " recipes shown.|r"
    return { { left = "No recipe matches (" .. table.concat(why, ", ") .. ").",
      empty = { icon = "Interface\\Icons\\INV_Misc_Spyglass_02", title = "No recipe matches",
        text = "No gear recipe fits " .. table.concat(why, ", ") .. "." .. (S.deMine and " Only ones I can make lists recipes this character knows: open the profession's window once so Kebold has read them." or ""),
        button = "Show all", onClick = resetFilters } } }, "Disenchant"
  end

  local key, desc = SORT[S.deSort or 6] or SORT[6], S.deDesc ~= false
  table.sort(list, function(a, b)
    local va, vb = key(a), key(b)
    if va == nil or vb == nil then
      if va == nil and vb == nil then return a.r.i < b.r.i end
      return vb == nil   -- recipes without a value go last, whichever way the column is sorted
    end
    if va == vb then return a.r.i < b.r.i end
    if desc then return va > vb end
    return va < vb
  end)

  local out = {}
  local measuredBands, estBands = {}, {}
  for _, e in ipairs(list) do
    local r, o = e.r, e.o
    if o.est then estBands[o.band] = true else measuredBands[o.band] = true end
    if o.est then lastCounts.est = lastCounts.est + 1 else lastCounts.measured = lastCounts.measured + 1 end
    local pick = S.sellPick[r.made]
    local c = NS.state(e.prof)
    local way = e.f.x.way
    local note = ""
    if pick == "de" then
      note = GOLD .. "  disenchant*|r"
    elseif way == "DE" then
      note = DIM .. "  disenchant|r"
    end
    local first = o.lines[1]
    local into = first and ((o.est and "~ " or "") .. itemName(first.item) .. ((first.chance < 0.995) and (DIM .. " " .. pct(first.chance) .. "|r") or "")) or (DIM .. "-|r")
    local value
    if e.known then
      value = (o.est and "~" or "") .. money(e.value)
    elseif e.value and e.value > 0 then
      value = money(e.value) .. DIM .. "?|r"   -- an outcome's material has no price: the rest of it
    else
      value = DIM .. "no price|r"
    end
    local function outlet(v, which)
      if not v then return DIM .. "-|r" end
      return (e.best == which and GREEN or "") .. money(v) .. (e.best == which and "|r" or "")
    end
    local tip = {}
    do
      local parts = {}
      for _, l in ipairs(e.dd.lines) do
        parts[#parts + 1] = pct(l.chance) .. " " .. qtyText(l) .. "x " .. itemName(l.item) .. (l.each and (" (" .. NS.plain(money(l.each)) .. " each)") or " (no price)")
      end
      tip[#tip + 1] = "Disenchants into: " .. table.concat(parts, ", ") .. "."
      tip[#tip + 1] = o.est and (DIM .. "~ an estimate: the original game's table for " .. bandText(o.band) .. ", not confirmed for Forever (" .. o.n .. " of " .. MIN_CASTS .. " of your own disenchants logged).|r")
        or (DIM .. "Measured: " .. o.n .. " of your own disenchants of " .. bandText(o.band) .. ".|r")
      if not e.known then tip[#tip + 1] = RED .. "A material it can give has no scanned price|r: " .. SCAN .. "." end
      tip[#tip + 1] = "Materials " .. (e.cost and money(e.cost) or "not priced") .. (e.f.mode == "buy" and ", parts bought" or (e.f.mode == "craft" and ", parts made" or ""))
        .. ". Time: " .. secsText(e.craftSecs) .. " to craft, " .. secsText(e.deSecs) .. " to disenchant."
      if e.best and e.best ~= "de" then
        tip[#tip + 1] = "It pays more " .. (e.best == "ah" and "at the auction house" or "at a vendor") .. " (in green)."
      end
      tip[#tip + 1] = e.can and "You know this recipe." or (c.st.seen and "You do not know this recipe." or "Not one of this character's professions (or its window was never opened).")
      tip[#tip + 1] = "Click for the outcomes one by one."
      tip[#tip + 1] = GOLD .. "Right-click for choices|r: Sells at (Disenchant counts it that way in routes and on the Craft page), the recipe's details, scan, search, link."
    end
    out[#out + 1] = { cols = {
        NS.COLOUR[c.ctx.colour(r, e.f.at)] .. r.name .. "|r" .. note,
        SHORT[e.prof] or e.prof,
        into, value,
        e.cost and money(e.cost) or (DIM .. "no price|r"),
        signed(e.profit), e.ph and signed(e.ph) or (DIM .. "-|r"),
        outlet(e.vend, "vendor"), outlet(e.ah, "ah"),
      }, item = r.made, recipe = r.id, deRecipe = r.id, prof = e.prof, menu = true, tip = tip,
      action = function() NS.deSelect(r.id) end,
      sellStep = S.sales ~= "off" and r.made or nil,
      value = e.value, known = e.known, cost = e.cost, profit = e.profit, ph = e.ph, vend = e.vend, ah = e.ah,
      est = o.est, band = o.band, best = e.best, can = e.can }
  end
  lastCounts.shown = #list
  local nm, ne = 0, 0
  for _ in pairs(measuredBands) do nm = nm + 1 end
  for _ in pairs(estBands) do ne = ne + 1 end
  lastStatus = string.format("%d of %d gear recipes shown. Outcomes: %d measured, %d estimates (~, the original game's table) in %d bands; %s.%s",
    #list, #all, lastCounts.measured, lastCounts.est, nm + ne, castNote, loading > 0 and ("  " .. loading .. " gear items not loaded by the game (yet).") or "")
  return out, "Disenchant"
end

-- ---- the pane: one recipe's outcomes ------------------------------------------------------------------------------
-- Rows: an outcome line is { cols = { material, chance, quantity, each, value }, item, deLine = the line's numbers };
-- everything else is { left, right } with key = "value" | "craft" | "note" | "mats" | "time" | "profit" | "ph" |
-- "vendor" | "ah" | "sellsAt" (that one carries sellItem and choice: a click opens the Sells at menu).
function NS.deDetail(recipeID)
  local S = settings()
  local r = recipeID and NS.data().byId[recipeID] or nil
  if not r then return {} end
  local c = NS.state(r.prof)
  local e = entryOf(c, r)
  if not e then
    return { { left = DIM .. "The game has not loaded this item yet, or it cannot be disenchanted.|r", key = "note" } }
  end
  local o, out = e.o, {}
  local function add(row)
    out[#out + 1] = row
    return row
  end
  add({ cols = { GOLD .. "Disenchanting one gives|r", DIM .. "chance|r", DIM .. "qty|r", DIM .. "each|r", DIM .. "value|r" }, heading = true, band = true })
  for _, l in ipairs(e.dd.lines) do
    add({ cols = { NS.itemText(l.item), pct(l.chance), qtyText(l), l.each and money(l.each) or (RED .. "?|r"), l.value and money(l.value) or (DIM .. "-|r") },
      item = l.item, deLine = l,
      tip = { pct(l.chance) .. " of disenchants give " .. qtyText(l) .. " (" .. string.format("%.2f", l.avg) .. " on average).",
        l.each and ("One sells for " .. money(l.each) .. (l.how == "vendor" and " at a vendor." or (" at the auction house after the cut (listed from " .. money(l.ahp or 0) .. ", " .. (l.listed or 0) .. " listed).")))
          or ((l.listed and "Too few are listed to count a price." or "Not scanned yet: ") .. (l.listed and "" or ((NS.scanLabel and NS.scanLabel("de") or "Scan disenchant materials") .. "."))),
        "Click at the auction house to search for it." } })
  end
  add({ key = "value", left = "Expected value of one", right = e.known and ((o.est and "~" or "") .. money(e.value / e.mk)) or ((e.value and e.value > 0) and (money(e.value / e.mk) .. DIM .. "?|r") or (RED .. "no price|r")),
    tip = { "The sum of chance x average quantity x what one sells for.", "No sales cap is applied: Kebold does not know how fast these materials sell." } })
  if e.mk ~= 1 then add({ key = "craft", left = "One craft makes " .. e.mk, right = e.value and money(e.value) or (DIM .. "-|r") }) end
  if o.est then
    add({ key = "note", left = DIM .. "~ Estimate: the original game's table for " .. bandText(o.band) .. ".|r", est = true })
    add({ key = "note", left = DIM .. "Not confirmed for Forever. " .. o.n .. " of " .. MIN_CASTS .. " of your own disenchants logged.|r", est = true,
      tip = { "Once " .. MIN_CASTS .. " of your own disenchants of this band are logged, the rates they gave are used instead of the table. /keboldde shows the log." } })
  else
    add({ key = "note", left = DIM .. "Measured: " .. o.n .. " of your own disenchants of " .. bandText(o.band) .. ".|r", est = false,
      tip = { "The rates your own disenchants gave, in place of the original game's table. /keboldde shows the log." } })
  end

  add({ left = "" })
  add({ left = GOLD .. "Crafting it to disenchant|r", band = true })
  add({ key = "mats", left = "Materials" .. (e.f.mode == "buy" and (DIM .. "  parts bought|r") or (e.f.mode == "craft" and (DIM .. "  parts made|r") or "")),
    right = e.cost and money(e.cost) or (RED .. "no price|r"),
    tip = { "What one craft's materials cost, the way the Craft page gets the parts (the one that earns the most per hour, unless you chose)." } })
  add({ key = "time", left = "Time", right = secsText(e.craftSecs) .. " + " .. secsText(e.deSecs) .. " disenchant",
    tip = { "The craft with the parts you make for it, then the disenchant cast" .. (select(2, NS.deCast()) and " (as seen in game)" or " (3.0 s assumed until one is seen)") .. " and the gap between casts." } })
  add({ key = "profit", left = "Profit disenchanted", right = signed(e.profit) })
  add({ key = "ph", left = "Per hour", right = e.ph and signed(e.ph) or (DIM .. "-|r") })

  add({ left = "" })
  add({ left = GOLD .. "Selling it instead|r", band = true })
  add({ key = "vendor", left = "Vendor", right = e.vend and (money(e.vend) .. ((e.cost) and ("  " .. signed(e.vend - e.cost)) or "")) or (DIM .. "unknown|r") })
  add({ key = "ah", left = "Auction house", right = e.ah and (money(e.ah) .. (e.cost and ("  " .. signed(e.ah - e.cost)) or ""))
    or (DIM .. (e.listed and ((e.ahp and "too few listed") or (e.listed > 0 and "only under vendor value" or "none listed")) or "not scanned") .. "|r"),
    tip = { "The cheapest listing not below vendor value, after the cut" .. (e.listed and (", " .. e.listed .. " listed.") or ".") } })
  if S.sales ~= "off" then
    local pick = S.sellPick[r.made]
    local x = e.f.x
    local text = pick and (NS.SELL_TEXT[pick] .. (((pick == "de" and x.way ~= "DE") or (pick == "ah" and x.way ~= "AH")) and (RED .. " n/a|r") or ""))
      or ("Auto: " .. (NS.wayLong(x.way) or "not counted"))
    add({ key = "sellsAt", left = "Sells at", right = (pick and GOLD or "") .. text .. (pick and "*|r" or ""), sellItem = r.made, choice = true,
      tip = { "Where the plans count this product as sold: routes, the Craft page and the profession window follow it.",
        "Disenchant: it counts at the expected value above and the disenchant cast is added to the craft's time.",
        GOLD .. "Click or right-click for choices.|r" } })
  end
  add({ left = "" })
  add({ key = "note", left = DIM .. "Kebold only counts: it never disenchants anything.|r" })
  return out
end

-- ---- the Disenchant page --------------------------------------------------------------------------------------------
-- Registered under "disenchant", between Craft and Shopping. One row of controls (Profession, Only ones I can
-- make, Only priced, Find, Scan disenchant materials), the list, and the pane of the selected recipe in the
-- split's right side. Sizes (all guesses until seen in game):
local DE = {
  profW = 120, mineW = 140, pricedW = 100, findW = 100, scanW = 168, quickW = 80,   -- the bar's controls
  paneHead = 54, paneFoot = 30, showW = 96, scanRecipeW = 84,
}
NS.DE = DE

-- Recipe, Profit and Per hour always stay. With the pane open the list is narrow and the others give way, the
-- highest drop number first. All nine fit the smallest window in every Row size once the pane is folded.
local COLUMNS = {
  { key = "name", title = HEADS[1], flex = 1, min = 116, sortable = true,
    tip = { "Recipe", "Gear the professions make that can be disenchanted, in its skill colour. disenchant after the name: it is counted as disenchanted (a gold * marks your own choice)." } },
  { key = "prof", title = HEADS[2], width = 56, sortable = true, drop = 6 },
  { key = "into", title = HEADS[3], width = 94, sortable = true, drop = 2,
    tip = { "Disenchants into", "The most likely outcome and its chance. ~ marks the original game's table (not confirmed for Forever); without it, the rates of your own logged disenchants." } },
  { key = "value", title = HEADS[4], width = 60, align = "RIGHT", sortable = true, drop = 1,
    tip = { "Value", "What disenchanting one craft's product gives on average: chance x quantity x what the material sells for at the auction house, after the cut.", "~ an estimate. ? a material has no scanned price." } },
  { key = "cost", title = HEADS[5], width = 62, align = "RIGHT", sortable = true, drop = 3, tip = { "Materials", "What one craft's materials cost, as on the Craft page." } },
  { key = "profit", title = HEADS[6], width = 66, align = "RIGHT", sortable = true, tip = { "Profit", "Value less materials: what one craft earns when its product is disenchanted." } },
  { key = "ph", title = HEADS[7], width = 68, align = "RIGHT", sortable = true, tip = { "Per hour", "Profit for an hour of crafting and disenchanting: the craft's casts and one disenchant cast for each product." } },
  { key = "vend", title = HEADS[8], width = 56, align = "RIGHT", sortable = true, drop = 4, tip = { "Vendor", "What a vendor pays for one craft's product. Green: more than disenchanting it." } },
  { key = "ah", title = HEADS[9], width = 56, align = "RIGHT", sortable = true, drop = 5,
    tip = { "AH", "What one craft's product sells for at the auction house after the cut (the cheapest listing not below vendor value, with enough listed). Green: more than disenchanting it." } },
}
NS.DE_COLUMNS = COLUMNS

local PANE_COLS = {
  { key = "name", flex = 1, min = 84 },
  { key = "chance", width = 36, align = "RIGHT" },
  { key = "qty", width = 30, align = "RIGHT", drop = 2 },
  { key = "each", width = 54, align = "RIGHT", drop = 1 },
  { key = "value", width = 58, align = "RIGHT" },
}
NS.DE_PANE_COLUMNS = PANE_COLS

local function buildPane(host)
  local p = CreateFrame("Frame", "KeboldsShinyDisenchantPane", host)
  p:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
  p:SetSize(NS.WIN.detail, 300)
  p.caption = UI.text(p, "dim", "Disenchanting")
  p.caption:SetPoint("TOPLEFT", 4, -2)
  p.icon = p:CreateTexture(nil, "ARTWORK")
  p.icon:SetSize(32, 32)
  p.icon:SetPoint("TOPLEFT", 4, -17)
  p.name = UI.text(p, "section")
  p.name:SetJustifyH("LEFT")
  p.name:SetWordWrap(false)
  p.sub = UI.text(p, "body")
  p.sub:SetJustifyH("LEFT")
  p.sub:SetWordWrap(false)
  p.list = UI.table(p, PANE_COLS, { header = false,
    onClick = function(b, button) NS.rowClick(b, button) end, onEnter = function(b) NS.rowEnter(b) end, onLeave = function(b) NS.rowLeave(b) end,
    empty = { icon = ICON, title = "No recipe selected", text = "Click a recipe in the list and what it disenchants into shows here: every outcome with its chance, its quantity and what it is worth." } })
  p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -DE.paneHead)
  p.bRecipe = UI.button(p, "Show recipe", DE.showW, function()
    local r = selID and NS.data().byId[selID] or nil
    if r and NS.openPanel then NS.openPanel(r.id) end   -- the page's onDetail sends it to the Craft page
  end, { "Show recipe", "The recipe's own details on the Craft page: materials, parts, where it sells, a buy list." })
  p.bRecipe:SetPoint("BOTTOMLEFT", 2, 3)
  p.bScan = NS.scanControl(UI.button(p, "Scan recipe", DE.scanRecipeW, function()
    if selID then NS.scanRecipe(selID) end
  end, { "Scan recipe", "Reads fresh auction house prices for what this recipe makes and everything needed to make it (a few seconds). The disenchant materials have their own scan above the list." }))
  p.bScan:SetPoint("LEFT", p.bRecipe, "RIGHT", 3, 0)
  p.rows, p.w, p.h, p.shownID = {}, NS.WIN.detail, 300, false
  function p:Layout(w, h)
    self.w, self.h = w, h
    self:SetSize(w, h)
    self.name:SetWidth(w - 46)
    self.sub:SetWidth(w - 46)
    self.list:Layout(w, max(40, h - DE.paneHead - DE.paneFoot))
  end
  function p:Fill(rows, r)
    self.rows, self.shownID = rows, r and r.id or false
    local tex = (r and not UI.plain() and settings().icons ~= false) and UI.iconOf({ item = r.made, recipe = r.id }) or nil
    if tex then
      self.icon:SetTexture(tex)
      self.icon:Show()
    else
      self.icon:Hide()
    end
    self.name:ClearAllPoints()
    self.name:SetPoint("TOPLEFT", tex and 42 or 4, -17)
    self.sub:ClearAllPoints()
    self.sub:SetPoint("TOPLEFT", tex and 42 or 4, -35)
    if r then
      local o = NS.deOutcome(r.made)
      self.name:SetText(NS.itemText(r.made, r.name))
      self.sub:SetText(r.prof .. (o and (" \194\183 " .. (QUALITY[o.quality] or "") .. " " .. o.kind .. ", item level " .. o.ilvl) or ""))
      self.bRecipe:Show()
      self.bScan:Show()
    else
      self.name:SetText("")
      self.sub:SetText("")
      self.bRecipe:Hide()
      self.bScan:Hide()
    end
    self.list:SetRows(rows)
  end
  return p
end

page = NS.page({ key = "disenchant", title = "Disenchant", order = 2.5, icon = ICON,
  tip = { "Disenchant", "Gear the professions make, valued by what it disenchants into: is it worth crafting to disenchant, against selling it?" },
  bars = 1, detail = true, columns = COLUMNS, marks = { "~", "*", "?" },
  empty = { icon = ICON, title = "Nothing to disenchant", text = "No gear recipe has a disenchant outcome." },
  rows = function() return NS.deRows() end,
  onSort = function(_, _, k) NS.deSortBy(k) end,
  selected = function(row) return row.deRecipe ~= nil and row.deRecipe == selID end,
  -- the split's right side is this page's own pane; a recipe's or an item's own details open on their own pages
  detailMine = function() return true end,
  onDetail = function(_, kind, id)
    local S = settings()
    if kind == "recipe" then
      local r = NS.data().byId[id]
      if r then S.prof = r.prof end
      S.tab = "recipes"
    else
      S.tab = "sales"
    end
  end,
  footer = function() return lastStatus end,
  build = function(pg)
    local at, bar = pg.at, pg.bar
    pg.dProf = at.put(UI.dropdown(bar, DE.profW, function()
      return settings().deProf or "All professions"
    end, function()
      local now_ = settings().deProf
      local items = { { title = true, text = "Profession" } }
      items[#items + 1] = { radio = true, checked = now_ == nil, text = "All professions", func = function()
        settings().deProf = nil
        NS.resetScroll()
        NS.refresh()
      end }
      for _, p in ipairs(NS.data().profs) do
        items[#items + 1] = { radio = true, checked = now_ == p, text = p, func = function()
          settings().deProf = p
          NS.resetScroll()
          NS.refresh()
        end }
      end
      return items
    end, { "Profession", "Gear of all nine professions in one list, or of one." }))
    pg.cMine = at.put(UI.check(bar, "Only ones I can make", function() return settings().deMine and true or false end, function(v)
      settings().deMine = v and true or nil
      NS.resetScroll()
      NS.refresh()
    end, { "Only ones I can make", "Only recipes this character knows (as read when the profession's window was last open)." }), 8, DE.mineW)
    pg.cPriced = at.put(UI.check(bar, "Only priced", function() return settings().dePriced and true or false end, function(v)
      settings().dePriced = v and true or nil
      NS.resetScroll()
      NS.refresh()
    end, { "Only priced", "Hides recipes without a profit figure: a material of the craft, or one the disenchant can give, has no price." }), 8, DE.pricedW)
    pg.eFind = at.put(UI.search(bar, DE.findW, function(self)
      local t = self:GetText() or ""
      if t ~= search then
        search = t
        NS.resetScroll()
        NS.refresh()
      end
    end), 8)
    pg.eFind:SetMaxLetters(30)
    local label = NS.scanLabel and NS.scanLabel("de") or "Scan disenchant materials"
    pg.bScan = at.put(NS.scanControl(UI.button(bar, label, DE.scanW, function() NS.scanButton("de") end,
      { label, SCAN_TIP, "It only looks prices up: nothing is bought." })), 8)
    if type(KeboldsShinyScan_HasQuick) == "function" then
      local quick = NS.scanLabel("quick")
      pg.bQuick = at.put(NS.scanControl(UI.button(bar, quick, DE.quickW, function() NS.scanButton("quick") end,
        { quick, "The whole auction house in one request: the gear on this page and the materials a disenchant gives, among everything else Kebold knows.",
          "The game allows it once per 15 minutes; when the server does not answer it reads gear only.", "It only looks prices up: nothing is bought." }),
        NS.quickWhy), 6)
    end
    pg.pane = buildPane(pg.split.right)
  end,
  layout = function(pg)
    local s = pg.split
    if type(pg.pane) == "table" and type(s) == "table" and s.rightW > 0 then pg.pane:Layout(s.rightW, s.h) end
  end,
  paint = function(pg)
    local S = settings()
    pg.dProf:Refresh()
    pg.cMine:Refresh()
    pg.cPriced:Refresh()
    pg.table:SetSort(S.deSort or 6, S.deDesc ~= false)
    local s = pg.split
    if type(s) == "table" and s.rightW > 0 then
      local r = selID and NS.data().byId[selID] or nil
      pg.pane:Layout(s.rightW, s.h)
      pg.pane:Fill(r and NS.deDetail(r.id) or {}, r)
      pg.pane:Show()
    else
      pg.pane:Hide()
    end
  end })
if type(NS.PAGE_ALIAS) == "table" then NS.PAGE_ALIAS.de = "disenchant" end

function NS.dePane() return page.pane end   -- for tests
