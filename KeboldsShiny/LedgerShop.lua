-- Kebold's Shiny: the Shopping list (the model and its lines, then the Shopping page that shows them)
-- One list of things to buy, added to from anywhere: N crafts of a recipe, a step of the leveling route, a whole
-- route, the favourites, or a plain item. Everything on it is merged: an item two entries need is one line, and
-- its price is walked over the COMBINED quantity, so the second entry pays the dearer listings. What is in the
-- bags (bank included, as on the Route tab) is taken off, parts you make yourself are opened up into their
-- materials, "Have it" materials cost nothing, and a line can be ticked off. It is saved with the other choices
-- (KeboldsShinyDB.ledger.shop), so it survives a reload. It only shows and counts: it never buys anything.
--
-- Saved (plain tables, numbers and strings only):
--   S.shop = {
--     entries = {                                             -- in the order they were added
--       { kind = "recipe", prof = "Blacksmithing", id = <spell id>, n = <crafts> },
--       { kind = "step",   prof = , id = <spell id>, n = <crafts>, from = , to = },   -- a route step as it was planned
--       { kind = "route",  prof = , from = , to = },          -- a whole route, read again from the plan when shown
--       { kind = "favs",   n = <crafts of each favourite> },  -- the favourites as they are when shown
--       { kind = "item",   id = <item id>, n = <units> },
--     },
--     done = { [item id] = true },                            -- lines ticked off
--   }
--
-- Decisions:
-- * A "route" entry is LIVE: it keeps the profession and the range it was added with, and every time the list is
--   shown the route is the plan of that moment (prices, recipes known, settings), from the character's skill when
--   that is past the entry's start. So the list shrinks as you level and follows a new scan; a frozen copy would
--   keep asking for the materials of steps already done. Once the skill reaches the entry's end it needs nothing.
-- * A "step" entry is FROZEN: the recipe and the crafts of the step as planned when it was added (that is what
--   "buy for this step" means; the route may move on, the step you chose to shop for does not).
-- * "favs" is live too (n crafts of every favourite at the time); shopAdd({ kind = "favs", n = , split = true })
--   adds each favourite as its own recipe entry instead, so they can be given different quantities.
-- * Parts are made in whole crafts: 5 parts from a recipe that makes 2 is 3 crafts and the materials of 3. The
--   route's own lists count fractions of a craft, so this list can be a little dearer than the route's total.
-- * Parts in the bags are used first: only the rest is made, and only the rest's materials are bought.
-- * Units that are not listed are not priced: a short line's cost is what the listed units cost, and it is flagged.
-- * An item both a vendor and the auction house sell: the listings cheaper than the vendor are bought first, the
--   rest at the vendor, without limit ("pay up to" is then the vendor's price).
--
-- Lines (NS.shopRows): the addon's row shape { left, c1, c2, right, item, recipe, tip, action(button), section }
-- plus these fields:
--   shopSection  "wants" | "buy" | "make" | "have" | "total" | "empty": which block the line belongs to
--   shopHead     true on a block's head line (it also carries `section`, so NS.fold can fold the block)
--   shopEntry    index of the entry (a "wants" line): for NS.shopRemove / NS.shopSetQty
--   shopQty      the entry's quantity when it can be typed (nil for a route)
--   shopItem     the item id of a buy / make / have line: for NS.shopTick
--   shopLine     the line's record from NS.shopList() (numbers, not text)
--   tick         true / false on buy and make lines: ticked off or not (nil elsewhere); `dim` = true when ticked
--   cells        the same line as separate cells, for a table: buy { name, to buy, in bags, pay up to, cost },
--                make { name, to make, in bags, crafts, "" }, wants { name, kind, "", "", quantity }
--   shopMenu     menu entries of the line's own choices ({ text, func, check, checked, ... } as UI.menu takes);
--                NS.rowMenu (Ledger.lua) puts them above the usual ones
--   cols         buy / make / have lines: the eight cells of the page's table, in its columns' order
--                { "" (the tick box is drawn), name and flags, to buy, in bags, pay up to, cost, where, "" (Search) }
--   shopName, shopNote   a "wants" line's name (coloured) and its note, for the page's entry line
--   icon         a route entry's profession icon
--   wide         on the heads of buy / make / have: one text across the table (c1, c2, right are for chat)
--   empty        on the lines of an empty list: the page shows them as an empty state (the first carries
--                { icon, title, text, button, onClick })
--   haveItem / pickItem / menu   as on the Route tab: the usual "Get it by" choices in the right-click menu
-- Left click: a buy or make line ticks it off (again: back on the list); a "wants" line opens its recipe's
-- details (the window's usual click); heads fold. Shift-click links. Everything else is in the right-click menu.
--
--   /keboldshop                      the list in chat
--   /keboldshop add recipe <spell id> [n]   /keboldshop add item <item id> [n]
--   /keboldshop add route [bs|lw|...]       /keboldshop add favs [n]
--   /keboldshop qty <line> <n>       /keboldshop remove <line>       /keboldshop clear
--   /keboldshop tick <item id>       /keboldshop untick <item id>

local NS = KeboldsShinyNS
if type(NS) ~= "table" then return end
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local MAX_QTY = 100000

local rev = 0            -- goes up with every change to the list
local sortKey, sortDesc = nil, false   -- how the Buy and Make lines are ordered (nil: as they were first needed)
local cache = nil        -- the last NS.shopList() and what it was made for
local routeCache = {}    -- [plan signature] = the route planned for a "route" entry

local function colour(k, fallback) return NS[k] or fallback end
local function DIM() return colour("DIM", "|cff909090") end
local function RED() return colour("RED", "|cffff5050") end
local function GOLD() return colour("GOLD", "|cffffd100") end
local function GREEN() return colour("GREEN", "|cff40d040") end

local function plain(s)
  local UI = KeboldsShinyUI
  if type(UI) == "table" and type(UI.plainText) == "function" then return UI.plainText(s) end
  return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function whole(v)
  v = tonumber(v)
  if not v or v ~= v then return nil end
  return max(1, min(MAX_QTY, floor(v + 0.5)))
end

-- ---- saved state ---------------------------------------------------------------------------------------------

local function store()
  local S = NS.settings()
  if type(S.shop) ~= "table" then S.shop = {} end
  local sh = S.shop
  if type(sh.entries) ~= "table" then sh.entries = {} end
  if type(sh.done) ~= "table" then sh.done = {} end
  for i = #sh.entries, 1, -1 do   -- a saved file edited by hand, or an older shape: drop what cannot be read
    local e = sh.entries[i]
    if type(e) ~= "table" or type(e.kind) ~= "string" then table.remove(sh.entries, i) end
  end
  return sh
end

local function changed()
  rev = rev + 1
  cache = nil
  local f = type(NS.frame) == "function" and NS.frame() or nil
  if type(f) == "table" and type(f.IsShown) == "function" and f:IsShown() and type(NS.refresh) == "function" then
    pcall(NS.refresh)
  end
end

function NS.shopInvalidate()   -- something the list depends on changed that it cannot see by itself
  cache = nil
end

function NS.shopEntries()
  return store().entries
end

-- Adds a want. Returns the entry's index, or nil and why not.
--   { kind = "recipe", id = <spell id>, n = }            (prof is filled in)
--   { kind = "step", id = <spell id>, n = , from = , to = }
--   { kind = "route", prof = , from = , to = }           (prof: the one on screen; range: the plan's, when left out)
--   { kind = "favs", n = , split = true | nil }
--   { kind = "item", id = <item id>, n = }
-- The same recipe, step or item again adds to its quantity; a route of the same profession replaces the earlier one.
function NS.shopAdd(e)
  if type(e) ~= "table" then return nil, "nothing to add" end
  local sh, db = store(), NS.data()
  local list = sh.entries
  local n = whole(e.n or 1)
  if e.kind == "recipe" or e.kind == "step" then
    local r = db.byId[tonumber(e.id) or 0]
    if not r then return nil, "no recipe with the id " .. tostring(e.id) end
    if not n then return nil, "the quantity is not a number" end
    local from, to = tonumber(e.from), tonumber(e.to)
    for i, x in ipairs(list) do
      if x.kind == e.kind and x.id == r.id and (e.kind == "recipe" or (x.from == from and x.to == to)) then
        x.n = whole((x.n or 0) + n)
        changed()
        return i
      end
    end
    -- stock = true: a route step of parts made ahead for later steps (see build)
    list[#list + 1] = { kind = e.kind, prof = r.prof, id = r.id, n = n, from = e.kind == "step" and from or nil, to = e.kind == "step" and to or nil,
      stock = (e.kind == "step" and e.stock) and true or nil }
  elseif e.kind == "route" then
    local c = NS.state(e.prof)
    if not c then return nil, "no profession to plan" end
    local from, to = tonumber(e.from) or c.from, tonumber(e.to) or c.to
    if not (from and to and to > from) then return nil, "the route has no range" end
    local new = { kind = "route", prof = c.prof, from = from, to = to }
    for i, x in ipairs(list) do
      if x.kind == "route" and x.prof == c.prof then
        list[i] = new
        changed()
        return i
      end
    end
    list[#list + 1] = new
  elseif e.kind == "favs" then
    if not n then return nil, "the quantity is not a number" end
    if e.split then   -- each favourite as its own recipe entry
      local S, last = NS.settings(), nil
      for _, r in ipairs(db.recipes) do
        if S.fav[r.id] then last = NS.shopAdd({ kind = "recipe", id = r.id, n = n }) end
      end
      if not last then return nil, "no favourites yet" end
      return last
    end
    for i, x in ipairs(list) do
      if x.kind == "favs" then
        x.n = n
        changed()
        return i
      end
    end
    list[#list + 1] = { kind = "favs", n = n }
  elseif e.kind == "item" then
    local id = tonumber(e.id)
    if not id or id <= 0 then return nil, "no item id" end
    if not n then return nil, "the quantity is not a number" end
    for i, x in ipairs(list) do
      if x.kind == "item" and x.id == id then
        x.n = whole((x.n or 0) + n)
        changed()
        return i
      end
    end
    list[#list + 1] = { kind = "item", id = id, n = n }
  else
    return nil, "unknown kind " .. tostring(e.kind)
  end
  changed()
  return #list
end

function NS.shopRemove(index)
  local list = store().entries
  if not list[index] then return false end
  table.remove(list, index)
  if #list == 0 then store().done = {} end   -- an empty list keeps no ticks
  changed()
  return true
end

-- A typed quantity: crafts (recipe, step, favourites) or units (item). A route has none. 0 or less removes the entry.
function NS.shopSetQty(index, n)
  local e = store().entries[index]
  if not e or e.kind == "route" then return false end
  n = tonumber(n)
  if not n or n ~= n then return false end
  if n < 0.5 then return NS.shopRemove(index) end
  e.n = whole(n)
  changed()
  return true
end

function NS.shopClear()
  local sh = store()
  sh.entries, sh.done = {}, {}
  changed()
end

function NS.shopTick(itemID, on)
  itemID = tonumber(itemID)
  if not itemID then return false end
  store().done[itemID] = on and true or nil
  changed()
  return true
end

-- ---- the merged list -----------------------------------------------------------------------------------------

-- Buying `qty` units of a supply (Engine: steps cheapest first, then `after` = a vendor's price, or nil when
-- nothing more is listed): the cost, the dearest unit price that quantity still needs, how many come from the
-- listings and how many from the vendor, and how many are not listed at all (those are not priced).
local function walk(S, qty)
  local out = { cost = 0, top = nil, ah = 0, vend = 0, short = 0, vendCost = 0 }
  local got = 0
  for _, st in ipairs(S.steps) do
    if got >= qty then break end
    local take = min(st[2], qty - got)
    if take > 0 then
      out.cost = out.cost + take * st[1]
      out.top = st[1]
      got = got + take
    end
  end
  out.ah = got
  local rest = qty - got
  if rest > 1e-9 then
    if S.after ~= nil then
      out.vend, out.vendCost, out.top = rest, rest * S.after, S.after
      out.cost = out.cost + out.vendCost
    else
      out.short = rest
    end
  end
  return out
end
NS.shopWalk = walk   -- for tests

-- The route a "route" entry stands for right now: segs, the range really planned, and the context it was planned
-- in. The Route tab's own route is used when it is the same plan; otherwise it is planned here and kept until
-- the plan's signature changes.
local function routeOf(e)
  local st = NS.profState(e.prof)
  local from, to = e.from, e.to
  if st.skill and st.skill > from then from = st.skill end
  if from >= to then return { done = true, from = from, to = to } end
  local c = NS.state(e.prof)
  local sig = NS.sigOf(e.prof, st, from, to)
  local cur = type(NS.current) == "function" and NS.current() or nil
  if cur and cur.route and cur.prof == e.prof and cur.from == from and cur.to == to and cur.sig == sig and cur.ctx == c.ctx then
    return { route = cur.route, from = from, to = to, ctx = c.ctx }
  end
  local kept = routeCache[e.prof]
  if not (kept and kept.sig == sig and kept.ctx == c.ctx) then
    local ok, route = pcall(c.ctx.planBest, e.prof, from, to)
    if not ok or type(route) ~= "table" then return { problem = "the route could not be planned", from = from, to = to } end
    kept = { sig = sig, ctx = c.ctx, route = route }
    routeCache[e.prof] = kept
    -- planBest leaves the shared context set to the paid recipes ITS route declined. When this is not the range
    -- on the Route tab, that would change how the Route tab's parts read: put the Route tab's own set back at the
    -- end (see `restore` in build).
    kept.foreign = not (c.from == from and c.to == to)
  end
  return { route = kept.route, from = from, to = to, ctx = c.ctx, foreign = kept.foreign }
end

local function build()
  local sh, db, S = store(), NS.data(), NS.settings()
  local need, order = {}, {}   -- [item] = record, and the items in the order they were first needed
  local wants = {}             -- one per entry: { index, entry, kind, label, n, problem, recipe, item, done }
  local restore = {}           -- contexts whose set of declined recipes has to be put back: { ctx, ban }

  local function addNeed(item, qty, ctx, by)
    local rec = need[item]
    if not rec then
      rec = { item = item, need = 0, ctx = ctx, by = {}, entries = {}, crafts = 0 }
      need[item] = rec
      order[#order + 1] = item
    end
    rec.need = rec.need + qty
    for _, i in ipairs(by) do
      if not rec.by[i] then
        rec.by[i] = true
        rec.entries[#rec.entries + 1] = i
      end
    end
  end
  local function addCrafts(r, n, ctx, by)
    for _, reg in ipairs(r.regs) do addNeed(reg[1], reg[2] * n, ctx, by) end
  end
  -- Parts made ahead (a route step marked stock): the step makes `units` of an item that later steps use. Its
  -- materials are counted ONCE: the item is needed in at least that quantity, and the steps that use it draw on
  -- the same units instead of adding their own. So the item's need is the larger of "made ahead" and "used", its
  -- crafts follow from that, and the materials come from those crafts alone.
  local function addStock(item, units, ctx, by)
    addNeed(item, 0, ctx, by)
    need[item].stock = (need[item].stock or 0) + units
  end
  local function needOf(rec)
    return max(rec.need, rec.stock or 0)
  end
  local function ctxOf(prof)
    local c = NS.state(prof)
    return c and c.ctx or nil
  end

  for i, e in ipairs(sh.entries) do
    local w = { index = i, entry = e, kind = e.kind, n = e.n }
    wants[i] = w
    if e.kind == "recipe" or e.kind == "step" then
      local r = db.byId[e.id or 0]
      if not r then
        w.label, w.problem = "recipe " .. tostring(e.id), "not in Kebold's data any more"
      else
        w.recipe, w.item = r.id, r.made > 0 and r.made or nil
        w.label = r.name .. (e.kind == "step" and e.from and e.to and ("  (step " .. e.from .. "-" .. e.to .. ")") or "")
        local ctx = ctxOf(r.prof)
        if e.kind == "step" and e.stock and r.made > 0 and ctx then
          w.stock = true
          addStock(r.made, (e.n or 1) * max(1e-9, ctx.makes(r)), ctx, { i })
        else
          addCrafts(r, e.n or 1, ctx, { i })
        end
      end
    elseif e.kind == "route" then
      -- planning this entry's route leaves the shared context set to the paid recipes ITS route declined: the set
      -- in force before is put back at the end, so the Level page's parts read as they did
      local c0 = ctxOf(e.prof)
      local before = (c0 and type(c0.getBan) == "function") and c0.getBan() or nil
      local x = routeOf(e)
      w.from, w.to = x.from, x.to
      w.label = tostring(e.prof) .. " route " .. x.from .. " to " .. e.to
      if x.done then
        w.done = true
      elseif x.problem then
        w.problem = x.problem
      else
        if x.foreign then x.ctx.setBan(x.route.ban or {}) end
        if before and x.ctx == c0 then restore[#restore + 1] = { ctx = c0, ban = before } end
        local crafts, gaps = 0, 0
        for _, g in ipairs(x.route.segs) do
          if g.r and not g.stock then   -- a step of parts made ahead buys nothing itself: the steps that use the parts do
            addCrafts(g.r, g.crafts, x.ctx, { i })
            crafts = crafts + g.crafts
          elseif not g.r then
            gaps = gaps + (g.to - g.from)
          end
        end
        w.crafts, w.gaps = crafts, gaps
        if crafts == 0 then w.problem = "no priced steps yet: scan the profession" end
      end
    elseif e.kind == "favs" then
      local k = 0
      for _, r in ipairs(db.recipes) do
        if S.fav[r.id] then
          k = k + 1
          addCrafts(r, e.n or 1, ctxOf(r.prof), { i })
        end
      end
      w.recipes = k
      w.label = "Favourites" .. (k > 0 and ("  (" .. k .. (k == 1 and " recipe)" or " recipes)")) or "")
      if k == 0 then w.problem = "no favourites yet" end
    elseif e.kind == "item" then
      local m = db.maker[e.id]
      w.item, w.label = e.id, NS.itemName(e.id)
      addNeed(e.id, e.n or 1, ctxOf(m and m.prof or nil), { i })
    else
      w.label, w.problem = tostring(e.kind), "an entry this version does not know"
    end
  end

  -- Open the parts up. A part's crafts follow its total need less what is in the bags, so the pass is repeated
  -- until nothing grows (a part used by two others gets both needs before its materials are final).
  local pass, grew = 0, true
  while grew and pass < 200 do
    grew, pass = false, pass + 1
    local i = 1
    while i <= #order do
      local rec = need[order[i]]
      if not rec.how then
        rec.bags = NS.bagCount(rec.item)
        if S.pick[rec.item] == "have" then
          rec.how = "have"
        else
          local p = rec.ctx and rec.ctx.part(rec.item) or nil
          rec.part = p ~= nil
          if p and p.r and (p.how == "Craft" or rec.stock) then   -- made ahead: the step says make them
            rec.how, rec.r, rec.mk = "make", p.r, max(1e-9, rec.ctx.makes(p.r))
          else
            rec.how = "buy"
          end
        end
      end
      if rec.how == "make" then
        local want = max(0, ceil(needOf(rec) - 1e-9) - rec.bags)
        local crafts = ceil(want / rec.mk - 1e-9)
        if crafts > rec.crafts then
          addCrafts(rec.r, crafts - rec.crafts, rec.ctx, rec.entries)
          rec.crafts = crafts
          grew = true
        end
      end
      i = i + 1
    end
  end

  local out = { wants = wants, buy = {}, make = {}, have = {}, cost = 0, vendorCost = 0, ahCost = 0, left = 0,
    nBuy = 0, nLeft = 0, nShort = 0, nNoPrice = 0, nMake = 0, nMakeLeft = 0 }
  for _, item in ipairs(order) do
    local rec = need[item]
    local units = ceil(needOf(rec) - 1e-9)
    local line = { item = item, need = units, bags = rec.bags or 0, entries = rec.entries, ticked = sh.done[item] == true, part = rec.part or false }
    if rec.how == "have" then
      out.have[#out.have + 1] = line
    elseif rec.how == "make" then
      line.toMake = max(0, units - line.bags)
      line.crafts, line.r, line.makes = rec.crafts, rec.r, rec.mk
      out.make[#out.make + 1] = line
      if line.toMake > 0 then
        out.nMake = out.nMake + 1
        if not line.ticked then out.nMakeLeft = out.nMakeLeft + 1 end
      end
    else
      local ctx = rec.ctx
      line.toBuy = max(0, units - line.bags)
      if ctx then
        local p = ctx.part(item)
        local stat
        if p then stat = p.buy else stat = ctx.matCost(item).c end
        local sup = ctx.supplyOf(item, stat)
        local L = ctx.ladder(item)
        line.listed, line.day = L and L.total or nil, L and L.day or nil
        line.scanned = L ~= nil
        line.vendor = sup.after   -- a vendor's unit price: any quantity at that price
        if #sup.steps == 0 and sup.after == nil then
          line.noPrice = not line.scanned              -- never looked up
          line.short = line.toBuy                       -- looked up, none listed (or not looked up at all)
        else
          local x = walk(sup, line.toBuy)
          line.cost, line.payUpTo, line.short = x.cost, x.top, x.short
          line.ahUnits, line.vendorUnits, line.vendorCost = x.ah, x.vend, x.vendCost
          if line.payUpTo == nil then   -- nothing left to buy: still say what one would cost
            line.payUpTo = sup.steps[1] and sup.steps[1][1] or sup.after
          end
        end
      else
        line.noPrice, line.short = true, line.toBuy
      end
      line.how = (line.vendorUnits or 0) > 0 and ((line.ahUnits or 0) > 0 and "AH + vendor" or "Vendor") or "AH"
      out.buy[#out.buy + 1] = line
      if line.toBuy > 0 then
        out.nBuy = out.nBuy + 1
        if not line.ticked then out.nLeft = out.nLeft + 1 end
        if line.noPrice then
          out.nNoPrice = out.nNoPrice + 1
        elseif (line.short or 0) > 0 then
          out.nShort = out.nShort + 1
        end
        if line.cost then
          out.cost = out.cost + line.cost
          out.vendorCost = out.vendorCost + (line.vendorCost or 0)
          if not line.ticked then out.left = out.left + line.cost end
        end
      end
    end
  end
  out.ahCost = out.cost - out.vendorCost
  for k = #restore, 1, -1 do pcall(restore[k].ctx.setBan, restore[k].ban) end   -- the first one saved is the set to end with
  return out
end

-- Everything on the list, merged:
--   wants = { { index, entry, kind, label, n, recipe, item, problem, done, crafts, gaps, recipes, from, to }, ... }
--   buy   = { { item, need, bags, toBuy, payUpTo, cost, vendor = a vendor's unit price or nil, vendorUnits, ahUnits,
--               vendorCost, listed, day, scanned, short = units not listed, noPrice = never scanned and no vendor,
--               part = a crafted part that is bought, how = "AH" | "Vendor" | "AH + vendor", entries = { indexes },
--               ticked }, ... }
--   make  = { { item, need, bags, toMake, crafts, r = its recipe, makes, entries, ticked }, ... }
--   have  = { { item, need, bags, entries }, ... }            materials set to "Have it": not bought, not priced
--   cost (everything still to buy, ticked lines too), vendorCost, ahCost, left (lines not ticked),
--   nBuy / nLeft (lines with something to buy / of those not ticked), nShort, nNoPrice, nMake, nMakeLeft
-- Kept for the frame: several callers in one frame share one list.
function NS.shopList()
  local now = (type(GetTime) == "function" and GetTime()) or 0
  local version = type(NS.version) == "function" and NS.version() or 0
  if cache and cache.at == now and cache.version == version and cache.rev == rev then return cache.list end
  local list = build()
  cache = { at = now, version = version, rev = rev, list = list }
  return list
end

-- Item ids whose prices the list rests on: what it buys first, then the parts it makes (their price decides
-- make or buy) and everything those parts and the listed recipes could use, all the way down.
function NS.shopScanIDs()
  local list, db, S = NS.shopList(), NS.data(), NS.settings()
  local ids, seen = {}, {}
  local function add(id)
    if type(id) == "number" and id > 0 and not seen[id] and S.pick[id] ~= "have" then
      seen[id] = true
      ids[#ids + 1] = id
      return true
    end
    return false
  end
  local function open(r, depth)
    for _, reg in ipairs(r.regs) do
      if add(reg[1]) and depth < 8 then
        local m = db.maker[reg[1]]
        if m and m ~= r then open(m, depth + 1) end
      end
    end
  end
  for _, b in ipairs(list.buy) do add(b.item) end
  for _, m in ipairs(list.make) do add(m.item) end
  for _, b in ipairs(list.buy) do   -- a part that is bought today: its materials say whether making it got cheaper
    local m = db.maker[b.item]
    if m and b.part then open(m, 0) end
  end
  for _, m in ipairs(list.make) do
    if m.r then open(m.r, 0) end
  end
  for _, w in ipairs(list.wants) do
    local r = w.recipe and db.byId[w.recipe] or nil
    if r then open(r, 0) end
  end
  return ids
end

-- For a badge or a status line: { entries, items = lines with something to buy, left = of those not ticked,
-- make, short, noPrice, cost, leftCost, vendorCost, text }
function NS.shopSummary()
  local list = NS.shopList()
  local s = { entries = #list.wants, items = list.nBuy, left = list.nLeft, make = list.nMake, short = list.nShort,
    noPrice = list.nNoPrice, cost = list.cost, leftCost = list.left, vendorCost = list.vendorCost }
  if s.entries == 0 then
    s.text = "Shopping list empty"
  elseif s.left == 0 then
    s.text = s.items == 0 and "Nothing left to buy" or "Everything ticked off"
  else
    s.text = s.left .. (s.left == 1 and " item" or " items") .. " to buy, " .. NS.money(s.leftCost)
      .. ((s.short + s.noPrice) > 0 and (", " .. (s.short + s.noPrice) .. " not fully priced") or "")
  end
  return s
end

-- One line for the window's footer: how much is left to buy and how good the prices behind it are.
function NS.shopStatus()
  local list = NS.shopList()
  local s = NS.shopSummary()
  if s.entries == 0 then return DIM() .. "Shopping list: empty|r" end
  local oldest, unscanned = nil, 0
  for _, b in ipairs(list.buy) do
    if b.toBuy > 0 and not b.ticked then
      if b.day then
        if not oldest or b.day < oldest then oldest = b.day end
      elseif not b.vendor then
        unscanned = unscanned + 1
      end
    end
  end
  local text = "Shopping list: " .. s.text:sub(1, 1):lower() .. s.text:sub(2)
  if oldest then
    local today = floor((((type(time) == "function" and time()) or 0) - (NS.DAY_ZERO or 0)) / 86400)
    local age = max(0, today - oldest)
    text = text .. ", oldest price " .. (age == 0 and "today" or (age == 1 and "yesterday" or (age .. " days ago")))
  end
  if s.make > 0 then text = text .. ", " .. s.make .. (s.make == 1 and " part to make" or " parts to make") end
  local bad = unscanned > 0 or (s.short + s.noPrice) > 0
  return (bad and RED() or DIM()) .. text .. "|r"
end

-- ---- lines for the screen ------------------------------------------------------------------------------------

local KIND_WORD = { recipe = "crafts", step = "route step", route = "whole route", favs = "of each", item = "units" }

local function age(day)
  if not day or not NS.DAY_ZERO or type(time) ~= "function" then return nil end
  local d = max(0, floor((time() - NS.DAY_ZERO) / 86400) - day)
  return d == 0 and "today" or (d == 1 and "yesterday" or (d .. " days ago"))
end

local function names(list, idx)
  local t = {}
  for _, i in ipairs(idx) do
    local w = list.wants[i]
    if w then t[#t + 1] = plain(w.label) end
  end
  return table.concat(t, ", ")
end

local function tickAction(row)
  return function()
    if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() and type(NS.linkRow) == "function" then
      NS.linkRow(row)
      return
    end
    NS.shopTick(row.shopItem, not row.tick)
  end
end

-- The order of the Buy and Make lines: a column's key of the page's table (name, tobuy, bags, upto, cost, where) or
-- nil for the order things were first needed in. Ticked lines stay last and covered ones after the open ones.
function NS.shopSort(key, desc)
  sortKey, sortDesc = key, desc and true or false
end
function NS.shopSorted() return sortKey, sortDesc end

local BUY_VALUE = {
  name = function(b) return string.lower(NS.itemName(b.item) or "") end,
  tobuy = function(b) return b.toBuy or 0 end,
  bags = function(b) return b.bags or 0 end,
  upto = function(b) return b.payUpTo or -1 end,
  cost = function(b) return b.cost or -1 end,
  where = function(b) return b.how or "" end,
}
local MAKE_VALUE = {
  name = BUY_VALUE.name,
  tobuy = function(m) return m.toMake or 0 end,
  bags = BUY_VALUE.bags,
  cost = function(m) return m.crafts or 0 end,
}
local function sortLines(list, values)
  local value = sortKey and values[sortKey] or nil
  if not value or #list < 2 then return end
  local at, val = {}, {}
  for i, x in ipairs(list) do at[x], val[x] = i, value(x) end
  table.sort(list, function(a, b)
    local va, vb = val[a], val[b]
    if va ~= vb then
      if sortDesc then return va > vb end
      return va < vb
    end
    return at[a] < at[b]
  end)
end

function NS.shopFavCount()
  local n = 0
  for _ in pairs(NS.settings().fav or {}) do n = n + 1 end
  return n
end

function NS.shopRows()
  local list = NS.shopList()
  local money, itemText = NS.money, NS.itemText
  local dim, red, gold, green = DIM(), RED(), GOLD(), GREEN()
  local out = {}
  if #list.wants == 0 then
    local favs = NS.shopFavCount()
    out[#out + 1] = { left = gold .. "Your shopping list is empty.|r", shopSection = "empty",
      empty = { icon = "Interface\\Icons\\INV_Misc_Bag_08", title = "Your shopping list is empty",
        text = "Add a step or the whole route on the Level page, any number of crafts of a recipe on the Craft page, or your favourites. What is in your bags and bank is taken off, and every line says what price to pay up to.",
        button = favs > 0 and ("Add favourites (" .. favs .. ")") or nil,
        onClick = favs > 0 and function() NS.shopAdd({ kind = "favs", n = 1 }) end or nil } }
    out[#out + 1] = { left = dim .. "Add to it from a route step or a whole route, from a recipe's details (any number of crafts),|r", shopSection = "empty", empty = true }
    out[#out + 1] = { left = dim .. "from your favourites, or type /keboldshop add recipe <spell id> <how many>.|r", shopSection = "empty", empty = true }
    out[#out + 1] = { left = dim .. "What is in your bags and bank is taken off, and every line says what price to pay up to.|r", shopSection = "empty", empty = true }
    return out
  end

  -- what you are shopping for
  out[#out + 1] = { left = gold .. "What you are shopping for|r  " .. dim .. #list.wants .. (#list.wants == 1 and " entry" or " entries") .. ", right-click one to change or remove it|r",
    right = dim .. "quantity|r", shopSection = "wants", shopHead = true }
  for _, w in ipairs(list.wants) do
    local i, e = w.index, w.entry
    local qty = e.kind ~= "route" and (e.n or 1) or nil
    local note = w.problem and (red .. "  " .. w.problem .. "|r") or (w.done and (green .. "  done: your skill is past it|r") or "")
    if e.kind == "route" and not w.problem and not w.done then
      note = dim .. "  " .. (w.crafts or 0) .. " crafts as planned now" .. ((w.gaps or 0) > 0 and (", " .. w.gaps .. " points without a recipe") or "") .. "|r"
    end
    local menu = {}
    if qty then
      for _, d in ipairs({ 1, 5, -1, -5 }) do
        if qty + d >= 1 then
          menu[#menu + 1] = { text = (d > 0 and "+" or "") .. d .. "  (" .. (qty + d) .. ")", func = function() NS.shopSetQty(i, qty + d) end }
        end
      end
    end
    menu[#menu + 1] = { text = "Remove from the shopping list", func = function() NS.shopRemove(i) end }
    local tip = { e.kind == "route" and "The whole route as it is planned right now, from your skill on: it follows new prices and shrinks as you level."
      or (e.kind == "step" and (e.stock and "Parts made ahead for later steps, as planned when you added it. Steps on the list that use these parts draw on them: the materials are counted once."
        or "A route step as it was planned when you added it.")
      or (e.kind == "favs" and "Every favourite recipe, this many crafts of each." or (e.kind == "item" and "This many of one item." or "This many crafts of one recipe."))),
      gold .. "Right-click|r to change the quantity or remove it." }
    local shown = w.item and e.kind ~= "favs" and itemText(w.item, w.label) or w.label
    local icon = nil
    if e.kind == "route" and type(NS.profIcon) == "function" then
      local okI, tex = pcall(NS.profIcon, e.prof)
      icon = okI and tex or nil
    end
    out[#out + 1] = { left = "   " .. (qty and (qty .. "x ") or "") .. shown .. note, shopName = shown, shopNote = note, icon = icon,
      c1 = dim .. (KIND_WORD[e.kind] or "") .. "|r", right = qty and tostring(qty) or (dim .. "-|r"),
      item = w.item, recipe = w.recipe, shopSection = "wants", shopEntry = i, shopQty = qty, shopLine = w, shopMenu = menu, menu = true, tip = tip,
      cells = { w.label, KIND_WORD[e.kind] or "", "", "", qty and tostring(qty) or "" } }
  end

  -- buy: lines with something left first, then the ones the bags cover, then the ticked ones
  local active, covered, ticked = {}, {}, {}
  for _, b in ipairs(list.buy) do
    if b.ticked then ticked[#ticked + 1] = b elseif b.toBuy > 0 then active[#active + 1] = b else covered[#covered + 1] = b end
  end
  if #list.buy > 0 then
    out[#out + 1] = { left = "" }
    out[#out + 1] = { left = gold .. "Buy|r  " .. dim .. list.nLeft .. " of " .. list.nBuy .. " left, click a line when you have bought it|r",
      c1 = dim .. "pay up to|r", c2 = gold .. money(list.left) .. "|r", right = dim .. "where|r", section = "shopbuy", shopSection = "buy", shopHead = true, wide = true,
      cells = { "Item", "To buy", "In bags", "Pay up to", "Cost" } }
    local function buyRow(b)
      local name = itemText(b.item)
      local left = "   " .. b.toBuy .. "x " .. name
      if b.bags > 0 then left = left .. dim .. "  have " .. b.bags .. " of " .. b.need .. (b.toBuy == 0 and ", enough" or "") .. "|r" end
      local flag = ""
      if b.toBuy > 0 then
        if b.noPrice then
          flag = red .. "  no price: scan it|r"
        elseif (b.short or 0) > 0 then
          flag = red .. "  only " .. (b.toBuy - b.short) .. " listed|r"
        end
      end
      local upTo = b.payUpTo and money(b.payUpTo) or (b.noPrice and "?" or "-")
      local cost = b.toBuy == 0 and (dim .. "enough|r") or (b.cost and money(b.cost) or (red .. "no price|r"))
      local tip = {}
      if b.toBuy > 0 and b.payUpTo then
        if (b.vendorUnits or 0) > 0 and (b.ahUnits or 0) > 0 then
          tip[#tip + 1] = b.ahUnits .. " from the auction house (cheaper than the vendor), the other " .. b.vendorUnits .. " from a vendor at " .. money(b.vendor) .. " each."
        elseif (b.vendorUnits or 0) > 0 then
          tip[#tip + 1] = "A vendor sells it at " .. money(b.vendor) .. " each, as many as you like."
        else
          tip[#tip + 1] = "Buy the cheapest " .. (b.toBuy - (b.short or 0)) .. ": no listing above " .. money(b.payUpTo) .. " each is needed."
        end
      end
      if (b.short or 0) > 0 and not b.noPrice and b.toBuy > 0 then
        tip[#tip + 1] = red .. b.short .. " more than were listed at the last scan: they are not in the cost.|r"
      end
      if b.noPrice then tip[#tip + 1] = red .. "Never scanned and no vendor known: scan the shopping list at the auction house.|r" end
      if b.listed then tip[#tip + 1] = dim .. b.listed .. " listed at the last scan" .. (age(b.day) and (", " .. age(b.day)) or "") .. ".|r" end
      tip[#tip + 1] = "Needed " .. b.need .. ", in your bags and bank " .. b.bags .. "."
      tip[#tip + 1] = dim .. "For: " .. names(list, b.entries) .. "|r"
      tip[#tip + 1] = b.ticked and "Click to put it back on the list." or "Click when you have bought it. Shift-click to link it."
      tip[#tip + 1] = gold .. "Right-click for choices|r: Have it, search the auction house."
      local row = { left = left .. flag, c1 = b.toBuy > 0 and upTo or "", c2 = cost, right = dim .. b.how .. "|r",
        item = b.item, haveItem = b.item, shopSection = "buy", shopItem = b.item, shopLine = b, tick = b.ticked, dim = b.ticked or nil, menu = true, tip = tip,
        cells = { name, tostring(b.toBuy), tostring(b.bags), b.toBuy > 0 and upTo or "", cost } }
      row.cols = { "", name .. flag, tostring(b.toBuy), tostring(b.bags), b.toBuy > 0 and upTo or "", cost, "  " .. dim .. b.how .. "|r", "" }
      row.shopMenu = { { check = true, checked = b.ticked, text = "Bought", func = function() NS.shopTick(b.item, not b.ticked) end } }
      row.action = tickAction(row)
      if b.ticked then   -- dimmed: plain grey text, no colours of its own
        row.left, row.c1, row.c2 = dim .. plain(row.left) .. "|r", dim .. plain(row.c1) .. "|r", dim .. plain(row.c2) .. "|r"
        row.right = dim .. "bought|r"
        for k, v in ipairs(row.cells) do row.cells[k] = dim .. plain(v) .. "|r" end
        for k, v in ipairs(row.cols) do row.cols[k] = v ~= "" and (dim .. plain(v) .. "|r") or "" end
        row.cols[7] = "  " .. dim .. "bought|r"
      end
      out[#out + 1] = row
    end
    sortLines(active, BUY_VALUE)
    sortLines(covered, BUY_VALUE)
    sortLines(ticked, BUY_VALUE)
    for _, b in ipairs(active) do buyRow(b) end
    for _, b in ipairs(covered) do buyRow(b) end
    for _, b in ipairs(ticked) do buyRow(b) end
  end

  -- make
  if #list.make > 0 then
    out[#out + 1] = { left = "" }
    out[#out + 1] = { left = gold .. "Make|r  " .. dim .. "parts you make yourself; their materials are in the list above|r", c1 = dim .. "crafts|r",
      section = "shopmake", shopSection = "make", shopHead = true, wide = true, cells = { "Part", "To make", "In bags", "Crafts", "" } }
    local rows2 = { {}, {}, {} }
    for _, m in ipairs(list.make) do
      local k = m.ticked and 3 or (m.toMake > 0 and 1 or 2)
      rows2[k][#rows2[k] + 1] = m
    end
    for k = 1, 3 do
      sortLines(rows2[k], MAKE_VALUE)
      for _, m in ipairs(rows2[k]) do
        local name = itemText(m.item)
        local left = "   " .. dim .. "make|r " .. m.toMake .. "x " .. name
        if m.bags > 0 then left = left .. dim .. "  have " .. m.bags .. " of " .. m.need .. (m.toMake == 0 and ", enough" or "") .. "|r" end
        local crafts = m.toMake > 0 and (m.crafts .. (m.crafts == 1 and " craft" or " crafts")) or (dim .. "enough|r")
        local row = { left = left, c1 = crafts, right = dim .. (m.ticked and "made" or "part") .. "|r",
          item = m.item, recipe = m.r and m.r.id or nil, pickItem = m.item, shopSection = "make", shopItem = m.item, shopLine = m,
          tick = m.ticked, dim = m.ticked or nil, menu = true,
          tip = { "A part you make yourself" .. (m.r and (" (" .. m.r.name .. ", " .. m.r.prof .. ")") or "") .. ". What it uses is in the Buy list.",
            "Needed " .. m.need .. ", in your bags and bank " .. m.bags .. "." .. ((m.makes or 1) > 1 and (" One craft makes " .. m.makes .. ".") or ""),
            dim .. "For: " .. names(list, m.entries) .. "|r",
            m.ticked and "Click to put it back on the list." or "Click when you have made them.",
            gold .. "Right-click for choices|r: Buy, Make or Have it." },
          cells = { name, tostring(m.toMake), tostring(m.bags), m.toMake > 0 and tostring(m.crafts) or "", "" } }
        row.shopMenu = { { check = true, checked = m.ticked, text = "Made", func = function() NS.shopTick(m.item, not m.ticked) end } }
        row.action = tickAction(row)
        row.cols = { "", dim .. "make|r " .. name, tostring(m.toMake), tostring(m.bags), "", crafts, "  " .. dim .. (m.ticked and "made" or "craft it") .. "|r", "" }
        if m.ticked then
          row.left, row.c1 = dim .. plain(row.left) .. "|r", dim .. plain(row.c1) .. "|r"
          for k2, v in ipairs(row.cols) do row.cols[k2] = v ~= "" and (dim .. plain(v) .. "|r") or "" end
        end
        out[#out + 1] = row
      end
    end
  end

  -- have it
  if #list.have > 0 then
    out[#out + 1] = { left = "" }
    out[#out + 1] = { left = gold .. "Have it|r  " .. dim .. "you said you have these: not bought, not counted|r", section = "shophave", shopSection = "have", shopHead = true, wide = true }
    for _, h in ipairs(list.have) do
      out[#out + 1] = { left = "   " .. h.need .. "x " .. itemText(h.item) .. dim .. "  " .. h.bags .. " in your bags and bank|r",
        c2 = dim .. "not bought|r", item = h.item, haveItem = h.item, choice = true, shopSection = "have", shopItem = h.item, shopLine = h,
        tip = { "Set to Have it: it costs nothing and is not bought, however many the list uses.",
          h.bags < h.need and (red .. "You have " .. h.bags .. " of the " .. h.need .. " the list uses.|r") or "You have enough of it.",
          gold .. "Click or right-click for choices|r: Auto prices and buys it again." },
        cells = { itemText(h.item), tostring(h.need), tostring(h.bags), "", "" },
        cols = { "", itemText(h.item), tostring(h.need), tostring(h.bags), "", dim .. "not bought|r", "  " .. dim .. "have it|r", "" } }
    end
  end

  -- totals
  out[#out + 1] = { left = "" }
  local notes = ""
  if list.nNoPrice > 0 then notes = notes .. red .. "  " .. list.nNoPrice .. " without a price|r" end
  if list.nShort > 0 then notes = notes .. red .. "  " .. list.nShort .. " with too few listed|r" end
  out[#out + 1] = { left = gold .. "Materials still to buy|r" .. notes, c2 = gold .. money(list.left) .. "|r", shopSection = "total", shopTotal = "left",
    tip = { "Everything on the Buy list that is not ticked off, at the prices of the last scan.",
      (list.nNoPrice + list.nShort) > 0 and (red .. "Short: items without a price, or with fewer listed than needed, are not counted in full.|r") or "Every line is priced in full." } }
  out[#out + 1] = { left = dim .. "   of the whole list: at vendors|r", c2 = money(list.vendorCost), shopSection = "total", shopTotal = "vendor" }
  out[#out + 1] = { left = dim .. "   of the whole list: at the auction house|r", c2 = money(list.ahCost), shopSection = "total", shopTotal = "ah" }
  if list.cost ~= list.left then
    out[#out + 1] = { left = dim .. "   the whole list, ticked lines included|r", c2 = money(list.cost), shopSection = "total", shopTotal = "all" }
  end
  return out
end

-- ---- the Shopping page -----------------------------------------------------------------------------------------
-- Registered under the key "shop" (it replaces the placeholder in Ledger.lua). From the top:
--   the bar          what the list is for in one line, then Scan shopping list, Add favourites, Clear list
--   "Shopping for"   one line per entry: icon, name, a stepper for its quantity (a route has none), Remove
--   the table        Buy, Make and Have it as foldable sections of one table: tick box, Item, To buy, In bags,
--                    Pay up to, Cost, Where, and a Search button at the auction house
--   the totals       left to buy, of which at vendors and at the auction house, the whole list
-- Everything shown is read from the rows of NS.shopRows(): the page only decides where a row goes (page.view:
-- the table's rows; page.wants: the entry lines; page.totalRows: the strip). It never buys anything.
--
-- Sizes (all guesses until seen in game):
local SHOP = {
  maxEntries = 4,    -- entry lines shown at once; the mouse wheel moves through more
  entryH = 24,       -- one entry line
  headH = 20,        -- the "Shopping for" caption
  totalH = 22,       -- the totals strip
  gap = 4,
  scanW = 130, favW = 104, clearW = 96,   -- the bar's buttons
  stepBox = 50,      -- the stepper's number box
  removeW = 66,
}
NS.SHOP = SHOP

local COLUMNS = {
  { key = "tick", title = "", width = 22, sortable = false, fixed = true },
  { key = "name", title = "Item", flex = 1, min = 160, sortable = true },
  { key = "tobuy", title = "To buy", width = 52, align = "RIGHT", sortable = true,
    tip = { "To buy", "What the list needs less what is in your bags and bank. For a part you make: how many to make." } },
  { key = "bags", title = "In bags", width = 52, align = "RIGHT", sortable = true, drop = 2,
    tip = { "In bags", "What you have of it now, bank included." } },
  { key = "upto", title = "Pay up to", width = 86, align = "RIGHT", sortable = true,
    tip = { "Pay up to", "The dearest price each that this quantity still needs: no listing above it is worth buying." } },
  { key = "cost", title = "Cost", width = 86, align = "RIGHT", sortable = true,
    tip = { "Cost", "What the listed units cost at the last scan. For a part you make: the crafts needed." } },
  { key = "where", title = "Where", width = 88, sortable = true, drop = 3 },
  { key = "find", title = "", width = 54, sortable = false, drop = 4, fixed = true },
}
NS.SHOP_COLUMNS = COLUMNS

local function UIkit() return KeboldsShinyUI end

-- An entry line holds a stepper (22 px), so it is never lower than 24; with roomy rows it follows the list's lines.
local function entryH()
  return max(SHOP.entryH, UIkit().density().rowH + 2)
end

local function atAH()
  return type(NS.atAuctionHouse) == "function" and NS.atAuctionHouse() and true or false
end

-- The number on the rail: Buy lines still open. Worked out again only when the list or the prices changed, or
-- while the Shopping page itself is showing.
local badge = { rev = -1, version = -1, text = nil }
function NS.shopBadge()
  local f = type(NS.frame) == "function" and NS.frame() or nil
  if type(f) ~= "table" or type(f.nav) ~= "table" then return nil end
  local version = type(NS.version) == "function" and NS.version() or 0
  local page = type(NS.currentPage) == "function" and NS.currentPage() or nil
  if badge.rev ~= rev or badge.version ~= version or (page and page.key == "shop") then
    local ok, s = pcall(NS.shopSummary)
    badge.rev, badge.version = rev, version
    badge.text = (ok and s.left > 0) and tostring(s.left) or nil
  end
  f.nav:SetBadge("shop", badge.text)
  return badge.text
end

-- "Scan shopping list" among the scans the buttons and menus offer, while the list has something to price.
local SHOP_SCAN_TIP = "What the shopping list buys, the parts it makes and what those use: fresh prices before you buy."
if type(NS.scanPresetAdd) == "function" and not NS.shopPresetAdded then   -- the scans' own way of taking one more
  NS.shopPresetAdded = true
  if type(NS.SCAN_NAME) == "table" and not NS.SCAN_NAME.shop then NS.SCAN_NAME.shop = "Shopping list" end
  NS.scanPresetAdd(function()
    local ok, ids = pcall(NS.shopScanIDs)
    local n = (ok and type(ids) == "table") and #ids or 0
    if n == 0 then return nil end
    return { key = "shop", word = "shop", count = n, tip = SHOP_SCAN_TIP }
  end)
elseif type(NS.scanPresets) == "function" and not NS.shopPresetAdded then
  NS.shopPresetAdded = true
  local base = NS.scanPresets
  NS.scanPresets = function()
    local list = base()
    local ok, ids = pcall(NS.shopScanIDs)
    local n = (ok and type(ids) == "table") and #ids or 0
    if n > 0 and type(list) == "table" then
      list[#list + 1] = { key = "shop", word = "shop", count = n,
        text = string.format("Scan shopping list (%d items, %s)", n, n < 90 and (ceil(n * 0.65) .. " s") or (ceil(n * 0.65 / 60) .. " min")),
        tip = SHOP_SCAN_TIP }
    end
    return list
  end
end

-- Which of the page's rows the table lists: the Buy, Make and Have it blocks (or the empty list's lines).
local function tableRows(rows)
  local out = {}
  for _, row in ipairs(rows) do
    local sec = row.shopSection
    if sec == "buy" or sec == "make" or sec == "have" or sec == "empty" then
      if row.shopHead and #out > 0 then out[#out + 1] = { left = "" } end
      out[#out + 1] = row
    end
  end
  return out
end

-- The tick boxes and the Search buttons on the table's lines (after every paint of the table).
local function dress(t)
  local UI = UIkit()
  local plainSkin, at = UI.plain(), atAH()
  for _, b in ipairs(t.lines) do
    local row = rawget(b, "row")
    local tickable = row ~= nil and (row.tick == true or row.tick == false)
    local box, mark = rawget(b, "shopBox"), rawget(b, "shopMark")
    if tickable and not plainSkin then
      if not box then
        box = b:CreateTexture(nil, "ARTWORK")
        box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
        mark = b:CreateTexture(nil, "OVERLAY")
        mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        b.shopBox, b.shopMark = box, mark
      end
      local side = UI.density().icon   -- the tick box follows the line's height, like the item icons
      box:SetSize(side, side)
      mark:SetSize(side, side)
      box:ClearAllPoints()
      box:SetPoint("LEFT", b, "LEFT", (t.xs[1] or 20) - 1, 0)
      mark:ClearAllPoints()
      mark:SetPoint("LEFT", b, "LEFT", (t.xs[1] or 20) - 1, 0)
      box:Show()
      if row.tick == true then mark:Show() else mark:Hide() end
    else
      if box then box:Hide() end
      if mark then mark:Hide() end
      if tickable and type(b.cells) == "table" and type(b.cells[1]) == "table" then
        b.cells[1]:SetText(row.tick == true and "[x]" or "[ ]")   -- the plain skin: the same in letters
      end
    end
    b.shopTicked = tickable and row.tick == true or false
    local find = rawget(b, "shopFind")
    local want = at and row ~= nil and row.shopSection == "buy" and row.item ~= nil and row.tick == false
      and type(row.shopLine) == "table" and (row.shopLine.toBuy or 0) > 0 and t.shown[8] == true
    if want then
      if not find then
        find = UI.button(b, "Search", 50, function()
          local r = rawget(b, "row")
          if r and r.item then NS.searchAH(r.item) end
        end, { "Search", "Shows this item's listings on the auction house's Buy page. Nothing is bought." })
        b.shopFind = find
      end
      pcall(find.SetHeight, find, min(t.rowH - 2, UI.density().ctl))
      find:ClearAllPoints()
      find:SetPoint("LEFT", b, "LEFT", t.xs[8] or 0, 0)
      find:Show()
    elseif find then
      find:Hide()
    end
    b.shopFindShown = want and true or false
  end
end

local function entryLine(page, i)
  local UI = UIkit()
  local b = page.entryLines[i]
  if b then return b end
  b = CreateFrame("Button", nil, page.wantsBox)
  b:SetSize(300, entryH())
  b.row = nil
  local hi = b:CreateTexture(nil, "HIGHLIGHT")
  hi:SetAllPoints()
  hi:SetColorTexture(1, 1, 1, 0.08)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(18, 18)
  b.icon:SetPoint("LEFT", 2, 0)
  b.name = UI.text(b, "body", "")
  b.name:SetPoint("LEFT", 26, 0)
  b.name:SetJustifyH("LEFT")
  b.name:SetWordWrap(false)
  b.remove = UI.button(b, "Remove", SHOP.removeW, function()
    local r = rawget(b, "row")
    if r then NS.shopRemove(r.shopEntry) end
  end, { "Remove", "Takes this off the shopping list." })
  b.remove:SetPoint("RIGHT", -4, 0)
  b.step = UI.stepper(b, { min = 1, max = MAX_QTY, w = SHOP.stepBox,
    tip = { "Quantity", "Crafts of the recipe (units for a plain item). Type a number, or use - and +." } },
    function()
      local r = rawget(b, "row")
      return r and r.shopQty or 1
    end,
    function(v)
      local r = rawget(b, "row")
      if r then NS.shopSetQty(r.shopEntry, v) end
    end)
  b.step:SetPoint("RIGHT", b.remove, "LEFT", -8, 0)
  b.kind = UI.text(b, "dim", "")
  b.kind:SetPoint("RIGHT", b.step, "LEFT", -8, 0)
  b.kind:SetJustifyH("RIGHT")
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, button)
    if rawget(self, "row") then NS.rowClick(self, button) end
  end)
  b:SetScript("OnEnter", function(self)
    if rawget(self, "row") then NS.rowEnter(self) end
  end)
  b:SetScript("OnLeave", function(self) NS.rowLeave(self) end)
  page.entryLines[i] = b
  return b
end

local function fillEntry(b, row, w)
  local UI = UIkit()
  b.row = row
  b:SetSize(w, entryH())
  UI.cellFont(b.name)
  b.icon:SetSize(UI.density().icon, UI.density().icon)
  local tex = (not UI.plain() and UI.opt("icons")) and UI.iconOf(row) or nil
  if tex then
    b.icon:SetTexture(tex)
    b.icon:Show()
  else
    b.icon:Hide()
  end
  b.name:SetWidth(max(60, w - 26 - (SHOP.removeW + 4 + 8 + SHOP.stepBox + 52 + 8 + 80)))
  b.name:SetText(UI.show((row.shopName or "") .. (row.shopNote or "")))
  b.kind:SetText(UI.plainText(row.c1 or ""))
  if row.shopQty then
    b.step:Show()
    b.step:Refresh()
  else
    b.step:Hide()
  end
  b:Show()
end

-- Puts the page's parts where they go for its size and the number of entries. Called after every refresh and
-- while the window is resized.
local function place(page)
  local w, h, y = page.w, page.h, page.shopY or 0
  local t = page.table
  if not (w and h and type(t) == "table") then return end
  local wants = page.wants or {}
  local n = #wants
  page.summary:SetWidth(max(60, w - 8 - (SHOP.scanW + SHOP.favW + SHOP.clearW + 8 + 8)))
  t:ClearAllPoints()
  if n == 0 then   -- nothing on the list: the table's empty state has the whole page
    page.wantsBox:Hide()
    page.totals:Hide()
    t:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, -y)
    t:Layout(w, h - y)
    return
  end
  local vis = min(n, SHOP.maxEntries)
  page.wantsOff = max(0, min(page.wantsOff or 0, n - vis))
  local boxH = SHOP.headH + vis * entryH() + SHOP.gap
  page.wantsBox:ClearAllPoints()
  page.wantsBox:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, -y)
  page.wantsBox:SetSize(w, boxH)
  page.wantsBox:Show()
  page.wantsHint:SetText(n > vis and ((page.wantsOff + 1) .. " to " .. (page.wantsOff + vis) .. " of " .. n .. ", scroll for more") or "")
  for i = 1, vis do
    local b = entryLine(page, i)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", page.wantsBox, "TOPLEFT", 0, -(SHOP.headH + (i - 1) * entryH()))
    fillEntry(b, wants[page.wantsOff + i], w - 4)
  end
  for i = vis + 1, #page.entryLines do
    page.entryLines[i].row = nil
    page.entryLines[i]:Hide()
  end
  t:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, -(y + boxH + SHOP.gap))
  t:Layout(w, h - y - boxH - SHOP.gap - SHOP.totalH)
  page.totals:ClearAllPoints()
  page.totals:SetPoint("BOTTOMLEFT", page.frame, "BOTTOMLEFT", 0, 0)
  page.totals:SetSize(w, SHOP.totalH)
  page.totals:Show()
end

NS.page({ key = "shop", title = "Shopping", order = 3, icon = "Interface\\Icons\\INV_Misc_Bag_08",
  tip = { "Shopping", "One list of what to buy for your plans: add a route step, a whole route, crafts of a recipe or your favourites. Your bags are taken off and every line says what price to pay up to." },
  bars = 1,
  -- the window's footer on this page: the list's own status (no plan, no scan button of the plan's)
  footer = function()
    local ok, text = pcall(NS.shopStatus)
    return ok and text or ""
  end,
  rows = function()
    return NS.shopRows(), "Shopping"
  end,
  view = function(_, rows) return tableRows(rows) end,
  build = function(page)
    local UI = UIkit()
    local fr = page.frame
    page.wants, page.totalRows, page.wantsOff, page.shopY, page.clearArmed = {}, {}, 0, 0, false
    -- the bar
    page.summary = UI.text(page.bar, "body", "")
    page.summary:SetPoint("TOPLEFT", page.bar, "TOPLEFT", 4, -7)
    page.summary:SetJustifyH("LEFT")
    page.summary:SetWordWrap(false)
    page.bClear = UI.button(page.bar, "Clear list", SHOP.clearW, function()
      if page.clearArmed ~= true then   -- asked once more before anything is thrown away
        page.clearArmed = true
        page.bClear:SetLabel("Really clear?")
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
          C_Timer.After(4, function()
            page.clearArmed = false
            page.bClear:SetLabel("Clear list")
          end)
        end
        return
      end
      page.clearArmed = false
      page.bClear:SetLabel("Clear list")
      NS.shopClear()
    end, { "Clear list", "Empties the shopping list and its ticks. Click twice: the second click within a few seconds clears it." })
    page.bClear:SetPoint("TOPRIGHT", page.bar, "TOPRIGHT", -2, -2)
    page.bFav = UI.button(page.bar, "Add favourites", SHOP.favW, function()
      for _, e in ipairs(NS.shopEntries()) do
        if e.kind == "favs" then
          NS.notice("Your favourites are on the list already: change their quantity there.", "info")
          return
        end
      end
      local ok, err = NS.shopAdd({ kind = "favs", n = 1 })
      if not ok then NS.notice("Not added: " .. tostring(err) .. ".") end
    end, { "Add favourites", "Adds one craft of every favourite recipe as one entry that follows your favourites. Its quantity can be typed." })
    page.bFav:SetPoint("RIGHT", page.bClear, "LEFT", -4, 0)
    page.bScan = NS.scanControl(UI.button(page.bar, "Scan shopping list", SHOP.scanW, function()
      NS.scanButton("shop")
    end, { "Scan shopping list", "Reads fresh prices for what the list buys, the parts it makes and what those use. It only looks: nothing is bought." }))
    page.bScan:SetPoint("RIGHT", page.bFav, "LEFT", -4, 0)
    -- what you are shopping for
    page.wantsBox = CreateFrame("Frame", nil, fr)
    page.wantsTitle = UI.text(page.wantsBox, "section", "Shopping for")
    page.wantsTitle:SetPoint("TOPLEFT", page.wantsBox, "TOPLEFT", 4, -3)
    page.wantsHint = UI.text(page.wantsBox, "dim", "")
    page.wantsHint:SetPoint("LEFT", page.wantsTitle, "RIGHT", 10, 0)
    page.entryLines = {}
    page.wantsBox:EnableMouseWheel(true)
    page.wantsBox:SetScript("OnMouseWheel", function(_, delta)
      page.wantsOff = (page.wantsOff or 0) - delta
      place(page)
    end)
    -- the table
    local t = UI.table(fr, COLUMNS, {
      onClick = NS.rowClick, onEnter = NS.rowEnter, onLeave = NS.rowLeave,
      onSort = function(key)
        local now, desc = NS.shopSorted()
        if now == key and desc then
          NS.shopSort(nil)                 -- third click: back to the order things were needed in
        else
          NS.shopSort(key, now == key)     -- first click ascending, second descending
        end
        NS.refresh()
      end })
    local basePaint = t.Paint
    function t:Paint()
      basePaint(self)
      dress(self)
    end
    page.table = t
    -- the totals
    page.totals = CreateFrame("Frame", nil, fr)
    page.totalLeft = UI.text(page.totals, "section", "")
    page.totalLeft:SetPoint("LEFT", page.totals, "LEFT", 4, 0)
    page.totalRest = UI.text(page.totals, "body", "")
    page.totalRest:SetPoint("RIGHT", page.totals, "RIGHT", -24, 0)
    page.totalRest:SetJustifyH("RIGHT")
  end,
  layout = function(page, _, _, y)
    page.shopY = y
    place(page)
  end,
  paint = function(page, rows)
    local UI = UIkit()
    local wants, totals = {}, {}
    for _, row in ipairs(rows) do
      if row.shopSection == "wants" and not row.shopHead then wants[#wants + 1] = row end
      if row.shopTotal then totals[row.shopTotal] = row end
    end
    page.wants, page.totalRows = wants, totals
    local s = NS.shopSummary()
    page.summaryText = s.entries == 0 and "Nothing on the list yet."
      or ((s.entries == 1 and "1 thing" or (s.entries .. " things")) .. " on the list:  " .. s.text)
    page.summary:SetText(UI.show(page.summaryText))
    local favs = NS.shopFavCount()
    page.bFav:SetEnabled(favs > 0, "No favourites yet: right-click a recipe on the Craft page and tick Favourite.")
    page.bClear:SetEnabled(s.entries > 0, "The list is empty.")
    if s.entries == 0 and page.clearArmed == true then
      page.clearArmed = false
      page.bClear:SetLabel("Clear list")
    end
    local function part(key, label)
      local row = totals[key]
      return row and (DIM() .. label .. "|r " .. (row.c2 or "")) or nil
    end
    page.totalLeft:SetText(UI.show(totals.left and (totals.left.left .. "    " .. (totals.left.c2 or "")) or ""))
    local rest = {}
    for _, x in ipairs({ { "vendor", "at vendors" }, { "ah", "at the auction house" }, { "all", "whole list" } }) do
      local text = part(x[1], x[2])
      if text then rest[#rest + 1] = text end
    end
    page.totalRest:SetText(UI.show(table.concat(rest, "     ")))
    local key, desc = NS.shopSorted()
    page.table:SetSort(key or 0, desc)
    place(page)
    NS.shopBadge()
  end,
})

-- ---- /keboldshop ---------------------------------------------------------------------------------------------

local function say(msg)
  if type(NS.say) == "function" then NS.say(msg) else print(msg) end
end

local function printList()
  local s = NS.shopSummary()
  say("Shopping: " .. plain(s.text))
  local list = {}
  for _, row in ipairs(NS.shopRows()) do
    if (row.left or "") ~= "" then list[#list + 1] = row end
  end
  NS.printRows(list, nil, function(row) return row.shopEntry and ("[" .. row.shopEntry .. "]") or nil end)
end

SLASH_KEBOLDSSHINYSHOP1 = "/keboldshop"
SLASH_KEBOLDSSHINYSHOP2 = "/ledgershop"   -- the name before the addon was renamed
SlashCmdList["KEBOLDSSHINYSHOP"] = function(msg)
  local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
  local ok, err = true, nil
  local a, b, c = cmd:match("^add%s+(%a+)%s*(%S*)%s*(%S*)$")
  if cmd == "" or cmd == "list" then
    printList()
    return
  elseif a == "recipe" or a == "item" then
    ok, err = NS.shopAdd({ kind = a, id = tonumber(b), n = tonumber(c) or 1 })
  elseif a == "route" then
    local prof = b ~= "" and NS.ALIAS and NS.ALIAS[b] or nil
    if b ~= "" and not prof then
      say("No profession called " .. b .. ".")
      return
    end
    ok, err = NS.shopAdd({ kind = "route", prof = prof })
  elseif a == "favs" or a == "fav" or a == "favourites" or a == "favorites" then
    ok, err = NS.shopAdd({ kind = "favs", n = tonumber(b) or 1, split = c == "split" })
  elseif cmd == "clear" then
    NS.shopClear()
    say("Shopping list cleared.")
    return
  elseif cmd:match("^remove%s+%d+$") then
    ok = NS.shopRemove(tonumber(cmd:match("%d+")))
    err = "no line with that number"
  elseif cmd:match("^qty%s+%d+%s+%d+$") then
    local i, n = cmd:match("^qty%s+(%d+)%s+(%d+)$")
    ok = NS.shopSetQty(tonumber(i), tonumber(n))
    err = "no line with that number, or it has no quantity"
  elseif cmd:match("^tick%s+%d+$") or cmd:match("^untick%s+%d+$") then
    NS.shopTick(tonumber(cmd:match("%d+")), cmd:sub(1, 2) ~= "un")
  else
    say("Usage: /keboldshop [list | add recipe <spell id> [n] | add item <item id> [n] | add route [profession] | add favs [n] | qty <line> <n> | remove <line> | clear | tick <item id> | untick <item id>]")
    return
  end
  if not ok then
    say("Not done: " .. tostring(err) .. ".")
    return
  end
  printList()
end
