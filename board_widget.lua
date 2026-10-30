local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

-- ---------------------------------------------------------------------------
-- FutoshikiBoardWidget
-- ---------------------------------------------------------------------------

local FutoshikiBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function FutoshikiBoardWidget:init()
    local n     = self.board and self.board.n or 5
    self.cols   = n
    self.rows   = n
    GridWidgetBase.init(self)
    -- The inequality signs sit on the cell borders, so the digits are kept
    -- smaller than the base fit (which fills the cell) to leave them room.
    self.number_face = Font:getFace("cfont",
        math.max(10, math.floor(self.number_face.orig_size * 0.6)))
end

function FutoshikiBoardWidget:onCellTap(row, col)
    if self.onCellSelected then
        self.onCellSelected(row, col)
    end
end

-- ---------------------------------------------------------------------------
-- Colour palette
-- ---------------------------------------------------------------------------

local C_BG         = Blitbuffer.COLOR_WHITE
local C_SEL        = Blitbuffer.COLOR_GRAY_D   -- selected cell highlight
local C_WRONG      = Blitbuffer.COLOR_GRAY_B   -- wrong-mark cell background
local C_GIVEN_BG   = Blitbuffer.COLOR_GRAY_E   -- slightly grey background for given cells
local C_LINE       = Blitbuffer.COLOR_BLACK
local C_GIVEN_FG   = Blitbuffer.COLOR_BLACK
local C_USER_FG    = Blitbuffer.COLOR_GRAY_2
local C_REVEAL_FG  = Blitbuffer.COLOR_GRAY_4
local C_NOTE_FG    = Blitbuffer.COLOR_GRAY_4
local C_INEQ       = Blitbuffer.COLOR_BLACK

-- ---------------------------------------------------------------------------
-- paintTo
-- ---------------------------------------------------------------------------

function FutoshikiBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local n      = self.board.n
    local cell   = self.dimen.w / n   -- cell size in pixels (float)

    -- White background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- -----------------------------------------------------------------------
    -- Cell backgrounds
    -- -----------------------------------------------------------------------
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)

            if self.selected and self.selected.r == r and self.selected.c == c then
                bb:paintRect(cx, cy, cw, ch, C_SEL)
            elseif self.board.wrong_marks[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_WRONG)
            elseif self.board:isGiven(r, c) then
                bb:paintRect(cx, cy, cw, ch, C_GIVEN_BG)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Grid lines
    -- -----------------------------------------------------------------------
    -- The outer border is the board's only frame, so it is drawn thick
    -- enough to read as one.
    local thin  = Size.line.thin  or 1
    local thick = math.max(Size.line.thick or 2, math.floor(cell * 0.05))

    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        -- The last line is drawn inside the widget, not past its edge.
        local p  = math.floor(i * cell) - (i == n and lw or 0)
        -- Vertical line
        drawLine(bb, x + p, y, lw, self.dimen.h, C_LINE)
        -- Horizontal line
        drawLine(bb, x, y + p, self.dimen.w, lw, C_LINE)
    end

    -- -----------------------------------------------------------------------
    -- Cell content: values or notes
    -- -----------------------------------------------------------------------
    local cell_padding = self.number_padding or 2
    local cell_inner   = math.max(1, math.floor(cell - 2 * cell_padding))

    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local v  = self.board:getDisplayValue(r, c)

            if v ~= 0 then
                -- Draw digit
                local text = tostring(v)
                local color
                if self.board:isShowingSolution() and not self.board:isGiven(r, c) then
                    color = C_REVEAL_FG
                elseif self.board:isGiven(r, c) then
                    color = C_GIVEN_FG
                else
                    color = C_USER_FG
                end
                local metrics  = RenderText:sizeUtf8Text(0, cell_inner, self.number_face, text, true, false)
                local text_w   = metrics.x
                local baseline = cy + cell_padding + math.floor((cell_inner + metrics.y_top - metrics.y_bottom) / 2)
                local text_x   = cx + cell_padding + math.floor((cell_inner - text_w) / 2)
                RenderText:renderUtf8Text(bb, text_x, baseline, self.number_face, text, true, false, color)
            else
                -- Draw candidate notes in a 3×ceil(n/3) sub-grid layout
                local notes = self.board.notes[r][c]
                if notes then
                    local cols3 = 3
                    local rows3 = math.ceil(n / cols3)
                    local mini_w = cell / cols3
                    local mini_h = cell / rows3
                    local np     = self.note_padding or 1
                    local miw    = math.max(1, math.floor(mini_w - 2 * np))
                    local mih    = math.max(1, math.floor(mini_h - 2 * np))
                    for d = 1, n do
                        if notes[d] then
                            local mc = (d - 1) % cols3
                            local mr = math.floor((d - 1) / cols3)
                            local mx = cx + math.floor(mc * mini_w)
                            local my = cy + math.floor(mr * mini_h)
                            local nt = tostring(d)
                            local nm = RenderText:sizeUtf8Text(0, miw, self.note_face, nt, true, false)
                            local nb = my + np + math.floor((mih + nm.y_top - nm.y_bottom) / 2)
                            local nx = mx + np + math.floor((miw - nm.x) / 2)
                            RenderText:renderUtf8Text(bb, nx, nb, self.note_face, nt, true, false, C_NOTE_FG)
                        end
                    end
                end
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Inequality constraints
    --
    -- Drawn as chevrons rather than "<" / "^" / "v" glyphs: the caret and
    -- the letter v are not the same shape as < and >, and sit at different
    -- heights in the font, so the vertical signs never looked like the
    -- horizontal ones. The chevron points at the smaller cell.
    -- -----------------------------------------------------------------------
    local arm  = math.max(3, math.floor(cell * 0.11))   -- half the opening
    local reach = math.max(2, math.floor(cell * 0.07))  -- half the depth
    local stroke = math.max(2, math.floor(cell * 0.035))

    local function segment(x0, y0, x1, y1)
        local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0), 1)
        local half  = math.floor(stroke / 2)
        for k = 0, steps do
            bb:paintRect(math.floor(x0 + (x1 - x0) * k / steps) - half,
                         math.floor(y0 + (y1 - y0) * k / steps) - half,
                         stroke, stroke, C_INEQ)
        end
    end

    for _, con in ipairs(self.board.constraints) do
        local r1, c1, r2 = con.r1, con.c1, con.r2
        -- con.less == true means cell(r1,c1) < cell(r2,c2): the apex points
        -- back at (r1,c1), which is left of / above (r2,c2).
        local dir = con.less and -1 or 1
        if r1 == r2 then
            local mx = x + math.floor(c1 * cell)
            local my = y + math.floor((r1 - 0.5) * cell)
            local ax, bx = mx + dir * reach, mx - dir * reach
            segment(ax, my, bx, my - arm)
            segment(ax, my, bx, my + arm)
        else
            local mx = x + math.floor((c1 - 0.5) * cell)
            local my = y + math.floor(r1 * cell)
            local ay, by = my + dir * reach, my - dir * reach
            segment(mx, ay, mx - arm, by)
            segment(mx, ay, mx + arm, by)
        end
    end
end

-- Expose selected cell so paintTo can highlight it.
function FutoshikiBoardWidget:setSelected(r, c)
    self.selected = r and c and { r = r, c = c } or nil
end

return FutoshikiBoardWidget
