--!strict
--[=[
	@Name Core/Registry.luau
	@Author iKrypto
	@Description Central registry for tracking active Entity and StateMachine instances
	by ID. Provides registration/unregistration, lookup, object pooling for entity
	reuse, and signals for registration events (EntityRegistered, StateMachineRegistered).
]=]
local Registry = {
	Entities = {} :: { [string]: any },
	StateMachines = {} :: { [string]: any },
	EntityPools = {} :: { [string]: { any } },
}

local Initialized = false

--[=[
	@description Initializes the Registry module with shared utilities.
	Creates the Logger instance and registration signals.

	@param Util table -- Orchestrator utility table containing Logger and Signal
	@return ()
	@writes Registry.Logger, Registry.EntityRegistered, Registry.StateMachineRegistered
]=]
function Registry.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Registry.Logger = Util.Logger.new({ Name = "Registry" })

	Registry.Logger:Log({ Level = "INFO", Message = "Registry initialized" })
	
	Registry.EntityRegistered = Util.Signal.new()
	Registry.EntityUnregistered = Util.Signal.new()
	Registry.StateMachineRegistered = Util.Signal.new()
end

local function ValidateRequest()
	assert(Initialized, "Registry not initialized")
	assert(type(Registry.Logger) == "table", "Logger not initialized")
end

--[=[
	@description Registers an entity by ID. Fires the EntityRegistered signal.

	@param id string -- Unique entity identifier
	@param entity any -- Entity instance to register
	@return ()
	@reads None
	@writes Registry.Entities[id]
]=]
function Registry.RegisterEntity(id: string, entity: any)
	ValidateRequest()
	Registry.Entities[id] = entity
	Registry.Logger:Log({ Level = "INFO", Message = "Entity registered: " .. id })
	Registry.EntityRegistered:Fire(id, entity)
end

--[=[
	@description Unregisters an entity by ID, removing it from the active registry.

	@param id string -- Entity identifier to remove
	@return ()
	@reads None
	@writes Registry.Entities[id]
]=]
function Registry.UnregisterEntity(id: string)
	ValidateRequest()
	local entity = Registry.Entities[id]
	Registry.Entities[id] = nil
	Registry.Logger:Log({ Level = "INFO", Message = "Entity unregistered: " .. id })
	if entity and Registry.EntityUnregistered then
		Registry.EntityUnregistered:Fire(id, entity)
	end
end

--[=[
	@description Retrieves an entity by ID from the active registry.

	@param id string -- Entity identifier
	@return any? -- The entity instance, or nil if not found
	@reads Registry.Entities
	@writes None
]=]
function Registry.GetEntity(id: string): any?
	ValidateRequest()
	return Registry.Entities[id]
end

--[=[
	@description Registers a state machine by ID. Fires the StateMachineRegistered signal.

	@param id string -- Unique state machine identifier
	@param stateMachine any -- StateMachine instance to register
	@return ()
	@reads None
	@writes Registry.StateMachines[id]
]=]
function Registry.RegisterStateMachine(id: string, stateMachine: any)
	ValidateRequest()
	Registry.StateMachines[id] = stateMachine
	Registry.Logger:Log({ Level = "INFO", Message = "State Machine registered: " .. id })
	Registry.StateMachineRegistered:Fire(id, stateMachine)
end

--[=[
	@description Unregisters a state machine by ID.

	@param id string -- State machine identifier to remove
	@return ()
	@reads None
	@writes Registry.StateMachines[id]
]=]
function Registry.UnregisterStateMachine(id: string)
	ValidateRequest()
	Registry.StateMachines[id] = nil
	Registry.Logger:Log({ Level = "INFO", Message = "State Machine unregistered: " .. id })
end

--[=[
	@description Retrieves a state machine by ID from the active registry.

	@param id string -- State machine identifier
	@return any? -- The state machine instance, or nil if not found
	@reads Registry.StateMachines
	@writes None
]=]
function Registry.GetStateMachine(id: string): any?
	ValidateRequest()
	return Registry.StateMachines[id]
end

--[=[
	@description Adds an entity to the reuse pool keyed by class name.
	Pooled entities can be retrieved later via GetPooledEntity to avoid
	reconstruction overhead.

	@param className string -- Entity class name for pool grouping
	@param entity any -- Entity instance to pool
	@return ()
	@reads None
	@writes Registry.EntityPools[className]
]=]
local MAX_POOL_SIZE = 64

function Registry.PoolEntity(className: string, entity: any)
	ValidateRequest()
	if not Registry.EntityPools[className] then
		Registry.EntityPools[className] = {}
	end
	if #Registry.EntityPools[className] >= MAX_POOL_SIZE then
		return
	end
	table.insert(Registry.EntityPools[className], entity)
	Registry.Logger:Log({ Level = "DEBUG", Message = "Entity pooled: " .. className })
end

--[=[
	@description Retrieves and removes an entity from the pool by class name.
	Returns nil if the pool is empty.

	@param className string -- Entity class name
	@return any? -- A pooled entity instance, or nil
	@reads Registry.EntityPools[className]
	@writes Registry.EntityPools[className] (removes last element)
]=]
function Registry.GetPooledEntity(className: string): any?
	ValidateRequest()
	local pool = Registry.EntityPools[className]
	if pool and #pool > 0 then
		Registry.Logger:Log({ Level = "DEBUG", Message = "Entity retrieved from pool: " .. className })
		return table.remove(pool)
	end
	Registry.Logger:Log({ Level = "DEBUG", Message = "Entity not found in pool: " .. className })
	return nil
end

--[=[
	@description Returns all active entities as a shared table.
	Do not mutate the returned table.

	@return { [string]: any } -- Map of entity ID → entity instance
	@reads Registry.Entities
	@writes None
]=]
function Registry.GetAllEntities()
	ValidateRequest()
	return table.clone(Registry.Entities)
end

--[=[
	@description Returns all active state machines as a shared table.
	Do not mutate the returned table.

	@return { [string]: any } -- Map of state machine ID → instance
	@reads Registry.StateMachines
	@writes None
]=]
function Registry.GetAllStateMachines()	
	ValidateRequest()
	return table.clone(Registry.StateMachines)
end

--[=[
	@description Cleans up registry signals and resets state.

	@return ()
	@reads Registry.EntityRegistered, Registry.EntityUnregistered, Registry.StateMachineRegistered
	@writes Initialized
]=]
function Registry.Destroy()
	if Registry.EntityRegistered then Registry.EntityRegistered:Destroy() end
	if Registry.EntityUnregistered then Registry.EntityUnregistered:Destroy() end
	if Registry.StateMachineRegistered then Registry.StateMachineRegistered:Destroy() end
	Initialized = false
end

return Registry
