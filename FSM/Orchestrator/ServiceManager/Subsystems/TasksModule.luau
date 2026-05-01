--!strict
-- @Name ServiceManager/Subsystems/TasksModule.luau
-- @Author iKrypto
-- @Description Enhanced TASKS subsystem with search/filter toolbar, sort options,
-- active/archived sections, task actions (execute/kill), performance strip with
-- sparkline indicators, and per-task detail drill-downs.

local Theme = require(script.Parent.Parent.Theme)
local SearchAutocomplete = require(script.Parent.Parent.SearchAutocomplete)

local TasksModule = {}
TasksModule.__index = TasksModule

local SORT_MODES = { "Priority", "Name", "Status", "Executions", "AvgTime" }

--[[
	Create the TASKS subsystem controller.
	Owns the task caches, filter state, and perf-strip smoothing buffers that
	back both the root list and its drill-down layers.
]]
function TasksModule.new(): any
	local self = setmetatable({}, TasksModule)
	self._taskCache = {} :: { [string]: any }
	self._archivedTasks = {} :: { [string]: any }
	self._completedTasks = {} :: { [string]: any }
	self._perfCache = {} :: { [string]: any }
	self._perfHistory = {} :: { any }
	self._lastFetchTime = 0
	self._selectedTask = nil :: string?
	self._searchText = ""
	self._sortMode = "Priority"
	self._showArchived = false
	self._showCompleted = true
	self._lastHistoryIndex = 0
	-- Track per-task execution snapshots between FetchData ticks so we can
	-- distinguish ACTIVE (ran since last fetch) vs IDLE (no executions since last fetch).
	-- This is the source of truth for the row status badge — `_running` only
	-- catches tasks mid-execution which almost never happens for fast heartbeat tasks.
	self._prevRunCounts = {} :: { [string]: number }
	self._lastActiveTime = {} :: { [string]: number }
	-- Smoothed values for perf strip animation (EMA-based to avoid jerky updates)
	self._smoothPerf = {
		FPS = 60,
		MemoryMB = 0,
		ActiveTasks = 0,
		FrameBudgetMs = 0,
	}
	-- Previous raw values for direction-arrow detection
	self._prevPerf = {
		FPS = 60,
		MemoryMB = 0,
		ActiveTasks = 0,
		FrameBudgetMs = 0,
	}
	-- Per-metric direction (-1 down, 0 stable, 1 up)
	self._perfDirections = {
		FPS = 0,
		MemoryMB = 0,
		ActiveTasks = 0,
		FrameBudgetMs = 0,
	}
	return self
end

-- ══════════════════════════════════════════════════════════════
-- PERF STRIP HELPERS
-- ══════════════════════════════════════════════════════════════

-- EMA smoothing factor — higher = more responsive, lower = smoother
local PERF_SMOOTH_ALPHA = 0.25
-- Threshold below which a change is considered "stable" (no direction arrow)
local PERF_STABLE_THRESHOLD = {
	FPS = 0.5,
	MemoryMB = 0.05,
	ActiveTasks = 0.5,
	FrameBudgetMs = 0.05,
}

function TasksModule:_UpdateSmoothedPerf()
	local raw = self._perfCache
	local smooth = self._smoothPerf
	local prev = self._prevPerf

	local rawFps = raw.FPS or 60
	local rawMem = raw.MemoryMB or 0
	local rawTasks = raw.ActiveTasks or 0
	local rawBudget = (raw.FrameBudget or 0) * 1000

	-- Direction detection (compare raw to previous raw)
	local function detectDir(curr: number, p: number, threshold: number): number
		local delta = curr - p
		if math.abs(delta) < threshold then return 0 end
		return if delta > 0 then 1 else -1
	end
	self._perfDirections.FPS = detectDir(rawFps, prev.FPS, PERF_STABLE_THRESHOLD.FPS)
	self._perfDirections.MemoryMB = detectDir(rawMem, prev.MemoryMB, PERF_STABLE_THRESHOLD.MemoryMB)
	self._perfDirections.ActiveTasks = detectDir(rawTasks, prev.ActiveTasks, PERF_STABLE_THRESHOLD.ActiveTasks)
	self._perfDirections.FrameBudgetMs = detectDir(rawBudget, prev.FrameBudgetMs, PERF_STABLE_THRESHOLD.FrameBudgetMs)

	-- EMA smoothing
	smooth.FPS = smooth.FPS + PERF_SMOOTH_ALPHA * (rawFps - smooth.FPS)
	smooth.MemoryMB = smooth.MemoryMB + PERF_SMOOTH_ALPHA * (rawMem - smooth.MemoryMB)
	smooth.ActiveTasks = smooth.ActiveTasks + PERF_SMOOTH_ALPHA * (rawTasks - smooth.ActiveTasks)
	smooth.FrameBudgetMs = smooth.FrameBudgetMs + PERF_SMOOTH_ALPHA * (rawBudget - smooth.FrameBudgetMs)

	prev.FPS = rawFps
	prev.MemoryMB = rawMem
	prev.ActiveTasks = rawTasks
	prev.FrameBudgetMs = rawBudget
end

--[=[
	Per-frame perf strip update. Called from ServiceManager's RenderStepped hook.
	Uses a frame-rate independent alpha so smoothing speed is consistent at any FPS.
	Updates labels in-place — no instance churn.
	@param nexus any
	@param dt number — delta time since last frame
	@reads nexus._orchestrator, nexus._lastFPS, nexus._serverData
	@writes self._smoothPerf, self._perfDirections, label texts/colors
]=]
function TasksModule:_TickPerfStrip(nexus: any, dt: number)
	-- Pull live raw values without invoking the heavy FetchData path.
	-- Memory + FPS update at frame rate; full data fetch still happens every 2s.
	local fps = nexus._lastFPS or 60
	local memMB = collectgarbage("count") / 1024
	local activeTasks = self._perfCache.ActiveTasks or 0
	local frameBudget = self._perfCache.FrameBudget or 0.0083

	-- Frame-rate-independent EMA: tau ~= 0.4s
	local alpha = 1 - math.exp(-(dt or (1/60)) / 0.4)
	local smooth = self._smoothPerf
	local prev = self._prevPerf
	local dirs = self._perfDirections

	-- Direction detection from raw values (compare to last raw used here)
	-- NOTE: This helper is duplicated in _UpdateSmoothedPerf; keep both copies aligned.
	local function detectDir(curr: number, p: number, threshold: number): number
		local delta = curr - p
		if math.abs(delta) < threshold then return 0 end
		return if delta > 0 then 1 else -1
	end
	dirs.FPS = detectDir(fps, prev.FPS, PERF_STABLE_THRESHOLD.FPS)
	dirs.MemoryMB = detectDir(memMB, prev.MemoryMB, PERF_STABLE_THRESHOLD.MemoryMB)
	-- Tasks/Budget rarely change per-frame; preserve from last fetch

	-- Apply smoothing
	smooth.FPS = smooth.FPS + alpha * (fps - smooth.FPS)
	smooth.MemoryMB = smooth.MemoryMB + alpha * (memMB - smooth.MemoryMB)
	smooth.ActiveTasks = smooth.ActiveTasks + alpha * (activeTasks - smooth.ActiveTasks)
	smooth.FrameBudgetMs = smooth.FrameBudgetMs + alpha * ((frameBudget * 1000) - smooth.FrameBudgetMs)

	-- Decay direction toward stable so arrows don't stick after change settles
	prev.FPS = prev.FPS * 0.85 + fps * 0.15
	prev.MemoryMB = prev.MemoryMB * 0.85 + memMB * 0.15

	-- Find the perf strip in the active TASKS layer and update labels in-place
	local navigator = nexus._navigator
	if not navigator then return end
	local layerHost = navigator._rootContainer
	if not layerHost then return end
	local tasksLayer = layerHost:FindFirstChild("Layer_TASKS")
	if not tasksLayer then return end
	local content = tasksLayer:FindFirstChild("Content")
	if not content then return end
	local strip = content:FindFirstChild("PerfStrip")
	if not strip then return end

	self:_UpdatePerfStripLabels(strip)
end

