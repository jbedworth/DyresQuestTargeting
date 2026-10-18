# CurseForge listing

Copy-ready text for the CurseForge project form. Keep it aligned with README.md
and the tested client; do not advertise clients or versions that have not been
tested.

## Project fields

| Field | Value |
| --- | --- |
| Name | Dyre's Quest Targeting |
| Class | Addons |
| Main category | Quests. Keep it identical to the TOC `## Category`, which groups the AddOn in the in-game AddOn list. |
| Additional categories | None yet (CurseForge allows up to 4; unrelated ones can send the project back for changes). |
| Author shown | Dyre, set through the CurseForge account's username |
| License | MIT License |
| Logo | artwork/dyres-quest-targeting-logo.png (1024 x 1024); artwork/dyres-quest-targeting-logo-512.png if a smaller square is wanted |
| Relations | Questie, optional dependency (CurseForge project 334372). CI uploads set it; add it by hand on any file uploaded through the website. QuestieDB has no CurseForge project. |
| Screenshots | artwork/screenshots/ (none taken yet; see artwork/README.md) |
| Source | https://github.com/jbedworth/DyresQuestTargeting |
| Issues | https://github.com/jbedworth/DyresQuestTargeting/issues |

## Summary

A targeting macro, "! Target (DQT)", that follows your focused quest in World of Warcraft: Forever: one key finds and marks the mobs and NPCs the quest needs.

## Description

Paste this with the description editor in Markdown mode. Pasted into the rich
text editor, the headings, bullets, and bold show as raw, escaped markdown.

Per-file changelogs need no manual text: each CI upload uses the version's
`CHANGELOG.md` section, through `release-notes.md`.

```markdown
**Dyre's Quest Targeting** keeps one macro, **! Target (DQT)**, up to date with the mobs and NPCs your focused quest needs. Put it on a bar and press it to find, target, and mark the nearest one.

### What it targets
- The mobs your focused quest still needs killed. Finished objectives drop out by themselves, and chat says so.
- With **QuestieDB** installed (it comes with Questie): the mobs that drop the quest's items, and the NPC you turn it in to once it is done. With Questie, it picks the best droppers by Questie's drop rates.
- A Questie objective focus targets only that objective.
- Your own hit list, for any mob: `/dqt add Goretusk` finds anything named like it; `/dqt add_exact Great Goretusk` only that name. With nothing typed, they add your target. Your hit list comes first.

### What it does when it finds one
- Goes back to your last target if what it found is dead, and marks a mob with a skull or an NPC with a green triangle (both can be changed or turned off).
- Optionally starts attacking, or casts a spell you pick from your spellbook (harmful, 1 second or less), such as a low rank you tag mobs with.
- It never changes in combat: anything that changes then is written when combat ends.

### Per character
Each character has its own macro and its own hit list. Short of character macro slots? A setting uses one account-wide macro instead.

### Questie optional
It follows the quest you focus in the game's quest log or map, or in Questie's tracker if you use Questie, whichever you set last. Chat says when the focused quest changes. Without Questie it still targets kill objectives and your hit list.

With Questie, two optional settings, **experimental and to be used with caution**: keep Questie's and the game's quest focus in sync, and point the TomTom arrow at the nearest of the mobs the macro looks for.

### Commands
- `/dqt` opens the settings; `/dqt list` lists what the macro targets, most wanted first, and why.
- `/dqt add [name]`, `/dqt add_exact [name]`, `/dqt remove [name]`, `/dqt reset`.
- `/dqt on`, `/dqt off`: turn updating the macro on or off.
- `/questtargeting` works the same, in case another AddOn uses `/dqt`.

### Talking to NPCs
A macro cannot interact with an NPC or click a quest object. Use the game's own Interact key (Options, Controls, Enable Interact Key).

### Compatibility
Beta, for the Forever beta client 1.60.1. If a client update removes an API it needs, it says so in chat and stays off.

WowUp users (2.24.0 or later): install from the repository URL; GitHub releases carry the Forever metadata WowUp needs.

Source, issues, and license (MIT): https://github.com/jbedworth/DyresQuestTargeting
```
