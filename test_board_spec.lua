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
end)
