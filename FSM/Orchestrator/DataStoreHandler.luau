--!strict
--[[
	@FileName:	DataStoreHandler
	@Author: 	jebjordan / iKrypto
	@Date: 		7/22/2018
	@Engine: 	Luau (Updated from Lua 5.1)
	@Notes:
	
	@Changelog:
		7/22/18 - Started Script
		7/22/18 - Finished (for now / until needed)?
		2/2/26  - Refactor: typed results + optional built-in retry; modernize task.wait/os.clock
]]
local Types = require(script.Parent.Types);

local lib: Types.DataStoreHandler = {} :: any;

local DataStoreService = game:GetService("DataStoreService")
local DSS = DataStoreService;
local RunService = game:GetService("RunService")

local function now()
	return os.clock()
end

type RetryConfig = Types.RetryConfig

local DEFAULT_RETRY: RetryConfig = {
	enabled = false,
	retries = 5,
	baseDelay = 0.75,
	jitter = 0.5,
}

--[[
	-- @Description: Normalizes a retry configuration.
	-- @param config: The retry configuration to normalize.
	-- @return: The normalized retry configuration.
]]
local function normalizeRetryConfig(config: RetryConfig?): RetryConfig
	local c = config or {}
	return {
		enabled = if c.enabled ~= nil then c.enabled else DEFAULT_RETRY.enabled,
		retries = if c.retries ~= nil then c.retries else DEFAULT_RETRY.retries,
		baseDelay = if c.baseDelay ~= nil then c.baseDelay else DEFAULT_RETRY.baseDelay,
		jitter = if c.jitter ~= nil then c.jitter else DEFAULT_RETRY.jitter,
	}
end

--[[
	-- @Description: Retries a function call with a configurable retry configuration.
	-- @param retryConfig: The retry configuration.
	-- @param fn: The function to retry.
	-- @return: A tuple containing a boolean indicating success, the result of the function, and an error message.
]]
local function retryCall(retryConfig: RetryConfig, fn: () -> any)
	local cfg = normalizeRetryConfig(retryConfig)
	local tries = 0
	local lastErr
	local maxTries = math.max(1, cfg.retries or 1)

	repeat
		tries += 1
		local ok, result = pcall(fn)
		if ok then
			return true, result, nil
		end
		lastErr = result
		warn(("[DataStoreHandler] - Datastore failure '%s'. Retrying! (%d/%d)"):format(tostring(lastErr), tries, maxTries))
		if tries < maxTries and not RunService:IsStudio() then
			local base = cfg.baseDelay or DEFAULT_RETRY.baseDelay
			local jit = cfg.jitter or DEFAULT_RETRY.jitter
			task.wait(base + jit * math.random())
		end
	until tries >= maxTries

	warn("[DataStoreHandler] - Datastore completely failed. No more recovery attempts.")
	return false, nil, tostring(lastErr)
end

local keyWait = 7; -- only for non-get requests
local DBAccess: {[string]: {number}} = { -- not really used for anything atm, but will be set anyways for info / incase needed later.
	Get = {0, 60}; -- max: 60 + numPlayers * 10 -- will all be set to min value though.
	Set = {0, 60}; -- max: 60 + numPlayers * 10 -- ^
	Sorted = {0, 5}; -- max: 5 + numPlayers * 2 -- ^
};

local databaseCache: {[string]: any} = {
	--[[
		['pizza'] = { -- EXAMPLE TABLE
			keyUsage = {
				a = lastSetTime
				b = lastSetTime
				
			};
		};
	--]]
};

--[[
	-- @Description: Checks if a key is allowed to be updated.
	-- @param databaseName: The name of the database.
	-- @param key: The key to check.
	-- @return: A boolean indicating whether the key is allowed to be updated.
]]
local function checkAllowedToUpdateKey(databaseName: string, key: string)
	local cacheEntry = databaseCache[databaseName]
	if not cacheEntry then
		return true
	end
	cacheEntry.keySetting = cacheEntry.keySetting or {}

	local thisTick = now();
	local lastUsage = cacheEntry.keySetting[key] or 0;
	if thisTick - lastUsage >= keyWait then
		cacheEntry.keySetting[key] = thisTick;
		return true; -- been not used recently, safe to attempt update
	else
		return false; -- has been used recently, unsafe to attempt update
	end;

