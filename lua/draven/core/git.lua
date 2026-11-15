---Async git plumbing.
---
---Every function here must be called inside `async.run`. Output is handled as
---raw bytes rather than `text = true`, because that option rewrites CRLF and
---would change the content hashes a review's state is keyed on.
local async = require("draven.util.async")
local config = require("draven.config")

local M = {}

---The hash of git's empty tree. Diffing against it turns "every tracked file"
---into "one big addition", which is what an unborn HEAD needs.
M.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@class draven.GitResult
---@field code integer
---@field stdout string
---@field stderr string

---@param args string[]
---@param opts? { cwd?: string, check?: boolean }
---@return draven.GitResult
function M.exec(args, opts)
	opts = opts or {}
	local cfg = config.options.git

	local cmd = { cfg.bin, "-c", "core.quotePath=false", "--no-pager" }
	vim.list_extend(cmd, args)

	local res = async.await(function(resume)
		local ok, err = pcall(vim.system, cmd, {
			cwd = opts.cwd,
			timeout = cfg.timeout_ms,
		}, function(out)
			vim.schedule(function()
				resume(out)
			end)
		end)

		if not ok then
			vim.schedule(function()
				resume({ code = -1, stdout = "", stderr = tostring(err) })
			end)
		end
	end)

	local result = {
		code = res.code or -1,
		stdout = res.stdout or "",
		stderr = res.stderr or "",
	}

	if opts.check ~= false and result.code ~= 0 then
		error(
			("draven: `git %s` failed (exit %d): %s"):format(
				table.concat(args, " "),
				result.code,
				vim.trim(result.stderr) ~= "" and vim.trim(result.stderr) or "no stderr"
			),
			0
		)
	end

	return result
end

---@param cwd? string
---@return string # absolute path to the work tree root
function M.root(cwd)
	local out = M.exec({ "rev-parse", "--show-toplevel" }, { cwd = cwd, check = false })
	if out.code ~= 0 then
		error(("draven: not inside a git repository (%s)"):format(cwd or vim.fn.getcwd()), 0)
	end
	return vim.trim(out.stdout)
end

---@param cwd? string
---@return string
function M.git_dir(cwd)
	return vim.trim(M.exec({ "rev-parse", "--absolute-git-dir" }, { cwd = cwd }).stdout)
end

---@param root string
---@return string
function M.storage_dir(root)
	return M.git_dir(root) .. "/draven"
end

---Resolve a revision to a commit sha, or nil if it does not exist.
---@param rev string
---@param cwd? string
---@return string|nil
function M.resolve(rev, cwd)
	local out = M.exec({ "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }, {
		cwd = cwd,
		check = false,
	})
	if out.code ~= 0 then
		return nil
	end
	local sha = vim.trim(out.stdout)
	return sha ~= "" and sha or nil
end

---The commit two revisions diverged from, or nil if they are unrelated.
---@param a string
---@param b string
---@param cwd? string
---@return string|nil
function M.merge_base(a, b, cwd)
	local out = M.exec({ "merge-base", a, b }, { cwd = cwd, check = false })
	if out.code ~= 0 then
		return nil
	end
	local sha = vim.trim(out.stdout)
	return sha ~= "" and sha or nil
end

