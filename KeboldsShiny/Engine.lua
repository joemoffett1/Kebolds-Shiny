-- Kebold's Shiny calculation engine
-- Plain Lua 5.1 with no game calls: recipes and prices in, numbers out, so it can be run and checked outside the
-- game (tests/lua/engine_test.lua, tests/addon_route.py). It is the web page's leveling and profit logic ported
-- function by function (site/template.html: matCost, partOptions, recipeCost, profitOf, chanceAt, ptsAt, bomOf,
-- supplyOf, supCost, bomSup, craftCostAt, netAt, plan, worthCurve, and the "Best /h" choice in compute). Keep the
-- two in step: a change of rule belongs in both.
--
--   local db  = KeboldsShinyEngine.load(KeboldsShinyData)
--   local ctx = KeboldsShinyEngine.new(db, { ladder = fn(itemID), vendor = fn(itemID), known = fn(recipe),
--                                            canMake = fn(recipe), learnAt = fn(recipe), pick = fn(itemID),
--                                            sellPick = fn(recipe), learnCost = fn(recipe),
--                                            deValue = fn(recipe), opts = {...} })
--   local route = ctx.plan("Blacksmithing", 150, 225)
--   local route = ctx.planBest("Blacksmithing", 150, 225)   -- parts made ahead, and recipes bought only when they pay
--   local list  = ctx.shopping(route.segs)
--   local ways  = ctx.approaches(recipe)    -- cheapest mix / buy every part / make every part, and the best per hour
--   local curve = ctx.worthCurve(recipe)    -- how many are worth making before prices move
--   local x, mode, why = ctx.bestInfo(recipe)   -- what the profit views show: the approach that pays most per hour

local E = {}
KeboldsShinyEngine = E

local floor, ceil, max, min, abs, huge = math.floor, math.ceil, math.max, math.min, math.abs, math.huge

local function round(x)
  return floor(x + 0.5)
end

-- Splits on a single character and keeps empty fields.
local function split(s, sep)
  local out, pos = {}, 1
  while true do
    local a = s:find(sep, pos, true)
    if not a then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, a - 1)
    pos = a + 1
  end
  return out
end
E.split = split

