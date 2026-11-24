# Agent Guidelines

## Project purpose and scope

Dyre's Quest Targeting (DQT, `/dqt`) is a World of Warcraft: Forever AddOn
that keeps one targeting macro up to date with the quest you are working on.
It began as the one RestedXP (RXP) feature the author still wanted, built from
Forever's own quest journal instead of a guide; since 1.3.0 it can also follow
a Zygor or RestedXP step, since 1.4.1 a QuestTrail step, and since 1.8.0 an OpenXP step. Keep this feature set; do not add speculative features
or frameworks without agreement.

Naming (author-approved): the title starts with "Dyre's", so players can find
all of the author's AddOns by searching for it ("Forever" matched too much).
The apostrophe is only in the title: the folder, TOC, saved variables, and
globals use `DyresQuestTargeting`. Commands `/dqt` and `/questtargeting`, chat
prefix `DQT:`. Listings say plainly that it is for WoW: Forever.

### The macro (built; author-approved design)

- One character macro, "! Target (DQT)" ("!" sorts it first; at most 16
  letters), per character (author-approved: RXP's one account macro, shared
  by every character, was a problem). Created in the character tab when
  missing. "Use an account-wide macro" (`db.accountMacro`, default off;
  author-approved, for players short of character slots who do not play two
  characters at once) makes and updates one account macro instead. DQT looks
  in one scope only (`GetMacroInfo` over that scope's index range, as
  Blizzard's Macro window numbers them); a macro of the same name in the
  other scope is left alone, with a word in chat.
  The icon is file ID 132177, "Hunter Marksman" (author's pick). A character
  macro with the pre-release name "! Quest Targets" is renamed in place.
- Rewritten only out of combat and only when the body changes. A body asked
  for in combat waits for `PLAYER_REGEN_ENABLED`. Quest events come in
  bursts; one rebuild 0.2 s after the first covers each.
- Body, in order: `/cleartarget`; one line per name, least important first
  (every line runs and the last one that finds a unit wins); `/targetlasttarget
  [dead]`; the marker line; the opener line. At most 255 letters: when full,
  the least important names are left out, and `/dqt list` says which. With no
  names, a `//` comment says so.
- Markers (author-approved): one line, `/tm [harm,nodead] !8;
  [exists,noharm,nodead] !4`, skull on a mob and green triangle on an NPC
  (there is no arrow marker: `MAX_RAID_TARGETS_USER` is 8). `!` keeps a second
  press from toggling the mark off. `noharm` rather than `help`, so neutral
  NPCs count; `exists`, because with no target `noharm` is true and `/tm`
  answers "You can't do that right now" (found in client). Each marker is
  a setting (None to Skull), and "Mark what the macro finds" turns the line
  off (for purists). Never mark from AddOn code: `GetRaidTargetIndex` is secret.
- Opener (author-approved): "On a mob, also" is Nothing (default), Start
  attacking (`/startattack [harm,nodead]`), or a spell picked from a list of
  active spellbook spells, `/use [harm,nodead] Name(Rank N)` (author's rule:
  `/use`, not `/cast`, in every Dyre's AddOn macro: one letter shorter; with
  no item of that name it casts the spell), each rank
  up to the one the spellbook shows. The rank is the spellbook's own subtext
  ("Rank 3", "Rang 3", "等级 3"; 1.6.1, John: "Yes, fix all six"): its one
  number gives the rank, and the macro uses the client's words with that number
  changed. Only harmful spells
  (`C_Spell.IsSpellHarmful`) that cast in 1 second or less
  (`C_Spell.GetSpellInfo(...).castTime`, ms) are listed, checked per rank
  (author-approved); without those APIs, every spell. Never on an NPC. A saved spell the
  spellbook no longer shows stays in the list. Spell names are at most 40
  letters.
- Interact cannot be done by a macro or AddOn code (no slash command, no
  secure action type; `INTERACTTARGET` is only a key binding). The README
  points at the game's Interact Key. `/targetexact` cannot find objects.

### Names (built)

- Classic Era and Anniversary (author, 1.2.0: "fall back to [Questie's
  focus] in classic and only not initialize if both are unavailable"): those
  clients have no C_SuperTrack or SUPER_TRACKING_CHANGED (their source uses it
  only in the Cata and Mists map files), no C_QuestLog.GetLogIndexForQuestID,
  IsComplete, or GetTitleForQuestID, and no C_SpellBook functions. DQT follows
  the game's focus (`DQT.HasGameFocus`) or Questie's tracker focus
  (`DQT.QuestieFocusAvailable`: QuestieLoader and TrackerUtils.FocusQuest).
  With neither (Classic without Questie), DQT still starts (author: "still
  useful for manually maintained hit-list mobs"): quest targeting is off, the
  macro keeps the hit list, one chat line at login says so, the box header
  reads "No quest focus: install Questie", and `/dqt list` says the same. Without the game's
  focus, Questie's is the only one: "Follow Questie's tracker focus" shows on
  and greyed (its saved value is ignored), the sync is greyed and does
  nothing, and SUPER_TRACKING_CHANGED is not registered (an unknown event is
  an error). Core's `DQT.QuestLogIndex`, `QuestTitle`, and `QuestComplete`
  use C_QuestLog where present, else GetQuestLogIndexByID (0 when absent) and
  GetQuestLogTitle (the sixth return is 1 when complete). The opener list
  falls back to GetNumSpellTabs, GetSpellTabInfo, GetSpellBookItemName
  ("Rank N"), and IsPassiveSpell. QuestieDB on Era ships QuestieDB_Vanilla.toc
  and QuestieDB_TBC.toc with contract 4 (Era's Questie uses LibQuestieDB
  too), so the same reads are used; a missing or older contract falls back to
  kill objectives as everywhere. The TOC lists Interfaces 16001 and 11509
  (one package, uploaded for Forever and Classic Era); Anniversary is not
  listed (players tick "Load out of date AddOns").
- A guide's step is a focus too (1.3.0); see "With Zygor Guides Viewer" and
  "With RestedXP".
- Only the focused quest counts (author-approved): the game's (the
  super-tracked quest, `C_SuperTrack.GetSuperTrackedQuestID`,
  `SUPER_TRACKING_CHANGED`) or Questie's tracker focus (author-approved: read
  both, because Questie hides the game's tracker by default). Questie's is
  `Questie.db.char.TrackerFocus`, a quest ID or "questID objectiveIndex"; it
  fires no event, so `TrackerUtils` (through the global `QuestieLoader`) has
  `FocusQuest`, `FocusObjective`, and `UnFocus` hooked with `hooksecurefunc`.
  The most recent change wins; at login, Questie's when set. The game's
  counts as changed only when its quest changes (the event also fires for map
  pins), outside loading (until 2 s after `PLAYER_ENTERING_WORLD`), as a
  guard against the game restoring its focus; that restore is not confirmed in
  client. Found in client: RestedXP sets the game's focus from its guide steps
  (`C_SuperTrack.SetSuperTrackedQuestID`, also with its window hidden), which
  made the game's focus keep beating Questie's; with RXP disabled, the focuses
  behaved as designed. An objective
  focus targets only that objective. This reads Questie's private data, not a
  public API: a Questie update can change it, and DQT then falls back to the
  game's focus. Not the tracked (watched) quests.
- Quest names always use `/targetexact` (author-approved, no setting).
- Unfinished objectives, in this order (most important first; the macro lists
  them the other way, as its last line wins):
  - "Smart targeting mode" (`db.smartOrder`, default on; author-named; author, 1.7.0: "1) named/
    rare or npc targets (kill, talk, or gather) go first 2) gather quest mobs
    sorted by drop rate (highest on top) 3) kill quest mobs 4) everything
    else"): rare or named mobs (`IsRare`: QuestieDB `Npc.rank` 2 rare elite, 3
    boss, or 4 rare, or 1 to 3 spawn points in `Npc.spawns`; none known is not
    rare), then every item's droppers together by drop rate (no rate after
    them), then kill targets, then the rest; ties keep the quest's order.
    QuestieDB gives no order for a quest's objectives (checked, 1.7.0). A
    guide step (Zygor, RestedXP, QuestTrail) keeps its guide's order, except
    that its rare or named mobs go first (`RareFirst`; author, 1.7.1: "in smart
    mode, put the named first"). Off: the quest's own order, the first
    objective most important, each item's droppers by rate.
  - A player's order (author, 1.7.0: "allowing the user to set whatever order
    they want"): dragging a target row in the box saves the whole order of the
    quest's names, most wanted first, in `db.targetOrder[key]` (`TargetOrderKey`:
    the quest ID, or a guide step's own key, as a string). It wins over both
    (`ApplyTargetOrder`, after the quest's targets are built); names it does not
    list keep their place before the listed ones. Kept per character
    (`characterKeys`), repaired on load, and pruned at the next drag (not at
    login, when the log may not be loaded): another guide step's, or a quest no
    longer in the log.
  Kill
  objectives (`monster`): the client's text gives the name, read with the
  client's own formats (1.6.1): `QUEST_MONSTERS_KILLED`, then
  `QUEST_OBJECTS_FOUND`, turned into Lua patterns (pattern characters escaped,
  the name is argument 1, `%d` any number, "|4one:many;" each word, a no-break
  space as a space). Classic's enUS is "%s slain: %d/%d", mainline's "%2$d/%3$d
  %1$s slain", frFR's "%1$s : %2$d/%3$d |4personnage tué:personnages tués;"
  (Ketho/BlizzardInterfaceResources GlobalStrings; the pinned wow-ui-source has
  no GlobalStrings). Text in neither format, or no globals: the English "X
  slain: 0/8" or "0/8 X slain" is stripped, other text kept. Item objectives: no
  client source.
- "Follow Questie's tracker focus" (`db.questieFocus`, default on; author-
  approved): off ignores Questie's focus. Without Questie installed, DQT
  follows the game's focus only, and without QuestieDB targets kill
  objectives only; both are tested.
- QuestieDB, when loaded (author-approved: use it if installed; do not build
  our own database): `LibQuestieDB.RequireContract(4)`, then
  `Quest.objectives` (creature entries matched to an objective by NPC name or
  text; shared kill-credit entries give up to 3 NPCs), `Item.npcDrops` for item
  objectives (matched by item name), and, for a complete quest,
  `Quest.finishedBy` (up to 2 turn-in NPCs). An older contract is not used.
  NPC names containing "UNUSED" (QuestieDB placeholders) are skipped.
- The best droppers (author-approved): with Questie loaded, each item's
  droppers are ranked by Questie's drop rate (`QuestieDB.GetItemDroprate`,
  its tooltip data: a Questie correction, then private-server, then Wowhead;
  on Forever, the Classic tables), and the best 6 are kept, the best last so
  it wins and is the last left out. Without Questie or rates, QuestieDB's
  order. `/dqt list` shows each dropper's rate; `/dqt debug` lists every dropper.
  Not the raw `LibQuestieDB.Support` tables: merging them would copy
  Questie's logic.
- The hit list (author's name for it; saved as `db.added`): `/dqt add [name]`
  writes `/tar Name`
  (similar names), `/dqt add_exact [name]` writes `/targetexact Name`. With
  nothing typed, the target's name (checked with `issecretvalue`; secret in
  some combat cases); with no target, nothing changes and DQT says so. Each
  keeps its kind; adding it again with the other command switches it.
  `/dqt remove [name]` removes one, `/dqt reset` all (quest names stay). Saved
  per character, newest last, at most 20; they go after the quest's names, so
  they win. A name with `;` or a line break, or too long to fit with every
  fixed line and the longest opener, is refused.
- A change of focused quest (or Questie objective) is said in chat
  (author-approved): "Focused quest changed via Questie|Quest Focus (<title>),
  targeting updated to <the quest's own first mob>", "after combat" while the
  write waits, then "Your hit list comes first: <name>." when the hit list
  wins (so it does not hide the change); or "No focused quest; ...". Not at
  login, and not for progress on the same quest.
- A name that leaves the same focused quest's list (its objective done, or the
  quest complete) is said in chat (author-approved): "<name> removed: Quest
  <title> objective completed. Use /dqt add if you want to keep targeting
  them.", plus "The macro updates after combat." while the write waits.