--[=[
	Apply current smoothed values + direction arrows to the existing perf strip
	cells without creating any new instances. Safe to call every frame.
]=]
function TasksModule:_UpdatePerfStripLabels(strip: Frame)
	local smooth = self._smoothPerf
	local raw = self._perfCache
	local dirs = self._perfDirections

	local rawFps = raw.FPS or smooth.FPS
	local fpsColor = if rawFps >= 55 then Theme.Colors.Success
		elseif rawFps >= 30 then Theme.Colors.Warning
		else Theme.Colors.Danger
	local memColor = if smooth.MemoryMB > 600 then Theme.Colors.Danger
		elseif smooth.MemoryMB > 300 then Theme.Colors.Warning
		else Theme.Colors.Cyan

	local cells = {
		FPS = {
			Value = string.format("%.0f", smooth.FPS),
			Color = fpsColor,
			Direction = dirs.FPS,
			HigherIsBetter = true,
		},
		MEM = {
			Value = string.format("%.1fMB", smooth.MemoryMB),
			Color = memColor,
			Direction = dirs.MemoryMB,
			HigherIsBetter = false,
		},
		TASKS = {
			Value = string.format("%d", math.floor(smooth.ActiveTasks + 0.5)),
			Color = Theme.Colors.Accent,
			Direction = dirs.ActiveTasks,
			HigherIsBetter = true,
		},
		BUDGET = {
			Value = string.format("%.1fms", smooth.FrameBudgetMs),
			Color = Theme.Colors.Orange,
			Direction = dirs.FrameBudgetMs,
			HigherIsBetter = false,
		},
	}

	for key, spec in pairs(cells) do
		local cell = strip:FindFirstChild("Cell_" .. key)
		if not cell then continue end
		local valueLbl = cell:FindFirstChild("Value") :: TextLabel
		local dirLbl = cell:FindFirstChild("Direction") :: TextLabel
		if valueLbl then
			Theme.ApplyProps(valueLbl, {
				Text = spec.Value,
				TextColor3 = spec.Color,
			})
		end
		if dirLbl then
			Theme.ApplyProps(dirLbl, {
				Text = dirGlyph(spec.Direction),
				TextColor3 = dirColor(spec.Direction, spec.HigherIsBetter),
			})
		end
	end
end

local function dirGlyph(dir: number): string
	-- Use arrow chars that Gotham covers (↑↓· are not in the typeface).
	-- ↑ ↓ are universally supported. Stable: empty (no symbol) — the muted
	-- color already conveys "no change".
	if dir > 0 then return "↑"
	elseif dir < 0 then return "↓"
	else return ""
	end
end

local function dirColor(dir: number, higherIsBetter: boolean): Color3
	if dir == 0 then return Theme.Colors.TextMuted end
	if higherIsBetter then
		return if dir > 0 then Theme.Colors.Success else Theme.Colors.Danger
	else
		return if dir > 0 then Theme.Colors.Danger else Theme.Colors.Success
	end
end

