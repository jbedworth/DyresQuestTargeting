# Testing

## Method

1. **Pinned source review.** Client behavior is read from Blizzard's FrameXML
   and generated API documentation at Gethe/wow-ui-source commit
   `943764493e6b16d63ded3ab304150d1f05e58b57` (`1.60.1.70338`). Source
   establishes declared APIs, templates, and code paths, not operational behavior.
2. **Automated mock tests.** `tests/run.lua` exercises commands, saved
   settings, the names built from a focused quest (with and without a mock
   QuestieDB), the macro body and its 255-letter limit, combat deferral, the
   spellbook opener list, and the settings page, against a minimal mock of the
   client. Mocks model secret values as values that raise errors on
   comparison, concatenation, indexing, or printing. Writing a macro in combat
   raises an error, as the client refuses it.
3. **In-client checks.** The checklist below covers everything mocks cannot.

```sh
lua5.1 tests/run.lua
luac5.1 -p Commands.lua Core.lua Quest.lua Macro.lua Options.lua tests/run.lua
python -m unittest discover -s tests -p 'test_*.py'
```

Locally, use the portable Lua 5.1 and Python under Mage Tools Forever's ignored
`.tools/` folder (or a copy here); CI uses ubuntu-24.04's `lua5.1` package and
native `python3`.

## Source findings

- Forever is game type "Camelot": `WOW_PROJECT_ID = 18`
  (Blizzard_ProjectConstants/Camelot/ProjectConstants.lua). It loads the
  Mainline quest log and map with small overrides.
- "Focus" is super-tracking: the quest log's focus toggle calls
  `C_SuperTrack.SetSuperTrackedQuestID` (QuestMapFrame.lua,
  `QuestLogPopupDetailMixin:ToggleQuestFocus`). One quest at a time; event
  `SUPER_TRACKING_CHANGED`.
- `C_QuestLog.GetQuestObjectives` returns text, type, finished, and counts,
  with no creature, item, or object IDs. Quest and super-track functions have
  no secret returns.
- `UnitName` has `SecretWhenUnitNameIdentityRestricted`; `/dqt add` checks
  `issecretvalue` before keeping a target's name. `GetRaidTargetIndex` has
  `SecretReturns`, so marking is left to `/tm` in the macro.
- `/tm` passes its whole text to `SecureCmdOptionParse`
  (Blizzard_ChatFrameBase/Shared/SlashCommands.lua), which takes the first `;`
  clause whose conditions match; `!N` skips a unit that already has marker N.
  `/target` calls `TargetUnit(name)` and `/targetexact` `TargetUnit(name, true)`.
  `/startattack` and `/cast` are secure macro commands.
- Interacting has no slash command and no secure action type: `INTERACTTARGET`
  is only a key binding (Bindings_Camelot.xml), enabled by Options → Controls
  → Enable Interact Key (`softTargetInteract`).
- The spellbook APIs (`C_SpellBook.GetSpellBookItemInfo` and friends) have no
  secret returns.
- Questie 12.1.0's tracker focus is its own, not super-tracking: `TrackerUtils:FocusQuest`
  and `FocusObjective` (Modules/Tracker/TrackerUtils.lua) set
  `Questie.db.char.TrackerFocus` to a quest ID or "questID objectiveIndex";
  `UnFocus` clears it. No event fires. `QuestieLoader` and `Questie` are globals.