- "Say targeting changes in chat" (`db.chatUpdates`, default on; author, 1.8.1:
  "add an option to hide the chat lines for non-critical updates", after a frFR
  player asked): off hides the two kinds of line above (focus changed or none, and
  removed). Errors, problems, and replies to the player's own commands always show.
  In the macro's settings, after "Smart targeting mode"; part of the profile.
- Rebuilds follow `QUEST_LOG_UPDATE` (as Blizzard's tracker), backed up by
  `QUEST_WATCH_UPDATE` and the player's `UNIT_QUEST_LOG_CHANGED`.
- `/dqt` passes text with "[" to `SecureCmdOptionParse` (a legacy global,
  not in the generated docs; Blizzard's slash commands use it) and runs the
  chosen clause, so `/dqt [mod:shift] remove; add` works in a player's macro;
  no match does nothing. Without the parser, the text falls through to the
  usage.
- On hold (author): removing the quest's own names (a per-quest hidden list)
  and a maintained "! Hit List" macro. Finished objectives should drop out on
  their own; a case where one did not is being reproduced first.
- `/dqt on` and `/dqt off` (and the settings page's switch): off leaves the
  macro as it is, and syncs nothing.

### With Zygor Guides Viewer (built 1.3.0; author-approved, 2026-11-05)

Author: "Latest focus change wins." Found in client: Zygor sets the game's
focus (so DQT followed it), but not at load, and only for the step's first
quest. Source verified in Zygor Guide Viewer Forever 1.6
(`_forever_\Interface\AddOns\ZygorGuidesViewerForever`); private fields,
not a public API. Zygor is a paid AddOn: tests mock only its fields.

- "Follow Zygor's current step" (`db.zygorFocus`, default on
  (author-approved; it only reads, as "Follow Questie's tracker focus");
  greyed out without Zygor, by `DQT.ZygorAvailable`: the global
  `ZygorGuidesViewer` with `AddMessageHandler`).
- Zygor's step is a third focus. A new step (`ZygorGuidesViewer.CurrentStep`,
  keyed by `CurrentGuide.title` and `step.num`) makes it the latest; goal
  progress on the same step only rebuilds. Questie's hooks and a game focus
  change make the quest focus the latest again, except a game focus on a
  quest of Zygor's shown steps (Zygor's own `ZGV:TrackQuest`, from
  `ZGV:FocusStep`). A step change while the world loads does not count (the
  same loading guard as the game's focus); the step at the end of loading
  is the one later steps compare with. At login, Zygor's step wins when it
  names someone (author-approved; Questie's, then the game's, otherwise).
  Only a new step counts as a Zygor change (author-approved): goal progress
  would otherwise take the focus back from a quest just chosen in Questie.
- Messages through `ZGV:AddMessageHandler` (handler(self, message, ...),
  unprotected, so DQT's handler only notes the step and asks for a
  rebuild): ZGV_STEP_CHANGED, ZGV_GOAL_COMPLETED, ZGV_GOAL_UNCOMPLETED,
  ZGV_GOAL_PROGRESS, ZGV_GUIDE_LOADED. No polling.
- Names: the shown steps are the sticky steps (`ZGV.CurrentStickies`, more
  important, the first sticky most; author, 1.7.1: "Sticky steps should be
  higher priority", found in client when a sticky rare was left out of a full
  macro) and the current step; within a step, goals from last to first,
  so the guide's first goal wins. A goal counts when `goal:GetStatus()` (or
  `goal.status`) is "incomplete" or "passive": Zygor's passive goals include
  "kill Timber Wolf, Young Wolf" beside "collect 8 Tough Wolf Meat"
  (author-approved: "incomplete" only would miss the droppers). Kill
  goals: `goal.targets` ({name, id} pairs) or `goal.target`; `goal.mobs`
  ({name, id, pl}) on any goal but "avoid" (the "from" line and the "|from"
  tag); `goal.npc` on talk, clicknpc, accept, and turnin goals. A plural goal
  (`goal.plural`) has a plural name, so its name is QuestieDB's for the ID,
  or none (author-approved). One line per name, at its most important place; all
  `/targetexact`. Sources "kill" and "talk" ("talk to"; not said as a
  completed objective, as a turn-in).
- A step that names no one falls back to the quest focus. Title: the first
  open goal's quest (`goal.questid`), else "Guide step N of <guide>"; the
  box's line under the header is "Zygor: step N of <guide>"
  (`CurrentGuide.title_short`), `/dqt list` says "(Zygor's step N of
  <guide>)", and chat "Focused quest changed via Zygor (...)".
