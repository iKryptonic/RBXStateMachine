--!strict
--[[
    @module TaskPool
    @author iKrypto
    @version 3.0
    @description Object pool for ScheduledTask structs.
    Reduces GC pressure by recycling task objects.
    
    Usage:
        local TaskPool = require(path.to.TaskPool)
        local t = TaskPool.Get()
        -- use t ...
        TaskPool.Release(t)
]]

local TaskPool = {
    _storage = table.create(100) :: { any },
    _count = 0,
}

--[[
    @description Returns a task object from the pool, or creates a fresh one.
    @return ScheduledTask
]]
function TaskPool.Get(): any
    if TaskPool._count > 0 then
        local t = TaskPool._storage[TaskPool._count]
        TaskPool._storage[TaskPool._count] = nil
        TaskPool._count -= 1
        return t
    end

    return {
        Name = "",
        Action = nil :: (() -> ())?,
        Delay = 0,
        IsRecurringTask = false,
        Priority = 0,
        Event = "",
        NextRun = 0,
        RunCount = 0,
        TotalRunTime = 0,
        MaxRunTime = 0,
        TotalMemory = 0,
        MaxMemory = 0,
        CreationTime = 0,
    }
end

--[[
    @description Cleans and returns a task object to the pool.
    IMPORTANT: Nils out Action to prevent closure/environment leaks.
    @param t ScheduledTask
]]
function TaskPool.Release(t: any)
    t.Action = nil
    t.Name = ""
    t.RunCount = 0
    t.TotalRunTime = 0
    t.MaxRunTime = 0
    t.TotalMemory = 0
    t.MaxMemory = 0

    TaskPool._count += 1
    TaskPool._storage[TaskPool._count] = t
end

--[[
    @description Reduces pool size to reclaim memory.
    @param target number? -- Objects to keep (default 10)
]]
function TaskPool.Shrink(target: number?)
    local keep = target or 10
    if TaskPool._count <= keep then return end

    for i = TaskPool._count, keep + 1, -1 do
        TaskPool._storage[i] = nil
    end
    TaskPool._count = keep
end

--[[
    @description Returns current pool size.
    @return number
]]
function TaskPool.GetCount(): number
    return TaskPool._count
end

return TaskPool
