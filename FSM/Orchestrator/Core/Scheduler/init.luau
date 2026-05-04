--!strict

--[=[
	@module Scheduler
	@description Frame-budget-aware, priority-driven task scheduler. Maintains per-event
	min-heaps keyed by RunService event name (Heartbeat, Stepped, PreSimulation, etc.).
	On each `Step`, pops all due tasks from the relevant heap, executes them in coroutines
	drawn from a shared thread pool, and reschedules recurring tasks. Writes
	`LastFrameStats` after every step. Requires `Initialize` before any instance is
	created or any method is invoked.
]=]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- Localize globals for speed
local os_clock = os.clock
local table_insert = table.insert
local table_remove = table.remove
local math_floor = math.floor
local xpcall = xpcall
local task_spawn = task.spawn

local defaultInstance = nil
local Initialized = false

local Scheduler = {}

local TaskPool = require(script.TaskPool)
local PerformanceManager = require(script.PerformanceManager)

local freeThreads = {}
local totalThreads = 0
local peakThreads = 0
local activeThreads = 0

local function runTask(func, thread, ...)
	func(...)
	activeThreads = math.max(0, activeThreads - 1)
	table_insert(freeThreads, thread)
end

local function yielder()
	while true do
		runTask(coroutine.yield())
	end
end

-- Static Error Handler to avoid closure creation
local function ERROR_HANDLER(err)
	return debug.traceback(tostring(err), 2)
end

local function ValidateRequest()
	assert(Initialized,"Scheduler not initialized")
end

local function ResolveScheduler(self: any)
	ValidateRequest()
	if type(self) == "table" and rawget(self,"_heaps") then
		return self
	end
	if not defaultInstance then
		defaultInstance = Scheduler.new()
	end
	return defaultInstance
end

local function GetWeightedTime(self, delay: number, priority: number)
	-- Higher priority results in a "smaller" (earlier) timestamp for the Min-Heap
	local weight = self.Settings.PriorityWeight or 0.001
	return os_clock() + delay - (priority * weight)
end

