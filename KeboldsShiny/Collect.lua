-- KeboldsShiny collector
-- Read-only, always on. Saves what the game itself shows about professions, so Kebold works from Forever's own
-- data instead of lists scraped from web sites:
--   * every recipe of a profession window you open, learned or not: reagents, item made, how many, skill colour
--   * every service of a trainer you talk to: what is taught, at which skill, for how much
--   * every item of a vendor you open: price and stack
--   * the vendor value of every item in those recipes
--   * your Legacy talent ranks
-- It buys, learns and crafts nothing. Saved under KeboldsShinyDB.collect.
--
--   /keboldcollect          what has been collected so far
--   /keboldcollect legacy   read your Legacy talent ranks now (they are also read by themselves every few minutes)
--   /keboldcollect off|on   stop or resume collecting
--   /keboldcollect chat on|off   a chat line for every profession, trainer and vendor read (off unless switched on;
--                           saved under KeboldsShinyDB.collect.chat)

local POLL = 1.0            -- seconds between checks for an open trainer window and pending work
local ITEMS_PER_TICK = 40   -- item lookups per check
local RECIPE_WAIT = 1.0     -- seconds after the last profession event before the recipe list is read
local REREAD_AFTER = 30     -- seconds before the same profession's list is read again
local ITEM_TRIES = 90       -- checks before an item that will not load is given up on
local LEGACY_EVERY = 300    -- seconds between quiet re-reads of the Legacy talents

local T = C_TradeSkillUI
local enabled = true
local recipeDue = nil       -- time at which the open profession's recipes are read
local itemQueue, itemQueued = {}, {}
local lastTrainer, lastMerchant = nil, nil
local warned, lastRead = {}, {}
local legacyAt = nil
local recipeForce = false   -- a recipe was just learned: read the list again whatever the half-minute rule says
local guarded, probeOnce    -- defined further down

local function say(msg)
  print("|cff66ccffKeboldCollect|r " .. msg)
end
local store
-- A line about something read in passing (a profession, a trainer, a vendor): only with /keboldcollect chat on.
local function note(msg)
  if store().chat == true then say(msg) end
end

function store()
  if type(KeboldsShinyDB) ~= "table" then KeboldsShinyDB = {} end
  local c = KeboldsShinyDB.collect
  if type(c) ~= "table" then
    c = {}
    KeboldsShinyDB.collect = c
  end
  c.v = 1
  for _, key in ipairs({ "recipes", "trainers", "merchants", "items", "probe" }) do
    if type(c[key]) ~= "table" then c[key] = {} end
  end
  return c
end

-- One clean field of a "|"-separated record: no separators, colour codes or line breaks.
local function field(v)
  if v == nil then return "" end
  if type(v) == "boolean" then return v and "1" or "0" end
  local s = tostring(v)
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " "):gsub("[|\r\n]", " ")
  return s
end

local function num(v)
  if type(v) ~= "number" then return "" end
  return string.format("%.0f", v)
end

-- Calls fn in pcall and returns its results, or nothing on error. Missing functions are simply skipped.
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local function pass(ok, ...)
    if ok then return ... end
    return nil
  end
  return pass(pcall(fn, ...))
end

