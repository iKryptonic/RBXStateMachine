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

function DataStoreEntity:GetContext(params: any)
	return {
		Orchestrator = params.Context and params.Context.Orchestrator
	}
end

function DataStoreEntity:ApplyChanges(changes)
	
end

function DataStoreEntity:Initialize()
	self.ActiveRequests = 0
	self.RateLimitBudget = 60 -- Placeholder/Visual
end

function DataStoreEntity:GetAsync(datastoreName: string, key: string, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:GetAsync(key)
	end, maxRetries)
end

function DataStoreEntity:SetAsync(datastoreName: string, key: string, value: any, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:SetAsync(key, value)
	end, maxRetries)
end

function DataStoreEntity:UpdateAsync(datastoreName: string, key: string, transform: (any)->any, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:UpdateAsync(key, transform)
	end, maxRetries)
end

function DataStoreEntity:RemoveAsync(datastoreName: string, key: string, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:RemoveAsync(key)
	end, maxRetries)
end

function DataStoreEntity:_ExecuteRequest(requestFn, maxRetries)
	local Orchestrator = self.Orchestrator
	if not Orchestrator then error("DataStoreEntity missing Orchestrator context") end

	self.ActiveRequests = self.ActiveRequests + 1
	
	-- Promise-like wrapping
	local bindable = Instance.new("BindableEvent")
	local resultData, resultErr
	local success = false
	
	-- Spawn FSM
	Orchestrator.CreateStateMachine({
		StateMachineClass = "RequestFSM",
		StateMachineId = "DS_" .. Orchestrator.Scheduler:GenerateKey(),
		Context = {
			Orchestrator = Orchestrator,
			RequestFunction = requestFn,
			MaxRetries = maxRetries or 3,
			RetryCount = 0,
			FSM = nil, -- Injected by factory or we set it? Factory injects 'self' into context? No, BaseStateMachine.new sets self.Context to the table.
			
			OnSuccess = function(res)
				success = true
				resultData = res
				self.ActiveRequests = self.ActiveRequests - 1
				bindable:Fire()
			end,
			OnFailure = function(err)
				success = false
				resultErr = err
				self.ActiveRequests = self.ActiveRequests - 1
				bindable:Fire()
			end
		}
	})
	
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
