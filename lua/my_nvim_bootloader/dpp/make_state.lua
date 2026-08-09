--- Full-featured dpp state builder.
---
--- Loads normal dpp dependencies (denops, dpp-ext plugins), validates the
--- plugin cache, and invokes `dpp#make_state` to recompile the vimrc.
--- Used when `dpp#min#load_state` fails or the cached state is broken (F1).
local M = {}
local is_debug = vim.g['vimrc#is_debug']
-- dpp#make_state call deno, but denops config may not set if dpp.vim config is
-- broken. So set `denops#deno` here also.
vim.g['denops#deno'] = vim.fs.abspath(
  vim.fs.joinpath(
    vim.env.MISE_DATA_DIR,
    'installs',
    'deno',
    'latest',
    'bin',
    'deno'
  ) or 'deno'
)

--- Plugins required to run `dpp#make_state` (denops + dpp-ext stack).
---@type string[]
local normal_deps = {
  'Shougo/dpp-ext-toml',
  'Shougo/dpp-ext-local',
  'Shougo/dpp-ext-installer',
  'Shougo/dpp-ext-packspec',
  'Shougo/dpp-protocol-git',
  'Shougo/dpp-protocol-http',
  'Shougo/dpp-ext-lazy',
  'vim-denops/denops.vim',
}

--- Check whether a plugin directory exists and is non-empty.
---@param plugin_path string Absolute path to the cloned plugin directory
---@return boolean
local function check_plugin_exists_in_cache(plugin_path)
  local stat = vim.uv.fs_stat(plugin_path)
  if not stat or stat.type ~= 'directory' then
    return false
  end
  local ok, entries = pcall(vim.fn.readdir, plugin_path)
  return ok and #entries > 0
end

--- Prepend available normal dependencies to runtimepath.
---
--- Iterates over module-level `normal_deps` and prepends each plugin found
--- under `base_path`. Missing plugins are collected for fallback rescue (F3).
---@param base_path string Absolute path to the GitHub plugin cache (`cache_github`)
---@return boolean ok                    `true` when every normal dep is present
---@return string[] missing_plugin_repos Repository names (e.g. `"Shougo/dpp-ext-toml"`) not found in cache
local function load_normal_deps(base_path)
  local missing_plugin_repos = {}
  for _, repo in ipairs(normal_deps) do
    local plugin_path = vim.fs.joinpath(base_path, repo)
    if check_plugin_exists_in_cache(plugin_path) then
      vim.opt.runtimepath:prepend(plugin_path)
      if is_debug then
        vim.notify(
          ('[MY_NVIM_BOOTLOADER]: rtp:prepend %s'):format(plugin_path),
          vim.log.levels.DEBUG
        )
      end
    else
      table.insert(missing_plugin_repos, repo)
      if is_debug then
        vim.notify(
          ('[MY_NVIM_BOOTLOADER]: plugin not found: %s'):format(plugin_path),
          vim.log.levels.WARN
        )
      end
    end
  end
  if #missing_plugin_repos == 0 then
    return true, {}
  end
  return false, missing_plugin_repos
end

--- Rebuild the dpp plugin state by calling `dpp#make_state`.
---
--- Validates arguments, loads normal deps into runtimepath, and on missing
--- deps delegates to `my_nvim_bootloader/fallback` (F3). Registers a `Dpp:makeStatePost`
--- autocmd to restart Neovim when the async make_state completes.
---@param args { cache_home: string, cache_github: string, dpp_script: string }
---@return boolean `true` when make_state was invoked or fallback succeeded
function make_state(args)
  if is_debug then
    vim.notify('[MY_NVIM_BOOTLOADER]: make_state called', vim.log.levels.DEBUG)
  end
  -- 1: chech args are correct
  if
    args.cache_home == nil
    or args.cache_github == nil
    or args.dpp_script == nil
  then
    vim.notify(
      '[MY_NVIM_BOOTLOADER#make_state]: invalid args',
      vim.log.levels.ERROR
    )
    return false
  end

  -- 2: Check plugins needed exist, then add runtimepath
  local deps_ok, missing = load_normal_deps(args.cache_github)
  -- F3: missing normal_deps
  if not deps_ok then
    vim.notify(
      ('[MY_NVIM_BOOTLOADER#make_state]: missing deps to use full dpp features: %s'):format(
        table.concat(missing, ', ')
      ),
      vim.log.levels.ERROR
    )
    local is_recovered = require('my_nvim_bootloader/fallback').startup({
      error_number = 3,
      missing_plugins = missing,
    })
    if is_recovered then
      vim.notify(
        '[MY_NVIM_BOOTLOADER#make_state]: fallback rescue succeeded',
        vim.log.levels.INFO
      )
      -- Re-add deps to runtimepath now that they are installed on disk.
      -- Without this, dpp#make_state cannot find the protocol/ext handlers
      -- and logs "Not found protocol: git" / "Not found ext: toml" etc.
      load_normal_deps(args.cache_github)
    else
      vim.notify(
        '[MY_NVIM_BOOTLOADER#make_state]: fallback rescue failed',
        vim.log.levels.ERROR
      )
      return false
    end
  end

  -- call dpp#make_state()
  local ok, result =
    pcall(vim.fn['dpp#make_state'], args.cache_home, args.dpp_script)

  if not ok then
    -- dpp or something isn't found; so fallback
    local error_msg =
      "`dpp#make_state` failed; dpp isn't loaded or variables related dpp.vim are missing"
    vim.notify(error_msg, vim.log.levels.ERROR)
    return require('my_nvim_bootloader/fallback').startup({
      error_number = 2,
      missing_plugins = vim.g['my_nvim_bootloader#dpp#minimum_deps'],
    })
  else
    if result == 1 then
      vim.notify(
        '[MY_NVIM_BOOTLOADER#make_state]: `dpp#make_state` return 1',
        vim.log.levels.ERROR
      )
      return false
    else
      -- result may be {} (wait denops) or 0
      vim.notify(
        '[MY_NVIM_BOOTLOADER#make_state]: `dpp#make_state` is called, but this is async function.',
        vim.log.levels.WARN
      )
      return true
    end
  end
  return true
end

M.run = make_state

return M

