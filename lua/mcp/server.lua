local M = {}
local tools = require("mcp.tools")

local uv = vim.uv or vim.loop
local all_servers = {}
M.all_servers = all_servers

-- Logging setup
local state_dir = vim.fn.stdpath("state")
local log_file = state_dir .. "/mcp/server.log"
vim.fn.mkdir(state_dir .. "/mcp", "p")

local function log_to_file(msg)
	local f = io.open(log_file, "a")
	if f then
		f:write(os.date("%H:%M:%S") .. " [SERVER] " .. msg .. "\n")
		f:close()
	end
end

-- Generic JSON-RPC Error Codes
local PARSE_ERROR = -32700
local INVALID_REQUEST = -32600
local METHOD_NOT_FOUND = -32601
local INVALID_PARAMS = -32602
local INTERNAL_ERROR = -32603

local function make_response(id, result, error)
	return {
		jsonrpc = "2.0",
		id = id,
		result = result,
		error = error,
	}
end

local function make_notification(method, params)
	return {
		jsonrpc = "2.0",
		method = method,
		params = params,
	}
end

local function send_json(client, data)
	if not client or client:is_closing() then
		return
	end
	local encoded = vim.json.encode(data)

	log_to_file("Sending: " .. (encoded:sub(1, 100) .. (encoded:len() > 100 and "..." or "")))
	client:write(encoded .. "\n")
end

local function handle_request(client, request, on_init)
	local id = request.id
	local method = request.method
	local params = request.params or {}

	log_to_file("Recv Request: " .. method)

	if method == "initialize" then
		local client_version = params.protocolVersion or "2024-11-05"
		send_json(
			client,
			make_response(id, {
				protocolVersion = client_version,
				serverInfo = {
					name = "mcp.nvim",
					version = "0.1.0",
				},
				capabilities = {
					tools = {
						listChanged = true,
					},
					resources = vim.empty_dict(),
					prompts = vim.empty_dict(),
				},
			})
		)
		return
	end

	if method == "notifications/initialized" then
		log_to_file("Client Initialized")
		if on_init then
			on_init()
		end
		return
	end

	if method == "ping" then
		send_json(client, make_response(id, {}))
		return
	end

	if method == "prompts/list" then
		send_json(client, make_response(id, { prompts = {} }))
		return
	end

	if method == "resources/list" then
		send_json(client, make_response(id, { resources = {} }))
		return
	end

	if method == "notifications/roots/list_changed" then
		log_to_file("Roots List Changed")
		return
	end

	if method == "tools/list" then
		send_json(client, make_response(id, { tools = tools.get_tool_specs() }))
		return
	end

	if method == "tools/call" then
		local name = params.name
		local args = params.arguments or {}
		local content = ""
		local is_error = false
		local err_msg = nil

		vim.schedule(function()
			local tool_handler = tools.get_tool_handler(name)
			if tool_handler then
				local ok, result = pcall(tool_handler, args)
				if not ok then
					is_error = true
					err_msg = "Internal Error: " .. tostring(result)
				elseif type(result) == "string" then
					content = result
				elseif type(result) == "table" then
					content = vim.json.encode(result)
				else
					content = tostring(result)
				end
			else
				is_error = true
				err_msg = "Tool not found: " .. name
			end

			if is_error then
				send_json(
					client,
					make_response(id, nil, {
						code = INTERNAL_ERROR,
						message = err_msg,
					})
				)
			else
				send_json(
					client,
					make_response(id, {
						content = {
							{
								type = "text",
								text = content,
							},
						},
						isError = false,
					})
				)
			end
		end)
		return
	end

	if id then
		send_json(
			client,
			make_response(id, nil, {
				code = METHOD_NOT_FOUND,
				message = "Method not found: " .. method,
			})
		)
	end
end

function M.notify_all(method, params)
	for _, s in ipairs(all_servers) do
		s:notify_all(method, params)
	end
end

--- @class mcp.ServerState
--- @field handle uv.uv_tcp_t
--- @field sessions any[]

