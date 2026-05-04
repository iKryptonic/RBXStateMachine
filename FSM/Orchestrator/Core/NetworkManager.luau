--!strict


--[=[
	@module NetworkManager
	@description Singleton network layer managing RemoteEvent and RemoteFunction lifecycle, named request callback dispatch, entity command routing, event buses, and per-remote call telemetry. Initialize once per runtime context via `NetworkManager.Initialize(Util)` before calling any other method.
]=]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal, Initialized

local NetworkManager = {
	_initialized = false,

	-- Remotes
	OrchestratorEvent = nil :: RemoteEvent?,
	OrchestratorFunction = nil :: RemoteFunction?,
	EntityUpdateEvent = nil :: RemoteEvent?,
	EntityCommandEvent = nil :: RemoteEvent?,

	-- Callbacks
	ServerRequestCallbacksSync = {} :: { [string]: (Player, ...any) -> any },
	ServerRequestCallbacksAsync = {} :: { [string]: (Player, ...any) -> any },
	EntityCommandCallbacks = {} :: { [string]: { [string]: (Player, ...any) -> () } },
	EventBuses = {} :: { [string]: any },

	-- Runtime statistics (populated automatically)
	_invokeStats = {} :: { [string]: { Count: number, LastInvoked: number } },
	_busStats = {} :: { [string]: { Count: number, LastFired: number, RecentCalls: { { Time: number, Args: string } }? } },
	-- Per-remote (RemoteEvent / RemoteFunction) call tracking. Keyed by the
	-- prefixed name used in NetworkModule's row id, e.g. "Remote:OrchestratorEvent".
	_remoteStats = {} :: { [string]: { Count: number, LastFired: number, RecentCalls: { { Time: number, Args: string, Direction: string } } } },
	_connections = {} :: { RBXScriptConnection },
}

-- ──────────────────────────────────────────────────────────────────────────
-- Stats helpers
-- ──────────────────────────────────────────────────────────────────────────

local function sanitizeForReplication(value: any, depth: number): any
	if depth > 4 then return"[...]" end
	local t = type(value)
	if t == "string" or t == "number" or t == "boolean" or t == "nil" then
		return value
	elseif t == "table" then
		local out = {}
		local count = 0
		for k, v in pairs(value) do
			count += 1
			if count > 16 then
				out["…"] = string.format("(+%d more)", count - 16)
				break
			end
			out[tostring(k)] = sanitizeForReplication(v, depth + 1)
		end
		return out
	elseif t == "userdata" then
		-- Use [...] not <...> so RichText TextLabels (which interpret
		-- angle brackets as font tags) render the type tag visibly.
		local ok, n = pcall(function() return tostring(value) end)
		return ok and ("[userdata:" .. tostring(n) .."]") or "[userdata]"
	else
		return"[" .. t .."]"
	end
end

local function formatArgsInline(packed): string
	local parts = {}
	local n = packed.n or #packed
	for i = 1, math.min(n, 4) do
		local v = packed[i]
		local t = type(v)
		if t == "string" then table.insert(parts, string.format("%q", v))
		elseif t == "number" or t == "boolean" then table.insert(parts, tostring(v))
		elseif t == "table" then
			-- Render a brief inline preview instead of "{table}". Show up to
			-- 3 keys with their values truncated. Click-to-expand in the UI
			-- shows full structure.
			local kvs = {}
			local kcount = 0
			for k, val in pairs(v) do
				kcount += 1
				if kcount > 3 then break end
				local vt = type(val)
				local vstr
				if vt == "string" then vstr = #val > 12 and (string.sub(val, 1, 10) .."..") or val
				elseif vt == "number" or vt == "boolean" then vstr = tostring(val)
				elseif vt == "table" then vstr = "{...}"
				else vstr = "[" .. vt .."]"-- not <...> (RichText would parse as font tag)
				end
				table.insert(kvs, tostring(k) .."=" .. vstr)
			end
			local total = 0
			for _ in pairs(v) do total += 1 end
			if total > 3 then table.insert(kvs,"+" .. (total - 3)) end
			table.insert(parts,"{" .. table.concat(kvs,", ") .."}")
		elseif t == "nil" then table.insert(parts,"nil")
		else table.insert(parts,"[" .. t .."]") end -- same RichText fix
	end
	if n > 4 then table.insert(parts,"...+" .. (n - 4)) end
	return"(" .. table.concat(parts,", ") ..")"
