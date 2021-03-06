-- mod-version:2 -- lite-xl 2.0

--[[

vim.lua - see end of file for license information

TODO LIST
(IN PROGRESS) combos
    - diw, cit, ...
(IN PROGRESS) commands
    - :q!
    - (IN PROGRESS) :s/foo/bar/g
(IN PROGRESS) number + command (123g, 50j, d3w, y10l)
(IN PROGRESS) marks (``, m)
    - last change (`.)
    - yank/change/delete to mark (y`a)
    - uppercase marks (mA)
repeat (.)
delete other windows (ctrl+w o)
replace mode (shift+r)
replace in visual block

TOFIX LIST
(high) tab indent (<<, >>) is broken
(high) indent left (<<) when indent is too small deletes the line
(high) substitution with certain characters crashes
(low) cursor should always stay in view (ctrl+e/y, mouse wheel)
(low) autocomplete shows up when using find (f)
(low) visual block insert gets misaligned when moving cursor from bottom to top
(low) (@@) does not work

--]]
--

local core = require "core"
local keymap = require "core.keymap"
local command = require "core.command"
local CommandView = require "core.commandview"
local DocView = require "core.docview"
local StatusView = require "core.statusview"
local Doc = require "core.doc"
local style = require "core.style"
local translate = require "core.doc.translate"
local common = require "core.common"
local config = require "core.config"

local is_lite_xl = system.get_file_info "data/core/start.lua"

local function dv()
    return core.active_view
end

local function doc()
    return core.active_view.doc
end

local mode = "normal" -- one of: "normal", "visual", "insert"
local visual_submode  -- one of: nil, "line", "block"

local visual_block_state = {
    current = "stopped", -- one of: "stopped", "recording", "playing"
    event_buffer = {},
    selection = {}
}

local function normal_mode()
    mode = "normal"
    visual_submode = nil
end

local function visual_mode(submode)
    mode = "visual"
    visual_submode = submode
end

local function insert_mode()
    mode = "insert"
    visual_submode = nil
end

-- doc:get_selection, but it gets vim's visual region
local function get_selection(doc)
    local l1, c1, l2, c2 = doc:get_selection(true)

    if visual_submode == "block" then
        core.error "get_selection while in visual block"
    elseif visual_submode == "line" then
        c1 = 1
        c2 = #doc.lines[l2]
    else
        c2 = c2 + 1
    end

    return l1, c1, l2, c2
end

-- used for number + command (50j to go down 50 lines, y3w to copy 3 words, etc)
local n_repeat = 0

local relative_line_mode = false
local enable_linenum = true

local stroke_combo_tree = {
    normal = {
        ["ctrl+w"] = {},
        ["shift+,"] = {},
        ["shift+."] = {},
        ["shift+z"] = {},
        c = {},
        d = {
            g = {},
            ["#"] = {}
        },
        g = {},
        y = {
            ["#"] = {}
        }
    },
    visual = {
        g = {},
        ["shift+,"] = {},
        ["shift+."] = {}
    },
    insert = {}
}

local stroke_combo_loc = stroke_combo_tree[mode] -- should be a reference to an item in stroke_combo_tree
local stroke_combo_string = "" -- key buffer

local previous_exec_command = ""
local exec_commands = {
    w = "doc:save",
    q = "root:close",
    wq = "vim:save-and-close",
    x = "vim:save-and-close",
    nohl = "vim:nohl",
    sort = "vim:sort-lines"
}

local substitute = {
    from = "",
    to = "",
    mods = "",
    display = false
}

local previous_search_command = ""
local search_text = ""
local should_highlight = false

local macros = {
    state = "stopped",
    key = nil,
    previously_played = nil,
    buffers = {}
}

local handled_events = {
    keypressed = true,
    keyreleased = true,
    textinput = true
}

local core_on_event = core.on_event
function core.on_event(type, ...)
    local res = core_on_event(type, ...)

    if visual_block_state.current == "recording" and handled_events[type] then
        table.insert(visual_block_state.event_buffer, {type, ...})
    end

    if macros.state == "recording" and handled_events[type] then
        table.insert(macros.buffers[macros.key], {type, ...})
    end

    return res
end

local mini_mode  -- either nil, or a function in mini_mode_callbacks

local previous_find_text

local mini_mode_callbacks = {
    find = function(input_text)
        previous_find_text = input_text
        local l1, c1, l2, c2 = doc():get_selection()
        local text = doc():get_text(l1, 1, l1, math.huge)

        for i = c1 + 1, #text do
            local c = text:sub(i, i)

            if c == input_text then
                if mode == "normal" then
                    doc():set_selection(l1, i)
                elseif mode == "visual" then
                    doc():set_selection(l1, i, l2, c2)
                end

                return
            end
        end

        core.error("Can't find " .. input_text)
    end,
    find_backwards = function(input_text)
        previous_find_text = input_text
        local l1, c1, l2, c2 = doc():get_selection()
        local text = doc():get_text(l1, 1, l1, math.huge)

        for i = c1 - 1, 1, -1 do
            local c = text:sub(i, i)

            if c == input_text then
                if mode == "normal" then
                    doc():set_selection(l1, i)
                elseif mode == "visual" then
                    doc():set_selection(l1, i, l2, c2)
                end

                return
            end
        end

        core.error("Can't find " .. input_text)
    end,
    find_til = function(input_text)
        previous_find_text = input_text
        local l1, c1, l2, c2 = doc():get_selection()
        local text = doc():get_text(l1, 1, l1, math.huge)

        for i = c1 + 1, #text do
            local c = text:sub(i, i)

            if c == input_text then
                if mode == "normal" then
                    doc():set_selection(l1, i - 1)
                elseif mode == "visual" then
                    doc():set_selection(l1, i - 1, l2, c2)
                end

                return
            end
        end

        core.error("Can't find " .. input_text)
    end,
    find_til_backwards = function(input_text)
        previous_find_text = input_text
        local l1, c1, l2, c2 = doc():get_selection()
        local text = doc():get_text(l1, 1, l1, math.huge)

        for i = c1 - 1, 1, -1 do
            local c = text:sub(i, i)

            if c == input_text then
                if mode == "normal" then
                    doc():set_selection(l1, i - 1)
                elseif mode == "visual" then
                    doc():set_selection(l1, i - 1, l2, c2)
                end

                return
            end
        end

        core.error("Can't find " .. input_text)
    end,
    record_macro = function(input_text)
        assert(macros.state == "stopped")

        macros.state = "recording"
        macros.buffers[input_text] = {}
        macros.key = input_text
        core.log(string.format("Recording @%s", input_text))
    end,
    play_macro = function(input_text)
        if input_text == "@" then
            input_text = macros.previously_played
        end

        local buffer = macros.buffers[input_text]
        if not buffer then
            core.error(string.format("No macro @%s", input_text))
            return
        end

        assert(macros.state == "stopped")
        macros.state = "playing"

        for _, ev in ipairs(buffer) do
            core_on_event(table.unpack(ev))
            core.root_view:update()
        end

        macros.state = "stopped"
        macros.previously_played = input_text
    end,
    replace = function(input_text)
        if visual_submode == "block" then
            -- TODO
            return
        end

        local l1, c1, l2, c2 = get_selection(doc())

        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)
        local sub = text:gsub("[^\n]", input_text)
        doc():insert(l1, c1, sub)

        if mode == "visual" then
            doc():set_selection(l1, c1)
            normal_mode()
        end
    end,
    set_mark = function(input_text)
        local line, col = doc():get_selection()
        dv().vim_marks[input_text] = {line, col}
        core.log("Set mark: " .. input_text)
    end,
    goto_mark = function(input_text)
        local l1, c1, l2, c2 = doc():get_selection()

        local mark = dv().vim_marks[input_text]
        if mark then
            if doc():has_selection() then
                doc():set_selection(mark[1], mark[2], l2, c2)
            else
                doc():set_selection(mark[1], mark[2])
            end

            dv().vim_marks["`"] = {l1, c1}
        else
            core.error("Mark not set: " .. input_text)
        end
    end
}

