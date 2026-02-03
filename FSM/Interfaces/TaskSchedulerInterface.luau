--!strict
-- @Interface SchedulerInterface
-- @Description Detailed interface documentation for the Scheduler class.

-- Definition of a scheduled task
export type Task = {
	Name: string, -- Unique name of the task
	Action: () -> (), -- The function to execute
	NextRun: number, -- Timestamp for the next execution
	Delay: number, -- Delay between executions (for recurring tasks)
	IsRecurringTask: boolean, -- True if it repeats
	Priority: number, -- Higher numbers run earlier in the frame
	Event: string, -- The RunService event name (e.g., "Heartbeat")
	
	-- Performance Stats
	RunCount: number,
	TotalRunTime: number,
	MaxRunTime: number,
	CreationTime: number,
	Reset: () -> (), -- Resets stats
}

-- Parameters for scheduling a task
export type ScheduleTaskParams = {
	TaskName: string, -- Unique name
	TaskAction: () -> (), -- Function to run
	TaskExecutionDelay: number?, -- Initial delay in seconds
	IsRecurringTask: boolean?, -- Should it repeat?
	Priority: number?, -- Execution priority (default 1)
	Event: string? -- RunService event (default "Heartbeat")
}

-- The Scheduler Class Interface
export type Scheduler = {
	-- Properties
	Settings: any, -- Configuration table
	History: {any}, -- List of recent execution history
	LastFrameStats: { FrameTime: number, TaskCount: number, Budget: number }, -- Stats from the last Step

	-- Methods

	--[[
		Initializes the scheduler with optional settings.
		@param settings Optional configuration table.
		@return The scheduler instance.
	]]
	Initialize: (self: Scheduler, settings: any?) -> Scheduler,

	--[[
		Clears all tasks, history, and statistics.
	]]
	Clear: (self: Scheduler) -> (),

	--[[
		Schedules a new task.
		@param params Configuration for the task.
		@return The created Task object or nil if invalid.
	]]
	Schedule: (self: Scheduler, params: ScheduleTaskParams) -> Task?,

	--[[
		Cancels a task by name.
		@param name The name of the task to remove.
	]]
	Deschedule: (self: Scheduler, name: string) -> (),

	--[[
		Retrieves a task object by name.
		@param name The task name.
		@return The Task object or nil.
	]]
	GetTask: (self: Scheduler, name: string) -> Task?,

	--[[
		Returns the total number of scheduled tasks.
		@return Count of tasks.
	]]
	GetTaskCount: (self: Scheduler) -> number,

	--[[
		Manually executes a task immediately, bypassing the schedule.
		@param taskOrName The Task object or its name.
	]]
	ExecuteTask: (self: Scheduler, taskOrName: string | Task) -> (),

	--[[
		Returns a serializable snapshot of the scheduler state for debugging/sync.
		@return Table containing Tasks, Logs, Settings, History, etc.
	]]
	GetSyncData: (self: Scheduler) -> any,

	--[[
		(Server Only) Sets up the RemoteFunction for client-side admin access.
	]]
	ExposeAPI: (self: Scheduler) -> (),

	--[[
		Resets the performance statistics for a specific task.
		@param name The task name.
	]]
	ResetTask: (self: Scheduler, name: string) -> (),

	--[[
		Generates a unique GUID string.
		@return A unique string ID.
	]]
	GenerateKey: (self: Scheduler) -> string,

	--[[
		Connects the scheduler to RunService events (Heartbeat, etc.).
		Must be called to start processing tasks.
	]]
	Start: (self: Scheduler) -> ()
}

return {}
