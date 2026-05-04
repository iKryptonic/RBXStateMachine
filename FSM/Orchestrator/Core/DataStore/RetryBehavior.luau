--!strict

--[=[
	@module RetryBehavior
	@description Assembles a reusable BehaviorTree retry strategy for DataStore requests.
	Resolves `BehaviorTree` from the Factory folder (sibling of the DataStore folder, or
	from `ReplicatedStorage.Orchestrator.Core.Factory` as a fallback). The tree returned
	by `Create` drives a `RequestFSM` through four outcomes: success, per-attempt
	retry with jittered exponential backoff, and permanent failure once retries are
	exhausted.
]=]

local BehaviorTree
do
	local factoryFolder = script.Parent.Parent:FindFirstChild("Factory")
	if not factoryFolder then
		factoryFolder = game:GetService("ReplicatedStorage"):FindFirstChild("Orchestrator")
		if factoryFolder then
			factoryFolder = factoryFolder:FindFirstChild("Core")
			factoryFolder = factoryFolder and factoryFolder:FindFirstChild("Factory")
		end
	end
	BehaviorTree = factoryFolder and require(factoryFolder:FindFirstChild("BehaviorTree"))
end

local RetryBehavior = {}

--[=[
	@description Builds and returns a BehaviorTree Selector that implements the
	DataStore call-retry-fail strategy. Defines five inner closures operating entirely
	on the `context` table passed by the BehaviorTree runner:
	- `AttemptCall`: invokes `context.RequestFunction` via pcall; writes `context.Result`
	  on success or `context.LastError` on failure.
	- `CanRetry`: returns Success if `context.RetryCount < context.MaxRetries` (default 3).
	- `ScheduleRetry`: increments `context.RetryCount`, computes a jittered exponential
	  backoff delay (2^RetryCount × random[0.75,1.25], capped at 30 s), writes
	  `context.FSM.WaitSpan`, and transitions `context.FSM.State` to "Retrying".
	- `FailRequest`: transitions `context.FSM.State` to "Failed".
	- `CompleteRequest`: transitions `context.FSM.State` to "Success".
	The `Orchestrator` parameter is accepted for API consistency but is not used inside
	the returned tree; all state flows through `context`.
	@param Orchestrator any -- Orchestrator reference (unused inside the tree; accepted for API symmetry).
	@return BehaviorTree -- Selector tree ready to be ticked by a RequestFSM.
]=]
function RetryBehavior.Create(Orchestrator)
	local BT = BehaviorTree

	-- Action: Attempt the DataStore Call
	local function AttemptCall(context)
		if not context.RequestFunction then
			return BT.BehaviorTreeStatus.Failure
		end

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
			CompleteRequest,
		}),
		BT.Sequence({
			CanRetry,
			ScheduleRetry,
		}),
		FailRequest,
	})

	return Tree
end

return RetryBehavior
