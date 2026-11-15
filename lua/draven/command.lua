---Command arguments and backend-aware revision completion.
local M = {}

function M.parse(args)
	local opts, positional = {}, {}
	local i = 1
	while i <= #args do
		local arg = args[i]
		local flag, value = arg:match("^(%-%-[%w%-]+)=(.*)$")
		flag = flag or arg
		local key = ({
			["-r"] = "rev",
			["--revision"] = "rev",
			["--from"] = "from",
			["--to"] = "to",
		})[flag]
		if key then
			if not value then
				i = i + 1
				value = args[i]
			end
			if not value or value == "" or value:match("^%-%-") or opts[key] then
				error("draven: expected one value for " .. flag, 0)
			end
			opts[key] = value
		elseif arg:sub(1, 1) == "-" then
			error("draven: unknown option " .. arg, 0)
		else
			positional[#positional + 1] = arg
		end
		i = i + 1
	end
	if #positional > 0 then
		if opts.rev or opts.from or opts.to then
			error("draven: do not mix a positional revision with revision/from/to options", 0)
		end
		opts.rev = table.concat(positional, " ")
	end
	if opts.rev and (opts.from or opts.to) then
		error("draven: use either a revision or from/to, not both", 0)
	end
	return opts
end

function M.complete(arglead)
	local ok, _, root, name = pcall(require("draven.core.vcs").detect)
	if not ok then
		return {}
	end
	local config = require("draven.config").options
	local candidates, cmd
	if name == "jj" then
		candidates = { "@", "@-", "root()", "-r", "--from", "--to" }
		cmd = {
			config.jj.bin,
			"--ignore-working-copy",
			"--no-pager",
			"--color=never",
			"bookmark",
			"list",
			"-T",
			'name ++ "\\n"',
		}
	else
		candidates = { "HEAD", "HEAD~1", "HEAD~5", "main...HEAD", "master...HEAD" }
		cmd = {
			config.git.bin,
			"for-each-ref",
			"--format=%(refname:short)",
			"refs/heads",
			"refs/tags",
			"refs/remotes",
		}
	end
	local ran, out = pcall(function()
		return vim.system(cmd, { cwd = root, timeout = config[name].timeout_ms }):wait()
	end)
	if ran and out.code == 0 then
		vim.list_extend(candidates, vim.split(out.stdout or "", "\n", { trimempty = true }))
	end
	local seen = {}
	return vim.tbl_filter(function(c)
		if seen[c] or c:sub(1, #arglead) ~= arglead then
			return false
		end
		seen[c] = true
		return true
	end, candidates)
end

return M
