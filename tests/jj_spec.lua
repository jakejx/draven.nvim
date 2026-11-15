-- Real jj plumbing only. Do not use helpers.repo(): it invokes Git.
local async = require("draven.util.async")
local changeset = require("draven.core.changeset")
local config = require("draven.config")
local helpers = require("helpers")
local session_mod = require("draven.session")
local state = require("draven.state")

local Repo = {}
Repo.__index = Repo

function Repo:jj(args)
	local cmd = { "jj", "--no-pager", "--color=never" }
	vim.list_extend(cmd, args)
	local result = vim.system(cmd, { cwd = self.dir, timeout = 15000 }):wait()
	assert.equals(0, result.code, table.concat(cmd, " ") .. "\n" .. (result.stderr or ""))
	return result.stdout or ""
end

function Repo:write(path, lines)
	local abs = self.dir .. "/" .. path
	vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
	vim.fn.writefile(lines, abs)
end

function Repo:resolve(rev, template)
	return vim.trim(self:jj({ "log", "--no-graph", "-r", rev, "-T", template or "commit_id" }))
end

function Repo:commit(message)
	self:jj({ "commit", "-m", message })
	return self:resolve("@-")
end

function Repo:build(opts)
	opts = vim.tbl_extend("force", { cwd = self.dir }, opts or {})
	return async.block(function()
		return changeset.build(opts)
	end)
end

local function file(cs, path)
	local found = changeset.file(cs, path)
	assert.is_not_nil(found, "missing changed file: " .. path)
	return found
end

local function fails(fn, pattern)
	local ok, err = pcall(fn)
	assert.is_false(ok, "selection unexpectedly succeeded")
	assert.is_truthy(tostring(err):match(pattern), tostring(err))
end

-- All environment changes are restored, including variables that were unset.
local env_keys = {
	"JJ_CONFIG",
	"JJ_CONFIG_TOML",
	"JJ_USER",
	"JJ_EMAIL",
	"JJ_TIMESTAMP",
	"JJ_RANDOMNESS_SEED",
	"JJ_OP_USERNAME",
	"JJ_OP_HOSTNAME",
	"GIT_CONFIG_GLOBAL",
	"GIT_CONFIG_SYSTEM",
	"GIT_CONFIG_NOSYSTEM",
	"GIT_CONFIG_COUNT",
}

describe("jj command parsing (pure unit tests)", function()
	local function parse(args)
		return require("draven.command").parse(args)
	end

	it("parses empty input without selecting a target", function()
		assert.same({}, parse({}))
	end)

	it("preserves a positional jj revset containing spaces", function()
		assert.same({ rev = "parents(@) | root()" }, parse({ "parents(@)", "|", "root()" }))
	end)

	it("accepts short, long and equals-form revision options", function()
		for _, args in ipairs({ { "-r", "@-" }, { "--revision", "@-" }, { "--revision=@-" } }) do
			assert.same({ rev = "@-" }, parse(args))
		end
	end)

	it("accepts endpoints in either order and preserves revset strings", function()
		assert.same({ from = "root()", to = "@" }, parse({ "--from=root()", "--to", "@" }))
		assert.same({ from = "parents(@)", to = "@" }, parse({ "--to=@", "--from", "parents(@)" }))
		assert.same({ from = "@-" }, parse({ "--from", "@-" }))
		assert.same({ to = "@" }, parse({ "--to=@" }))
	end)

	it("rejects missing, empty and duplicate option values", function()
		for _, args in ipairs({
			{ "-r" },
			{ "--revision=" },
			{ "--from" },
			{ "--to=" },
			{ "--from", "--to", "@" },
			{ "-r", "@", "--revision", "@-" },
			{ "--from=@", "--from=@-" },
			{ "--to=@", "--to=@-" },
		}) do
			fails(function()
				parse(args)
			end, "expected one value")
		end
	end)

	it("rejects mixed selection modes and unknown options", function()
		for _, args in ipairs({
			{ "@-", "--to", "@" },
			{ "@-", "-r", "@" },
			{ "-r", "@", "--from", "@-" },
			{ "--to=@", "--revision=@-" },
			{ "--unknown" },
		}) do
			fails(function()
				parse(args)
			end, "draven:")
		end
	end)
end)

