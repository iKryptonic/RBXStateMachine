--!strict
-- @Name Scheduler
-- @Author ikrypto
-- @Date 2026-01-26
-- @Description Lightweight Task Scheduler with basic performance tracking.

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

local function runTask(func, thread, ...)
    func(...)
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
	assert(Initialized, "Scheduler not initialized")
end

local function ResolveScheduler(self: any)
	ValidateRequest()
	if type(self) == "table" and rawget(self, "_heaps") then
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

	function Scheduler.Initialize(Util: any)
		if Initialized then return end
		Initialized = true
		Scheduler.Settings = Util.Settings.Scheduler
		Scheduler.Logger = Util.Logger.new({Name = "Scheduler"})
		Scheduler.Strings = Util.StaticStrings
	end

	--[[
		@description Creates a new Scheduler instance.
		@param settings any? -- Optional settings table
		@return any -- Scheduler instance
	]]
	function Scheduler.new(settings: any?)
		local self = setmetatable({
			Tasks = {},
			TaskStats = {},
			History = table.create(100),
			_historyIndex = 1,
			_heaps = {},
			_running = {},
			_connections = {},
			_taskCount = 0, -- O(1) tracking
			Settings = settings or {
				FrameBudget = 0.005,
				PriorityWeight = 0.001, -- How much 1 priority point "shifts" time
			},
			Logger = nil,
		}, Scheduler)
		
		self.PerformanceManager = PerformanceManager.new(self)
		return self
	end

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
        t.NextRun = os_clock() + t.Delay
        t.CreationTime = os_clock()

        if self.Tasks[t.Name] then
            -- If overwriting, we should ideally release the old one,
            -- but since it's in the Heap, lazy removal handles it.
            self._taskCount -= 1
            self.Tasks[t.Name] = nil
        end

        self.Tasks[t.Name] = t
        self._taskCount += 1
        if not self._heaps[t.Event] then self._heaps[t.Event] = {} end
        self:_heapPush(self._heaps[t.Event], t)
        
        return t
    end

	--[[
		@description Clears all scheduled tasks, heaps, history, and stats.
		@return ()
	]]
	function Scheduler:Clear()
		self.Tasks = {}
		self._heaps = {}
		self._taskCount = 0
		self.History = {}
		self._historyIndex = 1
		self.LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 }
		if self.TaskStats then table.clear(self.TaskStats) end
	end

	--[[
		@description Adds an entry to History (best-effort; used by ServiceManager).
		@param taskObj any
		@param status any
		@param duration any
		@param err string?
		@return ()
	]]
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

	--[[
		@description Deschedules (cancels) a task by name.
		@param name string
		@return ()
	]]
	function Scheduler:Deschedule(name: string)
		self = ResolveScheduler(self)
		if self.Tasks[name] then
			self:AddToHistory(self.Tasks[name], "Cancelled", 0, "")
			self.Tasks[name] = nil
			self.Logger:Log({
				Level = "INFO",
				Message = string.format("Descheduled: %s", name),
			})
		end
	end

	--[[
		@description Gets a task by name.
		@param name string
		@return Task?
	]]
	function Scheduler:GetTask(name: string)
		self = ResolveScheduler(self)
		return self.Tasks[name]
	end

	--[[
		@description Returns the number of currently scheduled tasks.
		@return number
	]]
	function Scheduler:GetTaskCount()
		return self._taskCount
	end

	--[[
		@description Executes a task immediately by name or task object.
		@param taskOrName string | Task
		@return ()
	]]
	function Scheduler:ExecuteTask(taskOrName: string | Task)
		self = ResolveScheduler(self)
		local task: Task? = nil
		if type(taskOrName) == "string" then
			task = self.Tasks[taskOrName]
		else
			task = taskOrName
		end
		if not task then return end
		self.Logger:Log({
			Level = "INFO",
			Message = string.format("Manually Executed: %s", task.Name),
		})
		self:_internalExecute(task)
	end

	--[[
		@description Returns a sanitized snapshot for ServiceManager server sync.
		@return any -- Serializable data
	]]
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

	--[[
		@description Checks whether a player is authorized to use admin-only API.
		@param player Player
		@return boolean
	]]
	function Scheduler:CheckAdmin(player: Player)
		if RunService:IsStudio() then return true end
		return player.UserId == game.CreatorId
	end

	--[[
		@description Resets a task's performance counters.
		@param name string
		@return ()
	]]
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
				self.Logger:Log({
					Level = "INFO",
					Message = string.format("Reset: %s", name),
				})
			end
		end
	end

	--[[
		@description Generates a GUID key string.
		@return string
	]]
	function Scheduler:GenerateKey()
		return HttpService:GenerateGUID(false)
	end

	--[[
		@description Internal execution wrapper with performance tracking and error capture.
		@param t Task
		@return ()
	]]
	function Scheduler:_internalExecute(t)
		local thread
		if #freeThreads > 0 then
			thread = table_remove(freeThreads)
		else
			thread = coroutine.create(yielder)
			coroutine.resume(thread) -- Start the yielder
		end

		-- We wrap the logic in a non-allocating wrapper
		task_spawn(thread, function()
			local start = os_clock()
			self._running[t.Name] = t
			
			local s, e = xpcall(t.Action, ERROR_HANDLER)
			
			local dur = os_clock() - start
			self._running[t.Name] = nil

			if self.Tasks[t.Name] == t then
				t.RunCount += 1
				t.TotalRunTime += dur
				if dur > t.MaxRunTime then t.MaxRunTime = dur end
				
				if not t.IsRecurringTask then
					self:AddToHistory(t, s and "Completed" or "Failed", dur, not s and tostring(e) or nil)
					self.Tasks[t.Name] = nil
					self._taskCount -= 1
					TaskPool.Release(t)
				end
			end
		end, thread)
	end

	--[[
		@description Reduces the pool size to a target amount to reclaim memory.
		@param target number? -- The amount of objects to keep (defaults to 10)
	]]
	function Scheduler:PrunePool()
    -- Only shrink if the pool is significantly large
		if TaskPool._count > 100 then
			TaskPool.Shrink(20)
			self.Logger:Log({
				Level = "DEBUG",
				Message = "TaskPool pruned to 20 objects."
			})
		end
	end

	--[[
		@description Executes due tasks for the given event name (frame-budgeted).
		@param eventName string?
		@return ()
	]]
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
				TaskPool.Release(t)
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
	end

	--[[
		@description Pushes an item into a min-heap sorted by NextRun.
		@param heap { Task }
		@param item Task
		@return ()
	]]
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

	--[[
		@description Pops the earliest item from a min-heap sorted by NextRun.
		@param heap { Task }
		@return Task
		]]
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
end
return Scheduler