- Every field is type-checked; with changed fields DQT falls back to the
  quest focus. The sync does not copy it. A game focus on a quest of a guide's
  shown steps changes nothing at all (no latest focus, no sync): the guide
  sets it itself.
- A guide step's location (author, 1.3.0, reversing the earlier "arrows differ
  on purpose": "For Zygor or RXP, if sync is enabled and the active step has a
  location, we use it. Otherwise, we fall back to current behavior. Then we
  behave at least as good as the guide's internal arrow; and arguably better in
  cases where the step has no location stored."). "Sync" is the guide's Follow
  setting plus "Point TomTom at the focused quest"; no new setting. It counts
  while the guide is the latest focus (`guideFocus`), also on a step that names no
  one, where the macro follows the quest focus; a quest focus changed last takes
  the arrow back. Set with `TomTom:AddWaypoint` (map ID, x and y 0 to 1), not
  Questie's `SetTomTomTarget`: that takes an area ID, and
  `ZoneDB:GetAreaIdByUiMapId` can raise an error. With Questie, the waypoint goes
  in its `db.char._tom_waypoint`, so each side removes the other's and it is
  saved as Questie's is; without Questie, DQT keeps it and asks for it not to be
  saved (`persistent = false`), or it would stay for good after a `/reload`.
  Without `AddWaypoint`, the path below.
- Zygor's location: the goal `step.current_waypoint_goal_num`, else the next goal
  with numeric `map`, `x`, `y` (0 to 1), `IsVisible()`, no `force_noway`, not
  "mapmarker" (Step.lua:786 `CycleWaypoint`, Step.lua:833 `CycleWaypointTo`,
  Waypoints.lua:170-181). Only the current step: Zygor's arrow does not go to a
  sticky step. It is the goal, not `Pointer.DestinationWaypoint` (which also holds
  manual and corpse points), and not the travel route LibRover finds to it, so on
  a long trip Zygor's arrow can show a flight master first. Signal: the message
  ZGV_STEP_WAYPOINT_CHANGED (Step.lua:839) and ZGV_GOAL_COMPLETED
  (`Goal:OnCompleted` cycles). A `path` farm step with no goal location falls
  back below.
- "Point TomTom at the focused quest" with no location follows a Zygor step (author,
  1.3.0, found in client: the arrow stayed on the earlier quest's NPC; Zygor sets
  no TomTom waypoint): the nearest spawn of the step's mobs and NPCs,
  sticky steps' too, as for a Questie focus. With no spawn data (a name not
  in QuestieDB), `SetQuestTomTomTarget` with the step's first open quest in
  the log (`quest.logQuest`); with none, the waypoint stays. `quest.id` is
  DQT's own key ("zygor ...") and never reaches Questie. The first step of
  a session is the one Zygor restores, also seconds after login, so it does
  not point; a later step, its next waypoint, or a change in the macro's mobs
  does. A first step chosen by hand does not point either, until the next change.

### With RestedXP (built 1.3.0; author-approved, 2026-11-05)

Author: "RXP's arrow sucks, if we did the same thing for RXP, the tomtom arrow
pointing would be worthwhile, even if people use RXP's targeting macro (though
I think ours is better)." Source verified in RXPGuides v4.11.32; private fields,
not a public API. Tests mock only its fields, with no guide text.

- "Follow RestedXP's current step" (`db.rxpFocus`, default on; greyed out
  without it, by `DQT.RxpAvailable`: `LibStub:GetLibrary("AceAddon-3.0",
  true):GetAddon("RXPGuides", true)` with `RXPFrame.activeSteps`). Not the
  global `RXP` ("debug purposes") or `_G.RXPGuides` (another table).
  `RXPTargeting`, RestedXP's own macro, is left alone.
