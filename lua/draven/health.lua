---`:checkhealth draven`
local M = {}

function M.check()
	local health = vim.health
	health.start("draven")

	if vim.fn.has("nvim-0.10") == 1 then
		health.ok("Neovim " .. tostring(vim.version()))
	else
		health.error("Neovim 0.10 or newer is required")
	end

	local config = require("draven.config")
	local detected, backend, root, name = pcall(require("draven.core.vcs").detect)
	if not detected then
		health.info(tostring(backend))
		return
	end
	local bin = config.options[name].bin

	if vim.fn.executable(bin) == 0 then
		health.error(("%s executable '%s' not found"):format(name, bin))
		return
	end

	local version = vim.fn.system({ bin, "--version" }):match("(%d+%.%d+%.%d+)")
	if version then
		health.ok(("%s %s"):format(name, version))
	else
		health.warn(("could not determine the version of '%s'"):format(bin))
	end

	local ok, dir = pcall(require("draven.util.async").block, function()
		return backend.storage_dir(root)
	end)
	if ok then
		health.ok("current directory is inside a " .. name .. " repository")
		if vim.fn.isdirectory(dir) == 1 then
			local reviews = vim.fn.glob(dir .. "/*.json", true, true)
			health.info(
				("%d saved review%s in %s"):format(#reviews, #reviews == 1 and "" or "s", dir)
			)
		else
			health.info("no reviews saved yet for this repository")
		end
	else
		health.error(tostring(dir))
	end

	if vim.fn.has("nvim-0.10") == 1 and vim.fn.exists("*sha256") == 0 then
		health.error("the sha256() function is missing — content addressing needs it")
	end

	local ignore_count = #config.options.ignore.patterns
	if config.options.ignore.enabled then
		health.ok(
			("%d ignore pattern%s active"):format(ignore_count, ignore_count == 1 and "" or "s")
		)
	else
		health.info("ignore rules are disabled")
	end
end

return M
