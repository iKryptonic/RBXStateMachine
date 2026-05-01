--!strict
--[[
    @module PerformanceManager
    @author iKrypto
    @version 3.0
    @description Read-only performance query interface for the TaskScheduler.
]]

local PerformanceManager = {}
PerformanceManager.__index = PerformanceManager

function PerformanceManager.new(scheduler: any)
    return setmetatable({ _s = scheduler }, PerformanceManager)
end

function PerformanceManager:GetActiveTasks(): { [string]: any }
    local result = {}
    for name, t in pairs(self._s._running) do
        result[name] = t
    end
    return result
end

function PerformanceManager:GetTaskAverage(name: string): number
    local t = self._s.Tasks[name]
    if not t or t.RunCount == 0 then return 0 end
    return t.TotalRunTime / t.RunCount
end

function PerformanceManager:GetTaskMaximum(name: string): number
    local t = self._s.Tasks[name]
    return t and t.MaxRunTime or 0
end

function PerformanceManager:GetTaskCount(name: string): number
    local t = self._s.Tasks[name]
    return t and t.RunCount or 0
end

function PerformanceManager:GetStatsSnapshot(): { [string]: any }
    local stats = {}
    for name, t in pairs(self._s.Tasks) do
        stats[name] = {
            RunCount = t.RunCount,
            RunTimeAverage = t.RunCount > 0 and (t.TotalRunTime / t.RunCount) or 0,
            RunTimeMax = t.MaxRunTime,
            MemoryAverage = t.RunCount > 0 and ((t.TotalMemory or 0) / t.RunCount) or 0,
            MemoryMax = t.MaxMemory or 0,
        }
    end
    return stats
end

return PerformanceManager
