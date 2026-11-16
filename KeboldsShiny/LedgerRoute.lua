-- Kebold's Shiny: what the Level page needs beyond planning (owner 2026-11-14: "I dont want the plan to change
-- once I've started it")
--   * a STARTED PLAN: the route on screen saved as it is, per profession and per "Plan for" set, and drawn from
--     that save until it is forgotten. Nothing plans it again: not prices, bags, skill, settings or choices.
--     Skill only marks progress. "Use instead" swaps the recipe of one step and leaves the others alone.
--   * ROUTE SETTINGS: one button and a small panel in place of Cheapest | Fastest: what an hour is worth, the most
--     one skill point may cost, three presets, a preview of the three routes, and "Buy for bad luck".
--   * OTHER RECIPES for a step's range (NS.stepAlternates), priced by the engine's ctx.stepFor.
--   * COUNTS FOR BAD LUCK (NS.stepBuffer): the crafts that cover a step 9 times out of 10 (E.safeCrafts).
-- The page itself is LedgerLevel.lua; this file has no rows of its own except the banner of a started plan and the
-- panel's model. It never crafts, buys or learns anything.
--
-- A started plan is saved in the active set of choices, beside the range typed for the profession:
--   NS.planOf(prof).started = {
--     v = 1, prof, from, to, day (days since NS.DAY_ZERO), time (the clock when it was started), skill (yours then),
--     at = a skill typed in by hand ("I'm at skill"), rev = edits made by Use instead / Undo,
--     set = { pf, pt (the range as typed, nil = automatic), recipes, sales, fast, tv, maxPoint, choices (a number
--             made from every pick, sale choice and skip) }: what it was planned with,
--     steps = { { id = recipe (0: a range with no recipe), from, to, crafts, all (parts made ahead: how many the
--                 later steps use), exp, cost, net, time, secs, casts, way ("AH" | "Vendor" | "DE"), stock, capped,
--                 over, cs = { points per craft at each level }, safe, safeCost,
--                 learn = { { id, cost, part, unk, text }, ... }, cause = { text, lines, fix } (no recipe),
--                 shop = <a buy list>, own = true and orig = <the step it replaced> (Use instead), rest = true
--                 (what is left of a step whose first part was replaced) }, ... },
--     shop = { cost, buy = { { item, qty, cost, short, how, part, listed, top (pay up to) }, ... },
--              made = { { item, qty, id = its recipe }, ... }, have = { { item, qty, part }, ... } },
--     tot = { cost, net, crafts, time, gaps, points, learn }, without = <totals learning nothing paid>,
--     ban = { [recipe id] = true }, ranks = { 225, ... } }
-- Because it lives in S.plan[prof], the owner's plans and each profile's are separate, it is saved with the
-- settings, and deleting a profile deletes its plans. The table S.plan itself is never replaced here.

local NS = KeboldsShinyNS
local UI = KeboldsShinyUI
local E = NS.E
local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local DIM, RED, GOLD, GREEN = NS.DIM, NS.RED, NS.GOLD, NS.GREEN
local money, itemName, settings, try, data = NS.money, NS.itemName, NS.settings, NS.try, NS.data

local BALANCED = E.defaults.timeValue   -- gold an hour: the engine's own default, what "Cheapest" used to plan with

-- 38 min, 1 h 12 min
local function mins(v)
  local m = ceil((v or 0) / 60)
  if m < 60 then return m .. " min" end
  return floor(m / 60) .. " h " .. (m % 60) .. " min"
end
-- 45s, 3.4 min, 1.2 h
local function span(v)
  local a = abs(v or 0)
  if a >= 3600 then return string.format("%.1f h", a / 3600) end
  if a >= 90 then return string.format("%.1f min", a / 60) end
  return string.format("%.0fs", a)
end
-- "1g 20s dearer" / "40s cheaper", "4.0 min slower" / "30s faster": a difference from the step's own recipe
local function diffMoney(v)
  return money(abs(v)) .. (v < 0 and " cheaper" or " dearer")
end
local function diffTime(v)
  return span(v) .. (v < 0 and " faster" or " slower")
end

-- ---- counts for bad luck ---------------------------------------------------------------------------------------------

