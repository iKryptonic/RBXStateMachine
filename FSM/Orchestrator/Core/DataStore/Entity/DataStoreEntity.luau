--!strict
-- @Name DataStoreEntity
-- @Author iKrypto
-- @Description Entity that serves as the DataStore Service facade. Spawns RequestFSMs for operations.

local DataStoreService = game:GetService("DataStoreService")

local DataStoreEntity = {
	Definition = {
		Name = "DataStoreEntity",
		Schema = {
			ActiveRequests = { Type = "number", Persist = false },
			RateLimitBudget = { Type = "number", Persist = false },
		}
	}
}

--[[
	@description Derives context values for the DataStoreEntity instance.
	@param params any -- Factory/BaseEntity constructor payload
	@return { Orchestrator: any? } -- Context exposing the orchestrator facade when provided
	@reads params.Context.Orchestrator
	@writes None
]]
function DataStoreEntity:GetContext(params: any)
	return {
		Orchestrator = params.Context and params.Context.Orchestrator
	}
end

--[[
	@description No-op visual hook for DataStoreEntity state changes.
	@param changes { [string]: any } -- Committed property delta from BaseEntity
	@return ()
	@reads None
	@writes None
]]
function DataStoreEntity:ApplyChanges(changes)

end

--[[
	@description Seeds default counters for request tracking and UI diagnostics.
	@return ()
	@reads None
	@writes self.ActiveRequests, self.RateLimitBudget
]]
function DataStoreEntity:Initialize()
	self.ActiveRequests = 0
	self.RateLimitBudget = 60 -- Placeholder/Visual
end

--[[
	@description Executes a DataStore:GetAsync call through RequestFSM retry orchestration.
	@param datastoreName string -- DataStore name passed to DataStoreService:GetDataStore
	@param key string -- Entry key to fetch
	@param maxRetries number? -- Retry budget override for transient failures
	@return any -- Retrieved value from the DataStore entry
	@reads self.Orchestrator, DataStoreService
	@writes self.ActiveRequests (via _ExecuteRequest)
]]
function DataStoreEntity:GetAsync(datastoreName: string, key: string, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:GetAsync(key)
	end, maxRetries)
end

--[[
	@description Executes a DataStore:SetAsync call through RequestFSM retry orchestration.
	@param datastoreName string -- DataStore name passed to DataStoreService:GetDataStore
	@param key string -- Entry key to overwrite
	@param value any -- Serialized payload to persist
	@param maxRetries number? -- Retry budget override for transient failures
	@return any -- Native return value from DataStore:SetAsync
	@reads self.Orchestrator, DataStoreService
	@writes self.ActiveRequests (via _ExecuteRequest)
]]
function DataStoreEntity:SetAsync(datastoreName: string, key: string, value: any, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:SetAsync(key, value)
	end, maxRetries)
end

--[[
	@description Executes a DataStore:UpdateAsync call through RequestFSM retry orchestration.
	@param datastoreName string -- DataStore name passed to DataStoreService:GetDataStore
	@param key string -- Entry key to update
	@param transform (any) -> any -- Callback invoked by Roblox with the current stored value
	@param maxRetries number? -- Retry budget override for transient failures
	@return any -- Value returned by the transform/UpdateAsync pipeline
	@reads self.Orchestrator, DataStoreService
	@writes self.ActiveRequests (via _ExecuteRequest)
]]
function DataStoreEntity:UpdateAsync(datastoreName: string, key: string, transform: (any)->any, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:UpdateAsync(key, transform)
	end, maxRetries)
end

--[[
	@description Executes a DataStore:RemoveAsync call through RequestFSM retry orchestration.
	@param datastoreName string -- DataStore name passed to DataStoreService:GetDataStore
	@param key string -- Entry key to delete
	@param maxRetries number? -- Retry budget override for transient failures
	@return any -- Native return value from DataStore:RemoveAsync
	@reads self.Orchestrator, DataStoreService
	@writes self.ActiveRequests (via _ExecuteRequest)
]]
function DataStoreEntity:RemoveAsync(datastoreName: string, key: string, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:RemoveAsync(key)
	end, maxRetries)
end

--[[
	@description Wraps a raw DataStore request in a RequestFSM so retries, backoff,
	and completion callbacks are driven by the framework instead of ad-hoc task logic.
	@param requestFn () -> any -- Function that performs the actual DataStore call
	@param maxRetries number? -- Retry budget override passed into RequestFSM context
	@return any -- Successful request result; throws on unrecoverable failure
	@reads self.Orchestrator, Orchestrator.Scheduler, Orchestrator.CreateStateMachine
	@writes self.ActiveRequests
]]
function DataStoreEntity:_ExecuteRequest(requestFn, maxRetries)
	local Orchestrator = self.Orchestrator
	if not Orchestrator then error("DataStoreEntity missing Orchestrator context") end

	self.ActiveRequests = (self.ActiveRequests or 0) + 1

	-- Promise-like wrapping
	local bindable = Instance.new("BindableEvent")
	local resultData, resultErr
	local success = false

	-- Spawn FSM (pcall-wrapped to prevent counter + Instance leak)
	local ok, createErr = pcall(function()
		local fsm = Orchestrator.CreateStateMachine({
			StateMachineClass = "RequestFSM",
			StateMachineId = "DS_" .. Orchestrator.Scheduler:GenerateKey(),
			Context = {
				Orchestrator = Orchestrator,
				RequestFunction = requestFn,
				MaxRetries = maxRetries or 3,
				RetryCount = 0,
				FSM = nil,
				OnSuccess = function(res)
					success = true
					resultData = res
					self.ActiveRequests = math.max(0, (self.ActiveRequests or 0) - 1)
					bindable:Fire()
				end,
				OnFailure = function(err)
					success = false
					resultErr = err
					self.ActiveRequests = math.max(0, (self.ActiveRequests or 0) - 1)
					bindable:Fire()
				end
			}
		})
		if not fsm then
			error("Failed to create RequestFSM for DataStore operation")
		end
	end)

	if not ok then
		self.ActiveRequests = math.max(0, (self.ActiveRequests or 0) - 1)
		bindable:Destroy()
		error(createErr)
	end

	-- Wait for FSM to complete (yields)
	bindable.Event:Wait()
	bindable:Destroy()

	if success then
		return resultData
	else
		error(resultErr) -- Re-throw error to caller
	end
end

return DataStoreEntity
