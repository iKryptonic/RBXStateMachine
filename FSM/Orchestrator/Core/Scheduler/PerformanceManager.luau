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


function PerformanceManager.new(scheduler)
	return setmetatable({
		_s = scheduler
	}, PerformanceManager)
end


function PerformanceManager:GetActiveTasks()
	local result = {}
	-- Shallow copy of the running tasks for UI/Debugging
	for name, task in pairs(self._s._running) do
		result[name] = task
	end
	return result
end


function PerformanceManager:GetTaskAverage(name: string): number
	local task = self._s.Tasks[name]
	if not task or task.RunCount == 0 then return 0 end
	return task.TotalRunTime / task.RunCount
end


function PerformanceManager:GetTaskMaximum(name: string): number
	local task = self._s.Tasks[name]
	if not task then return 0 end
	return task.MaxRunTime
end


function PerformanceManager:GetTaskCount(name: string): number
	local task = self._s.Tasks[name]
	if not task then return 0 end
	return task.RunCount
end


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
