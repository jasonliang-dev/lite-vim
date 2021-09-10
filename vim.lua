--[[

vim.lua - see end of file for license information

TODO LIST
(IN PROGRESS) combos (dw, yy, ...)
    - c prefix, (cw)
    - diw, cit
(IN PROGRESS) commands, (:wq, :q!, :s/foo/bar/g)
(IN PROGRESS) number + command (123g, 50j, d3w, y10l)
visual block
visual line
repeat (.)
macros (q, @)
marks (``, m)

TOFIX LIST
(high) visual selection off by one when moving cursor back, clearing text, etc
(high) forward/back word doesn't share the same behaviour from vim
(low) cursor should always stay in view (ctrl+e/y, mouse wheel, same file in different splits)
(low) autocomplete shows up when using find (f)
(low) find next/prev always goes to visual mode even if there's no results
    - should find/repeat-find even go into visual mode?
(low) ctrl+d, ctrl+u should be a half scroll
(low) ctrl+d, ctrl+u shouldn't move the cursor
(low) cursor shouldn't be able to sit on the newline

--]]
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

local has_autoindent =
    system.get_file_info "data/plugins/autoindent.lua" or system.get_file_info "data/user/plugins/autoindent.lua"
local has_macro = system.get_file_info "data/plugins/macro.lua" or system.get_file_info "data/user/plugins/macro.lua"

local function dv()
    return core.active_view
end

local function doc()
    return core.active_view.doc
end

-- one of: "normal", "visual", "insert"
local mode = "normal"

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
        m = {},
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

-- always a reference to an item in stroke_combo_tree
local stroke_combo_loc = stroke_combo_tree[mode]
-- key buffer
local stroke_combo_string = ""

