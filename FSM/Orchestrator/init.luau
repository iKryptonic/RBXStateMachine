--!strict
-- @Name Orchestrator
-- @Author iKrypto
-- @Description Factory and Registry for managing unique StateMachine instances by ID.

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local FactoryModule = script:FindFirstChild("Factory")

local Logger = require(script:WaitForChild("Logger") :: any)
local Scheduler = require(script:WaitForChild("Scheduler") :: any)
local Signal = require(script:WaitForChild("Signal") :: any)
local BehaviorTree = require(script:WaitForChild("BehaviorTree") :: any)
local DataStoreHandler = require(script:WaitForChild("DataStoreHandler") :: any)
local EntityPersistence = require(script:WaitForChild("EntityPersistence") :: any)
local Settings = require(script:WaitForChild("Settings") :: any)

local Types = require(script.Types);

local Orchestrator = {
	Logger = Logger.new({ Name = script.Name }),
	Persistence = nil :: any,
	Factory = nil :: any
}

local History = {}
Orchestrator.History = History

local StateMachines = {} :: { [string]: any }
local Entities = {} :: { [string]: any }
local CommandHandlers = {} :: { [string]: { [string]: (Player, ...any) -> () } }
local RequestHandlers = {} :: { [string]: (Player, ...any) -> any }
local EntityPools = {} :: { [string]: { any } }
local EventBuses = {} :: { [string]: any }
local EventBusRegistered = Signal.new()

local function CreateRemote(name: string, className: string): any
	if RunService:IsClient() then
		return ReplicatedStorage:WaitForChild(name)
	end

	if not name then warn("CreateRemote called without a name") return nil end
	if not className then warn("CreateRemote called without a className") return nil end

	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then return existing end

	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local function Sanitize(value: any, depth: number?): any
	depth = depth or 0
	if depth :: number > 3 then return tostring(value) end

	if type(value) == "table" then
		local sanitizedTable = {}
		for key, entryValue in pairs(value) do
			if type(key) == "string" or type(key) == "number" then
				sanitizedTable[key] = Sanitize(entryValue, (depth :: number) + 1)
			end
		end
		return sanitizedTable
	elseif type(value) == "function" then
		return "function"
	elseif typeof(value) == "Instance" then
		return value
	else
		return value
	end
end

-- Helper to safely resolve a class from string or return the object if already a table
local function ResolveClass(category: "Entity" | "StateMachine", input: any): any?
	if type(input) ~= "string" then return input end

	-- 1. Try Factory/Orchestrator resolution if available
	if Orchestrator.Factory and Orchestrator.Factory.Get then
		local ok, result = pcall(function() 
			return Orchestrator.Factory.Get(category, input) 
		end)
		if ok and result then return result end
	end

	-- 2. Fallback to Shared cache
	local sharedCategory = shared[category]
	if sharedCategory then
		return sharedCategory[input]
	end

	return nil
end

-- Helper to extract a consistent name from a class definition
local function GetClassName(class: any): string
	if not class then return "Unknown" end
	return (class.Definition and class.Definition.Name) or class.Name or tostring(class)
end

local ServiceManagerRemote = CreateRemote(Settings.StaticStrings.ServiceManagerRemoteName, "RemoteFunction") :: RemoteFunction
local ServiceManagerEvent = CreateRemote(Settings.StaticStrings.ServiceManagerEventName, "RemoteEvent") :: RemoteEvent
local EntityUpdateRemote = CreateRemote(Settings.StaticStrings.EntityUpdateRemoteName, "RemoteEvent") :: RemoteEvent
local EntityCommandRemote = CreateRemote(Settings.StaticStrings.EntityCommandRemoteName, "RemoteEvent") :: RemoteEvent

-------------------------------------------------------------------------------------------
---------------------------------- BEGIN SHARED METHODS -----------------------------------
-------------------------------------------------------------------------------------------

--[[
	@summary Loads Entity and StateMachine classes into shared globals and initializes shared.FSM.
	@return ()
]]
function Orchestrator:RegisterComponents()
	if shared.FSM then
		Orchestrator.Logger:Log({ Level = "INFO", Message = "FSM already registered", OperationId = "RegisterComponents" })
		return
	end
	Initialize()
end

