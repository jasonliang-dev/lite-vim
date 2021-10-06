# lite-vim

vim-like keybindings for [the lite text editor](https://github.com/rxi/lite).

## Key Configuration Example

```lua
-- data/user/init.lua

local keymap = require "core.keymap"
local config = require "core.config"
local command = require "core.command"

-- use space as leader key
local leader = "space"

-- register the leader key in normal and visual mode.
-- in normal mode, make `space w` a key combo prefix
config.vim_stroke_combos = {
    normal = {
        [leader] = {
            w = {}
        }
    },
    visual = {
       [leader] = {}
    }
}

-- let the plugin read `config.vim_stroke_combos`
command.perform "vim:use-user-stroke-combos"

keymap.add {
    -- `<leader> w h/j/k/l` to move between splits
    ["normal " .. leader .. " w h"] = "root:switch-to-left",
    ["normal " .. leader .. " w j"] = "root:switch-to-down",
    ["normal " .. leader .. " w k"] = "root:switch-to-up",
    ["normal " .. leader .. " w l"] = "root:switch-to-right",
    
    -- normal mode and visual mode bindings
    ["normal " .. leader .. " ="] = "my-formatter:format",
    ["visual " .. leader .. " ="] = "my-formatter:format-region",
    
    -- most default bindings are inaccessible from normal mode
    ["normal ctrl+pageup"] = "root:move-tab-left",
    ["normal ctrl+pagedown"] = "root:move-tab-right",

    -- no "normal" or "visual" prefix. this is insert mode
    ["ctrl+p"] = {"command:select-previous", "autocomplete:previous"},
    ["ctrl+n"] = {"command:select-next", "autocomplete:next"}
}
```
