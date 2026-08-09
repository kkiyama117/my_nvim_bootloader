local M = {}
local is_debug = vim.g['vimrc#is_debug']

-- ==========================================================================
-- Safe dpp installer
-- ==========================================================================
-- TODO: use `getFailed` of dpp and autofix broken plugins
-- ==========================================================================

--- Parse dpp-ext-toml files and return the plugin *names* defined in them.
---
--- dpp registers each plugin under `basename(repo)` (see
--- `dpp-ext-toml/main.ts`: `name: plugin.name ?? basename(plugin.repo)`),
--- and the installer's `names` filter matches `plugin.name` (see
--- `getPlugins()` in `dpp-ext-installer/main.ts`). So we must return the
--- last path segment of each `repo = "..."` entry, not the full `owner/name`.
---
--- Only the simple `repo = "owner/name"` shorthand is supported; every repo
--- in `deps/*.toml` uses this form.
---@param toml_paths string[] toml file paths (absolute or `$VAR`-expanded)
---@return string[] names unique plugin names (basename of `repo`)
local function collect_plugin_names_from_tomls(toml_paths)
  local seen = {}
  local names = {}
  for _, p in ipairs(toml_paths) do
    p = vim.fn.expand(p)
    if vim.fn.filereadable(p) == 1 then
      for _, line in ipairs(vim.fn.readfile(p) or {}) do
        local repo = line:match('^%s*repo%s*=%s*"([^"]+)"')
        if repo then
          local name = repo:match('([^/]+)$') or repo
          if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
          end
        end
      end
    end
  end
  return names
end

--- Build installer action params, scoped to `names` when given.
---@param names string[]|nil plugin names; nil/empty = all plugins
---@return table params empty dict for all, `{ names = {...} }` when scoped.
--- Note: an empty Lua `{}` serializes as a Vim *List* `[]`, which dpp's
--- `extAction` rejects (`isRecord`); `vim.empty_dict()` serializes as a Dict.
local function installer_params(names)
  if names and #names > 0 then
    return { names = names }
  end
  return vim.empty_dict()
end

--- Ask the user to confirm a Neovim restart, then restart if confirmed.
---
--- Headless / UI-less sessions (detached installers, embedded servers,
--- subagent nvims) must NEVER restart: there `vim.fn.confirm` returns the
--- default (`&Yes`) without asking, and `:restart` re-uses `v:argv` (any
--- `-c lua ...` args included) and leaves a dangling process when no UI
--- handles the "restart" event — together this caused an infinite
--- install/restart loop that also leaked stuck `nvim` processes.
---@param reason string reason shown in the prompt
local function ask_restart(reason)
  if #vim.api.nvim_list_uis() == 0 then
    vim.notify(
      '[MY_NVIM_BOOTLOADER#dpp]: headless session, restart skipped',
      vim.log.levels.INFO
    )
    return
  end
  vim.ui.select({ 'YES', 'NO' }, {
    prompt = ('[MY_NVIM_BOOTLOADER#dpp]: restart required (%s)'):format(reason),
  }, function(choice)
    if choice == 'YES' then
      vim.cmd('restart +xall')
    else
      vim.notify(
        '[MY_NVIM_BOOTLOADER#dpp]: restart skipped by user',
        vim.log.levels.INFO
      )
    end
  end)
end

---When config_files are updated, do everythings written below
---
---  1: install plugins if not installed
---  2: update plugins if needed
---  3: call dpp#make_state (my_nvim_bootloader/dpp/make_state.lua)
---
---When `names` is non-empty, install / `checkNotUpdated` are scoped to only
---those plugins (used when a config file changed); when nil/empty, all
---plugins are processed (used by `:DppUpdate` / full update).
---@param args { cache_home: string,cache_github:string, dpp_script: string}
---@param names string[]|nil plugin names to scope to; nil = all plugins
local function hooks_config_files_updated(args, names)
  local params = installer_params(names)
  -- 1: check all plugins are installed
  if
    #vim.fn['dpp#sync_ext_action']('installer', 'getNotInstalled', params) > 0
  then
    -- 1-A: if exists, then install and make AutoCmd to hook `2`
    vim.fn['dpp#async_ext_action']('installer', 'install', params)
    vim.api.nvim_create_autocmd('User', {
      pattern = 'Dpp:ext:installer:updateDone',
      group = vim.g['vimrc#augroup'],
      once = true,
      callback = function()
        -- call `2`
        vim.fn['dpp#async_ext_action']('installer', 'checkNotUpdated', params)
      end,
    })
  else
    -- 1-B: if `1` is skipped, do `2` directly.
    vim.fn['dpp#async_ext_action']('installer', 'checkNotUpdated', params)
  end
  -- 2: AutoCmd that wait `checkNotUpdated` and then do `3`
  -- Even if no plugins are updated, this should cbe called
  vim.api.nvim_create_autocmd('User', {
    pattern = 'Dpp:ext:installer:updateDone',
    group = vim.g['vimrc#augroup'],
    once = true,
    callback = function()
      -- 3: then call dpp#make_state to save new state
      require('my_nvim_bootloader/dpp/make_state').run({
        cache_home = args.cache_home,
        cache_github = args.cache_github,
        dpp_script = args.dpp_script,
      })
    end,
  })
