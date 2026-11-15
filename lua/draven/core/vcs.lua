---Repository discovery shared by changesets, completion and health checks.
local M = {}

---Prefer the closest repository boundary; prefer jj over Git at the same root.
---Do not let an enclosing jj workspace swallow a nested Git checkout.
function M.detect(cwd, requested)
	local choice = requested or require("draven.config").options.backend
	if choice ~= "auto" and choice ~= "git" and choice ~= "jj" then
		error("draven: backend must be auto, git or jj", 0)
	end
	local dir = vim.fs.normalize(vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"))
	while dir do
		for _, name in ipairs({ "jj", "git" }) do
			if
				(choice == "auto" or choice == name)
				and (vim.uv or vim.loop).fs_stat(dir .. "/." .. name)
			then
				return require("draven.core." .. name), dir, name
			end
		end
		local parent = vim.fs.dirname(dir)
		if parent == dir then
			break
		end
		dir = parent
	end
	error(
		"draven: not inside a " .. (choice == "auto" and "jj or git" or choice) .. " repository",
		0
	)
end

return M
