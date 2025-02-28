local util = require("tests.helpers.util")
local verify = require("tests.helpers.verify")
local config = require("neo-tree").config
local get_value = require("neo-tree.utils").get_value

local run_focus_command = function(command, expected_tree_node)
  local winid = vim.api.nvim_get_current_win()

  vim.cmd(command)
  verify.window_handle_is_not(winid)
  verify.buf_name_endswith("neo-tree filesystem [1]")
  if expected_tree_node then
    verify.filesystem_tree_node_is(expected_tree_node)
  end
end

local run_in_current_command = function(command, expected_tree_node)
  local winid = vim.api.nvim_get_current_win()

  vim.cmd(command)
  verify.window_handle_is(winid)
  verify.buf_name_endswith(string.format("neo-tree filesystem [%s]", winid), 1000)
  if expected_tree_node then
    verify.filesystem_tree_node_is(expected_tree_node)
  end
end

local run_show_command = function(command, expected_tree_node)
  local starting_winid = vim.api.nvim_get_current_win()
  local starting_bufname = vim.api.nvim_buf_get_name(0)
  local expected_num_windows = #vim.api.nvim_list_wins() + 1

  vim.cmd(command)
  verify.eventually(500, function()
    if #vim.api.nvim_list_wins() ~= expected_num_windows then
      return false
    end
    if vim.api.nvim_get_current_win() ~= starting_winid then
      return false
    end
    if vim.api.nvim_buf_get_name(0) ~= starting_bufname then
      return false
    end
    if expected_tree_node then
      verify.filesystem_tree_node_is(expected_tree_node)
    end
    return true
  end, "Expected to see a new window without focusing it.")
end

describe("Command", function()
  local fs = util.setup_test_fs()
  local is_follow = get_value(config, "filesystem.follow_current_file", false)

  after_each(function()
    util.clear_test_state()
  end)

  describe("with reveal:", function()
    it("`:Neotree float reveal` should reveal the current file in the floating window", function()
      local cmd = "Neotree float reveal"
      local testfile = fs.lookup["./foo/bar/baz1.txt"].abspath
      util.editfile(testfile)
      run_focus_command(cmd, testfile)
    end)

    it("`:Neotree reveal toggle` should toggle the reveal-state of the tree", function()
      local cmd = "Neotree reveal toggle"
      local testfile = fs.lookup["./foo/foofile1.txt"].abspath
      util.editfile(testfile)

      -- toggle OPEN
      run_focus_command(cmd, testfile)
      local tree_winid = vim.api.nvim_get_current_win()

      -- toggle CLOSE
      vim.cmd(cmd)
      verify.window_handle_is_not(tree_winid)
      verify.buf_name_is(testfile)

      -- toggle OPEN with a different file
      testfile = fs.lookup["./foo/bar/baz1.txt"].abspath
      util.editfile(testfile)
      run_focus_command(cmd, testfile)
    end)

    it("`:Neotree float reveal toggle` should toggle the reveal-state of the floating window", function()
      local cmd = "Neotree float reveal toggle"
      local testfile = fs.lookup["./foo/foofile1.txt"].abspath
      util.editfile(testfile)

      -- toggle OPEN
      run_focus_command(cmd, testfile)
      local tree_winid = vim.api.nvim_get_current_win()

      -- toggle CLOSE
      vim.cmd("Neotree float reveal toggle")
      verify.window_handle_is_not(tree_winid)
      verify.buf_name_is(testfile)

      -- toggle OPEN
      testfile = fs.lookup["./foo/bar/baz2.txt"].abspath
      util.editfile(testfile)
      run_focus_command(cmd, testfile)
    end)

    it("`:Neotree reveal` should reveal the current file in the sidebar", function()
      local cmd = "Neotree reveal"
      local testfile = fs.lookup["topfile1"].abspath
      util.editfile(testfile)
      run_focus_command(cmd, testfile)
    end)
  end)

  describe("with show  :", function()
    it("`:Neotree show` should show the window without focusing", function()
      local cmd = "Neotree show"
      local testfile = fs.lookup["topfile1"].abspath
      util.editfile(testfile)
      run_show_command(cmd)
    end)

    it("`:Neotree show toggle` should retain the focused node on next show", function()
      local cmd = "Neotree show toggle"
      local topfile = fs.lookup["topfile1"].abspath
      local baz = fs.lookup["./foo/bar/baz1.txt"].abspath

      -- focus a sub node to see if state is retained
      util.editfile(baz)
      run_focus_command(":Neotree reveal", baz)
      local expected_tree_node = baz

      verify.after(500, function()
        -- toggle CLOSE
        vim.cmd(cmd)

        -- toggle OPEN
        util.editfile(topfile)
        if is_follow then
          expected_tree_node = topfile
        end
        run_show_command(cmd, expected_tree_node)
        return true
      end)
    end)
  end)

  describe("with focus :", function()
    it("`:Neotree focus` should show the window and focus it", function()
      local cmd = "Neotree focus"
      local testfile = fs.lookup["topfile1"].abspath
      util.editfile(testfile)
      run_focus_command(cmd)
    end)

    it("`:Neotree focus toggle` should retain the focused node on next focus", function()
      local cmd = "Neotree focus toggle"
      local topfile = fs.lookup["topfile1"].abspath
      local baz = fs.lookup["./foo/bar/baz1.txt"].abspath

      -- focus a sub node to see if state is retained
      util.editfile(baz)
      run_focus_command("Neotree reveal", baz)
      local expected_tree_node = baz

      verify.after(500, function()
        -- toggle CLOSE
        vim.cmd(cmd)

        -- toggle OPEN
        util.editfile(topfile)
        if is_follow then
          expected_tree_node = topfile
        end
        run_focus_command(cmd, expected_tree_node)
        return true
      end)
    end)
  end)

  util.teardown_test_fs()
end)