end

local function formatArgs(packed): string
	-- Legacy export — kept name for compatibility but now produces the
	-- inline preview form (table values are summarized as {k=v, +N} instead
	-- of useless "{table}" placeholder).
	return formatArgsInline(packed)
end

local function ValidateRequest(context: string?)
	assert(Initialized,"NetworkManager not initialized")
	if context then
		assert(context == "Server" or context == "Client","Invalid context")
		if context == "Server" and RunService:IsClient() then
			assert(false,"NetworkManager: Invalid context. Cannot make server request on client")
		end
		if context == "Client" and RunService:IsServer() then
			assert(false,"NetworkManager: Invalid context. Cannot make client request on server")
		end
	end
end

local function CreateRemote(name: string, className: string): any
	if not name then return nil end

	if RunService:IsClient() then
		return ReplicatedStorage:WaitForChild(name)
	end

	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA(className) then return existing end

	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local function DisconnectTrackedConnections()
	for i = #NetworkManager._connections, 1, -1 do
		local connection = NetworkManager._connections[i]
		if connection then
			connection:Disconnect()
		end
		NetworkManager._connections[i] = nil
	end
end


--[=[
	@description Forwards a formatted log entry to the module-level Logger instance created during `Initialize`. Requires the module to be initialized.
	@param params { Level: string, Message: string, OperationId: string } -- Log entry fields passed directly to `NetworkManager.Logger:Log`.
	@reads NetworkManager.Logger
]=]

function NetworkManager.Log(params: { Level: string, Message: string, OperationId: string })
	ValidateRequest()
	NetworkManager.Logger:Log(params)
end


--[=[
	@description One-time setup that creates or retrieves the four shared RemoteEvent/RemoteFunction instances in `ReplicatedStorage`, initialises the `Signal` module reference and internal Logger, wires runtime listeners for the current execution context (server or client), and creates the `EventBusRegistered` signal. No-ops on subsequent calls via the module-level `Initialized` guard.
	@param Util table -- Shared utility table providing `Util.Logger`, `Util.Signal`, and `Util.Settings.StaticStrings` for remote instance names.
	@writes Initialized, NetworkManager.Logger, NetworkManager.OrchestratorEvent, NetworkManager.OrchestratorFunction, NetworkManager.EntityUpdateEvent, NetworkManager.EntityCommandEvent, NetworkManager.EventBusRegistered
]=]

function NetworkManager.Initialize(Util)
	if Initialized then return end
	Initialized = true

	NetworkManager.Logger = Util.Logger.new({ Name = "NetworkManager" }) :: any
	Signal = Util.Signal

	local Strings = Util.Settings.StaticStrings
	NetworkManager.OrchestratorEvent = CreateRemote(Strings.Instance.OrchestratorEventName,"RemoteEvent")
	NetworkManager.OrchestratorFunction = CreateRemote(Strings.Instance.OrchestratorFunctionName,"RemoteFunction")
	NetworkManager.EntityUpdateEvent = CreateRemote(Strings.Instance.EntityUpdateEventName,"RemoteEvent")
	NetworkManager.EntityCommandEvent = CreateRemote(Strings.Instance.EntityCommandEventName,"RemoteEvent")
	NetworkManager.EventBusRegistered = Signal.new()

	if RunService:IsServer() then
		NetworkManager._RegisterServerListeners()
	else
		NetworkManager._RegisterClientListeners()
	end
	NetworkManager.Log({ Level = "INFO", Message = "NetworkManager initialized" })
end


