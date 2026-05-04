--!strict

--[=[
	@module DataStoreEntity
	@description FSM Entity that wraps Roblox DataStoreService operations behind a
	synchronous-looking API. Each public method spawns a `RequestFSM` via the Orchestrator
	to handle retries through `RetryBehavior`. The calling coroutine yields on a
	`BindableEvent` until the FSM resolves. Tracks `ActiveRequests` (incremented at the
	start of each call, decremented on FSM resolution) and exposes `RateLimitBudget` as a
	read-only visual placeholder counter.
]=]

local DataStoreService = game:GetService("DataStoreService")

local DataStoreEntity = {
	Definition = {
		Name = "DataStoreEntity",
		Schema = {
			ActiveRequests = { Type = "number", Persist = false },
			RateLimitBudget = { Type = "number", Persist = false },
		},
	},
}

--[=[
	@description Extracts the Entity's execution context from FSM params. Returns a table
	with `Orchestrator` sourced from `params.Context.Orchestrator`. Called by the FSM
	framework to supply the entity with its runtime dependencies before state transitions
	begin. Reads `params.Context` only; does not mutate any state.
	@param params any -- FSM initialization params containing a `Context.Orchestrator` field.
	@return { Orchestrator: any } -- Context table for this entity instance.
]=]
function DataStoreEntity:GetContext(params: any)
	return {
		Orchestrator = params.Context and params.Context.Orchestrator,
	}
end

--[=[
	@description No-op stub fulfilling the Entity interface contract. DataStoreEntity
	does not maintain mutable schema state between requests; all operations are
	stateless per-call, so there are no changes to apply.
	@param changes any -- Ignored; present for interface compatibility.
	@return nil
]=]
function DataStoreEntity:ApplyChanges(changes) end

--[=[
	@description Resets runtime counters for this entity instance. Sets `ActiveRequests`
	to 0 and `RateLimitBudget` to 60 (a placeholder visual value). Called by the FSM
	framework when the entity is first attached to a running instance.
	@return nil
]=]
function DataStoreEntity:Initialize()
	self.ActiveRequests = 0
	self.RateLimitBudget = 60 -- Placeholder/Visual
end

--[=[
	@description Reads the value stored at `key` in `datastoreName` using
	`DataStoreService:GetAsync`. Delegates retry logic and FSM lifecycle to
	`_ExecuteRequest`. Yields the calling coroutine until the operation succeeds or
	exhausts all retries. Returns the stored value on success, or raises the final
	error on permanent failure.
	@param datastoreName string -- Name of the DataStore to read from.
	@param key string -- The key to retrieve.
	@param maxRetries number? -- Maximum retry attempts; defaults to 3 inside `_ExecuteRequest`.
	@return any -- The value stored at `key`, or raises on failure.
]=]
function DataStoreEntity:GetAsync(datastoreName: string, key: string, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:GetAsync(key)
	end, maxRetries)
end
--[=[
	@description Writes `value` to `key` in `datastoreName` using
	`DataStoreService:SetAsync`. Delegates retry logic and FSM lifecycle to
	`_ExecuteRequest`. Yields the calling coroutine until the write succeeds or exhausts
	all retries. Raises on permanent failure.
	@param datastoreName string -- Name of the DataStore to write to.
	@param key string -- The key to set.
	@param value any -- The value to store.
	@param maxRetries number? -- Maximum retry attempts; defaults to 3 inside `_ExecuteRequest`.
	@return any -- Return value from DataStore:SetAsync, or raises on failure.
]=]
function DataStoreEntity:SetAsync(datastoreName: string, key: string, value: any, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:SetAsync(key, value)
	end, maxRetries)
end

--[=[
	@description Atomically updates the value at `key` in `datastoreName` using
	`DataStoreService:UpdateAsync`. Passes `transform` (a function from old value to new
	value) directly to the DataStore API. Delegates retry logic and FSM lifecycle to
	`_ExecuteRequest`. Yields until complete or retries are exhausted.
	@param datastoreName string -- Name of the DataStore to update.
	@param key string -- The key to update.
	@param transform (any)->any -- Function receiving the current value and returning the new value.
	@param maxRetries number? -- Maximum retry attempts; defaults to 3 inside `_ExecuteRequest`.
	@return any -- Return value from DataStore:UpdateAsync, or raises on failure.
]=]
function DataStoreEntity:UpdateAsync(datastoreName: string, key: string, transform: (any) -> any, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:UpdateAsync(key, transform)
	end, maxRetries)
end

--[=[
	@description Deletes the entry at `key` from `datastoreName` using
	`DataStoreService:RemoveAsync`. Delegates retry logic and FSM lifecycle to
	`_ExecuteRequest`. Yields until the deletion succeeds or retries are exhausted.
	Raises on permanent failure.
	@param datastoreName string -- Name of the DataStore to delete from.
	@param key string -- The key to remove.
	@param maxRetries number? -- Maximum retry attempts; defaults to 3 inside `_ExecuteRequest`.
	@return any -- Return value from DataStore:RemoveAsync, or raises on failure.
]=]
function DataStoreEntity:RemoveAsync(datastoreName: string, key: string, maxRetries: number?)
	return self:_ExecuteRequest(function()
		local ds = DataStoreService:GetDataStore(datastoreName)
		return ds:RemoveAsync(key)
	end, maxRetries)
end

--[=[
	@description Core execution driver for all DataStore operations. Increments
	`ActiveRequests`, creates a `BindableEvent` for coroutine synchronization, and spawns
	a `RequestFSM` via `Orchestrator.CreateStateMachine` with `requestFn`,
	`maxRetries` (default 3), and `OnSuccess`/`OnFailure` callbacks. Each callback
	decrements `ActiveRequests`, stores the result or error, then fires the bindable.
	The calling coroutine yields on `bindable.Event:Wait()` until the FSM resolves; the
	bindable is destroyed immediately after. If FSM creation fails inside the pcall,
	`ActiveRequests` is decremented, the bindable is destroyed, and the creation error is
	re-raised. Returns the DataStore result on success, or re-raises the FSM error on
	failure.
	@param requestFn any -- Zero-argument function that performs the raw DataStore call.
	@param maxRetries any -- Maximum retry count forwarded to the FSM context.
	@return any -- The DataStore API result on success, or raises on failure.
]=]
function DataStoreEntity:_ExecuteRequest(requestFn, maxRetries)
	local Orchestrator = self.Orchestrator
	if not Orchestrator then
		error("DataStoreEntity missing Orchestrator context")
	end

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
				end,
			},
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
