--!strict
-- @Name RetryBehavior
-- @Author iKrypto
-- @Description Behavior Tree definition for DataStore request retry logic.

local BehaviorTree = require(script.Parent.Parent.Factory.BehaviorTree)

local RetryBehavior = {}

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
			-- Calculate Backoff
			local base = 2
			local delay = math.pow(base, context.RetryCount)
			
			context.FSM.WaitSpan = delay -- Use FSM's built-in delay capability
			context.FSM:ChangeState({ Name = "Retrying" })
			return BT.BehaviorTreeStatus.Success -- We successfully scheduled it
		end
		return BT.BehaviorTreeStatus.Failure
	end

	-- Action: Fail Permanently
	local function FailRequest(context)
		if context.FSM then
			context.FSM:Fail(tostring(context.LastError))
		end
		return BT.BehaviorTreeStatus.Success
	end

	-- Action: Succeed
	local function CompleteRequest(context)
		if context.FSM then
			context.FSM:Finish()
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