--[=[
	@description Registers a named server-side callback for inbound client requests. Async handlers are stored in `ServerRequestCallbacksAsync` and invoked via `OrchestratorEvent`; sync handlers go into `ServerRequestCallbacksSync` and are invoked via `OrchestratorFunction:InvokeServer`. Must be called server-side.
	@param name string -- Logical request key clients pass as the first argument to `ServerRequest` or `ServerRequestAsync`.
	@param handler (Player, ...any) -> any -- Callback invoked with the requesting player and the forwarded request arguments.
	@param isAsync boolean? -- When truthy, registers an async fire-and-forget handler; otherwise registers a synchronous handler whose return value is sent back to the client.
	@writes NetworkManager.ServerRequestCallbacksSync, NetworkManager.ServerRequestCallbacksAsync
]=]

function NetworkManager.RegisterServerRequest(name: string, handler: (Player, ...any) -> any, isAsync: boolean?)
	ValidateRequest("Server")
	if isAsync then
		NetworkManager.ServerRequestCallbacksAsync[name] = handler
	else
		NetworkManager.ServerRequestCallbacksSync[name] = handler
	end
	NetworkManager.Log({ Level = "INFO", Message = "Registered server request callback for " .. name })
end


--[=[
	@description Maps an `(entityId, command)` pair to a handler in `EntityCommandCallbacks`. Creates the entity sub-table on first use. Called on both server and client to register handlers for incoming entity commands in the respective runtime context.
	@param entityId string -- Identifier of the entity whose command table this handler is registered under.
	@param command string -- Command name used to select this handler when an entity command arrives.
	@param handler (Player, ...any) -> () -- Callback invoked with the triggering player (or nil on the client) and any forwarded arguments.
	@writes NetworkManager.EntityCommandCallbacks
]=]

function NetworkManager.RegisterEntityCommand(entityId: string, command: string, handler: (Player, ...any) -> ())
	ValidateRequest()
	if not NetworkManager.EntityCommandCallbacks[entityId] then
		NetworkManager.EntityCommandCallbacks[entityId] = {}
	end
	NetworkManager.EntityCommandCallbacks[entityId][command] = handler
	NetworkManager.Log({ Level = "INFO", Message = "Registered entity command callback for " .. entityId ..": " .. command })
end


--[=[
	@description Removes all registered command handlers for the given entity by setting `EntityCommandCallbacks[entityId]` to nil. Must be called server-side. Typically invoked when an entity is destroyed to prevent dangling callback references.
	@param entityId string -- Identifier of the entity whose entire command handler sub-table should be removed.
	@writes NetworkManager.EntityCommandCallbacks
]=]

function NetworkManager.UnregisterEntityCommands(entityId: string)
	ValidateRequest("Server")
	NetworkManager.EntityCommandCallbacks[entityId] = nil
	NetworkManager.Log({ Level = "INFO", Message = "Unregistered entity command callbacks for " .. entityId })
end

--[[
	@description Internal helper that records RemoteEvent/RemoteFunction call history
	for dashboard drill-down views.
	@param remoteName string -- Remote/stat bucket identifier
	@param direction string -- Human-readable traffic direction label
	@param packedArgs table -- table.pack(...) result for the call payload
	@return ()
	@reads NetworkManager._remoteStats
	@writes NetworkManager._remoteStats
]]
local function trackRemoteCall(remoteName: string, direction: string, packedArgs)
	local key = "Remote:" .. remoteName
	local stats = NetworkManager._remoteStats[key]
	if not stats then
		stats = { Count = 0, LastFired = 0, RecentCalls = {} }
		NetworkManager._remoteStats[key] = stats
	end
	stats.Count += 1
	stats.LastFired = os.clock()
	if not stats.RecentCalls then stats.RecentCalls = {} end
	-- Store both the inline summary string AND a structured (sanitized,
	-- depth-capped) snapshot of each arg so the dashboard can render
	-- click-to-expand drill-downs of nested table arguments instead of
	-- showing useless "{table}" placeholders.
	local argsStruct = {}
	local n = packedArgs.n or #packedArgs
	for i = 1, math.min(n, 8) do
		argsStruct[i] = sanitizeForReplication(packedArgs[i], 0)
	end
	argsStruct.n = math.min(n, 8)
	if n > 8 then argsStruct.truncated = n - 8 end

	table.insert(stats.RecentCalls, {
		Time = os.clock(),
		Args = formatArgs(packedArgs),
		ArgsStruct = argsStruct,
		Direction = direction,
	})
	while #stats.RecentCalls > 30 do
		table.remove(stats.RecentCalls, 1)
	end
