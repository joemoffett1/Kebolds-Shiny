-- KeboldsShiny (prototype)
-- Records, per item, the first price tiers of the auction house with the quantity at each, so one unit posted
-- at 1 copper can no longer pass for "the price". Written from Blizzard's API documentation only. The first
-- in-game runs timed out on items the client had not loaded yet, so the scan now loads each item's data before
-- searching it, logs an outcome per item, and /keboldscan debug records what the client does for one item.

local MAX_TIERS = 40        -- price tiers kept per item: deep enough to price buying a few thousand of a common material
local ITEM_TIMEOUT = 3      -- seconds to wait for one item's results before moving on (answers take about 0.1 s)
local LOAD_TIMEOUT = 3      -- seconds to wait for the client to load an item's data before skipping it
local PRELOAD_AHEAD = 20    -- items whose data is requested ahead of the one being searched
local THROTTLE_GIVE_UP = 30 -- seconds to wait for the server to accept the next search before stopping
local POLL = 0.1            -- seconds between checks of the throttle / timeout
local PROGRESS_EVERY = 25   -- items between progress lines
local DAY_ZERO = 1577836800 -- 2020-01-01 00:00 UTC, the day origin the web page uses
local DEBUG_ITEM = 2592     -- Wool Cloth: heavily listed, and it timed out in the first runs
local DEBUG_SECONDS = 60    -- length of a debug run
local DEBUG_MAX_LINES = 400 -- cap on the saved debug log

local AH = C_AuctionHouse

-- Cheapest first, so that if the server only sends a first page it is the page the ladder needs.
-- Price is documented as 0; the fallback covers a client where the enum table is missing.
local SORTS = { {
  sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0,
  reverseSort = false,
} }

local ahOpen = false
local scan = nil       -- state of the running scan, nil when idle
-- The running scan, or the last one of this session, for Kebold's auction house page: { ids, label, total, done,
-- running, how, started, state = { [item id] = "found" | "empty" | "timeout" } } (no state = not reached yet).
local lastRun = nil
local debugRun = nil   -- state of the running debug run, nil when idle
local quick = nil      -- state of the running quick scan (whole auction house, or gear by browsing), nil when idle
local Q = {}           -- the quick scan's functions, filled in further down (progress, stop, start, wait, event handlers)

local function say(msg)
  print("|cff66ccffKeboldScan|r " .. msg)
end

-- "%d" can overflow above 2^31 on some Lua builds; "%.0f" prints any whole number.
local function int(n)
  return string.format("%.0f", n)
end

local function today()
  return math.floor((time() - DAY_ZERO) / 86400)
end

-- The saved table for this realm, created on first use. Never wiped: partial scans add to it.
local function realmStore()
  if type(KeboldsShinyDB) ~= "table" then KeboldsShinyDB = {} end
  local db = KeboldsShinyDB
  db.v = 1
  if type(db.realms) ~= "table" then db.realms = {} end
  local name = GetRealmName() or "Unknown"
  if type(db.realms[name]) ~= "table" then db.realms[name] = {} end
  local store = db.realms[name]
  if type(store.items) ~= "table" then store.items = {} end
  return store
end

