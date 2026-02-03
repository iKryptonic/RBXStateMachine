--!strict
-- @Name Scheduler
-- @Author ikrypto
-- @Date 2026-01-26
-- @Description Lightweight Task Scheduler with basic performance tracking.

local Types = require(script.Parent.Types)
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Scheduler = {}

local defaultInstance: any = nil

local function ResolveScheduler(self: any)
	if type(self) == "table" and rawget(self, "_heaps") then
		return self
	end
	if not defaultInstance then
		defaultInstance = Scheduler.new()
	end
	return defaultInstance
end

-- Custom __index to allow scheduler["TaskName"] lookups for ServiceManager compatibility
Scheduler.__index = function(self, key)
	-- 1. Check for methods/class members
	if Scheduler[key] ~= nil then return Scheduler[key] end

	-- 2. Check for instance properties (Tasks, _heaps, etc.)
	local raw = rawget(self, key)
	if raw ~= nil then return raw end

	-- 3. Fallback to dynamic task lookups
	if type(key) == "string" then
		local tasks = rawget(self, "Tasks")
		return tasks and tasks[key]
	end
	return nil
end

-- Use shared types
type Task = Types.Task
type ScheduleTaskParams = Types.ScheduleTaskParams

--[[
	@summary Creates a new Scheduler instance.
	@param settings any? -- Optional settings table
	@return any -- Scheduler instance
]]
function Scheduler.new(settings: any?)
	local self;
	self = setmetatable({
		Tasks = {} :: { [string]: Task },
		History = {},
		_heaps = {} :: { [string]: { Task } },
		_running = {} :: { [string]: Task },
		LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 },
		TaskStats = {},

		Settings = settings or {
			PerformanceManagerSettings = {
				WarnOnLongThreadExecutions = true,
				MaximumThreadWarningThreshold = 0.5,
				KillRunawayTasks = false,
				RunawayTaskThreshold = 5,
			},
			FrameBudget = 0.005,
			Logging = {
				Enabled = true,
				Level = 1, -- 1=Info, 2=Warn, 3=Error
				LogToOutput = false
			},
			Scheduling = {
				ThrottleThreadCreation = false,
				ThreadCreationThreshold = 200,
				AgingFactor = 0.1,
			}
		},

		Logger = {
			OutputBuffer = {},
			Output = function(this, level, msg, ...)
				if self.Settings.Logging and (not self.Settings.Logging.Enabled or level < self.Settings.Logging.Level) then return end
				local formatted = string.format(msg, ...)
				table.insert(this.OutputBuffer, 1, {
					Type = level,
					Message = formatted,
					Time = os.time()
				})
				if #this.OutputBuffer > 500 then table.remove(this.OutputBuffer) end
				if (self.Settings.Logging and self.Settings.Logging.LogToOutput) or level >= 3 then warn("[Scheduler] " .. formatted) end
			end
		},
		PerformanceManager = {}
	}, Scheduler)

	-- Initialize PerformanceManager stub
	self.PerformanceManager = {
		GetActiveTasks = function()
			local result = {}
			for name, task in pairs(self._running) do
				result[name] = {
					Data = task
				}
			end
			return result
		end,
		GetTaskAverage = function(_, name)
			if self.TaskStats[name] then return self.TaskStats[name].Average end
			local task = self.Tasks[name]
			return (task and task.RunCount > 0) and (task.TotalRunTime / task.RunCount) or 0
		end,
		GetTaskMaximum = function(_, name)
			if self.TaskStats[name] then return self.TaskStats[name].MaxRunTime end
			local task = self.Tasks[name]
			return task and task.MaxRunTime or 0
		end,
		GetDelayedExecutionCount = function(_, name)
			local stats = self.TaskStats[name]
			return stats and stats.Delayed or 0
		end,
		Tasks = self.Tasks,
		Stats = self.TaskStats
	}

	return self
end

--[[
	@summary Initializes the scheduler with settings.
	@param settings any?
	@return any -- self
]]
function Scheduler:Initialize(settings: any?)
	if settings then self.Settings = settings end
	return self
end

--[[
	@summary Clears all scheduled tasks, heaps, history, and stats.
	@return ()
]]
function Scheduler:Clear()
	self.Tasks = {}
	self._heaps = {}
	self.History = {}
	self.LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 }
	table.clear(self.TaskStats)
end

