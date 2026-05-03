--!strict

--[=[
	@description Provides small compatibility helpers for FSM state changes, delayed transitions, release flows, and rollback routing. These functions are used by state machines that need to coordinate lock cleanup, failure recording, and transitions across differing FSM implementations.
	Assumes FSM objects expose State, Context, and optionally ScheduleTransition, Fail, and Log methods. Release and rollback helpers also assume the target states exist on the consuming FSM unless overridden through options.
]=]
local StateTransitionHelpers = {}

--[=[
	@description Schedules a transition to a target state using the FSM's native ScheduleTransition method when available, otherwise falls back to task.delay. In compatibility mode, the delayed transition only applies if the FSM is still active and currently in expectedState, or targetState when expectedState is omitted.
	@param fsm any -- State machine object that may expose ScheduleTransition and contains State and IsActive fields.
	@param seconds number -- Delay before attempting the state transition.
	@param targetState string -- State name to enter after the delay.
	@param expectedState string? -- Optional state name the FSM must still be in before the fallback transition is applied.
	@return nil -- No explicit return value.
	@reads fsm.ScheduleTransition, fsm.IsActive, fsm.State
	@writes fsm.State when using the fallback delayed transition path
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
	@description Either fails the FSM immediately or routes it into a release state when a lock is currently held. By default this expects a crowd-control workflow using _ccLockHeld, _failureReason, and ReleaseCCLock, but all field names and the release state can be overridden.
	@param fsm any -- State machine object containing lock/failure fields and a Fail method.
	@param reason string -- Failure reason recorded or passed to fsm:Fail.
	@param options { [string]: any }? -- Optional overrides for lockField, failureField, and releaseState.
	@return nil -- No explicit return value.
	@reads fsm[lockField], options.lockField, options.failureField, options.releaseState
	@writes fsm[failureField], fsm.State, or invokes fsm:Fail(reason)
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
	@description Queues a lock-release transition by storing the intended follow-up state and optional reason inside fsm.Context, then entering a release state. The consuming FSM is expected to read these context fields in its ReleaseLock state and transition onward after cleanup.
	@param fsm any -- State machine object containing a mutable Context table and State field.
	@param nextState string -- State to enter after the release state finishes cleanup.
	@param reason string? -- Optional reason recorded alongside the queued release.
	@param options { [string]: any }? -- Optional overrides for releaseState, targetField, and reasonField.
	@return nil -- No explicit return value.
	@reads options.releaseState, options.targetField, options.reasonField
	@writes fsm.Context[targetField], fsm.Context[reasonField], fsm.State
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
	@description Records a rollback failure reason in the FSM context, optionally emits an error log entry, and moves the FSM into its rollback state. The consuming FSM is expected to implement the configured rollbackState, defaulting to Rollback.
	@param fsm any -- State machine object containing a mutable Context table, State field, and optional Log method.
	@param reason string -- Failure reason stored for rollback handling and logging.
	@param options { [string]: any }? -- Optional overrides for failureField and rollbackState.
	@return nil -- No explicit return value.
	@reads options.failureField, options.rollbackState, fsm.Log
	@writes fsm.Context[failureField], fsm.State, and log output when Log exists
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
