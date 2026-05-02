--!strict
-- @Name Orchestrator
-- @Author iKrypto
-- @Description Factory and Registry for managing unique StateMachine instances by ID.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = {
	Factory = require(script.Core.Factory),
	Logger = require(script.Core.Logger),
	NetworkManager = require(script.Core.NetworkManager),
	Scheduler = require(script.Core.Scheduler),
	Signal = require(script.Core.Signal),
	Types = require(script.Core.Types),
	Settings = require(script.Core.Settings),
}; 
local Strings = Core.Settings.StaticStrings

local Orchestrator = {
	Logger = nil,
	Factory = nil, -- Expose Class Factory
	NetworkManager = Core.NetworkManager,
	Settings = Core.Settings,
	_serviceManager = nil,

	-- Expose History for legacy support/ServiceManager
	History = {}
}

local Initialized = false
local _initializing = false
local _moduleRegistry = {} :: { [string]: any }
local _sharedModulesRegistered = false

local function RegisterSharedModules()
	if _sharedModulesRegistered then
		return
	end

	local sharedFolder = ReplicatedStorage:FindFirstChild("shared")
	if not sharedFolder then
		return
	end

	for _, mod in ipairs(sharedFolder:GetChildren()) do
		if mod:IsA("ModuleScript") then
			pcall(function()
				Orchestrator.RegisterModule(mod.Name, require(mod))
			end)
		end
	end

	_sharedModulesRegistered = true
end

local function ValidateRequest(context: string)
	-- Allow calls during the bootstrap phase (Initialize() runs internal
	-- helpers that call ValidateRequest before the global Initialized flag
	-- is set). Without this, InitializeModule/SetSharedVariables fail on
	-- their first call, leaving Initialized=false forever.
	if not (Initialized or _initializing) then
		assert(false, "Orchestrator not initialized")
	end
	if context then
		if context == "Server" and not RunService:IsServer() then
			Orchestrator.Logger:Log({ Level = "ERROR", Message =  Strings.Error.ServerRequestErrorMessage })
			error(Strings.Error.ServerRequestErrorMessage)
			return false
		end
		if context == "Client" and not RunService:IsClient() then
			Orchestrator.Logger:Log({ Level = "ERROR", Message =  Strings.Error.ClientRequestErrorMessage })
			error(Strings.Error.ClientRequestErrorMessage)
			return false
		end
		return true
	end
end

-------------------------------------------------------------------------------------------
---------------------------------- BEGIN SHARED METHODS -----------------------------------
-------------------------------------------------------------------------------------------

function Orchestrator:RegisterComponents()
	local initialized = Initialize()

	if initialized then
		RegisterSharedModules()
	end

	if initialized and RunService:IsServer() and not self._serviceManager then
		local serviceManagerModule = script:FindFirstChild("ServiceManager")
		if serviceManagerModule then
			local serviceManager = require(serviceManagerModule)
			serviceManager.RegisterServerHandlers(self)
			self._serviceManager = serviceManager
		end
	end

	return initialized
end

function Orchestrator:StartServiceManager()
	if Orchestrator._serviceManager then return Orchestrator._serviceManager end

	local ok, serviceManager = pcall(require, script.ServiceManager)
	if not ok or not serviceManager then
		warn("[Orchestrator] Failed to load ServiceManager:", serviceManager)
		return nil
	end
	
	local initOk, initErr = pcall(function()
		serviceManager.Initialize(Orchestrator)
	end)
	if not initOk then
		warn("[Orchestrator] ServiceManager.Initialize failed:", initErr)
		return nil
	end
	
	Orchestrator._serviceManager = serviceManager
	return serviceManager
end

function Orchestrator:GetServiceManager()
	return Orchestrator and Orchestrator._serviceManager or nil
end

function Orchestrator.CreateEntity(params: { EntityClass: any, EntityId: string, Context: {any}?, Persistent: boolean?, PersistenceKey: string? })
	ValidateRequest()
	if not params.Context then params.Context = {} end
	params.Context._Orchestrator = Orchestrator
	return Core.Factory.CreateEntity(params)
end

function Orchestrator.CreateStateMachine(params: { StateMachineClass: any, StateMachineId: string, Context: {any}? })
	ValidateRequest()
	if not params.Context then params.Context = {} end
	params.Context._Orchestrator = Orchestrator
	return Core.Factory.CreateStateMachine(params)
end