end

---@param args { cache_home: string,cache_github:string, dpp_script: string}
---@param force boolean if true, force full update of ALL plugins
local function dpp_update(args, force)
  local updated_files = vim.fn['dpp#check_files'](args.cache_home)
  local has_updated = type(updated_files) == 'table'
    and not vim.tbl_isempty(updated_files)
  if has_updated or force then
    vim.notify('[MY_NVIM_BOOTLOADER#dpp]: Update started', vim.log.levels.WARN)
    -- Mark in-flight so VimLeavePre can wait for completion.
    -- Cleared by the Dpp:makeStatePost autocmd below.
    vim.g['my_nvim_bootloader#under_dpp_updating'] = true

    local names
    if force then
      -- `:DppUpdate` / forced full update: process every plugin.
      names = nil
      hooks_config_files_updated(args, names)
    else
      -- Config file changed: scope install / `checkNotUpdated` to only the
      -- plugins defined in the changed toml files, so we fetch a handful of
      -- repos instead of all 105.
      local toml_files = vim.tbl_filter(function(f)
        return type(f) == 'string' and f:sub(-5) == '.toml'
      end, updated_files)
      names = collect_plugin_names_from_tomls(toml_files)
      if #names == 0 then
        -- No toml among the changed files (e.g. only `dpp.ts` / a lua hook
        -- changed): nothing for the installer to do, just rebuild state.
        vim.notify(
          '[MY_NVIM_BOOTLOADER#dpp]: No toml changed; rebuild state only',
          vim.log.levels.INFO
        )
        require('my_nvim_bootloader/dpp/make_state').run({
          cache_home = args.cache_home,
          cache_github = args.cache_github,
          dpp_script = args.dpp_script,
        })
        return
      end
      if is_debug then
        vim.notify(
          ('[MY_NVIM_BOOTLOADER#dpp]: scoped update to %d plugin(s): %s'):format(
            #names,
            table.concat(names, ', ')
          ),
          vim.log.levels.DEBUG
        )
      end
      hooks_config_files_updated(args, names)
    end
  else
    vim.notify(
      '[MY_NVIM_BOOTLOADER#dpp]: No config files are updated',
      vim.log.levels.INFO
    )
  end
end

