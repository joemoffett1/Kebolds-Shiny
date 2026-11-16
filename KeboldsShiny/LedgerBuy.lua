-- Kebold's Shiny: the buy helper on the auction house's Buy tab
--   The player opens one item on Blizzard's Buy tab (the price lines, cheapest first, a Quantity box and a Buy
--   button). This file ADDS to that page (S.buy.where = "page", the default): a thin colour bar and a small
--   per-hour figure on each of Blizzard's own price rows of the commodity buy screen, and three label / value
--   lines under Blizzard's Buy button, written like the page's own Quantity / Unit Price / Total Price lines.
--   Nothing of Blizzard's is covered and there is no switch on the page. Or it draws a panel of its own outside
--   the right edge of the auction house window ("side", also used when Blizzard's buy display cannot be
--   found). Either says, for a recipe that uses the item, which price lines still pay: green = the crafts made from units at that
--   price earn at least the floor ("Worth above", gold an hour), yellow = a profit under the floor, red = no
--   profit or a loss; "Buy up to N at X or less"; and for the quantity typed into Blizzard's box what it costs, what the
--   crafts earn and how long they take. For an item a recipe MAKES it compares buying with making and with what
--   a vendor pays.
--
-- What is done to the game, and nothing more. THE ADDON READS AND DRAWS ONLY:
--   * it listens to the search-result events the client fires for the item the player opened and reads the
--     price lines with the documented getters (warcraft.wiki.gg, C_AuctionHouse):
--       COMMODITY_SEARCH_RESULTS_UPDATED / _ADDED (itemID)
--         GetNumCommoditySearchResults(itemID), GetCommoditySearchResultInfo(itemID, i) -> { unitPrice, quantity },
--         HasFullCommoditySearchResults(itemID)
--       ITEM_SEARCH_RESULTS_UPDATED (itemKey, newAuctionID) / _ADDED (itemKey)
--         GetNumItemSearchResults(itemKey), GetItemSearchResultInfo(itemKey, i) -> { buyoutAmount, quantity },
--         HasFullItemSearchResults(itemKey)
--     It sends no search of its own. While a Kebold scan runs (KeboldsShinyScan_Busy) the results are the scan's:
--     none is read here, and the panel says so instead of showing an item;
--   * it READS the number in Blizzard's Quantity box (a getter, never a setter; see quantityOf) and whether the
--     buy frames are shown; it never types into a box of Blizzard's and never clicks one of its buttons;
--   * its frames are children of Blizzard's frames (owner approved 2026-11-10): one small frame per row of the
--     commodity price list (the bar and the figure), the lines of the buy display, the side panel of
--     AuctionHouseFrame. They are only parented and anchored there: no Blizzard frame is hidden, moved, sized
--     or re-anchored, no field is written onto Blizzard's tables, no Blizzard script is replaced, and the list's
--     layout and data are left alone. The window's display mode is watched with hooksecurefunc; the price
--     list's scroll box is asked through its own callback registry to say when it scrolled. The item
--     (non-commodity) buy screen is left exactly as Blizzard draws it.
--   It never buys, bids, posts or cancels anything.
--
-- The live price lines are the best ladder there is, so they are saved as the item's reading exactly as a scan
-- would (KeboldsShinyScan_SaveLadder in KeboldsShiny.lua; only for items Kebold knows) and every page of Kebold
-- uses them at once (NS.bump).
--
-- Where the figures come from: the engine. The recipe's worth curve under its approach (ctx.worthBest /
-- ctx.worthCurve walked with `all`) gives, for every stretch of crafts, the profit of one craft and the unit
-- price of each material. Taking this item's own cost back out of a stretch leaves "everything else" (the sale,
-- the AH sales cap, the other materials getting dearer); the live price lines are then laid against that, the
-- crafts starting from the units already in the bags. See projectUse.
--
-- The logic output is plain tables: NS.buyModel(itemID, lines, qty [, choice]) and NS.buyRows() (the panel's
-- print lines), read by tests/lua/buy_mock.lua without a screen. The frame only paints them.

local NS, UI = KeboldsShinyNS, KeboldsShinyUI
if type(NS) ~= "table" or type(UI) ~= "table" then return end
local E = NS.E
local settings, try, money = NS.settings, NS.try, NS.money
local DIM, RED, GREEN, GOLD = NS.DIM, NS.RED, NS.GREEN, NS.GOLD
local YELLOW = "|cffffe45c"   -- a profit under the floor (not one of the three colours reserved for coins)
local floor, ceil, max, min, abs, huge = math.floor, math.ceil, math.max, math.min, math.abs, math.huge

local function isTable(x) return type(x) == "table" end
local function isFn(x) return type(x) == "function" end

-- Sizes, all guesses until seen in game.
local BUY = {
  w = 320,        -- the panel's width
  gap = 4,        -- between the auction house window and the panel
  rowH = 18,      -- a line of its two lists
  sumMax = 13,    -- lines of the summary shown before it scrolls
  bar = 5,        -- width of the colour bar at the left of a price line
  level = 10,     -- frame levels above the auction house window
  poll = 0.25,    -- seconds between two looks at Blizzard's Quantity box and at which frame shows
  top = 20,       -- the best-paying recipes offered in the dropdown, beside the pinned ones
  colListed = 34, colTotal = 40, colLast = 60,   -- the side panel's list: the price column takes the rest
  coin = 8,       -- what a coin picture adds to a text's estimated width
  -- the marks on Blizzard's own price rows (the numbers marked "source" are Blizzard's UI source, see below)
  rowBar = 3,     -- width of the colour bar at a row's left edge
  rowW = 180,     -- a row's width when the game gives none (source: the list is 210 wide, its rows 30 less)
  rowPriceX = 10, -- where Blizzard's price starts in a row (source: the price cell's left padding)
  rowPad = 10,    -- between Blizzard's quantity and the row's right edge (source: the quantity cell's right padding)
  rowCheck = 22,  -- the checkmark right of the price on a row that holds an auction of the player's (source: 6 + 16)
  rowDigit = 8, rowCoin = 17,   -- estimated width of one digit and of one coin picture in Blizzard's row font
  rowGap = 8,     -- kept free between the per-hour figure and Blizzard's texts
  -- the lines under Blizzard's Buy button
  -- Seen in game 2026-11-14: the display is about 425 wide and the Buy button's bottom edge about 150 above the
  -- display's bottom. The lines hang 10 under the button and are 84 high, so they end some 55 above the bottom.
  sumW = 342, sumH = 86,      -- width when the game gives none (source: the item display's); height (S.buy.pageHeight)
  inset = { 0, 10, 0, 4 },    -- S.buy.pageInset: moved right, gap under the Buy button, kept free at the right,
                              -- and from the display's bottom where the button is not found
  padL = 15, padR = 16,       -- the buy display's own left and right padding (source)
  btnPad = 110,               -- the Buy button starts this far right of the label column's left edge (source)
  pgLabel = 93, pgGapX = 18,  -- the label column's width and the gap before the value (source)
  pgCtl = 24, pgLine = 20, pgWarn = 16, pgGap = 2,   -- heights: the Craft line, a text line, the warning, a gap
  sumLevel = 5,
  sumMinBox = 60, pgBox = 196,   -- the Craft dropdown's box: the least it is given, and its width (source: the Buy button's)
  floors = { 0, 5, 10, 20, 50 },   -- the "Worth above" choices in the Craft dropdown's menu
}
NS.BUY = BUY
local TONE = { green = GREEN, yellow = YELLOW, red = RED }
local TONE_RGB = { green = { 0.25, 0.82, 0.25 }, yellow = { 1, 0.85, 0.2 }, red = { 1, 0.3, 0.3 },
  none = { 0.5, 0.5, 0.5 } }   -- a row without a figure: a dim grey bar, so every row has one

-- ---- small helpers ----------------------------------------------------------------------------------------------------

-- A text in a tone's colour. money() ends its coin letters with "|r", which would end the tone too: it is put
-- back after each (the coin markers themselves stay whole, so UI.show still finds them).
local function tint(tone, text)
  local c = TONE[tone]
  if not c then return text end
  return c .. tostring(text):gsub("|r", "|r" .. c) .. "|r"
end

local function signedMoney(v)
  if v == nil then return DIM .. "-|r" end
  if v < 0 then return "-" .. money(-v) end
  return money(v)
end

local function whole(n) return string.format("%.0f", floor(n + 0.5)) end

-- Compact money for narrow cells. The coin letters are money()'s own three marks (UI.MARK), so UI.show still
-- turns them into coins.
--   cmoney: gold only from 100g, no zero silver / copper ("4s", not "4s 0c"): two coins at most
--   short1: ONE coin, for a figure that only has to be read at a glance (per hour): 41.2g, 155g, 45s, 1.3s, 66c
local MG, MS, MC = UI.MARK.g, UI.MARK.s, UI.MARK.c
local function cmoney(v)
  if v == nil then return "?" end
  v = floor(abs(v) + 0.5)
  local g, s, c = floor(v / 10000), floor(v / 100) % 100, v % 100
  if g >= 100 then return whole(v / 10000) .. MG end
  if g > 0 then return s > 0 and (g .. MG .. " " .. s .. MS) or (g .. MG) end
  if s > 0 then return c > 0 and (s .. MS .. " " .. c .. MC) or (s .. MS) end
  return c .. MC
end
local function short1(v)
  v = abs(v or 0)
  local function dec(x, mark)
    local t = string.format("%.1f", x)
    if t:sub(-2) == ".0" then t = t:sub(1, -3) end
    return t .. mark
  end
  if v >= 999500 then return whole(v / 10000) .. MG end
  if v >= 9950 then return dec(v / 10000, MG) end
  if v >= 995 then return whole(v / 100) .. MS end
  if v >= 99.5 then return dec(v / 100, MS) end
  return whole(v) .. MC
end
local function signedC(v)
  if v == nil then return DIM .. "-|r" end
  return (v < 0 and "-" or "") .. cmoney(v)
end
local function signedShort(v)
  if v == nil then return DIM .. "-|r" end
  return (v < 0 and "-" or "") .. short1(v)
end
NS.buyMoney, NS.buyShort = cmoney, short1
-- A number of crafts: whole when it is whole, else one decimal.
local function crafts(n)
  if abs(n - floor(n + 0.5)) < 0.05 then return whole(n) end
  return string.format("%.1f", n)
end

local function timeText(secs)
  secs = floor(secs + 0.5)
  if secs < 90 then return secs .. " s" end
  local m = floor(secs / 60 + 0.5)
  if m < 90 then return m .. " min" end
  return floor(m / 60) .. " h " .. (m % 60) .. " min"
end

