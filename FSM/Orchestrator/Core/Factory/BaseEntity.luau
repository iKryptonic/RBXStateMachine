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
	return string.format("BaseEntity(%s) %s : [%s]", self.OwnerId or "-id-", self.entityName or "-name-", ((self.IsValid == true and "Valid") or (self.IsValid == false and "Invalid")) or "-state-")
end

local Logger, Signal, _Settings, Initialized;


--[=[
	Bootstraps BaseEntity with shared framework utilities. Must be called before
	any entity instances are created. Subsequent calls are no-ops.
	Stores Logger, Signal, and Settings module-locally for use by all
	subsequent `new()` calls.

	@param Util table -- Shared Orchestrator utilities; must contain `Util.Logger.new`,
	       `Util.Signal`, and `Util.Settings`.
	@reads Initialized
	@writes Logger, Signal, _Settings, Initialized
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
	Constructs a raw proxy-based entity instance. This is the low-level
	constructor; most code should use the subclass constructor from
	`BaseEntity.Extend().new()` instead.

	Creates a `privateProperties` closure holding the entity's authoritative
	`Data`, staged `Pending` writes, `Schema`, `Context`, versioning state,
	cleanup task list, and the two lifecycle signals (`StateUpdated`,
	`Destroyed`). Returns a proxy table whose `__index`/`__newindex`
	metamethods route reads through the cache → Data → Context → class →
	BaseEntity resolution chain, and route writes through schema validation
	into `Pending`.

	@param params { Name: string, OwnerId: string?, Context: { [any]: any }? } --
	       Construction parameters. `Name` becomes the logger label; `OwnerId`
	       identifies the owning player/object; `Context` seeds the context bag.
	@param class any? -- The compiled subclass table (from `BaseEntity.Extend`).
	       Used to fetch the Schema and to walk the cleanup hierarchy in `Destroy`.
	@return any -- Proxy entity instance with `.StateUpdated`, `.Destroyed`,
	       `._privateProperties`, and all BaseEntity methods accessible.
	@reads Logger, Signal, Initialized
	@writes None (returns new table per call)
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
	Creates and returns a new entity subclass. `extensionParams` is stored as
	`Subclass.Definition` and used by `BaseEntity.new` to derive the Schema,
	Mutable flag, and class name. The returned Subclass inherits all BaseEntity
	methods via metatable and exposes a `.new(params)` constructor that calls
	`GetContext` to seed instance-specific context after `InitialData` is
	pre-populated.

	@param extensionParams { Name: string, Schema: { [string]: any }?, Mutable: boolean? } --
	       Class definition. `Schema` maps field names to `{ Type, Default, Persist, Replicate }`
	       descriptors. `Mutable` must be `true` for `UpdateEntity` to accept writes.
	@return table -- Subclass table with `.new`, `.Definition`, and inherited BaseEntity methods.
	@reads None
	@writes None (returns a new table per call)
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
		Constructs a fully initialized instance of this entity subclass.
		Calls the base `BaseEntity.new`, pre-populates `Data` from any
		`params.InitialData` (used for client-side entity sync), then invokes
		the subclass `GetContext` hook to seed instance-specific context fields.
		`Super` and `super` references are also attached to the subclass for use
		in method overrides.

		@param params any -- Constructor parameters forwarded to `BaseEntity.new`;
		       may additionally carry `InitialData: { [string]: any }` for replication
		       bootstrapping.
		@return any -- Fully initialized entity proxy.
		@reads SubclassAny.GetContext
		@writes proxy Context (via SetContext), proxy Data (InitialData pre-population)
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
	Forwards a log entry to the instance-level Logger with the entity's
	`OwnerId` as the `OperationId`. Falls back to `print` if the Logger has
	not been initialized (e.g. during tests without `BaseEntity.Initialize`).

	@param params { Level: string, Message: string } -- Log level ("INFO", "WARN", "ERROR", "DEBUG") and message text.
	@reads self._logger
	@writes Logger output
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
	Replaces the entity's active Schema with the supplied table. Useful when
	a schema must be constructed dynamically after instantiation rather than
	declared statically in the `Extend` definition.

	@param schema { [string]: any } -- New schema map; keys are property names and values
	       are descriptor tables with at minimum `{ Type: string }`.
	@reads None
	@writes self._privateProperties.Schema
]=]
function BaseEntity:DefineSchema(schema: { [string]: any })
	self._privateProperties.Schema = schema
end
--[=[
	Writes an arbitrary key/value pair into the entity's Context bag. Context
	values are visible through the proxy `__index` resolution chain (after
	Data and the write-cache) and are used for non-schema state such as
	entity references, lifecycle flags, and persistence metadata.

	@param key any -- Context key.
	@param value any -- Value to store; may be any type.
	@reads None
	@writes self._privateProperties.Context[key]
]=]
function BaseEntity:SetContext(key: any, value: any)
	self._privateProperties.Context[key] = value
end


--[=[
	Registers `object` for automatic cleanup when `Destroy` is called. Supports
	Roblox `Instance` (`:Destroy()`), `RBXScriptConnection` (`:Disconnect()`),
	plain functions (called as `fn(self)`), and tables with a `.Destroy` method.

	@param object any -- Resource to track; must be one of the supported cleanup types.
	@return any -- Returns `object` unchanged for chaining (`local conn = entity:Manage(signal:Connect(...))`).
	@reads None
	@writes self._privateProperties._cleanupTasks (appends)
]=]
function BaseEntity:Manage(object: any)
	table.insert(self._privateProperties._cleanupTasks, object)
	return object
