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
local function ValidateRequest(context: string?)
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
	end
	return true
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

	-- Deep-clone context before destroying old SM to prevent stale references
	local context = oldSM.Context and table.clone(oldSM.Context) or {}
	local name = oldSM.Name
	local class = Core.Factory.Get("StateMachine", name)

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
	-- Snapshot before iterating; entity Destroy mutates the registry.
	local snapshot = {}
	for id, e in pairs(Core.Factory.Registry.GetAllEntities()) do snapshot[id] = e end
	for _, entity in pairs(snapshot) do
		pcall(function() entity:Destroy() end)
	end
	return true
end

function Orchestrator.CancelAll()
	ValidateRequest()
	-- Snapshot before iterating; Cancel may unregister mid-iteration.
	local snapshot = {}
	for id, sm in pairs(Core.Factory.Registry.GetAllStateMachines()) do snapshot[id] = sm end
	for _, sm in pairs(snapshot) do
		pcall(function() sm:Cancel() end)
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
	if RunService:IsServer() then
		pcall(Core.NetworkManager.BroadcastEntityCommand, entityId, "OnEntityPooled")
	end
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
		-- Yield until initialized, with a timeout and backoff
		if not Initialized then
			local start = os.clock()
			local waitTime = 0.03
			while not Initialized do
				if os.clock() - start > 5 then
					warn("[Orchestrator] Yielded for >5s waiting for initialization.")
					break
				end
				task.wait(waitTime)
				waitTime = math.min(waitTime * 2, 0.5) -- exponential backoff
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
			local className = (entity and (entity :: any)._privateProperties and (entity :: any)._privateProperties.Name) or (entity :: any).ClassName or (entity :: any).Name
			-- Sanitize: only include fields with Replicate=true.
			local sanitized = {}
			local pp = (entity :: any)._privateProperties
			if pp and pp.Schema and pp.Data then
				for k, def in pairs(pp.Schema) do
					if def and def.Replicate then
						sanitized[k] = pp.Data[k]
					end
				end
				sanitized._v = pp.Version
			end
			table.insert(snapshot, {
				Id = id,
				ClassName = className,
				Instance = entity.Instance,
				Data = sanitized,
				Version = (pp and pp.Version) or 0,
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
						Context = { Instance = data.Instance },
						InitialData = data.Data,
					})
					-- Drain any pending updates that arrived before entity was created
					if newEntity and Orchestrator._pendingUpdates and Orchestrator._pendingUpdates[data.Id] then
						local queue = Orchestrator._pendingUpdates[data.Id]
						Orchestrator._pendingUpdates[data.Id] = nil
						table.sort(queue, function(a, b) return (a._v or 0) < (b._v or 0) end)
						for _, changes in ipairs(queue) do
							pcall(function()
								local entity = Core.Factory.Registry.GetEntity(data.Id)
								if entity and entity._privateProperties then
									local newVersion = changes._v
									if newVersion and newVersion > (entity._privateProperties.Version or 0) then
										entity._privateProperties.Version = newVersion
										local schema = entity._privateProperties.Schema or {}
										for k, v in pairs(changes) do
											if k == "_v" then continue end
											local def = schema[k]
											if not def then continue end
											if v ~= nil and def.Type and def.Type ~= "any" and typeof(v) ~= def.Type then
												if not (typeof(v) == "Instance" and v:IsA(def.Type)) then
													continue
												end
											end
											entity._privateProperties.Data[k] = v
										end
										local visualChanges = table.clone(changes)
										visualChanges._v = nil
										entity:ApplyChanges(visualChanges)
									end
								end
							end)
						end
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

	-- Use a guard to prevent re-entrant initialization
	local initializing = rawget(Orchestrator, "_initializing")
	if initializing then return false end
	rawset(Orchestrator, "_initializing", true)

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
			-- Pending update buffer: holds EntityUpdateEvents that arrive BEFORE
			-- the entity has been created on this client. Drained when
			-- SyncEntitiesFromServer or OnEntityCreated finally creates the entity.
			Orchestrator._pendingUpdates = Orchestrator._pendingUpdates or {}

			if Core.NetworkManager.EntityUpdateEvent then
				Core.NetworkManager.EntityUpdateEvent.OnClientEvent:Connect(function(entityId, changes)
					local entity = Core.Factory.Registry.GetEntity(entityId)
					if not entity then
						-- Buffer for replay after creation (cap at 64 per entity)
						Orchestrator._pendingUpdates[entityId] = Orchestrator._pendingUpdates[entityId] or {}
						local q = Orchestrator._pendingUpdates[entityId]
						table.insert(q, changes)
						while #q > 64 do table.remove(q, 1) end
						return
					end

					-- Version Check
					local newVersion = changes._v
					if newVersion then
						local currentVersion = entity.Version or 0
						if newVersion <= currentVersion then
							-- Discard out-of-order packet
							return 
						end
						-- Warn on version gaps (lossy replication detected)
						if currentVersion > 0 and (newVersion - currentVersion) > 1 then
							Orchestrator.Logger:Log({
								Level = "WARN",
								Message = string.format("Entity %s version gap: jumped from v%d to v%d", tostring(entityId), currentVersion, newVersion),
							})
						end
						if entity._privateProperties then
							entity._privateProperties.Version = newVersion
						end
					end

					if entity._privateProperties then
						-- Validate against schema and write only known, type-correct fields
						local schema = entity._privateProperties.Schema or {}
						for k, v in pairs(changes) do
							if k == "_v" then continue end
							local def = schema[k]
							if not def then
								Orchestrator.Logger:Log({
									Level = "WARN",
									Message = string.format("Replicated unknown field '%s' on entity %s; dropped.", tostring(k), tostring(entityId)),
								})
								continue
							end
							if v ~= nil and def.Type and def.Type ~= "any" and typeof(v) ~= def.Type then
								if not (typeof(v) == "Instance" and v:IsA(def.Type)) then
									Orchestrator.Logger:Log({
										Level = "WARN",
										Message = string.format("Replicated type mismatch on %s.%s (expected %s, got %s); dropped.", tostring(entityId), tostring(k), def.Type, typeof(v)),
									})
									continue
								end
							end
							entity._privateProperties.Data[k] = v
						end
					end

					-- Strip _v before ApplyChanges so subclasses don't see it as a property
					local visualChanges = table.clone(changes)
					visualChanges._v = nil
					entity:ApplyChanges(visualChanges)
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
								Context = { Instance = data.Instance },
								InitialData = data.InitialData,
							})
							-- Drain any updates that arrived before this entity was created
							if ent and Orchestrator._pendingUpdates[entityId] then
								local queue = Orchestrator._pendingUpdates[entityId]
								Orchestrator._pendingUpdates[entityId] = nil
								table.sort(queue, function(a, b) return (a._v or 0) < (b._v or 0) end)
								for _, changes in ipairs(queue) do
									local liveEnt = Core.Factory.Registry.GetEntity(entityId)
									if liveEnt and liveEnt._privateProperties then
										local newVersion = changes._v
										if newVersion and newVersion > (liveEnt._privateProperties.Version or 0) then
											liveEnt._privateProperties.Version = newVersion
											local schema = liveEnt._privateProperties.Schema or {}
											for k, v in pairs(changes) do
												if k == "_v" then continue end
												local def = schema[k]
												if not def then continue end
												if v ~= nil and def.Type and def.Type ~= "any" and typeof(v) ~= def.Type then
													if not (typeof(v) == "Instance" and v:IsA(def.Type)) then
														continue
													end
												end
												liveEnt._privateProperties.Data[k] = v
											end
											local visualChanges = table.clone(changes)
											visualChanges._v = nil
											pcall(function() liveEnt:ApplyChanges(visualChanges) end)
										end
									end
								end
							end
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

	rawset(Orchestrator, "_initializing", nil)
	if Success then
		Initialized = true
	else
		Orchestrator.Logger:Log({Message = "Orchestrator initialization failed: " .. tostring(Result), Level = "ERROR"})
		Initialized = false
	end
	return Result
end

return Orchestrator