# Dyre's Quest Targeting

Shows your Focused Quest and builds a "hit list" and targeting macro based on
what you're trying to accomplish.

Dyre's Quest Targeting (DQT), for World of Warcraft: Forever, keeps
one character macro, **! Target (DQT)**, up to date with the mobs and NPCs
your focused quest needs. Put it on an action bar and press it to find, target, and mark the
nearest one. Type `/dqt` for the settings (see [Settings](#settings)).
Everything is saved per character. Works best with **Questie** and **TomTom**;
both are optional. It can also follow the current step of **Zygor Guides
Viewer** or **RestedXP**.

It began as the one part of RestedXP's guides the author still wanted, built
from Forever's own quest journal instead of a guide.

## What the macro targets

- **Your focused quest:** focus a quest in the game's quest log or on the map
  (the map and minimap then point the way), or with Questie's tracker
  (right-click, Focus Quest or Focus Objective; Questie hides the game's
  tracker by default). Whichever you set last counts; at login, Questie's
  (or Zygor's step, see below).
  A Questie objective focus targets only that objective. "Follow Questie's
  tracker focus" in the settings turns Questie's focus off. When the focused
  quest changes, chat says so: "Focused quest changed via Questie (Assessing
  the Threat), targeting updated to Redridge Poacher." Only the focused
  quest counts, not every tracked one.
- **Zygor's guide step** (with Zygor Guides Viewer, experimental): the mobs
  and NPCs of the step Zygor shows, for every quest of the step, and of the
  sticky steps shown with it. A new step counts as a focus change, so the
  focus you change last wins: Zygor's step, Questie's, or the game's. At
  login, Zygor's step wins when it names a mob or NPC. A travel or text step
  leaves your quest focus in charge. The header says "(Zygor)". See
  [With Zygor](#with-zygor).
- **RestedXP's guide step** (with RestedXP, experimental): the same, for the
  names on its current and sticky steps. See [With RestedXP](#with-restedxp).
- **Kill objectives** it still needs, the first objective first.
- With **QuestieDB** installed (its own CurseForge project; the CurseForge
  app installs it with DQT), also the mobs that **drop the quest's items** (with Questie, the six
  best by Questie's drop rates, the best one wanted most; `/dqt list` shows each
  rate),
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
names with every line on; `/dqt list` says which names did not fit.

## What it does with what it finds

The macro clears your target, looks for each name, goes back if what it found
is dead, then:

- **Marks it:** a skull on a mob, a green triangle on an NPC (anything you
  cannot attack). A second press leaves the mark. Both markers can be changed,
  and "Mark what the macro finds" turns marking off. In a raid, only leaders
  and assistants can mark.
- **On a mob, also** (off by default): start attacking, or cast a spell you
  pick from your spellbook, such as Moonfire (Rank 1) to tag a mob. The list
  holds only harmful spells that cast in 1 second or less, rank by rank.
  Never on an NPC. The macro casts it with `/use [harm,nodead] Name(Rank N)`
  (`/use` casts the spell like `/cast`, and is one letter shorter).

## Talking to NPCs and clicking quest objects

A macro cannot interact, and `/targetexact` cannot find objects. Use the
game's own Interact key: **Options → Controls → Enable Interact Key**, then
bind it. It talks to the NPC, loots the corpse, or clicks the quest object in
front of you.

## Commands

| Command | What it does |
| --- | --- |
| `/dqt` | Opens the settings (out of combat) |
| `/dqt list` | Lists what the macro targets, most wanted first, and why: quest objective, item drop with its drop rate, turn-in, NPC to talk to, or your hit list |
| `/dqt add [name]` | Adds a name; anything containing it matches |
| `/dqt add_exact [name]` | Adds a name; only that exact name matches |
| `/dqt remove [name]` | Takes one name off your hit list |
| `/dqt reset` | Clears your hit list (the box stays where it is; `/dqt reset_box` moves it back) |
| `/dqt on`, `/dqt off` | Turns updating the macro on or off; off leaves it as it is |
| `/dqt unlock`, `/dqt lock` | Unlocks or locks frames to move the Quest Target box, as `/dyre unlock` and `/dyre lock` do for every Dyre's AddOn |
| `/dqt reset_box` | Puts the Quest Target box back in its first place |
| `/dqt options` | Opens the settings, as `/dqt` does |
| `/dqt debug` | Prints the raw quest objectives, QuestieDB's answers, and the guides' steps |

`/questtargeting` works the same, in case another AddOn uses `/dqt`.

## The Quest Target box

A rounded box with a thin gold edge (on by default) shows what the macro
does. Its header names your
focused quest and how it is focused, "(Questie)", "(Zygor)", "(RestedXP)", or
"(Focus)"; under it is the objective you focused in Questie, or the guide's step. Then the names the macro looks for,
most wanted first, with each quest item and, in its own column, the drop
rate ("-" when Questie has no rate), the names left out of the macro's 255
letters, and your hit list. Hover over a cut-off row ("...") to read all of
it.

Each hit list name has a red X to remove it; drag a name up or down to
change its priority (the top one is the most wanted). The targets stay in
their own order, best drop rate first. The "Hit list" bar is the hit
list's title: its names show under it. It always shows, also when the box
is folded: the plus on the left adds your
target (Shift-click for the exact name; with no target, a small box opens to
type a mob's name), the red X on the right clears the hit
list, and the middle shows how many names it has. They
work in combat too:
the box changes at once and the macro updates when combat ends. Click a title
to fold or open its part: the quest's name in the header, a section title,
or "Hit list" in its bar. The plus or minus at the header's right end folds
or opens everything. Two settings decide how the box starts at login:
"Start the quest targets folded" (off by default) and "Start the hit list
folded" (on by default). The box lets clicks through to the
world, except on its icons, header, section titles, and hit list names. With no
focused quest it still shows, with a line on how to focus one, so you can
always change your hit list from it.

Ctrl-drag the header to move the box without unlocking (out of combat;
it drops where you let go, with no snapping). Or move it with
`/dqt unlock` (or `/dyre unlock`), then `/dqt lock`;
`/dqt reset_box` puts it back. "Style" picks brown and gold (the default) or black and
gold. The box grows and shrinks with what it shows, up to Max height in
DQT's settings; Width sets its width and Text size only the text: a taller
maximum shows more rows, bigger text fewer. A long list is cut, and its last row says how many more
(`/dqt list` shows all). Opacity, and "Show the Quest Target Box" turns it
off.

## Settings

`/dqt` opens the settings: Options > AddOns > Dyre's AddOns > Quest
Targeting, beside your other Dyre's AddOns; the toolkit's minimap menu opens
them too. The settings for other AddOns (Questie, Zygor, TomTom) are together
under "Integrations (Experimental)". DQT needs **Dyre's Toolkit** 2.0 or later (the CurseForge app
installs it with DQT). With an older toolkit, the macro still works, its
settings are under Options > AddOns > Dyre's Quest Targeting, there is no
box, and chat says once at login to update the toolkit from CurseForge.

## Without Questie

Questie is optional. Without it, the settings that need Questie are greyed
out; they keep their values and work again once the AddOn is installed and on.
"Point TomTom at the focused quest" needs TomTom, and Questie, Zygor, or
RestedXP. Without Questie, it uses only a guide step's location.

- **Neither Questie nor QuestieDB:** the macro follows the game's focus (quest
  log and map) and targets kill objectives only; `/dqt list` says QuestieDB is not
  loaded. Your hit list works as always.
- **QuestieDB without Questie** (QuestieDB is its own AddOn): quest-item
  droppers and turn-in NPCs work too, with the game's focus.
- **Questie on:** its tracker focus counts as well, unless you turn "Follow
  Questie's tracker focus" off. Two more settings, off until you turn them on:
  - **Keep Questie's and the game's focus in sync:** focus a quest in
    Questie's tracker and the game's quest log and map focus it too, and the
    other way round. A Questie objective focus gives the game its quest.
    Unfocusing in Questie clears the game's focus.
  - **Point TomTom at the focused quest** (needs TomTom): points the TomTom
    arrow at the nearest of the quest mobs the macro looks for, or at the
    turn-in once the quest is done. It moves each time the focused quest or
    objective changes, an objective is done, or the quest is ready to turn
    in. It never moves at login, so a waypoint of your own stays. On a Zygor
    or RestedXP step, see those sections.

  **Both are experimental: use them with caution.** They use Questie's own
  code, not a public API, so a Questie update can stop them; the macro keeps
  working.

## With Zygor

**Zygor Guides Viewer** is a separate product (its full guides are paid); DQT
does not install it. A Zygor step often covers several quests in one area, and
Zygor's Action Bar gives one button per name. DQT puts the whole step behind
one macro. With Zygor installed, "Follow Zygor's current step" (under
"Integrations (Experimental)") is on by default; without Zygor it is greyed
out. DQT reads the step Zygor shows and the sticky steps shown with it, and
targets the mobs to kill (also "from" mobs that drop an item) and the NPCs to
talk to, for every quest of the step: Zygor itself focuses only the step's
first quest. Done goals drop out. The guide's first goal is wanted most. A name
that Zygor makes plural ("Kobold Vermins") is QuestieDB's name for that NPC,
or left out without QuestieDB.

"Point TomTom at the focused quest" follows the step too. When the step has a
location, the arrow goes to the goal Zygor's arrow points at, also on a travel
step that names no one, and it moves when Zygor moves to its next waypoint.
TomTom shows that goal, not Zygor's travel route to it, so on a long trip
Zygor's arrow can point at a flight master first. With no location (and Questie),
the arrow goes to the nearest of the step's mobs and NPCs, or, when Questie has no
spawns for them, the step's quest. It does not move for the step Zygor restores
at login.

**Experimental: use it with caution.** It reads Zygor's own data, not a
public API, so a Zygor update can stop it; DQT then follows your quest focus,
and the macro keeps working.

## With RestedXP

With **RestedXP** installed, "Follow RestedXP's current step" (under
"Integrations (Experimental)") is on by default; without it, it is greyed out.
RestedXP has its own targeting macro and arrow, and DQT leaves them alone. Its
macro also uses exact names and marks what it finds. DQT's macro adds your hit
list, your own markers, and the opener, and the box shows it all. It targets the mobs and NPCs on the current step and the
sticky steps. A name whose objective is done drops out. A new step counts as a
focus change, so the focus you change last wins; RestedXP setting the game's
focus to a quest of its own steps does not count. At login, its step wins when
it names someone (Zygor's first, if you run both). A step that names no one
leaves your quest focus in charge.

"Point TomTom at the focused quest" follows the step too. When the step has a
location, the arrow goes where RestedXP's own arrow goes, sticky steps first, as
RestedXP does, also on a step that names no one, and it moves when you reach a
waypoint. A step with several waypoints uses RestedXP's next one. While you are
dead, RestedXP's arrow points at your corpse, and TomTom's stays on the step.
With no location (and Questie), the arrow goes to the nearest of the step's mobs and
NPCs: DQT looks each name up in the step's quests in QuestieDB (English names
only). With no match, it goes to the step's quest; on a step with no quest, the
waypoint stays. It does not move for the step RestedXP restores at login.

**Experimental: use it with caution.** It reads RestedXP's own data, not a
public API, so a RestedXP update can stop it; DQT then follows your quest focus,
and the macro keeps working.

## How it works, and its limits

- The macro is rewritten only out of combat and only when it changes;
  anything that changes in combat is written when combat ends.
- Each character has its own macro in the character tab, so each needs one
  free character macro slot. Short of slots? **Use an account-wide macro**
  (off by default) keeps one account macro instead, rewritten for whichever
  character is logged in. Do not use it if you play two characters at once.
  After switching, put the new macro on your bars and delete the old one;
  DQT leaves the other one alone and says so.
- Without QuestieDB, a kill objective's name comes from its English text
  ("Dire Condor slain: 0/8"). QuestieDB's names are English too.
- Another AddOn that sets the game's focus keeps taking over the focus: disable
  it. That includes RestedXP's guides (even with the window hidden) when
  "Follow RestedXP's current step" is off.
- `/tar` and `/targetexact` pick the nearest match, so same-named mobs (and,
  for `/tar`, players whose names contain it) can be picked.

## Compatibility

Built for World of Warcraft: Forever 1.60.1 (build 70450, Interface 16001)
and played on that build. DQT checks the APIs it needs at login and stays off, saying why,
if one is missing. TESTING.md lists the in-client checks.

Also for WoW Classic Era 1.15.9 (Interface 11509, in the TOC). Anniversary is
not in the TOC, so tick "Load out of date AddOns" there. Those clients have no
quest focus of their own, so DQT follows Questie's tracker focus there.
Without Questie, quest targeting is off, but the macro and the box still keep
your hit list, and chat says so at login.

## Support

Dyre's AddOns are free. If you enjoy them, you can support them on Ko-fi: https://ko-fi.com/dyre_janelle

## License

MIT. See LICENSE.
