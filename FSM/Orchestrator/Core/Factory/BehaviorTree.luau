--!strict
--[=[
	@Name BehaviorTree
	@Author iKrypto
	@Description Lightweight Behavior Tree (BT) implementation for composing
	complex decision logic from simple node functions. Provides standard composite
	nodes (Selector, Sequence), decorators (Inverter, Succeeder), and utility
	leaf constructors (SetState, Condition). Each node is a function
	`(context) -> BehaviorTreeStatus`.

	@usage
	local tree = BehaviorTree.Sequence({
		BehaviorTree.Condition(function(ctx) return ctx.Health > 0 end),
		BehaviorTree.SetState("Attacking"),
	})
	local status = tree(myContext)
]=]
local BehaviorTree = {}

BehaviorTree.BehaviorTreeStatus = {
	Success = "Success",
	Failure = "Failure",
	Running = "Running",
}

local Logger, Initialized;
--[=[
	@description Handles `Initialize` for `BehaviorTree`.
	@param Util any -- `Util` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function BehaviorTree.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Logger = Util.Logger.new({ Name = "BehaviorTree"} )

	Logger:Log({ Level = "INFO", Message = "BehaviorTree initialized" })
end

local function ValidateRequest()
	assert(Initialized, "BehaviorTree not initialized")
	assert(type(Logger) == "table", "Logger not initialized")
end

local function normalizeStatus(status: any): string
	if status == BehaviorTree.BehaviorTreeStatus.Success
		or status == BehaviorTree.BehaviorTreeStatus.Failure
		or status == BehaviorTree.BehaviorTreeStatus.Running
	then
		return status
	end
	return BehaviorTree.BehaviorTreeStatus.Failure
end
--[=[
	@description Implements `BehaviorTree.Selector`.
	@param children { (context: any) -> string } -- `children` input parameter.
	@return (context: any) -> string -- Return value produced by the implementation, if any.
]=]

function BehaviorTree.Selector(children: { (context: any) -> string }): (context: any) -> string
	ValidateRequest()
	return function(context)
		for _, child in ipairs(children) do
			local status = normalizeStatus(child(context))
			if status ~= BehaviorTree.BehaviorTreeStatus.Failure then
				return status
			end
		end
		return BehaviorTree.BehaviorTreeStatus.Failure
	end
end
--[=[
	@description Implements `BehaviorTree.Sequence`.
	@param children { (context: any) -> string } -- `children` input parameter.
	@return (context: any) -> string -- Return value produced by the implementation, if any.
]=]

function BehaviorTree.Sequence(children: { (context: any) -> string }): (context: any) -> string
	ValidateRequest()
	return function(context)
		for _, child in ipairs(children) do
			local status = normalizeStatus(child(context))
			if status ~= BehaviorTree.BehaviorTreeStatus.Success then
				return status
			end
		end
		return BehaviorTree.BehaviorTreeStatus.Success
	end
end
--[=[
	@description Implements `BehaviorTree.Inverter`.
	@param child (context: any) -> string -- `child` input parameter.
	@return (context: any) -> string -- Return value produced by the implementation, if any.
]=]

function BehaviorTree.Inverter(child: (context: any) -> string): (context: any) -> string
	ValidateRequest()
	return function(context)
		local status = normalizeStatus(child(context))
		if status == BehaviorTree.BehaviorTreeStatus.Success then
			return BehaviorTree.BehaviorTreeStatus.Failure
		elseif status == BehaviorTree.BehaviorTreeStatus.Failure then
			return BehaviorTree.BehaviorTreeStatus.Success
		end
		return status
	end
end
--[=[
	@description Implements `BehaviorTree.Succeeder`.
	@param child (context: any) -> string -- `child` input parameter.
	@return (context: any) -> string -- Return value produced by the implementation, if any.
]=]

function BehaviorTree.Succeeder(child: (context: any) -> string): (context: any) -> string
	ValidateRequest()
	return function(context)
		local status = normalizeStatus(child(context))
		if status == BehaviorTree.BehaviorTreeStatus.Running then
			return BehaviorTree.BehaviorTreeStatus.Running
		end
		return BehaviorTree.BehaviorTreeStatus.Success
	end
end
--[=[
	@description Updates module state through `BehaviorTree.SetState`.
	@param stateName string -- `stateName` input parameter.
	@return (fsm: any) -> string -- Return value produced by the implementation, if any.
]=]

function BehaviorTree.SetState(stateName: string): (fsm: any) -> string
	ValidateRequest()
	return function(fsm)
		if fsm.State ~= stateName then
			fsm.State = stateName
		end
		return BehaviorTree.BehaviorTreeStatus.Success
	end
end
--[=[
	@description Implements `BehaviorTree.Condition`.
	@param predicate (context: any) -> boolean -- `predicate` input parameter.
	@return (context: any) -> string -- Return value produced by the implementation, if any.
]=]

function BehaviorTree.Condition(predicate: (context: any) -> boolean): (context: any) -> string
	ValidateRequest()
	return function(context)
		return (predicate(context) and BehaviorTree.BehaviorTreeStatus.Success) or BehaviorTree.BehaviorTreeStatus.Failure
	end
end

return BehaviorTree
