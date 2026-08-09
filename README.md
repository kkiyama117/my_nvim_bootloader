# my_nvim_bootloader

Bootloader for [dpp.vim](https://github.com/Shougo/dpp.vim) plugin manager.

Handles initial bootstrap and recovery when the compiled plugin state is
missing or broken. See [doc](./doc/my-nvim-bootloader.txt) for the full
flow (success path, F1/F2/F3 fallbacks, headless mode).

## Requirements

- Neovim 0.9+
- [dpp.vim](https://github.com/Shougo/dpp.vim)
- [denops.vim](https://github.com/vim-denops/denops.vim)

## Usage

Add the plugin directory to `runtimepath` and call `startup()` from your
`init.lua` before VimEnter: >

```lua
vim.opt.runtimepath:prepend(vim.fs.joinpath(
  vim.env.HOME, 'programs', 'nvim_plugins', 'my_nvim_bootloader'
))
require('my_nvim_bootloader').startup()
```

The bootloader sets `g:my_nvim_bootloader#dpp#*` variables (cache paths,
minimum deps) and loads the compiled dpp state. On failure it installs
missing plugins from GitHub and rebuilds the state.

## License

NYSL
