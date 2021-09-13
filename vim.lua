--[[

vim.lua - see end of file for license information

TODO LIST
(IN PROGRESS) combos (dw, yy, ...)
    - c prefix, (cw)
    - diw, cit
(IN PROGRESS) commands
    - :q!
    - :s/foo/bar/g
(IN PROGRESS) number + command (123g, 50j, d3w, y10l)
visual block
repeat (.)
macros (q, @)
marks (``, m)
delete other windows (ctrl+w o)

TOFIX LIST
(high) forward/back word doesn't share the same behaviour from vim
(high) pasting
(low) cursor should always stay in view (ctrl+e/y, mouse wheel)
(low) autocomplete shows up when using find (f)
(low) cursor shouldn't be able to sit on the newline
(low) replace chars in visual mode is broken. newlines ignored
(low) visual line submode ignored when pasting

--]]
--

local core = require "core"
local keymap = require "core.keymap"
local command = require "core.command"
local CommandView = require "core.commandview"
local DocView = require "core.docview"
local Doc = require "core.doc"
local style = require "core.style"
local translate = require "core.doc.translate"
local common = require "core.common"
local config = require "core.config"

local function dv()
    return core.active_view
end

local function doc()
    return core.active_view.doc
end

-- one of: "normal", "visual", "insert"
local mode = "normal"
-- one of: nil, "line", "block"
local visual_submode

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

local function get_selection(doc)
    local l1, c1, l2, c2 = doc:get_selection(true)

    if visual_submode == "line" then
        c1 = 1
        c2 = #doc.lines[l2]
    else
        c2 = c2 + 1
    end

    return l1, c1, l2, c2
end

-- used for number + command (50j to down down 50 lines, y3w to copy 3 words, etc)
local n_repeat = 0

