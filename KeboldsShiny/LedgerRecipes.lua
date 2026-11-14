-- Kebold's Shiny: the Craft page and the details pane
-- (the window's shell and everything shared live in Ledger.lua, the Level page in LedgerLevel.lua, the Settings
-- page in LedgerSettings.lua)
--
-- Craft page: every recipe of the profession on screen, known or not, with what it costs, sells for and earns,
-- and how many are worth making. Click a column head to sort, a line for the recipe's details.
-- Details pane: one recipe in full, in the right pane of the Level, Craft and My sales pages, in the order a
-- player needs it: profit, how to get it, skill, reagents (with a choice for each part), the three ways to get
-- the parts, where it sells, how many are worth making, a buy list for any number of crafts. It also shows one
-- item (My sales).
--
-- WHICH NUMBERS (owner 2026-11-10: "under profit ... it will show you which is the most money"): everything here
-- that is about profit comes from ctx.bestInfo(r), the parts approach that earns the most per hour (cheapest mix,
-- every part bought or every part made), unless the player chose Buy or Make for a part of the recipe: then his
-- choices are used, as ctx.info(r) has them. figures().mode says which approach is in use and figures().why
-- says why ("best" | "pick" | "set"). Leveling figures (points, cost of a skill point) stay on the cheapest mix,
-- which is what routes are planned on.
--
-- ROW FIELDS added by the redesign (rows stay the only logic output; /kebold print and the tests read them):
--   Craft list   mode = "auto" | "buy" | "craft" (the approach in use), why, worth = crafts worth making (number,
--                math.huge = no limit) or nil, total = profit over them or nil, legend = true (the key to the marks),
--                empty = { title, text, button, onClick } (the list is only this: shown as the empty state)
--   pane         key = "sells" | "mats" | "profit" | "ph" | "worth" | "approach" (the Profit block's lines)
--                approach = mode, inUse = true (a line of "Parts: three ways")
--                how = "Craft" | "AH" | "Have" | "Vendor", each = copper for one (a reagent line)
--                qtyRow = true, qty = crafts the buy list is for, worth = crafts worth making or nil
--                buyLine = { item, units, top, cost, bags }, warn = "past" | "short" (a warning under the buy list)
--                shopAdd = { kind = "recipe", prof, id, n } (the Add to shopping line)
--                control = what is drawn over the line's middle cell, whose text (c2) says the same in words:
--                  { kind = "choice", text, items = function() -> menu entries, tip }      a button that opens a menu
--                  { kind = "stepper", get = function(), set = function(n), min, max, tip } a typed number with - and +
--                  { kind = "button", text, onClick = function(), off = why it cannot be pressed | nil, tip }

local NS = KeboldsShinyNS
local UI = KeboldsShinyUI
local E = NS.E
local floor, ceil, max, min, abs, huge = math.floor, math.ceil, math.max, math.min, math.abs, math.huge
local DIM, RED, GOLD, WHITE, GREEN = NS.DIM, NS.RED, NS.GOLD, NS.WHITE, NS.GREEN
local money, itemName, settings, try = NS.money, NS.itemName, NS.settings, NS.try

local HEADS = { "Recipe", "Learn", "Source", "Chance", "Cost", "Sells for", "Profit", "Per hour", "Worth making", "Total profit" }
local SHOW = { all = "all", known = "ones I know", learn = "ones I can learn now", skill = "ones that give skill", fav = "favourites" }
local MODE_NOTE = { buy = "parts bought", craft = "parts made" }
local MODE_NAME = { auto = "Cheapest mix", buy = "Buy every part", craft = "Make every part" }

local search = ""

-- +1g 20s in green, -30s in red, plain for nil
local function signed(v)
  if v == nil then return DIM .. "-|r" end
  if v >= 0 then return GREEN .. "+" .. money(v) .. "|r" end
  return RED .. "-" .. money(-v) .. "|r"
end

local function sourceWord(r)
  if r.start then return "start" end
  if r.src == "R" then
    local kind = r.kind ~= "" and r.kind:match("^[^/]+") or "item"
    return kind
  end
  if r.src == "A" then return "auto" end
  return r.guess and "trainer?" or "trainer"
end

-- One recipe's figures at skill `at`: everything a line of the list or the pane shows.
--   x     cost, time and sale of one craft under the approach in use (ctx.bestInfo)
--   mode  that approach: "auto" (the cheapest mix, or the player's own choices), "buy", "craft"
--   why   "best" (it pays the most per hour) | "pick" (he chose for a part) | "set" (the Crafted parts option)
--   x0    the cheapest mix (ctx.info), which leveling is planned on: pts and perPt come from it
local function figures(c, r)
  local ctx = c.ctx
  local at = max(c.from, ctx.learnOf(r))   -- a recipe you cannot learn yet is judged at the skill where you can
  local x0 = ctx.info(r)
  local x, mode, why = x0, "auto", nil
  if ctx.bestInfo then x, mode, why = ctx.bestInfo(r) end
  local f = { r = r, x = x, x0 = x0, mode = mode, why = why, at = at, known = (r.prof == c.prof and c.st.known and c.st.known[r.id]) or false }
  f.chance = r.col and ctx.chanceAt(r, at) or nil
  f.pts = r.col and ctx.ptsAt(r, at) or 0
  f.mk = ctx.makes(r)
  if x.cost ~= nil and x.p ~= nil then f.sale = x.cost + x.p end   -- what one craft sells for, after the cut
  f.ph = (x.p ~= nil and x.secs and x.secs > 0) and x.p / x.secs * 3600 or nil
  if x0.cost ~= nil and f.pts > 0 then f.perPt = (x0.p ~= nil and -x0.p or x0.cost) / f.pts end   -- net cost of one skill point
  return f
end
NS.figures = figures

-- How many are worth making under the approach in use: the engine's curve (walked on past the paying crafts, so a
-- buy list can be made for any number) or nil when the recipe has no cost or no sale.
local function worthOf(ctx, r)
  if ctx.worthBest then return (ctx.worthBest(r)) end
  local x = ctx.info(r)
  return ctx.worthCurve and x.cost and x.p and ctx.worthCurve(r) or nil
end
NS.worthOf = function(c, r) return worthOf(c.ctx, r) end

-- The count as text and as a number to sort by (nil = nothing to say).
local function worthText(w)
  if not w then return DIM .. "-|r", nil end
  if w.worth == huge then
    if w.known then return "no limit", huge end
    return DIM .. "?|r", nil   -- no real depth behind the prices: unknown, not "no limit"
  end
  return (w.known and "" or (DIM .. "~|r")) .. w.worth, w.worth
end

local function totalOf(w)
  if w and w.worth ~= huge and w.worth > 0 and w.total and w.total ~= huge then return w.total end
  return nil
end

local SORT = {
  function(f) return f.r.name end,
  function(f) return f.r.learn end,
  function(f) return f.known and "0" or ("1" .. sourceWord(f.r)) end,
  function(f) return f.chance end,
  function(f) return f.x.cost end,
  function(f) return f.sale end,
  function(f) return f.x.p end,
  function(f) return f.ph end,
  function(f) return f.worthN end,
  function(f) return f.total end,
}

function NS.sortBy(k)
  local S = settings()
  if S.sortKey == k then S.sortDesc = not S.sortDesc else S.sortKey, S.sortDesc = k, k >= 4 end   -- numbers start high to low
  NS.resetScroll()
  NS.refresh()
end

-- ---- recipes the game lists that the shipped data lacks ---------------------------------------------------------
-- The collector saves every recipe of an opened profession (Collect.lua, recipeLine):
--   name|item made|min made|max made|learned|difficulty|grey at|skill-ups|type|reagents "item:count,..."|source|category
-- One whose spell id is not in Data.lua is shown at the end of the list, dimmed and marked "game only", with only
-- what the game gave. Kebold has no learn level, colours, cast time or source for it, so it gets no chance,
-- profit or per-point figure and never enters a route (routes are planned from Data.lua alone). A cost is shown
-- only when every reagent has a scanned or vendor price.
local DIFF = { ["0"] = "o", ["1"] = "y", ["2"] = "g", ["3"] = "x" }
local DIFF_WORD = { o = "orange", y = "yellow", g = "green", x = "grey" }

local function fields(line)
  local out, from = {}, 1
  while true do
    local at = line:find("|", from, true)
    if not at then
      out[#out + 1] = line:sub(from)
      return out
    end
    out[#out + 1] = line:sub(from, at - 1)
    from = at + 1
  end
end

local function gameOnly(prof)
  local out = {}
  local col = NS.collected()
  local rec = NS.recipesOf(prof)   -- by name, else by the profession's id (a client that is not in English)
  if type(rec) ~= "table" or type(rec.list) ~= "table" then return out end
  local byId = NS.data().byId
  for id, line in pairs(rec.list) do
    if type(id) == "number" and type(line) == "string" and not byId[id] then
      local f = fields(line)
      local g = { id = id, name = (f[1] and f[1] ~= "") and f[1] or ("recipe " .. id), made = tonumber(f[2]) or 0,
        qmin = tonumber(f[3]) or 1, qmax = tonumber(f[4]) or tonumber(f[3]) or 1, known = f[5] == "1",
        diff = DIFF[f[6] or ""], grey = tonumber(f[7]), regs = {} }
      for pair in (f[10] or ""):gmatch("[^,]+") do
        local item, q = pair:match("^(%d+):(%d+)$")
        if item then g.regs[#g.regs + 1] = { tonumber(item), tonumber(q) } end
      end
      local it = g.made > 0 and type(col.items) == "table" and col.items[g.made] or nil
      if type(it) == "string" then g.sell = tonumber(fields(it)[3]) end   -- the game's own vendor value of the item made
      out[#out + 1] = g
    end
  end
  table.sort(out, function(a, b)
    local ga, gb = a.grey or 0, b.grey or 0
    if ga ~= gb then return ga < gb end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  return out
end
NS.gameOnly = gameOnly

-- What one reagent costs: a part the way Kebold would get it, anything else from the scan or a vendor.
local function gameEach(ctx, item)
  local part = ctx.part(item)
  if part and part.how == "Have" then return 0 end
  if part then return (part.how == "Craft" and part.craft) or part.buy or part.craft end
  return ctx.matCost(item).c
end

-- The reagents of one craft, or nil when any of them has no price (or the game gave no reagents).
local function gameCost(ctx, g)
  if #g.regs == 0 then return nil end
  local total = 0
  for _, reg in ipairs(g.regs) do
    local each = gameEach(ctx, reg[1])
    if each == nil then return nil end
    total = total + each * reg[2]
  end
  return total
end

-- The key to the marks of the list, one line.
local LEGEND = "~ an estimate    * your own choice    \194\187 a favourite    ? not known    (the ? button beside the page's name has this key too)"

function NS.buildRecipes()
  local S = settings()
  local WHOLE = NS.scanLabel and NS.scanLabel("whole") or "Scan whole profession"   -- the scan's one name (LedgerEntry.lua)
  local c = NS.state()
  S.prof = c.prof
  local ctx = c.ctx
  local show = SHOW[S.show] and S.show or "all"
  local all = NS.data().byProf[c.prof] or {}
  local list, needle, anyPriced = {}, search:lower(), false
  for _, r in ipairs(all) do
    local f = figures(c, r)
    if f.x.cost ~= nil then anyPriced = true end
    local keep = true
    if show == "known" then keep = f.known
    elseif show == "learn" then keep = not f.known and r.src ~= "R" and not r.guess and r.learn <= (c.st.skill or c.from)
    elseif show == "skill" then keep = (r.col and ctx.chanceAt(r, c.from) > 0) or false
    elseif show == "fav" then keep = S.fav[r.id] == true end
    if keep and S.priced and f.x.cost == nil then keep = false end
    if keep and needle ~= "" and not r.name:lower():find(needle, 1, true) then keep = false end
    if keep then
      if f.x.cost ~= nil and f.x.p ~= nil then
        f.w = worthOf(ctx, r)
        f.worthText, f.worthN = worthText(f.w)
        f.total = totalOf(f.w)
      end
      list[#list + 1] = f
    end
  end
  local extra, extraAll = {}, gameOnly(c.prof)
  for _, g in ipairs(extraAll) do
    g.cost = gameCost(ctx, g)
    local keep = true
    if show == "known" then keep = g.known
    elseif show == "learn" or show == "fav" then keep = false   -- nothing says where or when it is learned; not in the data
    elseif show == "skill" then keep = g.grey ~= nil and g.grey > c.from end
    if keep and S.priced and g.cost == nil then keep = false end
    if keep and needle ~= "" and not g.name:lower():find(needle, 1, true) then keep = false end
    if keep then extra[#extra + 1] = g end
  end

  -- Nothing to list: say why, with the way out as a button (the table shows a list of only `empty` rows that way).
  local filtered = show ~= "all" or needle ~= "" or S.priced
  local none = #list == 0 and #extra == 0
  if #all > 0 and not anyPriced and (not filtered or (none and show == "all" and needle == "")) then
    -- no recipe of the profession has a price: a list of "no price" lines says nothing. Typing in Find or picking a
    -- Show filter still lists them (to look up a learn level or a source).
    return { { left = "No prices yet for " .. c.prof .. ". " .. WHOLE .. " at the auction house (several minutes), or type in Find to look a recipe up.",
      empty = { icon = NS.profIcon and NS.profIcon(c.prof) or nil, title = "No prices yet for " .. c.prof,
        text = "Costs and profits come from a scan of the auction house. " .. WHOLE .. " reads every material and product of the profession (several minutes; keep the auction house open). To look a recipe up without prices, type in Find.",
        button = WHOLE, onClick = function() NS.scanButton(string.lower(c.prof) .. " all") end } } }, c.prof .. "  recipes"
  end
  if none and #all > 0 then
    local why = {}
    if needle ~= "" then why[#why + 1] = "Find: " .. search end
    if show ~= "all" then why[#why + 1] = "Show: " .. SHOW[show] end
    if S.priced then why[#why + 1] = "Only priced" end
    return { { left = "No recipe matches (" .. table.concat(why, ", ") .. ").",
      empty = { icon = "Interface\\Icons\\INV_Misc_Spyglass_02", title = "No recipe matches",
        text = "Nothing in " .. c.prof .. " fits " .. table.concat(why, ", ") .. ".", button = "Show all recipes", onClick = function()
          local S2 = settings()
          S2.show, S2.priced = "all", nil
          search = ""
          local page = NS.pageOf("recipes")
          if page and type(page.eFind) == "table" then pcall(page.eFind.SetText, page.eFind, "") end
          NS.resetScroll()
          NS.refresh()
        end } } }, c.prof .. "  recipes"
  end

  local key, desc = SORT[S.sortKey or 2] or SORT[2], S.sortDesc and true or false
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
  out[#out + 1] = { left = DIM .. string.format("%d of %d %s recipes. Colours, chance and points are at skill %d (the From box); a recipe learned later is judged at its own level.|r",
    #list, #all, c.prof, c.from),
    tip = { "Profit, Per hour, Worth making and Total profit use the way of getting the parts that earns the most per hour, unless you chose Buy or Make for a part.",
      "A recipe not on the cheapest mix says so after its name: parts bought, parts made." } }
  if #extraAll > 0 then
    out[#out + 1] = { left = DIM .. #extraAll .. " more recipes are listed by the game and missing from Kebold's data: they are at the end, under Recipes without data.|r" }
  end
  if not c.st.seen then
    out[#out + 1] = { left = DIM .. "Not one of this character's professions (or its window was never opened here), so nothing is marked as known.|r" }
  end
  local unpriced = 0
  for _, f in ipairs(list) do
    local r, x = f.r, f.x
    if x.cost == nil then unpriced = unpriced + 1 end
    local sells = DIM .. "-|r"
    local pick = r.made > 0 and S.sellPick[r.made] or nil
    if f.sale then sells = money(f.sale) .. (pick and GOLD or DIM) .. NS.wayShort(x.way) .. (pick and "*" or "") .. "|r" end
    local tip = { "Click for the recipe's details: materials, where it sells, how many are worth making and a buy list." }
    if f.mode ~= "auto" then
      local a = ctx.info(r)
      tip[#tip + 1] = GOLD .. (f.mode == "buy" and "Parts bought" or "Parts made") .. "|r: it pays more per hour than the cheapest mix ("
        .. ((a.p and a.secs and a.secs > 0) and signed(a.p / a.secs * 3600) or "-") .. " an hour, " .. signed(a.p) .. " a craft there). The details show all three ways."
    elseif f.why == "pick" then
      tip[#tip + 1] = "A part of it has your own Buy or Make choice, so the figures follow your choices."
    end
    if f.w and f.w.worth ~= huge then
      tip[#tip + 1] = "Worth making: " .. NS.plain(f.worthText) .. (f.total and (", " .. signed(f.total) .. " in all") or "")
        .. (f.w.known and "." or ". ~: a material has no scanned price steps, so its price is assumed not to move.")
    end
    if f.perPt then
      tip[#tip + 1] = "One skill point " .. (f.perPt <= 0 and ("pays " .. money(-f.perPt)) or ("costs " .. money(f.perPt))) .. " after selling the result (cheapest mix, as routes are planned)."
    end
    if S.sales ~= "off" and r.made > 0 then
      tip[#tip + 1] = "Vendor pays " .. (r.sell and (money(r.sell) .. " each") or "nothing known") .. ". AH: "
        .. (x.ahp and (money(x.ahp) .. " each, " .. (x.listed or 0) .. " listed") or (x.listed and (x.listed > 0 and "only listed under vendor value" or "none listed") or "not scanned")) .. "."
      tip[#tip + 1] = "Sells at: " .. NS.SELL_TEXT[pick or "auto"]
        .. ((not pick and r.gear and S.sales == "best") and (x.way == "DE" and " (gear on Auto is counted as disenchanted here: Settings, Count gear at disenchant value)" or " (gear on Auto goes to a vendor)") or "") .. ". A gold * marks your own choice."
      tip[#tip + 1] = GOLD .. "Right-click for choices|r: where it sells, favourite, scan its items, skip it in routes, search, link."
    end
    tip[#tip + 1] = "Shift-click to link it."
    out[#out + 1] = { cols = {
        (S.fav[r.id] and (GOLD .. "\194\187 |r") or "") .. NS.COLOUR[ctx.colour(r, f.at)] .. r.name .. "|r"
          .. (MODE_NOTE[f.mode] and (DIM .. "  " .. MODE_NOTE[f.mode] .. "|r") or ""),
        r.learn .. (r.est and "~" or ""),
        f.known and (GREEN .. "known|r") or (DIM .. sourceWord(r) .. "|r"),
        f.chance and string.format("%.0f%%", 100 * f.chance) or (DIM .. "-|r"),
        x.cost and money(x.cost) or (DIM .. "no price|r"),
        sells, signed(x.p), f.ph and signed(f.ph) or (DIM .. "-|r"),
        f.worthText or (DIM .. "-|r"),
        f.total and signed(f.total) or (DIM .. "-|r"),
      }, item = r.made > 0 and r.made or nil, recipe = r.id, tip = tip, mode = f.mode, why = f.why, worth = f.worthN, total = f.total,
      sellStep = (S.sales ~= "off" and r.made > 0) and r.made or nil }
  end
  if #list > 0 then
    out[#out + 1] = { left = "" }
    out[#out + 1] = { left = DIM .. LEGEND .. "|r", legend = true,
      tip = { "~ an estimate: after a learn level nobody has confirmed; before Worth making when a material has no scanned price steps, so its price is assumed not to move.",
        "* your own choice: after Sells for, you chose where this product sells (right-click the line).",
        "\194\187 a favourite: before the recipe's name.",
        "? not known: nobody has recorded it yet.",
        "Words, not marks: parts bought / parts made (the recipe earns more per hour that way than on the cheapest mix), vendor / AH after Sells for (where it is counted as sold)." } }
  end
  if unpriced > 0 then
    out[#out + 1] = { left = RED .. unpriced .. " of these have a material without a scanned price.|r " .. WHOLE .. " covers it (several minutes)." }
  end
  if #extra > 0 then
    out[#out + 1] = { left = "" }
    out[#out + 1] = { left = GOLD .. "Recipes without data|r" .. DIM .. "  " .. #extra .. " of " .. #extraAll
      .. " recipes the game lists that Kebold has no data for: no learn level, chance or profit, and never in a route.|r", section = "game" }
    for _, g in ipairs(extra) do
      local tip = { "Listed by the game, not in Kebold's data (spell " .. g.id .. ").",
        (g.known and "You know this recipe. " or "") .. ((g.grey and g.grey > 0) and ("Goes grey at " .. g.grey .. ". ") or "")
          .. (g.diff and ("It was " .. DIFF_WORD[g.diff] .. " when the profession window was last read.") or "") }
      if g.made > 0 then
        tip[#tip + 1] = "Makes " .. (g.qmin ~= g.qmax and (g.qmin .. " to " .. g.qmax) or g.qmin) .. " " .. itemName(g.made)
          .. (g.sell and (g.sell > 0 and (", vendor pays " .. money(g.sell) .. " each") or ", which a vendor will not buy") or "") .. "."
      end
      for _, reg in ipairs(g.regs) do
        local each = gameEach(ctx, reg[1])
        tip[#tip + 1] = reg[2] .. "x " .. itemName(reg[1]) .. "  " .. (each and money(each * reg[2]) or "no price")
      end
      if #g.regs == 0 then tip[#tip + 1] = "The game gave no materials for it." end
      out[#out + 1] = { cols = {
          DIM .. g.name .. "|r" .. (g.known and (GREEN .. " (known)|r") or ""),
          DIM .. "-|r", DIM .. "no data|r",
          g.diff and (NS.COLOUR[g.diff] .. DIFF_WORD[g.diff] .. "|r") or (DIM .. "-|r"),
          g.cost and (DIM .. money(g.cost) .. "|r") or (DIM .. "-|r"),
          (g.sell and g.sell > 0) and (DIM .. money(g.sell * g.qmin) .. " vendor|r") or (DIM .. "-|r"),
          DIM .. "-|r", DIM .. "-|r", DIM .. "-|r", DIM .. "-|r",
        }, item = g.made > 0 and g.made or nil, gameOnly = g.id, tip = tip }
    end
  end
  return out, c.prof .. "  recipes"
end

-- ---- the Craft page --------------------------------------------------------------------------------------------------

local SHOW_ORDER = { "all", "known", "learn", "skill", "fav" }
local SHOW_TIP = { all = "Every recipe of the profession.", known = "Only recipes you know.",
  fav = "Only the recipes you marked as favourites (right-click a recipe). Scan favourites reads their prices.",
  learn = "Trainer recipes you do not know yet and have the skill for.", skill = "Recipes that still give skill at the From level." }

-- The ten columns, in the order of a line's `cols`. Recipe, Profit and Per hour always stay; when the details pane is
-- open the list is narrow and the others give way, the highest drop number first.
local BEST_TIP = "Uses the way of getting the parts that earns the most per hour, unless you chose Buy or Make for a part."
local COLUMNS = {
  { key = "name", title = HEADS[1], flex = 1, min = 130, sortable = true,
    tip = { "Recipe", "In its skill colour at the From skill. \194\187 marks a favourite; parts bought / parts made says the recipe is not on the cheapest mix of parts." } },
  { key = "learn", title = HEADS[2], width = 44, align = "RIGHT", sortable = true, drop = 4, tip = { "Learn", "The skill it is learned at. ~ marks an estimate." } },
  { key = "source", title = HEADS[3], width = 56, sortable = true, drop = 5,
    tip = { "Source", "Where the recipe comes from: a trainer, a recipe item (vendor, drop, quest), or known already." } },
  { key = "chance", title = HEADS[4], width = 50, align = "RIGHT", sortable = true, drop = 7, tip = { "Chance of a point", "The chance of a point from one craft, at the From skill." } },
  { key = "cost", title = HEADS[5], width = 72, align = "RIGHT", sortable = true, drop = 3, tip = { "Cost", "Materials for one craft.", BEST_TIP } },
  { key = "sells", title = HEADS[6], width = 104, align = "RIGHT", sortable = true, drop = 6,
    tip = { "Sells for", "What one craft sells for, and where it is counted as sold: a vendor, or the auction house (AH) less its cut. * marks your own choice." } },
  { key = "profit", title = HEADS[7], width = 74, align = "RIGHT", sortable = true, tip = { "Profit", "What one craft earns.", BEST_TIP } },
  { key = "ph", title = HEADS[8], width = 72, align = "RIGHT", sortable = true, tip = { "Per hour", "Profit for an hour of casting, parts you make included.", BEST_TIP } },
  { key = "worth", title = HEADS[9], width = 80, align = "RIGHT", sortable = true, drop = 1,
    tip = { "Worth making", "How many crafts still pay before the cheap materials are bought up or the auction house has enough of them.",
      "~: a material has no scanned price steps. ?: no limit that the prices can show." } },
  { key = "total", title = HEADS[10], width = 80, align = "RIGHT", sortable = true, drop = 2, tip = { "Total profit", "The profit over the crafts worth making." } },
}

NS.page({ key = "recipes", title = "Craft", order = 2, icon = "Interface\\Icons\\Trade_BlackSmithing",
  tip = { "Craft", "Every recipe of a profession with its cost, what it sells for, its profit and how many are worth making." },
  plan = true, bars = 1, detail = true, columns = COLUMNS, footer = "plan", marks = { "~", "*", "\194\187", "?" },
  empty = { title = "No recipes", text = "Kebold has no recipes for this profession." },
  rows = function() return NS.buildRecipes() end,
  onSort = function(_, _, k) NS.sortBy(k) end,
  selected = function(row) return row.recipe ~= nil and NS.detailRecipe() == row.recipe end,
  build = function(page)
    local at, bar = page.at, page.bar
    page.dShow = at.put(UI.dropdown(bar, 180, function()
      local S = settings()
      return "Show: " .. SHOW[SHOW[S.show] and S.show or "all"]
    end, function()
      local S = settings()
      local now = SHOW[S.show] and S.show or "all"
      local items = { { title = true, text = "Show" } }
      for _, key in ipairs(SHOW_ORDER) do
        items[#items + 1] = { radio = true, checked = now == key, text = SHOW[key], tip = SHOW_TIP[key], func = function()
          settings().show = key
          NS.resetScroll()
          NS.refresh()
        end }
      end
      return items
    end, { "Show", "Which recipes are listed." }))
    page.cPriced = at.put(UI.check(bar, "Only priced", function() return settings().priced and true or false end, function(v)
      settings().priced = v and true or nil
      NS.resetScroll()
      NS.refresh()
    end, { "Only priced", "Hides recipes with a material that has no scanned or vendor price." }), 8, 104)
    page.eFind = at.put(UI.search(bar, 140, function(self)
      local t = self:GetText() or ""
      if t ~= search then
        search = t
        NS.resetScroll()
        NS.refresh()
      end
    end), 8)
    page.eFind:SetMaxLetters(30)
    local whole = NS.scanLabel and NS.scanLabel("whole") or "Scan whole profession"   -- the scans have one name each (LedgerEntry.lua)
    page.bScanAll = at.put(NS.scanControl(UI.button(bar, whole, 150, function()
      NS.scanButton(string.lower(NS.state().prof) .. " all")
    end, { whole, "Every material, part, product and recipe item of the profession: several minutes. Keep the auction house open while it runs." })), 8)
  end,
  paint = function(page)
    local S = settings()
    page.dShow:Refresh()
    page.cPriced:Refresh()
    page.table:SetSort(S.sortKey or 2, S.sortDesc and true or false)
  end })

-- ---- the details: what they say --------------------------------------------------------------------------------------

local panel, panelRows, panelRecipe = nil, {}, nil
local panelMode, panelItem = "recipe", nil   -- the pane shows a recipe, or one item (My sales)

-- ---- how many to make, and what to pay --------------------------------------------------------------------------
-- The engine's worth curve is a list of price steps (constant cost and profit between two points where a listing
-- runs out). Two readings of it for the panel, both plain data:

-- Neighbouring steps whose hourly profit is within 3% become one band: { from, to, each, ph, total, nx }
-- (each = average profit a craft, total = running profit to the band's end, nx = what gets dearer after it).
-- Steps past the crafts worth making (past = true, only in a curve walked on for the buy list) are left out.
function NS.worthBands(w, secsEach)
  local bands, run = {}, 0
  for _, g in ipairs(w.segs) do
    if not g.past then
      local b = bands[#bands]
      if b and g.to ~= huge and b.to ~= huge and abs(g.ph - b.ph0) <= 0.03 * abs(b.ph0) then
        b.sum = b.sum + g.profit * (g.to - g.from)
        b.to, b.nx = g.to, g.nx
      else
        b = { from = g.from, to = g.to, ph0 = g.ph, sum = g.to ~= huge and g.profit * (g.to - g.from) or nil, profit = g.profit, nx = g.nx }
        bands[#bands + 1] = b
      end
    end
  end
  for _, b in ipairs(bands) do
    b.each = (b.sum and b.to > b.from) and b.sum / (b.to - b.from) or b.profit
    b.ph = (secsEach and secsEach > 0) and b.each / secsEach * 3600 or nil
    if b.sum then
      run = run + b.sum
      b.total = run
    end
  end
  return bands
end

-- What n crafts buy: per material the units, the dearest price that quantity still needs ("pay up to") and the
-- sum; then the profit over them and how many of the n the curve really covers (fewer than n when the listings
-- run out first).
function NS.buyPlan(w, n)
  local mats = {}
  for i, m in ipairs(w.mats) do mats[i] = { n = m.n, u = m.u, units = 0, cost = 0, top = 0 } end
  local profit, done, cost = 0, 0, 0
  for _, g in ipairs(w.segs) do
    local k = min(g.to, n) - g.from
    if k <= 1e-9 then break end
    for i, m in ipairs(mats) do
      local p = g.pr[i] or 0
      m.units = m.units + k * m.u
      m.cost = m.cost + k * m.u * p
      if p > m.top then m.top = p end
    end
    profit, done, cost = profit + k * g.profit, done + k, cost + k * g.cost
  end
  return { mats = mats, profit = profit, crafts = done, cost = cost }
end

-- How many crafts the buy list is for, per recipe: kept in the saved settings (S.panelQty[recipe id]).
local QTY_MAX = 9999
local function qtyStore()
  local S = settings()
  if type(S.panelQty) ~= "table" then S.panelQty = {} end
  return S.panelQty
end

local function qtyStep(n)
  return n < 20 and 1 or (n < 100 and 10 or (n < 1000 and 50 or 100))
end

function NS.setPanelQty(recipeID, n)
  n = tonumber(n)
  if not (recipeID and n) then return end
  qtyStore()[recipeID] = max(1, min(QTY_MAX, floor(n + 0.5)))
  NS.refresh()
end

local function secs(v)
  if v == nil then return "?" end
  if v >= 90 then return string.format("%.1f min", v / 60) end
  return string.format("%.1fs", v)
end

local function bags(item)
  local n = NS.bagCount and try(NS.bagCount, item)
  return type(n) == "number" and n or 0
end

-- Every line of the pane for one recipe.
local function buildPanel(r)
  local S = settings()
  local c = NS.state()
  local ctx = c.ctx
  local f = figures(c, r)
  local x = f.x
  local mc = ctx.modeCtx and ctx.modeCtx(f.mode) or ctx   -- the context that costs things the way in use
  local w = (x.cost ~= nil and x.p ~= nil) and worthOf(ctx, r) or nil
  local out = {}
  local function add(row)
    out[#out + 1] = row
    return row
  end
  local function head(text, right)
    add({ left = "" })
    add({ left = GOLD .. text .. "|r", right = right and (DIM .. right .. "|r") or "", heading = true })
  end

  add({ left = (f.known and GREEN .. "You know this recipe.|r" or (c.st.seen and "You do not know this recipe." or DIM .. r.prof .. " recipe|r")),
    right = r.isNew and (DIM .. "new in Forever|r") or "", item = r.made > 0 and r.made or nil, linkRecipe = r.id,
    tip = { "Shift-click to link it in chat." } })

  -- 1. the profit, first
  head("Profit", f.mk ~= 1 and (f.mk .. " made per craft") or nil)
  add({ key = "sells", left = "Sells for", right = f.sale and (money(f.sale) .. DIM .. (x.way == "AH" and "  AH, after the cut" or (" " .. NS.wayShort(x.way))) .. "|r")
    or (DIM .. (x.cost and "no sale price" or "-") .. "|r") })
  add({ key = "mats", left = "Materials", c2 = MODE_NOTE[f.mode] and (DIM .. MODE_NOTE[f.mode] .. "|r") or nil,
    right = x.cost and money(x.cost) or (RED .. "no price|r"),
    tip = x.cost and { "What one craft's materials cost, the way the parts are got now (see Materials below)." }
      or { "A material has no scanned or vendor price. Scan AH (below) reads this recipe's items." } })
  add({ key = "profit", left = "Profit for one craft", right = signed(x.p) })
  add({ key = "ph", left = "Profit per hour", c2 = DIM .. secs(x.secs) .. " a craft|r", right = f.ph and signed(f.ph) or (DIM .. "-|r"),
    tip = { "An hour of casting, the parts you make included" .. ((x.casts and x.casts > 1) and string.format(" (%.1f casts a craft).", x.casts) or ".") } })
  if w then
    local text = worthText(w)
    local total = totalOf(w)
    add({ key = "worth", left = "Worth making", right = text .. (total and (DIM .. "  for |r" .. signed(total)) or ""), worth = w.worth,
      tip = { "How many crafts still pay before the cheap materials are bought up or the auction house has enough of them. The steps are further down." } })
  end
  if f.mode ~= "auto" then
    add({ key = "approach", left = DIM .. (f.mode == "buy" and "Parts bought" or "Parts made") .. ": that pays the most per hour.|r", approach = f.mode })
  elseif f.why == "pick" then
    add({ key = "approach", left = DIM .. "Your own Buy / Make choices for parts are in use.|r", approach = "auto" })
  end

  -- 2. how to get it
  if not f.known then
    head("How to get it")
    local text, cost = NS.learnText(ctx, r)
    add({ left = text, right = cost and money(cost) or "", item = r.pat > 0 and r.pat or nil,
      tip = r.pat > 0 and { "Click at the auction house to search for the recipe item." } or nil })
    if NS.whereRows then
      for _, row in ipairs(NS.whereRows(r)) do add(row) end
    end
  end

  -- 3. skill (the bar in the pane's head shows the same colours)
  head("Skill")
  if r.col then
    add({ left = "Learn " .. r.learn .. (r.est and "~" or "") .. "   yellow " .. r.y .. "   green " .. (r.g or "?") .. "   grey " .. r.grey,
      right = r.colEst and (DIM .. "estimates|r") or "" })
    add({ left = "At skill " .. f.at .. ": " .. NS.COLOUR[ctx.colour(r, f.at)] .. string.format("%.0f%%", 100 * (f.chance or 0)) .. " per craft|r",
      right = (f.pts > (f.chance or 0) + 1e-9) and string.format("%.2f points with its parts", f.pts) or "" })
    if f.perPt then
      add({ left = "One skill point costs", right = f.perPt <= 0 and signed(-f.perPt) or money(f.perPt),
        tip = { "After selling the result, on the cheapest mix of parts: that is what leveling routes are planned on." } })
    end
  else
    add({ left = DIM .. "No skill colours known for this recipe.|r" })
  end

  -- 4. reagents, as the way in use gets them. Each line: what one costs after the name, the line's sum on the
  -- right, so the lines add up to "Materials for one craft" (owner 2026-11-10: the "each" figures alone did not).
  -- A part has its choice as a control in the middle cell.
  head("Materials", "for all")
  local anyPart = false
  for _, reg in ipairs(r.regs) do
    local id, q = reg[1], reg[2]
    local part = mc.part(id)
    local pick = S.pick[id]
    if part and (part.craft or pick) then
      anyPart = anyPart or part.craft ~= nil
      local how = part.how
      local each = how == "Craft" and part.craft or (how == "Have" and 0 or part.buy)
      local text = pick and NS.PICK_TEXT[pick] or ("Auto: " .. (how == "Craft" and "make" or "buy"))
      add({ left = q .. "x " .. itemName(id) .. DIM .. "  " .. (how == "Craft" and "made" or (how == "Have" and "have it" or "bought")) .. "|r"
          .. ((each and each > 0 and q > 1) and ("  " .. money(each) .. DIM .. " each|r") or ""),
        c2 = (pick and GOLD or "") .. text .. (pick and "|r" or ""),
        right = each and money(each * q) or (RED .. "no price|r"),
        item = id, pickItem = id, haveItem = id, choice = true, how = how, each = each,
        control = { kind = "choice", text = text, items = function() return NS.rowMenu({ pickItem = id }) end,
          tip = { "Get it by", "Auto: Kebold decides. For this recipe that is what earns the most per hour; in a leveling route, what costs least.",
            "Buy / Make: always that, in every recipe that uses the part. Have it: you have them already, so they cost nothing." } },
        tip = { "A part you can make. For one: " .. (part.buy and ("buy " .. NS.plain(money(part.buy))) or "none to buy") .. ", "
            .. (part.craft and ("make " .. NS.plain(money(part.craft))) or "cannot be made") .. ".", "Every recipe that uses it follows your choice.",
          "Have it: you have them already, so they cost nothing and are neither bought nor made.", GOLD .. "Click or right-click for choices.|r" } })
    elseif pick == "have" then
      add({ left = q .. "x " .. itemName(id) .. DIM .. "  have it|r", c2 = GOLD .. "Have it|r", right = DIM .. "nothing|r", item = id, haveItem = id, choice = true,
        how = "Have", each = 0,
        control = { kind = "choice", text = "Have it", items = function() return NS.rowMenu({ haveItem = id }) end,
          tip = { "Get it by", "You said you have this already. Auto prices it again." } },
        tip = { "You said you have this already, so it costs nothing in every recipe that uses it.", GOLD .. "Click or right-click for choices|r: Auto prices it again." } })
    else
      local m = (part and { c = part.buy, how = "AH" }) or mc.matCost(id)
      add({ left = q .. "x " .. itemName(id), c2 = m.c and (money(m.c) .. DIM .. " " .. (m.how == "Vendor" and "vendor" or "AH") .. "|r") or nil,
        right = m.c and money(m.c * q) or (RED .. "no price|r"), how = m.how, each = m.c,
        item = id, haveItem = id, tip = { "Click at the auction house to search for it. Shift-click to link it.",
          GOLD .. "Right-click for choices|r: Have it, if you have it already (farmed or banked). It then costs nothing." } })
    end
  end
  add({ left = "Materials for one craft", right = x.cost and money(x.cost) or (RED .. "no price|r") })
  add({ left = "Time for one craft", right = secs(x.secs) .. ((x.casts and x.casts > 1) and string.format(" (%.1f casts)", x.casts) or "") })

  -- 5. the three ways to get the parts, when there is a part to make
  local ap = anyPart and ctx.approaches and ctx.approaches(r) or nil
  if ap and x.cost then
    head("Parts: three ways", "a craft      per hour")
    local bestP, bestPMode
    for _, a in ipairs(ap.list) do
      if a.p ~= nil and (bestP == nil or a.p > bestP + 1e-9) then bestP, bestPMode = a.p, a.mode end
    end
    for _, a in ipairs(ap.list) do
      local inUse = a.mode == f.mode
      local name = (a.mode == "auto" and f.why == "pick") and "Your choices" or MODE_NAME[a.mode]
      add({ left = name .. (inUse and (GOLD .. "  in use|r") or ((ap.best == a.mode) and (DIM .. "  best per hour|r") or "")),
        c2 = a.cost and signed(a.p) or nil, right = a.cost and (a.ph and signed(a.ph) or (DIM .. "-|r")) or (DIM .. "not possible|r"),
        approach = a.mode, inUse = inUse or nil, band = inUse or nil,
        tip = a.cost and { name, "Materials " .. money(a.cost) .. ", " .. secs(a.secs) .. " a craft.",
          "Profit " .. signed(a.p) .. " a craft" .. (a.way and (a.way == "AH" and " at the auction house" or (a.way == "DE" and " disenchanted" or " at a vendor")) or "") .. ", " .. (a.ph and signed(a.ph) or "-") .. " an hour." } or nil })
    end
    local note
    if f.why == "pick" then note = "In use: your Buy / Make choices. Set the parts to Auto for the best per hour."
    elseif f.why == "set" then note = "In use: the Crafted parts setting."
    elseif f.mode ~= "auto" then note = "In use because it pays the most per hour."
    else note = "In use: no other way pays more per hour." end
    add({ left = DIM .. note .. "|r" })
    if f.why == "best" and bestPMode and bestPMode ~= f.mode then   -- most per craft and most per hour differ: say so
      add({ left = DIM .. MODE_NAME[bestPMode] .. " earns more a craft, less an hour.|r" })
    end
  end

  -- 6. selling
  head("Selling", f.mk ~= 1 and (f.mk .. " made per craft") or nil)
  add({ left = "Vendor", right = r.sell and money(r.sell * f.mk) or (DIM .. "unknown|r") })
  add({ left = "Auction house", right = x.ahp and (money(x.ahp * f.mk) .. DIM .. "  " .. (x.listed or 0) .. " listed|r")
    or (DIM .. (x.listed and (x.listed > 0 and "only under vendor value" or "none listed") or "not scanned") .. "|r") })
  if r.made > 0 and NS.deValue then   -- what disenchanting it would give (LedgerDisenchant.lua); nothing for what cannot be
    local dv, dknown, dd = NS.deValue(r.made, ctx)
    if dd then
      add({ key = "de", left = "Disenchant", c2 = DIM .. (dd.o.est and "~ estimate" or "measured") .. "|r",
        right = dknown and (money(dv * f.mk) .. (dd.o.est and (DIM .. " ~|r") or "")) or (DIM .. "materials not scanned|r"),
        tip = { "What its disenchant materials sell for at the auction house, after the cut" .. (dd.o.est and ". ~: from the original game's disenchant table, not confirmed for Forever." or ", at the rates your own disenchants gave."),
          "The Disenchant page has the outcomes one by one. Kebold never disenchants anything itself." } })
    end
  end
  if r.made > 0 then
    local pick = S.sellPick[r.made]
    local way = NS.wayLong(x.way)
    local text = pick and NS.SELL_TEXT[pick] or ("Auto: " .. (way or "not counted"))
    add({ left = "Sells at", c2 = (pick and GOLD or "") .. text .. (pick and "|r" or ""), right = f.sale and money(f.sale) or (DIM .. "not counted|r"),
      sellItem = r.made, choice = true,
      control = { kind = "choice", text = text, items = function() return NS.rowMenu({ sellItem = r.made }) end,
        tip = { "Sells at", "Auto follows the plan's Sells at (" .. NS.SALES[S.sales] .. "); gear on Auto goes to a vendor.", "Vendor / Auction house / Disenchant: this product always counts that way." } },
      tip = { "Auto follows the plan's Sells at (" .. NS.SALES[S.sales] .. "); gear on Auto goes to a vendor.",
        "In the Craft list a right-click on the recipe gives the same choice.", GOLD .. "Click or right-click for choices.|r" } })
  end
  if r.made > 0 and type(KeboldsShinySales) == "table" then
    local ok, s = pcall(KeboldsShinySales.summary, r.made)
    if ok and s and ((s.posted or 0) > 0) then
      local share = NS.soldShare(r.made)
      add({ left = "Your auctions", right = (s.soldQty or 0) .. " sold, " .. (s.expiredQty or 0) .. " expired" .. ((s.openQty or 0) > 0 and (", " .. s.openQty .. " listed") or ""),
        tip = { share and string.format("%.0f%% of yours sold: the route counts that share of what is listed at the AH price.", 100 * share)
          or "Too few finished auctions to judge (5 needed): the AH sales cap setting is used.", "/keboldsales lists everything tracked." } })
    end
  end
  if r.made > 0 and type(KeboldsShinyHistory) == "table" then
    local ok, med, days = pcall(KeboldsShinyHistory.median, r.made)
    if ok and med and (days or 0) >= 3 then
      local ok2, drop = pcall(KeboldsShinyHistory.drop, r.made)
      add({ left = "Usual AH price", right = money(med * f.mk) .. DIM .. "  median of " .. days .. " scan days|r" .. ((ok2 and drop) and (RED .. string.format("  now %.0f%% under", 100 * drop) .. "|r") or ""),
        tip = { "From this addon's own scans, one reading a day. Shown only: prices are never replaced by it." } })
    end
  end

  -- 7. how many are worth making, and 8. the buy list for any number of crafts
  local store = qtyStore()
  local function setQty(n) NS.setPanelQty(r.id, n) end
  if w then
    head("How many are worth making")
    local limit = w.worth ~= huge and w.worth or nil
    local count = w.worth == huge and (w.known and "no limit" or "unknown") or tostring(w.worth)
    add({ left = "Crafts before it stops paying", right = (w.known and "" or DIM .. "~|r") .. count })
    if w.total and w.total ~= huge and w.worth ~= huge then add({ left = "Profit over them", right = signed(w.total) }) end
    local stop = w.stop
    if stop then
      local why = stop.why == "out" and ("then " .. itemName(stop.n) .. " runs out")
        or (stop.why == "cap" and "then the auction house has enough of them")
        or "then the materials cost too much"
      add({ left = DIM .. why .. "|r" })
    end
    local bands = NS.worthBands(w, x.secs)
    local qty = store[r.id]
    if not qty then
      qty = (limit and limit > 0 and limit) or ((bands[1] and bands[1].to ~= huge) and floor(bands[1].to + 1e-9)) or 1
    end
    qty = max(1, min(QTY_MAX, qty))
    if #bands > 0 then
      add({ left = DIM .. "crafts|r", c2 = DIM .. "profit each|r", right = DIM .. "per hour|r" })
      local shown = 0
      for _, b in ipairs(bands) do
        local first, last = floor(b.from + 1e-9) + 1, b.to ~= huge and floor(b.to + 1e-9) or nil
        if last == nil or last >= first then
          shown = shown + 1
          if shown > 10 then
            add({ left = DIM .. "... " .. (#bands - 10) .. " more price steps|r" })
            break
          end
          local inBand = qty >= first and (last == nil or qty <= last)
          local after = b.nx == "AH" and "After that the auction house has enough of them: the rest count at vendor value."
            or (b.nx and ("After that " .. itemName(b.nx) .. " gets dearer.") or "The price does not move after that.")
          local tip = { "Crafts " .. first .. (last and (" to " .. last) or " and on"), after }
          if b.total then tip[#tip + 1] = "Profit up to here: " .. signed(b.total) end
          if last then tip[#tip + 1] = GOLD .. "Click to set the buy list to " .. last .. " crafts.|r" end
          add({ left = (inBand and GOLD .. "> |r" or "   ") .. first .. (last and (" to " .. last) or " on"), c2 = signed(b.each), right = b.ph and signed(b.ph) or (DIM .. "-|r"),
            band = true, tip = tip, action = last and function() setQty(last) end or nil })
        end
      end
    end

    head("Buy list", "pay up to, in all")
    if #w.segs == 0 then
      add({ left = DIM .. "Nothing to list: " .. ((stop and stop.why == "out") and (itemName(stop.n) .. " is not listed.") or "no price steps.") .. "|r" })
    else
      local plan = NS.buyPlan(w, qty)
      local done = floor(plan.crafts + 1e-9)
      if done < qty and done >= 1 then plan = NS.buyPlan(w, done) end   -- the listings end first: whole crafts only
      add({ left = "Crafts to make", c2 = tostring(qty), right = DIM .. (limit and (limit .. " worth making") or (w.known and "no limit" or "limit unknown")) .. "|r",
        qtyRow = true, qty = qty, worth = limit,
        -- the plain skin draws no controls: there a click adds and a right-click takes away, as it used to
        action = UI.plain() and function(button) setQty(button == "RightButton" and (qty - qtyStep(qty)) or (qty + qtyStep(qty))) end or nil,
        control = { kind = "stepper", get = function() return qty end, set = setQty, min = 1, max = QTY_MAX,
          tip = { "Crafts to make", "Type a number, or use - and +. Any number can be asked for; the list says when it goes past the crafts worth making.",
            "A click on a line of price steps above jumps to the end of that step. Kept for this recipe." } },
        tip = { "Crafts to make", "How many crafts the list below is for. Any number: past the crafts worth making the extra ones lose money, and the list says so." } })
      for _, m in ipairs(plan.mats) do
        local units = ceil(m.units - 1e-9)
        local have = bags(m.n)
        local tip = { itemName(m.n), "Buy " .. units .. ", cheapest listings first, and stop at " .. NS.plain(money(m.top)) .. " each." }
        if m.units > 0 then tip[#tip + 1] = "That is " .. NS.plain(money(floor(m.cost / m.units + 0.5))) .. " each on average." end
        if have > 0 then tip[#tip + 1] = "You have " .. have .. " in your bags: " .. max(0, units - have) .. " still to buy. The sums here are for all " .. units .. "." end
        tip[#tip + 1] = "From the price steps of the last scan; a vendor's price never runs out."
        add({ left = "   " .. units .. "x " .. itemName(m.n) .. (have > 0 and (DIM .. "  have " .. have .. "|r") or ""), item = m.n,
          c2 = DIM .. "up to|r " .. money(m.top), right = money(floor(m.cost + 0.5)),
          buyLine = { item = m.n, units = units, top = m.top, cost = floor(m.cost + 0.5), bags = have }, tip = tip })
      end
      add({ left = "Materials in all", right = money(floor(plan.cost + 0.5)) })
      add({ left = "Profit", right = signed(floor(plan.profit + 0.5)) })
      if x.secs and x.secs > 0 and plan.crafts > 0 then
        add({ left = "Per hour over them", right = signed(floor(plan.profit / (plan.crafts * x.secs) * 3600 + 0.5)) })
        local t = plan.crafts * x.secs
        add({ left = "Casting time", right = t >= 5400 and string.format("%.1f h", t / 3600) or secs(t) })
      end
      if done < qty then
        add({ left = RED .. "Only " .. done .. " of " .. qty .. " can be bought from what is listed.|r", warn = "short" })
      end
      if limit and min(qty, done) > limit then
        add({ left = RED .. (limit == 0 and "No craft pays at these prices: every one loses money."
          or ("Past the " .. limit .. " worth making: the " .. (min(qty, done) - limit) .. " extra lose money.")) .. "|r", warn = "past" })
      end
      if not w.known then
        add({ left = DIM .. "~ a material has no scanned price steps: its price is assumed not to move.|r" })
      end
      if NS.shopAdd then
        local want = { kind = "recipe", prof = r.prof, id = r.id, n = qty }
        local function addIt()
          local ok, at, why = pcall(NS.shopAdd, want)
          if ok and at then
            NS.notice(qty .. "x " .. r.name .. " added to the shopping list.")
          else
            NS.notice("Not added: " .. tostring((ok and why) or at or "the shopping list refused it") .. ".", "warn")
          end
        end
        add({ left = "Shopping list", c2 = "Add " .. qty, right = DIM .. (qty == 1 and "1 craft" or (qty .. " crafts")) .. "|r", shopAdd = want,
          action = UI.plain() and addIt or nil,   -- (the plain skin has no button on the line)
          control = { kind = "button", text = "Add to list", onClick = addIt,
            tip = { "Add to the shopping list", "Puts " .. qty .. "x " .. r.name .. " on the Shopping page, which adds up everything you want to make and takes off what is in your bags." } },
          tip = { "Puts " .. qty .. "x " .. r.name .. " on the Shopping page." } })
      end
    end
  elseif x.cost ~= nil then
    -- no sale price, so no profit to walk: still a list of what the crafts buy
    head("Buy list", "in all")
    local qty = max(1, min(QTY_MAX, store[r.id] or 1))
    add({ left = "Crafts to make", c2 = tostring(qty), right = DIM .. "no sale price|r", qtyRow = true, qty = qty,
      control = { kind = "stepper", get = function() return qty end, set = setQty, min = 1, max = QTY_MAX, tip = { "Crafts to make", "Type a number, or use - and +." } },
      tip = { "Crafts to make", "How many crafts the list below is for." } })
    local shop = mc.shopping({ { r = r, crafts = qty } })
    for _, b in ipairs(shop.buy) do
      local units = ceil(b.qty - 1e-9)
      add({ left = "   " .. units .. "x " .. itemName(b.item), item = b.item, right = b.cost and money(floor(b.cost + 0.5)) or (RED .. "no price|r"),
        buyLine = { item = b.item, units = units, cost = b.cost and floor(b.cost + 0.5) or nil, bags = bags(b.item) },
        tip = { itemName(b.item), (b.short and b.short > 1e-9) and ("Only " .. floor(b.qty - b.short) .. " are listed.") or "Cheapest listings first." } })
    end
    add({ left = "Materials in all", right = money(floor(shop.cost + 0.5)) })
    add({ left = DIM .. "Nothing says what it sells for, so there is no profit to show.|r" })
  else
    head("Buy list")
    add({ left = DIM .. "A material has no price yet: scan this recipe's items first.|r" })
  end

  -- the actions: lines of the model here (button = true); the pane shows them as the buttons of its foot
  add({ left = "", button = true })
  add({ left = GOLD .. "Actions|r", right = "", button = true })
  add({ left = "Show it in the profession window", button = true, action = function() NS.showRecipe(r.id) end })
  if r.made > 0 then
    add({ left = "Scan the auction house for this recipe's items", item = r.made, button = true, action = function() NS.scanRecipe(r.id) end })
  end
  add({ left = "Link it in chat", button = true, action = function() NS.linkRow({ recipe = r.id, item = r.made > 0 and r.made or nil }) end })
  add({ left = "Favourite", right = S.fav[r.id] and (GOLD .. "[yes]|r") or (DIM .. "[no]|r"), button = true, action = function()
    NS.setFav(r.id, not S.fav[r.id])
  end })
  add({ left = "Skip this recipe in routes", right = S.exclude[r.id] and (GOLD .. "[skipped]|r") or (DIM .. "[used]|r"), button = true, action = function()
    NS.setSkip(r.id, not S.exclude[r.id])
  end, tip = { "A skipped recipe is never picked by the leveling route. Click again to use it." } })
  return out
end
NS.buildPanel = buildPanel

-- ---- the details pane ------------------------------------------------------------------------------------------------
-- One frame (KeboldsShinyPanel) that sits in the right pane of the page showing (Level, Craft, My sales): a head
-- (icon, name, one line of facts, the skill bar), the lines of buildPanel in a table of their own, and a foot with
-- the actions as buttons. It also shows one item's sales and price history (LedgerSalesTab.lua), and an empty
-- state while nothing is chosen. The shell tells it where it is and how large (NS.detailAttach, NS.detailLayout).
local HEAD_H, FOOT_H, FOOT_WRAP = 82, 30, 340   -- under FOOT_WRAP wide the foot's two check boxes go on a second row
local CTL = { w = 92, stepBox = 36 }   -- the control over a line's middle cell (guesses, like every size here); its height is the density's

-- ---- controls over lines -------------------------------------------------------------------------------------------
-- A line whose row carries `control` gets a real widget over its middle cell (c2): a button that opens a menu
-- (kind "choice"), a typed number with - and + ("stepper"), or a plain button ("button"). The widgets belong to
-- the line and are made the first time a line needs one; what they show and do is read from the row the line
-- holds at that moment, so scrolling re-uses them. The cell's own text is blanked under a widget.
local function controlOf(line)
  local row = rawget(line, "row")
  local c = row and row.control
  return type(c) == "table" and c or nil
end

local function lineWidgets(line)
  local ctl = rawget(line, "ctl")
  if type(ctl) == "table" then return ctl end
  ctl = {}
  ctl.button = UI.button(line, "", CTL.w, function(self)
    local c = controlOf(line)
    if not c then return end
    if c.kind == "choice" then
      local items = c.items and c.items() or {}
      if #items > 0 then UI.menu(self, items) end
    elseif c.onClick then
      c.onClick()
    end
  end, function()
    local c = controlOf(line)
    return c and c.tip or nil
  end)
  ctl.button:Hide()
  ctl.step = UI.stepper(line, { w = CTL.stepBox, step = function(v) return qtyStep(v or 1) end,
    min = function() local c = controlOf(line) return c and c.min or 1 end,
    max = function() local c = controlOf(line) return c and c.max or nil end,   -- nothing = no upper limit
    tip = function() local c = controlOf(line) return c and c.tip or nil end },
    function()
      local c = controlOf(line)
      return c and c.get and c.get() or 1
    end,
    function(v)
      local c = controlOf(line)
      if c and c.set then c.set(v) end
    end)
  ctl.step:Hide()
  line.ctl = ctl
  return ctl
end

local function dressControls(t)
  local k2
  for k, col in ipairs(t.columns) do
    if col.key == "c2" then k2 = k end
  end
  for _, line in ipairs(t.lines) do
    local c = line:IsShown() and controlOf(line) or nil
    local ctl = rawget(line, "ctl")
    if c and k2 and t.shown[k2] and not UI.plain() then
      ctl = lineWidgets(line)
      local right = t.xs[k2] + t.ws[k2]   -- the middle cell's right edge, from the line's left
      local fs = line.cells and line.cells[k2]
      if type(fs) == "table" then fs:SetText("") end
      if c.kind == "stepper" then
        ctl.button:Hide()
        ctl.step:ClearAllPoints()
        ctl.step:SetPoint("RIGHT", line, "LEFT", right, 0)
        ctl.step:Refresh()
        ctl.step:Show()
      else
        ctl.step:Hide()
        ctl.button:ClearAllPoints()
        ctl.button:SetPoint("RIGHT", line, "LEFT", right, 0)
        ctl.button:SetSize(min(UI.px(CTL.w), t.ws[k2]), min(t.rowH - 2, UI.density().ctl))
        ctl.button:SetLabel((c.text or "") .. (c.kind == "choice" and " v" or ""))
        ctl.button:SetEnabled(c.off == nil, c.off)
        ctl.button:Show()
      end
    elseif type(ctl) == "table" then
      ctl.button:Hide()
      ctl.step:Hide()
    end
  end
end

local function paintPanel()
  if not panel then return end
  local view = {}   -- the actions are buttons in the foot, not lines
  for _, row in ipairs(panelRows) do
    if not row.button then view[#view + 1] = row end
  end
  while #view > 0 and (view[#view].left or "") == "" and not view[#view].right do view[#view] = nil end
  panel.list:SetTop((panelMode == "item" and panel.chartOn == true) and 64 or 0)   -- the price chart sits above the item's lines
  panel.list:SetRows(view)
end

local SKILL_RGB = { o = { 1, 0.5, 0.25 }, y = { 1, 1, 0 }, g = { 0.25, 0.75, 0.25 }, x = { 0.5, 0.5, 0.5 } }

-- The four colours of a recipe from the level it is learned at to grey, with a white mark at the skill it is
-- judged at. Returns the widths it used (for tests).
local function paintSkill(r, at)
  local bar = panel.skill
  if not (r and r.col and r.grey and r.y and r.grey > r.learn) then
    bar:Hide()
    return nil
  end
  local barW = panel.barW
  local lo, hi = r.learn, r.grey + max(5, floor((r.grey - r.learn) * 0.1))   -- a little grey after the end
  local span = hi - lo
  local edge = { lo, max(lo, min(hi, r.y)), max(lo, min(hi, r.g or r.grey)), max(lo, min(hi, r.grey)), hi }
  local x, widths = 0, {}
  for i, key in ipairs({ "o", "y", "g", "x" }) do
    local w = floor((edge[i + 1] - edge[i]) / span * barW + 0.5)
    widths[i] = w
    local t = bar.part[key]
    t:ClearAllPoints()
    t:SetPoint("LEFT", x, 0)
    t:SetSize(max(1, w), 10)
    if w > 0 then t:Show() else t:Hide() end
    x = x + w
  end
  local where = max(lo, min(hi, at or lo))
  bar.marker:ClearAllPoints()
  bar.marker:SetPoint("LEFT", floor((where - lo) / span * barW + 0.5) - 1, 0)
  bar.at = where
  bar:Show()
  return widths
end

local function qualityRGB(item)
  local q = item and C_Item and try(C_Item.GetItemQualityByID, item)
  local c = type(q) == "number" and type(ITEM_QUALITY_COLORS) == "table" and ITEM_QUALITY_COLORS[q] or nil
  if type(c) == "table" and c.r then return c.r, c.g, c.b end
  return 0.6, 0.6, 0.6
end

local function panelHeader(icon, item, name, sub)
  local tex = (not UI.plain() and settings().icons ~= false and (item or icon)) and UI.iconOf({ item = item, recipe = icon }) or nil
  if tex then
    panel.icon:SetTexture(tex)
    panel.icon:Show()
    panel.iconEdge:SetColorTexture(qualityRGB(item))
    panel.iconEdge:Show()
  else
    panel.icon:Hide()
    panel.iconEdge:Hide()
  end
  panel.name:ClearAllPoints()
  panel.name:SetPoint("TOPLEFT", tex and 50 or 4, -18)
  panel.sub:ClearAllPoints()
  panel.sub:SetPoint("TOPLEFT", tex and 50 or 4, -38)
  panel.name:SetText(name or "")
  panel.sub:SetText(UI.show(sub or ""))
end

local function fillPanel()
  if not (panel and panel:IsShown()) then return end
  local list, ok
  local r = panelMode == "recipe" and panelRecipe and NS.data().byId[panelRecipe] or nil
  if panelMode == "item" and panelItem and NS.buildItemPanel then
    local lows
    ok, list, lows = pcall(NS.buildItemPanel, panelItem)
    panel.title:SetText("Item details")
    panelHeader(nil, panelItem, NS.itemText(panelItem), DIM .. "your auctions and the scans' price history|r")
    paintSkill(nil)
    panel.chartOn = ok and type(lows) == "table" and #lows > 1
    if panel.chartOn then
      panel.chart:Set(lows)
      panel.chart:Show()
      panel.chartNote:SetText(DIM .. #lows .. " scan days, lowest price of each|r")
      panel.chartNote:Show()
    else
      panel.chart:Hide()
      panel.chartNote:Hide()
    end
  elseif r then
    ok, list = pcall(buildPanel, r)
    local c = NS.state()
    local f = figures(c, r)
    panel.title:SetText("Recipe details")
    panelHeader(r.id, r.made > 0 and r.made or nil, NS.COLOUR[c.ctx.colour(r, f.at)] .. r.name .. "|r",
      r.prof .. " \194\183 learn " .. r.learn .. (r.est and "~" or "") .. " \194\183 " .. (f.known and (GREEN .. "known|r") or (DIM .. sourceWord(r) .. "|r")))
    paintSkill(r, f.at)
    panel.chartOn = false
    panel.chart:Hide()
    panel.chartNote:Hide()
  else   -- nothing chosen yet: the table's empty state says what to do
    panel.title:SetText("Details")
    panelHeader(nil, nil, "", "")
    paintSkill(nil)
    panel.chartOn = false
    panel.chart:Hide()
    panel.chartNote:Hide()
    panelRows = {}
    for _, w in ipairs(panel.foot) do w:Hide() end
    paintPanel()
    return
  end
  panelRows = ok and list or { { left = RED .. "The details hit an error:|r" }, { left = tostring(list) } }
  if not ok then NS.say("Details error: " .. tostring(list)) end
  local recipe = panelMode ~= "item"
  for _, w in ipairs(panel.foot) do w:Show() end
  for _, w in ipairs(panel.recipeOnly) do
    if recipe then w:Show() else w:Hide() end
  end
  if recipe then
    panel.cSkip:Refresh()
    panel.cFav:Refresh()
  end
  paintPanel()
end

-- The pane's lines behave like a page's, plus a recipe link on the first line.
local function panelClick(b, button)
  local row = rawget(b, "row")
  if not row then return end
  if row.linkRecipe and IsShiftKeyDown and IsShiftKeyDown() then
    local link = C_TradeSkillUI and try(C_TradeSkillUI.GetRecipeLink, row.linkRecipe)
    if link and ChatEdit_InsertLink then pcall(ChatEdit_InsertLink, link) end
    return
  end
  NS.rowClick(b, button)
end

-- What the foot's buttons act on: the recipe's product, or the item shown.
local function panelItemID()
  if panelMode == "item" then return panelItem end
  local r = panelRecipe and NS.data().byId[panelRecipe]
  return r and r.made > 0 and r.made or nil
end

local function createPanel()
  local p = CreateFrame("Frame", "KeboldsShinyPanel", NS.frame())
  panel = p
  p.skinUsed, p.host, p.chartOn = "pane", false, false
  p.barW = NS.WIN.detail - 8
  p:SetSize(NS.WIN.detail, 400)

  -- head
  p.title = UI.text(p, "dim", "Details")
  p.title:SetPoint("TOPLEFT", 4, -2)
  p.iconEdge = p:CreateTexture(nil, "BORDER")
  p.iconEdge:SetSize(40, 40)
  p.iconEdge:SetPoint("TOPLEFT", 4, -16)
  p.icon = p:CreateTexture(nil, "ARTWORK")
  p.icon:SetSize(36, 36)
  p.icon:SetPoint("TOPLEFT", 6, -18)
  p.name = UI.text(p, "title")
  p.name:SetWidth(NS.WIN.detail - 56)
  p.name:SetJustifyH("LEFT")
  p.name:SetWordWrap(false)
  p.sub = UI.text(p, "body")
  p.skill = CreateFrame("Frame", nil, p)
  p.skill:SetSize(p.barW, 10)
  p.skill:SetPoint("TOPLEFT", 4, -64)
  p.skill.part = {}
  for key, c in pairs(SKILL_RGB) do
    local t = p.skill:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(c[1], c[2], c[3], 0.9)
    p.skill.part[key] = t
  end
  p.skill.marker = p.skill:CreateTexture(nil, "OVERLAY")
  p.skill.marker:SetColorTexture(1, 1, 1, 1)
  p.skill.marker:SetSize(2, 14)
  p.skill:EnableMouse(true)
  UI.tip(p.skill, function()
    local r = panelRecipe and NS.data().byId[panelRecipe]
    if not r then return nil end
    return { "Skill", "Orange from " .. r.learn .. ", yellow from " .. r.y .. ", green from " .. (r.g or "?") .. ", grey at " .. r.grey .. ".",
      "The white mark is the skill the figures below are worked out at (" .. (p.skill.at or "?") .. ")." }
  end)

  -- the lines: a label, a middle figure on the three-column lines (price steps, buy list), the value
  p.list = UI.table(p, { { key = "left", flex = 1, min = 108 }, { key = "c2", width = 80, align = "RIGHT" }, { key = "right", width = 80, align = "RIGHT" } },
    { header = false, onClick = panelClick, onEnter = NS.rowEnter, onLeave = NS.rowLeave,
      empty = { icon = "Interface\\Icons\\INV_Misc_Note_01", title = "Nothing selected",
        text = "Click a recipe or an item in the list and its details show here: materials, where it sells, how many are worth making." } })
  p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -HEAD_H)
  -- every paint of the pane's own list (rows set, scrolled, resized) ends by putting the controls on their lines
  local paintList = p.list.Paint
  function p.list:Paint()
    paintList(self)
    dressControls(self)
  end
  p.scroll = p.list.scroll
  -- an item's price history: bars above its lines
  p.chart = UI.bars(p.list, NS.WIN.detail - 40, 46)
  p.chart:SetPoint("TOPLEFT", 8, -4)
  p.chart:Hide()
  p.chartNote = UI.text(p.list, "dim")
  p.chartNote:SetPoint("TOPLEFT", 8, -52)
  p.chartNote:Hide()

  -- the foot: the actions as buttons
  p.bProf = UI.button(p, "Open recipe", 84, function()
    if panelRecipe then NS.showRecipe(panelRecipe) end
  end, { "Open recipe", "Shows the recipe in your open profession window." })
  p.bProf:SetPoint("BOTTOMLEFT", 2, 3)
  p.bSearch = NS.scanControl(UI.button(p, "Scan AH", 66, function()
    if panelMode ~= "item" and panelRecipe then
      NS.scanRecipe(panelRecipe)
    else
      NS.scanItem(panelItemID())
    end
  end, { "Scan AH", "Reads fresh auction house prices for what this recipe makes and everything needed to make it (a few seconds), then updates the figures here.",
    "To browse the listings instead, right-click a line and choose Search the auction house." }))
  p.bSearch:SetPoint("LEFT", p.bProf, "RIGHT", 3, 0)
  p.bLink = UI.button(p, "Link", 44, function()
    NS.linkRow({ recipe = panelMode ~= "item" and panelRecipe or nil, item = panelItemID() })
  end, { "Link", "Puts a link into the chat line you are typing." })
  p.bLink:SetPoint("LEFT", p.bSearch, "RIGHT", 3, 0)
  p.cFav = UI.check(p, "Favourite", function()
    return panelRecipe ~= nil and settings().fav[panelRecipe] == true
  end, function(v)
    if panelRecipe then NS.setFav(panelRecipe, v) end
  end, { "Favourite", "Favourites have their own Show filter on the Craft page and their own scan (Scan favourites, /keboldscan fav)." })
  p.cSkip = UI.check(p, "Skip", function()
    return panelRecipe ~= nil and settings().exclude[panelRecipe] == true
  end, function(v)
    if panelRecipe then NS.setSkip(panelRecipe, v) end
  end, { "Skip", "A skipped recipe is never picked by the leveling route." })
  p.footH = FOOT_H   -- NS.detailLayout places the two check boxes: beside the buttons, or on a row of their own
  p.foot = { p.bProf, p.bSearch, p.bLink, p.cFav, p.cSkip }
  p.recipeOnly = { p.bProf, p.cSkip, p.cFav }
end

-- The shell gives the pane its size (the right pane of the page's split).
function NS.detailLayout(page, w, h)
  if not panel then return end
  panel:SetSize(w, h)
  panel.barW = w - 8
  panel.skill:SetWidth(panel.barW)
  panel.name:SetWidth(w - 56)
  -- the foot: three buttons and two check boxes in one row (about 334 px), or the check boxes above the buttons
  local wrap = w < FOOT_WRAP
  panel.footH = wrap and (FOOT_H + 22) or FOOT_H
  panel.cFav:ClearAllPoints()
  panel.cSkip:ClearAllPoints()
  if wrap then
    panel.cFav:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 2, FOOT_H - 2)
  else
    panel.cFav:SetPoint("LEFT", panel.bLink, "RIGHT", 6, 0)
  end
  panel.cSkip:SetPoint("LEFT", panel.cFav, "RIGHT", 78, 0)   -- past the Favourite label
  panel.list:Layout(w, h - HEAD_H - panel.footH)
end

-- Called on every refresh of a page with a details pane: puts the one pane into that page's split and shows it,
-- or hides it while the split is folded.
-- A page with a pane of its own in the same place (Level: the selected step) says who has the split's right side:
--   page.detailMine(page) -> true   the page's own pane shows there now; this one stays hidden
--   page.onDetail(page, kind, id)   a recipe ("recipe") or an item ("item") was opened while the page shows
function NS.detailAttach(page)
  local s = page.split
  if type(s) ~= "table" then return end
  if s.rightW <= 0 or (page.detailMine and page.detailMine(page) == true) then
    if panel then panel:Hide() end
    return
  end
  if not panel then createPanel() end
  if panel.host ~= s.right then
    panel.host = s.right
    pcall(panel.SetParent, panel, s.right)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", s.right, "TOPLEFT", 0, 0)
  end
  NS.detailLayout(page, s.rightW, s.h)
  panel:Show()
end

-- Shows the pane with what was chosen: on the page showing when it has one (unfolding it), else on `fallback`.
local function showDetail(fallback)
  local S = settings()
  local page = NS.currentPage()
  local same = page and page.detail and not S.detailOff and panel and panel:IsShown()
  if same and type(page.split) == "table" and page.split.rightW > 0 then
    fillPanel()
    NS.repaint()   -- the list marks the line that is open
    return
  end
  if not (page and page.detail) then S.tab = fallback end
  S.detailOff = nil
  NS.refresh()
end

function NS.openPanel(recipeID)
  if not NS.frame() then return end
  if (panelMode ~= "recipe" or panelRecipe ~= recipeID) and panel then panel.list.offset = 0 end
  panelMode, panelRecipe = "recipe", recipeID
  local page = NS.currentPage()
  if page and page.onDetail then page.onDetail(page, "recipe", recipeID) end
  showDetail("recipes")
end

-- One item instead of a recipe: its auctions and the price history of the scans (My sales' lines open it).
function NS.openItemPanel(itemID)
  if not NS.frame() then return end
  if (panelMode ~= "item" or panelItem ~= itemID) and panel then panel.list.offset = 0 end
  panelMode, panelItem = "item", itemID
  local page = NS.currentPage()
  if page and page.onDetail then page.onDetail(page, "item", itemID) end
  showDetail("sales")
end

-- What the pane shows: the recipe's id, or the item's (nil when it shows the other kind, or nothing).
function NS.detailRecipe() return panelMode == "recipe" and panelRecipe or nil end
function NS.detailItem() return panelMode == "item" and panelItem or nil end

function NS.onRefresh()
  fillPanel()
end

function NS.panel() return panel, panel and panel.list.lines or {}, panelRows end   -- for tests
