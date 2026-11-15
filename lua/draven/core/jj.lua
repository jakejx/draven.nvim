---Jujutsu plumbing. All process calls run inside draven.util.async.
local async = require("draven.util.async")
local config = require("draven.config")
local M = {}

function M.exec(args, opts)
	opts = opts or {}
	local cfg = config.options.jj
	local cmd = { cfg.bin, "--no-pager", "--color=never" }
	vim.list_extend(cmd, args)
	local result = async.await(function(resume)
		local ok, err = pcall(
			vim.system,
			cmd,
			{ cwd = opts.cwd, timeout = cfg.timeout_ms },
			function(out)
				vim.schedule(function()
					resume(out)
				end)
			end
		)
		if not ok then
			vim.schedule(function()
				resume({ code = -1, stdout = "", stderr = tostring(err) })
			end)
		end
	end)
	result.stdout, result.stderr = result.stdout or "", result.stderr or ""
	if opts.check ~= false and result.code ~= 0 then
		error(
			("draven: `jj %s` failed (exit %s): %s"):format(
				table.concat(args, " "),
				result.code,
				vim.trim(result.stderr)
			),
			0
		)
	end
	return result
end

function M.root(cwd)
	return vim.trim(M.exec({ "root", "--ignore-working-copy" }, { cwd = cwd }).stdout)
end

---Resolve exactly one revision, never silently choose a member of a revset.
local function resolve(rev, root)
	local out = M.exec(
		{ "log", "--ignore-working-copy", "--no-graph", "-r", rev, "-T", 'commit_id ++ "\\n"' },
		{ cwd = root }
	).stdout
	local ids = vim.split(vim.trim(out), "\n", { plain = true, trimempty = true })
	if #ids ~= 1 then
		error(("draven: revision '%s' must resolve to exactly one commit"):format(rev), 0)
	end
	return ids[1]
end

local function template(rev, expr, root)
	return vim.trim(
		M.exec(
			{ "log", "--ignore-working-copy", "--no-graph", "-r", rev, "-T", expr },
			{ cwd = root }
		).stdout
	)
end

---@param root string
---@return string
function M.storage_dir(root)
	return root .. "/.jj/draven"
end

---@return draven.BackendReview
function M.review(opts, root)
	if opts.rev and opts.rev ~= "" and (opts.from or opts.to) then
		error("draven: use either a revision or from/to, not both", 0)
	end
	-- Snapshot once, respecting jj's own tracking configuration. Subsequent
	-- commands use immutable commit IDs and do not snapshot again.
	M.exec({ "status" }, { cwd = root })
	local wc = resolve("@", root)
	local spec, args, base_rev, head, base_identity
	if opts.from or opts.to then
		local from, to = opts.from or "@", opts.to or "@"
		local base = resolve(from, root)
		head = resolve(to, root)
		spec = {
			kind = "range",
			base = from,
			head = head,
			symmetric = false,
			arg = ("--from %s --to %s"):format(from, to),
		}
		args = { "--from", base, "--to", head }
		base_rev = base
		base_identity = template(base, "change_id", root)
	else
		local rev = opts.rev and opts.rev ~= "" and opts.rev or "@"
		head = resolve(rev, root)
		spec = {
			kind = rev == "@" and "worktree" or "range",
			base = "parents(" .. rev .. ")",
			head = head,
			symmetric = false,
			arg = rev == "@" and "" or "-r " .. rev,
		}
		args = { "-r", head }
		-- The ordered parent IDs identify the synthetic merged base too.
		-- Conservatively invalidate old coordinates if any parent is rewritten.
		base_rev = "parents:" .. template(head, 'parents.map(|p| p.commit_id()).join(",")', root)
	end
	spec.label = (opts.from or opts.to) and spec.arg
		or (
			spec.kind == "worktree" and "working copy @ ← parents(@)"
			or "change " .. (opts.rev or "@")
		)
	local live = spec.kind == "worktree" and head == wc
	if not live then
		spec.kind = "range"
	end
	local diffargs =
		{ "diff", "--ignore-working-copy", "--git", "--context", tostring(config.options.context) }
	vim.list_extend(diffargs, args)
	local raw = M.exec(diffargs, { cwd = root }).stdout
	local identity = template(head, "change_id", root)
	local key = base_identity
			and ("target-" .. vim.fn.sha256(vim.json.encode({ "from-to", base_identity, identity })))
		or ("change-" .. identity)
	return {
		revspec = spec,
		base_rev = base_rev,
		head_rev = head,
		unborn = false,
		raw = raw,
		state_dir = M.storage_dir(root),
		state_key = key,
	}
end

function M.show(rev, path, cwd)
	local out = M.exec({
		"file",
		"show",
		"--ignore-working-copy",
		"--config",
		'templates.file_show=""',
		"-r",
		rev,
		"--",
		"root-file:" .. vim.json.encode(path),
	}, { cwd = cwd, check = false })
	return out.code == 0 and out.stdout or nil
end

---Deletion patches contain the entire pre-image, even for merged parents.
---@param _cs draven.Changeset
---@param file draven.File
---@return string
function M.preimage(_cs, file)
	local lines = {}
	for _, hunk in ipairs(file.hunks) do
		for _, line in ipairs(hunk.lines) do
			if line.kind ~= "add" then
				lines[#lines + 1] = line.text
			end
		end
	end
	return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

return M