- Quest.lua's local `guideFocus` is "zygor",
  "rxp", nil (a quest focus changed last), or "login". A guide step wins while
  it is the latest and names someone. With both guides at login, Zygor's first
  (proposed; both set the game's focus, so running both is unusual), then
  RestedXP's; after that the latest new step.
- A new step is a new `currentGuide.name` and current `step.index` (the last
  active step with a number). Read at each rebuild (`NoteRxpStep`); the same
  loading guard and "the step at the end of loading" rule as Zygor. The signal:
  `hooksecurefunc(addon.targeting, "UpdateUnitList", ...)`, run after each
  SetStep through RegisterGeneratedSteps, plus the quest events. Not the
  RXP_STEP_ messages: they would need AceEvent, and the hook is enough.
- Names: `step.elements[i].unitscan` and `.mobs` (source "kill") and `.targets`
  (source "talk"), as its UpdateUnitList reads them, through
  `addon.GetCreatureName` (the player's language). Not `GetCurrentTargets`: it
  adds rare and generated lists (dangerous mobs). The sticky steps (before
  the current step in activeSteps) are the most wanted, the first most (author,
  1.7.1, as for Zygor), then the current step, then a tip window after it; each
  step's elements from last to first. A "+" tag's list is nil
  once its parent is complete (UpdateTargets), so what is left is open; a tag
  without "+" stays until its step ends. An unresolved bare ID is a number
  string: QuestieDB's name, or none. One line per name; all `/targetexact`.
- A step that names no one falls back to the quest focus. Header "(RestedXP)";
  under it "RestedXP: step N of <guide>"; `/dqt list` and `/dqt debug` say so;
  chat "Focused quest changed via RestedXP (...)". Title: the first open quest
  (`element.questId` on accept, turnin, complete; current step first).
- The game's focus: RestedXP sets it from `step.track` and from complete and
  turnin tags, repeatedly. A game focus on a quest of an active step changes
  nothing (as for Zygor), so it no longer beats Questie's focus while this
  setting is on. With the setting off, the old "keeps taking over" limit holds.
- RestedXP's location, as its arrow chooses (`updateArrowData`, map.lua:1023):
  the first of `addon.activeWaypoints` not `hidden`, not `skip`, on a step with
  `active`, whose `parent` is not completed or skipped, with `arrow` (and not
  `text` and `completed`) or an odd `generated`; a `lowPrio` one only when no
  other is left. So a sticky step's location wins over the current step's, as on
  its arrow (activeSteps' order), so both arrows agree. `.goto` (functions.lua:1908):
  radius 0 alone has no `arrow`, a map pin only; radius 0 with a fifth value
  ("...,0,0") is `lowPrio`. `x`, `y` are 0 to 100 in the map `zone`. Signal:
  `hooksecurefunc(addon, "UpdateMap", ...)` when its argument is true (the list
  was rebuilt, also for a waypoint reached, on RestedXP's ticker); not its
  `UpdateGotoSteps`, which runs on a timer. Known gaps: a `.goto` with a negative
  radius (`dynamic`: the nearest of a set) is chosen again by distance without a
  rebuild, so TomTom keeps the last until the next one (8 of the guide's `.goto`
  lines); the arrow's corpse and spirit healer points are not followed. The list is
  empty until its first rebuild after login, so the first step counts until it fills
  (`RxpMapPending`), or that would point at login.
- With no location, TomTom points as for Zygor; never at login. Tags give names,
  not IDs, so each name is matched against the active steps' quests in QuestieDB
  (objectives, their droppers, startedBy, finishedBy; English names only), kept per
  quest. No match: `SetQuestTomTomTarget` with the step's first open quest in the
  log; none: the waypoint stays. QuestieDB has no name-to-ID index.
- Measured offline, one step at a time, on Forever's guide
  (Guides/forever/Alliance-1-10_NightElf.lua, 360 steps; Guides/GuideList-forever.xml
  loads it, not Classic-Alliance-1-10_NightElf.lua, 287 steps, which is Era's): 279
  have a location, 21 point at a mob or NPC, 2 at the quest, 58 leave the waypoint.
- Classic: RXPGuides_Vanilla.toc loads the same Lua files, so the fields are the
  same (source only; RestedXP is not installed in `_classic_era_`). A guide
  counts for `DQT.CanFollowQuests`, so RestedXP without Questie follows its step.

### With OpenXP (built 1.8.0; author-approved, 2026-11-23)

Author: a friend uses OpenXP, "another off-brand leveling guide that's free", and
"newest step wins unless the user has selected RXP, Zygor, OpenXP, etc. as their
primary guide". Source verified in OpenXP 1.3.66 (`_forever_\Interface\AddOns\OpenXP`,
CC BY-NC-SA 4.0; DQT copies none of it and only reads its fields): a fork of
RestedXP (NOTICE.md: upstream commit `b9f2e25`, 2026-11-07) whose new guide card
keeps RestedXP's window running hidden as the step engine. Tests mock only its fields.

OpenXP 1.x only (author, 2026-11-24: "Do B, update the docs to say 1.x only"). OpenXP
2.0.4 (2026-11-23, GPL-3.0, 1-20 guides from PoleStar; https://github.com/mjared123/OpenXP)
is a rewrite: no AceAddon, no `RXPFrame`, no LibStub library of its own, and its engine
is the private namespace (Core/Init.lua: modules talk "never through globals"). So
`DQT.OxpAvailable` is false and the switch stays greyed out; the tooltip, README, and
listing say 1.x only (tooltip: "Needs OpenXP 1.3.66 or earlier", author 2026-11-24). Rejected: reading its target row frames
(`OpenXPTargetButton`, `OpenXPTargetRow2`-`5`: `unitName`, `enemy`), UI fields with at
most 5 names, no step, quest, or location. Support for 2.x waits for a public read API
from OpenXP's authors (the current step's names, its quest, its location, a change signal).

- The same engine as RestedXP under another AceAddon name, "OpenXP" (Locale.lua:5).
  Quest.lua's `RXP_ENGINES` holds both (`rxp`: "RXPGuides", `oxp`: "OpenXP"), each with
  its own name ("RestedXP", "OpenXP") and setting; every RestedXP rule above applies to
  each. Unchanged fields, checked: `RXPFrame.activeSteps` (GuideWindow.lua:672-673),
  `targeting:UpdateUnitList` (the same function), `UpdateMap(resetPins)` (map.lua:1204),
  `GetCreatureName` (locale/NPCnames.lua:4), `currentGuide`, `activeWaypoints` and
  `updateArrowData` (only its saved variable is renamed, `OXPCData`).
- "Follow OpenXP's current step" (`db.oxpFocus`, default on, greyed out without it,
  by `DQT.OxpAvailable`), after the RestedXP switch. "Active guide" lists "OpenXP"
  (`oxp`). `guideFocus` "oxp"; at login after RestedXP. With both loaded, each is its
  own guide: the newest step wins unless one is the active guide.
- OpenXP's guides: its 1-20 Forever guides are RestedXP's; its own 21-60 guides use
  `.mob`, `.target`, `.goto`, and `.complete` (no `.unitscan` or `#sticky`). It sets the
  game's focus as RestedXP does (functions.lua:1596, 1939; GuideWindow.lua:795), so a
  game focus on a quest of its active steps changes nothing.
- Its "Quest Targets" key bindings (secure buttons `OpenXPTargetMobs`,
  `OpenXPTargetNPCs`) are left alone, as RestedXP's macro is.

### With QuestTrail (built 1.4.1; author-approved, 2026-11-10)

A player asked: DQT "picks up the focus quest targets but not the targets for the
'on the way' quests", which they added to the hit list by hand. Source verified in
QuestTrail 4.2.0 (`_forever_\Interface\AddOns\QuestTrail`, GPL; Forever only, one
Camelot TOC); private fields, not a public API. Tests mock only its fields.

- QuestTrail is a route planner, not a guide: its compass points at the next step
  of its plan, `ns.Arrow.current` ({kind, q, oi, cm, mx, my, ax, ay, key, path}).
  DQT reaches `ns` through `LibStub:GetLibrary("QuestTrail-Modules", true).ns`, the
  library QuestTrail hands its own modules (Core/QuestTrail_API.lua).
  `DQT.QuestTrailAvailable`: that `ns` with an `Arrow` table.
- It already sets the game's focus to its step's quest (`ns.Focus.Set`,
  UI/QuestTrail_Pins.lua:736; 0 for a quest not in the log), so before 1.4.1 DQT
  followed the quest, not the step. "Follow QuestTrail's current step"
  (`db.qtrFocus`, default on, greyed without it) adds the step: kinds "progress"
  (that objective, `oi`, with `ObjectiveTargets`; every open one without it),
  "finish" (`finishedBy`, source "turnin"), and "start" and "dropstart" (author:
  "target the quest giver": `startedBy` NPCs, source "talk", and the droppers of an
  item that starts it, source "drop"). Other kinds (hearth, the map pin, corpse) are
  no step. Header "(QuestTrail)", under it "QuestTrail: objective step" (take step,
  turn-in step), `/dqt list` "(QuestTrail's ...)". A step that names no one falls
  back to the quest focus.
- "On the way" (`ns.Arrow.onTheWay`, Planner/QuestTrail_OnTheWay.lua, made with each
  plan): {q, i, full, step, ...}, objectives in the log whose camps the plan's walk
  crosses, all-on-the-route first. Their targets go before the step's (less
  important), the fully crossed ones nearer the step; BuildMacro keeps each name once.
- `guideFocus` "qtr": a new step key (kind, quest, objective) not while loading makes
  it the latest; the step at the end of loading is the one later steps compare with;
  at login after Zygor and RestedXP. A game focus on the step's quest changes nothing
  (no latest focus, no sync), as for the guides. Signals: `hooksecurefunc` on
  `ns.Arrow` SavePlan (after each new plan sets the target), Advance, AdvanceDone,
  FocusNow, Skip, ResetRoute, RestorePlan, and `ns.Focus.Set`; not `A.Update`, which
  runs 20 times a second. A plan's interim target (while a long plan runs) shows only
  when the plan ends.
- TomTom (author, option C): QuestTrail sets no TomTom waypoint, but hooks
  `TomTom:AddWaypoint` and follows each new waypoint as its own map pin, and its plan
  waits (Planner/QuestTrail_Way.lua:152-163); it ignores `opts.silent`. So with
  QuestTrail loaded, every DQT waypoint is set with `TomTom:AddWaypoint` and `silent`:
  the step's location (`cm`; `ax`, `ay`, where the plan sent you, as the marker tour
  moves `mx`, `my`; 0 to 1), and Questie's spawns too (`ZoneDB:GetUiMapIdByAreaId`, and
  `DistanceUtils.GetNearestSpawnForQuest` for a quest, as `SetQuestTomTomTarget`
  does), since Questie's own calls are not silent. Never at login: QuestTrail
  restores its last plan then, and its first new plan can come a minute later.

### Active guide (built, not released; author-approved, 2026-11-14)

Author (bug): "Questie now sets the focus quest whenever you accept a quest, and
this overwrites the integration's RXP/Zygor step. If Zygor/RXP/QuestTrail
integration is enabled, we should be using that to drive Questie's focus quest."
Cause: the newest focus change won (Quest.lua `guideFocus`), and the focus on
accept is a new change. Source: the game focuses a quest you accept when nothing is
focused (`QuestUtil.CheckAutoSuperTrackQuest`, Blizzard_FrameXMLUtil
Mainline/QuestUtils.lua:440, from Blizzard_QuestSuperTracking.lua's QUEST_ACCEPTED
handler; the TOC loads it for mainline, which includes Camelot), and Questie 12.9.0's
"Follow Blizzard Super Tracking" (`trackerFollowSuperTracking`, default off,
Modules/Tracker/TrackerSuperTrack.lua:18-39) then calls `TrackerUtils:FocusQuest`,
which DQT hooks. Questie itself has no focus code on QUEST_ACCEPTED; that option is
the setting that turns it off. Both happen in the same frame (0 s; not timed in
client). Questie 12.9.0's `FocusQuest` also sets the game's focus
(TrackerUtils.lua:635-647), and it has no objective focus any more (a saved
"questID objectiveIndex" is cleared; `FocusObjective` is gone, so its hook is skipped).

- "Active guide" (`db.activeGuide`, a dropdown under the Integrations heading, after
  the four Follow switches): "recent", "Most Recent Focus" (author's label; the
  default, the behavior before it), then only the AddOns installed and followed:
  Questie, RestedXP, Zygor, QuestTrail (`DQT.ActiveGuideOn`). A saved choice not
  installed or not followed stays listed "(not loaded or not followed)" and counts
  as "recent" (`DQT.ActiveGuide`). Repaired on load.
- A guide chosen: only its steps drive DQT (`GuideAllowed`; at login only its step);
  each new step, while it is in charge, focuses the step's quest in your log in
  Questie's tracker (`DriveQuestie`: `TrackerUtils:FocusQuest`, then
  `QuestieQuest:ToggleNotes(false)`), once per step key. Questie chosen: no guide
  step drives DQT; the quest focus does, as before.
