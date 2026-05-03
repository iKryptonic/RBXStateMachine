--!strict
--[=[
	@Name BaseEntity
	@Author iKrypto
	@Description Abstract Base Entity class for schema-validated, proxy-wrapped data
	objects in the Orchestrator framework. Provides staged writes via __newindex,
	atomic commits via UpdateEntity(), serialization/deserialization for persistence,
	optimistic locking (AcquireLock/ReleaseLock), hierarchical cleanup traversal,
	and lifecycle signals (StateUpdated, Destroyed). Subclasses extend via
	`BaseEntity.Extend()` and override `GetContext()` / `ApplyChanges()` / `Cleanup()`.

	@usage
	local MyEntity = BaseEntity.Extend({
		Name = "MyEntity",
		Mutable = true,
		Schema = {
			Health = { Type = "number", Persist = true },
			Status = { Type = "string", Default = "Idle" },
		},
	})

	function MyEntity:ApplyChanges(changes)
		-- Apply visual updates
	end

	local instance = MyEntity.new({ Name = "Player1", OwnerId = "abc" })
	instance.Health = 100
	instance:UpdateEntity()
]=]
local BaseEntity = {}
-- Metamethods for property syntax (entity.Field = value)

local function __index(proxyTable: any, key: any)
	-- Support inheritance by looking up the key in the class (metatable) 
	local mt: any = getmetatable(proxyTable)
	if mt then
		return (mt :: any)[key]
	end
	return rawget(proxyTable :: any, key)
end

local function __newindex(proxyTable: any, key: any, value: any)
	rawset(proxyTable :: any, key, value)
end

BaseEntity.__index = __index
BaseEntity.__newindex = __newindex
BaseEntity.__tostring = function(self)
	return string.format("BaseEntity(%s) %s : [%s]", self.OwnerId or "-id-", self.entityName or "-name-", ((self.IsValid==true and "Valid") or (self.IsValid==false and "Invalid")) or "-state-")
end

