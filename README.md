# SpellTips

Spell tooltips that show the math: where each number comes from and which talents change it. Hold a key while hovering a spell.

> **This addon was written with AI assistance (Claude).** The code is generated and then tested in game by a human. Read it with that in mind, and expect some rough edges.

## What it shows

Hover a spell and hold a key:

| Held | You see |
|------|---------|
| nothing | the game's normal tooltip |
| **Alt** | your numbers (damage with your spell power or attack power, crit and hit, auras) and the talents you have picked, each with its effect on that number |
| **Alt + Shift** | also talents you could still take, and locked talents with the points still needed |

With the hold key down, the **mouse wheel** steps through the listed talents. Release the key to open the selected talent in the talent window.

Example (Revenge, holding Alt+Shift):

```
Damage
  • Improved Revenge [0/3]   +20%

LOCKED  (points still needed)
  ARMS
  • Impale [0/2]             needs 15 more
      Crit bonus +10%
  PROTECTION
  • Focused Rage [0/3]       needs 11 more
      Cost -1
```

Weapon abilities show the weapon, attack power and ability parts. Wands show the wand's own damage range.

## Settings

Type `/spelltips` (or `/stips`), or click the minimap button. A live preview tooltip appears where your tooltips normally do.

- **Hold key** and **more key**: Alt, Ctrl, Shift or None.
- **Always shown level**: show numbers or talents without holding a key.
- **Preview spell**: pick which spell the preview uses.
- **Colors**: every color the tooltip uses, with a picker.
- **Reset all**.

Settings are saved in `SpellTipsDB`.

### Slash commands

| Command | What it does |
|---------|--------------|
| `/spelltips` | open the settings window |
| `/spelltips reset` | reset all settings |
| `/spelltips minimap` | show or hide the minimap button |
| `/spelltips report` | text of what the last tooltip showed, to copy |
| `/spelltips enum [name]` | list the client's `Enum` tables (developer tool) |
| `/spelltips desc [spellID]` | where a spell's description text is (developer tool) |
| `/spelltips debug` | toggle debug output in chat (developer tool) |
| `/spelltips verify [name]` | check every talent's numbers against the game's own text (developer tool) |
| `/spelltips ranks <name>` | a talent's text at each rank and the data rows behind it (developer tool) |
| `/spelltips talent <name or id>` | open the talent window on a talent (developer tool) |

## Install

1. Copy the `spelltips` folder into `Interface/AddOns/`.
2. The `.toc` must load `Data.lua` before `Core.lua` and declare the saved variable:

```
## Interface: <your client's interface number>
## Title: SpellTips
## SavedVariables: SpellTipsDB
Data.lua
Core.lua
```

## How the data is made

`Data.lua` is generated from the game's own database tables, exported as CSV with [wow.export](https://github.com/Kruithne/wow.export). The generator is not part of this repository. Everything about the player (stats, talents, ranks) is read live in game, and spell numbers are not typed in by hand. The hand-made parts are small and named in the code: what each spell-modifier property id means (`MOD_PROPS` in `Core.lua`; it lives in the game's program code and is in no data table), which crowd-control aura types get a row, the order rows are drawn in, and the fixed weapon speeds the game uses for normalized attacks.

The data file defines one global table, `SpellTipsData`, and records the game build it came from. The addon warns in chat when the client's build differs, so you know the data is stale after a patch.

## Known limits

- **Beta data.** The game is in beta and some data rows disagree with the game's own text. When data is missing or unclear for a talent, the addon shows the game's own description for it instead of guessing.
- **English only.** Row labels are English.
- **Not every talent is covered.** A talent appears on a spell only when the data links it (a spell-class mask, a referenced spell, or a required equipped item type). Unlinked talents are listed in `Data_audit.txt`.
- **Combat.** The game marks some tooltip text as secret during combat. The addon avoids reading it, but report any error you see.
- Crowd-control rows (Stun, Root, Slow and so on) show only when a talent changes them.
- Spells with no modifiers and no numbers of their own show nothing extra.

## License

none