- A Questie or game focus change while a guide is chosen is decided at the next
  rebuild (`DecidePendingFocus`), because the automatic focus can come before DQT
  sees QUEST_ACCEPTED. Yours wins until the guide's next step or a re-sync (no way
  to tell a click from another AddOn's call). Not yours: a change within 1 s
  (`AUTO_FOCUS_WINDOW`, author-approved "about 1 s") of QUEST_ACCEPTED, which is also
  undone (the guide's quest goes back to Questie); a focus on a quest of a guide's
  step (`GuideHasQuest`: the guides and DQT set those); an unfocus; and Questie
  restoring its focus while the world loads.
- "Keep Questie's and the game's focus in sync" works as before; the automatic
  focus is not copied. With Questie 12.9.0 the guide's push sets both sides.
- QuestTrail drives Questie's focus the same way (its step's quest, `step.q`).
- Re-sync (`DQT.Resync`): the box's header button (`UI-RefreshButton`, left of the
  fold button, shown only while a guide is chosen), `/dqt resync`, and the key
  binding "Re-sync with your active guide". It makes the guide the latest focus and
  pushes its quest again. Choosing a guide in the setting does the same, silently.

### With Questie installed (built; author-approved, both default off)

Both are marked experimental (author): under the settings section heading
"Integrations (Experimental)" (when the client has
`CreateSettingsListSectionHeaderInitializer`), a caution in their tooltips,
README, CHANGELOG, and listing. The names never say "(experimental)"
(author, 1.3.0: the heading says it, and the names were cut off; Forever
and Classic Era both have the heading). The heading's type check is only a
safety check and changes no name.
That heading holds every setting for another AddOn (author, 1.3.0, renamed
from "Questie Synchronization": "I had a hard time finding the setting"),
in this order: "Follow Questie's tracker focus", "Follow Zygor's current
step", "Follow RestedXP's current step", "Follow OpenXP's current step", "Follow
QuestTrail's current step", "Active
guide", "Keep Questie's and the game's focus in sync", and "Point TomTom at the focused
quest". Above it, the macro's own settings: the switch, the
markers, the opener, the account-wide macro, "Smart targeting mode", and "Say
targeting changes in chat". Only the place changed:
saved keys, defaults, greying, and dependencies stay.

Without their AddOns (author, 1.1.1), "Follow Questie's tracker focus" and
"Keep Questie's and the game's focus in sync" (Questie) and "Point TomTom at
the focused quest" (TomTom, and Questie, Zygor, RestedXP, or QuestTrail: a step's
location needs no Questie) are greyed out, not hidden, with a
tooltip line that names what they need; saved values stay as they are. The
check is an initializer modify predicate (`AddModifyPredicate`,
Blizzard_SettingControls.lua), which the settings list runs each time it
draws the row, so an AddOn that loads after the page is built counts; it
tests the same globals the features use (`QuestieLoader`, `TomTom`).

- "Keep Questie's and the game's focus in sync" (`db.syncFocus`; needs
  "Follow Questie's tracker focus"): the focus you change last is copied to
  the other side. Questie's is set as its tracker menu sets it
  (`TrackerUtils:FocusQuest`, then `QuestieQuest:ToggleNotes(false)`); the
  game's with `C_SuperTrack.SetSuperTrackedQuestID`, and 0 clears it when you
  unfocus in Questie. The game has no objective focus: a Questie objective
  focus gives the game its quest, and a game focus on Questie's own quest
  keeps Questie's (objective) focus.