end
--[=[
	@description Sends an entity command from a client to the server through `EntityCommandEvent`. The payload is packed to preserve trailing nil values, recorded in `_remoteStats` under `"EntityCommandEvent"`, and then fired to the server.
	@param entityId string -- Identifier of the entity whose command handler should run on the server.
	@param command string -- Command name used to look up the server-side entity callback.
	@param ... any -- Additional command arguments forwarded to the server handler unchanged.
	@reads NetworkManager.EntityCommandEvent, NetworkManager._remoteStats
	@writes NetworkManager._remoteStats
]=]

function NetworkManager.ServerCommandEntity(entityId: string, command: string, ...: any)
	ValidateRequest("Client")
	local packed = table.pack(...)
	if NetworkManager.EntityCommandEvent then
		trackRemoteCall("EntityCommandEvent","C→S", table.pack(entityId, command, table.unpack(packed, 1, packed.n)))
		NetworkManager.EntityCommandEvent:FireServer(entityId, command, table.unpack(packed, 1, packed.n))
	end
end
--[=[
	@description Broadcasts an entity command from the server to every client through `EntityCommandEvent:FireAllClients`. The command and payload are mirrored into `_remoteStats` telemetry before firing so the dashboard can inspect outbound traffic.
	@param entityId string -- Identifier of the replicated entity that clients should route the command to.
	@param command string -- Command name clients use to select the appropriate entity handler.
	@param ... any -- Additional command arguments replicated to every client unchanged.
	@reads NetworkManager.EntityCommandEvent, NetworkManager._remoteStats
	@writes NetworkManager._remoteStats
]=]

function NetworkManager.BroadcastEntityCommand(entityId: string, command: string, ...: any)
	ValidateRequest("Server")
	local packed = table.pack(...)
	if NetworkManager.EntityCommandEvent then
		trackRemoteCall("EntityCommandEvent","S→All", table.pack(entityId, command, table.unpack(packed, 1, packed.n)))
		NetworkManager.EntityCommandEvent:FireAllClients(entityId, command, table.unpack(packed, 1, packed.n))
	end
end


--[=[
	@description Broadcasts an entity state-change table from the server to all clients through `EntityUpdateEvent:FireAllClients`. Telemetry is recorded in `_remoteStats` under the `"EntityUpdateEvent"` key before firing.
	@param entityId string -- Identifier of the entity being updated on all clients.
	@param changes { [string]: any } -- Partial state table containing only the properties that changed.
	@reads NetworkManager.EntityUpdateEvent, NetworkManager._remoteStats
	@writes NetworkManager._remoteStats
]=]

function NetworkManager.BroadcastEntityUpdate(entityId: string, changes: { [string]: any })
	ValidateRequest("Server")
	if NetworkManager.EntityUpdateEvent then
		trackRemoteCall("EntityUpdateEvent","S→All", table.pack(entityId, changes))
		NetworkManager.EntityUpdateEvent:FireAllClients(entityId, changes)
	end
end
--[=[
	@description Performs a synchronous client-to-server request through `OrchestratorFunction`. The request name and packed payload are logged to remote-call telemetry before invoking the server and the server's return value is passed back to the caller. Returns `nil` when the remote has not been initialized.
	@param requestName string -- Logical request key used to select a registered synchronous server callback.
	@param ... any -- Request arguments forwarded to the server callback unchanged.
	@return any -- Value returned by the server callback, or `nil` if no remote function is available.
	@reads NetworkManager.OrchestratorFunction, NetworkManager._remoteStats
	@writes NetworkManager._remoteStats
]=]

