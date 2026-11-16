-- Kebold's Shiny: the Level page (the leveling route)
-- The page is three things:
--   * a strip of six figures (points, crafts, casting, materials, to learn, after sales) and one status line that
--     says what is wrong with the plan (no prices, or a skill range with no usable recipe, and which of the two)
--     with the button that fixes it;
--   * the steps as a table, one figure per cell; what has to be learned or trained first is a second line of its
--     step. The other view of the same table, "Whole route", has the route's buy list, its choices (parts and
--     where products sell) and the recipes to learn, as foldable sections;
--   * the details pane filled with the SELECTED STEP: what to learn first and where, what to buy for it, and its
--     choices as real dropdowns. "Recipe details" swaps the pane for the Craft page's own (NS.openPanel).
--
-- The model is still row tables and nothing else (NS.buildRoute; /kebold print and the tests read it). Every row
-- says which part of the page shows it:
--   lv       "sum" (the strip and the status line), "steps" (the Steps view), "whole" (the Whole route view),
--            "step" (the pane: the selected step), "all" (both views: the empty state), "gaps" (not shown: a
--            route with no step at all lists its ranges here)
--   sum      "points" | "crafts" | "time" | "mats" | "learn" | "net": one figure of the strip (left = its name,
--            right = its value, tip = how it relates to the others)
--   status   "prices" | "gap" | "range" with level (0 fine .. 4 worst) and fix ("scan" | "recipes"): the status line
--   step     the index of the route step a line belongs to (the step itself, its second lines); gap = true on a
--            range with no recipe; sub = true on a second line; learnStep / learnCost on a "learn first" line
--   range, make, n, chance, each, sells   the cells of a step (c2 = step cost, right = after sales); left, c1 and
--            time are the same step as one line of text, for /kebold print
--   name, need, bags                      the cells of a buy line (c1 = pay up to, c2 = cost, right = the choice)
--   how      a part: "making" | "buying" | "have it"; a product: "to the AH" | "to a vendor" | "no sale"
--   control  { kind = "dropdown" | "button", text, items = function() -> menu entries, func, tip }: a real control
--            drawn over the line's last cell (the text of that cell is the same choice, for print and tests)
--   button   true: an action of the page or the pane (left = its label, action = what it does); drawn as a button
--   where, pin                            a recipe to learn: where it is taught or sold, and the map pin's target
--   started, changed, at, cheaper         the banner of a started plan (lv "all": both views; LedgerRoute.lua)
--   done, now, nowLine                    a step of a started plan that is behind you / the one you are in / its
--                                         "you are here" second line
--   safe, over, own                       a step's count for bad luck (the Crafts cell then ends in ~), a step above
--                                         the limit for one skill point, a step whose recipe you chose (ends in *)
--   alt, altNote, altHead                 the pane's "Other recipes for this range": an alternate (the table from
--                                         NS.stepAlternates), its line of words, the block's head
--   safeRow                               the pane's "to be safe" line under the step's buy list
-- A started plan (LedgerRoute.lua) is drawn by the same code from its save: the route is then NS.startedRoute(),
-- whose steps carry rec (the saved step), and nothing here plans.
-- The shell, the shared state and the menus are in Ledger.lua; the recipe's own details are LedgerRecipes.lua's.

local NS = KeboldsShinyNS
local UI = KeboldsShinyUI
local E = NS.E
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local DIM, RED, GOLD, WHITE, GREEN = NS.DIM, NS.RED, NS.GOLD, NS.WHITE, NS.GREEN
local COLOUR, PICK_TEXT, SELL_TEXT, RANKS, DAY_ZERO = NS.COLOUR, NS.PICK_TEXT, NS.SELL_TEXT, NS.RANKS, NS.DAY_ZERO
local money, itemName, itemText, settings, try, data = NS.money, NS.itemName, NS.itemText, NS.settings, NS.try, NS.data
local bagCount, myProfs, profState, rangeOf, realmItems, learnText = NS.bagCount, NS.myProfs, NS.profState, NS.rangeOf, NS.realmItems, NS.learnText
local scanScope, vendorPrices = NS.scanScope, NS.vendorPrices

local BOOK = "Interface\\Icons\\INV_Misc_Book_09"

-- What the page remembers between refreshes (this session only).
local sel = { id = nil, from = nil, follow = true }   -- the step chosen: its recipe (false = a range with no recipe) and its
                                                      -- start; follow = nothing was clicked: a started plan shows the step you are in
local paneMode = "step"                -- "step": the pane shows the selected step; "recipe": the Craft page's pane
local shownStep = nil                  -- the step the model was built for: { i, g, r, n, prof }
local page                             -- the registration table (set at the end of the file)

local function viewOf()
  return settings().levelView == "whole" and "whole" or "steps"
end

-- ---- small things ----------------------------------------------------------------------------------------------------

-- Casting time for people: 17.0s, 3.4 min, 1.2 h
local function dur(v)
  if v == nil then return "?" end
  if v >= 3600 then return string.format("%.1f h", v / 3600) end
  if v >= 90 then return string.format("%.1f min", v / 60) end
  return string.format("%.1fs", v)
end