describe("native jj", function()
	local repo, sandbox, saved_env, initial_buffers, views, windows

	before_each(function()
		assert.equals(1, vim.fn.executable("jj"), "jj is required for this spec")
		sandbox = vim.fn.tempname()
		vim.fn.mkdir(sandbox .. "/repo", "p")
		sandbox = assert((vim.uv or vim.loop).fs_realpath(sandbox))
		saved_env = {}
		for _, key in ipairs(env_keys) do
			saved_env[key] = vim.env[key] or false
			vim.env[key] = nil
		end
		local cfg = sandbox .. "/jj.toml"
		vim.fn.writefile({
			'user.name = "Draven JJ Test"',
			'user.email = "jj@draven.test"',
			'operation.username = "draven-test"',
			'operation.hostname = "test-host"',
			'signing.behavior = "drop"',
			'signing.backend = "none"',
			"git.colocate = false",
			'snapshot.auto-track = "all()"',
			'fsmonitor.backend = "none"',
			'ui.paginate = "never"',
		}, cfg)
		vim.env.JJ_CONFIG = cfg
		vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
		vim.env.GIT_CONFIG_SYSTEM = "/dev/null"
		vim.env.GIT_CONFIG_NOSYSTEM = "1"
		vim.env.GIT_CONFIG_COUNT = "0"
		config.setup({ backend = "auto", jj = { bin = "jj", timeout_ms = 15000 } })
		initial_buffers, views, windows = {}, {}, {}
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			initial_buffers[buf] = true
		end
		repo = setmetatable({ dir = sandbox .. "/repo" }, Repo)
		repo:jj({ "git", "init", "." })
	end)

	after_each(function()
		require("draven.ui").close()
		for _, view in ipairs(views or {}) do
			view:close()
		end
		for _, win in ipairs(windows or {}) do
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if initial_buffers and not initial_buffers[buf] then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
		end
		config.setup({})
		for _, key in ipairs(env_keys) do
			vim.env[key] = saved_env and saved_env[key] or nil
			if saved_env and saved_env[key] == false then
				vim.env[key] = nil
			end
		end
		if sandbox then
			vim.fn.delete(sandbox, "rf")
		end
	end)

	local function show(cs, path)
		vim.cmd("botright vsplit")
		local win = vim.api.nvim_get_current_win()
		windows[#windows + 1] = win
		local view = require("draven.ui.view").new(win, session_mod.new(cs))
		views[#views + 1] = view
		local done = false
		view:show(file(cs, path), {
			on_done = function()
				done = true
			end,
		})
		helpers.wait_for(function()
			return done
		end, "jj view: " .. path)
		assert.equals(view.bufnr, vim.api.nvim_win_get_buf(win))
		return view, vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
	end

	it("starts with an empty working-copy review", function()
		local cs = repo:build()
		assert.equals("jj", cs.backend)
		assert.equals(repo.dir, cs.root)
		assert.equals(repo.dir .. "/.jj/draven", cs.state_dir)
		assert.equals("worktree", cs.revspec.kind)
		assert.equals(repo:resolve("@"), cs.head_rev)
		assert.same({}, cs.files)
		assert.equals(0, cs.stats.hunks)
		assert.is_false(cs.unborn)
	end)

	it("snapshots additions and builds hunks without requiring a commit", function()
		repo:write("nested/new.txt", { "one", "two" })
		local cs = repo:build()
		local f = file(cs, "nested/new.txt")
		assert.equals("added", f.status)
		assert.equals(2, f.added)
		assert.equals(1, #f.hunks)
		assert.equals(64, #f.hunks[1].content_hash)
		assert.equals(repo:resolve("@"), cs.head_rev)
		assert.equals(1, cs.stats.files)
	end)

	it("reviews only the current change against its parent", function()
		repo:write("a.txt", { "one", "two" })
		local parent = repo:commit("base")
		repo:write("a.txt", { "ONE", "two" })
		local cs = repo:build()
		assert.equals("parents:" .. parent, cs.base_rev)
		local f = file(cs, "a.txt")
		assert.equals("modified", f.status)
		assert.equals(1, f.added)
		assert.equals(1, f.removed)
	end)

	it("supports the blocking public API and explicit backend override", function()
		repo:write("a.txt", { "one" })
		config.setup({ backend = "git" })
		local cs = require("draven").changeset({ cwd = repo.dir, backend = "jj" })
		assert.equals("jj", cs.backend)
		assert.equals("added", file(cs, "a.txt").status)
	end)

	it("uses the configured jj executable and surfaces process failures", function()
		config.setup({ backend = "jj", jj = { bin = sandbox .. "/missing-jj", timeout_ms = 1000 } })
		fails(function()
			repo:build()
		end, ".+")
	end)

	it("does not auto-track files when jj tracking is disabled", function()
		repo:write("tracked.txt", { "old" })
		repo:commit("base")
		repo:jj({ "config", "set", "--repo", "snapshot.auto-track", "none()" })
		repo:write("tracked.txt", { "new" })
		repo:write("untracked.txt", { "must stay untracked" })
		for _, include in ipairs({ true, false }) do
			config.setup({ backend = "jj", include_untracked = include })
			local cs = repo:build()
			assert.is_nil(changeset.file(cs, "untracked.txt"))
			assert.equals("modified", file(cs, "tracked.txt").status)
		end
		assert.is_nil(repo:jj({ "file", "list" }):find("untracked.txt", 1, true))
	end)

	it("respects jj ignore rules during snapshotting", function()
		repo:write(".gitignore", { "secret.txt" })
		repo:commit("ignore")
		repo:write("secret.txt", { "secret" })
		repo:write("visible.txt", { "visible" })
		local cs = repo:build()
		assert.is_nil(changeset.file(cs, "secret.txt"))
		assert.equals("added", file(cs, "visible.txt").status)
	end)

	it("refreshes immutable head IDs but keeps parent fingerprint and change key stable", function()
		repo:write("a.txt", { "base" })
		repo:commit("base")
		repo:write("a.txt", { "first edit" })
		local before = repo:build()
		local change_id = repo:resolve("@", "change_id")
		assert.equals("change-" .. change_id, before.state_key)
		repo:write("a.txt", { "second edit", "extra" })
		local after = repo:build()
		assert.are_not.equals(before.head_rev, after.head_rev)
		assert.equals(before.base_rev, after.base_rev)
		assert.equals(before.state_key, after.state_key)
		assert.are_not.equals(
			file(before, "a.txt").hunks[1].content_hash,
			file(after, "a.txt").hunks[1].content_hash
		)
		assert.equals(2, file(after, "a.txt").added)
	end)

	it("changes the base fingerprint when parents are rewritten", function()
		repo:write("a.txt", { "base" })
		repo:commit("base")
		repo:write("a.txt", { "edit" })
		local before = repo:build()
		repo:jj({ "describe", "-r", "@-", "-m", "rewritten parent" })
		local after = repo:build()
		assert.are_not.equals(before.base_rev, after.base_rev)
		assert.equals(before.state_key, after.state_key)
	end)

	it("retrieves historical content rather than the current disk file", function()
		repo:write("sample.c", { "return 'historical'" })
		local rev = repo:commit("historical")
		repo:write("sample.c", { "return 'working copy'" })
		repo:write("live-only.txt", { "live" })
		local cs = repo:build({ rev = rev })
		assert.equals("range", cs.revspec.kind)
		assert.equals(rev, cs.head_rev)
		assert.is_nil(changeset.file(cs, "live-only.txt"))
		local backend = require("draven.core.jj")
		assert.equals(
			"return 'historical'\n",
			async.block(function()
				return backend.show(cs.head_rev, "sample.c", cs.root)
			end)
		)
		local view, lines = show(cs, "sample.c")
		assert.same({ "return 'historical'" }, lines)
		assert.equals("nofile", vim.bo[view.bufnr].buftype)
		assert.is_false(vim.bo[view.bufnr].modifiable)
		assert.equals("c", vim.bo[view.bufnr].filetype)
		assert.same({ "return 'working copy'" }, vim.fn.readfile(repo.dir .. "/sample.c"))
	end)

	it("shows paths containing spaces and revset punctuation literally", function()
		local path = "nested/a [x]: space.txt"
		repo:write(path, { "literal content" })
		local rev = repo:commit("odd filename")
		assert.equals(
			"literal content\n",
			async.block(function()
				return require("draven.core.jj").show(rev, path, repo.dir)
			end)
		)
	end)

	it("compares explicit from/to endpoints, excluding later edits", function()
		repo:write("a.txt", { "first" })
		local base = repo:commit("first")
		repo:write("a.txt", { "second" })
		local head = repo:commit("second")
		repo:write("a.txt", { "third", "live" })
		local cs = repo:build({ from = base, to = head })
		assert.equals("range", cs.revspec.kind)
		assert.equals(base, cs.base_rev)
		assert.equals(head, cs.head_rev)
		assert.equals(1, file(cs, "a.txt").added)
		local _, lines = show(cs, "a.txt")
		assert.same({ "second" }, lines)
	end)

	it("keeps command endpoints on refresh and reloads historical buffer content", function()
		repo:write("a.txt", { "base" })
		repo:commit("base")
		repo:write("a.txt", { "first edit" })
		local previous = vim.fn.getcwd()
		vim.cmd.cd(vim.fn.fnameescape(repo.dir))
		vim.cmd("runtime plugin/draven.lua")
		vim.cmd("Draven --from @- --to @")
		vim.cmd.cd(vim.fn.fnameescape(previous))
		local function review_lines()
			if not require("draven.ui").is_open() then
				return nil
			end
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				local buf = vim.api.nvim_win_get_buf(win)
				if vim.api.nvim_buf_get_name(buf):match("^draven://.*a%.txt$") then
					return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				end
			end
		end
		helpers.wait_for(function()
			return vim.deep_equal({ "first edit" }, review_lines())
		end, "command review opened")
		repo:write("a.txt", { "second edit", "new line" })
		require("draven.ui").refresh({ silent = true })
		helpers.wait_for(function()
			return vim.deep_equal({ "second edit", "new line" }, review_lines())
		end, "refreshed historical content")
	end)

	local function review_window(path)
		if not require("draven.ui").is_open() then
			return
		end
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
			if name:sub(-#path - 1) == "/" .. path then
				return win
			end
		end
	end

	local function open_review(opts, path)
		require("draven.ui").open(vim.tbl_extend("force", { cwd = repo.dir }, opts or {}))
		helpers.wait_for(function()
			return review_window(path) ~= nil
		end, "review file: " .. path)
		return review_window(path)
	end

	it("preserves cursor and viewport when refreshing historical content", function()
		config.setup({ ui = { fold_unchanged = false } })
		local lines = {}
		for i = 1, 100 do
			lines[i] = ("line %03d"):format(i)
		end
		repo:write("a.txt", lines)
		repo:commit("base")
		lines[10], lines[90] = "first edit", "last edit"
		repo:write("a.txt", lines)
		local win = open_review({ from = "@-", to = "@" }, "a.txt")
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_win_set_cursor(win, { 80, 3 })
		vim.cmd("normal! zt")
		local before = vim.fn.winsaveview()
		lines[100] = "reloaded"
		repo:write("a.txt", lines)
		require("draven.ui").refresh({ silent = true })
		helpers.wait_for(function()
			local buf = vim.api.nvim_win_get_buf(win)
			return vim.api.nvim_buf_get_lines(buf, 99, 100, false)[1] == "reloaded"
		end, "historical content reloaded")
		assert.same({ 80, 3 }, vim.api.nvim_win_get_cursor(win))
		assert.equals(before.topline, vim.fn.winsaveview().topline)
	end)

	it("keeps a pending finding out of a different review without losing its text", function()
		repo:write("a.txt", { "first change" })
		local win = open_review({}, "a.txt")
		vim.api.nvim_set_current_win(win)
		require("draven.ui").comment()
		vim.cmd("stopinsert")
		local composer = vim.api.nvim_get_current_buf()
		assert.equals("draven://finding", vim.api.nvim_buf_get_name(composer))
		vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "Only belongs to the first change" })

		repo:jj({ "new" })
		repo:write("b.txt", { "second change" })
		require("draven.ui").refresh({ silent = true })
		helpers.wait_for(function()
			return review_window("b.txt") ~= nil
		end, "second review loaded")
		vim.api.nvim_buf_call(composer, function()
			vim.cmd("write")
		end)
		assert.is_true(vim.api.nvim_buf_is_valid(composer))
		assert.same(
			{ "Only belongs to the first change" },
			vim.api.nvim_buf_get_lines(composer, 0, -1, false)
		)
		require("draven.ui").close()
		assert.same({}, session_mod.new(repo:build()):findings())
	end)

	it("saves a finding to the review where its composer was opened", function()
		repo:write("a.txt", { "review this" })
		local win = open_review({}, "a.txt")
		vim.api.nvim_set_current_win(win)
		require("draven.ui").comment()
		vim.cmd("stopinsert")
		local composer = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(composer, 0, -1, false, { "A finding on this change" })
		vim.cmd("write")
		assert.is_false(vim.api.nvim_buf_is_valid(composer))
		require("draven.ui").close()
		local findings = session_mod.new(repo:build()):findings()
		assert.equals(1, #findings)
		assert.equals("A finding on this change", findings[1].body)
	end)

	it("defaults a missing endpoint to the working-copy commit", function()
		repo:write("a.txt", { "base" })
		local base = repo:commit("base")
		repo:write("a.txt", { "head" })
		local forward = repo:build({ from = base })
		assert.equals("range", forward.revspec.kind)
		assert.equals(base, forward.base_rev)
		assert.equals(repo:resolve("@"), forward.head_rev)
		local reverse = repo:build({ to = base })
		assert.equals("range", reverse.revspec.kind)
		assert.equals(forward.head_rev, reverse.base_rev)
		assert.equals(base, reverse.head_rev)
	end)

	it("returns an empty range for identical endpoints", function()
		repo:write("a.txt", { "base" })
		local rev = repo:commit("base")
		assert.same({}, repo:build({ from = rev, to = rev }).files)
	end)

	it("rejects rev combined with either endpoint", function()
		for _, opts in ipairs({ { rev = "@", from = "@-" }, { rev = "@", to = "@" } }) do
			fails(function()
				repo:build(opts)
			end, "either.*revision.*from/to")
		end
	end)

	it("rejects empty and multi-commit revsets in every selection slot", function()
		for _, slot in ipairs({ "rev", "from", "to" }) do
			for _, revset in ipairs({ "none()", "@ | root()" }) do
				fails(function()
					repo:build({ [slot] = revset })
				end, "exactly one commit")
			end
		end
	end)

	it("surfaces invalid revsets and nonexistent revisions", function()
		for _, rev in ipairs({ "(", "no_such_draven_revision" }) do
			fails(function()
				repo:build({ rev = rev })
			end, ".+")
		end
	end)

	it("round-trips review marks and snapshots under .jj/draven", function()
		repo:write("a.txt", { "base" })
		repo:commit("base")
		repo:write("a.txt", { "approved" })
		local cs = repo:build()
		local session = session_mod.new(cs)
		local hunk = session.order[1].hunk
		session:mark(hunk, true)
		session:save()
		assert.equals(cs.state_dir .. "/" .. cs.state_key .. ".json", state.path(cs))
		assert.equals(1, vim.fn.filereadable(state.path(cs)))
		assert.is_not_nil(state.read_snapshot(cs, hunk.content_hash))
		local reopened = session_mod.new(repo:build())
		assert.equals(1, select(1, reopened:progress()))
		assert.is_true(reopened:is_reviewed(reopened.order[1].hunk))
	end)

	it("isolates default changes and explicit review targets", function()
		repo:write("a.txt", { "base" })
		repo:commit("base")
		repo:write("a.txt", { "approved" })
		local default = repo:build()
		local session = session_mod.new(default)
		session:mark_all(true)
		session:save()
		local explicit = repo:build({ from = "@-", to = "@" })
		assert.are_not.equals(state.path(default), state.path(explicit))
		assert.are_not.equals(state.snapshot_dir(default), state.snapshot_dir(explicit))
		assert.equals(0, select(1, session_mod.new(explicit):progress()))
		repo:commit("next change")
		repo:write("a.txt", { "another change" })
		local next_change = repo:build()
		assert.are_not.equals(default.state_key, next_change.state_key)
		assert.equals(0, select(1, session_mod.new(next_change):progress()))
	end)

	it("shares canonical change identity and saved state across revision aliases", function()
		repo:write("a.txt", { "historical" })
		local rev = repo:commit("historical")
		local by_expr = repo:build({ rev = "@-" })
		local by_id = repo:build({ rev = rev })
		assert.equals("change-" .. repo:resolve(rev, "change_id"), by_id.state_key)
		assert.equals(by_expr.state_key, by_id.state_key)
		local session = session_mod.new(by_expr)
		session:mark_all(true)
		session:save()
		assert.equals(1, select(1, session_mod.new(by_id):progress()))
	end)

	it("flushes and reloads review state when jj new/edit switches changes", function()
		repo:write("a.txt", { "base" })
		repo:commit("base")
		repo:write("a.txt", { "first review" })
		local first = repo:build()
		local session = session_mod.new(first)
		session:mark_all(true)
		-- No explicit save: update must flush the old target before switching.
		repo:jj({ "new" })
		repo:write("a.txt", { "second review" })
		local second = repo:build()
		assert.are_not.equals(first.state_key, second.state_key)
		session:update(second)
		assert.equals(0, select(1, session:progress()))
		assert.equals(1, vim.fn.filereadable(state.path(first)))
		session:mark_all(true)
		repo:jj({ "edit", first.head_rev })
		session:update(repo:build())
		assert.equals(first.state_key, session.changeset.state_key)
		assert.equals(1, select(1, session:progress()))
		assert.equals(1, vim.fn.filereadable(state.path(second)))
		repo:jj({ "edit", second.head_rev })
		session:update(repo:build())
		assert.equals(second.state_key, session.changeset.state_key)
		assert.equals(1, select(1, session:progress()))
	end)

	it("shares default state with explicit aliases of the current change", function()
		repo:write("a.txt", { "review me" })
		local default = repo:build()
		local session = session_mod.new(default)
		session:mark_all(true)
		session:save()
		for _, rev in ipairs({ "@", default.head_rev, repo:resolve("@", "change_id") }) do
			local explicit = repo:build({ rev = rev })
			assert.equals(state.path(default), state.path(explicit))
			assert.equals(1, select(1, session_mod.new(explicit):progress()))
		end
	end)

	it("canonicalizes endpoint keys while isolating direction and selection mode", function()
		repo:write("a.txt", { "base" })
		local base = repo:commit("base")
		repo:write("a.txt", { "head" })
		local head = repo:commit("head")
		local symbolic = repo:build({ from = "@--", to = "@-" })
		local resolved = repo:build({ from = base, to = head })
		assert.equals(symbolic.state_key, resolved.state_key)
		assert.are_not.equals(resolved.state_key, repo:build({ from = head, to = base }).state_key)
		assert.are_not.equals(resolved.state_key, repo:build({ rev = head }).state_key)
	end)

	it("displays a deleted file's complete pre-image", function()
		repo:write("gone.c", { "// old", "return 42;" })
		repo:commit("base")
		vim.fn.delete(repo.dir .. "/gone.c")
		local cs = repo:build()
		assert.equals("deleted", file(cs, "gone.c").status)
		assert.equals(2, file(cs, "gone.c").removed)
		local view, lines = show(cs, "gone.c")
		assert.same({ "// old", "return 42;" }, lines)
		assert.is_true(view.deleted_file)
		assert.is_false(vim.bo[view.bufnr].modifiable)
		assert.equals(0, vim.fn.filereadable(repo.dir .. "/gone.c"))
	end)

	local function merge_fixture()
		repo:write("base.txt", { "common" })
		local base = repo:commit("base")
		repo:write("left.txt", { "left parent" })
		local left = repo:commit("left")
		repo:jj({ "new", base })
		repo:write("right.txt", { "right parent" })
		local right = repo:commit("right")
		repo:jj({ "new", left, right })
		return left, right
	end

	it("diffs against the merged parents, not just either single parent", function()
		local left, right = merge_fixture()
		local clean = repo:build()
		assert.same({}, clean.files)
		assert.equals("parents:" .. left .. "," .. right, clean.base_rev)
		repo:write("merge-only.txt", { "resolution" })
		local cs = repo:build()
		assert.equals(1, #cs.files)
		assert.equals("added", file(cs, "merge-only.txt").status)
		assert.equals(clean.base_rev, cs.base_rev)
	end)

	it("shows a deletion whose pre-image comes from the second merged parent", function()
		merge_fixture()
		vim.fn.delete(repo.dir .. "/right.txt")
		local cs = repo:build()
		assert.equals(1, #cs.files)
		assert.equals("deleted", file(cs, "right.txt").status)
		local view, lines = show(cs, "right.txt")
		assert.same({ "right parent" }, lines)
		assert.is_true(view.deleted_file)
	end)

	it("detects real nested repositories and prefers jj at colocated boundaries", function()
		local vcs = require("draven.core.vcs")
		local outer = sandbox .. "/boundaries"
		local inner = outer .. "/nested"
		local leaf = inner .. "/deep"
		vim.fn.mkdir(outer, "p")
		local outer_repo = setmetatable({ dir = outer }, Repo)
		outer_repo:jj({ "git", "init", "." })
		vim.fn.mkdir(inner, "p")
		local inner_repo = setmetatable({ dir = inner }, Repo)
		inner_repo:jj({ "git", "init", "--colocate", "." })
		-- Leave a real Git repository, removing only TEMP fixture jj metadata.
		vim.fn.delete(inner .. "/.jj", "rf")
		vim.fn.mkdir(leaf, "p")
		local backend, root, name = vcs.detect(leaf, "auto")
		assert.equals("git", name)
		assert.equals(inner, root)
		assert.equals(require("draven.core.git"), backend)
		backend, root, name = vcs.detect(leaf, "jj")
		assert.equals("jj", name)
		assert.equals(outer, root)
		assert.equals(require("draven.core.jj"), backend)
		inner_repo:jj({ "git", "init", "--colocate", "." })
		backend, root, name = vcs.detect(leaf, "auto")
		assert.equals("jj", name)
		assert.equals(inner, root)
		local _, git_root, git_name = vcs.detect(leaf, "git")
		assert.equals("git", git_name)
		assert.equals(inner, git_root)
	end)

	it("finds a real nested noncolocated jj workspace inside a Git repository", function()
		local outer = sandbox .. "/git-boundary"
		local inner = outer .. "/jj-workspace"
		vim.fn.mkdir(outer, "p")
		setmetatable({ dir = outer }, Repo):jj({ "git", "init", "--colocate", "." })
		vim.fn.delete(outer .. "/.jj", "rf")
		vim.fn.mkdir(inner, "p")
		setmetatable({ dir = inner }, Repo):jj({ "git", "init", "." })
		vim.fn.mkdir(inner .. "/src", "p")
		local _, root, name = require("draven.core.vcs").detect(inner .. "/src", "auto")
		assert.equals("jj", name)
		assert.equals(inner, root)
	end)

	it("completes real jj bookmarks with prefix filtering", function()
		repo:write("a.txt", { "base" })
		repo:commit("base")
		repo:jj({ "bookmark", "create", "draven-test-one", "-r", "@-" })
		repo:jj({ "bookmark", "create", "draven-test-two", "-r", "@-" })
		local previous = vim.fn.getcwd()
		vim.cmd.cd(vim.fn.fnameescape(repo.dir))
		local ok, result = pcall(function()
			return require("draven.command").complete("draven-test-")
		end)
		vim.cmd.cd(vim.fn.fnameescape(previous))
		assert.is_true(ok, tostring(result))
		table.sort(result)
		assert.same({ "draven-test-one", "draven-test-two" }, result)
	end)

	it("uses configured detection and rejects unknown or absent backends", function()
		config.setup({ backend = "jj" })
		local _, root, name = require("draven.core.vcs").detect(repo.dir)
		assert.equals("jj", name)
		assert.equals(repo.dir, root)
		fails(function()
			require("draven.core.vcs").detect(repo.dir, "bogus")
		end, "backend")
		local outside = sandbox .. "/outside"
		vim.fn.mkdir(outside, "p")
		fails(function()
			require("draven.core.vcs").detect(outside, "auto")
		end, "not inside")
	end)
end)
