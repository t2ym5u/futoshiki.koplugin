local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")

local emptyGrid      = grid_utils.emptyGrid
local emptyBoolGrid  = grid_utils.emptyBoolGrid
local copyGrid       = grid_utils.copyGrid
local shuffle        = grid_utils.shuffle

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

-- Fraction of adjacent pairs exposed as visible inequality constraints.
local CONSTRAINT_RATIOS = { easy = 0.60, medium = 0.40, hard = 0.25 }
-- Fraction of cells that are pre-filled givens.
local GIVEN_RATIOS      = { easy = 0.50, medium = 0.35, hard = 0.20 }

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
    obj:generate(obj.difficulty)
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
local NODE_BUDGET_UNIQUENESS = 200000

local function countSolutions(puzzle, given, constraints, n, limit, node_budget)
    local grid = {}
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do grid[r][c] = given[r][c] and puzzle[r][c] or 0 end
    end

    local cons = {}
    for r = 1, n do cons[r] = {}; for c = 1, n do cons[r][c] = {} end end
    for _, con in ipairs(constraints) do
        table.insert(cons[con.r1][con.c1], { r = con.r2, c = con.c2, self_less = con.less })
        table.insert(cons[con.r2][con.c2], { r = con.r1, c = con.c1, self_less = not con.less })
    end

    local solutions, nodes, exhausted = 0, 0, false

    local function rowUsed(r)
        local u = {}
        for c = 1, n do if grid[r][c] ~= 0 then u[grid[r][c]] = true end end
        return u
    end
    local function colUsed(c)
        local u = {}
        for r = 1, n do if grid[r][c] ~= 0 then u[grid[r][c]] = true end end
        return u
    end

    local function candidatesFor(r, c)
        local ru, cu = rowUsed(r), colUsed(c)
        local cands = {}
        for v = 1, n do
            if not ru[v] and not cu[v] then
                local ok = true
                for _, con in ipairs(cons[r][c]) do
                    local ov = grid[con.r][con.c]
                    if ov ~= 0 then
                        if con.self_less and not (v < ov) then ok = false; break end
                        if not con.self_less and not (v > ov) then ok = false; break end
                    end
                end
                if ok then cands[#cands + 1] = v end
            end
        end
        return cands
    end

    local function search(depth, empties)
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if depth > #empties then solutions = solutions + 1; return end
        local best_idx, best_cands, best_len = nil, nil, n + 1
        for i, cell in ipairs(empties) do
            if grid[cell.r][cell.c] == 0 then
                local cands = candidatesFor(cell.r, cell.c)
                if #cands < best_len then
                    best_len, best_cands, best_idx = #cands, cands, i
                    if best_len <= 1 then break end
                end
            end
        end
        if best_idx == nil then solutions = solutions + 1; return end
        if best_len == 0 then return end
        local cell = empties[best_idx]
        for _, v in ipairs(best_cands) do
            grid[cell.r][cell.c] = v
            search(depth + 1, empties)
            grid[cell.r][cell.c] = 0
            if solutions >= limit or exhausted then return end
        end
    end

    local empties = {}
    for r = 1, n do for c = 1, n do if grid[r][c] == 0 then empties[#empties + 1] = { r = r, c = c } end end end
    search(1, empties)
    return solutions, exhausted
end

function FutoshikiBoard:generate(difficulty)
    self.difficulty     = difficulty or self.difficulty
    local n             = self.n
    self.reveal_solution = false
    self.undo:clear()

    -- 1. Build a valid Latin square
    local sol = permuteLatin(makeBaseLatin(n), n)
    self.solution = sol

    -- 2. Collect every adjacent pair and its real inequality direction
    local all_pairs = {}
    for r = 1, n do
        for c = 1, n do
            -- horizontal: (r,c) vs (r,c+1)
            if c < n then
                all_pairs[#all_pairs + 1] = {
                    r1 = r, c1 = c, r2 = r, c2 = c + 1,
                    less = sol[r][c] < sol[r][c + 1],
                }
            end
            -- vertical: (r,c) vs (r+1,c)
            if r < n then
                all_pairs[#all_pairs + 1] = {
                    r1 = r, c1 = c, r2 = r + 1, c2 = c,
                    less = sol[r][c] < sol[r + 1][c],
                }
            end
        end
    end

    -- 3. Select which pairs become visible constraints
    local ratio = CONSTRAINT_RATIOS[self.difficulty] or 0.40
    shuffle(all_pairs)
    local num_constraints = math.max(1, math.floor(#all_pairs * ratio))
    self.constraints = {}
    for i = 1, num_constraints do
        self.constraints[i] = all_pairs[i]
    end

    -- 4. Choose given cells: dig one at a time (like sudoku-common's
    -- hole-digging), starting fully revealed and verifying with
    -- countSolutions after each tentative removal, putting the cell back
    -- if that broke uniqueness -- the old "shuffle positions, keep a flat
    -- ratio" approach never checked this (see
    -- docs/generator_robustness_audit.md's Tier 2 table: measured fine at
    -- small sizes/easy, degrading to 0% unique at n=7/hard). The visible
    -- constraint set chosen above stays fixed while digging; starting from
    -- every cell given is trivially unique regardless of which constraints
    -- are shown, so this only needs to verify uniqueness as *cells* are
    -- removed, not re-verify the constraint selection itself.
    local given_ratio = GIVEN_RATIOS[self.difficulty] or 0.35
    local num_givens  = math.max(1, math.floor(n * n * given_ratio))
    local target_hide = (n * n) - num_givens
    local positions   = {}
    for r = 1, n do
        for c = 1, n do
            positions[#positions + 1] = { r = r, c = c }
        end
    end
    shuffle(positions)

    self.given  = emptyBoolGrid(n)
    self.puzzle = emptyGrid(n)
    for r = 1, n do
        for c = 1, n do
            self.given[r][c]  = true
            self.puzzle[r][c] = sol[r][c]
        end
    end

    local hidden = 0
    for _, p in ipairs(positions) do
        if hidden >= target_hide then break end
        local r, c = p.r, p.c
        self.given[r][c] = false
        local solutions, exhausted = countSolutions(self.puzzle, self.given, self.constraints, n, 2, NODE_BUDGET_UNIQUENESS)
        if not exhausted and solutions == 1 then
            self.puzzle[r][c] = 0
            hidden = hidden + 1
        else
            self.given[r][c] = true
        end
    end

    -- 5. Reset user state
    self.user = emptyGrid(n)
    self.wrong_marks = emptyBoolGrid(n)
    self.notes = {}
    for r = 1, n do
        self.notes[r] = {}
        for c = 1, n do
            self.notes[r][c] = {}
        end
    end
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

return FutoshikiBoard
