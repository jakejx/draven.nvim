if vim.g.loaded_draven then
	return
end
vim.g.loaded_draven = true

if vim.fn.has("nvim-0.10") == 0 then
	vim.notify("[draven] requires Neovim 0.10 or newer", vim.log.levels.ERROR)
	return
end

local function with_options(cmd, callback)
	local ok, opts = pcall(require("draven.command").parse, cmd.fargs)
	if not ok then
		vim.notify(tostring(opts), vim.log.levels.ERROR)
		return
	end
	callback(opts)
end

local function complete_rev(arglead)
	return require("draven.command").complete(arglead)
end

vim.api.nvim_create_user_command("Draven", function(cmd)
	with_options(cmd, function(opts)
		require("draven").open(opts)
	end)
end, {
	nargs = "*",
	complete = complete_rev,
	desc = "Review a changeset (default: jj @ or Git working tree vs HEAD)",
})

vim.api.nvim_create_user_command("DravenClose", function()
	require("draven").close()
end, { desc = "Close the review and save its state" })

vim.api.nvim_create_user_command("DravenToggle", function(cmd)
	with_options(cmd, function(opts)
		require("draven").toggle(opts)
	end)
end, {
	nargs = "*",
	complete = complete_rev,
	desc = "Toggle the review surface",
})

vim.api.nvim_create_user_command("DravenExport", function()
	require("draven").export()
end, { desc = "Copy the review's findings as a prompt for your agent" })

vim.api.nvim_create_user_command("DravenFindings", function()
	require("draven").findings()
end, { desc = "Load the review's findings into the quickfix list" })

vim.api.nvim_create_user_command("DravenReset", function(cmd)
	with_options(cmd, function(opts)
		opts.force = cmd.bang
		require("draven").reset(opts)
	end)
end, {
	nargs = "*",
	bang = true,
	complete = complete_rev,
	desc = "Discard a review's marks and findings (! to skip the prompt)",
})

vim.api.nvim_create_user_command("DravenStatus", function(cmd)
	with_options(cmd, function(opts)
		opts.verbose = cmd.bang
		require("draven").status(opts.rev, opts)
	end)
end, {
	nargs = "*",
	bang = true,
	complete = complete_rev,
	desc = "Report a changeset without opening it (! for a per-file breakdown)",
})
