# Changelog

All notable changes to this project will be documented in this file.

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