--[[
	@summary Creates (or retrieves) a unique Entity instance by ID.
	@param params { EntityClass: any, EntityId: string, Context: { any }?, Persistent: boolean?, PersistenceKey: string? }
	@return any? -- The created or existing Entity instance (nil on failure)
]]
function Orchestrator.CreateEntity(params: { EntityClass: any, EntityId: string, Context: {any}?, Persistent: boolean?, PersistenceKey: string? })
	local EntityClass = ResolveClass("Entity", params.EntityClass)
	local entityId = params.EntityId
	local entityContext = params.Context or {}

	if not EntityClass then
		Orchestrator.Logger:Log({ Level = "ERROR", Message = "CreateEntity called with nil/unresolvable EntityClass", OperationId = "CreateEntity" })
		return nil
	end

	if not entityId or entityId == "" then
		-- Generate GUID if no ID provided
		entityId = HttpService:GenerateGUID(false)
	end

	entityContext.EntityId = entityId

	if not entityContext.Instance then
		Orchestrator.Logger:Log({ Level = "ERROR", Message = string.format("Entity '%s' requires an 'Instance' in its context.", entityId), OperationId = entityId })
		return nil
	end

	if Entities[entityId] then
		Orchestrator.Logger:Log({ Level = "WARN", Message = string.format("Entity '%s' already exists. Returning existing instance.", entityId), OperationId = entityId })
		return Entities[entityId]
	end

	local entityClassName = GetClassName(EntityClass)

	-- Forward args to the Entity's constructor (Factory entities expect {Name, Instance, OwnerId})
	local success, newEntity = xpcall(function()
		return EntityClass.new({
			Name = entityClassName,
			Instance = entityContext.Instance,
			OwnerId = entityContext.OwnerId,
			Context = entityContext,
		})
	end, function(err)
		return debug.traceback(tostring(err))
	end)

	if not success then
		Orchestrator.Logger:Log({ Level = "ERROR", Message = string.format("Failed to instantiate Entity '%s': %s", entityId, tostring(newEntity)), OperationId = entityId })
		return nil
	end

	-- Preserve Context table semantics for Factory entities
	if type((newEntity :: any).SetContext) == "function" then
		for k, v in pairs(entityContext) do
			if k ~= "Instance" and k ~= "OwnerId" and k ~= "Name" then
				pcall(function()
					(newEntity :: any):SetContext(k, v)
				end)
			end
		end
	elseif (newEntity :: any)._privateProperties and (newEntity :: any)._privateProperties.Context then
		for k, v in pairs(entityContext) do
			if k ~= "Instance" and k ~= "OwnerId" and k ~= "Name" then
				(newEntity :: any)._privateProperties.Context[k] = v
			end
		end
	end

	-- Server-side Persistence: Load existing state if marked as persistent
	if RunService:IsServer() and Orchestrator.Persistence and params.Persistent then
		local key = params.PersistenceKey or entityId
		newEntity:SetContext("_PersistenceKey", key)
		newEntity:SetContext("_IsPersistent", true)

		local loadSuccess, data = Orchestrator.Persistence:Load(newEntity, key)
		if loadSuccess and data then
			Orchestrator.Logger:Log({ Level = "INFO", Message = string.format("Restored persistent state for Entity '%s'", entityId), OperationId = entityId })
		end
	end

	-- Orchestrator "plugs in" to the Entity
	local entityStateChangeConnection = newEntity.StateUpdated:Connect(function(changes)
		--[[
			@summary Handles replication of Entity property changes to clients.
			@param entityId string
			@param changes { [string]: any }
			@param schema { [string]: any }
			@return ()
		]]
		local function HandleReplication(entityId: string, changes: {[string]: any}, schema: {[string]: any})
			if not RunService:IsServer() then return end

			local updatePacket = {}

			for key, value in pairs(changes) do
				local def = schema[key]
				if def and def.Replicate then
					updatePacket[key] = value
				end
			end

			if next(updatePacket) then EntityUpdateRemote:FireAllClients(entityId, updatePacket) end
		end

		if RunService:IsServer() then
			-- Handle Replication, Analytics, Logging, etc.
			HandleReplication(params.EntityId, changes, newEntity:GetValidProperties())

			-- Handle Auto-Save for persistent entities
			if Orchestrator.Persistence and params.Persistent then
				local key = params.PersistenceKey or entityId
				Orchestrator.Persistence:Save(newEntity, key)
			end
		end
	end)

	newEntity.Destroyed:Connect(function()
		-- Clean up connection and stop listening to state changes for replication
		entityStateChangeConnection:Disconnect()
	end)

	if RunService:IsServer() then
		-- Notify all clients to spawn this entity locally
		-- We send the ClassName so the client knows which Module to use
		ServiceManagerEvent:FireAllClients("OnEntityCreated", {
			EntityId = entityId,
			EntityClassName = entityClassName,
			Instance = entityContext.Instance,
			InitialData = newEntity._privateProperties.Data -- Send current state
		})
	end

	Entities[entityId] = newEntity

	Orchestrator.Logger:Log({ Level = "INFO", Message = string.format("Created Entity '%s'", entityId), OperationId = entityId })
	return newEntity
