# Changelog

All notable changes to this project will be documented in this file.

## [1.6.1] - 2026-11-12

### Changed
- Picks up game-common 1.16.0: games for two readers (new Two readers
  category) and the shared Start / Join dialog.

## [1.6.0] - 2026-11-05

### Changed
- Difficulty levels now really differ, and no puzzle needs guessing.
  Before, digging only checked that the answer stayed unique: Easy and
  Medium never needed more than singles, while Hard often could only be
  finished by trial and error (7×7: 60% of puzzles, 6×6: 23%). Each
  puzzle is now graded by a human-style solver:
  - Easy: singles, and signs read at a glance (next to a placed digit, or
    "the smaller cell is never the largest digit"). About a third of the
    digits and more than half of the signs shown.
  - Medium: also needs a few harder steps: bounds carried along chains of
    signs ("a < b < c, so a is at most n-2"), or pairs/triples of
    candidates in a row or column. Fewer digits and signs.
  - Hard: very few digits (sometimes none), a third of the signs, and many
    more of those steps.
- Puzzles differ from 1.5.x for the same seed (today's Daily Challenge
  puzzle changes once after updating). Saved games still load.

### Fixed
- The notes button reads "Notes : actif / inactif" in French, as in the
  sudoku games, instead of "Notes : ON / OFF".

## [1.5.2] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.5.1] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.5.0] - 2026-11-04

### Changed
- Much faster 7×7 Hard puzzles: up to 0.7 s on a desktop (about 15 s on a
  Kobo) down to 0.04 s. The solution check keeps track of the digits used
  per row and column and bounds each cell by its chains of inequalities;
  same puzzles as before.
- Opening the game no longer builds a puzzle it then throws away, and New
  game builds one puzzle instead of two.
- A "Generating puzzle…" progress bar shows when a puzzle takes more than a
  moment. Needs game-common 1.12.0.

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

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
