# GearSentry

**Never miss an upgrade again.** GearSentry is a World of Warcraft: Forever addon that watches
your bags, compares every weapon and armor piece with what you're wearing, and tells you when
something is better. Then it equips the item with one click.

[Download on CurseForge](https://www.curseforge.com/wow/addons/gearsentry) ·
[What's new](CHANGELOG.md) · [Report a problem](#report-a-problem)

GearSentry is in **beta**, like Forever itself. See [Known limitations](#known-limitations).

**About this repository:** the [`GearSentry/`](GearSentry/) folder holds the source of the latest
release, the same files the CurseForge download installs, and each release is tagged. It's
open source under the [MIT license](LICENSE), but not open contribution: it's written and
maintained by one developer, so pull requests aren't accepted. Bug reports and ideas are very
welcome as [issues](../../issues/new/choose), and under the MIT license you're free to fork it and
change it for yourself.

**Contents:** [Report a problem](#report-a-problem) · [Features](#features) ·
[Options](#options) · [Commands](#commands) · [Known limitations](#known-limitations) ·
[Working as designed](#working-as-designed)

## Report a problem

**[Open a new issue](../../issues/new/choose)** and pick the form that fits:

- **Lua error**: you got a BugSack report or the default error pop-up.
- **Wrong upgrade suggestion**: GearSentry called something an upgrade that isn't, or missed one.
- **Bug**: something else broke or didn't happen.
- **Feature request**: an idea or a missing option.

The most useful thing you can paste for a suggestion problem is the output of `/gs eval` followed
by the item (type `/gs eval `, then shift-click the item into chat). It shows exactly how
GearSentry scored that item.

Before reporting, check [Working as designed](#working-as-designed): some things that look like
bugs are intentional.

## Features

### Upgrade alerts

- A small pop-up appears when you loot, buy or receive an item that's an upgrade.
- Upgrades that were already in your bags when you logged in or reloaded pop up a few seconds
  after you enter the world (can be turned off).
- Click **Equip** to put it on, or **Ignore** to stop being told about that item.
- Several upgrades at once? They queue up ("1 of 3").
- Drag the pop-up wherever you like; it remembers its position.
- An optional chime plays when a new upgrade pops up.
- After equipping, chat confirms what went on, e.g. "Equipped [Runed Copper Bracers]".

### Tooltip line

- Hover any item (bags, vendors, loot, chat links, the Auction House) to see whether it's an
  upgrade for you, and by how much.

### Bag arrows

- A green arrow marks upgrades directly on your bag slots.
- Works with the default Blizzard bags and with **BetterBags**. In BetterBags, open `/bb` and pick
  GearSentry as the "Upgrade Icon Provider".

### Smart comparisons

- **Rings and trinkets:** compares against both equipped items and replaces the one where the
  swap helps most. Respects Unique-Equipped.
- **Weapons:** weighs a two-hander against main hand plus off-hand or shield, and handles dual
  wielding.
- **Class-aware stat weights:** each class has sensible defaults, with role profiles where a class
  has more than one job:
  - Warrior: DPS / Tank
  - Paladin: DPS / Tank / Healer
  - Shaman: Melee / Caster / Healer
  - Druid: Feral / Caster / Healer
  - Priest: Caster / Healer
- **Forever's stats** are understood: per-school spell damage counts only for the schools your
  class casts, weapon skill bonuses only for the weapons you use, and profession bonuses are
  ignored.
- **Bind on Equip** items are suggested with a clear warning. You can turn them off entirely.
- Items with special "Equip:" or "Use:" effects are flagged so you can judge them yourself.

### Your own stat weights

- Open the **Stat Weights** page (`/gs weights`, or **Options → AddOns → GearSentry → Stat
  Weights**) to see every weight in a profile.
- The default profiles are read-only. **Copy** one, or start a **New** one, and tune it to your
  liking.
- Changes stay unsaved until you click **Save**. **Apply** makes the profile the one this
  character uses.
- Your profiles are shared across all your characters of the same class.
- **Export** a profile as a text string to share it, and **Import** one from someone else.

### Safe by design

- **Never equips anything without your click.**
- Never tries to equip in combat. Alerts wait until combat ends.
- Lightweight: event-driven, no constant polling, no libraries.

## Options

Open with `/gs options`, from **Options → AddOns → GearSentry**, or from the addon compartment
button on the minimap.

- Turn the tooltip line, bag arrows and pop-up sound on or off
- Alert for upgrades already in your bags when you log in (on by default)
- Include or skip Bind on Equip items
- Only suggest your best armor type (off by default: stats win)
- Minimum gain, as a percentage or an absolute score
- Reset ignored items and the pop-up position
- Debug output

## Commands

| Command | What it does |
|---|---|
| `/gs` or `/gearsentry` | Show the command list |
| `/gs options` | Open the options panel |
| `/gs scan` | Scan your bags for upgrades now |
| `/gs eval <item link or ID>` | Is this item an upgrade, and why? Shows the full score breakdown |
| `/gs profile [name\|default]` | Show or pick this character's stat weight profile |
| `/gs weights` | Open the Stat Weights page |
| `/gs alerts` | Show the current suggestions again |
| `/gs unignore` | Clear this character's ignored items |
| `/gs tooltip` | Toggle the tooltip line |
| `/gs arrows` | Toggle the bag arrows |
| `/gs armorfilter` | Toggle "only my best armor type" |
| `/gs debug` | Toggle debug output |

**Tip:** type `/gs eval` and shift-click an item into chat to see exactly how GearSentry scores it.

## Known limitations

These parts haven't been tested in every situation yet. If one goes wrong for you, a report helps
a lot.

- **Ring, trinket and dual-wield swaps:** equipping into the second ring, trinket or off-hand slot,
  and moving your main hand to the off hand.
- **Equip edge cases:** accepting or cancelling the Bind on Equip prompt from the pop-up, double
  clicks, and combat starting while a pop-up is up.
- **Bows, guns and wands:** their damage per second may not be read correctly, so they could be
  scored wrong or never suggested.
- **Forever-only stats:** "+Sword Skill"-style and "+Fire Damage"-style items, and random-suffix
  items ("of the Bear"), may score oddly.
- **Weapons you can learn but haven't trained** may still be suggested.
- **Dual wield:** off-hand weapons may be suggested slightly too early or too late for your class.
- **Talents:** a new talent point may not trigger a rescan right away (`/gs scan` does it).
- **`/gs options` in combat** may do nothing.
- **Armor types above level 30** (mail and plate from level 40) follow the usual rules; this can't
  be checked until the level cap is raised.
- **Login pop-up timing:** the pop-up for upgrades already in your bags should come about 10
  seconds after the loading screen; tell us if it's much later.
- **Stat weights** are sensible starting points, not simulation-perfect.

## Working as designed

Players sometimes report these as bugs, but they're intentional:

- Nothing is ever equipped automatically. Equip needs a click and is greyed out in combat.
- Upgrades already in your bags pop up again after every login or `/reload` (once per session)
  until you equip, ignore or drop them. Turn off "Alert for upgrades already in bags at login" to
  stop that.
- The default profiles ("Paladin DPS - Default") can't be edited: copy one, then edit the copy.
- Stat Weights edits do nothing until **Save**. Closing the page asks you to Save or Discard.
- Profiles are per class: another class's share string won't import, and a profile made on a
  Paladin isn't listed on a Mage.
- Right after login, nothing is scanned until your equipped items have finished loading.
- BetterBags arrows need GearSentry picked as BetterBags' "Upgrade Icon Provider".

## License

GearSentry is open source under the [MIT license](LICENSE).
