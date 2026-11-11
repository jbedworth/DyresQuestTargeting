# CurseForge listing

Copy-ready text for the CurseForge project form. Keep it aligned with README.md
and the tested client; do not advertise clients or versions that have not been
tested.

## Project fields

| Field | Value |
| --- | --- |
| Name | Dyre's Quest Targeting |
| Project ID | 1752880 (the value for the `CURSEFORGE_PROJECT_ID` repository variable; see docs/RELEASE_PLAN.md) |
| Class | Addons |
| Main category | Quests. Keep it identical to the TOC `## Category`, which groups the AddOn in the in-game AddOn list when Dyre's Toolkit is missing (with it, `## Group: DyresToolkit` nests DQT under the toolkit). |
| Additional categories | None yet (CurseForge allows up to 4; unrelated ones can send the project back for changes). |
| Author shown | Dyre, set through the CurseForge account's username |
| License | MIT License |
| Logo | artwork/dyres-quest-targeting-logo.png (1024 x 1024); artwork/dyres-quest-targeting-logo-512.png if a smaller square is wanted |
| Relations | QuestieDB (CurseForge project 1696795, slug `questiedb`, by Lawgon) and Dyre's Toolkit (slug `dyres-toolkit`), required dependencies; Questie (project 334372) and TomTom (project 18808), optional dependencies. CI uploads set all four; add them by hand on any file uploaded through the website. Zygor Guides Viewer, RestedXP, and QuestTrail are not relations: they are separate AddOns, and DQT does not install them. |
| Screenshots | artwork/screenshots/, the PNG files; see Screenshots below |
| Source | https://github.com/jbedworth/DyresQuestTargeting |
| Issues | https://github.com/jbedworth/DyresQuestTargeting/issues |
| Donation | Ko-fi, https://ko-fi.com/dyre_janelle (the project's Donation field) |

## Summary

Shows your Focused Quest and builds a "hit list" and targeting macro based on what you're trying to accomplish.

## Screenshots

Upload the PNG files in the project's Images (Media) tab, each with its title
and caption. CurseForge's support pages state no format for these images
(only the logo must be a PNG), so use the PNGs.

| File | Title | Caption |
| --- | --- | --- |
| artwork/screenshots/quest-target-box.png | The Quest Target box | Your focused quest, its targets most wanted first with drop rates, the names left out of the macro, and your hit list. |
| artwork/screenshots/settings-macro-and-markers.png | Settings: the macro | Keep the macro up to date, pick the raid markers, choose what to do on a mob, and turn on the integrations with Questie, Zygor, RestedXP, and TomTom. |
| artwork/screenshots/settings-quest-target-box.png | Settings: the Quest Target box | Choose what starts folded, the style, width, maximum height, text size, and opacity. |

## Description

Paste this with the description editor in Markdown mode. Pasted into the rich
text editor, the headings, bullets, and bold show as raw, escaped markdown.

Per-file changelogs need no manual text: each CI upload uses the version's
`CHANGELOG.md` section, through `release-notes.md`.

This doc is the source: change the text here first, then paste it into
CurseForge. The opening sentences are the author's own wording.