E.defaults = {
  depth = 20,        -- an item's list price is the average of its cheapest this-many units
  gap = 0.5,         -- seconds between casts
  cast = 5,          -- cast seconds for a recipe with no known cast time
  timeValue = 10,    -- gold per hour your time is worth, for the "cheapest" route
  cap = 50,          -- AH sales count up to this share (%) of what is listed, then at vendor value
  cut = 5,           -- auction house cut (%)
  minListed = 3,     -- an AH sale price needs at least this many listed
  minPH = 0,         -- gold per hour below which a craft stops being worth making (worthCurve)
  sell = true,       -- take what the crafts sell for off the cost
  ahSales = true,    -- count AH sales for things likely to sell (not gear) when their prices were scanned
  gearAH = false,    -- count AH sales for gear too
  deGear = false,    -- count gear at its disenchant value when that beats where it would sell otherwise (needs
                     -- env.deValue; in game only, off by default: the disenchant tables are unconfirmed)
  mode = "cost",     -- "cost" or "time"
  parts = "auto",    -- crafted parts: "auto" = the cheaper of making and buying; "buy" or "craft" = that, wherever
                     -- it is possible (the page's Crafted parts setting). env.pick(item) overrides it per part.
  items = false,     -- include recipes learned from a recipe item you do not know yet
  guess = false,     -- include recipes whose source is a guess
  overtime = 0,      -- Working Overtime rank: +2 points of skill-up chance a rank (the talent reads 10% at rank 5)
  chef = 0,          -- Master Chef rank: chance of one extra item (rank 4 reads 30%, rank 5 gives 50%; 1 to 3 assumed 10% a rank)
  skillBonus = nil,  -- the skill-up bonus itself (0.10 for 10 points), when the game's talent text was read; beats overtime
  chefExtra = nil,   -- NOT USED any more: the talent's text reads "30%" at every rank, 5/5 included, where the game gives 50%
  exclude = {},      -- [recipe id] = true
}

-- KeboldsShinyData -> tables. Recipes keep the page's order: the route breaks ties by it.
function E.load(data)
  local db = { recipes = {}, byId = {}, byProf = {}, profs = {}, line = {}, maker = {}, items = {} }
  for id, text in pairs(data.items) do
    local f = split(text, "|")
    db.items[id] = { name = f[1], vp = tonumber(f[2]), raw = f[3] == "r" }
  end
  for _, p in ipairs(data.profs) do
    db.profs[#db.profs + 1] = p.name
    db.line[p.name] = p.line
    local list = {}
    db.byProf[p.name] = list
    for _, text in ipairs(p.recipes) do
      local f = split(text, "|")
      local fl = f[14] or ""
      local r = {
        id = tonumber(f[1]), name = f[2], made = tonumber(f[3]) or 0, mk0 = tonumber(f[4]) or 1,
        learn = tonumber(f[5]) or 1, y = tonumber(f[6]), g = tonumber(f[7]), grey = tonumber(f[8]),
        src = f[9], kind = f[10] or "", fee = tonumber(f[11]) or 0, cast = tonumber(f[12]), sell = tonumber(f[13]),
        gear = fl:find("g", 1, true) ~= nil, guess = fl:find("q", 1, true) ~= nil, start = fl:find("s", 1, true) ~= nil,
        est = fl:find("e", 1, true) ~= nil, isNew = fl:find("n", 1, true) ~= nil, colEst = fl:find("c", 1, true) ~= nil,
        regs = {}, pat = tonumber(f[16]) or 0, prof = p.name,
      }
      for item, q in (f[15] or ""):gmatch("(%d+):(%d+)") do
        r.regs[#r.regs + 1] = { tonumber(item), tonumber(q) }
      end
      r.col = r.y ~= nil and r.grey ~= nil
      r.i = #db.recipes + 1
      db.recipes[r.i] = r
      db.byId[r.id] = r
      list[#list + 1] = r
      if r.made > 0 and not db.maker[r.made] then db.maker[r.made] = r end
    end
  end
  return db
end

-- "<day>;<total qty>;<price>:<qty>,..." as the scanner saves it -> { day, total, tiers = { {price, qty}, ... } }
function E.parseLadder(text)
  if type(text) ~= "string" then return nil end
  local day, total, rest = text:match("^(%d+);(%d+);(.*)$")
  if not day then return nil end
  local tiers = {}
  for p, q in rest:gmatch("(%d+):(%d+)") do
    tiers[#tiers + 1] = { tonumber(p), tonumber(q) }
  end
  return { day = tonumber(day), total = tonumber(total), tiers = tiers }
end

-- Average price of the cheapest `need` units of a ladder, to a tenth of a copper.
function E.ladderAvg(tiers, need)
  local got, cost = 0, 0
  for _, t in ipairs(tiers) do
    local take = min(t[2], need - got)
    cost = cost + take * t[1]
    got = got + take
    if got >= need then break end
  end
  if got == 0 then return nil end
  return { p = round(cost / got * 10) / 10, got = got }
end

-- Cost of buying units number from+1 .. from+qty of a supply; short = how many of those are more than is listed.
function E.supCost(S, from, qty)
  local cost, pos, last = 0, 0, 0
  local stop = from + qty
  for _, st in ipairs(S.steps) do
    local p, q = st[1], st[2]
    local lo, hi = max(from, pos), min(stop, pos + q)
    if hi > lo then cost = cost + (hi - lo) * p end
    pos = pos + q
    last = p
    if pos >= stop then return { cost = cost, short = 0 } end
  end
  local rest = stop - max(from, pos)
  if S.after ~= nil then return { cost = cost + rest * S.after, short = 0 } end
  return { cost = cost + rest * last, short = rest }
end

-- An insertion-ordered sum per key, so results do not depend on the order `pairs` happens to use.
local function omap()
  return { keys = {}, v = {} }
end
local function oadd(m, k, x)
  if m.v[k] == nil then
    m.keys[#m.keys + 1] = k
    m.v[k] = x
  else
    m.v[k] = m.v[k] + x
  end
end

local NONE = { time = 0, casts = 0, how = "-" }
-- Master Chef: chance of one extra item by rank. 4 and 5 are known (see E.defaults), the rest assumed.
-- Seen in game 2026-11-10: at 5/5 the profession window still shows the talent text "30% chance", while a craft
-- of 3 vendors as 4.5 (owner). So the text is a fixed sentence, not the rank's value: 10 points a rank.
local CHEF = { [0] = 0, 0.1, 0.2, 0.3, 0.4, 0.5 }

function E.new(db, env)
  env = env or {}
  local o = {}
  for k, v in pairs(E.defaults) do o[k] = v end
  for k, v in pairs(env.opts or {}) do o[k] = v end
  local ctx = { db = db, opts = o }
  local maker, items = db.maker, db.items
  local ladCache, memo, infoCache, clc, bomc = {}, {}, {}, {}, {}
  local sibs = {}    -- the same prices with every part bought / made (sibling, below)
  local bestCache, worthCache = {}, {}   -- ctx.bestInfo / ctx.worthBest answers
  local recipeCost   -- defined below, used by partOptions

  -- Not on the web page, and with no env.learnCost / no "have" pick nothing here changes a number:
  -- * env.pick(item) == "have": the material is yours already (farmed, banked). It costs nothing wherever a
  --   material is costed and is never on a shopping list. No quantity is asked for: all of it counts as had.
  -- * env.learnCost(recipe) -> copper to learn it once (a trainer's fee, a recipe item's price), 0 when it is known
  --   or free, nil when it cannot be got at all (it then stays out of every route).
  -- * ban: recipes ctx.planBest decided not to buy; they are not used as a step or to make a part.
  local ban = env.ban or {}
  local lcCache = {}
  local function have(item)
    return env.pick ~= nil and env.pick(item) == "have"
  end
  local HAVE = { c = 0, time = 0, casts = 0, how = "Have" }
  local function learnCost(r)
    if not env.learnCost then return 0 end
    local v = lcCache[r]
    if v == nil then
      v = env.learnCost(r)
      if v == nil then v = false end
      lcCache[r] = v
    end
    return v or nil
  end
  ctx.learnCost = learnCost
  local function setBan(b)
    for k in pairs(ban) do ban[k] = nil end
    for k in pairs(b or {}) do ban[k] = true end
    memo, infoCache, clc, bomc, sibs = {}, {}, {}, {}, {}   -- everything worked out with the old set
    bestCache, worthCache = {}, {}
  end
  ctx.setBan = setBan
  -- A copy of the set now in force (what the last planBest or setBan left): for a caller that plans something
  -- else in this context and wants to put things back afterwards.
  function ctx.getBan()
    local b = {}
    for k in pairs(ban) do b[k] = true end
    return b
  end

  local function lad(item)
    local L = ladCache[item]
    if L == nil then
      L = (env.ladder and env.ladder(item)) or false
      ladCache[item] = L
    end
    return L or nil
  end
  ctx.ladder = lad

  local function ladderPrice(item)
    local L = lad(item)
    if L and #L.tiers > 0 then return E.ladderAvg(L.tiers, max(1, o.depth or 1)) end
    return nil
  end

  local function vendPrice(item)
    local v = env.vendor and env.vendor(item)
    if v ~= nil then return v end
    local it = items[item]
    return it and it.vp or nil
  end
  ctx.vendPrice = vendPrice

  -- A part can be crafted when a recipe makes it and the character can use that recipe.
  local function makerOf(item)
    local it = items[item]
    if it and it.raw then return nil end
    local r = maker[item]
    if r and (ban[r.id] or learnCost(r) == nil) then return nil end
    if r and env.canMake and not env.canMake(r) then return nil end
    return r
  end
  local function isRaw(item)
    local it = items[item]
    return (it and it.raw) or maker[item] == nil
  end

  local function learnOf(r)
    local v = env.learnAt and env.learnAt(r)
    return v or r.learn
  end
  ctx.learnOf = learnOf

  local function makes(r)
    if r.prof ~= "Cooking" then return r.mk0 end
    return r.mk0 + (CHEF[o.chef] or 0.1 * o.chef)
  end
  ctx.makes = makes

  local function castOf(r)
    return (r.cast or o.cast) + o.gap
  end

  local function seenKey(r)
    return r.made > 0 and r.made or ("r" .. r.id)
  end

  -- What a bought material costs: the average of its cheapest units, or a vendor when that is no dearer.
  local function matCost(item)
    if have(item) then return { c = 0, time = 0, casts = 0, how = "Have" } end
    local lp = ladderPrice(item)
    local c, how = lp and lp.p or nil, lp and "AH" or "-"
    local vp = vendPrice(item)
    if vp ~= nil and (c == nil or vp <= c) then c, how = vp, "Vendor" end
    return { c = c, time = 0, casts = 0, how = how }
  end
  ctx.matCost = matCost

  -- A crafted part: what buying one costs and what making one costs.
  local function partOptions(item, seen)
    local m = memo[item]
    if m then return m end
    local r = makerOf(item)
    local lp = ladderPrice(item)
    local craft = nil
    if r and not seen[item] then
      seen[item] = true
      local t = recipeCost(r, seen)
      seen[item] = nil
      if t.cost ~= nil then
        local mk = makes(r)
        craft = { c = t.cost / mk, time = t.time / mk, casts = t.casts / mk, how = "Craft" }
      end
    end
    local buy = lp and { c = lp.p, time = 0, casts = 0, how = "AH" } or nil
    m = { buy = buy, craft = craft }
    memo[item] = m
    return m
  end

  -- Make or buy one part. A choice for this part (env.pick) beats the general setting (opts.parts); "craft" and
  -- "buy" fall back to the other when theirs is impossible. Otherwise the cheaper; ties go to making, as on the page.
  local function choose(opt, item)
    local pick = env.pick and env.pick(item)
    if pick == "have" then return HAVE end   -- yours already: nothing to buy, nothing to make
    if pick ~= "buy" and pick ~= "craft" then pick = o.parts end
    if pick == "craft" then return opt.craft or opt.buy end
    if pick == "buy" then return opt.buy or opt.craft end
    if not opt.craft then return opt.buy end
    if not opt.buy then return opt.craft end
    if opt.buy.c < opt.craft.c then return opt.buy end
    return opt.craft
  end

  function recipeCost(r, seen)
    local cost, time, casts, ok = 0, castOf(r), 1, true
    for _, reg in ipairs(r.regs) do
      local n, q = reg[1], reg[2]
      local p
      if isRaw(n) then
        p = matCost(n)
      else
        p = choose(partOptions(n, seen or { [seenKey(r)] = true }), n) or NONE
      end
      if p.c == nil then ok = false else cost = cost + q * p.c end
      time = time + q * p.time
      casts = casts + q * p.casts
    end
    return { cost = ok and cost or nil, time = time, casts = casts }
  end

  -- What one unit of an item sells for at the auction house: the cheapest listing that is not below its vendor
  -- value `floorV` (anything under it is not a price to match), and how many are listed. nil, nil when it was
  -- never scanned; nil, total when nothing is listed at or above the floor.
  local function ahSale(item, floorV)
    local L = lad(item)
    if not L then return nil, nil end
    for _, tier in ipairs(L.tiers) do
      if tier[1] >= (floorV or 0) then return tier[1], L.total end
    end
    return nil, L.total
  end
  -- The same after the cut, as a sale is counted: nil unless at least minListed are listed. Also the listing's
  -- price and the number listed. (What info() does for a product; used for what a disenchant gives, LedgerDisenchant.lua.)
  function ctx.saleEach(item, floorV)
    local ahp, listed = ahSale(item, floorV)
    if ahp ~= nil and (listed or 0) >= o.minListed then return ahp * (1 - o.cut / 100), ahp, listed end
    return nil, ahp, listed
  end

  -- Cost, time and sale of one craft at list prices.
  -- The share of what is listed that counts as sold at the AH price: the measured share of your own auctions of
  -- this product that sold (env.sellRate, in game only) when there is one, else the AH sales cap setting.
  local function capShare(r)
    local m = env.sellRate and env.sellRate(r)
    if m ~= nil then return m end
    return o.cap / 100
  end

  local function info(r)
    local x = infoCache[r]
    if x then return x end
    local t = recipeCost(r, { [seenKey(r)] = true })
    x = { cost = t.cost, secs = t.time, casts = t.casts }
    local mk = makes(r)
    -- Where this product may sell. A choice for it (env.sellPick: "vendor", "ah" or "de") beats the general setting.
    local pick = env.sellPick and env.sellPick(r)
    local useAH = pick == "ah" or (pick ~= "vendor" and o.ahSales and (not r.gear or o.gearAH))
    -- AH sale price: the cheapest listing that is not below vendor value (anything under it is not a price to match).
    -- Read whenever the product was scanned, so it can be shown even when it is not used.
    if r.made > 0 then x.ahp, x.listed = ahSale(r.made, r.sell) end
    -- Disenchanting it instead (not on the web page; without env.deValue nothing here changes a number):
    -- env.deValue(recipe) -> what the materials of one disenchanted product sell for, and the seconds one disenchant
    -- takes; nil when it cannot be disenchanted or a material has no price. Asked only for a product set to
    -- "de" by hand, or for gear on Auto with the deGear option on while sales count at the best price.
    local dv, dsecs
    if env.deValue and r.made > 0 and (pick == "de" or (pick == nil and r.gear and o.deGear and o.ahSales)) then
      dv, dsecs = env.deValue(r)
    end
    if dv ~= nil and t.cost ~= nil then
      x.drev, x.dsecs = mk * dv, mk * (dsecs or 0)
      x.dp = x.drev - t.cost
    end
    if t.cost ~= nil and r.sell ~= nil then x.vp = mk * r.sell - t.cost end
    if useAH and t.cost ~= nil and x.ahp ~= nil and (x.listed or 0) >= o.minListed then
      x.ap = round(mk * x.ahp * (1 - o.cut / 100)) - t.cost
    end
    if pick == "de" and x.dp ~= nil then
      x.way, x.p = "DE", x.dp
    elseif pick == "ah" and x.ap ~= nil then
      x.way, x.p = "AH", x.ap
    elseif x.vp ~= nil and (x.ap == nil or x.vp >= x.ap) then
      x.way, x.p = "Vendor", x.vp
    elseif x.ap ~= nil then
      x.way, x.p = "AH", x.ap
    end
    -- gear on Auto with deGear on: disenchanted when that pays more than where it would sell otherwise
    if pick == nil and x.dp ~= nil and (x.p == nil or x.dp > x.p) then x.way, x.p = "DE", x.dp end
    if x.way == "DE" then x.secs = x.secs + x.dsecs end   -- the disenchant casts are part of the craft's time
    infoCache[r] = x
    return x
  end
  ctx.info = info

  -- Skill-up chance: certain below yellow, then (grey - skill) / (grey - yellow), none at grey.
  local function chanceAt(r, s)
    if not r.col or s < learnOf(r) then return 0 end
    if s < r.y then return 1 end
    if s >= r.grey then return 0 end
    return min(1, (r.grey - s) / (r.grey - r.y) + (o.skillBonus or 0.02 * o.overtime))
  end
  ctx.chanceAt = chanceAt

  -- "o" orange, "y" yellow, "g" green, "x" grey at skill s.
  function ctx.colour(r, s)
    if not r.col then return "x" end
    if s < r.y then return "o" end
    if r.g and s < r.g then return "y" end
    if s < r.grey then return "g" end
    return "x"
  end

  -- Every cast one craft of r takes, the parts you make for it included: { {r = recipe, n = casts}, ... }
  local function castList(r, mult, acc, seen)
    mult = mult or 1
    acc = acc or { list = {}, at = {} }
    seen = seen or { [seenKey(r)] = true }
    local e = acc.at[r]
    if not e then
      e = { r = r, n = 0 }
      acc.at[r] = e
      acc.list[#acc.list + 1] = e
    end
    e.n = e.n + mult
    for _, reg in ipairs(r.regs) do
      local n, q = reg[1], reg[2]
      if not isRaw(n) then
        local pr = makerOf(n)
        if pr and not seen[n] then
          local c = choose(partOptions(n, seen), n)
          if c and c.how == "Craft" then
            seen[n] = true
            castList(pr, mult * q / makes(pr), acc, seen)
            seen[n] = nil
          end
        end
      end
    end
    return acc
  end

  -- Expected skill points from one craft of r at skill s, counting same-profession parts you make for it.
  -- skip: [part recipe] = its stock entry { made, taken } from ctx.plan (parts made ahead, ctx.planAhead). Units
  -- of a part that really were made ahead (made - taken still in stock) gave their points where they were made,
  -- so they give none here; units not made ahead are made at this step and count as always. With some in stock
  -- the answer is the average over the crafts one skill point takes: the stocked parts' points come in once each
  -- one's stock is used up. (site/template.html: ptsAt, line for line)
  local function ptsAt(r, s, skip)
    if not r.col or s < learnOf(r) then return 0 end
    local L = clc[r]
    if not L then
      L = {}
      for _, e in ipairs(castList(r).list) do
        if e.r.prof == r.prof then L[#L + 1] = e end
      end
      clc[r] = L
    end
    if not (chanceAt(r, s) > 0) then return 0 end
    local t, H = 0, nil   -- H: { crafts the part's stock lasts, points per craft the part adds after that }, shortest first
    for _, e in ipairs(L) do
      local p = e.n * chanceAt(e.r, s)
      local st = skip and e.r ~= r and skip[e.r] or nil
      local a = st and st.made - st.taken or 0
      if a > 1e-9 and p > 0 then
        local k = a / (e.n * makes(e.r))
        H = H or {}
        local i = #H
        while i > 0 and H[i][1] > k do i = i - 1 end
        table.insert(H, i + 1, { k, p })
      else
        t = t + p
      end
    end
    if not H then return t end
    local k, got = 0, 0
    for _, h in ipairs(H) do
      if got + (h[1] - k) * t >= 1 then break end
      got = got + (h[1] - k) * t
      k = h[1]
      t = t + h[2]
    end
    if k == 0 then return t end
    return 1 / (k + (1 - got) / t)
  end
  ctx.ptsAt = ptsAt

  -- The units of parts made ahead that 1/c crafts of r use up: taken from the stock, { { part recipe, units }, ... } or nil.
  local function takeStock(r, c, skip)
    if not skip then return nil end
    local out = nil
    for _, e in ipairs(clc[r] or {}) do
      local st = e.r ~= r and skip[e.r] or nil
      if st then
        local a = st.made - st.taken
        if a > 1e-9 then
          local u = min(a, e.n * makes(e.r) / c)
          st.taken = st.taken + u
          out = out or {}
          out[#out + 1] = { e.r, u }
        end
      end
    end
    return out
  end

  -- Materials to buy and parts to make for `mult` crafts of r (both insertion-ordered sums). Materials set to
  -- "have it" go to buy.have, a third sum that nothing prices.
  local function bomOf(r, mult, buy, made, seen)
    seen = seen or { [seenKey(r)] = true }
    for _, reg in ipairs(r.regs) do
      local n, need = reg[1], reg[2] * mult
      if have(n) then   -- yours already: kept apart, never bought or made
        buy.have = buy.have or omap()
        oadd(buy.have, n, need)
      elseif isRaw(n) then
        oadd(buy, n, need)
      else
        local pr = makerOf(n)
        local c = nil
        if pr and not seen[n] then c = choose(partOptions(n, seen), n) end
        if c and c.how == "Craft" then
          oadd(made, n, need)
          seen[n] = true
          bomOf(pr, need / makes(pr), buy, made, seen)
          seen[n] = nil
        else
          oadd(buy, n, need)
        end
      end
    end
  end
  ctx.bomOf = bomOf

  -- Supply of one bought item: price steps, cheapest first, then `after` = the unit price once they are used up
  -- (a vendor, or the list price when there is no ladder), or nil when nothing more is listed.
  local function supplyOf(item, stat)
    if have(item) then return { n = item, steps = {}, after = 0, known = true } end
    local vend = nil
    if isRaw(item) then vend = vendPrice(item) end
    local L = lad(item)
    if not (L and #L.tiers > 0) then
      return { n = item, steps = {}, after = stat, known = vend ~= nil and stat ~= nil and abs(stat - vend) < 1e-6 }
    end
    local steps, kept = {}, 0
    for _, t in ipairs(L.tiers) do
      if vend ~= nil and t[1] >= vend then break end
      steps[#steps + 1] = { t[1], t[2] }
      kept = kept + t[2]
    end
    if vend ~= nil then return { n = item, steps = steps, after = vend, known = true } end
    -- listed beyond the tiers the scanner kept: at least the dearest kept price
    if L.total > kept then steps[#steps + 1] = { L.tiers[#L.tiers][1], L.total - kept } end
    return { n = item, steps = steps, after = nil, known = true }
  end
  ctx.supplyOf = supplyOf

  -- A crafted part's two prices and which one is in use: { buy, craft, how = "AH" | "Craft", r = its recipe }.
  -- nil for a plain material.
  function ctx.part(item)
    if isRaw(item) then return nil end
    local opt = partOptions(item, {})
    local c = choose(opt, item)
    return { buy = opt.buy and opt.buy.c or nil, craft = opt.craft and opt.craft.c or nil, how = c and c.how or nil, r = makerOf(item) }
  end

  local function statOf(item)
    if isRaw(item) then return matCost(item).c end
    local opt = partOptions(item, {})
    return opt.buy and opt.buy.c or nil
  end

  -- What one craft of r buys, each item with its supply; false when something cannot be bought at all.
  local function bomSup(r)
    local B = bomc[r]
    if B ~= nil then return B end
    local buy, made = omap(), omap()
    bomOf(r, 1, buy, made)
    B = {}
    for _, n in ipairs(buy.keys) do
      local stat
      if isRaw(n) then
        stat = matCost(n).c
      else
        local opt = partOptions(n, { [seenKey(r)] = true })
        stat = opt.buy and opt.buy.c or nil
      end
      local S = supplyOf(n, stat)
      if #S.steps == 0 and S.after == nil then
        B = false
        break
      end
      B[#B + 1] = { u = buy.v[n], S = S }
    end
    bomc[r] = B
    return B
  end

  -- Material cost of the NEXT craft of r when `used` ([item] = units) has already been bought.
  local function craftCostAt(r, used)
    local B = bomSup(r)
    if not B then return nil end
    local c, short = 0, nil
    for _, b in ipairs(B) do
      local x = E.supCost(b.S, used and used[b.S.n] or 0, b.u)
      c = c + x.cost
      if x.short > 1e-9 then short = b.S.n end
    end
    return { c = c, short = short }
  end
  ctx.craftCostAt = craftCostAt

  -- Net cost of one craft once `used` crafts of it are already headed for the AH: past the capped share of what
  -- is listed, the extras count at vendor value.
  local function netAt(r, used, cost)
    local x = info(r)
    if x.cost == nil then return nil end
    if cost == nil then cost = x.cost end
    if not o.sell or x.p == nil then return cost end
    local rev = x.p + x.cost
    if x.way ~= "AH" then return cost - rev end
    if used * makes(r) < (x.listed or 0) * capShare(r) then return cost - rev end
    if r.sell ~= nil then return cost - makes(r) * r.sell end
    return cost
  end
  ctx.netAt = netAt

  -- The same prices and settings with every part bought ("buy") or every part made ("craft"), wherever that is
  -- possible. Choices for single parts (env.pick) are left behind; built on first use.
  -- A material you have stays had, and recipes not bought stay out.
  local function sibling(mode)
    local c = sibs[mode]
    if not c then
      local e, op = {}, {}
      for k, v in pairs(env) do e[k] = v end
      for k, v in pairs(o) do op[k] = v end
      op.parts = mode
      e.pick, e.opts, e.ladder, e.ban = nil, op, lad, ban
      if env.pick then
        e.pick = function(item) return env.pick(item) == "have" and "have" or nil end
      end
      c = E.new(db, e)
      sibs[mode] = c
    end
    return c
  end

  -- The three ways to get a recipe's parts, each with what one craft then costs, takes and earns, and the one that
  -- earns the most per hour (the page's "Best /h": it leaves this context's own numbers, "auto", only for an
  -- approach that still makes a profit and pays more per hour).
  --   { list = { {mode = "auto", cost, secs, casts, vp, ap, way, p, ph}, {mode = "buy", ...}, {mode = "craft", ...} },
  --     best = "auto" | "buy" | "craft" }
  local MODES = { "auto", "buy", "craft" }
  function ctx.approaches(r)
    local list = {}
    for i, mode in ipairs(MODES) do
      local x = i == 1 and info(r) or sibling(mode).info(r)
      list[i] = { mode = mode, cost = x.cost, secs = x.secs, casts = x.casts, vp = x.vp, ap = x.ap, way = x.way, p = x.p,
        ph = x.p ~= nil and x.p / x.secs * 3600 or nil }
    end
    local best = list[1]
    for i = 2, #list do
      local a = list[i]
      if a.p ~= nil and a.p > 0 and (best.ph == nil or a.ph > best.ph + 1e-9) then best = a end
    end
    return { list = list, best = best.mode }
  end

  -- Has the player chosen how a part of this recipe is got? True when any part in its tree (parts of parts
  -- included) has env.pick "buy" or "craft"; "have" is not a choice of approach.
  local function pickedIn(r, seen)
    if not env.pick then return false end
    seen = seen or { [seenKey(r)] = true }
    for _, reg in ipairs(r.regs) do
      local n = reg[1]
      if not isRaw(n) and not seen[n] then
        local pick = env.pick(n)
        if pick == "buy" or pick == "craft" then return true end
        local pr = maker[n]
        if pr then
          seen[n] = true
          local hit = pickedIn(pr, seen)
          seen[n] = nil
          if hit then return true end
        end
      end
    end
    return false
  end

  -- The context that costs things under one approach: this one for "auto", else the sibling that buys / makes
  -- every part (its info, part, worthCurve, bomOf then all speak for that approach).
  function ctx.modeCtx(mode)
    if mode == "buy" or mode == "craft" then return sibling(mode) end
    return ctx
  end

  -- What the profit views show for a recipe: the approach that earns the most per hour (approaches().best), as
  -- long as the player has not chosen himself. Returns info-like numbers (the table info() of that approach
  -- returns), the approach ("auto" | "buy" | "craft") and why:
  --   "best"  the best per hour of the three (it is "auto" unless another approach makes a profit and pays more)
  --   "pick"  a part of the recipe has a Buy / Make choice (env.pick): his choices are used, as info() has them
  --   "set"   the Crafted parts option (opts.parts) is "buy" or "craft": that approach, for every recipe
  -- Leveling does not use this: routes are planned by cost, on info().
  function ctx.bestInfo(r)
    local b = bestCache[r]
    if not b then
      if o.parts == "buy" or o.parts == "craft" then
        b = { info(r), "auto", "set" }
      elseif pickedIn(r) then
        b = { info(r), "auto", "pick" }
      else
        local mode = ctx.approaches(r).best
        b = { mode == "auto" and info(r) or sibling(mode).info(r), mode, "best" }
      end
      bestCache[r] = b
    end
    return b[1], b[2], b[3]
  end

  -- How many crafts stay worth making. Walks forward one price step at a time: the next craft's materials get
  -- dearer as cheap tiers run out, and AH sales stop counting past the capped share of what is listed. Returns
  -- segments of constant profit, the count worth making (math.huge = no limit), the total profit over them and
  -- why it ends; nil when the recipe has no cost or no sale.
  --   { segs = { {from, to, cost, profit, ph, nx = item whose price steps up next | "AH" (the sales cap) | nil,
  --               pr = {unit price per material}}, ... },
  --     worth, total, stop = { why = "cost" | "out" | "cap", n = item that runs out, cost, profit, ph, pr } | nil,
  --     known = every material's depth is really known, mats = { {n = item, u = units per craft}, ... } }
  -- mode (optional): "buy" or "craft" = the curve under that approach, as approaches() costs it.
  -- all (optional): the walk goes on past the point where a craft stops paying, so a buy list can be made for any
  -- number of crafts. The segments after that point carry past = true and may show a loss; worth, total and stop
  -- are exactly what they are without it.
  local function worthCurve(r, mode, all)
    if mode == "buy" or mode == "craft" then return sibling(mode).worthCurve(r, nil, all) end
    local x = info(r)
    if x.cost == nil or x.p == nil or not x.way then return nil end
    local B = bomSup(r)
    if not B then return nil end
    local mk = makes(r)
    local floorPH, ahWay = o.minPH * 10000, x.way == "AH"
    local rev1, rev2, capK = nil, r.sell ~= nil and mk * r.sell or 0, huge
    if ahWay then
      rev1 = round(mk * x.ahp * (1 - o.cut / 100))
      capK = (x.listed or 0) * capShare(r) / mk
    elseif x.way == "DE" then
      rev1 = x.drev   -- disenchanted: no vendor, no sales cap
    else
      rev1 = mk * r.sell
    end
    local P, known = {}, true
    for i, b in ipairs(B) do
      P[i] = { u = b.u, S = b.S, i = 1, left = b.S.steps[1] and b.S.steps[1][2] or 0 }
      if not b.S.known then known = false end
    end
    local segs, k, total, stop = {}, 0, 0, nil
    local endK, endN = nil, 0   -- with `all`: where the paying crafts ended, and how many segments there were then
    for _ = 1, 200 do
      local cost, out, pr = 0, nil, {}   -- pr: each material's unit price for the next craft
      for _, s in ipairs(P) do
        local step = s.S.steps[s.i]
        local p = step and step[1] or s.S.after
        if p == nil then
          out = s.S.n
          break
        end
        cost = cost + s.u * p
        pr[#pr + 1] = p
      end
      if out then
        if not endK then stop = { why = "out", n = out } end
        break
      end
      local past = k >= capK - 1e-9
      local profit = (past and rev2 or rev1) - cost
      local ph = profit / x.secs * 3600
      if not endK and not (profit > 0 and ph >= floorPH) then
        stop = { why = (past and ahWay) and "cap" or "cost", cost = cost, profit = profit, ph = ph, pr = pr }
        if not all then break end
        endK, endN = k, #segs
      end
      local dk, nx = huge, nil
      for _, s in ipairs(P) do
        if s.S.steps[s.i] then
          local d = s.left / s.u
          if d < dk then dk, nx = d, s.S.n end
        end
      end
      if not past and capK - k < dk then dk, nx = capK - k, "AH" end
      if dk == huge then
        segs[#segs + 1] = { from = k, to = huge, cost = cost, profit = profit, ph = ph, nx = nil, pr = pr, past = endK and true or nil }
        if not endK then k, total = huge, huge end
        break
      end
      segs[#segs + 1] = { from = k, to = k + dk, cost = cost, profit = profit, ph = ph, nx = nx, pr = pr, past = endK and true or nil }
      if not endK then total = total + profit * dk end
      k = k + dk
      for _, s in ipairs(P) do
        if s.S.steps[s.i] then
          s.left = s.left - dk * s.u
          if s.left <= 1e-9 then
            s.i = s.i + 1
            s.left = s.S.steps[s.i] and s.S.steps[s.i][2] or 0
          end
        end
      end
    end
    if endK then k = endK else endN = #segs end
    local worth = k
    if k ~= huge then
      worth = floor(k + 1e-9)
      if endN > 0 then total = total - (k - worth) * segs[endN].profit end
      total = max(0, round(total))
    end
    local mats = {}
    for i, s in ipairs(P) do mats[i] = { n = s.S.n, u = s.u } end
    return { segs = segs, worth = worth, total = total, stop = stop, known = known, mats = mats }
  end
  ctx.worthCurve = worthCurve

  -- The curve under the approach bestInfo uses (kept until prices or the set of recipes change): curve or nil, mode.
  -- It is walked with `all`, so its segments go on past the crafts worth making (past = true).
  function ctx.worthBest(r)
    local _, mode = ctx.bestInfo(r)
    local w = worthCache[r]
    if w == nil then
      w = worthCurve(r, mode, true) or false
      worthCache[r] = w
    end
    return w or nil, mode
  end

  -- May the route use this recipe? One you know always; otherwise a trainer recipe with a confirmed source.
  local function allowed(r)
    if o.exclude[r.id] or ban[r.id] then return false end
    local k = env.known and env.known(r)
    if k then return true end
    if not ((o.items or r.src ~= "R") and (o.guess or not r.guess)) then return false end
    return learnCost(r) ~= nil   -- one that cannot be got at all stays out
  end
  ctx.allowed = allowed

  -- What a route has to learn first and what that costs (only with env.learnCost): every recipe with a price that
  -- a step uses, or that makes a part for a step, once, at the first step that needs it.
  --   route.learn = { list = { {r, cost, from = skill of that step, points = points of the steps needing it}, ... }, total }
  --   route.tot.learn = total, and g.learn = the entries first needed at step g
  local function addLearn(route)
    local list, at, total = {}, {}, 0
    for _, g in ipairs(route.segs) do
      if g.r then
        local inSeg = {}
        local function note(r)
          if inSeg[r] then return end
          inSeg[r] = true
          local e = at[r]
          if e == nil then
            local c = learnCost(r)
            e = false
            if c and c > 0 then
              e = { r = r, cost = c, from = g.from, points = 0 }
              list[#list + 1] = e
              total = total + c
              g.learn = g.learn or {}
              g.learn[#g.learn + 1] = e
            end
            at[r] = e
          end
          if e then e.points = e.points + (g.to - g.from) end
        end
        note(g.r)
        local buy, made = omap(), omap()
        bomOf(g.r, 1, buy, made)
        for _, n in ipairs(made.keys) do
          local pr = makerOf(n)
          if pr then note(pr) end
        end
      end
    end
    route.learn = { list = list, total = total }
    route.tot.learn = total
  end

  -- The route: for every skill point, the craft with the lowest (net cost + time) per expected point.
  -- stock (optional, from ctx.planAhead; the page has no such thing): { { r = part recipe, units = n }, ... },
  -- parts that later steps need anyway. While one of them still gives skill it is made first: its materials and
  -- casts are counted in the steps that use it, so those points cost nothing extra. A step that uses such a part
  -- takes it from what was made ahead (taken) and gets no points for those units; whatever was not made ahead is
  -- made at that step and gives its points there.
  function ctx.plan(prof, from, to, stock)
    local skip, stockList = nil, nil
    if stock and #stock > 0 then
      skip, stockList = {}, {}
      for i, e in ipairs(stock) do
        stockList[i] = { r = e.r, left = e.units, made = 0, taken = 0 }
        skip[e.r] = stockList[i]
      end
    end
    local C = {}
    for _, r in ipairs(db.byProf[prof] or {}) do
      if r.col and info(r).cost ~= nil and allowed(r) then C[#C + 1] = r end
    end
    local steps, used, usedMat, left = {}, {}, {}, {}
    local rate = o.timeValue * 10000 / 3600
    local byTime = o.mode == "time"
    local cur = nil
    -- A recipe that costs something to learn (env.learnCost) carries that price until the route first uses it,
    -- spread over the points it could then go on giving: up to halfway between its yellow and its grey level, or
    -- the end of the range. An estimate that only steers this pass; ctx.planBest then checks every recipe bought
    -- against the route without it. Once used the price is spent and no longer counts against the recipe.
    local bought = env.learnCost and {} or nil
    local function score(r, s)
      if learnOf(r) > s then return nil end
      local c = ptsAt(r, s, skip)
      if c <= 0 then return nil end
      local cc = craftCostAt(r, usedMat)
      local x = info(r)
      local cost = cc and cc.c or x.cost
      local net = netAt(r, used[r] or 0, cost)
      local tm, g = x.secs / c, (net + x.secs * rate) / c
      if bought and not bought[r] then
        local lc = learnCost(r)
        if lc and lc > 0 then g = g + lc / max(1, min(to, (r.y + r.grey) / 2) - s) end
      end
      if byTime then return tm, net / c, net, cost end
      return g, tm, net, cost
    end
    for s = from, to - 1 do
     -- a part for later steps that still gives skill: the one with the best chance, if enough are still needed
     local sp, sc = nil, 0
     if stockList then
       for _, e in ipairs(stockList) do
         local c = chanceAt(e.r, s)
         if c > sc and e.left >= makes(e.r) / c - 1e-9 then sp, sc = e, c end
       end
     end
      local best, bm, bt, bn, bc = nil, huge, huge, 0, 0
      local cm, cmNet, cmCost = nil, nil, nil
      for pass = 0, 1 do
        for _, r in ipairs(C) do
          if not (pass == 0 and left[r]) then
            local m, t, net, cost = score(r, s)
            if m then
              if r == cur then cm, cmNet, cmCost = m, net, cost end
              if m < bm - 1e-9 or (abs(m - bm) < 1e-9 and t < bt) then
                best, bm, bt, bn, bc = r, m, t, net, cost
              end
            end
          end
        end
        if best then break end
      end
      -- stay on the current recipe unless the new pick is clearly better (5%, at least 1c or 0.5s per point)
      if cur and cm and best ~= cur and cm - bm < max(abs(cm) * 0.05, byTime and 0.5 or 1) then
        best, bm, bn, bc = cur, cm, cmNet, cmCost
      end
     -- Parts made ahead are points for nothing, so they go before any craft that costs something. A craft that
     -- pays for itself (sold at a gain) still comes first: the parts can wait, they are needed anyway.
     if sp and (best == nil or bm > 1e-9) then
       local units = makes(sp.r) / sc
       sp.left, sp.made = sp.left - units, sp.made + units
       steps[#steps + 1] = { s = s, r = sp.r, c = sc, tc = sc, net = 0, cost = 0, capped = false, stock = true }
     else
      if cur and best ~= cur then left[cur] = true end
      cur = best
      if bought and best then bought[best] = true end
      local c = best and ptsAt(best, s, skip) or 0
      local capped, ah = false, nil
      if best then
        local x = info(best)
        capped = o.sell and x.way == "AH" and (used[best] or 0) * makes(best) >= (x.listed or 0) * capShare(best)
        used[best] = (used[best] or 0) + 1 / c
        local B = bomSup(best)
        if B then
          for _, b in ipairs(B) do usedMat[b.S.n] = (usedMat[b.S.n] or 0) + b.u / c end
        end
        ah = takeStock(best, c, skip)
      end
      steps[#steps + 1] = { s = s, r = best, c = c, tc = best and chanceAt(best, s) or 0, net = bn, cost = bc, capped = capped, ah = ah }
     end
    end
    -- g.ah: [part recipe] = units of it this step takes from the parts made ahead
    local segs = {}
    for _, x in ipairs(steps) do
      local last = segs[#segs]
      if last and last.r == x.r and last.stock == x.stock then
        last.to = x.s + 1
        last.cs[#last.cs + 1] = x.c
        last.nets[#last.nets + 1] = x.net
        last.costs[#last.costs + 1] = x.cost
        last.capped = last.capped or x.capped
      else
        last = { r = x.r, from = x.s, to = x.s + 1, cs = { x.c }, nets = { x.net }, costs = { x.cost }, capped = x.capped, stock = x.stock }
        segs[#segs + 1] = last
      end
      if x.ah then
        last.ah = last.ah or {}
        for _, t in ipairs(x.ah) do last.ah[t[1]] = (last.ah[t[1]] or 0) + t[2] end
      end
    end
    local tot = { cost = 0, net = 0, crafts = 0, time = 0, gaps = 0, points = to - from }
    for _, g in ipairs(segs) do
      if not g.r then
        tot.gaps = tot.gaps + (g.to - g.from)
      else
        local exp, cost, net = 0, 0, 0
        for k, c in ipairs(g.cs) do
          exp = exp + 1 / c
          cost = cost + g.costs[k] / c
          net = net + g.nets[k] / c
        end
        g.exp = exp
        g.crafts = ceil(exp - 1e-6)
        g.avg = (g.to - g.from) / exp
        g.cost = cost * g.crafts / exp
        g.net = net * g.crafts / exp
        -- parts made ahead cost and take nothing here: both are counted in the steps that use them
        g.time = g.stock and 0 or g.crafts * info(g.r).secs
        tot.cost, tot.net = tot.cost + g.cost, tot.net + g.net
        if not g.stock then tot.crafts = tot.crafts + g.crafts end
        tot.time = tot.time + g.time
      end
    end
    local route = { segs = segs, tot = tot, steps = steps, from = from, to = to, prof = prof, stock = stockList }
    if env.learnCost then addLearn(route) end
    return route
  end

  -- Parts a route makes for its steps that could have given skill before the step that uses them:
  -- a list { { r = part recipe, units = n }, ... } and the same by recipe.
  local function partsToMakeEarly(route)
    local list, need = {}, {}
    for _, g in ipairs(route.segs) do
      if g.r and not g.stock then
        local buy, made = omap(), omap()
        bomOf(g.r, g.crafts, buy, made)
        for _, n in ipairs(made.keys) do
          local pr = makerOf(n)
          if pr and pr.prof == route.prof and pr.col then
            local first = max(route.from, learnOf(pr))   -- the first skill at which it could be made on this route
            if first < g.from and first < pr.grey then
              if not need[pr] then
                need[pr] = { r = pr, units = 0 }
                list[#list + 1] = need[pr]
              end
              need[pr].units = need[pr].units + made.v[n]
            end
          end
        end
      end
    end
    return list, need
  end

  -- The route with parts made ahead (see ctx.plan). Asked for by the owner: a route that needed 42 Solid Grinding
  -- Stones for later steps sent him through 17 Solid Sharpening Stones first, when making the 42 stones at once
  -- gives those ten points for nothing. Planning with parts made ahead changes the route, which changes the parts
  -- it needs, so this goes round a few times and keeps the best route that never makes more ahead than it uses.
  -- The result carries route.need = [part recipe] = units the later steps use.
  -- Routes are compared the way the route itself is built: by cost plus the value of the time, or in "time" mode
  -- by points with no recipe, then seconds, then cost (routeNoWorse). What the route has to learn first
  -- (tot.learn, only with env.learnCost) is part of the cost.
  local function routeNoWorse(a, b)
    local rate = o.timeValue * 10000 / 3600
    local A, B
    if o.mode == "time" then
      A, B = { a.tot.gaps, a.tot.time, a.tot.net + (a.tot.learn or 0) }, { b.tot.gaps, b.tot.time, b.tot.net + (b.tot.learn or 0) }
    else
      A = { a.tot.gaps * 1e12 + a.tot.net + a.tot.time * rate + (a.tot.learn or 0) }
      B = { b.tot.gaps * 1e12 + b.tot.net + b.tot.time * rate + (b.tot.learn or 0) }
    end
    for i = 1, #A do
      if A[i] < B[i] - 1e-9 then return true end
      if A[i] > B[i] + 1e-9 then return false end
    end
    return true
  end
  ctx.routeNoWorse = routeNoWorse

  function ctx.planAhead(prof, from, to)
    local base = ctx.plan(prof, from, to)
    local best = base
    local stock = partsToMakeEarly(base)
    for _ = 1, 4 do
      if #stock == 0 then break end
      local route = ctx.plan(prof, from, to, stock)
      local list, need = partsToMakeEarly(route)
      local ok, same = true, #list == #route.stock
      for _, e in ipairs(route.stock) do
        local n = need[e.r] and need[e.r].units or 0
        if e.made > n + 1e-6 then ok = false end                 -- made more ahead than the route goes on to use
        if abs(e.made + e.left - n) > 1e-6 then same = false end   -- the parts needed changed: plan once more
      end
      if ok and routeNoWorse(route, best) then
        route.need = {}
        for pr, e in pairs(need) do route.need[pr] = e.units end
        best = route
      end
      if ok and same then break end
      stock = list
    end
    return best
  end

  -- The route to show: parts made ahead (planAhead), and with env.learnCost a recipe that costs something to learn
  -- is used only when the whole route is better with it bought than without it. Without env.learnCost this is
  -- planAhead and nothing else.
  --   1. Plan with every recipe that can be got. Each paid recipe weighs on the choice until it is first used
  --      (score, in ctx.plan).
  --   2. Take the recipes that route pays for, dearest per point of the steps needing them first, and plan again
  --      without one of them (the two dearest are tried). If that route is better by the route measure
  --      (routeNoWorse: points with no step, then materials less sales + learning + the value of the time; in
  --      "time" mode points with no step, seconds, then cost), the recipe stays out; repeat, at most 8 plans.
  --   3. Plan the route that learns nothing that costs anything (every paid recipe out), and the route of step 2,
  --      both with parts made ahead. The second is kept only when it is better than the first.
  -- So the route kept is never worse, by that measure and with learning counted, than learning nothing paid.
  -- It is not proved to be the best set of recipes: steps 1 and 2 are a search, not every combination.
  --   route.ban      [recipe id] = true: paid recipes left out (the context is left set to it, so shopping lists
  --                  and part choices match the route)
  --   route.without  the totals of the route that learns nothing paid
  function ctx.planBest(prof, from, to)
    if not env.learnCost then return ctx.planAhead(prof, from, to) end
    local all, any = {}, false
    for _, r in ipairs(db.recipes) do
      local c = learnCost(r)
      if c and c > 0 then all[r.id], any = true, true end
    end
    local function run(b, fn)
      setBan(b)
      local route = fn(prof, from, to)
      route.ban = b
      return route
    end
    if not any then return run({}, ctx.planAhead) end
    local cur, tries = run({}, ctx.plan), 0
    while tries < 8 and #cur.learn.list > 0 do
      local cands = {}
      for i, e in ipairs(cur.learn.list) do cands[i] = e end
      table.sort(cands, function(x, y)
        local rx, ry = x.cost / max(1, x.points), y.cost / max(1, y.points)
        if rx ~= ry then return rx > ry end
        return x.r.i < y.r.i
      end)
      local better = nil
      for i = 1, min(2, #cands) do
        local b2 = {}
        for id in pairs(cur.ban) do b2[id] = true end
        b2[cands[i].r.id] = true
        local alt = run(b2, ctx.plan)
        tries = tries + 1
        if not routeNoWorse(cur, alt) then
          better = alt
          break
        end
      end
      if not better then break end
      cur = better
    end
    local best = run(all, ctx.planAhead)
    local without = best.tot
    if #cur.learn.list > 0 then
      local alt = run(cur.ban, ctx.planAhead)
      if not routeNoWorse(best, alt) then best = alt end
    end
    setBan(best.ban)
    best.without = without
    return best
  end

  -- What to buy and what to make for a list of route segments, priced by walking each item's ladder over the
  -- whole quantity. buy = { {item, qty, cost, short, how}, ... }, made = { {item, qty}, ... },
  -- have = { {item, qty, part}, ... } = what the steps use of materials set to "have it" (not bought, not priced)
  -- A step of parts made ahead is left out (its materials are in the steps that use the parts) unless withStock.
  function ctx.shopping(segs, withStock)
    local buy, made = omap(), omap()
    for _, g in ipairs(segs) do
      if g.r and (withStock or not g.stock) then bomOf(g.r, g.crafts, buy, made) end
    end
    local out = { buy = {}, made = {}, have = {}, cost = 0 }
    for _, n in ipairs(buy.have and buy.have.keys or {}) do
      out.have[#out.have + 1] = { item = n, qty = buy.have.v[n], part = not isRaw(n) }
    end
    for _, n in ipairs(buy.keys) do
      local Q = buy.v[n]
      local S = supplyOf(n, statOf(n))
      local row = { item = n, qty = Q, how = (#S.steps > 0) and "AH" or (isRaw(n) and matCost(n).how or "AH"), part = not isRaw(n) }
      if #S.steps > 0 or S.after ~= nil then
        local x = E.supCost(S, 0, Q)
        row.cost, row.short = x.cost, x.short
        out.cost = out.cost + x.cost
      end
      local L = lad(n)
      row.listed = L and L.total or nil
      row.day = L and L.day or nil
      out.buy[#out.buy + 1] = row
    end
    for _, n in ipairs(made.keys) do
      out.made[#out.made + 1] = { item = n, qty = made.v[n], r = makerOf(n) }
    end
    return out
  end

  return ctx
end

-- Item ids worth scanning for one profession, in a stable order: everything its recipes buy (parts opened up
-- into their own materials too), then what they make.
--   skill    only recipes that still give points at this skill or later (grey above it); nil = every recipe
--   to       only recipes that can be learned by this skill
--   use      function(recipe) -> false to leave a recipe out (one the character cannot get, say)
--   outputs  "none", "nongear" (things likely to sell) or "all"
--   patterns also the recipe items (Plans, Patterns, ...) that teach its recipes: true, or function(recipe) ->
--            false to leave one out (a recipe already known)
function E.scanItems(db, prof, want)
  want = want or {}
  local ids, seen = {}, {}
  local function add(id)
    if id and id > 0 and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  local function open(item, depth)
    add(item)
    local r = db.maker[item]
    local it = db.items[item]
    if r and not (it and it.raw) and depth < 6 then
      for _, reg in ipairs(r.regs) do open(reg[1], depth + 1) end
    end
  end
  local list = {}
  for _, r in ipairs(db.byProf[prof] or {}) do
    if (want.skill == nil or (r.col and r.grey > want.skill)) and (want.to == nil or r.learn <= want.to)
        and (want.use == nil or want.use(r)) then
      list[#list + 1] = r
    end
  end
  for _, r in ipairs(list) do
    for _, reg in ipairs(r.regs) do open(reg[1], 0) end
  end
  local outputs = want.outputs or "nongear"
  if outputs ~= "none" then
    for _, r in ipairs(list) do
      if outputs == "all" or not r.gear then add(r.made) end
    end
  end
  if want.patterns then
    for _, r in ipairs(list) do
      if want.patterns == true or want.patterns(r) then add(r.pat) end
    end
  end
  return ids
end

-- Every item id any recipe of any profession uses, makes or is taught by, each once, the useful part first:
-- materials, then parts (reagents some recipe makes), then every other product (gear included), then recipe
-- items. Also returns how many of each: { mats, parts, products, patterns }.
function E.allItems(db)
  local ids, seen = {}, {}
  local function add(id)
    if id and id > 0 and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  local n = {}
  for pass = 1, 2 do
    for _, r in ipairs(db.recipes) do
      for _, reg in ipairs(r.regs) do
        local it = db.items[reg[1]]
        local raw = ((it and it.raw) or db.maker[reg[1]] == nil) and true or false
        if raw == (pass == 1) then add(reg[1]) end
      end
    end
    if pass == 1 then n.mats = #ids else n.parts = #ids - n.mats end
  end
  for _, r in ipairs(db.recipes) do add(r.made) end
  n.products = #ids - n.mats - n.parts
  for _, r in ipairs(db.recipes) do add(r.pat) end
  n.patterns = #ids - n.mats - n.parts - n.products
  return ids, n
end

-- Item ids a route touches: what it buys, the parts it makes, and what its crafts produce.
function E.routeItems(ctx, segs)
  local ids, seen = {}, {}
  local function add(id)
    if id and id > 0 and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  local shop = ctx.shopping(segs)
  for _, row in ipairs(shop.buy) do add(row.item) end
  for _, row in ipairs(shop.made) do add(row.item) end
  for _, g in ipairs(segs) do
    if g.r then add(g.r.made) end
  end
  return ids
end