-- Compatibility wrapper for table-based arguments
--[[
	@summary Schedules a task for execution.
	@param params ScheduleTaskParams
	@return Task? -- The created task object, or nil if invalid
]]
function Scheduler:Schedule(params: ScheduleTaskParams): Task?
	self = ResolveScheduler(self)
	if not params then
		self.Logger:Output(3, "Invalid params")
		return nil
	end
	if params.FetchData and type(params.FetchData) == "function" and type(params.TaskAction) ~= "function" then
		params.TaskAction = params.FetchData
	end
	if type(params.TaskName) ~= "string" or params.TaskName == "" then
		self.Logger:Output(3, "Invalid TaskName")
		return nil
	end
	if type(params.TaskAction) ~= "function" then
		self.Logger:Output(3, string.format("Invalid TaskAction for %s", tostring(params.TaskName)))
		return nil
	end
	local task: Task = {
		Name = params.TaskName,
		Action = params.TaskAction,
		Delay = params.TaskExecutionDelay or 0,
		IsRecurringTask = params.IsRecurringTask or false,
		Priority = params.Priority or 1,
		Event = params.Event or "Heartbeat",
		NextRun = os.clock() + (params.TaskExecutionDelay or 0),
		ConsecutiveDelays = 0,

		RunCount = 0,
		TotalRunTime = 0,
		MaxRunTime = 0,
		CreationTime = os.clock(),
		Reset = function() end,
	}

	-- Inject Reset method for ServiceManager compatibility
	task.Reset = function()
		task.RunCount = 0
		task.TotalRunTime = 0
		task.MaxRunTime = 0
		self.Logger:Output(2, string.format("Reset: %s", params.TaskName))
	end

	if self.Tasks[params.TaskName] then
		self.Logger:Output(2, string.format("Overwriting existing task: %s", params.TaskName))
		self.Tasks[params.TaskName] = nil
	end

	self.Tasks[params.TaskName] = task
	if not self._heaps[task.Event] then self._heaps[task.Event] = {} end
	self:_heapPush(self._heaps[task.Event], task)
	self.Logger:Output(1, string.format("Scheduled: %s", params.TaskName))
	return task
end

--[[
	@summary Adds an entry to History (best-effort; used by ServiceManager).
	@param taskObj any
	@param status any
	@param duration any
	@param err string?
	@return ()
]]
function Scheduler:AddToHistory(taskObj, status, duration, err: string?)
	self = ResolveScheduler(self)
	table.insert(self.History, 1, {
		Name = taskObj.Name,
		Status = status,
		Duration = duration,
		Time = os.time(),
		Error = err
	})
	if #self.History > 100 then table.remove(self.History) end
end

--[[
	@summary Deschedules (cancels) a task by name.
	@param name string
	@return ()
]]
function Scheduler:Deschedule(name: string)
	self = ResolveScheduler(self)
	if self.Tasks[name] then
		self:AddToHistory(self.Tasks[name], "Cancelled", 0, "")
		self.Tasks[name] = nil
		self.Logger:Output(2, "Descheduled: %s", name)
	end
end

--[[
	@summary Gets a task by name.
	@param name string
	@return Task?
]]
function Scheduler:GetTask(name: string)
	self = ResolveScheduler(self)
	return self.Tasks[name]
end

--[[
	@summary Returns the number of currently scheduled tasks.
	@return number
]]
function Scheduler:GetTaskCount()
	self = ResolveScheduler(self)
	local taskCount = 0
	for _ in pairs(self.Tasks) do
		taskCount += 1
	end
	return taskCount
end

