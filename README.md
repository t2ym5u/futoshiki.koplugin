# futoshiki.koplugin

A Futoshiki plugin for [KOReader](https://github.com/koreader/koreader).

## Concept

Futoshiki (Japanese: "not equal") is a logic puzzle played on a square grid.
Fill every cell with a digit so that:

1. Each digit appears exactly once in every row and column (like Sudoku).
2. All inequality constraints (< >) shown between adjacent cells are satisfied.

## Planned Features

- **Multiple grid sizes** — 4×4, 5×5, 6×6, 7×7
- **Three difficulty levels** — Easy, Medium, Hard (more constraints shown on Easy)
- **Inequality display** — arrows rendered between constrained cells
- **Note mode** — pencil in candidate digits
- **Constraint highlighting** — tap a cell to highlight all its active inequalities
- **Check** — highlights cells that violate a row, column or inequality constraint
- **Reveal solution** — shows the full solution
- **Undo** — step back through your moves
- **Auto-save** — game state saved and restored on next launch

## Controls

| Action | How |
|--------|-----|
| Select a cell | Tap it |
| Enter a digit | Tap the digit button |
| Erase a cell | Tap **Erase** |
| Toggle note mode | Tap **Note: Off / On** |
| Undo last move | Tap **Undo** |
| Check progress | Tap **Check** |
| New game | Tap **New game** |
| Change grid size | Tap **Grid** |
| Change difficulty | Tap **Diff** |

## Why e-ink friendly?

Inequality arrows are static glyphs that render sharply at any e-ink resolution.
The puzzle requires no animation and has discrete, tap-based interactions.

## License

GPL-3.0
