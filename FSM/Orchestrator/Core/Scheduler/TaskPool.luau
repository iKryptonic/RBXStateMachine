--!strict
--[=[
	@Name TaskPool
	@Author iKrypto
	@Description Lightweight object pool for Scheduler task records. Reuses table
	instances to reduce allocation churn while tasks are frequently scheduled,
	executed, and released.
]=]
local TaskPool = {
    _storage = table.create(100),
    _count = 0
}

export type Task = {
    Name: string,
    Action: () -> (),
    Delay: number,
    IsRecurringTask: boolean,
    Priority: number,
    Event: string,
    NextRun: number,
    RunCount: number,
    TotalRunTime: number,
    MaxRunTime: number,
    TotalMemory: number,
    MaxMemory: number,
    CreationTime: number,
    LastRunTime: number?,
}

--[[
    @description Returns a task object from the pool or creates a new one.
    @return Task -- Reusable task record ready to be populated by Scheduler:Schedule
    @reads TaskPool._count, TaskPool._storage
    @writes TaskPool._count, TaskPool._storage
]]
function TaskPool.Get(): Task
    if TaskPool._count > 0 then
        local t = TaskPool._storage[TaskPool._count]
        TaskPool._storage[TaskPool._count] = nil -- Clear reference
        TaskPool._count -= 1
        return t
    end
    
    return {
        Name = "", 
        Action = nil :: any, 
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
        LastRunTime = nil,
    }
end

--[[
    @description Cleans and returns a task object to the pool.
    @param t Task -- Task record that is no longer scheduled or running
    @return ()
    @reads None
    @writes t.*, TaskPool._count, TaskPool._storage
]]
function TaskPool.Release(t: Task)
    -- IMPORTANT: Nil out the Action to prevent closure/environment leaks
    t.Action = nil :: any
    t.Name = ""
    t.Delay = 0
    t.IsRecurringTask = false
    t.Priority = 0
    t.Event = ""
    t.NextRun = 0
    t.RunCount = 0
    t.TotalRunTime = 0
    t.MaxRunTime = 0
    t.TotalMemory = 0
    t.MaxMemory = 0
    t.CreationTime = 0
    t.LastRunTime = nil
    
    TaskPool._count += 1
    TaskPool._storage[TaskPool._count] = t
end

--[[
    @description Reduces the pool size to a target amount to reclaim memory.
    @param target number? -- The amount of objects to keep (defaults to 10)
    @return ()
    @reads TaskPool._count
    @writes TaskPool._storage, TaskPool._count
]]
function TaskPool.Shrink(target: number?)
    local keepCount = target or 10
    if TaskPool._count <= keepCount then return end
    
    -- Clear references from the top of the stack down to the target
    for i = TaskPool._count, keepCount + 1, -1 do
        TaskPool._storage[i] = nil
    end
    
    TaskPool._count = keepCount
end

return TaskPool