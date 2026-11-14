-- Kebold's Shiny: what your own auctions did, and a price history of the addon's own scans.
-- Written from Blizzard's API documentation (warcraft.wiki.gg) only. It WATCHES: it never posts, buys, cancels or
-- takes mail. The one message it sends is the "list my auctions" query the Auctions tab sends itself
-- (/keboldsales auto off stops that). Nothing here has run in the real game yet: every game call is wrapped, a
-- missing function or event switches off that part only, and what was seen goes to a capped log
-- (KeboldsShinyDB.salesLog, /keboldsales log).
--
-- ---- API ----------------------------------------------------------------------------------------------------------
-- KeboldsShinySales.rate(itemID)     -> share, units, auctions   or nil when no auction of it has finished
--     share    = units sold / (units sold + units expired), 0..1. Cancelled auctions are left out of both.
--     units    = the sample size in units (sold + expired); auctions = the same in auctions.
-- KeboldsShinySales.summary(itemID)  -> nil, or a fresh table:
--     { name, posted, postedQty, sold, soldQty, expired, expiredQty, cancelled, cancelledQty,   (auctions / units)
--       postPrice, postDay, salePrice, saleDay,      (copper per unit; day = the scanner's day number; may be nil)
--       open, openQty,                               (still listed, as far as the addon knows)
--       finished, rate }                             (finished = soldQty + expiredQty; rate nil when finished is 0)
-- KeboldsShinySales.events(itemID)   -> newest-first list of { day, kind, item, qty, unit, src } (all items when
--     itemID is nil); kind is posted / sold / expired / cancelled; src says which signal decided it.
-- KeboldsShinyHistory.readings(itemID) -> oldest-first list of { day = , low = , qty = }: one per scan day, at most
--     30. low is the cheapest unit price of that day's last scan, 0 when nothing was listed.
-- KeboldsShinyHistory.median(itemID)   -> median low, days   (days with a listing only; nil when there is none).
--     The median, never the mean: one bait day drags a mean. Rounded like the page's medianOf.
-- KeboldsShinyHistory.drop(itemID)     -> share, low, median  when the latest low is at least 20% under the median
--     of at least 3 days (the page's drop flag: (median - low) / median), otherwise nil. A flag only: history
--     cannot tell bait from a real drop, so never use it to replace a price.
-- KeboldsShinyHistory.record(store, itemID, day, low, qty)  is called by the scan for every item it saves.
-- All of them are safe to call at any time and for any id.
--
-- ---- saved ----------------------------------------------------------------------------------------------------------
-- KeboldsShinyDB.sales[<realm>] = { items = { [itemID] = counts }, open = { [auctionID] = auction },
--     events = { "day|kind|item|qty|unit|src", ... }, soldSeen, done, hints, names, mail }
-- KeboldsShinyDB.salesLog = { "<time> text", ... }      KeboldsShinyDB.salesAuto = false to stop the query
-- KeboldsShinyDB.realms[<realm>].hist[itemID] = "day:low:qty,day:low:qty,..."
-- (None of these strings look like a ladder, "day;total;tiers", which is what the web page reads from this file.)
--
-- ---- signals (two where possible) -----------------------------------------------------------------------------------
-- posted     a post-hook on C_AuctionHouse.PostItem / PostCommodity (item, quantity, price) matched with
--            AUCTION_HOUSE_AUCTION_CREATED (auction id); or an auction that is new in the owned list.
-- sold       the owned list: status Sold, a quantity that went down, or an auction that left the list before its
--            time was up; AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION (AuctionSold, with the auction id);
--            the system chat line ERR_AUCTION_SOLD_S; a seller invoice in the mailbox.
-- expired    the notification (AuctionExpired); the chat line ERR_AUCTION_EXPIRED_S; an auction that left the list
--            after its time was up (a guess, "gone-late", which a sale invoice in the mailbox later corrects).
-- cancelled  AUCTION_CANCELED (auction id); a post-hook on C_AuctionHouse.CancelAuction; the notification
--            (AuctionRemoved).

local MAX_EVENTS = 200       -- recent events kept per realm
local MAX_LOG = 300          -- debug log lines kept
local MAX_DAYS = 30          -- readings kept per item
local MAX_DONE = 100         -- finished auctions remembered, so a mail can confirm or correct them
local DROP_SHARE = 0.20      -- the page's default drop flag
local DROP_MIN_DAYS = 3
local PENDING_SECONDS = 30   -- how long a post call waits for its "auction created" event
local HINT_SECONDS = 3 * 86400
local MAIL_HINT_SECONDS = 30 * 86400
local DAY_ZERO = 1577836800  -- the scanner's day origin
local DURATION_HOURS = { 12, 24, 48 }
local KINDS = { posted = true, sold = true, expired = true, cancelled = true }

local AH = type(C_AuctionHouse) == "table" and C_AuctionHouse or {}
local floor = math.floor

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local function pass(ok, ...)
    if ok then return ... end
    return nil
  end
  return pass(pcall(fn, ...))
end

local function say(msg)
  print("|cff66ccffKeboldSales|r " .. msg)
end

local function now()
  return try(time) or 0
end

local function today()
  return floor((now() - DAY_ZERO) / 86400)
end

local function int(n)
  return string.format("%.0f", n)
end

local function db()
  if type(KeboldsShinyDB) ~= "table" then KeboldsShinyDB = {} end
  return KeboldsShinyDB
end

local function realmName()
  return try(GetRealmName) or "Unknown"
end

-- ---- debug log ------------------------------------------------------------------------------------------------------

-- The saved table is only there once the game has loaded it, so lines written while the file loads wait here.
local ready, early = false, {}

local function writeLog(line)
  local d = db()
  if type(d.salesLog) ~= "table" then d.salesLog = {} end
  local log = d.salesLog
  log[#log + 1] = line
  while #log > MAX_LOG do table.remove(log, 1) end
end

local function dlog(text)
  local line = int(now()) .. " " .. tostring(text)
  if not ready then
    if #early < 40 then early[#early + 1] = line end
    return
  end
  writeLog(line)
end

-- ---- storage ----------------------------------------------------------------------------------------------------------

local function salesStore()
  local d = db()
  if type(d.sales) ~= "table" then d.sales = {} end
  local name = realmName()
  if type(d.sales[name]) ~= "table" then d.sales[name] = {} end
  local s = d.sales[name]
  for _, key in ipairs({ "items", "open", "events", "soldSeen", "done", "hints", "names", "mail" }) do
    if type(s[key]) ~= "table" then s[key] = {} end
  end
  return s
end

-- read-only look: nil when nothing was ever saved for this realm (so a lookup never creates tables)
local function peekStore()
  local d = type(KeboldsShinyDB) == "table" and KeboldsShinyDB or nil
  local s = d and type(d.sales) == "table" and d.sales[realmName()] or nil
  return type(s) == "table" and type(s.items) == "table" and s or nil
end

local function me()
  return try(UnitName, "player") or "?"
end

local function itemName(id, link)
  local name = type(link) == "string" and link:match("%[(.-)%]") or nil
  if not name and type(C_Item) == "table" then
    name = try(C_Item.GetItemNameByID, id) or try(C_Item.GetItemInfo, id)
  end
  return type(name) == "string" and name ~= "" and name or nil
end

local function rec(s, id, name)
  local r = s.items[id]
  if type(r) ~= "table" then
    r = { posted = 0, postedQty = 0, sold = 0, soldQty = 0, expired = 0, expiredQty = 0, cancelled = 0, cancelledQty = 0 }
    s.items[id] = r
  end
  name = name or (not r.name and itemName(id)) or nil
  if name then
    r.name = name
    s.names[name] = id
  end
  return r
end

-- One thing that happened to an auction. count is 1 for a whole auction, 0 for part of one (a commodity selling
-- bit by bit must not count as several auctions).
local function event(s, kind, id, qty, unit, src, count, name)
  qty = tonumber(qty) or 1
  local r = rec(s, id, name)
  r[kind] = (r[kind] or 0) + (count or 1)
  r[kind .. "Qty"] = (r[kind .. "Qty"] or 0) + qty
  if kind == "posted" then
    if unit then r.postPrice = unit end
    r.postDay = today()
  elseif kind == "sold" then
    if unit then r.salePrice = unit end
    r.saleDay = today()
  end
  local ev = s.events
  ev[#ev + 1] = table.concat({ int(today()), kind, int(id), int(qty), unit and int(unit) or "", src or "" }, "|")
  while #ev > MAX_EVENTS do table.remove(ev, 1) end
  dlog(string.format("%s item=%s qty=%s unit=%s by=%s%s", kind, int(id), int(qty), unit and int(unit) or "?", src or "?",
    (count == 0) and " (part)" or ""))
end

-- ---- hints: signals that name an item but not an auction -------------------------------------------------------------

local function takeHint(s, kind, name, after, mail)
  for i, h in ipairs(s.hints) do
    if h.kind == kind and h.name == name and (h.src == "mail") == (mail and true or false) and (not after or h.t >= after) then
      table.remove(s.hints, i)
      return h
    end
  end
  return nil
end

local function pruneHints(s)
  local t = now()
  for i = #s.hints, 1, -1 do
    local h = s.hints[i]
    if t - (h.t or 0) > (h.src == "mail" and MAIL_HINT_SECONDS or HINT_SECONDS) then
      dlog("hint unused: " .. tostring(h.kind) .. " " .. tostring(h.name) .. " from " .. tostring(h.src))
      table.remove(s.hints, i)
    end
  end
end

local function remember(s, a, kind, qty, sure)
  local done = s.done
  done[#done + 1] = { item = a.item, name = a.name, kind = kind, qty = qty, unit = a.unit, t = now(), post = a.t, sure = sure and true or false }
  while #done > MAX_DONE do table.remove(done, 1) end
end

-- The auction is over. sure = false marks a guess that a later mail may correct.
local function finish(s, auctionID, kind, src, sure, hintTaken)
  local a = s.open[auctionID]
  if not a then return end
  s.open[auctionID] = nil
  event(s, kind, a.item, a.qty, a.unit, src, 1, a.name)
  remember(s, a, kind, a.qty, sure ~= false)
  -- the chat line about this same auction must not be used again for another one
  if a.name and kind ~= "cancelled" and not hintTaken then takeHint(s, kind, a.name) end
end

-- The owned list can only be trusted when the client has the functions that read it.
local function listWorks()
  return type(AH.GetOwnedAuctions) == "function"
    or (type(AH.GetNumOwnedAuctions) == "function" and type(AH.GetOwnedAuctionInfo) == "function")
end

local function oldestOpen(s, name)
  local best, bestID
  local who = me()
  for id, a in pairs(s.open) do
    if a.name == name and (a.who == who or a.who == nil) and (not best or (a.t or 0) < (best.t or 0)) then
      best, bestID = a, id
    end
  end
  return bestID
end

-- A sale or expiry known by item name only (chat line, notification without an id).
local function nameHint(s, kind, name, src)
  for _, h in ipairs(s.hints) do   -- the chat line and the notification can both report the same thing
    if h.kind == kind and h.name == name and h.src ~= src and h.src ~= "mail" and now() - h.t <= 2 then return end
  end
  for i = #s.done, 1, -1 do        -- or the notification already settled that auction a moment ago
    local e = s.done[i]
    if e.kind == kind and e.name == name and now() - e.t <= 2 and not e.said then
      e.said = true
      return
    end
  end
  if not listWorks() then
    -- no list to settle it later: count it now, against the oldest open auction of that item if one is known
    local id = oldestOpen(s, name)
    if id then
      finish(s, id, kind, src, true)
      s.done[#s.done].said = true
    elseif s.names[name] then
      event(s, kind, s.names[name], 1, nil, src .. "-noqty", 1, name)
    else
      dlog("no item known for '" .. name .. "' (" .. kind .. " by " .. src .. ")")
    end
    return
  end
  s.hints[#s.hints + 1] = { kind = kind, name = name, t = now(), src = src }
  dlog("hint " .. kind .. " '" .. name .. "' by " .. src)
end

-- A mail about a finished auction: confirms what was counted, corrects a guess, or waits for the list.
local function mailHint(s, kind, name)
  local done = s.done
  for i = #done, 1, -1 do
    local e = done[i]
    if e.name == name and e.kind == kind and not e.mailed then
      e.mailed, e.sure = true, true
      return
    end
  end
  for i = #done, 1, -1 do
    local e = done[i]
    if e.name == name and e.kind ~= kind and e.kind ~= "cancelled" and not e.sure and not e.mailed then
      local r = rec(s, e.item)
      r[e.kind] = math.max(0, (r[e.kind] or 0) - 1)
      r[e.kind .. "Qty"] = math.max(0, (r[e.kind .. "Qty"] or 0) - e.qty)
      dlog("mail corrects " .. e.kind .. " to " .. kind .. " for item " .. int(e.item))
      e.kind, e.mailed, e.sure = kind, true, true
      event(s, kind, e.item, e.qty, e.unit, "mail-fix", 1, name)
      return
    end
  end
  s.hints[#s.hints + 1] = { kind = kind, name = name, t = now(), src = "mail" }
  dlog("hint " .. kind .. " '" .. name .. "' by mail")
end

-- ---- posting ----------------------------------------------------------------------------------------------------------

local pending = nil   -- the last post call: what the next "auction created" events are about
local cancelAsked = {}   -- [auctionID] = time a cancel was asked for or reported (this session)

local function onPost(commodity, item, duration, quantity, a, b)
  local id = type(C_Item) == "table" and try(C_Item.GetItemID, item) or nil
  local unit
  if commodity then unit = tonumber(a) else unit = (tonumber(b) or 0) > 0 and tonumber(b) or tonumber(a) end
  if unit and unit <= 0 then unit = nil end
  quantity = tonumber(quantity) or 1
  pending = { item = id, left = quantity, qty = quantity, unit = unit, commodity = commodity, t = now(),
    hours = DURATION_HOURS[tonumber(duration) or 0] }
  dlog(string.format("post call %s item=%s qty=%s unit=%s duration=%s", commodity and "commodity" or "item",
    tostring(id), int(quantity), unit and int(unit) or "?", tostring(duration)))
end

local function onCreated(auctionID)
  if type(auctionID) ~= "number" then
    dlog("created without an auction id: " .. tostring(auctionID))
    return
  end
  local s = salesStore()
  if s.open[auctionID] then return end
  local p = pending
  if not p or now() - p.t > PENDING_SECONDS or not p.item then
    dlog("created " .. int(auctionID) .. ": no post call seen, waiting for the list")
    return
  end
  -- one commodity post is one auction; several of an item are posted one auction each
  local qty = p.commodity and p.qty or 1
  p.left = p.left - qty
  if p.left <= 0 then pending = nil end
  local name = itemName(p.item)
  s.open[auctionID] = { item = p.item, name = name, qty = qty, unit = p.unit, t = now(), who = me(),
    ends = p.hours and (now() + p.hours * 3600) or nil, ok = false }
  event(s, "posted", p.item, qty, p.unit, "hook", 1, name)
end

-- ---- the owned list -----------------------------------------------------------------------------------------------------

local ahOpen = false
local SOLD = (type(Enum) == "table" and type(Enum.AuctionStatus) == "table" and Enum.AuctionStatus.Sold) or 1

local function readOwned()
  local list = try(AH.GetOwnedAuctions)
  if type(list) ~= "table" and type(AH.GetNumOwnedAuctions) == "function" and type(AH.GetOwnedAuctionInfo) == "function" then
    local n = try(AH.GetNumOwnedAuctions)
    if type(n) ~= "number" then return nil end
    list = {}
    for i = 1, n do
      local r = try(AH.GetOwnedAuctionInfo, i)
      if type(r) == "table" then list[#list + 1] = r end
    end
  end
  return type(list) == "table" and list or nil
end

local function unitOf(r)
  local price = tonumber(r.buyoutAmount) or 0
  if price <= 0 then price = tonumber(r.bidAmount) or 0 end
  return price > 0 and price or nil
end

-- An auction that is no longer in the list: decide what became of it.
local function vanished(s, id, a)
  local t = now()
  if cancelAsked[id] or a.hint == "cancelled" then return finish(s, id, "cancelled", cancelAsked[id] and "cancel" or a.hintSrc, true) end
  if a.hint then return finish(s, id, a.hint, a.hintSrc or "notice", true) end
  if a.name then
    for _, kind in ipairs({ "sold", "expired" }) do
      if takeHint(s, kind, a.name, a.t) then return finish(s, id, kind, "chat", true, true) end
    end
  end
  if a.ends and t < a.ends - 60 then return finish(s, id, "sold", "gone-early", true) end   -- it could not have expired yet
  if a.name then
    for _, kind in ipairs({ "sold", "expired" }) do
      if takeHint(s, kind, a.name, a.t, true) then
        finish(s, id, kind, "mail", true)
        s.done[#s.done].mailed = true
        return
      end
    end
  end
  finish(s, id, "expired", "gone-late", false)   -- a guess: it may have sold first; a sale mail corrects it
end

local function diffOwned()
  if not ahOpen then return end
  local list = readOwned()
  if not list then
    dlog("owned list: could not be read")
    return
  end
  local full = true
  if type(AH.HasFullOwnedAuctionResults) == "function" then full = try(AH.HasFullOwnedAuctionResults) and true or false end
  local s = salesStore()
  local who, t = me(), now()
  local active, sold, nActive, nSold = {}, {}, 0, 0
  for _, r in ipairs(list) do
    local id = r.auctionID
    local item = type(r.itemKey) == "table" and r.itemKey.itemID or nil
    if type(id) == "number" and type(item) == "number" then
      if r.status == SOLD then
        sold[id] = r
        nSold = nSold + 1
      else
        active[id] = r
        nActive = nActive + 1
      end
    end
  end
  dlog(string.format("owned list: %d rows, %d active, %d sold, full=%s", #list, nActive, nSold, tostring(full)))

  local counted = {}   -- units of an auction id already counted as sold in this pass
  for id, r in pairs(sold) do
    local item, qty = r.itemKey.itemID, tonumber(r.quantity) or 1
    local seen = s.soldSeen[id]
    local delta = qty - (seen or 0)
    if delta > 0 then
      local a = s.open[id]
      local name = itemName(item, r.itemLink) or (a and a.name)
      if not a and not seen then event(s, "posted", item, delta, nil, "list-late", 1, name) end   -- posted before the addon watched
      -- a Sold row's price is the whole sale; the price the auction was posted at is per unit when we have it
      event(s, "sold", item, delta, (a and a.unit) or (qty == 1 and unitOf(r)) or nil, "list", seen and 0 or 1, name)
      if not seen then remember(s, { item = item, name = name, unit = a and a.unit, t = a and a.t }, "sold", delta, true) end
      if name then takeHint(s, "sold", name) end
      s.soldSeen[id] = qty
      counted[id] = delta
    end
    if s.open[id] and not active[id] then s.open[id] = nil end
  end

  for id, r in pairs(active) do
    local item, qty = r.itemKey.itemID, tonumber(r.quantity) or 1
    local a = s.open[id]
    local name = itemName(item, r.itemLink) or (a and a.name)
    if not a then
      a = { item = item, name = name, qty = qty, unit = unitOf(r), t = t, who = who, ok = true }
      s.open[id] = a
      event(s, "posted", item, qty, a.unit, "list", 1, name)
    elseif not a.ok then
      -- first sight of an auction the post hook recorded: the list is the truth about what was posted
      if a.item ~= item then
        dlog(string.format("auction %s: hook said item %s, list says %s", int(id), tostring(a.item), int(item)))
        local old = rec(s, a.item)
        old.posted, old.postedQty = math.max(0, old.posted - 1), math.max(0, old.postedQty - a.qty)
        a.item, a.name, a.qty = item, name, qty
        event(s, "posted", item, qty, a.unit, "list-fix", 1, name)
      elseif a.qty ~= qty then
        dlog(string.format("auction %s: hook said qty %s, list says %s", int(id), int(a.qty), int(qty)))
        local r2 = rec(s, item)
        r2.postedQty = math.max(0, r2.postedQty + qty - a.qty)
        a.qty = qty
      end
      a.ok, a.who, a.name = true, who, name or a.name
    elseif qty < a.qty then
      local delta = a.qty - qty - (counted[id] or 0)
      if delta > 0 then
        event(s, "sold", item, delta, a.unit, "list-qty", 0, name)
        if name then takeHint(s, "sold", name) end
      end
      a.qty = qty
    end
    a.unit = a.unit or unitOf(r)
    if tonumber(r.timeLeftSeconds) then a.ends = t + r.timeLeftSeconds end
    a.seen = t
  end

  if full then
    local gone = {}
    for id, a in pairs(s.open) do
      if not active[id] and (a.who == who or a.who == nil) then gone[#gone + 1] = id end
    end
    table.sort(gone)
    for _, id in ipairs(gone) do vanished(s, id, s.open[id]) end
    for id in pairs(s.soldSeen) do
      if not sold[id] then s.soldSeen[id] = nil end
    end
  end
  pruneHints(s)
end

local diffQueued = false
local function queueDiff()
  if diffQueued then return end
  if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return diffOwned() end
  diffQueued = true
  -- a short wait gathers a burst of updates, and skips a list emptied by the window closing
  C_Timer.After(0.5, function()
    diffQueued = false
    local ok, err = pcall(diffOwned)
    if not ok then dlog("ERROR owned list: " .. tostring(err)) end
  end)
end

-- Ask for the owned list once per visit, as opening the Auctions tab does. Skipped while a price scan runs.
local function askOwned(tries)
  if not ahOpen or db().salesAuto == false then return end
  if type(AH.QueryOwnedAuctions) ~= "function" then
    dlog("no QueryOwnedAuctions: the list is only read when the Auctions tab asks for it")
    return
  end
  local busy = type(KeboldsShinyScan_Busy) == "function" and try(KeboldsShinyScan_Busy)
  local clear = type(AH.IsThrottledMessageSystemReady) ~= "function" or try(AH.IsThrottledMessageSystemReady)
  if busy or not clear then
    if tries < 10 and type(C_Timer) == "table" and C_Timer.After then
      C_Timer.After(3, function() askOwned(tries + 1) end)
    else
      dlog("owned list not asked for: the auction house stayed busy")
    end
    return
  end
  local order = type(Enum) == "table" and type(Enum.AuctionHouseSortOrder) == "table" and Enum.AuctionHouseSortOrder.TimeRemaining or 5
  local ok, err = pcall(AH.QueryOwnedAuctions, { { sortOrder = order, reverseSort = false } })
  dlog(ok and "asked for the owned list" or ("ERROR QueryOwnedAuctions: " .. tostring(err)))
end

-- ---- chat, notifications, mail ----------------------------------------------------------------------------------------

local patterns = nil
local function pattern(global, fallback)
  local text = type(_G[global]) == "string" and _G[global] or fallback
  if not text then return nil end
  text = text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", "(.+)")
  return "^" .. text .. "$"
end

local function chatPatterns()
  if not patterns then
    patterns = {
      sold = pattern("ERR_AUCTION_SOLD_S", "A buyer has been found for your auction of %s."),
      expired = pattern("ERR_AUCTION_EXPIRED_S", "Your auction of %s has expired."),
      cancelled = pattern("ERR_AUCTION_REMOVED_S", nil),
      mailExpired = pattern("AUCTION_EXPIRED_MAIL_SUBJECT", "Auction expired: %s"),
    }
  end
  return patterns
end

local function matchText(text)
  local p = chatPatterns()
  for _, kind in ipairs({ "sold", "expired", "cancelled" }) do
    local name = p[kind] and text:match(p[kind])
    if name then return kind, name end
  end
  return nil
end

local function onChat(text)
  if type(text) ~= "string" then return end
  local kind, name = matchText(text)
  if kind == "sold" or kind == "expired" then
    nameHint(salesStore(), kind, name, "chat")
  elseif text:lower():find("auction", 1, true) then
    dlog("chat: " .. text:sub(1, 120))   -- so a wording this client uses and we do not know shows up
  end
end

local NOTICE = { [1] = "cancelled", [4] = "sold", [5] = "expired" }   -- Enum.AuctionHouseNotification, documented values
local function noticeKind(n)
  local e = type(Enum) == "table" and Enum.AuctionHouseNotification or nil
  if type(e) == "table" then
    if n == e.AuctionSold then return "sold" end
    if n == e.AuctionExpired then return "expired" end
    if n == e.AuctionRemoved then return "cancelled" end
    return nil
  end
  return NOTICE[n]
end

local function onNotice(notification, text, auctionID)
  local kind = noticeKind(notification)
  dlog(string.format("notice %s (%s) id=%s text=%s", tostring(notification), tostring(kind), tostring(auctionID), tostring(text):sub(1, 80)))
  if not kind then return end
  local s = salesStore()
  local a = type(auctionID) == "number" and s.open[auctionID] or nil
  if a then
    if kind == "sold" and listWorks() then
      -- a commodity can sell in parts, so the list decides how much went; this marks what to call it
      a.hint, a.hintSrc = "sold", "notice"
    else
      finish(s, auctionID, kind, "notice", true)
    end
    return
  end
  if kind == "cancelled" then
    if type(auctionID) == "number" then cancelAsked[auctionID] = now() end
    return
  end
  local k2, name = nil, nil
  if type(text) == "string" then k2, name = matchText(text) end
  if name and k2 == kind then nameHint(s, kind, name, "notice") end
end

local function onCanceled(auctionID)
  dlog("cancel event id=" .. tostring(auctionID))
  if type(auctionID) ~= "number" then return end
  local s = salesStore()
  if s.open[auctionID] then
    finish(s, auctionID, "cancelled", "event", true)
  else
    cancelAsked[auctionID] = now()
  end
end

-- The mailbox as it stands: how many sale invoices and "expired" mails there are per item. A count that went up
-- since the last look is new mail. Only headers and invoices are read; nothing is opened or taken.
local function readMail()
  if type(GetInboxNumItems) ~= "function" then return end
  local n = try(GetInboxNumItems)
  if type(n) ~= "number" then return end
  local s = salesStore()
  local who = me()
  local before = type(s.mail[who]) == "table" and s.mail[who] or {}
  local counts = {}
  local p = chatPatterns()
  for i = 1, n do
    local kind, name
    local invoice, item = try(GetInboxInvoiceInfo, i)
    if invoice == "seller" and type(item) == "string" then
      kind, name = "sold", item
    else
      local _, _, _, subject = try(GetInboxHeaderInfo, i)
      if type(subject) == "string" and p.mailExpired then
        name = subject:match(p.mailExpired)
        if name then
          kind = "expired"
          name = name:gsub("%s*%(%d+%)$", "")   -- a stack's subject can end in "(20)"
        end
      end
    end
    if kind then
      local key = kind .. "|" .. name
      counts[key] = (counts[key] or 0) + 1
    end
  end
  for key, count in pairs(counts) do
    local kind, name = key:match("^(%a+)|(.+)$")
    for _ = 1, count - (before[key] or 0) do mailHint(s, kind, name) end
  end
  s.mail[who] = counts
end

-- ---- public: sales ------------------------------------------------------------------------------------------------------

KeboldsShinySales = {}

function KeboldsShinySales.rate(itemID)
  local s = peekStore()
  local r = s and s.items[itemID]
  if type(r) ~= "table" then return nil end
  local expired, auctions = r.expiredQty or 0, (r.sold or 0) + (r.expired or 0)
  -- an "expired" that is only a guess (the auction was gone after its time, with no word from the game) may be a
  -- sale made while offline: it waits for its mail and is left out of the share until then
  for _, e in ipairs(type(s.done) == "table" and s.done or {}) do
    if e.item == itemID and e.kind == "expired" and not e.sure then
      expired, auctions = expired - (e.qty or 0), auctions - 1
    end
  end
  if expired < 0 then expired = 0 end
  local units = (r.soldQty or 0) + expired
  if units <= 0 then return nil end
  return (r.soldQty or 0) / units, units, auctions
end

function KeboldsShinySales.askOwned() askOwned(0) end

function KeboldsShinySales.summary(itemID)
  local s = peekStore()
  local r = s and s.items[itemID]
  if type(r) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(r) do out[k] = v end
  for kind in pairs(KINDS) do
    out[kind] = out[kind] or 0
    out[kind .. "Qty"] = out[kind .. "Qty"] or 0
  end
  out.open, out.openQty = 0, 0
  if type(s.open) == "table" then
    for _, a in pairs(s.open) do
      if a.item == itemID then out.open, out.openQty = out.open + 1, out.openQty + (a.qty or 0) end
    end
  end
  out.finished = out.soldQty + out.expiredQty
  out.rate = out.finished > 0 and out.soldQty / out.finished or nil
  return out
end

function KeboldsShinySales.events(itemID)
  local s = peekStore()
  local out = {}
  if not s or type(s.events) ~= "table" then return out end
  for i = #s.events, 1, -1 do
    local day, kind, item, qty, unit, src = tostring(s.events[i]):match("^(%d+)|(%a+)|(%d+)|(%d+)|(%d*)|(.*)$")
    if day and (itemID == nil or tonumber(item) == itemID) then
      out[#out + 1] = { day = tonumber(day), kind = kind, item = tonumber(item), qty = tonumber(qty), unit = tonumber(unit), src = src }
    end
  end
  return out
end

-- Every item ever posted, for Kebold's Sales tab: summary() of each with its id and name, the items with the
-- most finished units first.
function KeboldsShinySales.items()
  local s = peekStore()
  local out = {}
  if not s then return out end
  for id in pairs(s.items) do
    local x = KeboldsShinySales.summary(id)
    if x then
      out[#out + 1] = { id = id, name = x.name or ("item " .. tostring(id)), posted = x.posted, postedQty = x.postedQty, sold = x.sold, soldQty = x.soldQty,
        expired = x.expired, expiredQty = x.expiredQty, cancelled = x.cancelled, cancelledQty = x.cancelledQty, open = x.open, openQty = x.openQty,
        finished = x.finished, rate = x.rate, salePrice = x.salePrice, saleDay = x.saleDay }
    end
  end
  table.sort(out, function(a, b)
    if a.finished ~= b.finished then return a.finished > b.finished end
    if a.name ~= b.name then return a.name < b.name end
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

-- ---- public: price history ------------------------------------------------------------------------------------------------

KeboldsShinyHistory = {}

local function scanStore()
  local d = type(KeboldsShinyDB) == "table" and KeboldsShinyDB or nil
  local store = d and type(d.realms) == "table" and d.realms[realmName()] or nil
  return type(store) == "table" and store or nil
end

local function parseHist(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for day, low, qty in text:gmatch("(%d+):(%d+):(%d+)") do
    out[#out + 1] = { day = tonumber(day), low = tonumber(low), qty = tonumber(qty) }
  end
  return out
end

-- One reading per item and day; a later scan on the same day replaces it. store is the scan's realm table.
function KeboldsShinyHistory.record(store, itemID, day, low, qty)
  store = type(store) == "table" and store or scanStore()
  if not store or type(itemID) ~= "number" or type(day) ~= "number" then return end
  if type(store.hist) ~= "table" then store.hist = {} end
  local list = parseHist(store.hist[itemID])
  for i = #list, 1, -1 do
    if list[i].day == day then table.remove(list, i) end
  end
  list[#list + 1] = { day = day, low = floor(tonumber(low) or 0), qty = floor(tonumber(qty) or 0) }
  table.sort(list, function(a, b) return a.day < b.day end)
  local parts = {}
  for i = math.max(1, #list - MAX_DAYS + 1), #list do
    parts[#parts + 1] = int(list[i].day) .. ":" .. int(list[i].low) .. ":" .. int(list[i].qty)
  end
  store.hist[itemID] = table.concat(parts, ",")
end

-- The ids of the items that have readings, in order.
function KeboldsShinyHistory.items()
  local store = scanStore()
  local out = {}
  if store and type(store.hist) == "table" then
    for id, text in pairs(store.hist) do
      if type(id) == "number" and type(text) == "string" and text ~= "" then out[#out + 1] = id end
    end
  end
  table.sort(out)
  return out
end

function KeboldsShinyHistory.readings(itemID)
  local store = scanStore()
  return parseHist(store and type(store.hist) == "table" and store.hist[itemID] or nil)
end

function KeboldsShinyHistory.median(itemID)
  local lows = {}
  for _, r in ipairs(KeboldsShinyHistory.readings(itemID)) do
    if r.low > 0 then lows[#lows + 1] = r.low end
  end
  local n = #lows
  if n == 0 then return nil, 0 end
  table.sort(lows)
  if n % 2 == 1 then return lows[(n + 1) / 2], n end
  return floor((lows[n / 2] + lows[n / 2 + 1]) / 2 + 0.5), n
end

function KeboldsShinyHistory.drop(itemID)
  local list = KeboldsShinyHistory.readings(itemID)
  local last = list[#list]
  if not last or last.low <= 0 then return nil end
  local med, n = KeboldsShinyHistory.median(itemID)
  if not med or n < DROP_MIN_DAYS or med <= 0 then return nil end
  local share = (med - last.low) / med
  if share >= DROP_SHARE then return share, last.low, med end
  return nil
end

-- ---- commands -----------------------------------------------------------------------------------------------------------

local function coin(v)
  if not v then return "?" end
  v = floor(v + 0.5)
  local g, s, c = floor(v / 10000), floor(v / 100) % 100, v % 100
  if g > 0 then return g .. "g " .. s .. "s" end
  if s > 0 then return s .. "s " .. c .. "c" end
  return c .. "c"
end

local function printTable(filter)
  local s = peekStore()
  local rows = {}
  if s then
    for id, r in pairs(s.items) do
      local name = r.name or itemName(id) or ("item " .. int(id))
      if not filter or name:lower():find(filter, 1, true) then
        rows[#rows + 1] = { id = id, name = name, r = r, fin = (r.soldQty or 0) + (r.expiredQty or 0) }
      end
    end
  end
  if #rows == 0 then
    say(filter and ("No tracked auctions match '" .. filter .. "'.") or "No auctions tracked yet. Post something, or open the Auctions tab at the auction house.")
    return
  end
  table.sort(rows, function(a, b)
    if a.fin ~= b.fin then return a.fin > b.fin end
    return a.name < b.name
  end)
  say("Your auctions, in units (auctions): posted / sold / expired / cancelled, sold share")
  for i, row in ipairs(rows) do
    if i > 40 then
      say("... and " .. (#rows - 40) .. " more; add part of a name to narrow it down.")
      break
    end
    local r = row.r
    local share = KeboldsShinySales.rate(row.id)
    say(string.format("%s: %d (%d) / %d (%d) / %d (%d) / %d (%d), %s%s", row.name, r.postedQty or 0, r.posted or 0, r.soldQty or 0, r.sold or 0,
      r.expiredQty or 0, r.expired or 0, r.cancelledQty or 0, r.cancelled or 0,
      share and (floor(share * 100 + 0.5) .. "% sold") or "none finished",
      r.salePrice and (", last sale " .. coin(r.salePrice)) or ""))
  end
end

local function printLog(count)
  local log = type(KeboldsShinyDB) == "table" and KeboldsShinyDB.salesLog or nil
  if type(log) ~= "table" or #log == 0 then
    say("The log is empty.")
    return
  end
  for i = math.max(1, #log - count + 1), #log do
    print("|cffffcc66LS|r " .. (tostring(log[i]):gsub("|", "||")))
  end
  say(#log .. " lines in the log; /reload writes it to the saved file.")
end

SLASH_KEBOLDSSHINYSALES1 = "/keboldsales"
SLASH_KEBOLDSSHINYSALES2 = "/ledgersales"   -- the name before the addon was renamed
SlashCmdList["KEBOLDSSHINYSALES"] = function(msg)
  local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
  if cmd == "" then
    printTable(nil)
  elseif cmd == "log" or cmd:find("^log%s+%d+$") then
    printLog(tonumber(cmd:match("%d+")) or 30)
  elseif cmd == "auto on" or cmd == "auto off" then
    db().salesAuto = cmd == "auto on"
    say(cmd == "auto on" and "The list of your auctions is asked for each time the auction house opens."
      or "The list of your auctions is only read when you open the Auctions tab yourself.")
  elseif cmd == "help" then
    say("Usage: /keboldsales [part of an item name | log [lines] | auto on | auto off]")
  else
    printTable(cmd)
  end
end

-- ---- events -------------------------------------------------------------------------------------------------------------

local handlers = {}

function handlers.PLAYER_LOGIN() end   -- only there to open the log (see below)

function handlers.AUCTION_HOUSE_SHOW()
  ahOpen = true
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    C_Timer.After(2, function() askOwned(0) end)
  end
end

function handlers.AUCTION_HOUSE_CLOSED()
  ahOpen = false
end

handlers.AUCTION_HOUSE_AUCTION_CREATED = onCreated
handlers.OWNED_AUCTIONS_UPDATED = queueDiff
handlers.AUCTION_CANCELED = onCanceled
handlers.AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION = onNotice
handlers.CHAT_MSG_SYSTEM = onChat
handlers.MAIL_INBOX_UPDATE = readMail

local missing = {}
if type(CreateFrame) == "function" then
  local frame = CreateFrame("Frame")
  frame:SetScript("OnEvent", function(_, ev, ...)
    if not ready then
      ready = true
      for _, line in ipairs(early) do writeLog(line) end
      early = {}
    end
    local ok, err = pcall(handlers[ev], ...)
    if not ok then dlog("ERROR in " .. tostring(ev) .. ": " .. tostring(err)) end
  end)
  for name in pairs(handlers) do
    -- registering a name the client does not know raises an error
    if not pcall(frame.RegisterEvent, frame, name) then missing[#missing + 1] = name end
  end
end

-- Post-hooks run after Blizzard's own function and cannot change or block it.
local hooked = {}
local function hook(name, fn)
  if type(hooksecurefunc) == "function" and type(AH[name]) == "function" and pcall(hooksecurefunc, AH, name, fn) then
    hooked[#hooked + 1] = name
  end
end
local function guard(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then dlog("ERROR in a hook: " .. tostring(err)) end
  end
end
hook("PostItem", guard(function(item, duration, quantity, bid, buyout) onPost(false, item, duration, quantity, bid, buyout) end))
hook("ConfirmPostItem", guard(function(item, duration, quantity, bid, buyout) onPost(false, item, duration, quantity, bid, buyout) end))
hook("PostCommodity", guard(function(item, duration, quantity, unitPrice) onPost(true, item, duration, quantity, unitPrice) end))
hook("ConfirmPostCommodity", guard(function(item, duration, quantity, unitPrice) onPost(true, item, duration, quantity, unitPrice) end))
hook("CancelAuction", guard(function(auctionID)
  if type(auctionID) == "number" then cancelAsked[auctionID] = now() end
  dlog("cancel call id=" .. tostring(auctionID))
end))

-- What this client offers, once per session, so a part that stays silent can be told from a part that is absent.
do
  table.sort(missing)
  local have = {}
  for _, name in ipairs({ "GetOwnedAuctions", "GetNumOwnedAuctions", "GetOwnedAuctionInfo", "HasFullOwnedAuctionResults", "QueryOwnedAuctions" }) do
    if type(AH[name]) == "function" then have[#have + 1] = name end
  end
  local strings = {}
  for _, name in ipairs({ "ERR_AUCTION_SOLD_S", "ERR_AUCTION_EXPIRED_S", "ERR_AUCTION_REMOVED_S", "AUCTION_EXPIRED_MAIL_SUBJECT" }) do
    if type(_G[name]) == "string" then strings[#strings + 1] = name end
  end
  dlog("session: hooks [" .. table.concat(hooked, " ") .. "] list calls [" .. table.concat(have, " ") .. "] missing events ["
    .. table.concat(missing, " ") .. "] texts [" .. table.concat(strings, " ") .. "] mail "
    .. ((type(GetInboxNumItems) == "function" and type(GetInboxInvoiceInfo) == "function") and "yes" or "no"))
end
