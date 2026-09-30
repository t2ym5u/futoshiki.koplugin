local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Button          = require("ui/widget/button")
local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase          = require("screen_base")
local MenuHelper          = require("menu_helper")
local FutoshikiBoard      = lrequire("board")
local FutoshikiBoardWidget = lrequire("board_widget")

local DeviceScreen = Device.screen

local GRID_SIZES = { 4, 5, 6, 7 }

-- ---------------------------------------------------------------------------
-- FutoshikiScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Futoshiki — Rules

Fill the N×N grid with numbers 1 to N so that each row and each column contains each number exactly once.

Inequality constraint:
• Greater-than (>) and less-than (<) signs appear between some adjacent cells.
• The numbers placed in those cells must satisfy the inequality shown.

Tap a cell to select it, then tap a digit button to fill it in. Undo is available.
]])

local GAME_RULES_FR = [[
Futoshiki — Règles

Remplissez la grille N×N avec les chiffres de 1 à N de sorte que chaque ligne et chaque colonne contienne chaque chiffre exactement une fois.

Contrainte d'inégalité :
• Des signes supérieur (>) et inférieur (<) apparaissent entre certaines cases adjacentes.
• Les chiffres placés dans ces cases doivent satisfaire l'inégalité indiquée.

Appuyez sur une case pour la sélectionner, puis appuyez sur un chiffre pour le placer. L'annulation est disponible.
]]

local FutoshikiScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function FutoshikiScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 5)
    self.board  = FutoshikiBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "easy"))
    end
    self.selected  = nil
    self.note_mode = false
    ScreenBase.init(self)
end

function FutoshikiScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function FutoshikiScreen:buildLayout()
    local n  = self.board.n
    local sw = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = FutoshikiBoardWidget:new{
        board          = self.board,
        onCellSelected = function(r, c) self:onCellSelected(r, c) end,
    }
    if self.selected then
        self.board_widget:setSelected(self.selected.r, self.selected.c)
    end

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    self.status_text:setMaxWidth(is_landscape and button_width or board_frame_size)

    -- Title bar with Options menu
    local title_bar = self:buildTitleBar(_("Futoshiki"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            { text = self:getShowButtonText(), callback = function() self:toggleSolution() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Digit buttons  1 .. n  in a single row, drawn as real bordered buttons
    local digit_btn_width = math.floor(button_width / n)
    local digit_buttons = HorizontalGroup:new{}
    self.digit_button_refs = {}
    for d = 1, n do
        local dv = d
        local digit_btn = Button:new{
            text       = tostring(dv),
            width      = digit_btn_width,
            margin     = Size.margin.small,
            bordersize = Size.border.button,
            radius     = Size.radius.button,
            padding    = Size.padding.buttontable,
            callback   = function() self:onDigit(dv) end,
        }
        self.digit_button_refs[d] = digit_btn
        table.insert(digit_buttons, digit_btn)
    end

    -- Bottom action bar
    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { id = "note_button", text = self:getNoteButtonText(),
                  callback = function() self:toggleNoteMode() end },
                { text = _("Erase"),  callback = function() self:onErase() end },
                { text = _("Check"),  callback = function() self:onCheck() end },
                { text = _("Hint"), callback = function() self:onHint() end },
                { id = "undo_button", text = _("Undo"),
                  callback = function() self:onUndo() end },
            },
        },
    }
    self.note_button = bottom_buttons:getButtonById("note_button")
    self.undo_button = bottom_buttons:getButtonById("undo_button")

    self:_updateUndoButton()

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            digit_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        local content = VerticalGroup:new{
            align = "center",
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
        }
        local footer = VerticalGroup:new{
            align = "center",
            digit_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self:buildPortraitLayout(title_bar, content, footer)
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function FutoshikiScreen:onCellSelected(r, c)
    self.selected = { r = r, c = c }
    self.board_widget:setSelected(r, c)
    self.board_widget:refresh()
    self:updateStatus()
end

function FutoshikiScreen:onDigit(d)
    if not self.selected then return end
    local r, c = self.selected.r, self.selected.c
    local ok, err
    if self.note_mode then
        ok, err = self.board:toggleNote(r, c, d)
    else
        -- Toggle off if the same digit is entered twice
        local cur = self.board.user[r][c]
        if cur == d then
            ok, err = self.board:clearCell(r, c)
        else
            ok, err = self.board:setValue(r, c, d)
        end
    end
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        if self.board:isSolved() then
            self:updateStatus(_("Congratulations! Puzzle solved."))
        else
            self:updateStatus()
        end
    else
        self:updateStatus(err == "given" and _("Cannot edit a given cell.") or nil)
    end
    self.board_widget:refresh()
end

function FutoshikiScreen:onErase()
    if not self.selected then return end
    local r, c = self.selected.r, self.selected.c
    local ok, err = self.board:clearCell(r, c)
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
    elseif err == "given" then
        self:updateStatus(_("Cannot edit a given cell."))
        return
    end
    self.board_widget:refresh()
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function FutoshikiScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", 5)
    self.board = FutoshikiBoard:new{ n = n }
    self.board:generate(diff)
    self.selected  = nil
    self.note_mode = false
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function FutoshikiScreen:onUndo()
    local ok, msg = self.board:undo()
    if ok then
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
end

function FutoshikiScreen:onCheck()
    self.board:checkConflicts()
    self.board_widget:refresh()
    local remaining = self.board:getRemainingCells()
    if remaining > 0 then
        self:updateStatus(T(_("Check done. %1 cell(s) remaining."), remaining))
    elseif self.board:isSolved() then
        self:updateStatus(_("Congratulations! Puzzle solved."))
    else
        self:updateStatus(_("Some cells are incorrect."))
    end
end

function FutoshikiScreen:toggleSolution()
    self.board:toggleSolution()
    self.board_widget:refresh()
    if self.show_button then
        self.show_button:setText(self:getShowButtonText(), self.show_button.width)
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Note mode
-- ---------------------------------------------------------------------------

function FutoshikiScreen:toggleNoteMode()
    self.note_mode = not self.note_mode
    if self.note_button then
        self.note_button:setText(self:getNoteButtonText(), self.note_button.width)
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Grid size menu
-- ---------------------------------------------------------------------------

function FutoshikiScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes + 1] = {
            id   = sz,
            text = sz .. "\xC3\x97" .. sz,   -- UTF-8 "×"
        }
    end
    MenuHelper.openSizeMenu{
        title   = _("Select grid size"),
        sizes   = sizes,
        current = self.plugin:getSetting("grid_n", 5),
        parent  = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Difficulty menu
-- ---------------------------------------------------------------------------

function FutoshikiScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function FutoshikiScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    else
        local remaining = self.board:getRemainingCells()
        local diff      = self.plugin:getSetting("difficulty", "easy")
        local label     = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        if self.board:isShowingSolution() then
            status = _("Solution is shown; editing is disabled.")
        elseif self.board:isSolved() then
            status = _("Congratulations! Puzzle solved.")
        else
            local note_str = self.note_mode and _(" · Note ON") or ""
            status = T(_("%1×%2 · %3 · Empty: %4%5"),
                self.board.n, self.board.n, label, remaining, note_str)
        end
    end
    ScreenBase.updateStatus(self, status)
end

-- ---------------------------------------------------------------------------
-- Button text helpers
-- ---------------------------------------------------------------------------

function FutoshikiScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function FutoshikiScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

function FutoshikiScreen:getShowButtonText()
    return self.board:isShowingSolution() and _("Hide result") or _("Show result")
end

function FutoshikiScreen:getNoteButtonText()
    return self.note_mode and _("Note: ON") or _("Note: OFF")
end

function FutoshikiScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return FutoshikiScreen
