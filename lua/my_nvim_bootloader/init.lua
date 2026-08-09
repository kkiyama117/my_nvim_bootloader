--- Main bootloader entry point for dpp.vim.
---
--- Sets dpp cache paths, prepends minimum dependencies to runtimepath, and
--- attempts to load a compiled dpp state.
--- On failure, delegates to `my_nvim_bootloader/fallback` (and its min/dpp
--- rescue routines) as appropriate.
local M = {}

local is_debug = vim.g['vimrc#is_debug']

-- ==========================================================================
-- Runtimepath self-registration
-- ==========================================================================
--- Plugin root directory, derived from this file's source path
--- (`.../lua/my_nvim_bootloader/init.lua` → up 3 → plugin root).
local plugin_root = nil
do
  local info = debug.getinfo(1, 'S')
  local src = info and info.source or ''
  if src:sub(1, 1) == '@' then
    src = src:sub(2)
  end
  if src ~= '' then
    plugin_root = vim.fs.normalize(src)
    for _ = 1, 3 do
      plugin_root = vim.fs.dirname(plugin_root)
    end
  end
end

--- Ensure this plugin's root is on `runtimepath`.
---
--- `dpp#min#load_state` sources the compiled `startup.vim`, which REPLACES
--- `&runtimepath` with the state's plugin list. When this plugin is not yet
--- recorded in the state (e.g. right after the host config switched to it),
--- the host-added entry would vanish and later
--- `require('my_nvim_bootloader/...')` calls would fail. Re-prepending the
--- root (idempotent) keeps every module resolvable in all branches.
local function ensure_rtp()
  if plugin_root == nil then
    return
  end
  local rtp = vim.opt.runtimepath:get()
  if not vim.tbl_contains(rtp, plugin_root) then
    vim.opt.runtimepath:prepend(plugin_root)
  end
end

ensure_rtp()

--- Set global variables consumed by dpp.vim and dpp-ext plugins.
---
--- Configures `my_nvim_bootloader#dpp#*` paths (cache, GitHub clone dir, local dir,
--- denops script) and the minimum dependency list. Values must stay in sync
--- with the dpp-ext plugin configuration.
local function set_dpp_global_value() -- {{{
  vim.g['my_nvim_bootloader#dpp#minimum_deps'] = {
    'Shougo/dpp.vim',
    'Shougo/dpp-ext-lazy',
    'vim-denops/denops.vim',
  }
  local nvim_config_home = vim.env.NVIM_CONFIG_HOME or vim.fn.stdpath('config')
  local nvim_cache_home = vim.env.NVIM_CACHE_HOME or vim.fn.stdpath('cache')
  vim.g['my_nvim_bootloader#dpp#cache_home'] =
    vim.fs.joinpath(nvim_cache_home, 'dpp')
  vim.g['my_nvim_bootloader#dpp#cache_github'] =
    vim.fs.joinpath(
      vim.g['my_nvim_bootloader#dpp#cache_home'],
      'repos',
      'github.com'
    )
  vim.g['my_nvim_bootloader#dpp#cache_local'] =
    vim.fs.joinpath(vim.g['my_nvim_bootloader#dpp#cache_home'], 'local')
  vim.g['my_nvim_bootloader#dpp#denops_script'] =
    vim.fs.joinpath(nvim_config_home, 'denops', 'dpp.ts')
  if is_debug then -- {{{
    vim.notify(
      ('[MY_NVIM_BOOTLOADER]: dpp#cache_home = %s'):format(
        vim.g['my_nvim_bootloader#dpp#cache_home']
      ),
      vim.log.levels.DEBUG
    )
    vim.notify(
      ('[MY_NVIM_BOOTLOADER]: dpp#cache_github = %s'):format(
        vim.g['my_nvim_bootloader#dpp#cache_github']
      ),
      vim.log.levels.DEBUG
    )
    vim.notify(
      ('[MY_NVIM_BOOTLOADER]: dpp#cache_local = %s'):format(
        vim.g['my_nvim_bootloader#dpp#cache_local']
      ),
      vim.log.levels.DEBUG
    )
    vim.notify(
      ('[MY_NVIM_BOOTLOADER]: dpp#denops_script= %s'):format(
        vim.g['my_nvim_bootloader#dpp#denops_script']
      ),
      vim.log.levels.DEBUG
    )
  end -- }}}
end -- }}}

