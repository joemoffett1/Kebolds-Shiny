-- Kebold's Shiny: Waylaid Crates (static data, written by hand; LedgerCrates.lua is the model and the page)
--
-- WHERE THIS COMES FROM: guide sites written during the beta (zockify, method.gg, foreverdiff, wowf.io,
-- theforeverguides), collected 2026-11-11. NOTHING HERE HAS BEEN SEEN IN GAME. What the sites say:
-- * A Waylaid Crate is filled with ONE of its listed options (an item at a quantity) and becomes a Sealed crate,
--   which is handed in for Merchant's Favor (a per-character currency: the "points") and a little silver. No
--   reputation per crate. Crates drop from mobs and can be traded and auctioned; a sealed crate binds.
-- * Hand in: Horde at Dokimi, Durotar Supply and Logistics, west of the Crossroads in the Barrens (about 50.0,
--   29.2); Alliance at Marcy Baker, Three Corners, Redridge Mountains (about 9.6, 71.0). The first hand-in ever
--   gives a Shipping Label quest: 50 Favor, once.
-- * Favor and silver per sealed crate: "raw" crates (Herbs, Ore, Textiles, Curiosities) and "goods" crates
--   (Fabrics, Ingots, Parts), which give double. Apprentice 5 / 10 Favor and 2s 50c / 5s; Journeyman 10 / 20 and
--   5s / 10s; Expert 15 / 30 and 7s 50c / 15s (ONE site, beta: an estimate, shown with ~); Artisan: not known
--   (shown with ?, until a value is typed on the Settings page).
-- * Legacy talent Performance Bonus: 5 / 10 / 15% chance (rank 1 to 3) that a hand-in gives double Favor.
-- * Level needed: Apprentice 10, Journeyman 10, Expert 20, Artisan 35.
--
-- IDS: every material id below was checked against the names in Data.lua and the original game's item data
-- (2026-11-11: all 96 agree). Two were NOT given by the sites and are the original game's ids for the name
-- (`guess = true`): Gold Power Core 10558, Dark Iron Ore 11370. The 30 crate ids (248682 to 248713) are the
-- sites' and cannot be checked outside the game: the price scan's log says "noload" for an id the client does
-- not have. The crates' own names in game are not known either: the labels here are tier + kind.
--
-- One entry: { id = crate item id, tier = 1..4, name = kind, goods = true for the double-Favor crates,
--   options = { { quantity, item id [, doubt = "..."] [, guess = true] }, ... } }
KeboldsShinyCrates = {
  source = "guide sites from the beta (zockify, method.gg, foreverdiff, wowf.io, theforeverguides); not seen in game",
  -- favor / silver (copper) for a raw crate and a goods crate; est: an estimate (~); nil: not known (?)
  tiers = {
    { key = "apprentice", name = "Apprentice", level = 10, raw = { favor = 5, silver = 250 }, goods = { favor = 10, silver = 500 } },
    { key = "journeyman", name = "Journeyman", level = 10, raw = { favor = 10, silver = 500 }, goods = { favor = 20, silver = 1000 } },
    { key = "expert", name = "Expert", level = 20, est = true, raw = { favor = 15, silver = 750 }, goods = { favor = 30, silver = 1500 } },
    { key = "artisan", name = "Artisan", level = 35, raw = {}, goods = {} },
  },
  perfStep = 0.05,   -- Performance Bonus: chance of double Favor a rank
  perfMax = 3,
  firstFavor = 50,   -- the Shipping Label quest of the first hand-in, once
  turnIn = {
    H = { npc = "Dokimi", place = "Durotar Supply and Logistics, west of the Crossroads", zone = "The Barrens", x = 50.0, y = 29.2 },
    A = { npc = "Marcy Baker", place = "Three Corners", zone = "Redridge Mountains", x = 9.6, y = 71.0 },
  },
  list = {
    -- Apprentice
    { id = 248685, tier = 1, name = "Curiosities", options = { { 20, 10940 }, { 4, 10939 }, { 6, 10978 }, { 2, 11084 } } },   -- Strange Dust, Greater Magic Essence, Small / Large Glimmering Shard
    { id = 248702, tier = 1, name = "Fabrics", goods = true, options = { { 2, 4231 }, { 20, 2996 } } },                       -- Cured Light Hide, Bolt of Linen Cloth
    { id = 248682, tier = 1, name = "Herbs", options = { { 20, 2447 }, { 20, 765 }, { 10, 2449 }, { 10, 785 }, { 10, 2450 } } },   -- Peacebloom, Silverleaf, Earthroot, Mageroyal, Briarthorn
    { id = 248703, tier = 1, name = "Ingots", goods = true, options = { { 20, 2840 }, { 20, 3576 }, { 10, 2841 } } },         -- Copper Bar, Tin Bar, Bronze Bar
    { id = 248683, tier = 1, name = "Ore", options = { { 20, 2770 }, { 20, 2771 } } },                                        -- Copper Ore, Tin Ore
    { id = 248704, tier = 1, name = "Parts", goods = true, options = { { 16, 4359 }, { 16, 4361 }, { 4, 4363 } } },           -- Handful of Copper Bolts, Copper Tube, Copper Modulator
    { id = 248684, tier = 1, name = "Textiles", options = { { 40, 2589 }, { 20, 2318 } } },                                   -- Linen Cloth, Light Leather
    -- Journeyman
    { id = 248689, tier = 2, name = "Curiosities", options = { { 20, 11083 }, { 4, 11082 }, { 6, 11138 }, { 2, 11139 } } },   -- Soul Dust, Greater Astral Essence, Small / Large Glowing Shard
    { id = 248705, tier = 2, name = "Fabrics", goods = true, options = { { 6, 2997 }, { 10, 4305 }, { 2, 4233 } } },          -- Bolt of Woolen Cloth, Bolt of Silk Cloth, Cured Medium Hide
    { id = 248686, tier = 2, name = "Herbs", options = { { 10, 3820 }, { 10, 2453 }, { 10, 3355 }, { 10, 3369 }, { 10, 3356 } } },   -- Stranglekelp, Bruiseweed, Wild Steelbloom, Grave Moss, Kingsblood
    { id = 248706, tier = 2, name = "Ingots", goods = true, options = { { 10, 2842 }, { 20, 3575 } } },                       -- Silver Bar, Iron Bar
    { id = 248687, tier = 2, name = "Ore", options = { { 10, 2775 }, { 20, 2772 } } },                                        -- Silver Ore, Iron Ore
    { id = 248707, tier = 2, name = "Parts", goods = true, options = { { 8, 4371 }, { 7, 4375 }, { 4, 4382 },                 -- Bronze Tube, Whirring Bronze Gizmo, Bronze Framework
      { 45, 10558, guess = true, doubt = "Gold Power Core's item id is the original game's (the sites give none)." } } },
    { id = 248688, tier = 2, name = "Textiles", options = { { 20, 2592 }, { 40, 4306 },                                       -- Wool Cloth, Silk Cloth
      { 20, 2319, doubt = "One site says the beta took 40 Medium Leather, not 20." } } },
    -- Expert
    { id = 248690, tier = 3, name = "Earthly Herbs", options = { { 20, 3357 }, { 10, 3818 }, { 10, 3821 }, { 10, 3358 } } },  -- Liferoot, Fadeleaf, Goldthorn, Khadgar's Whisker
    { id = 248691, tier = 3, name = "Flowering Herbs", options = { { 10, 3819 }, { 10, 4625 }, { 20, 8831 }, { 10, 8836 } } },   -- Wintersbite, Firebloom, Purple Lotus, Arthas' Tears
    { id = 248694, tier = 3, name = "Curiosities", options = { { 20, 11137 }, { 4, 11135 }, { 6, 11177 }, { 2, 11178 } } },   -- Vision Dust, Greater Mystic Essence, Small / Large Radiant Shard
    { id = 248708, tier = 3, name = "Fabrics", goods = true, options = { { 8, 4339 }, { 2, 4236 } } },                        -- Bolt of Mageweave, Cured Heavy Hide
    { id = 248709, tier = 3, name = "Ingots", goods = true, options = { { 20, 3860 }, { 15, 3859 }, { 10, 3577 } } },         -- Mithril Bar, Steel Bar, Gold Bar
    { id = 248692, tier = 3, name = "Ore", options = { { 10, 2776 }, { 20, 3858 } } },                                        -- Gold Ore, Mithril Ore
    { id = 248710, tier = 3, name = "Parts", goods = true, options = { { 8, 4387 }, { 5, 10559 }, { 12, 10560 }, { 5, 10561 } } },   -- Iron Strut, Mithril Tube, Unstable Trigger, Mithril Casing
    { id = 248693, tier = 3, name = "Textiles", options = { { 40, 4338 }, { 20, 4234 } } },                                   -- Mageweave Cloth, Heavy Leather
    -- Artisan
    { id = 248699, tier = 4, name = "Curiosities", options = { { 20, 11176 }, { 4, 11175 }, { 6, 14343 }, { 2, 14344 } } },   -- Dream Dust, Greater Nether Essence, Small / Large Brilliant Shard
    { id = 248711, tier = 4, name = "Fabrics", goods = true, options = { { 8, 14048 }, { 2, 8172 } } },                       -- Bolt of Runecloth, Cured Thick Hide
    { id = 248712, tier = 4, name = "Ingots", goods = true, options = { { 2, 11371 }, { 10, 6037 }, { 20, 12359 } } },        -- Dark Iron Bar, Truesilver Bar, Thorium Bar
    { id = 248697, tier = 4, name = "Ore", options = { { 10, 7911 }, { 20, 10620 },                                           -- Truesilver Ore, Thorium Ore
      { 20, 11370, guess = true, doubt = "Dark Iron Ore's item id is the original game's (the sites give none)." } } },
    { id = 248713, tier = 4, name = "Parts", goods = true, options = { { 5, 15994 }, { 5, 18631 }, { 2, 16000 } } },          -- Thorium Widget, Truesilver Transformer, Thorium Tube
    { id = 248698, tier = 4, name = "Textiles", options = { { 40, 14047 }, { 20, 4304 }, { 20, 8170 } } },                    -- Runecloth, Thick Leather, Rugged Leather
    { id = 248695, tier = 4, name = "Earthly Herbs", options = { { 10, 13464 }, { 20, 8838 }, { 10, 8839 }, { 10, 8845 }, { 10, 8846 } } },   -- Golden Sansam, Sungrass, Blindweed, Ghost Mushroom, Gromsblood
    { id = 248696, tier = 4, name = "Flowering Herbs", options = { { 20, 13463 }, { 20, 13465 }, { 20, 13466 }, { 20, 13467 } } },   -- Dreamfoil, Mountain Silversage, Plaguebloom, Icecap
  },
}
