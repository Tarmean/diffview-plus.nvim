local async = require("diffview.async")
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")
local utils = require("diffview.utils")

local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local EventEmitter = require("diffview.events").EventEmitter
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local StandardView = require("diffview.scene.views.standard.standard_view").StandardView

local api = vim.api
local await = async.await
local eq = helpers.eq
local run = helpers.run
local cleanup_repo = helpers.cleanup_repo
local close_view = helpers.close_view

local LINES = 30
local CURSOR_ROW = 20

-- Build a repo whose sole entry differs on *every* line, so `foldmethod=diff`
-- has no unchanged context to fold. A closed fold would let the cursor drift
-- for reasons unrelated to what this spec is testing.
local function make_repo()
  local repo = helpers.init_repo()
  local path = repo .. "/existing.txt"

  local function write(prefix)
    local lines = {}
    for i = 1, LINES do
      lines[i] = ("%s line %d"):format(prefix, i)
    end
    local f = assert(io.open(path, "w"))
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
  end

  write("committed")
  run({ "git", "add", "existing.txt" }, repo)
  run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" }, repo)
  write("working")

  return repo
end

describe("refresh preserves the cursor (integration)", function()
  local orig_emitter, original_config

  before_each(function()
    orig_emitter = DiffviewGlobal.emitter
    DiffviewGlobal.emitter = EventEmitter()
    -- Reinstall the bridge `bootstrap.lua` puts on the real global emitter.
    -- `file_open_new` -- the event that replays `cursor_map` -- is emitted on
    -- the global emitter and only reaches the view's listeners through it, so
    -- a bare replacement emitter would silently disable the very behaviour
    -- under test.
    DiffviewGlobal.emitter:on_any(function(e, args)
      require("diffview").nore_emit(e.id, utils.tbl_unpack(args))
    end)
    original_config = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    DiffviewGlobal.emitter = orig_emitter
    config.setup(original_config)
  end)

  -- `update_files` morphs the file list by destroying entries it replaces.
  -- Destroying an entry wipes its buffers, which bumps the main window onto
  -- an unrelated buffer sitting at line 1 -- so the `file_open_pre` snapshot
  -- that `cursor_map` relies on used to record row 1 and the reopened entry
  -- landed at the top of the file. `update_files_impl` now snapshots before
  -- the morph loop, and `snapshot_main_view` refuses to record from a window
  -- that has drifted off its file, so the good snapshot survives.
  --
  -- `force = true` is what makes this reproducible on git: it replaces
  -- entries that have a STAGE-rev side. The jj adapter takes the same branch
  -- unconditionally via `force_entry_refresh_on_noop`, which is why every
  -- plain `:DiffviewRefresh` under jj used to reset the cursor.
  it(
    "keeps the cursor row when a refresh replaces the open entry",
    helpers.async_test(function()
      config.setup({
        use_icons = false,
        view = { default = { layout = "diff2_horizontal", focus_diff = false } },
      })

      local repo = make_repo()
      local view

      local ok, err = pcall(function()
        view = DiffView({
          adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} }),
          rev_arg = nil,
          path_args = {},
          left = GitRev(RevType.STAGE, 0),
          right = GitRev(RevType.LOCAL),
          options = {},
        })
        assert.is_true(view:is_valid())

        view:open()
        assert.is_true(
          vim.wait(5000, function() return view.initialized end, 10),
          "view did not finish loading within 5s"
        )
        if view._set_file_in_flight then
          await(view._set_file_in_flight)
        end

        local before_entry = view.cur_entry
        assert.is_not_nil(before_entry, "expected an open entry")
        eq("existing.txt", before_entry.path)

        local main = view.cur_layout:get_main_win()
        assert.is_true(api.nvim_win_is_valid(main.id))
        eq(LINES, api.nvim_buf_line_count(main.file.bufnr))
        api.nvim_win_set_cursor(main.id, { CURSOR_ROW, 0 })

        view:update_files({ force = true })
        assert.is_true(
          vim.wait(5000, function() return view.cur_entry ~= before_entry end, 10),
          "refresh did not replace the open entry within 5s"
        )
        if view._set_file_in_flight then
          await(view._set_file_in_flight)
        end
        await(async.scheduler())

        -- Sanity: this exercises the replace branch, not the reuse branch.
        assert.is_true(view.cur_entry ~= before_entry, "entry should have been replaced")
        eq("existing.txt", view.cur_entry.path)
        eq("existing.txt", view.panel.cur_file.path)

        local after_main = view.cur_layout:get_main_win()
        eq(CURSOR_ROW, api.nvim_win_get_cursor(after_main.id)[1])
      end)

      close_view(view)
      cleanup_repo(repo)
      if not ok then error(err) end
    end)
  )

  it("snapshot_main_view ignores a main window that has drifted off its file", function()
    local scratch = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(scratch, 0, -1, false, { "a", "b", "c", "d", "e" })

    local other = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(other, 0, -1, false, { "x" })

    local winid = api.nvim_open_win(scratch, false, {
      relative = "editor", row = 0, col = 0, width = 20, height = 5, style = "minimal",
    })
    api.nvim_win_set_cursor(winid, { 4, 0 })

    local fake_win = { id = winid, file = { bufnr = scratch } }
    local view = setmetatable({
      cursor_map = {},
      cur_layout = { get_main_win = function() return fake_win end },
    }, { __index = StandardView })

    -- Window still shows the file: the snapshot is recorded.
    view:snapshot_main_view("f.txt")
    assert.is_not_nil(view.cursor_map["f.txt"])
    eq(4, view.cursor_map["f.txt"].lnum)

    -- Window has drifted onto an unrelated buffer (what an entry destroy
    -- leaves behind): the stale position must not clobber the good one.
    api.nvim_win_set_buf(winid, other)
    view:snapshot_main_view("f.txt")
    eq(4, view.cursor_map["f.txt"].lnum)

    -- Same for a file whose buffer was wiped outright.
    fake_win.file.bufnr = nil
    view:snapshot_main_view("f.txt")
    eq(4, view.cursor_map["f.txt"].lnum)

    api.nvim_win_close(winid, true)
    api.nvim_buf_delete(scratch, { force = true })
    api.nvim_buf_delete(other, { force = true })
  end)
end)