--- Run the primary dpp startup sequence.
---
--- 1. Set dpp global variables.
--- 2. Prepend minimum deps (`dpp.vim`, `dpp-ext-lazy`, `denops.vim`) to runtimepath.
--- 3. Call `dpp#min#load_state`; on success trigger auto-update setup,
---    on non-zero result rebuild state via `my_nvim_bootloader/dpp/make_state`,
---    on missing function fall back to `my_nvim_bootloader/fallback`.
local function startup()
  -- 0: Set env variable
  set_dpp_global_value()
  -- 1: Add minimum_deps to rtp
  for _, repo in ipairs(vim.g['my_nvim_bootloader#dpp#minimum_deps']) do
    vim.opt.runtimepath:prepend(
      vim.fs.joinpath(vim.g['my_nvim_bootloader#dpp#cache_github'], repo)
    )
    if is_debug then
      vim.notify(
        ('[MY_NVIM_BOOTLOADER]: rtp:prepend %s'):format(repo),
        vim.log.levels.DEBUG
      )
    end
  end
  -- 2: Call dpp#load_state;
  --    `dpp.vim` COMPILE the vimrc and load it from the cache dir.
  --    This process doesn't depend on `denops.vim`; so we don't need to load it here.
  local ok, result =
    pcall(vim.fn['dpp#min#load_state'], vim.g['my_nvim_bootloader#dpp#cache_home'])
  -- startup.vim replaced &runtimepath; re-assert this plugin's entry before
  -- any internal require below.
  ensure_rtp()
  if ok then
    if result == 0 then
      -- When Succeeded, set AutoCmds that is hooked by configuration files updated
      require('my_nvim_bootloader/autocmds').setup_autocmd_load_state_succeeded({
        cache_home = vim.g['my_nvim_bootloader#dpp#cache_home'],
        cache_github = vim.g['my_nvim_bootloader#dpp#cache_github'],
        dpp_script = vim.g['my_nvim_bootloader#dpp#denops_script'],
      })
      require('my_nvim_bootloader/autocmds').setup_autocmd_make_state_post()
      if is_debug then
        vim.notify(
          '[MY_NVIM_BOOTLOADER]: call dpp#min#load_state successfully',
          vim.log.levels.INFO
        )
      end
      return true
    else
      -- F1: `dpp#load_state` returned non-zero value (state is broken); call `dpp#make_state`
      vim.notify(
        '[MY_NVIM_BOOTLOADER]: call dpp#min#load_state failed.',
        vim.log.levels.WARN
      )
      -- we should load denops manually to call dpp#make_state; `--noplugin` is set.
      if vim.fn.has('nvim') == 1 then
        local denops_path = vim.fs.joinpath(
          vim.g['my_nvim_bootloader#dpp#cache_github'],
          'vim-denops',
          'denops.vim'
        )
        -- Ensure denops.vim is installed before trying to load it.
        -- Without it, DenopsReady never fires and the F1 recovery chain
        -- dead-ends: make_state (and its F3 fallback) is never reached.
        if vim.fn.isdirectory(denops_path) == 0 then
          vim.notify(
            '[MY_NVIM_BOOTLOADER]: denops.vim not found, installing...',
            vim.log.levels.WARN
          )
          require('my_nvim_bootloader/min/github_installer').install_from_remote({
            repo = 'https://github.com/vim-denops/denops.vim',
            dest = denops_path,
          })
        end
        vim.opt.runtimepath:prepend(denops_path)
        vim.cmd([[runtime! plugin/denops.vim]])
      end
      require('my_nvim_bootloader/autocmds').setup_autocmd_load_state_failed({
        cache_home = vim.g['my_nvim_bootloader#dpp#cache_home'],
        cache_github = vim.g['my_nvim_bootloader#dpp#cache_github'],
        dpp_script = vim.g['my_nvim_bootloader#dpp#denops_script'],
      })
      -- In headless mode, setup_autocmd_load_state_failed skips the
      -- DenopsReady autocord (no UI to avoid racing interactive sessions).
      -- But if this is the only session, the state would never be rebuilt.
      -- Start denops and call make_state directly instead.
      if #vim.api.nvim_list_uis() == 0 then
        vim.notify(
          '[MY_NVIM_BOOTLOADER]: headless session, starting denops directly...',
          vim.log.levels.WARN
        )
        vim.fn['denops#server#start']()
        vim.wait(15000, function()
          return vim.fn['denops#server#status']() == 'running'
        end)
        if vim.fn['denops#server#status']() == 'running' then
          vim.notify(
            '[MY_NVIM_BOOTLOADER]: denops ready, calling make_state...',
            vim.log.levels.WARN
          )
          require('my_nvim_bootloader/dpp/make_state').run({
            cache_home = vim.g['my_nvim_bootloader#dpp#cache_home'],
            cache_github = vim.g['my_nvim_bootloader#dpp#cache_github'],
            dpp_script = vim.g['my_nvim_bootloader#dpp#denops_script'],
          })
          -- Register installer-completion listener BEFORE waiting, so we
          -- don't miss the Dpp:ext:installer:updateDone event.
          local install_done = false
          vim.api.nvim_create_autocmd('User', {
            pattern = 'Dpp:ext:installer:updateDone',
            group = vim.api.nvim_create_augroup(
              'vimrc_boot_install',
              { clear = true }
            ),
            once = true,
            callback = function()
              install_done = true
            end,
          })
          -- Wait for state files to be written (async make_state completion)
          local state_file = vim.fs.joinpath(
            vim.g['my_nvim_bootloader#dpp#cache_home'],
            'nvim',
            'state.vim'
          )
          vim.wait(60000, function()
            return vim.fn.filereadable(state_file) == 1
          end)
          if vim.fn.filereadable(state_file) == 1 then
            vim.notify(
              '[MY_NVIM_BOOTLOADER]: state rebuilt successfully',
              vim.log.levels.INFO
            )
            -- Dpp:makeStatePost has fired and on_make_state_post triggered
            -- the async installer for user plugins. Wait for it to finish.
            local has_pending = false
            pcall(function()
              has_pending =
                #vim.fn['dpp#sync_ext_action'](
                  'installer',
                  'getNotInstalled',
                  vim.empty_dict()
                ) > 0
            end)
            if has_pending then
              vim.notify(
                '[MY_NVIM_BOOTLOADER]: waiting for plugin install...',
                vim.log.levels.WARN
              )
              vim.wait(120000, function()
                return install_done
              end)
              vim.notify(
                '[MY_NVIM_BOOTLOADER]: plugin install complete',
                vim.log.levels.INFO
              )
            end
          end
        end
      end
      require('my_nvim_bootloader/autocmds').setup_autocmd_make_state_post()
      vim.notify(
        '[MY_NVIM_BOOTLOADER]: set AutoCmds for recover',
        vim.log.levels.INFO
      )
      return false
    end
  else
    -- F2: dpp#min#load_state function not found etc (E117); Fallback
    vim.notify(
      '[MY_NVIM_BOOTLOADER]: call dpp#min#load_state is missing',
      vim.log.levels.ERROR
    )
    require('my_nvim_bootloader/fallback').startup({
      error_number = 2,
      missing_plugins = vim.g['my_nvim_bootloader#dpp#minimum_deps'],
    })
    require('my_nvim_bootloader/autocmds').setup_autocmd_make_state_post()
    return false
  end
end

M.startup = startup
return M

