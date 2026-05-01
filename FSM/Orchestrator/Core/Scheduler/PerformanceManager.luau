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

--[[
    @description Creates a new PerformanceManager bound to a Scheduler instance.
    @param scheduler any -- Scheduler instance whose task/runtime tables will be inspected
    @return PerformanceManager -- Thin wrapper used for diagnostics and UI snapshots
    @reads None
    @writes self._s
]]
function PerformanceManager.new(scheduler)
    return setmetatable({
        _s = scheduler
    }, PerformanceManager)
end

--[[
    @description Returns a shallow snapshot of currently running tasks.
    @return { [string]: any } -- Task name to live task record map
    @reads self._s._running
    @writes None
]]
function PerformanceManager:GetActiveTasks()
    local result = {}
    -- Shallow copy of the running tasks for UI/Debugging
    for name, task in pairs(self._s._running) do
        result[name] = task
    end
    return result
end

--[[
    @description Returns the average runtime for a scheduled task.
    @param name string -- Registered task name
    @return number -- Average runtime in seconds, or 0 when the task has never run
    @reads self._s.Tasks
    @writes None
]]
function PerformanceManager:GetTaskAverage(name: string): number
    local task = self._s.Tasks[name]
    if not task or task.RunCount == 0 then return 0 end
    return task.TotalRunTime / task.RunCount
end

--[[
    @description Returns the maximum observed runtime for a scheduled task.
    @param name string -- Registered task name
    @return number -- Longest execution time in seconds, or 0 when unknown
    @reads self._s.Tasks
    @writes None
]]
function PerformanceManager:GetTaskMaximum(name: string): number
    local task = self._s.Tasks[name]
    if not task then return 0 end
    return task.MaxRunTime
end

--[[
    @description Returns how many times a scheduled task has executed.
    @param name string -- Registered task name
    @return number -- Run count, or 0 when the task is unknown
    @reads self._s.Tasks
    @writes None
]]
function PerformanceManager:GetTaskCount(name: string): number
    local task = self._s.Tasks[name]
    if not task then return 0 end
    return task.RunCount
end

--[[
    @description Returns a serializable snapshot of per-task timing and memory counters.
    @return { [string]: { RunCount: number, RunTimeAverage: number, RunTimeMax: number, MemoryAverage: number, MemoryMax: number } }
    @reads self._s.Tasks
    @writes None
]]
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