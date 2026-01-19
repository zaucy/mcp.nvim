local M = {}

--- @class mcp.InternalServerInfo
--- @field server_handle mcp.ServerState
--- @field port integer
--- @field token string|nil

--- @type table<string, mcp.InternalServerInfo>
local servers = {}
local last_opts = nil

local function ensure_server(cwd)
	local server = require("mcp.server")
	cwd = vim.fn.fnamemodify(cwd, ":p")
	if cwd:sub(-1) == "/" or cwd:sub(-1) == "\\" then
		cwd = cwd:sub(1, -2)
	end

	-- Server Logic
	local srv = servers[cwd]
	if not srv then
		-- Start new server on random port (0)
		local srv_handle, port = server.start(0, nil)
		if srv_handle then
			assert(type(port) == "number")
			srv = {
				server_handle = srv_handle,
				port = port,
				token = nil,
			}
			servers[cwd] = srv
			if last_opts and last_opts.debug then
				vim.notify(string.format("Started MCP Server for %s on port %d", cwd, port), vim.log.levels.DEBUG)
			end
			vim.api.nvim_exec_autocmds("User", {
				pattern = "McpServerCreated",
				data = { cwd = cwd },
			})
		else
			vim.notify("Failed to start MCP Server for " .. cwd, vim.log.levels.ERROR)
			return nil
		end
	end

	vim.api.nvim_exec_autocmds("User", {
		pattern = "McpServerDirChange",
		data = { cwd = cwd },
	})

	return srv
end

--- get mcp server instance for a particular directory
--- @return mcp.InternalServerInfo|nil
function M.get_server(dir)
	dir = vim.fn.fnamemodify(dir, ":p")
	if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
		dir = dir:sub(1, -2)
	end

	local active_server = servers[dir]
	if active_server and active_server.server_handle then
		return active_server
	end

	return nil
end

--- @return table<string, mcp.InternalServerInfo>
function M.get_servers_map()
	return servers
end

--- @param handler mcp.ToolHandler
--- @param tool_spec mcp.ToolSpec
function M.register_tool(handler, tool_spec)
	return require("mcp.tools").register_tool(tool_spec, handler)
end

function M.stop_all_servers()
	for _, s in pairs(servers) do
		s.server_handle:stop()
	end
	servers = {}
end

function M.restart_all_servers()
	for _, s in pairs(servers) do
		s.server_handle:stop()
	end
	local dirs = vim.tbl_keys(servers)
	servers = {}
	for _, dir in ipairs(dirs) do
		ensure_server(dir)
	end
end

function M.notify_all(method, params)
	require("mcp.server").notify_all(method, params)
end

function M.setup(opts)
	last_opts = opts or {}

	local init_dir = vim.fn.getcwd()
	vim.schedule(function()
		ensure_server(init_dir)
	end)

	local group = vim.api.nvim_create_augroup("Mcp", { clear = true })

	vim.api.nvim_create_autocmd("DirChanged", {
		group = group,
		callback = function()
			ensure_server(vim.fn.getcwd())
		end,
	})

	vim.api.nvim_create_user_command("McpRestart", M.restart_all_servers, {})
	vim.api.nvim_create_user_command("McpStop", M.stop_all_servers, {})
end

return M