-- A step whose chance of a point is below 100% somewhere: { crafts (expected), safe (enough 9 times out of 10,
-- E.safeCrafts), extra = what the materials of the crafts between the two cost (nil when not all are listed),
-- lo, hi = the chance at its first and last level }. nil for a step that is certain, a step of parts made ahead
-- (those are made anyway) and a range with no recipe. A started plan's step has the figures it was saved with.
function NS.stepBuffer(ctx, g)
  if not g.r or g.stock or type(g.cs) ~= "table" or #g.cs == 0 then return nil end
  local v = ctx   -- kept on the step for as long as the context lives: prices, known recipes and settings make a new one
  if g.bufV == v and g.buf ~= nil then return g.buf or nil end
  local any = false
  for _, c in ipairs(g.cs) do
    if c < 1 - 1e-9 then any = true end
  end
  local buf = false
  if any then
    local sv = g.rec
    if type(sv) == "table" and tonumber(sv.safe) then
      buf = { crafts = g.crafts, safe = max(g.crafts, sv.safe), extra = tonumber(sv.safeCost) }
    else
      local safe = (E.safeCrafts(g.cs))
      buf = { crafts = g.crafts, safe = max(g.crafts, safe) }
      if buf.safe > g.crafts then
        local a = ctx.shopping({ { r = g.r, crafts = g.crafts } }, true)
        local b = ctx.shopping({ { r = g.r, crafts = buf.safe } }, true)
        local short = false
        for _, row in ipairs(b.buy) do
          if row.cost == nil or (row.short or 0) >= 1 then short = true end
        end
        if not short then buf.extra = max(0, b.cost - a.cost) end
      end
    end
    buf.lo, buf.hi = g.cs[1], g.cs[#g.cs]
  end
  g.buf, g.bufV = buf, v
  return buf or nil
end

-- What buying for bad luck on every step of a route would add: { steps = how many have a chance below 100%,
-- extra = copper, unknown = steps whose extra materials are not all listed }.
function NS.routeBuffer(ctx, route)
  local out = { steps = 0, extra = 0, unknown = 0 }
  for _, g in ipairs(route.segs) do
    local b = NS.stepBuffer(ctx, g)
    if b and b.safe > b.crafts then
      out.steps = out.steps + 1
      if b.extra then out.extra = out.extra + b.extra else out.unknown = out.unknown + 1 end
    end
  end
  return out
end

-- ---- the route's settings --------------------------------------------------------------------------------------------
-- Saved: S.fast (true = the engine's "time" mode, as /kebold fast always set), S.opts.timeValue (gold an hour, the
-- Settings page's "Your time is worth": the same value), S.opts.maxPoint (copper; the engine's maxPoint option),
-- S.routeSafe (true = the Shopping buttons add the counts for bad luck).

function NS.routeState()
  local S = settings()
  local tv = tonumber(S.opts.timeValue)
  if tv == nil then tv = E.defaults.timeValue end
  local mp = tonumber(S.opts.maxPoint)
  if mp ~= nil and mp <= 0 then mp = nil end
  return { fast = S.fast == true, tv = tv, maxPoint = mp, safe = S.routeSafe == true }
end

-- "cheapest" | "balanced" | "fastest", or nil for a time value of the player's own
local function presetOf(s)
  if s.fast then return "fastest" end
  if s.tv == 0 then return "cheapest" end
  if s.tv == BALANCED then return "balanced" end
  return nil
end
NS.routePresetOf = presetOf
NS.ROUTE_BALANCED = BALANCED

-- What the button says: the choice in words.
-- short = true: the same in fewer letters, for a row of controls with no room left ("Route: 25g/h, limit").
function NS.routeLabel(s, short)
  s = s or NS.routeState()
  local name = presetOf(s)
  return "Route: " .. (name or (short and (s.tv .. "g/h") or ("time at " .. s.tv .. "g an hour"))) .. (s.maxPoint and ", limit" or "")
end
-- The same in a sentence, for /kebold print and the plan as text.
function NS.routeText(s)
  s = s or NS.routeState()
  local text = s.fast and "the fastest route, whatever it costs" or (s.tv == 0 and "the cheapest route, however long it takes"
    or ("the cheapest route with your time at " .. s.tv .. "g an hour" .. (s.tv == BALANCED and " (balanced)" or "")))
  if s.maxPoint then text = text .. ", at most " .. money(s.maxPoint) .. " for one skill point" end
  return text
end

-- The plan on screen as the previews need it: { prof, st, from, to, sig } (the plan bar's values, not a started plan's).
local function livePlan()
  local cur = NS.current()
  if cur and cur.prof == settings().prof then return cur end
  return NS.state()
end

-- One route planned with given settings in a context of its own (the shared one is not touched): what it costs
-- after sales with learning, its casting time, the points left without a step. Kept per plan and settings.
local previews, nPreviews = {}, 0
local function previewKey(c, mode, tv, mp)
  return table.concat({ tostring(c.sig), c.from, c.to, mode, tv, mp or "" }, "|")
end
local function planWith(c, mode, tv, mp, only)
  if mode == "time" then tv = 0 end   -- the fastest route does not read what time is worth
  local key = previewKey(c, mode, tv, mp)
  local hit = previews[key]
  if hit or only then return hit end
  local ctx = NS.context(c.prof, c.st)
  ctx.opts.mode, ctx.opts.timeValue, ctx.opts.maxPoint = mode, tv, mp
  local route = ctx.planBest(c.prof, c.from, c.to)
  local t = route.tot
  hit = { cost = t.net + (t.learn or 0), time = t.time, gaps = t.gaps }
  previews[key], nPreviews = hit, nPreviews + 1
  return hit
end
-- The route the page has just planned is one of them already.
function NS.routeSeed(cur)
  if not (cur and cur.route and not cur.started) then return end
  local s = NS.routeState()
  local key = previewKey(cur, s.fast and "time" or "cost", s.fast and 0 or s.tv, s.maxPoint)
  if not previews[key] then
    if nPreviews > 40 then previews, nPreviews = {}, 0 end   -- old plans' figures go; never in the middle of a preview
    local t = cur.route.tot
    previews[key], nPreviews = { cost = t.net + (t.learn or 0), time = t.time, gaps = t.gaps }, nPreviews + 1
  end
end

-- "This route: 4g 10s, 38 min. Cheapest would be 3g 60s, 1 h 12 min; fastest 22g, 19 min."
-- d = the values to preview (NS.routeState()'s shape). now = true plans what is missing (three routes at most);
-- without it only routes already planned are used, and nil comes back when one is missing.
function NS.routePreview(d, now)
  local c = livePlan()
  if not (c and c.prof and c.from and c.to and c.to > c.from) then return "Nothing to plan: the target is not above the start.", nil end
  if now and nPreviews > 40 then previews, nPreviews = {}, 0 end
  local this = planWith(c, d.fast and "time" or "cost", d.tv, d.maxPoint, not now)
  local cheap = planWith(c, "cost", 0, nil, not now)
  local fast = planWith(c, "time", 0, nil, not now)
  if not (this and cheap and fast) then return nil, nil end
  local function one(x)
    local sign = x.cost < 0 and "+" or ""
    return sign .. money(x.cost) .. ", " .. mins(x.time) .. (x.gaps > 0 and (RED .. " (" .. x.gaps .. " points with no step)|r") or "")
  end
  local name = presetOf(d)
  local text = "This route: " .. one(this) .. "."
  if name == "cheapest" and not d.maxPoint then
    text = text .. " Fastest would be " .. one(fast) .. "."
  elseif name == "fastest" and not d.maxPoint then
    text = text .. " Cheapest would be " .. one(cheap) .. "."
  else
    text = text .. " Cheapest would be " .. one(cheap) .. "; fastest " .. one(fast) .. "."
  end
  -- The route is built one skill point at a time, so the lowest price for each point is not always the lowest
  -- total: when the Cheapest preset comes out dearer than the values shown, say so rather than hide it.
  if not d.fast and cheap.gaps <= this.gaps and cheap.cost > this.cost + 1 then
    text = text .. DIM .. " (Here the cheapest price for each point adds up to more: keep these values.)|r"
  end
  return text, { this = this, cheap = cheap, fast = fast }
end

-- The values being edited in the panel, before Apply.
local draft = nil
local panel = nil
function NS.routeDraft(fresh)
  if draft == nil or fresh then
    local s = NS.routeState()
    draft = { fast = s.fast, tv = s.tv, maxPoint = s.maxPoint }
  end
  return draft
end
local function refreshPanel()
  if panel and panel:IsShown() then panel:Refresh() end
end
-- key: "tv" (gold an hour; choosing one means the cheapest route at that rate), "maxPoint" (copper, nil = no limit),
-- "preset" ("cheapest" | "balanced" | "fastest").
function NS.routeDraftSet(key, value)
  local d = NS.routeDraft()
  if key == "tv" then
    d.tv = max(0, min(500, floor((tonumber(value) or d.tv) + 0.5)))
    d.fast = false
  elseif key == "maxPoint" then
    local v = tonumber(value)
    d.maxPoint = (v and v > 0) and floor(v + 0.5) or nil
  elseif key == "preset" then
    if value == "cheapest" then
      d.fast, d.tv = false, 0
    elseif value == "balanced" then
      d.fast, d.tv = false, BALANCED
    elseif value == "fastest" then
      d.fast = true
    end
  end
  refreshPanel()
  return d
end
-- Are the draft's values the ones in force?
local function draftSame(d)
  local s = NS.routeState()
  return d.fast == s.fast and d.maxPoint == s.maxPoint and (d.fast or d.tv == s.tv)
end
-- Puts the draft in force and plans again. A started plan is not touched: false and why.
function NS.routeApply()
  local d = NS.routeDraft()
  local S = settings()
  if NS.startedPlan(S.prof) then return false, "Plan again to use new settings." end
  S.fast = d.fast and true or false
  S.opts.timeValue = (d.tv ~= E.defaults.timeValue) and d.tv or nil
  S.opts.maxPoint = d.maxPoint
  NS.bump()
  NS.refresh()
  refreshPanel()
  return true
end
-- Buy for bad luck: no part of the plan, so it applies at once, started or not.
function NS.routeSafe(on)
  if on ~= nil then
    settings().routeSafe = on and true or nil
    NS.refresh()
    refreshPanel()
  end
  return settings().routeSafe == true
end

-- The panel's model: one row per thing it shows (the tests and anything without a frame read these).
function NS.routeSettingsRows()
  local d = NS.routeDraft()
  local started = NS.startedPlan(settings().prof) ~= nil
  local name = presetOf(d)
  local out = {}
  out[#out + 1] = { key = "tv", left = "What my time is worth", c2 = d.fast and (DIM .. "not counted|r") or (d.tv .. "g an hour"),
    tip = { "What my time is worth", "The route adds this for every hour of casting, so it will not send you through 400 crafts to save a few silver.",
      "0: the cheapest route, whatever it takes. The same number as \"Your time is worth\" on the Settings page." } }
  for _, p in ipairs({ { "cheapest", "Cheapest", "Your time counts for nothing: the lowest cost after sales, however many crafts it takes." },
    { "balanced", "Balanced", "Your time at " .. BALANCED .. "g an hour: the rate routes were planned with until now. A craft that saves less than that an hour is not worth the casting." },
    { "fastest", "Fastest", "The least casting time. It ignores cost completely and can be very expensive." } }) do
    out[#out + 1] = { key = "preset", name = p[1], left = p[2], button = true, on = name == p[1], tip = { p[2], p[3] },
      action = function() NS.routeDraftSet("preset", p[1]) end }
  end
  if d.fast then
    out[#out + 1] = { key = "warn", left = RED .. "Fastest ignores what things cost.|r" .. (d.maxPoint and " Your limit for one point still holds." or " Set a limit for one point below to rein it in.") }
  elseif name == "balanced" then
    out[#out + 1] = { key = "warn", left = DIM .. "Balanced: an hour of casting counts as " .. BALANCED .. "g.|r" }
  elseif name == "cheapest" then
    out[#out + 1] = { key = "warn", left = DIM .. "Cheapest: casting time counts for nothing.|r" }
  else
    out[#out + 1] = { key = "warn", left = DIM .. "An hour of casting counts as " .. d.tv .. "g.|r" }
  end
  out[#out + 1] = { key = "maxPoint", left = "Most I will pay for one skill point", c2 = d.maxPoint and money(d.maxPoint) or (DIM .. "no limit|r"),
    tip = { "Most I will pay for one skill point", "After sales. A recipe that costs more than this for a point is only used where no other recipe gives one; that step is then marked.",
      "Typed in silver. Empty: no limit." } }
  out[#out + 1] = { key = "safe", left = "Buy for bad luck", c2 = NS.routeSafe() and "9 in 10" or "off", on = NS.routeSafe(),
    action = function() NS.routeSafe(not NS.routeSafe()) end,
    tip = { "Buy for bad luck", "A craft that is not orange gives a point only some of the time, so a step's crafts are an average.",
      "On: Add step to shopping and Add route to shopping add enough for bad luck 9 times out of 10. The route's own totals stay on the average.",
      "It is not part of the plan, so it can be changed while a plan is started." } }
  local text = NS.routePreview(d)
  out[#out + 1] = { key = "preview", left = text or (DIM .. "Working out the three routes...|r"), pending = text == nil }
  out[#out + 1] = { key = "apply", left = "Apply", button = true, off = started or draftSame(d),
    why = started and "Plan again to use new settings." or "These are the settings in use.", action = function() return NS.routeApply() end }
  if started then out[#out + 1] = { key = "note", left = GOLD .. "Plan again to use new settings.|r" } end
  out[#out + 1] = { key = "close", left = "Close", button = true, action = function() NS.routePanel(false) end }
  return out
end

-- ---- the panel -------------------------------------------------------------------------------------------------------
-- A small frame over the Level page, under its Route button. It is laid out from what its widgets really take (the
-- kit's widths: UI.widthOf, a button's .need, UI.textWidth), never from x offsets written by hand: p:Layout() puts
-- every line's pieces one after the other, makes the panel as wide as its widest line plus padding (never wider
-- than the page), lets a piece that does not fit go on below, and gives the two sentences as many lines as they
-- need. It runs on every Refresh, so it follows the Row size and the preview's text.
--   p.placed = { { key, w = widget, x, y, width, h }, ... }   where each piece was put (y down from the top, <= 0)
--   p.w, p.h   the panel's size;  p.inner = p.w - 2 * pad
-- The widths are the kit's estimate of a text's width: none of it has been seen in game.
local PANEL = { minW = 300, pad = 12, gap = 8, rowH = 28, ctlH = 22, slack = 4 }
NS.ROUTE_PANEL = PANEL
local SAFE_TEXT = "Buy for bad luck: enough for 9 times out of 10"
local UNIT_TIME, UNIT_MAX = "g an hour", "silver; empty = no limit"
local PRESETS = { { "cheapest", "Cheapest" }, { "balanced", "Balanced" }, { "fastest", "Fastest" } }

local function buildPanel(host)
  local p = CreateFrame("Frame", "KeboldsShinyRoutePanel", host)
  p.host, p.w, p.h, p.inner, p.placed = host, PANEL.minW, 200, PANEL.minW - 2 * PANEL.pad, {}
  p:SetSize(p.w, p.h)
  pcall(p.SetFrameStrata, p, "DIALOG")
  p:EnableMouse(true)
  local bg = p:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.06, 0.06, 0.08, 0.97)
  for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
    local line = p:CreateTexture(nil, "BORDER")
    line:SetColorTexture(1, 0.82, 0, 0.45)
    line:SetPoint(e[1], p, e[1], 0, 0)
    line:SetPoint(e[2], p, e[2], 0, 0)
    if e[3] then line:SetHeight(1) else line:SetWidth(1) end
  end
  p.title = UI.text(p, "section", "Route settings")
  p.lTime = UI.text(p, "body", "What my time is worth")
  p.sTime = UI.stepper(p, { w = 44, min = 0, max = 500, step = 5, tip = { "What my time is worth", "Gold an hour. 0: the cheapest route, whatever it takes." } },
    function() return NS.routeDraft().tv end, function(v) NS.routeDraftSet("tv", v) end)
  p.uTime = UI.text(p, "dim", UNIT_TIME)
  p.presets = {}
  for k, def in ipairs(PRESETS) do
    local b = UI.button(p, "", 84, function() NS.routeDraftSet("preset", def[1]) end)
    b.preset, b.plainText = def[1], def[2]
    p.presets[k] = b
  end
  p.warn = UI.text(p, "body", "")
  p.warn:SetJustifyH("LEFT")
  p.warn:SetJustifyV("TOP")
  p.warn:SetWordWrap(true)
  p.lMax = UI.text(p, "body", "Most I will pay for one skill point")
  p.eMax = UI.edit(p, 50, false)
  p.uMax = UI.text(p, "dim", UNIT_MAX)
  local function commitMax(self)
    local text = tostring(self:GetText() or ""):gsub(",", ".")
    local v = tonumber(text)
    NS.routeDraftSet("maxPoint", v and v * 100 or nil)
  end
  p.eMax:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    commitMax(self)
  end)
  p.eMax:SetScript("OnEditFocusLost", commitMax)
  p.cSafe = UI.check(p, SAFE_TEXT, function() return NS.routeSafe() end, function(v) NS.routeSafe(v) end,
    { "Buy for bad luck", "A craft that is not orange gives a point only some of the time, so a step's crafts are an average.",
      "On: Add step to shopping and Add route to shopping add enough for bad luck 9 times out of 10. The route's own totals stay on the average." })
  p.preview = UI.text(p, "body", "")
  p.preview:SetJustifyH("LEFT")
  p.preview:SetJustifyV("TOP")
  p.preview:SetWordWrap(true)
  p.note = UI.text(p, "body", "")
  p.note:SetJustifyH("LEFT")
  p.bClose = UI.button(p, "Close", 60, function() NS.routePanel(false) end)
  p.bApply = UI.button(p, "Apply", 70, function()
    local ok, why = NS.routeApply()
    if not ok and why then NS.notice(why) end
  end)
  p.pending = false

  function p:Layout()
    local fonts = UI.ctlFonts()
    local lineH = fonts.text == "GameFontHighlightSmall" and 12 or 14
    local pad, gap, rowH, ctlH = PANEL.pad, PANEL.gap, PANEL.rowH, PANEL.ctlH
    local function tw(s, font) return UI.textWidth(s, font or fonts.text) + PANEL.slack end
    for _, fs in ipairs({ self.lTime, self.lMax, self.warn, self.preview, self.note }) do pcall(fs.SetFontObject, fs, fonts.text) end
    for _, fs in ipairs({ self.uTime, self.uMax }) do pcall(fs.SetFontObject, fs, fonts.off) end
    local presetW = 84
    for _, b in ipairs(self.presets) do presetW = max(presetW, UI.textWidth(b.plainText, fonts.text) + UI.BUTTON_PAD) end
    local noteText = UI.plainText(tostring(self.note:GetText() or ""))
    -- the lines whose pieces stand side by side: the widget, its width, is it a text, the gap before it
    local function text(key, fs, s) return { key = key, w = fs, width = tw(s), text = true } end
    local lines = {
      { text("lTime", self.lTime, "What my time is worth"), { key = "sTime", w = self.sTime, width = UI.widthOf(self.sTime) }, text("uTime", self.uTime, UNIT_TIME) },
      { { key = "preset1", w = self.presets[1], width = presetW, gap = 4, set = true }, { key = "preset2", w = self.presets[2], width = presetW, gap = 4, set = true },
        { key = "preset3", w = self.presets[3], width = presetW, gap = 4, set = true } },
      "warn",
      -- (the box's own art starts a few pixels left of it: a wider gap before it)
      { text("lMax", self.lMax, "Most I will pay for one skill point"), { key = "eMax", w = self.eMax, width = UI.widthOf(self.eMax), gap = gap + 4 }, text("uMax", self.uMax, UNIT_MAX) },
      { { key = "cSafe", w = self.cSafe, width = UI.widthOf(self.cSafe) } },
      "preview",
    }
    local applyW, closeW = UI.widthOf(self.bApply), UI.widthOf(self.bClose)
    local footW = applyW + 4 + closeW
    -- as wide as the widest line, the page's width at most
    local need = max(PANEL.minW - 2 * pad, tw("Route settings", "GameFontNormal"), footW)
    for _, line in ipairs(lines) do
      if type(line) == "table" then
        local x = 0
        for i, it in ipairs(line) do x = x + (i > 1 and (it.gap or gap) or 0) + it.width end
        need = max(need, x)
      end
    end
    local hostW = tonumber((self.host:GetWidth())) or 0
    local w = need + 2 * pad
    if hostW > 2 * pad + 120 and w > hostW then w = hostW end
    local inner = w - 2 * pad
    self.w, self.inner = w, inner
    local placed = {}
    local function put(key, widget, x, y, width, h)
      widget:ClearAllPoints()
      widget:SetPoint("TOPLEFT", self, "TOPLEFT", x, y)
      placed[#placed + 1] = { key = key, w = widget, x = x, y = y, width = width, h = h }
    end
    -- a sentence: as many lines as its text needs in the panel's width (wrapping wastes a little of each line)
    local function sentence(key, fs, y, least)
      local s = UI.plainText(tostring(fs:GetText() or ""))
      local n = max(least, ceil((UI.textWidth(s, fonts.text) + PANEL.slack) / max(40, inner * 0.92)))
      fs:SetWidth(inner)
      pcall(fs.SetHeight, fs, n * lineH)
      put(key, fs, pad, y, inner, n * lineH)
      return y - n * lineH - 8
    end
    local y = -8
    put("title", self.title, pad, y, tw("Route settings", "GameFontNormal"), 16)
    y = y - 24
    for _, line in ipairs(lines) do
      if line == "warn" then
        y = sentence("warn", self.warn, y, 1)
      elseif line == "preview" then
        y = sentence("preview", self.preview, y - 2, 2)
      else
        local x = 0
        for i, it in ipairs(line) do
          if i > 1 then
            x = x + (it.gap or gap)
            if x + it.width > inner then   -- no room left (a narrow page): it goes on below
              x, y = 0, y - (it.text and (lineH + 6) or rowH)
            end
          end
          if it.set then it.w:SetWidth(it.width) end
          if it.text then
            it.w:SetWidth(it.width)
            put(it.key, it.w, pad + x, y - floor((ctlH - lineH) / 2), it.width, lineH)
          else
            put(it.key, it.w, pad + x, y, it.width, ctlH)
          end
          x = x + it.width
        end
        y = y - rowH
      end
    end
    -- the foot: the note (a started plan) left of Apply and Close, or on a line of its own above them
    local applyX = w - pad - closeW - 4 - applyW
    if noteText ~= "" then
      local nw = tw(noteText)
      if pad + nw + gap > applyX then
        self.note:SetWidth(inner)
        put("note", self.note, pad, y, min(nw, inner), lineH)
        y = y - lineH - 8
      else
        self.note:SetWidth(nw)
        put("note", self.note, pad, y - floor((ctlH - lineH) / 2), nw, lineH)
      end
    end
    put("bApply", self.bApply, applyX, y, applyW, ctlH)
    put("bClose", self.bClose, w - pad - closeW, y, closeW, ctlH)
    y = y - ctlH - 8
    self.h, self.placed = -y, placed
    self:SetSize(w, self.h)
    return w, self.h
  end

  function p:Refresh()
    local rows, by = NS.routeSettingsRows(), {}
    for _, row in ipairs(rows) do
      if row.key == "preset" then by[row.name] = row else by[row.key] = row end
    end
    self.sTime:Refresh()
    for _, b in ipairs(self.presets) do
      local row = by[b.preset]
      b:SetLabel((row.on and GOLD or DIM) .. row.left .. "|r")
      b.tip = row.tip
    end
    self.warn:SetText(by.warn and by.warn.left or "")
    local d = NS.routeDraft()
    if not self.eMax:HasFocus() then self.eMax:SetText(d.maxPoint and tostring(d.maxPoint / 100) or "") end
    self.cSafe:Refresh()
    self.preview:SetText(UI.show(by.preview.left))
    self.note:SetText(by.note and by.note.left or "")
    self.bApply:SetEnabled(not by.apply.off, by.apply.why)
    self:Layout()
    -- the three routes are planned a moment after the panel is drawn, never while a number is being typed
    if by.preview.pending and not self.pending and type(C_Timer) == "table" and type(C_Timer.After) == "function" then
      self.pending = true
      C_Timer.After(0.05, function()
        self.pending = false
        if not self:IsShown() then return end
        pcall(NS.routePreview, NS.routeDraft(), true)
        self:Refresh()
      end)
    end
  end
  UI.tip(p.lMax, { "Most I will pay for one skill point", "After sales. A recipe above it is only used where no other recipe gives a point; that step is then marked.", "Typed in silver. Empty: no limit." })
  p:Hide()
  -- A click anywhere outside the panel, or Escape, closes it like Close does: what was not applied is dropped.
  UI.popup(p, function() NS.routePanel(false) end)
  return p
end

-- Opens (true), closes (false) or flips (nil) the panel; host and anchor are given by the Level page the first time.
function NS.routePanel(open, host, anchor)
  if not panel then
    if not host then return false end
    panel = buildPanel(host)
    panel:SetPoint("TOPRIGHT", anchor or host, anchor and "BOTTOMRIGHT" or "TOPRIGHT", 0, -2)
  end
  if open == nil then open = not panel:IsShown() end
  if open then
    NS.routeDraft(true)
    panel:Show()
    panel:Refresh()
  else
    panel:Hide()
  end
  return panel:IsShown() and true or false
end
function NS.routePanelFrame() return panel end   -- for the tests

-- ---- a started plan: saving it -----------------------------------------------------------------------------------------

local function copy(list)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = v end
  return out
end

-- The started plan of a profession in the set of choices shown (the owner's, or the profile's), or nil. A save that
-- does not have the shape above (a file edited by hand) counts as none.
function NS.startedPlan(prof)
  prof = prof or settings().prof
  if not prof or not data().byProf[prof] then return nil end
  local P = NS.planOf(prof).started
  if type(P) ~= "table" or type(P.steps) ~= "table" or #P.steps == 0 or type(P.shop) ~= "table" or type(P.tot) ~= "table" then return nil end
  if not (tonumber(P.from) and tonumber(P.to) and P.to > P.from) then return nil end
  for _, s in ipairs(P.steps) do
    if type(s) ~= "table" or not (tonumber(s.from) and tonumber(s.to) and s.to > s.from) then return nil end
    if s.id ~= 0 and (type(s.cs) ~= "table" or not tonumber(s.crafts) or not tonumber(s.exp)) then return nil end
  end
  return P
end

-- A buy list (ctx.shopping's result) as it is saved, and back.
local function packShop(ctx, shop)
  local out = { cost = shop.cost, buy = {}, made = {}, have = {} }
  for i, b in ipairs(shop.buy) do
    out.buy[i] = { item = b.item, qty = b.qty, cost = b.cost, short = b.short, how = b.how, part = b.part and true or false, listed = b.listed,
      top = NS.payUpTo(ctx, b.item, b.qty) }
  end
  for i, m in ipairs(shop.made) do out.made[i] = { item = m.item, qty = m.qty, id = m.r and m.r.id or nil } end
  for i, h in ipairs(shop.have or {}) do out.have[i] = { item = h.item, qty = h.qty, part = h.part and true or false } end
  return out
end
function NS.unpackShop(saved)
  local db = data()
  local out = { cost = tonumber(saved and saved.cost) or 0, buy = {}, made = {}, have = {}, saved = true }
  for _, b in ipairs(type(saved) == "table" and type(saved.buy) == "table" and saved.buy or {}) do
    if type(b) == "table" and tonumber(b.item) and tonumber(b.qty) then
      out.buy[#out.buy + 1] = { item = b.item, qty = b.qty, cost = tonumber(b.cost), short = tonumber(b.short), how = b.how, part = b.part == true,
        listed = tonumber(b.listed), top = tonumber(b.top) or false }
    end
  end
  for _, m in ipairs(type(saved) == "table" and type(saved.made) == "table" and saved.made or {}) do
    if type(m) == "table" and tonumber(m.item) and tonumber(m.qty) then
      out.made[#out.made + 1] = { item = m.item, qty = m.qty, r = m.id and db.byId[m.id] or nil }
    end
  end
  for _, h in ipairs(type(saved) == "table" and type(saved.have) == "table" and saved.have or {}) do
    if type(h) == "table" and tonumber(h.item) and tonumber(h.qty) then
      out.have[#out.have + 1] = { item = h.item, qty = h.qty, part = h.part == true }
    end
  end
  return out
end

-- One step as it is saved. need = what has to be learned before it ({ { r, cost, part, li, text }, ... }), cause =
-- why a range has no recipe (LedgerLevel.lua's records of the route on screen).
local function packStep(ctx, g, need, cause)
  local r = g.r
  local s = { id = r and r.id or 0, from = g.from, to = g.to }
  if not r then
    if cause then s.cause = { text = cause.text, lines = copy(cause.lines), fix = cause.fix } end
    return s
  end
  local x = ctx.info(r)
  s.crafts, s.all, s.exp, s.cost, s.net, s.time = g.crafts, g.all, g.exp, g.cost, g.net, g.time
  s.secs, s.casts, s.way = x.secs, x.casts, x.way
  s.stock, s.capped, s.over = g.stock and true or nil, g.capped and true or nil, g.over and true or nil
  s.cs = copy(g.cs)
  s.learn = {}
  for _, e in ipairs(need or {}) do
    s.learn[#s.learn + 1] = { id = e.r.id, cost = e.cost, part = e.part and true or nil, unk = (e.li and e.li.unknown) and true or nil, text = e.text }
  end
  s.shop = packShop(ctx, ctx.shopping({ { r = r, crafts = g.all or g.crafts, stock = g.stock } }, true))
  local b = NS.stepBuffer(ctx, g)
  if b then s.safe, s.safeCost = b.safe, b.extra end
  return s
end

-- A number made from every choice of the set shown (picks, sale choices, skips): it changes when one of them does.
local function choicesMark()
  local S = settings()
  local h = 0
  local function eat(t, salt)
    for k, v in pairs(t) do
      local text = tostring(k) .. "=" .. tostring(v)
      local n = salt
      for i = 1, #text do n = (n * 31 + text:byte(i)) % 1000003 end
      h = (h + n) % 2147483647
    end
  end
  eat(S.pick, 7)
  eat(S.sellPick, 11)
  eat(S.exclude, 13)
  return h
end

-- What a plan is planned with, as it is now.
local function settingsNow(prof)
  local S = settings()
  local p = NS.planOf(prof)
  local s = NS.routeState()
  return { pf = tonumber(p.from), pt = tonumber(p.to), recipes = S.recipes, sales = S.sales, fast = s.fast, tv = s.tv, maxPoint = s.maxPoint,
    choices = choicesMark() }
end

-- What differs between the settings a plan was started with and the ones showing now: a list of words, empty when
-- nothing does. (Skill, prices, bags and vendors are not settings: they never appear here.)
function NS.planChanges(P, prof)
  local was, now = type(P.set) == "table" and P.set or {}, settingsNow(prof)
  local out = {}
  if was.pf ~= now.pf or was.pt ~= now.pt then out[#out + 1] = "the range" end
  if was.recipes ~= now.recipes then out[#out + 1] = "Recipes" end
  if was.sales ~= now.sales then out[#out + 1] = "Sells at" end
  if (was.fast == true) ~= now.fast or (not now.fast and was.tv ~= now.tv) or was.maxPoint ~= now.maxPoint then out[#out + 1] = "the route settings" end
  if was.choices ~= now.choices then out[#out + 1] = "your choices (buy, make, have it, where things sell, skipped recipes)" end
  return out
end

local function today()
  return floor(((try(time) or 0) - NS.DAY_ZERO) / 86400)
end

-- Freezes the route on the Level page for its profession. Returns the saved plan, or nil and why not.
function NS.startPlan()
  local cur = NS.current()
  if not (cur and cur.route and cur.prof) then return nil, "There is no route to start." end
  if cur.started then return nil, "This plan is started already." end
  local any = false
  for _, g in ipairs(cur.route.segs) do
    if g.r then any = true end
  end
  if not any or type(cur.recs) ~= "table" or type(cur.whole) ~= "table" then return nil, "There is no route to start." end
  local route, ctx = cur.route, cur.ctx
  local t = route.tot
  local P = { v = 1, prof = cur.prof, from = route.from or cur.from, to = route.to or cur.to, day = today(), time = try(time) or 0,
    skill = tonumber(cur.st and cur.st.skill), rev = 0, set = settingsNow(cur.prof), steps = {}, ban = {}, ranks = copy(cur.ranks),
    tot = { cost = t.cost, net = t.net, crafts = t.crafts, time = t.time, gaps = t.gaps, points = t.points, learn = t.learn or 0 } }
  for i, g in ipairs(route.segs) do
    local rec = cur.recs[i] or {}
    P.steps[i] = packStep(ctx, g, rec.need, rec.cause)
  end
  P.shop = packShop(ctx, cur.whole)
  if route.without then
    local w = route.without
    P.without = { cost = w.cost, net = w.net, crafts = w.crafts, gaps = w.gaps }
  end
  for id in pairs(route.ban or {}) do P.ban[id] = true end
  NS.planOf(cur.prof).started = P
  if NS.levelFollow then NS.levelFollow(true) end
  NS.refresh()
  return P
end

-- Forgets the started plan of a profession: the page plans live again.
function NS.stopPlan(prof)
  prof = prof or settings().prof
  if not prof then return false end
  local slot = NS.planOf(prof)
  if slot.started == nil then return false end
  slot.started = nil
  NS.bump()
  NS.refresh()
  return true
end

-- Plan again: the only way a started plan changes. Asks once, then plans from the skill and settings of now.
function NS.planAgain(sure)
  local prof = settings().prof
  local P = NS.startedPlan(prof)
  if P and not sure and NS.confirm then
    NS.confirm("Plan " .. prof .. " again from your skill and settings of now? The plan you started is forgotten.", "Plan again", function() NS.planAgain(true) end)
    return false
  end
  if prof then NS.planOf(prof).started = nil end
  NS.bump()
  NS.refresh()
  return true
end

-- "I'm at skill n": progress typed in, for a plan that is not this character's own skill (a profile, a profession
-- the character does not have).
function NS.planAt(prof, n)
  local P = NS.startedPlan(prof)
  if not P then return nil end
  if n ~= nil then
    P.at = max(P.from, min(P.to, floor((tonumber(n) or P.from) + 0.5)))
    NS.refresh()
  end
  return tonumber(P.at) or P.from
end

-- ---- a started plan: reading it ------------------------------------------------------------------------------------------

-- Where the plan stands: { skill, manual (typed in, not read from the character), n (steps), done (steps behind),
-- step (the one the skill is in; nil when finished), left / leftExp (crafts still expected in it, from the chance
-- at each level that remains), safeLeft (enough 9 times out of 10), finished, before (the skill is under its start) }.
-- This is progress, not planning: the steps stay what they were.
function NS.planProgress(P, st)
  local own = NS.who() == nil and st ~= nil and tonumber(st.skill) ~= nil
  local skill = own and tonumber(st.skill) or tonumber(P.at) or P.from
  local pr = { manual = not own, n = #P.steps, done = 0, before = skill < P.from }
  skill = max(P.from, min(P.to, skill))
  pr.skill = skill
  pr.finished = skill >= P.to
  for i, s in ipairs(P.steps) do
    if skill >= s.to then
      pr.done = pr.done + 1
    elseif skill >= s.from and not pr.step then
      pr.step = i
      if s.id ~= 0 and type(s.cs) == "table" then
        local rest, exp = {}, 0
        for k = skill - s.from + 1, #s.cs do
          local c = tonumber(s.cs[k]) or 0
          if c > 0 then
            rest[#rest + 1] = c
            exp = exp + 1 / c
          end
        end
        pr.leftExp, pr.left = exp, ceil(exp - 1e-6)
        pr.safeLeft = s.stock and pr.left or max(pr.left, (E.safeCrafts(rest)))
      end
    end
  end
  return pr
end

-- The started plan as a route (the shape ctx.planBest returns, so everything that reads "the route" reads it):
-- segs with r, from, to, cs, exp, crafts, all, cost, net, time, stock, capped, over, learn, and rec = the saved step.
-- nil when the profession has no started plan. LedgerShop.lua's "route" entry should use this instead of planning.
local routes = setmetatable({}, { __mode = "k" })
function NS.startedRoute(prof)
  local P = NS.startedPlan(prof)
  if not P then return nil end
  local hit = routes[P]
  if hit and hit.rev == (P.rev or 0) then return hit end
  local db = data()
  local route = { segs = {}, from = P.from, to = P.to, prof = P.prof, started = P, rev = P.rev or 0, ban = {}, learn = { list = {}, total = 0 } }
  for i, s in ipairs(P.steps) do
    local r = (s.id and s.id ~= 0) and db.byId[s.id] or nil
    local g = { r = r, from = s.from, to = s.to, rec = s, i = i }
    if r then
      g.cs, g.exp, g.crafts, g.all = s.cs, s.exp, s.crafts, tonumber(s.all)
      g.cost, g.net, g.time = tonumber(s.cost) or 0, tonumber(s.net) or 0, tonumber(s.time) or 0
      g.stock, g.capped, g.over = s.stock == true or nil, s.capped == true, s.over == true or nil
      g.avg = (s.to - s.from) / s.exp
      for _, e in ipairs(type(s.learn) == "table" and s.learn or {}) do
        local lr = type(e) == "table" and db.byId[e.id or 0] or nil
        if lr and tonumber(e.cost) and e.cost > 0 then
          local x = { r = lr, cost = e.cost, from = s.from, points = s.to - s.from }
          g.learn = g.learn or {}
          g.learn[#g.learn + 1] = x
          route.learn.list[#route.learn.list + 1] = x
          route.learn.total = route.learn.total + e.cost
        end
      end
    elseif s.id ~= 0 then
      g.lost = true   -- its recipe is not in the data any more: shown as a range with no recipe
    end
    route.segs[i] = g
  end
  local t = P.tot
  route.tot = { cost = tonumber(t.cost) or 0, net = tonumber(t.net) or 0, crafts = tonumber(t.crafts) or 0, time = tonumber(t.time) or 0,
    gaps = tonumber(t.gaps) or 0, points = P.to - P.from, learn = tonumber(t.learn) or 0 }
  if type(P.without) == "table" then route.without = P.without end
  for id in pairs(type(P.ban) == "table" and P.ban or {}) do route.ban[id] = true end
  routes[P] = route
  return route
end

-- The engine context shows parts the way the started plan had them: the paid recipes it declined stay out. Done
-- once per context.
local banned = setmetatable({}, { __mode = "k" })
function NS.planBan(ctx, P)
  if banned[ctx] == P then return end
  banned[ctx] = P
  local b = {}
  for id in pairs(type(P.ban) == "table" and P.ban or {}) do b[id] = true end
  ctx.setBan(b)
end

-- 14 Nov (the game's own short month name), or "day 2504" where the game has no date()
local function dayText(P)
  local t = tonumber(P.time)
  if t and t > 0 and type(date) == "function" then
    local ok, text = pcall(date, "%d %b", t)
    if ok and type(text) == "string" and text ~= "" then return (text:gsub("^0", "")) end
  end
  return "day " .. tostring(P.day or "?")
end
NS.planDayText = dayText

-- ---- would a new plan be cheaper? ----------------------------------------------------------------------------------------
-- A whole plan, so it is worked out a moment after the page is drawn, once per state of the prices and the skill,
-- in a context of its own. It only ever becomes one quiet line; nothing switches by itself.
local cmp = { key = false, text = false, pending = false }

-- What is left of a started plan costs, after sales, with the recipes still to learn, AT TODAY'S PRICES: the plan's
-- saved figures are the prices of the day it was started, and a new plan is priced today, so the two could not be
-- compared. Each remaining step's recipe is priced as the engine prices a step of it over the levels that are left
-- (ctx.stepFor: on its own, down today's listings), a craft at a time, for the crafts the plan still expects; a
-- recipe still to learn at what learning it costs today. nil when a step or a recipe cannot be priced today: then
-- nothing is said. (A step of parts made ahead costs nothing itself, as when it was saved.)
local function remainingCost(P, pr, st, ctx)
  local sum = 0
  local byId = data().byId
  for i, s in ipairs(P.steps) do
    if s.id ~= 0 and i >= (pr.step or (#P.steps + 1)) then
      local r = byId[s.id]
      if not r then return nil end
      if not s.stock then
        local from = (i == pr.step) and max(s.from, min(pr.skill, s.to - 1)) or s.from
        local crafts = tonumber(s.crafts) or 0
        if i == pr.step and pr.leftExp and s.exp and s.exp > 0 then crafts = crafts * min(1, pr.leftExp / s.exp) end
        local g = ctx.stepFor(r, from, s.to)
        if not g or g.to < s.to or g.short or not (g.crafts and g.crafts > 0) then return nil end
        sum = sum + g.net / g.crafts * crafts
      end
      for _, e in ipairs(type(s.learn) == "table" and s.learn or {}) do
        if type(e) == "table" and not (st.known and st.known[e.id]) then
          local lr = byId[e.id]
          local li = lr and ctx.learnInfo and ctx.learnInfo(lr) or nil
          if not li or li.cost == nil then return nil end
          sum = sum + li.cost
        end
      end
    end
  end
  return sum
end
NS.planRemainingCost = remainingCost   -- for tests

function NS.planCompare(P, prof, st, pr, sig)
  if pr.finished or pr.manual or not pr.step then return nil end
  local key = tostring(sig) .. "|" .. pr.skill .. "|" .. (P.rev or 0)
  if cmp.key == key then return cmp.text or nil end
  if cmp.pending or type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return nil end
  cmp.pending = true
  C_Timer.After(1, function()
    cmp.pending = false
    local ok, text = pcall(function()
      local c = NS.state(prof)
      local P2 = NS.startedPlan(prof)
      if P2 ~= P or not c then return false end
      local st2 = c.st
      local pr2 = NS.planProgress(P, st2)
      if pr2.finished or not pr2.step then return false end
      key = tostring(NS.sigOf(prof, st2, c.from, c.to)) .. "|" .. pr2.skill .. "|" .. (P.rev or 0)
      local ctx = NS.context(prof, st2)
      local route = ctx.planBest(prof, pr2.skill, P.to)
      local new = route.tot.net + (route.tot.learn or 0)
      -- the started plan's own steps at the same prices, with parts got the way the plan had them
      local ban = {}
      for id in pairs(type(P.ban) == "table" and P.ban or {}) do ban[id] = true end
      ctx.setBan(ban)
      local old = remainingCost(P, pr2, st2, ctx)
      if old == nil then return false end
      local gapsOld = 0
      for i, s in ipairs(P.steps) do
        if s.id == 0 and i >= pr2.step then gapsOld = gapsOld + (s.to - max(s.from, pr2.skill)) end
      end
      if route.tot.gaps > gapsOld then return false end
      local less = old - new
      if less < max(100, abs(old) * 0.02) then return false end
      return "A new plan from " .. pr2.skill .. " would cost " .. money(less) .. " less at today's prices."
    end)
    cmp.key, cmp.text = key, ok and text or false
    if cmp.text then NS.refresh() end
  end)
  return nil
end

-- ---- the banner of a started plan ----------------------------------------------------------------------------------------

-- The lines that say a started plan is showing: where it stands, what changed in the plan bar since, whether a new
-- plan would be cheaper, and "I'm at skill" for a plan whose progress is typed in. lv "all": both views show them.
function NS.planBanner(P, prof, st, pr, sig)
  local out = {}
  local where
  if pr.finished then
    where = GREEN .. "Finished: you are at " .. pr.skill .. ".|r Plan again for a new one."
  else
    local at = P.steps[pr.step]
    where = (pr.manual and "At skill " or "You are at ") .. pr.skill .. ", step " .. pr.step .. " of " .. pr.n
    if pr.left and at then where = where .. ": about " .. pr.left .. " more " .. (pr.left == 1 and "craft" or "crafts") .. " to " .. at.to end
    where = where .. ". Plan again to change it."
  end
  local edits = 0
  for _, s in ipairs(P.steps) do
    if s.own then edits = edits + 1 end
  end
  local head = GOLD .. "Started " .. dayText(P) .. " at skill " .. (tonumber(P.skill) or P.from) .. ".|r " .. where
  out[#out + 1] = { lv = "all", band = true, started = true, left = head, action = function() end,
    tip = { "A started plan", "This is the route as it was when you pressed Start this plan. Prices, scans, bags, new recipes and the plan bar do not change it.",
      "Your skill only marks how far you are. Plan again makes a new one; Forget plan goes back to planning as you go.",
      edits > 0 and (edits .. (edits == 1 and " step is" or " steps are") .. " your own choice (*).") or nil } }
  out[#out + 1] = { lv = "sum", status = "started", level = 1, left = head }
  local changes = NS.planChanges(P, prof)
  if #changes > 0 then
    out[#out + 1] = { lv = "all", changed = true, action = function() end,
      left = RED .. "Changed since it was started:|r " .. table.concat(changes, ", ") .. ". The plan does not follow; Plan again to use " .. (#changes == 1 and "it" or "them") .. "." }
  end
  if pr.manual and not pr.finished then
    out[#out + 1] = { lv = "all", at = true, left = "I'm at skill " .. pr.skill .. DIM .. "  (type it: this plan does not follow a character's skill)|r", right = tostring(pr.skill),
      control = { kind = "stepper", text = tostring(pr.skill), min = P.from, max = P.to, w = 96, get = function() return NS.planAt(prof) end, set = function(v) NS.planAt(prof, v) end,
        tip = { "I'm at skill", "Where you are in this plan. It marks the steps that are done and counts the crafts left in the current one." } } }
  end
  local cheaper = NS.planCompare(P, prof, st, pr, sig)
  if cheaper then out[#out + 1] = { lv = "all", cheaper = true, left = DIM .. cheaper .. " Plan again to use it.|r", action = function() end } end
  return out
end

-- ---- other recipes for a step ----------------------------------------------------------------------------------------------

-- The next best recipes that give points from the start of a step's range, each as ctx.stepFor has it over that
-- range (or as far as it gives points), with what it differs from the step's own recipe priced the same way:
--   { r, from, to, part (it stops before the step's end), crafts, exp, cost, net, time, learn (copper to learn it),
--     unknown (a price nobody knows), known, far (the plan may not use it as set, or its price is not known), perPoint (after sales with learning, a point), dNet, dTime (against the
--     step's recipe over the same levels; nil when that has no price now), score, why = { reasons it was not
--     chosen }, can (Use instead is possible), seg = the engine's step }
-- Up to `limit` (4), best first by the measure the route is planned by. Kept on the step until prices change.
-- (Not offered: a recipe that only starts giving points inside the range, and one that cannot be got at all.)
function NS.stepAlternates(ctx, st, prof, route, g, limit)
  if not g.r or g.stock then return {} end
  local v = ctx   -- kept on the step for as long as the context lives (see NS.stepBuffer)
  if g.alts and g.altsV == v then return g.alts end
  local S = settings()
  local rate = (ctx.opts.timeValue or 0) * 10000 / 3600
  local byTime = ctx.opts.mode == "time"
  local base = ctx.stepFor(g.r, g.from, g.to)
  local sv = g.rec
  local can = not (type(sv) == "table" and (sv.own or sv.rest))
  local list = {}
  for _, r in ipairs(data().byProf[prof] or {}) do
    if r ~= g.r and r.col and not ctx.opts.exclude[r.id] and not S.exclude[r.id] then
      local known = st.known ~= nil and st.known[r.id] == true
      local li = ctx.learnInfo and ctx.learnInfo(r) or nil
      if known or li == nil or li.cost ~= nil then   -- one that cannot be got at all is no alternative
        local a = ctx.stepFor(r, g.from, g.to)
        if a then
          local pts = a.to - a.from
          local learn = (not known and li and li.cost and li.cost > 0) and li.cost or 0
          local b = base
          if a.to < g.to then b = ctx.stepFor(g.r, g.from, a.to) end
          local e = { r = r, from = a.from, to = a.to, part = a.to < g.to, crafts = a.crafts, exp = a.exp, cost = a.cost, net = a.net, time = a.time,
            learn = learn, unknown = (not known and li and li.unknown) and true or false, known = known, perPoint = (a.net + learn) / pts,
            dNet = b and (a.net + learn - b.net) or nil, dTime = b and (a.time - b.time) or nil, short = a.short, seg = a, can = can,
            score = byTime and (a.time / pts) or ((a.net + a.time * rate + learn) / pts) }
          -- one the plan may not use as it is set (the Recipes switch), or whose price nobody knows, comes after the others
          e.far = (not known and (e.unknown or not ctx.allowed(r))) and true or false
          local why = {}
          if not known then
            if e.unknown then
              why[#why + 1] = "needs a recipe you do not know, at a price nobody knows"
            elseif learn > 0 then
              why[#why + 1] = "needs a recipe you do not know: + " .. money(learn) .. " to learn"
            else
              why[#why + 1] = "needs a recipe you do not know (free to learn)"
            end
          end
          if route.ban and route.ban[r.id] then
            why[#why + 1] = "the route was better without paying for it"
          elseif not known and not ctx.allowed(r) then
            why[#why + 1] = "not among the recipes the plan may use (Recipes)"
          end
          if e.part then why[#why + 1] = "goes grey at " .. a.to .. ", so it covers " .. a.from .. "-" .. a.to .. " only" end
          if a.short then why[#why + 1] = "not enough " .. itemName(a.short) .. " listed" end
          if e.dNet and e.dNet > 0.5 then why[#why + 1] = "dearer" end
          if e.dTime and e.dTime > 0.5 then why[#why + 1] = "slower" end
          if #why == 0 then
            why[#why + 1] = sv and "no worse at today's prices: they have moved since the plan was started" or "the route as a whole came out better with the other recipe"
          end
          e.why = why
          list[#list + 1] = e
        end
      end
    end
  end
  table.sort(list, function(x, y)
    if x.far ~= y.far then return y.far end     -- ones the plan may use, at a known price, first
    if x.part ~= y.part then return y.part end   -- then ones that cover the whole range
    if abs(x.score - y.score) > 1e-9 then return x.score < y.score end
    return x.r.i < y.r.i
  end)
  for k = #list, (limit or 4) + 1, -1 do list[k] = nil end
  g.alts, g.altsV = list, v
  return list
end

-- One line of words for an alternate: its difference from the step's recipe, what a point costs, why it was not chosen.
function NS.altLine(a)
  local parts = {}
  if a.dNet and abs(a.dNet) >= 0.5 then parts[1] = diffMoney(a.dNet) else parts[1] = a.dNet and "the same cost" or nil end
  if a.dTime and abs(a.dTime) >= 0.5 then parts[#parts + 1] = diffTime(a.dTime) end
  local text = (#parts > 0 and (table.concat(parts, ", ") .. " \194\183 ") or "")
    .. (a.perPoint < 0 and ("earns " .. money(a.perPoint)) or money(a.perPoint)) .. " a point \194\183 " .. span(a.time)
  return text, table.concat(a.why, "; ")
end

-- ---- Use instead, and Undo ---------------------------------------------------------------------------------------------

local function retotal(P)
  local t = { cost = 0, net = 0, crafts = 0, time = 0, gaps = 0, points = P.to - P.from, learn = 0 }
  for _, s in ipairs(P.steps) do
    if s.id == 0 then
      t.gaps = t.gaps + (s.to - s.from)
    else
      t.cost, t.net, t.time = t.cost + (tonumber(s.cost) or 0), t.net + (tonumber(s.net) or 0), t.time + (tonumber(s.time) or 0)
      if not s.stock then t.crafts = t.crafts + s.crafts end
      for _, e in ipairs(type(s.learn) == "table" and s.learn or {}) do t.learn = t.learn + (tonumber(e.cost) or 0) end
    end
  end
  P.tot = t
end

-- Adds (sign 1) or takes off (sign -1) one step's buy list from the whole route's; touched = the items whose
-- quantity moved, which are then priced again at today's listings. Every other line stays as it was saved.
local function shopDelta(whole, shop, sign, touched)
  local function move(list, rows, fill)
    for _, b in ipairs(type(rows) == "table" and rows or {}) do
      local e
      for _, x in ipairs(list) do
        if x.item == b.item then e = x end
      end
      if not e then
        e = fill(b)
        e.item, e.qty = b.item, 0
        list[#list + 1] = e
      end
      e.qty = e.qty + sign * b.qty
      touched[b.item] = true
    end
    for i = #list, 1, -1 do
      if list[i].qty <= 1e-6 then table.remove(list, i) end
    end
  end
  if type(shop) ~= "table" then return end
  move(whole.buy, shop.buy, function(b) return { how = b.how, part = b.part, listed = b.listed } end)
  move(whole.made, shop.made, function(b) return { id = b.id } end)
  move(whole.have, shop.have, function(b) return { part = b.part } end)
end
local function reprice(whole, ctx, touched)
  local sum = 0
  for _, b in ipairs(whole.buy) do
    if touched[b.item] then
      local p = ctx.part(b.item)
      local stat
      if p then stat = p.buy else stat = ctx.matCost(b.item).c end
      local sup = ctx.supplyOf(b.item, stat)
      b.cost, b.short = nil, nil
      if #sup.steps > 0 or sup.after ~= nil then
        local x = E.supCost(sup, 0, b.qty)
        b.cost, b.short = x.cost, x.short
      end
      b.top = NS.payUpTo(ctx, b.item, b.qty)
    end
    sum = sum + (tonumber(b.cost) or 0)
  end
  whole.cost = sum
end

-- What is left of a saved step from skill `at` on: the same recipe, the chances of the levels that remain, cost and
-- time in proportion to the crafts.
local function restOf(old, at, ctx)
  local B = { id = old.id, from = at, to = old.to, rest = true, secs = old.secs, casts = old.casts, way = old.way, capped = old.capped, over = old.over, cs = {} }
  local exp = 0
  for k = at - old.from + 1, #old.cs do
    B.cs[#B.cs + 1] = old.cs[k]
    exp = exp + 1 / old.cs[k]
  end
  B.exp, B.crafts = exp, ceil(exp - 1e-6)
  local share = B.crafts / max(1, old.crafts)
  B.cost, B.net, B.time = (old.cost or 0) * share, (old.net or 0) * share, (old.time or 0) * share
  B.learn = old.learn or {}
  local r = data().byId[old.id]
  if r then
    B.shop = packShop(ctx, ctx.shopping({ { r = r, crafts = B.crafts } }, true))
    local b = NS.stepBuffer(ctx, { r = r, cs = B.cs, crafts = B.crafts })
    if b then B.safe, B.safeCost = b.safe, b.extra end
  end
  return B
end

-- Replaces the recipe of one step of a started plan (the step shown on the Level page). The plan is started first
-- when it is not: a plan that is not started would simply be planned again and lose the choice. The new recipe has
-- the step's range when it gives points to its end; otherwise it takes the levels it can and the planned recipe
-- keeps the rest, as a second step. No other step changes. Returns true, or false and why.
function NS.useInstead(recipeID)
  local sh = NS.levelStep and NS.levelStep() or nil
  local cur = NS.current()
  if not (sh and cur and cur.route and sh.g and sh.g.r) then return false, "No step is selected." end
  local r = data().byId[recipeID or 0]
  if not r or r == sh.g.r then return false, "Not another recipe." end
  local i, prof, ctx, st = sh.i, cur.prof, cur.ctx, cur.st
  local P = cur.started
  if not P then
    local why
    P, why = NS.startPlan()
    if not P then return false, why end
  end
  local old = P.steps[i]
  if not old or old.id == 0 or old.stock then return false, "This step cannot be changed." end
  if old.own or old.rest then return false, "Undo your choice for this step first." end
  local a = ctx.stepFor(r, old.from, old.to)
  if not a then return false, r.name .. " gives no point at " .. old.from .. "." end
  -- Learning the new recipe is counted once in the plan: not here when an earlier step already learns it, and a
  -- later step's learn line of it comes here (as it was saved) instead of a second one being added.
  local need = {}
  local known = st.known ~= nil and st.known[r.id] == true
  local took
  if not known then
    local function lineOf(step)
      for n, e in ipairs(type(step.learn) == "table" and step.learn or {}) do
        if type(e) == "table" and e.id == r.id then return n, e end
      end
    end
    local earlier = false
    for k = 1, i - 1 do
      if lineOf(P.steps[k]) then earlier = true end
    end
    if not earlier then
      for k = i + 1, #P.steps do
        local n, e = lineOf(P.steps[k])
        if n then
          table.remove(P.steps[k].learn, n)
          took = { line = e, step = P.steps[k].id, from = P.steps[k].from }   -- where it came from, for Undo
          break
        end
      end
      if not took then
        local text, cost = NS.learnText(ctx, r)
        local li = ctx.learnInfo and ctx.learnInfo(r) or {}
        need[1] = { r = r, cost = cost, li = li, text = text }
      end
    end
  end
  local A = packStep(ctx, a, need)
  A.own, A.orig = true, old
  if took then
    A.took = took
    A.learn[#A.learn + 1] = { id = took.line.id, cost = took.line.cost, unk = took.line.unk, text = took.line.text }
  end
  local new = { A }
  if a.to < old.to then
    new[2] = restOf(old, a.to, ctx)
    if not known then   -- what is left of the planned step does not learn the new recipe a second time (as a part's recipe)
      local keep = {}
      for _, e in ipairs(new[2].learn) do
        if not (type(e) == "table" and e.id == r.id) then keep[#keep + 1] = e end
      end
      new[2].learn = keep   -- a list of its own: the planned step's is kept as it was, for Undo
    end
  end
  -- what the planned recipe had to learn stays with what is left of it, or goes to the next step that uses it
  if not new[2] then
    for _, e in ipairs(type(old.learn) == "table" and old.learn or {}) do
      if e.id == old.id then
        for k = i + 1, #P.steps do
          if P.steps[k].id == old.id then
            P.steps[k].learn = P.steps[k].learn or {}
            table.insert(P.steps[k].learn, 1, e)
            A.moved = k - i   -- its learn line went to a later step; Undo finds it there by the recipe's id
            break
          end
        end
      end
    end
  end
  local touched = {}
  shopDelta(P.shop, old.shop, -1, touched)
  for _, s in ipairs(new) do shopDelta(P.shop, s.shop, 1, touched) end
  reprice(P.shop, ctx, touched)
  table.remove(P.steps, i)
  for k, s in ipairs(new) do table.insert(P.steps, i + k - 1, s) end
  retotal(P)
  P.rev = (P.rev or 0) + 1
  if NS.levelPick then NS.levelPick(r.id, old.from) end
  NS.refresh()
  return true
end

-- Puts the planned recipe back into step i (the step you chose, or what was left of the planned one after it).
function NS.undoStep(i)
  local cur = NS.current()
  local P = cur and cur.started or NS.startedPlan()
  if not (P and cur) then return false end
  local s = P.steps[i]
  if s and s.rest and P.steps[i - 1] and P.steps[i - 1].own then i, s = i - 1, P.steps[i - 1] end
  if not (s and s.own and type(s.orig) == "table") then return false end
  local old = s.orig
  local gone = { s }
  if P.steps[i + 1] and P.steps[i + 1].rest then gone[2] = P.steps[i + 1] end
  -- Learn lines that moved when the step was changed go back, found by recipe id: steps may have been added or
  -- taken out in between since, so a saved distance would point at the wrong step.
  if s.moved then   -- the planned recipe's own learn line, which went to a later step that uses the recipe
    local found = false
    for k = i + #gone, #P.steps do
      local later = P.steps[k]
      for n, e in ipairs(type(later.learn) == "table" and later.learn or {}) do
        if not found and later.id == old.id and type(e) == "table" and e.id == old.id then
          table.remove(later.learn, n)
          found = true
        end
      end
    end
  end
  if type(s.took) == "table" and type(s.took.line) == "table" then   -- the chosen recipe's learn line, taken from a later step
    local back
    for k = i + #gone, #P.steps do
      local later = P.steps[k]
      if not back and later.id == s.took.step and later.from == s.took.from then back = later end
      -- that step was changed by hand since: its planned version gets the line back
      if not back and type(later.orig) == "table" and later.orig.id == s.took.step and later.orig.from == s.took.from then back = later.orig end
    end
    for k = i + #gone, #P.steps do   -- its range moved since: the next step that makes the same recipe
      if not back and P.steps[k].id == s.took.step then back = P.steps[k] end
    end
    if back then
      if type(back.learn) ~= "table" then back.learn = {} end
      table.insert(back.learn, 1, s.took.line)
    end
  end
  local touched = {}
  for _, x in ipairs(gone) do shopDelta(P.shop, x.shop, -1, touched) end
  shopDelta(P.shop, old.shop, 1, touched)
  reprice(P.shop, cur.ctx, touched)
  for _ = 1, #gone do table.remove(P.steps, i) end
  table.insert(P.steps, i, old)
  retotal(P)
  P.rev = (P.rev or 0) + 1
  if NS.levelPick then NS.levelPick(old.id, old.from) end
  NS.refresh()
  return true
end

-- ---- the Shopping list ---------------------------------------------------------------------------------------------------

-- Puts a route on the Shopping list step by step: what is left of a started plan (from the step you are in, with
-- the crafts still expected there), or with "Buy for bad luck" on the counts that cover bad luck. Steps of the same
-- plan already on the list are replaced, not added to. Returns how many steps went on, and whether they are safe
-- counts.
-- The crafts a route still asks for, step by step: { { r, n, from, to, stock, g }, ... }. pr = where a started plan
-- stands (steps behind are left out, the current one has the crafts still expected in it); safe = the counts
-- that cover bad luck 9 times out of 10.
local function stepsLeft(ctx, route, pr, safe)
  local out = {}
  for i, g in ipairs(route.segs) do
    if g.r and not (pr and (pr.finished or i < (pr.step or 1))) then
      local n = g.all or g.crafts
      local b = NS.stepBuffer(ctx, g)
      if pr and i == pr.step and pr.left and not g.stock then
        n = safe and pr.safeLeft or pr.left
      elseif safe and b then
        n = b.safe
      end
      if n > 0 then out[#out + 1] = { r = g.r, n = n, from = g.from, to = g.to, stock = g.stock and true or nil, g = g } end
    end
  end
  return out
end
-- For whoever lists what a profession's route still buys (LedgerShop.lua's "route" entry): the started plan's
-- remaining steps as above, or nil when the profession has no started plan (then plan as before). safe = nil reads
-- the Buy for bad luck setting.
function NS.startedSteps(prof, safe)
  local route = NS.startedRoute(prof)
  if not route then return nil end
  local c = NS.state(prof)
  if safe == nil then safe = settings().routeSafe == true end
  return stepsLeft(c.ctx, route, NS.planProgress(route.started, c.st), safe), route
end

function NS.addPlanToShopping()
  local cur = NS.current()
  if not (cur and cur.route and NS.shopAdd) then return 0 end
  local safe = settings().routeSafe == true
  local P = cur.started
  local pr = P and NS.planProgress(P, cur.st) or nil
  local want = {}
  for _, x in ipairs(stepsLeft(cur.ctx, cur.route, pr, safe)) do
    want[#want + 1] = { kind = "step", prof = cur.prof, id = x.r.id, n = x.n, from = x.from, to = x.to, stock = x.stock, plan = cur.prof }
  end
  -- Every step this button put on the list for the profession goes first (they carry plan = the profession), so
  -- steps finished since, or moved by other counts, leave no entry behind. A step entry without the mark (added
  -- one by one from a step, or by this button before the mark existed: the two cannot be told apart) stays,
  -- unless it is exactly one of the steps going on now, which is replaced and not added to.
  local ticks = {}   -- taking the last entry off empties the ticks: the ones there now are kept
  if type(NS.shopEntries) == "function" and type(NS.shopRemove) == "function" then
    local list = NS.shopEntries()
    local sh = settings().shop
    for item, on in pairs(type(sh) == "table" and type(sh.done) == "table" and sh.done or {}) do ticks[item] = on end
    for k = #list, 1, -1 do
      local e = list[k]
      if type(e) == "table" and e.kind == "step" and e.prof == cur.prof then
        local gone = e.plan == cur.prof
        if not gone and e.plan == nil then
          for _, w in ipairs(want) do
            if w.id == e.id and w.from == e.from and w.to == e.to then gone = true break end
          end
        end
        if gone then NS.shopRemove(k) end
      end
    end
  end
  local n = 0
  for _, w in ipairs(want) do
    if NS.shopAdd(w) then n = n + 1 end
  end
  if n > 0 and type(NS.shopTick) == "function" then
    local sh = settings().shop
    for item, on in pairs(ticks) do
      if on == true and type(sh) == "table" and type(sh.done) == "table" and sh.done[item] ~= true then NS.shopTick(item, true) end
    end
  end
  return n, safe
end

-- ---- /kebold cheap and /kebold fast ----------------------------------------------------------------------------------------
-- The two old words set what the presets set: "fast" the Fastest preset (Ledger.lua does that itself, S.fast),
-- "cheap" the Cheapest one, which is S.fast off AND time worth 0. The command is wrapped, not replaced.
do
  local was = SlashCmdList and SlashCmdList["KEBOLDSSHINY"]
  if type(was) == "function" then
    SlashCmdList["KEBOLDSSHINY"] = function(msg, ...)
      local cmd = string.lower(tostring(msg or ""):match("^%s*(.-)%s*$"))
      if cmd == "cheap" then
        settings().opts.timeValue = 0
        NS.bump()
      end
      return was(msg, ...)
    end
  end
end