- QuestieDB 1.0.6 (Forever flavor) exposes `LibQuestieDB` with
  `RequireContract`, and `Quest.objectives`, `Quest.finishedBy`, `Npc.name`,
  `Item.name`, and `Item.npcDrops` (its Types/*.t.lua, contract 4).
- TomTom 4.3.12's quest waypoints run only when `WOW_PROJECT_ID` is Mainline,
  so they are off on Forever.

## Found in client

- Forever's kill objective text puts the count first: "0/6 Redridge Poacher
  slain"; the name parses cleanly, and finished objectives report
  `finished=true` and are left out.
- QuestieDB loads without errors, and its NPC names match Forever's objective
  text (Assessing the Threat: Redridge Mongrel 423, Redridge Poacher 424;
  turn-in Deputy Feldon).
- The macro is made in the character tab (index 121, the first character
  slot), with the body as designed.
- RestedXP sets the game's focus from its guide steps, also with its window
  hidden; with it disabled, the game's and Questie's focuses behave as designed.
- A new AddOn folder was picked up by `/reload`.

## In-client checklist

With `/dqt debug` for details:

1. Login: the banner, "Made the character macro", and "! Target (DQT)" in the
   character tab of the Macros window, with the Hunter Marksman icon (file ID
   132177). A character with the old "! Quest Targets" macro gets "Renamed the
   character macro" instead, and the macro stays on its action bar button.
2. Focus a kill quest: the macro lists its mobs, the first objective last.
   Check the objective text Forever gives ("X slain: 0/8" or "0/8 X slain").
3. Press the macro near a quest mob: it is targeted and gets a skull; a second
   press keeps the skull. With no quest mob near, nothing is targeted.
4. Only a corpse near: check what `/targetlasttarget [dead]` after
   `/cleartarget` does (the old target may come back and be marked).
5. A quest NPC (the turn-in, with QuestieDB): the green triangle. A neutral
   (yellow) NPC: check that `[noharm]` marks it. With nothing found, the
   macro gives no "You can't do that right now".
6. With QuestieDB: an item quest lists the mobs that drop the item; a
   finished quest lists the turn-in NPC. Check that QuestieDB's names match
   Forever's mobs.
7. `/dqt add Goretusk` finds Great Goretusk; `/dqt add_exact` does not.
   `/dqt add` with a dead mob targeted adds its name.
8. In combat: `/dqt add` says the macro updates after combat; it does, once
   combat ends, and nothing is blocked (no "AddOn action blocked" message).
9. Opener: the dropdown lists your spellbook, every rank up to the one shown;
   pick a rank-1 spell and press the macro on a mob: it casts that rank.
   Check how Forever's spellbook names ranks (`subName` "Rank N"). Only
   harmful spells of 1 second or less are listed: no heals or buffs, and a
   spell whose top rank is slower shows only its fast ranks. Check that
   `castTime` is in milliseconds (an instant spell is 0).
10. "Mark what the macro finds" off: no `/tm` line.
11. Delete the macro: the next quest change makes it again.
19. With other AddOns' settings dropdowns opened first (for example a Dyre's
    Sounds sound picker in Mage Tools Forever), DQT's three dropdowns still
    show their own choice (Skull, Triangle, Nothing), not a sound name.
18. `/dqt` opens the settings page; in combat it says it opens out of combat
    and opens nothing. `/dqt list` works in and out of combat.
17. "Use an account-wide macro" on: "! Target (DQT)" appears in the General
    (account) tab with the Hunter Marksman icon, chat says the character one
    is no longer updated, and the account one follows the focused quest. Log
    in another character: the account macro follows that character's quest.
    Off again: the character macro is updated again.
13. Finish an objective in combat: chat says the mob was removed and that the
    macro updates after combat; after combat it is gone from the macro.
12. With Questie: right-click a quest in Questie's tracker, Focus Quest: the
    macro follows it, and `/dqt list` says "Questie's focus". Focus Objective:
    only that objective's mobs (check that Questie's objective index matches
    the game's). Then focus another quest in the game's quest log: that one
    wins. Unfocus in Questie: the game's focus again. Relog with a Questie
    focus set: Questie's wins.
14. "Keep Questie's and the game's focus in sync" on: Focus Quest in
    Questie's tracker moves the game's focus (the map's quest arrow) to it.
    Focus another quest in the game's quest log: Questie's tracker focuses it
    and fades the other quests' map icons. Focus Objective: the game focuses
    its quest and the macro keeps only that objective. Unfocus in Questie:
    the game's focus clears. No back and forth: `/dqt debug` shows both
    focuses on one quest. Check this with RestedXP disabled (it sets the
    game's focus itself).
15. "Point TomTom at the focused quest" on, with TomTom: turning it on sets
    the arrow on a mob the macro lists (compare with `/dqt list`); changing the
    focused quest moves it; Focus Objective points at that objective's
    mobs; finishing an objective, then the quest, moves it again (the
    turn-in last). A /reload does not move it.
16. With Questie, an item quest (The Totem of Infliction: Ghoul Fang has six
    droppers): `/dqt list` lists the droppers with drop rates, the best last in
    the macro; `/dqt debug` lists every dropper and its rate, and no
    "UNUSED" name reaches the macro.
