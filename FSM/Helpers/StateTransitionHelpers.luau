--!strict

--[=[
	@description Provides small compatibility helpers for FSM state changes, delayed transitions, release flows, and rollback routing. These functions are used by state machines that need to coordinate lock cleanup, failure recording, and transitions across differing FSM implementations.
	Assumes FSM objects expose State, Context, and optionally ScheduleTransition, Fail, and Log methods. Release and rollback helpers also assume the target states exist on the consuming FSM unless overridden through options.
]=]
local StateTransitionHelpers = {}
--[=[
	@description Implements `StateTransitionHelpers.scheduleTransitionCompat`.
	@param fsm any -- `fsm` input parameter.
	@param seconds number -- `seconds` input parameter.
	@param targetState string -- `targetState` input parameter.
	@param expectedState string? -- `expectedState` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function StateTransitionHelpers.scheduleTransitionCompat(
	fsm: any,
	seconds: number,
	targetState: string,
	expectedState: string?
)
	if type(fsm.ScheduleTransition) == "function" then
		fsm:ScheduleTransition(seconds, targetState)
		return
	end

	task.delay(seconds, function()
		if fsm.IsActive and fsm.State == (expectedState or targetState) then
			fsm.State = targetState
		end
	end)
end
--[=[
	@description Implements `StateTransitionHelpers.failOrRelease`.
	@param fsm any -- `fsm` input parameter.
	@param reason string -- `reason` input parameter.
	@param options { [string]: any }? -- `options` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function StateTransitionHelpers.failOrRelease(fsm: any, reason: string, options: { [string]: any }?)
	local config = options or {}
	local lockField = config.lockField or "_ccLockHeld"
	local failureField = config.failureField or "_failureReason"
	local releaseState = config.releaseState or "ReleaseCCLock"
	if fsm[lockField] then
		fsm[failureField] = reason
		fsm.State = releaseState
	else
		fsm:Fail(reason)
	end
end
--[=[
	@description Implements `StateTransitionHelpers.queueRelease`.
	@param fsm any -- `fsm` input parameter.
	@param nextState string -- `nextState` input parameter.
	@param reason string? -- `reason` input parameter.
	@param options { [string]: any }? -- `options` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function StateTransitionHelpers.queueRelease(fsm: any, nextState: string, reason: string?, options: { [string]: any }?)
	local config = options or {}
	local releaseState = config.releaseState or "ReleaseLock"
	local targetField = config.targetField or "_releaseTargetState"
	local reasonField = config.reasonField or "_releaseReason"
	fsm.Context[targetField] = nextState
	fsm.Context[reasonField] = reason
	fsm.State = releaseState
end
--[=[
	@description Implements `StateTransitionHelpers.queueRollback`.
	@param fsm any -- `fsm` input parameter.
	@param reason string -- `reason` input parameter.
	@param options { [string]: any }? -- `options` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function StateTransitionHelpers.queueRollback(fsm: any, reason: string, options: { [string]: any }?)
	local config = options or {}
	local failureField = config.failureField or "_failureReason"
	local rollbackState = config.rollbackState or "Rollback"
	fsm.Context[failureField] = reason
	if type(fsm.Log) == "function" then
		fsm:Log({ Level = "ERROR", Message = reason })
	end
	fsm.State = rollbackState
end

return StateTransitionHelpers
