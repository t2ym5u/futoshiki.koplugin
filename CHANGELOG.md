# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] - 2026-10-30

### Changed
- Redesigned play screen: the digits form one even row of keys above a
  full-width Note/Erase/Check/Hint/Undo bar (two rows in landscape, where five
  labels do not fit), and the board fills the room they leave, framed by its
  own thicker outer border.
- Inequality signs are drawn as chevrons pointing at the smaller cell. The
  vertical ones used to be "^" and "v" glyphs, which neither looked like "<" /
  ">" nor sat at the same height. Digits are a little smaller to leave the
  signs room.
- The status line reads "5×5 · Easy · Empty: 12" and wraps in landscape; the
  note mode is shown on the Note button only.
- Title-bar menu: "Size: 5×5", "Difficulty: Easy" and "Show solution" / "Hide
  solution" instead of "Grid:", "Diff:" and "Show result" / "Hide result".
- Once the puzzle is solved, the action bar shows "New game" in place of its
  buttons (not while the solution is only shown, since it can be hidden
  again).

### Fixed
- Tapping Undo crashed ("attempt to call method 'undo'"): the board's undo
  stack field shadowed its `undo()` method.
- The closing right and bottom grid lines were drawn past the board's edge.
- Digits overflowed their cells: game-common's font fit accepted every size,
  then DPI scaled it up again. They now fit their cell on every screen.
- An applied Hint no longer wipes the saved game (game-common saved it as
  nil). When a hint fills the last cell, the status now shows the win message.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps, not one: the first says which cell is about to
  give, the second acts on it -- a player who is told where to look usually
  finds the rest themselves, and only pays for the full reveal if they want
  it. A cell that contradicts the solution is always reported before a fresh
  one is revealed, and on a mistake the hint empties the cell rather than
  solving it.

## [1.1.8] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification — clues were chosen
  by shuffling all cell positions and revealing a flat top fraction of
  them with no check that the remaining givens and inequality
  constraints still forced a single Latin-square completion, degrading
  to 0% unique puzzles at larger sizes and harder difficulties.
  Generation now digs clues one at a time from a fully-revealed grid
  and keeps a cell hidden only after proving with a bounded MRV
  backtracking search that exactly one solution remains, guaranteeing
  every puzzle has a unique solution.
