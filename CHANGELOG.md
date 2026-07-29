# Changelog

All notable changes to this project will be documented in this file.

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
