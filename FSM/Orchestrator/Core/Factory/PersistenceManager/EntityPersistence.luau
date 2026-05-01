--!strict
--[=[
	@Name EntityPersistence
	@Author iKrypto
	@Description Persistence helper for saving/loading BaseEntity state to DataStore.
	Creates controller instances bound to a specific DataStore name and key prefix.
	Payloads are JSON-encoded with version stamps and metadata. Uses the
	DataStoreEntity facade for actual DataStore operations.

	@usage
	local persistence = EntityPersistence.new({
		DataStoreName = "EntitySaveData",
		KeyPrefix = "Door",
		DataStoreReference = dataStoreEntity,
	})
	persistence:Save(entity, "123")
	persistence:Load(entity, "123")
]=]

local HttpService = game:GetService("HttpService")

local EntityPersistence = {}
local Logger, Initialized = nil, false

local function ValidateRequest(config)
	assert(Initialized, "EntityPersistence not initialized")
	assert(Logger, "EntityPersistence not initialized")
	assert(config and config.DataStoreName, "EntityPersistence.new requires DataStoreName")
	assert(config and config.DataStoreReference, "EntityPersistence.new requires DataStoreReference")
end

--[=[
	@description Constructs a composite DataStore key from an optional prefix
	and the raw key, separated by a colon.

	@param prefix string? -- Optional key prefix (e.g. "Door")
	@param key string -- Raw entity key
	@return string -- Formatted key (e.g. "Door:123" or just "123")
	@reads None
	@writes None
]=]
local function makeKey(prefix: string?, key: string): string
	if prefix and prefix ~= "" then
		return prefix .. ":" .. key
	end
	return key
end

--[=[
	@description Encodes entity data and optional metadata into a versioned JSON
	payload for DataStore storage.

	@param data { [string]: any } -- Serialized entity data
	@param meta { [string]: any }? -- Optional metadata
	@return string -- JSON-encoded payload
	@reads None
	@writes None
]=]
local function encodePayload(data: { [string]: any }, meta: { [string]: any }?)
	return HttpService:JSONEncode({
		version = 1,
		updatedAt = os.time(),
		data = data,
		meta = meta or {},
	})
end

--[=[
	@description Decodes a stored JSON payload (or raw table) back into data
	and optional metadata. Handles both legacy raw tables and versioned payloads.

	@param raw any -- JSON string or raw table from DataStore
	@return { [string]: any } -- Decoded data
	@return { [string]: any }? -- Decoded metadata (nil for legacy format)
	@reads None
	@writes None
]=]
local function decodePayload(raw: any): ({ [string]: any }, { [string]: any }?)
	if type(raw) == "table" then
		return raw, nil
	end
	local decoded = HttpService:JSONDecode(raw)
	if decoded.data ~= nil then
		return decoded.data, decoded.meta
	end
	return decoded, nil
end

--[=[
	@description Initializes the EntityPersistence module with shared utilities.
	Must be called once before any controllers are created.

	@param Util table -- Orchestrator utility table containing Logger
	@return ()
	@writes Module-level Logger upvalue
]=]
function EntityPersistence.Initialize(Util)
	if Initialized then return end
    Initialized = true
    Logger = Util.Logger.new({ Name = "EntityPersistence" })

	Logger:Log({ Level = "INFO", Message = "EntityPersistence initialized" })
end