end;

--[[
	-- @Description: Resets the access count for each data store.
	-- @return: None
]]
function lib.ResetAccessCount()
	for i,v in pairs(DBAccess) do
		DBAccess[i][1] = 0;
	end;
end;

--[[
	-- @Description: Gets a data store.
	-- @param databaseName: The name of the database.
	-- @param scope: The scope of the data store.
	-- @param orderedBool: Whether the data store is ordered.
	-- @return: The data store.
]]
function lib.get(databaseName: string, scope: string?, orderedBool: boolean?): Types.DataStore
	local ds;
	if databaseCache[databaseName] then
		return databaseCache[databaseName];
	else
		if not orderedBool then
			ds = DSS:GetDataStore(databaseName, scope);
		else
			ds = DSS:GetOrderedDataStore(databaseName, scope);
		end;

		local DB: any = {};

		DB.CachingTime = 0;
		DB.RetryConfig = normalizeRetryConfig(nil)

		--[[
			-- @Description: Sets the retry configuration.
			-- @param config: The retry configuration.
		]]
		function DB:SetRetryConfig(config: RetryConfig?)
			DB.RetryConfig = normalizeRetryConfig(config)
		end

		--[[
			-- @Description: Enables or disables retries.
			-- @param enabled: Whether to enable retries.
		]]
		function DB:EnableRetry(enabled: boolean)
			DB.RetryConfig = normalizeRetryConfig({
				enabled = enabled,
			})
		end

		--[[
			-- @Description: Calls a function with retry logic.
			-- @param fn: The function to call.
			-- @return: A tuple containing a boolean indicating success, the result of the function, and an error message.
		]]
		function DB:_call(fn: () -> any)
			if DB.RetryConfig and DB.RetryConfig.enabled then
				return retryCall(DB.RetryConfig, fn)
			end
			local ok, result = pcall(fn)
			if ok then
				return true, result, nil
			end
			return false, nil, tostring(result)
		end

		--[[
			-- @Description: Gets a value from the data store.
			-- @param Key: The key of the value to get.
			-- @return: A tuple containing a boolean indicating success, the value, and an error message.
		]]
		function DB:GetAsync(Key: string)
			if (self.CachingTime or 0) > 0 then
				local entry = databaseCache[DB.DBName]
				local cached = entry and entry.Cache and entry.Cache[Key]
				if cached and (now() - (cached.lastGet or 0)) <= DB.CachingTime then
					return true, cached.Cache, nil
				end;
			end;

			DBAccess['Get'][1] = DBAccess['Get'][1] + 1;
			local ok, val, err = DB:_call(function()
				return DB.DBRef:GetAsync(Key)
			end)
			if ok then
				databaseCache[DB.DBName].Cache[Key] = {
					lastGet = now();
					Cache = val;
				};
			end
			return ok, val, err
		end;

		--[[
			-- @Description: Increments a value in the data store.
			-- @param Key: The key of the value to increment.
			-- @param delta: The amount to increment the value by.
			-- @return: A tuple containing a boolean indicating success, the result of the increment, and an error message.
		]]
		function DB:IncrementAsync(Key: string, delta: number)
			local canUpdate = checkAllowedToUpdateKey(DB.DBName, Key);
			if not canUpdate then
				return false, nil, "Throttled"
			end
			DBAccess['Set'][1] = DBAccess['Set'][1] + 1;
			local ok, result, err = DB:_call(function()
				return DB.DBRef:IncrementAsync(Key, delta)
			end)
			if ok then
				databaseCache[DB.DBName].Cache[Key] = {
					lastGet = now();
					Cache = result;
				};
			end
			return ok, result, err
		end;

		--[[
			-- @Description: Removes a value from the data store.
			-- @param Key: The key of the value to remove.
			-- @return: A tuple containing a boolean indicating success, the result of the removal, and an error message.
		]]
		function DB:RemoveAsync(Key: string)
			local canUpdate = checkAllowedToUpdateKey(DB.DBName, Key);
			if not canUpdate then
				return false, nil, "Throttled"
			end
			DBAccess['Set'][1] = DBAccess['Set'][1] + 1;
			local ok, result, err = DB:_call(function()
				return DB.DBRef:RemoveAsync(Key)
			end)
			if ok then
				databaseCache[DB.DBName].Cache[Key] = nil;
			end
			return ok, result, err
		end;

		--[[
			-- @Description: Sets a value in the data store.
			-- @param Key: The key of the value to set.
			-- @param value: The value to set.
			-- @return: A tuple containing a boolean indicating success, the result of the set, and an error message.
		]]
		function DB:SetAsync(Key: string, value: any)
			local canUpdate = checkAllowedToUpdateKey(DB.DBName, Key);
			if not canUpdate then
				return false, nil, "Throttled"
			end
			DBAccess['Set'][1] = DBAccess['Set'][1] + 1;
			local ok, _, err = DB:_call(function()
				DB.DBRef:SetAsync(Key, value)
				return true
			end)
			if ok then
				databaseCache[DB.DBName].Cache[Key] = {
					lastGet = now();
					Cache = value;
				};
			end
			return ok, nil, err
		end;

		--[[
			-- @Description: Updates a value in the data store.
			-- @param Key: The key of the value to update.
			-- @param transformFunction: The function to transform the value.
			-- @return: A tuple containing a boolean indicating success, the result of the update, and an error message.
		]]
		function DB:UpdateAsync(Key: string, transformFunction: (any) -> any)
			local canUpdate = checkAllowedToUpdateKey(DB.DBName, Key);
			if not canUpdate then
				return false, nil, "Throttled"
			end
			DBAccess['Set'][1] = DBAccess['Set'][1] + 1;
			local ok, result, err = DB:_call(function()
				return DB.DBRef:UpdateAsync(Key, transformFunction)
			end)
			if ok and result ~= nil then
				databaseCache[DB.DBName].Cache[Key] = {
					lastGet = now();
					Cache = result;
				};
			end
			return ok, result, err
		end;
		
		--[[
			-- @Description: Sets the caching time for the data store.
			-- @param TimeInSeconds: The time in seconds to cache the data store.
		]]
		function DB:SetCachingTime(TimeInSeconds: number) -- for caching things, if not set or 0 then it will always get straight from the DB
			if TimeInSeconds and TimeInSeconds>=0 then
				DB.CachingTime = TimeInSeconds;
			end;
		end;

		--[[
			-- @Description: Gets the name of the data store.
			-- @return: The name of the data store.
		]]
		function DB:GetDBName()
			return DB.DBName;
		end;
		if orderedBool then
			function DB:GetSortedAsync(ascending: boolean, pagesize: number, minValue: number?, maxValue: number?)
				DBAccess['Get'][1] = DBAccess['Get'][1] + 1;
				return DB:_call(function()
					return DB.DBRef:GetSortedAsync(ascending, pagesize, minValue, maxValue)
				end)

			end;
		end;

		-- Setting the common functions for the data store.
		DB.OnUpdate = ds.OnUpdate;
		DB.DBName	= databaseName;
		DB.DBRef	= ds;

		-- Setting the metatable for the data store.
		local Meta = setmetatable(DB, {
			__index = DB;
			__newindex = function(self, index, reference)
				return error("Attempt to modify a readonly table", 0);
			end;
			__metatable = "[Database]: "..DB.DBName;
			__name = "[Database]: "..DB.DBName;
			__tostring = function(self)
				return "[Database]: "..self.DBName;
			end;
		});

		-- Setting the cache for the data store.
		databaseCache[Meta.DBName] = setmetatable({
			DBReference = Meta;
			Cache = {};
			keySetting = {};
		}, {__index=Meta,__metatable=getmetatable(Meta)});

		return databaseCache[Meta.DBName];

	end;
end;
-- ex: lib.get("SaveData"); --> database

return lib;