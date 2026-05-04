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


--[=[
	@description Acquires a Task record from the free list. If `_count > 0`, pops the
	top item from `_storage`, clears its slot, and decrements `_count`. If the pool is
	empty, allocates a new table with all Task fields zeroed. Callers must reinitialize
	all fields before registering the record with the Scheduler.
	@return Task -- A blank or zeroed Task record ready to be populated.
]=]
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


--[=[
	@description Returns a completed Task record to the free list. Nils `Action` first to
	release any captured closures and prevent environment leaks, then zeroes all other
	fields. Increments `_count` and stores `t` at the new top of `_storage`. Must only be
	called after the task has fully completed execution; the Scheduler calls this
	automatically for non-recurring tasks and for stale heap entries.
	@param t Task -- The Task record to return to the pool.
	@return nil
]=]
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


--[=[
	@description Trims the free list to at most `target` entries (default 10) to bound
	memory after bulk task releases. Nils out `_storage` slots from the top of the stack
	down to `target + 1`, then sets `_count = target`. No-ops if `_count` is already at
	or below `target`. Called by `Scheduler:PrunePool` when the free list exceeds 100
	objects.
	@param target number? -- Maximum number of free entries to retain; defaults to 10.
	@return nil
]=]
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
