--!strict
-- @Name Core/NetworkManager.luau
-- @Description Handles network communications (Remotes) for the Orchestrator.

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
}

local function ValidateRequest(context: string?)
	assert(Initialized, "NetworkManager not initialized")
	if context then
		assert(context == "Server" or context == "Client", "Invalid context")
		if context == "Server" and RunService:IsClient() then
			assert(false, "NetworkManager: Invalid context. Cannot make server request on client")
		end
		if context == "Client" and RunService:IsServer() then
			assert(false, "NetworkManager: Invalid context. Cannot make client request on server")
		end
	end
end

local function CreateRemote(name: string, className: string): any
	if RunService:IsClient() then
		return ReplicatedStorage:WaitForChild(name)
	end

	if not name then return nil end

	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA(className) then return existing end

	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

function NetworkManager.Log(params: { Level: string, Message: string, OperationId: string })
	ValidateRequest()
	NetworkManager.Logger:Log(params)
end

function NetworkManager.Initialize(Util)
	if Initialized then return end
	Initialized = true

	NetworkManager.Logger = Util.Logger.new({ Name = "NetworkManager" }) :: any
	Signal = Util.Signal

	local Strings = Util.Settings.StaticStrings
	NetworkManager.OrchestratorEvent = CreateRemote(Strings.Instance.OrchestratorEventName, "RemoteEvent")
	NetworkManager.OrchestratorFunction = CreateRemote(Strings.Instance.OrchestratorFunctionName, "RemoteFunction")
	NetworkManager.EntityUpdateEvent = CreateRemote(Strings.Instance.EntityUpdateEventName, "RemoteEvent")
	NetworkManager.EntityCommandEvent = CreateRemote(Strings.Instance.EntityCommandEventName, "RemoteEvent")
	NetworkManager.EventBusRegistered = Signal.new()

	if RunService:IsServer() then
		NetworkManager._RegisterServerListeners()
	else
		NetworkManager._RegisterClientListeners()
	end
	NetworkManager.Log({ Level = "INFO", Message = "NetworkManager initialized" })
end

--[[
	@description Registers a server request callback.
	@param name string
	@param handler function
	@param isAsync boolean
]]
function NetworkManager.RegisterServerRequest(name: string, handler: (Player, ...any) -> any, isAsync: boolean?)
	ValidateRequest("Server")
	if isAsync then
		NetworkManager.ServerRequestCallbacksAsync[name] = handler
	else
		NetworkManager.ServerRequestCallbacksSync[name] = handler
	end
	NetworkManager.Log({ Level = "INFO", Message = "Registered server request callback for " .. name })
end

--[[
	@description Registers an entity command callback.
	@param entityId string
	@param command string
	@param handler function
]]
function NetworkManager.RegisterEntityCommand(entityId: string, command: string, handler: (Player, ...any) -> ())
	ValidateRequest()
	if not NetworkManager.EntityCommandCallbacks[entityId] then
		NetworkManager.EntityCommandCallbacks[entityId] = {}
	end
	NetworkManager.EntityCommandCallbacks[entityId][command] = handler
	NetworkManager.Log({ Level = "INFO", Message = "Registered entity command callback for " .. entityId .. ": " .. command })
end

--[[
	@description Unregisters entity command callbacks for a specific entity.
	@param entityId string
]]
function NetworkManager.UnregisterEntityCommands(entityId: string)
	ValidateRequest("Server")
	NetworkManager.EntityCommandCallbacks[entityId] = nil
	NetworkManager.Log({ Level = "INFO", Message = "Unregistered entity command callbacks for " .. entityId })
end

--[[
	@description Sends a command to an entity on the server.
	@param entityId string
	@param command string
	@param ... any
]]
function NetworkManager.ServerCommandEntity(entityId: string, command: string, ...: any)
	ValidateRequest("Client")
	local packed = table.pack(...)
	if NetworkManager.EntityCommandEvent then
		NetworkManager.EntityCommandEvent:FireServer(entityId, command, table.unpack(packed, 1, packed.n))
	end	
end

