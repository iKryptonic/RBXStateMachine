--!strict

local RequestFSM = {
	Definition = {
		Name = "RequestFSM",
		ValidStates = { "Queued", "Processing", "Retrying", "Success", "Failed" },
		TerminalStates = { "Success", "Failed" },
		InitialState = "Queued",
		Priority = 2, -- High priority for responsive data handling
	},
}

function RequestFSM:RegisterStates()
	local Orchestrator = self.Context.Orchestrator
	-- Use absolute path — script.Parent.Parent can resolve incorrectly in Rojo serve mode
	local DataStoreFolder = script.Parent.Parent
	local retryModule = DataStoreFolder:FindFirstChild("RetryBehavior")
	if not retryModule then
		-- Fallback: navigate from ReplicatedStorage
		DataStoreFolder = game:GetService("ReplicatedStorage"):FindFirstChild("Orchestrator")
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

	self:AddState("Queued", {
		OnEnter = function(_, fsm)
			fsm.State = "Processing"
		end,
	})

	self:AddState("Processing", {
		OnEnter = function(_, fsm)
			if not RetryBehavior then
				fsm.State = "Failed"
				return
			end
			fsm.Context.FSM = fsm
			RetryBehavior(fsm.Context)
		end,
	})

	self:AddState("Retrying", {
		OnEnter = function(_, fsm)
			fsm.State = "Processing"
		end,
	})

	self:AddState("Success", {
		OnEnter = function(_, fsm)
			if fsm.Context.OnSuccess then
				fsm.Context.OnSuccess(fsm.Context.Result)
			end
		end,
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
		end,
	})
end

return RequestFSM
