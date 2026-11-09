-- Difficulty guarantees for Futoshiki (see docs/dev/TESTING.md, "Difficulty
-- specs"). Levels are graded by the board's human-style solver
-- (Board._logicSolve): tier 1 = singles and signs read at a glance, tier 2 =
-- chains and subsets, never trial. Easy: tier 1 only; Medium/Hard: a window
-- of tier-2 steps, fewer digits and signs as the level goes up.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Futoshiki difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    describe("generator", function()
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

        it("gives the same puzzle for the same seed", function()
            math.randomseed(2026); local a = Board:new{ n = 6, difficulty = "hard" }
            math.randomseed(2026); local b = Board:new{ n = 6, difficulty = "hard" }
            assert.are.same(a.solution, b.solution)
            assert.are.same(a.given, b.given)
            assert.are.same(a.constraints, b.constraints)
        end)

        it("the level table is ordered: signs, tier, digits floor, tier-2 window", function()
            for _, n in ipairs(SIZES) do
                local e, m, h = Board.LEVELS.easy(n), Board.LEVELS.medium(n), Board.LEVELS.hard(n)
                assert.is_true(e.ineq > m.ineq and m.ineq > h.ineq)
                assert.is_true(e.tier == 1 and m.tier == 2 and h.tier == 2)
                assert.is_true(e.min_given > m.min_given and m.min_given > h.min_given)
                assert.are.equal(0, e.max_t2)
                assert.is_true(e.max_t2 < m.min_t2 and m.max_t2 <= h.min_t2)
            end
        end)

        -- Generation is bounded by attempt counts, never by time: with a
        -- clock that jumps 1000 s at every read, a seed still gives the
        -- same puzzle.
        it("generation never reads the clock", function()
            local oc, ot = os.clock, os.time
            for _, n in ipairs({ 4, 5 }) do
                for _, d in ipairs(LEVELS) do
                    math.randomseed(808 + n)
                    local a = Board:new{ n = n, difficulty = d }
                    local t = 0
                    os.clock = function() t = t + 1000; return t end
                    os.time = function(x) if x then return ot(x) end; t = t + 1000; return t end
                    local ok, b = pcall(function()
                        math.randomseed(808 + n)
                        return Board:new{ n = n, difficulty = d }
                    end)
                    os.clock, os.time = oc, ot
                    assert.is_true(ok, tostring(b))
                    assert.are.same(a.solution, b.solution)
                    assert.are.same(a.given, b.given)
                    assert.are.same(a.constraints, b.constraints)
                end
            end
            local src = assert(io.open(DIR .. "board.lua")):read("*a")
            assert.is_nil(src:find("os%.clock"))
            assert.is_nil(src:find("os%.time"))
        end)
    end)
end)