---@param revargs string[] # e.g. { "HEAD" } or { "main...HEAD" }
---@param cwd string
---@return string # raw unified diff
function M.diff(revargs, cwd)
	local args = {
		"diff",
		"--no-color",
		"--no-ext-diff",
		"--find-renames",
		"-U" .. tostring(config.options.context),
	}
	vim.list_extend(args, revargs)
	args[#args + 1] = "--"
	return M.exec(args, { cwd = cwd }).stdout
end

---@param cwd string
---@return string[] # repo-relative paths
function M.untracked(cwd)
	local out = M.exec({ "ls-files", "--others", "--exclude-standard", "-z" }, { cwd = cwd })
	local paths = {}
	for _, p in ipairs(vim.split(out.stdout, "\0", { plain = true })) do
		if p ~= "" then
			paths[#paths + 1] = p
		end
	end
	return paths
end

---Read a blob at a revision. Returns nil when the path does not exist there.
---@param rev string
---@param path string
---@param cwd string
---@return string|nil
function M.show(rev, path, cwd)
	local out = M.exec({ "show", ("%s:%s"):format(rev, path) }, { cwd = cwd, check = false })
	if out.code ~= 0 then
		return nil
	end
	return out.stdout
end

---@param cwd? string
---@return string|nil # e.g. "2.51.0"
function M.version(cwd)
	local out = M.exec({ "--version" }, { cwd = cwd, check = false })
	if out.code ~= 0 then
		return nil
	end
	return out.stdout:match("(%d+%.%d+%.%d+)")
end

---@param arg string|nil
---@return draven.RevSpec
function M.parse_revspec(arg)
	arg = arg and vim.trim(arg) or ""

	if arg == "" then
		return {
			kind = "worktree",
			base = config.options.base,
			head = nil,
			symmetric = false,
			arg = arg,
		}
	end

	local a, b = arg:match("^(.-)%.%.%.(.*)$")
	if a then
		return {
			kind = "range",
			base = a ~= "" and a or "HEAD",
			head = b ~= "" and b or "HEAD",
			symmetric = true,
			arg = arg,
		}
	end

	a, b = arg:match("^(.-)%.%.(.*)$")
	if a then
		return {
			kind = "range",
			base = a ~= "" and a or "HEAD",
			head = b ~= "" and b or "HEAD",
			symmetric = false,
			arg = arg,
		}
	end

	return {
		kind = "worktree",
		base = arg,
		head = nil,
		symmetric = false,
		arg = arg,
	}
end

---Preserve Git's existing state filenames independently of display labels.
---@param spec draven.RevSpec
---@return string
local function state_key(spec)
	local raw = ("%s@%s"):format(spec.kind, spec.arg ~= "" and spec.arg or spec.base)
	local slug = raw:gsub("[^%w@%.%-_]", "-")
	if #slug > 80 then
		-- Keep it recognisable, but bounded.
		slug = slug:sub(1, 72) .. "-" .. vim.fn.sha256(raw):sub(1, 7)
	end
	return slug
end

---Git's existing revision syntax and state location are preserved.
---@return draven.BackendReview
function M.review(opts, root)
	if opts.from or opts.to then
		error("draven: from/to options currently require the jj backend", 0)
	end
	local spec = M.parse_revspec(opts.rev)
	local base_rev, unborn = nil, false
	local diff_arg = spec.arg

	if spec.kind == "worktree" then
		base_rev = M.resolve(spec.base, root)

		if not base_rev then
			if spec.base == "HEAD" then
				-- Fresh repo with no commits: everything reads as added.
				base_rev, unborn = M.EMPTY_TREE, true
			else
				error(("draven: cannot resolve revision '%s'"):format(spec.base), 0)
			end
		end

		diff_arg = unborn and M.EMPTY_TREE or spec.base
	else
		-- Ranges need a resolved base too: it is the coordinate system the
		-- old side of every hunk is measured against, and stale detection
		-- is only meaningful while it holds still.
		base_rev = spec.symmetric and M.merge_base(spec.base, spec.head, root)
			or M.resolve(spec.base, root)
	end

	spec.label = spec.kind == "range" and spec.arg
		or (unborn and "working tree (no commits yet)" or ("working tree ← %s"):format(spec.base))
	local git_dir = M.git_dir(root)
	return {
		git_dir = git_dir,
		state_dir = git_dir .. "/draven",
		state_key = state_key(spec),
		revspec = spec,
		base_rev = base_rev,
		unborn = unborn,
		raw = M.diff({ diff_arg }, root),
	}
end

---Read the complete old side of a deleted file.
---@param cs draven.Changeset
---@param file draven.File
---@return string|nil
function M.preimage(cs, file)
	return M.show(cs.base_rev or cs.revspec.base, file.old_path or file.path, cs.root)
end

return M
