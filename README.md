# mcp.nvim

**mcp.nvim** is a Neovim plugin that implements a [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server. It allows external MCP clients (such as AI assistants) to connect to your Neovim instance, execute registered tools, and interact with the editor programmatically.

## Features

- **Automatic Server Management**: Automatically starts an MCP server for the current working directory.
- **TCP Support**: Communicates over TCP using JSON-RPC 2.0.
- **Protocol Support**: Handles both LSP-style framing (Content-Length headers) and raw JSON lines.
- **Extensible Tool API**: Easily register custom Lua functions as MCP tools that can be called by connected clients.
- **Event-Driven**: Emits Neovim User autocommands when servers are created or ready, allowing for flexible integration.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "zaucy/mcp.nvim",
    opts = {
        debug = false, -- Enable to see debug notifications
    },
}
```

## Usage

### Registering Tools

You can expose Neovim functionality to MCP clients by registering tools. A tool consists of a specification (name, description, input schema) and a handler function.

```lua
local mcp = require("mcp")

mcp.register_tool({
    name = "echo",
    description = "Echoes back the input text",
    inputSchema = {
        type = "object",
        properties = {
            text = { type = "string" },
        },
        required = { "text" },
    },
}, function(args)
    -- This function is called when the client executes the tool
    local text = args.text or ""
    vim.notify("MCP Client says: " .. text)
    return "Echo: " .. text
end)
```

### Connecting a Client

When `mcp.nvim` starts, it binds to a random available TCP port on `127.0.0.1`. Since the port changes, you can use the `McpServerReady` User autocommand to detect when the server is listening.

Example: Writing the port to a file so an external client can find it.

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "McpServerReady",
    callback = function(ev)
        local data = ev.data
        local port = data.port
        local cwd = data.cwd
        print(string.format("MCP Server for %s running on port %d", cwd, port))

        -- Setup your mcp clients to be aware of mcp.nvim
        -- For example https://github.com/zaucy/gemini.nvim uses this to setup environment variables for gemini
    end,
})
```

### API

- `require("mcp").get_server(dir)`: Get the server instance for a specific directory.
- `require("mcp").restart_all_servers()`: Restart all active MCP servers.
- `require("mcp").stop_all_servers()`: Stop all active MCP servers.

## Commands

- `:McpRestart`: Restarts all running MCP servers.
- `:McpStop`: Stops all running MCP servers.

## Logging

Server logs are written to the Neovim state directory:
- Linux/MacOS: `~/.local/state/nvim/mcp/server.log`
- Windows: `~/AppData/Local/nvim-data/mcp/server.log`

## License

MIT
