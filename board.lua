local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")
local Hint      = require("hint")
local bit       = require("bit")

local emptyGrid      = grid_utils.emptyGrid
local emptyBoolGrid  = grid_utils.emptyBoolGrid
local copyGrid       = grid_utils.copyGrid
local shuffle        = grid_utils.shuffle

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"


-- ---------------------------------------------------------------------------
-- FutoshikiBoard
-- ---------------------------------------------------------------------------

local FutoshikiBoard = {}
FutoshikiBoard.__index = FutoshikiBoard

function FutoshikiBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local obj = {
        n               = n,
        difficulty      = opts.difficulty or DEFAULT_DIFFICULTY,
        solution        = emptyGrid(n),
        given           = emptyBoolGrid(n),
        puzzle          = emptyGrid(n),
        user            = emptyGrid(n),
        notes           = {},
        constraints     = {},
        wrong_marks     = emptyBoolGrid(n),
        reveal_solution = false,
        undo            = UndoStack:new{ max_size = 200 },
    }
    -- notes[r][c] is a table keyed 1..n → bool
    for r = 1, n do
        obj.notes[r] = {}
        for c = 1, n do
            obj.notes[r][c] = {}
        end
    end
    setmetatable(obj, self)
    -- opts.empty: the caller loads a save or generates right after (with
    -- the progress bar), so skip the throwaway puzzle.
    if not opts.empty then obj:generate(obj.difficulty) end
    return obj
end

-- ---------------------------------------------------------------------------
-- Latin-square generation
-- ---------------------------------------------------------------------------

local function makeBaseLatin(n)
    local g = {}
    for r = 1, n do
        g[r] = {}
        for c = 1, n do
            g[r][c] = (r + c - 2) % n + 1
        end
    end
    return g
end

local function permuteLatin(g, n)
    -- Shuffle row order
    local row_order = {}
    for i = 1, n do row_order[i] = i end
    shuffle(row_order)
    -- Shuffle column order
    local col_order = {}
    for i = 1, n do col_order[i] = i end
    shuffle(col_order)
    -- Build permuted digit map so values stay a valid Latin square
    local digit_map = {}
    do
        local digits = {}
        for i = 1, n do digits[i] = i end
        shuffle(digits)
        for i = 1, n do digit_map[i] = digits[i] end
    end

    local out = {}
    for r = 1, n do
        out[r] = {}
        for c = 1, n do
            out[r][c] = digit_map[g[row_order[r]][col_order[c]]]
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- generate
-- ---------------------------------------------------------------------------

-- Counts solutions (up to `limit`) of the Latin-square+inequality instance
-- given the current given/constraint state, using MRV cell ordering.
-- Returns (solutions_found, exhausted); exhausted=true means node_budget
-- was hit before the search concluded, so the count isn't proof. Mirrors
-- sudokukiller.koplugin/board.lua's countCageSolutions.
--
-- 1.5.0: same counts (so the same puzzles: no count ever hit the node
-- budget, before or after, over 150 7x7 Hard seeds), but the digits used
-- per row and column are kept up to date as cells are filled instead of
-- being rebuilt as fresh tables for every candidate list, candidates are
-- only counted while looking for the most constrained cell, and chains of
-- inequalities bound each cell's values up front. 7x7 Hard took up to
-- ~0.7 s on a desktop for some seeds.
-- Since 1.6.0 the generator digs with logicSolve (below), which proves
-- uniqueness by itself; this counter stays as an independent check for
-- the specs.