local vim_search = {}

function vim_search.init_args(doc, line, col, text, opt)
    opt = opt or {}
    line, col = doc:sanitize_position(line, col)

    if opt.no_case then
        if opt.pattern then
            text =
                text:gsub(
                "%%?.",
                function()
                    if str:sub(1, 1) == "%" then
                        return str
                    end
                    return str:lower()
                end
            )
        else
            text = text:lower()
        end
    end

    return doc, line, col, text, opt
end

function vim_search.find(doc, line, col, text, opt)
    doc, line, col, text, opt = vim_search.init_args(doc, line, col, text, opt)

    for line = line, #doc.lines do
        local line_text = doc.lines[line]
        if opt.no_case then
            line_text = line_text:lower()
        end
        local s = line_text:find(text, col, not opt.pattern)
        if s then
            return line, s
        end
        col = 1
    end

    if opt.wrap then
        opt = {no_case = opt.no_case, pattern = opt.pattern}
        return vim_search.find(doc, 1, 1, text, opt)
    end
end

local function string_rfind(str, pattern, init, plain)
    str = str:sub(1, init)
    local i = init
    local s, e

    -- lol
    while not s and i ~= 0 do
        s, e = str:find(pattern, i, plain)
        i = i - 1
    end

    return s, e
end

function vim_search.find_backwards(doc, line, col, text, opt)
    doc, line, col, text, opt = vim_search.init_args(doc, line, col, text, opt)

    local line_text = doc.lines[line]
    for line = line, 1, -1 do
        if opt.no_case then
            line_text = line_text:lower()
        end
        local s = string_rfind(line_text, text, col, not opt.pattern)
        if s then
            return line, s
        end
        if line > 1 then
            line_text = doc.lines[line - 1]
            col = #line_text
        end
    end

    if opt.wrap then
        opt = {no_case = opt.no_case, pattern = opt.pattern}
        return vim_search.find_backwards(doc, #doc.lines, math.huge, text, opt)
    end
end

local modkey_map = {
    ["left ctrl"] = "ctrl",
    ["right ctrl"] = "ctrl",
    ["left shift"] = "shift",
    ["right shift"] = "shift",
    ["left alt"] = "alt",
    ["right alt"] = "altgr"
}

local modkeys = {"ctrl", "alt", "altgr", "shift"}

local function key_to_stroke(k)
    local stroke = ""
    for _, mk in ipairs(modkeys) do
        if keymap.modkeys[mk] then
            stroke = stroke .. mk .. "+"
        end
    end
    return stroke .. k
end

function keymap.on_key_pressed(k)
    if mini_mode then
        if k == "escape" then
            mini_mode = nil
            return true
        else
            return false
        end
    end

    local mk = modkey_map[k]
    if mk then
        keymap.modkeys[mk] = true
        -- work-around for windows where `altgr` is treated as `ctrl+alt`
        if mk == "altgr" then
            keymap.modkeys["ctrl"] = false
        end

        return false
    end

    local stroke = key_to_stroke(k)

    -- check for normal+0, and any other command with numbers
    if not (n_repeat ~= 0 and string.find("0123456789", stroke, 1, true)) then
        local commands
        if mode == "insert" then
            commands = keymap.map[stroke]
        elseif mode == "normal" then
            commands = keymap.map["normal" .. stroke_combo_string .. " " .. stroke]
        elseif mode == "visual" then
            commands = keymap.map["visual" .. stroke_combo_string .. " " .. stroke]
        else
            core.error('Cannot handle key in unknown mode "%s"', mode)
        end

        if commands then
            for _, cmd in ipairs(commands) do
                local performed = command.perform(cmd)
                if performed then
                    if not stroke_combo_string:find("#", 1, true) then
                        for n = 1, n_repeat - 1 do
                            command.perform(cmd)
                        end
                    end

                    n_repeat = 0
                    stroke_combo_string = ""
                    stroke_combo_loc = stroke_combo_tree[mode]
                    break
                end
            end

            return true
        end
    end

    if mode == "normal" or mode == "visual" then
        local num = tonumber(stroke, 10)
        if num ~= nil then
            n_repeat = n_repeat * 10 + num
            stroke = "#"

            if stroke_combo_string == "" then
                return true
            end
        end

        if stroke_combo_string:sub(-1) == "#" and stroke == "#" then
            return true
        end

        stroke_combo_loc = stroke_combo_loc[stroke]
        if stroke_combo_loc then
            stroke_combo_string = stroke_combo_string .. " " .. stroke
        else
            stroke_combo_loc = stroke_combo_tree[mode]
            stroke_combo_string = ""
            n_repeat = 0
        end

        return true
    end

    return false
end

local function mouse_selection(doc, clicks, l1, c1, l2, c2)
    local swap = l2 < l1 or l2 == l1 and c2 <= c1
    if swap then
        l1, c1, l2, c2 = l2, c2, l1, c1
    end

    if clicks == 2 then
        l1, c1 = translate.start_of_word(doc, l1, c1)
        l2, c2 = translate.end_of_word(doc, l2, c2)

        if mode ~= "insert" then
            c2 = c2 - 1
        end
    elseif clicks == 3 then
        if l2 == #doc.lines and doc.lines[#doc.lines] ~= "\n" then
            doc:insert(math.huge, math.huge, "\n")
        end
        l1, c1, l2, c2 = l1, 1, l2, math.huge
    end

    if mode ~= "insert" and (l1 ~= l2 or c1 ~= c2) then
        visual_mode()

        if clicks == 3 then
            visual_submode = "line"
        end
    end

    if swap then
        return l2, c2, l1, c1
    end
    return l1, c1, l2, c2
end

local previous_visual_submode

local command_view_enter = CommandView.enter
function CommandView:enter(text, submit, suggest, cancel)
    previous_visual_submode = visual_submode
    insert_mode()
    command_view_enter(self, text, submit, suggest, cancel)
end

local command_view_exit = CommandView.exit
function CommandView:exit(submitted, inexplicit)
    if core.last_active_view.doc and core.last_active_view.doc:has_selection() then
        visual_mode(previous_visual_submode)
    else
        normal_mode()
    end

    command_view_exit(self, submitted, inexplicit)
end

local doc_undo = Doc.undo
function Doc:undo()
    doc_undo(self)

    if mode ~= "insert" then
        local line, col = self:get_selection()
        self:set_selection(line, col)
    end
end

local docview_new = DocView.new
function DocView:new(doc)
    DocView.super.new(self)
    docview_new(self, doc)
    self.vim_marks = {}
end

function DocView:on_mouse_pressed(button, x, y, clicks)
    local caught = DocView.super.on_mouse_pressed(self, button, x, y, clicks)
    if caught then
        return
    end
    if keymap.modkeys["shift"] then
        if clicks == 1 then
            if mode == "normal" then
                visual_mode()
            end

            local line1, col1 = select(3, self.doc:get_selection())
            local line2, col2 = self:resolve_screen_position(x, y)
            self.doc:set_selection(line2, col2, line1, col1)
        end
    else
        if mode == "visual" then
            normal_mode()
        end
        local line, col = self:resolve_screen_position(x, y)
        self.doc:set_selection(mouse_selection(self.doc, clicks, line, col, line, col))
        self.mouse_selecting = {line, col, clicks = clicks}
    end

    if not is_lite_xl then
        self.blink_timer = 0
    end
end

function DocView:on_mouse_moved(x, y, ...)
    DocView.super.on_mouse_moved(self, x, y, ...)

    if self:scrollbar_overlaps_point(x, y) or self.dragging_scrollbar then
        self.cursor = "arrow"
    else
        self.cursor = "ibeam"
    end

    if self.mouse_selecting then
        local l1, c1 = self:resolve_screen_position(x, y)
        local l2, c2 = table.unpack(self.mouse_selecting)

        if mode == "normal" and (l1 ~= l2 or c1 ~= c2) then
            visual_mode()
        end

        local clicks = self.mouse_selecting.clicks
        self.doc:set_selection(mouse_selection(self.doc, clicks, l1, c1, l2, c2))
    end
end

local docview_on_mouse_released = DocView.on_mouse_released
function DocView:on_mouse_released(button)
    docview_on_mouse_released(self, button)
    local line, col = self.doc:get_selection()

    if col == #self.doc.lines[line] then
        if self.doc:has_selection() then
            local l1, c1, l2, c2 = self.doc:get_selection()
            self.doc:set_selection(l1, c1 - 1, l2, c2)
        else
            self.doc:set_selection(line, col - 1)
        end
    end
end

local on_text_input = DocView.on_text_input
function DocView:on_text_input(text)
    if mini_mode then
        local fn = mini_mode
        mini_mode = nil
        fn(text)
    elseif mode == "insert" then
        on_text_input(self, text)
    end
end

local draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(idx, x, y)
    local line1, col1, line2, col2 = self.doc:get_selection(true)

    local tx, ty = x, y + self:get_line_text_y_offset()
    local font = self:get_font()

    if substitute.display and dv() ~= self and idx >= line1 and idx <= line2 and not self:is(CommandView) then
        local g = substitute.mods:find("g", 1, true)
        local remaining = self.doc.lines[idx]

        ::top::
        local s, e = remaining:find(substitute.from, 1, true)
        if s then
            tx = renderer.draw_text(font, remaining:sub(1, s - 1), tx, ty, style.syntax.comment)
            tx = renderer.draw_text(font, remaining:sub(s, e), tx, ty, style.syntax.keyword2)
            tx = renderer.draw_text(font, substitute.to, tx, ty, style.syntax["function"])
            remaining = remaining:sub(e + 1)

            if g then
                goto top
            end
        end

        renderer.draw_text(font, remaining, tx, ty, style.syntax.comment)
    else
        draw_line_text(self, idx, x, y)
    end
end

local function draw_box(x, y, w, h, pad, color)
    local r = renderer.draw_rect
    pad = pad * math.ceil(SCALE)
    r(x, y, w, pad, color)
    r(x, y + h - pad, w, pad, color)
    r(x, y + pad, pad, h - pad * 2, color)
    r(x + w - pad, y + pad, pad, h - pad * 2, color)
end

function DocView:draw_line_body(idx, x, y)
    local line, col = self.doc:get_selection()
    local line1, col1, line2, col2 = self.doc:get_selection(true)

    -- draw selection
    if core.active_view == self and idx >= line1 and idx <= line2 then
        local text = self.doc.lines[idx]

        local x1
        local x2
        if visual_submode == "block" then
            if col1 > col2 then
                col1, col2 = col2, col1
            end

            x1 = x + self:get_col_x_offset(idx, col1)
            x2 = x + self:get_col_x_offset(idx, col2 + 1)
        elseif visual_submode == "line" then
            x1 = x
            x2 = x + self:get_col_x_offset(idx, #text + 1)
        else
            if line1 ~= idx then
                col1 = 1
            end
            if line2 ~= idx then
                col2 = #text + 1
            end

            x1 = x + self:get_col_x_offset(idx, col1)

            if mode == "visual" and line2 == idx then
                x2 = x + self:get_col_x_offset(idx, col2 + 1)
            else
                x2 = x + self:get_col_x_offset(idx, col2)
            end
        end

        local lh = self:get_line_height()
        renderer.draw_rect(x1, y, x2 - x1, lh, style.selection)
    end

    -- draw line highlight
    if
        config.highlight_current_line and mode ~= "visual" and not self.doc:has_selection() and line == idx and
            core.active_view == self
     then
        self:draw_line_highlight(x + self.scroll.x, y)
    end

    -- draw search results
    if should_highlight and not self:is(CommandView) then
        local lh = self:get_line_height()

        local text = self.doc.lines[idx]
        if search_text == search_text:lower() then
            text = text:lower()
        end

        local last_col = 1
        local start_col, end_col = text:find(search_text, last_col, true)

        while start_col do
            local x1 = x + self:get_col_x_offset(idx, start_col)
            local x2 = x + self:get_col_x_offset(idx, end_col + 1)
            draw_box(x1, y, x2 - x1, lh, 2, style.text)

            last_col = end_col + 1
            start_col, end_col = text:find(search_text, last_col, true)
        end
    end

    -- draw line's text
    self:draw_line_text(idx, x, y)

    local blink_period
    local timer

    if is_lite_xl then
        blink_period = config.blink_period
        timer = (core.blink_timer - core.blink_start) % blink_period
    else
        blink_period = 0.8
        timer = self.blink_timer
    end

    -- draw caret
    if line == idx and core.active_view == self and timer < blink_period / 2 and system.window_has_focus() then
        local lh = self:get_line_height()
        local x1 = x + self:get_col_x_offset(line, col)

        if mode == "normal" or mode == "visual" then
            local w = self:get_font():get_width " "

            if mode == "visual" then
                local visual_caret_color = style.visual_caret or style.syntax.string
                renderer.draw_rect(x1, y, w, lh, visual_caret_color)
            else
                renderer.draw_rect(x1, y, w, lh, style.caret)
            end

            local ch = self.doc:get_text(line, col, line, col + 1)
            renderer.draw_text(self:get_font(), ch, x1, y + self:get_line_text_y_offset(), style.background)
        else
            renderer.draw_rect(x1, y, style.caret_width, lh, style.caret)
        end
    end
end

function DocView:draw_line_gutter(idx, x, y)
    if not enable_linenum then
        return
    end

    local color = style.line_number
    local line1, _, line2, _ = self.doc:get_selection()

    local ln = idx
    if relative_line_mode and idx ~= line1 and self == core.active_view and mode ~= "insert" then
        ln = math.abs(idx - line1)
    end

    if line1 > line2 then
        line1, line2 = line2, line1
    end

    if idx >= line1 and idx <= line2 then
        color = style.line_number2
    end

    local yoffset = self:get_line_text_y_offset()
    x = x + style.padding.x
    renderer.draw_text(self:get_font(), ln, x, y + yoffset, color)
end

local get_gutter_width = DocView.get_gutter_width
function DocView:get_gutter_width()
    if enable_linenum then
        return get_gutter_width(self)
    end

    return style.padding.x
end

if is_lite_xl then
    function DocView:draw_overlay()
        -- pass
    end
end

local status_view_get_items = StatusView.get_items
function StatusView:get_items()
    local left, right = status_view_get_items(self)

    if n_repeat ~= 0 then
        if next(left) then
            table.insert(left, style.dim)
            table.insert(left, self.separator)
        end

        table.insert(left, style.text)
        table.insert(left, tostring(n_repeat))
    end

    if mode == "normal" then
        return left, right
    end

    if next(left) then
        table.insert(left, style.dim)
        table.insert(left, self.separator)
    end

    table.insert(left, style.accent or style.text)
    if visual_submode then
        table.insert(left, string.format("-- %s %s --", mode, visual_submode))
    else
        table.insert(left, string.format("-- %s --", mode))
    end

    if mode == "visual" and doc() then
        table.insert(left, style.text)
        table.insert(left, self.separator)

        local l1, c1, l2, c2 = doc():get_selection(true)
        local lines = math.abs(l1 - l2) + 1

        if visual_submode == "block" then
            table.insert(left, string.format("%dx%d", math.abs(l1 - l2) + 1, math.abs(c1 - c2) + 1))
        elseif visual_submode == "line" then
            if lines == 1 then
                table.insert(left, "1 line")
            else
                table.insert(left, string.format("%d lines", lines))
            end
        else
            if lines == 1 then
                if c1 == c2 then
                    table.insert(left, "1 char")
                else
                    table.insert(left, string.format("%d chars", math.abs(c1 - c2) + 1))
                end
            else
                local count = 0
                for line = l1 + 1, l2 - 1 do
                    count = count + #doc().lines[line] - 1
                end
                count = count + #doc().lines[l1] - c1 + 1
                count = count + c2 - 1
                table.insert(left, string.format("%d chars, %d lines", count, lines))
            end
        end
    end

    return left, right
end

local set_active_view = core.set_active_view
function core.set_active_view(view)
    local av = core.active_view
    set_active_view(view)

    if av:is(DocView) and not av:is(CommandView) then
        av.vim_last_selection = table.pack(av.doc:get_selection())
    end

    if av ~= view and view:is(DocView) then
        if view.vim_last_selection then
            view.doc:set_selection(table.unpack(view.vim_last_selection))
            return
        end

        local min, max = view:get_visible_line_range()
        local line = view.doc:get_selection()

        if line < min or line > max then
            view.doc:set_selection(min + math.floor((max - min) / 2), 1)
        end
    end
end

local function char_type(char)
    if char:find "%s" then
        return "whitespace"
    elseif char:find "%w" then
        return "word"
    else
        return "other"
    end
end

local vim_translate = {}

function vim_translate.goto_first_line(doc, line, col, dv)
    dv.vim_marks["`"] = {line, col}

    if n_repeat ~= 0 then
        local n = n_repeat
        n_repeat = 0
        return n, 1
    else
        return 1, 1
    end
end

function vim_translate.goto_line(doc, line, col, dv)
    dv.vim_marks["`"] = {line, col}

    if n_repeat ~= 0 then
        local n = n_repeat
        n_repeat = 0
        return n, 1
    else
        return #doc.lines, 1
    end
end

function vim_translate.previous_char(doc, line, col)
    local line2, col2 = line, col

    repeat
        line2, col2 = doc:position_offset(line2, col2, -1)
    until not common.is_utf8_cont(doc:get_char(line2, col2))

    if line2 ~= line then
        return line, col
    else
        return line2, col2
    end
end

function vim_translate.next_char(doc, line, col)
    local line2, col2 = line, col

    repeat
        line2, col2 = doc:position_offset(line2, col2, 1)
    until not common.is_utf8_cont(doc:get_char(line2, col2))

    if line2 ~= line then
        return line, col
    else
        if col2 == #doc.lines[line2] then
            col2 = col2 - 1
        end

        return line2, col2
    end
end

function vim_translate.previous_line(doc, line, col, dv)
    local line2, col2 = DocView.translate.previous_line(doc, line, col, dv)
    if col2 >= #doc.lines[line2] then
        col2 = #doc.lines[line2] - 1
    end

    return line2, col2
end

function vim_translate.next_line(doc, line, col, dv)
    local line2, col2 = DocView.translate.next_line(doc, line, col, dv)
    if col2 >= #doc.lines[line2] then
        col2 = #doc.lines[line2] - 1
    end

    return line2, col2
end

function vim_translate.start_of_word(doc, line, col)
    local t = char_type(doc:get_char(line, col))
    if t == "whitespace" then
        core.error "Unexpected whitespace"
        return line, col
    end

    while true do
        local line2, col2 = doc:position_offset(line, col, -1)
        local char = doc:get_char(line2, col2)
        if char_type(char) ~= t then
            break
        end
        line, col = line2, col2
    end

    return line, col
end

function vim_translate.end_of_word(doc, line, col)
    local t = char_type(doc:get_char(line, col))
    if t == "whitespace" then
        core.error "Unexpected whitespace"
        return line, col
    end

    while true do
        local line2, col2 = doc:position_offset(line, col, 1)
        local char = doc:get_char(line2, col2)
        if char_type(char) ~= t then
            break
        end
        line, col = line2, col2
    end

    return line, col
end

function vim_translate.previous_word(doc, line, col)
    local anchor = line
    while line > 1 or col > 1 do
        local char = doc:get_char(line, col)
        local prev_line, prev_col = doc:position_offset(line, col, -1)
        if anchor - prev_line > 1 then
            break
        end

        local prev = doc:get_char(prev_line, prev_col)

        if char_type(prev) ~= "whitespace" then
            return vim_translate.start_of_word(doc, prev_line, prev_col)
        end

        line, col = prev_line, prev_col
    end

    return line, col
end

function vim_translate.next_word(doc, line, col)
    local anchor = line
    local end_line, end_col = translate.end_of_doc(doc, line, col)

    while line < end_line or col < end_col do
        local char = doc:get_char(line, col)
        local next_line, next_col = doc:position_offset(line, col, 1)
        if next_line - anchor > 1 then
            break
        end

        local next = doc:get_char(next_line, next_col)

        if char_type(next) ~= "whitespace" and char_type(char) ~= char_type(next) then
            return next_line, next_col
        end

        line, col = next_line, next_col
    end

    return line, col
end

function vim_translate.next_word_end(doc, line, col)
    local end_line, end_col = translate.end_of_doc(doc, line, col)

    while line < end_line or col < end_col do
        local char = doc:get_char(line, col)
        local next_line, next_col = doc:position_offset(line, col, 1)
        local next = doc:get_char(next_line, next_col)

        if char_type(next) ~= "whitespace" then
            return vim_translate.end_of_word(doc, next_line, next_col)
        end

        line, col = next_line, next_col
    end

    return line, col
end

function vim_translate.end_of_line(doc, line, col)
    return line, #doc.lines[line] - 1
end

function vim_translate.first_non_blank(doc, line, col)
    local text = doc:get_text(line, 1, line + 1, 1)

    local i = text:find "%S"
    if i then
        return line, i
    end

    return line, math.huge
end

function vim_translate.other_delim(doc, line, col)
    local line2, col2 = line, col
    local delim = doc:get_text(line, col, line, col + 1)

    local forward = {
        ["("] = ")",
        ["["] = "]",
        ["{"] = "}",
        ["<"] = ">"
    }

    local other = forward[delim]
    if other then
        local start = col + 1
        local count = 1

        while line <= #doc.lines do
            local text = doc:get_text(line, 1, line, math.huge)

            for i = start, #text do
                local c = text:sub(i, i)

                if c == delim then
                    count = count + 1
                elseif c == other then
                    count = count - 1
                end

                if count == 0 then
                    return line, i
                end
            end

            start = 1
            line = line + 1
        end
    else
        local backward = {
            [")"] = "(",
            ["]"] = "[",
            ["}"] = "{",
            [">"] = "<"
        }

        other = backward[delim]
        if other then
            local start = col - 1
            local count = 1

            local text = doc:get_text(line, 1, line, math.huge)
            while line > 0 do
                for i = start, 1, -1 do
                    local c = text:sub(i, i)

                    if c == delim then
                        count = count + 1
                    elseif c == other then
                        count = count - 1
                    end

                    if count == 0 then
                        return line, i
                    end
                end

                line = line - 1
                text = doc:get_text(line, 1, line, math.huge)
                start = #text
            end
        end
    end

    -- core.error "No matching item found"
    return line2, col2
end

function vim_translate.page_down(doc, line, col, dv)
    local delta = dv.size.y / 2
    dv.scroll.to.y = dv.scroll.to.y + delta
    line = common.clamp(line + math.floor(delta / dv:get_line_height()), 1, #doc.lines)
    return line, math.min(col, #doc.lines[line] - 1)
end

function vim_translate.page_up(doc, line, col, dv)
    local delta = dv.size.y / 2
    dv.scroll.to.y = dv.scroll.to.y - delta
    line = common.clamp(line - math.floor(delta / dv:get_line_height()), 1, #doc.lines)
    return line, math.min(col, #doc.lines[line] - 1)
end

function vim_translate.visible_top(doc, line, col, dv)
    local min = dv:get_visible_line_range()
    return min, 1
end

function vim_translate.visible_middle(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return math.floor((max + min) / 2), 1
end

function vim_translate.visible_bottom(doc, line, col, dv)
    local _, max = dv:get_visible_line_range()
    return max, 1
end

local commands = {
    ["vim:debug"] = function()
        core.log("config.indent_size: " .. config.indent_size)
    end,
    ["vim:use-user-stroke-combos"] = function()
        local function merge_trees(t1, t2)
            for k, v in pairs(t2) do
                if t1[k] then
                    merge_trees(t1[k], v)
                else
                    t1[k] = v
                end
            end
        end

        merge_trees(stroke_combo_tree, config.vim_stroke_combos or {})
    end,
    ["vim:insert-mode"] = insert_mode,
    ["vim:escape"] = function()
        if core.active_view:is(CommandView) then
            command.perform "command:escape"
            return
        end

        if not doc() then
            normal_mode()
            return
        end

        if visual_block_state.current == "recording" then
            local final_location = table.pack(doc():get_selection())
            visual_block_state.current = "playing"

            local l1, c1, l2, c2 = table.unpack(visual_block_state.selection)
            for line = l1 + 1, l2 do
                doc():set_selection(line, c1)
                for _, ev in ipairs(visual_block_state.event_buffer) do
                    core_on_event(table.unpack(ev))
                    core.root_view:update()
                end
            end

            visual_block_state.current = "stopped"
            doc():set_selection(table.unpack(final_location))
        end

        normal_mode()
        doc():move_to(vim_translate.previous_char, dv())
    end,
    ["vim:force-normal-mode"] = function()
        normal_mode()
        n_repeat = 0
    end,
    ["vim:visual-mode"] = visual_mode,
    ["vim:visual-line-mode"] = function()
        visual_mode "line"
    end,
    ["vim:visual-block-mode"] = function()
        visual_mode "block"
    end,
    ["vim:exit-visual-mode"] = function()
        command.perform "doc:select-none"
        normal_mode()
    end,
    ["vim:exec"] = function()
        core.command_view:set_text(previous_exec_command, true)
        core.command_view:enter(
            "vim",
            function(text)
                previous_exec_command = text

                if text:sub(1, 2) == "s/" then
                    local line, col = doc():get_selection()
                    local l1, _, l2 = doc():get_selection(true)

                    for i = l1, l2 do
                        local replace
                        if substitute.mods:find("g", 1, true) then
                            replace = doc().lines[i]:gsub(substitute.from, substitute.to)
                        else
                            replace = doc().lines[i]:gsub(substitute.from, substitute.to, 1)
                        end
                        doc():insert(i + 1, 1, replace)
                        doc():remove(i, 1, i + 1, 1)
                    end

                    substitute.from = ""
                    substitute.to = ""
                    substitute.mods = ""
                    substitute.display = false
                    doc():set_selection(line, col)
                    normal_mode()
                else
                    local cmd = exec_commands[text]
                    if cmd then
                        command.perform(cmd)
                    else
                        core.error('Unknown command ":%s"', text)
                    end
                end
            end,
            function(text)
                if text:sub(1, 2) == "s/" then
                    local split = {}
                    for str in text:gmatch "/([^/]*)" do
                        table.insert(split, str)
                    end
                    substitute.from = split[1] or ""
                    substitute.to = split[2] or ""
                    substitute.mods = split[3] or ""
                    substitute.display = true
                else
                    substitute.from = ""
                    substitute.to = ""
                    substitute.mods = ""
                    substitute.display = false
                end
            end,
            function(explicit)
                substitute.from = ""
                substitute.to = ""
                substitute.mods = ""
                substitute.display = false
            end
        )
    end,
    ["vim:find-command"] = function()
        command.perform "core:find-command"
        insert_mode()
    end,
    ["vim:find-file"] = function()
        command.perform "core:find-file"
        insert_mode()
    end,
    ["vim:nohl"] = function()
        should_highlight = false
    end,
    ["vim:relative-line"] = function()
        relative_line_mode = not relative_line_mode
    end,
    ["vim:linenum"] = function()
        enable_linenum = not enable_linenum
    end
}

local doc_commands = {
    ["vim:change-end-of-line"] = function()
        doc():select_to(translate.end_of_line, dv())
        command.perform "doc:cut"
        insert_mode()
    end,
    ["vim:change-line"] = function()
        local line = doc():get_selection()
        doc():set_selection(line, 1, line, math.huge)
        command.perform "doc:cut"
        insert_mode()
    end,
    ["vim:change-selection"] = function()
        local selection = table.pack(doc():get_selection(true))
        command.perform "vim:cut"
        if visual_submode == "block" then
            assert(visual_block_state.current == "stopped")
            visual_block_state.current = "recording"
            visual_block_state.event_buffer = {}
            visual_block_state.selection = selection
        end
        insert_mode()
    end,
    ["vim:change-word"] = function()
        doc():select_to(translate.next_word_end, dv())
        command.perform "doc:cut"
        insert_mode()
    end,
    ["vim:copy"] = function()
        local l1, c1, l2, c2 = get_selection(doc())
        local text = doc():get_text(l1, c1, l2, c2)
        if visual_submode == "line" then
            text = text .. "\n"
        end

        system.set_clipboard(text)
        doc():set_selection(l1, c1)
        normal_mode()
    end,
    ["vim:copy-line"] = function()
        local line = doc():get_selection()
        local text = doc():get_text(line, 1, line + 1, 1)
        system.set_clipboard(text)
    end,
    ["vim:cut"] = function()
        if visual_submode == "block" then
            local l1, c1, l2, c2 = doc():get_selection(true)

            if c1 > c2 then
                c1, c2 = c2, c1
            end

            c2 = c2 + 1

            local lines = {}
            for line = l1, l2 do
                table.insert(lines, doc():get_text(line, c1, line, c2))
                doc():remove(line, c1, line, c2)
            end

            system.set_clipboard(table.concat(lines, "\n"))
            doc():set_selection(l1, c1)
        else
            local l1, c1, l2, c2 = get_selection(doc())
            local text = doc():get_text(l1, c1, l2, c2)
            system.set_clipboard(text)
            doc():set_selection(l1, c1)
            doc():remove(l1, c1, l2, c2)
        end
    end,
    ["vim:delete-char"] = function()
        command.perform "vim:cut"
    end,
    ["vim:delete-end-of-line"] = function()
        doc():select_to(translate.end_of_line, dv())
        command.perform "doc:cut"
    end,
    ["vim:delete-lines"] = function()
        local line = doc():get_selection()
        if n_repeat ~= 0 then
            doc():set_selection(line, 1, line + n_repeat, 1)
            n_repeat = 0
        else
            doc():set_selection(line, 1, line + 1, 1)
        end

        command.perform "doc:cut"
    end,
    ["vim:delete-selection"] = function()
        command.perform "vim:cut"

        if visual_submode == "line" then
            local line = doc():get_selection()
            doc():remove(line, 1, line + 1, 1)
        end

        normal_mode()
    end,
    ["vim:find-char"] = function()
        mini_mode = mini_mode_callbacks.find
    end,
    ["vim:find-char-backwards"] = function()
        mini_mode = mini_mode_callbacks.find_backwards
    end,
    ["vim:find-char-til"] = function()
        mini_mode = mini_mode_callbacks.find_til
    end,
    ["vim:find-char-til-backwards"] = function()
        mini_mode = mini_mode_callbacks.find_til_backwards
    end,
    ["vim:goto-mark"] = function()
        mini_mode = mini_mode_callbacks.goto_mark
    end,
    ["vim:indent-left"] = function()
        local l1, c1, l2 = doc():get_selection(true)

        for i = l1, l2 do
            local text = doc():get_text(i, 1, i, math.huge)
            doc():remove(i, 1, i, math.huge)

            if config.tab_type == "soft" then
                if text:match("^" .. string.rep(" ", config.indent_size)) then
                    doc():insert(i, 1, text:sub(config.indent_size + 1))
                end
            else
                if text:match "^\t" then
                    doc():insert(i, 1, text:sub(2))
                end
            end
        end

        doc():set_selection(l1, c1)
        normal_mode()
    end,
    ["vim:indent-right"] = function()
        local l1, c1, l2 = doc():get_selection(true)

        for i = l1, l2 do
            local text = doc():get_text(i, 1, i, math.huge)
            doc():remove(i, 1, i, math.huge)

            if config.tab_type == "soft" then
                doc():insert(i, 1, string.rep(" ", config.indent_size) .. text)
            else
                doc():insert(i, 1, "\t" .. text)
            end
        end

        doc():set_selection(l1, c1)
        normal_mode()
    end,
    ["vim:insert-end-of-line"] = function()
        command.perform "doc:move-to-end-of-line"
        insert_mode()
    end,
    ["vim:insert-from-visual"] = function()
        local l1, c1, l2, c2 = doc():get_selection(true)
        if visual_submode == "block" then
            assert(visual_block_state.current == "stopped")
            visual_block_state.current = "recording"
            visual_block_state.event_buffer = {}
            visual_block_state.selection = table.pack(l1, c1, l2, c2)
            doc():set_selection(l1, c1)
            insert_mode()
        end
    end,
    ["vim:insert-next-char"] = function()
        local line, col = doc():get_selection()
        local next_line, next_col = translate.next_char(doc(), line, col)

        if line ~= next_line then
            doc():move_to(translate.end_of_line, dv())
        else
            doc():move_to(translate.next_char, dv())
        end

        insert_mode()
    end,
    ["vim:insert-newline-above"] = function()
        command.perform "doc:newline-above"
        insert_mode()
    end,
    ["vim:insert-newline-below"] = function()
        command.perform "doc:newline-below"
        insert_mode()
    end,
    ["vim:join-lines"] = function()
        command.perform "doc:join-lines"
        normal_mode()
    end,
    ["vim:lowercase"] = function()
        local l1, c1, l2, c2 = get_selection(doc())
        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)
        doc():insert(l1, c1, text:lower())
        doc():set_selection(l1, c1)
        normal_mode()
    end,
    ["vim:paste"] = function()
        local clipboard = system.get_clipboard():gsub("\r", "")

        if mode == "visual" then
            if visual_submode == "line" and clipboard:sub(-1) == "\n" then
                clipboard = clipboard:sub(1, #clipboard - 1)
            end
            command.perform "vim:cut"
            doc():text_input(clipboard)
            normal_mode()
        elseif clipboard:sub(-1) == "\n" then
            local line = doc():get_selection()
            doc():insert(line, math.huge, "\n" .. clipboard:sub(1, -2))
            doc():set_selection(line + 1, 1)
        else
            local line, col = doc():get_selection()
            doc():insert(line, col + 1, clipboard)
            doc():move_to(#clipboard)
        end
    end,
    ["vim:paste-before"] = function()
        local clipboard = system.get_clipboard():gsub("\r", "")

        if mode == "visual" then
            command.perform "vim:cut"
            doc():text_input(clipboard)
            normal_mode()
        elseif clipboard:sub(-1) == "\n" then
            local line = doc():get_selection()
            doc():insert(line, 1, clipboard)
            doc():set_selection(line, 1)
        else
            local line, col = doc():get_selection()
            doc():insert(line, col, clipboard)
            doc():move_to(#clipboard)
        end
    end,
    ["vim:play-macro"] = function()
        if n_repeat ~= 0 then
            local n = n_repeat
            mini_mode = function(text_input)
                for i = 1, n do
                    mini_mode_callbacks.play_macro(text_input)
                end
            end
        else
            mini_mode = mini_mode_callbacks.play_macro
        end
    end,
    ["vim:replace"] = function()
        mini_mode = mini_mode_callbacks.replace
    end,
    ["vim:scroll-line-down"] = function()
        local lh = dv():get_line_height()
        dv().scroll.to.y = dv().scroll.to.y + lh
    end,
    ["vim:scroll-line-up"] = function()
        local lh = dv():get_line_height()
        dv().scroll.to.y = math.max(0, dv().scroll.to.y - lh)
    end,
    ["vim:save-and-close"] = function()
        command.perform "doc:save"
        command.perform "root:close"
    end,
    ["vim:search"] = function()
        local line, col = doc():get_selection()

        core.command_view:set_text(previous_search_command, true)
        core.command_view:enter(
            "Search",
            function(text)
                assert(search_text == text)
                previous_search_command = text

                local l1, c1 =
                    vim_search.find(doc(), line, col + 1, text, {wrap = true, no_case = text == text:lower()})
                if l1 then
                    doc():set_selection(l1, c1)
                else
                    core.error(string.format('Search failed: "%s"', text))
                end
            end,
            function(text)
                search_text = text
                should_highlight = text ~= ""
            end,
            function(explicit)
                if explicit or search_text == "" then
                    should_highlight = false
                end
            end
        )
    end,
    ["vim:search-next"] = function()
        if previous_search_command ~= "" then
            if search_text ~= previous_search_command then
                search_text = previous_search_command
            end

            should_highlight = true
            local line, col = doc():get_selection()
            local l1, c1 =
                vim_search.find(
                doc(),
                line,
                col + 1,
                previous_search_command,
                {wrap = true, no_case = previous_search_command == previous_search_command:lower()}
            )
            if l1 then
                doc():set_selection(l1, c1)
            else
                core.error(string.format('Search failed: "%s"', previous_search_command))
            end
        else
            core.error "No previous find"
        end
    end,
    ["vim:search-previous"] = function()
        if previous_search_command ~= "" then
            if search_text ~= previous_search_command then
                search_text = previous_search_command
            end

            should_highlight = true
            local line, col = doc():get_selection()
            local l1, c1 =
                vim_search.find_backwards(
                doc(),
                line,
                col - 1,
                previous_search_command,
                {wrap = true, no_case = previous_search_command == previous_search_command:lower()}
            )
            if l1 then
                doc():set_selection(l1, c1)
            else
                core.error(string.format('Search failed: "%s"', previous_search_command))
            end
        else
            core.error "No previous find"
        end
    end,
    ["vim:set-mark"] = function()
        mini_mode = mini_mode_callbacks.set_mark
    end,
    ["vim:sort-lines"] = function()
        if not doc():has_selection() then
            return
        end

        local l1, _, l2 = doc():get_selection(true)

        local lines = {}
        for i = l1, l2 do
            table.insert(lines, doc().lines[i])
        end

        table.sort(lines)

        doc():remove(l1, 1, l2, math.huge)
        doc():insert(l1, 1, table.concat(lines):sub(1, -2))

        normal_mode()
        doc():set_selection(l1, 1)
    end,
    ["vim:swap-case"] = function()
        local l1, c1, l2, c2 = get_selection(doc())
        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)

        local chars = {}
        for c in text:gmatch "." do
            table.insert(chars, c)
        end

        for k, c in pairs(chars) do
            if c:match "[A-Z]" then
                chars[k] = c:lower()
            else
                chars[k] = c:upper()
            end
        end

        doc():insert(l1, c1, table.concat(chars))

        if mode == "normal" then
            doc():set_selection(l1, c1 + 1)
        else
            doc():set_selection(l1, c1)
        end
    end,
    ["vim:toggle-record-macro"] = function()
        if macros.state == "recording" then
            macros.state = "stopped"

            local buffer = macros.buffers[macros.key]
            -- remove the first text input (if macro recorded in register 'q', remove the 'q' key event)
            assert(#buffer >= 2 and buffer[1][1] == "textinput" and buffer[2][1] == "keyreleased")
            table.remove(buffer, 1)
            table.remove(buffer, 1)

            core.log(string.format("Recorded @%s. (%d events)", macros.key, #buffer))
        else
            mini_mode = mini_mode_callbacks.record_macro
        end
    end,
    ["vim:uppercase"] = function()
        local l1, c1, l2, c2 = get_selection(doc())
        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)
        doc():insert(l1, c1, text:upper())
        doc():set_selection(l1, c1)
        normal_mode()
    end
}

local vim_translation_commands = {
    ["previous-char"] = vim_translate.previous_char,
    ["next-char"] = vim_translate.next_char,
    ["previous-word"] = vim_translate.previous_word,
    ["next-line"] = vim_translate.next_line,
    ["previous-line"] = vim_translate.previous_line,
    ["next-word"] = vim_translate.next_word,
    ["next-word-end"] = vim_translate.next_word_end,
    ["end-of-line"] = vim_translate.end_of_line,
    ["other-delim"] = vim_translate.other_delim,
    ["page-down"] = vim_translate.page_down,
    ["page-up"] = vim_translate.page_up,
    ["visible-top"] = vim_translate.visible_top,
    ["visible-middle"] = vim_translate.visible_middle,
    ["visible-bottom"] = vim_translate.visible_bottom,
    ["line"] = vim_translate.goto_line,
    ["first-line"] = vim_translate.goto_first_line,
    ["first-non-blank"] = vim_translate.first_non_blank
}

for name, fn in pairs(vim_translation_commands) do
    doc_commands["vim:move-to-" .. name] = function()
        doc():move_to(fn, dv())
    end

    doc_commands["vim:select-to-" .. name] = function()
        doc():select_to(fn, dv())
    end

    doc_commands["vim:delete-to-" .. name] = function()
        local l1, c1 = doc():get_selection(true)
        local l2, c2 = doc():position_offset(l1, c1, fn, dv())
        system.set_clipboard(doc():get_text(l1, c1, l2, c2))
        doc():delete_to(fn, dv())
    end

    doc_commands["vim:change-to-" .. name] = function()
        local l1, c1 = doc():get_selection(true)

        local l2, c2 = doc():position_offset(l1, c1, fn, dv())
        c2 = c2 + 1
        l2, c2 = doc():sanitize_position(l2, c2)

        system.set_clipboard(doc():get_text(l1, c1, l2, c2))
        doc():remove(l1, c1, l2, c2)

        if l1 > l2 or l1 == l2 and c1 > c2 then
            l1, c1 = l2, c2
        end

        doc():set_selection(l1, c1)
        insert_mode()
    end
end

command.add(nil, commands)
command.add("core.docview", doc_commands)

keymap.add {
    ["shift f3"] = "vim:debug",
    ["normal shift+f3"] = "vim:debug",
    ["visual shift+f3"] = "vim:debug",
    -- insert
    ["escape"] = "vim:escape",
    -- normal
    ["normal ctrl+p"] = "vim:find-file",
    ["normal ctrl+shift+p"] = "vim:find-command",
    ["normal ctrl+\\"] = "treeview:toggle",
    ["normal ctrl+s"] = "doc:save",
    ["normal escape"] = {"command:escape", "vim:force-normal-mode"},
    ["normal shift+;"] = "vim:exec",
    ["normal a"] = "vim:insert-next-char",
    ["normal shift+a"] = "vim:insert-end-of-line",
    ["normal c c"] = "vim:change-line",
    ["normal shift+c"] = "vim:change-end-of-line",
    ["normal c w"] = "vim:change-to-next-word-end",
    ["normal c e"] = "vim:change-to-next-word-end",
    ["normal d d"] = "vim:delete-lines",
    ["normal d w"] = "vim:delete-to-next-word",
    ["normal shift+d"] = "vim:delete-end-of-line",
    ["normal shift+h"] = "vim:move-to-visible-top",
    ["normal shift+m"] = "vim:move-to-visible-middle",
    ["normal shift+l"] = "vim:move-to-visible-bottom",
    ["normal i"] = "vim:insert-mode",
    ["normal o"] = "vim:insert-newline-below",
    ["normal shift+o"] = "vim:insert-newline-above",
    ["normal p"] = "vim:paste",
    ["normal shift+p"] = "vim:paste-before",
    ["normal g t"] = "root:switch-to-next-tab",
    ["normal g shift+t"] = "root:switch-to-previous-tab",
    ["normal v"] = "vim:visual-mode",
    ["normal shift+v"] = "vim:visual-line-mode",
    ["normal ctrl+v"] = "vim:visual-block-mode",
    ["normal x"] = "vim:delete-char",
    ["normal y y"] = "vim:copy-line",
    ["normal u"] = "doc:undo",
    ["normal ctrl+r"] = "doc:redo",
    ["normal r"] = "vim:replace",
    ["normal shift+j"] = "vim:join-lines",
    ["normal shift+, shift+,"] = "vim:indent-left",
    ["normal shift+. shift+."] = "vim:indent-right",
    ["normal shift+`"] = "vim:swap-case",
    ["normal shift+z shift+z"] = "vim:save-and-close",
    ["normal q"] = "vim:toggle-record-macro",
    ["normal shift+2"] = "vim:play-macro",
    -- cursor movement
    ["normal left"] = "vim:move-to-previous-char",
    ["normal down"] = "doc:move-to-next-line",
    ["normal up"] = "doc:move-to-previous-line",
    ["normal right"] = "vim:move-to-next-char",
    ["normal h"] = "vim:move-to-previous-char",
    ["normal j"] = "vim:move-to-next-line",
    ["normal k"] = "vim:move-to-previous-line",
    ["normal l"] = "vim:move-to-next-char",
    ["normal b"] = "vim:move-to-previous-word",
    ["normal w"] = "vim:move-to-next-word",
    ["normal e"] = "vim:move-to-next-word-end",
    ["normal 0"] = "doc:move-to-start-of-line",
    ["normal shift+4"] = "vim:move-to-end-of-line",
    ["normal shift+5"] = "vim:move-to-other-delim",
    ["normal shift+6"] = "vim:move-to-first-non-blank",
    ["normal /"] = "vim:search",
    ["normal n"] = "vim:search-next",
    ["normal shift+n"] = "vim:search-previous",
    ["normal ctrl+d"] = "vim:move-to-page-down",
    ["normal ctrl+u"] = "vim:move-to-page-up",
    ["normal shift+g"] = "vim:move-to-line",
    ["normal g g"] = "vim:move-to-first-line",
    ["normal f"] = "vim:find-char",
    ["normal shift+f"] = "vim:find-char-backwards",
    ["normal t"] = "vim:find-char-til",
    ["normal shift+t"] = "vim:find-char-til-backwards",
    ["normal ctrl+e"] = "vim:scroll-line-down",
    ["normal ctrl+y"] = "vim:scroll-line-up",
    ["normal `"] = "vim:goto-mark",
    ["normal m"] = "vim:set-mark",
    -- splits
    ["normal ctrl+w v"] = "root:split-right",
    ["normal ctrl+w s"] = "root:split-down",
    ["normal ctrl+w h"] = "root:switch-to-left",
    ["normal ctrl+w j"] = "root:switch-to-down",
    ["normal ctrl+w k"] = "root:switch-to-up",
    ["normal ctrl+w l"] = "root:switch-to-right",
    -- visual
    ["visual v"] = "vim:visual-mode",
    ["visual shift+v"] = "vim:visual-line-mode",
    ["visual ctrl+v"] = "vim:visual-block-mode",
    ["visual escape"] = "vim:exit-visual-mode",
    ["visual ctrl+p"] = "vim:find-file",
    ["visual ctrl+shift+p"] = "vim:find-command",
    ["visual shift+;"] = "vim:exec",
    ["visual h"] = "vim:select-to-previous-char",
    ["visual j"] = "vim:select-to-next-line",
    ["visual k"] = "vim:select-to-previous-line",
    ["visual l"] = "vim:select-to-next-char",
    ["visual b"] = "vim:select-to-previous-word",
    ["visual w"] = "vim:select-to-next-word",
    ["visual e"] = "vim:select-to-next-word-end",
    ["visual 0"] = "doc:select-to-start-of-line",
    ["visual shift+4"] = "vim:select-to-end-of-line",
    ["visual shift+5"] = "vim:select-to-other-delim",
    ["visual shift+6"] = "vim:select-to-first-non-blank",
    ["visual ctrl+d"] = "vim:select-to-page-down",
    ["visual ctrl+u"] = "vim:select-to-page-up",
    ["visual shift+g"] = "vim:select-to-line",
    ["visual g g"] = "vim:select-to-first-line",
    ["visual n"] = "vim:search-next",
    ["visual shift+n"] = "vim:search-previous",
    ["visual x"] = "vim:delete-selection",
    ["visual d"] = "vim:delete-selection",
    ["visual c"] = "vim:change-selection",
    ["visual y"] = "vim:copy",
    ["visual r"] = "vim:replace",
    ["visual u"] = "vim:exit-visual-mode",
    ["visual shift+j"] = "vim:join-lines",
    ["visual shift+,"] = "vim:indent-left",
    ["visual shift+."] = "vim:indent-right",
    ["visual shift+`"] = "vim:swap-case",
    ["visual u"] = "vim:lowercase",
    ["visual shift+u"] = "vim:uppercase",
    ["visual p"] = "vim:paste",
    ["visual shift+p"] = "vim:paste-before",
    ["visual shift+h"] = "vim:select-to-visible-top",
    ["visual shift+m"] = "vim:select-to-visible-middle",
    ["visual shift+l"] = "vim:select-to-visible-bottom",
    ["visual ctrl+e"] = "vim:scroll-line-down",
    ["visual ctrl+y"] = "vim:scroll-line-up",
    ["visual shift+i"] = "vim:insert-from-visual",
    ["visual f"] = "vim:find-char",
    ["visual shift+f"] = "vim:find-char-backwards",
    ["visual t"] = "vim:find-char-til",
    ["visual shift+t"] = "vim:find-char-til-backwards"
}

--[[
------------------------------------------------------------------------------
This software is available under 2 licenses -- choose whichever you prefer.
------------------------------------------------------------------------------
ALTERNATIVE A - MIT License
Copyright (c) 2021 Jason Liang
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
ALTERNATIVE B - Public Domain (www.unlicense.org)
This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.
In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to
the detriment of our heirs and successors. We intend this dedication to be an
overt act of relinquishment in perpetuity of all present and future rights to
this software under copyright law.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
------------------------------------------------------------------------------
--]]
