--- Git-based plugin installer for the minimum bootloader.
---
--- Clones repositories with a partial clone (`--filter blob:none`) into
--- the dpp GitHub cache layout.
local M = {}
local is_debug = vim.g['vimrc#is_debug']

--- Clone a remote Git repository into the dpp plugin cache.
---
--- Uses full clone (not `--filter blob:none`) because partial clones
--- can leave files as missing/staged-deleted, breaking plugin loading.
---@param args {repo: string, dest: string} `repo`: clone URL; `dest`: target directory
---@return boolean `true` when clone succeeded
local function install_from_remote(args)
  if is_debug then
    vim.notify('[MY_NVIM_BOOTLOADER]: install_from_remote', vim.log.levels.DEBUG)
    vim.notify(
      '[MY_NVIM_BOOTLOADER]: args=' .. vim.inspect(args),
      vim.log.levels.DEBUG
    )
  end
  local git_clone_log = vim.fn.system({
    'git',
    'clone',
    args.repo,
    args.dest,
  })
  if is_debug then
    vim.notify(
      ('[MY_NVIM_BOOTLOADER]: log=%s'):format(git_clone_log),
      vim.log.levels.TRACE
    )
  end
  if vim.v.shell_error ~= 0 then
    vim.notify(
      ('[MY_NVIM_BOOTLOADER]: failed to clone %s'):format(args.repo),
      vim.log.levels.ERROR
    )
    return false
  end
  return true
end

---@type fun(args: {repo: string, dest: string}): boolean
M.install_from_remote = install_from_remote
return M

