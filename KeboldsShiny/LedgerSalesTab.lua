-- Kebold's Shiny: the My sales page and the Prices page (row builders, their controls, their columns)
--   My sales: three views behind a switch (My auctions, Recent events, Price history), each a table that sorts by
--             any column. A click on a line opens the item in the details pane, with a bar chart of its daily lows.
--   Prices:   four cards: Scan (one button per scan, the plan they follow, Stop, the progress), Last scan (its items
--             as a table), Prices by profession and Vendor values that changed. NS.pricesView builds them; the same
--             view is shown inside the auction house by LedgerAH.lua, from the same rows, so the two cannot disagree.
-- Both only read what the scanner and the sale tracker saved. (The pages' keys are still "sales" and "scan".)
-- The logic output is row tables: NS.buildSales() and NS.buildScan(). The controls only show what those rows say.

local NS = KeboldsShinyNS
local UI = KeboldsShinyUI
local E = NS.E
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local DIM, RED, GOLD, WHITE, GREEN = NS.DIM, NS.RED, NS.GOLD, NS.WHITE, NS.GREEN
local money, itemName, settings, try = NS.money, NS.itemName, NS.settings, NS.try

local function isTable(x) return type(x) == "table" end

-- ---- My sales --------------------------------------------------------------------------------------------------------

local VIEW = { items = "My auctions", events = "Recent events", history = "Price history" }
local VIEW_ORDER = { "items", "events", "history" }
local VIEW_TIP = { items = "Every item you posted: how many auctions and units sold, expired or were cancelled.",
  events = "What happened to your auctions, newest first.", history = "One reading a day from this addon's scans: the price now against the usual one." }
local KIND_COLOUR = { posted = WHITE, sold = GREEN, expired = RED, cancelled = DIM }
NS.SALES_VIEWS, NS.SALES_VIEW_ORDER = VIEW, VIEW_ORDER

local search = ""

local function today()
  return floor(((try(time) or 0) - NS.DAY_ZERO) / 86400)
end

local function dayWord(day)
  if not day then return DIM .. "-|r" end
  local age = today() - day
  return age <= 0 and "today" or (age == 1 and "yesterday" or (age .. " days ago"))
end

local function matches(name)
  return search == "" or tostring(name):lower():find(search:lower(), 1, true) ~= nil
end

-- what a click on a column head sorts by, per view, in the columns' order
local SORT = {
  items = {
    function(x) return x.name end, function(x) return x.postedQty end, function(x) return x.soldQty end, function(x) return x.expiredQty end,
    function(x) return x.cancelledQty end, function(x) return x.openQty end, function(x) return x.rate end, function(x) return x.saleDay end,
  },
  events = {
    function(e) return e.day end, function(e) return e.kind end, function(e) return string.lower(e.name) end, function(e) return e.qty or 1 end,
    function(e) return e.unit end,
  },
  history = {
    function(h) return string.lower(h.name) end, function(h) return h.now > 0 and h.now or nil end, function(h) return h.usual end,
    function(h) return h.change end, function(h) return h.days end, function(h) return h.listed or 0 end,
  },
}

-- The column a view is sorted by and whether downwards: nil for the view's own order.
local function sortOf(view)
  local S = settings()
  if view == "items" then return S.salesSort, S.salesDesc and true or false end
  local st = isTable(S.salesSorts) and S.salesSorts[view] or nil
  if isTable(st) then return st[1], st[2] and true or false end
  return nil, false
end

-- A click on a column head of the view showing. My auctions: up / down. The other two: up, down, then the view's
-- own order again (newest first; price drops first).
function NS.sortSales(k)
  local S = settings()
  local view = S.salesView
  if view == "items" then
    if S.salesSort == k then S.salesDesc = not S.salesDesc else S.salesSort, S.salesDesc = k, k ~= 1 end
  else
    if not isTable(S.salesSorts) then S.salesSorts = {} end
    local st = S.salesSorts[view]
    if isTable(st) and st[1] == k then
      if st[2] then S.salesSorts[view] = nil else st[2] = true end
    else
      S.salesSorts[view] = { k, false }
    end
  end
  NS.resetScroll()
  NS.refresh()
end

-- Sorts by what `key` reads; lines without the value go last either way round, equal ones keep `tie`'s order.
local function sortBy(list, key, desc, tie)
  table.sort(list, function(a, b)
    local va, vb = key(a), key(b)
    if va == nil or vb == nil then
      if va == nil and vb == nil then return tie(a, b) end
      return vb == nil
    end
    if va == vb then return tie(a, b) end
    if desc then return va > vb end
    return va < vb
  end)
end

local function qty(auctions, units)
  if (auctions or 0) == 0 and (units or 0) == 0 then return DIM .. "-|r" end
  return units .. DIM .. " (" .. auctions .. ")|r"
end

local NO_AUCTIONS = { icon = "Interface\\Icons\\INV_Letter_15", title = "No auctions tracked yet",
  text = "Post something, or open the Auctions tab at the auction house: Kebold then keeps count of what sold, expired and was cancelled." }

local function noMatch(out)
  out[#out + 1] = { left = DIM .. "Nothing here has \"" .. search .. "\" in its name. Empty the search box to see everything.|r",
    empty = { icon = "Interface\\Icons\\INV_Misc_Spyglass_03", title = "Nothing matches",
      text = "Nothing here has \"" .. search .. "\" in its name. Empty the search box to see everything." } }
end

local function buildItems(out)
  local SA = KeboldsShinySales
  local list = type(SA) == "table" and type(SA.items) == "function" and SA.items() or {}
  local shown = {}
  for _, x in ipairs(list) do
    if matches(x.name) then shown[#shown + 1] = x end
  end
  local k, desc = sortOf("items")
  local key = SORT.items[k or 0]
  if key then sortBy(shown, key, desc, function(a, b) return a.id < b.id end) end
  if #list == 0 then
    out[#out + 1] = { left = DIM .. "No auctions tracked yet. Post something, or open the Auctions tab at the auction house.|r", empty = NO_AUCTIONS }
    return
  end
  if #shown == 0 then return noMatch(out) end
  out[#out + 1] = { caption = true, left = DIM .. #shown .. " of " .. #list .. " items you posted. Units, with the number of auctions in brackets. Click a line for the item's details.|r" }
  for _, x in ipairs(shown) do
    local rate = DIM .. "-|r"
    if x.rate then rate = (x.rate >= 0.7 and GREEN or (x.rate < 0.3 and RED or "")) .. string.format("%.0f%%", 100 * x.rate) .. ((x.rate >= 0.7 or x.rate < 0.3) and "|r" or "") end
    out[#out + 1] = { cols = { NS.itemText(x.id, x.name), qty(x.posted, x.postedQty), qty(x.sold, x.soldQty), qty(x.expired, x.expiredQty),
        qty(x.cancelled, x.cancelledQty), qty(x.open, x.openQty), rate, x.salePrice and (money(x.salePrice) .. DIM .. " " .. dayWord(x.saleDay) .. "|r") or (DIM .. "-|r") },
      item = x.id, itemPanel = x.id, tip = { "Sold % is the share of finished units (sold or expired) that sold: green from 70%, red under 30%.",
        "From 5 finished auctions on, the route counts that share of what is listed at the AH price for this product.", "Click for its events and price history." } }
  end
end

local function buildEvents(out)
  local SA = KeboldsShinySales
  local list = type(SA) == "table" and type(SA.events) == "function" and SA.events() or {}
  if #list == 0 then
    out[#out + 1] = { left = DIM .. "No auctions tracked yet. Post something, or open the Auctions tab at the auction house.|r", empty = NO_AUCTIONS }
    return
  end
  local shown = {}
  for i, e in ipairs(list) do
    local name = itemName(e.item)
    if matches(name) then shown[#shown + 1] = { n = i, e = e, name = name, day = e.day, kind = e.kind, qty = e.qty, unit = e.unit } end
  end
  if #shown == 0 then return noMatch(out) end
  local k, desc = sortOf("events")
  local key = SORT.events[k or 0]
  if key then sortBy(shown, key, desc, function(a, b) return a.n < b.n end) end
  out[#out + 1] = { caption = true, left = DIM .. "The last " .. #list .. " things that happened to your auctions" .. (key and "" or ", newest first") .. ". Click a line for the item's details.|r" }
  for _, x in ipairs(shown) do
    local e = x.e
    out[#out + 1] = { cols = { dayWord(e.day), (KIND_COLOUR[e.kind] or "") .. e.kind .. "|r", NS.itemText(e.item, x.name), tostring(e.qty or 1),
        e.unit and money(e.unit) or (DIM .. "-|r") }, item = e.item, itemPanel = e.item, src = e.src,
      tip = { "Click for the item's details.", (e.src and e.src ~= "") and (DIM .. "How Kebold noticed it: " .. e.src .. " (/keboldsales log has the details).|r") or nil } }
  end
end

-- One item's history: { now, usual, days, listed, change, drop, lows }
local function historyOf(id)
  local H = KeboldsShinyHistory
  local list = try(H.readings, id) or {}
  local last = list[#list]
  if not last then return nil end
  local med, days = try(H.median, id)
  local drop = try(H.drop, id)
  local lows = {}
  for i = max(1, #list - 29), #list do lows[#lows + 1] = list[i].low end
  return { now = last.low, usual = med, days = days or 0, listed = last.qty, day = last.day,
    change = (med and med > 0 and last.low > 0) and (last.low - med) / med or nil, drop = drop, lows = lows }
end

local histAll, histV, histN = nil, nil, nil
local function buildHistory(out)
  local H = KeboldsShinyHistory
  local ids = type(H) == "table" and type(H.items) == "function" and H.items() or {}
  if #ids == 0 then
    out[#out + 1] = { left = DIM .. "No price history yet: every scan adds one reading a day for each item it looks up.|r",
      empty = { icon = "Interface\\Icons\\INV_Misc_Coin_01", title = "No price history yet",
        text = "Every scan adds one reading a day for each item it looks up. Open the auction house and run a scan from the Prices page." } }
    return
  end
  -- every item's readings parsed and sorted once, kept until prices change (a scan ended): after a scan of
  -- everything this is thousands of items, too many to redo on each refresh
  local v = NS.version and NS.version() or nil
  if not histAll or v == nil or histV ~= v or histN ~= #ids then
    histAll, histV, histN = {}, v, #ids
    for _, id in ipairs(ids) do
      local h = historyOf(id)
      if h then
        h.id, h.name = id, itemName(id)
        histAll[#histAll + 1] = h
      end
    end
    table.sort(histAll, function(a, b)
      if (a.drop ~= nil) ~= (b.drop ~= nil) then return a.drop ~= nil end   -- drops first
      if a.name ~= b.name then return a.name < b.name end
      return a.id < b.id
    end)
    for i, h in ipairs(histAll) do h.n = i end
  end
  local list = {}
  for _, h in ipairs(histAll) do
    if matches(h.name) then list[#list + 1] = h end
  end
  if #list == 0 then return noMatch(out) end
  local k, desc = sortOf("history")
  local key = SORT.history[k or 0]
  if key then sortBy(list, key, desc, function(a, b) return a.n < b.n end) end
  out[#out + 1] = { caption = true, left = DIM .. #list .. " of " .. #ids .. " items with readings" .. (key and "" or ", price drops first")
    .. ". Usual = the median of the daily lows. Shown only: a price is never replaced by it.|r" }
  for _, h in ipairs(list) do
    local change = DIM .. "-|r"
    if h.change then
      change = (h.drop and RED or (h.change > 0.2 and GREEN or "")) .. string.format("%+.0f%%", 100 * h.change) .. ((h.drop or h.change > 0.2) and "|r" or "")
    end
    out[#out + 1] = { cols = { NS.itemText(h.id, h.name), h.now > 0 and money(h.now) or (DIM .. "none|r"), h.usual and money(h.usual) or (DIM .. "-|r"),
        change, tostring(h.days), tostring(h.listed or 0) }, item = h.id, itemPanel = h.id,
      tip = { h.drop and (RED .. string.format("Now %.0f%% under its usual price.|r", 100 * h.drop)) or "Change: the price now against the usual one.",
        "Last read " .. dayWord(h.day) .. ". Click for the chart." } }
  end
end

function NS.buildSales()
  local S = settings()
  local out = {}
  local view = S.salesView
  if view == "events" then buildEvents(out) elseif view == "history" then buildHistory(out) else buildItems(out) end
  return out, "My sales - " .. VIEW[view]:lower()
end

-- The details pane's lines for one item, and its daily lows for the chart.
function NS.buildItemPanel(id)
  local out = {}
  local function add(row)
    out[#out + 1] = row
    return row
  end
  local function head(text, right)
    add({ left = "" })
    add({ left = GOLD .. text .. "|r", right = right and (DIM .. right .. "|r") or "", band = true })
  end
  local L = E.parseLadder(NS.realmItems()[id])
  add({ left = GOLD .. "At the last scan|r", right = "", band = true, item = id })
  if L then
    add({ left = "Cheapest listing", right = #L.tiers > 0 and money(L.tiers[1][1]) or (DIM .. "none listed|r") })
    add({ left = "Listed", right = tostring(L.total) .. DIM .. "  " .. dayWord(L.day) .. "|r" })
    for i = 2, min(#L.tiers, 5) do
      add({ left = DIM .. "   then " .. L.tiers[i][2] .. " at|r", right = money(L.tiers[i][1]) })
    end
  else
    add({ left = DIM .. "Not scanned.|r" })
  end
  local it = NS.data().items[id]
  if it and it.vp then add({ left = "Vendors sell it for", right = money(it.vp) }) end

  local lows
  local h = type(KeboldsShinyHistory) == "table" and historyOf(id) or nil
  if h then
    lows = h.lows
    head("Price history", h.days .. " scan days")
    add({ left = "Now", right = h.now > 0 and money(h.now) or (DIM .. "none listed|r") })
    add({ left = "Usual (median of the daily lows)", right = h.usual and money(h.usual) or (DIM .. "-|r") })
    if h.change then add({ left = "Change", right = (h.drop and RED or "") .. string.format("%+.0f%%", 100 * h.change) .. (h.drop and "|r" or "") }) end
  end

  local SA = KeboldsShinySales
  local s = type(SA) == "table" and try(SA.summary, id) or nil
  if s then
    head("Your auctions", "units (auctions)")
    add({ left = "Posted", right = qty(s.posted, s.postedQty) })
    add({ left = "Sold", right = qty(s.sold, s.soldQty) })
    add({ left = "Expired", right = qty(s.expired, s.expiredQty) })
    add({ left = "Cancelled", right = qty(s.cancelled, s.cancelledQty) })
    add({ left = "Listed now", right = qty(s.open, s.openQty) })
    add({ left = "Sold share of what finished", right = s.rate and string.format("%.0f%%", 100 * s.rate) or (DIM .. "nothing finished yet|r") })
    if s.salePrice then add({ left = "Last sale", right = money(s.salePrice) .. DIM .. "  " .. dayWord(s.saleDay) .. "|r" }) end
    local events = try(SA.events, id) or {}
    if #events > 0 then
      head("Events", "newest first")
      for i, e in ipairs(events) do
        if i > 20 then
          add({ left = DIM .. "... " .. (#events - 20) .. " more|r" })
          break
        end
        add({ left = dayWord(e.day) .. "  " .. (KIND_COLOUR[e.kind] or "") .. e.kind .. "|r  " .. (e.qty or 1) .. "x", right = e.unit and (money(e.unit) .. " each") or "" })
      end
    end
  else
    head("Your auctions")
    add({ left = DIM .. "You have not posted this item (or it was before Kebold kept track).|r" })
  end
  return out, lows
end

-- ---- the Prices page: its rows -----------------------------------------------------------------------------------------

local function ago(t)
  local d = (try(time) or 0) - (t or 0)
  if d < 90 then return "just now" end
  if d < 5400 then return floor(d / 60 + 0.5) .. " min ago" end
  if d < 129600 then return floor(d / 3600 + 0.5) .. " h ago" end
  return floor(d / 86400 + 0.5) .. " days ago"
end

local function scanProgress()
  return type(KeboldsShinyScan_Progress) == "function" and KeboldsShinyScan_Progress() or nil
end

local function lastRun()
  local run = type(KeboldsShinyScan_Last) == "function" and KeboldsShinyScan_Last() or nil
  return isTable(run) and run or nil
end

-- The Last scan card's rows: what the scan did (sum = "run": this session's, counted live; "saved": the record in
-- the saved file; "label": what it covered), then one line per item (NS.ahRows in LedgerAH.lua: cheapest, listed,
-- vendor, against the usual price). Also called alone while a scan runs, so the table follows it cheaply.
function NS.pricesLastRows()
  local out = { { left = GOLD .. "Last scan|r", head = "last", card = "last" } }
  local run = lastRun()
  if run and NS.ahSummary then
    local ok, text = pcall(NS.ahSummary)
    if ok and type(text) == "string" and text ~= "" then out[#out + 1] = { left = text, wide = true, sum = "run", card = "last" } end
  end
  local last = isTable(KeboldsShinyDB) and KeboldsShinyDB.lastScan or nil
  if isTable(last) and not (run and run.running) then
    out[#out + 1] = { left = tostring(last.how or "Scan") .. ": " .. (last.done or 0) .. " of " .. (last.total or 0) .. " items, " .. (last.found or 0) .. " with listings, "
      .. (last.empty or 0) .. " empty, " .. ((last.timeouts or 0) > 0 and RED or "") .. (last.timeouts or 0) .. " timeouts" .. ((last.timeouts or 0) > 0 and "|r" or "")
      .. DIM .. ", " .. ago(last.time) .. "|r", wide = true, sum = "saved", card = "last" }
    if last.label then out[#out + 1] = { left = DIM .. tostring(last.label) .. "|r", wide = true, sum = "label", card = "last" } end
    if type(last.note) == "string" and last.note ~= "" then   -- a quick scan: how much it read and what it left out
      out[#out + 1] = { left = DIM .. last.note .. "|r", wide = true, sum = "note", card = "last" }
    end
  elseif run and run.label then
    out[#out + 1] = { left = DIM .. tostring(run.label) .. "|r", wide = true, sum = "label", card = "last" }
  end
  if NS.ahRows then
    local ok, rows = pcall(NS.ahRows)
    if ok and isTable(rows) then
      for _, row in ipairs(rows) do
        row.card = "last"
        out[#out + 1] = row
      end
    end
  end
  return out
end

-- Everything the Prices page (and the Kebold tab of the auction house) shows, as rows. `card` says which card a
-- row belongs to (scan | profs | sells | last); `head` rows are the cards' titles.
--   scan:  plan = the plan the scans follow; status = what to do / what runs; preset = one scan (name, info, can,
--          why, action); stop = the Stop button
function NS.buildScan()
  local out = {}
  local at = type(KeboldsShinyScan_AtAuctionHouse) == "function" and KeboldsShinyScan_AtAuctionHouse() and true or false
  local p = scanProgress()
  local okc, c = pcall(NS.state)
  local plan = (okc and isTable(c)) and (c.prof .. " " .. tostring(c.from) .. " to " .. tostring(c.to)) or tostring(settings().prof or "Profession")
  out[#out + 1] = { left = GOLD .. "Scan|r  " .. DIM .. "the scans follow the plan " .. plan .. "|r", head = "scan", card = "scan", plan = plan }
  if p then
    out[#out + 1] = { left = GREEN .. "Scanning|r  " .. (p.label or ""), wide = true, status = true, card = "scan" }
    out[#out + 1] = { left = "   " .. ((type(p.text) == "string" and p.text ~= "") and p.text   -- a quick scan says what it is doing
      or (p.done .. " of " .. p.total .. " items: " .. p.found .. " with listings, " .. p.empty .. " empty, " .. p.timeouts .. " timeouts")), wide = true, card = "scan" }
  elseif not at then
    out[#out + 1] = { left = RED .. "Scans need the auction house open.|r Open it, then press a scan.", status = true, card = "scan" }
  else
    out[#out + 1] = { left = DIM .. "The auction house is open: press a scan.|r", status = true, card = "scan" }
  end
  -- (no "/reload after a scan" line: Kebold reads the prices from memory; only the web page's import needs the
  -- saved file, and the scanner says so in chat)
  for _, preset in ipairs(NS.scanPresets and NS.scanPresets() or {}) do
    local can = at and not p and preset.count > 0 and preset.blocked == nil
    local why = (not can) and (p and "A scan is running: stop it first." or ((not at) and "Open the auction house first."
      or (preset.blocked or ("Nothing to scan: " .. preset.info .. ".")))) or nil
    out[#out + 1] = { left = "   " .. preset.text, right = (can and "" or DIM) .. preset.info .. (can and "" or "|r"), card = "scan",
      preset = preset.key, name = preset.name, info = preset.info, can = can, why = why,
      action = function() NS.scanButton(preset.word) end,
      tip = { preset.label, preset.tip, can and "Keep the auction house open while it runs." or nil,
        DIM .. "The same as /keboldscan" .. (preset.word ~= "" and (" " .. preset.word) or "") .. "|r" } }
  end
  if p then
    out[#out + 1] = { left = "   Stop the scan", stop = true, card = "scan", action = function()
      if type(KeboldsShinyScan_Stop) == "function" then KeboldsShinyScan_Stop() end
      NS.refresh()
    end, tip = { "Ends the scan and keeps what it has read so far." } }
  end

  out[#out + 1] = { left = "" }
  out[#out + 1] = { left = GOLD .. "Prices by profession|r  " .. DIM .. "what each one's plan buys; click a line to open it on Level|r", c2 = DIM .. "scanned|r", right = DIM .. "oldest|r",
    head = "profs", card = "profs" }
  for _, prof in ipairs(NS.data().profs) do
    local st = NS.state(prof)
    local got, total, age = NS.pricesOf(prof)
    local oldest = got > 0 and (age == 0 and "today" or (age == 1 and "yesterday" or (age .. " days ago"))) or nil
    out[#out + 1] = { left = prof .. DIM .. "  " .. st.from .. " to " .. st.to .. "|r", icon = NS.profIcon(prof), card = "profs", prof = prof,
      c2 = (total > 0 and got < total and RED or "") .. got .. " of " .. total .. ((total > 0 and got < total) and "|r" or ""),
      right = oldest or (DIM .. "-|r"),
      action = function()
        settings().prof = prof
        NS.showTab("route")
      end, tip = { "Items the plan from " .. st.from .. " to " .. st.to .. " could buy that have a scanned price: " .. got .. " of " .. total .. ".",
        oldest and ("The oldest of those prices is from " .. oldest .. ".") or "None of them has a price yet: scan this plan.",
        "Click to open this profession on the Level page." } }
  end

  -- vendor values: what the game says against what the addon shipped with
  local changes, read = NS.sellChanges()
  local log = isTable(KeboldsShinyDB) and KeboldsShinyDB.sellLog or nil
  local logged = isTable(log) and #log or 0
  out[#out + 1] = { left = "" }
  out[#out + 1] = { left = GOLD .. "Vendor values that changed|r  " .. DIM .. read .. " read in game; " .. #changes .. " differ from the built-in data|r",
    c2 = DIM .. "built in|r", right = DIM .. "in game|r", head = "sells", card = "sells",
    tip = { "Every scan also reads what a vendor pays for each item it looks up, and opening a profession window reads its products.",
      "The game's value is the one used everywhere in Kebold. This list is what changed against the data the addon came with." } }
  if read == 0 then
    out[#out + 1] = { left = DIM .. "None read yet: every scan reads what a vendor pays for the items it looks up.|r", card = "sells",
      empty = { icon = "Interface\\Icons\\INV_Misc_Coin_02", title = "No vendor values read yet", text = "Every scan reads what a vendor pays for the items it looks up." } }
  elseif #changes == 0 and logged == 0 then
    out[#out + 1] = { left = DIM .. "All " .. read .. " values read in game are the same as the built-in data.|r", card = "sells",
      empty = { icon = "Interface\\Icons\\INV_Misc_Coin_02", title = "Nothing changed", text = "All " .. read .. " values read in game are the same as the built-in data." } }
  end
  for i, ch in ipairs(changes) do
    if i > 80 then
      out[#out + 1] = { left = DIM .. "... " .. (#changes - 80) .. " more|r", card = "sells" }
      break
    end
    out[#out + 1] = { left = ch.name, item = ch.item, card = "sells", c2 = ch.was and (ch.was > 0 and money(ch.was) or (DIM .. "not bought|r")) or (DIM .. "unknown|r"),
      right = ch.now > 0 and money(ch.now) or (DIM .. "not bought|r"),
      tip = { "A vendor pays " .. (ch.now > 0 and money(ch.now) or "nothing") .. " for it in game; the data the addon came with said "
        .. (ch.was and (ch.was > 0 and money(ch.was) or "nothing") or "nothing about it") .. "." } }
  end
  if logged > 0 then
    out[#out + 1] = { left = DIM .. "Changed in game between two readings (newest first):|r", wide = true, card = "sells" }
    for i = #log, max(1, #log - 19), -1 do
      local day, id, was, now = tostring(log[i]):match("^(%d+);(%d+);(%d+);(%d+)$")
      if day then
        local it = NS.data().items[tonumber(id)]
        local made = NS.data().maker[tonumber(id)]
        out[#out + 1] = { left = ((it and it.name) or (made and made.name) or ("item " .. id)) .. DIM .. "  " .. dayWord(tonumber(day)) .. "|r", item = tonumber(id), card = "sells",
          c2 = money(tonumber(was)), right = money(tonumber(now)) }
      end
    end
  end

  out[#out + 1] = { left = "" }
  for _, row in ipairs(NS.pricesLastRows()) do out[#out + 1] = row end
  return out, "Prices"
end

-- ---- the Prices view: four cards ---------------------------------------------------------------------------------------
-- NS.pricesView(parent, opts) -> view. Used twice: by the Prices page of the window and by the Kebold tab inside
-- the auction house (opts.ah). Both are painted from NS.buildScan()'s rows.
--   opts.ah        the copy inside the auction house: adds "Open this tab when a scan starts" and "Open Kebold
--                  window", and a click on an item searches it on the Buy tab
--   opts.titleX    where the Scan card's title starts (right of the auction house's portrait)
--   opts.bottom    the height of the two lower cards (default: 42% of the view, 130 to 238)
--   opts.visible() is the view on screen
--   opts.click(line, button)   a click on a line of the Last scan table
--   view:Layout(w, h)   view:Paint(rows)   view:PaintLast()   view:Tick(progress or nil)   view:Progress(p)
-- Fields: .cScan .cLast .cProfs .cSells (cards), .dProf .planText, .presets[i] (.row .info), .stop .bar .barNote
--         .status, .follow .open (opts.ah), .summary .label .find .tLast, .tProfs .tSells
-- Every size below is a guess (nothing here has been seen in game).
local PV = { left = 260, gap = 6, rowH = 24, button = 126, top = 28, statusH = 40, headH = 32 }
NS.PRICES = PV

local LAST_COLUMNS = {
  { key = "item", title = "Item", flex = 1, min = 120, sortable = true, tip = "The items of the running or the last scan, in the scan's order until a column is clicked." },
  { key = "price", title = "Cheapest", width = 84, align = "RIGHT", sortable = true, tip = { "Cheapest", "The cheapest listing for one. Green: below what a vendor pays." } },
  { key = "listed", title = "Listed", width = 54, align = "RIGHT", sortable = true, drop = 2, tip = "How many are listed in all." },
  { key = "vendor", title = "Vendor", width = 78, align = "RIGHT", sortable = true, drop = 3, tip = "What a vendor pays for one." },
  { key = "vs", title = "Against usual", width = 120, align = "RIGHT", sortable = true, drop = 1, tip = { "Against usual",
    "The cheapest price against the usual one: the middle one of the cheapest prices on earlier days this item was scanned." } },
}
local PROF_COLUMNS = {
  { key = "left", title = "Profession", flex = 1, min = 130 },
  { key = "c2", title = "Scanned", width = 64, align = "RIGHT", tip = { "Scanned", "Items the profession's plan could buy that have a price, of all it could buy. Red: some are missing." } },
  { key = "right", title = "Oldest", width = 70, align = "RIGHT", drop = 1, tip = "How old the oldest of those prices is." },
}
local SELL_COLUMNS = {
  { key = "left", title = "Item", flex = 1, min = 60 },
  { key = "c2", title = "Built in", width = 62, align = "RIGHT", drop = 1, tip = "What the data the addon came with says a vendor pays." },
  { key = "right", title = "In game", width = 62, align = "RIGHT", tip = "What a vendor pays in game: the value Kebold uses." },
}
NS.PRICES_COLUMNS = { last = LAST_COLUMNS, profs = PROF_COLUMNS, sells = SELL_COLUMNS }

local views = {}

-- The Last scan table of every view on screen again (a sort, the find box): `top` puts the lists back to their start.
function NS.pricesRepaintLast(top)
  for _, v in ipairs(views) do
    if top then v.tLast.offset, v.followAt = 0, 0 end
    if v:OnScreen() then v:PaintLast() end
  end
end

-- A scan started: the lists follow the item being read again.
function NS.pricesScanStarted()
  for _, v in ipairs(views) do
    v.following, v.followAt, v.tickDone = true, false, false   -- false, not nil: a frame answers unknown keys itself
    v.tLast.offset = 0
  end
end

-- An empty state needs room (the kit's is 340 by 150): in a small table the same sentence is an ordinary line.
local function fitEmpty(rows, t)
  if t.w >= 360 and t.h >= 180 then return rows end
  local out = {}
  for i, row in ipairs(rows) do
    if row.empty then
      local copy = {}
      for k, val in pairs(row) do copy[k] = val end
      copy.empty, copy.wide = nil, true
      out[i] = copy
    else
      out[i] = row
    end
  end
  return out
end

function NS.pricesView(parent, opts)
  opts = opts or {}
  local v = CreateFrame("Frame", nil, parent)
  v.opts, v.kind = opts, opts.ah and "ah" or "page"
  v.presets, v.w, v.h, v.shown = {}, 0, 0, 0
  v.following, v.followAt, v.tickDone = true, false, false
  v.planText, v.rows = "", {}
  v.follow, v.open = false, false
  views[#views + 1] = v

  function v:OnScreen()
    if opts.visible then return opts.visible() and true or false end
    return true
  end

  -- the Scan card
  v.cScan = UI.card(v, "Scan")
  if opts.titleX then   -- inside the auction house the window's portrait lies over the card's top left corner
    v.cScan.title:ClearAllPoints()
    v.cScan.title:SetPoint("TOPLEFT", opts.titleX, -7)
  end
  v.over = v.cScan:Layout(PV.left)   -- what a card takes around its content (its head and its padding)
  local sc = v.cScan.content
  local colW = PV.left - 16
  v.dProf = UI.dropdown(sc, colW, function() return v.planText end, function()
    local items = { { title = true, text = "Profession the scans follow" } }
    local ok, db = pcall(NS.data)
    local cur = settings().prof
    local okc, c = pcall(NS.state)
    if okc and isTable(c) then cur = c.prof end
    for _, prof in ipairs(ok and isTable(db) and db.profs or {}) do
      local st = NS.profState(prof)
      items[#items + 1] = { radio = true, checked = cur == prof, text = prof .. (st.skill and (" (yours " .. st.skill .. "/" .. (st.max or "?") .. ")") or ""),
        func = function() NS.pricesSetProf(prof) end }
    end
    return items
  end, { "The plan the scans follow", "Its profession is chosen here. The skill range and the Recipes switch are set on the Level page." })
  v.dProf:SetPoint("TOPLEFT", 0, 0)

  local function presetButton(i)
    local b = v.presets[i]
    if b then return b end
    b = UI.button(sc, "", PV.button, function()
      local row = b.row
      if row and row.action then row.action("LeftButton") end
    end, function()
      local row = b.row
      return row and row.tip or nil
    end)
    b.row = false
    b:SetPoint("TOPLEFT", 0, -(PV.top + (i - 1) * PV.rowH))
    -- the item count and the time: right-aligned in what is left of the column, so it ends at the card's edge
    b.info = UI.text(sc, "body")
    b.info:SetPoint("LEFT", b, "RIGHT", 4, 0)
    b.info:SetWidth(colW - PV.button - 4)
    b.info:SetJustifyH("RIGHT")
    b.info:SetWordWrap(false)
    v.presets[i] = b
    return b
  end

  v.stop = UI.button(sc, "Stop", 50, function()
    if type(KeboldsShinyScan_Stop) == "function" then KeboldsShinyScan_Stop() end
  end, { "Stop", "Ends the scan and keeps what it has read so far." })
  v.bar = UI.progress(sc, colW - 56, 18)
  v.bar:SetPoint("LEFT", v.stop, "RIGHT", 6, 0)
  v.barNote = UI.text(sc, "dim")
  v.barNote:SetPoint("LEFT", v.stop, "RIGHT", 6, 0)
  v.barNote:SetWidth(colW - 56)
  v.barNote:SetJustifyH("LEFT")
  v.barNote:SetWordWrap(false)
  v.barNote:Hide()
  v.status = UI.text(sc, "body")
  v.status:SetWidth(colW)
  v.status:SetHeight(PV.statusH)
  v.status:SetJustifyH("LEFT")
  v.status:SetJustifyV("TOP")
  pcall(v.status.SetWordWrap, v.status, true)
  if opts.ah then
    v.open = UI.button(sc, "Open the Kebold window", colW, function()
      if NS.openDocked then NS.openDocked(true) else NS.toggle(true) end
    end, { "The Kebold window", "The route, the recipes, the shopping list, sales and settings." })
    v.open:SetPoint("BOTTOMLEFT", sc, "BOTTOMLEFT", 0, 0)
    v.follow = UI.check(sc, "Open this tab when a scan starts", function() return settings().ahFollow ~= false end, function(on)
      settings().ahFollow = on and true or false
    end, "Every scan started at the auction house, typed ones too, switches to this tab.")
    v.follow:SetPoint("BOTTOMLEFT", sc, "BOTTOMLEFT", -2, 26)
  end

  -- the Last scan card: what the scan did on two lines, the find box in the card's head, the items
  v.cLast = UI.card(v, "Last scan")
  local lc = v.cLast.content
  v.summary = UI.text(lc, "body")
  v.summary:SetPoint("TOPLEFT", 2, 0)
  v.summary:SetJustifyH("LEFT")
  v.summary:SetWordWrap(false)
  v.label = UI.text(lc, "dim")
  v.label:SetPoint("TOPLEFT", 2, -14)
  v.label:SetJustifyH("LEFT")
  v.label:SetWordWrap(false)
  v.find = v.cLast:SetAction(UI.search(v.cLast, 140, function(self)
    local text = self:GetText()
    text = type(text) == "string" and text or ""
    if NS.ahFind and NS.ahFindText and text ~= NS.ahFindText() then NS.ahFind(text) end
  end))
  pcall(v.find.SetMaxLetters, v.find, 30)
  v.tLast = UI.table(lc, LAST_COLUMNS, {
    onClick = function(line, button)
      if opts.click then opts.click(line, button) else NS.rowClick(line, button) end
    end,
    onEnter = NS.rowEnter, onLeave = NS.rowLeave,
    onSort = function(_, k)
      if NS.ahSort then NS.ahSort(k) end
    end })
  v.tLast:SetPoint("TOPLEFT", 0, -PV.headH)

  -- the two lower cards
  v.cProfs = UI.card(v, "Prices by profession")
  v.tProfs = UI.table(v.cProfs.content, PROF_COLUMNS, { onClick = NS.rowClick, onEnter = NS.rowEnter, onLeave = NS.rowLeave })
  v.tProfs:SetPoint("TOPLEFT", 0, 0)
  v.cSells = UI.card(v, "Vendor values that changed")
  v.tSells = UI.table(v.cSells.content, SELL_COLUMNS, { onClick = NS.rowClick, onEnter = NS.rowEnter, onLeave = NS.rowLeave })
  v.tSells:SetPoint("TOPLEFT", 0, 0)

  -- A card at (x, y) of the view, cw wide and ch high over all: returns the size of its content.
  local function fix(card, x, y, cw, ch)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", v, "TOPLEFT", x, -y)
    card:SetContentHeight(max(20, ch - v.over))
    card:Layout(cw)
    return max(40, cw - 16), max(20, ch - v.over)
  end

  function v:Layout(w, h)
    w, h = max(PV.left + 200, tonumber(w) or self.w), max(200, tonumber(h) or self.h)
    self.w, self.h = w, h
    self:SetSize(w, h)
    fix(self.cScan, 0, 0, PV.left, h)
    local x, rw = PV.left + PV.gap, w - PV.left - PV.gap
    local bottom = min(h - 120, tonumber(opts.bottom) or min(238, max(130, floor(h * 0.42))))
    local cw, ch = fix(self.cLast, x, 0, rw, h - bottom - PV.gap)
    self.summary:SetWidth(cw - 4)
    self.label:SetWidth(cw - 4)
    self.tLast:Layout(cw, ch - PV.headH)
    local pw = floor((rw - PV.gap) * 0.58)
    cw, ch = fix(self.cProfs, x, h - bottom, pw, bottom)
    self.tProfs:Layout(cw, ch)
    cw, ch = fix(self.cSells, x + pw + PV.gap, h - bottom, rw - PV.gap - pw, bottom)
    self.tSells:Layout(cw, ch)
  end

  -- The bar of the Scan card. While a scan runs its progress shows in one place only (NS.progressOwner): a view
  -- that is not that place says where to look instead.
  function v:Progress(p)
    if p then
      local owner = NS.progressOwner and NS.progressOwner() or self.kind
      if owner == self.kind then
        self.bar:Set(p.done, p.total, NS.scanText and NS.scanText(p) or (p.done .. " / " .. p.total))
        self.bar:Show()
        self.barNote:Hide()
      else
        self.bar:Hide()
        self.barNote:SetText(owner == "ah" and "Progress: on the auction house tab" or "Scanning")
        self.barNote:Show()
      end
    else
      self.bar:Set(0, 1, "No scan running")
      self.bar:Show()
      self.barNote:Hide()
    end
  end

  -- The Last scan card from its rows (NS.pricesLastRows() when none are given).
  function v:PaintLast(list)
    list = list or NS.pricesLastRows()
    local items, sum, saved, label = {}, nil, nil, nil
    for _, row in ipairs(list) do
      if row.sum == "run" then sum = row elseif row.sum == "saved" then saved = row elseif row.sum == "label" then label = row
      elseif not row.head then items[#items + 1] = row end
    end
    sum = sum or saved
    self.summary:SetText(sum and UI.show(sum.left) or "")
    self.label:SetText(label and UI.show(label.left) or "")
    local t, S = self.tLast, settings()
    local run = lastRun()
    local k = tonumber(S.ahSort) or 0
    local sorted = k >= 1 and k <= #LAST_COLUMNS
    -- the item being read stays in the middle, until the list is moved by hand (its place is then no longer ours)
    if self.followAt and t.offset ~= self.followAt then self.following = false end
    if run and run.running and self.following and not sorted and (not NS.ahFindText or NS.ahFindText() == "") then
      t.offset = max(0, (tonumber(run.done) or 0) - floor(t:Visible() / 2))
    end
    t:SetRows(fitEmpty(items, t))
    self.followAt = t.offset
    t:SetSort(sorted and k or 0, S.ahDesc and true or false)
    if NS.ahFindText then   -- the two copies of the find box say the same
      local text = self.find:GetText()
      if (type(text) == "string" and text or "") ~= NS.ahFindText() then self.find:SetText(NS.ahFindText()) end
    end
  end

  function v:Paint(rows)
    rows = rows or self.rows
    self.rows = rows
    local n, status, stopRow = 0, {}, nil
    local profs, sells, last = {}, {}, {}
    for _, row in ipairs(rows) do
      if row.card == "scan" then
        if row.plan then self.planText = row.plan end
        if row.preset then
          n = n + 1
          local b = presetButton(n)
          b.row = row
          b:SetLabel(row.name or row.preset)
          b.info:SetText(UI.show(row.right or row.info or ""))
          b:SetEnabled(row.can == true, row.why)
          b:Show()
          b.info:Show()
        elseif row.status then
          status[#status + 1] = row.left
        elseif row.stop then
          stopRow = row
        end
      elseif row.card == "profs" then
        if not row.head then profs[#profs + 1] = row end
      elseif row.card == "sells" then
        if not row.head then sells[#sells + 1] = row end
      elseif row.card == "last" then
        last[#last + 1] = row
      end
    end
    for i = n + 1, #self.presets do
      self.presets[i].row = false
      self.presets[i]:Hide()
      self.presets[i].info:Hide()
    end
    self.shown = n
    -- Stop and the bar under the last scan button, then what to do or what runs (three lines at most)
    local y = PV.top + n * PV.rowH + 6
    self.stop:ClearAllPoints()
    self.stop:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -y)
    self.stop:SetEnabled(stopRow ~= nil, "No scan is running.")
    self.status:ClearAllPoints()
    self.status:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(y + 28))
    self.status:SetText(UI.show(table.concat(status, "\n")))
    self.dProf:Refresh()
    if self.follow then self.follow:Refresh() end
    self:Progress(scanProgress())
    self.tProfs:SetRows(fitEmpty(profs, self.tProfs))
    self.tSells:SetRows(fitEmpty(sells, self.tSells))
    self:PaintLast(last)
  end

  -- Five times a second while a scan runs: the bar every time, the table only when an item was settled.
  function v:Tick(p)
    self:Progress(p)
    if p then
      local run = lastRun()
      local done = run and run.done or nil
      if done ~= self.tickDone or done == nil then
        self.tickDone = done or false
        self:PaintLast()
      end
    else
      self.tickDone = false
    end
  end

  return v
end

-- The profession the scans (and the Kebold window) follow.
function NS.pricesSetProf(prof)
  settings().prof = prof
  pcall(NS.refresh)                       -- the window, when it exists and shows
  if NS.ahPaint then pcall(NS.ahPaint) end   -- the Kebold tab of the auction house, when it shows
end

-- ---- the pages -------------------------------------------------------------------------------------------------------

-- My sales: one set of columns for each of the three views, in the order of a line's `cols`; every column sorts.
-- The columns with a drop number give way when the details pane is open.
local COLUMNS = {
  items = {
    { key = "item", title = "Item", flex = 1, min = 150, sortable = true },
    { key = "posted", title = "Posted", width = 60, align = "RIGHT", sortable = true, tip = { "Posted", "Units you posted, with the number of auctions in brackets." } },
    { key = "sold", title = "Sold", width = 60, align = "RIGHT", sortable = true },
    { key = "expired", title = "Expired", width = 64, align = "RIGHT", sortable = true, drop = 3 },
    { key = "cancelled", title = "Cancelled", width = 70, align = "RIGHT", sortable = true, drop = 5 },
    { key = "open", title = "Listed now", width = 76, align = "RIGHT", sortable = true, drop = 4 },
    { key = "rate", title = "Sold %", width = 56, align = "RIGHT", sortable = true, tip = { "Sold %", "The share of finished units (sold or expired) that sold." } },
    { key = "last", title = "Last sale", width = 120, align = "RIGHT", sortable = true, drop = 6 },
  },
  events = {
    { key = "day", title = "Day", width = 76, sortable = true },
    { key = "what", title = "Event", width = 60, sortable = true, tip = { "Event", "Posted, sold, expired or cancelled." } },
    { key = "item", title = "Item", flex = 1, min = 100, sortable = true },
    { key = "qty", title = "Units", width = 50, align = "RIGHT", sortable = true, drop = 1 },
    { key = "each", title = "Price each", width = 80, align = "RIGHT", sortable = true },
  },
  history = {
    { key = "item", title = "Item", flex = 1, min = 104, sortable = true },
    { key = "now", title = "Price now", width = 76, align = "RIGHT", sortable = true, tip = { "Price now", "The cheapest listing at the last scan." } },
    { key = "usual", title = "Usual price", width = 76, align = "RIGHT", sortable = true, tip = { "Usual price", "The median of the cheapest price on each day it was scanned." } },
    { key = "change", title = "Change", width = 60, align = "RIGHT", sortable = true, tip = { "Change", "The price now against the usual one. Red: a drop." } },
    { key = "days", title = "Days scanned", width = 84, align = "RIGHT", sortable = true, drop = 2 },
    { key = "listed", title = "Listed", width = 60, align = "RIGHT", sortable = true, drop = 1 },
  },
}
NS.SALES_COLUMNS = COLUMNS

local SEG_W = { items = 92, events = 104, history = 96 }

NS.page({ key = "sales", title = "My sales", order = 5, icon = "Interface\\Icons\\INV_Letter_15",
  tip = { "My sales", "Your own auctions: what sold, what expired, and the price history of the scans." },
  bars = 2, detail = true, columns = COLUMNS.items,
  rows = function() return NS.buildSales() end,
  view = function(page, rows)   -- the sentence above the list is the page's caption, not a line of the table
    local out = {}
    page.captionText = ""
    for _, row in ipairs(rows) do
      if row.caption then page.captionText = row.left or "" else out[#out + 1] = row end
    end
    return out
  end,
  onSort = function(_, _, k) NS.sortSales(k) end,
  selected = function(row) return row.itemPanel ~= nil and NS.detailItem ~= nil and NS.detailItem() == row.itemPanel end,
  build = function(page)
    local at, bar = page.at, page.bar
    -- the three views, side by side: the one showing is gold
    page.seg = {}
    for _, key in ipairs(VIEW_ORDER) do
      page.seg[key] = at.put(UI.button(bar, VIEW[key], SEG_W[key], function()
        if settings().salesView ~= key then
          settings().salesView = key
          NS.resetScroll()
          NS.refresh()
        end
      end, { VIEW[key], VIEW_TIP[key] }), 2)
    end
    at.x = at.x + 10
    page.eSales = at.put(UI.search(bar, 150, function(self)
      local t = self:GetText() or ""
      if t ~= search then
        search = t
        NS.resetScroll()
        NS.refresh()
      end
    end))
    page.eSales:SetMaxLetters(30)
    -- second row: what the list is
    page.caption = UI.text(bar, "dim")
    page.caption:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -(NS.WIN.bar + 6))
    page.caption:SetJustifyH("LEFT")
    page.caption:SetWordWrap(false)
    page.captionText = ""
    page.viewNow = "items"
  end,
  layout = function(page, w)
    page.caption:SetWidth(max(100, w - 8))
  end,
  paint = function(page)
    local S = settings()
    local view = S.salesView
    if page.viewNow ~= view then   -- another view: its own columns and heads
      page.viewNow = view
      page.table:SetColumns(COLUMNS[view])
      page.table:Paint()
    end
    for _, key in ipairs(VIEW_ORDER) do
      local b = page.seg[key]
      b.selected = key == view
      b.label:SetText((key == view and GOLD or DIM) .. VIEW[key] .. "|r")
    end
    page.caption:SetText(UI.show(page.captionText or ""))
    local k, desc = sortOf(view)
    page.table:SetSort(k or 0, desc)
  end })

NS.page({ key = "scan", title = "Prices", order = 4, icon = "Interface\\Icons\\INV_Misc_Coin_01",
  tip = { "Prices", "The auction house scans, what the last one found, and how complete each profession's prices are." },
  rows = function() return NS.buildScan() end,
  build = function(page)
    page.view = NS.pricesView(page.frame, { visible = function()
      local f = NS.frame()
      return f ~= nil and f:IsShown() and page.active == true
    end })
    page.view:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, 0)
    page.scanBar, page.scanStop = page.view.bar, page.view.stop   -- the names the first shell gave them
    page.scanWas, page.atWas = false, false
    NS.tickers[#NS.tickers + 1] = function(p)
      local f = NS.frame()
      local on = f and f:IsShown() and page.active == true
      if on then page.view:Tick(p) end
      -- the cards carry the scan's state: rebuilt when it starts and when it ends
      local running = p ~= nil
      if page.scanWas ~= running and on then NS.refreshSoon(0.1) end
      page.scanWas = running
      -- the auction house opened or closed while the page shows: its buttons change with it
      local at = NS.atAuctionHouse() and true or false
      if page.atWas ~= at then
        page.atWas = at
        if on then NS.refresh() end
      end
    end
  end,
  layout = function(page, w, h)
    page.view:Layout(w, h)
  end,
  paint = function(page, rows)
    page.atWas = NS.atAuctionHouse() and true or false
    page.view:Paint(rows)
  end })
