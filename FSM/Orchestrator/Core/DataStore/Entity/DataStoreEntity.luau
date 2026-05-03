--!strict
--[=[
	@module DataStoreEntity
	@description Defines the `DataStoreEntity` module and its exported API.
]=]

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
--[=[
	@description Returns the data produced by `DataStoreEntity.GetContext`.
	@param params any -- `params` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreEntity:GetContext(params: any)
	return {
		Orchestrator = params.Context and params.Context.Orchestrator
	}
end
--[=[
	@description Implements `DataStoreEntity.ApplyChanges`.
	@param changes any -- `changes` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreEntity:ApplyChanges(changes)

end
--[=[
	@description Handles `Initialize` for `DataStoreEntity`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreEntity:Initialize()
	self.ActiveRequests = 0
	self.RateLimitBudget = 60 -- Placeholder/Visual
end
--[=[
	@description Returns the data produced by `DataStoreEntity.GetAsync`.
	@param datastoreName string -- `datastoreName` input parameter.
	@param key string -- `key` input parameter.
	@param maxRetries number? -- `maxRetries` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreEntity:GetAsync(datastoreName: string, key: string, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:GetAsync(key)
	end, maxRetries)
end
--[=[
	@description Updates module state through `DataStoreEntity.SetAsync`.
	@param datastoreName string -- `datastoreName` input parameter.
	@param key string -- `key` input parameter.
	@param value any -- `value` input parameter.
	@param maxRetries number? -- `maxRetries` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreEntity:SetAsync(datastoreName: string, key: string, value: any, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:SetAsync(key, value)
	end, maxRetries)
end
--[=[
	@description Implements `DataStoreEntity.UpdateAsync`.
	@param datastoreName string -- `datastoreName` input parameter.
	@param key string -- `key` input parameter.
	@param transform (any)->any -- `transform` input parameter.
	@param maxRetries number? -- `maxRetries` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreEntity:UpdateAsync(datastoreName: string, key: string, transform: (any)->any, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:UpdateAsync(key, transform)
	end, maxRetries)
end
--[=[
	@description Implements `DataStoreEntity.RemoveAsync`.
	@param datastoreName string -- `datastoreName` input parameter.
	@param key string -- `key` input parameter.
	@param maxRetries number? -- `maxRetries` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreEntity:RemoveAsync(datastoreName: string, key: string, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:RemoveAsync(key)
	end, maxRetries)
end
--[=[
	@description Implements `DataStoreEntity._ExecuteRequest`.
	@param requestFn any -- `requestFn` input parameter.
	@param maxRetries any -- `maxRetries` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreEntity:_ExecuteRequest(requestFn, maxRetries)
	local Orchestrator = self.Orchestrator
	if not Orchestrator then error("DataStoreEntity missing Orchestrator context") end

	self.ActiveRequests = ((self.ActiveRequests or 0) + 1)

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
