# Dyre's Quest Targeting artwork

Publishing images for project pages and distribution listings (CurseForge
screenshots and the like). Keep this directory out of the runtime release
ZIP; the TOC uses a built-in client icon (Ability_Hunter_SniperShot).

## Logo

Original vector artwork: a gold targeting ring with a red aim point around a
glowing golden quest exclamation mark, on a rich dark-brown background. It
shares its frame and colors with the Mage Tools Forever, Warlock Tools
Forever, Weapon Sets Forever, Weapon Skills Forever, and Dyre's Shields Up
logos. The design has no font or external-image dependencies.

- `dyres-quest-targeting-logo.svg`: editable, resolution-independent source.
- `dyres-quest-targeting-logo.png`: 1024 x 1024 PNG master.
- `dyres-quest-targeting-logo-512.png`: 512 x 512 PNG for square project
  images.

The PNGs are rendered from the SVG with headless Chrome, for example:

```sh
chrome --headless=new --hide-scrollbars --window-size=1024,1024 --force-device-scale-factor=0.5 --screenshot=dyres-quest-targeting-logo-512.png dyres-quest-targeting-logo.svg
```

## Screenshots

In-game captures by the author on the Forever beta client, saved as PNG in
`screenshots/`. None are taken yet. Suggested shots:

- `screenshots/macro.png`: the "! Target (DQT)" macro on an action bar, and
  a skulled quest mob it found.
- `screenshots/list.png`: `/dqt list` in chat, with the droppers and their
  drop rates.
- `screenshots/focus-change.png`: the chat line when the focused quest
  changes.
- `screenshots/settings.png`: the settings page, with the Questie
  Synchronization (Experimental) section.

List each screenshot here once it is added. Retake a screenshot when the
feature it shows changes visibly.

This artwork is covered by the repository's MIT License. Copyright (c) 2026
John Bedworth. Include the applicable license notice with distributed copies.