--[=[
	@description Creates a new EntityPersistence controller bound to a specific
	DataStore configuration. The controller provides Save, Load, Update, and
	Delete operations for entity state.

	@param config PersistenceConfig
		- DataStoreName: string -- DataStore name
		- KeyPrefix: string? -- Optional prefix for all keys
		- DataStoreReference: any -- DataStoreEntity facade instance
	@return EntityPersistence -- Controller with Save/Load/Update/Delete methods
	@reads config
	@writes None
]=]
function EntityPersistence.new(config: PersistenceConfig): EntityPersistence
	ValidateRequest(config)

	local DataStore = config.DataStoreReference


	local controller: EntityPersistence = {} :: any

    --[=[
        @description Saves the entity's serialized data to the DataStore under
        the given key. Calls entity:Serialize() to collect persistent fields,
        then encodes and stores the payload.

        @param entity any -- Entity instance (must implement Serialize)
        @param key string -- DataStore key
        @param metadata { [string]: any }? -- Optional metadata to store alongside data
        @return boolean -- True on success
        @return string? -- Error code on failure
        @reads entity:Serialize()
        @writes DataStore (via SetAsync)
    ]=]
	function controller:Save(entity: any, key: string, metadata: { [string]: any }?)
		if not entity or type(entity.Serialize) ~= "function" then
			return false, "EntityMissingSerialize"
		end

		local data = entity:Serialize()
		local ok, payloadOrErr = pcall(function()
			return encodePayload(data, metadata)
		end)
		if not ok then
			return false, "SerializeFailed"
		end

		-- BUG FIX: `DataStore:SetAsync(...)` returns a version string (or nil/error),
		-- never `true`. The previous `== true` check made every save report
		-- failure even on success. Use pcall + check the call itself.
		if not DataStore.SetAsync then return false, "DatastoreFail" end
		local writeOk, writeErr = pcall(function()
			DataStore:SetAsync(config.DataStoreName, makeKey(config.KeyPrefix, key), payloadOrErr)
		end)
		if not writeOk then
			Logger:Log({ Level = "ERROR", Message = string.format("Save failed for key '%s': %s", key, tostring(writeErr)) })
			return false, "DatastoreFail"
		end
		Logger:Log({ Level = "INFO", Message = string.format("Saved persistent state for Entity with key '%s'", key) })
		return true, nil
	end

    --[=[
        @description Loads the entity's data from the DataStore under the given
        key and deserializes it into the entity instance.

        @param entity any -- Entity instance (must implement Deserialize)
        @param key string -- DataStore key
        @return boolean -- True on success (even if no data exists)
        @return { [string]: any }? -- Loaded data, or nil if key was empty
        @return string? -- Error message on decode failure
        @reads DataStore (via GetAsync)
        @writes entity (via Deserialize)
    ]=]
	function controller:Load(entity: any, key: string)
		local readOk, raw = pcall(function()
			return DataStore:GetAsync(config.DataStoreName, makeKey(config.KeyPrefix, key))
		end)
		if not readOk then
			Logger:Log({ Level = "ERROR", Message = string.format("Load failed for key '%s': %s", key, tostring(raw)) })
			return false, nil, "DatastoreFail"
		end
		if raw == nil then
			return true, nil, nil
		end

		local decodeOk, data, _meta = pcall(function()
			return decodePayload(raw)
		end)
		if not decodeOk then
			return false, nil, "DecodeFailed: " .. tostring(data)
		end
		if entity and type(entity.Deserialize) == "function" then
			entity:Deserialize(data)
		end
		Logger:Log({ Level = "INFO", Message = string.format("Restored persistent state for Entity with key '%s'", key) })
		return true, data, nil
	end

    --[=[
        @description Atomically updates data in the DataStore using a mutate function.
        The mutate function receives the current data and returns the updated data.

        @param key string -- DataStore key
        @param mutateFn (data: { [string]: any }) -> { [string]: any } -- Transform function
        @return boolean -- True on success
        @return string? -- Error code on failure
        @reads DataStore (via UpdateAsync)
        @writes DataStore (via UpdateAsync)
    ]=]
	function controller:Update(key: string, mutateFn: (data: { [string]: any }) -> { [string]: any })
		-- UpdateAsync in Facade
		local ok, result = pcall(function()
			return DataStore:UpdateAsync(config.DataStoreName, makeKey(config.KeyPrefix, key), function(old)
				local current: { [string]: any } = {}
				local meta: { [string]: any } = {}
				if old ~= nil then
					local decodeOk, decodedData, decodedMeta = pcall(function()
						return decodePayload(old)
					end)
					if decodeOk then
						current = decodedData
						meta = decodedMeta or {}
					end
				end

				local nextData = mutateFn and mutateFn(current) or current
				return encodePayload(nextData, meta)
			end)
		end)
		if not ok then
			Logger:Log({ Level = "ERROR", Message = string.format("Update failed for key '%s': %s", key, tostring(result)) })
			return false, "DatastoreFail"
		end
		
		if result == nil then
			return false, "DatastoreFail"
		end
		return true, nil
	end

    --[=[
        @description Deletes the entity's data from the DataStore under the given key.

        @param key string -- DataStore key to remove
        @return boolean -- Always true (fire-and-forget)
        @return string? -- Always nil
        @reads None
        @writes DataStore (via RemoveAsync)
    ]=]
	function controller:Delete(key: string)
		if not DataStore.RemoveAsync then return false, "DatastoreFail" end
		local ok, err = pcall(function()
			DataStore:RemoveAsync(config.DataStoreName, makeKey(config.KeyPrefix, key))
		end)
		if not ok then
			Logger:Log({ Level = "ERROR", Message = string.format("Delete failed for key '%s': %s", key, tostring(err)) })
			return false, "DatastoreFail"
		end

		Logger:Log({ Level = "INFO", Message = string.format("Deleted persistent state for Entity with key '%s'", key) })
		return true, nil
	end

	Logger:Log({ Level = "INFO", Message = string.format("EntityPersistence controller created for DataStore '%s'", config.DataStoreName) })
	return controller
end

return EntityPersistence