function NetworkManager.ServerRequest(requestName: string, ...: any)
	ValidateRequest("Client")
	local packed = table.pack(...)
	if NetworkManager.OrchestratorFunction then
		trackRemoteCall("OrchestratorFunction","C→S (sync)", table.pack(requestName, table.unpack(packed, 1, packed.n)))
		return NetworkManager.OrchestratorFunction:InvokeServer("AppRequestSync", requestName, table.unpack(packed, 1, packed.n))
	end
	return nil
end
--[=[
	@description Queues an asynchronous client-to-server application request through `OrchestratorEvent`. The payload is packed to preserve nils, recorded in remote-call telemetry, and then fired without waiting for a response.
	@param requestName string -- Logical request key used to select a registered asynchronous server callback.
	@param ... any -- Request arguments forwarded to the server callback unchanged.
	@reads NetworkManager.OrchestratorEvent, NetworkManager._remoteStats
	@writes NetworkManager._remoteStats
]=]

function NetworkManager.ServerRequestAsync(requestName: string, ...: any)
	ValidateRequest("Client")
	local packed = table.pack(...)
	if NetworkManager.OrchestratorEvent then
		trackRemoteCall("OrchestratorEvent","C→S (async)", table.pack(requestName, table.unpack(packed, 1, packed.n)))
		NetworkManager.OrchestratorEvent:FireServer("AppRequestAsync", requestName, table.unpack(packed, 1, packed.n))
	end
end


--[=[
	@description Creates and stores a new Signal-backed event bus at `EventBuses[name]` if one does not already exist, then fires `EventBusRegistered` with the bus name. Returns the existing or newly created Signal.
	@param name string -- Unique identifier for the event bus.
	@return Signal -- The registered Signal instance for `name`.
	@writes NetworkManager.EventBuses
]=]

function NetworkManager.RegisterEventBus(name: string)
	ValidateRequest()
	if not NetworkManager.EventBuses[name] then
		NetworkManager.EventBuses[name] = Signal.new()
		NetworkManager.EventBusRegistered:Fire(name)
		NetworkManager.Log({ Level = "INFO", Message = "Registered event bus " .. name })
	end
	return NetworkManager.EventBuses[name]
end


--[=[
	@description Destroys the Signal stored at `EventBuses[name]` (calling `:Destroy()` if available) and removes the entry from the table. Subsequent `GetEventBus` or `FireEventBus` calls for this name will return nil or silently skip until the bus is re-registered.
	@param name string -- Identifier of the event bus to tear down.
	@writes NetworkManager.EventBuses
]=]

function NetworkManager.UnregisterEventBus(name: string)
	ValidateRequest()
	local bus = NetworkManager.EventBuses[name]
	if bus and type(bus.Destroy) == "function" then bus:Destroy() end
	NetworkManager.EventBuses[name] = nil
	NetworkManager.Log({ Level = "INFO", Message = "Unregistered event bus " .. name })
end


--[=[
	@description Returns the Signal instance registered under `name`, or `nil` if no bus with that name has been registered. Does not create a new bus.
	@param name string -- Identifier of the event bus to retrieve.
	@return Signal? -- The Signal for `name`, or `nil` if absent.
	@reads NetworkManager.EventBuses
]=]

function NetworkManager.GetEventBus(name: string)
	ValidateRequest()
	return NetworkManager.EventBuses[name]
end
--[=[
	@description Fires the named event bus and updates its analytics entry in `_busStats`. Each emission increments the call count, records the wall-clock timestamp, and appends a row to a capped 30-entry ring buffer containing both an inline string preview and a sanitized depth-limited structured snapshot of the arguments for UI drill-down. Silently no-ops when no bus is registered for `name`.
	@param name string -- Event bus identifier previously registered with `RegisterEventBus`.
	@param ... any -- Payload forwarded to all connected listeners and captured in the recent-call history.
	@reads NetworkManager.EventBuses, NetworkManager._busStats
	@writes NetworkManager._busStats
]=]

