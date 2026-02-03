--!strict
-- @Interface OrchestratorInterface
-- @Description Detailed interface documentation for the Orchestrator singleton.

-- The Orchestrator Singleton Interface
export type Orchestrator = {
	-- Properties
	Logger: any, -- The internal logger instance
	History: {any}, -- History of StateMachine lifecycle events

	-- Methods

	--[[
		Loads Entity and StateMachine classes into shared globals and initializes shared.FSM.
	]]
	RegisterComponents: (self: Orchestrator) -> (),

	--[[
		Creates (or retrieves) a unique Entity instance by ID.
		@param params Table containing EntityClass, EntityId, and optional Context.
		@return The created or existing Entity instance (nil on failure).
	]]
	CreateEntity: (params: { EntityClass: any, EntityId: string, Context: {any}? }) -> any?,

	--[[
		Creates (or retrieves) a unique StateMachine instance by ID.
		@param params Table containing StateMachineClass, StateMachineId, and optional Context.
		@return The created or existing StateMachine instance (nil on failure).
	]]
	CreateStateMachine: (params: { StateMachineClass: any, StateMachineId: string, Context: {any}? }) -> any?,

	--[[
		Retries a stateMachine by ID, preserving its Context.
		@param stateMachineId The ID of the StateMachine to retry.
	]]
	RetryStateMachine: (stateMachineId: string) -> (),

	--[[
		Retrieves a StateMachine by its ID.
		@param stateMachineId The ID of the StateMachine.
		@return The StateMachine instance or nil.
	]]
	GetStateMachine: (stateMachineId: string) -> any?,

	--[[
		Retrieves an Entity by its ID.
		@param entityId The ID of the Entity.
		@return The Entity instance or nil.
	]]
	GetEntity: (entityId: string) -> any?,

	--[[
		Cancels a specific StateMachine by ID.
		@param stateMachineId The ID of the StateMachine.
		@return True if found and cancelled.
	]]
	CancelStateMachine: (stateMachineId: string) -> boolean,

	--[[
		Deletes (destroys) a specific Entity by ID.
		@param entityId The ID of the Entity.
	]]
	DeleteEntity: (entityId: string) -> (),

	--[[
		Deletes (destroys) all active Entities.
	]]
	DeleteAllEntities: () -> (),

	--[[
		Cancels all active StateMachines.
	]]
	CancelAll: () -> (),

	--[[
		Returns the current active Entities map.
		@return Dictionary of EntityId -> EntityInstance.
	]]
	GetEntities: () -> { [string]: any },

	--[[
		Returns the current active StateMachines map.
		@return Dictionary of StateMachineId -> StateMachineInstance.
	]]
	GetStateMachines: () -> { [string]: any },

	--[[
		Initializes client-side listeners for Entity state updates.
		(Client Only)
	]]
	InitClientListeners: () -> (),

	--[[
		Starts the ServiceManager remote API.
		(Server Only)
	]]
	StartServiceManagerAPI: () -> (),

	--[[
		Handles replication of Entity property changes to clients.
		(Server Only)
		@param entityId The ID of the entity.
		@param changes The table of changed properties.
		@param schema The entity's schema definition.
	]]
	HandleReplication: (entityId: string, changes: {[string]: any}, schema: {[string]: any}) -> ()
}

return {}