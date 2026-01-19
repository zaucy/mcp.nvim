local M = {
	--- @type mcp.ToolSpec[]
	tool_specs = {},

	--- @type table<string, mcp.ToolHandler>
	tool_handlers = {},

	--- @type table<string, number>
	registered_tools = {},
}

--- @class mcp.RegisterToolSpec
--- @field name string unique tool name
--- @field description string description of tool
--- @field inputSchema any json schema defining the properties this tool can take in

--- @alias mcp.ToolSpec mcp.RegisterToolSpec|{name: string}

--- @alias mcp.ToolHandler fun(args)

--- @param tool_spec mcp.ToolSpec
--- @param handler mcp.ToolHandler
function M.register_tool(tool_spec, handler)
	assert(type(tool_spec.name) == "string")
	assert(M.registered_tools[tool_spec.name] == nil, "mcp tool " .. tool_spec.name .. " already registered")

	table.insert(M.tool_specs, tool_spec)
	M.registered_tools[tool_spec.name] = #M.tool_specs
	M.tool_handlers[tool_spec.name] = handler
end

--- @return mcp.ToolHandler|nil
function M.get_tool_handler(name)
	return M.tool_handlers[name]
end

--- @return mcp.ToolSpec[]
function M.get_tool_specs()
	return M.tool_specs
end

--- @param name string
--- @return mcp.ToolSpec|nil
function M.get_tool_spec(name)
	local index = M.registered_tools[name]
	if index ~= nil then
		return M.tool_specs[index]
	end

	return nil
end

return M
