# Changelog

Player-facing changes for each Dyre's Quest Targeting release, newest first. The
release builder puts the matching section at the top of each release's notes.

## 1.1.1

### Other changes

- Without Questie, "Follow Questie's tracker focus" and "Keep Questie's and the game's focus in sync" are greyed out in the settings; without Questie and TomTom, so is "Point TomTom at the focused quest". Their tooltips say what they need, and they keep their values, so they work again once the AddOn is installed.
- Size sliders are labeled without "(%)": their values already show the % sign.

## 1.1.0

### Features

- The Quest Target box shows your focused quest in its header ("(Questie)" or "(Focus)"), the objective you focused in Questie, what the macro looks for (most wanted first, with each quest item and its drop rate in its own column), the names left out of the macro, and your hit list. Hover over a cut-off row to read all of it.
- Change the hit list from the box: drag a name up or down to change its priority; a red X removes a name; in the footer bar, which always shows (with the hit list's count), the plus adds your target (Shift-click for the exact name) and the red X clears the list. They work in combat too; the macro updates when combat ends.
- Click a title to fold or open its part: the quest's name in the header, a section title, or "Hit list" in its bar; the plus or minus at the header's right end folds or opens everything. The box grows and shrinks to fit, keeping its top edge. "Start the quest targets folded" (off by default) and "Start the hit list folded" (on by default) decide how it starts at login.
- The box is a rounded panel with a thin gold edge and a darker rounded header; "Style" picks brown and gold (the default) or black and gold. Ctrl-drag its header to move it without unlocking, or move it with `/dqt unlock` and `/dqt lock` (the same as `/dyre unlock` and `/dyre lock`), or put it back with `/dqt reset_box`. Its width, maximum height, text size, and opacity are settings, and the box size and text size are independent. "Show the Quest Target Box" turns it off. It hides when there is nothing to show, and lets clicks through except on its icons, header, and section titles.

### Other changes

- Dyre's Toolkit 2.0 or later is now required (the CurseForge app installs it). With an older toolkit, the macro still works, without the box, and chat says to update it.

## 1.0.0

The first full release for WoW: Forever, no longer marked beta: it was play tested on the Forever beta client 1.60.1, build 70450. CurseForge now offers it as a release, so the app updates it and installs what it needs for every player.

- The CurseForge app installs Dyre's Toolkit with DQT. Questie and TomTom are listed as optional: DQT works best with both.

## 0.1.2-beta

- Joins Dyre's Toolkit, when it is installed: the settings move under Options > AddOns > Dyre's AddOns, the toolkit's minimap menu opens them, and the in-game AddOn list shows DQT under Dyre's Toolkit. The CurseForge app installs the toolkit with DQT.
- Without Dyre's Toolkit, DQT works as before, and chat says once at login where to get it.
- A spell you pick for "On a mob, also" now uses `/use` instead of `/cast` in the macro: it casts the same spell, one letter shorter, so a little more room is left for names.

## 0.1.1-beta

- Settings dropdowns (markers and "On a mob, also") show their own choice, even after you open another AddOn's sound picker, such as one from Dyre's Sounds 0.1.0.

## 0.1.0-beta

First beta for WoW: Forever.

- The character macro "! Target (DQT)" follows your focused quest. Each character gets its own macro. Press it to target the nearest mob or NPC the quest still needs and mark it: a skull on a mob, a green triangle on an NPC.
- It follows the quest you focus in the game's quest log or map, or in Questie's tracker (a setting), whichever you set last. A Questie objective focus targets only that objective. Chat says when the focused quest changes.
- Kill objectives come from the quest log. With QuestieDB installed, it also finds the mobs that drop the quest's items and the NPC you turn the quest in to. With Questie too, it picks the six best droppers by Questie's drop rates, and `/dqt list` shows each rate.
- Finished objectives leave the macro by themselves, and chat says so. In combat, the macro updates when combat ends.
- Your hit list: `/dqt add` and `/dqt add_exact` add any mob (similar names or the exact name), saved per character; `/dqt remove` and `/dqt reset` take them off. `/dqt` reads macro conditions, so `/dqt [mod:shift] remove; add` works in a macro of your own.
- Settings: which markers to use, or no marking; and what to do on a mob: nothing, start attacking, or cast a harmful spell of 1 second or less that you pick from your spellbook. `/dqt on` and `/dqt off` stop or start updating the macro.
- `/dqt` opens the settings. `/dqt list` lists what the macro targets, most wanted first, and why, and which names did not fit in the macro's 255 letters.
- Short of character macro slots? "Use an account-wide macro" (off by default) keeps one account macro instead. Not for playing two characters at once.
- With Questie, two experimental settings (off by default; use with caution): keep Questie's and the game's quest focus in sync, and point the TomTom arrow at the nearest of the mobs the macro looks for, moving it as objectives finish.