- "Point TomTom at the focused quest" (`db.tomtom`; needs TomTom, and for a
  quest focus Questie): the nearest spawn of the quest mobs the macro lists
  (author-approved: Questie's own target can be a dropper the macro leaves
  out), from `QuestieDB:GetNPC` spawns and `DistanceUtils.GetNearestSpawn`,
  set with `TrackerUtils:SetTomTomTarget`. A complete quest uses
  `TrackerUtils.SetQuestTomTomTarget` (the turn-in). With no spawn data, as
  Questie's "Set TomTom Target" does: an objective focus uses that
  objective's `spawnList` with `DistanceUtils.GetNearestObjective`, a quest
  focus `SetQuestTomTomTarget`. A guide step: see "With Zygor Guides Viewer" and
  "With RestedXP"; QuestTrail loaded: see "With QuestTrail".
  Pointed again when the focus, the unfinished
  objectives, the macro's quest mobs, or completion change; when the setting
  is turned on; never at login, so a waypoint of the player's own stays.
- Both call Questie's private modules through `QuestieLoader:ImportModule`
  (an unknown module comes back as an empty table, so each function is
  checked). They run after the macro is written, so a Questie change cannot
  stop the macro. Not confirmed in client.

### With Dyre's Toolkit (built; author-approved, 2026-10-19; required 1.1.0)

Dyre's Toolkit (`DyresToolkit`, its own repository, owned by the coordinating
session; do not edit it here) gives Dyre's AddOns one settings home, a
minimap menu, and widgets (contract 2). The Quest Target box is a widget.

- TOC: `## OptionalDeps: DyresToolkit, QuestieDB, Questie`, no
  `## Dependencies` (author, 1.3.0: DQT needs the toolkit for the Quest Target
  box, but without it DQT still loads, keeps the macro working, and says once
  what to install; CurseForge installs the toolkit), and `## Group:
  DyresToolkit` nests DQT under the toolkit in the in-game AddOn list.
  CurseForge uploads list
  `dyres-toolkit` and `questiedb` (project 1696795, by Lawgon, its own
  CurseForge project since 2026-11) as required dependencies, so the app
  installs them; Questie (334372) and TomTom (18808) are optional
  dependencies (author: "Works best with both").
  TomTom is not in the TOC: DQT reads `_G.TomTom` only when it points, after
  login, never at load time.
- When `DyresToolkit.RequireContract(2)` returns the toolkit, Core calls
  `RegisterAddOn` (addon, title, `openSettings = DQT.OpenSettings`) and
  Options makes the page with `RegisterSettingsCategory`, under "Dyre's
  AddOns", with the same settings and Integrations section heading. `/dqt` still
  opens DQT's own page.
- Dyre's Toolkit Profile (Toolkit 2.10.0; John, 2026-11-15 and 2026-11-17: "one
  place to go to persist your profile"; ../DyresToolkit/docs/PROFILES.md): Core's
  `JoinProfile`, from `LoadDB` (after the saved settings load, before the box), calls
  `RegisterProfilePart{addon, title, current = DyresQuestTargetingDB, sanitize =
  DQT.SanitizeDB, characterKeys, refresh = DQT.ApplyProfile}` when the toolkit has
  it; an older toolkit, or none, changes nothing, and the minimum toolkit stays.
  In the profile: every other key of DyresQuestTargetingDB (the macro switch,
  markers, mark, accountMacro, the Follow switches, activeGuide, syncFocus, tomtom,
  the box's switch, style, start folds, and `box`: its place, sizes, opacity, and
  folds). `characterKeys` (never copied, exported, or imported): `added`, the hit
  list (live data: the mobs of this character's quests and places; author,
  2026-11-20: "Hit list stays with the character that owns it."), `opener`
  (a spell of this character's spellbook; another class's spell would do nothing),
  and `targetOrder` (this character's quests).
  The macro's name is a constant, not saved. No account table. `ApplyProfile`
  (live, no reload): the toolkit's `ReapplyWidgets` for the box, `ApplyBoxStyle`,
  then `SelectGuide(db.activeGuide)`, which rebuilds the macro (a write in combat
  waits, as always; the toolkit refuses a copy in combat anyway).
- Otherwise (an older toolkit, or no page from it), the macro works as
  before with a top-level page and no box, and one chat line at login says
  to install or update Dyre's Toolkit from CurseForge.

### The Quest Target box (built 1.1.0; author-approved design, 2026-10-20)

- A toolkit widget (Box.lua, key `box`, saved in `db.box`; the toolkit owns
  its place, dragging, width, height, opacity, and mouse). Plain frames and
  buttons, nothing secure, so nothing is protected.
- Look (author: "really, just round the rectangle"; reference: a modern
  panel with rounded corners, a thin edge, and a header with the title left
  and icon buttons right): a rounded panel with a thin gold edge
  (UI-Tooltip-Background, UI-Tooltip-Border, edge 14), and the header as its
  own rounded inset panel (the same textures, edge 10, a gold edge at 60%),
  the quest name left and the fold button right; no close button. Built-in
  textures only. "Style" (`db.boxStyle`, a dropdown; repaired on load):
  "Brown and gold" (default; panel 0.28, 0.16, 0.07, 0.85, header 0.10,
  0.06, 0.02) or "Black and gold" (panel 0.05, 0.05, 0.06, 0.9, header
  slightly lighter, 0.13, 0.13, 0.14, so it reads); gold edges and titles in
  both. A change only re-colors, so it applies at once, also in combat. The
  author chose brown as the default: "it's classic". Opacity fades the whole box.
- Header (author): one line, "<quest> (Questie)", "(Zygor)", "(RestedXP)", or
  "(Focus)", plus
  " · ready to turn in"; "No focused quest"; "Macro off: ..." when DQT is
  off. Under it, "Objective: <text>" for a Questie objective focus.
- Sections, each title with its count: "Targets, most wanted first" (kill
  objective, "drops <item>", turn-in); "Not in the macro (255-letter
  limit)"; then the hit list, with no title row (the footer bar is its
  title, author), newest first, each "exact" or "similar" with a red X
  (`UI-GroupLoot-Pass-Up`; the game font has no "✕"). Targets and left-out
  names have a right-aligned rate column ("30.3%", or "-" with no rate), so
  the rate is never the part cut off. The tooltip says the rate in words:
  "drops <item>, 30.3% drop rate", or "drop rate unknown" for a dropper
  without one; a kill or turn-in names no drop rate.
