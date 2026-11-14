# Kebold's Shiny

An addon for WoW Forever: leveling routes and crafting profit from live auction house prices, inside the
game. It reads and plans; it never crafts, buys, posts, cancels or learns anything, and it needs no other addon.

It has four parts:

1. **The Kebold window** (`/kebold`): eight pages on a rail at the left.
2. **A Kebold tab inside the auction house**: the scans and what the last one found.
3. **A block inside the profession window**: the selected recipe's figures.
4. **Collectors that run by themselves**: what the game shows about recipes, trainers, vendors, vendor values,
   Legacy talents and your own auctions.

Nothing has a price until it was scanned: open the auction house and run a scan first.

## Install

1. On <https://github.com/joemoffett1/Kebolds-Shiny> click the green **Code** button, then **Download ZIP**, and
   unzip it.
2. Copy the `KeboldsShiny` folder from inside it into `World of Warcraft\_forever_\Interface\AddOns\`, so that
   `...\AddOns\KeboldsShiny\KeboldsShiny.toc` exists.
3. Restart the game. After copying a newer version over an old one, restart the game too.
4. Open the auction house, click the **Kebold** button under it and run **Quick scan**. Then type `/kebold`.

What to expect on your own character:

- Everything it knows about you it reads itself, while you play: open each of your profession windows once (your
  known recipes and skill), visit the vendors and trainers you use, and scan at the auction house. Until then it
  plans from the data it shipped with.
- Prices are kept per realm. Vendor prices are only used when a character of your own faction read them.
- The game does not need to be in English for your professions to be recognised. Legacy talents, however, are
  found by their English names: if Settings says a rank was "not read from the game", type your rank there.
- Much of the shipped data (who sells or teaches what, and where) is the original game's and can be wrong for
  Forever; what the addon reads in game replaces it.

## The window's pages

| page | what it is for |
|---|---|
| **Level** | The cheapest or the fastest route from one skill to another for any of the nine professions, yours or not. A strip of six figures (points covered, crafts, casting, materials, to learn, after sales), the steps as a table, and beside it the selected step: what to learn first and where, what to buy and what to pay up to, its choices. "Whole route" shows everything the route buys, the parts (buy or make), where each product sells, and the recipes to learn. The window's footer on this page says what is wrong with the plan (prices missing, a skill range with no usable recipe and why) beside the scans. |
| **Craft** | Every recipe of the profession: learn level, source, chance of a point, cost, what it sells for, profit, profit per hour, how many are worth making and the total. A click opens the recipe's details: materials, the three ways of getting its parts, the price steps, a buy list for any number of crafts, and "Add to list". |
| **Disenchant** | Every piece of gear the nine professions make that can be disenchanted: what it disenchants into, what that is worth, the craft's materials, profit and profit per hour, against what a vendor and the auction house pay. A click shows every outcome with its chance. The outcome table is the original game's (marked `~`, not confirmed for Forever) until 20 of your own disenchants of a band are logged. Kebold never disenchants anything itself. |
| **Crates** | Waylaid Crates: for each of the 30, the Merchant's Favor it gives, the cheapest thing to fill it with and what that costs, what one point of Favor costs, the crate's own auction price, and how many you hold. A click shows every option (bought or made), the reward and where to hand it in. Everything about the crates is from guide sites of the beta, not seen in game: Expert Favor is an estimate (`~`), Artisan Favor is not known (`?`) until typed on the Settings page. Kebold never fills or hands in a crate. |
| **Shopping** | One list of what to buy for the things you added (a route step, a whole route, crafts of a recipe, your favourites, plain items): your bags are taken off, every line says what price to pay up to, parts you make are opened into their materials, and lines can be ticked off. Parts made ahead for later steps are counted once. |
| **Prices** | The scans (this plan, this route, whole profession, materials and parts, everything, disenchant materials, crate materials, favourites, shopping list), what the last scan found, how complete each profession's prices are, and vendor values the game reports differently from the shipped data. |
| **My sales** | Your own auctions: posted, sold, expired and cancelled per item, recent events, and the price history of the scans. |
| **Settings** | Whose plan it is, the numbers the calculations use, the look (Row size, coins, icons, window scale), where Kebold's buttons and figures sit, your choices, and what was read from the game. |

Things that are the same everywhere:

- **The plan** is the profession, the skill range, which recipes may be used and where products sell (the bar at
  the top of Level and Craft). **The route** is the list of steps planned from it.
- **Sells at**: best price (vendor or auction house, whichever pays more; gear counts at vendor value), vendor, or
  not counted. One product can be set on its own with a right-click: Auto, Vendor, Auction house.
- **Materials and parts**: a part is a material another recipe makes. Each can be set to Auto, Buy, Make or Have it
  (you have it already: it costs nothing and is not bought).
- **Skip**: a skipped recipe is never used by a route.
- **Marks**, each with one meaning; the `?` button beside a page's name shows the key: `~` an estimate, `*` your own
  choice, `»` a favourite, `?` not known, `!` (beside Prices on the rail) prices are missing for the plan.
- **Row size** (Settings): compact, normal or roomy lines in every list. The window is at least 1010 wide with
  normal rows, 1050 with roomy ones and 920 with compact ones.
- Right-click a line for its choices; Shift-click links it in chat.

### Plans for somebody else

"Plan for" (first control of the plan bar, and the first card of Settings) switches between **Me** and a
**profile**: a plan for another player, with their faction and Legacy ranks (Working Overtime, Master Chef,
Bartering), no known recipes, no bags, and their own ranges and choices. "Copy plan" on the Level page (or
`/kebold copy`) gives the route as text to hand over. While a profile is shown, the block in the profession window,
the strip above it and the item tooltips still show your own figures: there you craft as yourself.

## At the auction house

A **Kebold** button sits under the auction house window (or above its title bar: Settings). A left-click shows the
Kebold's page inside the auction house: a button for each scan, Stop, the progress, and the items of the running or
last scan with cheapest price, listed, vendor value and how the price compares with the usual one. A click on an
item searches it on the Buy page. A right-click on the button is a menu of the same scans. Keep the auction house
open while a scan runs; closing it stops the scan and keeps what was collected.

The Kebold window opened from there sits beside the auction house when there is room for it on the screen.

## In the profession window

A small block under the selected recipe (or a strip above the window: Settings) shows vendor value, auction house
value, profit and profit per hour, the chance of a point at your skill and how many are worth making, with a Kebold
button and a Scan button for that recipe. Item tooltips get Kebold lines too: the scanned price, a vendor's price,
what making the item costs and earns, and what a recipe item teaches.

## Commands

| command | what it does |
|---|---|
| `/kebold` | opens or closes the window |
| `/kebold bs` (`lw`, `tailoring`, `eng`, `alch`, `ench`, `cook`, `firstaid`, `mining`) | plans that profession |
| `/kebold from <skill or auto>`, `/kebold to <skill or auto>`, `/kebold mine` | the skill range; `mine` goes back to your own skill and cap |
| `/kebold trainer`, `buyable`, `all` | which recipes the route may use: a trainer's only, also recipe items a vendor sells or that are listed, also guessed sources |
| `/kebold sales best`, `vendor`, `off` | Sells at |
| `/kebold cheap`, `/kebold fast` | cheapest or fastest route |
| `/kebold tab level`, `craft`, `disenchant`, `crates`, `shopping`, `prices`, `sales`, `settings` | opens on that page |
| `/kebold print`, `/kebold copy` | the page's lines in chat; the route as text in a box to copy from |
| `/kebold strip pane`, `top`, `off` | the recipe figures at the profession window: under the recipe, above the window, off |
| `/kebold skin plain`, `auto` | plain widgets instead of Blizzard's (then `/reload`) |
| `/kebold ui`, `/kebold ui gallery` | what this client has; every widget in both looks |
| `/keboldscan` | scans the materials and parts of all nine professions (about 460 items, 5 minutes) |
| `/keboldscan bs` | what the plan for that profession could use (about 60 items for Blacksmithing 150 to 225) |
| `/keboldscan bs all` | every material, part, product and recipe item of the profession |
| `/keboldscan route`, `fav`, `shop`, `recipe <spell id>` | the route on the Level page, your favourites, the shopping list, one recipe |
| `/keboldscan de` | the 24 dusts, essences, shards and crystals a disenchant can give (the Disenchant page's prices) |
| `/keboldscan crates` | the 96 things a Waylaid Crate can be filled with and the 30 crates themselves (the Crates page's prices, about 2 minutes) |
| `/keboldscan everything` | every item any recipe makes or uses (about 3,800 items, 42 minutes; materials first) |
| `/keboldscan quick` | Quick scan: the whole auction house in ONE request, a full ladder for every item Kebold knows (about a minute; the game allows it once per 15 minutes). If the server does not answer in 30 seconds it reads gear only |
| `/keboldscan gear` | Gear (quick): one browse of armour and weapons, uncommon and better. Cheapest price and number listed per item, no price steps |
| `/keboldscan mats`, `parts`, `all`, `<item ids>` | the older fixed lists, or just those items |
| `/keboldscan status`, `stop` | progress; end the scan |
| `/keboldshop` | the shopping list in chat; `add recipe <spell id> [n]`, `add item <item id> [n]`, `add route [profession]`, `add favs [n]`, `qty <line> <n>`, `remove <line>`, `clear`, `tick <item id>`, `untick <item id>` |
| `/keboldde` | your logged disenchants: how many, per band whether the rates are measured yet, the cast time; `log` the last lines, `debug` what the watcher saw |
| `/keboldsales` | your auctions in chat; `<part of a name>`, `log [lines]`, `auto on`, `auto off` |
| `/keboldah` | shows or hides the auction house tab's page; `follow on`, `follow off`, and `level`, `strata`, `inset`, `reset`, `tabs` to tune where it sits |
| `/keboldcollect` | what was collected; `legacy` reads the Legacy talents now; `off`, `on`; `chat on`, `chat off` = a chat line for every profession, trainer and vendor read (off unless you switch it on) |

## What it collects by itself

Always on and read-only, saved under `KeboldsShinyDB.collect`:

- **Open a profession window**: every recipe of it, learned or not, with its materials, the item made, how many,
  the skill colour and where it goes grey. Kebold takes your known recipes from this.
- **Talk to a trainer**: what is taught, the skill needed and the fee. A trainer read in game replaces the shipped
  guess about what he teaches (unless the trainer window's filters could not be read, when the list may be
  incomplete and is only kept).
- **Open a vendor**: every item with its price (your discounts included) and stock. Only prices read by a
  character of the faction being planned for are used.
- **Vendor values**: read for every item a scan or the collector touches; one that differs from the shipped data
  is listed on the Prices page.
- **Legacy talents**: your ranks.
- **Your own auctions** (`Sales.lua`): posted, sold, expired, cancelled. After five finished auctions of an item
  its share sold replaces the AH sales cap for that product.

## The saved file

```
World of Warcraft\_forever_\WTF\Account\<ACCOUNT>\SavedVariables\KeboldsShiny.lua
```

The game writes it at `/reload` or on logging out. Kebold itself reads everything from memory, so no reload is
needed after a scan.

Prices are kept per realm, one line an item: `[itemID] = "<day>;<total quantity>;<unit price in copper>:<quantity>,..."`
(up to 40 price steps, cheapest first; `<day>` is days since 2020-01-01 UTC; nothing listed is `"<day>;0;"`).
Nothing about sellers is stored. An item's line is replaced when a scan reaches it, so a scan stopped part-way
keeps the older prices of what it did not reach. Each scan also appends one reading an item a day (30 days) to
`hist`, and writes a `log` with one line an item:

```
2589 timeout 5.0s rows=0 cached=yes key=unknown thr=SR
```

the item, how it ended (`commodity`, `item`, `lastlook`, `timeout`, `noload`), the seconds it took, the rows the
game held, whether the item's data was loaded, what the auction house knew it as, and the throttle events seen.
`noload` means the game could not load the item at all: it does not exist in Forever.

## If a scan only times out

The game only answers a search for an item whose data it has loaded, so the scan loads each item first. If scans
still time out:

1. Open the auction house and type `/keboldscan debug` (Wool Cloth), or `/keboldscan debug <item id>` for an item
   you know is listed.
2. Leave the auction house open for 60 seconds. When the chat line starting with `NOW` appears, search for the same
   item by hand and click it in the results.
3. At `debug finished`, type `/reload`. The log is the `debug` list of `KeboldsShinyDB` in the saved file.
