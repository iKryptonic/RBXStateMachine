--!strict

--[=[
	@description Provides small compatibility helpers for FSM state changes, delayed transitions, release flows, and rollback routing. These functions are used by state machines that need to coordinate lock cleanup, failure recording, and transitions across differing FSM implementations.
	Assumes FSM objects expose State, Context, and optionally ScheduleTransition, Fail, and Log methods. Release and rollback helpers also assume the target states exist on the consuming FSM unless overridden through options.
]=]
local StateTransitionHelpers = {}
--[=[
	@description Schedules a delayed state change while supporting FSM implementations with or without a
	native ScheduleTransition method. When the method exists it is delegated directly; otherwise a task.delay
	fallback waits the requested duration and only overwrites fsm.State if the FSM is still active and still
	in the expected state.

	@param fsm any -- FSM instance whose state should change after a delay.
	@param seconds number -- Delay in seconds before the transition is attempted.
	@param targetState string -- State name to enter after the delay elapses.
	@param expectedState string? -- Optional state the FSM must still be in for the fallback transition to apply; defaults to targetState.
	@return nil
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
	@description Routes a failure either into a lock-release cleanup state or directly into fsm:Fail. If the
	configured lock field is currently set, the failure reason is stored on the FSM and execution moves to a
	release state so cleanup can happen before termination; otherwise the FSM fails immediately.

	@param fsm any -- FSM instance that may need to release a held lock before failing.
	@param reason string -- Failure reason recorded on the FSM or passed to fsm:Fail.
	@param options { [string]: any }? -- Optional override fields for lockField, failureField, and releaseState.
	@return nil
	@writes fsm state and failure metadata
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
	@description Queues a lock-release state by storing where the FSM should go afterward and why. The next
	state and optional reason are written into configurable Context fields, then the FSM is moved into the
	release state so another state can perform the actual unlock work.

	@param fsm any -- FSM instance whose Context will carry release metadata.
	@param nextState string -- State to enter after the release step finishes.
	@param reason string? -- Optional reason recorded for release/cleanup handlers.
	@param options { [string]: any }? -- Optional override fields for releaseState, targetField, and reasonField.
	@return nil
	@writes fsm.Context, fsm.State
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
	@description Marks an FSM for rollback by recording the failure reason, optionally logging it, and then
	switching into a rollback state. This keeps failure context available to cleanup logic instead of losing
	the original reason before the rollback sequence runs.

	@param fsm any -- FSM instance that should enter its rollback path.
	@param reason string -- Human-readable failure reason stored in Context and optionally emitted through Log.
	@param options { [string]: any }? -- Optional override fields for failureField and rollbackState.
	@return nil
	@writes fsm.Context, fsm.State
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
