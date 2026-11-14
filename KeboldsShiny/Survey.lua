-- KeboldsShiny survey
-- Read-only. Records which game functions, windows and events this client has for professions, trainers, vendors,
-- tooltips, links and Legacy talents, so the full in-game Kebold can be designed against what really exists.
-- Nothing here changes the game or is used by a scan. Results go to KeboldsShinyDB.survey.
--
--   /keboldsurvey         start (or restart) a survey: records the client, then listens while you open windows
--   /keboldsurvey snap    record again right now, plus the window under the mouse (use with a window open)
--   /keboldsurvey done    stop listening; then /reload so the game writes the saved file

local MAX_NAMES = 2500     -- cap on names kept per list
local MAX_SNAPS = 60       -- cap on recorded moments
local SAMPLE = 6           -- rows sampled from a recipe / trainer / vendor list
local WORDS = { "tradeskill", "craft", "trainer", "merchant", "profession", "legacy", "skillline", "reagent", "recipe" }
local EVENTS = {
  "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_DETAILS_UPDATE", "CRAFT_SHOW", "CRAFT_CLOSE", "CRAFT_UPDATE",
  "TRAINER_SHOW", "TRAINER_UPDATE", "TRAINER_CLOSED", "MERCHANT_SHOW", "MERCHANT_UPDATE", "MERCHANT_CLOSED",
  "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED", "LEARNED_SPELL_IN_TAB", "CHAT_MSG_SKILL",
  "UNIT_SPELLCAST_SUCCEEDED", "BAG_UPDATE_DELAYED",
}
-- Named one by one: whether each exists decides how recipes, links and tooltips are read.
local NAMES = {
  "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillLine", "GetTradeSkillItemLink", "GetTradeSkillRecipeLink",
  "GetTradeSkillNumReagents", "GetTradeSkillReagentInfo", "GetTradeSkillReagentItemLink", "GetTradeSkillNumMade",
  "GetTradeSkillSelectionIndex", "DoTradeSkill", "GetNumCrafts", "GetCraftInfo", "GetCraftItemLink",
  "GetCraftReagentInfo", "GetCraftDisplaySkillLine", "GetNumSkillLines", "GetSkillLineInfo", "GetProfessions",
  "GetProfessionInfo", "GetNumTrainerServices", "GetTrainerServiceInfo", "GetTrainerServiceSkillReq",
  "GetTrainerServiceCost", "GetTrainerServiceLevelReq", "GetTrainerServiceItemLink", "IsTradeskillTrainer",
  "GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink", "GetItemInfo", "GetItemCount",
  "GetSpellInfo", "GetSpellLink", "GetMouseFocus", "GetMouseFoci", "ChatEdit_InsertLink", "HandleModifiedItemClick",
  "SetItemRef", "IsAddOnLoaded", "TooltipDataProcessor", "GameTooltip", "ItemRefTooltip", "TradeSkillFrame",
  "ProfessionsFrame", "CraftFrame", "ClassTrainerFrame", "MerchantFrame", "AuctionHouseFrame", "PlayerSpellsFrame",
  "TalentFrame", "PlayerTalentFrame", "C_TradeSkillUI", "C_TooltipInfo", "C_Item", "C_Spell", "C_MerchantFrame",
  "C_AddOns", "C_Map", "C_Container", "C_CraftingOrders", "C_ProfSpecs", "C_Traits", "C_ClassTalents",
}
local UI_ADDONS = { "Blizzard_TradeSkillUI", "Blizzard_Professions", "Blizzard_CraftUI", "Blizzard_TrainerUI",
  "Blizzard_AuctionHouseUI", "Blizzard_TalentUI", "Blizzard_PlayerSpells", "Blizzard_ClassTalentUI",
  "Blizzard_ProfessionsBook", "Blizzard_ProfessionsTemplates", "Auctionator" }

local active = nil   -- the running survey's saved table, nil when idle
local listener = nil

