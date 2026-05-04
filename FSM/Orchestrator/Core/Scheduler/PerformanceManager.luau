--!strict
--[=[
	@Name PerformanceManager
	@Author iKrypto
	@Description Read-only facade over Scheduler runtime counters. Produces snapshots
	for dashboards and diagnostics without exposing mutation helpers that could skew
	scheduler accounting.
]=]
local PerformanceManager = {}
PerformanceManager.__index = PerformanceManager

--[=[
	@description Constructs a PerformanceManager bound to a Scheduler instance. Stores
	the scheduler reference as `_s`. All reads are live against the scheduler's state at
	call time; no counters are copied or cached on construction.
	@param scheduler any -- The Scheduler instance this facade observes.
	@return PerformanceManager -- New facade instance.
]=]
function PerformanceManager.new(scheduler)
	return setmetatable({
		_s = scheduler
	}, PerformanceManager)
end


--[=[
	@description Returns a shallow copy of `_s._running`, mapping task names to their
	live Task records. Reflects the exact set of tasks currently executing inside
	coroutines at the moment of the call; entries appear only while `_internalExecute`
	has started and not yet finished.
	@return { [string]: Task } -- Map of task name to active Task record.
]=]
function PerformanceManager:GetActiveTasks()
	local result = {}
	-- Shallow copy of the running tasks for UI/Debugging
	for name, task in pairs(self._s._running) do
		result[name] = task
	end
	return result
end


--[=[
	@description Returns the mean wall-clock execution time (in seconds) for task `name`,
	computed as `TotalRunTime / RunCount`. Returns 0 if the task is not currently
	registered or has never completed a run.
	@param name string -- The `TaskName` to query.
	@return number -- Average execution time in seconds, or 0.
]=]
function PerformanceManager:GetTaskAverage(name: string): number
	local task = self._s.Tasks[name]
	if not task or task.RunCount == 0 then return 0 end
	return task.TotalRunTime / task.RunCount
end


--[=[
	@description Returns the single-run peak wall-clock execution time (in seconds) for
	task `name`, stored in `MaxRunTime`. Returns 0 if the task is not registered.
	@param name string -- The `TaskName` to query.
	@return number -- Worst-case execution time in seconds, or 0.
]=]
function PerformanceManager:GetTaskMaximum(name: string): number
	local task = self._s.Tasks[name]
	if not task then return 0 end
	return task.MaxRunTime
end


--[=[
	@description Returns the total number of times task `name` has completed execution
	(`RunCount`). Returns 0 if the task is not registered. Does not include runs that
	errored before completing the counter increment.
	@param name string -- The `TaskName` to query.
	@return number -- Completed execution count, or 0.
]=]
function PerformanceManager:GetTaskCount(name: string): number
	local task = self._s.Tasks[name]
	if not task then return 0 end
	return task.RunCount
end


--[=[
	@description Returns a table mapping every currently registered task name to a stats
	record with five fields: `RunCount`, `RunTimeAverage` (seconds), `RunTimeMax`
	(seconds), `MemoryAverage` (KB), and `MemoryMax` (KB). Iterates `_s.Tasks` live at
	call time; tasks descheduled between calls will not appear in subsequent snapshots.
	@return { [string]: { RunCount: number, RunTimeAverage: number, RunTimeMax: number, MemoryAverage: number, MemoryMax: number } }
]=]
function PerformanceManager:GetStatsSnapshot()
	local stats = {}
	for name, task in pairs(self._s.Tasks) do
		stats[name] = {
			RunCount = task.RunCount,
			RunTimeAverage = task.RunCount > 0 and (task.TotalRunTime / task.RunCount) or 0,
			RunTimeMax = task.MaxRunTime,
			MemoryAverage = task.RunCount > 0 and (task.TotalMemory / task.RunCount) or 0,
			MemoryMax = task.MaxMemory or 0
		}
	end
	return stats
end

return PerformanceManager
