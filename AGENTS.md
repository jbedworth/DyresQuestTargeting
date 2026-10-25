# Agent Guidelines

## Project purpose and scope

Dyre's Quest Targeting (DQT, `/dqt`) is a World of Warcraft: Forever AddOn
that keeps one targeting macro up to date with the quest you are working on.
It replaces the one RestedXP (RXP) feature the author still wanted, built from
Forever's own quest journal instead of a guide. Keep this feature set; do not
add speculative features or frameworks without agreement.

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
  up to the one the spellbook shows. Only harmful spells
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
  kill objectives as everywhere. The TOC stays Interface 16001 for now
  (players tick "Load out of date AddOns"); release plumbing comes later.
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
- Unfinished objectives, the first objective last (most important). Kill
  objectives (`monster`): the client's text gives the name ("X slain: 0/8" or
  "0/8 X slain", English only). Item objectives: no client source.
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

### With Questie installed (built; author-approved, both default off)

Both are marked experimental (author): under the settings section heading
"Questie Synchronization (Experimental)" (when the client has
`CreateSettingsListSectionHeaderInitializer`), "(experimental)" in the
setting names, a caution in their tooltips, README, CHANGELOG, and listing.

Without their AddOns (author, 1.1.1), "Follow Questie's tracker focus" and
"Keep Questie's and the game's focus in sync" (Questie) and "Point TomTom at
the focused quest" (Questie and TomTom) are greyed out, not hidden, with a
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
- "Point TomTom at the focused quest" (`db.tomtom`; needs Questie and
  TomTom): the nearest spawn of the quest mobs the macro lists
  (author-approved: Questie's own target can be a dropper the macro leaves
  out), from `QuestieDB:GetNPC` spawns and `DistanceUtils.GetNearestSpawn`,
  set with `TrackerUtils:SetTomTomTarget`. A complete quest uses
  `TrackerUtils.SetQuestTomTomTarget` (the turn-in). With no spawn data, as
  Questie's "Set TomTom Target" does: an objective focus uses that
  objective's `spawnList` with `DistanceUtils.GetNearestObjective`, a quest
  focus `SetQuestTomTomTarget`. Pointed again when the focus, the unfinished
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

- TOC: `## Dependencies: DyresToolkit` (required since 1.1.0, for the box,
  as every Dyre's AddOn with frames) and `## Group: DyresToolkit` nests DQT
  under the toolkit in the in-game AddOn list. CurseForge uploads list `dyres-toolkit`
  as a required dependency, so the app installs it; Questie (334372) and
  TomTom (18808) are optional dependencies (author: "Works best with both").
  TomTom is not in the TOC: DQT reads `_G.TomTom` only when it points, after
  login, never at load time.
- When `DyresToolkit.RequireContract(2)` returns the toolkit, Core calls
  `RegisterAddOn` (addon, title, `openSettings = DQT.OpenSettings`) and
  Options makes the page with `RegisterSettingsCategory`, under "Dyre's
  AddOns", with the same settings and Questie section heading. `/dqt` still
  opens DQT's own page.
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
- Header (author): one line, "<quest> (Questie)" or "<quest> (Focus)", plus
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
  priority; the target rows keep their order (drop rate order). The box
  shows the most wanted first; `db.added` keeps it last (`DQT.MoveAdded`
  maps the box's place to the saved one). Hit list rows take clicks (to
  start the drag) and are not drag handles of the box. While dragging, the
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
  titles, and the hit list rows take clicks.
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

- `/dqt` opens the settings (author-approved; not in combat, where it says
  so), as `/dqt options` does. `/dqt list` lists the focused quest, the names
  most wanted first with where each came from (and drop rates), names left
  out, and whether QuestieDB is loaded. `add`, `add_exact`, `remove`,
  `reset` (the hit list), `on`, `off` (the macro switch), `unlock` and `lock`
  (the toolkit's `Unlock`/`Lock`, as `/mtf` and `/dbr`: the toolkit's one
  `Dyre:` line, no DQT line), `reset_box` (`ResetWidgets`; not `reset`, which
  already clears the hit list), `debug` (runs even when DQT is unavailable). Backup slash `/questtargeting`; a clash on `/dqt` is
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
  Macro.lua, Box.lua, Options.lua, loaded in that order. Commands parses `/dqt`; Core
  owns saved settings and their repair, the login banner, install and API
  checks, slash conflict reporting, the hit list, refresh scheduling, joining
  Dyre's Toolkit, and startup; Quest builds the focused quest's names; Macro builds and writes the
  macro; Box draws the Quest Target box; Options owns the settings page and
  the spellbook list.
- tests/toolkit holds a copy of Dyre's Toolkit's Core, Layout, Widgets, and
  Settings files, which the suite loads; a test fails when the copy differs
  from ../DyresToolkit. Copy them again after a toolkit change.
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
- No runtime assets. Add none without agreement.
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
  Macro.lua, Box.lua, Options.lua, and LICENSE under the top-level
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