function Orchestrator.RegisterModule(name: string, module: any)
	_moduleRegistry[name] = module
end

function Orchestrator.GetModule(name: string): any?
	if _moduleRegistry[name] then
		return _moduleRegistry[name]
	end

	local sharedFolder = ReplicatedStorage:FindFirstChild("shared")
	if sharedFolder then
		local mod = sharedFolder:FindFirstChild(name)
		if mod and mod:IsA("ModuleScript") then
			local result = require(mod)
			_moduleRegistry[name] = result
			return result
		end
	end

	return nil
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

	local context = table.clone(oldSM.Context)
	local name = oldSM.Name
	-- BUG FIX: Use Factory.Get to look up the COMPILED CLASS, not the
	-- instance registry. The previous Registry.GetStateMachine was the
	-- instance lookup keyed by FSM Id, which always returned nil here,
	-- silently destroying the old FSM and creating no replacement.
	local class = Core.Factory.Get("StateMachine", name)

	if not class then return end

	-- Remove old (after we've confirmed we can build a replacement)
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
	-- BUG FIX: Only the SERVER may BroadcastEntityCommand. The client receives
	-- this same broadcast (OnEntityPooled action) and re-invokes PoolEntity,
	-- which would then trigger NetworkManager.ValidateRequest("Server") and
	-- assert. Gate the broadcast to the server side.
	if RunService:IsServer() then
		Core.NetworkManager.BroadcastEntityCommand(entityId, "OnEntityPooled")
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

-- Convenience alias used throughout the codebase
Orchestrator.Request = Orchestrator.ServerRequest

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
			local waitTime = 0.03
			while not Initialized do
				if os.clock() - start > 5 then
					warn("[Orchestrator] Yielded for >5s waiting for initialization.")
					break
				end
				task.wait(waitTime)
				waitTime = math.min(waitTime * 2, 0.5)
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
		Orchestrator.NetworkManager = Core.NetworkManager
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



	end

end

local function RegisterCallbacks()
	if not RunService:IsServer() then return end

	-- Request Entity Snapshot
	local function GetEntitySnapshot()
		local snapshot = {}
		for id, entity in pairs(Core.Factory.Registry.GetAllEntities()) do
			local className = (entity and (entity :: any)._privateProperties and (entity :: any)._privateProperties.Name) or (entity :: any).ClassName or (entity :: any).Name
			-- Sanitize: only include fields with Replicate=true. Otherwise we
			-- leak persistent server-only fields (passwords, tokens, etc.) to
			-- every connecting client.
			local sanitized = {}
			local pp = (entity :: any)._privateProperties
			if pp and pp.Schema and pp.Data then
				for k, def in pairs(pp.Schema) do
					if def and def.Replicate then
						sanitized[k] = pp.Data[k]
					end
				end
				-- Stamp with server's authoritative version so client's
				-- pp.Version starts correct (otherwise it stays 0, and the
				-- next replicated update overwrites with no diff baseline).
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

	-- Debug introspection: lets clients (and tests) read the live _remoteStats
	-- without needing to share the require-cache. Returns the same table the
	-- NetworkModule.FetchData reads from.
	Core.NetworkManager.RegisterServerRequest("__DebugRemoteStats", function()
		return Core.NetworkManager._remoteStats or {}
	end)
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
					-- Pass InitialData so BaseEntity Subclass.new pre-populates
					-- pp.Data BEFORE GetContext runs. This ensures GetContext
					-- can read replicated fields (e.g. IsOpen) and derive
					-- correct cached state (e.g. _closedCFrame).
					local newEntity = Core.Factory.CreateEntity({
						EntityClass = class,
						EntityId = data.Id,
						Context = { Instance = data.Instance },
						InitialData = data.Data,
					})
					-- Drain any pending updates that arrived for this entity
					-- before it was created (see _pendingUpdates buffer below).
					if newEntity and Orchestrator._pendingUpdates and Orchestrator._pendingUpdates[data.Id] then
						local queue = Orchestrator._pendingUpdates[data.Id]
						Orchestrator._pendingUpdates[data.Id] = nil
						-- Sort by version so they apply in order
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
											if not def then
												warn(string.format("Unknown field '%s' in buffered update for entity %s", tostring(k), tostring(data.Id)))
												continue
											end
											if v ~= nil and def.Type and def.Type ~= "any" and typeof(v) ~= def.Type then
												if not (typeof(v) == "Instance" and v:IsA(def.Type)) then
													warn(string.format("Type mismatch for field '%s': expected %s got %s", tostring(k), def.Type, typeof(v)))
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
	if _initializing then return false end
	_initializing = true

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
			-- Pending update buffer: holds EntityUpdateEvents that arrive
			-- BEFORE the entity has been created on this client (e.g. a delta
			-- arrives during the snapshot round-trip). Drained when
			-- SyncEntitiesFromServer or OnEntityCreated finally creates the
			-- entity.
			Orchestrator._pendingUpdates = Orchestrator._pendingUpdates or {}

			if Core.NetworkManager.EntityUpdateEvent then
				Core.NetworkManager.EntityUpdateEvent.OnClientEvent:Connect(function(entityId, changes)
					-- Track inbound update for the dashboard's "View Calls" drill-down
					if Core.NetworkManager.RecordInboundCall then
						Core.NetworkManager.RecordInboundCall("EntityUpdateEvent", "S→C", entityId, changes)
					end
					local entity = Core.Factory.Registry.GetEntity(entityId)
					if not entity then
						-- Buffer for replay after creation. Cap per-entity to
						-- 64 to avoid unbounded growth on a stuck snapshot.
						local MAX_PENDING_ENTITIES = 256
						if not Orchestrator._pendingUpdates[entityId] then
							local count = 0
							for _ in pairs(Orchestrator._pendingUpdates) do count += 1 end
							if count >= MAX_PENDING_ENTITIES then
								return
							end
						end
						Orchestrator._pendingUpdates[entityId] = Orchestrator._pendingUpdates[entityId] or {}
						local q = Orchestrator._pendingUpdates[entityId]
						table.insert(q, changes)
						while #q > 64 do table.remove(q, 1) end
						return
					end

					-- Version Check
					local newVersion = changes._v
					if newVersion then
						local currentVersion = (entity._privateProperties and entity._privateProperties.Version) or 0
						if newVersion <= currentVersion then
							-- Discard out-of-order packet
							return
						end
						-- Warn on large version gaps (small gaps are expected during rapid combat updates)
						if currentVersion > 0 and (newVersion - currentVersion) > 5 then
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
						-- Build version history snapshot BEFORE writing Data
						-- so From values reflect pre-update state.
						if entity._privateProperties._versionHistory then
							local schema = entity._privateProperties.Schema or {}
							local snapshot = {} :: { [string]: any }
							for k, v in pairs(changes) do
								if k ~= "_v" then
									snapshot[k] = { From = entity._privateProperties.Data[k], To = v }
								end
							end
							table.insert(entity._privateProperties._versionHistory, {
								Version = newVersion or (entity._privateProperties.Version or 0),
								Time = os.clock(),
								Changes = snapshot,
							})
							while #entity._privateProperties._versionHistory > (entity._privateProperties._versionHistoryMax or 50) do
								table.remove(entity._privateProperties._versionHistory, 1)
							end
						end

						-- Validate against schema and write only known fields
						-- to Data. Unknown / mistyped keys are dropped with a
						-- warning rather than silently corrupting state.
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

					-- Strip _v before ApplyChanges so subclasses iterating
					-- changes don't see _v as a property.
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
								-- Pass through replicated initial state so
								-- BaseEntity Subclass.new pre-populates pp.Data
								-- BEFORE GetContext runs.
								InitialData = data.InitialData,
							})
							-- Drain any updates that arrived before this create
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
												if not def then
													warn(string.format("Unknown field '%s' in buffered update for entity %s", tostring(k), tostring(entityId)))
													continue
												end
												if v ~= nil and def.Type and def.Type ~= "any" and typeof(v) ~= def.Type then
													if not (typeof(v) == "Instance" and v:IsA(def.Type)) then
														warn(string.format("Type mismatch for field '%s': expected %s got %s", tostring(k), def.Type, typeof(v)))
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
						-- Pool the LOCAL client-side entity without re-broadcasting
						-- (PoolEntity has a server-only gate for the broadcast).
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
		warn("[Orchestrator] initialization failed: " .. tostring(Result))
		if Orchestrator.Logger then
			Orchestrator.Logger:Log({Message = "Orchestrator initialization failed: " .. tostring(Result), Level = "ERROR"})
		end
		_initializing = false
	else
		_initializing = false
		Initialized = true
	end
	return Result
end

return Orchestrator