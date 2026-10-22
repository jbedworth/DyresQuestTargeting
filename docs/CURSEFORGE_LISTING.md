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
| Relations | Dyre's Toolkit (slug `dyres-toolkit`), required dependency; Questie (CurseForge project 334372) and TomTom (project 18808), optional dependencies. CI uploads set all three; add them by hand on any file uploaded through the website. QuestieDB has no CurseForge project. |
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
| artwork/screenshots/settings-macro-and-markers.png | Settings: the macro | Keep the macro up to date, follow Questie's focus, pick the raid markers, and choose what to do on a mob. |
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
- With QuestieDB installed (it comes with Questie): the mobs that drop the quest's items, and the NPC you turn it in to once it is done. With Questie, DQT picks the best droppers by Questie's drop rates.
- A Questie objective focus targets only that objective.
- Your own hit list, for any mob: `/dqt add Goretusk` finds anything named like it; `/dqt add_exact Great Goretusk` only that name. With nothing typed, they add your target. Your hit list is prioritized over the quest list.

### What it does when it finds one
- Goes back to your last target if what it found is dead, and marks a mob with a skull or an NPC with a green triangle (both can be changed or turned off).
- Optionally starts attacking, or casts a spell you pick from your spellbook (harmful, 1 second or less), such as a low rank you tag mobs with.
- The macro never changes in combat: anything that changes then is written when combat ends.

### Quest Target Box
A small box shows your focused quest, what the macro looks for (with drop rates), the names left out of the macro, and your hit list. Add your target with the plus (Shift-click for the exact name), remove a name with its red X, and drag names to change their order; this works in combat too. Click a title to fold that part, or the button at the header's right to fold or open everything. Ctrl-drag the header to move it, or use `/dqt unlock`. The settings have its Style (Brown and gold, or Black and gold), Width, Max height, Text size, and Opacity, and "Start the quest targets folded" and "Start the hit list folded" for how it starts. "Show the Quest Target Box" turns it off.

### Per character
Each character has its own macro and its own hit list. Short of character macro slots? A setting uses one account-wide macro instead.

### Questie and TomTom optional
It follows the quest you focus in the game's quest log or map, or in Questie's tracker if you use Questie, whichever you set last. Chat says when the focused quest changes. Without Questie it still targets kill objectives and your hit list, and the settings that need Questie are greyed out.

With Questie, two optional settings, experimental and to be used with caution: keep Questie's and the game's quest focus in sync, and (with TomTom) point the TomTom arrow at the nearest of the mobs the macro looks for.

### Dyre's Toolkit
DQT needs Dyre's Toolkit; the CurseForge app installs it with DQT. It gives all Dyre's AddOns one settings home, one way to move their frames, and a minimap menu.

### Commands
- `/dqt` opens the settings.
- `/dqt list` lists what the macro targets, most wanted first, and why.
- `/dqt add [name]`, `/dqt add_exact [name]`, `/dqt remove [name]`, `/dqt reset` (clears the hit list).
- `/dqt on`, `/dqt off`: turn updating the macro on or off.
- `/dqt unlock`, `/dqt lock`: move the Quest Target Box (all Dyre's AddOns' frames, as `/dyre unlock` does); `/dqt reset_box` puts it back.
- `/questtargeting` works the same, in case another AddOn uses `/dqt`.

### Talking to NPCs
A macro cannot interact with an NPC or click a quest object. Use the game's own Interact key (Options, Controls, Enable Interact Key).

### Compatibility
For World of Warcraft: Forever 1.60.1 (tested on build 70450). If a client update removes an API it needs, it says so in chat and stays off.

WowUp users (2.24.0 or later): install from the repository URL; GitHub releases carry the Forever metadata WowUp needs.

Source, issues, and license (MIT): https://github.com/jbedworth/DyresQuestTargeting
```