local function say(msg)
  print("|cff66ccffKeboldSurvey|r " .. msg)
end

-- Text for any value. Tables are shown depth levels deep with at most 40 entries; links keep their codes.
local function show(v, depth)
  depth = depth or 2
  local t = type(v)
  if t == "table" then
    if depth <= 0 then return "{...}" end
    local parts, n = {}, 0
    for k, x in pairs(v) do
      n = n + 1
      if n <= 40 then parts[#parts + 1] = tostring(k) .. "=" .. show(x, depth - 1) end
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. (n > 40 and ", ...(" .. n .. ")" or "") .. "}"
  elseif t == "string" then
    if #v > 300 then v = v:sub(1, 300) .. "..." end
    return '"' .. v .. '"'
  end
  return tostring(v)
end

local function packShow(depth, ok, ...)
  if not ok then return "ERROR " .. tostring((...)) end
  local n = select("#", ...)
  if n == 0 then return "(nothing)" end
  local parts = {}
  for i = 1, n do parts[i] = show((select(i, ...)), depth) end
  return table.concat(parts, " | ")
end

-- Calls a global function by name (or a namespace function "C_X.Fn") and returns one line describing the result.
local function call(depth, name, ...)
  local fn = _G[name]
  local ns, member = name:match("^([%w_]+)%.([%w_]+)$")
  if ns then fn = type(_G[ns]) == "table" and _G[ns][member] or nil end
  if type(fn) ~= "function" then return name .. ": no such function" end
  return name .. " = " .. packShow(depth, pcall(fn, ...))
end

local function frameKind(v)
  if type(v) ~= "table" or type(rawget(v, 0)) ~= "userdata" then return nil end
  local ok, kind = pcall(function() return v:GetObjectType() end)
  return ok and kind or "widget"
end

local function matches(name)
  local low = name:lower()
  for _, word in ipairs(WORDS) do
    if low:find(word, 1, true) then return true end
  end
  return false
end

local function joined(list)
  table.sort(list)
  if #list > MAX_NAMES then
    local n = #list
    for i = n, MAX_NAMES + 1, -1 do list[i] = nil end
    list[#list + 1] = "...(" .. n .. " in all)"
  end
  return table.concat(list, " ")
end

-- Every C_ namespace with its functions, plus global functions, windows and tables whose name has a keyword.
local function scanGlobals(out)
  local spaces, fns, frames, tables = {}, {}, {}, {}
  for name, v in pairs(_G) do
    if type(name) == "string" then
      local t = type(v)
      if t == "table" and name:sub(1, 2) == "C_" then
        local members = {}
        for k, x in pairs(v) do
          if type(k) == "string" and type(x) == "function" then members[#members + 1] = k end
        end
        spaces[#spaces + 1] = name .. ": " .. joined(members)
      elseif matches(name) then
        if t == "function" then
          fns[#fns + 1] = name
        elseif t == "table" then
          local kind = frameKind(v)
          if kind then frames[#frames + 1] = name .. "(" .. kind .. ")" else tables[#tables + 1] = name end
        end
      end
    end
  end
  table.sort(spaces)
  out.namespaces = spaces
  out.functions = joined(fns)
  out.frames = joined(frames)
  out.tables = joined(tables)
  local enums = {}
  if type(Enum) == "table" then
    for name, t in pairs(Enum) do
      if type(name) == "string" and type(t) == "table" and matches(name) then
        enums[#enums + 1] = name .. " = " .. show(t, 1)
      end
    end
  end
  table.sort(enums)
  out.enums = enums
end

local function scanNamed(out)
  local parts = {}
  for i, name in ipairs(NAMES) do
    local v = _G[name]
    parts[i] = name .. "=" .. (frameKind(v) or type(v))
  end
  out.named = table.concat(parts, " ")
  local loaded = {}
  for i, name in ipairs(UI_ADDONS) do
    local a, b = "?", "?"
    if C_AddOns and C_AddOns.IsAddOnLoaded then
      local ok, v = pcall(C_AddOns.IsAddOnLoaded, name)
      a = ok and tostring(v) or "error"
    elseif type(IsAddOnLoaded) == "function" then
      local ok, v = pcall(IsAddOnLoaded, name)
      a = ok and tostring(v) or "error"
    end
    if C_AddOns and C_AddOns.GetAddOnInfo then
      local ok, _, _, _, _, reason = pcall(C_AddOns.GetAddOnInfo, name)
      b = ok and tostring(reason) or "error"
    end
    loaded[i] = name .. " loaded=" .. a .. " reason=" .. b
  end
  out.addons = loaded
  local tip = {}
  if type(GameTooltip) == "table" then
    for _, script in ipairs({ "OnTooltipSetItem", "OnTooltipSetSpell", "OnTooltipCleared" }) do
      local ok, has = pcall(function() return GameTooltip:HasScript(script) end)
      tip[#tip + 1] = script .. "=" .. (ok and tostring(has) or "error")
    end
  end
  if type(TooltipDataProcessor) == "table" then
    tip[#tip + 1] = "TooltipDataProcessor: " .. show(TooltipDataProcessor, 1)
  end
  if type(Enum) == "table" and type(Enum.TooltipDataType) == "table" then
    tip[#tip + 1] = "Enum.TooltipDataType = " .. show(Enum.TooltipDataType, 1)
  end
  out.tooltip = tip
end

local function scanPlayer(out)
  local lines = {}
  lines[#lines + 1] = call(1, "GetBuildInfo")
  lines[#lines + 1] = "WOW_PROJECT_ID = " .. tostring(WOW_PROJECT_ID)
  lines[#lines + 1] = call(1, "UnitFactionGroup", "player")
  lines[#lines + 1] = call(1, "UnitLevel", "player")
  lines[#lines + 1] = call(1, "GetProfessions")
  if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
    local ok, a, b, c, d, e = pcall(GetProfessions)
    if ok then
      for _, index in ipairs({ a or false, b or false, c or false, d or false, e or false }) do
        if index then lines[#lines + 1] = call(1, "GetProfessionInfo", index) end
      end
    end
  end
  if type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
    local ok, n = pcall(GetNumSkillLines)
    lines[#lines + 1] = "GetNumSkillLines = " .. tostring(n)
    if ok and type(n) == "number" then
      for i = 1, math.min(n, 60) do lines[#lines + 1] = call(1, "GetSkillLineInfo", i) end
    end
  end
  out.player = lines
end

-- The open profession window, read through whichever set of functions this client has.
local function snapTradeSkill(lines)
  lines[#lines + 1] = call(1, "GetTradeSkillLine")
  lines[#lines + 1] = call(1, "GetNumTradeSkills")
  lines[#lines + 1] = call(1, "GetTradeSkillSelectionIndex")
  if type(GetNumTradeSkills) == "function" and type(GetTradeSkillInfo) == "function" then
    local ok, n = pcall(GetNumTradeSkills)
    if ok and type(n) == "number" then
      local shown = 0
      for i = 1, n do
        local okInfo, _, kind = pcall(GetTradeSkillInfo, i)
        if okInfo and kind ~= "header" and kind ~= "subheader" then
          shown = shown + 1
          lines[#lines + 1] = call(1, "GetTradeSkillInfo", i)
          lines[#lines + 1] = call(1, "GetTradeSkillItemLink", i)
          lines[#lines + 1] = call(1, "GetTradeSkillRecipeLink", i)
          lines[#lines + 1] = call(1, "GetTradeSkillNumMade", i)
          lines[#lines + 1] = call(1, "GetTradeSkillNumReagents", i)
          lines[#lines + 1] = call(1, "GetTradeSkillReagentInfo", i, 1)
          lines[#lines + 1] = call(1, "GetTradeSkillReagentItemLink", i, 1)
          if shown >= SAMPLE then break end
        end
      end
    end
  end
  local T = C_TradeSkillUI
  if type(T) ~= "table" then
    lines[#lines + 1] = "C_TradeSkillUI: none"
    return
  end
  for _, fn in ipairs({ "IsTradeSkillReady", "GetBaseProfessionInfo", "GetChildProfessionInfo", "GetTradeSkillLine",
    "GetProfessionChildSkillLineID", "IsNPCCrafting", "IsTradeSkillLinked" }) do
    lines[#lines + 1] = call(2, "C_TradeSkillUI." .. fn)
  end
  if type(T.GetAllRecipeIDs) == "function" then
    local ok, ids = pcall(T.GetAllRecipeIDs)
    if ok and type(ids) == "table" then
      lines[#lines + 1] = "C_TradeSkillUI.GetAllRecipeIDs: " .. #ids .. " recipes"
      local shown = 0
      for _, id in ipairs(ids) do
        local okInfo, info = pcall(T.GetRecipeInfo, id)
        if okInfo and type(info) == "table" and info.learned then
          shown = shown + 1
          lines[#lines + 1] = "GetRecipeInfo(" .. id .. ") = " .. show(info, 2)
          lines[#lines + 1] = call(4, "C_TradeSkillUI.GetRecipeSchematic", id, false)
          lines[#lines + 1] = call(1, "C_TradeSkillUI.GetRecipeItemLink", id)
          lines[#lines + 1] = call(1, "C_TradeSkillUI.GetRecipeLink", id)
          lines[#lines + 1] = call(2, "C_TradeSkillUI.GetRecipeOutputItemData", id)
          lines[#lines + 1] = call(1, "C_TradeSkillUI.GetRecipeNumItemsProduced", id)
          lines[#lines + 1] = call(1, "C_TradeSkillUI.GetRecipeNumReagents", id)
          lines[#lines + 1] = call(1, "C_TradeSkillUI.GetRecipeReagentInfo", id, 1)
          lines[#lines + 1] = call(1, "C_TradeSkillUI.GetRecipeReagentItemLink", id, 1)
          lines[#lines + 1] = call(1, "C_TradeSkillUI.GetRecipeCooldown", id)
          lines[#lines + 1] = call(2, "C_TradeSkillUI.GetRecipeSourceText", id)
          if shown >= SAMPLE then break end
        end
      end
      -- one recipe the character has not learned: does the game say where it comes from?
      for _, id in ipairs(ids) do
        local okInfo, info = pcall(T.GetRecipeInfo, id)
        if okInfo and type(info) == "table" and not info.learned then
          lines[#lines + 1] = "unlearned GetRecipeInfo(" .. id .. ") = " .. show(info, 2)
          lines[#lines + 1] = call(2, "C_TradeSkillUI.GetRecipeSourceText", id)
          lines[#lines + 1] = call(4, "C_TradeSkillUI.GetRecipeSchematic", id, false)
          break
        end
      end
    else
      lines[#lines + 1] = "C_TradeSkillUI.GetAllRecipeIDs = " .. packShow(1, ok, ids)
    end
  end
end

local function snapCraft(lines)
  lines[#lines + 1] = call(1, "GetCraftDisplaySkillLine")
  lines[#lines + 1] = call(1, "GetNumCrafts")
  if type(GetNumCrafts) == "function" then
    local ok, n = pcall(GetNumCrafts)
    if ok and type(n) == "number" then
      for i = 1, math.min(n, SAMPLE) do
        lines[#lines + 1] = call(1, "GetCraftInfo", i)
        lines[#lines + 1] = call(1, "GetCraftItemLink", i)
        lines[#lines + 1] = call(1, "GetCraftReagentInfo", i, 1)
      end
    end
  end
end

local function snapTrainer(lines)
  lines[#lines + 1] = call(1, "UnitName", "npc")
  lines[#lines + 1] = call(1, "UnitGUID", "npc")
  lines[#lines + 1] = call(1, "IsTradeskillTrainer")
  lines[#lines + 1] = call(1, "GetNumTrainerServices")
  if type(GetNumTrainerServices) == "function" then
    local ok, n = pcall(GetNumTrainerServices)
    if ok and type(n) == "number" then
      for i = 1, math.min(n, SAMPLE + 4) do
        lines[#lines + 1] = call(1, "GetTrainerServiceInfo", i)
        lines[#lines + 1] = call(1, "GetTrainerServiceSkillReq", i)
        lines[#lines + 1] = call(1, "GetTrainerServiceCost", i)
        lines[#lines + 1] = call(1, "GetTrainerServiceLevelReq", i)
        lines[#lines + 1] = call(1, "GetTrainerServiceItemLink", i)
      end
    end
  end
end

local function snapMerchant(lines)
  lines[#lines + 1] = call(1, "UnitName", "npc")
  lines[#lines + 1] = call(1, "UnitGUID", "npc")
  lines[#lines + 1] = call(1, "GetMerchantNumItems")
  local n = 0
  if type(GetMerchantNumItems) == "function" then
    local ok, v = pcall(GetMerchantNumItems)
    if ok and type(v) == "number" then n = v end
  end
  for i = 1, math.min(n, SAMPLE) do
    lines[#lines + 1] = call(1, "GetMerchantItemInfo", i)
    lines[#lines + 1] = call(2, "C_MerchantFrame.GetItemInfo", i)
    lines[#lines + 1] = call(1, "GetMerchantItemLink", i)
  end
end

-- The window under the mouse and the windows it sits in, so new lines can be attached to the right one.
local function snapMouse(lines)
  local focus = nil
  if type(GetMouseFoci) == "function" then
    local ok, list = pcall(GetMouseFoci)
    if ok and type(list) == "table" then focus = list[1] end
  elseif type(GetMouseFocus) == "function" then
    local ok, f = pcall(GetMouseFocus)
    if ok then focus = f end
  end
  local chain, steps = {}, 0
  while type(focus) == "table" and steps < 12 do
    steps = steps + 1
    local okName, name = pcall(function() return focus:GetName() end)
    local okDebug, debugName = pcall(function() return focus:GetDebugName() end)
    chain[#chain + 1] = tostring(okName and name or "?") .. " [" .. tostring(okDebug and debugName or "?") .. "]"
    local okParent, parent = pcall(function() return focus:GetParent() end)
    focus = okParent and parent or nil
  end
  lines[#lines + 1] = "mouse over: " .. (chain[1] and table.concat(chain, " < ") or "nothing")
end

local function shownFrames(lines)
  local parts = {}
  for _, name in ipairs({ "TradeSkillFrame", "ProfessionsFrame", "CraftFrame", "ClassTrainerFrame", "MerchantFrame",
    "AuctionHouseFrame", "PlayerSpellsFrame", "TalentFrame", "PlayerTalentFrame" }) do
    local f = _G[name]
    if frameKind(f) then
      local ok, shown = pcall(function() return f:IsShown() end)
      parts[#parts + 1] = name .. "=" .. (ok and (shown and "shown" or "hidden") or "error")
    end
  end
  lines[#lines + 1] = "windows: " .. (parts[1] and table.concat(parts, " ") or "none of the known names exist")
end

-- One recorded moment. kinds picks what to read; every part is guarded so one failure does not lose the rest.
local function snap(label, kinds)
  local s = active
  if not s then return end
  if #s.snaps >= MAX_SNAPS then return end
  local lines = { label }
  shownFrames(lines)
  for _, kind in ipairs(kinds) do
    local fn = (kind == "tradeskill" and snapTradeSkill) or (kind == "craft" and snapCraft)
      or (kind == "trainer" and snapTrainer) or (kind == "merchant" and snapMerchant) or (kind == "mouse" and snapMouse)
    local ok, err = pcall(fn, lines)
    if not ok then lines[#lines + 1] = kind .. " ERROR " .. tostring(err) end
  end
  -- windows load their code on first use, so the keyword lists are taken again at every moment
  local again = {}
  local ok, err = pcall(scanGlobals, again)
  if ok then
    -- kept only when a list changed since it was last written, which is when a window loaded its code
    for _, key in ipairs({ "functions", "frames", "tables" }) do
      if again[key] ~= s[key] then
        s[key] = again[key]
        lines[#lines + 1] = key .. " now: " .. again[key]
      end
    end
  else
    lines[#lines + 1] = "scan ERROR " .. tostring(err)
  end
  s.snaps[#s.snaps + 1] = lines
  say("recorded: " .. label .. " (" .. #s.snaps .. ")")
end

local SNAP_ON = {
  TRADE_SKILL_SHOW = { "tradeskill" }, TRADE_SKILL_LIST_UPDATE = { "tradeskill" }, CRAFT_SHOW = { "craft" },
  TRAINER_SHOW = { "trainer" }, MERCHANT_SHOW = { "merchant" },
}

local function onEvent(_, event, ...)
  local s = active
  if not s then return end
  s.events[event] = (s.events[event] or 0) + 1
  if s.events[event] == 1 then
    local parts = {}
    for i = 1, math.min(select("#", ...), 6) do parts[i] = show((select(i, ...)), 1) end
    s.firstArgs[#s.firstArgs + 1] = event .. ": " .. table.concat(parts, ", ")
  end
  local kinds = SNAP_ON[event]
  -- the list event fires many times; one recording of it is enough
  if kinds and (event ~= "TRADE_SKILL_LIST_UPDATE" or s.events[event] == 1) then
    local label = event
    -- the window's data can arrive a moment after the event
    C_Timer.After(0.5, function()
      if active == s then snap(label, kinds) end
    end)
  end
end

local function start()
  if type(KeboldsShinyDB) ~= "table" then KeboldsShinyDB = {} end
  local s = { started = time(), snaps = {}, events = {}, firstArgs = {}, registered = {} }
  KeboldsShinyDB.survey = s
  active = s
  for _, part in ipairs({ scanNamed, scanPlayer, scanGlobals }) do
    local ok, err = pcall(part, s)
    if not ok then s.errors = (s.errors or "") .. tostring(err) .. " ; " end
  end
  if not listener then
    listener = CreateFrame("Frame")
    listener:SetScript("OnEvent", onEvent)
  end
  for _, event in ipairs(EVENTS) do
    local ok = pcall(listener.RegisterEvent, listener, event)
    s.registered[#s.registered + 1] = event .. "=" .. (ok and "yes" or "no")
  end
  say("Survey started. Now, one after another: open a profession window and click a recipe; open a second")
  say("profession if you have one (Enchanting matters); talk to a profession trainer; open a vendor; open the")
  say("Legacy talents window and type /keboldsurvey snap with the mouse over it. Then /keboldsurvey done and /reload.")
end

SLASH_KEBOLDSSHINYSURVEY1 = "/keboldsurvey"
SLASH_KEBOLDSSHINYSURVEY2 = "/ledgersurvey"   -- the name before the addon was renamed
SlashCmdList["KEBOLDSSHINYSURVEY"] = function(msg)
  local cmd = string.lower((msg or ""):match("^%s*(.-)%s*$"))
  if cmd == "" then
    start()
  elseif cmd == "snap" then
    if not active then
      say("No survey is running. Type /keboldsurvey first.")
    else
      snap("manual snap", { "mouse", "tradeskill", "craft" })
    end
  elseif cmd == "done" then
    if active then
      if listener then pcall(listener.UnregisterAllEvents, listener) end
      say("Survey finished: " .. #active.snaps .. " moments recorded. Type /reload so the game writes the file.")
      active = nil
    else
      say("No survey is running.")
    end
  else
    say("Usage: /keboldsurvey [snap | done]")
  end
end
