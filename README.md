# Dyre's Quest Targeting

A targeting macro for World of Warcraft: Forever (beta) that follows the quest
you are working on. Dyre's Quest Targeting (DQT) keeps one character macro,
**! Quest Targets**, up to date with the mobs and NPCs your focused quest
needs. Put it on an action bar and press it to find, target, and mark the
nearest one. Settings are in **Options → AddOns → Dyre's Quest Targeting**, or
type `/dqt options`. Everything is saved per character.

It replaces the one part of RestedXP's guides the author still wanted, built
from Forever's own quest journal instead of a guide.

## What the macro targets

- **Your focused quest:** focus a quest in the game's quest log or on the map
  (the map and minimap then point the way), or with Questie's tracker
  (right-click, Focus Quest or Focus Objective; Questie hides the game's
  tracker by default). Whichever you set last counts; at login, Questie's.
  A Questie objective focus targets only that objective. "Follow Questie's
  tracker focus" in the settings turns Questie's focus off. When the focused
  quest changes, chat says so: "Focused quest changed via Questie (Assessing
  the Threat), targeting updated to Redridge Poacher." Only the focused
  quest counts, not every tracked one.
- **Kill objectives** it still needs, the first objective first.
- With **QuestieDB** installed (it comes with Questie, and also installs on its
  own), also the mobs that **drop the quest's items** (up to three per item),
  every mob a shared kill objective counts, and, once the quest is done, the
  **NPC you turn it in to**. Without it, only kill objectives are targeted:
  the client names no mobs for quest items.
- **Your hit list**: names you add, for any mob, quest or not. They win over
  the quest's:
  - `/dqt add Goretusk` finds anything whose name contains it (`/tar`), such
    as Great Goretusk.
  - `/dqt add_exact Great Goretusk` finds only that name (`/targetexact`).
  - With nothing typed, both add your target, which can be a dead one: target
    the corpse and the macro finds the next.
  - `/dqt remove [name]` and `/dqt reset` take them away; the quest's names stay.
  - `/dqt` reads macro conditions in brackets, so a macro of your own,
    `/dqt [mod:shift] remove; add`, adds your target on a click and removes
    it on Shift-click.
- Finished objectives drop out by themselves as the quest log updates, and
  chat says so: "Redridge Mongrel removed: Quest Assessing the Threat
  objective completed. Use /dqt add if you want to keep targeting them." In
  combat the macro cannot change, so it catches up when combat ends.

Quest names always use the exact name. A macro holds 255 letters, about six
names with every line on; `/dqt` says which names did not fit.

## What it does with what it finds

The macro clears your target, looks for each name, goes back if what it found
is dead, then:

- **Marks it:** a skull on a mob, a green triangle on an NPC (anything you
  cannot attack). A second press leaves the mark. Both markers can be changed,
  and "Mark what the macro finds" turns marking off. In a raid, only leaders
  and assistants can mark.
- **On a mob, also** (off by default): start attacking, or cast a spell you
  pick from your spellbook, such as Moonfire (Rank 1) to tag a mob. Never on
  an NPC.

## Talking to NPCs and clicking quest objects

A macro cannot interact, and `/targetexact` cannot find objects. Use the
game's own Interact key: **Options → Controls → Enable Interact Key**, then
bind it. It talks to the NPC, loots the corpse, or clicks the quest object in
front of you.

## Commands

| Command | What it does |
| --- | --- |
| `/dqt` | Lists what the macro targets, and why |
| `/dqt add [name]` | Adds a name; anything containing it matches |
| `/dqt add_exact [name]` | Adds a name; only that exact name matches |
| `/dqt remove [name]` | Takes one name off your hit list |
| `/dqt reset` | Clears your hit list |
| `/dqt on`, `/dqt off` | Turns updating the macro on or off; off leaves it as it is |
| `/dqt options` | Opens the settings |
| `/dqt debug` | Prints the raw quest objectives and QuestieDB's answers |

`/questtargeting` works the same, in case another AddOn uses `/dqt`.

## Without Questie

Questie is optional.

- **Neither Questie nor QuestieDB:** the macro follows the game's focus (quest
  log and map) and targets kill objectives only; `/dqt` says QuestieDB is not
  loaded. Your hit list works as always.
- **QuestieDB without Questie** (keep its folder, disable Questie): quest-item
  droppers and turn-in NPCs work too, with the game's focus.
- **Questie on:** its tracker focus counts as well, unless you turn "Follow
  Questie's tracker focus" off.

## How it works, and its limits

- The macro is rewritten only out of combat and only when it changes;
  anything that changes in combat is written when combat ends.
- Each character has its own macro in the character tab, so each needs one
  free character macro slot. An account-wide macro with the same name is left
  alone, and DQT says so.
- Without QuestieDB, a kill objective's name comes from its English text
  ("Dire Condor slain: 0/8"). QuestieDB's names are English too.
- Another AddOn that sets the game's focus, such as RestedXP's guides (even
  with its window hidden), keeps taking over the focus. Disable it.
- `/tar` and `/targetexact` pick the nearest match, so same-named mobs (and,
  for `/tar`, players whose names contain it) can be picked.

## Compatibility

Built for Forever beta 1.60.1 (build 70338, Interface 16001). DQT checks the
APIs it needs at login and stays off, saying why, if one is missing.

Not yet verified in client: everything. TESTING.md lists the in-client checks.

## License

MIT. See LICENSE.