end

--[[
	@summary Creates (or retrieves) a unique StateMachine instance by ID.
	@param params { StateMachineClass: any, StateMachineId: string, Context: { any }? }
	@return any? -- The created or existing StateMachine instance (nil on failure)
]]
function Orchestrator.CreateStateMachine(params: { StateMachineClass: any, StateMachineId: string, Context: {any}? })
	local StateMachineClass = ResolveClass("StateMachine", params.StateMachineClass)
	local stateMachineId = params.StateMachineId
	local stateMachineContext = params.Context or {}

	-- Allow passing a class name string; resolve via Factory/shared registry
	if type(StateMachineClass) == "string" then
		local className = StateMachineClass
		if Orchestrator.Factory and Orchestrator.Factory.Get then
			local ok, resolvedOrErr = pcall(function()
				return Orchestrator.Factory.Get("StateMachine", className)
			end)
			if ok then
				StateMachineClass = resolvedOrErr
			else
				StateMachineClass = shared.StateMachine and shared.StateMachine[className] or nil
			end
		else
			StateMachineClass = shared.StateMachine and shared.StateMachine[className] or nil
		end
	end

	if not StateMachineClass then
		Orchestrator.Logger:Log({ Level = "ERROR", Message = "CreateStateMachine called with nil/unresolvable StateMachineClass", OperationId = "CreateStateMachine" })
		return nil
	end

	if not stateMachineId or stateMachineId == "" then
		-- Generate GUID if no ID provided
		stateMachineId = HttpService:GenerateGUID(false)
	end

	stateMachineContext.StateMachineId = stateMachineId

	if StateMachines[stateMachineId] then
		Orchestrator.Logger:Log({ Level = "WARN", Message = string.format("StateMachine '%s' already exists. Returning existing instance.", stateMachineId), OperationId = stateMachineId })
		return StateMachines[stateMachineId]
	end

	-- Forward the arguments table to the StateMachine's constructor
	local success, newStateMachine = xpcall(StateMachineClass.new, function(err) return debug.traceback(tostring(err)) end, stateMachineContext)

	if not success then
		Orchestrator.Logger:Log({ Level = "ERROR", Message = string.format("Failed to instantiate StateMachine '%s': %s", stateMachineId, tostring(newStateMachine)), OperationId = stateMachineId })
		return nil
	end

	StateMachines[stateMachineId] = newStateMachine

	-- Auto-Unregister when the stateMachine finishes
	local function addToHistory(status, err)
		table.insert(History, 1, {
			Name = newStateMachine.Name,
			Id = stateMachineId,
			Status = status,
			Time = os.time(),
			Duration = newStateMachine.TotalDuration or 0,
			Error = err
		})
		if #History > 100 then table.remove(History) end
	end

	local connections = {};

	local function cleanup()
		if StateMachines[stateMachineId] == newStateMachine then
			StateMachines[stateMachineId] = nil
			-- Disconnect local listeners first back-to-front
			for i = #connections, 1, -1 do
				connections[i]:Disconnect()
			end
			newStateMachine:Destroy()
		end
	end

	connections[#connections+1] = newStateMachine.Completed:Connect(function() addToHistory("Completed"); cleanup() end)
	connections[#connections+1] = newStateMachine.Failed:Connect(function(r) addToHistory("Failed", r); cleanup() end)
	connections[#connections+1] = newStateMachine.Cancelled:Connect(function() addToHistory("Cancelled"); cleanup() end)
	connections[#connections+1] = newStateMachine.StateChanged:Connect(function(newState, oldState)
		if RunService:IsServer() then
			ServiceManagerEvent:FireAllClients("StateMachineStateChanged", stateMachineId, newState)
		end
	end)

	Orchestrator.Logger:Log({ Level = "INFO", Message = string.format("Created StateMachine '%s'", stateMachineId), OperationId = stateMachineId })

	return newStateMachine
end

--[[
	@summary Retries a stateMachine by ID, preserving its Context.
	@param stateMachineId string
	@return ()
]]
function Orchestrator.RetryStateMachine(stateMachineId: string)
	local oldStateMachine = StateMachines[stateMachineId]
	if not oldStateMachine then return end

	local context = oldStateMachine.Context
	local name = oldStateMachine.Name
	local class = shared.StateMachine[name]

	if not class then return end

	StateMachines[stateMachineId] = nil -- Detach to allow ID reuse
	oldStateMachine:Destroy()

	Orchestrator.CreateStateMachine({
		StateMachineClass = class,
		StateMachineId = stateMachineId,
		Context = context
	})
end

--[[
	@summary Retrieves a StateMachine by its ID.
	@param stateMachineId string
	@return any?
]]
function Orchestrator.GetStateMachine(stateMachineId: string)
	return StateMachines[stateMachineId]
end

--[[
	@summary Retrieves an Entity by its ID.
	@param entityId string
	@return any?
]]
function Orchestrator.GetEntity(entityId: string)
	return Entities[entityId]
end

--[[
	@summary Cancels a specific StateMachine by ID.
	@param stateMachineId string
	@return boolean -- True if found and cancelled
]]
function Orchestrator.CancelStateMachine(stateMachineId: string)
	local stateMachine = StateMachines[stateMachineId]
	if stateMachine then
		stateMachine:Cancel()
		return true
	end
	return false
end

--[[
	@summary Deletes (destroys) a specific Entity by ID.
	@param entityId string
	@return ()
]]
function Orchestrator.DeleteEntity(entityId: string)
	local entity = Entities[entityId]
	if entity then
		-- Save persistent data before destruction
		if RunService:IsServer() and Orchestrator.Persistence and entity._privateProperties.Context._IsPersistent then
			local key = entity._privateProperties.Context._PersistenceKey or entityId
			Orchestrator.Persistence:Save(entity, key)
		end
		entity:Destroy()
		Entities[entityId] = nil
	end
	CommandHandlers[entityId] = nil
end

--[[
	@summary Deletes (destroys) all active Entities.
	@return ()
]]
function Orchestrator.DeleteAllEntities()
	Orchestrator.Logger:Log({ Level = "WARN", Message = "Deleting all active entities..." })

	local entityIdList = {}
	for id, _ in pairs(Entities) do table.insert(entityIdList, id) end

	for _, id in ipairs(entityIdList) do
		Orchestrator.DeleteEntity(id)
	end
end

--[[
	@summary Cancels all active StateMachines.
	@return ()
]]
function Orchestrator.CancelAll()
	Orchestrator.Logger:Log({ Level = "WARN", Message = "Cancelling all active stateMachines..." })

	local fsmIdList = {}
	for id, _ in pairs(StateMachines) do table.insert(fsmIdList, id) end

	for _, id in ipairs(fsmIdList) do
		Orchestrator.CancelStateMachine(id)
	end
end

--[[
	@summary Returns the current active Entities map.
	@return { [string]: any }
]]
function Orchestrator.GetEntities()
	return Entities
end

--[[
	@summary Returns the current active StateMachines map.
	@return { [string]: any }
]]
function Orchestrator.GetStateMachines()
	return StateMachines
end

--[[
	@summary Registers a handler for a specific command on an entity (Server-only).
	@param entityId string
	@param command string
	@param handler (Player, ...any) -> ()
	@return ()
]]
function Orchestrator.RegisterCommandHandler(entityId: string, command: string, handler: (Player, ...any) -> ())
	if not RunService:IsServer() then return end
	if not CommandHandlers[entityId] then
		CommandHandlers[entityId] = {}
	end
	CommandHandlers[entityId][command] = handler
end

--[[
	@summary Registers a server handler for a request/response call.
	@param requestName string
	@param handler (Player, ...any) -> any
	@return ()
]]
function Orchestrator.RegisterRequestHandler(requestName: string, handler: (Player, ...any) -> any)
	if not RunService:IsServer() then return end
	if type(requestName) ~= "string" or requestName == "" then return end
	RequestHandlers[requestName] = handler
end

--[[
	@summary Performs a request/response call from client to server.
	@param requestName string
	@param ... any
	@return any?
]]
function Orchestrator.Request(requestName: string, ...: any)
	if not RunService:IsClient() then return nil end
	local packed = table.pack(...)
	local ok, result = pcall(function()
		return ServiceManagerRemote:InvokeServer("AppRequest", requestName, table.unpack(packed, 1, packed.n))
	end)
	return ok and result or nil
end

--[[
	@summary Sends a command from client to server for a specific entity.
	@param entityId string
	@param command string
	@param ... any args
	@return ()
]]
function Orchestrator.SendCommand(entityId: string, command: string, ...: any)
	if not RunService:IsClient() then return end
	EntityCommandRemote:FireServer(entityId, command, ...)
end

--[[
	@summary Deactivates and pools an entity for later reuse.
	@param entityId string
	@return ()
]]
function Orchestrator.PoolEntity(entityId: string)
	local entity = Entities[entityId]
	if not entity then return end

	local className = entity.Name
	if not EntityPools[className] then
		EntityPools[className] = {}
	end

	-- Deactivate
	entity._privateProperties.IsValid = false
	Entities[entityId] = nil
	CommandHandlers[entityId] = nil

	if RunService:IsServer() then
		ServiceManagerEvent:FireAllClients("OnEntityPooled", entityId)
	end

	table.insert(EntityPools[className], entity)
	Orchestrator.Logger:Log({ Level = "INFO", Message = string.format("Pooled Entity '%s' (%s)", entityId, className), OperationId = entityId })
end

--[[
	@summary Retrieves a pooled entity or creates a new one if none available.
	@param params { EntityClass: any, EntityId: string, Context: { any } }
	@return any?
]]
function Orchestrator.GetPooledEntity(params: { EntityClass: any, EntityId: string, Context: {any}? })
	local className: string = GetClassName(params.EntityClass);
	if not className then return nil end

	local pool = EntityPools[className]

	if pool and #pool > 0 then
		local entity = table.remove(pool)
		local entityId = params.EntityId or HttpService:GenerateGUID(false)

		-- Reactivate and Re-initialize
		entity._privateProperties.IsValid = true
		table.clear(entity._privateProperties.Data)
		table.clear(entity._privateProperties.Pending)

		-- Apply new context
		if params.Context then
			for k, v in pairs(params.Context) do
				entity._privateProperties.Context[k] = v
			end
		end
		entity._privateProperties.Context.EntityId = entityId

		Entities[entityId] = entity
		Orchestrator.Logger:Log({ Level = "INFO", Message = string.format("Reused Pooled Entity '%s' (%s)", entityId, className), OperationId = entityId })

		if RunService:IsServer() then
			ServiceManagerEvent:FireAllClients("OnEntityCreated", {
				EntityId = entityId,
				EntityClassName = className,
				Instance = entity.Instance,
				InitialData = {}
			})
		end

		return entity
	else
		return Orchestrator.CreateEntity(params)
	end
end

--[[
	@summary Registers a new local event bus by name.
	@param name string
	@return any
]]
function Orchestrator.RegisterEventBus(name: string): any
	if not EventBuses[name] then
		EventBuses[name] = Signal.new()
		EventBusRegistered:Fire(name)
	end
	return EventBuses[name]
end

--[[
	@summary Retrieves an existing local event bus by name.
	@param name string
	@return any?
]]
function Orchestrator.GetEventBus(name: string): any?
	return EventBuses[name]
end

--[[
	@summary Fires a local event bus.
	@param name string
	@param ... any args
	@return ()
]]
function Orchestrator.FireEventBus(name: string, ...: any)
	local bus = EventBuses[name]
	if bus then
		bus:Fire(...)
	end
end

--[[
	@summary Yields until an event bus with the given name is registered.
	@param name string
	@param timeout number?
	@return any?
]]
function Orchestrator.AwaitEventBus(name: string, timeout: number?): any?
	if EventBuses[name] then
		return EventBuses[name]
	end

	local start = os.clock()
	while not EventBuses[name] do
		local elapsed = os.clock() - start
		if timeout and elapsed >= timeout then
			return nil
		end

		-- Calculate remaining time and wait with timeout
		local remainingTime = timeout and (timeout - elapsed) or math.huge
		if remainingTime > 0 then
			task.wait(math.min(0.1, remainingTime))
		else
			return nil
		end
	end

	return EventBuses[name]
end

-------------------------------------------------------------------------------------------
---------------------------------- END SHARED METHODS -------------------------------------
---------------------------------- BEGIN CLIENT METHODS -----------------------------------
-------------------------------------------------------------------------------------------

-------------------------------------------------------------------------------------------
---------------------------------- END CLIENT METHODS -------------------------------------
---------------------------------- BEGIN SERVER METHODS -----------------------------------
-------------------------------------------------------------------------------------------

-------------------------------------------------------------------------------------------
---------------------------------- END SERVER METHODS -------------------------------------
---------------------------------- BEGIN INIT METHODS -------------------------------------
-------------------------------------------------------------------------------------------

--[[
	@summary Sets shared variables for the FSM system.
	@return ()
]]
local function SetSharedVariables()
	shared.Logger = Logger
	shared.Signal = Signal

	shared.Scheduler = Scheduler;
	shared.Entity = {}
	shared.StateMachine = {}

	shared.FSM = {
		StateMachines = StateMachines,
		Entities = Entities,
		Orchestrator = Orchestrator,
		Scheduler = Scheduler.new(),
		BehaviorTree = BehaviorTree,
		Logger = Logger,
		Settings = Settings.FSMSettings,
		History = History
	}
end

--[[
	@summary Initializes all state machines and entities from the factory.
	@return ()
]]
local function InitializeStateMachines()
	local subclassFactory = require(FactoryModule) :: any
	Orchestrator.Factory = subclassFactory
	shared.FSM.Factory = subclassFactory

	local okEntities, entitiesOrErr = pcall(function()
		return subclassFactory.GetAll("Entity")
	end)
	local okSM, smOrErr = pcall(function()
		return subclassFactory.GetAll("StateMachine")
	end)

	if okEntities and type(entitiesOrErr) == "table" then
		for name, entityClass in pairs(entitiesOrErr) do
			shared.Entity[name] = entityClass
		end
	end
	if okSM and type(smOrErr) == "table" then
		for name, stateMachineClass in pairs(smOrErr) do
			shared.StateMachine[name] = stateMachineClass
		end
	end
	subclassFactory.LoadSubclasses()
end

--[[
	@summary Synchronizes entities from the server to the client.
	@return ()
]]
local function SyncEntitiesFromServer()
	if not RunService:IsClient() then return end

	-- Request initial snapshot of all entities from server
	local snapshot = ServiceManagerRemote:InvokeServer("RequestEntitySnapshot")
	for _, data in pairs(snapshot) do
		-- Force create entities that already exist on the server
		local class = shared.Entity[data.ClassName]
		if class then
			local newEntity = Orchestrator.CreateEntity({
				EntityClass = class,
				EntityId = data.Id,
				Context = { Instance = data.Instance }
			})

			if not newEntity then 
				Orchestrator.Logger:Log
				{ 
					Level = "ERROR", 
					Message = string.format("Failed to create entity '%s' from snapshot.", data.Id), 
					OperationId = data.Id 
				}
				continue 
			end

			-- Sync current data
			for k, v in pairs(data.Data) do 
				newEntity._privateProperties.Data[k] = v 
			end
			newEntity:ApplyChanges(data.Data)
		end
	end
end

--[[
	@summary Initializes client-side listeners for Entity state updates.
	@return ()
]]
local function InitClientListeners()
	if not RunService:IsClient() then return end

	-- Shared handler for both channels
	-- @param entityId string The ID of the Entity being updated
	-- @param changes { [string]: any } The changed properties
	local function onStateReceived(entityId: string, changes: {[string]: any})
		local entity = Orchestrator.GetEntity(entityId)

		if entity then
			-- 1. Authority Update: Update the local 'Data' table directly
			-- We bypass 'Pending' because the Server has already validated this data.
			for key, value in pairs(changes) do
				entity._privateProperties.Data[key] = value
			end

			-- 2. Visual Trigger: Run the subclass-defined ApplyChanges
			entity:ApplyChanges(changes)
		else
			-- Optional: If the entity doesn't exist yet, we might be receiving 
			-- updates for an object that hasn't finished spawning.
			Orchestrator.Logger:Log({
				Level = "DEBUG", 
				Message = "Received update for unknown Entity: " .. entityId
			})
		end
	end

	local function onServiceManagerEvent(action, data)
		if action == "OnEntityCreated" then
			-- Find the class in the shared registry
			local class = shared.Entity[data.EntityClassName]
			if class then
				local entity = Orchestrator.CreateEntity({
					EntityClass = class,
					EntityId = data.EntityId,
					Context = { Instance = data.Instance }
				})

				-- Inject the initial data sent by the server
				if entity and data.InitialData then
					for k, v in pairs(data.InitialData) do
						entity._privateProperties.Data[k] = v
					end
					entity:ApplyChanges(data.InitialData)
				end
			end
		end
	end

	ServiceManagerEvent.OnClientEvent:Connect(onServiceManagerEvent)
	EntityUpdateRemote.OnClientEvent:Connect(onStateReceived)
end

--[[
	@summary Registers the database and persistence components.
	@return ()
]]
local function RegisterDatabaseAndPersistence()
	if not RunService:IsServer() then return end

	Orchestrator.Persistence = EntityPersistence.new({ 
		DataStoreName = Settings.DataStore.DataStoreName, 
		KeyPrefix = Settings.DataStore.KeyPrefix,
		DataStoreHandler = DataStoreHandler
	})

	-- Wire up DataStore access reset with task scheduler
	shared.FSM.Scheduler:Schedule({
		TaskName = Settings.StaticStrings.ResetDataStoreAccessCountTaskName,
		TaskAction = DataStoreHandler.ResetAccessCount,
		TaskExecutionDelay = Settings.DataStore.ResetAccessCountIntervalInSeconds,
		IsRecurringTask = true,
		Priority = 1,
		Event = "Heartbeat"
	})
end

--[[
	@summary Starts the ServiceManager remote API (server-only).
	@return ()
]]
local function StartServiceManagerAPI()
	if not RunService:IsServer() then return end

	EntityCommandRemote.OnServerEvent:Connect(function(player, entityId, command, ...)
		local handlers = CommandHandlers[entityId]
		if handlers and handlers[command] then
			handlers[command](player, ...)
		else
			Orchestrator.Logger:Log({ 
				Level = "WARN", 
				Message = string.format("No handler for command '%s' on entity '%s'", tostring(command), tostring(entityId)),
				OperationId = entityId 
			})
		end
	end)

	ServiceManagerRemote.OnServerInvoke = function(player, requestType, ...)
		if requestType == "GetSyncData" then
			local tsData = nil
			if shared.FSM.Scheduler and shared.FSM.Scheduler.GetSyncData then
				tsData = shared.FSM.Scheduler:GetSyncData()
			end

			local fsmData = {
				StateMachines = {},
				Entities = {},
				Logs = Orchestrator.Logger.History,
				History = History,
				Settings = { Debug = true } -- Placeholder settings
			}

			for id, stateMachine in pairs(StateMachines) do
				fsmData.StateMachines[id] = {
					Name = stateMachine.Name,
					State = stateMachine.State,
					Priority = stateMachine.Priority,
					Context = Sanitize(stateMachine.Context),
					ValidStates = stateMachine.validStates,
					Graph = {
						Transitions = stateMachine._transitions or {},
						CurrentState = stateMachine.State
					}
				}
			end

			for id, entity in pairs(Entities) do
				local props = entity._privateProperties or {}
				fsmData.Entities[id] = {
					Name = entity.Name or props.Name,
					IsValid = props.IsValid,
					OwnerId = props.OwnerId,
					Data = Sanitize(props.Data)
				}
			end

			return {
				Scheduler = tsData,
				FSM = fsmData
			}
		elseif requestType == "UpdateSettings" then
			local section, key, val = ...
			if shared.FSM.Scheduler and shared.FSM.Scheduler.Settings then
				if section and shared.FSM.Scheduler.Settings[section] then
					shared.FSM.Scheduler.Settings[section][key] = val
				else
					shared.FSM.Scheduler.Settings[key] = val
				end
			end
		elseif requestType == "FSM" then
			local action, id = ...
			if action == "CancelStateMachine" or action == "CancelJob" then
				Orchestrator.CancelStateMachine(id)
			elseif action == "RetryStateMachine" or action == "RetryJob" then
				Orchestrator.RetryStateMachine(id)
			end
		elseif requestType == "ConsoleCommand" then
			local cmd, _options = ...
			if cmd == "ps" or cmd == "stateMachines" then
				local out = ""
				for id, stateMachine in pairs(StateMachines) do out = out .. string.format("%s [%s] - %s\n", id, stateMachine.Name or "?", stateMachine.State or "?") end
				if out == "" then out = "No active stateMachines." end
				return out
			elseif cmd == "clearlogs" then Orchestrator.Logger.History = {}; return "Logs cleared."
			end
			-- Forward to Scheduler if not handled
			if shared.FSM.Scheduler then
				local tsOut = nil
				if cmd == "ps" or cmd == "tasks" then
					local out = ""
					for taskName in pairs(shared.FSM.Scheduler.Tasks) do
						out = out .. tostring(taskName) .. "\n"
					end
					if out == "" then out = "No active tasks." end
					tsOut = out
				end
				if tsOut then return tsOut end
			end
			return "Unknown command (or not handled by FSM/Scheduler)."
		elseif requestType == "Scheduler" then
			local action, p1, p2, p3, p4, p5, p6 = ...
			-- Enforce Scheduler security check if available
			if shared.FSM.Scheduler and shared.FSM.Scheduler.CheckAdmin and not shared.FSM.Scheduler:CheckAdmin(player) then
				return "Unauthorized"
			end
			if shared.FSM.Scheduler then
				if action == "Schedule" then shared.FSM.Scheduler:Schedule(p1)
				elseif action == "Deschedule" then shared.FSM.Scheduler:Deschedule(p1)
				elseif action == "ExecuteTask" then shared.FSM.Scheduler:ExecuteTask(p1)
				elseif action == "ResetTask" then shared.FSM.Scheduler:ResetTask(p1)
				elseif action == "ScheduleTestTask" then
					shared.FSM.Scheduler:Schedule({
						TaskName = p1,
						TaskExecutionDelay = p2,
						IsRecurringTask = p3,
						Priority = p4,
						Event = p5,
						TaskAction = function() print("[SERVER TEST]: " .. tostring(p6)) end
					})
				end
			end
		elseif requestType == "RequestEntitySnapshot" then
			local snapshot = {}
			for id, entity in pairs(Entities) do
				table.insert(snapshot, {
					Id = id,
					ClassName = entity.Name,
					Instance = entity.Instance,
					Data = Sanitize(entity._privateProperties.Data)
				})
			end
			return snapshot
		elseif requestType == "AppRequest" then
			local requestName = select(1, ...)
			if type(requestName) ~= "string" or requestName == "" then
				return nil
			end
			local handler = RequestHandlers[requestName]
			if not handler then
				return nil
			end

			local packed = table.pack(select(2, ...))
			local ok, result = pcall(function()
				return handler(player, table.unpack(packed, 1, packed.n))
			end)
			return ok and result or nil
		end
		return nil
	end
end

-- Public wrapper for tests and manual startup
function Orchestrator.StartServiceManagerAPI()
	StartServiceManagerAPI()
end

--[[
	@summary Initializes the orchestrator's server and client components.
	@return ()
]]
function Initialize()
	local InitializationMethods = {
		{
			Method = SetSharedVariables, 
			TaskName = "Set shared variables",
			Layer = "All"
		},
		{
			Method = InitializeStateMachines, 
			TaskName = "Initialize state machines",
			Layer = "All"
		},
		{
			Method = RegisterDatabaseAndPersistence, 
			TaskName = "Register database and persistence",
			Layer = "Server"
		},
		{
			Method = StartServiceManagerAPI, 
			TaskName = "Start service manager API",
			Layer = "Server"
		},
		{
			Method = InitClientListeners, 
			TaskName = "Initialize client listeners",
			Layer = "Client"
		},
		{
			Method = SyncEntitiesFromServer, 
			TaskName = "Synchronize entities from server",
			Layer = "Client"
		}
	}

	local CurrentLayer = RunService:IsServer() and "Server" or "Client"

	for _, method in ipairs(InitializationMethods) do
		if (method.Layer == "All") or (method.Layer == CurrentLayer) then
			local Success, Result = xpcall(method.Method, debug.traceback)
			if not Success then
				Orchestrator.Logger:Log({
					Level = "ERROR",
					Message = string.format("Failed to during stage: %s: %s", method.TaskName, tostring(Result))
				})
			else
				Orchestrator.Logger:Log({
					Level = "INFO",
					Message = string.format("Completed stage: %s", method.TaskName)
				})
			end
		else
			Orchestrator.Logger:Log({
				Level = "INFO",
				Message = string.format("Skipping stage: %s", method.TaskName)
			})
		end
	end
end

-------------------------------------------------------------------------------------------
---------------------------------- END INIT METHODS ---------------------------------------
-------------------------------------------------------------------------------------------

return Orchestrator