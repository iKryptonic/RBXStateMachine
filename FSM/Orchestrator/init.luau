--!strict
-- @Name Orchestrator
-- @Author iKrypto
-- @Description Factory and Registry for managing unique StateMachine instances by ID.

local RunService = game:GetService("RunService")

local Core = {
	Factory = require(script.Core.Factory),
	Logger = require(script.Core.Logger),
	NetworkManager = require(script.Core.NetworkManager),
	Scheduler = require(script.Core.Scheduler),
	Signal = require(script.Core.Signal),
	Types = require(script.Core.Types),
	Settings = require(script.Core.Settings),
	ServiceManager = script.Core.ServiceManager -- Directory
}; 
local Strings = Core.Settings.StaticStrings

local Orchestrator = {
	Logger = nil,
	Factory = nil, -- Expose Class Factory
	Settings = Core.Settings,

	-- Expose History for legacy support/ServiceManager
	History = {}
}

local Initialized = false
local function ValidateRequest(context: string)
	assert(Initialized, "Orchestrator not initialized")
	if context then
		if context == "Server" and not RunService:IsServer() then
			Orchestrator.Logger:Log({ Level = "ERROR", Message =  Strings.Error.ServerRequestErrorMessage })
			error(Strings.Error.ServerRequestErrorMessage)
		end
		if context == "Client" and not RunService:IsClient() then
			Orchestrator.Logger:Log({ Level = "ERROR", Message =  Strings.Error.ClientRequestErrorMessage })
			error(Strings.Error.ClientRequestErrorMessage)
		end
		return true
	end
end

-------------------------------------------------------------------------------------------
---------------------------------- BEGIN SHARED METHODS -----------------------------------
-------------------------------------------------------------------------------------------

function Orchestrator:RegisterComponents()
	return Initialize()
end

function Orchestrator.CreateEntity(params: { EntityClass: any, EntityId: string, Context: {any}?, Persistent: boolean?, PersistenceKey: string? })
	ValidateRequest()
	return Core.Factory.CreateEntity(params)
end

function Orchestrator.CreateStateMachine(params: { StateMachineClass: any, StateMachineId: string, Context: {any}? })
	ValidateRequest()
	return Core.Factory.CreateStateMachine(params)
end

function Orchestrator.GetStateMachine(stateMachineId: string)
	ValidateRequest()
	return Core.Factory.Registry.GetStateMachine(stateMachineId)
end

function Orchestrator.GetEntity(entityId: string)
	ValidateRequest()
	return Core.Factory.Registry.GetEntity(entityId)
end

function Orchestrator.CancelStateMachine(stateMachineId: string)
	ValidateRequest()
	local sm = Core.Factory.Registry.GetStateMachine(stateMachineId)
	if sm then
		sm:Cancel()
		return true
	end
	return false
end

function Orchestrator.RetryStateMachine(stateMachineId: string)
	ValidateRequest()
	local oldSM = Core.Factory.Registry.GetStateMachine(stateMachineId)
	if not oldSM then return end

	local context = oldSM.Context
	local name = oldSM.Name
	local class = Core.Factory.Get("StateMachine", name) -- Resolve class definition for retry

	if not class then return end

	-- Remove old
	Core.Factory.Registry.UnregisterStateMachine(stateMachineId)
	oldSM:Destroy()

	Orchestrator.CreateStateMachine({
		StateMachineClass = class,
		StateMachineId = stateMachineId,
		Context = context
	})
	return true
end

function Orchestrator.DeleteEntity(entityId: string)
	ValidateRequest()
	local entity = Core.Factory.Registry.GetEntity(entityId)
	if not entity then return false end
	entity:Destroy() -- Entity.Destroy triggers Registry cleanup via signal in Factory
	return true
end

function Orchestrator.DeleteAllEntities()
	ValidateRequest()
	for _, entity in pairs(Core.Factory.Registry.GetAllEntities()) do
		entity:Destroy()
	end
	return true
end

