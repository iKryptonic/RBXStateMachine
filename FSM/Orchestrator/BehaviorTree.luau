--!strict
-- @Name BehaviorTree
-- @Author iKrypto
-- @Description Lightweight Behavior Tree (BT) implementation for complex AI logic.

local Types = require(script.Parent.Types)
local BehaviorTree = {}

BehaviorTree.BehaviorTreeStatus = {
	Success = "Success" :: Types.BehaviorTreeStatus,
	Failure = "Failure" :: Types.BehaviorTreeStatus,
	Running = "Running" :: Types.BehaviorTreeStatus,
}

--[[
	@summary Runs children until one succeeds.
]]
function BehaviorTree.Selector(children: { (context: any) -> Types.BehaviorTreeStatus }): (context: any) -> Types.BehaviorTreeStatus
	return function(context)
		for _, child in ipairs(children) do
			local status = child(context)
			if status ~= BehaviorTree.BehaviorTreeStatus.Failure then
				return status
			end
		end
		return BehaviorTree.BehaviorTreeStatus.Failure
	end
end

--[[
	@summary Runs children until one fails.
]]
function BehaviorTree.Sequence(children: { (context: any) -> Types.BehaviorTreeStatus }): (context: any) -> Types.BehaviorTreeStatus
	return function(context)
		for _, child in ipairs(children) do
			local status = child(context)
			if status ~= BehaviorTree.BehaviorTreeStatus.Success then
				return status
			end
		end
		return BehaviorTree.BehaviorTreeStatus.Success
	end
end

--[[
	@summary Inverts Success/Failure. Returns Running as-is.
]]
function BehaviorTree.Inverter(child: (context: any) -> Types.BehaviorTreeStatus): (context: any) -> Types.BehaviorTreeStatus
	return function(context)
		local status = child(context)
		if status == BehaviorTree.BehaviorTreeStatus.Success then
			return BehaviorTree.BehaviorTreeStatus.Failure
		elseif status == BehaviorTree.BehaviorTreeStatus.Failure then
			return BehaviorTree.BehaviorTreeStatus.Success
		end
		return status
	end
end

--[[
	@summary Always returns Success.
]]
function BehaviorTree.Succeeder(child: (context: any) -> Types.BehaviorTreeStatus): (context: any) -> Types.BehaviorTreeStatus
	return function(context)
		local status = child(context)
		if status == BehaviorTree.BehaviorTreeStatus.Running then
			return BehaviorTree.BehaviorTreeStatus.Running
		end
		return BehaviorTree.BehaviorTreeStatus.Success
	end
end

--[[
	@summary Utility to change FSM state.
]]
function BehaviorTree.SetState(stateName: string): (fsm: any) -> Types.BehaviorTreeStatus
	return function(fsm)
		if fsm.State ~= stateName then
			fsm.State = stateName
		end
		return BehaviorTree.BehaviorTreeStatus.Success
	end
end

--[[
	@summary Utility to check a condition.
]]
function BehaviorTree.Condition(predicate: (context: any) -> boolean): (context: any) -> Types.BehaviorTreeStatus
	return function(context)
		return (predicate(context) and BehaviorTree.BehaviorTreeStatus.Success) or BehaviorTree.BehaviorTreeStatus.Failure
	end
end

return BehaviorTree
