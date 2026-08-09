--- Auto-update hooks for dpp state and plugin sync.

local M = {}
local is_debug = vim.g['vimrc#is_debug']

local my_autocmds = vim.api.nvim_create_augroup('vimrc', { clear = false })

--- Whether this session has a UI attached (interactive nvim).
---
--- UI-less sessions — the kakehashi host (`nvim --embed`), detached
--- installers, subagent nvims — must not register the config-change
--- watchers or schedule make_state: they would duplicate the interactive
--- session's rebuild, and `dpp#make_state` clears state.vim FIRST, so a
--- concurrent rebuild can leave the state missing (which previously
--- re-triggered the install/restart loop).
---@return boolean
local function has_ui()
  local uis = vim.api.nvim_list_uis()
  return uis ~= nil and not vim.tbl_isempty(uis)
end

-- ==========================================================================
-- Utilities
-- ==========================================================================
--- Return whether `file` lies inside the `vim.env.NVIM_CONFIG_HOME`.
---
---@param file string Absolute or relative path
---@return boolean
local function is_under_nvim_config_home(file)
  local nvim_config_home = vim.fs.normalize(vim.env.NVIM_CONFIG_HOME)
  if file == '' then
    return false
  end
  file = vim.fs.normalize(file)
  local sep = package.config:sub(1, 1)
  return file == nvim_config_home
    or vim.startswith(file, nvim_config_home .. sep)
end

-- ==========================================================================
-- AutoCmds
-- ==========================================================================

--- Deno fires Dpp:makeStatePost only after both state.vim and startup.vim
--- are written, so this is the reliable "make_state finished" signal.
---
--- This only registers the autocmd; the actual branch logic (toml-save
--- install vs. verify-and-restart) lives in
--- `my_nvim_bootloader/dpp/auto_update.on_make_state_post`.
---
---@return boolean true if setup finished successfully.
local function setup_autocmd_make_state_post()
  vim.api.nvim_create_autocmd('User', {
    pattern = 'Dpp:makeStatePost',
    group = vim.api.nvim_create_augroup('vimrc', { clear = false }),
    callback = function()
      require('my_nvim_bootloader/dpp/auto_update').on_make_state_post()
    end,
  })
  return true
end