local function queueItem(id)
  if type(id) == "number" and id > 0 and not itemQueued[id] then
    itemQueued[id] = true
    itemQueue[#itemQueue + 1] = id
  end
end

-- Where the player stands: "zone name;map id;x;y" with x and y in percent of the map.
local function place()
  local mapID = C_Map and try(C_Map.GetBestMapForUnit, "player")
  local name, x, y = "", "", ""
  if mapID then
    local info = try(C_Map.GetMapInfo, mapID)
    if type(info) == "table" then name = info.name or "" end
    local pos = try(C_Map.GetPlayerMapPosition, mapID, "player")
    if type(pos) == "table" and type(pos.GetXY) == "function" then
      local px, py = try(pos.GetXY, pos)
      if type(px) == "number" and type(py) == "number" then
        x, y = string.format("%.1f", px * 100), string.format("%.1f", py * 100)
      end
    end
  end
  return field(name) .. ";" .. num(mapID) .. ";" .. x .. ";" .. y
end

-- The NPC being talked to: its id (the sixth part of its GUID), name and where the player stands.
local function npc()
  local guid = try(UnitGUID, "npc")
  local id = type(guid) == "string" and tonumber((select(6, strsplit("-", guid)))) or nil
  return id, field((try(UnitName, "npc"))), place()
end

local function playerLine()
  local faction = try(UnitFactionGroup, "player")
  return field(faction) .. ";" .. num(try(UnitLevel, "player")) .. ";" .. field(try(GetRealmName))
end

-- ---- recipes -----------------------------------------------------------------------------------------------

-- "name|item made|min made|max made|learned|difficulty|grey at|skill-ups|type|reagents|source|category"
-- difficulty: 0 orange, 1 yellow, 2 green, 3 grey. reagents: "itemID:count,itemID:count".
local function recipeLine(id)
  local info = try(T.GetRecipeInfo, id)
  if type(info) ~= "table" then return nil end
  local schem = try(T.GetRecipeSchematic, id, false)
  local made, qmin, qmax, rtype, reagents = "", "", "", "", {}
  if type(schem) == "table" then
    made, qmin, qmax, rtype = num(schem.outputItemID), num(schem.quantityMin), num(schem.quantityMax), num(schem.recipeType)
    queueItem(schem.outputItemID)
    if type(schem.reagentSlotSchematics) == "table" then
      for _, slot in ipairs(schem.reagentSlotSchematics) do
        local first = type(slot.reagents) == "table" and slot.reagents[1] or nil
        -- Basic reagents only (type 1); optional and finishing slots are not part of the recipe's cost
        if type(first) == "table" and first.itemID and slot.reagentType == 1 then
          reagents[#reagents + 1] = num(first.itemID) .. ":" .. num(slot.quantityRequired)
          queueItem(first.itemID)
        end
      end
    end
  end
  local source = try(T.GetRecipeSourceText, id)
  return table.concat({ field(info.name), made, qmin, qmax, field(info.learned and true or false),
    num(info.relativeDifficulty), num(info.maxTrivialLevel), num(info.numSkillUps), rtype,
    table.concat(reagents, ","), field(source), num(info.categoryID) }, "|"), info.learned and true or false
end

local function collectRecipes(force)
  if type(T) ~= "table" or not try(T.IsTradeSkillReady) then return end
  if try(T.IsTradeSkillLinked) or try(T.IsTradeSkillGuild) or try(T.IsNPCCrafting) then return end   -- someone else's list
  local prof = try(T.GetBaseProfessionInfo)
  if type(prof) ~= "table" or not prof.professionName or prof.professionName == "" then return end
  -- the list event fires after every craft; one read of a profession per half minute is plenty
  if not force and lastRead[prof.professionName] and GetTime() - lastRead[prof.professionName] < REREAD_AFTER then return end
  lastRead[prof.professionName] = GetTime()
  local ids = try(T.GetAllRecipeIDs)
  if type(ids) ~= "table" or #ids == 0 then return end
  local list, n, learned = {}, 0, 0
  for _, id in ipairs(ids) do
    local line, known = recipeLine(id)
    if line then
      list[id] = line
      n = n + 1
      if known then learned = learned + 1 end
    end
  end
  local c = store()
  local old = c.recipes[prof.professionName]
  c.recipes[prof.professionName] = {
    id = prof.professionID, skill = prof.skillLevel, max = prof.maxSkillLevel, time = time(), player = playerLine(), list = list,
    who = (function()   -- whose list this is: Kebold only counts its recipes as known on this character
      local n = try(UnitName, "player")
      return type(n) == "string" and n ~= "" and (n .. "-" .. tostring(try(GetRealmName) or "")) or nil
    end)(),
  }
  if not old or old.n ~= n then
    note(string.format("%s: %d recipes saved (%d of them learned).", prof.professionName, n, learned))
  end
  c.recipes[prof.professionName].n = n
  guarded("the recipe probe", probeOnce)
end

-- ---- trainers ----------------------------------------------------------------------------------------------

-- One line per service: "name|kind|skill needed|skill value|cost|level needed|taught spell or item id|skill line|link"
local function collectTrainer()
  if type(GetNumTrainerServices) ~= "function" then return end
  if not try(IsTradeskillTrainer) then return end   -- class and riding trainers are not Kebold's business
  local id, name, where = npc()
  if not id then return end
  -- The list honours the window's three filters; show everything while reading, then put the filters back.
  -- The filters are only touched when all three could be read as on / off first: a filter whose setting is not
  -- known could not be put back. The list is then read as the window shows it and marked `partial` (it may leave
  -- recipes out, so it does not count as "everything this trainer teaches").
  local kinds, before = { "available", "unavailable", "used" }, {}
  local switch, partial = false, false
  if type(GetTrainerServiceTypeFilter) == "function" and type(SetTrainerServiceTypeFilter) == "function" then
    switch = true
    for _, kind in ipairs(kinds) do
      local ok, value = pcall(GetTrainerServiceTypeFilter, kind)
      if ok and type(value) == "boolean" then before[kind] = value else switch = false end
    end
    if switch then
      for _, kind in ipairs(kinds) do pcall(SetTrainerServiceTypeFilter, kind, true) end
    else
      partial = not (before.available == true and before.unavailable == true and before.used == true)
    end
  end
  local n, lines = 0, {}
  -- read inside pcall: whatever happens in between, the filters are put back
  local readOK = pcall(function()
    n = try(GetNumTrainerServices) or 0
    for i = 1, n do
      local serviceName, kind = try(GetTrainerServiceInfo, i)
      local skillName, skillValue = try(GetTrainerServiceSkillReq, i)
      local cost = try(GetTrainerServiceCost, i)
      local level = try(GetTrainerServiceLevelReq, i)
      local taught = ""
      if C_TooltipInfo and C_TooltipInfo.GetTrainerService then
        local tip = try(C_TooltipInfo.GetTrainerService, i)
        if type(tip) == "table" then taught = num(tip.type) .. ":" .. num(tip.id) end
      end
      lines[#lines + 1] = table.concat({ field(serviceName), field(kind), field(skillName), num(skillValue), num(cost),
        num(level), taught, field(try(GetTrainerServiceSkillLine, i)), field(try(GetTrainerServiceItemLink, i)) }, "|")
    end
  end)
  if switch then
    for _, kind in ipairs(kinds) do pcall(SetTrainerServiceTypeFilter, kind, before[kind]) end
  end
  if not readOK or n == 0 then return end
  local c = store()
  local isNew = c.trainers[id] == nil
  c.trainers[id] = {
    name = name, where = where, time = time(), player = playerLine(),
    tradeskill = try(IsTradeskillTrainer) and true or false, ranks = field(table.concat({ tostringall(try(GetTrainerTradeskillRankValues)) }, ",")),
    list = lines, partial = partial or nil,
  }
  if isNew then note(string.format("Trainer %s: %d services saved.", name, n)) end
end

-- ---- vendors -----------------------------------------------------------------------------------------------

-- One line per item: "itemID|price for the stack|stack size|number available (-1 unlimited)|name|other cost"
local function collectMerchant()
  if type(GetMerchantNumItems) ~= "function" then return end
  local id, name, where = npc()
  if not id then return end
  local n = try(GetMerchantNumItems) or 0
  if n == 0 then return end
  local lines = {}
  for i = 1, n do
    local itemID = try(GetMerchantItemID, i)
    local info = C_MerchantFrame and try(C_MerchantFrame.GetItemInfo, i)
    if type(info) == "table" then
      lines[#lines + 1] = table.concat({ num(itemID), num(info.price), num(info.stackCount), num(info.numAvailable),
        field(info.name), field(info.hasExtendedCost and true or false) }, "|")
      queueItem(itemID)
    end
  end
  local c = store()
  local isNew = c.merchants[id] == nil
  c.merchants[id] = { name = name, where = where, time = time(), player = playerLine(), list = lines }
  if isNew then note(string.format("Vendor %s: %d items saved.", name, #lines)) end
end

-- ---- items -------------------------------------------------------------------------------------------------

-- "name|quality|vendor value|stack size|class|subclass|bind type", read once the client has the item loaded.
local function workItems()
  if #itemQueue == 0 or not (C_Item and C_Item.GetItemInfo) then return end
  local c = store()
  local keep, done = {}, 0
  for i, id in ipairs(itemQueue) do
    if done >= ITEMS_PER_TICK then
      keep[#keep + 1] = id
    else
      done = done + 1
      local name, _, quality, _, _, _, _, stack, _, _, sell, classID, subclassID, bind = try(C_Item.GetItemInfo, id)
      if name then
        c.items[id] = table.concat({ field(name), num(quality), num(sell), num(stack), num(classID), num(subclassID), num(bind) }, "|")
        -- the same vendor value the scans keep, so Kebold uses it straight away
        if type(sell) == "number" and type(KeboldsShinyScan_NoteSell) == "function" then pcall(KeboldsShinyScan_NoteSell, id, sell) end
      else
        -- not loaded yet: asking makes the client fetch it; tried again a few times, then dropped
        warned[id] = (warned[id] or 0) + 1
        if warned[id] <= ITEM_TRIES then
          if C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
          keep[#keep + 1] = id
        end
      end
    end
  end
  itemQueue = keep
end

-- ---- Legacy talents --------------------------------------------------------------------------------------

-- The Legacy window is three ordinary trait trees (LegacyTreeData: Professions, Adventure, Resourcefulness), so
-- ranks are read with the trait functions and the window does not need to be open.
-- One line per talent: "tree|node id|name|rank|max rank|spell id|description"
local LEGACY_FALLBACK = { { name = "Professions", treeID = 1187 }, { name = "Adventure", treeID = 1188 }, { name = "Resourcefulness", treeID = 1189 } }

local function collectLegacy(loud)
  if not C_Traits then return end
  local trees = type(LegacyTreeData) == "table" and LegacyTreeData[1] and LegacyTreeData or LEGACY_FALLBACK
  local lines, spent = {}, 0
  for _, tree in ipairs(trees) do
    local treeID = type(tree) == "table" and tree.treeID or nil
    local configID = treeID and try(C_Traits.GetConfigIDByTreeID, treeID)
    local nodes = treeID and try(C_Traits.GetTreeNodes, treeID)
    if configID and type(nodes) == "table" then
      for _, nodeID in ipairs(nodes) do
        local node = try(C_Traits.GetNodeInfo, configID, nodeID)
        if type(node) == "table" and node.ID and node.ID ~= 0 then
          local entryID = (type(node.activeEntry) == "table" and node.activeEntry.entryID) or (type(node.entryIDs) == "table" and node.entryIDs[1]) or nil
          local entry = entryID and try(C_Traits.GetEntryInfo, configID, entryID)
          local def = type(entry) == "table" and entry.definitionID and try(C_Traits.GetDefinitionInfo, entry.definitionID) or nil
          local spellID = type(def) == "table" and (def.spellID or def.overriddenSpellID) or nil
          local name = type(def) == "table" and def.overrideName or nil
          if (not name or name == "") and spellID and C_Spell then name = try(C_Spell.GetSpellName, spellID) end
          local text = type(def) == "table" and def.overrideDescription or nil
          if (not text or text == "") and spellID and C_Spell then text = try(C_Spell.GetSpellDescription, spellID) end
          local rank = node.ranksPurchased or node.currentRank or 0
          spent = spent + (type(rank) == "number" and rank or 0)
          lines[#lines + 1] = table.concat({ field(tree.name), num(nodeID), field(name), num(rank), num(node.maxRanks),
            num(spellID), field(text) }, "|")
        end
      end
    else
      lines[#lines + 1] = table.concat({ field(type(tree) == "table" and tree.name or "?"), "", "no config or nodes", "", "", "",
        "config=" .. tostring(configID) .. " nodes=" .. type(nodes) }, "|")
    end
  end
  local c = store()
  c.legacy = { time = time(), player = playerLine(), list = lines }
  if loud then say(string.format("Legacy talents: %d read, %d ranks bought.", #lines, spent)) end
end

-- ---- can recipes be read without opening their profession? (decides how much data must be shipped) ----------

function probeOnce()
  local c = store()
  if c.probe.done then return end
  c.probe.done = true
  local out = {}
  local function note(label, ...)
    local parts = {}
    for i = 1, select("#", ...) do
      local v = select(i, ...)
      parts[i] = type(v) == "table" and "table" or tostring(v)
    end
    out[#out + 1] = label .. " = " .. table.concat(parts, ", ")
  end
  if type(T) == "table" then
    -- Bolt of Linen Cloth (Tailoring) and Minor Healing Potion (Alchemy): original-game spell ids
    for _, id in ipairs({ 2963, 2330 }) do
      local info = try(T.GetRecipeInfo, id)
      note("GetRecipeInfo " .. id, info and info.name, info and info.learned, info and info.maxTrivialLevel)
      local schem = try(T.GetRecipeSchematic, id, false)
      note("GetRecipeSchematic " .. id, schem and schem.outputItemID, schem and schem.reagentSlotSchematics and #schem.reagentSlotSchematics)
      note("GetTradeSkillLineForRecipe " .. id, try(T.GetTradeSkillLineForRecipe, id))
      note("IsRecipeProfessionLearned " .. id, try(T.IsRecipeProfessionLearned, id))
    end
    local lines = try(T.GetAllProfessionTradeSkillLines)
    note("GetAllProfessionTradeSkillLines", type(lines) == "table" and table.concat(lines, " ") or lines)
    for _, line in ipairs({ 197, 171, 333, 165 }) do
      local info = try(T.GetProfessionInfoBySkillLineID, line)
      note("GetProfessionInfoBySkillLineID " .. line, info and info.professionName, info and info.skillLevel, info and info.maxSkillLevel)
    end
  end
  c.probe.lines = out
end

-- ---- wiring ------------------------------------------------------------------------------------------------

function guarded(label, fn)
  local ok, err = pcall(fn)
  if not ok and not warned[label] then
    warned[label] = true
    say("Problem while reading " .. label .. ": " .. tostring(err))
  end
end

local frame = CreateFrame("Frame")
local handlers = {}

local function recipesSoon()
  recipeDue = GetTime() + RECIPE_WAIT
end
handlers.TRADE_SKILL_SHOW = recipesSoon
handlers.TRADE_SKILL_LIST_UPDATE = recipesSoon
handlers.TRADE_SKILL_DATA_SOURCE_CHANGED = recipesSoon
function handlers.NEW_RECIPE_LEARNED()
  recipeForce = true
  recipesSoon()
end
function handlers.MERCHANT_SHOW()
  lastMerchant = nil
  C_Timer.After(0.5, function()
    if enabled then guarded("the vendor", collectMerchant) end
  end)
end
function handlers.TRAINER_SHOW() lastTrainer = nil end
function handlers.TRAINER_CLOSED() lastTrainer = nil end

frame:SetScript("OnEvent", function(_, event)
  if enabled and handlers[event] then handlers[event]() end
end)
for event in pairs(handlers) do pcall(frame.RegisterEvent, frame, event) end

-- The trainer window opens without an event this client lets addons see, so it is noticed by looking.
local function tick()
  if enabled then
    if recipeDue and GetTime() >= recipeDue then
      recipeDue = nil
      local force = recipeForce
      recipeForce = false
      guarded("the recipes", function() collectRecipes(force) end)
    end
    -- a trainer is open when the game reports services for the NPC being talked to, whatever window shows them
    local services = try(GetNumTrainerServices)
    if type(services) == "number" and services > 0 then
      local guid = try(UnitGUID, "npc")
      if guid and guid ~= lastTrainer then
        lastTrainer = guid
        guarded("the trainer", collectTrainer)
      end
    end
    if not legacyAt or GetTime() - legacyAt > LEGACY_EVERY then
      legacyAt = GetTime()
      guarded("the Legacy talents", function() collectLegacy(false) end)
    end
    guarded("item values", workItems)
  end
  C_Timer.After(POLL, tick)
end
C_Timer.After(POLL, tick)

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

SLASH_KEBOLDSSHINYCOLLECT1 = "/keboldcollect"
SLASH_KEBOLDSSHINYCOLLECT2 = "/ledgercollect"   -- the name before the addon was renamed
SlashCmdList["KEBOLDSSHINYCOLLECT"] = function(msg)
  local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
  if cmd == "legacy" then
    guarded("the Legacy talents", function() collectLegacy(true) end)
  elseif cmd == "off" then
    enabled = false
    say("Collecting is off until you type /keboldcollect on or reload.")
  elseif cmd == "on" then
    enabled = true
    say("Collecting is on.")
  elseif cmd == "chat on" or cmd == "chat off" or cmd == "chat" then
    local c = store()
    if cmd ~= "chat" then c.chat = (cmd == "chat on") or nil end
    say("A chat line for every profession, trainer and vendor read is " .. (c.chat == true and "on." or "off (/keboldcollect chat on)."))
  elseif cmd == "" or cmd == "status" then
    local c = store()
    local profs = {}
    for name, p in pairs(c.recipes) do profs[#profs + 1] = name .. " " .. tostring(p.n or "?") end
    table.sort(profs)
    say("Recipes: " .. (profs[1] and table.concat(profs, ", ") or "none yet (open a profession window)") .. ".")
    say(string.format("Trainers: %d. Vendors: %d. Item values: %d saved, %d waiting. Collecting is %s.",
      count(c.trainers), count(c.merchants), count(c.items), #itemQueue, enabled and "on" or "off"))
    say("Kebold uses all of this at once; the game keeps it when you log out or reload.")
  else
    say("Usage: /keboldcollect [status | legacy | off | on | chat on | chat off]")
  end
end