function NetworkManager.FireEventBus(name: string, ...)
	ValidateRequest()
	if NetworkManager.EventBuses[name] then
		-- Track bus fire stats
		local stats = NetworkManager._busStats[name]
		if not stats then
			stats = { Count = 0, LastFired = 0, RecentCalls = {} }
			NetworkManager._busStats[name] = stats
		end
		stats.Count += 1
		stats.LastFired = os.clock()

		-- Track recent calls (ring buffer of 30) for the View Calls drill-down.
		-- Use the shared formatArgs (which inline-summarizes tables) and
		-- also store a sanitized structured snapshot for click-to-expand.
		if not stats.RecentCalls then stats.RecentCalls = {} end
		local args = table.pack(...)
		local argsStr = formatArgs(args)
		local argsStruct = {}
		for i = 1, math.min(args.n, 8) do
			argsStruct[i] = sanitizeForReplication(args[i], 0)
		end
		argsStruct.n = math.min(args.n, 8)
		if args.n > 8 then argsStruct.truncated = args.n - 8 end
		table.insert(stats.RecentCalls, {
			Time = os.clock(),
			Args = argsStr,
			ArgsStruct = argsStruct,
		})
		while #stats.RecentCalls > 30 do
			table.remove(stats.RecentCalls, 1)
		end

		NetworkManager.EventBuses[name]:Fire(...)
	end
end


--[=[
	@description Polls every 0.1 seconds until an event bus with the given name is registered, then returns it. If `timeout` seconds elapse before the bus appears, returns `nil`. Useful for consumers that may initialize before the producer that registers the bus.
	@param name string -- Identifier of the event bus to wait for.
	@param timeout number? -- Maximum seconds to wait before giving up. If omitted, waits indefinitely.
	@return Signal? -- The registered Signal, or `nil` on timeout.
	@reads NetworkManager.EventBuses
]=]

function NetworkManager.AwaitEventBus(name: string, timeout: number?)
	ValidateRequest()
	local start = os.clock()
	while not NetworkManager.EventBuses[name] do
		if timeout and (os.clock() - start >= timeout) then
			return nil
		end
		task.wait(0.1)
	end
	return NetworkManager.EventBuses[name]
end


--[=[
	@description Wires all server-side remote listeners after disconnecting any previously tracked connections. Sets `OrchestratorFunction.OnServerInvoke` and connects `OrchestratorEvent.OnServerEvent` to a shared handler that dispatches sync and async requests to registered callbacks, records per-request invocation stats and call history via `trackRemoteCall`, and surfaces errors through `pcall`. Also connects `EntityCommandEvent.OnServerEvent` to route entity commands and accumulate their telemetry.
	@writes NetworkManager._connections, NetworkManager._invokeStats, NetworkManager._remoteStats
]=]

