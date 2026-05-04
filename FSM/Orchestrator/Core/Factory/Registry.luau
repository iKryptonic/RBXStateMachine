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
	Bootstraps the Registry with a Logger and creates the three lifecycle signals:
	`EntityRegistered`, `EntityUnregistered`, and `StateMachineRegistered`. No-ops
	if called again after the first successful call.

	@param Util table -- Shared Orchestrator utilities; must expose `Util.Logger.new` and `Util.Signal`.
	@reads Initialized
	@writes Registry.Logger, Registry.EntityRegistered, Registry.EntityUnregistered,
	        Registry.StateMachineRegistered, Initialized
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
	assert(Initialized,"Registry not initialized")
	assert(type(Registry.Logger) == "table","Logger not initialized")
end


--[=[
	Stores an entity instance under the given `id` in `Registry.Entities` and
	fires the `EntityRegistered` signal. Overwrites any prior entry for the same
	id without warning.

	@param id string -- Unique entity identifier (typically a GUID).
	@param entity any -- Entity instance to register.
	@reads Initialized
	@writes Registry.Entities[id]
	@fires Registry.EntityRegistered
]=]
function Registry.RegisterEntity(id: string, entity: any)
	ValidateRequest()
	Registry.Entities[id] = entity
	Registry.Logger:Log({ Level = "INFO", Message = "Entity registered: " .. id })
	Registry.EntityRegistered:Fire(id, entity)
end


--[=[
	Removes the entity keyed by `id` from `Registry.Entities` and fires the
	`EntityUnregistered` signal with the removed instance. Silent no-op if `id`
	is not currently registered.

	@param id string -- Unique entity identifier to remove.
	@reads Registry.Entities[id]
	@writes Registry.Entities[id] = nil
	@fires Registry.EntityUnregistered (only when entity existed)
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
	Returns the entity instance associated with `id`, or nil if it has not been
	registered (or was already unregistered).

	@param id string -- Unique entity identifier to look up.
	@return any? -- Registered entity instance, or nil.
	@reads Registry.Entities[id]
	@writes None
]=]
function Registry.GetEntity(id: string): any?
	ValidateRequest()
	return Registry.Entities[id]
end


--[=[
	Stores a state-machine instance under `id` in `Registry.StateMachines` and
	fires `StateMachineRegistered`. Overwrites any prior entry without warning.

	@param id string -- Unique FSM identifier.
	@param stateMachine any -- StateMachine instance to register.
	@reads Initialized
	@writes Registry.StateMachines[id]
	@fires Registry.StateMachineRegistered
]=]
function Registry.RegisterStateMachine(id: string, stateMachine: any)
	ValidateRequest()
	Registry.StateMachines[id] = stateMachine
	Registry.Logger:Log({ Level = "INFO", Message = "State Machine registered: " .. id })
	Registry.StateMachineRegistered:Fire(id, stateMachine)
end


--[=[
	Removes the state machine keyed by `id` from `Registry.StateMachines`. Silent
	no-op if not registered. Does not fire any signal.

	@param id string -- Unique FSM identifier to remove.
	@reads Registry.StateMachines[id]
	@writes Registry.StateMachines[id] = nil
]=]
function Registry.UnregisterStateMachine(id: string)
	ValidateRequest()
	Registry.StateMachines[id] = nil
	Registry.Logger:Log({ Level = "INFO", Message = "State Machine unregistered: " .. id })
end


--[=[
	Returns the state machine instance for `id`, or nil if unregistered.

	@param id string -- Unique FSM identifier to look up.
	@return any? -- Registered FSM instance, or nil.
	@reads Registry.StateMachines[id]
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


--[=[
	Adds `entity` to the per-class reuse pool capped at `MAX_POOL_SIZE` (64).
	Entities in the pool are returned by `GetPooledEntity` and recycled by
	`Factory.CreateEntity` rather than being garbage-collected, reducing
	construction overhead for frequently-created classes.

	@param className string -- Entity class name used as the pool bucket key.
	@param entity any -- Entity instance to store in the pool.
	@reads Registry.EntityPools[className]
	@writes Registry.EntityPools[className]
]=]
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
	Pops and returns the most-recently pooled entity for `className`, or nil if
	the pool is empty. Logs a DEBUG message either way to help trace pool hit/miss
	rates.

	@param className string -- Entity class name to retrieve a pooled instance for.
	@return any? -- A recycled entity instance, or nil if pool is empty.
	@reads Registry.EntityPools[className]
	@writes Registry.EntityPools[className] (removes last element on hit)
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
	Returns a shallow clone of the entire `Entities` map. Callers receive an
	independent snapshot; mutations to the returned table do not affect the
	Registry.

	@return { [string]: any } -- Snapshot of all currently registered entities keyed by id.
	@reads Registry.Entities
	@writes None
]=]
function Registry.GetAllEntities()
	ValidateRequest()
	return table.clone(Registry.Entities)
end


--[=[
	Returns a shallow clone of the entire `StateMachines` map. Callers receive an
	independent snapshot; mutations do not affect the Registry.

	@return { [string]: any } -- Snapshot of all registered FSM instances keyed by id.
	@reads Registry.StateMachines
	@writes None
]=]
function Registry.GetAllStateMachines()
	ValidateRequest()
	return table.clone(Registry.StateMachines)
end


--[=[
	Destroys all three lifecycle signals and resets `Initialized` to false,
	allowing the Registry to be re-initialized (e.g. during tests or server
	teardown). Does not clear the Entities/StateMachines/EntityPools tables.

	@reads Registry.EntityRegistered, Registry.EntityUnregistered,
	       Registry.StateMachineRegistered, Initialized
	@writes Initialized = false
]=]
function Registry.Destroy()
	if Registry.EntityRegistered then Registry.EntityRegistered:Destroy() end
	if Registry.EntityUnregistered then Registry.EntityUnregistered:Destroy() end
	if Registry.StateMachineRegistered then Registry.StateMachineRegistered:Destroy() end
	Initialized = false
end

return Registry
