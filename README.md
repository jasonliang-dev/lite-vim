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
    ["normal+" .. leader .. "+w+v"] = "root:split-right",

    ["normal+" .. leader .. "+w+h"] = "root:switch-to-left",
    ["normal+" .. leader .. "+w+j"] = "root:switch-to-down",
    ["normal+" .. leader .. "+w+k"] = "root:switch-to-up",
    ["normal+" .. leader .. "+w+l"] = "root:switch-to-right",

    ["normal+" .. leader .. "+="] = "my-formatter:luafmt",
    ["visual+" .. leader .. "+="] = "my-formatter:luafmt-region",

    -- no prefix. this is insert mode.
    ["ctrl+p"] = "autocomplete:previous",
    ["ctrl+n"] = "autocomplete:next"
}
```