- Footer (author: icons, always visible, "boxed similar to the header"): a
  hit list bar, the same rounded inset panel as the header and as tall. A
  click anywhere on it but its icons folds or opens the hit list (author:
  as on every section title); the icons sit above it. It is the hit list's
  title (author): with names shown, it sits under the quest rows and over
  its names, and the empty strip goes under the names; with the hit list
  folded, no strip (author: nothing to drop on), the bar right under the
  quest rows; with no names, the strip right under the bar, in its own
  section (author: it shows that names could go there).
  Every part is placed from the box's top, as the box grows and shrinks. Add at
  its left end and Clear at its right end (author), each inset as the fold
  button; between them the hit list's title, "Hit list: N" in gold
  (" (hidden)" when folded), a button: a click folds or opens the hit list
  (tooltip "Show or hide the hit list."). Icons and the fold button are 1.4 text sizes: the
  textures have a clear margin, so the mark shows just under the title's
  letters (author: "slightly smaller than the title text"). Folded, the box
  is a compact card: border, header bar, gap, objective line, gap, footer
  bar, border. Add (the plus texture): a click
  adds your target with similar names, a Shift-click the exact name; tooltip
  "Add your target to the hit list. Shift-click to match the exact name.
  With no target, type a name." With no target, out of combat (author,
  1.2.0), the plus opens a small panel under the box (not a popup in the
  middle of the screen): "Mob name to add" (or "(exact name)" after a
  Shift-click), a one-line edit box with the focus, Add and Cancel. Enter or
  Add adds the trimmed name through `/dqt add` or `add_exact`'s code (the
  same checks, duplicates, and 20-name limit); Escape, Cancel, or an empty
  name closes it. Never in combat (the plus then says "Target a mob or type
  a name." as before), and PLAYER_REGEN_DISABLED closes it.
  Clear (the red X texture): clears the hit list (no question asked, no
  popup); disabled and desaturated when empty; tooltip "Clear the hit
  list."
- Reordering (author): drag a hit list row up or down to change its
  priority, and (1.7.0) a target row within the targets the same way
  (`DQT.MoveTarget`, saved per quest; see "Names"). A row under "Not in the
  macro" is a target row too (1.7.1, author): drag it up into the targets. The box
  shows the most wanted first; `db.added` keeps it last (`DQT.MoveAdded`
  maps the box's place to the saved one). Hit list and target rows take clicks (to
  start the drag) and are not drag handles of the box; a row is dropped only
  within its own list (`dragRows.added`, `dragRows.targets`). While dragging, the
  row dims and a thin gold line shows the drop place, placed by an
  `OnUpdate` set only for the drag (on its start, cleared on its stop; not
  idle). The drop area is the whole box (author): anywhere above the first
  name (the bar, the targets, the header too) puts the name first, anywhere
  below the last name puts it last; only a drop outside the box cancels. The macro rebuilds as for add and
  remove; in combat the list changes at once and chat says "Moved <name> in
  your hit list. The macro updates after combat." Only the shown rows take
  part: a name past "+N more" or in a folded section is not reached (make
  the box taller, or `/dqt add` it again to make it the most wanted).
- No title bar (author: "keep it clean"): hovering over the header shows a
  tooltip with "Dyre's Quest Targeting" in gold, then the whole header line.
- Cut text (author): a row whose text is cut ("...") shows the whole text
  in a tooltip on mouse-over (`FontString:IsTruncated`). Rows take the
  mouse-over only (`SetMouseClickEnabled(false)`), so clicks pass through
  them to the world; the footer icons, the red X, the header, the section
  titles, and the hit list and target rows take clicks.
- Folding (author: "clicking the section titles should expand/collapse that
  section; the +/- at the top should expand/collapse all"): the header, the
  quest's title, folds the quest's part (its sections; the objective line
  stays); a section title folds that section; "Hit list" in the hit list
  bar folds the hit list. The fold button at the header's right end (plus
  or minus, text height; the header text stops before it, cut with a
  tooltip) folds all (the quest's part and the hit list) or, when all are
  folded, opens all (every section). All folded, the box is a compact card:
  the header bar, the objective line, and the hit list bar. Saved by key in
  `db.box.foldedSections` (quest, targets, dropped, added). Two settings
  (author) decide at login and `/reload`: "Start the quest targets folded"
  (`db.startQuestFolded`, default off) and "Start the hit list folded"
  (`db.startHitListFolded`, default on); the targets and left-out sections
  keep their saved folds. A 1.1.0 test build's `db.startFolded` becomes
  `db.startQuestFolded`. On the settings page, under "Quest Target Box":
  "Show the Quest Target Box", then the two fold switches, then "Style". The box keeps its top edge
  (`SetContentSize(width, height, "TOP")`, toolkit 2.1.0) and grows and
  shrinks with its content (author), up to Max height.
- The buttons call the `/dqt add`, `add_exact`, `remove`, and `reset` code,
  in combat too (author's choice): the hit list changes at once, the macro
  updates after combat, with the same chat line. The target name goes
  through the same secret check.
- Settings (author: "two knobs working against each other" otherwise): Width
  (180 to 400) and Max height (120 to 600) in pixels, and Text size (80 to
  150%), which changes only the font; no Size (scale) and no Lines. The rows
  that fit under Max height are its room divided by the row height, so a
  taller maximum shows more rows and bigger text fewer.
- Open, an empty strip half a bar tall (author: room to drop a dragged name
  last), under the hit list's names, or right under its bar when there are
  none; none when the hit list is folded: the bars' dark fill, no edge (an edge
  does not fit its height), no text. "Show the Quest Target
  Box" (`db.showBox`, default on), Opacity; "Reset size" restores Width,
  Height, and Text size, and keeps Opacity. A long list is cut: rows are
  shared out between open sections one at a time, and a cut section's last
  row is "+N more: /dqt list shows all".
- Shown whenever "Show the Quest Target Box" is on and DQT is on (author,
  1.2.0: also with no focused quest, "otherwise we can't add to our hitlist
  without a macro"); DQT off shows it only unlocked. With no focused quest,
  the line under the header says how to focus one (Questie's tracker where
  the game has no focus; the quest log, map, or Questie's tracker on
  Forever), and the hit list stays usable. The box itself takes clicks only
  while unlocked (toolkit mouse "unlocked"); the header and the footer icons
  are drag handles, so a Ctrl-drag on them moves the box while locked
  (toolkit 2.2.0's free move, family-wide, author-approved). A press that
  became a drag is not a click (it does not fold, add, or clear). Redrawn at the end of each rebuild and on unlock; no
  polling.

### Commands

- Key bindings (author-approved, 1.4.1): Bindings.xml, header
  "Dyre's Quest Targeting" (category ADDONS, as Dyre's Tank Tools), with "Add
  target to the hit list", "Add target to the hit list (exact name)", "Remove
  target from the hit list", and "Re-sync with your active guide". Each runs
  `SlashCmdList.DYRESQUESTTARGETING` with `add`, `add_exact`, `remove`, or `resync`, so it has the same checks and works in combat;
  no new global and no button click (`/click` does not press AddOn buttons). The
  `BINDING_` names are set in Core.lua. The game reads Bindings.xml by name, so the
  TOC does not list it.
- `/dqt` opens the settings (author-approved; not in combat, where it says
  so), as `/dqt options` does. `/dqt list` lists the focused quest, the names
  most wanted first with where each came from (and drop rates), names left
  out, and whether QuestieDB is loaded. `add`, `add_exact`, `remove`,
  `reset` (the hit list), `on`, `off` (the macro switch), `resync` (the active guide), `unlock` and `lock`
  (the toolkit's `Unlock`/`Lock`, as `/mtf` and `/dbr`: the toolkit's one
  `Dyre:` line, no DQT line), `reset_box` (`ResetWidgets`; not `reset`, which
  already clears the hit list), `debug` (runs even when DQT is unavailable; 1.8.1 adds the client's `GetLocale()` and
  QuestieDB's name language, `LibQuestieDB.l10n.currentLocale`, a private field shown only,
  because QuestieDB 1.1.4 has French names for 10,945 of 15,560 NPC IDs and the rest stay English). Backup slash `/questtargeting`; a clash on `/dqt` is
  reported once at login.

### Later (discussed, not agreed to build)

- Delete-cheapest-junk is skipped: Scrap already has that keybind. (TomTom's
  own quest waypoints are off on Forever, so DQT points TomTom through
  Questie; see above.)
- Interacting with the found NPC by turning the same key into
  `INTERACTTARGET` out of combat (two presses).
- Not built (author, 2026-10-21: "not worth it"): without Questie, pointing
  TomTom at the quest's map icon (`C_QuestLog.GetQuestsOnMap`; the game's own
  super-track arrow already points there) and turn-in names parsed from
  `GetQuestLogCompletionText`. No client API gives item droppers or
  objective NPC IDs.

## Project structure

- Runtime files: DyresQuestTargeting.toc, Commands.lua, Core.lua, Quest.lua,
  Macro.lua, Box.lua, Options.lua, loaded in that order, and Bindings.xml (the key
  bindings, read by the game by name). Commands parses `/dqt`; Core
  owns saved settings and their repair, the login banner, install and API
  checks, slash conflict reporting, the hit list, refresh scheduling, joining
  Dyre's Toolkit, and startup; Quest builds the focused quest's names; Macro builds and writes the
  macro; Box draws the Quest Target box; Options owns the settings page and
  the spellbook list.
- The suite loads the real Dyre's Toolkit (Core, Layout, Widgets, Settings,
  Profiles) from ../DyresToolkit when that folder exists, else the copy in
  tests/toolkit (as in CI; `DQT_VENDORED_TOOLKIT=1` uses the copy locally too). No test compares the copy with the toolkit (author: shared files
  are not checked byte for byte); a test checks the contract and the
  functions DQT calls. Refresh the copy when CI needs newer toolkit behavior.
- artwork/ holds the logo (SVG source, 1024 and 512 PNG renders) and
  screenshots/ for listings; it is never packaged.
- tests/run.lua holds the Lua 5.1 mock suite. tests/test_*.py cover the
  release helpers in scripts/. .github/workflows/ holds CI, opt-in publishing,
  and the approval gate check.
- README.md is the user-facing overview, TESTING.md the verification method,
  source evidence, and in-client checklist, docs/RELEASE_PLAN.md the release
  process, docs/CURSEFORGE_LISTING.md the CurseForge form text, and
  CHANGELOG.md the per-release change list.
- Documentation describes purpose, design, rules, and methodology. Do not add
  dated status reports or test-result logs to the docs; CHANGELOG.md is the
  release record. Keep README's claims true.
- The project uses the MIT License. The public author name is `Dyre` (TOC
  `## Author`, login banner, listings); LICENSE keeps the legal name, John
  Bedworth, and the release builder requires that exact notice.
- The TOC has `## Group: DyresToolkit`, so DQT nests under Dyre's Toolkit in
  the in-game AddOn list. Its `## Category: Quests` groups it only when the
  toolkit is missing; keep that identical to the CurseForge main category,
  because the list groups by exact text.
- No runtime assets besides Bindings.xml (author-approved, 1.4.1). Add none
  without agreement.
- Git origin: git@github.com:jbedworth/DyresQuestTargeting.git (public, as
  all of the author's AddOns). Inspect Git state before acting and preserve
  user work. Text is LF under .gitattributes.

## Client and API verification

- Target: Forever beta 1.60.1, build 70450, Interface 16001, Lua 5.1. Pin
  source review to Gethe/wow-ui-source commit
  `943764493e6b16d63ded3ab304150d1f05e58b57` (the 70338 source; the client
  is tested on 70450). Treat target-client
  documentation and FrameXML as authoritative; Retail and Classic examples are
  references only. Forever is game type "Camelot" (`WOW_PROJECT_ID` 18).
- Do not gate the runtime on client version, build, Interface, or class. Gate
  only on required APIs (Core's `REQUIRED_APIS`; an entry may list
  alternatives, any one of which is enough) and on a quest focus to follow.
- The target client has Midnight's secret values and AddOn restrictions. Never
  compare, concatenate, index, or print a value that may be secret: check
  `DQT.IsSecret` first and print with `DQT.Describe`.
- Never register `COMBAT_LOG_EVENT_UNFILTERED`: the client refuses it.
  `/click` does not press AddOn buttons. Macros change only out of combat.
- WoW APIs can return no values rather than nil; store results in locals before
  passing them to `tostring`. The client may not show Lua error popups, so
  diagnostics report errors in chat.

## Clean coding

- Lua 5.1 syntax and libraries only. Four-space indentation. Prefer local
  variables and functions; share state through the AddOn namespace. Expose
  globals only when WoW requires them (slash commands, saved variables),
  prefixed `DyresQuestTargeting` or `DQT`.
- Centralize meaningful constants; avoid unexplained magic numbers.
- Comment sparingly: non-obvious intent, API constraints, or tradeoffs.
- Event-driven work only; no polling or idle `OnUpdate` handlers.

## Safety and error reporting

- Validate commands and names before changing settings or the macro. Treat bad
  commands, missing APIs, and mixed installs as expected failures with concise
  feedback prefixed `DQT:`.
- Never prompt or open popups in combat. Never swallow errors with blanket
  `pcall` handlers or replace the error handler.
- Repair saved settings on load so a damaged or older table cannot break DQT.
- Startup is driven by Core at `PLAYER_LOGIN`; never rely on event handler
  order between files.

## Testing and documentation

- Run `tests/run.lua` with Lua 5.1 and `luac5.1 -p` on every Lua file (Mage
  Tools Forever's `.tools/` has portable copies). Run
  `python -m unittest discover -s tests -p 'test_*.py'` and actionlint on
  workflow changes. Report actual results; never invent them.
- Add focused tests alongside behavior changes. Mocks cannot prove
  protected-action rules, secret-value behavior, or taint; those need the
  in-client checks in TESTING.md.

## Releases and collaboration

- Read docs/RELEASE_PLAN.md before packaging or changing release automation.
- Do not create commits, repositories, tags, uploads, or releases unless asked.
- Every release needs a `## <version>` section in CHANGELOG.md with
  player-facing changes; the builder puts it at the top of release-notes.md
  and fails without it.
- Package only DyresQuestTargeting.toc, Commands.lua, Core.lua, Quest.lua,
  Macro.lua, Box.lua, Options.lua, Bindings.xml, and LICENSE under the top-level
  `DyresQuestTargeting/` folder, named
  `DyresQuestTargeting-<version>-forever.zip`, with the builder's
  BigWigs-format `release.json` (flavor `forever`) attached for WowUp.
- Publishing requires repository variables `ENABLE_GITHUB_RELEASES='true'`
  and, for CurseForge, `ENABLE_CURSEFORGE_UPLOADS='true'`, plus
  `CURSEFORGE_PROJECT_ID`, `CURSEFORGE_GAME_VERSION_ID`, and the `release`
  environment secret `CF_API_TOKEN` (an environment secret, never a repository
  secret). Both publish jobs use the `release` environment with a required
  reviewer; verify the gate with `gate-check.yml` before enabling publishing.
- Action pins are full commit SHAs; review any pin change against the GitHub API.
- Commit messages, when requested: imperative, capitalized subject, at most
  about 50 characters, no ending punctuation; short wrapped body when useful.
