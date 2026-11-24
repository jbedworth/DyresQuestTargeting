# Changelog

Player-facing changes for each Dyre's Quest Targeting release, newest first. The
release builder puts the matching section at the top of each release's notes.

## 1.8.1

### Features

- "Say targeting changes in chat" in the settings (on by default). Turn it off to hide the chat lines that say the focused quest changed or that a finished objective's mob left the macro. Errors, problems, and replies to your own commands still show.

### Other changes

- `/dqt debug` now shows the client's language and the language QuestieDB gives names in. On a client that is not English, a mob QuestieDB has no translation for keeps its English name, and the macro then cannot find it by that name.
- OpenXP support is for OpenXP 1.x only. OpenXP 2.0 is a new AddOn that keeps its data private, so DQT cannot read its steps, and "Follow OpenXP's current step" stays greyed out with it. The setting's tooltip now says so. With OpenXP 2, DQT follows your quest focus as usual.

## 1.8.0

### Features

- With OpenXP, the free leveling guide based on RestedXP's: the macro can target the mobs and NPCs on OpenXP's current and sticky steps, as it does for RestedXP. "Follow OpenXP's current step" in the settings, on by default, greyed out without OpenXP. OpenXP is also a choice under "Active guide", and "Point TomTom at the focused quest" follows its step's location. With RestedXP and OpenXP both loaded, the newest step wins, unless you choose one under "Active guide". Experimental: it reads OpenXP's own data, not a public API, so an OpenXP update can stop it; the macro keeps working.

### Other changes

- The login message follows Dyre's Toolkit's "Welcome messages at login" switch (Toolkit 2.14.0 or later). Errors still show.

## 1.7.1

### Fixes

- Zygor and RestedXP: the mobs of a sticky step now come before the current step's in the macro. Before, a sticky rare such as Anaya Dawnrunner was the first name left out when the macro was full.
- Smart targeting mode now puts rare and named mobs first on Zygor, RestedXP, and QuestTrail steps too. The other names keep the guide's order.
- A name under "Not in the macro" in the Quest Target Box can now be dragged up into the targets.

## 1.7.0

### Features

- Drag a quest target up or down in the Quest Target Box to change its priority, as with the hit list. DQT keeps your order for that quest until it leaves your quest log.
- "Smart targeting mode" (on by default): the macro now wants rare and named mobs first, then the mobs that drop the quest's items (highest drop rate first, across all of the quest's items), then the mobs you kill for it. Turn it off for the quest's own order. An order you drag wins over both.

## 1.6.1

### Fixes

- Clients in other languages: "On a mob, also" now lists each rank of a spell (such as "Rang 3" in French) and casts it with the client's own words.
- Clients in other languages: a kill objective now targets its mob when Questie's database does not know it, using the client's own objective text (such as "Condor : 0/8 personnages tués" in French).

## 1.6.0

### Features

- DQT's settings and the Quest Target Box's place, size, and style are now part of your Dyre's Toolkit profile: copy them from another character, or export and import them, on Dyre's Toolkit's settings page. They apply at once, with no reload. Your hit list and your "On a mob, also" spell stay with each character. This needs Dyre's Toolkit 2.10.0 or newer; with an older one, DQT works as before.

## 1.5.0

### Features

- "Active guide" in the settings: choose which focus drives the macro. Most Recent Focus (the default) works as before. Choose Questie to follow your quest focus only, or Zygor, RestedXP, or QuestTrail to follow that guide's step: each new step then also focuses its quest in Questie's tracker, and the quest Questie focuses by itself when you accept a quest no longer takes the macro away from your guide. A quest you focus yourself wins until the guide's next step. Experimental: it uses the guides' and Questie's own code, not a public API.
- Re-sync with your active guide: a button on the Quest Target Box header, `/dqt resync`, and a key binding take the macro and Questie's focus back to the guide's current step.

## 1.4.1

The QuestTrail support is new and in beta. Please tell us how it works for you, and what goes wrong, in the comments on CurseForge or in an issue on GitHub.

### Features

- With QuestTrail (beta): the macro can target the step QuestTrail's compass points at (that objective's mobs, the turn-in, or who gives the quest) and its "on the way" objectives, the camps its route walks through. "Follow QuestTrail's current step" in the settings, on by default, greyed out without QuestTrail. With "Point TomTom at the focused quest", the TomTom arrow goes where QuestTrail's compass goes. Experimental: it reads QuestTrail's own data, not a public API, so a QuestTrail update can stop it; the macro keeps working.
- With QuestTrail loaded, the TomTom waypoints DQT sets no longer take over QuestTrail's compass.
- Key bindings for the hit list: add your target, add it with its exact name, or remove it. Find them under Options > Key Bindings > AddOns > Dyre's Quest Targeting.

## 1.3.0

### Features

- With Zygor Guides Viewer: the macro can target the mobs and NPCs of the guide step Zygor shows, for every quest of the step and of the sticky steps shown with it. "Follow Zygor's current step" in the settings, on by default, greyed out without Zygor. The focus you change last wins: Zygor's new step, Questie's tracker focus, or the game's. A travel or text step leaves your quest focus in charge. The box header and `/dqt list` say "(Zygor)". Experimental: it reads Zygor's own data, not a public API, so a Zygor update can stop it; the macro keeps working.
- With RestedXP: the same for the names on its current and sticky steps. "Follow RestedXP's current step" in the settings, on by default, greyed out without RestedXP. RestedXP's own macro and arrow are left alone. Experimental: it reads RestedXP's own data, not a public API, so a RestedXP update can stop it; the macro keeps working.
- The settings for other AddOns (Questie, Zygor, RestedXP, TomTom) are now together under one heading, "Integrations (Experimental)", which was "Questie Synchronization". Your choices stay as they are.
- "Point TomTom at the focused quest" also follows Zygor's and RestedXP's steps: when the step has a location, the arrow goes there and moves on with the guide's next waypoint. Otherwise, with Questie, it goes to the nearest of the step's mobs and NPCs. It does not move at login. With a guide, this setting no longer needs Questie for a step's location.

### Other changes

- QuestieDB is now its own CurseForge project, and the CurseForge app installs it with DQT, as it does Dyre's Toolkit.
- DQT now loads also when Dyre's Toolkit is missing, and says once in chat to install it; without it, the macro works but there is no Quest Target box.

## 1.2.0

### Features

- WoW Classic Era and Anniversary: the game has no quest focus there, so DQT follows Questie's tracker focus. Without Questie, quest targeting is off, but the macro and the box still keep your hit list; chat says so at login.
- The Quest Target box shows also with no focused quest, with a line on how to focus one, so you can always change the hit list from it.
- With no target, the hit list's plus opens a small box under the Quest Target box to type a mob's name (Shift-click for the exact name). It never opens in combat.
- On those clients, "Follow Questie's tracker focus" shows on and greyed (it is the only focus), "Keep Questie's and the game's focus in sync" is greyed (nothing to sync), and the "On a mob, also" list reads your spellbook there too.

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