local function setup_autocmd_load_state_failed(args)
  -- Headless / embedded sessions must not rebuild the state: the rebuild
  -- clears state.vim first and races the interactive session's rebuild.
  if not has_ui() then
    vim.notify(
      '[MY_NVIM_BOOTLOADER#AutoCmd]: no UI; skipping make_state recovery (headless session)',
      vim.log.levels.WARN
    )
    return false
  end
  local dpp_cache_home = args.cache_home
  local dpp_cache_github = args.cache_github
  local dpp_denops_script = args.dpp_script
  if
    dpp_cache_home == nil
    or dpp_cache_github == nil
    or dpp_denops_script == nil
  then
    vim.notify('[MY_NVIM_BOOTLOADER#AutoCmd]: invalid args', vim.log.levels.ERROR)
    return false
  else
    -- if denops is ready, call dpp#make_state directly.
    -- Do NOT route through fallback F1 → dpp_update_force, because
    -- dpp#min#load_state already failed and dpp functions that check
    -- initialization (dpp#check_files, dpp#sync_ext_action, etc.) will
    -- refuse to work. dpp#make_state is designed to run without prior
    -- initialization and is the correct recovery path.
    vim.api.nvim_create_autocmd('User', {
      pattern = 'DenopsReady',
      once = true,
      callback = function()
        vim.notify(
          '[MY_NVIM_BOOTLOADER#AutoCmd]: DenopsReady -> make_state',
          vim.log.levels.WARN
        )
        require('my_nvim_bootloader/dpp/make_state').run({
          cache_home = vim.g['my_nvim_bootloader#dpp#cache_home'],
          cache_github = vim.g['my_nvim_bootloader#dpp#cache_github'],
          dpp_script = vim.g['my_nvim_bootloader#dpp#denops_script'],
        })
      end,
    })
    vim.notify(
      '[MY_NVIM_BOOTLOADER#AutoCmd]: Wait DenopsReady',
      vim.log.levels.WARN
    )
  end
end

--- Register autocmds that react to config file writes.
---
--- Watches `*.lua`, `*.vim`, `*.toml`, `*.ts`, and vimrc files under
--- `$NVIM_CONFIG_HOME`. Intended to call `dpp#check_files` and
--- `dpp#make_state` when configs change (not yet wired up).
---@param args {cache_home: string,cache_github:string, dpp_script: string}
---@return boolean true if setup finished successfully.
local function setup_autocmd_load_state_succeeded(args)
  -- Headless / embedded sessions must not watch config writes: every save
  -- would trigger a duplicate make_state that clears state.vim out from
  -- under the interactive session's rebuild.
  if not has_ui() then
    vim.notify(
      '[MY_NVIM_BOOTLOADER#AutoCmd]: no UI; skipping update watchers (headless session)',
      vim.log.levels.WARN
    )
    return false
  end
  local dpp_cache_home = args.cache_home
  local dpp_cache_github = args.cache_github
  local dpp_denops_script = args.dpp_script
  if
    dpp_cache_home == nil
    or dpp_cache_github == nil
    or dpp_denops_script == nil
  then
    vim.notify('[MY_NVIM_BOOTLOADER#AutoCmd]: invalid args', vim.log.levels.ERROR)
    return false
  else
    -- When BufWritePost, check buf is config files,
    -- and update plugins and dpp cache if so.
    vim.api.nvim_create_autocmd('BufWritePost', { -- {{{
      pattern = '*.dpp,*.lua,*.vim,*.toml,*.ts,vimrc,.vimrc',
      group = my_autocmds,
      callback = function(ev)
        local filepath = vim.api.nvim_buf_get_name(ev.buf)
        if is_under_nvim_config_home(filepath) then
          if filepath:match('%.toml$') then
            -- TOML file: make_state first (registers new plugins), then
            -- install after the state is reloaded.  We cannot use the
            -- `dpp#check_files`-gated `dpp_update` path here because
            -- check_files cannot see a newly-added toml.
            vim.notify(
              '[MY_NVIM_BOOTLOADER#AutoCmd]: TOML config updated; make_state -> install',
              vim.log.levels.WARN
            )
            return require('my_nvim_bootloader/dpp/auto_update').dpp_update_toml({
              cache_home = dpp_cache_home,
              cache_github = dpp_cache_github,
              dpp_script = dpp_denops_script,
            })
          else
            -- Non-TOML file: only rebuild state (skip install/update)
            vim.notify(
              '[MY_NVIM_BOOTLOADER#AutoCmd]: Config updated, rebuilding state',
              vim.log.levels.WARN
            )
            return require('my_nvim_bootloader/dpp/make_state').run({
              cache_home = dpp_cache_home,
              cache_github = dpp_cache_github,
              dpp_script = dpp_denops_script,
            })
          end
        else
          -- Skip if buf is not the config file's one
          return true
        end
      end,
    }) -- }}}
    -- Create custom Command to force update {{{
    vim.api.nvim_create_user_command('DppUpdate', function()
      require('my_nvim_bootloader/dpp/auto_update').dpp_update({
        cache_home = dpp_cache_home,
        cache_github = dpp_cache_github,
        dpp_script = dpp_denops_script,
      }, true)
    end, {
      desc = 'Rebuild dpp plugin state manually',
    })
    -- }}}
    return true
  end
end

M.setup_autocmd_make_state_post = setup_autocmd_make_state_post
M.setup_autocmd_load_state_succeeded = setup_autocmd_load_state_succeeded
M.setup_autocmd_load_state_failed = setup_autocmd_load_state_failed
return M

