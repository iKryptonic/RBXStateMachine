--!strict
--[=[
	@module RequestFSM
	@description Defines the `RequestFSM` state machine module and its exported API.
]=]

local RequestFSM = {
	Definition = {
		Name = "RequestFSM",
		ValidStates = { "Queued", "Processing", "Retrying", "Success", "Failed" },
		TerminalStates = { "Success", "Failed" },
		InitialState = "Queued",
		Priority = 2 -- High priority for responsive data handling
	}
}
--[=[
	@description Handles `RegisterStates` for `RequestFSM`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function RequestFSM:RegisterStates()
	local Orchestrator = self.Context.Orchestrator
	-- Use absolute path — script.Parent.Parent can resolve incorrectly in Rojo serve mode
	local DataStoreFolder = script.Parent.Parent
	local retryModule = DataStoreFolder:FindFirstChild("RetryBehavior")
	if not retryModule then
		-- Fallback: navigate from ReplicatedStorage
		DataStoreFolder = game:GetService("ReplicatedStorage")
			:FindFirstChild("Orchestrator")
		if DataStoreFolder then
			DataStoreFolder = DataStoreFolder:FindFirstChild("Core")
			DataStoreFolder = DataStoreFolder and DataStoreFolder:FindFirstChild("DataStore")
			retryModule = DataStoreFolder and DataStoreFolder:FindFirstChild("RetryBehavior")
		end
	end
	if not retryModule then
		warn("[RequestFSM] RetryBehavior module not found — using inline retry")
	end
	local RetryBehavior = retryModule and require(retryModule).Create(Orchestrator) or nil
	--[=[
		@state Queued
		@description Handles the `Queued` state for `RequestFSM`.
	]=]

	self:AddState("Queued", {
		OnEnter = function(_, fsm)
			fsm.State = "Processing"
		end
	})
	--[=[
		@state Processing
		@description Handles the `Processing` state for `RequestFSM`.
	]=]

	self:AddState("Processing", {
		OnEnter = function(_, fsm)
			if not RetryBehavior then
				fsm.State = "Failed"
				return
			end
			fsm.Context.FSM = fsm
			RetryBehavior(fsm.Context)
		end
	})
	--[=[
		@state Retrying
		@description Handles the `Retrying` state for `RequestFSM`.
	]=]

	self:AddState("Retrying", {
		OnEnter = function(_, fsm)
			fsm.State = "Processing"
		end
	})
	--[=[
		@state Success
		@description Handles the `Success` state for `RequestFSM`.
	]=]

	self:AddState("Success", {
		OnEnter = function(_, fsm)
			if fsm.Context.OnSuccess then
				fsm.Context.OnSuccess(fsm.Context.Result)
			end
		end
	})
	--[=[
		@state Failed
		@description Handles the `Failed` terminal state for `RequestFSM`.
	]=]

	self:AddState("Failed", {
		OnEnter = function(_, fsm)
			if fsm.Context.OnFailure then
				fsm.Context.OnFailure(fsm.Context.LastError)
			end
		end
	})
end

return RequestFSM
