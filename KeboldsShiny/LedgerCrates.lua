-- Kebold's Shiny: Waylaid Crates (the model, the Crates page and its pane; the data is Crates.lua)
-- What each crate costs to fill, how much Merchant's Favor it gives, and so what one point of Favor costs: which
-- crate and which of its options is the cheapest way to points.
--
-- It only COUNTS. It never fills a crate, never hands one in, never buys or posts anything: the scan only looks
-- prices up, "Add to Shopping" only writes a line on Kebold's own shopping list.
--
-- EVERYTHING ABOUT THE CRATES IS FROM GUIDE SITES OF THE BETA AND HAS NOT BEEN SEEN IN GAME (see Crates.lua):
-- the options and their quantities, the Favor and silver per crate, the level needed, where they are handed in,
-- the crate item ids. Expert Favor is one site's figure (an estimate, ~); Artisan Favor and silver are not known
-- (?) until a Favor value is typed on the Settings page.
--
-- ---- how a crate is costed -------------------------------------------------------------------------------------------
-- N = the "Crates" stepper (how many of EACH crate are priced, 1 by default). For every option of a crate:
--   buy    the engine's supply of the item (ctx.supplyOf: the scanned price steps, cut off where a vendor is
--          cheaper, then the vendor) walked over the WHOLE quantity N x the option's quantity, with the walk the
--          shopping list uses (NS.shopWalk). So thin listings raise the price, and a quantity that is not all
--          listed has no buy cost ("only 12 listed"): half a fill does not seal a crate.
--   make   when a recipe in the data makes the item: what Kebold already says one made unit costs in that
--          profession's own context (ctx.part(item).craft), times the quantity. It is at LIST prices: it does not
--          move with the quantity, and the casting time is not counted. It only competes with buying when this
--          character knows the recipe, or a "Plan for" profile is shown; otherwise it is shown as information.
--   choice S.pick[item] as everywhere else: "have" = it costs nothing; "buy" / "craft" = that way when it is
--          possible (an explicit "craft" counts even for a recipe not known); none = the cheaper of the two.
-- The crate's fill is its cheapest option. Then
--   total cost           = the crate on the AH + cost to fill - silver back: a whole amount, for all N crates
--   total, fill only     = cost to fill - silver back: the same for crates he already holds ("earns X" when the
--                          silver pays for the fill)
--   per point            = total cost / expected Favor
--   per point with crate = the same with the crate itself bought on the auction house (its own supply walk over N)
--   expected Favor       = Favor x (1 + 0.05 x Performance Bonus rank)   (a 5% chance a rank of double Favor)
-- Assumed: what is in the bags is NOT taken off the cost (it is worth what it sells for; "Have it" says otherwise);
-- an unknown silver reward (Artisan) counts as 0; the 50 Favor of the first hand-in ever is not counted.
--
-- ---- API ---------------------------------------------------------------------------------------------------------------
-- NS.crateList() -> the crates (Crates.lua's list)      NS.crateLabel(crate) -> "Apprentice Ingots"
-- NS.crateReward(crate) -> favor (nil: not known), silver (nil: not known), est, typed
-- NS.cratePerf() -> the Performance Bonus rank counted, and whether it was typed in
-- NS.crateFigures(crate [, n]) -> { n, options = { { i, item, qty, units, bags, buy, short, got, listed, scanned,
--     make, makeProf, known, canMake, pick, cost, how = "buy"|"make"|"have", top, vend, pp, doubt, guess }, ... },
--     best = index of the cheapest option | nil, cost, how, favor (expected, all n), favor1 (one crate), base, est,
--     typed, silver (all n; 0 when not known), silverKnown, pp, crateCost, crateEach, crateFirst, crateListed,
--     crateShort, crateScanned, ppWith, held, total (crate + fill - silver back, all n; the fill alone when
--     noCrate), totalFill (fill - silver back, all n), ppFill, net (= total, only with a Favor value) }
-- NS.crateRows() -> the page's rows, title              NS.crateDetail(crateID) -> the pane's rows
-- NS.crateStatus() -> the page's one status line        NS.crateScanIDs() -> every option item, then the 30 crates
-- NS.crateOptions() -> the three settings (Settings page and its model)      NS.setCrateOpt(key, value)
-- NS.crateSelect(id) / NS.crateSelected() / NS.crateChoose(id, option index) / NS.crateFind(text) /
-- NS.crateSortBy(column) / NS.crateAddToShop(id) / NS.crateFacts(itemID) (the tooltip's lines)
--
-- ---- saved (with Kebold's other settings; NOT engine options, the engine never sees them) -------------------
-- S.crates = { perf = Performance Bonus rank typed in (nil: your own, read from the game; 0 for a profile),
--   artRaw / artGoods = Favor of an Artisan raw / goods crate typed in (nil: not known),
--   n = how many of each crate are priced, tier = 1..4 (nil: all), held, priced = the two filters,
--   sort = the sorted column's key ("name", "tier", "favor", "reward", "fill", "cost", "crate", "pp", "total",
--   "totalFill"; a number is the column of the nine-column list before 2026-11-13 and is read as its key), desc }

local NS = KeboldsShinyNS
if type(NS) ~= "table" then return end
local C = KeboldsShinyCrates
if type(C) ~= "table" or type(C.list) ~= "table" then return end
local UI = KeboldsShinyUI
local E = NS.E
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local DIM, RED, GOLD, GREEN = NS.DIM, NS.RED, NS.GOLD, NS.GREEN
local money, itemName, settings, try = NS.money, NS.itemName, NS.settings, NS.try

local ICON = "Interface\\Icons\\INV_Crate_01"
local MAX_N = 100
local SCAN_TIP = "Everything a Waylaid Crate can be filled with, and the 30 crates themselves: the prices the Crates page works with."

-- ---- the data, indexed --------------------------------------------------------------------------------------------------

local byId, fills = {}, {}   -- [crate id] = crate; [item id] = { { crate, option index }, ... }
for _, c in ipairs(C.list) do
  byId[c.id] = c
  for i, o in ipairs(c.options) do
    local list = fills[o[2]]
    if not list then
      list = {}
      fills[o[2]] = list
    end
    list[#list + 1] = { c, i }
  end
end

function NS.crateList() return C.list end
function NS.crateById(id) return byId[id] end
function NS.crateFills(item) return fills[item] end

local function tierOf(c) return C.tiers[c.tier] end

function NS.crateLabel(c)
  return tierOf(c).name .. " " .. c.name
end

local function store()
  local S = settings()
  if type(S.crates) ~= "table" then S.crates = {} end
  return S.crates
end

local function countN()
  local n = floor((tonumber(store().n) or 1) + 0.5)
  return max(1, min(MAX_N, n))
end
NS.crateCount = countN

-- The Performance Bonus rank that is counted: one typed in, else your own as the collector read it (a profile
-- is a fresh character: 0). Second value: true when it was typed in.
function NS.cratePerf()
  local v = tonumber(store().perf)
  if v then return max(0, min(C.perfMax, floor(v + 0.5))), true end
  if NS.who() then return 0, false end
  return max(0, min(C.perfMax, NS.legacyRank("Performance Bonus") or 0)), false
end

-- Favor and silver of one sealed crate: favor (nil when not known), silver in copper (nil when not known),
-- est (one site's beta figure), typed (the Favor was typed in on the Settings page).
function NS.crateReward(c)
  local t = tierOf(c)
  local k = c.goods and t.goods or t.raw
  local favor, typed = k.favor, false
  if favor == nil then
    local v = tonumber(store()[c.goods and "artGoods" or "artRaw"])
    if v and v > 0 then favor, typed = v, true end
  end
  return favor, k.silver, t.est == true, typed
end

-- The three settings, for the Settings page and its model. Each: key, label, hint, tip, min, max, get() -> the
-- value counted, set(v), changed() -> typed in, text() -> what the model's line says.
local OPTIONS
function NS.crateOptions()
  if OPTIONS then return OPTIONS end
  local function art(key, label, kind)
    return { key = key, label = label, min = 0, max = 999, w = 40,
      hint = "0 = not known (?): no per point figure",
      tip = "What one sealed Artisan " .. kind .. " crate gives in Merchant's Favor. The guide sites do not say: type what the game shows once you have handed one in. 0 puts it back to not known, and those crates then have no per point figure.",
      get = function() return tonumber(store()[key]) or 0 end,
      changed = function() return store()[key] ~= nil end,
      text = function()
        local v = tonumber(store()[key])
        return v and (GOLD .. v .. " Favor|r") or (DIM .. "not known|r")
      end }
  end
  OPTIONS = {
    { key = "perf", label = "Performance Bonus rank (Legacy)", min = 0, max = C.perfMax, w = 30,
      hint = "0 to 3: a 5% chance a rank of double Favor",
      tip = "The Legacy talent Performance Bonus: the expected Favor of a crate is its Favor x (1 + 0.05 x rank). Your own rank is used when it was read from the game; when it was not (the talent is found by its English name), it counts as 0: type your rank. A value typed here overrides it.",
      get = function() return (NS.cratePerf()) end,
      changed = function() return store().perf ~= nil end,
      text = function()
        local v, typed = NS.cratePerf()
        local _, found = NS.legacyRank("Performance Bonus")
        if not typed and found ~= true and not NS.who() then return DIM .. "not read from the game: type your rank|r" end
        return (typed and GOLD or "") .. v .. " of " .. C.perfMax .. (typed and "|r" or "")
      end },
    art("artRaw", "Artisan crate Favor (raw)", "raw (Herbs, Ore, Textiles, Curiosities)"),
    art("artGoods", "Artisan crate Favor (goods)", "goods (Fabrics, Ingots, Parts)"),
  }
  for _, o in ipairs(OPTIONS) do
    o.set = function(v) NS.setCrateOpt(o.key, v) end
  end
  return OPTIONS
end

-- perf: 0..3, forgotten when it equals the rank read from the game. artRaw / artGoods: a Favor value, 0 or nil
-- = not known again. n: how many of each crate are priced.
function NS.setCrateOpt(key, value)
  local st = store()
  local v = tonumber(value)
  if key == "perf" then
    if v then
      v = max(0, min(C.perfMax, floor(v + 0.5)))
      local own = NS.who() and 0 or max(0, min(C.perfMax, NS.legacyRank("Performance Bonus") or 0))
      if v == own then v = nil end
    end
    st.perf = v
  elseif key == "artRaw" or key == "artGoods" then
    if v then v = floor(v + 0.5) end
    st[key] = (v and v > 0) and min(999, v) or nil
  elseif key == "n" then
    v = v and max(1, min(MAX_N, floor(v + 0.5))) or 1
    st.n = v ~= 1 and v or nil
  else
    return
  end
  if NS.refresh then NS.refresh() end
end

-- ---- the model: one crate's figures --------------------------------------------------------------------------------

local function ladderOf(item)
  return E.parseLadder(NS.realmItems()[item])
end

-- The profession context an item is costed in: its maker's (so a made part's cost is that profession's own),
-- else any (a plain material costs the same in all of them).
local function stateFor(item)
  local d = NS.data()
  local r = d.maker[item]
  return NS.state(r and r.prof or d.profs[1]), r
end

local function optionOf(c, i, n)
  local o = c.options[i]
  local qty, item = o[1], o[2]
  local units = n * qty
  local st, r = stateFor(item)
  local ctx = st.ctx
  local pick = settings().pick[item]
  local e = { i = i, item = item, qty = qty, units = units, doubt = o.doubt, guess = o.guess == true, pick = pick, bags = NS.bagCount(item) }
  local L = ladderOf(item)
  e.scanned, e.listed = L ~= nil, L and L.total or nil
  local part = ctx.part(item)   -- nil for a plain material
  if pick == "have" then
    e.cost, e.how = 0, "have"
  else
    local stat
    if part then stat = part.buy else stat = ctx.matCost(item).c end
    local w = NS.shopWalk(ctx.supplyOf(item, stat), units)
    if w.short > 1e-9 then
      e.short, e.got = w.short, units - w.short
    else
      e.buy, e.top, e.vend = w.cost, w.top, w.vend
    end
  end
  if part then
    e.makeProf = r and r.prof or nil
    e.makeRecipe = r and r.id or nil
    e.known = (r and st.st.known and st.st.known[r.id] == true) and true or false
    e.canMake = e.known or NS.who() ~= nil
    if part.craft then e.make = units * part.craft end
  end
  if pick ~= "have" then
    local mk = (e.canMake or pick == "craft") and e.make or nil
    if pick == "craft" and mk then
      e.cost, e.how = mk, "make"
    elseif pick == "buy" and e.buy then
      e.cost, e.how = e.buy, "buy"
    elseif mk and (e.buy == nil or mk < e.buy) then
      e.cost, e.how = mk, "make"
    elseif e.buy then
      e.cost, e.how = e.buy, "buy"
    end
  end
  return e
end

function NS.crateFigures(c, n)
  n = n or countN()
  local f = { crate = c, n = n, options = {} }
  for i = 1, #c.options do
    local e = optionOf(c, i, n)
    f.options[i] = e
    if e.cost ~= nil and (f.cost == nil or e.cost < f.cost) then f.best, f.cost, f.how = i, e.cost, e.how end
  end
  local base, silver, est, typed = NS.crateReward(c)
  local rank = NS.cratePerf()
  f.base, f.est, f.typed, f.rank = base, est, typed, rank
  f.favor1 = base and base * (1 + C.perfStep * rank) or nil
  f.favor = f.favor1 and f.favor1 * n or nil
  f.silverKnown = silver ~= nil
  f.silver1 = silver or 0
  f.silver = f.silver1 * n
  -- the crate itself on the auction house
  local L = ladderOf(c.id)
  f.crateScanned = L ~= nil
  if L then
    f.crateListed = L.total
    if #L.tiers > 0 then
      f.crateFirst = L.tiers[1][1]
      local w = NS.shopWalk(NS.state(NS.data().profs[1]).ctx.supplyOf(c.id, nil), n)
      if w.short > 1e-9 then
        f.crateShort = w.short
      else
        f.crateCost, f.crateEach = w.cost, w.cost / n
      end
    end
  end
  -- What a point costs counts the crate itself (owner, 2026-11-12: "be sure to include the box price"):
  --   pp     = (the crate + cost to fill - silver back) / expected Favor; without a price for the crate it is the
  --            fill alone and `noCrate` says so (shown with "+?")
  --   ppFill = (cost to fill - silver back) / expected Favor: for a crate he already holds
  f.noCrate = f.crateCost == nil
  -- the two whole amounts (all n crates), Favor known or not: buying and filling, and filling a crate held
  if f.cost ~= nil then
    f.totalFill = f.cost - f.silver
    f.total = f.totalFill + (f.crateCost or 0)
  end
  for _, e in ipairs(f.options) do
    if e.cost ~= nil and f.favor and f.favor > 0 then
      e.ppFill = (e.cost - f.silver) / f.favor
      e.pp = (e.cost - f.silver + (f.crateCost or 0)) / f.favor
    end
  end
  if f.best then
    f.pp, f.ppFill = f.options[f.best].pp, f.options[f.best].ppFill
    if f.cost ~= nil and f.favor and f.favor > 0 then
      f.net = f.cost + (f.crateCost or 0) - f.silver
      if f.crateCost then f.ppWith = f.pp end
    end
  end
  f.held = NS.bagCount(c.id)
  return f
end

function NS.crateScanIDs()
  local ids, seen = {}, {}
  for _, c in ipairs(C.list) do
    for _, o in ipairs(c.options) do
      if not seen[o[2]] then
        seen[o[2]] = true
        ids[#ids + 1] = o[2]
      end
    end
  end
  for _, c in ipairs(C.list) do ids[#ids + 1] = c.id end
  return ids
end

-- ---- the scan ----------------------------------------------------------------------------------------------------------

if type(NS.scanPresetAdd) == "function" and not NS.cratePresetAdded then
  NS.cratePresetAdded = true
  if type(NS.SCAN_NAME) == "table" and not NS.SCAN_NAME.crates then NS.SCAN_NAME.crates = "Crate materials" end
  NS.scanPresetAdd(function()
    return { key = "crates", word = "crates", count = #NS.crateScanIDs(), tip = SCAN_TIP }
  end)
end

-- ---- texts -------------------------------------------------------------------------------------------------------------

local function numText(v)
  if abs(v - floor(v + 0.5)) < 1e-9 then return tostring(floor(v + 0.5)) end
  return (string.format("%.2f", v):gsub("0+$", ""))
end

-- What a point costs: "1s 20c"; a fill that pays for itself (silver back beats the cost): "earns 50c" in green.
-- noCrate: the crate itself has no price, so the figure is the fill alone ("+?" after it).
local function ppText(v, est, noCrate)
  if v == nil then return DIM .. "-|r" end
  local tail = noCrate and (RED .. " +?|r") or ""
  if v < 0 then return GREEN .. "earns " .. money(-v) .. "|r" .. tail end
  return (est and "~" or "") .. money(v) .. tail
end

-- A whole amount (Total cost, Fill only): the same marks as a per point figure.
local amountText = ppText

-- The silver one sealed crate pays back: "5s", "~7s 50c" (Expert: one site's figure), "?" (Artisan: not known).
local function rewardText(f)
  if not f.silverKnown then return RED .. "?|r" end
  return (f.est and "~" or "") .. money(f.silver1)
end

local function favorText(f)
  if not f.favor1 then return RED .. "?|r" end
  return (f.est and "~" or "") .. numText(f.favor1) .. (f.typed and (GOLD .. "*|r") or "")
end

local PICK_NOTE = { have = " have it", buy = " buy", craft = " make" }
local function optName(e)
  return e.qty .. " " .. itemName(e.item)
end

local function buyWhy(e)
  if e.short then
    if not e.scanned then return "no scan" end   -- short texts: they sit in narrow cells; the tooltip has the sentence
    return numText(max(0, e.got)) .. " listed"
  end
  return nil
end

-- The game's own name of a crate, when the client has loaded it; our label otherwise.
local asked = {}
local function liveName(id)
  local live = type(C_Item) == "table" and try(C_Item.GetItemNameByID, id) or nil
  if type(live) == "string" and live ~= "" then return live end
  if not asked[id] then
    asked[id] = true
    if type(C_Item) == "table" and type(C_Item.RequestLoadItemDataByID) == "function" then pcall(C_Item.RequestLoadItemDataByID, id) end
  end
  return nil
end

local function searchCrate(id)
  local name = liveName(id)
  if not name then
    NS.notice("The game has not given this crate's name yet (its item id is a guide site's and may be wrong). Search for Waylaid Crate by hand.")
    return false
  end
  return NS.searchAH(id)
end

local function handIn()
  local side = NS.side()
  local out = {}
  for _, k in ipairs({ "H", "A" }) do
    if side == nil or side == k then
      local t = C.turnIn[k]
      out[#out + 1] = { side = k, npc = t.npc, text = t.npc .. ", " .. t.zone, where = t.place .. " (about " .. string.format("%.1f, %.1f", t.x, t.y) .. ")" }
    end
  end
  return out
end
NS.crateHandIn = handIn

-- ---- the page: the model ---------------------------------------------------------------------------------------------
-- Rows: { cols = { Crate (+ " (2)" when 2 are held), Tier, Favor, Reward, Fill with, Cost to fill, Crate cost, Per
--   point, Total cost, Fill only }, item = the crate's item id, crate = the same, action (a click selects it), menu =
--   true, shopMenu, tip, and the numbers: tier, favor (expected, one crate), silver (one crate; nil: not known), est,
--   typed, fill = the cheapest option's index, fillItem, fillQty, how, cost, pp, ppFill, total, totalFill, crateEach,
--   ppWith, held, n }; or one row with `empty` (shown as the empty state).
-- Cost to fill, Total cost and Fill only are for ALL the crates priced (the Crates box); Favor, Reward and Crate
-- cost are one crate's; Per point is per point.

local HEADS = { "Crate", "Tier", "Favor", "Reward", "Fill with", "Cost to fill", "Crate cost", "Per point", "Total cost", "Fill only" }
local KEYS = { "name", "tier", "favor", "reward", "fill", "cost", "crate", "pp", "total", "totalFill" }
-- the nine columns before 2026-11-13, by number, as S.crates.sort was saved then (In bags is no column any more)
local OLD_SORT = { "name", "tier", "favor", "fill", "cost", "pp", "crate", "totalFill", "pp" }
local search = ""
local selID = nil          -- the crate whose options the pane shows
local chosen = {}          -- [crate id] = option index picked in the pane (this session), for Add to Shopping
local lastStatus = ""
local lastCounts = { shown = 0, all = #C.list, priced = 0 }
local page

local SORT = {
  name = function(x) return x.order end,
  tier = function(x) return x.c.tier end,
  favor = function(x) return x.f.favor1 end,
  reward = function(x) return x.f.silverKnown and x.f.silver1 or nil end,
  fill = function(x) return x.f.best and itemName(x.f.options[x.f.best].item) or nil end,
  cost = function(x) return x.f.cost end,
  crate = function(x) return x.f.crateEach end,
  pp = function(x) return x.f.pp end,
  total = function(x) return x.f.total end,
  totalFill = function(x) return x.f.totalFill end,
}

-- The sorted column's key. A number is what the nine-column list saved: it is read as that column's key, once.
local function sortKey()
  local st = store()
  local k = st.sort
  if type(k) == "number" then
    k = OLD_SORT[k]
    st.sort = k
  end
  if type(k) ~= "string" or not SORT[k] then return "pp" end
  return k
end
NS.crateSortKey = sortKey

function NS.crateSortBy(k)   -- a column's key, or its number in the list as it is now
  local st = store()
  if type(k) == "number" then k = KEYS[k] end
  if type(k) ~= "string" or not SORT[k] then return end
  if sortKey() == k then
    st.sort, st.desc = k, not (st.desc == true)
  else
    st.sort, st.desc = k, (k == "favor" or k == "reward")   -- Favor and Reward start high to low, everything else low to high
  end
  if not st.desc then st.desc = nil end
  if NS.resetScroll then NS.resetScroll() end
  NS.refresh()
end

function NS.crateSelect(id)
  selID = byId[id] and id or nil
  if page and type(page.pane) == "table" and type(page.pane.list) == "table" then page.pane.list.offset = 0 end
  NS.refresh()
end
function NS.crateSelected() return selID end

-- The option the pane's buttons act on: the one clicked, else the cheapest, else the first.
function NS.crateChoose(id, i)
  local c = byId[id]
  if not c then return end
  chosen[id] = (i and c.options[i]) and i or nil
  NS.refresh()
end
function NS.crateChosen(id, f)
  local c = byId[id]
  if not c then return nil end
  if chosen[id] and c.options[chosen[id]] then return chosen[id], true end
  f = f or NS.crateFigures(c)
  return f.best or 1, false
end

function NS.crateFind(text)   -- the Find box (also for tests)
  search = tostring(text or "")
end

function NS.crateStatus() return lastStatus end
function NS.crateCounts() return lastCounts end

local function resetFilters()
  local st = store()
  st.tier, st.held, st.priced = nil, nil, nil
  search = ""
  if page and type(page.eFind) == "table" then pcall(page.eFind.SetText, page.eFind, "") end
  if NS.resetScroll then NS.resetScroll() end
  NS.refresh()
end

local function anyPriced()
  local items = NS.realmItems()
  for _, id in ipairs(NS.crateScanIDs()) do
    local L = E.parseLadder(items[id])
    if L and #L.tiers > 0 then return true end
  end
  return false
end

-- "Get it by" for one option's item, in the context that makes it (the usual menu asks the profession on screen).
local function pickMenu(e)
  local now = settings().pick[e.item] or "auto"
  local items = { { title = true, text = "Get " .. itemName(e.item) .. " by" } }
  local function radio(key, text, disabled, tip)
    items[#items + 1] = { radio = true, checked = now == key, text = text, disabled = disabled or nil, tip = tip, func = function() NS.setPick(e.item, key) end }
  end
  radio("auto", e.makeProf and "Auto (cheaper)" or "Auto (buy it)", nil,
    e.makeProf and "The cheaper of buying it and making it; making only counts for a recipe you know." or "Bought at the scanned or the vendor's price.")
  if e.makeProf then
    radio("buy", "Buy", nil, "Always bought, when enough is listed.")
    radio("craft", "Make", not e.make, e.make and ("Always made with " .. e.makeProf .. ", also when the recipe is not known yet.") or "Not possible: Kebold has no cost for making it.")
  end
  radio("have", "Have it", nil, "You have them already (farmed or banked): they cost nothing.")
  return items
end

function NS.crateRows()
  local st = store()
  local n = countN()
  local SCAN = NS.scanLabel and NS.scanLabel("crates") or "Scan crate materials"
  local QUICK = (type(KeboldsShinyScan_HasQuick) == "function" and NS.scanLabel) and NS.scanLabel("quick") or nil
  lastCounts = { shown = 0, all = #C.list, priced = 0 }
  for _, c in ipairs(C.list) do liveName(c.id) end   -- asks the game for the crates' own names, once

  if not anyPriced() then
    lastStatus = DIM .. "Nothing a crate takes has a price yet: " .. SCAN .. " at the auction house.|r"
    return { { left = "No crate prices yet. " .. SCAN .. " at the auction house.",
      empty = { icon = ICON, title = "No crate prices yet",
        text = "What a point of Merchant's Favor costs comes from the auction house prices of what the crates are filled with. " .. SCAN .. " reads all "
          .. #NS.crateScanIDs() .. " items (the materials and the crates themselves, about " .. NS.scanTime(#NS.crateScanIDs()) .. ", at the auction house)."
          .. (QUICK and (" " .. QUICK .. " reads them too.") or ""),
        button = SCAN, onClick = function() NS.scanButton("crates") end,
        button2 = QUICK, onClick2 = QUICK and function() NS.scanButton("quick") end or nil } } }, "Crates"
  end

  local needle = search:lower()
  local list = {}
  local cheapest
  for order, c in ipairs(C.list) do
    local f = NS.crateFigures(c, n)
    if f.pp ~= nil then
      lastCounts.priced = lastCounts.priced + 1
      if cheapest == nil or f.pp < cheapest.f.pp then cheapest = { c = c, f = f } end
    end
    local keep = true
    if st.tier and c.tier ~= st.tier then keep = false end
    if keep and st.held and f.held <= 0 then keep = false end
    if keep and st.priced and f.pp == nil then keep = false end
    if keep and needle ~= "" then
      local hit = NS.crateLabel(c):lower():find(needle, 1, true) ~= nil
      for _, o in ipairs(c.options) do
        if not hit and itemName(o[2]):lower():find(needle, 1, true) then hit = true end
      end
      keep = hit
    end
    if keep then list[#list + 1] = { c = c, f = f, order = order } end
  end
  if #list == 0 then
    local why = {}
    if needle ~= "" then why[#why + 1] = "Find: " .. search end
    if st.tier then why[#why + 1] = C.tiers[st.tier].name end
    if st.held then why[#why + 1] = "Only crates I hold" end
    if st.priced then why[#why + 1] = "Only priced" end
    lastStatus = DIM .. "0 of " .. #C.list .. " crates shown.|r"
    return { { left = "No crate matches (" .. table.concat(why, ", ") .. ").",
      empty = { icon = "Interface\\Icons\\INV_Misc_Spyglass_02", title = "No crate matches",
        text = "No crate fits " .. table.concat(why, ", ") .. "." .. (st.held and " Only crates I hold lists the crates in your bags and bank (by the item ids of the guide sites)." or ""),
        button = "Show all", onClick = resetFilters } } }, "Crates"
  end

  local key, desc = SORT[sortKey()], st.desc == true
  table.sort(list, function(a, b)
    local va, vb = key(a), key(b)
    if va == nil or vb == nil then
      if va == nil and vb == nil then return a.order < b.order end
      return vb == nil   -- crates without a value go last, whichever way the column is sorted
    end
    if va == vb then return a.order < b.order end
    if desc then return va > vb end
    return va < vb
  end)

  local out = {}
  for _, x in ipairs(list) do
    local c, f = x.c, x.f
    local t = tierOf(c)
    local best = f.best and f.options[f.best] or nil
    local fill
    if best then
      fill = optName(best) .. (best.how == "make" and (DIM .. " made|r") or "")
        .. (best.pick and (GOLD .. (PICK_NOTE[best.pick] or "") .. "*|r") or "") .. (best.doubt and (DIM .. " ?|r") or "")
    else
      fill = DIM .. "no price|r"
    end
    local crateCell
    if f.crateEach then
      crateCell = money(f.crateEach)
    elseif f.crateShort then
      crateCell = RED .. numText(n - f.crateShort) .. " listed|r"
    elseif f.crateScanned then
      crateCell = DIM .. "0 listed|r"
    else
      crateCell = DIM .. "-|r"
    end
    local tip = {}
    do
      tip[#tip + 1] = NS.crateLabel(c) .. " crate" .. (c.goods and " (goods: double Favor)" or " (raw)") .. ", needs level " .. t.level .. "."
      local parts = {}
      for _, e in ipairs(f.options) do
        parts[#parts + 1] = optName(e) .. " (" .. (e.cost ~= nil and NS.plain(money(e.cost)) or (buyWhy(e) or "no price")) .. ")"
      end
      tip[#tip + 1] = "Filled with ONE of: " .. table.concat(parts, ", ") .. "."
      if f.favor1 then
        tip[#tip + 1] = "Favor " .. numText(f.base) .. (f.rank > 0 and (", " .. numText(f.favor1) .. " expected with Performance Bonus " .. f.rank) or "")
          .. (f.silverKnown and (", and " .. NS.plain(money(f.silver1)) .. " back") or ", silver back not known (counted as 0)") .. "."
      else
        tip[#tip + 1] = RED .. "Artisan Favor is not known|r: no per point figure until a value is typed on the Settings page (Waylaid crates)."
      end
      if f.est then tip[#tip + 1] = DIM .. "~ Expert Favor is one guide site's figure from the beta: an estimate.|r" end
      if n > 1 then tip[#tip + 1] = "Priced for " .. n .. " of this crate: the cost is of all " .. n .. ", and thin listings raise it." end
      if f.crateEach then
        tip[#tip + 1] = "The crate itself: " .. NS.plain(money(f.crateEach)) .. (n > 1 and " each on average" or "") .. " at the auction house, " .. (f.crateListed or 0) .. " listed. It is counted in Per point."
      else
        tip[#tip + 1] = RED .. "+? The crate itself has no price|r (" .. (f.crateShort and "not enough listed" or (f.crateScanned and "none listed" or "not scanned")) .. "): Per point and Total cost are the fill alone."
      end
      if f.total ~= nil then
        local of = n > 1 and (" for " .. n .. " crates") or ""
        tip[#tip + 1] = "Total cost" .. of .. " (crate + fill - silver back): " .. NS.plain(amountText(f.total, f.est, f.noCrate))
          .. ". Fill only" .. of .. " (fill - silver back, a crate you already hold): " .. NS.plain(amountText(f.totalFill, f.est)) .. "."
      end
      if f.held > 0 then tip[#tip + 1] = GREEN .. "You hold " .. f.held .. " of this crate.|r" end
      tip[#tip + 1] = DIM .. "From guide sites of the beta; not seen in game.|r"
      tip[#tip + 1] = "Click for every option. " .. GOLD .. "Right-click|r for the menu."
    end
    out[#out + 1] = { cols = {
        NS.crateLabel(c) .. (f.held > 0 and (DIM .. " (" .. f.held .. ")|r") or ""),
        t.name,
        favorText(f),
        rewardText(f),
        fill,
        f.cost ~= nil and money(f.cost) or (DIM .. "no price|r"),
        crateCell,
        f.favor1 and ppText(f.pp, f.est, f.noCrate) or (RED .. "?|r"),
        amountText(f.total, f.est, f.noCrate),
        amountText(f.totalFill, f.est),
      }, item = c.id, crate = c.id, menu = true, tip = tip,
      action = function() NS.crateSelect(c.id) end,
      tier = c.tier, favor = f.favor1, est = f.est, typed = f.typed, fill = f.best, fillItem = best and best.item or nil, fillQty = best and best.qty or nil,
      silver = f.silverKnown and f.silver1 or nil, total = f.total, totalFill = f.totalFill,
      how = f.how, cost = f.cost, pp = f.pp, ppFill = f.ppFill, noCrate = f.noCrate, net = f.net, crateEach = f.crateEach, ppWith = f.ppWith, held = f.held, n = n }
  end
  lastCounts.shown = #list
  local notes = {}
  if cheapest then
    local b = cheapest.f.options[cheapest.f.best]
    notes[#notes + 1] = "Cheapest: " .. (cheapest.f.pp < 0 and ("earns " .. money(-cheapest.f.pp)) or ((cheapest.f.est and "~" or "") .. money(cheapest.f.pp)))
      .. " a point" .. (cheapest.f.noCrate and " +? crate" or " with the crate") .. " (" .. NS.crateLabel(cheapest.c) .. ", " .. optName(b) .. ")."
  end
  local missing = 0
  for _, x in ipairs(list) do if x.f.pp ~= nil and x.f.noCrate then missing = missing + 1 end end
  if missing > 0 then notes[#notes + 1] = "+? " .. missing .. " without a price for the crate itself (scan the crate materials)." end
  local art = (store().artRaw and 1 or 0) + (store().artGoods and 1 or 0)
  notes[#notes + 1] = "~ Expert Favor is an estimate" .. (art < 2 and "; ? Artisan Favor is not known (Settings)" or "") .. "; all of it is from guide sites, not seen in game."
  lastStatus = string.format("%d of %d crates shown, %d priced%s. ", #list, #C.list, lastCounts.priced, n > 1 and (", " .. n .. " of each") or "") .. table.concat(notes, " ")
  return out, "Crates"
end

-- ---- the pane: one crate's options -----------------------------------------------------------------------------------
-- Rows: an option line is { cols = { "20 Copper Bar", in bags, buy, make, per point }, item, crateOpt = index,
-- opt = its figures, best = true on the cheapest, action (a click chooses it for Add to Shopping), menu = true,
-- shopMenu (Get it by) }; everything else is { left, right } with key = "favor" | "silver" | "level" | "first" |
-- "fill" | "cost" | "crate" | "silver2" | "net" (Total cost) | "favorN" | "pp" | "totalFill" (Fill only) | "ppFill" |
-- "held" | "handin" | "where" | "doubt" | "note".
function NS.crateDetail(id)
  local c = byId[id]
  if not c then return {} end
  local n = countN()
  local f = NS.crateFigures(c, n)
  local t = tierOf(c)
  local out = {}
  local function add(row)
    out[#out + 1] = row
    return row
  end
  local pick = NS.crateChosen(id, f)
  add({ cols = { GOLD .. "Fill with ONE of|r", DIM .. "bags|r", DIM .. "buy|r", DIM .. "make|r", DIM .. "a point|r" }, heading = true, band = true })
  for _, e in ipairs(f.options) do
    local isBest = f.best == e.i
    local name = (isBest and GREEN or "") .. optName(e) .. (isBest and "|r" or "")
      .. (e.pick and (GOLD .. (PICK_NOTE[e.pick] or "") .. "*|r") or "") .. (e.doubt and (DIM .. " ?|r") or "")
    local buy
    if e.pick == "have" then
      buy = DIM .. "have it|r"
    elseif e.buy then
      buy = money(e.buy)
    else
      buy = ((e.scanned and (e.got or 0) > 0) and RED or DIM) .. (buyWhy(e) or "-") .. "|r"
    end
    local make
    if e.make then
      make = (e.canMake or e.pick == "craft") and money(e.make) or (DIM .. NS.plain(money(e.make)) .. "|r")
    else
      make = DIM .. "-|r"
    end
    local tip = {}
    tip[#tip + 1] = n * e.qty .. " needed for " .. n .. (n == 1 and " crate" or " crates") .. " (" .. e.qty .. " a crate). In bags: " .. e.bags .. "."
    if e.pick == "have" then
      tip[#tip + 1] = "Set to Have it: it costs nothing."
    elseif e.buy then
      tip[#tip + 1] = "Buying all of them costs " .. money(e.buy) .. (e.top and (", paying up to " .. money(e.top) .. " each") or "")
        .. ((e.vend or 0) > 0 and (" (" .. numText(e.vend) .. " from a vendor)") or "") .. "."
    else
      tip[#tip + 1] = RED .. (e.scanned and ("Only " .. numText(e.got or 0) .. " of " .. e.units .. " are listed: it cannot be filled by buying.") or "Not scanned yet.") .. "|r"
    end
    if e.makeProf then
      tip[#tip + 1] = e.make and ("Making them with " .. e.makeProf .. " costs " .. money(e.make) .. " in materials at list prices (the casting is not counted)"
          .. (e.known and ": you know the recipe." or (NS.who() and "." or ": you do NOT know the recipe, so it is shown for information only.")))
        or (e.makeProf .. " makes it, but Kebold has no cost for that (a material has no price, or the plan may not use the recipe).")
    end
    if e.doubt then tip[#tip + 1] = RED .. "Doubt:|r " .. e.doubt end
    tip[#tip + 1] = isBest and (GREEN .. "The cheapest way to fill this crate.|r") or "Click to choose this option for Add to Shopping."
    tip[#tip + 1] = GOLD .. "Right-click|r: Get it by (buy, make, have it), search, link."
    add({ cols = { name, e.bags > 0 and tostring(e.bags) or (DIM .. "-|r"), buy, make, f.favor1 and ppText(e.pp, f.est, f.noCrate) or (RED .. "?|r") },
      item = e.item, crateOpt = e.i, opt = e, best = isBest, picked = pick == e.i, menu = true, shopMenu = pickMenu(e), tip = tip,
      action = function() NS.crateChoose(id, e.i) end })
  end

  add({ left = "" })
  add({ left = GOLD .. "Reward for one sealed crate|r", band = true })
  add({ key = "favor", left = "Merchant's Favor", right = f.favor1 and (favorText(f) .. ((f.rank > 0) and (DIM .. "  (" .. numText(f.base) .. " x " .. numText(1 + C.perfStep * f.rank) .. ")|r") or "")) or (RED .. "? not known|r"),
    tip = { f.favor1 and ((c.goods and "A goods crate (Fabrics, Ingots, Parts): double Favor." or "A raw crate (Herbs, Ore, Textiles, Curiosities).")
        .. (f.rank > 0 and (" Performance Bonus rank " .. f.rank .. ": a " .. 5 * f.rank .. "% chance of double Favor, so " .. numText(f.favor1) .. " on average.") or ""))
        or "The guide sites do not say what an Artisan crate gives. Type the value on the Settings page (Waylaid crates) once the game has shown it.",
      f.est and "~ one guide site's figure from the beta: an estimate." or (f.typed and "* typed in on the Settings page." or "From guide sites of the beta; not seen in game.") } })
  add({ key = "silver", left = "Reward (silver back)", right = f.silverKnown and rewardText(f) or (RED .. "?|r" .. DIM .. " counted as 0|r") })
  add({ key = "level", left = "Needs level", right = tostring(t.level) })
  add({ key = "first", left = DIM .. "Your first hand-in ever: +" .. C.firstFavor .. " Favor once (Shipping Label).|r" })

  add({ left = "" })
  add({ left = GOLD .. "Filling " .. n .. (n == 1 and " crate|r" or " crates|r"), band = true })
  local best = f.best and f.options[f.best] or nil
  add({ key = "fill", left = "Cheapest fill", right = best and (optName(best) .. (best.how == "make" and (DIM .. " made|r") or (best.how == "have" and (DIM .. " have it|r") or ""))) or (DIM .. "no option has a price|r") })
  add({ key = "cost", left = "Cost to fill", right = f.cost ~= nil and money(f.cost) or (DIM .. "no price|r"),
    tip = { "What the cheapest option costs for " .. n .. (n == 1 and " crate" or " crates") .. ": bought over the whole quantity, so thin listings raise it.",
      "What is in your bags is not taken off: set a material to Have it (right-click) when it costs you nothing." } })
  -- the sum, written out: the crate + the fill - the silver back = what it costs, over the Favor
  local crateText = f.crateEach and (money(f.crateCost) .. (n > 1 and (DIM .. " (" .. NS.plain(money(f.crateEach)) .. " each)|r") or ""))
      or (f.crateShort and (RED .. numText(n - f.crateShort) .. " listed|r") or (RED .. "?|r" .. DIM .. (f.crateScanned and " none listed" or " not scanned") .. "|r"))
  add({ key = "crate", left = "+ Crate cost" .. (n > 1 and (" (" .. n .. " crates)") or ""), right = crateText,
    tip = { "The cheapest listings of the crate itself" .. (f.crateListed and (", " .. f.crateListed .. " listed.") or "."),
      "Without a price the crate counts as nothing and Total cost and Per point are marked +?: scan the crate materials at the auction house.",
      "Crates also drop from mobs; a sealed crate binds." } })
  add({ key = "silver2", left = "- Reward (silver back)", right = f.silverKnown and ((f.est and "~" or "") .. money(f.silver)) or (RED .. "?|r" .. DIM .. " counted as 0|r") })
  if f.total ~= nil then
    local tip = { "Crate cost + cost to fill - the silver the hand-in gives back: what buying and filling " .. (n == 1 and "this crate" or ("these " .. n .. " crates")) .. " at the auction house costs you. A whole amount, not per point." }
    if f.total < 0 then tip[#tip + 1] = "earns: the silver back is more than it costs." end
    if f.noCrate then tip[#tip + 1] = RED .. "+? the crate itself has no price, so this is the fill alone.|r" end
    add({ key = "net", left = "= Total cost", right = amountText(f.total, f.est, f.noCrate), tip = tip })
    if f.favor then add({ key = "favorN", left = "/ Merchant's Favor", right = (f.est and "~" or "") .. numText(f.favor) }) end
  end
  add({ key = "pp", left = "= Per point", right = f.favor1 and ppText(f.pp, f.est, f.noCrate) or (RED .. "?|r"),
    tip = { "What one point of Favor costs: Total cost / expected Favor.", f.noCrate and (RED .. "+? the crate itself has no price, so this is the fill alone.|r") or nil } })
  add({ left = "" })
  add({ left = GOLD .. "With " .. (n == 1 and "a crate" or (n .. " crates")) .. " you already hold|r", band = true })
  do
    local tip = { "Cost to fill - the silver the hand-in gives back, the crate itself not counted. A whole amount, not per point." }
    if f.totalFill ~= nil and f.totalFill < 0 then tip[#tip + 1] = "earns: the silver back is more than the fill costs." end
    add({ key = "totalFill", left = "Fill only", right = amountText(f.totalFill, f.est), tip = tip })
  end
  add({ key = "ppFill", left = "Per point then", right = f.favor1 and ppText(f.ppFill, f.est) or (RED .. "?|r"),
    tip = { "Fill only / expected Favor: what one point of Favor costs when the crate itself cost you nothing." } })
  add({ key = "held", left = "Crates in your bags", right = f.held > 0 and (GREEN .. f.held .. "|r") or (DIM .. "none|r") })

  add({ left = "" })
  add({ left = GOLD .. "Hand in|r", band = true })
  for _, h in ipairs(handIn()) do
    add({ key = "handin", left = h.text, right = DIM .. (h.side == "H" and "Horde" or "Alliance") .. "|r", side = h.side })
    add({ key = "where", left = DIM .. "   " .. h.where .. "|r", side = h.side })
  end
  for _, e in ipairs(f.options) do
    if e.doubt then add({ key = "doubt", left = RED .. "? |r" .. DIM .. e.doubt .. "|r", item = e.item, tip = { e.doubt } }) end
  end
  if f.est then add({ key = "note", left = DIM .. "~ Expert Favor and reward: one site's beta figures.|r", est = true }) end
  add({ key = "note", left = DIM .. "From guide sites of the beta; not seen in game.|r" })
  add({ key = "note", left = DIM .. "Kebold only counts: it never fills or hands in a crate.|r" })
  return out
end

-- The option chosen in the pane (the cheapest unless another was clicked), times the crates priced, as one plain
-- item on the shopping list. Returns the entry's index, the item and the quantity.
function NS.crateAddToShop(id)
  local c = byId[id]
  if not c or type(NS.shopAdd) ~= "function" then return nil end
  local i = NS.crateChosen(id)
  local o = c.options[i]
  local units = countN() * o[1]
  local at, why = NS.shopAdd({ kind = "item", id = o[2], n = units })
  if at then
    NS.notice("Added " .. units .. " " .. itemName(o[2]) .. " to the shopping list (" .. NS.crateLabel(c) .. " crate).", "info")
  else
    NS.notice("Not added: " .. tostring(why) .. ".")
  end
  return at, o[2], units
end

-- ---- item tooltips -------------------------------------------------------------------------------------------------
-- On a crate: its cheapest fill and the cost, its Favor, what a point costs. On something a crate takes: which
-- crate and how many. As { label, value, text } like NS.itemFacts; for one crate, as the character itself.
local function crateFacts(id)
  local out = {}
  local c = byId[id]
  if c then
    local f = NS.crateFigures(c, 1)
    local best = f.best and f.options[f.best] or nil
    out[#out + 1] = { label = "Cheapest fill", value = best and (optName(best) .. ", " .. money(f.cost)) or (DIM .. "not priced|r"),
      text = best and ("Cheapest fill: " .. optName(best) .. " for " .. money(f.cost)) or "Cheapest fill: not priced (scan the crate materials)" }
    out[#out + 1] = { label = "Favor", value = favorText(f) .. DIM .. " (" .. NS.crateLabel(c) .. ")|r",
      text = "Favor: " .. (f.favor1 and ((f.est and "~" or "") .. numText(f.favor1)) or "? (not known)") .. " (" .. NS.crateLabel(c) .. ", from guide sites)" }
    if f.favor1 then
      out[#out + 1] = { label = "A point costs", value = ppText(f.pp, f.est, f.noCrate), text = f.pp ~= nil and ("A point costs " .. NS.plain(ppText(f.pp, f.est, f.noCrate))) or nil }
    end
  end
  for _, pair in ipairs(fills[id] or {}) do
    local fc, o = pair[1], pair[1].options[pair[2]]
    out[#out + 1] = { label = "Fills", value = NS.crateLabel(fc) .. " crate" .. DIM .. " (" .. o[1] .. " needed)|r",
      text = "Fills: " .. NS.crateLabel(fc) .. " crate (" .. o[1] .. " needed)" }
  end
  return out
end
function NS.crateFacts(id)
  if type(id) ~= "number" or not (byId[id] or fills[id]) then return {} end
  if type(NS.asMe) == "function" then return NS.asMe(crateFacts, id) end
  return crateFacts(id)
end

if type(NS.itemFacts) == "function" and not NS.crateFactsHooked then
  NS.crateFactsHooked = true
  local inner = NS.itemFacts
  NS.itemFacts = function(id, ...)
    local out = inner(id, ...)
    if type(out) == "table" and type(id) == "number" and (byId[id] or fills[id]) then
      local ok, more = pcall(NS.crateFacts, id)
      for _, fact in ipairs(ok and type(more) == "table" and more or {}) do out[#out + 1] = fact end
    end
    return out
  end
end

-- ---- the Crates page -------------------------------------------------------------------------------------------------
-- Registered under "crates", between Disenchant and Shopping. One row of controls (Tier, Only crates I hold, Only
-- priced, Find, Crates stepper, Scan crate materials, Quick scan), the list, and the pane of the selected crate
-- in the split's right side. Sizes (all guesses until seen in game):
local CR = {
  tierW = 96, heldW = 122, pricedW = 86, findW = 74, nLabelW = 40, nBoxW = 30, scanW = 142, quickW = 76,   -- the bar's controls
  paneHead = 54, paneFoot = 30, addW = 124, searchW = 124,
}
NS.CR = CR

-- Crate, Fill with, Per point and Total cost stay with the pane open; the others give way, the highest drop
-- number first. All ten fit the smallest window in every Row size once the pane is folded (their widths add up to
-- 622, which is all the roomy rows leave at 1050), so Crate and Fill with share the spare width. Widths are for compact
-- rows (the kit scales them).
local COLUMNS = {
  { key = KEYS[1], title = HEADS[1], flex = 1, min = 100, sortable = true,
    tip = { "Crate", "The 30 Waylaid Crates by tier and kind (the game's own names are not known yet). Sorted by this column they are in the guide's order.", "(2): you hold two of this crate (bags and bank)." } },
  { key = KEYS[2], title = HEADS[2], width = 48, sortable = true, drop = 9 },
  { key = KEYS[3], title = HEADS[3], width = 34, align = "RIGHT", sortable = true, drop = 7,
    tip = { "Favor", "Merchant's Favor of one sealed crate, with your Performance Bonus counted in.", "~ an estimate (Expert: one site's beta figure). ? not known (Artisan). * typed in on the Settings page." } },
  { key = KEYS[4], title = HEADS[4], width = 44, align = "RIGHT", sortable = true, drop = 8,
    tip = { "Reward", "The silver the hand-in of one sealed crate pays back.", "~ an estimate (Expert: one site's beta figure). ? not known (Artisan): counted as 0." } },
  { key = KEYS[5], title = HEADS[5], flex = 1, min = 78, sortable = true, drop = 1,
    tip = { "Fill with", "The cheapest of the crate's options: the quantity and the item to put in. made: cheaper made than bought. A gold * marks your own choice for that item." } },
  { key = KEYS[6], title = HEADS[6], width = 60, align = "RIGHT", sortable = true, drop = 4,
    tip = { "Cost to fill", "What the materials of that option cost for the number of crates priced (the Crates box), bought over the whole quantity." } },
  { key = KEYS[7], title = HEADS[7], width = 54, align = "RIGHT", sortable = true, drop = 5,
    tip = { "Crate cost", "What the crate itself costs at the auction house (one crate; the average over the number priced)." } },
  { key = KEYS[8], title = HEADS[8], width = 54, align = "RIGHT", sortable = true,
    tip = { "Per point", "What one point of Merchant's Favor costs: Total cost / expected Favor.", "+? the crate itself has no price yet: the figure is the fill alone." } },
  { key = KEYS[9], title = HEADS[9], width = 66, align = "RIGHT", sortable = true,
    tip = { "Total cost", "Buying and filling from the auction house: crate cost + cost to fill - the silver back, for the number of crates priced. A whole amount, not per point.",
      "earns: the silver back is more than it costs.", "+? the crate itself has no price yet: the figure is the fill alone." } },
  { key = KEYS[10], title = HEADS[10], width = 56, align = "RIGHT", sortable = true, drop = 6,
    tip = { "Fill only", "For a crate you already hold: cost to fill - the silver back, for the number of crates priced. A whole amount, not per point.",
      "earns: the silver back is more than the fill costs." } },
}
NS.CRATE_COLUMNS = COLUMNS

local PANE_COLS = {
  { key = "name", flex = 1, min = 84 },
  { key = "bags", width = 28, align = "RIGHT", drop = 2 },
  { key = "buy", width = 56, align = "RIGHT" },
  { key = "make", width = 50, align = "RIGHT", drop = 1 },
  { key = "pp", width = 52, align = "RIGHT" },
}
NS.CRATE_PANE_COLUMNS = PANE_COLS

local function buildPane(host)
  local p = CreateFrame("Frame", "KeboldsShinyCratePane", host)
  p:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
  p:SetSize(NS.WIN.detail, 300)
  p.caption = UI.text(p, "dim", "Waylaid Crate")
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
    selected = function(row) return row.crateOpt ~= nil and row.picked == true end,
    empty = { icon = ICON, title = "No crate selected", text = "Click a crate in the list and every way to fill it shows here: what each option costs bought or made, what it gives, and where to hand it in." } })
  p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -CR.paneHead)
  p.bAdd = UI.button(p, "Add to Shopping", CR.addW, function()
    if selID then NS.crateAddToShop(selID) end
  end, { "Add to Shopping", "Puts the chosen option (the cheapest, unless you clicked another) on the shopping list, for the number of crates priced.", "It only writes the list: nothing is bought." })
  p.bAdd:SetPoint("BOTTOMLEFT", 2, 3)
  p.bSearch = UI.button(p, "Search for crate", CR.searchW, function()
    if selID then searchCrate(selID) end
  end, { "Search the auction house", "Searches the auction house for the crate itself (the auction house must be open, and the game must know the crate's name)." })
  p.bSearch:SetPoint("LEFT", p.bAdd, "RIGHT", 3, 0)
  p.rows, p.w, p.h, p.shownID = {}, NS.WIN.detail, 300, false
  function p:Layout(w, h)
    self.w, self.h = w, h
    self:SetSize(w, h)
    self.name:SetWidth(w - 46)
    self.sub:SetWidth(w - 46)
    self.list:Layout(w, max(40, h - CR.paneHead - CR.paneFoot))
  end
  function p:Fill(rows, c)
    self.rows, self.shownID = rows, c and c.id or false
    local tex = (c and not UI.plain() and settings().icons ~= false) and (UI.iconOf({ item = c.id }) or ICON) or nil
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
    if c then
      local t = tierOf(c)
      self.name:SetText(liveName(c.id) or (NS.crateLabel(c) .. " crate"))
      self.sub:SetText(NS.crateLabel(c) .. " \194\183 " .. (c.goods and "goods" or "raw") .. " \194\183 level " .. t.level)
      self.bAdd:Show()
      self.bSearch:Show()
    else
      self.name:SetText("")
      self.sub:SetText("")
      self.bAdd:Hide()
      self.bSearch:Hide()
    end
    self.list:SetRows(rows)
  end
  return p
end

page = NS.page({ key = "crates", title = "Crates", order = 2.75, icon = ICON,
  tip = { "Crates", "Waylaid Crates: what each costs to fill, the Merchant's Favor it gives, and so which crate and which filling is the cheapest way to points." },
  bars = 1, detail = true, columns = COLUMNS, marks = { "~", "*", "?" },
  empty = { icon = ICON, title = "No crates", text = "No crate matches." },
  rows = function() return NS.crateRows() end,
  onSort = function(_, key, k) NS.crateSortBy(SORT[key] and key or k) end,
  selected = function(row) return row.crate ~= nil and row.crate == selID end,
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
    pg.dTier = at.put(UI.dropdown(bar, CR.tierW, function()
      local t = store().tier
      return t and C.tiers[t].name or "All tiers"
    end, function()
      local now_ = store().tier
      local items = { { title = true, text = "Tier" } }
      items[#items + 1] = { radio = true, checked = now_ == nil, text = "All tiers", func = function()
        store().tier = nil
        NS.resetScroll()
        NS.refresh()
      end }
      for i, t in ipairs(C.tiers) do
        items[#items + 1] = { radio = true, checked = now_ == i, text = t.name, tip = "Needs level " .. t.level .. ".", func = function()
          store().tier = i
          NS.resetScroll()
          NS.refresh()
        end }
      end
      return items
    end, { "Tier", "All 30 crates, or the ones of one tier." }))
    pg.cHeld = at.put(UI.check(bar, "Only crates I hold", function() return store().held and true or false end, function(v)
      store().held = v and true or nil
      NS.resetScroll()
      NS.refresh()
    end, { "Only crates I hold", "Only the crates in your bags and bank." }), 4, CR.heldW)
    pg.cPriced = at.put(UI.check(bar, "Only priced", function() return store().priced and true or false end, function(v)
      store().priced = v and true or nil
      NS.resetScroll()
      NS.refresh()
    end, { "Only priced", "Hides crates without a per point figure: no option has a price, or the crate's Favor is not known." }), 4, CR.pricedW)
    pg.eFind = at.put(UI.search(bar, CR.findW, function(self)
      local t = self:GetText() or ""
      if t ~= search then
        search = t
        NS.resetScroll()
        NS.refresh()
      end
    end), 6)
    pg.eFind:SetMaxLetters(30)
    pg.lCount = at.label("Crates", CR.nLabelW)
    pg.sCount = at.put(UI.stepper(bar, { min = 1, max = MAX_N, step = 1, w = CR.nBoxW,
      tip = { "Crates", "How many of EACH crate are priced. Cost to fill, Total cost and Fill only are then of all of them, so the per point figure shows the prices moving as the cheap listings run out." } },
      function() return countN() end, function(v) NS.setCrateOpt("n", v) end), 4)
    local label = NS.scanLabel and NS.scanLabel("crates") or "Scan crate materials"
    pg.bScan = at.put(NS.scanControl(UI.button(bar, label, CR.scanW, function() NS.scanButton("crates") end,
      { label, SCAN_TIP, "It only looks prices up: nothing is bought." })), 4)
    if type(KeboldsShinyScan_HasQuick) == "function" then
      local quick = NS.scanLabel("quick")
      pg.bQuick = at.put(NS.scanControl(UI.button(bar, quick, CR.quickW, function() NS.scanButton("quick") end,
        { quick, "The whole auction house in one request: the crates and what they take, among everything else Kebold knows.",
          "The game allows it once per 15 minutes; when the server does not answer it reads gear only.", "It only looks prices up: nothing is bought." }),
        NS.quickWhy), 4)
    end
    pg.pane = buildPane(pg.split.right)
  end,
  layout = function(pg)
    local s = pg.split
    if type(pg.pane) == "table" and type(s) == "table" and s.rightW > 0 then pg.pane:Layout(s.rightW, s.h) end
  end,
  paint = function(pg)
    local st = store()
    pg.dTier:Refresh()
    pg.cHeld:Refresh()
    pg.cPriced:Refresh()
    pg.sCount:Refresh()
    pg.table:SetSort(sortKey(), st.desc == true)
    local s = pg.split
    if type(s) == "table" and s.rightW > 0 then
      local c = selID and byId[selID] or nil
      pg.pane:Layout(s.rightW, s.h)
      pg.pane:Fill(c and NS.crateDetail(c.id) or {}, c)
      pg.pane:Show()
    else
      pg.pane:Hide()
    end
  end })
if type(NS.PAGE_ALIAS) == "table" then NS.PAGE_ALIAS.crate = "crates" end

function NS.cratePane() return page.pane end   -- for tests
