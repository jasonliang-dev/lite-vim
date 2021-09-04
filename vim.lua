--[[

vim.lua - see end of file for license information

TODO LIST
(IN PROGRESS) combos (dw, yy, ...)
(IN PROGRESS) search (/, n, N)
visual block
visual line
macros (q, @)
repeat (.)
go to other delim (%)
commands, (:wq, :q!, :s/foo/bar/g)
scroll up/down by a line (ctrl+e, ctrl+y)
number + command (123g, 50j)
replace (r)
marks (``, m)

TOFIX LIST
(high) visual selection off by one when moving cursor back
(high) forward/back word doesn't share the same behaviour from vim
(low) ctrl+d, ctrl+u should be a half scroll
(low) ctrl+d, ctrl+u shouldn't move the cursor
(low): cursor shouldn't be able to sit on the newline

--]]
local core = require "core"
local keymap = require "core.keymap"
local command = require "core.command"
local CommandView = require "core.commandview"
local DocView = require "core.docview"
local style = require "core.style"
local translate = require "core.doc.translate"
local common = require "core.common"

local has_autoindent =
    system.get_file_info("data/plugins/autoindent.lua") or system.get_file_info("data/user/plugins/autoindent.lua")
local has_macro = system.get_file_info("data/plugins/macro.lua") or system.get_file_info("data/user/plugins/macro.lua")

local mode = "normal"

local modkey_map = {
    ["left ctrl"] = "ctrl",
    ["right ctrl"] = "ctrl",
    ["left shift"] = "shift",
    ["right shift"] = "shift",
    ["left alt"] = "alt",
    ["right alt"] = "altgr"
}

local modkeys = {"ctrl", "alt", "altgr", "shift"}

local marks = {
    ["`"] = {}
}

local key_combo_tree = {
    normal = {
        ["ctrl+w"] = {},
        c = {},
        d = {
            g = {}
        },
        g = {},
        m = {},
        y = {}
    },
    visual = {}
}

local key_combo_string = ""
local key_combo_loc = key_combo_tree[mode]

local function doc()
    return core.active_view.doc
end

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
    local commands
    if mode == "insert" then
        commands = keymap.map[stroke]
    elseif mode == "normal" then
        commands = keymap.map["normal" .. key_combo_string .. "+" .. stroke]
    elseif mode == "visual" then
        commands = keymap.map["visual" .. key_combo_string .. "+" .. stroke]
    else
        core.error("cannot handle key in unknown mode '%s'", mode)
    end

    if commands then
        for _, cmd in ipairs(commands) do
            local performed = command.perform(cmd)
            if performed then
                key_combo_string = ""
                key_combo_loc = key_combo_tree[mode]
                break
            end
        end

        return true
    end

    if mode == "normal" or mode == "visual" then
        key_combo_loc = key_combo_loc[stroke]
        if key_combo_loc then
            if key_combo_string == "" then
                key_combo_string = ":" .. stroke
            else
                key_combo_string = key_combo_string .. "," .. stroke
            end
        else
            key_combo_loc = key_combo_tree[mode]
            key_combo_string = ""
        end

        return true
    end

    return false
end

local function mouse_selection(doc, clicks, line1, col1, line2, col2)
    local swap = line2 < line1 or line2 == line1 and col2 <= col1
    if swap then
        line1, col1, line2, col2 = line2, col2, line1, col1
    end

    if clicks == 2 then
        if mode == "normal" then
            mode = "visual"
        end

        line1, col1 = translate.start_of_word(doc, line1, col1)
        line2, col2 = translate.end_of_word(doc, line2, col2)
    elseif clicks == 3 then
        if mode == "normal" then
            mode = "visual"
        end

        if line2 == #doc.lines and doc.lines[#doc.lines] ~= "\n" then
            doc:insert(math.huge, math.huge, "\n")
        end
        line1, col1, line2, col2 = line1, 1, line2 + 1, 1
    end

    if swap then
        return line2, col2, line1, col1
    end
    return line1, col1, line2, col2
end

local command_view_enter = CommandView.enter
function CommandView:enter(text, submit, suggest, cancel)
    command_view_enter(self, text, submit, suggest, cancel)
    mode = "insert"
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

local draw_line_body = DocView.draw_line_body
function DocView:draw_line_body(idx, x, y)
    local line, col = self.doc:get_selection()
    draw_line_body(self, idx, x, y)

    if mode == "normal" or mode == "visual" then
        if line == idx and core.active_view == self and system.window_has_focus() then
            local lh = self:get_line_height()
            local x1 = x + self:get_col_x_offset(line, col)
            local w = self:get_font():get_width(" ")

            if mode == "visual" then
                renderer.draw_rect(x1, y, w, lh, {common.color "#ffff00"})
            else
                renderer.draw_rect(x1, y, w, lh, style.caret)
            end

            local ch = self.doc:get_text(line, col, line, col + 1)
            renderer.draw_text(self:get_font(), ch, x1, y + self:get_line_text_y_offset(), style.background)
        end
    end
end

local function vim_previous_char(doc, line, col)
    local line_cpy = line
    local col_cpy = col

    repeat
        line, col = doc:position_offset(line, col, -1)
    until not common.is_utf8_cont(doc:get_char(line, col))

    if line_cpy ~= line then
        return line_cpy, col_cpy
    else
        return line, col
    end