--[[
	Refresh the TASKS snapshot for the active context and push the latest list /
	perf data into the shared store. Client mode derives active-vs-idle state
	from scheduler run deltas; server mode consumes the polled server snapshot.
]]
function TasksModule:FetchData(nexus: any)
	local orchestrator = nexus._orchestrator
	if not orchestrator then return end

	if nexus._contextMode == "client" then
		local scheduler = orchestrator.Scheduler
		if scheduler and scheduler.Tasks then
			self._taskCache = {}
			local now = os.clock()
			-- Tasks that ran since the last fetch are ACTIVE; tasks unchanged are IDLE.
			-- The active window adapts to the task's cadence:
			--   max(3s, 2 * TaskExecutionDelay)
			-- A heartbeat task with Delay=0 gets the 3s minimum (smooths out
			-- the badge so single skipped frames don't drop it to IDLE).
			-- A 5s-recurring poll gets a 10s window so it stays ACTIVE between
			-- ticks instead of flickering 3s-on / 2s-off every cycle.
			local MIN_ACTIVE_WINDOW = 3.0
			for name, taskDef in pairs(scheduler.Tasks) do
				local runCount = taskDef.RunCount or 0
				local avgTimeSec = if runCount > 0 then (taskDef.TotalRunTime or 0) / runCount else 0
				local totalMem = taskDef.TotalMemory or 0
				local maxMem = taskDef.MaxMemory or 0
				local avgMem = if runCount > 0 then totalMem / runCount else 0
				local errCount = taskDef.ErrorCount or taskDef.Errors or 0
				local taskDelay = taskDef.Delay or 0
				local activeWindow = math.max(MIN_ACTIVE_WINDOW, taskDelay * 2)

				-- Detect activity: did runCount increase since last fetch?
				local prevCount = self._prevRunCounts[name] or 0
				if runCount > prevCount then
					self._lastActiveTime[name] = now
				end
				self._prevRunCounts[name] = runCount

				-- Determine status with a richer state machine:
				-- 1. ERROR  — has error counter
				-- 2. RUNNING — caught mid-execution (rare)
				-- 3. ACTIVE — ran within activeWindow (recurring task firing regularly)
				-- 4. IDLE   — registered but not recently executed
				local isMidExec = type(scheduler._running) == "table"
					and type(scheduler._running[name]) == "table"
				local lastActive = self._lastActiveTime[name] or 0
				local activeAge = now - lastActive
				local status: string
				if errCount > 0 then
					status = "error"
				elseif isMidExec then
					status = "running"
				elseif lastActive > 0 and activeAge <= activeWindow then
					status = "active"
				else
					status = "idle"
				end

				self._taskCache[name] = {
					Name = name,
					Status = status,
					Priority = taskDef.Priority or 1,
					ExecutionCount = runCount,
					IsRecurring = taskDef.IsRecurringTask or false,
					LastRun = lastActive,
					LastRunAgo = if lastActive > 0 then activeAge else nil,
					AvgTimeMs = avgTimeSec * 1000,
					MaxTimeMs = (taskDef.MaxRunTime or 0) * 1000,
					MinTimeMs = 0,
					Errors = errCount,
					Event = taskDef.Event or "Heartbeat",
					TaskExecutionDelay = taskDef.Delay or 0,
					HasAction = taskDef.Action ~= nil,
					MemoryAvgKB = avgMem,
					MemoryMaxKB = maxMem,
					MemoryTotalKB = totalMem,
				}
			end
			-- Drop stale entries from prevRunCounts for tasks that no longer exist
			for name in pairs(self._prevRunCounts) do
				if not scheduler.Tasks[name] then
					self._prevRunCounts[name] = nil
					self._lastActiveTime[name] = nil
				end
			end
		end
		local taskCount = 0
		if scheduler and scheduler.Tasks then
			for _ in pairs(scheduler.Tasks) do taskCount += 1 end
		end
		local frameBudget = if scheduler then (scheduler.Settings and scheduler.Settings.FrameBudget or 0.005) else 0
		self._perfCache = {
			FPS = nexus._lastFPS or 60,
			FrameBudget = frameBudget,
			TasksPerFrame = taskCount,
			MemoryMB = collectgarbage("count") / 1024,
			ActiveTasks = taskCount,
		}

		-- Completed/Failed/Cancelled one-shot tasks from Scheduler.History ring buffer
		if scheduler and scheduler.History then
			for i = 0, 99 do
				local entry = scheduler.History[i]
				if entry and type(entry) == "table" and entry.Name then
					-- Only track tasks no longer in the active Tasks table
					if not scheduler.Tasks[entry.Name] then
						local status = entry.Status or "Completed"
						local statusLower = string.lower(status)
						self._completedTasks[entry.Name .. "@" .. tostring(entry.Time or 0)] = {
							Name = entry.Name,
							Status = statusLower,
							Priority = 99,
							ExecutionCount = 1,
							IsRecurring = false,
							LastRun = entry.Time or 0,
							AvgTimeMs = (entry.Duration or 0) * 1000,
							MaxTimeMs = (entry.Duration or 0) * 1000,
							MinTimeMs = (entry.Duration or 0) * 1000,
							Errors = if entry.Error then 1 else 0,
							ErrorMessage = entry.Error,
							Event = "OneShot",
							TaskExecutionDelay = 0,
							HasAction = false,
							MemoryAvgKB = 0,
							MemoryMaxKB = 0,
							MemoryTotalKB = 0,
						}
					end
				end
			end
		end
	else
		local serverData = nexus._serverData
		if serverData and serverData.Tasks then
			self._taskCache = {}
			if serverData.Tasks.List then
				local now = os.clock()
				-- Use the same adaptive ACTIVE_WINDOW as the client branch so
				-- the heartbeat task and other server-context recurring tasks
				-- correctly show as ACTIVE instead of being stuck at IDLE.
				-- Window adapts to task cadence: max(3s, 2 * TaskExecutionDelay).
				local MIN_ACTIVE_WINDOW = 3.0
				for name, taskDef in pairs(serverData.Tasks.List) do
					local runCount = taskDef.RunCount or taskDef.ExecutionCount or 0
					local errCount = taskDef.Errors or taskDef.ErrorCount or 0
					local lastRunTime = taskDef.LastRunTime or taskDef.LastRun or 0
					local taskDelay = taskDef.TaskExecutionDelay or taskDef.Delay or 0
					local activeWindow = math.max(MIN_ACTIVE_WINDOW, taskDelay * 2)

					-- Detect activity via runCount delta since last fetch.
					local prevCount = self._prevRunCounts[name] or 0
					if runCount > prevCount then
						self._lastActiveTime[name] = now
					end
					self._prevRunCounts[name] = runCount

					-- Also accept the snapshot's IsRunning (true mid-execution)
					-- as a definitive ACTIVE signal.
					local lastActive = self._lastActiveTime[name] or 0
					local activeAge = now - lastActive
					local status: string
					if errCount > 0 then
						status = "error"
					elseif taskDef.IsRunning then
						status = "running"
					elseif lastActive > 0 and activeAge <= activeWindow then
						status = "active"
					else
						status = "idle"
					end

					self._taskCache[name] = {
						Name = name,
						Status = status,
						Priority = taskDef.Priority or 5,
						ExecutionCount = runCount,
						IsRecurring = taskDef.IsRecurringTask or false,
						LastRun = lastRunTime,
						LastRunAgo = if lastRunTime > 0 then activeAge else nil,
						AvgTimeMs = taskDef.AvgTimeMs or 0,
						MaxTimeMs = taskDef.MaxTimeMs or 0,
						MinTimeMs = taskDef.MinTimeMs or 0,
						Errors = errCount,
						Event = taskDef.Event or "Heartbeat",
						TaskExecutionDelay = taskDef.TaskExecutionDelay or 0,
						HasAction = true,
					}
				end
				-- Drop stale entries from prevRunCounts for tasks that no
				-- longer exist on the server.
				for n in pairs(self._prevRunCounts) do
					if not serverData.Tasks.List[n] then
						self._prevRunCounts[n] = nil
						self._lastActiveTime[n] = nil
					end
				end
			end
			if serverData.Tasks.Performance then
				self._perfCache = serverData.Tasks.Performance
			end
		end
	end

	-- Record perf history
	if self._perfCache.FPS then
		table.insert(self._perfHistory, {
			FPS = self._perfCache.FPS,
			Memory = self._perfCache.MemoryMB or 0,
			Tasks = self._perfCache.ActiveTasks or 0,
			Time = os.clock(),
		})
		while #self._perfHistory > 60 do
			table.remove(self._perfHistory, 1)
		end
	end

	-- Update smoothed/direction values for the perf strip
	self:_UpdateSmoothedPerf()

	nexus.Store:BatchUpdate(function()
		nexus.Store:Set("tasks.list", self._taskCache)
		nexus.Store:Set("tasks.perf", self._perfCache)
	end)
	self._lastFetchTime = os.clock()
end

--[[
	Legacy subsystem hook retained for interface parity.
	TASKS renders through BuildRootLayer and navigator-driven rebuilds.
]]
function TasksModule:Render(_nexus: any) end

-- ══════════════════════════════════════════════════════════════
-- SORTING / FILTERING
-- ══════════════════════════════════════════════════════════════

function TasksModule:_GetSortedFilteredTasks(): { { Name: string, Data: any } }
	local result = {}
	for name, data in pairs(self._taskCache) do
		if self._searchText ~= "" then
			local lower = string.lower(self._searchText)
			if not string.lower(name):find(lower, 1, true)
				and not string.lower(data.Status or ""):find(lower, 1, true)
				and not string.lower(data.Event or ""):find(lower, 1, true) then
				continue
			end
		end
		table.insert(result, { Name = name, Data = data })
	end

	local mode = self._sortMode
	table.sort(result, function(a, b)
		if mode == "Priority" then return (a.Data.Priority or 99) < (b.Data.Priority or 99)
		elseif mode == "Name" then return a.Name < b.Name
		elseif mode == "Status" then return (a.Data.Status or "") < (b.Data.Status or "")
		elseif mode == "Executions" then return (a.Data.ExecutionCount or 0) > (b.Data.ExecutionCount or 0)
		elseif mode == "AvgTime" then return (a.Data.AvgTimeMs or 0) > (b.Data.AvgTimeMs or 0)
		end
		return a.Name < b.Name
	end)
	return result
end

-- ══════════════════════════════════════════════════════════════
-- Z-AXIS LAYER BUILDERS
-- ══════════════════════════════════════════════════════════════

--[[
	Build or rebuild the TASKS root layer inside the supplied Z-axis frame.
	Preserves stable toolbar / perf-strip instances so live metrics can animate
	without being recreated on every brain tick.
]]
function TasksModule:BuildRootLayer(frame: Frame, context: any)
	local nexus = context.Nexus
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	-- Idempotent rebuild: preserve PerfStrip and ToolbarRow across rebuilds so
	-- their internal labels can update in-place via EMA smoothing rather than
	-- being destroyed and re-created on each ServiceBrain refresh.
	Theme.ClearExcept(contentFrame, {
		PerfStrip = true,
		ToolbarRow = true,
	})

	-- Layout / padding (idempotent: only create if missing)
	if not contentFrame:FindFirstChildOfClass("UIListLayout") then
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 4)
		layout.Parent = contentFrame
	end
	if not contentFrame:FindFirstChildOfClass("UIPadding") then
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 10)
		padding.PaddingRight = UDim.new(0, 10)
		padding.PaddingTop = UDim.new(0, 6)
		padding.Parent = contentFrame
	end

	-- Perf strip (idempotent: updates labels in-place)
	self:_BuildPerfStrip(contentFrame, nexus)
	-- Search + sort toolbar (idempotent)
	self:_BuildToolbar(contentFrame, nexus)

	-- Active tasks
	local sortedTasks = self:_GetSortedFilteredTasks()
	local activeCount, errorCount = 0, 0
	for _, item in ipairs(sortedTasks) do
		if item.Data.Status == "running" or item.Data.Status == "active" then activeCount += 1 end
		if (item.Data.Errors or 0) > 0 then errorCount += 1 end
	end

	Theme.CreateLabel({
		Text = string.format("SCHEDULED TASKS (%d)  <font color=\"#3CD278\">%d active</font>  <font color=\"#F05050\">%d errors</font>",
			#sortedTasks, activeCount, errorCount),
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 20

	local itemsToAnimate = {}
	for i, item in ipairs(sortedTasks) do
		local row = self:_BuildTaskRow(contentFrame, item.Name, item.Data, nexus, 20 + i)
		table.insert(itemsToAnimate, row)
	end

	-- Archived section
	if self._showArchived then
		local archivedCount = 0
		for _ in pairs(self._archivedTasks) do archivedCount += 1 end
		if archivedCount > 0 then
			Theme.CreateLabel({
				Text = string.format("ARCHIVED (%d)", archivedCount),
				Size = UDim2.new(1, 0, 0, 18),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 500

			local order = 501
			for name, data in pairs(self._archivedTasks) do
				local row = self:_BuildTaskRow(contentFrame, name, data, nexus, order)
				row.BackgroundTransparency = 0.92
				table.insert(itemsToAnimate, row)
				order += 1
			end
		end
	end

	-- Completed/Failed/Cancelled tasks (from Scheduler.History)
	if self._showCompleted then
		local completedCount = 0
		for _ in pairs(self._completedTasks) do completedCount += 1 end
		if completedCount > 0 then
			local failedCount = 0
			for _, td in pairs(self._completedTasks) do
				if td.Errors and td.Errors > 0 then failedCount += 1 end
			end
			Theme.CreateLabel({
				Text = string.format('<font color="#3CD278">COMPLETED TASKS (%d)</font>  <font color="#F05050">%d failed</font>',
					completedCount, failedCount),
				Size = UDim2.new(1, 0, 0, 18),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 300

			local order = 301
			for id, data in pairs(self._completedTasks) do
				local row = self:_BuildTaskRow(contentFrame, id, data, nexus, order)
				row.BackgroundTransparency = 0.92
				table.insert(itemsToAnimate, row)
				order += 1
				if order > 350 then break end
			end
		end
	end

	if nexus._animationController and #itemsToAnimate > 0 then
		nexus._animationController:StaggerIn(
			itemsToAnimate,
			{ BackgroundTransparency = 1, Position = UDim2.new(0.03, 0, 0, 0) },
			{ BackgroundTransparency = 0.85, Position = UDim2.new(0, 0, 0, 0) },
			Theme.Tween.Fast
		)
	end
end

function TasksModule:_BuildToolbar(parent: Frame, nexus: any)
	-- Idempotent: reuse if already built. Only the search text and toggle button
	-- text/colors need to update each render.
	local toolbar = parent:FindFirstChild("ToolbarRow") :: Frame?
	local isNew = toolbar == nil
	if isNew then
		local newToolbar = Instance.new("Frame")
		newToolbar.Name = "ToolbarRow"
		newToolbar.Size = UDim2.new(1, 0, 0, 30)
		newToolbar.BackgroundTransparency = 1
		newToolbar.LayoutOrder = 10
		newToolbar.Parent = parent
		toolbar = newToolbar

		local tbLayout = Instance.new("UIListLayout")
		tbLayout.FillDirection = Enum.FillDirection.Horizontal
		tbLayout.SortOrder = Enum.SortOrder.LayoutOrder
		tbLayout.Padding = UDim.new(0, 6)
		tbLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		tbLayout.Parent = toolbar
	else
		-- Already built — just sync stateful elements (search text, toggle styling)
		if toolbar then
			local searchFrame = toolbar:FindFirstChild("SearchFrame")
			local searchBox = searchFrame and searchFrame:FindFirstChild("SearchBox") or nil
			if searchBox and (searchBox :: any).Text ~= self._searchText then
				(searchBox :: any).Text = self._searchText
			end
		end
		return
	end

	if not toolbar then return end

	-- First-time build below

	-- Search box
	local searchFrame = Instance.new("Frame")
	searchFrame.Name = "SearchFrame"
	searchFrame.Size = UDim2.new(0, 200, 0, 26)
	searchFrame.BackgroundColor3 = Theme.Colors.GlassOverlay
	searchFrame.BackgroundTransparency = 0.3
	searchFrame.BorderSizePixel = 0
	searchFrame.LayoutOrder = 1
	searchFrame.Parent = toolbar

	local sCorner = Instance.new("UICorner")
	sCorner.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	sCorner.Parent = searchFrame

	Theme.CreateLabel({
		Text = "🔍",
		Size = UDim2.new(0, 22, 1, 0),
		Position = UDim2.new(0, 4, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		Alignment = Enum.TextXAlignment.Center,
		Parent = searchFrame,
	})

	local searchBox = Instance.new("TextBox")
	searchBox.Name = "SearchBox"
	searchBox.Size = UDim2.new(1, -30, 1, -4)
	searchBox.Position = UDim2.new(0, 26, 0, 2)
	searchBox.BackgroundTransparency = 1
	searchBox.Text = self._searchText
	searchBox.PlaceholderText = "Search tasks..."
	searchBox.PlaceholderColor3 = Theme.Colors.TextMuted
	searchBox.TextColor3 = Theme.Colors.TextPrimary
	searchBox.TextSize = Theme.TextSize.Caption
	searchBox.FontFace = Theme.Font.Mono
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.ClearTextOnFocus = false
	searchBox.BorderSizePixel = 0
	searchBox.Parent = searchFrame

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		self._searchText = searchBox.Text
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	-- Attach search autocomplete
	if self._searchAC then self._searchAC:Destroy(); self._searchAC = nil end
	self._searchAC = SearchAutocomplete.new({
		TextBox = searchBox,
		ParentFrame = parent,
		GetSuggestions = function(text: string): { string }
			local lower = string.lower(text)
			local matches = {}
			for name, _ in pairs(self._taskCache) do
				if string.find(string.lower(name), lower, 1, true) then
					table.insert(matches, name)
				end
			end
			table.sort(matches)
			return matches
		end,
		OnSelect = function(selected: string)
			self._searchText = selected
			if nexus then nexus._lastDataRefresh = 0 end
		end,
	})

	-- Sort selector
	local sortBtn = Instance.new("TextButton")
	sortBtn.Size = UDim2.new(0, 90, 0, 26)
	sortBtn.BackgroundColor3 = Theme.Colors.GlassTertiary
	sortBtn.BackgroundTransparency = 0.4
	sortBtn.Text = "↓ " .. self._sortMode
	sortBtn.TextColor3 = Theme.Colors.TextSecondary
	sortBtn.TextSize = Theme.TextSize.Caption
	sortBtn.FontFace = Theme.Font.Bold
	sortBtn.AutoButtonColor = false
	sortBtn.BorderSizePixel = 0
	sortBtn.LayoutOrder = 2
	sortBtn.Parent = toolbar

	local sortCorner = Instance.new("UICorner")
	sortCorner.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	sortCorner.Parent = sortBtn

	sortBtn.MouseButton1Click:Connect(function()
		local idx = table.find(SORT_MODES, self._sortMode) or 1
		idx = if idx >= #SORT_MODES then 1 else idx + 1
		self._sortMode = SORT_MODES[idx]
		sortBtn.Text = "↓ " .. self._sortMode
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	-- Archive toggle
	local archiveBtn = Instance.new("TextButton")
	archiveBtn.Size = UDim2.new(0, 70, 0, 26)
	archiveBtn.BackgroundColor3 = if self._showArchived then Theme.Colors.Accent else Theme.Colors.GlassTertiary
	archiveBtn.BackgroundTransparency = if self._showArchived then 0.5 else 0.6
	archiveBtn.Text = "Archive"
	archiveBtn.TextColor3 = if self._showArchived then Theme.Colors.TextOnAccent else Theme.Colors.TextMuted
	archiveBtn.TextSize = Theme.TextSize.Caption
	archiveBtn.FontFace = Theme.Font.Bold
	archiveBtn.AutoButtonColor = false
	archiveBtn.BorderSizePixel = 0
	archiveBtn.LayoutOrder = 3
	archiveBtn.Parent = toolbar

	local aCorner = Instance.new("UICorner")
	aCorner.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	aCorner.Parent = archiveBtn

	archiveBtn.MouseButton1Click:Connect(function()
		self._showArchived = not self._showArchived
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	-- Completed toggle
	local completedBtn = Instance.new("TextButton")
	completedBtn.Size = UDim2.new(0, 80, 0, 26)
	completedBtn.BackgroundColor3 = if self._showCompleted then Theme.Colors.Success else Theme.Colors.GlassTertiary
	completedBtn.BackgroundTransparency = if self._showCompleted then 0.5 else 0.6
	completedBtn.Text = "Completed"
	completedBtn.TextColor3 = if self._showCompleted then Theme.Colors.TextOnAccent else Theme.Colors.TextMuted
	completedBtn.TextSize = Theme.TextSize.Caption
	completedBtn.FontFace = Theme.Font.Bold
	completedBtn.AutoButtonColor = false
	completedBtn.BorderSizePixel = 0
	completedBtn.LayoutOrder = 4
	completedBtn.Parent = toolbar
	Instance.new("UICorner", completedBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	completedBtn.MouseButton1Click:Connect(function()
		self._showCompleted = not self._showCompleted
		if nexus then nexus._lastDataRefresh = 0 end
	end)
end

function TasksModule:_BuildPerfStrip(parent: Frame, nexus: any)
	-- Idempotent: reuse existing strip if present, only update values.
	local strip = parent:FindFirstChild("PerfStrip") :: TextButton?
	local isNew = strip == nil
	if isNew then
		local newStrip = Instance.new("TextButton")
		newStrip.Name = "PerfStrip"
		newStrip.Size = UDim2.new(1, 0, 0, 56)
		newStrip.BackgroundColor3 = Theme.Colors.CardBG
		newStrip.BackgroundTransparency = 0.6
		newStrip.BorderSizePixel = 0
		newStrip.Text = ""
		newStrip.AutoButtonColor = false
		newStrip.LayoutOrder = 0
		newStrip.ZIndex = Theme.ZIndex.Header
		newStrip.Parent = parent
		strip = newStrip

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
		corner.Parent = strip

		local stroke = Instance.new("UIStroke")
		stroke.Color = Theme.Colors.BorderSubtle
		stroke.Thickness = 1
		stroke.Transparency = 0.7
		stroke.Parent = strip

		local innerLayout = Instance.new("UIListLayout")
		innerLayout.FillDirection = Enum.FillDirection.Horizontal
		innerLayout.SortOrder = Enum.SortOrder.LayoutOrder
		innerLayout.Padding = UDim.new(0, 8)
		innerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		innerLayout.Parent = strip

		local innerPad = Instance.new("UIPadding")
		innerPad.PaddingLeft = UDim.new(0, 12)
		innerPad.PaddingRight = UDim.new(0, 12)
		innerPad.Parent = strip
	end

	if not strip then return end

	-- Pull smoothed values for display; raw values are used for color
	local smooth = self._smoothPerf
	local raw = self._perfCache
	local dirs = self._perfDirections

	local rawFps = raw.FPS or 60
	local fpsColor = if rawFps >= 55 then Theme.Colors.Success
		elseif rawFps >= 30 then Theme.Colors.Warning
		else Theme.Colors.Danger
	local memColor = if smooth.MemoryMB > 600 then Theme.Colors.Danger
		elseif smooth.MemoryMB > 300 then Theme.Colors.Warning
		else Theme.Colors.Cyan

	local metricSpecs = {
		{
			Key = "FPS",
			Label = "FPS",
			Value = string.format("%.0f", smooth.FPS),
			Color = fpsColor,
			Direction = dirs.FPS,
			HigherIsBetter = true,
		},
		{
			Key = "MEM",
			Label = "MEM",
			Value = string.format("%.1fMB", smooth.MemoryMB),
			Color = memColor,
			Direction = dirs.MemoryMB,
			HigherIsBetter = false,
		},
		{
			Key = "TASKS",
			Label = "TASKS",
			Value = string.format("%d", math.floor(smooth.ActiveTasks + 0.5)),
			Color = Theme.Colors.Accent,
			Direction = dirs.ActiveTasks,
			HigherIsBetter = true,
		},
		{
			Key = "BUDGET",
			Label = "BUDGET",
			Value = string.format("%.1fms", smooth.FrameBudgetMs),
			Color = Theme.Colors.Orange,
			Direction = dirs.FrameBudgetMs,
			HigherIsBetter = false,
		},
	}

	for i, spec in ipairs(metricSpecs) do
		local cell = (strip :: any):FindFirstChild("Cell_" .. spec.Key) :: Frame?
		if not cell then
			local newCell = Instance.new("Frame")
			newCell.Name = "Cell_" .. spec.Key
			newCell.Size = UDim2.new(0, 88, 1, 0)
			newCell.BackgroundTransparency = 1
			newCell.LayoutOrder = i
			newCell.Parent = strip
			cell = newCell

			-- Value label (top, big)
			local valueLbl = Instance.new("TextLabel")
			valueLbl.Name = "Value"
			valueLbl.Size = UDim2.new(1, -16, 0, 22)
			valueLbl.Position = UDim2.new(0, 0, 0, 6)
			valueLbl.BackgroundTransparency = 1
			valueLbl.TextSize = Theme.TextSize.Heading
			valueLbl.FontFace = Theme.Font.Bold
			valueLbl.TextXAlignment = Enum.TextXAlignment.Left
			valueLbl.RichText = true
			valueLbl.Parent = cell

			-- Direction arrow (right side of value)
			local dirLbl = Instance.new("TextLabel")
			dirLbl.Name = "Direction"
			dirLbl.Size = UDim2.new(0, 14, 0, 22)
			dirLbl.Position = UDim2.new(1, -14, 0, 6)
			dirLbl.BackgroundTransparency = 1
			dirLbl.TextSize = Theme.TextSize.Caption
			dirLbl.FontFace = Theme.Font.Bold
			dirLbl.TextXAlignment = Enum.TextXAlignment.Center
			dirLbl.Parent = cell

			-- Label (below)
			local labelLbl = Instance.new("TextLabel")
			labelLbl.Name = "Label"
			labelLbl.Size = UDim2.new(1, 0, 0, 14)
			labelLbl.Position = UDim2.new(0, 0, 0, 32)
			labelLbl.BackgroundTransparency = 1
			labelLbl.Text = spec.Label
			labelLbl.TextColor3 = Theme.Colors.TextMuted
			labelLbl.TextSize = Theme.TextSize.Tiny
			labelLbl.FontFace = Theme.Font.Bold
			labelLbl.TextXAlignment = Enum.TextXAlignment.Left
			labelLbl.Parent = cell
		end

		if not cell then continue end

		-- Update values in place (no new instances)
		local valueLbl = cell:FindFirstChild("Value") :: TextLabel
		local dirLbl = cell:FindFirstChild("Direction") :: TextLabel
		if valueLbl then
			Theme.ApplyProps(valueLbl, {
				Text = spec.Value,
				TextColor3 = spec.Color,
			})
		end
		if dirLbl then
			Theme.ApplyProps(dirLbl, {
				Text = dirGlyph(spec.Direction),
				TextColor3 = dirColor(spec.Direction, spec.HigherIsBetter),
			})
		end
	end

	-- Sparkline (rebuild only when history shape changes meaningfully)
	self:_RenderSparkline(strip :: any)

	-- Click handler — only attach once
	if isNew and strip then
		(strip :: any).MouseButton1Click:Connect(function()
			if nexus._navigator then
				nexus._navigator:ExpandLayer({
					Id = "tasks.performance",
					ParentId = "TASKS",
					Label = "Performance",
					Builder = function(f, ctx) self:_BuildPerfDetailLayer(f, ctx) end,
					Context = { Nexus = nexus },
				})
			end
		end)

		-- Hover effect
		if nexus._animationController then
			nexus._animationController:HoverGlow(strip, Theme.Colors.Accent)
		end
	end
end

--[=[
	Render the FPS sparkline as connected line segments (rotated thin frames)
	with min/max overlay text. Idempotent: clears segments and redraws on each call.
	@param strip Frame containing the sparkline frame
]=]
function TasksModule:_RenderSparkline(strip: Frame)
	local spark = strip:FindFirstChild("Sparkline") :: Frame?
	if not spark then
		local newSpark = Instance.new("Frame")
		newSpark.Name = "Sparkline"
		newSpark.Size = UDim2.new(0, 180, 0, 44)
		newSpark.BackgroundColor3 = Theme.Colors.GlassPrimary
		newSpark.BackgroundTransparency = 0.65
		newSpark.BorderSizePixel = 0
		newSpark.LayoutOrder = 10
		newSpark.ClipsDescendants = true
		newSpark.Parent = strip
		spark = newSpark

		local sc = Instance.new("UICorner")
		sc.CornerRadius = UDim.new(0, Theme.Radius.Xs)
		sc.Parent = spark

		local stroke = Instance.new("UIStroke")
		stroke.Color = Theme.Colors.BorderSubtle
		stroke.Thickness = 1
		stroke.Transparency = 0.6
		stroke.Parent = spark

		-- Title pill at top-left so the user knows what the line is
		local title = Instance.new("TextLabel")
		title.Name = "TitleLbl"
		title.Size = UDim2.new(0, 26, 0, 11)
		title.Position = UDim2.new(0, 4, 0, 2)
		title.BackgroundTransparency = 1
		title.Text = "FPS"
		title.TextColor3 = Theme.Colors.TextSecondary
		title.TextSize = Theme.TextSize.Tiny
		title.FontFace = Theme.Font.Bold
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.ZIndex = 3
		title.Parent = spark

		-- Midline grid reference so the trend has visual context
		local midline = Instance.new("Frame")
		midline.Name = "Midline"
		midline.Size = UDim2.new(1, -4, 0, 1)
		midline.Position = UDim2.new(0, 2, 0.5, 0)
		midline.BackgroundColor3 = Theme.Colors.BorderSubtle
		midline.BackgroundTransparency = 0.5
		midline.BorderSizePixel = 0
		midline.ZIndex = 1
		midline.Parent = spark

		-- Min/max value labels — placed at right edge in monospace so they
		-- don't fight the line on the left side of the sparkline.
		local maxLbl = Instance.new("TextLabel")
		maxLbl.Name = "MaxLbl"
		maxLbl.Size = UDim2.new(0, 32, 0, 11)
		maxLbl.Position = UDim2.new(1, -36, 0, 2)
		maxLbl.AnchorPoint = Vector2.new(0, 0)
		maxLbl.BackgroundTransparency = 1
		maxLbl.TextColor3 = Theme.Colors.Success
		maxLbl.TextSize = Theme.TextSize.Tiny
		maxLbl.FontFace = Theme.Font.Mono
		maxLbl.TextXAlignment = Enum.TextXAlignment.Right
		maxLbl.ZIndex = 3
		maxLbl.Parent = spark

		local minLbl = Instance.new("TextLabel")
		minLbl.Name = "MinLbl"
		minLbl.Size = UDim2.new(0, 32, 0, 11)
		minLbl.Position = UDim2.new(1, -36, 1, -13)
		minLbl.AnchorPoint = Vector2.new(0, 0)
		minLbl.BackgroundTransparency = 1
		minLbl.TextColor3 = Theme.Colors.Danger
		minLbl.TextSize = Theme.TextSize.Tiny
		minLbl.FontFace = Theme.Font.Mono
		minLbl.TextXAlignment = Enum.TextXAlignment.Right
		minLbl.ZIndex = 3
		minLbl.Parent = spark

		-- Live current-value badge in the center-bottom
		local liveLbl = Instance.new("TextLabel")
		liveLbl.Name = "LiveLbl"
		liveLbl.Size = UDim2.new(0, 40, 0, 11)
		liveLbl.Position = UDim2.new(0, 32, 1, -13)
		liveLbl.BackgroundTransparency = 1
		liveLbl.TextColor3 = Theme.Colors.TextSecondary
		liveLbl.TextSize = Theme.TextSize.Tiny
		liveLbl.FontFace = Theme.Font.Mono
		liveLbl.TextXAlignment = Enum.TextXAlignment.Left
		liveLbl.ZIndex = 3
		liveLbl.Parent = spark

		-- Container for line segments (so we can wipe just these on update)
		local segs = Instance.new("Frame")
		segs.Name = "Segments"
		segs.Size = UDim2.new(1, 0, 1, 0)
		segs.BackgroundTransparency = 1
		segs.BorderSizePixel = 0
		segs.ZIndex = 2
		segs.Parent = spark
	end

	if not spark then return end

	local segs = (spark :: any):FindFirstChild("Segments")
	local minLbl = (spark :: any):FindFirstChild("MinLbl") :: TextLabel
	local maxLbl = (spark :: any):FindFirstChild("MaxLbl") :: TextLabel
	local liveLbl = (spark :: any):FindFirstChild("LiveLbl") :: TextLabel

	-- Clear existing segments
	if segs then
		for _, child in ipairs(segs:GetChildren()) do child:Destroy() end
	end

	if #self._perfHistory < 2 then
		if minLbl then minLbl.Text = "" end
		if maxLbl then maxLbl.Text = "" end
		if liveLbl then liveLbl.Text = "" end
		return
	end

	local count = math.min(#self._perfHistory, 30)
	-- Determine min/max FPS over visible window
	local minFps = math.huge
	local maxFps = -math.huge
	local lastFps = 0
	for j = 1, count do
		local idx = #self._perfHistory - count + j
		local snap = self._perfHistory[idx]
		if snap and snap.FPS then
			if snap.FPS < minFps then minFps = snap.FPS end
			if snap.FPS > maxFps then maxFps = snap.FPS end
			lastFps = snap.FPS
		end
	end
	if minFps == math.huge then minFps = 0 end
	if maxFps == -math.huge then maxFps = 60 end
	-- Pad the range so a stable line doesn't render as a flat min=max
	-- with no visible trend area.
	if maxFps - minFps < 5 then
		local mid = (maxFps + minFps) / 2
		minFps = math.max(0, mid - 5)
		maxFps = mid + 5
	end
	local range = math.max(maxFps - minFps, 1)

	local sparkW = 180 - 8 -- account for stroke padding on both sides
	local sparkH = 44 - 14 -- reserve top/bottom for labels
	local sparkOffsetX = 4
	local sparkOffsetY = 13
	local prevX, prevY = nil, nil

	for j = 1, count do
		local idx = #self._perfHistory - count + j
		local snap = self._perfHistory[idx]
		if not snap or not snap.FPS then continue end

		-- Map x linearly across width, y inversely (high FPS = top)
		local px = sparkOffsetX + (j - 1) / math.max(count - 1, 1) * sparkW
		local norm = (snap.FPS - minFps) / range -- 0..1
		local py = sparkOffsetY + (1 - norm) * sparkH

		-- Color the dot based on raw FPS quality
		local dotColor = if snap.FPS >= 55 then Theme.Colors.Success
			elseif snap.FPS >= 30 then Theme.Colors.Warning
			else Theme.Colors.Danger

		if prevX and prevY and segs then
			-- Draw line segment from previous point to current
			local dx = px - prevX
			local dy = py - prevY
			local length = math.sqrt(dx * dx + dy * dy)
			if length > 0.01 then
				local angle = math.deg(math.atan2(dy, dx))
				local seg = Instance.new("Frame")
				seg.Size = UDim2.new(0, length, 0, 2)
				seg.AnchorPoint = Vector2.new(0, 0.5)
				seg.Position = UDim2.new(0, prevX, 0, prevY)
				seg.Rotation = angle
				seg.BackgroundColor3 = dotColor
				seg.BackgroundTransparency = 0
				seg.BorderSizePixel = 0
				seg.ZIndex = 2
				seg.Parent = segs
			end
		end

		-- Draw dot at current point (slightly larger for legibility)
		if segs then
			local dot = Instance.new("Frame")
			dot.Size = UDim2.new(0, 4, 0, 4)
			dot.AnchorPoint = Vector2.new(0.5, 0.5)
			dot.Position = UDim2.new(0, px, 0, py)
			dot.BackgroundColor3 = dotColor
			dot.BackgroundTransparency = 0
			dot.BorderSizePixel = 0
			dot.ZIndex = 3
			dot.Parent = segs
			local dc = Instance.new("UICorner")
			dc.CornerRadius = UDim.new(1, 0)
			dc.Parent = dot
		end

		prevX = px
		prevY = py
	end

	if minLbl then
		Theme.ApplyProps(minLbl, { Text = string.format("%.0f", minFps) })
	end
	if maxLbl then
		Theme.ApplyProps(maxLbl, { Text = string.format("%.0f", maxFps) })
	end
	if liveLbl then
		local liveColor = if lastFps >= 55 then Theme.Colors.Success
			elseif lastFps >= 30 then Theme.Colors.Warning
			else Theme.Colors.Danger
		Theme.ApplyProps(liveLbl, {
			Text = string.format("%.0f now", lastFps),
			TextColor3 = liveColor,
		})
	end
end

function TasksModule:_BuildTaskRow(parent: Frame, name: string, taskData: any, nexus: any, order: number): Frame
	local statusColor = if taskData.Status == "running" then Theme.Colors.Accent
		elseif taskData.Status == "active" then Theme.Colors.Success
		elseif taskData.Status == "error" then Theme.Colors.Danger
		else Theme.Colors.TextMuted -- idle

	-- Format perf stats
	local execText = string.format("×%d", taskData.ExecutionCount or 0)
	local avgMs = taskData.AvgTimeMs or 0
	local avgText = string.format("%.2fms", avgMs)
	local avgColor = if avgMs > 10 then Theme.Colors.Danger
		elseif avgMs > 5 then Theme.Colors.Warning
		else Theme.Colors.TextMuted

	local memKB = taskData.MemoryAvgKB or 0
	local memColor = if memKB > 100 then Theme.Colors.Danger
		elseif memKB > 50 then Theme.Colors.Warning
		else Theme.Colors.TextMuted
	local memText = if memKB >= 1024 then string.format("%.1fMB", memKB / 1024)
		elseif memKB >= 1 then string.format("%.1fKB", memKB)
		else string.format("%.0fB", memKB * 1024)

	local stats: { Theme.RowStat } = {
		{ Text = "P" .. tostring(taskData.Priority or 0), Color = Theme.Colors.TextMuted, Width = 30, FontSize = Theme.TextSize.Tiny },
		{ Text = memText, Color = memColor, Width = 64 },
		{ Text = avgText, Color = avgColor, Width = 60 },
		{ Text = execText, Color = Theme.Colors.TextSecondary, Width = 56 },
	}

	if (taskData.Errors or 0) > 0 then
		table.insert(stats, 1, {
			Text = string.format("↑%d", taskData.Errors),
			Color = Theme.Colors.Danger,
			Width = 36,
		})
	end

	if taskData.IsRecurring then
		-- Tiny "REC" badge with a Cyan tint, indicating the task is recurring.
		-- (Was "↻" but Gotham doesn't have that glyph; renders as a box.)
		table.insert(stats, {
			Text = "REC",
			Color = Theme.Colors.Cyan,
			Width = 28,
			Mono = false,
			FontSize = Theme.TextSize.Tiny,
		})
	end

	-- Status badge as a styled stat (uppercase status text in colored pill)
	local statusText = string.format(
		'<font color="%s"><b>%s</b></font>',
		string.format("rgb(%d,%d,%d)", math.floor(statusColor.R * 255), math.floor(statusColor.G * 255), math.floor(statusColor.B * 255)),
		string.upper(taskData.Status or "idle")
	)
	table.insert(stats, 1, {
		Text = statusText,
		Width = 60,
		Mono = false,
	})

	local row = Theme.CreateRow({
		Name = "Task_" .. name,
		Size = UDim2.new(1, 0, 0, 36),
		StatusColor = statusColor,
		Title = name,
		BackgroundColor = if (taskData.Errors or 0) > 0 then Theme.Colors.Danger else Theme.Colors.GlassTertiary,
		BackgroundTransparency = if (taskData.Errors or 0) > 0 then 0.88 else 0.85,
		LayoutOrder = order,
		Stats = stats,
		Parent = parent,
		OnClick = function()
			self._selectedTask = name
			if nexus._navigator then
				nexus._navigator:ExpandLayer({
					Id = "tasks.detail." .. name,
					ParentId = "TASKS",
					Label = name,
					Builder = function(f, ctx) self:_BuildTaskDetailLayer(f, ctx) end,
					Context = { Nexus = nexus, TaskName = name, TaskData = taskData },
				})
			end
		end,
	})

	-- Pulse status dot for live tasks (running this instant or recently active)
	local dot = row:FindFirstChild("StatusDot")
	if dot and (taskData.Status == "running" or taskData.Status == "active") and nexus._animationController then
		nexus._animationController:StartPulse("task_" .. name, dot, "BackgroundTransparency", 0.6)
	end

	-- Hover glow on the click overlay
	local btn = row:FindFirstChild("ClickOverlay")
	if btn and nexus._animationController then
		nexus._animationController:HoverGlow(btn, Theme.Colors.Accent)
	end

	return row
end

-- ══════════════════════════════════════════════════════════════
-- TASK DETAIL
-- ══════════════════════════════════════════════════════════════

function TasksModule:_BuildTaskDetailLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	local taskName = context.TaskName or "Unknown"
	local taskData = context.TaskData or {}
	local nexus = context.Nexus

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 5)
	layout.Parent = contentFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.Parent = contentFrame

	-- Header
	Theme.CreateLabel({
		Text = string.format('<font color="#3898FF">⬢</font> %s', taskName),
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	-- Action buttons
	local actionBar = Instance.new("Frame")
	actionBar.Size = UDim2.new(1, 0, 0, 30)
	actionBar.BackgroundTransparency = 1
	actionBar.LayoutOrder = 1
	actionBar.Parent = contentFrame

	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection = Enum.FillDirection.Horizontal
	actionLayout.Padding = UDim.new(0, 6)
	actionLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	actionLayout.Parent = actionBar

	local execBtn = Theme.CreateIconButton({
		Label = "▶ Run",
		Size = UDim2.new(0, 70, 0, 26),
		Color = Theme.Colors.Success,
		Parent = actionBar,
	})
	execBtn.LayoutOrder = 1
	execBtn.MouseButton1Click:Connect(function()
		local orch = nexus._orchestrator
		if orch and orch.Scheduler and orch.Scheduler.Tasks then
			local taskDef = orch.Scheduler.Tasks[taskName]
			if taskDef and taskDef.TaskAction then
				pcall(taskDef.TaskAction)
			end
		end
	end)

	local killBtn = Theme.CreateIconButton({
		Label = "Kill",
		Size = UDim2.new(0, 70, 0, 26),
		Color = Theme.Colors.Danger,
		Parent = actionBar,
	})
	killBtn.LayoutOrder = 2
	killBtn.MouseButton1Click:Connect(function()
		local orch = nexus._orchestrator
		if orch and orch.Scheduler and orch.Scheduler.Unschedule then
			pcall(orch.Scheduler.Unschedule, orch.Scheduler, taskName)
		end
		self._archivedTasks[taskName] = taskData
		if nexus._navigator then nexus._navigator:CollapseToLayer("TASKS") end
	end)

	local resetBtn = Theme.CreateIconButton({
		Label = "Reset",
		Size = UDim2.new(0, 70, 0, 26),
		Color = Theme.Colors.Warning,
		Parent = actionBar,
	})
	resetBtn.LayoutOrder = 3
	resetBtn.MouseButton1Click:Connect(function()
		local orch = nexus._orchestrator
		if orch and orch.Scheduler and orch.Scheduler.Tasks then
			local taskDef = orch.Scheduler.Tasks[taskName]
			if taskDef then
				taskDef.ExecutionCount = 0
				taskDef.Errors = 0
				if taskDef.Perf then
					taskDef.Perf.AvgExecutionTime = 0
					taskDef.Perf.MaxExecutionTime = 0
				end
			end
		end
		nexus._lastDataRefresh = 0
	end)

	-- Properties section
	Theme.CreateLabel({
		Text = "PROPERTIES",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 5

	local properties = {
		{ Key = "Status", Value = taskData.Status or "unknown", Color = if taskData.Status == "running" or taskData.Status == "active" then Theme.Colors.Success elseif taskData.Status == "error" then Theme.Colors.Danger else Theme.Colors.TextPrimary },
		{ Key = "Priority", Value = tostring(taskData.Priority or 0), Color = Theme.Colors.Accent },
		{ Key = "Event", Value = taskData.Event or "Heartbeat", Color = Theme.Colors.Cyan },
		{ Key = "Recurring", Value = tostring(taskData.IsRecurring), Color = Theme.Colors.Purple },
		{ Key = "Delay", Value = string.format("%.2fs", taskData.TaskExecutionDelay or 0), Color = Theme.Colors.TextSecondary },
	}
	for i, prop in ipairs(properties) do
		self:_BuildPropRow(contentFrame, prop.Key, prop.Value, prop.Color, 10 + i)
	end

	-- Performance section
	Theme.CreateLabel({
		Text = "PERFORMANCE",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 50

	local memAvg = taskData.MemoryAvgKB or 0
	local memMax = taskData.MemoryMaxKB or 0
	local memTotal = taskData.MemoryTotalKB or 0
	local perfProps = {
		{ Key = "Executions", Value = tostring(taskData.ExecutionCount or 0), Color = Theme.Colors.TextPrimary },
		{ Key = "Avg Time", Value = string.format("%.3fms", taskData.AvgTimeMs or 0), Color = Theme.Colors.Cyan },
		{ Key = "Max Time", Value = string.format("%.3fms", taskData.MaxTimeMs or 0), Color = Theme.Colors.Orange },
		{ Key = "Min Time", Value = string.format("%.3fms", taskData.MinTimeMs or 0), Color = Theme.Colors.Success },
		{ Key = "Errors", Value = tostring(taskData.Errors or 0), Color = if (taskData.Errors or 0) > 0 then Theme.Colors.Danger else Theme.Colors.TextMuted },
		{ Key = "Avg Memory", Value = if memAvg >= 1024 then string.format("%.2f MB", memAvg / 1024) else string.format("%.2f KB", memAvg), Color = Theme.Colors.Cyan },
		{ Key = "Max Memory", Value = if memMax >= 1024 then string.format("%.2f MB", memMax / 1024) else string.format("%.2f KB", memMax), Color = Theme.Colors.Orange },
		{ Key = "Total Memory", Value = if memTotal >= 1024 then string.format("%.2f MB", memTotal / 1024) else string.format("%.2f KB", memTotal), Color = Theme.Colors.TextSecondary },
	}
	for i, prop in ipairs(perfProps) do
		self:_BuildPropRow(contentFrame, prop.Key, prop.Value, prop.Color, 50 + i)
	end
end

function TasksModule:_BuildPropRow(parent: Frame, key: string, value: string, color: Color3, order: number)
	local propRow = Instance.new("Frame")
	propRow.Size = UDim2.new(1, 0, 0, 24)
	propRow.BackgroundColor3 = Theme.Colors.GlassTertiary
	propRow.BackgroundTransparency = 0.88
	propRow.BorderSizePixel = 0
	propRow.LayoutOrder = order
	propRow.Parent = parent

	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	c.Parent = propRow

	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 8)
	p.PaddingRight = UDim.new(0, 8)
	p.Parent = propRow

	Theme.CreateLabel({ Text = key, Size = UDim2.new(0.45, 0, 1, 0), Color = Theme.Colors.TextSecondary, FontSize = Theme.TextSize.Caption, Parent = propRow })
	Theme.CreateLabel({ Text = value, Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0.48, 0, 0, 0), Color = color, FontSize = Theme.TextSize.Body, FontFace = Theme.Font.Mono, Alignment = Enum.TextXAlignment.Right, Parent = propRow })
end

-- ══════════════════════════════════════════════════════════════
-- PERF DETAIL
-- ══════════════════════════════════════════════════════════════

function TasksModule:_BuildPerfDetailLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = contentFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.Parent = contentFrame

	Theme.CreateLabel({
		Text = '<font color="#3898FF">◆</font> Performance Dashboard',
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	local metrics = {
		{ Key = "Frames/Sec", Value = string.format("%.1f", self._perfCache.FPS or 0), Color = Theme.Colors.Success },
		{ Key = "Memory", Value = string.format("%.2f MB", self._perfCache.MemoryMB or 0), Color = Theme.Colors.Cyan },
		{ Key = "Active Tasks", Value = tostring(self._perfCache.ActiveTasks or 0), Color = Theme.Colors.Accent },
		{ Key = "Frame Budget", Value = string.format("%.2fms", (self._perfCache.FrameBudget or 0) * 1000), Color = Theme.Colors.Orange },
		{ Key = "Tasks/Frame", Value = string.format("%.1f", self._perfCache.TasksPerFrame or 0), Color = Theme.Colors.Purple },
		{ Key = "History Samples", Value = tostring(#self._perfHistory), Color = Theme.Colors.TextSecondary },
	}
	for i, m in ipairs(metrics) do
		self:_BuildPropRow(contentFrame, m.Key, m.Value, m.Color, i)
	end

	-- FPS chart
	Theme.CreateLabel({
		Text = "FPS HISTORY",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 50

	local chartFrame = Instance.new("Frame")
	chartFrame.Size = UDim2.new(1, 0, 0, 80)
	chartFrame.BackgroundColor3 = Theme.Colors.CardBG
	chartFrame.BackgroundTransparency = 0.4
	chartFrame.BorderSizePixel = 0
	chartFrame.LayoutOrder = 51
	chartFrame.ClipsDescendants = true
	chartFrame.Parent = contentFrame

	local chartCorner = Instance.new("UICorner")
	chartCorner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	chartCorner.Parent = chartFrame

	-- 60 FPS budget line
	local budgetLine = Instance.new("Frame")
	budgetLine.Size = UDim2.new(1, -8, 0, 1)
	budgetLine.Position = UDim2.new(0, 4, 0, 8)
	budgetLine.BackgroundColor3 = Theme.Colors.Accent
	budgetLine.BackgroundTransparency = 0.6
	budgetLine.BorderSizePixel = 0
	budgetLine.Parent = chartFrame

	Theme.CreateLabel({
		Text = "60",
		Size = UDim2.new(0, 20, 0, 12),
		Position = UDim2.new(1, -24, 0, 1),
		Color = Theme.Colors.Accent,
		FontSize = 8,
		FontFace = Theme.Font.Mono,
		Parent = chartFrame,
	})

	-- Draw bars
	local count = math.min(#self._perfHistory, 50)
	if count > 1 then
		local barW = math.max(2, math.floor(580 / count))
		for j = 1, count do
			local idx = #self._perfHistory - count + j
			local snap = self._perfHistory[idx]
			if snap then
				local fpsClamped = math.clamp(snap.FPS or 0, 0, 70)
				local h = (fpsClamped / 70) * 60
				local barColor = if fpsClamped >= 55 then Theme.Colors.Success
					elseif fpsClamped >= 30 then Theme.Colors.Warning
					else Theme.Colors.Danger

				local bar = Instance.new("Frame")
				bar.Size = UDim2.new(0, math.max(barW - 1, 1), 0, math.max(h, 1))
				bar.Position = UDim2.new(0, 4 + (j - 1) * barW, 1, -6 - h)
				bar.BackgroundColor3 = barColor
				bar.BackgroundTransparency = 0.3
				bar.BorderSizePixel = 0
				bar.Parent = chartFrame
			end
		end
	end

	-- Per-task stats
	Theme.CreateLabel({
		Text = "PER-TASK PERFORMANCE",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 100

	local taskList = {}
	for name, data in pairs(self._taskCache) do
		table.insert(taskList, { Name = name, Data = data })
	end
	table.sort(taskList, function(a, b) return (a.Data.AvgTimeMs or 0) > (b.Data.AvgTimeMs or 0) end)

	local nexus = context.Nexus
	for i, item in ipairs(taskList) do
		if i > 15 then break end
		local avgMs = item.Data.AvgTimeMs or 0
		local c = if avgMs > 10 then Theme.Colors.Danger elseif avgMs > 5 then Theme.Colors.Warning else Theme.Colors.Success

		-- Clickable per-task row that navigates to task detail
		local perfRow = Instance.new("Frame")
		perfRow.Size = UDim2.new(1, 0, 0, 24)
		perfRow.BackgroundColor3 = Theme.Colors.GlassTertiary
		perfRow.BackgroundTransparency = 0.88
		perfRow.BorderSizePixel = 0
		perfRow.LayoutOrder = 100 + i
		perfRow.Parent = contentFrame
		Instance.new("UICorner", perfRow).CornerRadius = UDim.new(0, Theme.Radius.Xs)

		local pp = Instance.new("UIPadding")
		pp.PaddingLeft = UDim.new(0, 8)
		pp.PaddingRight = UDim.new(0, 8)
		pp.Parent = perfRow

		Theme.CreateLabel({ Text = item.Name, Size = UDim2.new(0.45, 0, 1, 0), Color = Theme.Colors.TextSecondary, FontSize = Theme.TextSize.Caption, Parent = perfRow })
		Theme.CreateLabel({ Text = string.format("%.3fms (×%d)", avgMs, item.Data.ExecutionCount or 0), Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0.48, 0, 0, 0), Color = c, FontSize = Theme.TextSize.Body, FontFace = Theme.Font.Mono, Alignment = Enum.TextXAlignment.Right, Parent = perfRow })

		local perfBtn = Instance.new("TextButton")
		perfBtn.Size = UDim2.new(1, 0, 1, 0)
		perfBtn.BackgroundTransparency = 1
		perfBtn.Text = ""
		perfBtn.ZIndex = 10
		perfBtn.Parent = perfRow

		local capturedName = item.Name
		local capturedData = item.Data
		perfBtn.MouseButton1Click:Connect(function()
			self._selectedTask = capturedName
			if nexus and nexus._navigator then
				nexus._navigator:ExpandLayer({
					Id = "tasks.detail." .. capturedName,
					ParentId = "tasks.performance",
					Label = capturedName,
					Builder = function(f, ctx) self:_BuildTaskDetailLayer(f, ctx) end,
					Context = { Nexus = nexus, TaskName = capturedName, TaskData = capturedData },
				})
			end
		end)

		if nexus and nexus._animationController then
			nexus._animationController:HoverGlow(perfBtn, c)
		end
	end
end

--[[
	Release autocomplete resources and clear cached task / perf state.
]]
function TasksModule:Destroy()
	if self._searchAC then self._searchAC:Destroy(); self._searchAC = nil end
	table.clear(self._taskCache)
	table.clear(self._archivedTasks)
	table.clear(self._perfCache)
	table.clear(self._perfHistory)
end

return TasksModule