-- ---- vendor values ---------------------------------------------------------------------------------------
-- What a vendor pays for an item, as the client reports it (the 11th value of C_Item.GetItemInfo, the same
-- number the item's tooltip shows). Kept for the whole account under KeboldsShinyDB.sell[item id]; the
-- Kebold lays it over the values it shipped with. A value that differs from the one read before is written to
-- KeboldsShinyDB.sellLog as "<day>;<item id>;<before>;<now>" (the newest 300 are kept).
local SELL_LOG_MAX = 300
local sellVersion = 0
function KeboldsShinyScan_NoteSell(itemID, price)
  if type(itemID) ~= "number" or type(price) ~= "number" or price < 0 then return false end
  if type(KeboldsShinyDB) ~= "table" then KeboldsShinyDB = {} end
  local db = KeboldsShinyDB
  if type(db.sell) ~= "table" then db.sell = {} end
  local old = db.sell[itemID]
  if old == price then return false end
  db.sell[itemID] = price
  sellVersion = sellVersion + 1
  if type(old) == "number" then
    if type(db.sellLog) ~= "table" then db.sellLog = {} end
    local log = db.sellLog
    log[#log + 1] = int(today()) .. ";" .. int(itemID) .. ";" .. int(old) .. ";" .. int(price)
    while #log > SELL_LOG_MAX do table.remove(log, 1) end
  end
  return true
end
-- goes up with every new or changed value, so Kebold knows when to read them again
function KeboldsShinyScan_SellVersion()
  return sellVersion
end

-- Reads the vendor value of an item whose data the client has loaded. True when it was new or different.
local function readSell(itemID)
  if not (C_Item and C_Item.GetItemInfo) then return false end
  local ok, name, _, _, _, _, _, _, _, _, _, sell = pcall(C_Item.GetItemInfo, itemID)
  if ok and name and type(sell) == "number" then return KeboldsShinyScan_NoteSell(itemID, sell) end
  return false
end

-- What the client already knows about an item: is its data cached, and does the auction house know whether it
-- is a commodity. The leading suspicion for silent timeouts is that a search is dropped unless this is known,
-- so the scan logs it per item. A later "wait for item data, then search" strategy would test these two values.
local function itemFacts(itemID, key)
  local cached, kind = "?", "?"
  if C_Item and C_Item.IsItemDataCachedByID then
    local ok, value = pcall(C_Item.IsItemDataCachedByID, itemID)
    if ok then cached = value and "yes" or "no" end
  end
  if AH.GetItemKeyInfo then
    local ok, info = pcall(AH.GetItemKeyInfo, key)
    if ok then kind = (type(info) ~= "table" and "unknown") or (info.isCommodity and "commodity") or "item" end
  end
  return cached, kind
end

-- tiers maps unit price -> quantity, which is what merges listings at the same price.
local function addTier(tiers, price, qty)
  tiers[price] = (tiers[price] or 0) + qty
end

-- Both readers return how many result rows the client holds, and whether that was the full list.
local function readCommodity(itemID, tiers)
  local n = AH.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, n do
    local r = AH.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice and r.quantity and r.quantity > 0 then
      addTier(tiers, r.unitPrice, r.quantity)
    end
  end
  return n, n == 0 or AH.HasFullCommoditySearchResults(itemID)
end

local function readItems(itemKey, tiers)
  local n = AH.GetNumItemSearchResults(itemKey) or 0
  for i = 1, n do
    local r = AH.GetItemSearchResultInfo(itemKey, i)
    local qty = r and r.quantity or 0
    -- Bid-only auctions have no price anyone can simply pay, so they are not part of the ladder.
    if qty > 0 and r.buyoutAmount and r.buyoutAmount > 0 then
      -- Rounded up: a stack of 20 for 199c costs at least 10c a unit to the buyer.
      addTier(tiers, math.ceil(r.buyoutAmount / qty), qty)
    end
  end
  return n, n == 0 or AH.HasFullItemSearchResults(itemKey)
end

-- "<day>;<total qty>;<price>:<qty>,..." - a flat string so the web page can read it with one regex.
local function encode(day, tiers)
  local prices, total = {}, 0
  for price, qty in pairs(tiers) do
    prices[#prices + 1] = price
    total = total + qty
  end
  table.sort(prices)
  local parts = {}
  for i = 1, math.min(#prices, MAX_TIERS) do
    parts[i] = int(prices[i]) .. ":" .. int(tiers[prices[i]])
  end
  return int(day) .. ";" .. int(total) .. ";" .. table.concat(parts, ","), total, prices[1] or 0
end

local function finish(reason)
  local s = scan
  scan = nil
  if lastRun and lastRun.ids == s.ids then lastRun.running, lastRun.how, lastRun.done = false, reason, s.done end
  if s.done > 0 then
    s.store.day = s.day
    s.store.time = time()
  end
  -- what the last scan did, for Kebold's Scan tab
  if type(KeboldsShinyDB) == "table" then
    KeboldsShinyDB.lastScan = { done = s.done, total = #s.ids, found = s.found, empty = s.empty, timeouts = s.timeouts,
      time = time(), label = s.label, how = reason, sells = s.sells }
  end
  if (s.sells or 0) > 0 then
    say(s.sells .. " vendor values were new or different from the last reading. Kebold's Scan tab lists the ones that differ from its built-in data.")
  end
  say(string.format("%s: %d of %d items scanned - %d with listings, %d empty, %d timeouts, %.1f seconds.",
    reason, s.done, #s.ids, s.found, s.empty, s.timeouts, GetTime() - s.started))
  if s.partial > 0 then
    say(s.partial .. " items had more listings than the first page; their total quantity is understated.")
  end
  if s.done < #s.ids then
    say((#s.ids - s.done) .. " items were not reached and keep their earlier prices. Run the scan again for a full set; it starts from the beginning.")
  end
  if s.done > 0 then
    say("Kebold uses the new prices at once.")
  end
  -- the Kebold window re-plans from the new prices
  if type(KeboldsShiny_OnScanFinished) == "function" then pcall(KeboldsShiny_OnScanFinished, s.done, #s.ids) end
end

-- The item being waited on is settled: write its line in the per-item log, count it and move on.
-- outcome is commodity / item (the result event that answered), lastlook (rows found with no event) or timeout.
-- thr holds the throttle events seen while waiting: S sent, Q queued, D dropped, R response received, Y ready.
local function advance(outcome, rows)
  local s = scan
  s.log[#s.log + 1] = string.format("%s %s %.1fs rows=%s cached=%s key=%s thr=%s",
    int(s.waiting), outcome, GetTime() - s.sentAt, int(rows), s.cached, s.kind, s.thr)
  if (outcome == "timeout" or outcome == "noload") and s.waiting then
    -- No answer this time keeps the earlier reading (it carries its own day, and the price line says how old the
    -- oldest is): one lost search used to take every recipe using the item out of the routes. An item the client
    -- cannot load does not exist here, so it has no reading.
    if outcome == "noload" then s.store.items[s.waiting] = nil end
    if lastRun and lastRun.ids == s.ids then lastRun.state[s.waiting] = "timeout" end
  end
  if outcome == "timeout" then
    s.timeouts = s.timeouts + 1
    s.lateFrom[s.waiting] = s.sentAt   -- so an answer that arrives after we gave up still shows in the log
  elseif outcome == "noload" then
    s.timeouts = s.timeouts + 1        -- the client never loaded the item, so no search was sent
  end
  s.waiting, s.key = nil, nil
  s.done = s.done + 1
  if lastRun and lastRun.ids == s.ids then lastRun.done = s.done end
  s.lastMove = GetTime()
  if s.done >= #s.ids then
    finish("Scan complete")
  elseif s.done % (#s.ids > 1000 and 100 or PROGRESS_EVERY) == 0 then   -- a scan of thousands reports every 100
    say(string.format("%d / %d (%d timeouts, %.0f s so far)", s.done, #s.ids, s.timeouts, GetTime() - s.started))
  end
end

local function record(itemID, tiers, full, outcome, rows)
  local s = scan
  local text, total, low = encode(s.day, tiers)
  s.store.items[itemID] = text
  -- one reading per item and day for the price history (Sales.lua, which loads after this file)
  if type(KeboldsShinyHistory) == "table" and KeboldsShinyHistory.record then
    pcall(KeboldsShinyHistory.record, s.store, itemID, s.day, low, total)
  end
  if total > 0 then s.found = s.found + 1 else s.empty = s.empty + 1 end
  if lastRun and lastRun.ids == s.ids then lastRun.state[itemID] = total > 0 and "found" or "empty" end
  if not full then s.partial = s.partial + 1 end
  advance(outcome, rows)
end

-- A result for an item we already gave up on: log it (nothing is stored, the scan strategy is unchanged).
-- "Answered late" and "never answered" point at different causes, so the difference is worth a line.
local function noteLate(itemID, kind, rows)
  local s = scan
  if s and s.lateFrom[itemID] then
    s.log[#s.log + 1] = string.format("%s late-%s %.1fs rows=%s", int(itemID), kind, GetTime() - s.lateFrom[itemID], int(rows))
    s.lateFrom[itemID] = nil
  end
end

-- Seen in game: a search is only answered for an item the client has already loaded. Loaded, Wool Cloth answered
-- in 0.1 s three times running and MakeItemKey filled in its item level (15); not loaded, it timed out, and the only
-- items that ever answered were ones the client had seen before. So an item's data is loaded before it is searched.
local function isCached(itemID)
  if not (C_Item and C_Item.IsItemDataCachedByID) then return true end   -- cannot tell: search straight away
  local ok, value = pcall(C_Item.IsItemDataCachedByID, itemID)
  if not ok then return true end
  return value and true or false
end

local function requestLoad(s, itemID)
  if s.asked[itemID] or isCached(itemID) then return end
  s.asked[itemID] = true
  if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
end

-- True once the next item's data is loaded. While waiting it returns false; after LOAD_TIMEOUT it logs the item
-- as "noload" and moves on, so one item the client cannot load does not stall the scan.
local function itemReady(s, itemID)
  -- Ask for the next few items as well, so their data has usually arrived by the time their turn comes.
  for i = s.done + 1, math.min(s.done + 1 + PRELOAD_AHEAD, #s.ids) do
    requestLoad(s, s.ids[i])
  end
  if isCached(itemID) then
    s.loadAt = nil
    return true
  end
  if not s.loadAt then
    s.loadAt = GetTime()
    return false
  end
  if GetTime() - s.loadAt < LOAD_TIMEOUT then return false end
  s.waiting, s.key, s.sentAt, s.cached, s.kind, s.thr = itemID, nil, s.loadAt, "no", "?", ""
  s.loadAt = nil
  advance("noload", 0)
  return false
end

-- One move of the scan: give up on a silent item, or send the next search once the server allows it.
local function step()
  local s = scan
  if not s then return end
  if s.waiting then
    if GetTime() - s.sentAt < ITEM_TIMEOUT then return end
    -- Last look before giving up, in case results arrived without the event we were waiting for.
    local tiers = {}
    local nc, fullC = readCommodity(s.waiting, tiers)
    local ni, fullI = readItems(s.key, tiers)
    if nc + ni > 0 then
      record(s.waiting, tiers, fullC and fullI, "lastlook", nc + ni)
    else
      advance("timeout", 0)   -- nothing stored: a timeout is "unknown", not "no listings"
    end
    return
  end
  local itemID = s.ids[s.done + 1]
  if not itemReady(s, itemID) then return end   -- still loading, or skipped as "noload" (the scan may have ended)
  -- Sending while throttled gets the message delayed or dropped, so wait for the all-clear.
  if not AH.IsThrottledMessageSystemReady() then
    -- The item timeout only covers searches already sent; without this a throttle that never clears hangs the scan.
    if GetTime() - s.lastMove > THROTTLE_GIVE_UP then
      finish("The server throttle never cleared, scan stopped")
    end
    return
  end
  -- The item's data is loaded here, so its vendor value can be read too (no extra request).
  if readSell(itemID) then s.sells = (s.sells or 0) + 1 end
  -- Built only now: with the item's data loaded MakeItemKey fills in the item level the search needs.
  s.key = AH.MakeItemKey(itemID)
  -- Logged as they are just before the search.
  s.cached, s.kind = itemFacts(itemID, s.key)
  s.thr = ""
  s.waiting = itemID   -- set before sending: the throttle events can fire inside the call
  s.sentAt = GetTime()
  AH.SendSearchQuery(s.key, SORTS, false)
end

-- An error inside a timer callback would silently end the scan; report it and keep what was collected.
local function safeStep()
  local ok, err = pcall(step)
  if not ok and scan then
    say("Stopped by an error: " .. tostring(err))
    finish("Scan aborted")
  end
end

-- C_Timer.After cannot be cancelled, so each loop carries its scan and dies when that scan is over.
local function poll(s)
  if scan ~= s then return end
  safeStep()
  if scan == s then
    C_Timer.After(POLL, function() poll(s) end)
  end
end

-- Shared by scans and debug runs: true when a run may start, otherwise it says why not.
local function canStart()
  if scan or quick then
    say("A scan is already running. /keboldscan stop ends it.")
  elseif debugRun then
    say("A debug run is active (it ends by itself after " .. DEBUG_SECONDS .. " seconds). /keboldscan stop ends it.")
  elseif not (AH and AH.SendSearchQuery and AH.IsThrottledMessageSystemReady and AH.MakeItemKey) then
    say("This client does not offer the auction house search functions this addon needs.")
  elseif not ahOpen then
    say("Please open the auction house first, then type the command again.")
  else
    return true
  end
  return false
end

local function startScan(lists, label)
  if not canStart() then return end
  local ids, seen = {}, {}
  for _, list in ipairs(lists) do
    for _, id in ipairs(list) do
      if type(id) == "number" and id > 0 and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
      end
    end
  end
  if #ids == 0 then
    say("Nothing to scan: the " .. label .. " list is empty. The addon's item list (Items.lua) is missing or damaged: copy the addon's folder again.")
    return
  end
  local store = realmStore()
  store.log = {}   -- one line per item of this scan, see advance()
  -- An item's earlier reading is replaced when its turn comes (see advance), not here: a 40-minute scan stopped
  -- part-way must not leave everything it never reached without a price. Each reading carries its own day, and
  -- the window says how old the oldest price it uses is.
  scan = {
    ids = ids, done = 0, found = 0, empty = 0, timeouts = 0, partial = 0,
    started = GetTime(), lastMove = GetTime(), day = today(), store = store, log = store.log, lateFrom = {},
    asked = {},   -- items whose data has been requested, so each is asked for once
    label = label,
  }
  lastRun = { ids = ids, label = label, total = #ids, done = 0, running = true, started = time(), state = {} }
  -- about 0.65 s an item in the first full run (456 items in just under 5 minutes)
  say(string.format("Scanning %d items (%s), about %s. Keep the auction house open; /keboldscan stop ends it early.",
    #ids, label, #ids < 90 and (math.ceil(#ids * 0.65) .. " seconds") or (math.ceil(#ids * 0.65 / 60) .. " minutes")))
  -- Kebold shows a progress bar, also for a scan typed in chat
  if type(KeboldsShiny_OnScanStarted) == "function" then pcall(KeboldsShiny_OnScanStarted, #ids, label) end
  poll(scan)
end

-- For Kebold (Ledger.lua): scan exactly these item ids / is a scan running / is the auction house open.
function KeboldsShinyScan_Start(ids, label)
  startScan({ ids }, label)
end
function KeboldsShinyScan_Busy()
  return scan ~= nil or debugRun ~= nil or quick ~= nil
end
function KeboldsShinyScan_AtAuctionHouse()
  return ahOpen
end
-- nil when no scan runs, else where it stands: { done, total, found, empty, timeouts, elapsed, eta, label }
function KeboldsShinyScan_Progress()
  if quick then return Q.progress() end
  local s = scan
  if not s then return nil end
  local elapsed = GetTime() - s.started
  local left = #s.ids - s.done
  return { done = s.done, total = #s.ids, found = s.found, empty = s.empty, timeouts = s.timeouts, elapsed = elapsed,
    eta = s.done > 0 and (elapsed / s.done * left) or (left * 0.65), label = s.label }
end
-- The running scan or the last one of this session (see lastRun above), nil before the first. Read only.
function KeboldsShinyScan_Last()
  return lastRun
end
-- Ends a running scan and keeps what it collected. True when there was one.
function KeboldsShinyScan_Stop()
  if quick then return Q.stop("stopped") end
  if not scan then return false end
  finish("Scan stopped")
  return true
end

local function status()
  local items = KeboldsShinyScanItems or {}
  if scan then
    say(string.format("Scanning: %d / %d - %d with listings, %d empty, %d timeouts, %.0f s so far.",
      scan.done, #scan.ids, scan.found, scan.empty, scan.timeouts, GetTime() - scan.started))
  elseif debugRun then
    say(string.format("Debug run active: %.0f of %d seconds, %d lines logged.",
      GetTime() - debugRun.started, DEBUG_SECONDS, #debugRun.log))
  else
    say("Idle. The auction house is " .. (ahOpen and "open." or "closed."))
  end
  local saved = 0
  for _ in pairs(realmStore().items) do saved = saved + 1 end
  say(string.format("Lists: %d materials, %d crafted parts, %d other crafted. Saved for this realm: %d items.",
    #(items.mats or {}), #(items.parts or {}), #(items.crafted or {}), saved))
end

-- ---------------------------------------------------------------------------------------------------------
-- /keboldscan debug [itemID]: one item, every step logged to chat and to KeboldsShinyDB.debug, to find
-- out why searches for listed items get no answer. Nothing below is used by a normal scan.
-- ---------------------------------------------------------------------------------------------------------

-- Compact text for any value; tables one level deep as key=value, which is enough for an item key.
local function show(v, nested)
  if type(v) == "table" then
    if nested then return "{...}" end
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. show(x, true) end
    table.sort(parts)
    return "{" .. table.concat(parts, ",", 1, math.min(#parts, 14)) .. (#parts > 14 and ",..." or "") .. "}"
  elseif type(v) == "string" and #v > 90 then
    return v:sub(1, 90) .. "..."
  end
  return tostring(v)
end

local function dlog(text)
  local d = debugRun
  if not d then return end
  local line = string.format("%.1f %s", GetTime() - d.started, text)
  if #d.log >= DEBUG_MAX_LINES then
    if not d.full then
      d.full = true
      d.log[#d.log + 1] = line:match("^%S+") .. " LOG FULL, later lines dropped"
      say("The debug log is full; later lines are not kept.")
    end
    return
  end
  d.log[#d.log + 1] = line
  -- "|" starts a colour or link code in chat; doubled, chat shows the text exactly as it was saved.
  print("|cffffcc66LS|r " .. (line:gsub("|", "||")))
end

local function logCall(label, ok, ...)
  if not ok then
    dlog(label .. " ERROR " .. show((...)))
    return nil
  end
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = show((select(i, ...))) end
  dlog(label .. " = " .. (parts[1] and table.concat(parts, ", ") or "(no value)"))
  return ...
end

-- Calls fn inside pcall, logs what it returned or the error text, and passes the results on.
local function try(label, fn, ...)
  if type(fn) ~= "function" then
    dlog(label .. " : no such function")
    return nil
  end
  return logCall(label, pcall(fn, ...))
end

local function logEnvironment()
  dlog("WOW_PROJECT_ID = " .. show(WOW_PROJECT_ID) .. " (documented: 18 is Forever)")
  try("GetBuildInfo()", GetBuildInfo)
  -- Existence of the old auction functions and window would mean the old auction house is (also) present.
  local names = { "C_AuctionHouse", "QueryAuctionItems", "GetNumAuctionItems", "CanSendAuctionQuery",
    "AuctionFrame", "AuctionHouseFrame", "IsUsingLegacyAuctionClient" }
  local parts = {}
  for i, name in ipairs(names) do parts[i] = name .. "=" .. type(_G[name]) end
  dlog("globals: " .. table.concat(parts, " "))
  for _, name in ipairs({ "AuctionFrame", "AuctionHouseFrame" }) do
    local f = _G[name]
    if type(f) == "table" and type(f.IsShown) == "function" then
      try(name .. ":IsShown()", f.IsShown, f)
    end
  end
  if type(CanSendAuctionQuery) == "function" then try("CanSendAuctionQuery()", CanSendAuctionQuery) end
  -- The exact list of what this client offers; a function the documentation does not know would show up here.
  local fns = {}
  for name, v in pairs(AH) do
    if type(v) == "function" then fns[#fns + 1] = name end
  end
  table.sort(fns)
  dlog("C_AuctionHouse has " .. #fns .. " functions:")
  local line = ""
  for _, name in ipairs(fns) do
    if #line + #name > 200 then
      dlog("  " .. line)
      line = ""
    end
    line = line .. name .. " "
  end
  if line ~= "" then dlog("  " .. line) end
end

local function logFacts(tag, itemID, key)
  try(tag .. " C_Item.IsItemDataCachedByID", C_Item and C_Item.IsItemDataCachedByID, itemID)
  -- Documented as taking an item location (an item in a bag), not an ID; tried anyway, its error text tells us.
  try(tag .. " GetItemCommodityStatus(itemID)", AH.GetItemCommodityStatus, itemID)
  try(tag .. " GetItemKeyInfo", AH.GetItemKeyInfo, key)
end

local function sendSearch(tag, key)
  try(tag .. " IsThrottledMessageSystemReady", AH.IsThrottledMessageSystemReady)
  dlog(tag .. " SendSearchQuery key=" .. show(key))
  local ok, err = pcall(AH.SendSearchQuery, key, SORTS, false)
  dlog(tag .. (ok and " sent, no error" or " ERROR " .. tostring(err)))
end

local function logRows(tag, itemID, key)
  local nc = try(tag .. " GetNumCommoditySearchResults", AH.GetNumCommoditySearchResults, itemID) or 0
  local ni = try(tag .. " GetNumItemSearchResults", AH.GetNumItemSearchResults, key) or 0
  for i = 1, math.min(nc, 3) do
    local r = AH.GetCommoditySearchResultInfo(itemID, i) or {}
    dlog(string.format("%s commodity row %d: unitPrice=%s quantity=%s", tag, i, show(r.unitPrice), show(r.quantity)))
  end
  for i = 1, math.min(ni, 3) do
    local r = AH.GetItemSearchResultInfo(key, i) or {}
    dlog(string.format("%s item row %d: buyoutAmount=%s bidAmount=%s minBid=%s quantity=%s itemKey=%s", tag, i,
      show(r.buyoutAmount), show(r.bidAmount), show(r.minBid), show(r.quantity), show(r.itemKey)))
  end
end

-- Event sniffer. Any event whose name contains one of these words is logged with its payload.
local SNIFF_WORDS = { "AUCTION", "COMMODITY", "ITEM_SEARCH", "ITEM_KEY", "BROWSE" }
-- These fire for every item the client loads, so only the ones about the debug item are kept.
local SNIFF_ITEM_EVENTS = { ITEM_DATA_LOAD_RESULT = true, GET_ITEM_INFO_RECEIVED = true }
-- Only used if the client refuses RegisterAllEvents.
local SNIFF_FALLBACK = {
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED", "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
  "AUCTION_HOUSE_BROWSE_FAILURE", "EXTRA_BROWSE_INFO_RECEIVED", "ITEM_KEY_ITEM_INFO_RECEIVED",
  "ITEM_DATA_LOAD_RESULT", "GET_ITEM_INFO_RECEIVED", "AUCTION_ITEM_LIST_UPDATE",
}
local sniffer = nil

local function onSniff(_, event, ...)
  local d = debugRun
  if not d then return end
  local keep = false
  if SNIFF_ITEM_EVENTS[event] then
    keep = (...) == d.item
  else
    for _, word in ipairs(SNIFF_WORDS) do
      if event:find(word, 1, true) then
        keep = true
        break
      end
    end
  end
  if not keep then return end
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = show((select(i, ...))) end
  dlog("EVENT " .. event .. (parts[1] and " " .. table.concat(parts, ", ") or ""))
end

local function startSniffer()
  if not sniffer then
    sniffer = CreateFrame("Frame")
    sniffer:SetScript("OnEvent", onSniff)
  end
  if not pcall(sniffer.RegisterAllEvents, sniffer) then
    local n = 0
    for _, event in ipairs(SNIFF_FALLBACK) do
      if pcall(sniffer.RegisterEvent, sniffer, event) then n = n + 1 end
    end
    dlog("RegisterAllEvents failed; listening to " .. n .. " named events instead")
  end
end

local function endDebug(reason)
  local d = debugRun
  -- Written directly so the closing line is kept even when the log is full.
  d.log[#d.log + 1] = string.format("%.1f %s", GetTime() - d.started, reason)
  debugRun = nil
  -- If this does not undo RegisterAllEvents on this client, onSniff still ignores everything until the reload.
  if sniffer then pcall(sniffer.UnregisterAllEvents, sniffer) end
  say(reason .. " (" .. #d.log .. " lines saved).")
end

-- Runs fn after delay seconds if this debug run is still the active one; an error is logged, not thrown.
local function probe(d, delay, label, fn)
  local function run()
    if debugRun ~= d then return end
    local ok, err = pcall(fn)
    if not ok then dlog(label .. " ERROR " .. tostring(err)) end
  end
  if delay == 0 then run() else C_Timer.After(delay, run) end
end

local function startDebug(itemID)
  if not canStart() then return end
  realmStore()   -- makes sure the saved table exists
  KeboldsShinyDB.debug = {}
  local d = { started = GetTime(), log = KeboldsShinyDB.debug, item = itemID }
  debugRun = d
  startSniffer()
  local key

  -- Search 1: exactly what a scan does, with what the client knows about the item logged first.
  probe(d, 0, "start", function()
    dlog("DEBUG item " .. itemID .. ", lasts " .. DEBUG_SECONDS .. " s; keep the auction house open")
    logEnvironment()
    d.name = try("C_Item.GetItemNameByID", C_Item and C_Item.GetItemNameByID, itemID)
    key = AH.MakeItemKey(itemID)
    dlog("MakeItemKey = " .. show(key))
    logFacts("before search 1:", itemID, key)
    sendSearch("search 1 (plain key):", key)
  end)
  probe(d, 4, "search 1 rows", function()
    logRows("search 1 after 4s:", itemID, key)
  end)

  -- Search 2: the same search once the item's data has been asked for and had time to arrive.
  probe(d, 5, "item data request", function()
    try("C_Item.RequestLoadItemDataByID", C_Item and C_Item.RequestLoadItemDataByID, itemID)
  end)
  probe(d, 8, "search 2", function()
    d.name = d.name or try("C_Item.GetItemNameByID", C_Item and C_Item.GetItemNameByID, itemID)
    logFacts("before search 2:", itemID, key)
    sendSearch("search 2 (after item data request):", key)
  end)
  probe(d, 12, "search 2 rows", function()
    logRows("search 2 after 4s:", itemID, key)
  end)

  -- Search 3: browse by name as the auction window does, then search with the item key the browse returned.
  probe(d, 13, "browse", function()
    if type(AH.SendBrowseQuery) ~= "function" then
      dlog("browse skipped: no SendBrowseQuery")
      return
    end
    if type(d.name) ~= "string" then
      dlog("browse skipped: the item name is still unknown")
      return
    end
    local order = Enum and Enum.AuctionHouseSortOrder or {}
    local filter = Enum and Enum.AuctionHouseFilter or {}
    -- Documented: a browse shows nothing without at least one filter, and seems to want price plus name sorts.
    local filters = {}
    for i, name in ipairs({ "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality",
      "LegendaryQuality", "ArtifactQuality" }) do
      filters[i] = filter[name] or (5 + i)   -- documented values 6 to 12
    end
    local query = {
      searchString = d.name,
      sorts = {
        { sortOrder = order.Price or 0, reverseSort = false },
        { sortOrder = order.Name or 1, reverseSort = false },
      },
      filters = filters,
    }
    try("browse: IsThrottledMessageSystemReady", AH.IsThrottledMessageSystemReady)
    dlog("browse: SendBrowseQuery searchString=" .. d.name .. ", price+name sorts, 7 quality filters")
    local ok, err = pcall(AH.SendBrowseQuery, query)
    dlog("browse:" .. (ok and " sent, no error" or " ERROR " .. tostring(err)))
  end)
  probe(d, 17, "browse rows", function()
    if type(AH.GetBrowseResults) ~= "function" then
      dlog("browse rows skipped: no GetBrowseResults")
      return
    end
    local results = AH.GetBrowseResults() or {}
    dlog("browse results: " .. #results)
    for i, r in ipairs(results) do
      if i <= 5 then
        dlog(string.format("browse row %d: itemKey=%s minPrice=%s totalQuantity=%s", i,
          show(r.itemKey), show(r.minPrice), show(r.totalQuantity)))
      end
      if not d.browseKey and type(r.itemKey) == "table" and r.itemKey.itemID == itemID then
        d.browseKey = r.itemKey
      end
    end
    if d.browseKey then
      logFacts("before search 3:", itemID, d.browseKey)
      sendSearch("search 3 (key from browse):", d.browseKey)
    else
      dlog("search 3 skipped: no browse row for item " .. itemID)
    end
  end)
  probe(d, 21, "search 3 rows", function()
    if d.browseKey then logRows("search 3 after 4s:", itemID, d.browseKey) end
  end)

  -- The rest of the run records what the game's own auction window triggers.
  probe(d, 22, "hint", function()
    dlog("NOW search for this item by hand in the auction window and click it. Listening until "
      .. DEBUG_SECONDS .. " s.")
  end)
  probe(d, DEBUG_SECONDS, "end", function()
    endDebug("debug finished, type /reload")
  end)
end

-- ---------------------------------------------------------------------------------------------------------
-- Quick scan (/keboldscan quick, /keboldscan gear). NOT seen on Forever: everything here is written from the
-- API pages of warcraft.wiki.gg and guarded, and what happens is logged to KeboldsShinyDB.quickLog.
--
--   quick  one request for every auction (C_AuctionHouse.ReplicateItems, allowed once per 15 minutes). After
--          REPLICATE_ITEM_LIST_UPDATE the rows are read a few hundred per frame (GetReplicateItemInfo, indexes
--          0 to GetNumReplicateItems() - 1; count, buyoutPrice and itemID are documented as available at once),
--          a price ladder is built per item Kebold knows and saved exactly as a per-item scan saves it. A
--          known item with no auction in the dump is saved as an empty reading. Other items are only counted.
--          No answer within REPLICATE_TIMEOUT seconds, no rows, or no such function: it falls back to gear.
--   gear   one browse of armour and weapons, uncommon and better (SendBrowseQuery, then RequestMoreBrowseResults
--          until HasFullBrowseResults). A browse row has the cheapest price and the number listed of one item key
--          and no ladder; item keys with the same item id are merged (cheapest price, quantities added up) and
--          saved as "<day>;<number listed>;<cheapest price>:1": ONE unit at the cheapest price, the rest of the
--          number listed without a price of its own. A reading whose tiers add up to less than its total is
--          therefore a price-and-total reading, never a full ladder. A same-day reading with more tiers is kept.
-- Queries only: nothing here buys, bids, posts or cancels.
-- ---------------------------------------------------------------------------------------------------------
local REPLICATE_COOLDOWN = 900   -- seconds the game wants between two whole-house requests (documented: 15 minutes)
local REPLICATE_TIMEOUT = 30     -- seconds to wait for the list before falling back to the gear browse
local READ_CHUNK = 500           -- auction rows read per frame
local SAVE_CHUNK = 200           -- items saved per frame
local PENDING_WAIT = 5           -- seconds given to rows that came without an item id or a count
local BROWSE_TIMEOUT = 10        -- seconds to wait for one page of browse results
local BROWSE_MAX_PAGES = 400     -- pages of 500 item keys after which the browse stops asking for more
local BROWSE_STALE = 3           -- pages in a row that brought nothing new before it stops asking
local LOAD_PER_TICK = 40         -- gear items whose data is requested per poll while the browse runs
local QUICK_LOG_MAX = 200        -- lines kept in KeboldsShinyDB.quickLog (the last quick scan's)
local QUICK_LABEL = "the whole auction house (quick scan)"
local GEAR_LABEL = "gear: cheapest price and number listed (quick)"

local function qlog(text)
  if type(KeboldsShinyDB) ~= "table" then return end
  local log = KeboldsShinyDB.quickLog
  if type(log) ~= "table" then
    log = {}
    KeboldsShinyDB.quickLog = log
  end
  if #log >= QUICK_LOG_MAX then return end
  log[#log + 1] = string.format("%.1f %s", quick and (GetTime() - quick.started) or 0, text)
end

-- One message for the player: Kebold's notice bar and chat when Kebold is loaded, else chat.
local function tell(text)
  local ns = KeboldsShinyNS
  if type(ns) == "table" and type(ns.notice) == "function" and pcall(ns.notice, text, "warn", true) then return end
  say(text)
end

local function waitText(seconds)
  if seconds >= 90 then return math.ceil(seconds / 60) .. " min" end
  return math.ceil(seconds) .. " s"
end

-- Seconds until the whole-house request may be sent again on this realm (0 = now). The time of the last request
-- is kept in the saved file (realms[...].quick.at), so a /reload does not forget it.
function KeboldsShinyScan_QuickWait()
  local q = realmStore().quick
  local at = type(q) == "table" and tonumber(q.at) or nil
  if not at then return 0 end
  local left = REPLICATE_COOLDOWN - (time() - at)
  if left <= 0 or left > REPLICATE_COOLDOWN then return 0 end   -- over, or the clock was set back
  return left
end

-- The items a quick scan saves: ids in Kebold's order, the same as a set, and the set of crafted gear.
-- From Kebold (every item any recipe makes, uses or is taught by); without it, from Items.lua.
local function knownItems()
  local ids, gear
  if type(KeboldsShiny_QuickItems) == "function" then
    local ok, a, b = pcall(KeboldsShiny_QuickItems)
    if ok and type(a) == "table" then ids, gear = a, (type(b) == "table" and b or {}) end
  end
  if not ids then
    ids, gear = {}, {}
    local items, seen = type(KeboldsShinyScanItems) == "table" and KeboldsShinyScanItems or {}, {}
    for _, list in ipairs({ items.mats or {}, items.parts or {}, items.crafted or {} }) do
      for _, id in ipairs(list) do
        if type(id) == "number" and id > 0 and not seen[id] then
          seen[id] = true
          ids[#ids + 1] = id
        end
      end
    end
  end
  local set = {}
  for _, id in ipairs(ids) do set[id] = true end
  return ids, set, gear
end

-- True only when the client says the item's data is loaded (isCached above answers true when it cannot tell).
local function loadedForSure(itemID)
  if not (C_Item and C_Item.IsItemDataCachedByID) then return false end
  local ok, value = pcall(C_Item.IsItemDataCachedByID, itemID)
  return ok and value and true or false
end

-- Is this armour or a weapon of uncommon quality or better, which is what the gear browse asks for? true / false,
-- nil when the client has not loaded the item (GetItemInfo: 3rd value quality, 12th class; 2 weapon, 4 armour).
local function browsable(itemID)
  if not loadedForSure(itemID) or not C_Item.GetItemInfo then return nil end
  local ok, name, _, quality, _, _, _, _, _, _, _, _, classID = pcall(C_Item.GetItemInfo, itemID)
  if not ok or not name or type(quality) ~= "number" or type(classID) ~= "number" then return nil end
  return quality >= 2 and (classID == 2 or classID == 4)
end

-- "<day>;<total>;<price>:<qty>,..." -> { day, total, n = tiers, sum = units in the tiers, low = cheapest price }
local function parseReading(text)
  if type(text) ~= "string" then return nil end
  local day, total, rest = text:match("^(%d+);(%d+);(.*)$")
  if not day then return nil end
  local r = { day = tonumber(day), total = tonumber(total), n = 0, sum = 0, low = nil }
  for p, n in rest:gmatch("(%d+):(%d+)") do
    r.n = r.n + 1
    r.sum = r.sum + tonumber(n)
    if not r.low then r.low = tonumber(p) end
  end
  return r
end

local function throttleReady()
  if type(AH.IsThrottledMessageSystemReady) ~= "function" then return true end
  local ok, ready = pcall(AH.IsThrottledMessageSystemReady)
  return (not ok) or (ready and true or false)
end

local function note(q, text)
  if lastRun == q.run then q.run.note = text end
end

local function saveHistory(q, itemID, low, total)
  if type(KeboldsShinyHistory) == "table" and KeboldsShinyHistory.record then
    pcall(KeboldsShinyHistory.record, q.store, itemID, q.day, low, total)
  end
end

local function settle(q, itemID, state)
  if state == "found" then q.found = q.found + 1 elseif state == "empty" then q.empty = q.empty + 1 end
  if lastRun == q.run then q.run.state[itemID] = state end
end

local function qfinish(reason)
  local q = quick
  quick = nil
  local text
  if q.browse then
    text = string.format("%d kinds of gear read over %d %s%s: %d of them are items Kebold knows.", q.nkeys, q.page, q.page == 1 and "page" or "pages",
      q.full and "" or " (the list is NOT complete)", q.browseKnown or 0)
    if q.kept > 0 then text = text .. " " .. q.kept .. " kept a fuller reading from today." end
    if (q.foreign or 0) > 0 then
      text = text .. " " .. q.foreign .. (q.foreign == 1 and " kind in the list is" or " kinds in the list are")
        .. " not gear (another search ran at the same time): gear missing from the list was left as it was, not saved as none listed."
    end
    if (q.skipped or 0) > 0 then
      text = text .. " " .. q.skipped .. (q.skipped == 1 and " item Kebold knows was" or " items Kebold knows were")
        .. " not saved from this list (not gear, or the game has not loaded it)."
    end
    if (q.unchecked or 0) > 0 then
      text = text .. " " .. q.unchecked .. (q.unchecked == 1 and " crafted gear item" or " crafted gear items")
        .. " missing from the list could not be checked (the game has not loaded them): left as they were."
    end
  elseif q.n > 0 then
    text = string.format("%d auctions read. %d auctions of %d other items were not saved.", q.rows, q.unknownRows, q.unknown)
    if q.noBuyout > 0 then text = text .. " " .. q.noBuyout .. " auctions without a buyout were skipped." end
    if q.unread > 0 then
      text = text .. " " .. q.unread .. (q.unread == 1 and " auction" or " auctions") .. " came without an item id, so "
        .. q.left .. " items with no auction read keep their earlier price."
    end
  end
  local run = q.run
  if lastRun == run then
    run.running, run.how, run.done = false, reason, q.done
    run.note = text or ""
  end
  if q.done > 0 then
    q.store.day = q.day
    q.store.time = time()
  end
  if type(KeboldsShinyDB) == "table" then
    KeboldsShinyDB.lastScan = { done = q.done, total = #q.ids, found = q.found, empty = q.empty, timeouts = q.left, time = time(),
      label = q.label, how = reason, sells = q.sells, note = text, quick = true }
  end
  qlog("finish: " .. reason .. (text and (" | " .. text) or ""))
  if q.sells > 0 then
    say(q.sells .. " vendor values were new or different from the last reading. Kebold's Prices page lists the ones that differ from its built-in data.")
  end
  say(string.format("%s: %d of %d items saved - %d with listings, %d without, %.1f seconds.", reason, q.done, #q.ids, q.found, q.empty, GetTime() - q.started))
  if text then say(text) end
  if q.done > 0 then
    say("Kebold uses the new prices at once.")
  end
  if type(KeboldsShiny_OnScanFinished) == "function" then pcall(KeboldsShiny_OnScanFinished, q.done, #q.ids) end
end

-- kind: "stopped" (by the player), "closed" (the auction house), "error", "failed" (why says what).
-- Before the saving starts nothing is written: half a dump would give short ladders and wrong "nothing listed".
function Q.stop(kind, why)
  local q = quick
  if not q then return false end
  local what = (q.browse ~= nil or q.mode == "gear") and "Gear scan" or "Quick scan"
  local reason = (kind == "closed" and ("Auction house closed, " .. what:lower() .. " stopped")) or (kind == "error" and (what .. " aborted"))
    or (kind == "failed" and (what .. " failed (" .. tostring(why) .. ")")) or (what .. " stopped")
  if q.phase ~= "save" then reason = reason .. ", nothing was saved" end
  qfinish(reason)
  return true
end

-- ---- the gear browse ------------------------------------------------------------------------------------

-- Documented (SendBrowseQuery): searchString and sorts are required, a browse shows nothing without at least one
-- filter, and the sorts seem to want price plus name. Enum values as documented, used when the enum is missing.
local function browseQuery()
  local order = Enum and Enum.AuctionHouseSortOrder or {}
  local filter = Enum and Enum.AuctionHouseFilter or {}
  local class = Enum and Enum.ItemClass or {}
  return {
    searchString = "",
    sorts = {
      { sortOrder = order.Price or 0, reverseSort = false },
      { sortOrder = order.Name or 1, reverseSort = false },
    },
    filters = { filter.UncommonQuality or 8, filter.RareQuality or 9, filter.EpicQuality or 10, filter.LegendaryQuality or 11,
      filter.ArtifactQuality or 12 },
    itemClassFilters = { { classID = class.Weapon or 2 }, { classID = class.Armor or 4 } },
  }
end

local function browseResults()
  if type(AH.GetBrowseResults) ~= "function" then return nil end
  local ok, list = pcall(AH.GetBrowseResults)
  return ok and type(list) == "table" and list or nil
end

-- Rows are kept per item key, so a row that arrives twice (in the event and in the full list) counts once.
local function absorb(q, list)
  if type(list) ~= "table" then return end
  for _, r in ipairs(list) do
    local key = type(r) == "table" and r.itemKey or nil
    local id = type(key) == "table" and key.itemID or nil
    if type(id) == "number" and id > 0 then
      local k = id .. ":" .. tostring(key.itemLevel or 0) .. ":" .. tostring(key.itemSuffix or 0) .. ":" .. tostring(key.battlePetSpeciesID or 0)
      if not q.keys[k] then q.nkeys = q.nkeys + 1 end
      q.keys[k] = { id, tonumber(r.minPrice) or 0, tonumber(r.totalQuantity) or 0 }
    end
  end
end

-- The game's data for crafted gear is asked for while the browse runs, so that at the end the scan can tell which
-- of the items missing from the list are really the kind of item the browse asked for.
local function loadSome(q)
  if not (C_Item and C_Item.RequestLoadItemDataByID) then return end
  local n = 0
  while q.loadPos <= #q.all and n < LOAD_PER_TICK do
    local id = q.all[q.loadPos]
    q.loadPos = q.loadPos + 1
    if q.gear[id] and not isCached(id) then
      pcall(C_Item.RequestLoadItemDataByID, id)
      n = n + 1
    end
  end
end

local function beginSave(q)
  local ids = {}
  if q.browse then
    absorb(q, browseResults())   -- the client's whole list, when it keeps one
    -- The client's browse list is one list: a search typed on the Buy tab, or sent by another addon, while this
    -- scan waits lands in it too. So a row is only saved for crafted gear of the scan's own set, or for an item
    -- the game says is armour or a weapon of uncommon quality or better (what the gear query asks for). A row the
    -- game says is something else proves foreign rows are in the list (q.foreign): the list is then not the gear
    -- query's own, and nothing missing from it is written down as "none listed".
    local other, fitOf = {}, {}
    for _, e in pairs(q.keys) do
      local id, low, qty = e[1], e[2], e[3]
      local fits = fitOf[id]
      if fits == nil then
        fits = browsable(id)
        if fits == nil then fits = "?" end
        fitOf[id] = fits
        if fits == false then q.foreign = q.foreign + 1 end
      end
      if q.known[id] and not (q.gear[id] or fits == true) then
        if not other[id] then
          other[id] = true
          q.skipped = q.skipped + 1
        end
      elseif q.known[id] then
        local b = q.browse[id]
        if not b then
          b = { qty = 0, low = nil }
          q.browse[id] = b
        end
        b.qty = b.qty + qty
        if low > 0 and (b.low == nil or low < b.low) then b.low = math.ceil(low) end
      elseif not other[id] then
        other[id] = true
        q.unknown = q.unknown + 1
      end
    end
    for _, id in ipairs(q.all) do
      if q.browse[id] then ids[#ids + 1] = id end
    end
    q.browseKnown = #ids
    -- Crafted gear the complete list does not have: nothing is listed, IF the browse would have shown it.
    if q.foreign > 0 then
      qlog("browse: " .. q.foreign .. " kinds in the list are not armour or weapons of uncommon quality or better (another search's rows): "
        .. q.skipped .. " known items not saved, nothing written as none listed")
    end
    if q.full and q.foreign == 0 then
      for _, id in ipairs(q.all) do
        if q.gear[id] and not q.browse[id] then
          local fits = browsable(id)
          if fits == true then ids[#ids + 1] = id elseif fits == nil then q.unchecked = q.unchecked + 1 end
        end
      end
    end
  else
    for _, id in ipairs(q.all) do
      if q.tiers[id] then ids[#ids + 1] = id end
    end
    for _, id in ipairs(q.all) do
      if not q.tiers[id] then ids[#ids + 1] = id end
    end
  end
  q.ids, q.spos, q.phase = ids, 1, "save"
  if lastRun == q.run then q.run.ids, q.run.total = ids, #ids end
  qlog("saving " .. #ids .. " items")
  if #ids == 0 then
    qfinish(q.browse and (q.full and "Gear scan complete" or "Gear scan ended early") or "Quick scan complete")
  end
end

local function nextPage(q, grew)
  q.lastMove = GetTime()
  q.stale = grew and 0 or (q.stale + 1)
  local full = nil
  if type(AH.HasFullBrowseResults) == "function" then
    local ok, value = pcall(AH.HasFullBrowseResults)
    if ok then full = value and true or false end
  end
  if full == true then
    q.full = true
    beginSave(q)
  elseif full == nil or type(AH.RequestMoreBrowseResults) ~= "function" or q.page >= BROWSE_MAX_PAGES or q.stale >= BROWSE_STALE then
    qlog("browse ends without the full list: full=" .. tostring(full) .. " page=" .. q.page .. " stale=" .. q.stale)
    q.full = false
    beginSave(q)
  else
    q.phase = "bmore"
  end
end

local function beginBrowse(q)
  q.browse, q.phase, q.lastMove = {}, "bsend", GetTime()
  if not (type(AH.SendBrowseQuery) == "function" and type(AH.GetBrowseResults) == "function") then
    Q.stop("failed", "this client has no browse query")
  end
end

-- AUCTION_HOUSE_BROWSE_RESULTS_UPDATED (no payload: read the list) and ..._ADDED (payload: the rows added).
function Q.onBrowse(added)
  local q = quick
  if not (q and q.phase == "bwait") then return end
  local before = q.nkeys
  if type(added) == "table" then absorb(q, added) else absorb(q, browseResults()) end
  qlog("browse page " .. q.page .. ": " .. q.nkeys .. " item keys so far")
  nextPage(q, q.nkeys > before)
end

function Q.onBrowseFailure()
  local q = quick
  if not (q and (q.phase == "bwait" or q.phase == "bmore")) then return end
  qlog("AUCTION_HOUSE_BROWSE_FAILURE on page " .. q.page)
  if q.nkeys > 0 then
    q.full = false
    beginSave(q)
  else
    Q.stop("failed", "the auction house reported a browse failure")
  end
end

-- ---- the whole house ------------------------------------------------------------------------------------

-- The whole-house request did not work: say so once and read gear by browsing instead.
local function fallback(q, why)
  qlog("fallback to the gear browse: " .. why)
  q.fellBack = why
  q.label = GEAR_LABEL .. ", because the whole-house request got nowhere"
  if lastRun == q.run then q.run.label = q.label end
  tell("Quick scan: " .. why .. ". Reading gear only instead (cheapest price and number listed); materials need one of the other scans.")
  beginBrowse(q)
end

local function beginRead(q, n)
  q.phase, q.n, q.pos = "read", n, 0
  qlog("list received: " .. n .. " auctions")
end

-- REPLICATE_ITEM_LIST_UPDATE: the list is there. (It fires again for every row the client fills in afterwards;
-- those are ignored, the rows are read by position.)
function Q.onReplicate()
  local q = quick
  if not (q and q.phase == "wait") then return end
  local ok, n = pcall(AH.GetNumReplicateItems)
  n = ok and tonumber(n) or 0
  if n > 0 then
    beginRead(q, n)
  else
    fallback(q, "the auction house answered with no auctions")
  end
end

local function requestAll(q)
  if not (type(AH.ReplicateItems) == "function" and type(AH.GetNumReplicateItems) == "function" and type(AH.GetReplicateItemInfo) == "function") then
    fallback(q, "this client has no whole-auction-house request")
    return
  end
  local before = q.store.quick
  q.phase, q.sentAt = "wait", GetTime()
  -- Remembered when it is sent, answered or not: the server may have counted it. Set before the call, because
  -- the answer can arrive inside it.
  q.store.quick = { at = time() }
  local ok, err = pcall(AH.ReplicateItems)
  qlog("ReplicateItems " .. (ok and "sent" or ("ERROR " .. tostring(err))))
  if not ok and quick == q and q.phase == "wait" then
    q.store.quick = before   -- never sent
    fallback(q, "the whole-auction-house request raised an error")
  end
end

-- One row of the dump. Returns false when the row has no item id or count yet (documented as there at once; kept
-- for a second look in case this client fills them in later).
local function readRow(q, i)
  -- returns: name, texture, count, qualityID, usable, level, levelType, minBid, minIncrement, buyoutPrice, bidAmount,
  -- highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemID, hasAllInfo
  local ok, err, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = pcall(AH.GetReplicateItemInfo, i)
  if not ok then
    q.errors = q.errors + 1
    if q.errors <= 3 then qlog("GetReplicateItemInfo(" .. i .. ") ERROR " .. tostring(err)) end
    return true
  end
  if type(itemID) ~= "number" or itemID <= 0 or type(count) ~= "number" or count <= 0 then return false end
  q.rows = q.rows + 1
  if type(buyout) ~= "number" or buyout <= 0 then
    q.noBuyout = q.noBuyout + 1   -- bid only: no price anyone can simply pay
    if q.known[itemID] and not q.tiers[itemID] then q.tiers[itemID] = {} end
    return true
  end
  if q.known[itemID] then
    local tiers = q.tiers[itemID]
    if not tiers then
      tiers = {}
      q.tiers[itemID] = tiers
    end
    addTier(tiers, math.ceil(buyout / count), count)   -- rounded up, as in the per-item scan
  else
    q.unknownRows = q.unknownRows + 1
    if not q.unknownIds[itemID] then
      q.unknownIds[itemID] = true
      q.unknown = q.unknown + 1
    end
  end
  return true
end

local function saveOne(q, id)
  if q.browse then
    local b = q.browse[id]
    local qty, low = b and b.qty or 0, b and b.low or nil
    local tiers = (low and qty > 0) and 1 or 0
    local old = parseReading(q.store.items[id])
    -- A reading of today with more tiers knows more than a browse row does; so does today's full one-tier
    -- ladder that says the same price and number.
    if old and old.day == q.day and (old.n > tiers
        or (old.n == 1 and tiers == 1 and old.sum == old.total and old.low == low and old.total == qty)) then
      q.kept = q.kept + 1
      settle(q, id, (old.n > 0 or old.total > 0) and "found" or "empty")
    else
      -- ONE unit at the cheapest price; the number listed is the total. Not a ladder, and it does not look like one.
      q.store.items[id] = int(q.day) .. ";" .. int(qty) .. ";" .. (tiers == 1 and (int(low) .. ":1") or "")
      saveHistory(q, id, tiers == 1 and low or 0, qty)
      settle(q, id, qty > 0 and "found" or "empty")
    end
  else
    local tiers = q.tiers[id]
    if tiers or q.unread == 0 then
      local text, total, low = encode(q.day, tiers or {})
      q.store.items[id] = text
      saveHistory(q, id, low, total)
      settle(q, id, total > 0 and "found" or "empty")
    else
      q.left = q.left + 1
      settle(q, id, "timeout")   -- some rows could not be read: "nothing listed" would be a guess
    end
  end
  if loadedForSure(id) and readSell(id) then q.sells = q.sells + 1 end
  q.done = q.done + 1
end

function Q.step(q)
  local now = GetTime()
  if q.phase == "wait" then
    note(q, "asking for the whole auction house")
    if now - q.sentAt < REPLICATE_TIMEOUT then return end
    local ok, n = pcall(AH.GetNumReplicateItems)   -- last look, in case the list came without its event
    n = ok and tonumber(n) or 0
    if n > 0 then
      qlog("no list event, but the client holds " .. n .. " auctions")
      beginRead(q, n)
    else
      fallback(q, "the auction house did not answer the whole-house request within " .. REPLICATE_TIMEOUT .. " seconds")
    end
  elseif q.phase == "read" then
    local last = math.min(q.pos + READ_CHUNK, q.n) - 1
    for i = q.pos, last do   -- indexes are 0-based
      if not readRow(q, i) then
        q.pending[#q.pending + 1] = i
      end
    end
    q.pos = last + 1
    note(q, "reading " .. q.pos .. " of " .. q.n .. " auctions")
    if q.pos >= q.n then
      if #q.pending > 0 then
        qlog(#q.pending .. " rows without an item id or count: looking again for up to " .. PENDING_WAIT .. " s")
        q.phase, q.pendAt, q.pendNext, q.ppos, q.again = "pending", now, now + 1, 1, {}
      else
        beginSave(q)
      end
    end
  elseif q.phase == "pending" then
    if q.ppos == 1 and now < q.pendNext then return end
    local last = math.min(q.ppos + READ_CHUNK - 1, #q.pending)
    for k = q.ppos, last do
      if not readRow(q, q.pending[k]) then q.again[#q.again + 1] = q.pending[k] end
    end
    q.ppos = last + 1
    if q.ppos > #q.pending then
      q.pending, q.again, q.ppos, q.pendNext = q.again, {}, 1, now + 1
      if #q.pending == 0 or now - q.pendAt >= PENDING_WAIT then
        q.unread = #q.pending
        if q.unread > 0 then qlog(q.unread .. " rows never got an item id or count") end
        beginSave(q)
      end
    end
  elseif q.phase == "save" then
    local last = math.min(q.spos + SAVE_CHUNK - 1, #q.ids)
    for k = q.spos, last do saveOne(q, q.ids[k]) end
    q.spos = last + 1
    if lastRun == q.run then q.run.done = q.done end
    note(q, "saving " .. q.done .. " of " .. #q.ids .. " items")
    if q.spos > #q.ids then
      qfinish(q.browse and (q.full and "Gear scan complete" or "Gear scan ended early") or "Quick scan complete")
    end
  elseif q.phase == "bsend" or q.phase == "bmore" then
    loadSome(q)
    note(q, "reading gear: " .. q.nkeys .. " kinds so far")
    if not throttleReady() then
      if now - q.lastMove > THROTTLE_GIVE_UP then
        qlog("the throttle never cleared in phase " .. q.phase)
        if q.nkeys > 0 then
          q.full = false
          beginSave(q)
        else
          Q.stop("failed", "the server throttle never cleared")
        end
      end
      return
    end
    local first = q.phase == "bsend"
    q.phase, q.sentAt, q.page = "bwait", now, q.page + 1   -- set before sending: the answer can arrive inside the call
    local ok, err
    if first then ok, err = pcall(AH.SendBrowseQuery, browseQuery()) else ok, err = pcall(AH.RequestMoreBrowseResults) end
    qlog((first and "SendBrowseQuery " or "RequestMoreBrowseResults ") .. (ok and "sent" or ("ERROR " .. tostring(err))))
    if not ok and quick == q and q.phase == "bwait" then
      if q.nkeys > 0 then
        q.full = false
        beginSave(q)
      else
        Q.stop("failed", "the browse query raised an error")
      end
    end
  elseif q.phase == "bwait" then
    loadSome(q)
    if now - q.sentAt < BROWSE_TIMEOUT then return end
    local before = q.nkeys
    absorb(q, browseResults())   -- last look, in case rows came without an event
    qlog("browse page " .. q.page .. " timed out; " .. (q.nkeys - before) .. " new item keys at the last look")
    if q.nkeys > before then
      nextPage(q, true)
    elseif q.nkeys > 0 then
      q.full = false
      beginSave(q)
    else
      Q.stop("failed", "the auction house did not answer the gear query within " .. BROWSE_TIMEOUT .. " seconds")
    end
  end
end

-- Reading and saving go frame by frame; waiting is polled like the per-item scan.
local function qtick(q)
  if quick ~= q then return end
  local ok, err = pcall(Q.step, q)
  if not ok and quick == q then
    qlog("error: " .. tostring(err))
    say("Quick scan stopped by an error: " .. tostring(err))
    Q.stop("error")
  end
  if quick == q then
    local fast = q.phase == "read" or q.phase == "pending" or q.phase == "save"
    C_Timer.After(fast and 0 or POLL, function() qtick(q) end)
  end
end

-- What Kebold's progress bars show: the same fields as a per-item scan, plus `text` (what it is doing).
function Q.progress()
  local q = quick
  local done, total, text = 0, 1, ""
  if q.phase == "wait" then
    text = string.format("asking for the whole auction house (%d s of up to %d)", GetTime() - q.sentAt, REPLICATE_TIMEOUT)
  elseif q.phase == "read" then
    done, total, text = q.pos, q.n, "reading " .. q.pos .. " of " .. q.n .. " auctions"
  elseif q.phase == "pending" then
    done, total, text = q.n, q.n, "waiting for " .. #q.pending .. " auctions the game has not filled in"
  elseif q.phase == "save" then
    done, total, text = q.done, #q.ids, "saving " .. q.done .. " of " .. #q.ids .. " items"
  else
    done, total, text = q.nkeys, math.max(q.nkeys, 1), "reading gear: " .. q.nkeys .. " kinds, page " .. math.max(q.page, 1)
  end
  return { done = done, total = total, found = q.found, empty = q.empty, timeouts = 0, elapsed = GetTime() - q.started, eta = 0,
    label = q.label, text = text, quick = true, phase = q.phase }
end

-- mode: "quick" (the whole house, falling back to gear) or "gear" (the browse alone). True when it started.
function Q.start(mode)
  if scan or quick then
    say("A scan is already running. /keboldscan stop ends it.")
    return false
  elseif debugRun then
    say("A debug run is active (it ends by itself after " .. DEBUG_SECONDS .. " seconds). /keboldscan stop ends it.")
    return false
  elseif type(AH) ~= "table" then
    say("This client does not offer the auction house functions this addon needs.")
    return false
  elseif not ahOpen then
    say("Please open the auction house first, then type the command again.")
    return false
  end
  if mode == "quick" then
    local wait = KeboldsShinyScan_QuickWait()
    if wait > 0 then
      tell("The game allows the whole-auction-house request once per 15 minutes: ready in " .. waitText(wait)
        .. ". Gear (quick), /keboldscan gear, works meanwhile.")
      return false
    end
  end
  local ids, known, gear = knownItems()
  if #ids == 0 then
    say("Nothing to scan: Kebold's item lists are empty.")
    return false
  end
  local store = realmStore()
  KeboldsShinyDB.quickLog = {}
  local label = mode == "quick" and QUICK_LABEL or GEAR_LABEL
  local q = {
    mode = mode, phase = mode == "quick" and "wait" or "bsend", started = GetTime(), lastMove = GetTime(), sentAt = GetTime(), day = today(), store = store, label = label,
    all = ids, known = known, gear = gear,
    n = 0, pos = 0, tiers = {}, pending = {}, rows = 0, noBuyout = 0, unknown = 0, unknownRows = 0, unknownIds = {}, unread = 0, errors = 0,
    browse = nil, keys = {}, nkeys = 0, page = 0, stale = 0, full = false, unchecked = 0, loadPos = 1, foreign = 0, skipped = 0,
    ids = {}, spos = 1, done = 0, found = 0, empty = 0, kept = 0, left = 0, sells = 0,
  }
  quick = q
  lastRun = { ids = {}, label = label, total = 0, done = 0, running = true, started = time(), state = {}, quick = true, note = "" }
  q.run = lastRun
  qlog("start " .. mode .. ": " .. #ids .. " known items")
  if mode == "quick" then
    say("Quick scan: asking for the whole auction house (one request, allowed once per 15 minutes). Keep the auction house open; /keboldscan stop ends it.")
  else
    say("Gear scan: browsing armour and weapons, uncommon and better. Keep the auction house open; /keboldscan stop ends it.")
  end
  if type(KeboldsShiny_OnScanStarted) == "function" then pcall(KeboldsShiny_OnScanStarted, #ids, label) end
  if mode == "quick" then requestAll(q) else beginBrowse(q) end
  if quick == q then qtick(q) end
  return true
end

-- For Kebold's buttons: does this scanner have the quick scans at all.
function KeboldsShinyScan_HasQuick()
  return true
end

SLASH_KEBOLDSSHINYSCAN1 = "/keboldscan"
SLASH_KEBOLDSSHINYSCAN2 = "/ledgerscan"   -- the name before the addon was renamed
SlashCmdList["KEBOLDSSHINYSCAN"] = function(msg)
  local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
  local items = KeboldsShinyScanItems or {}
  if cmd == "" then
    -- What you buy to craft: raw materials plus the crafted parts other recipes use (bars, leather, tubes, bolts).
    startScan({ items.mats or {}, items.parts or {} }, "materials and crafted parts")
  elseif cmd == "mats" then
    startScan({ items.mats or {} }, "materials")
  elseif cmd == "parts" then
    startScan({ items.parts or {} }, "crafted parts")
  elseif cmd == "all" then
    startScan({ items.mats or {}, items.parts or {}, items.crafted or {} }, "materials, crafted parts, then everything else")
  elseif cmd == "quick" then
    Q.start("quick")
  elseif cmd == "gear" then
    Q.start("gear")
  elseif cmd == "stop" then
    if quick then
      Q.stop("stopped")
    elseif scan then
      finish("Scan stopped")
    elseif debugRun then
      endDebug("debug stopped, type /reload")
    else
      say("Nothing is running.")
    end
  elseif cmd == "status" then
    status()
  elseif cmd == "debug" or cmd:find("^debug%s") then
    startDebug(tonumber(cmd:match("^debug%s+(%d+)$")) or DEBUG_ITEM)
  elseif cmd:find("^[%d,%s]+$") then
    local ids = {}
    for id in cmd:gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
    startScan({ ids }, "chosen items")
  elseif type(KeboldsShiny_ScanCommand) == "function" and KeboldsShiny_ScanCommand(cmd) then
    -- a profession ("bs", "lw", ...), "route" or "everything": Kebold picked the items and started the scan
  else
    say("Usage: /keboldscan [mats | parts | all | stop | status | <item ids separated by commas or spaces>]")
    say("One profession only: /keboldscan bs (or lw, tailoring, eng, alch, ench, cook, firstaid, mining), add 'all' for every item of it. /keboldscan route = just the items of your leveling route.")
    say("/keboldscan fav = the recipes you marked as favourites in Kebold (what they make and everything needed to make them).")
    say("/keboldscan everything = every item of all nine professions: materials, parts, products with gear, recipe items (several thousand, about 40 minutes).")
    say("/keboldscan quick = the whole auction house in one request (once per 15 minutes; falls back to gear when the server does not answer). /keboldscan gear = armour and weapons by browsing: cheapest price and number listed only.")
    if type(KeboldsShiny_ScanHelp) == "function" then pcall(KeboldsShiny_ScanHelp) end   -- the scans by the names Kebold's pages use
  end
end

local handlers = {}

function handlers.AUCTION_HOUSE_SHOW()
  ahOpen = true
end

-- Documented to fire twice per close; the second call finds nothing running and does nothing.
function handlers.AUCTION_HOUSE_CLOSED()
  ahOpen = false
  if scan then finish("Auction house closed, scan stopped") end
  if quick then Q.stop("closed") end
  if debugRun then endDebug("auction house closed, debug stopped early, type /reload") end
end

-- The throttle events carry no payload, but while one search is pending they can only be about it.
local function mark(letter)
  if scan and scan.waiting then scan.thr = scan.thr .. letter end
end

function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_SENT() mark("S") end
function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED() mark("Q") end
function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED() mark("D") end
function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED() mark("R") end

-- Saves up to one poll interval per item compared with waiting for the next timer tick.
function handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
  mark("Y")
  safeStep()
end

-- We do not know whether Forever files stackable materials as commodities, so both result kinds are handled.
-- The Blizzard window searches too; results for any item other than the one we are waiting on are ignored.
function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
  if scan and scan.waiting and itemID == scan.waiting then
    local tiers = {}
    local n, full = readCommodity(itemID, tiers)
    record(itemID, tiers, full, "commodity", n)
  elseif scan and type(itemID) == "number" and scan.lateFrom[itemID] then
    noteLate(itemID, "commodity", AH.GetNumCommoditySearchResults(itemID) or 0)
  end
end

function handlers.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
  local itemID = type(itemKey) == "table" and itemKey.itemID or nil
  if scan and scan.waiting and itemID == scan.waiting then
    local tiers = {}
    -- Read with the key the client reported: it may carry an item level or suffix ours does not.
    local n, full = readItems(itemKey, tiers)
    record(itemID, tiers, full, "item", n)
  elseif scan and itemID and scan.lateFrom[itemID] then
    noteLate(itemID, "item", AH.GetNumItemSearchResults(itemKey) or 0)
  end
end

-- The quick scan's events (see Q above). REPLICATE_ITEM_LIST_UPDATE can fire thousands of times a frame while
-- rows are read, so its handler does nothing unless a quick scan is waiting for the list.
function handlers.REPLICATE_ITEM_LIST_UPDATE() Q.onReplicate() end
function handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED() Q.onBrowse(nil) end
function handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED(added) Q.onBrowse(added) end
function handlers.AUCTION_HOUSE_BROWSE_FAILURE() Q.onBrowseFailure() end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
  local ok, err = pcall(handlers[event], ...)
  if not ok then
    say("Error in " .. event .. ": " .. tostring(err))
    if scan then finish("Scan aborted") end
    if quick then Q.stop("error") end
  end
end)
for event in pairs(handlers) do
  -- Registering a name the client does not know raises an error, which would stop the file loading.
  if not pcall(frame.RegisterEvent, frame, event) then
    say("This client has no event " .. event .. ".")
  end
end
