--!strict
--[=[
	@Name Core/PersistenceManager.luau
	@Author iKrypto
	@Description Manages the lifecycle of entity data persistence.
	Provides a server-side facade over EntityPersistence, with lazy-loaded
	DataStoreSystem resolution and convenience LoadState/SaveState methods.
	Only operational on the server when persistence is enabled in Settings.
]=]

local RunService = game:GetService("RunService")
local EntityPersistence = require(script.EntityPersistence)
local Initialized = false

local PersistenceManager = {
	Controller = nil :: any, -- EntityPersistence instance
	_logger = nil :: any,
	_settings = nil :: any,
	_core = nil :: any,
}

--[=[
	Bootstraps PersistenceManager for server-side use. Initialises the
	EntityPersistence sub-module, stores the Util reference for lazy
	controller construction, and captures Logger and Settings. The actual
	EntityPersistence controller is NOT created here; it is created on first
	use by `GetController` to avoid a dependency cycle with DataStoreSystem.
	No-ops on the client or after the first successful call.

	@param Util table -- Shared Orchestrator utilities (Logger, Settings, Factory).
	@reads Initialized, RunService:IsServer()
	@writes PersistenceManager._core, PersistenceManager._settings,
	        PersistenceManager._logger, Initialized
]=]
function PersistenceManager.Initialize(Util)
	if not RunService:IsServer() then
		return
	end
	if Initialized then
		return
	end
	Initialized = true
	EntityPersistence.Initialize(Util)

	PersistenceManager._core = Util
	PersistenceManager._settings = Util.Settings
	PersistenceManager._logger = Util.Logger.new({ Name = "PersistenceManager" })

	-- Controller is lazy loaded to avoid dependency cycles with DataStoreSystem
end

--[=[
	@description Lazy-loads the EntityPersistence controller by resolving the
	DataStoreSystem entity from the Registry. Returns nil if the DataStoreSystem
	is not yet registered (persistence disabled).

	@return any? -- EntityPersistence controller, or nil
	@reads PersistenceManager._core, Registry
	@writes PersistenceManager.Controller
]=]
local function GetController()
	if PersistenceManager.Controller then
		return PersistenceManager.Controller
	end
	if not PersistenceManager._core then
		return nil
	end

	-- Lazy load DataStoreSystem
	local DataStoreSystem = PersistenceManager._core.Factory.Registry.GetEntity("DataStoreSystem")
	if not DataStoreSystem then
		-- Only warn if we actually try to use it and it's missing (it might just be loading if we are super early, but we are lazy loading so it should be fine)
		-- Actually, if this is called, we expect it to exist.
		PersistenceManager._logger:Log({ Level = "WARN", Message = "DataStoreSystem not found. Persistence disabled." })
		return nil
	end

	PersistenceManager.Controller = EntityPersistence.new({
		DataStoreName = PersistenceManager._settings.DataStore.DataStoreName,
		KeyPrefix = PersistenceManager._settings.DataStore.KeyPrefix,
		DataStoreReference = DataStoreSystem,
	})

	return PersistenceManager.Controller
end

local function ValidateRequest()
	assert(Initialized, "PersistenceManager not initialized")
	assert(RunService:IsServer(), "PersistenceManager can only be used on the server")
	assert(PersistenceManager._settings.DataStore.PersistenceEnabled, "Persistence is disabled")
end

--[=[
	Loads persisted entity state from the DataStore and applies it via
	`entity:Deserialize`. Also marks the entity as persistent by writing
	`_PersistenceKey` and `_IsPersistent` into its Context so that
	subsequent `UpdateEntity` triggers can call `SaveState` automatically.
	Silently no-ops when the controller is unavailable (DataStoreSystem not
	yet registered) or when validation fails (client, persistence disabled).

	@param entity any -- Entity instance to load into; must implement `Deserialize`.
	@param key string -- DataStore key (usually EntityId or a custom prefix key).
	@reads PersistenceManager._core, PersistenceManager._settings, Initialized
	@writes entity Context._PersistenceKey, entity Context._IsPersistent
]=]
function PersistenceManager.LoadState(entity: any, key: string)
	ValidateRequest()

	local controller = GetController()
	if not controller then
		return
	end

	-- Mark entity as persistent
	if type(entity.SetContext) == "function" then
		entity:SetContext("_PersistenceKey", key)
		entity:SetContext("_IsPersistent", true)
	end

	local success, data, err = controller:Load(entity, key)
	if success and data then
		PersistenceManager._logger:Log({ Level = "INFO", Message = string.format("Restored state for key '%s'", key) })
	elseif not success then
		PersistenceManager._logger:Log({
			Level = "ERROR",
			Message = string.format("Failed to load state for key '%s': %s", key, tostring(err)),
		})
	end
end

--[=[
	Serialises entity state and writes it to the DataStore. Only operates when
	`entity._privateProperties.Context._IsPersistent` is true (set by
	`LoadState`). Derives the DataStore key from `_PersistenceKey` falling back
	to `Context.EntityId`. Silently no-ops when the controller is unavailable
	or validation fails.

	@param entity any -- Entity instance to save; must implement `Serialize`.
	@reads entity._privateProperties.Context._IsPersistent,
	       entity._privateProperties.Context._PersistenceKey,
	       entity._privateProperties.Context.EntityId
	@writes DataStore (via EntityPersistence.Save)
]=]
function PersistenceManager.SaveState(entity: any)
	ValidateRequest()

	local controller = GetController()
	if not controller then
		return
	end

	-- Check if persistent
	local context = (entity._privateProperties and entity._privateProperties.Context) or {}
	if not context._IsPersistent then
		return
	end

	local key = context._PersistenceKey or context.EntityId
	if not key then
		return
	end

	local ok, err = controller:Save(entity, key)
	if not ok then
		PersistenceManager._logger:Log({
			Level = "ERROR",
			Message = string.format("Failed to save state for key '%s': %s", key, tostring(err)),
		})
	end
end

return PersistenceManager