local Logger, Signal, _Settings, Initialized;
--[=[
	@description Handles `Initialize` for `BaseEntity`.
	@param Util any -- `Util` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity.Initialize(Util)
	if Initialized then return end
	Initialized = true
	_Settings = Util.Settings
	Logger = Util.Logger.new({ Name = "BaseEntity" })
	Signal = Util.Signal

	Logger:Log({ Level = "INFO", Message = "BaseEntity initialized" })
end
--[=[
	@description Implements `BaseEntity.new`.
	@param params { Name: string, OwnerId: string?, Context: { [any]: any }? } -- `params` input parameter.
	@param class any? -- `class` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity.new(params: { Name: string, OwnerId: string?, Context: { [any]: any }? }, class: any?): any
	local privateProperties = {
		Name = params.Name,
		Schema = class and class.Definition.Schema or {} :: { [string]: any },
		Pending = {} :: { [string]: any },
		-- Track pending key set explicitly so that nil writes survive the commit
		-- loop. `next(Pending)` and `pairs(Pending)` cannot distinguish between
		-- "not set" and "set to nil"; this set does.
		_pendingKeys = {} :: { [string]: boolean },
		Data = {} :: { [string]: any },
		Context = params.Context or {},
		OwnerId = params.OwnerId,
		Mutable = (class and class.Definition and class.Definition.Mutable) or false,
		_class = class,

		EntityLocked = false,
		IsValid = true,

		_cache = {} :: { [string]: any },
		_stateUpdatedEvent = (Signal and Signal.new()) or error("BaseEntity: Signal not initialized. Did you call BaseEntity.Initialize(Util)?"),
		_entityDestroyedEvent = (Signal and Signal.new()) or error("BaseEntity: Signal not initialized. Did you call BaseEntity.Initialize(Util)?"),
		_cleanupTasks = {} :: { any },
		_logger = (Logger and Logger.new({ Name = params.Name or "BaseEntity" })) or error("BaseEntity: Logger not initialized. Did you call BaseEntity.Initialize(Util)?"),
		Version = 0 :: number,
		-- Ring buffer of version history entries, populated by UpdateEntity.
		-- Each entry: { Version, Time, Changes: { [string]: { From, To } } }
		_versionHistory = {} :: { { Version: number, Time: number, Changes: { [string]: any } } },
		_versionHistoryMax = 50,
	}
	local proxy = {}

	local mt = {
		__index = function(originalTable, key)
			-- Explicit nil checks at each tier — `or` cascade incorrectly swallows
			-- legitimate `false` / falsy values and falls through to the next tier.
			-- E.g. Data[key] = false would skip Data and read Context, breaking
			-- every boolean read after a write.
			local schema = privateProperties.Schema or {}
			local v = privateProperties._cache[key]
			if v ~= nil then return v end
			v = privateProperties.Data[key]
			if v ~= nil then return v end
			v = privateProperties.Context[key]
			if v ~= nil then return v end
			if class then
				v = (class :: any)[key]
				if v ~= nil then return v end
			end
			v = BaseEntity[key]
			if v ~= nil then return v end
			v = privateProperties[key]
			if v ~= nil then return v end
			if schema[key] then return schema[key].Default end
			return nil
		end,
		__newindex = function(originalTable, key, value)
			if not privateProperties.IsValid then
				originalTable:Log({ Level = "WARN", Message = string.format("[Entity] Attempt to modify destroyed entity property '%s'.", key) })
				return
			end
			local schema = privateProperties.Schema or {}
			local def = schema[key]
			if not def then
				-- Prevent the entity from being "mutated" unless ApplyChanges is explicitly overridden
				if key == "ApplyChanges" then
					rawset(originalTable, key, value)
					return
				end

				originalTable:Log
				{ 
					Level = "WARN", 
					Message = string.format("[Entity] Cannot set property '%s' as it does not exist in the Schema.", tostring(key)) 
				}
				return
			end

			-- NOTE: The first IsValid guard at the top of __newindex already handles
			-- destroyed-entity writes. No duplicate check needed here.

			-- Allow nil writes (clearing/resetting a property)
			-- Skip validation for "any" type - it accepts all values
			if value ~= nil and def.Type ~= "any" and typeof(value) ~= def.Type then
				-- Allow IsA check for Instances
				if not (typeof(value) == "Instance" and value:IsA(def.Type)) then
					originalTable:Log({ Level = "WARN", Message = string.format("[Entity] Type Mismatch: %s expected %s, got %s", key, def.Type, typeof(value)) })
					return
				end
			end
			privateProperties.Pending[key] = value
			-- Track keys explicitly so that nil writes survive the commit (otherwise
			-- a `nil` entry in Pending is indistinguishable from "no entry").
			privateProperties._pendingKeys = privateProperties._pendingKeys or {}
			privateProperties._pendingKeys[key] = true
			privateProperties._cache[key] = value
		end,
		__tostring = function()
			local clsName = (class and class.Definition and class.Definition.Name) or "BaseEntity"
			return string.format("%s(%s)", clsName, params.Name or "Unnamed")
		end,
	}

	proxy.StateUpdated = privateProperties._stateUpdatedEvent
	proxy.Destroyed = privateProperties._entityDestroyedEvent

	proxy._privateProperties = privateProperties

	--[=[
		@description Returns the entity's committed data table without proxy resolution.
		Useful for read-only snapshots or replication code that must ignore pending writes.
		@return { [string]: any } -- Authoritative committed property values
		@reads privateProperties.Data
		@writes None
	]=]
	proxy.GetRawData = function()
		return privateProperties.Data
	end

	setmetatable(proxy, mt)
	return proxy
end
--[=[
	@description Implements `BaseEntity.Extend`.
	@param extensionParams { Name: string, Schema: { [string]: any }? } -- `extensionParams` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity.Extend(extensionParams: { Name: string, Schema: { [string]: any }? })
	-- This is the Class Table (where methods like MyEntity:Method() will live)
	local Subclass: any = {}
	local SubclassAny: any = Subclass
	Subclass.Definition = extensionParams
	local subclassMetaTable = {}

	subclassMetaTable.__index = BaseEntity
	subclassMetaTable.__newindex = BaseEntity.__newindex
	subclassMetaTable.__tostring = function()
		return Subclass.Definition.Name or "UnnamedEntity"
	end;
	setmetatable(Subclass, subclassMetaTable)
	--[=[
		@description Implements `SubclassAny.new`.
		@param params any -- `params` input parameter.
		@return any -- Return value produced by the implementation, if any.
	]=]

	function SubclassAny.new(params)
		local subclassEntity = BaseEntity.new(params, SubclassAny);
		SubclassAny.Super = BaseEntity
		SubclassAny.super = BaseEntity

		-- Pre-populate Data from params.InitialData BEFORE GetContext runs so
		-- that GetContext can read self.<replicated_field> via the normal proxy
		-- read path and see the correct values (e.g. client-side sync where the
		-- server's Data must be visible during context derivation).
		if params and (params :: any).InitialData and type((params :: any).InitialData) == "table" then
			local pp = subclassEntity._privateProperties
			for k, v in pairs((params :: any).InitialData) do
				if k ~= "_v" then
					pp.Data[k] = v
				end
			end
			-- Reflect the version too so future replication packets aren't dropped
			-- by the version-check guard
			local syncedVersion = (params :: any).InitialData._v
			if type(syncedVersion) == "number" then
				pp.Version = syncedVersion
			end
		end

		local genericGetContextMethod = SubclassAny.GetContext
		if type(genericGetContextMethod) ~= "function" then
			subclassEntity:Log
			{ 
				Level = "WARN", 
				Message = string.format("Subclass '%s' did not implement 'GetContext'. No context set.", subclassEntity.entityName or "UnnamedEntity"),
			}
		end;

		-- Allow GetContext(self, params) to initialize cached parts, default state, etc.
		local EntityContext = (type(genericGetContextMethod) == "function" and genericGetContextMethod(subclassEntity, params)) or nil

		if EntityContext then
			for contextKey, contextValue in pairs(EntityContext) do
				subclassEntity:SetContext(contextKey, contextValue)
			end
		end

		return subclassEntity;
	end

	return Subclass
end
--[=[
	@description Implements `BaseEntity.Log`.
	@param params { Level: string, Message: string } -- `params` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:Log(params: { Level: string, Message: string })
	if not self._logger then
		print(params.Message, params.Level)
		return
	end
	self._logger:Log{
		Level = params.Level,
		Message = params.Message,
		OperationId = self._privateProperties and self._privateProperties.OwnerId or ""
	}
end
--[=[
	@description Implements `BaseEntity.DefineSchema`.
	@param schema { [string]: any } -- `schema` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:DefineSchema(schema: { [string]: any })
	self._privateProperties.Schema = schema
end
--[=[
	@description Updates module state through `BaseEntity.SetContext`.
	@param key any -- `key` input parameter.
	@param value any -- `value` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:SetContext(key: any, value: any)
	self._privateProperties.Context[key] = value
end
--[=[
	@description Implements `BaseEntity.Manage`.
	@param object any -- `object` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:Manage(object: any)
	table.insert(self._privateProperties._cleanupTasks, object)
	return object
end
--[=[
	@description Implements `BaseEntity.Serialize`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:Serialize()
	local data = {}
	local schema = self._privateProperties.Schema

	for key, def in pairs(schema) do
		if def.Persist then
			local value = self[key]
			if value ~= nil then
				data[key] = value
			end
		end
	end

	return data
end
--[=[
	@description Implements `BaseEntity.Deserialize`.
	@param data { [string]: any } -- `data` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:Deserialize(data: { [string]: any })
	if not data then return end

	for key, value in pairs(data) do
		-- We rely on __newindex for validation
		-- Only load if it's in the schema and marked as persistent
		local def = self._privateProperties.Schema[key]
		if def and def.Persist then
			self[key] = value
		end
	end
end
--[=[
	@description Implements `BaseEntity.UpdateEntity`.
	@param lockingCallerId string? -- `lockingCallerId` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:UpdateEntity(lockingCallerId: string?)
	local privateProperties = self._privateProperties
	local fastFailReason = ""
	local isLockContention = false
	if not privateProperties.IsValid then
		fastFailReason ..= "Attempt to call UpdateEntity on destroyed entity. "
	end
	if privateProperties.EntityLocked and privateProperties.EntityLocked ~= lockingCallerId then
		fastFailReason ..= "Attempt to call UpdateEntity without holding the lock. "
		isLockContention = true
	end
	-- Detect "no pending" via the explicit key set so that nil writes count as changes
	local hasPending = false
	if privateProperties._pendingKeys then
		hasPending = next(privateProperties._pendingKeys) ~= nil
	end
	if not hasPending then
		hasPending = next(privateProperties.Pending) ~= nil
	end
	if not hasPending then
		fastFailReason ..= "No pending changes to apply in UpdateEntity. "
	end
	if not privateProperties.Mutable then
		fastFailReason ..= "Attempt to call UpdateEntity on immutable entity. "
	end
	if fastFailReason ~= "" then
		-- Lock contention during combat is expected; log as WARN not ERROR
		local level = if isLockContention then "WARN" else "ERROR"
		self:Log({ Level = level, Message = "UpdateEntity failed: " .. fastFailReason })
		return false
	end

	-- Snapshot the pending-key set up front. UpdateEntity clears _pendingKeys
	-- during commit, so any post-commit consumers (changedKeys, history, etc.)
	-- must read from a stable copy.
	local pendingKeysSnapshot = {} :: { [string]: boolean }
	local changes: { [string]: any } = {}
	if privateProperties._pendingKeys then
		for k in pairs(privateProperties._pendingKeys) do
			pendingKeysSnapshot[k] = true
			changes[k] = privateProperties.Pending[k]
		end
	else
		changes = table.clone(privateProperties.Pending)
		for k in pairs(changes) do
			pendingKeysSnapshot[k] = true
		end
	end

	-- Build version history snapshot BEFORE committing (so From values reflect
	-- the prior state, not the about-to-be-committed values).
	local historySnapshot: { [string]: any }? = nil
	if privateProperties._versionHistory then
		historySnapshot = {}
		for k, v in pairs(changes) do
			(historySnapshot :: any)[k] = { From = privateProperties.Data[k], To = v }
		end
		-- Include nil-cleared keys explicitly
		if privateProperties._pendingKeys then
			for k in pairs(privateProperties._pendingKeys) do
				if changes[k] == nil and (historySnapshot :: any)[k] == nil then
					(historySnapshot :: any)[k] = { From = privateProperties.Data[k], To = nil }
				end
			end
		end
	end

	-- Commit changes to authoritative Data. Use the explicit key set so nil
	-- writes actually clear Data fields.
	for k in pairs(pendingKeysSnapshot) do
		privateProperties.Data[k] = privateProperties.Pending[k]
	end
	if privateProperties._pendingKeys then
		table.clear(privateProperties._pendingKeys)
	end
	table.clear(privateProperties.Pending)
	table.clear(privateProperties._cache)
	
	-- Increment Version
	privateProperties.Version += 1
	changes._v = privateProperties.Version

	-- Append to version history ring buffer (snapshot was built pre-commit)
	if privateProperties._versionHistory and historySnapshot then
		table.insert(privateProperties._versionHistory, {
			Version = privateProperties.Version,
			Time = os.clock(),
			Changes = historySnapshot,
		})
		while #privateProperties._versionHistory > (privateProperties._versionHistoryMax or 50) do
			table.remove(privateProperties._versionHistory, 1)
		end
	end

	-- Build changedKeys from the pre-commit snapshot so nil-clears survive and
	-- re-entrant writes made by StateUpdated listeners don't contaminate this diff.
	local changedKeys = {}
	for k in pairs(pendingKeysSnapshot) do
		table.insert(changedKeys, k)
	end
	privateProperties._stateUpdatedEvent:Fire(changes, changedKeys)

	-- Strip _v before passing to ApplyChanges so subclasses iterating
	-- `changes` don't see _v as a property to render.
	local visualChanges = table.clone(changes)
	visualChanges._v = nil

	-- Apply Changes (Visual/Instance updates)
	local success, err = xpcall(function()
		self:ApplyChanges(visualChanges)
	end, function(e) return debug.traceback(tostring(e)) end)
	if not success then
		self:Log({ Level = "ERROR", Message = string.format("ApplyChanges failed: %s", tostring(err)) })
	end
	return success
end
--[=[
	@description Implements `BaseEntity.ApplyChanges`.
	@param changes { [string]: any } -- `changes` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:ApplyChanges(changes: { [string]: any })
	self:Log
	{ 
		Level = "WARN", 
		Message = "Abstract Method 'ApplyChanges' called with changes: " .. tostring(changes) 
	}
	self:Log
	{ 
		Level = "WARN", 
		Message = "Subclasses must implement 'ApplyChanges' to handle property updates." 
	}
end
--[=[
	@description Implements `BaseEntity.Cleanup`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:Cleanup()
	-- Override in subclasses if needed
end
--[=[
	@description Returns the data produced by `BaseEntity.GetValidProperties`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:GetValidProperties()
	return self._privateProperties.Schema
end
--[=[
	@description Implements `BaseEntity.AcquireLock`.
	@param callerId string -- `callerId` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:AcquireLock(callerId: string)
	if not callerId then
		self:Log
		{ 
			Level = "ERROR", 
			Message = "AcquireLock called without callerId." 
		}
		return false
	end;

	if not self._privateProperties.EntityLocked then
		self._privateProperties.EntityLocked = callerId
		return true
	end
	return false
end
--[=[
	@description Implements `BaseEntity.ReleaseLock`.
	@param callerId string -- `callerId` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:ReleaseLock(callerId: string)
	if self._privateProperties.EntityLocked then
		if self._privateProperties.EntityLocked ~= callerId then
			self:Log
			{ 
				Level = "ERROR", 
				Message = "ReleaseLock called by non-owner." 
			}
			return false
		end

		self._privateProperties.EntityLocked = nil
		return true
	end
	return false
end
--[=[
	@description Implements `BaseEntity.Destroy`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function BaseEntity:Destroy()
	local privateProperties = self._privateProperties
	if not privateProperties.IsValid then return end

	-- Automated Bubbling: Run every 'Cleanup' method in the class hierarchy
	local currentClass = privateProperties._class
	while currentClass do
		local cleanupHook = rawget(currentClass, "Cleanup")
		if type(cleanupHook) == "function" then
			table.insert(privateProperties._cleanupTasks, cleanupHook)
		end
		-- Move up to the next class in the hierarchy
		local parentMeta = getmetatable(currentClass :: any)
		if type(parentMeta) == "table" and type(parentMeta.__index) == "table" then
			currentClass = parentMeta.__index
		else
			currentClass = nil
		end
	end

	for _, cleanupTask in ipairs(privateProperties._cleanupTasks) do
		local ok, err = pcall(function()
			if typeof(cleanupTask) == "Instance" then cleanupTask:Destroy()
			elseif typeof(cleanupTask) == "RBXScriptConnection" then cleanupTask:Disconnect()
			elseif type(cleanupTask) == "function" then cleanupTask(self)
			elseif type(cleanupTask) == "table" and cleanupTask.Destroy then cleanupTask:Destroy(self)
			end
		end)
		if not ok then
			privateProperties._logger:Log({ Level = "ERROR", Message = "Cleanup task failed: " .. tostring(err) })
		end
	end
	privateProperties._cleanupTasks = {}
	privateProperties.IsValid = false
	if privateProperties._pendingKeys then table.clear(privateProperties._pendingKeys) end
	table.clear(privateProperties.Pending)
	table.clear(privateProperties._cache)

	privateProperties._entityDestroyedEvent:Fire()
	task.defer(function()
		if privateProperties._entityDestroyedEvent then privateProperties._entityDestroyedEvent:Destroy() end
		if privateProperties._stateUpdatedEvent then privateProperties._stateUpdatedEvent:Destroy() end
	end)
end

return BaseEntity