-- ==========================================================================
-- TOML-save flow
-- ==========================================================================
-- `dpp#check_files` only inspects files recorded in the *previous* state
-- (`g:dpp.state.check_files`); a brand-new toml is invisible to it, so the
-- gated `dpp_update` path bails out with "No config files are updated" and
-- never even runs `make_state`.  Even if it did, the installer's
-- `getNotInstalled` reads `g:dpp.state.plugins` (the previous state), so
-- newly-added plugins are unknown until `make_state` writes `state.vim` and
-- the state is reloaded.
--
-- Therefore the correct order for a toml save is:
--   1. make_state    (re-globs deps/*.toml, registers the new plugins)
--   2. reload state (so dpp#util#_get_plugins returns the new plugins)
--   3. install      (getNotInstalled now sees the new plugins)
--   4. ask to restart  (load the new state + cloned plugins)
-- There is a single `Dpp:makeStatePost` handler (`on_make_state_post`
-- below), registered once at boot by `autocmds.setup_autocmd_make_state_post`.
-- It branches on `install_pending`:
--   * toml-save flow: reload state so the new plugins appear in
--     `g:dpp.state.plugins`, then `install` them; a one-shot
--     `Dpp:ext:installer:updateDone` autocmd asks to restart afterwards.
--   * default: verify the rebuilt state is loadable, then ask to restart.
local install_pending = false

--- Pending one-shot `Dpp:ext:installer:updateDone` handler registered by
--- `dpp_update_toml` (asks to restart after the install).  Module-level so
--- `on_make_state_post` can drop it when the install is skipped (otherwise
--- it would fire on a later, unrelated `updateDone` and ask to restart for
--- no reason).
local install_done_id = nil

--- Source the (re)built state into the *running* session.
---
--- `dpp#min#load_state` is not a passive check: it sources the generated
--- `startup.vim`, whose dpp-ext-lazy block re-registers a one-shot
--- `SafeState` autocmd defining the dummy `on_map` mappings with `<unique>`.
--- In a live session those mappings already exist (boot-time dummies, or the
--- real ones once the plugin loaded), so the next idle moment raises E227
--- for every on_map mapping.  The boot-time autocmd was `++once` and has
--- already fired, so clearing the group's SafeState handler after sourcing
--- drops only the freshly-added duplicate.
---@param cache_home string
---@return boolean ok true when the state was loaded successfully
local function load_state_live(cache_home)
  local ok, result = pcall(vim.fn['dpp#min#load_state'], cache_home)
  pcall(vim.api.nvim_clear_autocmds, {
    group = 'dpp-ext-lazy',
    event = 'SafeState',
  })
  return ok and result == 0
end

--- Single `Dpp:makeStatePost` handler.
---
--- In the toml-save flow (`install_pending`): reload the freshly-written
--- state so `dpp#util#_get_plugins` returns the new plugins, then install
--- every not-installed plugin.  Restart happens on
--- `Dpp:ext:installer:updateDone` (registered by `dpp_update_toml`).
--- Otherwise: verify the rebuilt state is loadable and ask to restart (prevents
--- infinite restart loops when the state is consistently broken).
function M.on_make_state_post()
  local cache_home = vim.g['my_nvim_bootloader#dpp#cache_home']
  if install_pending then
    install_pending = false
    vim.notify(
      '[MY_NVIM_BOOTLOADER#dpp]: make_state done; reload state -> install',
      vim.log.levels.WARN
    )
    if not cache_home then
      vim.notify(
        '[MY_NVIM_BOOTLOADER#dpp]: cache_home not set, skip install',
        vim.log.levels.ERROR
      )
      return
    end
    -- 2: reload so g:dpp.state.plugins contains the new plugins.
    if not load_state_live(cache_home) then
      vim.notify(
        '[MY_NVIM_BOOTLOADER#dpp]: state reload failed after make_state',
        vim.log.levels.ERROR
      )
      return
    end
    -- 3: install every not-installed plugin (incl. the new ones).
    -- `vim.empty_dict()` (not `{}`) so it serializes as a Dict record;
    -- an empty Lua `{}` becomes a List `[]` and dpp rejects it.
    if
      #vim.fn['dpp#sync_ext_action'](
        'installer',
        'getNotInstalled',
        vim.empty_dict()
      ) > 0
    then
      vim.fn['dpp#async_ext_action']('installer', 'install', vim.empty_dict())
    else
      -- Nothing to install; the pending `updateDone` handler will never
      -- fire, so drop it and ask to restart right here.
      if install_done_id then
        pcall(vim.api.nvim_del_autocmd, install_done_id)
        install_done_id = nil
      end
      ask_restart('dpp state rebuilt (nothing to install)')
    end
    return
  end

  -- Default path: verify the rebuilt state is loadable, then install
  -- every not-installed plugin (the user plugins from deps/*.toml).
  -- Previously this only asked to restart, leaving plugins uninstalled.
  vim.notify('dpp make_state() may be done successfully', vim.log.levels.WARN)
  if cache_home == nil then
    vim.notify(
      '[MY_NVIM_BOOTLOADER#AutoCmd]: cache_home not set, skip install',
      vim.log.levels.ERROR
    )
    return
  end
  if load_state_live(cache_home) then
    vim.notify(
      '[MY_NVIM_BOOTLOADER#AutoCmd]: state verified, installing plugins...',
      vim.log.levels.WARN
    )
    if
      #vim.fn['dpp#sync_ext_action'](
        'installer',
        'getNotInstalled',
        vim.empty_dict()
      ) > 0
    then
      vim.fn['dpp#async_ext_action']('installer', 'install', vim.empty_dict())
    else
      ask_restart('dpp state rebuilt (nothing to install)')
    end
  else
    vim.notify(
      '[MY_NVIM_BOOTLOADER#AutoCmd]: state still broken after make_state, skip install',
      vim.log.levels.ERROR
    )
  end
end

---@param args { cache_home: string, cache_github: string, dpp_script: string }
local function dpp_update_toml(args)
  vim.notify(
    '[MY_NVIM_BOOTLOADER#dpp]: TOML updated; make_state -> install',
    vim.log.levels.WARN
  )
  install_pending = true

  -- 4: after install finishes, ask to restart to load the new state + plugins.
  install_done_id = vim.api.nvim_create_autocmd('User', {
    pattern = 'Dpp:ext:installer:updateDone',
    group = vim.g['vimrc#augroup'],
    once = true,
    callback = function()
      install_done_id = nil
      ask_restart('plugins installed')
    end,
  })

  -- 1: make_state (async). The global `Dpp:makeStatePost` handler
  -- (`on_make_state_post`) picks up `install_pending` and runs 2 + 3.
  local ok = require('my_nvim_bootloader/dpp/make_state').run(args)
  if not ok then
    -- make_state never started; clear the flag and drop the pending
    -- `updateDone` handler so it does not fire on a later install.
    install_pending = false
    if install_done_id then
      pcall(vim.api.nvim_del_autocmd, install_done_id)
      install_done_id = nil
    end
  end
end

M.collect_plugin_names_from_tomls = collect_plugin_names_from_tomls
M.dpp_update = dpp_update
M.dpp_update_force = function(args)
  dpp_update(args, true)
end
M.dpp_update_toml = dpp_update_toml
return M

