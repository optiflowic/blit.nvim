-- Entry point for `make test`: runs every case strictly one after another.
--
-- mini.test queues each step (hooks, cases, the reporter's finish) with
-- vim.schedule() before any of them runs. vim.wait() processes scheduled
-- callbacks, so a case that waits would have the following cases, and
-- finally the reporter's finish (which quits headless Neovim), run inside
-- its wait: its own expectations after the wait were never checked
-- (issue #62).
--
-- Here the steps are collected instead, and each one is handed to the real
-- vim.schedule() only after the previous one has returned. Timers and
-- autocmds still fire during a vim.wait(); the next case does not start.

local steps = {}
local schedule = vim.schedule

vim.schedule = function(step)
  steps[#steps + 1] = step
end
local collected, collect_err = pcall(MiniTest.run)
vim.schedule = schedule

-- An error outside a case body (collection, a reporter callback) would
-- otherwise leave headless Neovim running with nothing left to quit it.
---@param err any
local function abort(err)
  print("tests/run.lua: " .. tostring(err))
  vim.cmd("cquit 1")
end

if not collected then
  abort(collect_err)
end

local function run_next_step()
  local step = table.remove(steps, 1)
  if not step then
    return
  end
  local ok, err = pcall(step)
  if not ok then
    abort(err)
  end
  schedule(run_next_step)
end

schedule(run_next_step)
