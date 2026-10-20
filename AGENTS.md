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

### With Dyre's Toolkit (built; author-approved, 2026-10-19)

Dyre's Toolkit (`DyresToolkit`, its own repository, owned by the coordinating
session; do not edit it here) gives Dyre's AddOns one settings home and a
minimap menu. DQT has no movable frames, so it only joins those.

- TOC: `## OptionalDeps` lists `DyresToolkit` (never `## Dependencies`, so
  DQT loads without it) and `## Group: DyresToolkit` nests DQT under the
  toolkit in the in-game AddOn list. CurseForge uploads list `dyres-toolkit`
  as a required dependency, so the app installs it; Questie stays optional.
- When `DyresToolkit.RequireContract(1)` returns the toolkit, Core calls
  `RegisterAddOn` (addon, title, `openSettings = DQT.OpenSettings`) and
  Options makes the page with `RegisterSettingsCategory`, under "Dyre's
  AddOns", with the same settings and Questie section heading. `/dqt` still
  opens DQT's own page.
- Otherwise (no toolkit, a newer contract, or no page from it), the
  top-level page as before. With no toolkit at all, one chat line at login
  names CurseForge as the place to install it.

### Commands

- `/dqt` opens the settings (author-approved; not in combat, where it says
  so), as `/dqt options` does. `/dqt list` lists the focused quest, the names
  most wanted first with where each came from (and drop rates), names left
  out, and whether QuestieDB is loaded. `add`, `add_exact`, `remove`,
  `reset`, `on`, `off`, `debug` (runs even when DQT is unavailable). Backup slash `/questtargeting`; a clash on `/dqt` is
  reported once at login.

### Later (discussed, not agreed to build)

- Delete-cheapest-junk is skipped: Scrap already has that keybind. (TomTom's
  own quest waypoints are off on Forever, so DQT points TomTom through
  Questie; see above.)
- Interacting with the found NPC by turning the same key into
  `INTERACTTARGET` out of combat (two presses).

## Project structure

- Runtime files: DyresQuestTargeting.toc, Commands.lua, Core.lua, Quest.lua,
  Macro.lua, Options.lua, loaded in that order. Commands parses `/dqt`; Core
  owns saved settings and their repair, the login banner, install and API
  checks, slash conflict reporting, the hit list, refresh scheduling, joining
  Dyre's Toolkit, and startup; Quest builds the focused quest's names; Macro builds and writes the
  macro; Options owns the settings page and the spellbook list.
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
  only on required APIs (Core's `REQUIRED_APIS`).
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
  Macro.lua, Options.lua, and LICENSE under the top-level
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
