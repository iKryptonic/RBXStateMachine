--!strict
-- @Interface BaseEntityInterface
-- @Description Detailed interface documentation for the BaseEntity class.

export type LogLevel = "INFO" | "WARN" | "ERROR" | "DEBUG"

-- Definition of a property in the schema
export type PropertyDef = {
	Type: string, -- The expected Luau type (e.g., "number", "string", "Instance") or ClassName
	Description: string? -- Documentation for what this property represents
}

-- The BaseEntity Class Interface
export type BaseEntity = {
	-- Properties
	Name: string, -- The name of the entity
	Instance: Instance, -- The underlying Roblox Instance being managed
	IsValid: boolean, -- Whether the entity is currently valid (not destroyed)
	OwnerId: string?, -- The ID of the system that owns/created this entity
	
	-- Signals
	StateUpdated: RBXScriptSignal, -- Fired when properties are successfully committed (returns changes table)
	Destroyed: RBXScriptSignal, -- Fired when the entity is destroyed

	-- Methods

	--[[
		Logs a message associated with this entity.
		@param params Table containing Level and Message.
	]]
	Log: (self: BaseEntity, params: { Level: LogLevel, Message: string }) -> (),

	--[[
		Defines the schema for valid properties.
		@param schema A dictionary mapping property names to PropertyDef definitions.
	]]
	DefineSchema: (self: BaseEntity, schema: { [string]: PropertyDef }) -> (),

	--[[
		Sets a value in the internal Context (non-physical data).
		@param key The key to store.
		@param value The value to store.
	]]
	SetContext: (self: BaseEntity, key: any, value: any) -> (),

	--[[
		Registers an object to be cleaned up when the entity is destroyed.
		@param object An Instance, Connection, function, or object with a Destroy method.
		@return The object passed in.
	]]
	Manage: (self: BaseEntity, object: any) -> any,

	--[[
		Commits pending property changes to the entity.
		Triggers ApplyChanges and fires StateUpdated.
		@param lockingCallerId Optional ID if the entity is locked.
		@return True if the update was successful.
	]]
	UpdateEntity: (self: BaseEntity, lockingCallerId: string?) -> boolean,

	--[[
		Abstract method to apply changes to the physical instance.
		Override this in subclasses.
		@param changes A table of key-value pairs that have changed.
	]]
	ApplyChanges: (self: BaseEntity, changes: { [string]: any }) -> (),

	--[[
		Returns the current schema definition.
		@return The schema table.
	]]
	GetValidProperties: (self: BaseEntity) -> { [string]: PropertyDef },

	--[[
		Attempts to lock the entity to a specific owner.
		@param callerId The ID of the system requesting the lock.
		@return True if the lock was acquired.
	]]
	AcquireLock: (self: BaseEntity, callerId: string) -> boolean,

	--[[
		Releases a lock if the callerId matches the current owner.
		@param callerId The ID of the system releasing the lock.
		@return True if the lock was released.
	]]
	ReleaseLock: (self: BaseEntity, callerId: string) -> boolean,

	--[[
		Destroys the entity proxy and cleans up resources.
		Called automatically if the Instance is removed.
	]]
	Destroy: (self: BaseEntity) -> ()
}

return {}
