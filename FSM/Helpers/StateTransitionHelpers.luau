--!strict

local StateTransitionHelpers = {}

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

function StateTransitionHelpers.queueRelease(fsm: any, nextState: string, reason: string?, options: { [string]: any }?)
	local config = options or {}
	local releaseState = config.releaseState or "ReleaseLock"
	local targetField = config.targetField or "_releaseTargetState"
	local reasonField = config.reasonField or "_releaseReason"
	fsm.Context[targetField] = nextState
	fsm.Context[reasonField] = reason
	fsm.State = releaseState
end

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