function Orchestrator.CancelAll()
	ValidateRequest()
	for _, sm in pairs(Core.Factory.Registry.GetAllStateMachines()) do
		sm:Cancel()
	end
	return true
end

function Orchestrator.GetEntities()
	ValidateRequest()
	return Core.Factory.Registry.GetAllEntities()
end

function Orchestrator.GetStateMachines()
	ValidateRequest()
	return Core.Factory.Registry.GetAllStateMachines()
end

-- Pooling Delegates
function Orchestrator.PoolEntity(entityId: string)
	ValidateRequest()
	local entity = Core.Factory.Registry.GetEntity(entityId)
	if not entity then return false end

	local className = entity.Name
	entity._privateProperties.IsValid = false
	Core.Factory.Registry.UnregisterEntity(entityId)
	Core.NetworkManager.BroadcastEntityCommand(entityId, "OnEntityPooled")
	Core.Factory.Registry.PoolEntity(className, entity)
	return true
end

-------------------------------------------------------------------------------------------
---------------------------------- REMOTE WRAPPERS ----------------------------------------
-------------------------------------------------------------------------------------------

function Orchestrator.RegisterEntityCommandCallback(entityId: string, command: string, handler: (Player, ...any) -> ())
	ValidateRequest() -- Allow both contexts
	Core.NetworkManager.RegisterEntityCommand(entityId, command, handler)
	return true
end

function Orchestrator.ServerCommandEntity(entityId: string, command: string, ...: any)
	ValidateRequest("Client")
	Core.NetworkManager.ServerCommandEntity(entityId, command, ...)
end

function Orchestrator.RegisterServerRequestCallback(requestName: string, handler: (Player, ...any) -> any, aSync: boolean)
	ValidateRequest("Server")
	Core.NetworkManager.RegisterServerRequest(requestName, handler, aSync)
	return true
end

function Orchestrator.ServerRequest(requestName: string, ...: any)
	ValidateRequest("Client")
	return Core.NetworkManager.ServerRequest(requestName, ...)
end

function Orchestrator.ServerRequestAsync(requestName: string, ...: any)
	ValidateRequest("Client")
	return Core.NetworkManager.ServerRequestAsync(requestName, ...)
end

function Orchestrator.BroadcastEntityCommand(requestType: string, entityId: string, ...: any)
	ValidateRequest("Server")
	Core.NetworkManager.BroadcastEntityCommand(entityId, requestType, ...)
	return true
end

-------------------------------------------------------------------------------------------
---------------------------------- EVENT BUS ----------------------------------------------
-------------------------------------------------------------------------------------------

function Orchestrator.RegisterEventBus(name: string)
	ValidateRequest()
	return Core.NetworkManager.RegisterEventBus(name)
end
function Orchestrator.GetEventBus(name: string) 
	ValidateRequest()
	return Core.NetworkManager.GetEventBus(name) 
end
function Orchestrator.FireEventBus(name: string, ...) 
	ValidateRequest()
	return Core.NetworkManager.FireEventBus(name, ...) 
end
function Orchestrator.AwaitEventBus(name: string, timeout: number?)
	ValidateRequest()
	return Core.NetworkManager.AwaitEventBus(name, timeout)
end
function Orchestrator.UnregisterEventBus(name: string) 
	ValidateRequest()
	return Core.NetworkManager.UnregisterEventBus(name) 
end

-------------------------------------------------------------------------------------------
---------------------------------- CLIENT METHODS -----------------------------------------
-------------------------------------------------------------------------------------------

function Orchestrator:AttachServiceManager()
    -- Legacy shim if user calls it manually, though Init handles it.
	ValidateRequest("Client")
	if not Core.Settings.ServiceManager.Enabled then
		return nil
	end

	if not shared.fsm then
		pcall(function() (self :: any):RegisterComponents() end)
	end
    
    -- Return the CLient Entity if it exists
    return Core.Factory.Registry.GetEntity("ServiceManager") -- Assuming singleton ID
end

-------------------------------------------------------------------------------------------
---------------------------------- INITIALIZATION -----------------------------------------
-------------------------------------------------------------------------------------------

