--!strict
-- @Name RetryBehavior
-- @Author iKrypto
-- @Description Behavior Tree definition for DataStore request retry logic.

local BehaviorTree
do
	local factoryFolder = script.Parent.Parent:FindFirstChild("Factory")
	if not factoryFolder then
		factoryFolder = game:GetService("ReplicatedStorage")
			:FindFirstChild("Orchestrator")
		if factoryFolder then
			factoryFolder = factoryFolder:FindFirstChild("Core")
			factoryFolder = factoryFolder and factoryFolder:FindFirstChild("Factory")
		end
	end
	BehaviorTree = factoryFolder and require(factoryFolder:FindFirstChild("BehaviorTree"))
end

local RetryBehavior = {}

--[[
	@description Builds the retry behavior tree used by RequestFSM instances.
	@param Orchestrator any -- Shared orchestrator facade used by the surrounding FSM context
	@return (context: any) -> string -- BehaviorTree node that mutates request context and drives FSM transitions
	@reads BehaviorTree constructors, context.RequestFunction, context.MaxRetries, context.RetryCount, context.FSM
	@writes context.Result, context.LastError, context.RetryCount, context.FSM.WaitSpan
]]
function RetryBehavior.Create(Orchestrator)
	local BT = BehaviorTree

	-- Action: Attempt the DataStore Call
	local function AttemptCall(context)
		if not context.RequestFunction then return BT.BehaviorTreeStatus.Failure end
		
		local success, result = pcall(context.RequestFunction)
		if success then
			context.Result = result
			return BT.BehaviorTreeStatus.Success
		else
			context.LastError = result
			return BT.BehaviorTreeStatus.Failure
		end
	end

	-- Condition: Can we retry?
	local function CanRetry(context)
		local max = context.MaxRetries or 3
		local current = context.RetryCount or 0
		return (current < max) and BT.BehaviorTreeStatus.Success or BT.BehaviorTreeStatus.Failure
	end

	-- Action: Schedule Retry (Transitions FSM state)
	local function ScheduleRetry(context)
		if context.FSM then
			context.RetryCount = (context.RetryCount or 0) + 1
			local MAX_DELAY = 30
			local jitter = math.random() * 0.5 + 0.75
			local delay = math.min(math.pow(2, context.RetryCount) * jitter, MAX_DELAY)

			context.FSM.WaitSpan = delay
			context.FSM.State = "Retrying"
			return BT.BehaviorTreeStatus.Success
		end
		return BT.BehaviorTreeStatus.Failure
	end

	local function FailRequest(context)
		if context.FSM then
			context.FSM.State = "Failed"
		end
		return BT.BehaviorTreeStatus.Success
	end

	local function CompleteRequest(context)
		if context.FSM then
			context.FSM.State = "Success"
		end
		return BT.BehaviorTreeStatus.Success
	end

	-- The Strategy:
	-- 1. Try to Call. If Success -> Complete.
	-- 2. If Fail -> Check Retry.
	-- 3. If Can Retry -> Schedule Retry.
	-- 4. If Cannot Retry -> Fail Permanently.
	
	local Tree = BT.Selector({
		BT.Sequence({
			AttemptCall,
			CompleteRequest
		}),
		BT.Sequence({
			CanRetry,
			ScheduleRetry
		}),
		FailRequest
	})

	return Tree
end

return RetryBehavior