local function countSolutions(puzzle, given, constraints, n, limit, node_budget)
    local grid = {}
    local row_has, col_has = {}, {}
    for i = 1, n do
        row_has[i], col_has[i] = {}, {}
        for v = 1, n do row_has[i][v], col_has[i][v] = false, false end
    end
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do
            local v = given[r][c] and puzzle[r][c] or 0
            grid[r][c] = v
            if v ~= 0 then row_has[r][v], col_has[c][v] = true, true end
        end
    end

    -- cons_r/cons_c/cons_less[r][c]: the cells (r, c) is compared with, and
    -- whether (r, c) must be the smaller one.
    local cons_r, cons_c, cons_less = {}, {}, {}
    for r = 1, n do
        cons_r[r], cons_c[r], cons_less[r] = {}, {}, {}
        for c = 1, n do cons_r[r][c], cons_c[r][c], cons_less[r][c] = {}, {}, {} end
    end
    local function addCons(r, c, or_, oc, less)
        local lr = cons_r[r][c]
        lr[#lr + 1] = or_
        cons_c[r][c][#lr] = oc
        cons_less[r][c][#lr] = less
    end
    for _, con in ipairs(constraints) do
        addCons(con.r1, con.c1, con.r2, con.c2, con.less)
        addCons(con.r2, con.c2, con.r1, con.c1, not con.less)
    end

    -- Static bounds from chains of inequalities: a cell smaller than
    -- another is at most that one's upper bound - 1, and so on along the
    -- chain (relaxed to a fixed point; the chains come from a real
    -- solution, so they never loop). Only rules out values no solution
    -- can use, so counts are unchanged.
    local lo, hi = {}, {}
    for r = 1, n do
        lo[r], hi[r] = {}, {}
        for c = 1, n do lo[r][c], hi[r][c] = 1, n end
    end
    for _ = 1, n do
        local moved = false
        for r = 1, n do
            for c = 1, n do
                local lr, lc, ll = cons_r[r][c], cons_c[r][c], cons_less[r][c]
                for i = 1, #lr do
                    local orr, occ = lr[i], lc[i]
                    if ll[i] then
                        -- (r, c) < other
                        if hi[r][c] > hi[orr][occ] - 1 then hi[r][c] = hi[orr][occ] - 1; moved = true end
                    elseif lo[r][c] < lo[orr][occ] + 1 then
                        lo[r][c] = lo[orr][occ] + 1
                        moved = true
                    end
                end
            end
        end
        if not moved then break end
    end

    local solutions, nodes, exhausted = 0, 0, false

    local function allowed(r, c, v)
        if v < lo[r][c] or v > hi[r][c] then return false end
        if row_has[r][v] or col_has[c][v] then return false end
        local lr, lc, ll = cons_r[r][c], cons_c[r][c], cons_less[r][c]
        for i = 1, #lr do
            local ov = grid[lr[i]][lc[i]]
            if ov ~= 0 then
                if ll[i] then
                    if not (v < ov) then return false end
                elseif not (v > ov) then
                    return false
                end
            end
        end
        return true
    end

    local function countCandidates(r, c)
        local k = 0
        for v = 1, n do
            if allowed(r, c, v) then k = k + 1 end
        end
        return k
    end

    local function search(depth, empties)
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if depth > #empties then solutions = solutions + 1; return end
        local best_idx, best_len = nil, n + 1
        for i = 1, #empties do
            local cell = empties[i]
            if grid[cell.r][cell.c] == 0 then
                local k = countCandidates(cell.r, cell.c)
                if k < best_len then
                    best_len, best_idx = k, i
                    if best_len <= 1 then break end
                end
            end
        end
        if best_idx == nil then solutions = solutions + 1; return end
        if best_len == 0 then return end
        local cell = empties[best_idx]
        local r, c = cell.r, cell.c
        local cands = {}
        for v = 1, n do
            if allowed(r, c, v) then cands[#cands + 1] = v end
        end
        for _, v in ipairs(cands) do
            grid[r][c] = v
            row_has[r][v], col_has[c][v] = true, true
            search(depth + 1, empties)
            grid[r][c] = 0
            row_has[r][v], col_has[c][v] = false, false
            if solutions >= limit or exhausted then return end
        end
    end

    local empties = {}
    for r = 1, n do for c = 1, n do if grid[r][c] == 0 then empties[#empties + 1] = { r = r, c = c } end end end
    search(1, empties)
    return solutions, exhausted
end

-- ---------------------------------------------------------------------------
-- Human-style solver (1.6.0), used to grade and dig puzzles
-- ---------------------------------------------------------------------------
--
-- Keeps, for every cell, the set of digits still possible (a bitmask:
-- bit v-1 for digit v), and narrows them down without trial and error:
--   tier 1  what a beginner does:
--           - a placed digit is crossed out of its row and column;
--           - a cell with one digit left takes it (naked single);
--           - a digit with one place left in a row or column goes there
--             (hidden single);
--           - a sign next to a placed digit: the other cell is below
--             (or above) it; next to an open cell, the smaller cell is
--             never n and the larger never 1.
--   tier 2  - a sign against the other cell's remaining candidates: the
--             smaller cell stays below the larger one's highest candidate,
--             and the reverse, so bounds travel along chains of signs
--             ("a < b < c, so a is at most n-2");
--           - candidate subsets within a row or column: two cells sharing
--           the same two digits (or three cells, three digits) take them
--           away from the rest of the line (naked pair / triple), and two
--           digits that only fit in the same two cells clear those cells
--           of everything else (hidden pair).
-- Tier 2 is only tried when tier 1 is stuck, and each tier-2 step counts:
-- that count tells the levels apart. A puzzle it finishes has exactly one
-- solution, since every step only follows from the rules.
local POP, LOW, HIGH = {}, {}, {}
for m = 0, 127 do
    local k, lo, hi = 0, nil, nil
    for v = 1, 7 do
        if bit.band(m, bit.lshift(1, v - 1)) ~= 0 then
            k = k + 1
            lo = lo or v
            hi = v
        end
    end
    POP[m], LOW[m], HIGH[m] = k, lo or 0, hi or 0
end

-- puzzle: grid of digits (0 = empty); constraints: list of
-- {r1, c1, r2, c2, less}. Returns solved, t2_steps, values (grid, 0 where
-- still open).
local function logicSolve(puzzle, constraints, n, max_tier)
    local full = bit.lshift(1, n) - 1
    local N = n * n
    local C = {}
    for r = 1, n do
        for c = 1, n do
            local v = puzzle[r][c]
            C[(r - 1) * n + c] = (v and v > 0) and bit.lshift(1, v - 1) or full
        end
    end
    local units = {}
    for k = 1, n do
        local row, col = {}, {}
        for i = 1, n do
            row[i] = (k - 1) * n + i
            col[i] = (i - 1) * n + k
        end
        units[#units + 1] = row
        units[#units + 1] = col
    end
    -- Inequalities as (smaller cell, larger cell).
    local lt_a, lt_b = {}, {}
    for i, con in ipairs(constraints) do
        local a = (con.r1 - 1) * n + con.c1
        local b = (con.r2 - 1) * n + con.c2
        if con.less then lt_a[i], lt_b[i] = a, b else lt_a[i], lt_b[i] = b, a end
    end
    local done = {}   -- singles already crossed out of their lines
    local bad = false

    local function setMask(i, m)
        if m == 0 then bad = true end
        C[i] = m
    end

    local function tier1()
        local prog = false
        -- Cross out placed digits.
        for i = 1, N do
            local m = C[i]
            if not done[i] and POP[m] == 1 then
                done[i] = true
                prog = true
                local r = (i - 1 - (i - 1) % n) / n + 1
                local c = (i - 1) % n + 1
                local keep = bit.bnot(m)
                for k = 1, n do
                    local j = (r - 1) * n + k
                    if j ~= i then setMask(j, bit.band(C[j], keep)) end
                    j = (k - 1) * n + c
                    if j ~= i then setMask(j, bit.band(C[j], keep)) end
                end
            end
        end
        -- Signs, read at a glance: below a placed digit, or at least
        -- "the smaller cell is never n, the larger never 1".
        for k = 1, #lt_a do
            local a, b = lt_a[k], lt_b[k]
            local ma, mb = C[a], C[b]
            local hb = POP[mb] == 1 and HIGH[mb] or n
            local la = POP[ma] == 1 and LOW[ma] or 1
            local na = bit.band(ma, bit.lshift(1, hb - 1) - 1)
            local nb = bit.band(mb, bit.bnot(bit.lshift(1, la) - 1))
            if na ~= ma then setMask(a, na); prog = true end
            if nb ~= mb then setMask(b, nb); prog = true end
        end
        if bad or prog then return prog end
        -- Hidden singles.
        for u = 1, #units do
            local U = units[u]
            for v = 1, n do
                local bm = bit.lshift(1, v - 1)
                local cnt, last = 0, nil
                for k = 1, n do
                    if bit.band(C[U[k]], bm) ~= 0 then cnt = cnt + 1; last = U[k] end
                end
                if cnt == 0 then bad = true; return false end
                if cnt == 1 and C[last] ~= bm then C[last] = bm; return true end
            end
        end
        return false
    end

    local function tier2()
        -- Signs against the other cell's remaining candidates: the smaller
        -- cell stays below the larger one's highest candidate (and the
        -- reverse), which carries bounds along chains of signs.
        for k = 1, #lt_a do
            local a, b = lt_a[k], lt_b[k]
            local ma, mb = C[a], C[b]
            local na = bit.band(ma, bit.lshift(1, HIGH[mb] - 1) - 1)
            local nb = bit.band(mb, bit.bnot(bit.lshift(1, LOW[ma]) - 1))
            if na ~= ma or nb ~= mb then
                setMask(a, na); setMask(b, nb)
                return true
            end
        end
        for u = 1, #units do
            local U = units[u]
            local open = {}
            for k = 1, n do if POP[C[U[k]]] > 1 then open[#open + 1] = U[k] end end
            local no = #open
            -- Naked pairs and triples.
            for x = 1, no do
                for y = x + 1, no do
                    local m2 = bit.bor(C[open[x]], C[open[y]])
                    if POP[m2] == 2 then
                        local ch = false
                        for z = 1, no do
                            local j = open[z]
                            if z ~= x and z ~= y and bit.band(C[j], m2) ~= 0 then
                                setMask(j, bit.band(C[j], bit.bnot(m2))); ch = true
                            end
                        end
                        if ch then return true end
                    end
                    for w = y + 1, no do
                        local m3 = bit.bor(m2, C[open[w]])
                        if POP[m3] == 3 then
                            local ch = false
                            for z = 1, no do
                                local j = open[z]
                                if z ~= x and z ~= y and z ~= w and bit.band(C[j], m3) ~= 0 then
                                    setMask(j, bit.band(C[j], bit.bnot(m3))); ch = true
                                end
                            end
                            if ch then return true end
                        end
                    end
                end
            end
            -- Hidden pairs.
            for v = 1, n do
                for w = v + 1, n do
                    local bm = bit.bor(bit.lshift(1, v - 1), bit.lshift(1, w - 1))
                    local hits, h1, h2 = 0, nil, nil
                    local both = true
                    for k = 1, n do
                        local m = C[U[k]]
                        if bit.band(m, bm) ~= 0 then
                            hits = hits + 1
                            if hits == 1 then h1 = U[k] else h2 = U[k] end
                            if bit.band(m, bm) ~= bm then both = false end
                        end
                    end
                    if hits == 2 and both and (C[h1] ~= bm or C[h2] ~= bm) then
                        C[h1], C[h2] = bm, bm
                        return true
                    end
                end
            end
        end
        return false
    end

    local t2 = 0
    while not bad do
        if not tier1() then
            if bad then break end
            local solved = true
            for i = 1, N do if POP[C[i]] ~= 1 then solved = false; break end end
            if solved then break end
            if max_tier >= 2 and tier2() then
                t2 = t2 + 1
            else
                break
            end
        end
    end
    local values, solved = {}, not bad
    for r = 1, n do
        values[r] = {}
        for c = 1, n do
            local m = C[(r - 1) * n + c]
            if POP[m] == 1 then values[r][c] = LOW[m] else values[r][c] = 0; solved = false end
        end
    end
    return solved, t2, values
end
FutoshikiBoard._logicSolve = logicSolve

-- What each level asks for (1.6.0). Before, digging only checked that the
-- answer stayed unique, so Easy and Medium never needed more than singles
-- and Hard often needed trial and error (7x7: 60% of puzzles).
--   ineq       fraction of neighbouring pairs shown as a sign
--   tier       the hardest reasoning the puzzle may need (see logicSolve)
--   min_given  never show fewer digits than this fraction of the grid
--   min_t2/max_t2  how many tier-2 steps the solution needs
-- Easy: singles and signs read at a glance. Medium: a few chain or subset
-- steps. Hard: fewer digits and signs, many more of them. Never trial and
-- error.
local LEVELS = {
    easy   = function(n) return { ineq = 0.55, tier = 1, min_given = 0.35, min_t2 = 0, max_t2 = 0 } end,
    medium = function(n) return { ineq = 0.45, tier = 2, min_given = 0.20, min_t2 = 1, max_t2 = n - 1 } end,
    hard   = function(n) return { ineq = 0.33, tier = 2, min_given = 0.0, min_t2 = n - 1, max_t2 = math.huge } end,
}
FutoshikiBoard.LEVELS = LEVELS
-- Candidates tried per puzzle, by size: small grids are cheap to dig but
-- miss the tier-2 window more often.
FutoshikiBoard.ATTEMPTS = { [4] = 40, [5] = 16, [6] = 12, [7] = 8 }

-- One candidate puzzle: a fresh Latin square, a random share of its signs,
-- then digits hidden in a random order, each one only if the solver at the
-- level's tier still finishes the grid. Returns solution, puzzle, given,
-- constraints, t2.
local function makeCandidate(n, level, on_progress, base, span)
    local sol = permuteLatin(makeBaseLatin(n), n)
    local all_pairs = {}
    for r = 1, n do
        for c = 1, n do
            if c < n then
                all_pairs[#all_pairs + 1] = { r1 = r, c1 = c, r2 = r, c2 = c + 1, less = sol[r][c] < sol[r][c + 1] }
            end
            if r < n then
                all_pairs[#all_pairs + 1] = { r1 = r, c1 = c, r2 = r + 1, c2 = c, less = sol[r][c] < sol[r + 1][c] }
            end
        end
    end
    shuffle(all_pairs)
    local constraints = {}
    for i = 1, math.max(1, math.floor(#all_pairs * level.ineq)) do constraints[i] = all_pairs[i] end

    local given, puzzle = emptyBoolGrid(n), emptyGrid(n)
    for r = 1, n do
        for c = 1, n do given[r][c] = true; puzzle[r][c] = sol[r][c] end
    end
    local positions = {}
    for r = 1, n do
        for c = 1, n do positions[#positions + 1] = { r = r, c = c } end
    end
    shuffle(positions)
    local total = n * n
    local floor_given = math.ceil(total * level.min_given)
    local shown = total
    for i, p in ipairs(positions) do
        if shown <= floor_given then break end
        if on_progress then on_progress(base + span * i / total) end
        local r, c = p.r, p.c
        puzzle[r][c] = 0
        if logicSolve(puzzle, constraints, n, level.tier) then
            given[r][c] = false
            shown = shown - 1
        else
            puzzle[r][c] = sol[r][c]
        end
    end
    local _, t2 = logicSolve(puzzle, constraints, n, 2)
    return sol, puzzle, given, constraints, t2
end

-- on_progress (optional): called with a 0..1 fraction while digging.
function FutoshikiBoard:generate(difficulty, on_progress)
    self.difficulty     = difficulty or self.difficulty
    local n             = self.n
    self.reveal_solution = false
    self.undo:clear()
    local level = (LEVELS[self.difficulty] or LEVELS.medium)(n)

    -- Up to ATTEMPTS candidates until one needs a number of tier-2 steps
    -- in the level's range; otherwise the closest one. Every candidate is
    -- finished by logicSolve without trial, so any of them is a valid,
    -- unique puzzle. Bounded by attempt counts only: same seed, same
    -- puzzle on every device.
    local attempts = FutoshikiBoard.ATTEMPTS[n] or 8
    local best, best_miss
    for attempt = 1, attempts do
        local sol, puzzle, given, constraints, t2 =
            makeCandidate(n, level, on_progress, (attempt - 1) / attempts, 1 / attempts)
        local miss = 0
        if t2 < level.min_t2 then miss = level.min_t2 - t2
        elseif t2 > level.max_t2 then miss = t2 - level.max_t2 end
        if not best or miss < best_miss then
            best = { solution = sol, puzzle = puzzle, given = given,
                     constraints = constraints, t2 = t2, attempt = attempt }
            best_miss = miss
        end
        if miss == 0 then break end
    end
    self.solution    = best.solution
    self.puzzle      = best.puzzle
    self.given       = best.given
    self.constraints = best.constraints
    -- How the kept puzzle graded (not saved; read by the specs).
    self.grade = { t2 = best.t2, attempt = best.attempt }

    -- Reset user state
    self.user = emptyGrid(n)
    self.wrong_marks = emptyBoolGrid(n)
    self.notes = {}
    for r = 1, n do
        self.notes[r] = {}
        for c = 1, n do
            self.notes[r][c] = {}
        end
    end
    if on_progress then on_progress(1) end
end

-- ---------------------------------------------------------------------------
-- Cell access
-- ---------------------------------------------------------------------------

function FutoshikiBoard:isGiven(r, c)
    return self.given[r] and self.given[r][c] == true
end

function FutoshikiBoard:getDisplayValue(r, c)
    if self.reveal_solution then
        return self.solution[r][c]
    end
    if self:isGiven(r, c) then
        return self.puzzle[r][c]
    end
    return self.user[r][c]
end

-- ---------------------------------------------------------------------------
-- Editing
-- ---------------------------------------------------------------------------

local function _cloneNotes(notes_cell)
    local out = {}
    for k, v in pairs(notes_cell) do out[k] = v end
    return out
end

function FutoshikiBoard:setValue(r, c, v)
    if self:isGiven(r, c) then
        return false, "given"
    end
    if self.reveal_solution then
        return false, "solution_shown"
    end
    local prev_val   = self.user[r][c]
    local prev_notes = _cloneNotes(self.notes[r][c])
    self.undo:push{ r = r, c = c, prev_value = prev_val, prev_notes = prev_notes }
    self.user[r][c]  = v
    -- Clear notes for this cell when a value is placed
    self.notes[r][c] = {}
    self.wrong_marks[r][c] = false
    return true
end

function FutoshikiBoard:clearCell(r, c)
    if self:isGiven(r, c) then
        return false, "given"
    end
    if self.reveal_solution then
        return false, "solution_shown"
    end
    local prev_val   = self.user[r][c]
    local prev_notes = _cloneNotes(self.notes[r][c])
    self.undo:push{ r = r, c = c, prev_value = prev_val, prev_notes = prev_notes }
    self.user[r][c]  = 0
    self.notes[r][c] = {}
    self.wrong_marks[r][c] = false
    return true
end

function FutoshikiBoard:toggleNote(r, c, d)
    if self:isGiven(r, c) then
        return false, "given"
    end
    if self.reveal_solution then
        return false, "solution_shown"
    end
    -- Notes are only useful on empty cells, but allow them anyway
    local prev_notes = _cloneNotes(self.notes[r][c])
    self.undo:push{ r = r, c = c, prev_notes = prev_notes }
    self.notes[r][c][d] = not self.notes[r][c][d] or nil
    return true
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

function FutoshikiBoard:canUndo()
    return self.undo:canUndo()
end

function FutoshikiBoard:undo()
    local entry = self.undo:pop()
    if not entry then
        return false, UndoStack.NOTHING_TO_UNDO
    end
    local r, c = entry.r, entry.c
    if entry.prev_value ~= nil then
        self.user[r][c] = entry.prev_value
    end
    if entry.prev_notes then
        self.notes[r][c] = _cloneNotes(entry.prev_notes)
    end
    self.wrong_marks[r][c] = false
    return true
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

function FutoshikiBoard:checkConflicts()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local v = self:getDisplayValue(r, c)
            if v ~= 0 and self.solution[r][c] and v ~= self.solution[r][c] then
                self.wrong_marks[r][c] = true
            else
                self.wrong_marks[r][c] = false
            end
        end
    end
end

function FutoshikiBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local v = self:getDisplayValue(r, c)
            if v == 0 or v ~= self.solution[r][c] then
                return false
            end
        end
    end
    return true
end

function FutoshikiBoard:getRemainingCells()
    local n     = self.n
    local count = 0
    for r = 1, n do
        for c = 1, n do
            if self:getDisplayValue(r, c) == 0 then
                count = count + 1
            end
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Solution reveal
-- ---------------------------------------------------------------------------

function FutoshikiBoard:toggleSolution()
    self.reveal_solution = not self.reveal_solution
end

function FutoshikiBoard:isShowingSolution()
    return self.reveal_solution
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

Hint.install(FutoshikiBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    isGiven     = function(b, r, c) return b:isGiven(r, c) end,
    setCell     = function(b, r, c, v) return b:setValue(r, c, v) end,
    clearCell   = function(b, r, c) return b:clearCell(r, c) end,
})

function FutoshikiBoard:serialize()
    local n = self.n
    -- Serialise notes as plain nested tables (no boolean keys, just truthy entries)
    local notes_out = {}
    for r = 1, n do
        notes_out[r] = {}
        for c = 1, n do
            local cell = {}
            for d, v in pairs(self.notes[r][c]) do
                if v then cell[d] = true end
            end
            notes_out[r][c] = cell
        end
    end
    -- Serialise constraints
    local cons_out = {}
    for i, con in ipairs(self.constraints) do
        cons_out[i] = { r1 = con.r1, c1 = con.c1, r2 = con.r2, c2 = con.c2, less = con.less }
    end
    return {
        n               = n,
        difficulty      = self.difficulty,
        solution        = copyGrid(self.solution, n),
        given           = copyGrid(self.given, n),
        puzzle          = copyGrid(self.puzzle, n),
        user            = copyGrid(self.user, n),
        notes           = notes_out,
        constraints     = cons_out,
        wrong_marks     = copyGrid(self.wrong_marks, n),
        reveal_solution = self.reveal_solution,
        undo            = self.undo:serialize(),
    }
end

function FutoshikiBoard:load(data)
    if type(data) ~= "table" or not data.solution or not data.puzzle then
        return false
    end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.solution   = copyGrid(data.solution, n)
    self.puzzle     = copyGrid(data.puzzle, n)
    self.user       = copyGrid(data.user or {}, n)

    -- Restore given grid (bool values stored as 0/1 or true/false)
    self.given = emptyBoolGrid(n)
    if data.given then
        for r = 1, n do
            for c = 1, n do
                local v = data.given[r] and data.given[r][c]
                self.given[r][c] = (v == true or v == 1)
            end
        end
    end

    -- Restore notes
    self.notes = {}
    for r = 1, n do
        self.notes[r] = {}
        for c = 1, n do
            self.notes[r][c] = {}
            local saved = data.notes and data.notes[r] and data.notes[r][c]
            if type(saved) == "table" then
                for d, v in pairs(saved) do
                    if v then self.notes[r][c][d] = true end
                end
            end
        end
    end

    -- Restore constraints
    self.constraints = {}
    if type(data.constraints) == "table" then
        for i, con in ipairs(data.constraints) do
            self.constraints[i] = {
                r1 = con.r1, c1 = con.c1,
                r2 = con.r2, c2 = con.c2,
                less = con.less,
            }
        end
    end

    -- Restore wrong marks
    self.wrong_marks = emptyBoolGrid(n)
    if data.wrong_marks then
        for r = 1, n do
            for c = 1, n do
                local v = data.wrong_marks[r] and data.wrong_marks[r][c]
                self.wrong_marks[r][c] = (v == true or v == 1)
            end
        end
    end

    self.reveal_solution = data.reveal_solution or false
    self.undo = UndoStack:new{ max_size = 200 }
    if data.undo then self.undo:load(data.undo) end

    return true
end

-- for the specs
FutoshikiBoard._countSolutions = countSolutions

return FutoshikiBoard