local stroke_combo_tree = {
    normal = {
        ["ctrl+w"] = {},
        ["shift+,"] = {},
        ["shift+."] = {},
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

-- merge t2 into t1
local function merge_trees(t1, t2)
    for k, v in pairs(t2) do
        if t1[k] then
            merge_trees(t1[k], v)
        else
            t1[k] = v
        end
    end
end

--[[
local function inspect_tree(tree, indent)
    indent = indent or 0
    local str = ""

    if not tree then
        str = str .. "nil\n"
    else
        str = str .. "{\n"
        for k, v in pairs(tree) do
            str =
                str .. string.rep(" ", indent + 4) .. string.format("['%s'] = %s", k, inspect_tree(tree[k], indent + 4))
        end
        str = str .. string.rep(" ", indent) .. "}\n"
    end

    return str
end
--]]
--

local previous_exec_command = ""
local exec_commands = {
    w = "doc:save",
    q = "root:close",
    wq = "vim:save-and-close",
    x = "vim:save-and-close",
    nohl = "vim:nohl"
}

local previous_find_command = ""
local should_highlight = false

-- should be a reference to an item in stroke_combo_tree
local stroke_combo_loc = stroke_combo_tree[mode]
-- key buffer
local stroke_combo_string = ""

-- either nil, or a function in mini_mode_callbacks
local mini_mode

local mini_mode_callbacks = {
    find = function(input_text)
        local line, col = doc():get_selection()
        local text = doc():get_text(line, 1, line, math.huge)

        for i = col + 1, #text do
            local c = text:sub(i, i)

            if c == input_text then
                doc():set_selection(line, i)
                return
            end
        end

        core.error("Can't find " .. input_text)
    end,
    find_backwards = function(input_text)
        local line, col = doc():get_selection()
        local text = doc():get_text(line, 1, line, math.huge)

        for i = col - 1, 1, -1 do
            local c = text:sub(i, i)

            if c == input_text then
                doc():set_selection(line, i)
                return
            end
        end

        core.error("Can't find " .. input_text)
    end,
    find_til = function(input_text)
        local line, col = doc():get_selection()
        local text = doc():get_text(line, 1, line, math.huge)

        for i = col + 1, #text do
            local c = text:sub(i, i)

            if c == input_text then
                doc():set_selection(line, i - 1)
                return
            end
        end

        core.error("Can't find " .. input_text)
    end,
    find_til_backwards = function(input_text)
        local line, col = doc():get_selection()
        local text = doc():get_text(line, 1, line, math.huge)

        for i = col - 1, 1, -1 do
            local c = text:sub(i, i)

            if c == input_text then
                doc():set_selection(line, i + 1)
                return
            end
        end

        core.error("Can't find " .. input_text)
    end,
    replace = function(input_text)
        local l1, c1, l2, c2 = get_selection(doc())

        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)
        doc():insert(l1, c1, string.rep(input_text, #text))
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
    -- print(mode .. stroke_combo_string .. "+" .. stroke)

    -- check for normal+0, and any other command with numbers
    if not (n_repeat ~= 0 and string.find("0123456789", stroke, 1, true)) then
        local commands
        if mode == "insert" then
            commands = keymap.map[stroke]
        elseif mode == "normal" then
            commands = keymap.map["normal" .. stroke_combo_string .. "+" .. stroke]
        elseif mode == "visual" then
            commands = keymap.map["visual" .. stroke_combo_string .. "+" .. stroke]
        else
            core.error("Cannot handle key in unknown mode '%s'", mode)
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
            stroke_combo_string = stroke_combo_string .. "+" .. stroke
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

local command_view_enter = CommandView.enter
function CommandView:enter(text, submit, suggest, cancel)
    insert_mode()
    command_view_enter(self, text, submit, suggest, cancel)
end

local command_view_exit = CommandView.exit
function CommandView:exit(submitted, inexplicit)
    if core.last_active_view.doc and core.last_active_view.doc:has_selection() then
        visual_mode()
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
    self.blink_timer = 0
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

function DocView:on_text_input(text)
    if mini_mode then
        mini_mode(text)
        mini_mode = nil
    else
        self.doc:text_input(text)
    end
end

local blink_period = 0.8

local function draw_box(x, y, w, h, color)
    local r = renderer.draw_rect
    local s = math.ceil(SCALE)
    r(x, y, w, s, color)
    r(x, y + h - s, w, s, color)
    r(x, y + s, s, h - s * 2, color)
    r(x + w - s, y + s, s, h - s * 2, color)
end

function DocView:draw_line_body(idx, x, y)
    local line, col = self.doc:get_selection()
    local line1, col1, line2, col2 = self.doc:get_selection(true)

    -- draw selection
    if core.active_view == self and idx >= line1 and idx <= line2 then
        local text = self.doc.lines[idx]
        if line1 ~= idx then
            col1 = 1
        end
        if line2 ~= idx then
            col2 = #text + 1
        end

        local x1
        local x2
        if visual_submode == "line" then
            x1 = x
            x2 = x + self:get_col_x_offset(idx, #text + 1)
        else
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
        local text = self.doc.lines[idx]:lower()

        local last_col = 1
        local start_col, end_col = text:find(previous_find_command, last_col, true)

        while start_col do
            local x1 = x + self:get_col_x_offset(idx, start_col)
            local x2 = x + self:get_col_x_offset(idx, end_col + 1)
            draw_box(x1, y, x2 - x1, lh, style.text)

            last_col = end_col + 1
            start_col, end_col = text:find(previous_find_command, last_col, true)
        end
    end

    -- draw line's text
    self:draw_line_text(idx, x, y)

    -- draw caret
    if line == idx and core.active_view == self and self.blink_timer < blink_period / 2 and system.window_has_focus() then
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

local set_active_view = core.set_active_view
function core.set_active_view(view)
    set_active_view(view)

    if view:is(DocView) and mode ~= "visual" then
        local min, max = view:get_visible_line_range()
        local line = view.doc:get_selection()

        if line < min or line > max then
            view.doc:set_selection(min + math.floor((max - min) / 2), 1)
        end
    end
end

local function is_non_word(char)
    return config.non_word_chars:find(char, nil, true)
end

local vim_translate = {
    goto_first_line = function(doc, line, col)
        if n_repeat ~= 0 then
            local n = n_repeat
            n_repeat = 0
            return n, 1
        else
            return 1, 1
        end
    end,
    goto_line = function(doc, line, col)
        if n_repeat ~= 0 then
            local n = n_repeat
            n_repeat = 0
            return n, 1
        else
            return #doc.lines, #doc.lines[#doc.lines]
        end
    end,
    previous_char = function(doc, line, col)
        local line2
        local col2

        repeat
            line2, col2 = doc:position_offset(line, col, -1)
        until not common.is_utf8_cont(doc:get_char(line2, col2))

        if line ~= line2 then
            return line, col
        else
            return line2, col2
        end
    end,
    next_char = function(doc, line, col)
        local line2
        local col2

        repeat
            line2, col2 = doc:position_offset(line, col, 1)
        until not common.is_utf8_cont(doc:get_char(line2, col2))

        if line ~= line2 then
            return line, col
        else
            return line2, col2
        end
    end,
    -- previous_line = function(doc, line, col, dv)
    --    return DocView.translate.previous_line(doc, line, col, dv)
    -- end,
    -- next_line = function(doc, line, col, dv)
    --    return DocView.translate.previous_line(doc, line, col, dv)
    -- end,
    previous_word = function(doc, line, col)
        return translate.previous_word_start(doc, line, col)
    end,
    next_word = function(doc, line, col)
        return translate.next_word_end(doc, line, col)
        --[[
        local prev
        local end_line, end_col = translate.end_of_doc(doc, line, col)
        while line < end_line or col < end_col do
            local char = doc:get_char(line, col)
            if prev and is_non_word(prev) and not is_non_word(char) then
                break
            end
            line, col = doc:position_offset(line, col, 1)
            prev = char
        end
        return line, col
        ]]
    end,
    end_of_line = function(doc, line, col)
        return line, #doc.lines[line] - 1
    end,
    first_non_blank = function(doc, line, col)
        local text = doc:get_text(line, 1, line + 1, 1)

        local i = text:find("%S")
        if i then
            return line, i
        end

        return line, math.huge
    end,
    other_delim = function(doc, line, col)
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
    end,
    page_down = function(doc, line, col, dv)
        local delta = dv.size.y / 2
        dv.scroll.to.y = dv.scroll.to.y + delta
        return line + math.floor(delta / dv:get_line_height()), col
    end,
    page_up = function(doc, line, col, dv)
        local delta = dv.size.y / 2
        dv.scroll.to.y = dv.scroll.to.y - delta
        return line - math.floor(delta / dv:get_line_height()), col
    end,
    visible_top = function(doc, line, col, dv)
        local min = dv:get_visible_line_range()
        return min, 1
    end,
    visible_middle = function(doc, line, col, dv)
        local min, max = dv:get_visible_line_range()
        return math.floor((max + min) / 2), 1
    end,
    visible_bottom = function(doc, line, col, dv)
        local _, max = dv:get_visible_line_range()
        return max, 1
    end
}

local commands = {
    ["vim:debug"] = function()
        -- local line1, col1, line2, col2 = doc():get_selection(true)
        -- print(line1, col1, line2, col2)
    end,
    ["vim:use-user-stroke-combos"] = function()
        merge_trees(stroke_combo_tree, config.vim_stroke_combos or {})
    end,
    ["vim:insert-mode"] = insert_mode,
    ["vim:normal-mode"] = function()
        doc():move_to(vim_translate.previous_char, dv())
        command.perform "command:escape"
        normal_mode()
    end,
    ["vim:force-normal-mode"] = function()
        normal_mode()
        n_repeat = 0
    end,
    ["vim:visual-mode"] = visual_mode,
    ["vim:visual-line-mode"] = function()
        visual_mode("line")
    end,
    ["vim:exit-visual-mode"] = function()
        command.perform "doc:select-none"
        normal_mode()
    end,
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
        command.perform "vim:cut"
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
        system.set_clipboard(text)
        doc():set_selection(l1, c1)
        normal_mode()
    end,
    ["vim:cut"] = function()
        local l1, c1, l2, c2 = get_selection(doc())
        local text = doc():get_text(l1, c1, l2, c2)
        system.set_clipboard(text)
        doc():set_selection(l1, c1)
        doc():remove(l1, c1, l2, c2)
    end,
    ["vim:copy-line"] = function()
        local line = doc():get_selection()
        local text = doc():get_text(line, 1, line + 1, 1)
        system.set_clipboard(text)
    end,
    ["vim:copy-n-words"] = function()
        local line, col = doc():get_selection()

        for i = 1, n_repeat do
            doc():select_to(translate.next_word_end, dv())
        end

        command.perform "doc:copy"
        doc():set_selection(line, col)
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
    ["vim:delete-word"] = function()
        doc():select_to(translate.next_word_end, dv())
        command.perform "doc:cut"
    end,
    ["vim:exec"] = function()
        core.command_view:set_text(previous_exec_command, true)
        core.command_view:enter(
            "vim",
            function(text)
                previous_exec_command = text
                local cmd = exec_commands[text]
                if cmd then
                    command.perform(cmd)
                else
                    core.error("Unknown command ':%s'", text)
                end
            end
        )
    end,
    ["vim:find-command"] = function()
        command.perform "core:find-command"
        insert_mode()
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
    ["vim:find-file"] = function()
        command.perform "core:find-file"
        insert_mode()
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
    ["vim:nohl"] = function()
        should_highlight = false
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

        core.command_view:set_text(previous_find_command, true)
        core.command_view:enter(
            "Search",
            function(text)
                previous_find_command = text
                should_highlight = true
                local l1, c1 = vim_search.find(doc(), line, col + 1, text, {wrap = true, no_case = true})
                if l1 then
                    doc():set_selection(l1, c1)
                end
            end,
            nil,
            function(explicit)
                if explicit then
                    should_highlight = false
                end
            end
        )
    end,
    ["vim:search-next"] = function()
        if previous_find_command ~= "" then
            should_highlight = true
            local line, col = doc():get_selection()
            local l1, c1 = vim_search.find(doc(), line, col + 1, previous_find_command, {wrap = true, no_case = true})
            if l1 then
                doc():set_selection(l1, c1)
            end
        else
            core.error("No previous find")
        end
    end,
    ["vim:search-previous"] = function()
        if previous_find_command ~= "" then
            should_highlight = true
            local line, col = doc():get_selection()
            local l1, c1 =
                vim_search.find_backwards(doc(), line, col - 1, previous_find_command, {wrap = true, no_case = true})
            if l1 then
                doc():set_selection(l1, c1)
            end
        else
            core.error("No previous find")
        end
    end,
    ["vim:swap-case"] = function()
        local l1, c1, l2, c2 = get_selection(doc())
        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)

        local split = {}
        for c in text:gmatch "." do
            table.insert(split, c)
        end

        for k, c in pairs(split) do
            if c:match "[A-Z]" then
                split[k] = c:lower()
            else
                split[k] = c:upper()
            end
        end

        doc():insert(l1, c1, table.concat(split))

        if mode == "normal" then
            doc():set_selection(l1, c1 + 1)
        else
            doc():set_selection(l1, c1)
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
    ["previous-line"] = vim_translate.previous_line,
    ["next-line"] = vim_translate.next_line,
    ["previous-word"] = vim_translate.previous_word,
    ["next-word"] = vim_translate.next_word,
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
    commands["vim:move-to-" .. name] = function()
        doc():move_to(fn, dv())
    end

    commands["vim:select-to-" .. name] = function()
        doc():select_to(fn, dv())
    end

    commands["vim:delete-to-" .. name] = function()
        doc():delete_to(fn, dv())
    end
end

command.add(nil, commands)

keymap.add {
    ["shift+f3"] = "vim:debug",
    ["normal+shift+f3"] = "vim:debug",
    ["visual+shift+f3"] = "vim:debug",
    -- insert
    ["escape"] = "vim:normal-mode",
    -- normal
    ["normal+escape"] = {"command:escape", "vim:force-normal-mode"},
    ["normal+shift+;"] = "vim:exec",
    ["normal+a"] = "vim:insert-next-char",
    ["normal+shift+a"] = "vim:insert-end-of-line",
    ["normal+c+c"] = "vim:change-line",
    ["normal+shift+c"] = "vim:change-end-of-line",
    ["normal+c+w"] = "vim:change-word",
    ["normal+d+d"] = "vim:delete-lines",
    ["normal+d+w"] = "vim:delete-word",
    ["normal+shift+d"] = "vim:delete-end-of-line",
    ["normal+shift+h"] = "vim:move-to-visible-top",
    ["normal+shift+m"] = "vim:move-to-visible-middle",
    ["normal+shift+l"] = "vim:move-to-visible-bottom",
    ["normal+i"] = "vim:insert-mode",
    ["normal+o"] = "vim:insert-newline-below",
    ["normal+shift+o"] = "vim:insert-newline-above",
    ["normal+p"] = "doc:paste",
    ["normal+shift+p"] = "doc:paste",
    ["normal+ctrl+p"] = "vim:find-file",
    ["normal+ctrl+shift+p"] = "vim:find-command",
    ["normal+ctrl+\\"] = "treeview:toggle",
    ["normal+ctrl+s"] = "doc:save",
    ["normal+g+t"] = "root:switch-to-next-tab",
    ["normal+g+shift+t"] = "root:switch-to-previous-tab",
    ["normal+v"] = "vim:visual-mode",
    ["normal+shift+v"] = "vim:visual-line-mode",
    ["normal+x"] = "vim:delete-char",
    ["normal+y+y"] = "vim:copy-line",
    ["normal+y+#+w"] = "vim:copy-n-words",
    ["normal+u"] = "doc:undo",
    ["normal+ctrl+r"] = "doc:redo",
    ["normal+r"] = "vim:replace",
    ["normal+shift+j"] = "vim:join-lines",
    ["normal+shift+,+shift+,"] = "vim:indent-left",
    ["normal+shift+.+shift+."] = "vim:indent-right",
    ["normal+shift+`"] = "vim:swap-case",
    -- cursor movement
    ["normal+left"] = "vim:move-to-previous-char",
    ["normal+down"] = "doc:move-to-next-line",
    ["normal+up"] = "doc:move-to-previous-line",
    ["normal+right"] = "vim:move-to-next-char",
    ["normal+h"] = "vim:move-to-previous-char",
    ["normal+j"] = "doc:move-to-next-line",
    ["normal+k"] = "doc:move-to-previous-line",
    ["normal+l"] = "vim:move-to-next-char",
    ["normal+b"] = "vim:move-to-previous-word",
    ["normal+w"] = "vim:move-to-next-word",
    ["normal+e"] = "doc:move-to-next-word-end",
    ["normal+0"] = "doc:move-to-start-of-line",
    ["normal+shift+4"] = "vim:move-to-end-of-line",
    ["normal+shift+5"] = "vim:move-to-other-delim",
    ["normal+shift+6"] = "vim:move-to-first-non-blank",
    ["normal+/"] = "vim:search",
    ["normal+n"] = "vim:search-next",
    ["normal+shift+n"] = "vim:search-previous",
    ["normal+ctrl+d"] = "vim:move-to-page-down",
    ["normal+ctrl+u"] = "vim:move-to-page-up",
    ["normal+shift+g"] = "vim:move-to-line",
    ["normal+g+g"] = "vim:move-to-first-line",
    ["normal+f"] = "vim:find-char",
    ["normal+shift+f"] = "vim:find-char-backwards",
    ["normal+t"] = "vim:find-char-til",
    ["normal+shift+t"] = "vim:find-char-til-backwards",
    ["normal+ctrl+e"] = "vim:scroll-line-down",
    ["normal+ctrl+y"] = "vim:scroll-line-up",
    -- splits
    ["normal+ctrl+w+v"] = "root:split-right",
    ["normal+ctrl+w+s"] = "root:split-down",
    ["normal+ctrl+w+h"] = "root:switch-to-left",
    ["normal+ctrl+w+j"] = "root:switch-to-down",
    ["normal+ctrl+w+k"] = "root:switch-to-up",
    ["normal+ctrl+w+l"] = "root:switch-to-right",
    -- visual
    ["visual+escape"] = "vim:exit-visual-mode",
    ["visual+ctrl+p"] = "vim:find-file",
    ["visual+ctrl+shift+p"] = "vim:find-command",
    ["visual+h"] = "vim:select-to-previous-char",
    ["visual+j"] = "doc:select-to-next-line",
    ["visual+k"] = "doc:select-to-previous-line",
    ["visual+l"] = "vim:select-to-next-char",
    ["visual+b"] = "doc:select-to-previous-word-start",
    ["visual+w"] = "doc:select-to-next-word-end",
    ["visual+e"] = "doc:select-to-next-word-end",
    ["visual+0"] = "doc:select-to-start-of-line",
    ["visual+shift+4"] = "vim:select-to-end-of-line",
    ["visual+shift+5"] = "vim:select-to-other-delim",
    ["visual+shift+6"] = "vim:select-to-first-non-blank",
    ["visual+ctrl+d"] = "vim:select-to-page-down",
    ["visual+ctrl+u"] = "vim:select-to-page-up",
    ["visual+shift+g"] = "vim:select-to-line",
    ["visual+g+g"] = "vim:select-to-first-line",
    ["visual+n"] = "vim:search-next",
    ["visual+shift+n"] = "vim:search-previous",
    ["visual+x"] = "vim:delete-selection",
    ["visual+d"] = "vim:delete-selection",
    ["visual+c"] = "vim:change-selection",
    ["visual+y"] = "vim:copy",
    ["visual+r"] = "vim:replace",
    ["visual+u"] = "vim:exit-visual-mode",
    ["visual+shift+j"] = "vim:join-lines",
    ["visual+shift+,"] = "vim:indent-left",
    ["visual+shift+."] = "vim:indent-right",
    ["visual+shift+`"] = "vim:swap-case",
    ["visual+u"] = "vim:lowercase",
    ["visual+shift+u"] = "vim:uppercase",
    ["visual+p"] = "doc:paste",
    ["visual+shift+p"] = "doc:paste",
    ["visual+shift+h"] = "vim:select-to-visible-top",
    ["visual+shift+m"] = "vim:select-to-visible-middle",
    ["visual+shift+l"] = "vim:select-to-visible-bottom",
    ["visual+shift+v"] = "vim:visual-line-mode"
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
