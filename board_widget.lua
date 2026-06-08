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
    -- The grid occupies most of the cell; leave a gap on each edge for
    -- inequality symbols so we reduce size_ratio slightly.
    self.size_ratio = 0.78
    GridWidgetBase.init(self)
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
    local thin  = Size.line.thin  or 1
    local thick = Size.line.thick or 2

    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        -- Vertical line
        drawLine(bb, x + math.floor(i * cell), y, lw, self.dimen.h, C_LINE)
        -- Horizontal line
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, lw, C_LINE)
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
    -- -----------------------------------------------------------------------
    local sym_size  = math.max(8, math.floor(cell * 0.22))
    local sym_face  = Font:getFace("cfont", sym_size)

    for _, con in ipairs(self.board.constraints) do
        local r1, c1, r2, c2 = con.r1, con.c1, con.r2, con.c2
        -- Determine which symbol to draw from the perspective of (r1,c1)→(r2,c2)
        -- con.less == true  means cell(r1,c1) < cell(r2,c2)  → symbol on the left/top is "<"
        -- We always draw the symbol from the smaller side.
        local sym = con.less and "<" or ">"

        if r1 == r2 then
            -- Horizontal constraint: (r,c1) and (r,c2=c1+1)
            local mid_x = x + math.floor(c1 * cell)
            local mid_y = y + math.floor((r1 - 0.5) * cell)
            local sm    = RenderText:sizeUtf8Text(0, 200, sym_face, sym, true, false)
            local sx    = mid_x - math.floor(sm.x / 2)
            local sbase = mid_y + math.floor((sm.y_top - sm.y_bottom) / 2)
            RenderText:renderUtf8Text(bb, sx, sbase, sym_face, sym, true, false, C_INEQ)
        else
            -- Vertical constraint: (r1,c) and (r2=r1+1,c)
            -- "^" = top cell is smaller (con.less=true), "v" = bottom cell is smaller.
            local vsym  = con.less and "^" or "v"
            local mid_x = x + math.floor((c1 - 0.5) * cell)
            local mid_y = y + math.floor(r1 * cell)
            local sm    = RenderText:sizeUtf8Text(0, 200, sym_face, vsym, true, false)
            local sx    = mid_x - math.floor(sm.x / 2)
            local sbase = mid_y + math.floor((sm.y_top - sm.y_bottom) / 2)
            RenderText:renderUtf8Text(bb, sx, sbase, sym_face, vsym, true, false, C_INEQ)
        end
    end
end

-- Expose selected cell so paintTo can highlight it.
function FutoshikiBoardWidget:setSelected(r, c)
    self.selected = r and c and { r = r, c = c } or nil
end

return FutoshikiBoardWidget
