local utils = require("neo-tree.utils")
local events = require("neo-tree.events")
local Job = require("plenary.job")
local log = require("neo-tree.log")
local git_utils = require("neo-tree.git.utils")

local M = {}

local function get_simple_git_status_code(status)
  -- Prioritze M then A over all others
  if status:match("U") or status == "AA" or status == "DD" then
    return "U"
  elseif status:match("M") then
    return "M"
  elseif status:match("[ACR]") then
    return "A"
  elseif status:match("!$") then
    return "!"
  elseif status:match("?$") then
    return "?"
  else
    local len = #status
    while len > 0 do
      local char = status:sub(len, len)
      if char ~= " " then
        return char
      end
      len = len - 1
    end
    return status
  end
end

local function get_priority_git_status_code(status, other_status)
  if not status then
    return other_status
  elseif not other_status then
    return status
  elseif status == "U" or other_status == "U" then
    return "U"
  elseif status == "?" or other_status == "?" then
    return "?"
  elseif status == "M" or other_status == "M" then
    return "M"
  elseif status == "A" or other_status == "A" then
    return "A"
  else
    return status
  end
end

local parse_git_status_line = function(context, line)
  context.lines_parsed = context.lines_parsed + 1
  if type(line) ~= "string" then
    return
  end
  if #line < 4 then
    return
  end
  local git_root = context.git_root
  local git_status = context.git_status
  local exclude_directories = context.exclude_directories

  local line_parts = vim.split(line, "	")
  if #line_parts < 2 then
    return
  end
  local status = line_parts[1]
  local relative_path = line_parts[2]

  -- rename output is `R000 from/filename to/filename`
  if status:match("^R") then
    relative_path = line_parts[3]
  end

  -- remove any " due to whitespace in the path
  relative_path = relative_path:gsub('^"', ""):gsub('$"', "")
  if utils.is_windows == true then
    relative_path = utils.windowize_path(relative_path)
  end
  local absolute_path = utils.path_join(git_root, relative_path)
  -- merge status result if there are results from multiple passes
  local existing_status = git_status[absolute_path]
  if existing_status then
    local merged = ""
    local i = 0
    while i < 2 do
      i = i + 1
      local existing_char = #existing_status >= i and existing_status:sub(i, i) or ""
      local new_char = #status >= i and status:sub(i, i) or ""
      local merged_char = get_priority_git_status_code(existing_char, new_char)
      merged = merged .. merged_char
    end
    status = merged
  end
  git_status[absolute_path] = status

  if not exclude_directories then
    -- Now bubble this status up to the parent directories
    local parts = utils.split(absolute_path, utils.path_separator)
    table.remove(parts) -- pop the last part so we don't override the file's status
    utils.reduce(parts, "", function(acc, part)
      local path = acc .. utils.path_separator .. part
      if utils.is_windows == true then
        path = path:gsub("^" .. utils.path_separator, "")
      end
      local path_status = git_status[path]
      local file_status = get_simple_git_status_code(status)
      git_status[path] = get_priority_git_status_code(path_status, file_status)
      return path
    end)
  end
end

---Parse "git status" output for the current working directory.
---@base git ref base
---@exclude_directories boolean Whether to skip bubling up status to directories
---@path string Path to run the git status command in, defaults to cwd.
---@return table table Table with the path as key and the status as value.
---@return string string The git root for the specified path.
M.status = function(base, exclude_directories, path)
  local git_root = git_utils.get_repository_root(path)
  if not utils.truthy(git_root) then
    return {}
  end

  local staged_cmd = 'git -C "' .. git_root .. '" diff --staged --name-status ' .. base .. " --"
  local staged_ok, staged_result = utils.execute_command(staged_cmd)
  if not staged_ok then
    return {}
  end
  local unstaged_cmd = 'git -C "' .. git_root .. '" diff --name-status'
  local unstaged_ok, unstaged_result = utils.execute_command(unstaged_cmd)
  if not unstaged_ok then
    return {}
  end
  local untracked_cmd = 'git -C "' .. git_root .. '" ls-files --exclude-standard --others'
  local untracked_ok, untracked_result = utils.execute_command(untracked_cmd)
  if not untracked_ok then
    return {}
  end

  local context = {
    git_root = git_root,
    git_status = {},
    exclude_directories = exclude_directories,
    lines_parsed = 0
  }

  for _, line in ipairs(staged_result) do
    parse_git_status_line(context, line)
  end
  for _, line in ipairs(unstaged_result) do
    if line then
      line = " " .. line
    end
    parse_git_status_line(context, line)
  end
  for _, line in ipairs(untracked_result) do
    if line then
      line = "?	" .. line
    end
    parse_git_status_line(context, line)
  end

  return context.git_status, git_root
