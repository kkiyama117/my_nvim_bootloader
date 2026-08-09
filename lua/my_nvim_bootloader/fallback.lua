--- Fallback router for bootloader error conditions.
---
--- Dispatches to `my_nvim_bootloader/min` rescue routines based on `error_number`:
--- - **F1**: `dpp#min#load_state` failed → delegate to `my_nvim_bootloader/dpp`
--- - **F2**: `dpp#min#load_state` missing → `rescue_min`
--- - **F3**: normal dpp deps missing → `rescue_normal`
local M = {}

--- Handle a bootloader failure by running the appropriate rescue path.
---@param args {error_number: integer, missing_plugins?: string[], cache_home?: string, cache_github?: string, dpp_script?: string}
---@return boolean|nil `true`/`false` from rescue on F2/F3; `nil` on unknown error
M.startup = function(args)
  local error_number = args.error_number
  vim.notify(
    ('[BOOTLOADER]: Fallback called with Error %s'):format(error_number),
    vim.log.levels.ERROR
  )
  -- F1: failed to load state => check plugins status, then make_state
  -- F2: dpp#min#load_state isn't found
  -- F3: plugins for dpp aren't found
  if error_number == 1 then
    local cache_home = args.cache_home
    local cache_github = args.cache_github
    local dpp_script = args.dpp_script
    -- TODO: ask user to run dpp/auto_update
    require('my_nvim_bootloader/dpp/auto_update').dpp_update_force({
      cache_home = cache_home,
      cache_github = cache_github,
      dpp_script = dpp_script,
    })
  elseif error_number == 2 then
    local missing_plugins = args.missing_plugins
    vim.notify(
      ('[BOOTLOADER/Fallback]: rescue %s'):format(error_number),
      vim.log.levels.ERROR
    )
    -- This may call `:restart`
    if missing_plugins then
      return require('my_nvim_bootloader/min').rescue_min(missing_plugins)
    else
      vim.notify(
        '[BOOTLOADER/Fallback]: rescue called but no missing_plugins',
        vim.log.levels.ERROR
      )
      return false
    end
  elseif error_number == 3 then
    local missing_plugins = args.missing_plugins
    if missing_plugins then
      vim.notify(
        ('[BOOTLOADER/Fallback]: rescue %s'):format(error_number),
        vim.log.levels.ERROR
      )
      return require('my_nvim_bootloader/min').rescue_normal(missing_plugins)
    else
      vim.notify(
        '[BOOTLOADER/Fallback]: rescue called but no missing_plugins',
        vim.log.levels.ERROR
      )
      return false
    end
  else
    vim.notify(
      ('[BOOTLOADER/Fallback]: UNKNOWN ERROR OF BOOTLOADER'):format(
        error_number
      ),
      vim.log.levels.ERROR
    )
  end
end

return M

