local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("FutoshikiBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local function newBoard(n)
        math.randomseed(42)
        return Board:new({ n = n or 5 })
    end

    describe("construction", function()
        it("creates an n×n board", function()
            local b = newBoard(4)
            assert.are.equal(4, b.n)
            assert.are.equal(4, #b.solution)
            assert.are.equal(4, #b.solution[1])
        end)

        it("solution is a valid latin square", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                local seen = {}
                for c = 1, n do
                    local v = b.solution[r][c]
                    assert.is_nil(seen[v], "row " .. r .. " has duplicate " .. v)
                    seen[v] = true
                end
            end
            for c = 1, n do
                local seen = {}
                for r = 1, n do
                    local v = b.solution[r][c]
                    assert.is_nil(seen[v], "col " .. c .. " has duplicate " .. v)
                    seen[v] = true
                end
            end
        end)

        it("has at least one given cell", function()
            local b = newBoard(5)
            local n = b.n
            local count = 0
            for r = 1, n do
                for c = 1, n do
                    if b:isGiven(r, c) then count = count + 1 end
                end
            end
            assert.is_true(count > 0, "expected at least one given cell")
        end)

        it("has at least one constraint", function()
            local b = newBoard(5)
            assert.is_true(#b.constraints > 0)
        end)
    end)

    -- 1.5.0: the counter keeps per-row/column digit sets up to date and
    -- bounds cells by their inequality chains (7x7 Hard took up to ~0.7 s
    -- on a desktop). Keep the old counter here and check the two agree,
    -- and that generation stays unique and quick.
    describe("counter", function()
        -- The pre-1.5.0 counter, verbatim.
        local function oldCountSolutions(puzzle, given, constraints, n, limit, node_budget)
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
        it("counts the same solutions as the old counter on random instances", function()
            for _, n in ipairs({ 4, 5, 6, 7 }) do
                for seed = 1, 25 do
                    math.randomseed(seed * 5501 + n)
                    local sol = Board:new{ n = n, difficulty = "easy" }.solution
                    local cons = {}
                    local ratio = ({ 0.1, 0.3, 0.5, 0.7 })[seed % 4 + 1]
                    for r = 1, n do
                        for c = 1, n do
                            if c < n and math.random() < ratio then
                                cons[#cons + 1] = { r1 = r, c1 = c, r2 = r, c2 = c + 1, less = sol[r][c] < sol[r][c + 1] }
                            end
                            if r < n and math.random() < ratio then
                                cons[#cons + 1] = { r1 = r, c1 = c, r2 = r + 1, c2 = c, less = sol[r][c] < sol[r + 1][c] }
                            end
                        end
                    end
                    local given, puzzle = {}, {}
                    local gr = ({ 0.1, 0.25, 0.4 })[seed % 3 + 1]
                    for r = 1, n do
                        given[r], puzzle[r] = {}, {}
                        for c = 1, n do
                            given[r][c] = math.random() < gr
                            puzzle[r][c] = sol[r][c]
                        end
                    end
                    local so, eo = oldCountSolutions(puzzle, given, cons, n, 3, 400000)
                    local sn, en = Board._countSolutions(puzzle, given, cons, n, 3, 4000000)
                    if not eo then
                        assert.is_false(en)
                        assert.are.equal(so, sn, ("n=%d seed %d"):format(n, seed))
                    end
                end
            end
        end)

        it("generates uniquely solvable 7x7 Hard puzzles quickly", function()
            local worst = 0
            for seed = 1, 8 do
                math.randomseed(seed * 7919)
                local t0 = os.clock()
                local b = Board:new{ n = 7, difficulty = "hard" }
                worst = math.max(worst, os.clock() - t0)
                local count, exhausted = Board._countSolutions(b.puzzle, b.given, b.constraints, 7, 2, 10000000)
                assert.is_false(exhausted)
                assert.are.equal(1, count)
            end
            -- generous: ~0.04 s on a desktop
            assert.is_true(worst < 2.0, ("took %.2f s"):format(worst))
        end)
    end)

    describe("isGiven / getDisplayValue", function()
        it("given cells show the puzzle value", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if b:isGiven(r, c) then
                        assert.are.equal(b.puzzle[r][c], b:getDisplayValue(r, c))
                        return  -- one check is enough
                    end
                end
            end
        end)

        it("empty user cells display as 0", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if not b:isGiven(r, c) then
                        assert.are.equal(0, b:getDisplayValue(r, c))
                        return
                    end
                end
            end
        end)
    end)

    describe("setValue", function()
        it("rejects writes to given cells", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if b:isGiven(r, c) then
                        local ok, reason = b:setValue(r, c, 1)
                        assert.is_false(ok)
                        assert.are.equal("given", reason)
                        return
                    end
                end
            end
        end)

        it("writes to a free cell and clears notes", function()
            local b = newBoard(5)
            local r, c = 1, 1
            while b:isGiven(r, c) do
                c = c + 1
                if c > b.n then c = 1; r = r + 1 end
            end
            b:toggleNote(r, c, 1)
            assert.is_true(b.notes[r][c][1])
            local ok = b:setValue(r, c, 3)
            assert.is_true(ok)
            assert.are.equal(3, b.user[r][c])
            assert.is_nil(b.notes[r][c][1])  -- notes cleared
        end)
    end)

    describe("clearCell", function()
        it("sets user value back to 0", function()
            local b = newBoard(5)
            local r, c = 1, 1
            while b:isGiven(r, c) do
                c = c + 1
                if c > b.n then c = 1; r = r + 1 end
            end
            b:setValue(r, c, 2)
            local ok = b:clearCell(r, c)
            assert.is_true(ok)
            assert.are.equal(0, b.user[r][c])
        end)
    end)

    describe("undo", function()
        it("canUndo is false on a fresh board", function()
            local b = newBoard(5)
            assert.is_false(b:canUndo())
        end)

        it("restores previous value after setValue", function()
            local b = newBoard(5)
            local r, c = 1, 1
            while b:isGiven(r, c) do
                c = c + 1
                if c > b.n then c = 1; r = r + 1 end
            end
            b:setValue(r, c, 5)
            assert.is_true(b:canUndo())
            Board.undo(b)  -- b.undo field (UndoStack) shadows the :undo() method
            assert.are.equal(0, b.user[r][c])
        end)

        it("restores notes after toggleNote", function()
            local b = newBoard(5)
            local r, c = 1, 1
            while b:isGiven(r, c) do
                c = c + 1
                if c > b.n then c = 1; r = r + 1 end
            end
            b:toggleNote(r, c, 2)
            assert.is_true(b.notes[r][c][2])
            Board.undo(b)
            assert.is_nil(b.notes[r][c][2])
        end)
    end)

    describe("isSolved", function()
        it("returns false for a fresh board", function()
            local b = newBoard(5)
            assert.is_false(b:isSolved())
        end)

        it("returns true when all cells match the solution", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if not b:isGiven(r, c) then
                        b.user[r][c] = b.solution[r][c]
                    end
                end
            end
            assert.is_true(b:isSolved())
        end)
    end)

    describe("checkConflicts", function()
        it("marks a wrong cell", function()
            local b = newBoard(5)
            local n = b.n
            local r, c
            for rr = 1, n do
                for cc = 1, n do
                    if not b:isGiven(rr, cc) then
                        -- Find a wrong value (not the solution value)
                        local wrong = (b.solution[rr][cc] % n) + 1
                        b.user[rr][cc] = wrong
                        r, c = rr, cc
                        goto found
                    end
                end
            end
            ::found::
            b:checkConflicts()
            assert.is_true(b.wrong_marks[r][c])
        end)

        it("clears a wrong mark when value corrected", function()
            local b = newBoard(5)
            local n = b.n
            local r, c
            for rr = 1, n do
                for cc = 1, n do
                    if not b:isGiven(rr, cc) then r, c = rr, cc; goto found end
                end
            end
            ::found::
            b.user[r][c] = (b.solution[r][c] % n) + 1
            b:checkConflicts()
            assert.is_true(b.wrong_marks[r][c])
            b.user[r][c] = b.solution[r][c]
            b:checkConflicts()
            assert.is_false(b.wrong_marks[r][c])
        end)
    end)

    describe("getRemainingCells", function()
        it("counts empty non-given cells", function()
            local b = newBoard(5)
            local n = b.n
            local empty = 0
            for r = 1, n do
                for c = 1, n do
                    if not b:isGiven(r, c) then empty = empty + 1 end
                end
            end
            assert.are.equal(empty, b:getRemainingCells())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips the full board state", function()
            local b = newBoard(5)
            local n = b.n
            -- Write a value and a note into free cells
            local fr, fc
            for r = 1, n do
                for c = 1, n do
                    if not b:isGiven(r, c) then fr, fc = r, c; goto done end
                end
            end
            ::done::
            b:setValue(fr, fc, 1)
            local data = b:serialize()

            local b2 = Board:new({ n = n })  -- generates a fresh random board
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(1, b2.user[fr][fc])
            for r = 1, n do
                for c = 1, n do
                    assert.are.equal(b.solution[r][c], b2.solution[r][c])
                end
            end
        end)

        it("load returns false for invalid data", function()
            local b = newBoard(5)
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)

    -- 1.6.0: levels graded by a human-style solver, never trial and error.
    describe("difficulty levels (1.6.0)", function()
        local SIZES, LEVELS = { 4, 5, 6, 7 }, { "easy", "medium", "hard" }
        local SEEDS = 8

        local function shown(b)
            local p, k = {}, 0
            for r = 1, b.n do
                p[r] = {}
                for c = 1, b.n do
                    p[r][c] = b.given[r][c] and b.solution[r][c] or 0
                    if b.given[r][c] then k = k + 1 end
                end
            end
            return p, k
        end

        it("every level is solvable without trial, within its tier", function()
            for _, n in ipairs(SIZES) do
                for _, d in ipairs(LEVELS) do
                    local level = Board.LEVELS[d](n)
                    for seed = 1, SEEDS do
                        math.randomseed(seed * 131 + n)
                        local b = Board:new{ n = n, difficulty = d }
                        local p = shown(b)
                        local ok, t2, values = Board._logicSolve(p, b.constraints, n, level.tier)
                        assert.is_true(ok, n .. " " .. d .. " seed " .. seed)
                        assert.are.same(b.solution, values)
                        if d == "easy" then
                            assert.are.equal(0, t2)
                        else
                            assert.is_true(t2 >= 1, n .. " " .. d .. " needs tier 2")
                        end
                    end
                end
            end
        end)

        it("levels are distinct: fewer clues and more tier-2 steps as they go up", function()
            for _, n in ipairs(SIZES) do
                local clues, t2s = {}, {}
                for li, d in ipairs(LEVELS) do
                    clues[li], t2s[li] = 0, 0
                    for seed = 1, SEEDS do
                        math.randomseed(seed * 71 + n)
                        local b = Board:new{ n = n, difficulty = d }
                        local p, k = shown(b)
                        local _, t2 = Board._logicSolve(p, b.constraints, n, 2)
                        t2s[li] = t2s[li] + t2
                        clues[li] = clues[li] + k + #b.constraints
                    end
                end
                assert.is_true(clues[1] > clues[2] and clues[2] > clues[3], "clues n=" .. n)
                assert.is_true(t2s[1] < t2s[2] and t2s[2] < t2s[3], "tier-2 steps n=" .. n)
            end
        end)

        it("the solver never settles an ambiguous grid", function()
            local solved = 0
            for seed = 1, 80 do
                math.randomseed(seed * 7)
                local n = 4 + seed % 3
                local sol = Board:new{ n = n, difficulty = "easy" }.solution
                local cons, given, puzzle, p = {}, {}, {}, {}
                for r = 1, n do
                    for c = 1, n do
                        if c < n and math.random() < 0.4 then
                            cons[#cons + 1] = { r1 = r, c1 = c, r2 = r, c2 = c + 1, less = sol[r][c] < sol[r][c + 1] }
                        end
                        if r < n and math.random() < 0.4 then
                            cons[#cons + 1] = { r1 = r, c1 = c, r2 = r + 1, c2 = c, less = sol[r][c] < sol[r + 1][c] }
                        end
                    end
                end
                for r = 1, n do
                    given[r], puzzle[r], p[r] = {}, {}, {}
                    for c = 1, n do
                        given[r][c] = math.random() < 0.25
                        puzzle[r][c] = sol[r][c]
                        p[r][c] = given[r][c] and sol[r][c] or 0
                    end
                end
                local ok, _, values = Board._logicSolve(p, cons, n, 2)
                if ok then
                    solved = solved + 1
                    assert.are.equal(1, (Board._countSolutions(puzzle, given, cons, n, 2, 1e7)))
                    assert.are.same(sol, values)
                end
            end
            assert.is_true(solved > 0)
        end)

        it("gives the same puzzle for the same seed", function()
            math.randomseed(2026); local a = Board:new{ n = 6, difficulty = "hard" }
            math.randomseed(2026); local b = Board:new{ n = 6, difficulty = "hard" }
            assert.are.same(a.solution, b.solution)
            assert.are.same(a.given, b.given)
            assert.are.same(a.constraints, b.constraints)
        end)

        it("loads a save from 1.5.x", function()
            local b = Board:new{ n = 4, empty = true }
            assert.is_true(b:load({
                n = 4, difficulty = "hard",
                solution = { {1,2,3,4}, {2,3,4,1}, {3,4,1,2}, {4,1,2,3} },
                puzzle   = { {1,0,0,0}, {0,0,0,0}, {0,0,0,0}, {0,0,0,3} },
                given    = { {true,false,false,false}, {false,false,false,false},
                             {false,false,false,false}, {false,false,false,true} },
                user     = { {0,2,0,0}, {0,0,0,0}, {0,0,0,0}, {0,0,0,0} },
                constraints = { { r1 = 1, c1 = 1, r2 = 1, c2 = 2, less = true } },
            }))
            assert.are.equal("hard", b.difficulty)
            assert.are.equal(2, b:getDisplayValue(1, 2))
            assert.are.equal(1, #b.constraints)
        end)
    end)
end)