end


--[=[
	Returns a flat table of all schema fields that have `Persist = true`,
	reading each from the proxy (Data → Context → schema Default resolution
	chain). Used by `EntityPersistence:Save` to build a DataStore payload.
	Fields set to `nil` are omitted from the output.

	@return { [string]: any } -- Serialized persistent property values.
	@reads self._privateProperties.Schema, self._privateProperties.Data
	@writes None
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
	Applies `data` (typically from a DataStore load) back onto the entity by
	routing each key through `__newindex` for schema validation. Only fields
	present in the Schema and flagged `Persist = true` are applied; unknown
	or non-persistent keys are ignored.

	@param data { [string]: any } -- Flat table of property values to restore.
	@reads self._privateProperties.Schema
	@writes self (via __newindex → Pending → _pendingKeys)
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
	Atomically commits all pending writes from `Pending`/`_pendingKeys` into
	`Data`, increments `Version`, appends a ring-buffer history entry, fires
	`StateUpdated(changes, changedKeys)`, and calls `ApplyChanges(visualChanges)`.
	Fails fast (returns false, logs) if: the entity is destroyed, a lock is held
	by a different caller, there are no pending writes, or the entity is
	immutable. Nil writes are supported via the explicit `_pendingKeys` set.

	@param lockingCallerId string? -- Id that must match `EntityLocked` when a lock is held.
	       Pass the same id used in `AcquireLock`; omit when the entity is not locked.
	@return boolean -- `true` on successful commit, `false` on any fast-fail condition.
	@reads privateProperties.IsValid, EntityLocked, Mutable, Pending, _pendingKeys
	@writes privateProperties.Data, Pending, _pendingKeys, _cache, Version, _versionHistory
	@fires StateUpdated, then ApplyChanges
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
		local level = if isLockContention then"WARN" else"ERROR"
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
	Abstract hook called by `UpdateEntity` with the committed changes after
	each successful commit. Subclasses override this to apply visual or
	instance-level updates (e.g. updating a Part's color when `Color` changes).
	The base implementation logs a WARN to remind implementers to override it.
	The `_v` version key is stripped from `changes` before this is called.

	@param changes { [string]: any } -- Map of committed property names to their new values.
	@reads None
	@writes Nothing (base implementation is a no-op stub)
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
	Virtual lifecycle hook invoked automatically during `Destroy` after all
	cleanup tasks have been run. Subclasses override this to perform any
	custom teardown logic (disconnecting external signals, cancelling coroutines,
	etc.). The base implementation is intentionally empty.

	@reads None
	@writes Nothing (base implementation is a no-op stub)
]=]
function BaseEntity:Cleanup()
	-- Override in subclasses if needed
end


--[=[
	Returns the entity's Schema table (a reference, not a clone). Used by
	replication code and persistence to enumerate valid property definitions
	without going through the proxy resolution chain.

	@return { [string]: any } -- Schema descriptor table as set during construction or via DefineSchema.
	@reads self._privateProperties.Schema
	@writes None
]=]
function BaseEntity:GetValidProperties()
	return self._privateProperties.Schema
end


--[=[
	Acquires an exclusive write lock on the entity using `callerId` as the
	owner token. While locked, `UpdateEntity` rejects calls from any other
	caller id. Logs ERROR and returns false if `callerId` is nil. Returns
	false (without logging) if the lock is already held by someone else.

	@param callerId string -- Unique caller identifier that will own the lock.
	@return boolean -- `true` if the lock was successfully acquired, `false` otherwise.
	@reads self._privateProperties.EntityLocked
	@writes self._privateProperties.EntityLocked
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
	Releases a previously acquired lock. Only the caller that holds the lock
	(matched by `callerId`) can release it. Logs ERROR and returns false if
	the wrong caller attempts to release. Returns false silently if no lock
	is currently held.

	@param callerId string -- Must match the id used in `AcquireLock`.
	@return boolean -- `true` if the lock was released, `false` otherwise.
	@reads self._privateProperties.EntityLocked
	@writes self._privateProperties.EntityLocked = nil
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
	Permanently destroys the entity. Traverses the subclass hierarchy to
	collect all `Cleanup` overrides, appends them to the cleanup-task list,
	then runs every task in order (Instances, Connections, functions, tables
	with `.Destroy`). Finally sets `IsValid = false`, clears all pending/cache
	tables, fires `Destroyed`, and defers the destruction of both lifecycle
	signals. Idempotent: subsequent calls on an already-destroyed entity
	are silently ignored via the `IsValid` guard.

	@reads self._privateProperties.IsValid, _class (for cleanup traversal)
	@writes privateProperties.IsValid = false, Pending, _pendingKeys, _cache cleared
	@fires Destroyed (immediately); signals destroyed deferred
]=]
function BaseEntity:Destroy()
	local privateProperties = self._privateProperties
	if not privateProperties.IsValid then return end

	-- Automated Bubbling: Run every 'Cleanup' method in the class hierarchy
	local currentClass = privateProperties._class
	while currentClass do
		local cleanupHook = rawget(currentClass,"Cleanup")
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