end

M.status_async = function(path, base)
  local git_root = git_utils.get_repository_root(path)
  if utils.truthy(git_root) then
    log.trace("git.status.status_async called")
  else
    log.trace("status_async: not a git folder: ", path)
    return false
  end

  local context = {
    git_root = git_root,
    git_status = {},
    exclude_directories = false,
    lines_parsed = 0
  }

  local should_process = function(err, line, job, err_msg)
    if vim.v.dying > 0 or vim.v.exiting ~= vim.NIL then
      job:shutdown()
      return false
    end
    if err and err > 0 then
      log.error(err_msg, err, line)
      return false
    end
    return true
  end

  local event_id = "git_status_" .. git_root
  utils.debounce(event_id, function()
    local staged_job = Job
      :new({
        command = "git",
        args = { "-C", git_root, "diff", "--staged", "--name-status", base, "--" },
        enable_recording = false,
        on_stdout = vim.schedule_wrap(function(err, line, job)
          if should_process(err, line, job, "status_async staged error:") then
            parse_git_status_line(context, line)
          end
        end),
        on_stderr = function(err, line)
          if err and err > 0 then
            log.error("status_async staged error: ", err, line)
          end
        end,
        on_exit = function(_, return_val)
          log.trace("status_async staged completed with return_val: ", return_val)
        end,
      })

    local unstaged_job = Job
      :new({
        command = "git",
        args = { "-C", git_root, "diff", "--name-status" },
        enable_recording = false,
        on_stdout = vim.schedule_wrap(function(err, line, job)
          if should_process(err, line, job, "status_async unstaged error:") then
            if line then
              line = " " .. line
            end
            parse_git_status_line(context, line)
          end
        end),
        on_stderr = function(err, line)
          if err and err > 0 then
            log.error("status_async unstaged error: ", err, line)
          end
        end,
        on_exit = function(_, return_val)
          log.trace("status_async unstaged completed with return_val: ", return_val)
        end,
      })

    local untracked_job = Job
      :new({
        command = "git",
        args = { "-C", git_root, "ls-files", "--exclude-standard", "--others" },
        enable_recording = false,
        on_stdout = vim.schedule_wrap(function(err, line, job)
          if should_process(err, line, job, "status_async untracked error:") then
            if line then
              line = "?	" .. line
            end
            parse_git_status_line(context, line)
          end
        end),
        on_stderr = function(err, line)
          if err and err > 0 then
            log.error("status_async untracked error: ", err, line)
          end
        end,
        on_exit = function(_, return_val)
          utils.debounce(event_id, nil, nil, nil, utils.debounce_action.COMPLETE_ASYNC_JOB)
          log.trace("status_async untracked completed with return_val:", return_val, ";", context.lines_parsed, "lines parsed")
          vim.schedule(function()
            events.fire_event(events.GIT_STATUS_CHANGED, {
              git_root = context.git_root,
              git_status = context.git_status,
            })
          end)
        end,
      })

    Job.chain(staged_job, unstaged_job, untracked_job)
  end, 1000, utils.debounce_strategy.CALL_FIRST_AND_LAST, utils.debounce_action.START_ASYNC_JOB)

  return true
end

return M