-- A step's chance of a point per craft at its first and its last level: "60>50%". It is worked out level by level.
local function chanceRange(g)
  local a, b = 100 * g.cs[1], 100 * g.cs[#g.cs]
  if floor(a + 0.5) == floor(b + 0.5) then return string.format("%.0f%%", a) end
  return string.format("%.0f>%.0f%%", a, b)
end

-- The same in words, for the pane: "62% to 25%".
local function chanceWords(g)
  local a, b = 100 * g.cs[1], 100 * g.cs[#g.cs]
  if floor(a + 0.5) == floor(b + 0.5) then return string.format("%.0f%%", a) end
  return string.format("%.0f%% to %.0f%%", a, b)
end

-- Every cell of a line in grey: a step of a started plan that is behind you.
local function dimRow(row)
  for _, k in ipairs({ "range", "make", "n", "chance", "each", "c1", "c2", "right", "sells", "left", "time" }) do
    if type(row[k]) == "string" and row[k] ~= "" then row[k] = DIM .. UI.plainText(row[k]) .. "|r" end
  end
  row.done = true
  return row
end

-- The dearest unit price buying `qty` of an item still needs ("pay up to"): the last price step the quantity
-- reaches, or the vendor's price once the listings are used up. nil when it has no price.
local function payUpTo(ctx, item, qty)
  local p = ctx.part(item)
  local stat
  if p then stat = p.buy else stat = ctx.matCost(item).c end
  local sup = ctx.supplyOf(item, stat)
  local got, top = 0, nil
  for _, s in ipairs(sup.steps) do
    if got >= qty - 1e-9 then break end
    top = s[1]
    got = got + s[2]
  end
  if got < qty - 1e-9 and sup.after ~= nil then top = sup.after end
  return top
end
NS.payUpTo = payUpTo

-- Where a recipe is learned: the first trainer or vendor with a known place, else the first (as the line menu's
-- "Pin on map" picks it). Returns the target, "trainer" | "vendor", and "Name, Zone".
local function learnPlace(lr)
  local target, first, word
  if lr.src ~= "R" and NS.trainersOf then
    word = "trainer"
    for _, n in ipairs(NS.trainersOf(lr)) do
      first = first or n
      if not target and n.x and n.y then target = n end
    end
  elseif lr.src == "R" and NS.sourcesOf then
    word = "vendor"
    for _, src in ipairs(NS.sourcesOf(lr)) do
      if src.kind == "v" then
        first = first or src
        if not target and src.x and src.y then target = src end
      end
    end
  end
  target = target or first
  if not target then return nil end
  return target, word, target.name .. ((target.zone and target.zone ~= "") and (", " .. target.zone) or "")
end

-- ---- choices as controls ---------------------------------------------------------------------------------------------

-- How an item is got, as the dropdown reads: the choice made by hand, or "Auto: " and what Auto came to.
local function pickText(S, item, how, part)
  local pick = S.pick[item] or "auto"
  if pick ~= "auto" then return PICK_TEXT[pick] end
  local w = (how == "Craft" and "make") or (how == "Vendor" and "vendor") or (how == "AH" and (part and "buy" or "AH")) or (how == "Have" and "have it") or nil
  return w and ("Auto: " .. w) or "Auto"
end

local PICK_TIP = { "Got by", "Auto takes the cheaper way. Buy and Make force one of them.",
  "Have it: you have them already (farmed or banked), so they cost nothing and are not bought, however many the route uses.",
  "The choice is kept, and every recipe that uses the item follows it." }
local SELL_TIP = { "Sells at", "Auto follows the plan's Sells at; gear on Auto goes to a vendor.",
  "Vendor: counted at vendor value only, for things that do not sell reliably.",
  "Auction house: counted at the cheapest real listing less the cut, up to the AH sales cap share of what is listed; needs it scanned.",
  "The choice is kept, and the route is planned again with it." }

local function pickControl(item, text)
  return { kind = "dropdown", text = text, tip = PICK_TIP, items = function() return NS.rowMenu({ pickItem = item }) end }
end
local function sellControl(item, text)
  return { kind = "dropdown", text = text, tip = SELL_TIP, items = function() return NS.rowMenu({ sellItem = item }) end }
end
local function skipControl(id)
  return { kind = "dropdown", text = settings().exclude[id] and "Skipped" or "Used",
    tip = { "This recipe in routes", "A skipped recipe is never picked by the leveling route. The Settings page lists the skipped ones." },
    items = function()
      local off = settings().exclude[id] == true
      return { { title = true, text = "This recipe in routes" },
        { radio = true, checked = not off, text = "Use it", func = function() NS.setSkip(id, false) end },
        { radio = true, checked = off, text = "Skip it", tip = "The route is planned again without it.", func = function() NS.setSkip(id, true) end } }
    end }
end

-- ---- the lines of a buy list -----------------------------------------------------------------------------------------

-- What to buy, what to make and what you said you have, for a whole route (lv "whole": the choice is a dropdown
-- in the last cell) or for one step (lv "step": the pane has the choices in a block of their own).
-- fz: the list is a started plan's, as it was saved: its prices and ways are the saved ones and it has no choices.
local function shopRows(out, ctx, shop, lv, fz)
  local S = settings()
  local whole = lv == "whole"
  local function pickControl(item, text)   -- (shadows the file's: a started plan's lines have no dropdown)
    if fz then return nil end
    return { kind = "dropdown", text = text, tip = PICK_TIP, items = function() return NS.rowMenu({ pickItem = item }) end }
  end
  for _, b in ipairs(shop.buy) do
    local qty = ceil(b.qty - 1e-9)
    local have = bagCount(b.item)
    local top = b.top
    if top == nil then top = payUpTo(ctx, b.item, b.qty) end
    top = top or nil
    local left = "   " .. qty .. "x " .. itemText(b.item)
    if have > 0 then left = left .. DIM .. "  have " .. have .. (have >= qty and ", enough" or (", buy " .. (qty - have))) .. "|r" end
    local flag = ""
    if b.short and b.short >= 1 then flag = RED .. "  only " .. (qty - floor(b.short + 0.5)) .. " listed|r" end
    local tip = { qty .. " needed" .. (have > 0 and (", " .. have .. " in your bags and bank" .. (have >= qty and ": enough" or (": " .. (qty - have) .. " to buy"))) or "") .. "." }
    if b.cost then
      tip[#tip + 1] = "Pay up to " .. (top and money(top) or "?") .. " each: the dearest listing that quantity still needs. All of them: " .. money(b.cost)
        .. " (" .. money(b.cost / b.qty) .. " each on average)."
    end
    if b.listed then tip[#tip + 1] = b.listed .. " listed at the last scan" end
    tip[#tip + 1] = "Click at the auction house to search for it. Shift-click to link it."
    tip[#tip + 1] = GOLD .. "Right-click for choices|r: Have it, if you have it already (farmed or banked). It then costs nothing and is not bought, however many the route uses."
    local text = pickText(S, b.item, b.how, b.part)
    if fz then text = (b.how == "Vendor" and "vendor") or (b.part and "buy") or "AH" end
    out[#out + 1] = { lv = lv, name = itemText(b.item) .. flag, left = left .. flag, need = tostring(qty), bags = have > 0 and tostring(have) or "",
      c1 = top and money(top) or "", c2 = b.cost and money(b.cost) or (RED .. "no price|r"),
      right = whole and text or nil, control = whole and pickControl(b.item, text) or nil,
      how = b.how, item = b.item, haveItem = b.item, tip = tip }
  end
  for _, m in ipairs(shop.made) do
    local qty = ceil(m.qty - 1e-9)
    local have = bagCount(m.item)
    local text = fz and "make" or pickText(S, m.item, "Craft", true)
    out[#out + 1] = { lv = lv, name = DIM .. "make|r " .. itemText(m.item), left = "   " .. DIM .. "make|r " .. qty .. "x " .. itemText(m.item),
      need = tostring(qty), bags = have > 0 and tostring(have) or "", c2 = DIM .. "part|r",
      right = whole and text or nil, control = whole and pickControl(m.item, text) or nil,
      item = m.item, recipe = m.r and m.r.id or nil, haveItem = m.item,
      tip = { "A part you make yourself for the steps that use it; its materials are in the lines above.",
        GOLD .. "Right-click for choices|r: Buy, Make, or Have it if you have it already (it is then neither made nor bought)." } }
  end
  -- materials set to "have it": listed so the choice can be seen and taken back, never priced
  for _, h in ipairs(shop.have or {}) do
    local qty = ceil(h.qty - 1e-9)
    out[#out + 1] = { lv = lv, name = DIM .. "have it|r " .. itemText(h.item), left = "   " .. DIM .. "have it|r " .. qty .. "x " .. itemText(h.item),
      need = tostring(qty), c2 = DIM .. "not bought|r",
      right = whole and "Have it" or nil, control = whole and pickControl(h.item, "Have it") or nil,
      item = h.item, haveItem = h.item, choice = true,
      tip = { "You said you have this already, so it costs nothing and is not in the totals. Kebold does not check how many you really have.",
        GOLD .. "Click or right-click for choices|r: Auto prices and buys it again." } }
  end
end

-- The Parts block of the Whole route view: every crafted part the route uses, what buying and making one costs,
-- and the choice Auto / Buy / Make / Have it for that part (saved, and used by every recipe that needs it).
local function partRows(out, ctx, shop)
  local S = settings()
  local list, seen = {}, {}
  -- Only parts with a real choice: ones you can make (a bar you cannot smelt is just a material), or ones you
  -- already set by hand.
  local function add(item, qty)
    if seen[item] then return end
    seen[item] = true
    local x = ctx.part(item)
    if x and (x.craft or S.pick[item]) then list[#list + 1] = { item = item, qty = qty } end
  end
  for _, m in ipairs(shop.made) do add(m.item, m.qty) end
  for _, b in ipairs(shop.buy) do
    if b.part then add(b.item, b.qty) end
  end
  for _, h in ipairs(shop.have or {}) do
    if h.part then add(h.item, h.qty) end
  end
  if #list == 0 then return end
  out[#out + 1] = { lv = "whole", left = "" }
  out[#out + 1] = { lv = "whole", left = GOLD .. "Parts: buy or make|r", c1 = DIM .. "buy, each|r", c2 = DIM .. "make, each|r", right = DIM .. "got by|r", section = "parts" }
  for _, p in ipairs(list) do
    local x = ctx.part(p.item) or {}
    local pick = S.pick[p.item] or "auto"
    local forced = (pick == "buy" and not x.buy) or (pick == "craft" and not x.craft)
    local qty = ceil(p.qty - 1e-9)
    local have = bagCount(p.item)
    local text = pickText(S, p.item, x.how, true) .. (forced and (RED .. " n/a|r") or "")
    out[#out + 1] = { lv = "whole", name = itemText(p.item), left = "   " .. qty .. "x " .. itemText(p.item),
      need = tostring(qty), bags = have > 0 and tostring(have) or "",
      c1 = x.buy and money(x.buy) or (RED .. "none listed|r"), c2 = x.craft and money(x.craft) or (DIM .. "cannot make|r"),
      right = text, control = pickControl(p.item, text),
      how = x.how == "Craft" and "make" or (x.how == "Have" and "have it" or "buy"),
      item = p.item, pickItem = p.item, choice = true,
      tip = { "Auto takes the cheaper of buying and making.",
        "Buy: the average of the cheapest listings. Make: its materials at the same prices, plus nothing for your time.",
        "Have it: you have them already (farmed or banked). They cost nothing, take no casts and are not on the shopping list, however many the route uses.",
        forced and "That choice is not possible right now, so the other one is used." or "The choice is kept, and every recipe that uses the part follows it.",
        "Shift-click to link it.", GOLD .. "Use the dropdown, or click or right-click the line.|r" } }
  end
end

-- What a product's sale reads as: the choice made by hand, or "Auto: " and where Auto sends it.
local function sellText(S, r, x)
  local pick = S.sellPick[r.made] or "auto"
  if pick ~= "auto" then return SELL_TEXT[pick] .. (((pick == "ah" and x.way ~= "AH") or (pick == "de" and x.way ~= "DE")) and (RED .. " n/a|r") or "") end
  return "Auto: " .. (NS.wayLong(x.way) or "not counted")
end

-- The Selling block of the Whole route view: every product of the route (and every product you set by hand),
-- what a vendor and the auction house pay, and the choice Auto / Vendor / AH for that one product.
local function sellRows(out, ctx, prof, segs)
  local S = settings()
  if S.sales == "off" then return end
  local list, seen = {}, {}
  for _, g in ipairs(segs) do
    if g.r and not g.stock and g.r.made > 0 and not seen[g.r.made] then
      seen[g.r.made] = true
      list[#list + 1] = g.r
    end
  end
  for _, r in ipairs(data().byProf[prof] or {}) do   -- choices made earlier stay visible when the route moved on
    if r.made > 0 and S.sellPick[r.made] and not seen[r.made] then
      seen[r.made] = true
      list[#list + 1] = r
    end
  end
  if #list == 0 then return end
  out[#out + 1] = { lv = "whole", left = "" }
  out[#out + 1] = { lv = "whole", left = GOLD .. "Where each product sells|r", c1 = DIM .. "vendor, each|r", c2 = DIM .. "auction house, each|r", right = DIM .. "sells at|r", section = "sell" }
  for _, r in ipairs(list) do
    local x = ctx.info(r)
    local ah = x.ahp and (money(x.ahp) .. DIM .. " (" .. (x.listed or 0) .. ")|r") or (DIM .. (x.listed and (x.listed > 0 and "under vendor" or "none listed") or "not scanned") .. "|r")
    local text = sellText(S, r, x)
    out[#out + 1] = { lv = "whole", name = itemText(r.made, r.name), left = "   " .. itemText(r.made, r.name),
      c1 = r.sell and money(r.sell) or (DIM .. "?|r"), c2 = ah, right = text, control = sellControl(r.made, text),
      how = NS.wayLong(x.way) or "not counted",
      item = r.made, sellItem = r.made, choice = true,
      tip = { "Auto follows the plan's Sells at; gear on Auto goes to a vendor.",
        "Vendor: counted at vendor value only, for things that do not sell reliably.",
        "Auction house: counted at the cheapest real listing less the cut, up to the AH sales cap share of what is listed; needs it scanned with enough listed. The number in brackets is how many are listed.",
        "The choice is kept, and the route is planned again with it. Shift-click to link it.", GOLD .. "Use the dropdown, or click or right-click the line.|r" } }
  end
end

-- ---- why a range has no step -----------------------------------------------------------------------------------------

-- Items a recipe needs that have no price at all (parts opened up into their materials).
local function unpriced(ctx, r, into, depth)
  for _, reg in ipairs(r.regs) do
    local id = reg[1]
    local p = ctx.part(id)
    if p then
      if not p.buy and not p.craft then
        into[id] = true
        if p.r and p.r ~= r and depth < 6 then unpriced(ctx, p.r, into, depth + 1) end
      end
    elseif ctx.matCost(id).c == nil then
      into[id] = true
    end
  end
end

-- Why no recipe gives points from skill a to b: which recipes could, and what keeps each of them out.
--   { recipes = could give a point here, noPrice = of those, allowed but a material has no price, items = how many
--     such materials, wider = would be allowed with the Recipes switch set wider, skipped = skipped by hand,
--     lost = cannot be got (a drop nobody lists, the other faction), declined = left out by the route because
--     learning it costs more than it saves, fix = "scan" | "recipes" | nil, text, lines }
local function gapCause(ctx, prof, st, a, b)
  local S = settings()
  local c = { recipes = 0, noPrice = 0, items = 0, wider = 0, skipped = 0, lost = 0, priced = 0, declined = 0 }
  local items = {}
  for _, r in ipairs(data().byProf[prof] or {}) do
    local learn = ctx.learnOf(r)
    if r.col and learn < b and r.grey > max(a, learn) then   -- it could give a point somewhere in the range
      c.recipes = c.recipes + 1
      local known = st.known and st.known[r.id]
      local li = ctx.learnInfo and ctx.learnInfo(r) or nil
      local allowed = ctx.allowed(r)
      if not allowed and S.exclude[r.id] then
        c.skipped = c.skipped + 1
      elseif not allowed and not known and NS.factionLocked and NS.factionLocked(r) then
        c.lost = c.lost + 1
      elseif not allowed and not known and ((r.guess and S.recipes < 3) or (r.src == "R" and S.recipes < 2)) then
        if li == nil or li.cost ~= nil or r.src ~= "R" then c.wider = c.wider + 1 else c.lost = c.lost + 1 end
      elseif not allowed and not (li and li.cost ~= nil) then
        c.lost = c.lost + 1
      elseif ctx.info(r).cost == nil then   -- usable, or left out by the route itself: either way it has no price
        c.noPrice = c.noPrice + 1
        unpriced(ctx, r, items, 0)
      elseif allowed then
        c.priced = c.priced + 1
      else
        c.declined = c.declined + 1   -- the route was better without paying for it
      end
    end
  end
  c.unscanned = 0   -- of those materials, the ones never looked up: a scan helps; the rest were not listed
  for id in pairs(items) do
    c.items = c.items + 1
    if ctx.ladder(id) == nil then c.unscanned = c.unscanned + 1 end
  end
  local function n(v, one, many) return v .. " " .. (v == 1 and one or many) end
  local lines = {}
  if c.noPrice > 0 and c.unscanned > 0 then
    c.fix = "scan"
    c.text = n(c.items, "material", "materials") .. " of " .. n(c.noPrice, "recipe", "recipes") .. (c.items == 1 and " has" or " have") .. " no price: not scanned."
    lines[#lines + 1] = n(c.noPrice, "recipe", "recipes") .. " could give points here,"
    lines[#lines + 1] = "but " .. n(c.items, "material has", "materials have") .. " no price (" .. c.unscanned .. " never scanned)."
    lines[#lines + 1] = GOLD .. "Scan this plan|r at the auction house."
  elseif c.noPrice > 0 then
    c.text = n(c.items, "material", "materials") .. " of " .. n(c.noPrice, "recipe", "recipes") .. (c.items == 1 and " is" or " are") .. " not on the auction house."
    lines[#lines + 1] = n(c.noPrice, "recipe", "recipes") .. " could give points here,"
    lines[#lines + 1] = "but " .. n(c.items, "material was", "materials were") .. " not listed at the last scan."
  end
  if c.wider > 0 then
    if not c.fix then
      c.fix = "recipes"
      c.text = (c.text and (c.text .. " ") or "") .. n(c.wider, "recipe needs", "recipes need") .. " Recipes set wider."
    end
    lines[#lines + 1] = n(c.wider, "more recipe", "more recipes") .. " would count with the " .. GOLD .. "Recipes|r"
    lines[#lines + 1] = "switch set wider (recipe items, unconfirmed sources)."
  end
  if c.priced > 0 and not c.fix then
    c.text = "The recipes priced for it give no point here."
    lines[#lines + 1] = n(c.priced, "recipe is", "recipes are") .. " priced, but none gives a point here."
  end
  if c.declined > 0 then lines[#lines + 1] = n(c.declined, "recipe was", "recipes were") .. " left out: learning costs more than it saves." end
  if c.skipped > 0 then lines[#lines + 1] = n(c.skipped, "recipe is", "recipes are") .. " skipped by you (Settings lists them)." end
  if c.lost > 0 then lines[#lines + 1] = n(c.lost, "recipe", "recipes") .. " cannot be got: not sold, none listed, or the other faction's." end
  if not c.text then
    c.text = c.recipes == 0 and "No recipe in the data gives points here." or "No recipe you can get gives points here."
    if c.recipes == 0 then lines[#lines + 1] = "No recipe in the data gives points in this range." end
  end
  c.lines = lines
  return c
end

-- ---- the model -------------------------------------------------------------------------------------------------------

local function selectStep(g)
  sel.id, sel.from, sel.follow = g.r and g.r.id or false, g.from, false
  paneMode = "step"
  settings().detailOff = nil   -- a click on a step shows it
  NS.refresh()
end

local function stepAction(g, i)
  return function(button)
    if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() and g.r then
      NS.linkRow({ recipe = g.r.id, item = g.r.made > 0 and g.r.made or nil })
      return
    end
    -- a click on the step whose details are showing closes them (the selection stays, and a started plan still
    -- follows the step you are in); with the pane closed, or on another step, it selects and shows
    if NS.detailClick(paneMode == "step" and shownStep ~= nil and shownStep.i == i, button) then return end
    selectStep(g)
  end
end

-- Which step is the selected one: the same recipe at the same start, else the same recipe, else the first step.
local function pickStep(segs, here)
  if here and sel.follow and segs[here] then return here end   -- a started plan nobody clicked in: the step you are in
  local same, first
  for i, g in ipairs(segs) do
    local id = g.r and g.r.id or false
    if sel.id ~= nil and id == sel.id then
      if g.from == sel.from then return i end
      if id and (not same or abs(g.from - sel.from) < abs(segs[same].from - sel.from)) then same = i end
    end
    if g.r and not first then first = i end
  end
  return same or first or (segs[1] and 1 or nil)
end

local function addStepToShopping()
  local s = shownStep
  if not (s and s.r) then return end
  if not NS.shopAdd then
    NS.notice("The Shopping list is not loaded.")
    return
  end
  -- a step of parts made ahead is marked: the Shopping list then counts its crafts once, not once here and once
  -- more under the steps that use the parts
  -- Buy for bad luck (Route settings): the count that covers bad luck 9 times out of 10, and the notice says so
  local n, note = s.n, ""
  local buf = (settings().routeSafe == true and NS.stepBuffer and s.ctx) and NS.stepBuffer(s.ctx, s.g) or nil
  if buf and buf.safe > n then n, note = buf.safe, " Enough for bad luck: " .. buf.safe .. " crafts, where " .. s.n .. " are expected." end
  local ok, err = NS.shopAdd({ kind = "step", prof = s.prof, id = s.r.id, n = n, from = s.g.from, to = s.g.to, stock = s.g.stock and true or nil })
  if ok then
    NS.notice(n .. "x " .. s.r.name .. " (" .. s.g.from .. "-" .. s.g.to .. ") is on the Shopping list." .. note, "info")
  else
    NS.notice("Not added: " .. tostring(err))
  end
end

local function addRouteToShopping()
  local cur = NS.current()
  if not (cur and cur.route) then return end
  if not NS.shopAdd then
    NS.notice("The Shopping list is not loaded.")
    return
  end
  -- A started plan goes on as its own steps (what is left of them), and so does any route with Buy for bad luck
  -- on: the Shopping list's "route" entry plans by itself and would follow neither.
  if (cur.started or settings().routeSafe == true) and NS.addPlanToShopping then
    local n, safe = NS.addPlanToShopping()
    if n > 0 then
      NS.notice((cur.started and "What is left of the started " or "The ") .. cur.prof .. (cur.started and " plan" or " route") .. " is on the Shopping list: " .. n .. (n == 1 and " step" or " steps")
        .. (safe and ", with enough for bad luck 9 times out of 10." or "."), "info")
    else
      NS.notice("Not added: no step is left to make.")
    end
    return
  end
  local ok, err = NS.shopAdd({ kind = "route", prof = cur.prof, from = cur.from, to = cur.to })
  if ok then
    NS.notice("The " .. cur.prof .. " route " .. cur.from .. " to " .. cur.to .. " is on the Shopping list. It follows your skill and the prices.", "info")
  else
    NS.notice("Not added: " .. tostring(err))
  end
end

local function scanPlan()
  local cur = NS.current()
  if cur then NS.scanButton(string.lower(cur.prof)) end
end

-- The pane's lines for the selected step: its figures, what to learn first and where, what to buy, its choices,
-- the other recipes that could do its range.
-- rec = { i, g, need = { { r, text, cost, li, part, tip } }, ranks = { skill, ... }, cause (a range with no recipe) }
-- P, prog: the started plan and where it stands (nil for a plan that is not started). The step of a started plan
-- shows the figures and the buy list it was saved with (g.rec) and has no choices.
local function stepRows(out, ctx, st, prof, rec, route, P, prog)
  local S = settings()
  local g, r = rec.g, rec.g.r
  local sv = g.rec
  local function add(row)
    row.lv = "step"
    out[#out + 1] = row
    return row
  end
  out[#out + 1] = { lv = "step", left = "" }
  if not r then
    add({ left = GOLD .. "Selected step|r  " .. g.from .. "-" .. g.to .. "  no usable recipe", section = "step", stepHead = true, action = function() end })
    add({ left = RED .. "No recipe gives points from " .. g.from .. " to " .. g.to .. ".|r" })
    for _, line in ipairs(rec.cause and rec.cause.lines or {}) do add({ left = line }) end
    for _, b in ipairs(rec.ranks) do add({ left = GOLD .. "At " .. b .. ": train the next rank at a trainer.|r" }) end
    return
  end
  local n = g.all or g.crafts
  local x = ctx.info(r)
  local secs, casts, way = x.secs, x.casts, x.way
  if sv then secs, casts, way = tonumber(sv.secs) or secs, tonumber(sv.casts) or casts, sv.way end
  local buf = NS.stepBuffer and NS.stepBuffer(ctx, g) or nil
  local unsure = buf ~= nil and buf.safe > g.crafts
  add({ left = GOLD .. "Selected step|r  " .. g.from .. "-" .. g.to .. "  " .. n .. "x " .. r.name, section = "step", stepHead = true, action = function() end,
    recipe = r.id, item = r.made > 0 and r.made or nil })
  -- where a started plan stands in this step
  if prog and prog.step == rec.i then
    add({ left = GOLD .. (prog.manual and "At skill " or "You are at ") .. prog.skill .. "|r",
      c2 = prog.left and ("about " .. prog.left .. " more" .. ((prog.safeLeft or 0) > prog.left and (DIM .. ", up to " .. prog.safeLeft .. "|r") or "")) or "", nowLine = true,
      tip = { "Crafts still expected from your skill to the end of this step, from the chance at each level that is left.",
        (prog.safeLeft or 0) > (prog.left or 0) and ("Up to " .. prog.safeLeft .. " if unlucky: enough 9 times out of 10.") or nil } })
  elseif prog and (prog.finished or rec.i < (prog.step or 0)) then
    add({ left = DIM .. "Done: your skill is past this step.|r", done = true })
  end
  if sv and sv.own then
    local was = type(sv.orig) == "table" and data().byId[sv.orig.id or 0] or nil
    add({ left = GOLD .. "*|r Your choice" .. (was and (", instead of " .. was.name) or ""), c2 = "Undo", own = true,
      control = { kind = "button", text = "Undo", w = 60, func = function() NS.undoStep(rec.i) end,
        tip = { "Undo", "Puts the planned recipe back into this step." .. (was and (" (" .. was.name .. ")") or "") } },
      tip = { "You chose this recipe with Use instead. Every other step is as it was planned." } })
  elseif sv and sv.rest then
    add({ left = DIM .. "What is left of this step after your choice above it.|r", c2 = "Undo", rest = true,
      control = { kind = "button", text = "Undo", w = 60, func = function() NS.undoStep(rec.i) end, tip = { "Undo", "Puts the planned recipe back for the whole range." } } })
  end
  add({ left = "Skill", c2 = g.from .. " to " .. g.to .. DIM .. " (" .. (g.to - g.from) .. (g.to - g.from == 1 and " point)|r" or " points)|r") })
  add({ left = "Crafts", c2 = n .. DIM .. string.format(" (%.1f on average)|r", g.exp),
    tip = { string.format("%.1f crafts on average for these %d points, so %d. Luck will vary.", g.exp, g.to - g.from, g.crafts) } })
  if unsure then
    add({ left = "Crafts to be safe", c2 = buf.safe .. DIM .. " (bad luck, 9 in 10)|r", safe = buf.safe,
      tip = { "x" .. g.crafts .. ", up to " .. buf.safe .. " if unlucky.",
        "A craft that is not orange gives a point only some of the time, so " .. g.crafts .. " is an average. " .. buf.safe .. " crafts are enough 9 times out of 10.",
        DIM .. "Worked out from the chance at every level of the step, parts made for it and Working Overtime included.|r" } })
  end
  add({ left = "Chance of a point", c2 = chanceWords(g), tip = { "At the step's first level and at its last. It is worked out level by level (hover the step in the list)." } })
  add({ left = "Casting", c2 = dur(secs) .. " each" .. ((not g.stock) and (", " .. dur(g.time) .. " in all") or ""),
    tip = { "One craft" .. ((casts and casts > 1.0001) and string.format(" is %.1f casts with the parts you make for it", casts) or "") .. ". Casting only: no travel, no buying." } })
  local sales = S.sales
  if P and type(P.set) == "table" and P.set.sales then sales = P.set.sales end
  if g.stock then
    add({ left = "Cost", c2 = DIM .. "in later steps|r", tip = { "These are parts the later steps need anyway. Their materials and casting time are counted in the steps that use them." } })
  else
    add({ left = "Materials", c2 = money(g.cost) .. DIM .. " (" .. money(g.cost / g.crafts) .. " each)|r",
      tip = { sv and "This step's crafts, as they were priced when the plan was started." or "This step's crafts, priced one after another down the listings as the route was planned." } })
    if sales ~= "off" then
      local wayText = NS.wayLong(way)
      local each = (not sv or way == x.way) and (way == "AH" and x.ahp or (way == "DE" and x.drev and x.drev / ctx.makes(r)) or r.sell) or nil
      add({ left = "Sells at", c2 = wayText and (wayText .. (each and (", " .. money(each) .. " each") or "")) or (DIM .. "not counted|r"),
        tip = { "Where this product is counted as sold." .. (P and "" or " Change it under Choices below.") } })
      add({ left = "After sales", c2 = g.net < 0 and (GREEN .. "+" .. money(-g.net) .. "|r") or money(g.net),
        tip = { "The step's materials less what its crafts sell for. A green + is a gain." } })
    end
    if g.over then
      add({ left = RED .. "Above your limit for one point|r", c2 = money(g.net / max(1, g.to - g.from)) .. " a point", over = true,
        tip = { "No recipe at or under the most you will pay for one skill point gives a point here, so this one is used.", "The limit is in Route settings." } })
    end
  end

  -- what to learn or train before it
  if #rec.need > 0 or #rec.ranks > 0 then
    local sum = 0
    for _, e in ipairs(rec.need) do sum = sum + (e.cost or 0) end
    add({ left = "" })
    add({ left = GOLD .. "Learn first|r", c2 = sum > 0 and (GOLD .. money(sum) .. "|r") or "", band = true })
    for _, e in ipairs(rec.need) do
      local lr = e.r
      add({ left = "   " .. lr.name .. (e.part and (DIM .. " (for a part)|r") or "") .. (e.known and (GREEN .. "  learned|r") or ""),
        c2 = e.li.unknown and (RED .. "?|r") or (e.cost and money(e.cost) or (DIM .. "free|r")),
        item = lr.pat > 0 and lr.pat or nil, recipe = lr.id, tip = e.tip })
      add({ left = DIM .. "      " .. e.text .. "|r", tip = e.tip })
      local target, word, where = learnPlace(lr)
      if target then
        add({ left = DIM .. "      " .. word .. ": |r" .. where, c2 = NS.pin and "Pin on map" or "", pin = target,
          control = NS.pin and { kind = "button", text = "Pin on map", w = 76, func = function() NS.pin(target) end,
            tip = { "Pin on map", "Puts a pin on the map at " .. where .. "." } } or nil,
          tip = e.tip })
      end
    end
    for _, b in ipairs(rec.ranks) do
      add({ left = GOLD .. "   At " .. b .. ": train the next rank at a trainer|r" .. (b == g.from and " before this step." or " to go on.") })
    end
  end

  -- what to buy for it
  local shop = (sv and type(sv.shop) == "table") and NS.unpackShop(sv.shop) or ctx.shopping({ { r = r, crafts = n, stock = g.stock } }, true)
  add({ left = "" })
  add({ left = GOLD .. "Buy for this step|r", need = DIM .. "need|r", bags = DIM .. "bags|r", c1 = DIM .. "pay up to|r", c2 = DIM .. "cost|r", band = true })
  shopRows(out, ctx, shop, "step", sv ~= nil)
  add({ left = "   Total", c2 = GOLD .. money(shop.cost) .. "|r",
    tip = { sv and "This step bought on its own, as it was priced when the plan was started."
      or "This step bought on its own. Inside the route it can cost more: earlier steps may have bought the cheapest listings of the same materials." } })
  if unsure then
    add({ left = "   To be safe: " .. buf.safe .. " crafts, " .. (buf.safe - g.crafts) .. " more", c2 = buf.extra and ("+ " .. money(buf.extra)) or (RED .. "not all listed|r"), safeRow = true,
      tip = { "The materials of the " .. (buf.safe - g.crafts) .. " crafts between the average and the count that covers bad luck 9 times out of 10.",
        "Buy for bad luck in Route settings makes Add step to shopping add them." } })
  end

  -- its choices, as dropdowns (a started plan has none: it does not change)
  add({ left = "" })
  add({ left = GOLD .. "Choices|r", band = true })
  if P then
    add({ left = DIM .. "   Fixed while the plan is started. Plan again to change them.|r" })
  else
    if S.sales ~= "off" and r.made > 0 and not g.stock then
      local text = sellText(S, r, x)
      add({ left = "   Sell " .. itemText(r.made, r.name), c2 = text, control = sellControl(r.made, text), item = r.made, sellItem = r.made, choice = true, tip = SELL_TIP })
    end
    local function pick(item, how, part)
      local text = pickText(S, item, how, part)
      add({ left = "   " .. itemText(item), c2 = text, control = pickControl(item, text), item = item, pickItem = item, choice = true, tip = PICK_TIP })
    end
    for _, m in ipairs(shop.made) do pick(m.item, "Craft", true) end
    for _, b in ipairs(shop.buy) do pick(b.item, b.how, b.part) end
    for _, h in ipairs(shop.have or {}) do pick(h.item, "Have", h.part) end
    local skip = skipControl(r.id)
    add({ left = "   This recipe in routes", c2 = skip.text, control = skip, skipRecipe = r.id, tip = skip.tip })
  end

  -- the other recipes that give points here
  if NS.stepAlternates and not g.stock then
    local alts = NS.stepAlternates(ctx, st, prof, route, g)
    add({ left = "" })
    add({ left = GOLD .. "Other recipes for this range|r", need = DIM .. "crafts|r", c1 = DIM .. "after sales|r", band = true, altHead = true,
      tip = { "The next best recipes that give points from " .. g.from .. ", each priced on its own at today's listings, against this step's recipe priced the same way.",
        "Use instead puts one in this step's place and leaves every other step alone." } })
    if #alts == 0 then add({ left = DIM .. "   No other recipe you can get gives points here.|r" }) end
    for _, a in ipairs(alts) do
      local line, why = NS.altLine(a)
      local tip = { a.r.name .. ", " .. a.from .. " to " .. a.to,
        a.crafts .. " crafts, materials " .. money(a.cost) .. ", after sales " .. (a.net < 0 and "+" or "") .. money(a.net) .. ", casting " .. dur(a.time) .. "." }
      if a.dNet and a.dTime then tip[#tip + 1] = "Against " .. r.name .. " over the same levels: " .. (line:match("^(.-) \194\183") or "the same") .. "." end
      tip[#tip + 1] = "Not chosen: " .. why .. "."
      tip[#tip + 1] = a.can and (P and "Use instead: this step only; every other step stays." or "Use instead starts the plan first: a plan that is not started would be planned again and lose the choice.")
        or "Undo your choice for this step before choosing another."
      add({ name = "   " .. COLOUR[ctx.colour(a.r, g.from)] .. a.r.name .. "|r", left = "   " .. a.r.name, need = tostring(a.crafts),
        c1 = a.net < 0 and (GREEN .. "+" .. money(-a.net) .. "|r") or money(a.net), c2 = a.can and "Use instead" or "", alt = a, item = a.r.made > 0 and a.r.made or nil, action = function() end,
        control = a.can and { kind = "button", text = "Use instead", w = 84, func = function()
          local ok, err = NS.useInstead(a.r.id)
          if not ok and err then NS.notice(err) end
        end, tip = { "Use instead", tip[#tip] } } or nil,
        tip = tip })
      add({ left = DIM .. "      " .. line .. "|r", altNote = true, action = function() end, tip = tip })
      add({ left = DIM .. "      " .. why .. "|r", altNote = true, action = function() end, tip = tip })
    end
  end

  -- its actions: the pane's buttons
  add({ left = "Add step to shopping", button = true, action = addStepToShopping })
  add({ left = "Scan", button = true, action = function() NS.scanRecipe(r.id) end })
  add({ left = "Show recipe", button = true, action = function()
    if NS.openPanel then NS.openPanel(r.id) end
  end })
end

-- Every line of the Level page for one profession. Also keeps the route (NS.setCurrent) for /keboldscan route, the
-- footer and the slash commands.
local function buildRoute()
  local current = NS.current()
  local S = settings()
  local out = {}
  local prof = S.prof
  if not prof or not data().byProf[prof] then prof = myProfs()[1] or data().profs[1] end
  S.prof = prof
  local st = profState(prof)
  local from, to, manual = rangeOf(prof, st)
  -- A started plan (LedgerRoute.lua): the route as it was saved. Nothing below plans it again; the skill only says
  -- how far it is.
  local P = NS.startedPlan and NS.startedPlan(prof) or nil
  local prog = P and NS.planProgress(P, st) or nil
  local title = P and string.format("%s  %d > %d  (started)", prof, P.from, P.to) or string.format("%s  %d > %d", prof, from, to)
  shownStep = nil

  if st.skill then
    out[#out + 1] = { lv = "sum", left = DIM .. "Your " .. prof .. ": skill " .. st.skill .. (st.max and (", cap " .. st.max) or "")
      .. (st.nKnown and (", " .. st.nKnown .. " recipes known") or "") .. "." .. (manual and "|r  Planning a range you typed in." or "|r") }
  else
    out[#out + 1] = { lv = "sum", left = DIM .. "Not one of this character's professions (or its window was never opened here): planned as a new character would see it.|r" }
  end

  -- how much of what this plan buys has a price, and how old the prices are
  local items = realmItems()
  local want = E.scanItems(data(), prof, scanScope(prof, st, "none"))
  local got, oldest = 0, nil
  for _, id in ipairs(want) do
    local L = E.parseLadder(items[id])
    if L then
      got = got + 1
      if not oldest or L.day < oldest then oldest = L.day end
    end
  end
  local today = floor(((try(time) or 0) - DAY_ZERO) / 86400)
  local missing = #want - got
  if got == 0 then
    out[#out + 1] = { lv = "sum", status = "prices", level = 4, fix = "scan", missing = missing,
      left = RED .. "No prices yet for what this plan buys.|r Open the auction house and press Scan this plan." }
  else
    local age = oldest and max(0, today - oldest) or 0
    out[#out + 1] = { lv = "sum", status = "prices", level = missing > 0 and 2 or 0, fix = missing > 0 and "scan" or nil, missing = missing,
      left = (missing > 0 and RED or DIM) .. string.format("Prices: %d of %d items scanned, oldest %s.|r", got, #want,
        age == 0 and "today" or (age == 1 and "yesterday" or (age .. " days ago")))
        .. (missing > 0 and (" No price for " .. missing .. (missing == 1 and " item" or " items") .. ": recipes using them are left out. Press Scan this plan.") or "") }
  end

  -- Planning is the slow part, so the route is kept until something it depends on changes: range, cap, recipes
  -- known, settings, a finished scan or a newly seen vendor. Bag changes only redo the cheap lines below.
  local sig = NS.sigOf(prof, st, from, to)
  local kept = current and current.sig == sig and not current.started and current or nil
  -- One context for the route, the Craft page, the details pane and the profession window's block: planBest leaves it set to the paid recipes
  -- the route declined, so a part reads "bought" or "made" the same way everywhere.
  local ctx = kept and kept.ctx or NS.contextFor(prof, st, from, to, sig)

  if P then
    for _, row in ipairs(NS.planBanner(P, prof, st, prog, sig)) do out[#out + 1] = row end
  elseif NS.routeText then
    out[#out + 1] = { lv = "sum", left = DIM .. "Route settings: " .. NS.routeText() .. ".|r" }
  end

  if not P and from >= to then
    NS.setCurrent({ prof = prof, ctx = ctx, st = st, sig = sig, from = from, to = to })
    local atCap = st.max == from and not manual
    local text = atCap and ("You are at " .. from .. ", your cap. " .. (from >= 300 and "There is no rank above it." or "Train the next rank to go on.")) or "Nothing to plan: the target is not above the start."
    out[#out + 1] = { lv = "all", status = "range", level = 1, left = text,
      empty = { icon = BOOK, title = atCap and "At your cap" or "Nothing to plan", text = text } }
    return out, title
  end

  -- planBest: parts made ahead, and a recipe that costs something to learn only when the route is better with it
  local vendorSeen = select(2, vendorPrices())   -- recipe items whose price was seen at a vendor in game
  local route
  if P then
    route = NS.startedRoute(prof)
    NS.planBan(ctx, P)   -- parts read as the plan had them
  else
    route = kept and kept.route or ctx.planBest(prof, from, to)
  end
  -- from / to here stay the plan bar's values (its boxes show them); route.from / route.to are the route's own
  local cur = { prof = prof, ctx = ctx, route = route, st = st, sig = sig, from = from, to = to, started = P }
  NS.setCurrent(cur)
  if not P and NS.routeSeed then NS.routeSeed(cur) end
  if P then from, to = P.from, P.to end   -- from here on: the range of the route shown
  local salesMode = S.sales   -- what the route was planned with: a started plan keeps its own
  if P and type(P.set) == "table" and P.set.sales then salesMode = P.set.sales end
  local tot = route.tot
  local learn = tot.learn or 0
  local function netText(v)
    if salesMode == "off" then return "" end
    return v < 0 and (GREEN .. "+" .. money(-v) .. "|r") or money(v)
  end

  -- rank-ups the range passes (ranks you already hold are not repeated), each with the step it falls in
  local ranks = {}
  for _, b in ipairs(RANKS) do
    if b >= from and b < to and (not st.max or b >= st.max) then ranks[#ranks + 1] = b end
  end

  local steps, recs = {}, {}   -- the lines of the Steps view, and one record per route step for the pane
  local firstStep, toLearn, unknownLearn, learnShown = nil, 0, 0, {}
  local learnList = {}   -- every recipe the route has to learn, in the order it needs them
  local gaps = {}        -- the ranges with no recipe, with why
  for i, g in ipairs(route.segs) do
    local rec = { i = i, g = g, need = {}, ranks = {} }
    recs[i] = rec
    for _, b in ipairs(ranks) do
      if b >= g.from and b < g.to then rec.ranks[#rec.ranks + 1] = b end
    end
    local act = stepAction(g, i)
    local behind = prog ~= nil and (prog.finished or g.to <= prog.skill)   -- a started plan: this step is done
    if not g.r then
      local cause
      if g.rec then   -- a started plan: why it had no recipe then
        local c = type(g.rec.cause) == "table" and g.rec.cause or {}
        cause = { text = g.lost and "The recipe of this step is no longer in Kebold's data." or tostring(c.text or "No recipe gave points here when the plan was started."),
          lines = type(c.lines) == "table" and c.lines or {}, fix = nil }
      else
        cause = gapCause(ctx, prof, st, g.from, g.to)
      end
      rec.cause = cause
      gaps[#gaps + 1] = { g = g, cause = cause }
      local tip = { "No recipe the plan may use, with all its materials priced, gives skill in this range." }
      for _, line in ipairs(cause.lines) do tip[#tip + 1] = line end
      tip[#tip + 1] = "Click for what would help."
      steps[#steps + 1] = { lv = "steps", step = i, gap = true, action = act, tip = tip,
        left = RED .. string.format("%d-%d  no usable recipe gives points here|r", g.from, g.to) .. "  " .. DIM .. cause.text .. "|r" }
      if behind then dimRow(steps[#steps]) end
    else
      local r = g.r
      firstStep = firstStep or g
      -- what has to be learned before this step: its own recipe, and paid recipes for parts it makes
      local need, stepLearn = {}, 0
      if not g.rec then
        if not (st.known and st.known[r.id]) then need[#need + 1] = r end
        for _, e in ipairs(g.learn or {}) do
          if e.r ~= r then need[#need + 1] = e.r end
        end
      else   -- a started plan: what it had to learn then, as it was saved; one learned since says so
        for _, sl in ipairs(type(g.rec.learn) == "table" and g.rec.learn or {}) do
          local lr = type(sl) == "table" and data().byId[sl.id or 0] or nil
          if lr and not learnShown[lr] then
            learnShown[lr] = true
            local cost = tonumber(sl.cost)
            local known = st.known ~= nil and st.known[lr.id] == true
            toLearn = toLearn + 1
            if sl.unk then unknownLearn = unknownLearn + 1 end
            if cost then stepLearn = stepLearn + cost end
            local tip = { known and "You have learned this recipe." or "A recipe to learn.",
              cost and ("+ " .. money(cost) .. " to learn it, as it was priced when the plan was started. It is in To learn, once.")
                or (sl.unk and (RED .. "What it costs was not known: nothing is counted for it.|r") or "Learning it costs nothing that is known.") }
            if NS.whereLines then
              for _, line in ipairs(NS.whereLines(lr)) do tip[#tip + 1] = line end
            end
            local e = { r = lr, text = tostring(sl.text or ""), cost = cost, li = { unknown = sl.unk == true }, at = g.from, part = sl.part == true, known = known, tip = tip }
            learnList[#learnList + 1] = e
            rec.need[#rec.need + 1] = e
          end
        end
      end
      for _, lr in ipairs(need) do
        if not learnShown[lr] then
          learnShown[lr] = true
          local text, cost = learnText(ctx, lr)
          local li = ctx.learnInfo and ctx.learnInfo(lr) or {}
          toLearn = toLearn + 1
          if li.unknown then unknownLearn = unknownLearn + 1 end
          if cost then stepLearn = stepLearn + cost end
          local tip = { st.seen and "You do not know this recipe yet." or "A recipe to learn.",
            cost and ("+ " .. money(cost) .. " to learn it: " .. ((li.how == "trainer" or not li.how) and "the trainer's fee" or (li.how == "vendor" and "the vendor's price for the recipe item"
              or "the recipe item's cheapest listing at the last scan")) .. ". It is in To learn, once.")
            or (li.unknown and (RED .. "What it costs is not known" .. (li.how == "vendor" and " (a vendor sells it, at a price nobody recorded; visit him once and Kebold knows it)" or " (no vendor known, none on the auction house at the last scan)")
              .. ": nothing is counted for it.|r") or "Learning it costs nothing that is known.") }
          if lr.src == "R" and li.vendor and li.ah then tip[#tip + 1] = "Vendor " .. money(li.vendor) .. ", auction house " .. money(li.ah) .. ": the cheaper one is counted." end
          if lr.src == "R" and li.how == "vendor" and not vendorSeen[lr.pat] then tip[#tip + 1] = DIM .. "The vendor price is the original game's, without your discounts; it is replaced once you have seen the vendor.|r" end
          if NS.whereLines then
            for _, line in ipairs(NS.whereLines(lr)) do tip[#tip + 1] = line end
          end
          local e = { r = lr, text = text, cost = cost, li = li, at = g.from, part = lr ~= r, tip = tip }
          learnList[#learnList + 1] = e
          rec.need[#rec.need + 1] = e
        end
      end
      local x = ctx.info(r)
      local tip = { string.format("%.1f crafts on average for these %d points, so %d. Luck will vary.", g.exp, g.to - g.from, g.crafts),
        "Yellow " .. r.y .. ", green " .. (r.g or "?") .. ", grey " .. r.grey .. (r.colEst and " (estimates)" or "") }
      do   -- the chance at every level of the step: it falls as you go, and the count above adds them up
        local lines, line = {}, ""
        for k, pts in ipairs(g.cs) do
          if k > 25 then
            line = line .. "   ..."
            break
          end
          line = line .. (line ~= "" and "   " or "") .. (g.from + k - 1) .. ": " .. string.format("%.0f%%", 100 * pts)
          if k % 5 == 0 then
            lines[#lines + 1] = line
            line = ""
          end
        end
        if line ~= "" then lines[#lines + 1] = line end
        local bonus = ctx.opts.skillBonus
        tip[#tip + 1] = "Chance of a point per craft, level by level" .. ((bonus and bonus > 0) and string.format(" (Working Overtime's +%.0f%% included)", 100 * bonus) or "") .. ":"
        for _, text in ipairs(lines) do tip[#tip + 1] = DIM .. text .. "|r" end
      end
      for _, reg in ipairs(r.regs) do
        local L = ctx.ladder(reg[1])
        local vp = ctx.vendPrice(reg[1])
        tip[#tip + 1] = reg[2] .. "x " .. itemName(reg[1]) .. DIM .. "  " .. ((L and #L.tiers > 0) and ("AH from " .. money(L.tiers[1][1])) or (vp and "" or "no price"))
          .. (vp and ((L and #L.tiers > 0 and ", " or "") .. "vendor " .. money(vp)) or "") .. "|r"
      end
      local sells = ""
      if S.sales ~= "off" then
        local mk = ctx.makes(r)
        tip[#tip + 1] = "Vendor pays " .. (r.sell and (money(r.sell) .. " each") or "nothing known") .. "."
        if x.ahp then
          tip[#tip + 1] = "AH: cheapest real listing " .. money(x.ahp) .. ", " .. (x.listed or 0) .. " listed"
            .. ((x.listed or 0) < 3 and " (too few to count)" or "") .. "."
        elseif S.sales == "best" then
          tip[#tip + 1] = x.listed and "AH: nothing listed at or above vendor value." or "AH: not scanned (Scan this plan looks products up too)."
        end
        if r.gear and x.way ~= "AH" and x.way ~= "DE" and S.sales == "best" and not S.sellPick[r.made] then
          tip[#tip + 1] = DIM .. "Gear counts at vendor value unless you set it to Auction house.|r"
        end
        if x.way == "AH" then
          sells = "AH"
          local share = NS.soldShare(r.made)
          tip[#tip + 1] = GREEN .. "Counted at the AH price less the 5% cut|r, up to " .. (share and string.format("%.0f%% of what is listed (the share of your own auctions of it that sold)", 100 * share) or "the AH sales cap share of what is listed") .. (g.capped and "; this step makes more than that, the rest counts at vendor value." or ".")
          tip[#tip + 1] = DIM .. "Not counted: the deposit you lose when it does not sell, and how long it takes.|r"
        elseif x.way == "Vendor" then
          sells = "vendor"
        elseif x.way == "DE" then
          sells = "disenchant"
          tip[#tip + 1] = GREEN .. "Counted as disenchanted|r: what its disenchant materials sell for at the auction house, after the cut. The disenchant cast is in the step's time."
        end
        if x.cost and x.p then tip[#tip + 1] = "One craft: materials " .. money(x.cost) .. ", sells for " .. money(x.cost + x.p) .. " (" .. mk .. " made)." end
      end
      if S.sales ~= "off" and r.made > 0 and not g.rec then
        tip[#tip + 1] = "Sells at: " .. SELL_TEXT[S.sellPick[r.made] or "auto"] .. (S.sellPick[r.made] and " (your choice)" or "") .. "."
      end
      local secs = x.secs
      if g.rec then   -- a started plan: where it was counted as sold and how long a craft took then
        secs = tonumber(g.rec.secs) or secs
        sells = salesMode ~= "off" and ((g.rec.way == "AH" and "AH") or (g.rec.way == "Vendor" and "vendor") or (g.rec.way == "DE" and "disenchant")) or ""
        table.insert(tip, 1, DIM .. "The step's figures are the started plan's; the prices below are today's.|r")
      end
      if stepLearn > 0 then tip[#tip + 1] = GOLD .. "+ " .. money(stepLearn) .. " to learn|r before this step (the line under it). It is in To learn, not in this step's figures." end
      tip[#tip + 1] = "Time: " .. dur(secs) .. " for one craft" .. ((x.casts and x.casts > 1.0001) and string.format(" (%.1f casts with the parts you make for it)", x.casts) or "")
        .. ", " .. dur(g.time) .. " for the step. Casting only: no travel, no buying."
      tip[#tip + 1] = "Click for this step's details: what to buy, what to learn, its choices. Shift-click to link it."
      tip[#tip + 1] = GOLD .. "Right-click for choices.|r"
      local col = COLOUR[ctx.colour(r, g.from)]
      local row = { lv = "steps", step = i, action = act, menu = true,
        range = g.from .. "-" .. g.to, make = col .. r.name .. "|r", n = tostring(g.crafts), chance = chanceRange(g),
        each = money(g.cost / g.crafts), c2 = money(g.cost), right = netText(g.net), sells = sells ~= "" and (DIM .. sells .. "|r") or "",
        -- the same step as one line of text, for /kebold print
        left = string.format("%d-%d  %s%dx %s|r", g.from, g.to, col, g.crafts, r.name),
        c1 = chanceRange(g) .. "  " .. money(g.cost / g.crafts) .. " each",
        time = dur(secs) .. " / " .. dur(g.time),   -- one craft with the parts made for it / the whole step
        item = r.made > 0 and r.made or nil, recipe = r.id, tip = tip,
        sellStep = (S.sales ~= "off" and r.made > 0 and not P) and r.made or nil }
      steps[#steps + 1] = row
      if g.stock then   -- parts for later steps, made now while they still give skill
        if not g.rec then   -- (a started plan saved the number)
          local all = ceil((route.need and route.need[r] or 0) / ctx.makes(r) - 1e-6)
          g.all = max(all, g.crafts)
        end
        g.all = g.all or g.crafts
        row.n = tostring(g.all)
        row.make = col .. r.name .. "|r" .. GOLD .. "  parts for later|r"
        row.left = string.format("%d-%d  %s%dx %s|r", g.from, g.to, col, g.all, r.name) .. GOLD .. "  parts for later steps|r"
        row.c1, row.each = chanceRange(g), ""
        row.c2, row.right, row.sells, row.sellStep, row.time = DIM .. "in later steps|r", "", "", nil, nil
        row.tip = { "The steps below need " .. g.all .. " of these as parts. Make them all now: while the recipe still gives skill they",
          "level you for nothing extra. About " .. g.crafts .. " of them take you from " .. g.from .. " to " .. g.to .. ".",
          "Their materials and casting time are counted in the steps that use them, so this line shows no cost.",
          "Click for this step's details. Shift-click to link it.", GOLD .. "Right-click for choices.|r" }
      end
      -- a count for bad luck: the Crafts cell ends in ~ (an estimate) and the tooltip has both counts
      local buf = NS.stepBuffer and NS.stepBuffer(ctx, g) or nil
      if buf and buf.safe > g.crafts then
        row.safe = buf.safe
        row.n = row.n .. DIM .. "~|r"
        table.insert(row.tip, 2, "x" .. g.crafts .. ", up to " .. buf.safe .. " if unlucky: enough 9 times out of 10."
          .. (buf.extra and (" The extra materials would cost about " .. money(buf.extra) .. ".") or ""))
      end
      if g.over then   -- above the most one skill point may cost (Route settings), used because nothing else gives a point
        row.over = true
        row.make = row.make .. RED .. "  over your limit|r"
        row.left = row.left .. RED .. "  over your limit for one point|r"
        table.insert(row.tip, 2, RED .. "Above the most you will pay for one skill point|r (" .. money(g.net / max(1, g.to - g.from)) .. " a point): no cheaper recipe gives a point here.")
      end
      if g.rec and (g.rec.own or g.rec.rest) then   -- your own choice (Use instead), or what it left of the planned step
        row.own = g.rec.own and true or nil
        if g.rec.own then
          row.make = row.make .. GOLD .. " *|r"
          row.left = row.left .. GOLD .. " *|r"
          table.insert(row.tip, 2, GOLD .. "* Your choice|r, in place of the recipe the plan had here. The step's details have Undo.")
        end
      end
      if behind then
        dimRow(row)
      elseif prog and prog.step == i then
        row.now = true
      end
      -- its second lines: what to learn before it
      for _, e in ipairs(rec.need) do
        local lr = e.r
        steps[#steps + 1] = { lv = "steps", step = i, sub = true, learnStep = true, learnCost = e.cost, action = act, menu = true,
          left = "      " .. GOLD .. "learn|r first: " .. lr.name .. (e.part and (DIM .. " (makes a part for this step)|r") or "") .. DIM .. ": " .. e.text .. "|r"
            .. (e.known and (GREEN .. "  learned|r") or (e.li.unknown and (RED .. "  + ? to learn|r") or (e.cost and (GOLD .. "  + " .. money(e.cost) .. " to learn|r") or ""))),
          recipe = lr.id, tip = e.tip }
        if behind then dimRow(steps[#steps]) end
      end
      if prog and prog.step == i and not prog.finished then   -- where you are in it
        steps[#steps + 1] = { lv = "steps", step = i, sub = true, nowLine = true, action = act,
          left = "      " .. GOLD .. "you are here|r: skill " .. prog.skill .. (prog.left and (", about " .. prog.left .. " more " .. (prog.left == 1 and "craft" or "crafts") .. " to " .. g.to
            .. (((prog.safeLeft or 0) > prog.left) and (DIM .. " (up to " .. prog.safeLeft .. " if unlucky)|r") or "")) or ""),
          tip = { "Crafts still expected from your skill to the end of this step, from the chance at each level that is left.",
            "This only marks progress: the plan itself does not change." } }
      end
    end
    for _, b in ipairs(rec.ranks) do
      steps[#steps + 1] = { lv = "steps", step = i, sub = true, rank = b, action = act,
        left = GOLD .. "      At " .. b .. ": train the next rank at a trainer|r" .. (b == g.from and " before this step." or " to go on."),
        tip = { "Your skill stops at " .. b .. " until a trainer teaches the next rank." } }
      if behind then dimRow(steps[#steps]) end
    end
  end

  -- the whole route's buy list: a started plan's is the one it was saved with
  local whole = firstStep and ((P and NS.unpackShop(P.shop)) or ctx.shopping(route.segs)) or nil
  cur.recs, cur.whole, cur.ranks = recs, whole, ranks   -- what Start this plan saves (LedgerRoute.lua)

  -- the six figures, and how they relate
  do
    local points, covered = to - from, to - from - tot.gaps
    local sales = tot.cost - tot.net
    local function sum(key, name, value, tip)
      table.insert(tip, 1, name)
      out[#out + 1] = { lv = "sum", sum = key, left = name, right = value, tip = tip }
    end
    sum("points", "Points covered", (tot.gaps > 0 and RED or "") .. covered .. " of " .. points .. (tot.gaps > 0 and "|r" or ""),
      { "Skill points the steps cover, of the " .. points .. " from " .. from .. " to " .. to .. ".",
        tot.gaps > 0 and (RED .. tot.gaps .. (tot.gaps == 1 and " point has" or " points have") .. " no step|r: the status line says why.") or "Every point has a step." })
    sum("crafts", "Crafts", tostring(tot.crafts), { "Whole crafts, each step rounded up from its average. Luck will vary.",
      "Parts you make for a step are not in this number; their casts are in Casting." })
    sum("time", "Casting", "about " .. ceil(tot.time / 60) .. " min", { "Casting time of every craft and of the parts made for them.", DIM .. "Not counted: travel, buying, posting.|r" })
    do
      local tip = { "What the steps' crafts buy: the Step cost column added up.", "Recipes to learn are not in this figure; they are in To learn." }
      if whole and abs(whole.cost - tot.cost) >= 1 then
        tip[#tip + 1] = "The Whole route buy list comes to " .. money(whole.cost) .. ": the steps are priced one after another as the route was planned, the list in one go over the whole quantity."
      elseif whole then
        tip[#tip + 1] = "The Whole route buy list adds up to the same."
      end
      -- what buying for bad luck would add (the totals themselves stay on the average counts)
      local add = (firstStep and NS.routeBuffer) and NS.routeBuffer(ctx, route) or nil
      if add and add.steps > 0 then
        tip[#tip + 1] = add.steps .. (add.steps == 1 and " step has" or " steps have") .. " a chance of a point below 100% (marked ~). Buying enough for bad luck 9 times out of 10 on "
          .. (add.steps == 1 and "it" or "all of them") .. " would add about " .. money(add.extra) .. (add.unknown > 0 and (", and more for " .. add.unknown .. " whose extra materials are not all listed") or "") .. "."
      end
      sum("mats", "Materials", money(tot.cost), tip)
    end
    do
      local tip = { "Trainer fees and recipe items (a vendor's price or the cheapest listing), each once, at the step that first needs it.",
        "A recipe that costs something is only used when the route is better with it bought than without it." }
      if unknownLearn > 0 then
        tip[#tip + 1] = RED .. unknownLearn .. (unknownLearn == 1 and " recipe on the way has" or " recipes on the way have") .. " a price nobody knows (marked ?): this figure is short by that much.|r"
      end
      local w = route.without
      if w and learn > 0 then
        tip[#tip + 1] = DIM .. "Learning nothing that costs anything: materials " .. money(w.cost) .. (S.sales ~= "off" and (", after sales " .. (w.net < 0 and "+" or "") .. money(w.net)) or "")
          .. ", " .. w.crafts .. " crafts" .. (w.gaps > 0 and (", and " .. w.gaps .. " points with no recipe at all") or "") .. ".|r"
      end
      local value = learn > 0 and money(learn) or (toLearn > 0 and (DIM .. "free|r") or (DIM .. "nothing|r"))
      if unknownLearn > 0 then value = (learn > 0 and (money(learn) .. " ") or "") .. RED .. "+ ?|r" end
      sum("learn", "To learn", value .. (toLearn > 0 and (DIM .. "  (" .. toLearn .. ")|r") or ""), tip)
    end
    if salesMode ~= "off" then
      sum("net", "After sales", netText(tot.net + learn),
        { "Materials " .. money(tot.cost) .. (learn > 0 and (" + learning recipes " .. money(learn)) or "") .. " - what the crafts sell for " .. money(sales) .. ".",
          "A green + is a gain; without it this is what the route costs you in the end.",
          DIM .. "Not counted: travel, the auction house deposit, recipes whose price is unknown (marked ?).|r" })
    else
      sum("net", "In all", money(tot.cost + learn),
        { "Materials " .. money(tot.cost) .. (learn > 0 and (" + learning recipes " .. money(learn)) or "") .. ". Sales are not counted (Sells at: not counted).",
          DIM .. "Not counted: travel, recipes whose price is unknown (marked ?).|r" })
    end
  end

  -- what is wrong with the plan, worst first: every range with no step says which kind of thing is missing
  for _, x in ipairs(gaps) do
    out[#out + 1] = { lv = "sum", status = "gap", level = 3, fix = x.cause.fix, from = x.g.from, to = x.g.to, cause = x.cause,
      left = RED .. x.g.from .. "-" .. x.g.to .. ": no step.|r " .. x.cause.text, tip = x.cause.lines }
  end
  if tot.gaps > 0 then
    out[#out + 1] = { lv = "sum", left = RED .. tot.gaps .. (tot.gaps == 1 and " point has" or " points have") .. " no step.|r" }
  end
  if toLearn > 0 then
    out[#out + 1] = { lv = "sum", left = DIM .. toLearn .. (toLearn == 1 and " recipe" or " recipes") .. " to learn on the way, " .. (learn > 0 and (money(learn) .. " in all") or "free")
      .. (unknownLearn > 0 and (RED .. ", " .. unknownLearn .. " with an unknown price|r") or "") .. DIM .. ".|r" }
  end

  if not firstStep then
    -- nothing at all can be made: the views show one message with the button that helps, not a list of ranges
    for _, row in ipairs(steps) do row.lv = "gaps" end
    for _, row in ipairs(steps) do out[#out + 1] = row end
    local cause = gaps[1] and gaps[1].cause or nil
    local fix = got == 0 and "scan" or (cause and cause.fix) or nil
    local text = got == 0 and "Nothing this plan buys has a price yet. Open the auction house and press Scan this plan."
      or ("No recipe gives points from " .. from .. " to " .. to .. ". " .. (cause and cause.text or ""))
    out[#out + 1] = { lv = "all", left = text, empty = { icon = BOOK, title = got == 0 and "No prices yet" or "No route",
      text = text, button = fix == "scan" and (NS.scanLabel and NS.scanLabel("plan") or "Scan this plan") or nil, onClick = fix == "scan" and scanPlan or nil } }
    return out, title
  end
  for _, row in ipairs(steps) do out[#out + 1] = row end

  -- under the steps: what the whole route needs (owner 2026-11-10: "not showing the items needed at the bottom
  -- anymore"). The same lines as the Whole route view's buy list, in the steps' columns; the choices stay there.
  do
    local need = {}
    shopRows(need, ctx, whole, "steps", P ~= nil)
    if #need > 0 then
      out[#out + 1] = { lv = "steps", left = "" }
      out[#out + 1] = { lv = "steps", range = "", make = GOLD .. "Materials for the whole route|r  " .. DIM .. from .. " to " .. to .. "|r",
        left = GOLD .. "Materials for the whole route|r  " .. from .. " to " .. to, each = DIM .. "pay up to|r", c2 = GOLD .. money(whole.cost) .. "|r",
        section = "need", needHead = true,
        tip = { "Everything the route's crafts buy, each item priced once over the whole quantity.",
          "Click to fold. The choices for each item (buy, make, have it) are in a right-click and in the Whole route view." } }
      for _, row in ipairs(need) do
        row.range, row.make, row.each, row.needRow = "", (row.left:gsub("^%s+", "")), row.c1, true
        out[#out + 1] = row
      end
    end
  end

  -- the Whole route view: the buy list, the choices, the recipes to learn
  out[#out + 1] = { lv = "whole", left = GOLD .. "Buy for the whole route|r  " .. from .. " to " .. to, c2 = GOLD .. money(whole.cost) .. "|r", section = "whole",
    tip = { "Everything the route's crafts buy, each item priced once over the whole quantity.",
      "Recipes to learn (" .. (learn > 0 and money(learn) or "nothing") .. ") are in their own section below, not in this figure.",
      abs(whole.cost - tot.cost) >= 1 and ("The steps add up to " .. money(tot.cost) .. " (Materials): they are priced one after another as the route was planned.") or "The same as Materials above." } }
  out[#out + 1] = { lv = "whole", left = "Add route to shopping", button = true, action = addRouteToShopping }
  shopRows(out, ctx, whole, "whole", P ~= nil)
  if P then   -- a started plan has no choices: they would not change it
    out[#out + 1] = { lv = "whole", left = "" }
    out[#out + 1] = { lv = "whole", left = DIM .. "Parts and where products sell are fixed while the plan is started. Plan again to change them.|r", fixed = true }
  else
    partRows(out, ctx, whole)
    sellRows(out, ctx, prof, route.segs)
  end
  -- every recipe to learn in one place, with where to get it: the list to take to the trainers
  if #learnList > 0 then
    out[#out + 1] = { lv = "whole", left = "" }
    out[#out + 1] = { lv = "whole", left = GOLD .. "Recipes to learn|r  " .. DIM .. #learnList .. " on the way, in the order the route needs them|r",
      c2 = GOLD .. money(learn) .. "|r", section = "learn" }
    for _, e in ipairs(learnList) do
      local lr = e.r
      local target, word, where = learnPlace(lr)
      local tip = { "Needed from skill " .. e.at .. ". Click for the recipe's details.", GOLD .. "Right-click for choices|r, a map pin among them." }
      for k = 3, #e.tip do tip[#tip + 1] = e.tip[k] end
      out[#out + 1] = { lv = "whole", left = "   " .. lr.name .. DIM .. "  at " .. e.at .. ": " .. e.text .. (where and ("  -  " .. where) or "") .. "|r",
        c2 = e.li.unknown and (RED .. "?|r") or (e.cost and money(e.cost) or (DIM .. "free|r")),
        right = (target and NS.pin) and "Pin on map" or "", where = where or "", pin = target,
        control = (target and NS.pin) and { kind = "button", text = "Pin on map", func = function() NS.pin(target) end,
          tip = { "Pin on map", "Puts a pin on the map at the " .. word .. ": " .. where .. "." } } or nil,
        item = lr.pat > 0 and lr.pat or nil, recipe = lr.id, learnRow = true, tip = tip }
    end
  end

  -- the selected step, for the pane
  local at = pickStep(route.segs, prog and not prog.finished and prog.step or nil)
  if at then
    local g = route.segs[at]
    shownStep = { i = at, g = g, r = g.r, n = g.r and (g.all or g.crafts) or 0, prof = prof, ctx = ctx }
    stepRows(out, ctx, st, prof, recs[at], route, P, prog)
  end
  return out, title
end

NS.buildRoute = buildRoute

-- ---- the page --------------------------------------------------------------------------------------------------------

-- The Steps view: one figure per cell. With the details pane open the list is narrow, and Each, Sells, Chance and
-- (at the smallest window) Step cost give way in that order. Widths are stated for compact rows; the kit scales them.
local STEP_COLS = {
  { key = "range", title = "Skill", width = 56, tip = { "Skill", "The skill points this step covers. A route is ordered by skill, so it cannot be sorted." } },
  { key = "make", title = "Make", flex = 1, min = 100, tip = { "Make", "The recipe, in the colour it has at the step's first point.", "Click a step and its details show beside the list." } },
  { key = "n", title = "Crafts", width = 40, align = "RIGHT", tip = { "Crafts", "How many to make: the average for these points, rounded up." } },
  { key = "chance", title = "Chance", width = 60, align = "RIGHT", drop = 2, tip = { "Chance of a point", "The chance of a point per craft at the step's first and at its last point." } },
  { key = "each", title = "Each", width = 66, align = "RIGHT", drop = 4, tip = { "Each", "What one craft's materials cost in this step." } },
  { key = "c2", title = "Step cost", width = 72, align = "RIGHT", drop = 1, tip = { "Step cost", "The materials of the step's crafts. They add up to Materials above." } },
  { key = "right", title = "After sales", width = 80, align = "RIGHT", tip = { "After sales", "Step cost less what the crafts sell for. A green + is a gain." } },
  { key = "sells", title = "Sells at", width = 56, drop = 3, tip = { "Sells at", "Where the product is counted as sold: a vendor or the auction house." } },
}
-- The Whole route view: a buy list's cells; the last one is the line's choice, as a dropdown.
local WHOLE_COLS = {
  { key = "name", title = "Item", flex = 1, min = 112, tip = { "Item", "Click a section head to fold it." } },
  { key = "need", title = "Need", width = 36, align = "RIGHT", tip = { "Need", "Units the whole route uses." } },
  { key = "bags", title = "In bags", width = 44, align = "RIGHT", drop = 2, tip = { "In bags", "What you carry and have banked." } },
  { key = "c1", title = "Pay up to", width = 70, align = "RIGHT", drop = 1, tip = { "Pay up to", "The dearest listing the quantity still needs. Under Parts and Selling: what the head of the section says." } },
  { key = "c2", title = "Cost", width = 72, align = "RIGHT", tip = { "Cost", "All of them, down the listings." } },
  { key = "right", title = "Choice", width = 96, tip = { "Choice", "How the item is got, or where the product sells." } },
}
-- The pane: the selected step. Its buy list has the same cells without the choice (the choices are a block of
-- their own, with a dropdown over the end of the line).
local PANE_COLS = {
  { key = "name", flex = 1, min = 96 },
  { key = "need", width = 30, align = "RIGHT" },
  { key = "bags", width = 30, align = "RIGHT", drop = 2 },
  { key = "c1", width = 62, align = "RIGHT", drop = 1 },
  { key = "c2", width = 70, align = "RIGHT" },
}
local PANE_HEAD, PANE_FOOT, CONTROL_W = 54, 30, 104
local SUMS = { "points", "crafts", "time", "mats", "learn", "net" }
-- The page's own bar: one row of controls (26 px), then the strip of figures. What is wrong with the plan is the
-- window's footer line on this page, beside the scan buttons, so the list gets the height.
local SUM_Y, SUM_H = 30, 46
local ROUTE_W = 150   -- the Route settings button: "Route: balanced, limit"
local FOOT = { route = 116, fix = 106, gap = 4 }   -- the footer's own buttons: Scan this route, and the fix for a range with no step

-- Real controls over a table's lines: a line whose row carries `control` gets a dropdown (or a button, or a
-- number box with - and +) over its last cell. The widgets belong to the line and are made the first time a line
-- needs one.
local function placeControl(t, b, c, last)
  local dd, bt, sp = rawget(b, "ctlDrop"), rawget(b, "ctlBtn"), rawget(b, "ctlStep")
  if type(dd) == "table" then dd:Hide() end
  if type(bt) == "table" then bt:Hide() end
  if type(sp) == "table" then sp:Hide() end
  if not c then return end
  local w = max(c.w or 0, t.ws[last] or 0, 60)
  if t.opts.controlW then w = max(c.w or 0, t.opts.controlW) end
  local widget
  if c.kind == "stepper" then   -- "I'm at skill": the line's own number, typed or stepped
    if type(sp) ~= "table" then
      sp = UI.stepper(b, { w = 44, min = function()
        local cc = type(sp) == "table" and rawget(sp, "ctl") or nil
        return cc and cc.min or nil
      end, max = function()
        local cc = type(sp) == "table" and rawget(sp, "ctl") or nil
        return cc and cc.max or nil
      end }, function()
        local cc = type(sp) == "table" and rawget(sp, "ctl") or nil
        return cc and cc.get and cc.get() or 0
      end, function(v)
        local cc = type(sp) == "table" and rawget(sp, "ctl") or nil
        if cc and cc.set then cc.set(v) end
      end)
      b.ctlStep = sp
    end
    sp.ctl = c
    w = UI.widthOf(sp)   -- the stepper's real width (it was a number written here)
    sp:ClearAllPoints()
    sp:SetPoint("LEFT", b, "LEFT", (t.xs[last] or 0) + (t.ws[last] or 0) - w, 0)
    sp:Refresh()
    sp:Show()
    local cell = b.cells and b.cells[last]
    if type(cell) == "table" and last > 1 then cell:SetText("") end
    return
  end
  if c.kind == "button" then
    if type(bt) ~= "table" then
      bt = UI.button(b, "", w, function(self)
        local cc = rawget(self, "ctl")
        if cc and cc.func then cc.func(self) end
      end)
      b.ctlBtn = bt
    end
    widget = bt
    bt:SetLabel(c.text or "")
  else
    if type(dd) ~= "table" then
      dd = UI.dropdown(b, w, function()
        local cc = rawget(dd, "ctl")
        return cc and cc.text or ""
      end, function()
        local cc = rawget(dd, "ctl")
        return cc and cc.items and cc.items() or {}
      end)
      b.ctlDrop = dd
    end
    widget = dd
  end
  widget.ctl = c
  widget.tip = c.tip
  widget:SetSize(w, min(t.rowH, UI.density().ctl))   -- a control is as tall as the line, a red button 22 at most
  widget:ClearAllPoints()
  widget:SetPoint("LEFT", b, "LEFT", (t.xs[last] or 0) + (t.ws[last] or 0) - w, 0)
  if widget.Refresh and c.kind ~= "button" then widget:Refresh() end
  widget:Show()
  local cell = b.cells and b.cells[last]
  if type(cell) == "table" then cell:SetText("") end   -- the control says it
end

local function withControls(t)
  local paint = t.Paint
  function t:Paint()
    paint(self)
    local last = #self.columns
    while last > 1 and not self.shown[last] do last = last - 1 end
    for _, b in ipairs(self.lines) do
      local row = rawget(b, "row")
      placeControl(self, b, (row and b:IsShown() and type(row.control) == "table") and row.control or nil, last)
    end
  end
  return t
end

-- The step pane: a head (icon, the step, one line of facts), the step's lines, three buttons.
local function buildPane(host)
  local p = CreateFrame("Frame", "KeboldsShinyStepPane", host)
  p:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
  p:SetSize(NS.WIN.detail, 300)
  p.caption = UI.text(p, "dim", "This step")
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
  p.list = withControls(UI.table(p, PANE_COLS, { header = false, controlW = CONTROL_W,
    onClick = function(b, button) NS.rowClick(b, button) end, onEnter = function(b) NS.rowEnter(b) end, onLeave = function(b) NS.rowLeave(b) end,
    empty = { icon = BOOK, title = "No step selected", text = "Click a step in the list and what it needs shows here: what to learn first, what to buy, its choices." } }))
  p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -PANE_HEAD)
  p.bShop = UI.button(p, "Add step to shopping", 132, addStepToShopping,
    { "Add step to shopping", "Puts this step's crafts on the Shopping list as they are planned now: its materials, with the parts you make opened up into theirs." })
  p.bShop:SetPoint("BOTTOMLEFT", 2, 3)
  p.bScan = NS.scanControl(UI.button(p, "Scan", 50, function()
    if shownStep and shownStep.r then NS.scanRecipe(shownStep.r.id) end
  end, { "Scan", "Reads fresh auction house prices for what this step makes and everything needed to make it (a few seconds)." }))
  p.bScan:SetPoint("LEFT", p.bShop, "RIGHT", 3, 0)
  p.bRecipe = UI.button(p, "Show recipe", 96, function()
    if shownStep and shownStep.r and NS.openPanel then NS.openPanel(shownStep.r.id) end
  end, { "Show recipe", "The recipe's own details: materials, how many are worth making, the price steps.", "Click the step in the list to come back here." })
  p.bRecipe:SetPoint("LEFT", p.bScan, "RIGHT", 3, 0)
  p.rows, p.w, p.h = {}, NS.WIN.detail, 300
  function p:Layout(w, h)
    self.w, self.h = w, h
    self:SetSize(w, h)
    self.name:SetWidth(w - 46)
    self.sub:SetWidth(w - 46)
    self.list:Layout(w, max(40, h - PANE_HEAD - PANE_FOOT))
  end
  -- rows: the model's lines of the selected step; s = the step they are for (nil: nothing to show)
  function p:Fill(rows, s)
    local view = {}
    for _, row in ipairs(rows) do
      if row.lv == "step" and not row.button and not row.stepHead then view[#view + 1] = row end
    end
    while view[1] and UI.blankRow(view[1]) do table.remove(view, 1) end
    while #view > 0 and UI.blankRow(view[#view]) do view[#view] = nil end
    self.rows = view
    local r = s and s.r or nil
    local tex = (r and not UI.plain() and settings().icons ~= false) and UI.iconOf({ item = r.made > 0 and r.made or nil, recipe = r.id }) or nil
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
    if not s then
      self.name:SetText("")
      self.sub:SetText("")
    elseif r then
      self.name:SetText(s.n .. "x " .. r.name)
      self.sub:SetText("skill " .. s.g.from .. " to " .. s.g.to .. " \194\183 step " .. s.i)
    else
      self.name:SetText(RED .. "No usable recipe|r")
      self.sub:SetText("skill " .. s.g.from .. " to " .. s.g.to)
    end
    for _, b in ipairs({ self.bShop, self.bRecipe }) do
      if r then b:Show() else b:Hide() end
    end
    if r then self.bScan:Show() else self.bScan:Hide() end
    if r then self.bShop:SetEnabled(NS.shopAdd ~= nil, "The Shopping list is not loaded.") end
    self.list:SetRows(view)
  end
  return p
end

local function scanTip(title, text)
  return function()
    return { title, text, NS.atAuctionHouse() and "Keep the auction house open while it runs." or nil }
  end
end

-- Puts the strip's cells and the status line where the page's width says.
local function place(pg, w)
  if type(pg.cells) ~= "table" then return end
  local n, gap = #SUMS, 4
  local cw = floor((w - gap * (n - 1)) / n)
  for k, cell in ipairs(pg.cells) do
    cell:ClearAllPoints()
    cell:SetPoint("TOPLEFT", pg.bar, "TOPLEFT", (k - 1) * (cw + gap), -SUM_Y)
    cell:SetSize(cw, SUM_H)
    cell.value:SetWidth(cw - 10)
    cell.label:SetWidth(cw - 10)
  end
  local s = pg.split
  if type(pg.pane) == "table" and type(s) == "table" and s.rightW > 0 then pg.pane:Layout(s.rightW, s.h) end
end

local function setView(v)
  settings().levelView = v == "whole" and "whole" or nil
  if page and type(page.table) == "table" then page.table.offset = 0 end
  NS.refresh()
end

page = NS.page({ key = "route", title = "Level", order = 1, icon = BOOK,
  tip = { "Level", "The way from one skill to another, step by step, with what to buy for it. Start a plan and it stays as it is while you level." },
  plan = true, bars = 1, barH = SUM_Y + SUM_H, detail = true,
  columns = STEP_COLS,
  empty = { icon = BOOK, title = "No route", text = "Choose a profession and a range above." },
  rows = function() return buildRoute() end,
  -- which of the model's lines the table shows: the steps, or the whole route's sections
  view = function(pg, rows)
    local v = viewOf()
    local cols = v == "whole" and WHOLE_COLS or STEP_COLS
    if pg.table.columns ~= cols then pg.table:SetColumns(cols) end
    local out = {}
    for _, row in ipairs(rows) do
      if (row.lv == v or row.lv == "all") and not row.button then out[#out + 1] = row end
    end
    while out[1] and UI.blankRow(out[1]) do table.remove(out, 1) end
    while #out > 0 and UI.blankRow(out[#out]) do out[#out] = nil end
    return out
  end,
  selected = function(row)
    if paneMode == "recipe" and NS.detailRecipe and NS.detailRecipe() ~= nil then return row.recipe ~= nil and NS.detailRecipe() == row.recipe end
    return row.step ~= nil and shownStep ~= nil and row.step == shownStep.i
  end,
  build = function(pg)
    local at = pg.at
    withControls(pg.table)
    -- the one row of controls: the two views, start / forget the plan, plan again, the plan as text, the route onto
    -- the Shopping list, and at its right end the Route settings button. It must stay one line: the strip of
    -- figures sits right under it (the bar's height is stated, so a wrapped row would lie over the strip).
    pg.bSteps = at.put(UI.button(pg.bar, "Steps", 56, function() setView("steps") end,
      { "Steps", "The route step by step. Click a step and what it needs shows beside the list." }), 2)
    pg.bWhole = at.put(UI.button(pg.bar, "Whole route", 86, function() setView("whole") end,
      { "Whole route", "Everything the route buys, its choices (parts, where products sell) and the recipes to learn." }), 12)
    -- Start this plan / Forget plan: one button, the plan is either started or it is not
    pg.bStart = at.put(UI.button(pg.bar, "Start this plan", 104, function()
      if NS.startedPlan() then
        NS.confirm("Forget the plan you started? The page goes back to planning as you go: from your skill, at the prices of the last scan.", "Forget plan", function() NS.stopPlan() end)
      else
        local P, why = NS.startPlan()
        if not P and why then NS.notice(why) end
      end
    end, function()
      if NS.startedPlan() then
        return { "Forget plan", "Stops following the started plan. The page then plans as you go again: every skill point, scan and setting can change the route." }
      end
      return { "Start this plan", "Keeps the route on screen exactly as it is. Prices, scans, bags, new recipes, your skill and the plan bar no longer change it.",
        "Your skill marks the steps that are done and counts the crafts left in the one you are in.", "Plan again makes a new plan; Forget plan goes back to planning as you go." }
    end))
    pg.bRefresh = at.put(UI.button(pg.bar, "Plan again", 76, function()
      if NS.planAgain then
        NS.planAgain()   -- a started plan: asks once, then plans from the skill and the settings of now
      else
        NS.bump()
        NS.refresh()
      end
    end, function()
      if NS.startedPlan and NS.startedPlan() then
        return { "Plan again", "The only way a started plan changes: asks once, then plans from your skill and the settings of now. The new plan is not started." }
      end
      return { "Plan again", "Plans the route again from scratch." }
    end))
    pg.bCopy = at.put(UI.button(pg.bar, "Copy plan", 76, function()
      if NS.copyPlan then NS.copyPlan() end
    end, { "Copy plan", "The route as plain text in a box to copy from, to hand to somebody (/kebold copy)." }))
    pg.bAddRoute = at.put(UI.button(pg.bar, "Add route to shopping", 150, addRouteToShopping, function()
      if NS.startedPlan and NS.startedPlan() then
        return { "Add route to shopping", "Puts what is left of the started plan on the Shopping list, step by step: from the step you are in, with the crafts still expected there.",
          settings().routeSafe == true and "Buy for bad luck is on: each step goes on with enough for 9 times out of 10." or nil }
      end
      if settings().routeSafe == true then
        return { "Add route to shopping", "Buy for bad luck is on: the route goes on step by step, each with enough crafts for bad luck 9 times out of 10." }
      end
      return { "Add route to shopping", "Puts the whole route on the Shopping list. The entry follows your skill and the prices: it shrinks as you level." }
    end))
    -- Route settings: one button at the right end that says the choice in words, and its panel (LedgerRoute.lua).
    -- It stands where Cheapest | Fastest stood.
    pg.bRoute = UI.button(pg.bar, NS.routeLabel and NS.routeLabel() or "Route settings", ROUTE_W, function(self)
      if NS.routePanel then NS.routePanel(nil, pg.frame, self) end
    end, function()
      return { "Route settings", NS.routeText and ("Now: " .. NS.routeText() .. ".") or nil,
        "What your time is worth, the most one skill point may cost, the three ready-made choices and Buy for bad luck.",
        (NS.startedPlan and NS.startedPlan()) and "A started plan keeps the settings it was made with: Plan again to use new ones." or nil }
    end)
    if type(at.right) == "function" then
      at.right(pg.bRoute, 0)   -- as wide as its label needs (ROUTE_W at least): the row places it by its real width
    else
      pg.bRoute:SetPoint("TOPRIGHT", pg.bar, "TOPRIGHT", 0, -2)
    end
    -- rows 2 and 3: the six figures
    pg.cells = {}
    for k, key in ipairs(SUMS) do
      local cell = CreateFrame("Frame", nil, pg.bar)
      cell.key, cell.sumRow = key, false
      local bg = cell:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints()
      bg:SetColorTexture(1, 1, 1, 0.05)
      cell.label = UI.text(cell, "dim")
      cell.label:SetPoint("TOPLEFT", 6, -5)
      cell.label:SetJustifyH("LEFT")
      cell.label:SetWordWrap(false)
      cell.value = UI.text(cell, "GameFontHighlight")
      cell.value:SetPoint("TOPLEFT", 6, -22)
      cell.value:SetJustifyH("LEFT")
      cell.value:SetWordWrap(false)
      cell:EnableMouse(true)
      UI.tip(cell, function(self)
        local row = rawget(self, "sumRow")
        return row and row.tip or nil
      end)
      pg.cells[k] = cell
    end
    -- The footer on this page: what is wrong with the plan (the shell writes the line, pg.footLine), the fix for a
    -- range that needs more recipes, and the two scans. "Scan this plan" is the shell's own button.
    local f = NS.frame()
    pg.statusText = f.status   -- the footer's line, for the tests
    pg.status, pg.footLine = false, ""
    pg.bScanRoute = NS.scanControl(UI.button(f, NS.scanLabel and NS.scanLabel("route") or "Scan this route", FOOT.route, function() NS.scanButton("route") end,
      scanTip(NS.scanLabel and NS.scanLabel("route") or "Scan this route", "Only the items of the route on screen: a quick refresh before buying.")))
    pg.bScanRoute:SetPoint("RIGHT", f.footScan, "LEFT", -FOOT.gap, 0)
    pg.bFix = UI.button(f, "Choose recipes", FOOT.fix, function(self)
      UI.menu(self, pg.planBar.dRecipes.getItems())
    end, { "Recipes", "A skill range has no step because the plan may not use the recipes for it.",
      "Choose which recipes the route may use: only a trainer's, also recipe items you can buy, or everything." })
    pg.bFix:SetPoint("RIGHT", pg.bScanRoute, "LEFT", -FOOT.gap, 0)
    pg.bFix.footOff = true
    pg.footWidgets = { pg.bScanRoute, pg.bFix }
    -- buttons grow to their text (the kit's `need`), so the room they take is theirs, not the stated widths
    local function wide(b, w) return max(w, type(b) == "table" and type(b.need) == "number" and b.need or 0) end
    pg.footRoom = 26 + wide(f.footScan, 110) + FOOT.gap + wide(pg.bScanRoute, FOOT.route) + FOOT.gap + wide(pg.bFix, FOOT.fix) + 14
    -- the pane of the selected step, in the split's right side; the Craft page's pane takes its place for a recipe
    pg.pane = buildPane(pg.split.right)
  end,
  -- Who has the split's right side: this page's own pane (the selected step), unless a recipe's own details were
  -- asked for while the page shows (NS.openPanel tells the page; LedgerRecipes.lua's pane then takes the place).
  onDetail = function(_, kind)
    paneMode = kind == "recipe" and "recipe" or "step"
  end,
  detailMine = function()
    return not (paneMode == "recipe" and NS.detailRecipe ~= nil and NS.detailRecipe() ~= nil)
  end,
  footer = function(pg) return pg.footLine or "" end,
  footScan = true,
  marks = { "~", "*", "?" },
  layout = function(pg, w) place(pg, w) end,
  paint = function(pg, rows)
    local S = settings()
    local v = viewOf()
    if v == "steps" then
      pg.table:SetHeadText(7, S.sales ~= "off" and "After sales" or "")
      pg.table:SetHeadText(8, S.sales ~= "off" and "Sells at" or "")
    end
    pg.bSteps.label:SetText((v == "steps" and GOLD or DIM) .. "Steps|r")
    pg.bWhole.label:SetText((v == "whole" and GOLD or DIM) .. "Whole route|r")
    -- a started plan or not; what the route is planned by
    local started = NS.startedPlan ~= nil and NS.startedPlan() ~= nil
    pg.bStart:SetLabel(started and "Forget plan" or "Start this plan")
    -- The Route settings button says the choice in words, so its label changes ("Route: time at 25g an hour,
    -- limit"): the button is as wide as the label needs, up to the room its row has left (the row must stay one
    -- line: the strip of figures is right under it); with no room for the words it says them shorter
    -- ("Route: 25g/h, limit"; the tooltip has the sentence). The row is placed again when its width changed.
    do
      local fl = pg.at and pg.at.flow or nil
      local was = UI.widthOf(pg.bRoute)
      local room
      if fl then
        local mine = fl:Where(pg.bRoute)
        local x, last = fl.x0, fl.x0
        for _, it in ipairs(fl.items) do
          if mine and it.row == mine.row and it.right ~= true and it.on == true then
            last = x + UI.widthOf(it.w)
            x = last + it.gap
          end
        end
        room = (pg.w or 700) - last - 8
      end
      pg.bRoute:SetLabel(NS.routeLabel and NS.routeLabel() or "Route settings")
      pg.bRoute:Fit()
      if room and NS.routeLabel and pg.bRoute.need > room then
        pg.bRoute:SetLabel(NS.routeLabel(nil, true))
        pg.bRoute:Fit()
      end
      if room and UI.widthOf(pg.bRoute) > max(ROUTE_W, room) then pg.bRoute:SetWidth(max(ROUTE_W, room)) end
      if fl and UI.widthOf(pg.bRoute) ~= was then fl:Layout(pg.w or 700) end
    end
    local rp = NS.routePanelFrame and NS.routePanelFrame() or nil
    if type(rp) == "table" and rp:IsShown() then rp:Refresh() end
    -- the strip and the status line, from the model
    local sums, status, ranges = {}, nil, 0
    for _, row in ipairs(rows) do
      if row.sum then sums[row.sum] = row end
      if row.status then
        if row.status == "gap" then ranges = ranges + 1 end
        if not status or (row.level or 0) > (status.level or 0) then status = row end
      end
    end
    for _, cell in ipairs(pg.cells) do
      local row = sums[cell.key]
      cell.sumRow = row or false
      if row then
        cell.label:SetText(row.left)
        cell.value:SetText(UI.show(row.right))
        cell:Show()
      else
        cell:Hide()
      end
    end
    pg.status = status or false
    local text = status and status.left or ""
    if status and status.status == "gap" and ranges > 1 then text = text .. DIM .. "  (and " .. (ranges - 1) .. (ranges == 2 and " more range)|r" or " more ranges)|r") end
    pg.footLine = text   -- the shell puts it into the footer after this
    -- a range that needs more recipes gets its button beside the scans; missing prices are fixed by Scan this plan,
    -- which is there already
    pg.bFix.footOff = not (status and status.fix == "recipes")
    local cur = NS.current()
    pg.bAddRoute:SetEnabled(cur ~= nil and cur.route ~= nil and shownStep ~= nil and NS.shopAdd ~= nil,
      NS.shopAdd == nil and "The Shopping list is not loaded." or "There is no route to add.")
    pg.bStart:SetEnabled(started or (cur ~= nil and cur.route ~= nil and shownStep ~= nil and NS.startPlan ~= nil), "There is no route to start.")
    place(pg, pg.w or 700)
    -- the pane: the selected step, unless a recipe's own details were asked for
    local s = pg.split
    local open = type(s) == "table" and s.rightW > 0
    local recipe = paneMode == "recipe" and NS.detailRecipe ~= nil and NS.detailRecipe() ~= nil
    if not recipe then paneMode = "step" end
    if open and not recipe then   -- (the recipe's pane was left hidden by NS.detailAttach: page.detailMine)
      pg.pane:Layout(s.rightW, s.h)
      pg.pane:Fill(rows, shownStep)
      pg.pane:Show()
    else
      pg.pane:Hide()
    end
  end })

-- For the tests and for other pages: the view ("steps" | "whole"), the selected step, the pane.
function NS.levelView(v)
  if v ~= nil then setView(v) end
  return viewOf()
end
function NS.levelStep() return shownStep end
function NS.levelSelect(i)
  local cur = NS.current()
  local g = cur and cur.route and cur.route.segs[i] or nil
  if g then selectStep(g) end
  return g ~= nil
end
function NS.levelPane() return page.pane, paneMode end
-- The selection follows a started plan's progress again (true), and: select the step of this recipe at this start
-- on the next refresh (Use instead and Undo change a step's recipe under the selection).
function NS.levelFollow(on) sel.follow = on and true or false end
function NS.levelPick(id, from) sel.id, sel.from, sel.follow = id or false, from, false end
