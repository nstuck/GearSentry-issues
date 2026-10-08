# GearSentry

## v0.3.1

- GearSentry is now open source under the MIT license. The source of every release is on GitHub: [nstuck/GearSentry](https://github.com/nstuck/GearSentry).

## v0.3.0

- Upgrades that are already in your bags when you log in or reload now get the pop-up a few seconds after you enter the world. Before, they only showed in the tooltip and bag arrows. Turn this off with "Alert for upgrades already in bags at login" in the options.

## v0.2.0

- **Weight profiles**: each class gets read-only default profiles (e.g. "Paladin DPS - Default"), and you can make your own: create, copy, rename and delete them. Your profiles are shared across your characters of the same class. Pick the active one with `/gs profile` (`/gs scale` still works); your earlier scale choice carries over.
- **Stat Weights page** (`/gs weights`, or Options → AddOns → GearSentry → Stat Weights): edit every stat weight in a profile. Edits stay unsaved until you click **Save**; **Discard** drops them, and leaving the page or switching profiles asks first. **Apply** makes the shown profile the active one.
- **Import / Export**: share a profile as a text string and paste one in from someone else.
- The chat confirmation after equipping now names the item (e.g. "Equipped [Runed Copper Bracers]").
- New GearSentry icon in the AddOns list and the addon compartment.

## v0.1.0 (first beta)

First public release, for World of Warcraft: Forever.

- **Upgrade pop-up** when an item in your bags beats what you're wearing, with one-click **Equip** and **Ignore**. Several upgrades queue up. Drag it anywhere; the position is remembered.
- **Tooltip line** on any item (bags, vendors, loot, chat links, Auction House) saying whether it's an upgrade and by how much.
- **Bag arrows** on upgrades in the default bags and in BetterBags (pick GearSentry as the "Upgrade Icon Provider" in `/bb`).
- **Paired slots and weapons**: rings and trinkets are compared against both equipped items; two-handers are weighed against main hand + off-hand or shield, including dual wield.
- **Class stat weights** with optional role scales (`/gs scale`), aware of Forever's school spell damage and weapon skill stats.
- **Bind on Equip** items are suggested with a warning (can be turned off); items with special effects are flagged.
- **Options panel** (`/gs options`, Options → AddOns, or the addon compartment): tooltip line, bag arrows, pop-up sound, BoE items, armor type filter, minimum gain, reset ignored items, reset pop-up position.
- Never equips without your click, and never in combat.
