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
	Bootstraps the BehaviorTree module with shared framework utilities.
	Must be called exactly once before any node constructors are used.
	Sets `Logger` and marks `Initialized = true`. No-ops on subsequent calls.

	@param Util table -- The shared Orchestrator utility table; must contain `Util.Logger.new`.
	@reads Initialized
	@writes Logger, Initialized
]=]
function BehaviorTree.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Logger = Util.Logger.new({ Name = "BehaviorTree"} )

	Logger:Log({ Level = "INFO", Message = "BehaviorTree initialized" })
end

local function ValidateRequest()
	assert(Initialized,"BehaviorTree not initialized")
	assert(type(Logger) == "table","Logger not initialized")
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
	Returns a composite Selector node that evaluates children left-to-right and
	returns the first non-Failure status. If all children return Failure, the
	Selector itself returns Failure. Unknown status strings are normalised to
	Failure before comparison.

	@param children { (context: any) -> string } -- Ordered list of child node functions to evaluate.
	@return (context: any) -> string -- A single node function representing the Selector.
	@reads Initialized, Logger
	@writes None (pure closure)
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
	Returns a composite Sequence node that evaluates children left-to-right and
	returns the first non-Success status. If all children return Success, the
	Sequence itself returns Success.

	@param children { (context: any) -> string } -- Ordered list of child node functions.
	@return (context: any) -> string -- A single node function representing the Sequence.
	@reads Initialized, Logger
	@writes None (pure closure)
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
	Returns a decorator node that inverts the child's Success/Failure result.
	Running is passed through unchanged (a running child keeps the inverter
	running).

	@param child (context: any) -> string -- The node whose status will be inverted.
	@return (context: any) -> string -- Inverted node function.
	@reads Initialized, Logger
	@writes None (pure closure)
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
	Returns a decorator node that always returns Success unless the child is
	Running, in which case Running is forwarded. Both Success and Failure from
	the child become Success.

	@param child (context: any) -> string -- The wrapped child node.
	@return (context: any) -> string -- Node function that always succeeds (unless running).
	@reads Initialized, Logger
	@writes None (pure closure)
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
	Returns a leaf node that assigns `stateName` to `fsm.State` when executed,
	triggering a deferred state transition via `BaseStateMachine._Update`. The
	write is skipped when the FSM is already in the target state to avoid
	redundant `_Update` cycles.

	@param stateName string -- Target state name to transition the FSM into.
	@return (fsm: any) -> string -- Leaf node function; always returns Success.
	@reads fsm.State
	@writes fsm.State
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
	Returns a leaf node that evaluates `predicate(context)` and maps the boolean
	result to BehaviorTreeStatus.Success or BehaviorTreeStatus.Failure. The
	predicate receives the same context table that the tree was invoked with.

	@param predicate (context: any) -> boolean -- Boolean test to evaluate at runtime.
	@return (context: any) -> string -- Leaf node function.
	@reads Initialized, Logger
	@writes None (pure closure)
]=]
function BehaviorTree.Condition(predicate: (context: any) -> boolean): (context: any) -> string
	ValidateRequest()
	return function(context)
		return (predicate(context) and BehaviorTree.BehaviorTreeStatus.Success) or BehaviorTree.BehaviorTreeStatus.Failure
	end
end

return BehaviorTree