local function InitializeModule(Module: any)
	ValidateRequest()
	Module.Initialize(Core)
end

local function SetSharedVariables()
	local OrchestratorObject = newproxy(true);
	local Object_mt = getmetatable(OrchestratorObject);
	
	Object_mt.__index = function(_, key)
		-- Yield until initialized, with a timeout
		if not Initialized then
			local start = os.clock()
			while not Initialized do
				if os.clock() - start > 5 then
					warn("[Orchestrator] Yielded for >5s waiting for initialization.")
					break
				end
				task.wait()
			end
		end
		return Orchestrator[key]
	end
	
	Object_mt.__newindex = function() end;
	Object_mt.__tostring = function()
		return script.Name
	end
	Object_mt.__metatable = script.Name
	
	shared.fsm = OrchestratorObject

	do 
	-- Load the factory and initialize submodules
		
		InitializeModule(Core.NetworkManager)
		InitializeModule(Core.Factory)
		InitializeModule(Core.Scheduler)

		Orchestrator.Scheduler = Core.Scheduler.new()
		Orchestrator.Factory = Core.Factory
		Orchestrator.StateMachines = Core.Factory.Registry.GetAllStateMachines()
		Orchestrator.Entities = Core.Factory.Registry.GetAllEntities()

        -- Initialize New DataStore Entity and Persistence
		if Core.Settings.DataStore.PersistenceEnabled and RunService:IsServer() then
            -- System Entity: DataStore
            Orchestrator.CreateEntity({
                EntityClass = "DataStoreEntity",
                EntityId = "DataStoreSystem",
                Context = { Orchestrator = Orchestrator }
            })
			Orchestrator.Logger:Log({Message = "DataStore/Persistence initialized", Level = "INFO"})
		end

        -- Initialize ServiceManager (Sidecar)
        if Core.Settings.ServiceManager.Enabled then
            if RunService:IsServer() then
                Orchestrator.CreateEntity({
                    EntityClass = "ServiceManagerHostEntity",
                    EntityId = "ServiceManager",
                    Context = { Orchestrator = Orchestrator }
                })
            elseif RunService:IsClient() then	
                Orchestrator.CreateEntity({
                    EntityClass = "ServiceManagerClientEntity",
                    EntityId = "ServiceManager",
                    Context = { Orchestrator = Orchestrator, ServiceManager = require(Core.ServiceManager) }
                }):Initialize()
            end
        end

	end

end

local function RegisterCallbacks()
	if not RunService:IsServer() then return end

	-- Request Entity Snapshot
	local function GetEntitySnapshot()
		local snapshot = {}
		for id, entity in pairs(Core.Factory.Registry.GetAllEntities()) do
			table.insert(snapshot, {
				Id = id,
				ClassName = entity.ClassName or entity.Name,
				Instance = entity.Instance,
				Data = (entity._privateProperties and entity._privateProperties.Data) or {} -- Should use Sanitizer if needed
			})
		end
		return snapshot
	end
	Core.NetworkManager.RegisterServerRequest("RequestEntitySnapshot", GetEntitySnapshot)
end

-- SyncEntitiesFromServer (Client Side)
local function SyncEntitiesFromServer()
	if not RunService:IsClient() then return end
	task.spawn(function()
		local snapshot = Core.NetworkManager.ServerRequest("RequestEntitySnapshot")
		if snapshot then
			for _, data in pairs(snapshot) do
				local class = Core.Factory.Get("Entity", data.ClassName)
				if class then
					local newEntity = Core.Factory.CreateEntity({
						EntityClass = class,
						EntityId = data.Id,
						Context = { Instance = data.Instance }
					})
					if newEntity and data.Data then
						newEntity:ApplyChanges(data.Data)
					end
				end
			end
			Orchestrator.Logger:Log({Message = "SyncEntitiesFromServer completed", Level = "INFO"})
		else
			Orchestrator.Logger:Log({Message = "SyncEntitiesFromServer failed", Level = "ERROR"})
		end
	end)
end