local function buySet()
  local S = settings()
  if not isTable(S.buy) then S.buy = {} end
  if S.buy.on ~= false then S.buy.on = true end
  -- "page": marks on Blizzard's own rows and lines under its Buy button | "side": the panel.
  -- A saved "overlay" (Kebold's rows over the list, 2026-11-14) counts as "page"; its own settings are dropped.
  if S.buy.where ~= "side" then S.buy.where = "page" end
  S.buy.list, S.buy.listInset, S.buy.level, S.buy.inset, S.buy.height = nil, nil, nil, nil, nil
  if S.buy.rowph ~= false then S.buy.rowph = true end         -- false: the rows get the colour bar only
  return S.buy
end

-- The floor, gold an hour: the panel's own number (S.buy.floor, 10 until changed; owner: "dont go below 10g per
-- hour anything below that could be yellow"). It only colours the price lines: it is not the engine's "worth
-- making stops below" option, so changing it changes no figure anywhere else.
local FLOOR_DEFAULT = 10
local function floorGold()
  local v = tonumber(buySet().floor)
  if v == nil then v = FLOOR_DEFAULT end
  return max(0, min(500, v))
end
local function setFloor(v)
  buySet().floor = max(0, min(500, floor((tonumber(v) or 0) + 0.5)))
end
function NS.buyFloor(v)
  if v ~= nil then setFloor(v) end
  return floorGold()
end

-- profit of one craft and its hourly rate -> "green" | "yellow" | "red"
-- Yellow is a real profit under the floor: a craft that earns exactly nothing is red, like a loss.
local function toneOf(profit, ph, floorPH)
  if profit <= 1e-9 then return "red" end
  if ph >= floorPH - 1e-6 then return "green" end
  return "yellow"
end

-- Price lines as { { unit price, quantity }, ... }: merged by price, cheapest first.
local function cleanLines(lines)
  local by, prices = {}, {}
  for _, t in ipairs(isTable(lines) and lines or {}) do
    local p, q = isTable(t) and tonumber(t[1]) or nil, isTable(t) and tonumber(t[2]) or nil
    if p and q and p > 0 and q > 0 then
      p, q = ceil(p), floor(q)
      if not by[p] then
        by[p] = 0
        prices[#prices + 1] = p
      end
      by[p] = by[p] + q
    end
  end
  table.sort(prices)
  local out, total = {}, 0
  for i, p in ipairs(prices) do
    out[i] = { p, by[p] }
    total = total + by[p]
  end
  return out, total
end

-- ---- which recipes an item belongs to ----------------------------------------------------------------------------------

-- [item id] = { use = { recipes that use it, directly or through a part they make }, make = { recipes that make it } }
local index, known = nil, nil
local function buildIndex()
  index = {}
  local db = NS.data()
  local function slot(id)
    local s = index[id]
    if not s then
      s = { use = {}, make = {} }
      index[id] = s
    end
    return s
  end
  local function tree(r, into, order, seen)
    for _, reg in ipairs(r.regs) do
      local n = reg[1]
      if not into[n] then
        into[n] = true
        order[#order + 1] = n
      end
      local it = db.items[n]
      local m = db.maker[n]
      if m and not (it and it.raw) and not seen[n] then
        seen[n] = true
        tree(m, into, order, seen)
        seen[n] = nil
      end
    end
  end
  for _, r in ipairs(db.recipes) do
    local set, order = {}, {}
    tree(r, set, order, { [r.made] = true })
    for _, n in ipairs(order) do
      local s = slot(n)
      s.use[#s.use + 1] = r
    end
    if r.made > 0 then
      local s = slot(r.made)
      s.make[#s.make + 1] = r
    end
  end
end
local function slotOf(item)
  if not index then buildIndex() end
  return index[item]
end

-- Does Kebold know the item (a recipe makes or uses it, or one of its other pages prices it)? Only those are saved.
function NS.buyKnows(item)
  if slotOf(item) then return true end
  if not known then
    known = {}
    if isFn(KeboldsShiny_QuickItems) then
      local ok, ids = pcall(KeboldsShiny_QuickItems)
      for _, id in ipairs(ok and isTable(ids) and ids or {}) do known[id] = true end
    end
  end
  return known[item] == true
end

local function isDirect(r, item)
  for _, reg in ipairs(r.regs) do
    if reg[1] == item then return true end
  end
  return false
end

-- The recipe of the step a started plan of this profession is at (nil without one).
local function stepRecipe(prof)
  if not isFn(NS.startedSteps) then return nil end
  local ok, list = pcall(NS.startedSteps, prof)
  local s = ok and isTable(list) and list[1] or nil
  return isTable(s) and isTable(s.r) and s.r.id or nil
end

local chosen = {}   -- [item id] = the key picked in the dropdown, for this session

-- The recipes the item can be judged for: those that use it first (the one selected in the Kebold window, the
-- step a started plan is at, favourites, then by what a craft earns an hour at list prices), then those that
-- make it. Each: { key = "use:<id>" | "make:<id>", kind, r, ph, pin = "selected" | "step" | "fav" | nil, direct, text }.
-- The second value is the default: the selected recipe, else a plan's step, else a favourite, else the use that
-- earns most an hour (else the recipe that makes it).
local function choicesFor(item)
  local s = slotOf(item)
  local out = {}
  if not s then return out, nil end
  local S = settings()
  local sel = isFn(NS.detailRecipe) and NS.detailRecipe() or nil
  local steps = {}
  local function rank(r)
    if sel ~= nil and r.id == sel then return 1, "selected" end
    if steps[r.prof] == nil then steps[r.prof] = stepRecipe(r.prof) or false end
    if steps[r.prof] == r.id then return 2, "step" end
    if isTable(S.fav) and S.fav[r.id] == true then return 3, "fav" end
    return 4, nil
  end
  local uses = {}
  for _, r in ipairs(s.use) do
    local ok, c = pcall(NS.state, r.prof)
    local ph
    if ok and isTable(c) and isTable(c.ctx) then
      local ok2, x = pcall(c.ctx.bestInfo, r)
      if ok2 and isTable(x) and x.p ~= nil and (x.secs or 0) > 0 then ph = x.p / x.secs * 3600 end
    end
    local rk, pin = rank(r)
    uses[#uses + 1] = { key = "use:" .. r.id, kind = "use", r = r, ph = ph, rank = rk, pin = pin, direct = isDirect(r, item) }
  end
  table.sort(uses, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.ph ~= b.ph then
      if a.ph == nil or b.ph == nil then return a.ph ~= nil end
      return a.ph > b.ph
    end
    return a.r.i < b.r.i
  end)
  local plainN = 0
  for _, e in ipairs(uses) do
    if e.rank == 4 then plainN = plainN + 1 end
    if e.rank < 4 or plainN <= BUY.top then out[#out + 1] = e end
  end
  for _, r in ipairs(s.make) do
    local rk, pin = rank(r)
    out[#out + 1] = { key = "make:" .. r.id, kind = "make", r = r, rank = rk, pin = pin, direct = true }
  end
  for _, e in ipairs(out) do
    local what = e.kind == "make" and ("Make it: " .. e.r.name) or e.r.name
    e.text = what
    e.menu = what .. DIM .. "  " .. e.r.prof .. (e.direct and "" or ", through a part") .. "|r"
      .. (e.ph and ("  " .. signedMoney(e.ph) .. DIM .. " an hour|r") or "")
      .. (e.pin == "selected" and (GOLD .. "  selected|r") or (e.pin == "step" and (GOLD .. "  your plan's step|r") or (e.pin == "fav" and (GOLD .. "  favourite|r") or "")))
  end
  -- With nothing pinned: the use that earns most an hour (the first one, when it has a figure at all), else the
  -- first recipe that makes the item, else the first use.
  local def
  for _, e in ipairs(out) do
    if e.kind == "use" and e.ph ~= nil then def = e break end
  end
  if not def then
    for _, e in ipairs(out) do
      if e.kind == "make" then def = e break end
    end
  end
  def = def or out[1]
  for _, e in ipairs(out) do
    if e.rank < def.rank then def = e end
  end
  return out, def
end

-- ---- the model: an item something is made from --------------------------------------------------------------------------

-- The curve of recipe r under an approach that buys `item`: the one the profit views use first, then with every
-- part made, the cheapest mix, every part bought. Returns the curve, the approach, the item's place in the
-- curve's materials; or nil and, when some curve exists, true (the recipe does not buy the item as it is set up).
local function curveFor(ctx, r, item)
  local best = "auto"
  if isFn(ctx.bestInfo) then
    local _, m = ctx.bestInfo(r)
    best = m or "auto"
  end
  local tried, any = {}, false
  for _, mode in ipairs({ best, "craft", "auto", "buy" }) do
    if not tried[mode] then
      tried[mode] = true
      local w
      if mode == best and isFn(ctx.worthBest) then
        w = ctx.worthBest(r)
      else
        w = ctx.worthCurve(r, mode ~= "auto" and mode or nil, true)
      end
      if w then
        any = true
        for j, m in ipairs(w.mats) do
          if m.n == item then return w, mode, j end
        end
      end
    end
  end
  return nil, best, any
end

-- The projection. For recipe r, which buys `u` units of the item a craft:
--   1. each stretch of the engine's curve (crafts from..to with one profit and one unit price per material) gives
--        base  = profit + u x the item's price in that stretch   = the sale - every OTHER material, for one craft
--        ocost = cost - u x the item's price                     = the other materials of one craft
--      which no longer depend on what this item costs;
--   2. the live price lines are walked from the cheapest: bought unit number b belongs to craft (held + b) / u,
--      because the units in the bags are used first; the craft's profit is base(craft) - u x the line's price,
--      its hourly rate that over the seconds of one craft;
--   3. a line is cut where the tone changes (a stretch of the curve ends inside it), so one row has one tone.
-- Past the end of the curve: when it ended because this item ran out (the bags carry the crafts further than
-- the listings alone), the last stretch is assumed to go on (rows marked est); when another material ran out,
-- the units beyond have no figure.
-- Returns J = { cuts = { { from, to (bought units), price, each (profit a craft), ph, tone, ocost, base, est } },
--   u, secs, mode, held, floor (copper an hour), outBy (item id or true) }, or nil and a sentence.
local function projectUse(c, r, item, lines, held)
  local ctx = c.ctx
  local w, mode, j = curveFor(ctx, r, item)
  if not w then
    if j == true then return nil, "As this recipe is set up it does not buy this item (a part is bought ready-made, or it is set to Have it)." end
    local x = ctx.info(r)
    if x.cost == nil then return nil, "Another material of this recipe has no price yet: scan the recipe." end
    return nil, "What this recipe makes has no sale value Kebold can count."
  end
  local mctx = isFn(ctx.modeCtx) and ctx.modeCtx(mode) or ctx
  local secs = mctx.info(r).secs
  if not secs or secs <= 0 then secs = 1 end
  local u = w.mats[j].u
  local pieces = {}
  for _, g in ipairs(w.segs) do
    local px = g.pr[j] or 0
    pieces[#pieces + 1] = { from = g.from, to = g.to, base = g.profit + u * px, ocost = g.cost - u * px }
  end
  local last, outBy = pieces[#pieces], nil
  if last and last.to ~= huge then
    -- why the curve ends here: this item's own listings are used up, or another material's
    local S = mctx.supplyOf(item, nil)
    local total = 0
    for _, st in ipairs(S.steps) do total = total + st[2] end
    if (S.after == nil and total <= last.to * u + 1e-6) or #w.segs >= 200 then
      pieces[#pieces + 1] = { from = last.to, to = huge, base = last.base, ocost = last.ocost, est = true }
    else
      outBy = (isTable(w.stop) and w.stop.why == "out" and w.stop.n) or true
    end
  elseif not last then
    outBy = (isTable(w.stop) and w.stop.why == "out" and w.stop.n) or true
  end
  local floorPH = floorGold() * 10000
  local cuts, b, pi = {}, 0, 1
  for _, line in ipairs(lines) do
    local p, left = line[1], line[2]
    while left > 0 do
      local k = (held + b) / u
      while pieces[pi] and pieces[pi].to ~= huge and pieces[pi].to <= k + 1e-9 do pi = pi + 1 end
      local pc = pieces[pi]
      local take, cut
      if pc then
        -- whole units: the unit that straddles two stretches counts for the earlier one
        local room = pc.to == huge and huge or max(1, ceil(pc.to * u - held - b - 1e-9))
        take = min(left, room)
        local each = pc.base - u * p
        local ph = each / secs * 3600
        cut = { from = b, to = b + take, price = p, each = each, ph = ph, tone = toneOf(each, ph, floorPH), ocost = pc.ocost, base = pc.base, est = pc.est }
      else
        take = left
        cut = { from = b, to = b + take, price = p }
      end
      cuts[#cuts + 1] = cut
      b, left = b + take, left - take
    end
  end
  return { cuts = cuts, u = u, secs = secs, mode = mode, held = held, floor = floorPH, outBy = outBy, w = w }
end

local MODE_NOTE = { buy = "with its parts bought", craft = "with its parts made" }

local function outText(outBy)
  if type(outBy) == "number" then return "No figure: " .. NS.itemName(outBy) .. " runs out before these would be used." end
  return "No figure: another material runs out before these would be used."
end

-- Rows of the price list from the cuts: neighbouring cuts of one price line and one tone are one row.
--   { price, qty, run (units up to here), crafts (the crafts the running total covers, bags included), each, ph,
--     phHi, phLo, tone, part (the price line was cut), est, why }
-- then the marks: green = { units, price }, yellow = { units, price } (the furthest unit that still is that good).
local function rowsOfUse(J)
  local rows = {}
  local cur
  for _, cut in ipairs(J.cuts) do
    if cur and cur.price == cut.price and cur.tone == cut.tone then
      cur.qty = cur.qty + (cut.to - cut.from)
      if cut.each then
        cur.sum = cur.sum + cut.each * (cut.to - cut.from) / J.u
        cur.phLo = cut.ph
      end
    else
      local cutLine = cur ~= nil and cur.price == cut.price
      if cutLine then cur.part = true end
      cur = { price = cut.price, qty = cut.to - cut.from, tone = cut.tone, sum = cut.each and cut.each * (cut.to - cut.from) / J.u or nil,
        phHi = cut.ph, phLo = cut.ph, est = cut.est, part = cutLine or nil }
      if not cut.tone then cur.why = outText(J.outBy) end
      rows[#rows + 1] = cur
    end
    cur.run = cut.to
  end
  local marks = { green = { units = 0 }, yellow = { units = 0 } }
  local gOpen, yOpen = true, true
  for _, row in ipairs(rows) do
    row.crafts = floor((J.held + row.run) / J.u + 1e-9)
    if row.sum then
      row.each = row.sum / (row.qty / J.u)
      row.ph = row.each / J.secs * 3600
    end
    if gOpen and row.tone == "green" then marks.green = { units = row.run, price = row.price } else gOpen = false end
    if yOpen and (row.tone == "green" or row.tone == "yellow") then marks.yellow = { units = row.run, price = row.price } else yOpen = false end
  end
  return rows, marks
end

-- What `qty` units bought down the list cost and earn.
--   { qty, units (of them listed), short, cost, top (the dearest price reached), topTone, crafts (the crafts the
--     bought units add, bags used first), other (the other materials of those crafts), sales, profit, ph, secs,
--     tone, green / yellow / red / none (units of each kind), est }
local function sumUse(J, qty)
  local s = { qty = qty, units = 0, cost = 0, other = 0, sales = 0, profit = 0, crafts = 0, green = 0, yellow = 0, red = 0, none = 0, zero = 0 }
  for _, cut in ipairs(J.cuts) do
    local n = min(cut.to, qty) - cut.from
    if n <= 0 then break end
    s.units = s.units + n
    s.cost = s.cost + n * cut.price
    s.top, s.topTone = cut.price, cut.tone
    if cut.tone then
      local k = n / J.u
      s.crafts = s.crafts + k
      s.other = s.other + k * cut.ocost
      s.sales = s.sales + k * (cut.base + cut.ocost)
      s.profit = s.profit + k * cut.each
      s[cut.tone] = s[cut.tone] + n
      if cut.tone == "red" and cut.each >= -1e-9 then s.zero = s.zero + n end   -- no profit, but not a loss either
      if cut.est then s.est = true end
    else
      s.none = s.none + n
    end
  end
  s.short = qty - s.units
  s.secs = s.crafts * J.secs
  if s.crafts > 0 then
    s.ph = s.profit / s.secs * 3600
    s.tone = toneOf(s.profit / s.crafts, s.ph, J.floor)
  end
  return s
end

-- ---- the model: an item a recipe makes ---------------------------------------------------------------------------------

-- Buying the product against making it (the recipe's cost for one, at list prices, cheapest mix) and against
-- what a vendor pays for it.
--   rows: { price, qty, run, tone, vend (vendor value - price when that is a profit), make (making - price), text }
--   green: under vendor value (a sure profit of the difference), or cheaper than making it; red: dearer than
--   making it; yellow: the same as making it; no tone when Kebold cannot cost the recipe.
local function projectMake(c, r, lines)
  local ctx = c.ctx
  local x = ctx.info(r)
  local mk = ctx.makes(r)
  local J = { vendor = r.sell, makeEach = (x.cost ~= nil and mk > 0) and x.cost / mk or nil, rows = {},
    marks = { vendor = { units = 0 }, make = { units = 0 } } }
  local run, vOpen, mOpen = 0, true, true
  for _, line in ipairs(lines) do
    local p, q = line[1], line[2]
    run = run + q
    local row = { price = p, qty = q, run = run }
    if J.vendor and J.vendor > 0 and p < J.vendor then row.vend = J.vendor - p end
    if J.makeEach then row.make = J.makeEach - p end
    if row.vend then
      row.tone = "green"
      row.text = money(row.vend) .. " under what a vendor pays: a sure profit."
    elseif row.make and row.make > 0.5 then
      row.tone = "green"
      row.text = money(row.make) .. " cheaper than making it (" .. money(J.makeEach) .. " each)."
    elseif row.make and row.make < -0.5 then
      row.tone = "red"
      row.text = money(-row.make) .. " dearer than making it (" .. money(J.makeEach) .. " each)."
    elseif row.make then
      row.tone = "yellow"
      row.text = "The same as making it (" .. money(J.makeEach) .. " each)."
    else
      row.text = "Kebold cannot say what making it costs: a material has no price."
    end
    if vOpen and row.vend then J.marks.vendor = { units = run, price = p } else vOpen = false end
    if mOpen and (row.vend or (row.make and row.make > 0.5)) then J.marks.make = { units = run, price = p } else mOpen = false end
    J.rows[#J.rows + 1] = row
  end
  return J
end

--   { qty, units, short, cost, top, topTone, vendor (what a vendor pays for them all), sure (the profit of
--     selling the ones under vendor value to a vendor), sureUnits, making (what making them would cost), saved
--     (making - cost), dearer (units that cost more than making them) }
local function sumMake(J, qty)
  local s = { qty = qty, units = 0, cost = 0, sure = 0, sureUnits = 0, dearer = 0 }
  local from = 0
  for _, row in ipairs(J.rows) do
    local n = min(row.run, qty) - from
    if n <= 0 then break end
    s.units = s.units + n
    s.cost = s.cost + n * row.price
    s.top, s.topTone = row.price, row.tone
    if row.vend then
      s.sure = s.sure + n * row.vend
      s.sureUnits = s.sureUnits + n
    end
    if row.make and row.make < -0.5 then s.dearer = s.dearer + n end
    from = row.run
  end
  s.short = qty - s.units
  if J.vendor then s.vendor = s.units * J.vendor end
  if J.makeEach then
    s.making = s.units * J.makeEach
    s.saved = s.making - s.cost
  end
  return s
end

-- ---- the model -----------------------------------------------------------------------------------------------------------

-- NS.buyModel(itemID, lines, qty [, choice]) -> M, as the character himself (never a "Plan for" profile):
--   M.item, M.name, M.known (a recipe uses or makes it), M.lines (cleaned: { { price, qty }, ... }), M.listed,
--   M.held (in bags), M.floor (gold an hour), M.qty
--   M.choices (see choicesFor), M.choice (the one judged), M.kind = "use" | "make" | "none"
--   M.rows (the price list, see rowsOfUse / projectMake), M.marks, M.sum (for qty > 0; see sumUse / sumMake)
--   M.note (a sentence when the recipe cannot be judged), M.mode ("auto" | "buy" | "craft"), M.u (units a craft),
--   M.secs (seconds a craft)
-- lines: { { unit price, quantity }, ... } as the game listed them (any order). qty: the number typed, or nil.
-- choice: a key ("use:<recipe id>" / "make:<recipe id>"); nil = the one remembered for the item, else the default.
local function model(itemID, lines, qty, choice)
  local clean, listed = cleanLines(lines)
  local M = { item = itemID, name = NS.itemName(itemID), lines = clean, listed = listed, floor = floorGold(), kind = "none", rows = {},
    qty = (tonumber(qty) and tonumber(qty) > 0) and floor(tonumber(qty)) or nil }
  M.held = max(0, tonumber(NS.bagCount(itemID)) or 0)
  local list, def = choicesFor(itemID)
  M.choices, M.known = list, #list > 0
  local want = choice or chosen[itemID]
  local pick
  for _, e in ipairs(list) do
    if e.key == want then pick = e end
  end
  pick = pick or def
  M.choice = pick
  if not pick then
    for _, line in ipairs(clean) do
      local n = (M.rows[#M.rows] and M.rows[#M.rows].run or 0) + line[2]
      M.rows[#M.rows + 1] = { price = line[1], qty = line[2], run = n }
    end
    M.note = "No recipe Kebold knows uses or makes this."
    return M
  end
  local c = NS.state(pick.r.prof)
  M.kind = pick.kind
  if pick.kind == "use" then
    local J, why = projectUse(c, pick.r, itemID, clean, M.held)
    if not J then
      for _, line in ipairs(clean) do
        local n = (M.rows[#M.rows] and M.rows[#M.rows].run or 0) + line[2]
        M.rows[#M.rows + 1] = { price = line[1], qty = line[2], run = n, why = why }
      end
      M.note = why
      return M
    end
    M.rows, M.marks = rowsOfUse(J)
    M.mode, M.u, M.secs, M.outBy = J.mode, J.u, J.secs, J.outBy
    M.way = (isFn(c.ctx.modeCtx) and c.ctx.modeCtx(J.mode) or c.ctx).info(pick.r).way
    if M.qty then M.sum = sumUse(J, M.qty) end
  else
    local J = projectMake(c, pick.r, clean)
    M.rows, M.marks, M.vendor, M.makeEach = J.rows, J.marks, J.vendor, J.makeEach
    if M.qty then M.sum = sumMake(J, M.qty) end
  end
  return M
end

function NS.buyModel(itemID, lines, qty, choice)
  if isFn(NS.asMe) then return NS.asMe(model, itemID, lines, qty, choice) end
  return model(itemID, lines, qty, choice)
end

-- ---- print lines ---------------------------------------------------------------------------------------------------------

local function floorText(M)
  return money(M.floor * 10000) .. " an hour"
end

local function perHour(row)
  if not row.ph then return DIM .. "-|r" end
  return tint(row.tone, signedShort(row.ph)) .. (row.est and (DIM .. "~|r") or "")
end

-- The summary block (blk = "sum"): rows { left, right } and whole-width sentences.
local function sumRows(M)
  local out = {}
  local function add(left, right, extra)
    local row = { blk = "sum", left = left, right = right }
    for k, v in pairs(extra or {}) do row[k] = v end
    out[#out + 1] = row
    return row
  end
  if M.note then add(DIM .. M.note .. "|r", nil, { wide = true, tip = M.note }) end
  if M.kind == "use" and M.marks then
    local g, y = M.marks.green, M.marks.yellow
    if g.units > 0 then
      add("Buy up to", tint("green", whole(g.units) .. " at " .. money(g.price) .. " or less"), { mark = "green",
        tip = "Every unit up to here is made into crafts that earn " .. (M.floor > 0 and ("at least " .. floorText(M)) or "a profit") .. "." })
    elseif y.units > 0 then
      add(tint("yellow", "Nothing listed earns " .. floorText(M) .. "."), nil, { wide = true, mark = "green" })
    elseif #M.rows > 0 and M.rows[1].tone == "red" then
      -- the cheapest units earn the most: when they earn exactly nothing, "a loss" would not be true of them
      add(tint("red", (M.rows[1].each or -1) >= -1e-9 and "Nothing listed makes a profit." or "Every unit listed would be made at a loss."), nil, { wide = true, mark = "green" })
    end
    if y.units > g.units then
      add("A profit up to", tint("yellow", whole(y.units) .. " at " .. money(y.price) .. " or less"), { mark = "yellow",
        tip = "Past the green limit these still earn something, but less than " .. floorText(M) .. "." })
    end
    if M.held > 0 then add("In your bags", whole(M.held) .. DIM .. " (the crafts start from them)|r") end
    add(DIM .. "One craft uses|r", crafts(M.u) .. " of these" .. DIM .. (MODE_NOTE[M.mode] and (", " .. MODE_NOTE[M.mode]) or "") .. "|r")
  elseif M.kind == "make" then
    local v, m = M.marks.vendor, M.marks.make
    add("A vendor pays", M.vendor and (M.vendor > 0 and money(M.vendor) or (DIM .. "nothing|r")) or (DIM .. "?|r"))
    add("Making one costs", M.makeEach and money(M.makeEach) or (DIM .. "? (a material has no price)|r"))
    if v.units > 0 then
      add("Under vendor value", tint("green", whole(v.units) .. " at " .. money(v.price) .. " or less"), { mark = "green",
        tip = "Bought and sold to a vendor these make a sure profit." })
    end
    if m.units > v.units then
      add("Cheaper than making", tint("green", whole(m.units) .. " at " .. money(m.price) .. " or less"), { mark = "make" })
    elseif m.units == 0 and M.makeEach and #M.rows > 0 then
      add(tint("red", "Making it is cheaper than every listing."), nil, { wide = true, mark = "make" })
    end
  end
  local s = M.sum
  if not s then
    if M.kind ~= "none" and not M.note then add(DIM .. "Type a quantity to see what it costs and earns.|r", nil, { wide = true }) end
    return out
  end
  add(GOLD .. "For " .. whole(s.qty) .. "|r", nil, { wide = true, head = true })
  if s.units <= 0 then
    add(RED .. "None listed.|r", nil, { wide = true })
    return out
  end
  add("Cost", money(s.cost) .. DIM .. " (dearest |r" .. tint(s.topTone, money(s.top)) .. DIM .. ")|r", { fig = "cost" })
  if M.kind == "use" then
    if s.crafts > 0 then
      add("Covers", crafts(s.crafts) .. (s.crafts == 1 and " craft" or " crafts"), { fig = "crafts" })
      add("Other materials", money(s.other), { fig = "other" })
      add("Sells for", money(s.sales) .. DIM .. (isFn(NS.wayShort) and NS.wayShort(M.way) or "") .. "|r", { fig = "sales",
        tip = "By the plan's Sells at rule: at the auction house up to the AH sales cap, then at vendor value." })
      add("Profit", tint(s.tone, signedMoney(s.profit)) .. (s.est and (DIM .. "~|r") or ""), { fig = "profit" })
      add("Per hour", tint(s.tone, signedMoney(s.ph)), { fig = "ph" })
      add("Casting", timeText(s.secs), { fig = "secs" })
    end
    if s.red > 0 then add(tint("red", "The last " .. whole(s.red) .. ((s.zero or 0) > 0 and " make no profit." or " lose money.")), nil, { wide = true, warn = "red" }) end
    if s.yellow > 0 then
      add(tint("yellow", (s.red > 0 and "Before them " or "The last ") .. whole(s.yellow) .. " earn less than " .. floorText(M) .. "."), nil, { wide = true, warn = "yellow" })
    end
    if s.none > 0 then add(DIM .. whole(s.none) .. " have no figure: " .. (type(M.outBy) == "number" and NS.itemName(M.outBy) or "another material") .. " runs out.|r", nil, { wide = true, warn = "none" }) end
  else
    if s.vendor then add("A vendor pays", money(s.vendor), { fig = "vendor" }) end
    if s.sureUnits > 0 then add("Sure profit", tint("green", money(s.sure)) .. DIM .. " on " .. whole(s.sureUnits) .. "|r", { fig = "sure" }) end
    if s.making then
      add("Making them costs", money(s.making), { fig = "making" })
      add(s.saved >= 0 and "Buying saves" or "Buying costs more by", tint(s.saved >= 0 and "green" or "red", money(abs(s.saved))), { fig = "saved" })
    end
    if s.dearer > 0 then add(tint("red", "The last " .. whole(s.dearer) .. " cost more than making them."), nil, { wide = true, warn = "red" }) end
  end
  if s.short > 0 then
    add(tint("red", "Only " .. whole(s.units) .. " are listed: " .. whole(s.short) .. " short."), nil, { wide = true, warn = "short" })
  end
  return out
end

-- The price list (blk = "list"): the side panel's list, and what the marks on Blizzard's own rows are taken from:
--   rows { cols = { price, listed, running total, per hour | against making }, tone, tip, src } and marker lines
--   { wide, marker = tone, left (short: it must fit 220 px), tip (the whole sentence) } after the last green
--   (and the last yellow) step. Everything a cell has no room for is in the row's tip.
local function floorShort(M) return whole(M.floor) .. "g/h" end
local function listRows(M)
  local out = {}
  if M.scan then return out end   -- no item is being read: the summary's sentence says why
  if #M.rows == 0 then
    out[1] = { blk = "list", left = DIM .. "None listed.|r", wide = true }
    return out
  end
  local g = M.kind == "use" and M.marks and M.marks.green or nil
  local y = M.kind == "use" and M.marks and M.marks.yellow or nil
  if g and g.units == 0 and M.rows[1].tone then
    out[#out + 1] = { blk = "list", wide = true, marker = y.units > 0 and "yellow" or "red",   -- the tone of what it states
      left = tint(y.units > 0 and "yellow" or "red", y.units > 0 and ("Nothing here earns " .. floorShort(M)) or "Nothing here pays"),
      tip = y.units > 0 and ("No unit listed is made into crafts that earn " .. floorText(M) .. ".") or "No unit listed is made into a craft that makes a profit." }
  end
  for _, row in ipairs(M.rows) do
    local cols
    if M.kind == "make" then
      cols = { tint(row.tone, cmoney(row.price)), whole(row.qty), whole(row.run),
        row.make and tint(row.tone, (row.make >= 0 and "-" or "+") .. short1(row.make)) or (DIM .. (M.makeEach and "-" or "?") .. "|r") }
    else
      cols = { tint(row.tone, cmoney(row.price)), whole(row.qty), whole(row.run), perHour(row) }
    end
    local tip = row.text or row.why
    if not tip and not row.each and M.kind ~= "make" then   -- a row without a figure says why it has none
      tip = "No figure: " .. (M.note or "Kebold cannot say what crafts made from these earn.")
    end
    if not tip and row.each and row.tone == "red" and row.each >= -1e-9 then
      tip = "Crafts made from these make no profit: they earn exactly what they cost."
    elseif not tip and row.each then
      tip = "Crafts made from these earn " .. signedMoney(row.each) .. " each, " .. signedMoney(row.ph) .. " an hour"
        .. ((row.phHi and row.phLo and abs(row.phHi - row.phLo) > 1) and (" (" .. signedMoney(row.phHi) .. " down to " .. signedMoney(row.phLo) .. ")") or "") .. "."
        .. (row.est and " An estimate: the other materials' prices are taken to stay where the listings end." or "")
    end
    tip = whole(row.qty) .. " at " .. money(row.price) .. " each, " .. whole(row.run) .. " so far"
      .. (row.crafts and (": enough for " .. whole(row.crafts) .. (row.crafts == 1 and " craft" or " crafts")) or "") .. "."
      .. (tip and (" " .. tip) or "")
    out[#out + 1] = { blk = "list", cols = cols, tone = row.tone, tip = tip, src = row }
    if g and g.units > 0 and row.run == g.units and row.tone == "green" then
      out[#out + 1] = { blk = "list", wide = true, marker = "green", left = tint("green", "Buy up to " .. whole(g.units)),
        tip = "Buy up to " .. whole(g.units) .. " at " .. money(g.price) .. " or less: every unit up to here is made into crafts that earn "
          .. (M.floor > 0 and ("at least " .. floorText(M)) or "a profit") .. "." }
    end
    if y and y.units > (g and g.units or 0) and row.run == y.units and row.tone == "yellow" then
      out[#out + 1] = { blk = "list", wide = true, marker = "yellow",
        left = tint("yellow", "Profit up to " .. whole(y.units) .. ", under " .. floorShort(M)),
        tip = "A profit up to " .. whole(y.units) .. " at " .. money(y.price) .. " or less, but under " .. floorText(M) .. "." }
    end
  end
  return out
end
NS.buyListRows = listRows

-- The lines under Blizzard's Buy button, as plain data (the Craft line, the recipe's dropdown, is the frame's):
--   { profit  = { label, value, tip } | false     "Profit": what the quantity typed earns, in its tone, then dimmer
--                                                  "(19g 68s an hour)"; for a product "Against making"; or a dim
--                                                  word when no quantity is typed or the box cannot be read
--     verdict = { label, value, tone, tip } | { value, wide = true, tone = false, tip } | false
--                                                  "Buy up to": "913 at 6s or less" (green); "Profit up to": "500 at
--                                                  3s, under 10g/h" (yellow, when nothing is green); "Buy up to":
--                                                  "none: every unit is a loss" (red); or ONE sentence across the
--                                                  block (wide): a scan is running, no recipe, no figure
--     warn    = { text, tip, level, n } | false }  the worst warning; the others are in its tip
-- Cost is not repeated: it is Blizzard's own Total Price. Casting time, the crafts covered, what the products
-- sell for and the other materials are in the Profit line's tooltip.
-- qtyRead: true = the number was read from Blizzard's box, false = the box could not be read, nil = no box is
-- looked at (a scan). A tip is a list of lines (the first is its title).
local WARN_ORDER = { red = 1, short = 2, yellow = 3, none = 4 }
-- dim text that may hold coins: money() ends each coin letter with "|r", which would end the dimming too
local function dim(text)
  return DIM .. tostring(text):gsub("|r", "|r" .. DIM) .. "|r"
end
local function summaryOf(M, qtyRead)
  local out = { profit = false, verdict = false, warn = false }
  local warns = {}
  local function V(label, tone, value, tip)
    out.verdict = { label = label, value = tint(tone, value), tone = tone, tip = tip, wide = false }
  end
  local function W(level, text) warns[#warns + 1] = { level = level, text = text } end
  if M.kind == "use" and M.marks then
    local g, y = M.marks.green, M.marks.yellow
    local under = whole(y.units) .. " at " .. cmoney(y.price or 0) .. ", under " .. floorShort(M)
    if g.units > 0 then
      V("Buy up to", "green", whole(g.units) .. " at " .. cmoney(g.price) .. " or less",
        { "Buy up to " .. whole(g.units) .. " at " .. money(g.price) .. " or less",
          "Every unit up to here is made into crafts that earn " .. (M.floor > 0 and ("at least " .. floorText(M)) or "a profit") .. "." })
      if y.units > g.units then
        local t = out.verdict.tip
        t[#t + 1] = tint("yellow", "Profit up to " .. under)
        t[#t + 1] = "Past the green limit these still earn something, but less than " .. floorText(M) .. "."
      end
    elseif y.units > 0 then
      V("Profit up to", "yellow", under, { "Profit up to " .. whole(y.units) .. " at " .. money(y.price) .. " or less",
        "No unit listed is made into crafts that earn " .. floorText(M) .. ".", "Up to here they still make a profit." })
    elseif #M.rows > 0 and M.rows[1].tone == "red" then
      -- the cheapest units earn the most: when they earn exactly nothing, "a loss" would not be true of them
      local zero = (M.rows[1].each or -1) >= -1e-9
      V("Buy up to", "red", zero and "none: nothing makes a profit" or "none: every unit is a loss",
        { zero and "Nothing listed makes a profit" or "Every unit listed is a loss", "The cheapest units earn the most, and they do not pay." })
    end
    if out.verdict then
      local t = out.verdict.tip
      if M.held > 0 then t[#t + 1] = "In your bags: " .. whole(M.held) .. " (the crafts start from them)." end
      t[#t + 1] = "One craft uses " .. crafts(M.u) .. " of these" .. (MODE_NOTE[M.mode] and (", " .. MODE_NOTE[M.mode]) or "") .. "."
      t[#t + 1] = "Worth above: " .. floorText(M) .. " (change it in the Craft menu)."
    end
  elseif M.kind == "make" and M.marks then
    local v, m = M.marks.vendor, M.marks.make
    local facts = { "A vendor pays " .. (M.vendor and money(M.vendor) or "?") .. " for one.",
      M.makeEach and ("Making one costs " .. money(M.makeEach) .. ", at list prices.") or "What making one costs is not known: a material has no price." }
    if v.units > 0 then
      V("Buy up to", "green", whole(v.units) .. " at " .. cmoney(v.price) .. ": under vendor value",
        { "Under vendor value: " .. whole(v.units) .. " at " .. money(v.price) .. " or less", "Bought and sold to a vendor these make a sure profit." })
      if m.units > v.units then
        local t = out.verdict.tip
        t[#t + 1] = tint("green", "Cheaper to buy than to make: " .. whole(m.units) .. " at " .. cmoney(m.price) .. " or less")
      end
    elseif m.units > 0 then
      V("Buy up to", "green", whole(m.units) .. " at " .. cmoney(m.price) .. ": cheaper than making",
        { "Cheaper to buy: " .. whole(m.units) .. " at " .. money(m.price) .. " or less", "Up to here a listing costs less than making the item yourself." })
    elseif M.makeEach and #M.rows > 0 then
      V("Buy up to", "red", "none: making it is cheaper", { "Making it is cheaper than every listing." })
    end
    if out.verdict then
      for _, line in ipairs(facts) do out.verdict.tip[#out.verdict.tip + 1] = line end
    end
  end
  if M.note and not out.verdict then   -- a scan is running, no recipe, no figure
    out.verdict = { label = false, value = DIM .. M.note .. "|r", tone = false, tip = { M.note }, wide = true }
  end
  local s = M.sum
  local function P(label, value, tip) out.profit = { label = label, value = value, tip = tip } end
  local label = M.kind == "make" and "Against making" or "Profit"
  if qtyRead == false then
    P(label, DIM .. "quantity not read|r", { "Kebold could not read Blizzard's Quantity box.", "/keboldah buy probe says what it found." })
  elseif not s then
    if qtyRead == true and M.kind ~= "none" and not M.note then
      P(label, DIM .. "type a quantity|r", { "Type a number into Blizzard's Quantity box to see what it earns." })
    end
  elseif s.units <= 0 then
    P(label, RED .. "none listed|r", { "Nothing is listed." })
  else
    local tip = { "For " .. whole(s.qty) .. ": " .. money(s.cost) .. ", the dearest at " .. money(s.top) }
    if M.kind == "use" then
      if s.crafts > 0 then
        tip[#tip + 1] = "Covers " .. crafts(s.crafts) .. (s.crafts == 1 and " craft" or " crafts") .. ": " .. timeText(s.secs) .. " of casting ("
          .. string.format("%.1f", M.secs or 0) .. " s each)."
        tip[#tip + 1] = "Sells for " .. money(s.sales) .. (isFn(NS.wayShort) and NS.wayShort(M.way) or "") .. "."
        tip[#tip + 1] = "By the plan's Sells at rule: at the auction house up to the AH sales cap, then at vendor value."
        tip[#tip + 1] = "Less these: " .. money(s.cost) .. ", other materials: " .. money(s.other) .. "."
        tip[#tip + 1] = "One craft uses " .. crafts(M.u) .. " of these" .. (MODE_NOTE[M.mode] and (", " .. MODE_NOTE[M.mode]) or "") .. "."
        tip[#tip + 1] = "Green from " .. floorText(M) .. " (Worth above, in the Craft menu)."
        P(label, tint(s.tone, signedC(s.profit)) .. (s.est and (DIM .. "~|r") or "") .. dim("  (" .. signedC(s.ph) .. " an hour)"), tip)
      else
        tip[#tip + 1] = outText(M.outBy)
        P(label, DIM .. "-|r", tip)
      end
      if s.red > 0 then W("red", tint("red", "The last " .. whole(s.red) .. ((s.zero or 0) > 0 and " make no profit." or " lose money."))) end
      if s.yellow > 0 then
        W("yellow", tint("yellow", (s.red > 0 and "Before them " or "The last ") .. whole(s.yellow) .. " earn less than " .. floorShort(M) .. "."))
      end
      if s.none > 0 then W("none", DIM .. whole(s.none) .. " have no figure: " .. (type(M.outBy) == "number" and NS.itemName(M.outBy) or "another material") .. " runs out.|r") end
    else
      if s.vendor then tip[#tip + 1] = "A vendor pays " .. money(s.vendor) .. " for them." end
      if s.sureUnits > 0 then tip[#tip + 1] = "Sure profit: " .. money(s.sure) .. " on " .. whole(s.sureUnits) .. " sold to a vendor." end
      if s.making then
        tip[#tip + 1] = "Making them costs " .. money(s.making) .. "."
        P(label, tint(s.saved >= 0 and "green" or "red", (s.saved >= 0 and "saves " or "dearer by ") .. cmoney(abs(s.saved))), tip)
      else
        tip[#tip + 1] = "What making them costs is not known: a material has no price."
        P(label, DIM .. "?|r", tip)
      end
      if s.dearer > 0 then W("red", tint("red", "The last " .. whole(s.dearer) .. " cost more than making them.")) end
    end
    if s.short > 0 then W("short", tint("red", "Only " .. whole(s.units) .. " are listed: " .. whole(s.short) .. " short.")) end
  end
  table.sort(warns, function(a, b) return WARN_ORDER[a.level] < WARN_ORDER[b.level] end)
  if warns[1] then
    local tip = {}
    for i, w in ipairs(warns) do tip[i] = w.text end
    out.warn = { text = warns[1].text, level = warns[1].level, tip = tip, n = #warns }
  end
  return out
end
NS.buySummary = summaryOf

function NS.buyModelRows(M)
  local out = sumRows(M)
  for _, row in ipairs(listRows(M)) do out[#out + 1] = row end
  return out
end

-- ---- what the player is looking at -------------------------------------------------------------------------------------

local ahOpen = false
local cur = nil            -- { item, kind = "commodity" | "item", lines, listed, full, stamp, saved }, or while a
                           -- Kebold scan answers: { scan = true, lines = {}, listed = 0, stamp } (no item)
local stamp = 0
local sessionOff = false   -- the panel's own x: hidden until it is switched on again
local ownQty = 0           -- the panel's own Quantity box, when Blizzard's cannot be read
local frame, lastModel, lastSig = nil, nil, nil

local function api()
  return isTable(C_AuctionHouse) and C_AuctionHouse or nil
end

local function busy()
  return isFn(KeboldsShinyScan_Busy) and KeboldsShinyScan_Busy() and true or false
end

-- A result for an item of a Kebold scan that ended this very second is the scan's last answer, not the player's.
local function scansAnswer(itemID)
  local run = isFn(KeboldsShinyScan_Last) and KeboldsShinyScan_Last() or nil
  if not (isTable(run) and isTable(run.state) and run.state[itemID] ~= nil) then return false end
  if run.running == true then return true end
  local done = isTable(KeboldsShinyDB) and isTable(KeboldsShinyDB.lastScan) and tonumber(KeboldsShinyDB.lastScan.time) or nil
  return done ~= nil and isFn(time) and time() - done <= 1
end

local function readCommodity(itemID)
  local A = api()
  if not (A and isFn(A.GetNumCommoditySearchResults) and isFn(A.GetCommoditySearchResultInfo)) then return nil end
  local ok, n = pcall(A.GetNumCommoditySearchResults, itemID)
  n = ok and tonumber(n) or 0
  local lines = {}
  for i = 1, n do
    local ok2, r = pcall(A.GetCommoditySearchResultInfo, itemID, i)
    if ok2 and isTable(r) and tonumber(r.unitPrice) and tonumber(r.quantity) and r.quantity > 0 then
      lines[#lines + 1] = { r.unitPrice, r.quantity }
    end
  end
  local full = n == 0
  if not full and isFn(A.HasFullCommoditySearchResults) then
    local ok3, f = pcall(A.HasFullCommoditySearchResults, itemID)
    full = ok3 and f and true or false
  end
  return lines, full
end

local function readItems(itemKey)
  local A = api()
  if not (A and isFn(A.GetNumItemSearchResults) and isFn(A.GetItemSearchResultInfo)) then return nil end
  local ok, n = pcall(A.GetNumItemSearchResults, itemKey)
  n = ok and tonumber(n) or 0
  local lines = {}
  for i = 1, n do
    local ok2, r = pcall(A.GetItemSearchResultInfo, itemKey, i)
    local qty = ok2 and isTable(r) and tonumber(r.quantity) or 0
    -- An auction with no buyout has no price anyone can simply pay. A row is `quantity` identical auctions that
    -- each cost `buyoutAmount` (Blizzard's own window shows the buyout undivided beside the quantity), so the
    -- price is not divided by the quantity.
    -- not seen in game: check with /keboldscan debug <id> on an item one seller listed several times
    if qty > 0 and tonumber(r.buyoutAmount) and r.buyoutAmount > 0 then
      lines[#lines + 1] = { r.buyoutAmount, qty }
    end
  end
  local full = n == 0
  if not full and isFn(A.HasFullItemSearchResults) then
    local ok3, f = pcall(A.HasFullItemSearchResults, itemKey)
    full = ok3 and f and true or false
  end
  return lines, full
end

local update, screenItem   -- defined below

-- The number listed in the item's stored reading when that reading is today's, else nil.
local function storedToday(itemID)
  if not isFn(KeboldsShinyScan_Reading) then return nil end
  local ok, day, total, now = pcall(KeboldsShinyScan_Reading, itemID)
  if ok and day ~= nil and day == now then return tonumber(total) or 0 end
  return nil
end

-- May these lines replace the item's stored reading?
--   * a commodity's complete list always may (no line at all is a true "none listed");
--   * a list the client holds only in part (HasFull... false) may not replace a fuller reading of today;
--   * an item's auctions are read for ONE item key (one suffix, one item level) but stored under the item id, as
--     a scan's reading that merged every variant is: no line at all is never saved, and a reading of today with
--     more units is kept.
local function maySave(kind, itemID, listed, full)
  if kind == "item" then
    if listed <= 0 then return false end
  elseif full then
    return true
  end
  local had = storedToday(itemID)
  return not (had ~= nil and had > listed)
end

-- The client has results for an item the player opened: keep them, save them as the item's reading, repaint.
local function onResults(kind, itemID, key)
  if type(itemID) ~= "number" or itemID <= 0 then return end
  if busy() then
    -- A Kebold scan's results are its own, and nothing tells them from a search of the player's: the panel stops
    -- showing an item (the one opened before the scan is not the one on screen any more) and says so.
    if not (cur and cur.scan == true) then
      stamp = stamp + 1
      cur = { scan = true, lines = {}, listed = 0, stamp = stamp, saved = false }
    end
    update()
    return
  end
  if scansAnswer(itemID) then return end
  local lines, full
  if kind == "commodity" then lines, full = readCommodity(itemID) else lines, full = readItems(key) end
  if not lines then return end
  local clean, listed = cleanLines(lines)
  local saved = false
  if NS.buyKnows(itemID) and isFn(KeboldsShinyScan_SaveLadder) and maySave(kind, itemID, listed, full) then
    local ok, did, changed = pcall(KeboldsShinyScan_SaveLadder, itemID, clean)
    saved = ok and did == true
    if saved and changed == true then
      NS.bump()   -- every page of Kebold prices the item from these lines now
      if isFn(NS.refreshSoon) then pcall(NS.refreshSoon, 0.5) end
    end
  end
  -- Results for another item than the one Blizzard's buy screen shows (another addon's search, a late answer)
  -- are a reading, saved above, but not what the player is looking at. Where the screen's item cannot be read
  -- every result counts as the item on screen, as before.
  local on = screenItem()
  if on ~= nil and on ~= itemID then return end
  stamp = stamp + 1
  cur = { item = itemID, kind = kind, lines = clean, listed = listed, full = full, stamp = stamp, saved = saved }
  update()
end

-- ---- reading Blizzard's window (never writing to it) --------------------------------------------------------------------

local function ahFrame()
  return isTable(AuctionHouseFrame) and AuctionHouseFrame or nil
end

local function shownFrame(f)
  if not isTable(f) or not isFn(f.IsShown) then return nil end
  local ok, v = pcall(f.IsShown, f)
  if not ok then return nil end
  return v == true
end

-- Which buy screen shows: "commodity", "item", false (neither: another tab, or the browse list), or nil when
-- the client gives nothing to tell by. None of these frame fields is confirmed on Forever.
local function viewing()
  local ah = ahFrame()
  if not ah then return nil end
  local cb, ib = ah.CommoditiesBuyFrame, ah.ItemBuyFrame
  local c, i = shownFrame(cb), shownFrame(ib)
  if c == true then return "commodity" end
  if i == true then return "item" end
  if c ~= nil or i ~= nil then return false end
  local modes, mode = AuctionHouseFrameDisplayMode, ah.displayMode
  if isTable(modes) and isTable(mode) then
    if mode == modes.CommoditiesBuy then return "commodity" end
    if mode == modes.ItemBuy then return "item" end
    return false
  end
  return nil
end

-- The number in Blizzard's Quantity box of the commodity buy screen, or nil when it cannot be read. Getters
-- only; each shape is tried in turn:
--   1. <holder>.QuantityInput:GetQuantity()
--   2. <holder>.QuantityInput.InputBox:GetNumber()
--   3. <holder>.QuantityInput.InputBox:GetText()  (as a number)
-- where <holder> is AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay, else the CommoditiesBuyFrame itself.
local function quantityOf()
  local ah = ahFrame()
  local cb = ah and ah.CommoditiesBuyFrame
  if not isTable(cb) or shownFrame(cb) == false then return nil end
  for _, holder in ipairs({ isTable(cb.BuyDisplay) and cb.BuyDisplay or false, cb }) do
    local qi = isTable(holder) and holder.QuantityInput or nil
    if isTable(qi) then
      if isFn(qi.GetQuantity) then
        local ok, v = pcall(qi.GetQuantity, qi)
        if ok and tonumber(v) then return max(0, floor(tonumber(v))), "GetQuantity" end
      end
      local box = qi.InputBox
      if isTable(box) then
        if isFn(box.GetNumber) then
          local ok, v = pcall(box.GetNumber, box)
          if ok and tonumber(v) then return max(0, floor(tonumber(v))), "GetNumber" end
        end
        if isFn(box.GetText) then
          local ok, v = pcall(box.GetText, box)
          if ok and tonumber(v) then return max(0, floor(tonumber(v))), "GetText" end
        end
      end
    end
  end
  return nil
end
NS.buyQuantityOf = quantityOf

-- The item Blizzard's buy screen itself shows, or nil when it cannot be read. Getters only, each probed, from
-- Blizzard's own auction house UI source: the commodity buy display has GetItemID() and the item buy frame
-- GetItemKey(); both hold an ItemDisplay with GetItemID() / GetItemKey(). None is confirmed on Forever.
local function idFrom(o)
  if not isTable(o) then return nil end
  if isFn(o.GetItemID) then
    local ok, v = pcall(o.GetItemID, o)
    if ok and type(v) == "number" and v > 0 then return v, "GetItemID" end
  end
  if isFn(o.GetItemKey) then
    local ok, k = pcall(o.GetItemKey, o)
    if ok and isTable(k) and type(k.itemID) == "number" and k.itemID > 0 then return k.itemID, "GetItemKey" end
  end
  return nil
end
-- -> item id, how it was read ("CommoditiesBuyFrame.BuyDisplay:GetItemID()")
function screenItem()
  local ah = ahFrame()
  if not ah then return nil end
  local v = viewing()
  local f, name
  if v == "commodity" then f, name = ah.CommoditiesBuyFrame, "CommoditiesBuyFrame" elseif v == "item" then f, name = ah.ItemBuyFrame, "ItemBuyFrame" end
  if not isTable(f) then return nil end
  local d = isTable(f.BuyDisplay) and f.BuyDisplay or nil
  for _, c in ipairs({ { d, ".BuyDisplay" }, { f, "" }, { d and d.ItemDisplay, ".BuyDisplay.ItemDisplay" }, { f.ItemDisplay, ".ItemDisplay" } }) do
    local id, by = idFrom(c[1])
    if id then return id, name .. c[2] .. ":" .. by .. "()" end
  end
  return nil
end
NS.buyScreenItem = screenItem

-- ---- finding Blizzard's frames to draw on (type() and pcall only; nothing of theirs is changed) ----------------------
-- From Blizzard's own auction house UI source (AuctionHouseCommoditiesBuyFrameTemplate): the commodity buy frame
-- holds BuyDisplay (the left box: item, Quantity, prices, Buy button, laid out in a column from the top) and, to
-- its right, ItemList (HeaderContainer, ScrollBox = the rows, ScrollBar). The item buy frame has no such left
-- box. None of this is confirmed on Forever. (The price rows are found further down: findRows.)

-- a frame: a table that answers IsShown and GetWidth
local function answers(f)
  if not isTable(f) or not isFn(f.IsShown) or not isFn(f.GetWidth) then return false end
  local ok1 = pcall(f.IsShown, f)
  local ok2 = pcall(f.GetWidth, f)
  return ok1 and ok2
end
local function sizeOf(f)
  local w, h
  if isTable(f) then
    if isFn(f.GetWidth) then
      local ok, v = pcall(f.GetWidth, f)
      if ok and type(v) == "number" then w = v end
    end
    if isFn(f.GetHeight) then
      local ok, v = pcall(f.GetHeight, f)
      if ok and type(v) == "number" then h = v end
    end
  end
  return w, h
end

-- The box Kebold's lines go into: the commodity screen's BuyDisplay, else the CommoditiesBuyFrame itself.
--   -> frame, how
local function findDisplay()
  local ah = ahFrame()
  local cb = ah and ah.CommoditiesBuyFrame
  if not isTable(cb) then return nil end
  if answers(cb.BuyDisplay) then return cb.BuyDisplay, "CommoditiesBuyFrame.BuyDisplay" end
  if answers(cb) then return cb, "CommoditiesBuyFrame" end
  return nil
end

-- Where the helper draws: "page" (second value: the buy display) or "side" (why: "set" by the player, or
-- "nodisplay": Blizzard's buy display was not found, so there is no page to write on).
local function whereNow()
  if buySet().where == "side" then return "side", nil, "set" end
  local D = findDisplay()
  if not D then return "side", nil, "nodisplay" end
  return "page", D
end

-- Should the panel show now, and for which reading?
local function wanted()
  if not ahOpen or sessionOff or not buySet().on or not cur then return false end
  local ah = ahFrame()
  if not ah or shownFrame(ah) == false then return false end
  if isFn(NS.ahShown) and NS.ahShown() then return false end   -- Kebold's own tab lies over the Buy tab
  local v = viewing()
  if v == false then return false end
  if v ~= nil and cur.scan ~= true and v ~= cur.kind then return false end
  return true
end

-- ---- the panel -----------------------------------------------------------------------------------------------------------

-- the same four columns as the rows over Blizzard's list; fixed: stated for the larger font already
local LIST_COLS = {
  { key = "price", title = "Price", width = 62, align = "RIGHT", fixed = true },
  { key = "qty", title = "Listed", width = BUY.colListed, align = "RIGHT", fixed = true },
  { key = "run", title = "Total", width = BUY.colTotal, align = "RIGHT", fixed = true },
  { key = "ph", title = "Per hour", width = BUY.colLast, align = "RIGHT", fixed = true },
}
local SUM_COLS = {
  { key = "left", title = "", min = 90, flex = 1 },
  { key = "right", title = "", width = 130, align = "RIGHT" },
}

local bars = setmetatable({}, { __mode = "k" })   -- [a line of the price list] = its colour bar (ours, on our own line)

local function dress(t)
  for _, line in ipairs(t.lines) do
    local row = rawget(line, "row")
    local bar = bars[line]
    local tone = isTable(row) and (row.tone or row.marker or (isTable(row.cols) and "none")) or nil
    local rgb = tone and TONE_RGB[tone] or nil
    if rgb and line:IsShown() then
      if not bar then
        bar = line:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("TOPLEFT", 2, -1)
        bar:SetPoint("BOTTOMLEFT", 2, 1)
        bar:SetWidth(BUY.bar)
        bars[line] = bar
      end
      bar:SetColorTexture(rgb[1], rgb[2], rgb[3], (tone == "none" and 0.6) or (isTable(row) and row.marker and 0.45) or 1)
      bar.tone = tone
      bar:Show()
    elseif bar then
      bar.tone = false
      bar:Hide()
    end
  end
end

local function tipOf(line)
  local row = rawget(line, "row")
  if not (isTable(row) and row.tip) or not isTable(GameTooltip) then return end
  pcall(function()
    GameTooltip:SetOwner(line, UI.tipAnchor and UI.tipAnchor(line) or "ANCHOR_RIGHT")
    GameTooltip:AddLine(UI.show(row.tip), 1, 1, 1, true)
    GameTooltip:Show()
  end)
end
local function tipHide()
  if isTable(GameTooltip) and isFn(GameTooltip.Hide) then pcall(GameTooltip.Hide, GameTooltip) end
end

local function place(f, ah)
  if f.ahParent ~= ah then
    pcall(f.SetParent, f, ah)
    f.ahParent = ah
  end
  -- Outside the window's right edge. While the Kebold window is docked there and its dock has not been taught
  -- about this panel (NS.dockKnowsBuy), the panel goes to the left edge instead of under the window.
  local left = isFn(NS.isDocked) and NS.isDocked() and NS.dockKnowsBuy ~= true and isFn(NS.frame) and isTable(NS.frame()) and NS.frame():IsShown()
  f.side = left and "left" or "right"
  f:ClearAllPoints()
  if left then
    f:SetPoint("TOPRIGHT", ah, "TOPLEFT", -BUY.gap, 0)
    f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMLEFT", -BUY.gap, 0)
  else
    f:SetPoint("TOPLEFT", ah, "TOPRIGHT", BUY.gap, 0)
    f:SetPoint("BOTTOMLEFT", ah, "BOTTOMRIGHT", BUY.gap, 0)
  end
  f:SetWidth(BUY.w)
  local lvl = isFn(ah.GetFrameLevel) and tonumber((ah:GetFrameLevel())) or 1
  pcall(f.SetFrameLevel, f, lvl + BUY.level)
  local h = isFn(ah.GetHeight) and tonumber((ah:GetHeight())) or 0
  if h < 300 then h = 505 end
  f.h = h
end

local function layout(f)
  local w = BUY.w - 16
  local y = -30
  f.choice:ClearAllPoints()
  f.choice:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y)
  y = y - 26
  f.floorLabel:ClearAllPoints()
  f.floorLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y - 4)
  f.floor:ClearAllPoints()
  f.floor:SetPoint("TOPLEFT", f, "TOPLEFT", 10 + UI.textWidth("Worth above", UI.ctlFonts().text) + 6, y)
  f.floorUnit:ClearAllPoints()
  f.floorUnit:SetPoint("LEFT", f.floor, "RIGHT", 6, 0)
  y = y - 26
  if f.ownQty == true then
    f.qtyLabel:ClearAllPoints()
    f.qtyLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y - 4)
    f.qtyBox:ClearAllPoints()
    f.qtyBox:SetPoint("TOPLEFT", f, "TOPLEFT", 10 + UI.textWidth("Quantity", UI.ctlFonts().text) + 12, y)
    f.qtyLabel:Show()
    f.qtyBox:Show()
    y = y - 26
  else
    f.qtyLabel:Hide()
    f.qtyBox:Hide()
  end
  local sumH = min(max(1, f.sumN), BUY.sumMax) * BUY.rowH + 8
  f.sum:ClearAllPoints()
  f.sum:SetPoint("TOPLEFT", f, "TOPLEFT", 8, y)
  f.sum:Layout(w, sumH)
  y = y - sumH - 4
  f.list:ClearAllPoints()
  f.list:SetPoint("TOPLEFT", f, "TOPLEFT", 8, y)
  f.list:Layout(w, max(60, f.h + y - 8))
end

local FLOOR_TIP = "Gold an hour. Green: the crafts earn at least this. Yellow: a profit, but less. Red: no profit, or a loss. Only the buy helper uses the number."

-- The recipe dropdown: the recipe the price lines are judged for. The side panel's is captioned "For"; the
-- page's has its label drawn by the page ("Craft") and, withFloor, also carries the "Worth above" choices, so the
-- page needs no stepper: 0, 5, 10, 20, 50 g an hour, the one set ticked (any other value set with NS.buyFloor or
-- /keboldah buy floor is listed too).
local function recipeChoice(parent, minW, maxW, caption, withFloor)
  return UI.choice(parent, caption or "For", function()
    local out = {}
    for _, e in ipairs(lastModel and lastModel.choices or {}) do out[#out + 1] = e.text end
    if #out == 0 then out[1] = "no recipe" end
    return out
  end, function()
    return lastModel and lastModel.choice and lastModel.choice.text or "no recipe"
  end, function()
    local items = { { title = true, text = "Judge this item for" } }
    local makes = false
    for _, e in ipairs(lastModel and lastModel.choices or {}) do
      if e.kind == "make" and not makes then
        makes = true
        if #items > 1 then items[#items + 1] = { divider = true } end
      end
      items[#items + 1] = { radio = true, checked = lastModel.choice == e, text = e.menu, func = function() NS.buyChoose(e.key) end }
    end
    if #items == 1 then items[#items + 1] = { text = DIM .. "no recipe Kebold knows uses or makes this|r", disabled = true } end
    if withFloor then
      local now, list, has = floorGold(), {}, false
      for _, v in ipairs(BUY.floors) do
        list[#list + 1] = v
        if v == now then has = true end
      end
      if not has then
        list[#list + 1] = now
        table.sort(list)
      end
      items[#items + 1] = { divider = true }
      items[#items + 1] = { title = true, text = "Green from (gold an hour)" }
      for _, v in ipairs(list) do
        items[#items + 1] = { radio = true, checked = v == now, floor = v, text = "Worth above: " .. whole(v) .. " g/h", tip = FLOOR_TIP,
          func = function()
            setFloor(v)
            update(true)
          end }
      end
    end
    return items
  end, "The recipe the price lines are judged for: what its crafts earn when the item is bought at each price.", minW, maxW)
end

local function build(ah)
  local f = UI.window("KeboldsShinyBuyPanel", ah, BUY.w, 505, { noPortrait = true, top = 26, bottom = 6, left = 6, right = 6 })
  f.ahParent, f.side, f.h, f.sumN, f.ownQty, f.kind = false, "right", 505, 1, false, false
  f:Hide()
  f:EnableMouse(true)
  f.close:SetScript("OnClick", function()
    sessionOff = true   -- for this session; the Kebold button's menu and /keboldah buy on bring it back
    f:Hide()
    if isFn(NS.onBuyPanel) then pcall(NS.onBuyPanel, false) end
  end)
  UI.tip(f.close, "Hides the buy helper until you switch it on again: right-click the Kebold button, or /keboldah buy on.")
  f.choice = recipeChoice(f, 120, BUY.w - 60)
  f.floorLabel = UI.text(f, "body", "Worth above")
  f.floor = UI.stepper(f, { min = 0, max = 500, step = 5, w = 40,
    tip = FLOOR_TIP },
    floorGold, function(v)
      setFloor(v)
      update(true)
    end)
  f.floorUnit = UI.text(f, "dim", "g an hour")
  f.qtyLabel = UI.text(f, "body", "Quantity")
  f.qtyBox = UI.edit(f, 60, true)
  f.qtyBox:SetScript("OnTextChanged", function(self)
    ownQty = max(0, floor(tonumber(self:GetText()) or 0))
    update()
  end)
  f.sum = UI.table(f, SUM_COLS, { header = false, rowH = BUY.rowH, onEnter = tipOf, onLeave = tipHide })
  f.list = UI.table(f, LIST_COLS, { rowH = BUY.rowH, onEnter = tipOf, onLeave = tipHide })
  local paint = f.list.Paint
  f.list.Paint = function(self)   -- our own table: the colour bars follow every repaint (a scroll too)
    paint(self)
    dress(self)
  end
  return f
end

local function paint(M, own)
  local f = frame
  lastModel = M
  f.title:SetText(M.name)
  f.choice:Fit()
  f.choice:Refresh()
  f.floor:Refresh()
  local sums, list = sumRows(M), listRows(M)
  f.sumN, f.ownQty = #sums, own and true or false
  local kind = M.kind == "make" and "make" or "use"
  if f.kind ~= kind then   -- the last head says what the column holds
    f.kind = kind
    f.list:SetHeadText(4, kind == "make" and "Making" or "Per hour")
  end
  layout(f)
  f.sum:SetRows(sums)
  f.list:SetRows(list)
end

-- What the panel shows while (and after) a Kebold scan took the results: no item, one sentence.
local function scanModel()
  return { scan = true, name = "Kebold's Shiny", kind = "none", rows = {}, choices = {}, lines = {}, listed = 0, held = 0, floor = floorGold(),
    note = busy() and "A Kebold scan is running: prices are not read here until it ends."
      or "The Kebold scan has ended. Open the item again to read its prices." }
end

-- What decides the default recipe beside the selected one: the favourites among the item's recipes and the step
-- each of their professions' started plans is at. Neither moves NS.version().
local function pinKey(item)
  local s = slotOf(item)
  if not s then return "" end
  local S = settings()
  local out, steps = {}, {}
  for _, list in ipairs({ s.use, s.make }) do
    for _, r in ipairs(list) do
      if steps[r.prof] == nil then
        steps[r.prof] = stepRecipe(r.prof) or false
        if steps[r.prof] then out[#out + 1] = "s" .. tostring(steps[r.prof]) end
      end
      if isTable(S.fav) and S.fav[r.id] == true then out[#out + 1] = "f" .. tostring(r.id) end
    end
  end
  return table.concat(out, ",")
end
local function heldAndPins(item)
  return NS.bagCount(item), pinKey(item)
end

-- ---- on Blizzard's own page: marks on its price rows, lines under its Buy button ----------------------------------------
-- S.buy.where = "page". Nothing of Blizzard's is covered, hidden, moved, sized or re-anchored, and no field is
-- written onto its tables. Kebold only ADDS frames of its own:
--   * per visible row of the commodity price list, one frame (a child of that row, the row's size, no mouse) with
--     a thin colour bar at the row's left edge and, where there is room between Blizzard's price and quantity, a
--     small "per hour" figure. They are kept in a weak-keyed table of Kebold's own, indexed by the row frame;
--   * under the Buy button, a frame (a child of the buy display) with label / value lines like Blizzard's own
--     Quantity / Unit Price / Total Price lines.
--
-- What is taken from Blizzard's own UI source (Gethe/wow-ui-source, branch "classic",
-- Interface/AddOns/Blizzard_AuctionHouseUI; read 2026-11-15). ALL of it is a guess for the Forever client, so
-- every field is probed with type() and every call is made under pcall (/keboldah buy probe prints what was found):
--   Shared/Blizzard_AuctionHouseCommoditiesBuyFrame.xml: CommoditiesBuyFrame.BuyDisplay is a vertical layout
--     (padding: top 19, left 15, right 16, bottom 120; 15 between children) of ItemDisplay (342 x 72),
--     QuantityInput, UnitPrice, TotalPrice and BuyButton (196 x 22, leftPadding 110); .ItemList is to its right.
--   Shared/Blizzard_AuctionHouseSellFrame.xml (the aligned control templates those lines use): a line is 200 x 30
--     with .Label = GameFontNormal, right-justified, 93 wide at the line's left; the value starts 18 right of it.
--   Classic/Blizzard_AuctionHouseItemList.xml: ItemList.HeaderContainer, .ScrollBox (WowScrollBoxList), .ScrollBar;
--     a row (AuctionHouseItemListLineTemplate) is a 20 px high button.
--   Shared/Blizzard_AuctionHouseItemList.lua: a row keeps its data as row.rowData (GetRowData() returns it); the
--     list itself registers ScrollBoxListMixin.Event.OnScroll on its ScrollBox with RegisterCallback.
--   Shared/Blizzard_AuctionHouseTableBuilder.lua (commodity buy list): two columns, the unit price (a money
--     display at the left, 10 px in; rowData.unitPrice, a checkmark 6 px right of it when
--     rowData.containsOwnerItem) and the quantity (rowData.quantity, right-justified, 10 px from the right edge).
--     Between the two the row is empty: that is where the per-hour figure goes.
--   Shared/Blizzard_AuctionHouseCommoditiesList.xml: the list is 210 wide (its rows about 180).
-- Not from that source (general knowledge of the client's scroll boxes, unverified): ScrollBox:ForEachFrame(fn),
-- ScrollBox:GetFrames(), and the events OnUpdate / OnDataRangeChanged beside OnScroll.

local marks = setmetatable({}, { __mode = "k" })   -- [a row frame of Blizzard's] = { holder, bar, fs, on, tone, text, fig, ... }
local tips = setmetatable({}, { __mode = "k" })    -- [one of our lines] = its tooltip: a string, or a list (the first is the title)
local pg = { box = false, how = false, why = false, cbBox = false, cbs = {}, driver = false, driverParent = false,
  by = false,          -- [unit price] = { tone, text } for the reading shown (false: no marks)
  maxQty = 0,          -- the largest quantity of one price line: what Blizzard's quantity column needs
  seen = 0, withData = 0, marked = 0, rowW = false, pass = 0 }
local blk = { frame = false, parent = false, w = BUY.sumW, h = BUY.sumH, cols = false, anchor = false, labelW = BUY.pgLabel, labelHow = false,
  craftLabel = false, choice = false, profit = false, verdict = false, warn = false, data = false,
  rects = {} }   -- [name] = { x, y, w, h } from the block's top left, y downwards: where the layout put each part

-- A text's estimated width with its coin pictures (UI.textWidth counts a coin as its letter; a picture is wider).
local function textW(text, font)
  local n, t = 0, tostring(text or "")
  for _, mark in ipairs({ MG, MS, MC }) do
    local from = 1
    while true do
      local _, b = t:find(mark, from, true)
      if not b then break end
      n, from = n + 1, b + 1
    end
  end
  return UI.textWidth(t, font) + n * BUY.coin
end
NS.buyTextW = textW

local function showTip(owner)
  local t = tips[owner]
  if type(t) == "string" then t = { t } end
  if not isTable(t) or type(t[1]) ~= "string" or not isTable(GameTooltip) then return end
  pcall(function()
    GameTooltip:SetOwner(owner, UI.tipAnchor and UI.tipAnchor(owner) or "ANCHOR_RIGHT")
    GameTooltip:SetText(UI.show(t[1]), 1, 1, 1, 1, true)
    for i = 2, #t do
      if type(t[i]) == "string" then GameTooltip:AddLine(UI.show(t[i]), 0.85, 0.85, 0.85, true) end
    end
    GameTooltip:Show()
  end)
end

local function insetOf(key, def)
  local t = buySet()[key]
  local out = {}
  for i = 1, 4 do out[i] = isTable(t) and tonumber(t[i]) or def[i] end
  return out
end

local function levelOver(f, add)
  local lvl
  if isTable(f) and isFn(f.GetFrameLevel) then
    local ok, v = pcall(f.GetFrameLevel, f)
    if ok and type(v) == "number" then lvl = v end
  end
  return (lvl or 1) + add
end

-- ---- the marks on Blizzard's rows ----

-- The rows of the commodity price list: its ScrollBox and how its row frames are walked.
--   -> ScrollBox, "ForEachFrame" | "GetFrames", the list frame;  or nil, why
local function findRows()
  local ah = ahFrame()
  local cb = ah and ah.CommoditiesBuyFrame
  local il = isTable(cb) and cb.ItemList or nil
  if not isTable(il) then return nil, "CommoditiesBuyFrame.ItemList not found" end
  local box = il.ScrollBox
  if not isTable(box) then return nil, "ItemList.ScrollBox not found" end
  if isFn(box.ForEachFrame) then return box, "ForEachFrame", il end
  if isFn(box.GetFrames) then return box, "GetFrames", il end
  return nil, "ItemList.ScrollBox has neither ForEachFrame nor GetFrames"
end

local function eachRow(box, how, fn)
  if how == "ForEachFrame" then
    pcall(box.ForEachFrame, box, fn)
  else
    local ok, list = pcall(box.GetFrames, box)
    if ok and isTable(list) then
      for _, row in ipairs(list) do fn(row) end
    end
  end
end

-- What a row of Blizzard's shows: unit price, quantity, whether it holds an auction of the player's (a checkmark
-- right of the price). Read only: row.rowData, else row:GetRowData().
local function rowData(row)
  local d = row.rowData
  if not isTable(d) and isFn(row.GetRowData) then
    local ok, v = pcall(row.GetRowData, row)
    d = ok and v or nil
  end
  if not isTable(d) then return nil end
  local p = tonumber(d.unitPrice)
  if not p or p <= 0 then return nil end
  return ceil(p), tonumber(d.quantity) or 0, d.containsOwnerItem == true
end

-- Estimated width of Blizzard's price in a row: each coin shown is its digits and a coin picture, and the coins
-- under the largest one are always two digits wide.
local function priceW(v)
  v = floor(abs(v) + 0.5)
  local g, s = floor(v / 10000), floor(v / 100) % 100
  local function coin(n) return #tostring(n) * BUY.rowDigit + BUY.rowCoin end
  local two = 2 * BUY.rowDigit + BUY.rowCoin
  if g > 0 then return coin(g) + 2 * two end
  if s > 0 then return coin(s) + two end
  return coin(v % 100)
end
-- Estimated width of Blizzard's quantity (thousands separated).
local function qtyW(n)
  local d = #tostring(floor(max(0, n)))
  return (d + floor((d - 1) / 3)) * BUY.rowDigit
end

-- The per-hour figure's distance from a row's right edge: the saved one (/keboldah buy rowx), else what clears
-- the widest quantity of the list shown, so that the figures of all rows line up.
local function rowX()
  local v = tonumber(buySet().rowx)
  if v then return v, true end
  return BUY.rowPad + qtyW(pg.maxQty) + BUY.rowGap, false
end

-- [unit price] = { tone, text } for the reading the model was made from.
-- THE RULE: one row of Blizzard's is one price with a quantity, while the model cuts a price line where the tone
-- changes. A row takes the tone (and the per-hour figure) of its FIRST unit, the cheapest position it holds:
-- the units listed at lower prices are counted, and the piece of the model that unit number falls into decides.
-- A row whose later units are worse still shows the better tone; the exact count is in the "Buy up to" line.
local function rowIndex(M)
  if not isTable(M) or M.scan or not isTable(M.lines) or #M.lines == 0 then return false, 0 end
  local segs = {}
  for _, e in ipairs(listRows(M)) do
    if isTable(e.src) and isTable(e.cols) then
      -- the figure is what the crafts earn an hour, said so ("41.2g/h": the row has no column head); a product's
      -- rows (bought against making it) get the bar alone
      segs[#segs + 1] = { to = e.src.run, tone = e.tone or "none", text = (M.kind == "use" and e.src.ph) and (e.cols[4] .. DIM .. "/h|r") or false }
    end
  end
  local by, before, si, most = {}, 0, 1, 0
  for _, line in ipairs(M.lines) do
    while segs[si] and segs[si].to <= before do si = si + 1 end
    local s = segs[si]
    if s then by[line[1]] = { tone = s.tone, text = s.text } end
    before = before + line[2]
    most = max(most, line[2])
  end
  return by, most
end

local function makeMark(row)
  local holder = CreateFrame("Frame", nil, row)   -- ours; no mouse: every click and hover stays the row's
  holder:SetAllPoints(row)
  local bar = holder:CreateTexture(nil, "OVERLAY")
  bar:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -1)
  bar:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 1)
  bar:SetWidth(BUY.rowBar)
  local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("RIGHT")
  fs:SetWordWrap(false)
  local m = { holder = holder, bar = bar, fs = fs, on = false, tone = false, text = false, fig = false, sig = false, pass = 0 }
  marks[row] = m
  return m
end

local function clearMark(m)
  if m.on == true then
    m.holder:Hide()
    m.on, m.tone, m.text, m.fig, m.sig = false, false, false, false, false
  end
end
local function clearMarks()
  for _, m in pairs(marks) do clearMark(m) end
  pg.marked = 0
end

-- Marks every visible row of Blizzard's list for the reading shown and clears the others. Row frames are reused
-- while the list scrolls, so this runs after every scroll / update of the list (its callbacks), every frame
-- while the marks show (our own driver frame) and on every look of the helper.
local function markRows()
  local box, how, by = pg.box, pg.how, pg.by
  if not box or not by then
    if pg.marked > 0 then clearMarks() end
    return 0
  end
  local B = buySet()
  local x, set = rowX()
  local showFig = B.rowph ~= false
  local seen, withData, n = 0, 0, 0
  pg.pass = pg.pass + 1
  local pass = pg.pass
  eachRow(box, how, function(row)
    if not isTable(row) then return end
    seen = seen + 1
    local price, _, mine = rowData(row)
    if price then withData = withData + 1 end
    local e = price and by[price] or nil
    local m = marks[row]
    if not e or shownFrame(row) == false then
      if m then clearMark(m) end
      return
    end
    local w = sizeOf(row)
    if not (w and w >= 60) then w = BUY.rowW end
    pg.rowW = w
    if not m then
      local ok, made = pcall(makeMark, row)
      if not ok or not isTable(made) then return end
      m = made
    end
    -- painted again only when something it shows moved (this runs every frame: no text is built to compare)
    if m.sig ~= e or m.price ~= price or m.w ~= w or m.x ~= x or m.showFig ~= showFig or m.mine ~= mine then
      local rgb = TONE_RGB[e.tone] or TONE_RGB.none
      m.bar:SetColorTexture(rgb[1], rgb[2], rgb[3], e.tone == "none" and 0.6 or 1)
      -- the figure only where it clears Blizzard's price at the left (and its quantity at the right, by x)
      local fig = false
      if showFig and e.tone ~= "none" and e.text then
        local need = textW(e.text, "GameFontHighlightSmall")
        local free = BUY.rowPriceX + priceW(price) + (mine and BUY.rowCheck or 0) + BUY.rowGap
        if set or w - x - need >= free then fig = true end
      end
      if fig then
        m.fs:ClearAllPoints()
        m.fs:SetPoint("RIGHT", m.holder, "RIGHT", -x, 0)
        m.fs:SetText(UI.show(e.text))
        m.fs:Show()
      else
        m.fs:SetText("")
        m.fs:Hide()
      end
      m.tone, m.text, m.fig, m.sig = e.tone, e.text, fig, e
      m.price, m.w, m.x, m.showFig, m.mine = price, w, x, showFig, mine
    end
    if m.on ~= true then
      m.holder:Show()
      m.on = true
    end
    m.pass = pass
    n = n + 1
  end)
  -- a row frame the list no longer shows (scrolled out, released) loses its mark
  for _, m in pairs(marks) do
    if m.on == true and m.pass ~= pass then clearMark(m) end
  end
  pg.seen, pg.withData, pg.marked = seen, withData, n
  return n
end
local function markSafe() pcall(markRows) end

-- Finds the rows, asks the list to say when it scrolled or changed (its own callback registry; nothing of it is
-- replaced) and makes the driver frame. Without rows there are simply no marks.
local SCROLL_EVENTS = { "OnUpdate", "OnScroll", "OnDataRangeChanged" }
local function rowsSetup()
  local box, how, il = findRows()
  if not box then
    pg.box, pg.how, pg.why = false, false, how
    return false
  end
  pg.box, pg.how, pg.why = box, how, false
  if pg.cbBox ~= box then
    pg.cbBox, pg.cbs = box, {}
    if isFn(box.RegisterCallback) then
      local ev = isTable(ScrollBoxListMixin) and isTable(ScrollBoxListMixin.Event) and ScrollBoxListMixin.Event or nil
      for _, name in ipairs(SCROLL_EVENTS) do
        local key = ev and ev[name] or name   -- the events are their own names in the client's registries
        if pcall(box.RegisterCallback, box, key, markSafe, pg) then pg.cbs[#pg.cbs + 1] = name end
      end
    end
  end
  if not pg.driver then
    local ok, d = pcall(CreateFrame, "Frame", nil, il)
    if ok and isTable(d) then
      d:Hide()
      d:SetScript("OnUpdate", markSafe)
      pg.driver, pg.driverParent = d, il
    end
  elseif pg.driverParent ~= il then
    pcall(pg.driver.SetParent, pg.driver, il)
    pg.driverParent = il
  end
  return true
end

-- ---- the lines under Blizzard's Buy button ----

-- Where the lines go in a block `w` wide: the label column (labelW, right-justified, as Blizzard's own lines)
-- and the values right of it; y = { craft, profit, verdict, warn } from the block's top, downwards; h (what the
-- lines need); boxW (the Craft dropdown's box: as wide as Blizzard's Buy button above it, or the value column).
local function pageLayout(w, labelW)
  local c = { w = w, labelW = labelW or BUY.pgLabel, y = {} }
  c.valueX = c.labelW + BUY.pgGapX
  c.valueW = w - c.valueX
  c.y.craft = 0
  c.y.profit = BUY.pgCtl + BUY.pgGap
  c.y.verdict = c.y.profit + BUY.pgLine
  c.y.warn = c.y.verdict + BUY.pgLine + BUY.pgGap
  c.h = c.y.warn + BUY.pgWarn
  c.boxW = max(BUY.sumMinBox, min(BUY.pgBox, c.valueW))   -- one width whatever the recipe: the page does not jump
  return c
end
NS.buyPageLayout = pageLayout

-- The saved height of the block (S.buy.pageHeight).
local function sumHeight()
  return tonumber(buySet().pageHeight) or BUY.sumH
end

-- A line: a frame of ours (for its tooltip) with a yellow label in the label column and a value right of it.
-- wide: one sentence across the whole block (no label), wrapped, as high as `h`.
local function pageLine(parent, h)
  local line = CreateFrame("Frame", nil, parent)
  line:EnableMouse(true)
  line:SetHeight(h)
  line.label = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")   -- Blizzard's own label font
  line.label:SetJustifyH("RIGHT")
  line.label:SetWordWrap(false)
  line.fs = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  line.fs:SetJustifyH("LEFT")
  line.wide = false
  line:SetScript("OnEnter", showTip)
  line:SetScript("OnLeave", tipHide)
  return line
end
local function lineSet(line, c, label, value, wide, h)
  line.wide = wide and true or false
  line:SetHeight(h)
  line.label:ClearAllPoints()
  line.fs:ClearAllPoints()
  if wide then
    line.label:SetText("")
    line.label:Hide()
    pcall(line.fs.SetFontObject, line.fs, "GameFontHighlightSmall")
    line.fs:SetPoint("TOPLEFT", line, "TOPLEFT", 0, -2)
    line.fs:SetWidth(c.w)
    line.fs:SetWordWrap(true)
  else
    line.label:SetPoint("LEFT", line, "LEFT", 0, 0)
    line.label:SetWidth(c.labelW)
    line.label:SetText(label or "")
    line.label:Show()
    pcall(line.fs.SetFontObject, line.fs, "GameFontHighlight")
    line.fs:SetPoint("LEFT", line, "LEFT", c.valueX, 0)
    line.fs:SetWidth(c.valueW)
    line.fs:SetWordWrap(false)
  end
  line.fs:SetText(UI.show(value or ""))
end

local function blkBuild(parent)
  local f = CreateFrame("Frame", "KeboldsShinyBuySummary", parent)
  f:Hide()
  f.ignoreInLayout = true   -- a field of our own frame: Blizzard's buy display lays its children out in a column
  blk.craftLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  blk.craftLabel:SetJustifyH("RIGHT")
  blk.craftLabel:SetWordWrap(false)
  blk.craftLabel:SetText("Craft")
  blk.choice = recipeChoice(f, BUY.sumMinBox, nil, "", true)
  -- the box may be narrower than the recipe's name: the whole name is the tooltip's first line
  blk.choice.drop.tip = function()
    return { lastModel and lastModel.choice and lastModel.choice.text or "no recipe",
      "The recipe the prices are judged for: what its crafts earn when the item is bought at each price.",
      "Worth above (" .. whole(floorGold()) .. " g an hour) is in this menu too: green rows earn at least that." }
  end
  blk.profit = pageLine(f, BUY.pgLine)
  blk.verdict = pageLine(f, BUY.pgLine)
  blk.warn = pageLine(f, BUY.pgWarn)
  blk.frame = f
end

-- Puts the block under Blizzard's Buy button, its label column on Blizzard's own (the button starts 110 right of
-- the column's left edge), or, where the button cannot be found, at the bottom of the buy display.
local function blkPlace(D)
  local f = blk.frame
  if blk.parent ~= D then
    pcall(f.SetParent, f, D)
    blk.parent = D
  end
  local i = insetOf("pageInset", BUY.inset)
  local h = max(40, sumHeight())
  local dw = sizeOf(D)
  local w = (dw and dw >= 200) and (dw - BUY.padL - BUY.padR - i[1] - i[3]) or (BUY.sumW - i[1] - i[3])
  w = max(200, floor(w + 0.5))
  local btn = D.BuyButton
  f:ClearAllPoints()
  if answers(btn) then
    blk.anchor = "button"
    f:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", i[1] - BUY.btnPad, -i[2])
  else
    blk.anchor = "bottom"
    f:SetPoint("BOTTOMLEFT", D, "BOTTOMLEFT", BUY.padL + i[1], i[4])
  end
  f:SetSize(w, h)
  pcall(f.SetFrameLevel, f, levelOver(D, BUY.sumLevel))
  blk.w, blk.h = w, h
  -- the label column: as wide as Blizzard's own labels when the game says how wide those are
  local lw, how = nil, false
  local tp = D.TotalPrice
  if isTable(tp) and isTable(tp.Label) then
    lw = sizeOf(tp.Label)
    if lw and lw >= 40 and lw <= 200 then how = "TotalPrice.Label" else lw = nil end
  end
  blk.labelW, blk.labelHow = lw or BUY.pgLabel, how
  local ch = blk.choice
  ch:Fit()
  local c = pageLayout(w, blk.labelW)
  blk.cols = c
  local R = blk.rects
  blk.craftLabel:ClearAllPoints()
  blk.craftLabel:SetPoint("LEFT", f, "TOPLEFT", 0, -(c.y.craft + BUY.pgCtl / 2))
  blk.craftLabel:SetWidth(c.labelW)
  R.craftLabel = { 0, c.y.craft, c.labelW, BUY.pgCtl }
  ch.boxW, ch.kitW = c.boxW, c.boxW
  ch.drop:SetWidth(c.boxW)
  ch:SetSize(c.boxW, BUY.pgCtl)
  ch:ClearAllPoints()
  ch:SetPoint("TOPLEFT", f, "TOPLEFT", c.valueX, -c.y.craft)
  R.choice = { c.valueX, c.y.craft, c.boxW, BUY.pgCtl }
  for _, name in ipairs({ "profit", "verdict", "warn" }) do
    local line = blk[name]
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -c.y[name])
    line:SetWidth(w)
  end
end

local function blkPaint(M, qtyRead)
  local S = summaryOf(M, qtyRead)
  local c, R = blk.cols, blk.rects
  blk.data = S
  blk.choice:Refresh()
  local function put(name, e, h)
    local line = blk[name]
    if e then
      lineSet(line, c, e.label, e.value, e.wide, h)
      tips[line] = e.tip
      R[name] = { 0, c.y[name], c.w, h }
      line:Show()
    else
      tips[line] = nil
      R[name] = nil
      line:Hide()
    end
  end
  put("profit", S.profit, BUY.pgLine)
  -- a sentence in the verdict's place may wrap into the warning's line: there is no warning then
  put("verdict", S.verdict, (S.verdict and S.verdict.wide) and (c.h - c.y.verdict) or BUY.pgLine)
  put("warn", not (S.verdict and S.verdict.wide) and S.warn and { value = S.warn.text, wide = true, tip = S.warn.tip } or false, BUY.pgWarn)
end

local function hideSide()
  if frame and frame:IsShown() then
    frame:Hide()
    if isFn(NS.onBuyPanel) then pcall(NS.onBuyPanel, false) end
  end
end
-- The side panel (S.buy.where = "side", or Blizzard's list frame was not found).
local function updateSide(force)
  local ah = ahFrame()
  if not frame then
    local ok, f = pcall(build, ah)
    if not ok or not isTable(f) then
      sessionOff = true
      NS.say("The buy helper could not be built: " .. tostring(f))
      return false
    end
    frame = f
  end
  place(frame, ah)
  if cur.scan == true then
    local shown = frame:IsShown()
    if not shown then frame:Show() end
    local sig = "scan|" .. (busy() and 1 or 0) .. "|" .. frame.side
    if force or not shown or sig ~= lastSig then
      lastSig = sig
      paint(scanModel(), false)
    end
    if not shown and isFn(NS.onBuyPanel) then pcall(NS.onBuyPanel, true) end
    return true
  end
  local qty = nil
  if cur.kind == "commodity" then qty = quantityOf() end
  local own = qty == nil
  if own then qty = ownQty end
  local was = frame:IsShown()
  if not was then frame:Show() end
  -- everything the panel's lines depend on: painted again only when one of them moved
  local function sigNow()
    local held, pins
    if isFn(NS.asMe) then held, pins = NS.asMe(heldAndPins, cur.item) else held, pins = heldAndPins(cur.item) end
    return table.concat({ cur.stamp, NS.version(), qty or 0, own and 1 or 0, held or 0, tostring(chosen[cur.item]), floorGold(),
      tostring(isFn(NS.detailRecipe) and NS.detailRecipe() or nil), frame.side, tostring(pins) }, "|")
  end
  if force or not was or sigNow() ~= lastSig then
    local ok, M = pcall(NS.buyModel, cur.item, cur.lines, qty)
    if not ok then
      NS.say("The buy helper hit an error: " .. tostring(M))
      return false
    end
    lastSig = sigNow()   -- after the model: reading a vendor value on the way may have moved the price version
    paint(M, own)
  end
  if not was and isFn(NS.onBuyPanel) then pcall(NS.onBuyPanel, true) end
  return true
end

local function hidePage()
  if blk.frame and blk.frame:IsShown() then blk.frame:Hide() end
  if pg.marked > 0 then clearMarks() end
  pg.by = false
  if pg.driver and pg.driver:IsShown() then pg.driver:Hide() end
end

-- Kebold's additions to Blizzard's commodity buy screen (S.buy.where = "page").
local pgSig = nil
local function updatePage(force, D)
  -- The item (non-commodity) screen is left exactly as Blizzard draws it: its rows pick the auction to buy.
  -- The reading is still saved (onResults).
  if viewing() == "item" or (cur.scan ~= true and cur.kind == "item") then
    hidePage()
    pgSig = nil
    return false
  end
  local ok, err = pcall(function()
    if not blk.frame then blkBuild(D) end
  end)
  if not ok then
    sessionOff = true
    NS.say("The buy helper could not be built: " .. tostring(err))
    return false
  end
  rowsSetup()
  blkPlace(D)
  local fresh = false
  if not blk.frame:IsShown() then
    blk.frame:Show()
    fresh = true
  end
  -- the quantity is Blizzard's own box, read only: true = read, false = not readable
  local qty, qtyRead = nil, nil
  if cur.scan ~= true then
    qty = quantityOf()
    qtyRead = qty ~= nil
  end
  local function sigNow()
    local held, pins = 0, ""
    if cur.item ~= nil then
      if isFn(NS.asMe) then held, pins = NS.asMe(heldAndPins, cur.item) else held, pins = heldAndPins(cur.item) end
    end
    return table.concat({ "page", cur.stamp, NS.version(), tostring(qty), tostring(qtyRead), held or 0, tostring(cur.item ~= nil and chosen[cur.item] or nil),
      floorGold(), tostring(isFn(NS.detailRecipe) and NS.detailRecipe() or nil), tostring(pins), blk.w, blk.h, blk.labelW, tostring(blk.anchor),
      busy() and 1 or 0 }, "|")
  end
  if force or fresh or sigNow() ~= pgSig then
    local M
    if cur.scan == true then
      M = scanModel()
    else
      local ok2, m = pcall(NS.buyModel, cur.item, cur.lines, qty)
      if not ok2 then
        NS.say("The buy helper hit an error: " .. tostring(m))
        return false
      end
      M = m
    end
    pgSig = sigNow()   -- after the model: reading a vendor value on the way may have moved the price version
    lastModel = M
    pg.by, pg.maxQty = rowIndex(M)
    blkPaint(M, qtyRead)
  end
  markRows()
  if pg.driver then
    local want = pg.box and pg.by and true or false
    if want ~= (pg.driver:IsShown() == true) then
      if want then pg.driver:Show() else pg.driver:Hide() end
    end
  end
  return true
end

-- Shows, hides and repaints the helper for what the player is looking at. force = true: paint even when nothing
-- it depends on moved.
function update(force)
  if not wanted() then
    hideSide()
    hidePage()
    lastSig, pgSig = nil, nil
    return false
  end
  local mode, D = whereNow()
  if mode == "side" then
    hidePage()
    pgSig = nil
    return updateSide(force)
  end
  hideSide()
  lastSig = nil
  return updatePage(force, D)
end

-- ---- what the other files (and the tests) call -----------------------------------------------------------------------------

function NS.buyUpdate(force) return update(force) end
function NS.buyPanel() return frame, lastModel end               -- for tests: the frame and the model it shows
function NS.buyPanelShown() return frame ~= nil and frame:IsShown() and true or false end
-- The room the panel takes beside the auction house (its width and the gap), 0 while it is hidden.
function NS.buyPanelWidth() return NS.buyPanelShown() and (BUY.w + BUY.gap) or 0 end
-- Anything of the helper on screen: the side panel, the lines under the Buy button or a mark on a price row.
function NS.buyShown()
  return NS.buyPanelShown() or (blk.frame and blk.frame:IsShown() and true) or pg.marked > 0
end
-- For tests and the probe: what Kebold added to Blizzard's buy page.
--   mode ("page" | "side"), block (the lines' frame), blk (its parts: craftLabel, choice, profit, verdict, warn,
--   cols, w, h, anchor, labelW), summary (NS.buySummary's table as painted), rects, tips, marks ([row frame of
--   Blizzard's] = { holder, bar, fs, on, tone, text, fig }), rows (the scroll box, how it is walked, the
--   callbacks registered, the driver frame, counts), by ([unit price] = { tone, text }), rowx
function NS.buyPage()
  return { mode = (whereNow()), block = blk.frame, blk = blk, summary = blk.data, rects = blk.rects, tips = tips, marks = marks, rows = pg, by = pg.by,
    rowx = (rowX()) }
end
-- Marks Blizzard's visible price rows again (what the list's callbacks and the driver frame do); -> rows marked.
function NS.buyMarkRows() return markRows() end
function NS.buyCurrent() return cur end                           -- the reading shown: { item, kind, lines, listed, full, saved }; { scan = true } while a scan answers

-- The panel's print lines: the summary block, then the price list ({} while nothing is being looked at).
function NS.buyRows()
  if not cur then return {} end
  if cur.scan == true then
    local m = scanModel()
    return NS.buyModelRows(m), m
  end
  local qty = cur.kind == "commodity" and quantityOf() or nil
  if qty == nil then qty = ownQty end
  local ok, M = pcall(NS.buyModel, cur.item, cur.lines, qty)
  if not ok then return { { left = RED .. tostring(M) .. "|r" } } end
  return NS.buyModelRows(M), M
end

-- The dropdown's choice: remembered for the item until the game is left.
function NS.buyChoose(key)
  if not cur or cur.item == nil then return end
  chosen[cur.item] = key
  update(true)
end

-- The saved switch (the Kebold button's menu, /keboldah buy on|off). Switching it on also undoes the panel's x.
function NS.buySwitch(on)
  local B = buySet()
  if on == nil then on = not (B.on and not sessionOff) end
  B.on = on and true or false
  if B.on then sessionOff = false end
  update(true)
  return B.on
end
function NS.buyOn() return buySet().on == true and not sessionOff end

-- ---- wiring --------------------------------------------------------------------------------------------------------------

local ticking = false
local function tick()
  if not ahOpen then
    ticking = false
    return
  end
  pcall(update)
  C_Timer.After(BUY.poll, tick)
end

local modeHooked = nil
local function watchMode()
  local ah = ahFrame()
  if not ah or modeHooked == ah or not isFn(hooksecurefunc) or not isFn(ah.SetDisplayMode) then return end
  if pcall(hooksecurefunc, ah, "SetDisplayMode", function() pcall(update) end) then modeHooked = ah end
end

local handlers = {}
function handlers.AUCTION_HOUSE_SHOW()
  ahOpen = true
  cur, lastSig = nil, nil
  if isTable(C_Timer) and isFn(C_Timer.After) then
    C_Timer.After(0, function() pcall(watchMode) end)   -- a frame later: Blizzard's window exists by then
    if not ticking then
      ticking = true
      C_Timer.After(BUY.poll, tick)
    end
  end
end
function handlers.AUCTION_HOUSE_CLOSED()
  ahOpen = false
  cur = nil
  update()
end
function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(itemID) onResults("commodity", itemID) end
function handlers.COMMODITY_SEARCH_RESULTS_ADDED(itemID) onResults("commodity", itemID) end
function handlers.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
  if isTable(itemKey) then onResults("item", itemKey.itemID, itemKey) end
end
function handlers.ITEM_SEARCH_RESULTS_ADDED(itemKey)
  if isTable(itemKey) then onResults("item", itemKey.itemID, itemKey) end
end
function handlers.BAG_UPDATE_DELAYED()
  if cur and NS.buyShown() then update() end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
  local h = handlers[event]
  if not h then return end
  local ok, err = pcall(h, ...)
  if not ok then NS.say("The buy helper hit an error: " .. tostring(err)) end
end)
for event in pairs(handlers) do
  pcall(events.RegisterEvent, events, event)   -- a name the client does not know raises an error
end

-- The Kebold button's right-click menu gains the switch (the menu is ours: NS.entryMenu in LedgerEntry.lua).
do
  local was = NS.entryMenu
  if isFn(was) then
    NS.entryMenu = function(...)
      local items = was(...)
      if isTable(items) then
        local at = #items + 1
        for i, it in ipairs(items) do
          if isTable(it) and it.divider then
            at = i
            break
          end
        end
        table.insert(items, at, { check = true, checked = NS.buyOn(), text = "Buy helper on the Buy tab",
          tip = "Open an item on the Buy tab: Kebold colours each price by what the crafts made from it earn.",
          func = function() NS.buySwitch() end })
      end
      return items
    end
  end
end

-- /keboldah buy probe: which of Blizzard's fields were found, one line each (for the owner to paste back).
function NS.buyProbe()
  local out = {}
  local function add(text) out[#out + 1] = text end
  local function px(v) return v and whole(v) or "?" end
  local function has(x) return isTable(x) and "found" or "NOT found" end
  local B = buySet()
  local ah = ahFrame()
  add("AuctionHouseFrame: " .. (ah and "found" or "NOT found"))
  local cb, ib = ah and ah.CommoditiesBuyFrame, ah and ah.ItemBuyFrame
  local v = viewing()
  local by = (shownFrame(cb) ~= nil or shownFrame(ib) ~= nil) and "CommoditiesBuyFrame / ItemBuyFrame :IsShown()"
    or ((ah and isTable(ah.displayMode)) and "AuctionHouseFrame.displayMode" or "nothing to tell by")
  add("Screen detected: " .. (v == "commodity" and "commodity buy" or (v == "item" and "item buy" or (v == false and "neither buy screen" or "unknown")))
    .. " (" .. by .. ")")
  local D, how = findDisplay()
  if D then
    local w, h = sizeOf(D)
    add("Buy display: " .. how .. ", " .. px(w) .. " x " .. px(h))
    local tp = D.TotalPrice
    local lw = isTable(tp) and isTable(tp.Label) and sizeOf(tp.Label) or nil
    add("Buy display parts: BuyButton " .. (answers(D.BuyButton) and "found" or "NOT found") .. ", TotalPrice " .. has(tp) .. ", TotalPrice.Label "
      .. ((isTable(tp) and isTable(tp.Label)) and ("found, " .. px(lw) .. " wide") or "NOT found") .. ", UnitPrice " .. has(D.UnitPrice)
      .. ", QuantityInput " .. has(D.QuantityInput) .. ", ItemDisplay " .. has(D.ItemDisplay))
  else
    add("Buy display: NOT found (tried CommoditiesBuyFrame.BuyDisplay, then CommoditiesBuyFrame)")
  end
  local q, getter = quantityOf()
  add("Quantity box: " .. (q and ("QuantityInput, read with " .. tostring(getter) .. "() = " .. q)
    or ("NOT read (QuantityInput:GetQuantity(), .InputBox:GetNumber(), .InputBox:GetText())" .. (v ~= "commodity" and "; open a commodity first" or ""))))
  local item, ihow = screenItem()
  add("Item on screen: " .. (item and (tostring(ihow) .. " = " .. item) or ("NOT read (GetItemID / GetItemKey of the buy frame, its BuyDisplay and ItemDisplay)"
    .. ((v ~= "commodity" and v ~= "item") and "; open an item first" or ""))))
  -- the price rows
  local il = isTable(cb) and cb.ItemList or nil
  local box, walk = findRows()
  if box then
    local bw, bh = sizeOf(box)
    add("Price rows: CommoditiesBuyFrame.ItemList.ScrollBox, " .. px(bw) .. " x " .. px(bh) .. ", walked with " .. walk .. "; RegisterCallback "
      .. (isFn(box.RegisterCallback) and "found" or "NOT found") .. ", ScrollBoxListMixin.Event "
      .. ((isTable(ScrollBoxListMixin) and isTable(ScrollBoxListMixin.Event)) and "found" or "NOT found")
      .. "; told of: " .. ((pg.cbBox == box and #pg.cbs > 0) and table.concat(pg.cbs, ", ") or "nothing (the rows are re-marked every frame and every look)"))
    local seen, withTable, withGetter, withPrice, sample, fields = 0, 0, 0, 0, nil, nil
    eachRow(box, walk, function(row)
      if not isTable(row) then return end
      seen = seen + 1
      if isTable(row.rowData) then withTable = withTable + 1 elseif isFn(row.GetRowData) then
        local ok, d = pcall(row.GetRowData, row)
        if ok and isTable(d) then withGetter = withGetter + 1 end
      end
      local p, n, mine = rowData(row)
      if p then
        withPrice = withPrice + 1
        if not sample then
          sample = "unitPrice " .. p .. ", quantity " .. n .. (mine and ", containsOwnerItem" or "")
          local d, names = row.rowData, {}
          if isTable(d) then
            for k in pairs(d) do names[#names + 1] = tostring(k) end
            table.sort(names)
            fields = table.concat(names, ", ")
          end
        end
      end
    end)
    local rw = pg.rowW
    add("Row frames: " .. seen .. " seen, " .. withTable .. " with .rowData, " .. withGetter .. " through :GetRowData(), " .. withPrice .. " with a unit price"
      .. (sample and ("; first: " .. sample) or "") .. (fields and ("; rowData fields: " .. fields) or "") .. "; row width " .. px(rw)
      .. "; marked now: " .. pg.marked)
  else
    add("Price rows: NOT reached (" .. tostring(walk) .. "); ItemList " .. has(il) .. ", ItemList.ScrollBox " .. has(isTable(il) and il.ScrollBox or nil)
      .. ": no marks on the rows, the lines under the Buy button still show")
  end
  add("Item buy screen: left as Blizzard draws it (nothing is added there; its prices are still saved)")
  local mode, _, why = whereNow()
  add("Drawing: " .. (mode == "page" and "on Blizzard's page: marks on its price rows, lines under its Buy button"
    or (why == "set" and "the side panel (set with /keboldah buy where side)" or "the SIDE PANEL, because the buy display was not found"))
    .. "; helper " .. (NS.buyOn() and "on" or "off"))
  local i = insetOf("pageInset", BUY.inset)
  local x, set = rowX()
  add("Lines under the Buy button: " .. blk.w .. " x " .. blk.h .. (blk.frame and "" or " (not built yet)") .. ", "
    .. (blk.anchor == "button" and "hung under BuyButton" or (blk.anchor == "bottom" and "at the BOTTOM of the buy display (BuyButton not found)" or "not placed yet"))
    .. ", label column " .. px(blk.labelW) .. " (" .. (blk.labelHow or "the source's 93") .. "), inset " .. table.concat(i, " ") .. ", height " .. sumHeight()
    .. "; row figure " .. (B.rowph ~= false and "on" or "off") .. ", rowx " .. px(x) .. (set and " (set)" or " (auto)") .. ", floor " .. whole(floorGold()) .. " g an hour")
  return out
end

-- /keboldah buy ...: the command is wrapped, not replaced.
do
  local was = SlashCmdList and SlashCmdList["KEBOLDSSHINYAH"]
  if isFn(was) then
    local NUM4 = "(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)$"
    SlashCmdList["KEBOLDSSHINYAH"] = function(msg, ...)
      local cmd = string.lower(tostring(msg or ""):match("^%s*(.-)%s*$"))
      if cmd ~= "buy" and cmd:sub(1, 4) ~= "buy " then return was(msg, ...) end
      local a = cmd:sub(5):match("^%s*(.-)%s*$")
      local B = buySet()
      if a == "" or a == "on" or a == "off" then
        local on
        if a == "on" then on = true elseif a == "off" then on = false end
        on = NS.buySwitch(on)
        NS.say("The buy helper on the Buy tab is " .. (on and "on: open an item on the Buy tab." or "off."))
      elseif a == "where page" or a == "page" or a == "where overlay" or a == "overlay" or a == "where side" or a == "side" then
        B.where = (a == "side" or a == "where side") and "side" or "page"
        update(true)
        local mode = whereNow()
        NS.say(B.where == "side" and "The buy helper is the panel beside the auction house."
          or (mode == "page" and "The buy helper marks Blizzard's own price rows and writes its lines under the Buy button."
            or "The buy helper is set to draw on Blizzard's buy page, but its buy display was not found: the side panel is used. /keboldah buy probe says what was found."))
      elseif a == "list" or a:find("^list ") or a:find("^listinset") or a:find("^level") then
        NS.say("That setting is gone: Kebold no longer covers Blizzard's price list, it marks Blizzard's own rows. See /keboldah buy rowph and rowx.")
      elseif a == "inset reset" or a == "reset" then
        B.pageInset = nil
        if a == "reset" then B.pageHeight, B.rowx, B.rowph = nil, nil, true end
        update(true)
        NS.say("The buy helper's " .. (a == "reset" and "sizes are" or "lines are") .. " back where they were made to lie.")
      elseif a:find("^inset%s+" .. NUM4) then
        local l, t, r, b = a:match("^inset%s+" .. NUM4)
        B.pageInset = { tonumber(l), tonumber(t), tonumber(r), tonumber(b) }
        update(true)
        NS.say("The lines under the Buy button are moved " .. l .. " to the right, start " .. t .. " under the button and end " .. r
          .. " earlier at the right (" .. b .. " from the bottom where the button is not found).")
      elseif a:find("^height%s+%d+$") then
        B.pageHeight = max(40, min(400, tonumber(a:match("%d+"))))
        update(true)
        NS.say("The lines under the Buy button take " .. B.pageHeight .. " in height.")
      elseif a:find("^floor%s+%d+$") then
        setFloor(tonumber(a:match("%d+")))
        update(true)
        NS.say("Worth above: " .. whole(floorGold()) .. " g an hour. Green rows earn at least that; yellow ones a profit under it.")
      elseif a == "rowx auto" or a == "rowx reset" then
        B.rowx = nil
        update(true)
        NS.say("The per-hour figure on a price row sits just left of Blizzard's quantity again.")
      elseif a:find("^rowx%s+%-?%d+$") then
        B.rowx = max(0, min(400, tonumber(a:match("%-?%d+"))))
        update(true)
        NS.say("The per-hour figure on a price row ends " .. B.rowx .. " from the row's right edge, on every row.")
      elseif a == "rowph on" or a == "rowph off" or a == "rowph" then
        if a == "rowph" then B.rowph = B.rowph == false else B.rowph = a == "rowph on" end
        update(true)
        NS.say(B.rowph and "Price rows show what their crafts earn an hour, where there is room." or "Price rows show the colour bar only.")
      elseif a == "probe" then
        for _, line in ipairs(NS.buyProbe()) do NS.say(line) end
      else
        local i = insetOf("pageInset", BUY.inset)
        local x, set = rowX()
        NS.say("Usage: /keboldah buy on | off | where page | where side | floor <g an hour> | rowph on | off | rowx <n> | rowx auto | inset <left> <top> <right> <bottom> | height <n> | reset | probe")
        NS.say("Now: " .. (NS.buyOn() and "on" or "off") .. ", where " .. B.where .. ", floor " .. whole(floorGold()) .. ", rowph " .. (B.rowph and "on" or "off")
          .. ", rowx " .. (set and whole(x) or "auto") .. ", inset " .. table.concat(i, " ") .. ", height " .. sumHeight() .. ".")
      end
    end
  end
end