function NetworkManager._RegisterServerListeners()
	ValidateRequest("Server")
	DisconnectTrackedConnections()
	local function HandleAppRequest(player, requestType, ...)
		local requestName = select(1, ...)
		local packed = table.pack(select(2, ...))

		if type(requestName) ~= "string" or requestName == "" then return nil end

		local handler
		if requestType == "AppRequestSync" then
			handler = NetworkManager.ServerRequestCallbacksSync[requestName]
		elseif requestType == "AppRequestAsync" then
			handler = NetworkManager.ServerRequestCallbacksAsync[requestName]
		end

		if handler then
			-- Track invocation stats (per-name Count + LastInvoked)
			local stats = NetworkManager._invokeStats[requestName]
			if not stats then
				stats = { Count = 0, LastInvoked = 0 }
				NetworkManager._invokeStats[requestName] = stats
			end
			stats.Count += 1
			stats.LastInvoked = os.clock()

			-- Track recent calls per ServerRequest name so the dashboard's
			-- View Calls layer has data for individual requests (not just
			-- the aggregate OrchestratorFunction/OrchestratorEvent remotes).
			-- Direction tags: client → server inbound, request type prefix.
			local dir = if requestType == "AppRequestSync" then"C→S (sync)" else"C→S (async)"
			trackRemoteCall("ServerRequest:" .. requestName, dir, packed)

			local success, result = pcall(handler, player, table.unpack(packed, 1, packed.n))
			if not success then
				NetworkManager.Log({ Level = "ERROR", Message = string.format("Request '%s' failed: %s", requestName, tostring(result)) })
			end
			return success and result or nil
		end
		return nil
	end

	if NetworkManager.OrchestratorFunction then
		NetworkManager.OrchestratorFunction.OnServerInvoke = HandleAppRequest
		NetworkManager.Log({ Level = "INFO", Message = "Registered orchestrator RemoteFunction listeners" })
	end

	if NetworkManager.OrchestratorEvent then
		table.insert(NetworkManager._connections, NetworkManager.OrchestratorEvent.OnServerEvent:Connect(HandleAppRequest))
		NetworkManager.Log({ Level = "INFO", Message = "Registered orchestrator RemoteEvent listeners" })
	end

	if NetworkManager.EntityCommandEvent then
		table.insert(NetworkManager._connections, NetworkManager.EntityCommandEvent.OnServerEvent:Connect(function(player, entityId, command, ...)
			local handlers = NetworkManager.EntityCommandCallbacks[entityId]
			if handlers and handlers[command] then
				-- Track invocation stats for entity commands
				local key = entityId ..":" .. command
				local stats = NetworkManager._invokeStats[key]
				if not stats then
					stats = { Count = 0, LastInvoked = 0 }
					NetworkManager._invokeStats[key] = stats
				end
				stats.Count += 1
				stats.LastInvoked = os.clock()

				-- Per-command call history for the dashboard's "View Calls"
				trackRemoteCall("EntityCommand:" .. key,"C→S", table.pack(...))

				handlers[command](player, ...)
			end
		end))
		NetworkManager.Log({ Level = "INFO", Message = "Registered entity command listeners" })
	end
	NetworkManager.Log({ Level = "INFO", Message = "Registered server listeners" })
end


--[=[
	@description Wires all client-side remote listeners after disconnecting any previously tracked connections. Connects `EntityCommandEvent.OnClientEvent` to route server-broadcast entity commands to registered client handlers (passing nil as the player argument). Also exposes `NetworkManager.RecordInboundCall` as a helper allowing other inbound RemoteEvent consumers (e.g., the EntityUpdateEvent listener in Orchestrator) to record receive-side call telemetry.
	@writes NetworkManager._connections, NetworkManager.RecordInboundCall
]=]

function NetworkManager._RegisterClientListeners()
	DisconnectTrackedConnections()
	if NetworkManager.EntityCommandEvent then
		table.insert(NetworkManager._connections, NetworkManager.EntityCommandEvent.OnClientEvent:Connect(function(entityId, command, ...)
			-- Track inbound entity-command broadcast (S→C direction)
			trackRemoteCall("EntityCommandEvent","S→C", table.pack(entityId, command, ...))
			local handlers = NetworkManager.EntityCommandCallbacks[entityId]
			if handlers and handlers[command] then
				handlers[command](nil, ...) -- No player on client
			end
		end))
		NetworkManager.Log({ Level = "INFO", Message = "Registered client listeners" })
	end
	-- EntityUpdateEvent listener lives in Orchestrator.init.luau, so we expose
	-- a small helper for that consumer (and any future inbound RemoteEvent
	-- consumer) to record receive-side calls.
	NetworkManager.RecordInboundCall = function(remoteName: string, direction: string, ...)
		trackRemoteCall(remoteName, direction, table.pack(...))
	end
end

return NetworkManager