function Initialize()
	if Initialized then return true end
	Initialized = true

	local Success, Result = pcall(function()
		InitializeModule(Core.Logger)
		Orchestrator.Logger = Core.Logger.new({ Name = script.Name })
		Orchestrator.Logger:Log({Message = "Initializing Orchestrator", Level = "INFO"})
		SetSharedVariables()
		Orchestrator.Logger:Log({Message = "SetSharedVariables completed", Level = "INFO"})

		if Orchestrator.Scheduler then 
			Orchestrator.Scheduler:Start() 

			-- Hook Global Heartbeat (BaseStateMachine)
			if Core.Factory.BaseModules.BaseStateMachine then
				Core.Factory.BaseModules.BaseStateMachine.DisableInternalLoop()
				Orchestrator.Logger:Log({ Level = "INFO", Message = "BaseStateMachine internal loop disabled. Hooking into Scheduler." })
				
				local lastUpdate = os.clock()
				Orchestrator.Scheduler:Schedule({
					TaskName = "GlobalStateMachineHeartbeat",
					Priority = 1,
					Event = "Heartbeat",
					IsRecurringTask = true,
					TaskExecutionDelay = 0,
					TaskAction = function()
						local now = os.clock()
						local dt = now - lastUpdate
						lastUpdate = now
						if dt > 0.1 then dt = 0.1 end
						Core.Factory.BaseModules.BaseStateMachine.Step(dt)
					end
				})
			end
		end
		Orchestrator.Logger:Log({Message = "Scheduler started", Level = "INFO"})

		Core.NetworkManager.Initialize(Core.Settings)
		Orchestrator.Logger:Log({Message = "NetworkManager initialized", Level = "INFO"})

		RegisterCallbacks()
		Orchestrator.Logger:Log({Message = "Callbacks registered", Level = "INFO"})

		if RunService:IsClient() then
			if Core.NetworkManager.EntityUpdateEvent then
				Core.NetworkManager.EntityUpdateEvent.OnClientEvent:Connect(function(entityId, changes)
					local entity = Core.Factory.Registry.GetEntity(entityId)
					if entity then
						-- Version Check
						local newVersion = changes._v
						if newVersion then
							local currentVersion = entity.Version or 0
							if newVersion <= currentVersion then
								-- Discard out of sync packet
								return 
							end
							if entity._privateProperties then
								entity._privateProperties.Version = newVersion
							end
						end
						
						if entity._privateProperties then
							for k,v in pairs(changes) do 
								if k ~= "_v" then
									entity._privateProperties.Data[k] = v 
								end
							end
						end
						entity:ApplyChanges(changes)
					end
				end)
				Orchestrator.Logger:Log({Message = "EntityUpdateEvent connected", Level = "INFO"})
			end
			if Core.NetworkManager.EntityCommandEvent then
				Core.NetworkManager.EntityCommandEvent.OnClientEvent:Connect(function(entityId, action, data)
					if action == "OnEntityCreated" then
						local class = Core.Factory.Get("Entity", data.EntityClassName)
						if class then
							local ent = Core.Factory.CreateEntity({
								EntityClass = class,
								EntityId = entityId,
								Context = { Instance = data.Instance }
							})
							if ent and data.InitialData then ent:ApplyChanges(data.InitialData) end
						end
					elseif action == "OnEntityPooled" then
						Orchestrator.PoolEntity(entityId)
					elseif action == "OnEntityDestroyed" then
						Orchestrator.DeleteEntity(entityId)
					end
				end)
				Orchestrator.Logger:Log({Message = "EntityCommandEvent connected", Level = "INFO"})
			end
			SyncEntitiesFromServer()
			Orchestrator.Logger:Log({Message = "Client hooked", Level = "INFO"})
		end
		Orchestrator.Logger:Log({Message = "Orchestrator initialized", Level = "INFO"})
	return true
	end)

	if not Success then
		Orchestrator.Logger:Log({Message = "Orchestrator initialization failed: " .. Result, Level = "ERROR"})
		Initialized = false
	end
	return Result
end

return Orchestrator