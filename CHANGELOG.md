# Changelog

Player-facing changes for each Dyre's Quest Targeting release, newest first. The
release builder puts the matching section at the top of each release's notes.

## 0.1.0-beta

- The character macro "! Quest Targets" follows your focused quest: it finds the nearest mob the quest still needs, skips dead ones, and marks it (skull for mobs, green triangle for NPCs).
- With QuestieDB installed, it also finds the mobs that drop the quest's items, and the NPC you turn the quest in to.
- Your hit list: `/dqt add` and `/dqt add_exact` add any mob (similar names or the exact name), saved per character; `/dqt remove` and `/dqt reset` take them off.
- Follows the quest you focus in the game's quest log or map, or in Questie's tracker (a setting), whichever you set last. Chat says when the focused quest changes and when a finished objective's mob leaves the macro.
- Settings: markers or none, and what to do on a mob: nothing, start attacking, or cast a spell you pick from your spellbook.