end

local function vim_next_char(doc, line, col)
    local line_cpy = line
    local col_cpy = col

    repeat
        line, col = doc:position_offset(line, col, 1)
    until not common.is_utf8_cont(doc:get_char(line, col))

    if line_cpy ~= line then
        return line_cpy, col_cpy
    else
        return line, col
    end
end

command.add(
    nil,
    {
        ["vim:insert-mode"] = function()
            mode = "insert"
        end,
        ["vim:normal-mode"] = function()
            mode = "normal"
            doc():move_to(vim_previous_char)
            command.perform("command:escape")
        end,
        ["vim:visual-mode"] = function()
            mode = "visual"
        end,
        ["vim:exit-visual-mode"] = function()
            mode = "normal"
            command.perform("doc:select-none")
        end,
        ["vim:copy"] = function()
            mode = "normal"
            command.perform("doc:copy")

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
        ["vim:delete-char"] = function()
            doc():select_to(translate.next_char, core.active_view)
            local text = doc():get_text(doc():get_selection())
            system.set_clipboard(text)
            doc():delete_to(0)
        end,
        ["vim:delete-selection"] = function()
            mode = "normal"
            command.perform("doc:copy")
            doc():delete_to(0)
        end,
        ["vim:delete-word"] = function()
            doc():select_to(translate.next_word_end, core.active_view)
            command.perform("doc:copy")
            doc():delete_to(0)
        end,
        ["vim:find-command"] = function()
            mode = "insert"
            command.perform("core:find-command")
        end,
        ["vim:find-file"] = function()
            mode = "insert"
            command.perform("core:find-file")
        end,
        ["vim:insert-end-of-line"] = function()
            mode = "insert"
            command.perform("doc:move-to-end-of-line")
        end,
        ["vim:insert-next-char"] = function()
            mode = "insert"
            local line, col = doc():get_selection()
            local next_line, next_col = translate.next_char(doc(), line, col)

            if line ~= next_line then
                doc():move_to(translate.end_of_line, core.active_view)
            else
                doc():move_to(translate.next_char)
            end
        end,
        ["vim:insert-newline-above"] = function()
            mode = "insert"
            command.perform("doc:newline-above")
        end,
        ["vim:insert-newline-below"] = function()
            mode = "insert"

            if has_autoindent then
                command.perform("autoindent:newline-below")
            else
                command.perform("doc:newline-below")
            end
        end,
        ["vim:move-to-previous-char"] = function()
            doc():move_to(vim_previous_char)
        end,
        ["vim:move-to-next-char"] = function()
            doc():move_to(vim_next_char)
        end
    }
)

keymap.add {
    -- insert
    ["escape"] = "vim:normal-mode",
    -- normal
    ["normal+a"] = "vim:insert-next-char",
    ["normal+shift+a"] = "vim:insert-end-of-line",
    ["normal:d+d"] = "doc:delete-lines",
    ["normal:d+w"] = "vim:delete-word",
    ["normal+i"] = "vim:insert-mode",
    ["normal+o"] = "vim:insert-newline-below",
    ["normal+shift+o"] = "vim:insert-newline-above",
    ["normal+shift+p"] = "doc:paste",
    ["normal+ctrl+p"] = "vim:find-file",
    ["normal+ctrl+shift+p"] = "vim:find-command",
    ["normal+ctrl+s"] = "doc:save",
    ["normal+v"] = "vim:visual-mode",
    ["normal+x"] = "vim:delete-char",
    ["normal:y+y"] = "vim:copy-line",
    ["normal+u"] = "doc:undo",
    ["normal+ctrl+r"] = "doc:redo",
    -- cursor movement
    ["normal+h"] = "vim:move-to-previous-char",
    ["normal+j"] = "doc:move-to-next-line",
    ["normal+k"] = "doc:move-to-previous-line",
    ["normal+l"] = "vim:move-to-next-char",
    ["normal+b"] = "doc:move-to-previous-word-start",
    ["normal+w"] = "doc:move-to-next-word-end",
    ["normal+e"] = "doc:move-to-next-word-end",
    ["normal+0"] = "doc:move-to-start-of-line",
    ["normal+shift+4"] = "doc:move-to-end-of-line",
    ["normal+/"] = "find-replace:find",
    ["normal+n"] = "find-replace:repeat-find",
    ["normal+shift+n"] = "find-replace:previous-find",
    -- doc movement
    ["normal+ctrl+d"] = "doc:move-to-next-page",
    ["normal+ctrl+u"] = "doc:move-to-previous-page",
    ["normal+shift+g"] = "doc:move-to-end-of-doc",
    ["normal:g+g"] = "doc:move-to-start-of-doc",
    -- splits
    ["normal:ctrl+w+v"] = "root:split-right",
    ["normal:ctrl+w+s"] = "root:split-down",
    ["normal:ctrl+w+h"] = "root:switch-to-left",
    ["normal:ctrl+w+j"] = "root:switch-to-down",
    ["normal:ctrl+w+k"] = "root:switch-to-up",
    ["normal:ctrl+w+l"] = "root:switch-to-right",
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
    ["visual+x"] = "vim:delete-selection",
    ["visual+y"] = "vim:copy"
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