```markdown
Dyre's Quest Targeting makes it easy to see what quest you are focused on, and builds a targeting macro that you can use to target what you are after. Also lets you manually add your own targets to the "hit list". A targeting macro is built and maintained for you based on what you're trying to do. Works with Questie, if you want the best experience.

### What it targets
- The mobs your focused quest still needs killed. Finished objectives drop out by themselves. DQT lets you know in chat when the lists change.
- With QuestieDB installed (the CurseForge app installs it with DQT): the mobs that drop the quest's items, and the NPC you turn it in to once it is done. With Questie, DQT picks the best droppers by Questie's drop rates.
- A Questie objective focus targets only that objective.
- Your own hit list, for any mob: `/dqt add Goretusk` finds anything named like it; `/dqt add_exact Great Goretusk` only that name. With nothing typed, they add your target. Your hit list is prioritized over the quest list.

### With Zygor Guides Viewer
A Zygor step often covers several quests in one area, and Zygor's Action Bar gives one button per name. DQT puts the whole step behind one macro: one press looks for the mobs and NPCs of every quest of the step, plus the sticky steps Zygor shows with it.
- A new step updates the macro by itself, and finished goals drop out. The box header and `/dqt list` say "(Zygor)".
- The focus you change last wins: Zygor's step, Questie's tracker, or the game's quest log and map. At login, Zygor's step wins when it names a mob or NPC. A travel or text step leaves your quest focus in charge.
- Zygor Guides Viewer is a separate product (its full guides are paid). DQT does not install it, and the setting is greyed out without it.
- Experimental, to be used with caution: DQT reads Zygor's own data, not a public API, so a Zygor update can stop it. DQT then follows your quest focus, and the macro keeps working.

### With RestedXP
RestedXP has its own targeting macro and arrow, and DQT leaves them alone. DQT follows its current and sticky steps too. DQT's macro adds your hit list, your choice of markers, and a spell or attack on a mob, and the box shows what it looks for. With TomTom, you can also use TomTom's arrow, and it goes to the step's location.
- A new step updates the macro by itself, and a name whose objective is done drops out. The box header and `/dqt list` say "(RestedXP)".
- The focus you change last wins. RestedXP setting the game's focus to a quest of its own steps does not count.
- RestedXP is a separate product. DQT does not install it, and the setting is greyed out without it.
- Experimental, to be used with caution: DQT reads RestedXP's own data, not a public API, so a RestedXP update can stop it. DQT then follows your quest focus, and the macro keeps working.

### What it does when it finds one
- Goes back to your last target if what it found is dead, and marks a mob with a skull or an NPC with a green triangle (both can be changed or turned off).
- Optionally starts attacking, or casts a spell you pick from your spellbook (harmful, 1 second or less), such as a low rank you tag mobs with.
- The macro never changes in combat: anything that changes then is written when combat ends.

### Quest Target Box
A small box shows your focused quest, what the macro looks for (with drop rates), the names left out of the macro, and your hit list. Add your target with the plus (Shift-click for the exact name; with no target, type a name), remove a name with its red X, and drag names to change their order; this works in combat too. Click a title to fold that part, or the button at the header's right to fold or open everything. Ctrl-drag the header to move it, or use `/dqt unlock`. The settings have its Style (Brown and gold, or Black and gold), Width, Max height, Text size, and Opacity, and "Start the quest targets folded" and "Start the hit list folded" for how it starts. "Show the Quest Target Box" turns it off.

### Per character
Each character has its own macro and its own hit list. Short of character macro slots? A setting uses one account-wide macro instead.

### With QuestTrail
QuestTrail's compass plans your route. DQT targets the step it points at: that objective's mobs, the turn-in NPC, or who gives the quest. It also targets the "on the way" objectives, the camps the route walks through, so you no longer add them to the hit list by hand.
- A new step updates the macro by itself. The box header and `/dqt list` say "(QuestTrail)".
- The focus you change last wins. QuestTrail setting the game's focus to its step's quest does not count.
- With TomTom, TomTom's arrow goes where QuestTrail's compass goes, and QuestTrail's compass keeps its plan.
- QuestTrail is a separate AddOn. DQT does not install it, and the setting is greyed out without it.
- Experimental, to be used with caution: DQT reads QuestTrail's own data, not a public API, so a QuestTrail update can stop it. DQT then follows your quest focus, and the macro keeps working.

### Works with Questie, TomTom, Zygor, RestedXP, and QuestTrail
All five are optional, and their settings are together under "Integrations (Experimental)". A setting whose AddOn is missing is greyed out. Use these with caution: they use the other AddOns' own code or data, not a public API.
- Follow Questie's tracker focus (on by default): DQT follows the quest you focus in the game's quest log or map, or in Questie's tracker, whichever you set last. Chat says when the focused quest changes. Without Questie it still targets kill objectives and your hit list.
- Follow Zygor's current step, Follow RestedXP's current step, and Follow QuestTrail's current step (on by default): see above.
- Keep Questie's and the game's focus in sync (off by default).
- Point TomTom at the focused quest (off by default; needs TomTom, with Questie, Zygor, RestedXP, or QuestTrail): on a Zygor, RestedXP, or QuestTrail step with a location, points the TomTom arrow there and moves on with the guide's next waypoint. Otherwise, with Questie, it points at the nearest of the mobs and NPCs the macro looks for, or at the turn-in once the quest is done.

### Dyre's Toolkit
The Quest Target Box needs Dyre's Toolkit; the CurseForge app installs it with DQT. Without it, the macro still works, and chat says once what to install. It gives all Dyre's AddOns one settings home, one way to move their frames, and a minimap menu.

### Commands
- `/dqt` opens the settings.
- `/dqt list` lists what the macro targets, most wanted first, and why.
- `/dqt add [name]`, `/dqt add_exact [name]`, `/dqt remove [name]`, `/dqt reset` (clears the hit list).
- Key bindings: add your target to the hit list, add it with its exact name, or remove it.
- `/dqt on`, `/dqt off`: turn updating the macro on or off.
- `/dqt unlock`, `/dqt lock`: move the Quest Target Box (all Dyre's AddOns' frames, as `/dyre unlock` does); `/dqt reset_box` puts it back.
- `/questtargeting` works the same, in case another AddOn uses `/dqt`.

### Talking to NPCs
A macro cannot interact with an NPC or click a quest object. Use the game's own Interact key (Options, Controls, Enable Interact Key).

### Compatibility
For World of Warcraft: Forever 1.60.1 (tested on build 70450). Also for Classic Era 1.15.9, which has no quest focus of its own, so DQT follows Questie's tracker focus there; without Questie, the macro and the box keep your hit list. If a client update removes an API it needs, it says so in chat and stays off.

WowUp users (2.24.0 or later): install from the repository URL; GitHub releases carry the Forever metadata WowUp needs.

Source, issues, and license (MIT): https://github.com/jbedworth/DyresQuestTargeting
```