-- one of values in mini_mode_callbacks
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
        local l1, c1, l2, c2 = doc():get_selection(true)

        c2 = c2 + 1

        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)
        doc():insert(l1, c1, string.rep(input_text, #text))
    end
}

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

    -- workaround for (normal+0)
    if not (stroke == "0" and n_repeat ~= 0) then
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
    elseif clicks == 3 then
        if l2 == #doc.lines and doc.lines[#doc.lines] ~= "\n" then
            doc:insert(math.huge, math.huge, "\n")
        end
        l1, c1, l2, c2 = l1, 1, l2 + 1, 1
    end

    if mode ~= "insert" and (l1 ~= l2 or c1 ~= c2) then
        mode = "visual"
    end

    if swap then
        return l2, c2, l1, c1
    end
    return l1, c1, l2, c2
end

local command_view_enter = CommandView.enter
function CommandView:enter(text, submit, suggest, cancel)
    mode = "insert"
    command_view_enter(self, text, submit, suggest, cancel)
end

local command_view_exit = CommandView.exit
function CommandView:exit(submitted, inexplicit)
    if core.last_active_view.doc and core.last_active_view.doc:has_selection() then
        mode = "visual"
    else
        mode = "normal"
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
                mode = "visual"
            end

            local line1, col1 = select(3, self.doc:get_selection())
            local line2, col2 = self:resolve_screen_position(x, y)
            self.doc:set_selection(line2, col2, line1, col1)
        end
    else
        if mode == "visual" then
            mode = "normal"
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
            mode = "visual"
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

local visual_caret_color = style.visual_caret or style.syntax.string

local draw_line_body = DocView.draw_line_body
function DocView:draw_line_body(idx, x, y)
    local line, col = self.doc:get_selection()
    draw_line_body(self, idx, x, y)

    if mode == "normal" or mode == "visual" then
        if line == idx and system.window_has_focus() then
            local lh = self:get_line_height()
            local x1 = x + self:get_col_x_offset(line, col)
            local w = self:get_font():get_width " "

            if dv() ~= self then
                renderer.draw_rect(x1, y, w, lh, style.syntax.keyword)
            elseif mode == "visual" then
                renderer.draw_rect(x1, y, w, lh, visual_caret_color)
            else
                renderer.draw_rect(x1, y, w, lh, style.caret)
            end

            local ch = self.doc:get_text(line, col, line, col + 1)
            renderer.draw_text(self:get_font(), ch, x1, y + self:get_line_text_y_offset(), style.background)
        end
    end
end

local previous_exec_command = ""
local exec_commands = {
    w = "doc:save",
    q = "root:close",
    wq = "vim:save-and-close",
    x = "vim:save-and-close"
}

local function is_non_word(char)
    return config.non_word_chars:find(char, nil, true)
end

local vim_translate = {
    first_line = function(doc, line, col)
        if n_repeat ~= 0 then
            local n = n_repeat
            n_repeat = 0
            return n, 1
        else
            return 1, 1
        end
    end,
    line = function(doc, line, col)
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

        core.error "No matching item found"
        return line2, col2
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
    ["vim:insert-mode"] = function()
        mode = "insert"
    end,
    ["vim:normal-mode"] = function()
        mode = "normal"
        doc():move_to(vim_translate.previous_char, dv())
        command.perform "command:escape"
    end,
    ["vim:visual-mode"] = function()
        mode = "visual"
    end,
    ["vim:exit-visual-mode"] = function()
        mode = "normal"
        command.perform "doc:select-none"
    end,
    ["vim:change-end-of-line"] = function()
        mode = "insert"
        doc():select_to(translate.end_of_line, dv())
        command.perform "doc:cut"
    end,
    ["vim:change-selection"] = function()
        mode = "insert"
        command.perform "doc:cut"
    end,
    ["vim:change-word"] = function()
        mode = "insert"
        doc():select_to(translate.next_word_end, dv())
        command.perform "doc:cut"
    end,
    ["vim:copy"] = function()
        mode = "normal"

        local l1, c1, l2, c2 = doc():get_selection()
        local text = doc():get_text(l1, c1, l2, c2)
        system.set_clipboard(text)

        local cursor_at_selection_start = l2 < l1 or (l2 == l1 and c2 < c1)
        if cursor_at_selection_start then
            doc():set_selection(l2, c2)
        else
            doc():set_selection(l1, c1)
        end
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
        doc():select_to(translate.next_char, dv())
        command.perform "doc:cut"
    end,
    ["vim:delete-end-of-line"] = function()
        doc():select_to(translate.end_of_line, dv())
        command.perform "doc:cut"
    end,
    ["vim:delete-selection"] = function()
        mode = "normal"
        command.perform "doc:cut"
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
        mode = "insert"
        command.perform "core:find-command"
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
        mode = "insert"
        command.perform "core:find-file"
    end,
    ["vim:find-next"] = function()
        mode = "visual"
        command.perform "find-replace:repeat-find"
    end,
    ["vim:find-previous"] = function()
        mode = "visual"
        command.perform "find-replace:previous-find"
    end,
    ["vim:indent-left"] = function()
        mode = "normal"
        local l1, c1, l2, c2 = doc():get_selection(true)

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
    end,
    ["vim:indent-right"] = function()
        mode = "normal"
        local l1, c1, l2, c2 = doc():get_selection(true)

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
    end,
    ["vim:insert-end-of-line"] = function()
        mode = "insert"
        command.perform "doc:move-to-end-of-line"
    end,
    ["vim:insert-next-char"] = function()
        mode = "insert"
        local line, col = doc():get_selection()
        local next_line, next_col = translate.next_char(doc(), line, col)

        if line ~= next_line then
            doc():move_to(translate.end_of_line, dv())
        else
            doc():move_to(translate.next_char, dv())
        end
    end,
    ["vim:insert-newline-above"] = function()
        mode = "insert"
        command.perform "doc:newline-above"
    end,
    ["vim:insert-newline-below"] = function()
        mode = "insert"

        if has_autoindent then
            command.perform "autoindent:newline-below"
        else
            command.perform "doc:newline-below"
        end
    end,
    ["vim:join-lines"] = function()
        mode = "normal"
        command.perform "doc:join-lines"
    end,
    ["vim:lowercase"] = function()
        local l1, c1, l2, c2 = doc():get_selection(true)
        c2 = c2 + 1

        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)
        doc():insert(l1, c1, text:lower())
        doc():set_selection(l1, c1)
        mode = "normal"
    end,
    ["vim:replace"] = function()
        mini_mode = mini_mode_callbacks.replace
    end,
    ["vim:scroll-down"] = function()
        local lh = dv():get_line_height()
        dv().scroll.to.y = dv().scroll.to.y + lh
    end,
    ["vim:scroll-up"] = function()
        local lh = dv():get_line_height()
        dv().scroll.to.y = math.max(0, dv().scroll.to.y - lh)
    end,
    ["vim:save-and-close"] = function()
        command.perform "doc:save"
        command.perform "root:close"
    end,
    ["vim:swap-case"] = function()
        local l1, c1, l2, c2 = doc():get_selection(true)
        c2 = c2 + 1

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
        end
    end,
    ["vim:uppercase"] = function()
        local l1, c1, l2, c2 = doc():get_selection(true)
        c2 = c2 + 1

        local text = doc():get_text(l1, c1, l2, c2)
        doc():remove(l1, c1, l2, c2)
        doc():insert(l1, c1, text:upper())
        doc():set_selection(l1, c1)
        mode = "normal"
    end
}

