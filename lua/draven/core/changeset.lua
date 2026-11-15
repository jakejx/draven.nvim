---
---Must be called inside `async.run`.
local config = require("draven.config")
local diff = require("draven.core.diff")
local fs = require("draven.util.fs")
local git = require("draven.core.git")
local vcs = require("draven.core.vcs")
local hunk = require("draven.core.hunk")
local ignore = require("draven.core.ignore")

local M = {}

---@class draven.ReviewOptions
---@field cwd? string
---@field backend? "auto"|"git"|"jj"
---@field rev? string # Git revspec or one jj revision
---@field from? string # jj only; omitted endpoint defaults to @
---@field to? string # jj only; omitted endpoint defaults to @

---@class draven.RevSpec
---@field kind "worktree"|"range"
---@field base string
---@field head string|nil # nil means the working tree
---@field symmetric boolean # true for `a...b`
---@field arg string # backend-specific revision arguments
---@field label string # canonical human-readable review scope

---Normalized result of backend.review(opts, root); storage identity is owned
---by the backend and must not be derived from the display label.
---@class draven.BackendReview
---@field revspec draven.RevSpec
---@field state_dir string # absolute directory for persisted review state
---@field state_key string # stable, filesystem-safe review identity
---@field raw string # unified diff
---@field base_rev string|nil # opaque base identity for stale detection
---@field head_rev string|nil # resolved post-image revision, when available
---@field unborn boolean
---@field git_dir string|nil # backward-compatible Git metadata

---@class draven.File
---@field path string
---@field old_path string|nil
---@field status "added"|"modified"|"deleted"|"renamed"|"copied"|"mode"
---@field binary boolean
---@field untracked boolean
---@field ignored boolean
---@field skipped string|nil # "too-large" | "unreadable"
---@field old_mode string|nil
---@field new_mode string|nil
---@field similarity integer|nil # percent, renames and copies only
---@field hunks draven.Hunk[]
---@field added integer
---@field removed integer

---@class draven.Stats
---@field files integer
---@field hunks integer
---@field added integer
---@field removed integer
---@field ignored_files integer
---@field binary_files integer

---@class draven.Changeset
---@field root string
---@field backend "git"|"jj"
---@field git_dir string|nil # Git only
---@field state_dir string # backend-owned storage directory
---@field state_key string # stable backend-specific review identity
---@field head_rev string|nil # resolved post-image revision
---@field revspec draven.RevSpec
---@field base_rev string|nil # base identity; opaque for jj merged parents
---@field unborn boolean # HEAD has no commits yet
---@field files draven.File[]
---@field stats draven.Stats
---@field created_at integer

---Parse Git revision syntax (kept for API compatibility).
M.parse_revspec = git.parse_revspec

---@param raw draven.RawFile
---@return draven.File
local function file_from_raw(raw)
	local hunks, added, removed = {}, 0, 0

	for i, rh in ipairs(raw.hunks) do
		local h = hunk.build(raw.path, rh, i)
		hunks[i] = h
		added = added + h.added
		removed = removed + h.removed
	end

	return {
		path = raw.path,
		old_path = raw.old_path,
		status = raw.status,
		binary = raw.binary,
		untracked = false,
		ignored = false,
		old_mode = raw.old_mode,
		new_mode = raw.new_mode,
		similarity = raw.similarity,
		hunks = hunks,
		added = added,
		removed = removed,
	}
end

---Untracked files have no blob to diff against, so synthesise the addition.
---@param root string
---@param path string
---@return draven.File|nil
local function untracked_file(root, path)
	local abs = root .. "/" .. path

	local stat = fs.stat(abs)
	if not stat or stat.type ~= "file" then
		return nil
	end

	---@type draven.File
	local file = {
		path = path,
		old_path = nil,
		status = "added",
		binary = false,
		untracked = true,
		ignored = false,
		hunks = {},
		added = 0,
		removed = 0,
	}

	if stat.size > config.options.max_file_bytes then
		file.skipped = "too-large"
		return file
	end

	local data = fs.read(abs)
	if not data then
		file.skipped = "unreadable"
		return file
	end

	if fs.looks_binary(data) then
		file.binary = true
		return file
	end

	local lines = vim.split(data, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines) -- trailing newline, not a final empty line
	end
	if #lines == 0 then
		return file
	end

	local dlines = {}
	for i, text in ipairs(lines) do
		dlines[i] = { kind = "add", text = text, new_lnum = i }
	end

	file.hunks = {
		hunk.build(path, {
			old_start = 0,
			old_count = 0,
			new_start = 1,
			new_count = #lines,
			section = "",
			lines = dlines,
		}, 1),
	}
	file.added = #lines

	return file
end

---@param files draven.File[]
---@return draven.Stats
local function compute_stats(files)
	local stats = {
		files = 0,
		hunks = 0,
		added = 0,
		removed = 0,
		ignored_files = 0,
		binary_files = 0,
	}

	for _, f in ipairs(files) do
		if f.binary then
			stats.binary_files = stats.binary_files + 1
		end

		if f.ignored then
			stats.ignored_files = stats.ignored_files + 1
		else
			-- Ignored files stay in the list but never inflate the denominator.
			stats.files = stats.files + 1
			stats.hunks = stats.hunks + #f.hunks
			stats.added = stats.added + f.added
			stats.removed = stats.removed + f.removed
		end
	end

	return stats
end

---@param opts? draven.ReviewOptions
---@return draven.Changeset
function M.build(opts)
	opts = opts or {}

	local cwd = opts.cwd or vim.fn.getcwd()
	local backend, _, name = vcs.detect(cwd, opts.backend)
	local root = backend.root(cwd)
	local review = backend.review(opts, root)
	local spec = review.revspec
	local files = {}
	for _, raw in ipairs(diff.parse(review.raw)) do
		files[#files + 1] = file_from_raw(raw)
	end

	if name == "git" and spec.kind == "worktree" and config.options.include_untracked then
		for _, path in ipairs(backend.untracked(root)) do
			local file = untracked_file(root, path)
			if file then
				files[#files + 1] = file
			end
		end
	end

	for _, f in ipairs(files) do
		f.ignored = ignore.match(f.path)
	end

	table.sort(files, function(a, b)
		return a.path < b.path
	end)

	return {
		root = root,
		backend = name,
		git_dir = review.git_dir,
		state_dir = review.state_dir,
		state_key = review.state_key,
		head_rev = review.head_rev,
		revspec = spec,
		base_rev = review.base_rev,
		unborn = review.unborn,
		files = files,
		stats = compute_stats(files),
		created_at = os.time(),
	}
end

---Find a file in a changeset by repo-relative path.
---@param cs draven.Changeset
---@param path string
---@return draven.File|nil
function M.file(cs, path)
	for _, f in ipairs(cs.files) do
		if f.path == path then
			return f
		end
	end
	return nil
end

---Iterate every hunk in the changeset, skipping ignored files.
---@param cs draven.Changeset
---@return fun(): draven.File|nil, draven.Hunk|nil
function M.hunks(cs)
	local fi, hi = 1, 0

	return function()
		while fi <= #cs.files do
			local f = cs.files[fi]

			if f.ignored then
				fi, hi = fi + 1, 0
			else
				hi = hi + 1
				if hi <= #f.hunks then
					return f, f.hunks[hi]
				end
				fi, hi = fi + 1, 0
			end
		end
		return nil, nil
	end
end

return M