--[[
	@description Broadcasts an entity command to all clients.
	@param entityId string
	@param command string
	@param ... any
]]
function NetworkManager.BroadcastEntityCommand(entityId: string, command: string, ...: any)
	ValidateRequest("Server")
	local packed = table.pack(...)
	if NetworkManager.EntityCommandEvent then
		NetworkManager.EntityCommandEvent:FireAllClients(entityId, command, table.unpack(packed, 1, packed.n))
	end
end

--[[
	@description Sends an entity update to all clients.
	@param entityId string
	@param changes table
]]
function NetworkManager.BroadcastEntityUpdate(entityId: string, changes: { [string]: any })
	ValidateRequest("Server")
	if NetworkManager.EntityUpdateEvent then
		NetworkManager.EntityUpdateEvent:FireAllClients(entityId, changes)
	end
end

--[[
	@description Makes a server request (Synchronous).
	@param requestName string
	@param ... any
]]
function NetworkManager.ServerRequest(requestName: string, ...: any)
	ValidateRequest("Client")
	local packed = table.pack(...)
	if NetworkManager.OrchestratorFunction then
		return NetworkManager.OrchestratorFunction:InvokeServer("AppRequestSync", requestName, table.unpack(packed, 1, packed.n))
	end
	return nil
end

--[[
	@description Makes a server request (Asynchronous).
	@param requestName string
	@param ... any
]]
function NetworkManager.ServerRequestAsync(requestName: string, ...: any)
	ValidateRequest("Client")
	local packed = table.pack(...)
	if NetworkManager.OrchestratorEvent then
		NetworkManager.OrchestratorEvent:FireServer("AppRequestAsync", requestName, table.unpack(packed, 1, packed.n))
	end
end

--[[ 
	@description Registers an event bus.
	@param name string
	@return any
]]
function NetworkManager.RegisterEventBus(name: string)
	ValidateRequest()
	if not NetworkManager.EventBuses[name] then 
		NetworkManager.EventBuses[name] = Signal.new() 
		NetworkManager.EventBusRegistered:Fire(name)
		NetworkManager.Log({ Level = "INFO", Message = "Registered event bus " .. name })
	end
	return NetworkManager.EventBuses[name]
end

--[[ 
	@description Unregisters an event bus.
	@param name string
]]
function NetworkManager.UnregisterEventBus(name: string) 
	ValidateRequest()
	NetworkManager.EventBuses[name] = nil 
	NetworkManager.Log({ Level = "INFO", Message = "Unregistered event bus " .. name })
end

--[[
	@description Gets an event bus.
	@param name string
]] 
function NetworkManager.GetEventBus(name: string) 
	ValidateRequest()
	return NetworkManager.EventBuses[name] 
end

--[[
	@description Fires an event bus.
	@param name string
	@param ... any
]] 
function NetworkManager.FireEventBus(name: string, ...) 
	ValidateRequest()
	if NetworkManager.EventBuses[name] then 
		NetworkManager.EventBuses[name]:Fire(...) 
	end 
end

--[[
	@description Awaits an event bus.
	@param name string
	@param timeout number?
]] 
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

-- private
function NetworkManager._RegisterServerListeners()
	ValidateRequest("Server")
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
		NetworkManager.OrchestratorEvent.OnServerEvent:Connect(HandleAppRequest)
		NetworkManager.Log({ Level = "INFO", Message = "Registered orchestrator RemoteEvent listeners" })
	end

	if NetworkManager.EntityCommandEvent then
		NetworkManager.EntityCommandEvent.OnServerEvent:Connect(function(player, entityId, command, ...)
			local handlers = NetworkManager.EntityCommandCallbacks[entityId]
			if handlers and handlers[command] then
				handlers[command](player, ...)
			end
		end)
		NetworkManager.Log({ Level = "INFO", Message = "Registered entity command listeners" })
	end
	NetworkManager.Log({ Level = "INFO", Message = "Registered server listeners" })
end

function NetworkManager._RegisterClientListeners()
	if NetworkManager.EntityCommandEvent then
		NetworkManager.EntityCommandEvent.OnClientEvent:Connect(function(entityId, command, ...)
			local handlers = NetworkManager.EntityCommandCallbacks[entityId]
			if handlers and handlers[command] then
				handlers[command](nil, ...) -- No player on client
			end
		end)
		NetworkManager.Log({ Level = "INFO", Message = "Registered client listeners" })
	end
end

return NetworkManager