--[[
	@summary Executes a task immediately by name or task object.
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
	self.Logger:Output(1, "Manually Executed: %s", task.Name)
	self:_internalExecute(task)
end

--[[
	@summary Returns a sanitized snapshot for ServiceManager server sync.
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
		Logs = self.Logger.OutputBuffer,
		Settings = self.Settings,
		History = self.History,
		LastFrameStats = self.LastFrameStats,
		TaskStats = self.TaskStats
	}
end

--[[
	@summary Checks whether a player is authorized to use admin-only API.
	@param player Player
	@return boolean
]]
function Scheduler:CheckAdmin(player: Player)
	if RunService:IsStudio() then return true end
	return player.UserId == game.CreatorId
end

--[[
	@summary Exposes RemoteFunction API for ServiceManager/clients (server-only).
	@return ()
]]
function Scheduler:ExposeAPI()
	if RunService:IsServer() then
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local clientRemoteFunction = ReplicatedStorage:FindFirstChild("SchedulerClientFunction") :: RemoteFunction?
		if not clientRemoteFunction then
			local createdRemoteFunction = Instance.new("RemoteFunction")
			createdRemoteFunction.Name = "SchedulerClientFunction"
			createdRemoteFunction.Parent = ReplicatedStorage
			clientRemoteFunction = createdRemoteFunction
		end

		(clientRemoteFunction :: RemoteFunction).OnServerInvoke = function(player, action, a1, a2, a3, a4, a5, a6)
			if not self:CheckAdmin(player) then
				warn(string.format("[Scheduler] Unauthorized access attempt by %s", player.Name))
				return "Unauthorized"
			end

			if action == "GetSyncData" then return self:GetSyncData()
			elseif action == "Deschedule" then self:Deschedule(a1)
			elseif action == "ExecuteTask" then self:ExecuteTask(a1)
			elseif action == "ResetTask" then self:ResetTask(a1)
			elseif action == "UpdateSettings" then
				local section, key, val = a1, a2, a3
				if section and self.Settings[section] then
					self.Settings[section][key] = val
				elseif not section then
					self.Settings[key] = val
				end
			elseif action == "ConsoleCommand" then
				local cmd, _options = a1, a2
				if cmd == "ps" then
					local out = ""
					for taskName in pairs(self.Tasks) do
						out = out .. tostring(taskName) .. "\n"
					end
					if out == "" then out = "No active tasks." end
					return out
				elseif cmd == "stats" then
					return "Tasks: " .. self:GetTaskCount()
				elseif cmd == "clearlogs" then
					self.Logger.OutputBuffer = {}
					return "Logs flushed."
				elseif cmd == "help" then
					return "Available commands: help, ps, stats, clearlogs"
				end
				return "Unknown server command."
 			elseif action == "ScheduleTestTask" then
				self:Schedule({
					TaskName = a1,
					TaskExecutionDelay = a2,
					IsRecurringTask = a3,
					Priority = a4,
					Event = a5,
					TaskAction = function() print("[SERVER TEST]: " .. tostring(a6)) end
				})
			end
		end
	end
end

--[[
	@summary Resets a task's performance counters.
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
			self.Logger:Output(2, "Reset: %s", name)
		end
	end
end

--[[
	@summary Generates a GUID key string.
	@return string
]]
function Scheduler:GenerateKey()
	return HttpService:GenerateGUID(false)
end

--[[
	@summary Connects scheduler.Step to RunService signals.
	@return ()
]]
function Scheduler:Start()
	self = ResolveScheduler(self)
	local eventMap: { [string]: RBXScriptSignal } = {
		Heartbeat = RunService.Heartbeat,
		Stepped = RunService.Stepped,
		PreSimulation = RunService.PreSimulation,
		PostSimulation = RunService.PostSimulation,
	}
	if RunService:IsClient() then
		eventMap.RenderStepped = RunService.RenderStepped
	end

	for name, signal in pairs(eventMap) do
		if signal then
			signal:Connect(function() self:Step(name) end)
		end
	end
end

--[[
	@summary Internal execution wrapper with performance tracking and error capture.
	@param t Task
	@return ()
]]
function Scheduler:_internalExecute(t: Task)
	task.spawn(function()
		local start = os.clock()
			self._running[t.Name] = t
			t.ConsecutiveDelays = 0 -- Reset aging on run
		local s: boolean, e = xpcall(function()
			t.Action()
		end, function(err)
			return debug.traceback(tostring(err), 2)
		end)
		local dur = os.clock() - start
			self._running[t.Name] = nil

		if self.Tasks[t.Name] == t then
			t.RunCount += 1
			t.TotalRunTime += dur
			if dur > t.MaxRunTime then t.MaxRunTime = dur end

			-- Update persistent stats
			if not self.TaskStats[t.Name] then self.TaskStats[t.Name] = { RunCount = 0, TotalRunTime = 0, MaxRunTime = 0, Average = 0, Delayed = 0 } end
			local stats = self.TaskStats[t.Name]
			stats.RunCount += 1
			stats.TotalRunTime += dur
			if dur > stats.MaxRunTime then stats.MaxRunTime = dur end
			stats.Average = stats.TotalRunTime / stats.RunCount
		end

		if not s then
			self.Logger:Output(3, "Task Error [%s]: %s", t.Name, tostring(e))
			if not t.IsRecurringTask then
				self:AddToHistory(t, "Failed", dur, tostring(e))
			end
		else
			if not t.IsRecurringTask then
				self:AddToHistory(t, "Completed", dur, "")
			end
		end
	end)
end

--[[
	@summary Executes due tasks for the given event name (frame-budgeted).
	@param eventName string?
	@return ()
]]
function Scheduler:Step(eventName: string?)
	self = ResolveScheduler(self)
	if type(eventName) ~= "string" then eventName = "Heartbeat" end
	local heap = self._heaps[eventName]
	if not heap then return end

	local now = os.clock()
	local startTime = os.clock()
	local budget = self.Settings.FrameBudget or 0.002
	local readyTasks = {}
	local tasksRun = 0

	while #heap > 0 do
		local task = heap[1]

		-- Lazy removal check
		if self.Tasks[task.Name] ~= task then
			self:_heapPop(heap)
			continue
		end

		if task.NextRun > now then
			break
		end

		table.insert(readyTasks, self:_heapPop(heap))
	end

	-- Sort by Priority (Higher number = Higher Priority)
	-- Incorporates AgingFactor for fairness: Effective Priority = Priority + (ConsecutiveDelays * AgingFactor)
	-- Uses NextRun as a tie-breaker (FIFO)
	local agingFactor = self.Settings.Scheduling and self.Settings.Scheduling.AgingFactor or 0.1
	table.sort(readyTasks, function(a: Task, b: Task)
		local prioA = a.Priority + (a.ConsecutiveDelays * agingFactor)
		local prioB = b.Priority + (b.ConsecutiveDelays * agingFactor)
		
		if prioA ~= prioB then
			return prioA > prioB
		end
		
		return a.NextRun < b.NextRun
	end)

	for i, task in ipairs(readyTasks) do
		tasksRun += 1
		-- Execute with performance tracking
		self:_internalExecute(task)

		if task.IsRecurringTask and self.Tasks[task.Name] == task then
			task.NextRun = now + task.Delay
			self:_heapPush(heap, task)
		else
			if self.Tasks[task.Name] == task then
				self.Tasks[task.Name] = nil
			end
		end

		-- Frame Budget Check (Check AFTER execution to prevent livelock)
		if (os.clock() - startTime) >= budget then
			-- Re-queue remaining tasks
			for j = i + 1, #readyTasks do
				local deferred = readyTasks[j]
				self:_heapPush(heap, deferred)
				if deferred and deferred.Name then
					deferred.ConsecutiveDelays += 1 -- Increment aging
					if not self.TaskStats[deferred.Name] then
						self.TaskStats[deferred.Name] = { RunCount = 0, TotalRunTime = 0, MaxRunTime = 0, Average = 0, Delayed = 0 }
					end
					self.TaskStats[deferred.Name].Delayed += 1
				end
			end
			self.Logger:Output(2, "Frame budget exceeded. Deferred %d tasks.", #readyTasks - i)
			break
		end
	end

	self.LastFrameStats = {
		FrameTime = os.clock() - startTime,
		TaskCount = tasksRun,
		Budget = budget
	}
end

-- Min-Heap Helpers
--[[
	@summary Pushes an item into a min-heap sorted by NextRun.
	@param heap { Task }
	@param item Task
	@return ()
]]
function Scheduler:_heapPush(heap: {Task}, item: Task)
	table.insert(heap, item)
	local heapIndex = #heap
	while heapIndex > 1 do
		local parentIndex = math.floor(heapIndex / 2)
		if heap[heapIndex].NextRun < heap[parentIndex].NextRun then
			heap[heapIndex], heap[parentIndex] = heap[parentIndex], heap[heapIndex]
			heapIndex = parentIndex
		else
			break
		end
	end
end

--[[
	@summary Pops the earliest item from a min-heap sorted by NextRun.
	@param heap { Task }
	@return Task
]]
function Scheduler:_heapPop(heap: {Task})
	local root = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		heap[1] = last :: Task
		local heapIndex, heapSize = 1, #heap
		while true do
			local leftChildIndex, rightChildIndex = 2 * heapIndex, 2 * heapIndex + 1
			local smallestIndex = heapIndex
			if leftChildIndex <= heapSize and heap[leftChildIndex].NextRun < heap[smallestIndex].NextRun then
				smallestIndex = leftChildIndex
			end
			if rightChildIndex <= heapSize and heap[rightChildIndex].NextRun < heap[smallestIndex].NextRun then
				smallestIndex = rightChildIndex
			end
			if smallestIndex == heapIndex then
				break
			end
			heap[heapIndex], heap[smallestIndex] = heap[smallestIndex], heap[heapIndex]
			heapIndex = smallestIndex
		end
	end
	return root
end

return Scheduler