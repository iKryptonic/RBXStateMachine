--!strict
-- @Name BehaviorTree
-- @Author iKrypto
-- @Description Lightweight Behavior Tree (BT) implementation for complex AI logic.
local BehaviorTree = {}

BehaviorTree.BehaviorTreeStatus = {
	Success = "Success",
	Failure = "Failure",
	Running = "Running",
}

local Logger, Signal, Settings, Initialized;
function BehaviorTree.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Settings = Util.Settings
	Logger = Util.Logger.new({ Name = "BehaviorTree"} )
	Signal = Util.Signal

	Logger:Log({ Level = "INFO", Message = "BehaviorTree initialized" })
end

local function ValidateRequest()
	assert(Initialized, "BehaviorTree not initialized")
	assert(type(Logger) == "table", "Logger not initialized")
	assert(type(Signal) == "table", "Signal not initialized")
	assert(type(Settings) == "table", "Settings not initialized")
end

--[[
	@description Runs children until one succeeds.
]]
function BehaviorTree.Selector(children: { (context: any) -> string }): (context: any) -> string
	ValidateRequest()
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
	@description Runs children until one fails.
]]
function BehaviorTree.Sequence(children: { (context: any) -> string }): (context: any) -> string
	ValidateRequest()
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
	@description Inverts Success/Failure. Returns Running as-is.
]]
function BehaviorTree.Inverter(child: (context: any) -> string): (context: any) -> string
	ValidateRequest()
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
	@description Always returns Success.
]]
function BehaviorTree.Succeeder(child: (context: any) -> string): (context: any) -> string
	ValidateRequest()
	return function(context)
		local status = child(context)
		if status == BehaviorTree.BehaviorTreeStatus.Running then
			return BehaviorTree.BehaviorTreeStatus.Running
		end
		return BehaviorTree.BehaviorTreeStatus.Success
	end
end

--[[
	@description Utility to change FSM state.
]]
function BehaviorTree.SetState(stateName: string): (fsm: any) -> string
	ValidateRequest()
	return function(fsm)
		if fsm.State ~= stateName then
			fsm.State = stateName
		end
		return BehaviorTree.BehaviorTreeStatus.Success
	end
end

--[[
	@description Utility to check a condition.
]]
function BehaviorTree.Condition(predicate: (context: any) -> boolean): (context: any) -> string
	ValidateRequest()
	return function(context)
		return (predicate(context) and BehaviorTree.BehaviorTreeStatus.Success) or BehaviorTree.BehaviorTreeStatus.Failure
	end
end

return BehaviorTree