local vim_translation_commands = {
    ["previous-char"] = vim_translate.previous_char,
    ["next-char"] = vim_translate.next_char,
    ["previous-word"] = vim_translate.previous_word,
    ["next-word"] = vim_translate.next_word,
    ["other-delim"] = vim_translate.other_delim,
    ["visible-top"] = vim_translate.visible_top,
    ["visible-middle"] = vim_translate.visible_middle,
    ["visible-bottom"] = vim_translate.visible_bottom,
    ["line"] = vim_translate.line,
    ["first-line"] = vim_translate.first_line
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
    -- insert
    ["escape"] = "vim:normal-mode",
    -- normal
    ["normal+shift+;"] = "vim:exec",
    ["normal+a"] = "vim:insert-next-char",
    ["normal+shift+a"] = "vim:insert-end-of-line",
    ["normal+shift+c"] = "vim:change-end-of-line",
    ["normal+c+w"] = "vim:change-word",
    ["normal+d+d"] = "doc:delete-lines",
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
    ["normal+shift+4"] = "doc:move-to-end-of-line",
    ["normal+shift+5"] = "vim:move-to-other-delim",
    ["normal+/"] = "find-replace:find",
    ["normal+n"] = "vim:find-next",
    ["normal+shift+n"] = "vim:find-previous",
    ["normal+ctrl+d"] = "doc:move-to-next-page",
    ["normal+ctrl+u"] = "doc:move-to-previous-page",
    ["normal+shift+g"] = "vim:move-to-line",
    ["normal+g+g"] = "vim:move-to-first-line",
    ["normal+f"] = "vim:find-char",
    ["normal+shift+f"] = "vim:find-char-backwards",
    ["normal+t"] = "vim:find-char-til",
    ["normal+shift+t"] = "vim:find-char-til-backwards",
    ["normal+ctrl+e"] = "vim:scroll-down",
    ["normal+ctrl+y"] = "vim:scroll-up",
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
    ["visual+h"] = "doc:select-to-previous-char",
    ["visual+j"] = "doc:select-to-next-line",
    ["visual+k"] = "doc:select-to-previous-line",
    ["visual+l"] = "doc:select-to-next-char",
    ["visual+b"] = "doc:select-to-previous-word-start",
    ["visual+w"] = "doc:select-to-next-word-end",
    ["visual+e"] = "doc:select-to-next-word-end",
    ["visual+0"] = "doc:select-to-start-of-line",
    ["visual+shift+4"] = "doc:select-to-end-of-line",
    ["visual+shift+5"] = "vim:select-to-other-delim",
    ["visual+ctrl+d"] = "doc:select-to-next-page",
    ["visual+ctrl+u"] = "doc:select-to-previous-page",
    ["visual+shift+g"] = "vim:select-to-line",
    ["visual+g+g"] = "vim:select-to-first-line",
    ["visual+n"] = "vim:find-next",
    ["visual+shift+n"] = "vim:find-previous",
    ["visual+x"] = "vim:delete-selection",
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
    ["visual+shift+l"] = "vim:select-to-visible-bottom"
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
