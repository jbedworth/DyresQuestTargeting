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
| Logo | Not made yet. |
| Source | https://github.com/jbedworth/DyresQuestTargeting |
| Issues | https://github.com/jbedworth/DyresQuestTargeting/issues |

## Summary

A targeting macro, "! Quest Targets", that follows your focused quest in World of Warcraft: Forever: one key finds and marks the mobs and NPCs the quest needs.

## Description

Paste this with the description editor in Markdown mode. Pasted into the rich
text editor, the headings, bullets, and bold show as raw, escaped markdown.

Per-file changelogs need no manual text: each CI upload uses the version's
`CHANGELOG.md` section, through `release-notes.md`.

```markdown
**Dyre's Quest Targeting** keeps one character macro, **! Quest Targets**, up to date with the mobs and NPCs your focused quest needs. Put it on a bar and press it to find, target, and mark the nearest one.

### What it targets
- The mobs your focused quest still needs killed.
- With **QuestieDB** installed (it comes with Questie): the mobs that drop the quest's items, and the NPC you turn it in to once it is done.
- Your own hit list, for any mob: `/dqt add Goretusk` finds anything named like it; `/dqt add_exact Great Goretusk` only that name. With nothing typed, they add your target.

### What it does when it finds one
- Skips a dead one, and marks the mob with a skull or the NPC with a green triangle (both can be changed or turned off).
- Optionally starts attacking, or casts a spell you pick from your spellbook, such as a low rank you tag mobs with.

### Per character
Each character has its own macro and its own hit list.

### Questie optional
It follows the quest you focus in the game's quest log, or in Questie's tracker if you use Questie. Without Questie it still targets kill objectives and your hit list.

### Commands
- `/dqt` lists what the macro targets and why.
- `/dqt add [name]`, `/dqt add_exact [name]`, `/dqt remove [name]`, `/dqt reset`.
- `/dqt on`, `/dqt off`, `/dqt options`.
- `/questtargeting` works the same, in case another AddOn uses `/dqt`.

### Compatibility
Beta, for the Forever beta client 1.60.1. If a client update removes an API it needs, it says so in chat and stays off.

WowUp users (2.24.0 or later): install from the repository URL; GitHub releases carry the Forever metadata WowUp needs.

Source, issues, and license (MIT): https://github.com/jbedworth/DyresQuestTargeting
```