do
	Scheduler.__index = Scheduler


	--[=[
		@description One-time module initialization. Reads `Util.Settings.Scheduler` into
		the shared `Scheduler.Settings`, constructs a named Logger from `Util.Logger`, and
		stores `Util.StaticStrings`. Sets the module-level `Initialized` flag so subsequent
		calls are no-ops. Must be called before any Scheduler instance is created or any
		method is invoked.
		@param Util any -- Utility bundle exposing `Settings.Scheduler`, `Logger.new`, and `StaticStrings`.
		@return nil
	]=]
	function Scheduler.Initialize(Util: any)
		if Initialized then return end
		Initialized = true
		Scheduler.Settings = Util.Settings.Scheduler
		Scheduler.Logger = Util.Logger.new({Name = "Scheduler"})
		Scheduler.Strings = Util.StaticStrings
	end


	--[=[
		@description Constructs a new independent Scheduler instance. Initializes empty
		`Tasks`, `_heaps`, `_running`, and `_connections` tables, a ring-buffer `History`
		of 100 slots, `LastFrameStats`, and a fresh `PerformanceManager` bound to this
		instance. `settings` overrides the global defaults (FrameBudget, PriorityWeight).
		Does not start RunService connections; call `Start()` separately.
		@param settings any? -- Optional config table; keys `FrameBudget` (seconds) and `PriorityWeight` (time shift per priority unit).
		@return Scheduler -- New scheduler instance.
	]=]
	function Scheduler.new(settings: any?)
		local self = setmetatable({
			Tasks = {},
			History = table.create(100),
			_historyIndex = 1,
			_heaps = {},
			_running = {},
			_connections = {},
			_taskCount = 0, -- O(1) tracking
			TaskStats = {},
			LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 },
			Settings = settings or Scheduler.Settings or {
				FrameBudget = 0.005,
				PriorityWeight = 0.001, -- How much 1 priority point "shifts" time
			},
			Logger = nil,
		}, Scheduler)

		self.PerformanceManager = PerformanceManager.new(self)
		return self
	end


	--[=[
		@description Registers a task for deferred execution. Acquires a `Task` record from
		the pool, populates it from `params`, and computes `NextRun` as the current clock
		plus the delay minus a priority offset (higher priority → earlier timestamp). Inserts
		the record into the per-event min-heap. If a task with the same name already exists,
		the old heap entry is abandoned and cleaned up lazily during the next `Step`.
		Increments `_taskCount` for genuinely new task names. Returns the Task record, or
		nil if `TaskName` is missing or `TaskAction` is not a function.
		@param params any -- Table with fields: `TaskName` (string), `TaskAction` (function), `TaskExecutionDelay` (number?), `IsRecurringTask` (boolean?), `Priority` (number?), `Event` (string? defaults to "Heartbeat").
		@return Task? -- The registered Task record, or nil on invalid input.
	]=]
	function Scheduler:Schedule(params: any)
		if not params.TaskName or type(params.TaskAction) ~= "function" then return nil end

		-- Use the Pool
		local t = TaskPool.Get()
		t.Name = params.TaskName
		t.Action = params.TaskAction
		t.Delay = params.TaskExecutionDelay or 0
		t.IsRecurringTask = params.IsRecurringTask or false
		t.Priority = params.Priority or 1
		-- Default to Heartbeat if Event is missing or nil
		t.Event = params.Event or "Heartbeat"
		t.NextRun = GetWeightedTime(self, t.Delay, t.Priority)
		t.CreationTime = os_clock()
		t.TotalMemory = 0
		t.MaxMemory = 0

		local isNew = not self.Tasks[t.Name]
		if not isNew then
			-- If overwriting, we should ideally release the old one,
			-- but since it's in the Heap, lazy removal handles it.
			self.Tasks[t.Name] = nil
		end

		self.Tasks[t.Name] = t
		if isNew then
			self._taskCount += 1
		end
		if not self._heaps[t.Event] then self._heaps[t.Event] = {} end
		self:_heapPush(self._heaps[t.Event], t)

		return t
	end


	--[=[
		@description Resets the instance to an empty state. Clears `Tasks`, `_heaps`,
		`History`, `TaskStats`, `LastFrameStats`, `_historyIndex`, and `_taskCount`. Does
		not disconnect RunService events, release pooled coroutines, or affect the shared
		thread pool counters.
		@return nil
	]=]
	function Scheduler:Clear()
		self.Tasks = {}
		self._heaps = {}
		self.History = {}
		self.LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 }
		if self.TaskStats then table.clear(self.TaskStats) end
		self._historyIndex = 1
		self._taskCount = 0
	end


	--[=[
		@description Appends an execution record to the ring-buffer `History`. Writes
		`Name`, `Status`, `Duration`, `Time` (wall-clock seconds), and optional `Error`
		string to slot `_historyIndex`, then advances the index modulo 100, overwriting the
		oldest entry when the buffer is full.
		@param taskObj any -- Task record; only `Name` is read.
		@param status any -- Outcome string, e.g. "Completed", "Failed", or "Cancelled".
		@param duration any -- Wall-clock execution time in seconds.
		@param err string? -- Error message to store; nil for successful completions.
		@return nil
	]=]
	function Scheduler:AddToHistory(taskObj, status, duration, err: string?)
		local entry = {
			Name = taskObj.Name,
			Status = status,
			Duration = duration,
			Time = os.time(),
			Error = err
		}
		self.History[self._historyIndex] = entry
		self._historyIndex = (self._historyIndex % 100) + 1
	end


	--[=[
		@description Removes a named task from `Tasks` and decrements `_taskCount`. Appends
		a "Cancelled" history entry and logs the removal. The stale entry in the min-heap is
		cleaned up lazily the next time `Step` encounters it. No-ops if the name is not
		currently registered.
		@param name string -- The `TaskName` of the task to cancel.
		@return nil
	]=]
	function Scheduler:Deschedule(name: string)
		self = ResolveScheduler(self)
		if self.Tasks[name] then
			self:AddToHistory(self.Tasks[name],"Cancelled", 0,"")
			self._taskCount -= 1
			self.Tasks[name] = nil
			local logger = self.Logger or Scheduler.Logger
			if logger then
				logger:Log({
					Level = "INFO",
					Message = string.format("Descheduled: %s", name),
				})
			end
		end
	end


	--[=[
		@description Returns the live Task record registered under `name`, or nil if not
		present. Resolves to `defaultInstance` when called on the class rather than on a
		specific instance.
		@param name string -- The `TaskName` to look up.
		@return Task? -- The Task record or nil.
	]=]
	function Scheduler:GetTask(name: string)
		self = ResolveScheduler(self)
		return self.Tasks[name]
	end


	--[=[
		@description Returns the O(1) counter `_taskCount` reflecting the number of
		currently registered tasks. Does not scan `Tasks` or the heaps.
		@return number -- Number of active tasks.
	]=]
	function Scheduler:GetTaskCount()
		return self._taskCount
	end


	--[=[
		@description Immediately executes a task outside of the normal `Step` cycle.
		Accepts either a task name string or a Task record directly. Logs the manual
		execution, then delegates to `_internalExecute`, which runs the action in a pooled
		coroutine and updates all per-task counters normally.
		@param taskOrName string | Task -- Task name or Task record to execute.
		@return nil
	]=]
	function Scheduler:ExecuteTask(taskOrName: string | Task)
		self = ResolveScheduler(self)
		local task: Task? = nil
		if type(taskOrName) == "string" then
			task = self.Tasks[taskOrName]
		else
			task = taskOrName
		end
		if not task then return end
		local logger = self.Logger or Scheduler.Logger
		if logger then
			logger:Log({
				Level = "INFO",
				Message = string.format("Manually Executed: %s", task.Name),
			})
		end
		self:_internalExecute(task)
	end


	--[=[
		@description Produces a serialization-safe snapshot of this scheduler's state.
		Strips all function-valued fields from each Task before returning. Returns a table
		containing `Tasks` (sanitized), `Logs` (from Logger history), `Settings`, `History`
		(ring buffer), `LastFrameStats`, and `TaskStats`. Intended for server→client
		dashboard replication where functions cannot cross the boundary.
		@return table -- Snapshot with keys: Tasks, Logs, Settings, History, LastFrameStats, TaskStats.
	]=]
	function Scheduler:GetSyncData()
		self = ResolveScheduler(self)
		local safeTasks = {}
		for name, task in pairs(self.Tasks) do
			local safeTask = {}
			for keyName, value in pairs(task) do
				if type(value) ~= "function" then
					safeTask[keyName] = value
				end
			end
			safeTasks[name] = safeTask
		end

		return {
			Tasks = safeTasks,
			Logs = self.Logger:GetHistory(),
			Settings = self.Settings,
			History = self.History,
			LastFrameStats = self.LastFrameStats,
			TaskStats = self.TaskStats
		}
	end


	--[=[
		@description Returns true if `player` should have admin access to scheduler
		diagnostics. Always returns true inside Roblox Studio. In live games, returns true
		only when `player.UserId` matches `game.CreatorId`.
		@param player Player -- The player to authorize.
		@return boolean -- True if the player is an authorized admin.
	]=]
	function Scheduler:CheckAdmin(player: Player)
		if RunService:IsStudio() then return true end
		return player.UserId == game.CreatorId
	end


	--[=[
		@description Resets accumulated performance counters for a named task. If the task
		exposes its own `Reset` function, calls it. Otherwise zeroes `RunCount`,
		`TotalRunTime`, `MaxRunTime`, `TotalMemory`, and `MaxMemory` directly, then logs
		the reset. No-ops if the task is not currently registered.
		@param name string -- The `TaskName` of the task to reset.
		@return nil
	]=]
	function Scheduler:ResetTask(name: string)
		self = ResolveScheduler(self)
		local task = self.Tasks[name]
		if task then
			if type(task.Reset) == "function" then
				task.Reset()
			else
				task.RunCount = 0
				task.TotalRunTime = 0
				task.MaxRunTime = 0
				task.TotalMemory = 0
				task.MaxMemory = 0
				local logger = self.Logger or Scheduler.Logger
				if logger then
					logger:Log({
						Level = "INFO",
						Message = string.format("Reset: %s", name),
					})
				end
			end
		end
	end


	--[=[
		@description Returns a new collision-free GUID string generated by
		`HttpService:GenerateGUID(false)`. Used to produce unique task names and FSM
		instance identifiers.
		@return string -- A fresh GUID string without braces.
	]=]
	function Scheduler:GenerateKey()
		return HttpService:GenerateGUID(false)
	end


	--[=[
		@description Returns a snapshot of the module-level coroutine thread pool counters
		shared across all Scheduler instances. Fields: `TotalThreads` (ever created),
		`FreeThreads` (available to pick up work), `ActiveThreads` (currently executing),
		and `PeakThreads` (historical maximum concurrent threads).
		@return table -- Thread pool stats: TotalThreads, FreeThreads, ActiveThreads, PeakThreads.
	]=]
	function Scheduler:GetThreadPoolStats()
		return {
			TotalThreads = totalThreads,
			FreeThreads = #freeThreads,
			ActiveThreads = activeThreads,
			PeakThreads = peakThreads,
		}
	end


	--[=[
		@description Executes a single Task record in a pooled coroutine. Acquires a free
		coroutine from `freeThreads` or creates a new yielder thread, incrementing
		`totalThreads` and updating `peakThreads`. Increments `activeThreads`. Marks the
		task in `_running` and records `LastRunTime`. Runs `t.Action` under `xpcall` with
		a traceback handler. After the call: updates `RunCount`, `TotalRunTime`,
		`MaxRunTime`, `TotalMemory`, and `MaxMemory`. For non-recurring tasks, appends to
		History, removes from `Tasks`, decrements `_taskCount`, and releases the record to
		`TaskPool`. If the task was replaced (stale `Tasks` pointer), releases it directly.
		An outer `pcall` guards the entire body so `activeThreads` and thread-return always
		execute; errors are reported via `warn`.
		@param t any -- The Task record to execute; must be a valid pool entry.
		@return nil
	]=]
	function Scheduler:_internalExecute(t)
		local thread
		if #freeThreads > 0 then
			thread = table_remove(freeThreads)
		else
			thread = coroutine.create(yielder)
			coroutine.resume(thread) -- Start the yielder
			totalThreads += 1
			if totalThreads > peakThreads then
				peakThreads = totalThreads
			end
		end
		activeThreads += 1

		-- We wrap the logic in a non-allocating wrapper
		task_spawn(thread, function()
			local ok, execErr = pcall(function()
				local start = os_clock()
				local startMem = collectgarbage("count")
				self._running[t.Name] = t
				-- Record the most recent execution wallclock so the dashboard
				-- can derive an "active vs idle" state without needing to
				-- track its own delta against `RunCount` (the server-context
				-- snapshot doesn't have access to a previous-tick delta).
				t.LastRunTime = start

				local s, e = xpcall(t.Action, ERROR_HANDLER)

				local dur = os_clock() - start
				local endMem = collectgarbage("count")
				local memDelta = math.max(0, endMem - startMem) -- Ignore negative delta if GC ran

				self._running[t.Name] = nil

				if self.Tasks[t.Name] == t then
					t.RunCount += 1
					t.TotalRunTime += dur
					if dur > t.MaxRunTime then t.MaxRunTime = dur end

					t.TotalMemory = (t.TotalMemory or 0) + memDelta
					if memDelta > (t.MaxMemory or 0) then t.MaxMemory = memDelta end

					if not t.IsRecurringTask then
						self:AddToHistory(t, s and "Completed" or "Failed", dur, not s and tostring(e) or nil)
						self.Tasks[t.Name] = nil
						self._taskCount -= 1
						TaskPool.Release(t)
					end
				else
					TaskPool.Release(t)
				end
			end)
			-- pcall ensures this closure never throws, so runTask
			-- always reaches its own activeThreads decrement and thread return.
			if not ok then
				self._running[t.Name] = nil
				warn("[Scheduler] Task execution error: " .. tostring(execErr))
			end
		end, thread)
	end


	--[=[
		@description Shrinks the `TaskPool` free list to 20 entries when it exceeds 100
		objects, bounding memory from bulk task releases. Calls `TaskPool.Shrink(20)` and
		logs the operation at DEBUG level if a Logger is available.
		@return nil
	]=]
	function Scheduler:PrunePool()
	-- Only shrink if the pool is significantly large
		if TaskPool._count > 100 then
			TaskPool.Shrink(20)
			local logger = self.Logger or Scheduler.Logger
			if logger then
				logger:Log({
					Level = "DEBUG",
					Message = "TaskPool pruned to 20 objects."
				})
			end
		end
	end


	--[=[
		@description Executes one frame's worth of due tasks for `eventName` (defaults to
		"Heartbeat"). Pops all entries with `NextRun <= now` from the corresponding
		min-heap, skipping stale entries via lazy removal (heap entry not matching
		`Tasks[name]`). Executes each due task through `_internalExecute`. Reschedules
		recurring tasks back into the heap with an updated `NextRun`. Stops early if elapsed
		time since step start exceeds `Settings.FrameBudget`, deferring remaining collected
		tasks back to the heap. Writes `LastFrameStats` with `FrameTime`, `TaskCount`, and
		`Budget` after every call.
		@param eventName string? -- RunService event name to process; defaults to "Heartbeat".
		@return nil
	]=]
	function Scheduler:Step(eventName: string?)
		local event = eventName or "Heartbeat"
		local heap = self._heaps[event]
		if not heap or #heap == 0 then return end

		local now = os_clock()
		local startTime = now
		local budget = self.Settings.FrameBudget

		-- 1. Collect all due tasks
		local dueTasks = {}
		local count = 0

		while #heap > 0 do
			local t = heap[1]

			-- Lazy Removal check
			if self.Tasks[t.Name] ~= t then
				self:_heapPop(heap)
				if not self._running[t.Name] then
					TaskPool.Release(t)
				end
				continue
			end

			if t.NextRun > now then break end

			-- Pop and add to execution list
			self:_heapPop(heap)
			count += 1
			dueTasks[count] = t
		end

		-- 2. Execute and Reschedule
		for i = 1, count do
			local t = dueTasks[i]
			self:_internalExecute(t)

			-- Reschedule if recurring
			if t.IsRecurringTask and self.Tasks[t.Name] == t then
				-- IMPORTANT: Ensure NextRun calculated here, but pushed back
				-- AFTER we are done popping, effectively shifting it to the next Step execution
				-- (because we are inside the same function/frame).
				-- Even if NextRun is now, it's safe because we already emptied the heap of *currently visible* due tasks.
				t.NextRun = GetWeightedTime(self, t.Delay, t.Priority)
				self:_heapPush(heap, t)
			end

			-- Budget Check
			if (os_clock() - startTime) >= budget then
				-- If we hit budget, we must re-push the REMAINING tasks (that we popped but didn't run)
				for j = i + 1, count do
					local deferred = dueTasks[j]

					-- Optimization: increment deferred priority slightly? No, keep simple.
					self:_heapPush(heap, deferred)
				end
				break
			end
		end

		-- 3. Update LastFrameStats
		local frameTime = os_clock() - startTime
		self.LastFrameStats = {
			FrameTime = frameTime,
			TaskCount = count,
			Budget = budget
		}
	end


	--[=[
		@description Inserts `item` into the min-heap array `heap` ordered by `NextRun`.
		Appends the item to the end and bubbles it up by swapping with its parent until
		heap order is restored. Mutates `heap` in-place.
		@param heap any -- The min-heap array for a specific event.
		@param item any -- Task record with a `NextRun` field.
		@return nil
	]=]
	function Scheduler:_heapPush(heap, item)
		table_insert(heap, item)
		local idx = #heap
		while idx > 1 do
			local parent = math_floor(idx / 2)
			if heap[idx].NextRun < heap[parent].NextRun then
				heap[idx], heap[parent] = heap[parent], heap[idx]
				idx = parent
			else break end
		end
	end


	--[=[
		@description Removes and returns the root item (minimum `NextRun`) from `heap`.
		Moves the last element to the root and sifts it down to restore heap order. Returns
		nil if the heap is empty. Mutates `heap` in-place.
		@param heap any -- The min-heap array to pop from.
		@return Task? -- The Task record with the smallest NextRun, or nil if empty.
	]=]
	function Scheduler:_heapPop(heap)
		local size = #heap
		if size == 0 then return nil end
		local root = heap[1]

		if size > 1 then
			heap[1] = heap[size]
			heap[size] = nil
			size -= 1
			local idx = 1
			while true do
				local left, right = 2 * idx, 2 * idx + 1
				local smallest = idx
				if left <= size and heap[left].NextRun < heap[smallest].NextRun then smallest = left end
				if right <= size and heap[right].NextRun < heap[smallest].NextRun then smallest = right end
				if smallest == idx then break end
				heap[idx], heap[smallest] = heap[smallest], heap[idx]
				idx = smallest
			end
		else
			heap[1] = nil
		end
		return root
	end


	--[=[
		@description Connects `Step` to each supported RunService event: Heartbeat,
		Stepped, PreSimulation, PostSimulation, and PreAnimation on both server and client;
		additionally RenderStepped and PreRender on the client only. Stores connections in
		`_connections` keyed by event name. No-ops if already started (Heartbeat connection
		present). Logs the start at INFO level.
		@return nil
	]=]
	function Scheduler:Start()
		if self._connections.Heartbeat then return end

		local ValidStates =
		{
			"Heartbeat",
			"Stepped",
			"PreSimulation",
			"PostSimulation",
			"PreAnimation"
		}
		local ClientStates = {
			"RenderStepped",
			"PreRender",
		}

		for _, state in ipairs(ValidStates) do
			self._connections[state] = RunService[state]:Connect(function(dt)
				self:Step(state)
			end)
		end
		if RunService:IsClient() then
			for _, state in ipairs(ClientStates) do
				self._connections[state] = RunService[state]:Connect(function(dt)
					self:Step(state)
				end)
			end
		end
		self.Logger:Log({
			Level = "INFO",
			Message = "Scheduler started."
		})
	end


	--[=[
		@description Disconnects all RunService event connections stored in `_connections`
		and clears the table. Tasks remain registered and the thread pool is unaffected;
		calling `Start()` again resumes execution.
		@return nil
	]=]
	function Scheduler:Stop()
		for state, conn in pairs(self._connections) do
			if conn and typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			end
		end
		table.clear(self._connections)
	end
end
return Scheduler