--- @return mcp.ServerState, integer
function M.start(port, token, on_init)
	local server_state = {
		handle = uv.new_tcp(),
		sessions = {},
	}

	log_to_file("Starting Server on port " .. tostring(port))

	function server_state:stop()
		log_to_file("Stopping Server")
		if self.handle then
			self.handle:close()
			self.handle = nil
		end
		for _, client in ipairs(self.sessions) do
			if not client:is_closing() then
				client:close()
			end
		end
		self.sessions = {}
		for i, s in ipairs(all_servers) do
			if s == self then
				table.remove(all_servers, i)
				break
			end
		end
	end

	function server_state:notify_all(method, params)
		for _, client in ipairs(self.sessions) do
			if not client:is_closing() then
				send_json(client, make_notification(method, params))
			end
		end
	end
	server_state.handle:bind("127.0.0.1", port)
	server_state.handle:listen(128, function(err)
		if err then
			log_to_file("Listen Error: " .. tostring(err))
			return
		end
		local client = uv.new_tcp()
		assert(client, "failed to create tcp client")
		server_state.handle:accept(client)

		log_to_file("Client Connected")

		table.insert(server_state.sessions, client)

		local buffer = ""
		local content_length = nil
		client:read_start(function(read_err, chunk)
			if read_err or not chunk then
				log_to_file("Client Disconnected")
				client:close()
				for i, s in ipairs(server_state.sessions) do
					if s == client then
						table.remove(server_state.sessions, i)
						break
					end
				end
				return
			end

			log_to_file("Recv Chunk: " .. #chunk .. " bytes")

			buffer = buffer .. chunk
			while true do
				if not content_length then
					-- State 1: Reading Headers OR Raw JSON Line
					if buffer:match("^Content%-Length:") then
						-- Case A: LSP Framing
						local start_idx, end_idx = buffer:find("\r\n\r\n", 1, true)
						if not start_idx then
							start_idx, end_idx = buffer:find("\n\n", 1, true)
						end

						if start_idx then
							local headers = buffer:sub(1, start_idx - 1)
							buffer = buffer:sub(end_idx + 1)

							local len_match = headers:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
							if len_match then
								content_length = tonumber(len_match)
								log_to_file("LSP Header Found, Len: " .. content_length)
							else
								log_to_file("LSP Header missing Content-Length: " .. headers)
								-- fallback to line mode if header is mangled?
								break
							end
						else
							break -- wait for more header data
						end
					else
						-- Case B: Raw JSON Line (or just wait for more data)
						local line_end = buffer:find("\n", 1, true)
						if line_end then
							local line = buffer:sub(1, line_end)
							buffer = buffer:sub(line_end + 1)

							log_to_file("Raw Line Found: " .. (line:sub(1, 50) .. "..."))
							local ok, req = pcall(vim.json.decode, line)
							if ok and req then
								handle_request(client, req, on_init)
							else
								-- Not valid JSON, maybe just whitespace or garbage
								log_to_file("Invalid JSON line: " .. line)
							end
						else
							-- No newline and no Content-Length header yet.
							-- If buffer is very long and still no newline, it's garbage.
							if #buffer > 10000 then
								log_to_file("Buffer overflow, clearing")
								buffer = ""
							end
							break
						end
					end
				else
					-- State 2: Reading LSP Body
					if #buffer >= content_length then
						local body = buffer:sub(1, content_length)
						buffer = buffer:sub(content_length + 1)
						content_length = nil

						log_to_file("LSP Body Decoded: " .. (body:sub(1, 50) .. "..."))

						local ok, req = pcall(vim.json.decode, body)
						if ok and req then
							handle_request(client, req, on_init)
						else
							log_to_file("LSP Body JSON Decode Error")
						end
					else
						break -- Not enough data for body
					end
				end
			end
		end)
	end)

	local sockname = server_state.handle:getsockname()
	assert(sockname, "failed to get sockname")
	assert(type(sockname.port) == "number", "unexpected socketname.port:" .. vim.inspect(sockname.port))
	table.insert(all_servers, server_state)
	return server_state, sockname.port
end
return M
