--!strict


local Theme = require(script.Parent.Parent.Theme)

local ProfilerModule = {}
ProfilerModule.__index = ProfilerModule

local MAX_HOT_ITEMS = 10


function ProfilerModule.new(): any
	local self = setmetatable({}, ProfilerModule)
	self._taskPerf = {} :: { [string]: any }
	self._fsmPerf = {} :: { [string]: any }
	self._frameBudget = { UsedMs = 0, BudgetMs = 16.6, FPS = 60 }
	self._threadPool = { Total = 0, Free = 0, Active = 0, Peak = 0 }
	self._networkTraffic = {} :: { { Name: string, Count: number, LastFired: number } }
	self._gcStats = { MemoryMB = 0 }
	self._instanceMemory = { Services = {}, TopOffenders = {}, TotalDescendants = 0, DuplicateAssets = nil } :: any
	self._sortMode = "AvgTime"
	self._fsmSortMode = "AvgTime"
	self._showDiagnostics = false
	self._showInstanceMemory = true
	return self
end


function ProfilerModule:FetchData(nexus: any)
	local orchestrator = nexus._orchestrator
	if not orchestrator then return end

	if nexus._contextMode == "client" then
		self:_FetchClient(orchestrator, nexus)
	else
		-- In server mode, read from the server snapshot. But also read
		-- the LOCAL orchestrator for any data that's only available locally
		-- (FPS, thread pool stats, client-side scheduler tasks).
		self:_FetchServer(nexus._serverData)
		-- FPS comes from the client's render loop, not the server.
		self._frameBudget.FPS = nexus._lastFPS or self._frameBudget.FPS
	end

	nexus.Store:BatchUpdate(function()
		nexus.Store:Set("profiler.frameBudget", self._frameBudget)
		nexus.Store:Set("profiler.taskCount", self:_CountTable(self._taskPerf))
		nexus.Store:Set("profiler.fsmCount", self:_CountTable(self._fsmPerf))
	end)
end


function ProfilerModule:_CountTable(t: { [any]: any }): number
	local n = 0
	for _ in pairs(t) do n + = 1 end
	return n
end


function ProfilerModule:_FetchClient(orchestrator: any, nexus: any?)
	-- Tasks
	self._taskPerf = {}
	local scheduler = orchestrator.Scheduler
	if scheduler and scheduler.Tasks then
		for name, taskDef in pairs(scheduler.Tasks) do
			local runCount = taskDef.RunCount or 0
			local totalRunTime = taskDef.TotalRunTime or 0
			local avgMs = if runCount > 0 then (totalRunTime / runCount) * 1000 else 0
			local maxMs = (taskDef.MaxRunTime or 0) * 1000
			local totalMem = taskDef.TotalMemory or 0
			local maxMem = taskDef.MaxMemory or 0
			local avgMem = if runCount > 0 then totalMem / runCount else 0

			self._taskPerf[name] = {
				Name = name,
				AvgMs = avgMs,
				MaxMs = maxMs,
				RunCount = runCount,
				MemoryAvgKB = avgMem,
				MemoryMaxKB = maxMem,
				Priority = taskDef.Priority or 5,
				IsRecurring = taskDef.IsRecurringTask or false,
				Event = taskDef.Event or "Heartbeat",
			}
		end

		-- Frame budget from LastFrameStats
		if scheduler.LastFrameStats then
			local lfs = scheduler.LastFrameStats
			self._frameBudget.UsedMs = (lfs.FrameTime or 0) * 1000
			self._frameBudget.BudgetMs = (lfs.Budget or 0.005) * 1000
		end

		-- Thread pool
		if type(scheduler.GetThreadPoolStats) == "function" then
			local ok, stats = pcall(scheduler.GetThreadPoolStats)
			if ok and stats then
				self._threadPool = {
					Total = stats.TotalThreads or 0,
					Free = stats.FreeThreads or 0,
					Active = stats.ActiveThreads or 0,
					Peak = stats.PeakThreads or 0,
				}
			end
		end
	end

	-- FPS comes from the Nexus render loop, not the Orchestrator table.
	self._frameBudget.FPS = (if nexus then nexus._lastFPS else nil)
		or ((orchestrator :: any).Scheduler and (orchestrator :: any).Scheduler.PerformanceManager and (orchestrator :: any).Scheduler.PerformanceManager.FPS)
		or 60

	-- FSMs
	self._fsmPerf = {}
	local factory = orchestrator.Factory
	if factory and factory.Registry then
		local fsms = {}
		if type(factory.Registry.GetAllStateMachines) == "function" then
			local ok, result = pcall(factory.Registry.GetAllStateMachines)
			if ok and type(result) == "table" then fsms = result end
		end
		for id, fsm in pairs(fsms) do
			local perf = (fsm :: any).Perf
			if perf then
				self._fsmPerf[id] = {
					Id = id,
					State = rawget(fsm,"_activeStateName") or rawget(fsm,"State") or "?",
					AvgMs = (perf.AvgUpdateTime or 0) * 1000,
					MaxMs = (perf.MaxUpdateTime or 0) * 1000,
					UpdateCount = perf.UpdateCount or 0,
					MemDeltaKB = perf.MaxMemKBDelta or 0,
					IsActive = rawget(fsm,"IsActive") or false,
				}
			end
		end
	end

	-- Network traffic
	self:_FetchNetworkClient(orchestrator.NetworkManager)

	-- GC
	self._gcStats.MemoryMB = collectgarbage("count") / 1024

	-- Instance memory (client-side)
	self:_FetchInstanceMemoryLocal()
end


function ProfilerModule:_FetchServer(serverData: any?)
	self._taskPerf = {}
	self._fsmPerf = {}
	self._networkTraffic = {}
	if not serverData then
		self._frameBudget.UsedMs = 0
		self._frameBudget.BudgetMs = 16.6
		self._gcStats.MemoryMB = 0
		return
	end

	-- Tasks from snapshot
	if serverData.Tasks and serverData.Tasks.List then
		for name, td in pairs(serverData.Tasks.List) do
			local runCount = td.RunCount or td.ExecutionCount or 0
			local avgMs = td.AvgTimeMs or 0
			local maxMs = td.MaxTimeMs or 0
			self._taskPerf[name] = {
				Name = name,
				AvgMs = avgMs,
				MaxMs = maxMs,
				RunCount = runCount,
				MemoryAvgKB = 0,
				MemoryMaxKB = 0,
				Priority = td.Priority or 5,
				IsRecurring = td.IsRecurringTask or false,
				Event = td.Event or "Heartbeat",
			}
		end
	end

	-- Frame budget from server performance
	if serverData.Tasks and serverData.Tasks.Performance then
		local perf = serverData.Tasks.Performance
		-- Server has no render loop so FPS is only advisory here; FetchData will
		-- overwrite it with the client's live FPS after this snapshot is read.
		self._frameBudget.FPS = perf.FPS or 0
		local rawUsed = perf.UsedMs or perf.FrameTimeMs or perf.FrameTime or 0
		self._frameBudget.UsedMs = if rawUsed > 0 and rawUsed < 1 then rawUsed * 1000 else rawUsed
		-- FrameBudget may be in seconds (e.g., 0.005) — convert to ms.
		local rawBudget = perf.FrameBudget or perf.FrameBudgetMs or 0
		self._frameBudget.BudgetMs = if rawBudget > 0 and rawBudget < 1 then rawBudget * 1000 else rawBudget
		if self._frameBudget.BudgetMs < 0.1 then self._frameBudget.BudgetMs = 16.6 end
		self._gcStats.MemoryMB = perf.MemoryMB or 0
	end

	-- FSMs from snapshot
	self._fsmPerf = {}
	if serverData.FSM then
		local fsmList = serverData.FSM.StateMachines or serverData.FSM.List or {}
		for id, fsmInfo in pairs(fsmList) do
			if type(fsmInfo) ~= "table" then continue end
			local perf = fsmInfo.Perf or {}
			self._fsmPerf[id] = {
				Id = id,
				State = fsmInfo.CurrentState or fsmInfo.State or "?",
				AvgMs = (perf.AvgUpdateTime or 0) * 1000,
				MaxMs = (perf.MaxUpdateTime or 0) * 1000,
				UpdateCount = perf.UpdateCount or 0,
				MemDeltaKB = perf.MaxMemKBDelta or 0,
				IsActive = fsmInfo.IsActive ~= false,
			}
		end
	end

	-- Network from snapshot
	self._networkTraffic = {}
	if serverData.Network then
		for _, category in ipairs({ serverData.Network.Commands, serverData.Network.EventBuses, serverData.Network.Remotes }) do
			if category then
				for name, info in pairs(category) do
					if type(info) == "table" and (info.MessageCount or info.Count or 0) > 0 then
						table.insert(self._networkTraffic, {
							Name = info.Name or name,
							Count = info.MessageCount or info.Count or 0,
							LastFired = info.LastFired or info.LastInvoked or 0,
						})
					end
				end
			end
		end
		table.sort(self._networkTraffic, function(a, b) return a.Count > b.Count end)
	end

	-- Instance memory from server snapshot
	if serverData.InstanceMemory then
		self._instanceMemory = serverData.InstanceMemory
	end
end


function ProfilerModule:_FetchNetworkClient(nm: any?)
	self._networkTraffic = {}
	if not nm then return end

	local function addStats(statsTable: { [string]: any }?)
		if not statsTable then return end
		for name, stats in pairs(statsTable) do
			if type(stats) == "table" and (stats.Count or 0) > 0 then
				table.insert(self._networkTraffic, {
					Name = name,
					Count = stats.Count or 0,
					LastFired = stats.LastFired or stats.LastInvoked or 0,
				})
			end
		end
	end
	addStats(nm._remoteStats)
	addStats(nm._busStats)
	addStats(nm._invokeStats)
	table.sort(self._networkTraffic, function(a, b) return a.Count > b.Count end)
end


function ProfilerModule:_FetchInstanceMemoryLocal()
	local instMem: { [string]: any } = { Services = {}, TopOffenders = {}, TotalDescendants = 0 }
	local serviceNames = {"ReplicatedStorage","Workspace","Lighting","SoundService"}
	for _, svcName in ipairs(serviceNames) do
		local ok, svc = pcall(function() return game:GetService(svcName) end)
		if ok and svc then
			local c = 0
			for _ in svc:GetDescendants() do c + = 1 end
			instMem.Services[svcName] = c
			instMem.TotalDescendants + = c
		end
	end
	-- PlayerGui
	local Players = game:GetService("Players")
	local lp = Players.LocalPlayer
	if lp then
		local pg = lp:FindFirstChild("PlayerGui")
		if pg then
			local c = 0
			for _ in pg:GetDescendants() do c + = 1 end
			instMem.Services["PlayerGui"] = c
			instMem.TotalDescendants + = c
		end
	end
	-- Top offenders in RS
	local rs = game:FindFirstChild("ReplicatedStorage")
	if rs then
		for _, child in rs:GetChildren() do
			local c = 0
			for _ in child:GetDescendants() do c + = 1 end
			if c > 50 then
				table.insert(instMem.TopOffenders, { Name = child.Name, Class = child.ClassName, Count = c, Service = "RS" })
			end
		end
	end
	-- Top offenders in Workspace
	for _, child in game.Workspace:GetChildren() do
		local c = 0
		for _ in child:GetDescendants() do c + = 1 end
		if c > 100 then
			table.insert(instMem.TopOffenders, { Name = child.Name, Class = child.ClassName, Count = c, Service = "WS" })
		end
	end
	table.sort(instMem.TopOffenders, function(a, b) return a.Count > b.Count end)
	if #instMem.TopOffenders > 15 then
		local trimmed = {}
		for i = 1, 15 do trimmed[i] = instMem.TopOffenders[i] end
		instMem.TopOffenders = trimmed
	end
	-- Detect duplicate assets
	local assetsFolder = rs and rs:FindFirstChild("Assets")
	if assetsFolder then
		local nameCounts: {[string]: number} = {}
		for _, child in assetsFolder:GetChildren() do
			nameCounts[child.Name] = (nameCounts[child.Name] or 0) + 1
		end
		local dupes = {}
		for name, count in pairs(nameCounts) do
			if count > 1 then
				table.insert(dupes, { Name = name, Count = count })
			end
		end
		if #dupes > 0 then
			table.sort(dupes, function(a, b) return a.Count > b.Count end)
			instMem.DuplicateAssets = dupes
		end
	end
	self._instanceMemory = instMem
end


function ProfilerModule:Render(_nexus: any) end


function ProfilerModule:_GetSortedTasks(): { any }
	local result = {}
	for _, data in pairs(self._taskPerf) do
		table.insert(result, data)
	end
	local mode = self._sortMode
	table.sort(result, function(a, b)
		if mode == "AvgTime" then return (a.AvgMs or 0) > (b.AvgMs or 0)
		elseif mode == "MaxTime" then return (a.MaxMs or 0) > (b.MaxMs or 0)
		elseif mode == "Runs" then return (a.RunCount or 0) > (b.RunCount or 0)
		elseif mode == "Memory" then return (a.MemoryAvgKB or 0) > (b.MemoryAvgKB or 0)
		elseif mode == "Name" then return (a.Name or "") < (b.Name or "")
		end
		return (a.AvgMs or 0) > (b.AvgMs or 0)
	end)
	return result
end


function ProfilerModule:_GetSortedFSMs(): { any }
	local result = {}
	for _, data in pairs(self._fsmPerf) do
		table.insert(result, data)
	end
	local mode = self._fsmSortMode
	table.sort(result, function(a, b)
		if mode == "AvgTime" then return (a.AvgMs or 0) > (b.AvgMs or 0)
		elseif mode == "MaxTime" then return (a.MaxMs or 0) > (b.MaxMs or 0)
		elseif mode == "Updates" then return (a.UpdateCount or 0) > (b.UpdateCount or 0)
		elseif mode == "Memory" then return (a.MemDeltaKB or 0) > (b.MemDeltaKB or 0)
		elseif mode == "Name" then return (a.Id or "") < (b.Id or "")
		end
		return (a.AvgMs or 0) > (b.AvgMs or 0)
	end)
	return result
end


function ProfilerModule:BuildRootLayer(frame: Frame, context: any)
	local nexus = context.Nexus
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	Theme.ClearExcept(contentFrame, {})

	if not contentFrame:FindFirstChildOfClass("UIListLayout") then
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = contentFrame
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 10)
		pad.PaddingTop = UDim.new(0, 8)
		pad.PaddingBottom = UDim.new(0, 8)
		pad.Parent = contentFrame
	end

	local order = 0
	local function nextOrder(): number
		order + = 1
		return order
	end

	-- ── FRAME BUDGET BAR ──────────────────────────────────────
	self:_BuildBudgetBar(contentFrame, nextOrder())

	-- ── HOT TASKS ─────────────────────────────────────────────
	self:_BuildHotTasksSection(contentFrame, nexus, nextOrder())

	-- ── HOT FSMs ──────────────────────────────────────────────
	self:_BuildHotFSMsSection(contentFrame, nexus, nextOrder())

	-- ── INSTANCE MEMORY ──────────────────────────────────────
	self:_BuildInstanceMemorySection(contentFrame, nexus, nextOrder())

	-- ── DIAGNOSTICS (collapsed) ───────────────────────────────
	self:_BuildDiagnosticsSection(contentFrame, nexus, nextOrder())
end


function ProfilerModule:_BuildBudgetBar(parent: Frame, layoutOrder: number)
	local fb = self._frameBudget
	local usedMs = fb.UsedMs or 0
	local budgetMs = math.max(fb.BudgetMs or 16.6, 0.1)
	local fps = fb.FPS or 0
	local pct = math.clamp(usedMs / budgetMs, 0, 1)
	local barColor = if pct > 0.9 then Theme.Colors.Danger
		elseif pct > 0.6 then Theme.Colors.Warning
		else Theme.Colors.Success

	local container = Instance.new("Frame")
	container.Name = "BudgetBar"
	container.Size = UDim2.new(1, 0, 0, 40)
	container.BackgroundColor3 = Theme.Colors.GlassTertiary
	container.BackgroundTransparency = 0.7
	container.BorderSizePixel = 0
	container.LayoutOrder = layoutOrder
	container.Parent = parent
	Instance.new("UICorner", container).CornerRadius = UDim.new(0, Theme.Radius.Sm)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = container

	-- Label
	Theme.CreateLabel({
		Text = string.format(
			'<font color="#888">FRAME BUDGET</font>  <font color="#FFF">%.2fms</font> / <font color="#888">%.1fms</font>  <font color="#666">(%d FPS)</font>',
			usedMs, budgetMs, fps),
		Size = UDim2.new(1, 0, 0, 14),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Alignment = Enum.TextXAlignment.Left,
		Parent = container,
	})

	-- Bar track
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 8)
	track.Position = UDim2.new(0, 0, 1, -8)
	track.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	track.BackgroundTransparency = 0.3
	track.BorderSizePixel = 0
	track.Parent = container
	Instance.new("UICorner", track).CornerRadius = UDim.new(0, 4)

	-- Fill
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(pct, 0, 1, 0)
	fill.BackgroundColor3 = barColor
	fill.BackgroundTransparency = 0.2
	fill.BorderSizePixel = 0
	fill.Parent = track
	Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 4)

	-- Memory badge (Lua heap + Instance count)
	local totalInst = self._instanceMemory.TotalDescendants or 0
	local instColor = if totalInst > 5000 then"#FF4444" elseif totalInst > 2000 then"#FFAA00" else"#888"
	Theme.CreateLabel({
		Text = string.format('<font color="#666">LUA</font> %.1fMB  <font color="%s">INST</font> <font color="%s">%s</font>',
			self._gcStats.MemoryMB, instColor, instColor,
			if totalInst > 1000 then string.format("%.1fK", totalInst / 1000) else tostring(totalInst)),
		Size = UDim2.new(0, 200, 0, 14),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Alignment = Enum.TextXAlignment.Right,
		Parent = container,
	})
end


function ProfilerModule:_BuildHotTasksSection(parent: Frame, nexus: any, layoutOrder: number)
	local sorted = self:_GetSortedTasks()

	Theme.CreateLabel({
		Text = string.format('<font color="#3898FF">▸</font> HOT TASKS <font color="#666">(%d total, top %d)</font>',
			#sorted, math.min(#sorted, MAX_HOT_ITEMS)),
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Alignment = Enum.TextXAlignment.Left,
		Parent = parent,
	}).LayoutOrder = layoutOrder * 100

	-- Header row
	local headerOrder = layoutOrder * 100 + 1
	self:_BuildTableHeader(parent, headerOrder,
		{"Name","AvgMs","MaxMs","×Runs","MemKB","Pri" },
		{ 0.35, 0.13, 0.13, 0.13, 0.13, 0.08 })

	for i, task in ipairs(sorted) do
		if i > MAX_HOT_ITEMS then break end
		local rowOrder = layoutOrder * 100 + 1 + i

		local avgColor = if task.AvgMs > 1 then Theme.Colors.Danger
			elseif task.AvgMs > 0.1 then Theme.Colors.Warning
			else Theme.Colors.Success

		self:_BuildTableRow(parent, rowOrder, {
			{ Text = task.Name or "?", Width = 0.35, Color = Theme.Colors.TextPrimary },
			{ Text = string.format("%.3f", task.AvgMs), Width = 0.13, Color = avgColor },
			{ Text = string.format("%.2f", task.MaxMs), Width = 0.13, Color = Theme.Colors.TextSecondary },
			{ Text = string.format("×%d", task.RunCount), Width = 0.13, Color = Theme.Colors.Cyan },
			{ Text = string.format("%.1f", task.MemoryAvgKB), Width = 0.13, Color = Theme.Colors.TextMuted },
			{ Text = string.format("P%d", task.Priority), Width = 0.08, Color = Theme.Colors.TextMuted },
		})
	end

	if #sorted == 0 then
		Theme.CreateLabel({
			Text = "(no tasks)",
			Size = UDim2.new(1, 0, 0, 14),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Center,
			Parent = parent,
		}).LayoutOrder = layoutOrder * 100 + 2
	end
end


function ProfilerModule:_BuildHotFSMsSection(parent: Frame, nexus: any, layoutOrder: number)
	local sorted = self:_GetSortedFSMs()

	Theme.CreateLabel({
		Text = string.format('<font color="#3CD278">▸</font> HOT FSMs <font color="#666">(%d total, top %d)</font>',
			#sorted, math.min(#sorted, MAX_HOT_ITEMS)),
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Alignment = Enum.TextXAlignment.Left,
		Parent = parent,
	}).LayoutOrder = layoutOrder * 100

	-- Header
	local headerOrder = layoutOrder * 100 + 1
	self:_BuildTableHeader(parent, headerOrder,
		{"FSM Id","State","AvgMs","MaxMs","×Updates","MemΔ" },
		{ 0.30, 0.15, 0.13, 0.13, 0.13, 0.11 })

	for i, fsm in ipairs(sorted) do
		if i > MAX_HOT_ITEMS then break end
		local rowOrder = layoutOrder * 100 + 1 + i

		local avgColor = if fsm.AvgMs > 1 then Theme.Colors.Danger
			elseif fsm.AvgMs > 0.1 then Theme.Colors.Warning
			else Theme.Colors.Success

		-- Truncate FSM id for display
		local displayId = fsm.Id or "?"
		if #displayId > 30 then displayId = displayId:sub(1, 28) ..".." end

		self:_BuildTableRow(parent, rowOrder, {
			{ Text = displayId, Width = 0.30, Color = if fsm.IsActive then Theme.Colors.TextPrimary else Theme.Colors.TextMuted },
			{ Text = fsm.State or "?", Width = 0.15, Color = Theme.Colors.Accent },
			{ Text = string.format("%.3f", fsm.AvgMs), Width = 0.13, Color = avgColor },
			{ Text = string.format("%.2f", fsm.MaxMs), Width = 0.13, Color = Theme.Colors.TextSecondary },
			{ Text = string.format("×%d", fsm.UpdateCount), Width = 0.13, Color = Theme.Colors.Cyan },
			{ Text = string.format("%.1f", fsm.MemDeltaKB), Width = 0.11, Color = Theme.Colors.TextMuted },
		})
	end

	if #sorted == 0 then
		Theme.CreateLabel({
			Text = "(no FSMs with perf data)",
			Size = UDim2.new(1, 0, 0, 14),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Center,
			Parent = parent,
		}).LayoutOrder = layoutOrder * 100 + 2
	end
end


function ProfilerModule:_BuildInstanceMemorySection(parent: Frame, _nexus: any, layoutOrder: number)
	local im = self._instanceMemory
	local total = im.TotalDescendants or 0
	local totalColor = if total > 5000 then Theme.Colors.Danger
		elseif total > 2000 then Theme.Colors.Warning
		else Theme.Colors.Success

	-- Toggle button
	local btn = Instance.new("TextButton")
	btn.Name = "InstanceMemoryToggle"
	btn.Size = UDim2.new(1, 0, 0, 22)
	btn.BackgroundColor3 = Theme.Colors.GlassTertiary
	btn.BackgroundTransparency = 0.8
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.LayoutOrder = layoutOrder * 100
	btn.Text = ""
	btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	local chevron = if self._showInstanceMemory then"▾" else"▸"
	Theme.CreateLabel({
		Text = string.format(
			'<font color="#FF8C00">%s</font> INSTANCE MEMORY <font color="#666">(%s total descendants)</font>',
			chevron,
			if total > 1000 then string.format("%.1fK", total / 1000) else tostring(total)),
		Size = UDim2.new(1, -8, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		Color = totalColor,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Alignment = Enum.TextXAlignment.Left,
		Parent = btn,
	})

	if not self._showInstanceMemory then
		btn.MouseButton1Click:Connect(function()
			self._showInstanceMemory = true
			local nav = _nexus and _nexus._navigator
			if nav then nav:RebuildCurrentLayer() end
		end)
		return
	end

	btn.MouseButton1Click:Connect(function()
		self._showInstanceMemory = false
		local nav = _nexus and _nexus._navigator
		if nav then nav:RebuildCurrentLayer() end
	end)

	-- Service breakdown
	Theme.CreateLabel({
		Text = '<font color="#888">SERVICE BREAKDOWN</font>',
		Size = UDim2.new(1, 0, 0, 14),
		Color = Theme.Colors.TextSecondary,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Bold,
		Alignment = Enum.TextXAlignment.Left,
		Parent = parent,
	}).LayoutOrder = layoutOrder * 100 + 1

	-- Sort services by count descending
	local services = {}
	for name, count in pairs(im.Services or {}) do
		table.insert(services, { Name = name, Count = count })
	end
	table.sort(services, function(a, b) return a.Count > b.Count end)

	for i, svc in ipairs(services) do
		local svcColor = if svc.Count > 3000 then"#FF4444"
			elseif svc.Count > 1000 then"#FFAA00"
			elseif svc.Count > 500 then"#FFD700"
			else"#888"
		Theme.CreateLabel({
			Text = string.format('  <font color="%s">%-28s</font> <font color="%s">%s</font>',
				"#9DC9FF", svc.Name, svcColor,
				if svc.Count > 1000 then string.format("%.1fK", svc.Count / 1000) else tostring(svc.Count)),
			Size = UDim2.new(1, 0, 0, 14),
			Color = Theme.Colors.TextSecondary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = parent,
		}).LayoutOrder = layoutOrder * 100 + 1 + i
	end

	-- Top offenders
	local offenders = im.TopOffenders or {}
	if #offenders > 0 then
		Theme.CreateLabel({
			Text = string.format('<font color="#888">TOP OFFENDERS</font> <font color="#666">(>50 descendants)</font>'),
			Size = UDim2.new(1, 0, 0, 14),
			Color = Theme.Colors.TextSecondary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Bold,
			Alignment = Enum.TextXAlignment.Left,
			Parent = parent,
		}).LayoutOrder = layoutOrder * 100 + 50

		-- Header
		self:_BuildTableHeader(parent, layoutOrder * 100 + 51,
			{"Name","Class","Descendants","Service" },
			{ 0.35, 0.20, 0.25, 0.15 })

		for i, off in ipairs(offenders) do
			if i > 10 then break end
			local countColor = if off.Count > 1000 then Theme.Colors.Danger
				elseif off.Count > 500 then Theme.Colors.Warning
				else Theme.Colors.TextSecondary

			self:_BuildTableRow(parent, layoutOrder * 100 + 51 + i, {
				{ Text = off.Name or "?", Width = 0.35, Color = Theme.Colors.TextPrimary },
				{ Text = off.Class or "?", Width = 0.20, Color = Theme.Colors.TextMuted },
				{ Text = if off.Count > 1000 then string.format("%.1fK", off.Count / 1000) else tostring(off.Count), Width = 0.25, Color = countColor },
				{ Text = off.Service or "RS", Width = 0.15, Color = Theme.Colors.Cyan },
			})
		end
	end

	-- Duplicate assets warning
	local dupes = im.DuplicateAssets
	if dupes and #dupes > 0 then
		local dupeOrder = layoutOrder * 100 + 70
		Theme.CreateLabel({
			Text = string.format('<font color="#FF4444">⚠ DUPLICATE ASSETS DETECTED (%d names)</font>', #dupes),
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.Danger,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Alignment = Enum.TextXAlignment.Left,
			Parent = parent,
		}).LayoutOrder = dupeOrder

		for i, dupe in ipairs(dupes) do
			if i > 10 then break end
			Theme.CreateLabel({
				Text = string.format('  <font color="#FF6666">%s</font> × <font color="#FF4444">%d copies</font>',
					dupe.Name, dupe.Count),
				Size = UDim2.new(1, 0, 0, 14),
				Color = Theme.Colors.TextSecondary,
				FontSize = Theme.TextSize.Tiny,
				FontFace = Theme.Font.Mono,
				Alignment = Enum.TextXAlignment.Left,
				Parent = parent,
			}).LayoutOrder = dupeOrder + i
		end
	end

	-- FSM Instance ownership
	local ownership = im.FSMOwnership
	if ownership and next(ownership) then
		local ownOrder = layoutOrder * 100 + 82
		Theme.CreateLabel({
			Text = '<font color="#888">FSM INSTANCE OWNERSHIP</font>',
			Size = UDim2.new(1, 0, 0, 14),
			Color = Theme.Colors.TextSecondary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Bold,
			Alignment = Enum.TextXAlignment.Left,
			Parent = parent,
		}).LayoutOrder = ownOrder

		-- Sort by count descending
		local sorted = {}
		for fsmId, count in pairs(ownership) do
			table.insert(sorted, { Id = fsmId, Count = count })
		end
		table.sort(sorted, function(a, b) return a.Count > b.Count end)

		for i, entry in ipairs(sorted) do
			if i > 8 then break end
			local countColor = if entry.Count > 5 then"#FF4444" elseif entry.Count > 2 then"#FFAA00" else"#888"
			local displayId = entry.Id
			if #displayId > 35 then displayId = displayId:sub(1, 33) ..".." end
			Theme.CreateLabel({
				Text = string.format('  <font color="#9DC9FF">%s</font>  <font color="%s">×%d instances</font>',
					displayId, countColor, entry.Count),
				Size = UDim2.new(1, 0, 0, 14),
				Color = Theme.Colors.TextSecondary,
				FontSize = Theme.TextSize.Tiny,
				FontFace = Theme.Font.Mono,
				Alignment = Enum.TextXAlignment.Left,
				Parent = parent,
			}).LayoutOrder = ownOrder + i
		end
	end

	-- Suspected orphans
	local orphans = im.SuspectedOrphans
	if orphans and #orphans > 0 then
		local orphOrder = layoutOrder * 100 + 92
		Theme.CreateLabel({
			Text = string.format('<font color="#FF8C00">⚠ SUSPECTED ORPHAN INSTANCES (%d found)</font>', #orphans),
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.Warning,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Alignment = Enum.TextXAlignment.Left,
			Parent = parent,
		}).LayoutOrder = orphOrder

		for i, orphan in ipairs(orphans) do
			if i > 8 then break end
			Theme.CreateLabel({
				Text = string.format('  <font color="#FFB347">%s</font> (%s)  <font color="#666">age: %ds</font>',
					orphan.Name, orphan.Class, orphan.Age or 0),
				Size = UDim2.new(1, 0, 0, 14),
				Color = Theme.Colors.TextSecondary,
				FontSize = Theme.TextSize.Tiny,
				FontFace = Theme.Font.Mono,
				Alignment = Enum.TextXAlignment.Left,
				Parent = parent,
			}).LayoutOrder = orphOrder + i
		end
	end
end


function ProfilerModule:_BuildDiagnosticsSection(parent: Frame, _nexus: any, layoutOrder: number)
	local btn = Instance.new("TextButton")
	btn.Name = "DiagnosticsToggle"
	btn.Size = UDim2.new(1, 0, 0, 22)
	btn.BackgroundColor3 = Theme.Colors.GlassTertiary
	btn.BackgroundTransparency = 0.8
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.LayoutOrder = layoutOrder * 100
	btn.Text = ""
	btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	local chevron = if self._showDiagnostics then"▾" else"▸"
	Theme.CreateLabel({
		Text = string.format('<font color="#666">%s</font> DIAGNOSTICS', chevron),
		Size = UDim2.new(1, -8, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Alignment = Enum.TextXAlignment.Left,
		Parent = btn,
	})

	if not self._showDiagnostics then
		btn.MouseButton1Click:Connect(function()
			self._showDiagnostics = true
			-- Rebuild via navigator
			local nav = _nexus and _nexus._navigator
			if nav then nav:RebuildCurrentLayer() end
		end)
		return
	end

	btn.MouseButton1Click:Connect(function()
		self._showDiagnostics = false
		local nav = _nexus and _nexus._navigator
		if nav then nav:RebuildCurrentLayer() end
	end)

	-- Thread pool
	local tp = self._threadPool
	local threadText = string.format(
		'<font color="#888">THREAD POOL</font>  Total: %d  Free: %d  Active: %d  Peak: %d',
		tp.Total, tp.Free, tp.Active, tp.Peak)
	Theme.CreateLabel({
		Text = threadText,
		Size = UDim2.new(1, 0, 0, 14),
		Color = Theme.Colors.TextSecondary,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Alignment = Enum.TextXAlignment.Left,
		Parent = parent,
	}).LayoutOrder = layoutOrder * 100 + 1

	-- GC
	Theme.CreateLabel({
		Text = string.format('<font color="#888">GC</font>  Heap: %.1f MB', self._gcStats.MemoryMB),
		Size = UDim2.new(1, 0, 0, 14),
		Color = Theme.Colors.TextSecondary,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Alignment = Enum.TextXAlignment.Left,
		Parent = parent,
	}).LayoutOrder = layoutOrder * 100 + 2

	-- Network traffic top 5
	Theme.CreateLabel({
		Text = string.format('<font color="#888">NETWORK TRAFFIC</font>  <font color="#666">(top 5 by volume)</font>'),
		Size = UDim2.new(1, 0, 0, 14),
		Color = Theme.Colors.TextSecondary,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Bold,
		Alignment = Enum.TextXAlignment.Left,
		Parent = parent,
	}).LayoutOrder = layoutOrder * 100 + 3

	for i, item in ipairs(self._networkTraffic) do
		if i > 5 then break end
		local ago = "—"
		if item.LastFired and item.LastFired > 0 then
			local a = os.clock() - item.LastFired
			if a < 1 then ago = string.format("%.0fms ago", a * 1000)
			elseif a < 60 then ago = string.format("%.1fs ago", a)
			else ago = string.format("%.0fm ago", a / 60) end
		end
		Theme.CreateLabel({
			Text = string.format('  <font color="#9DC9FF">%s</font>  ×%d  <font color="#666">%s</font>',
				item.Name, item.Count, ago),
			Size = UDim2.new(1, 0, 0, 14),
			Color = Theme.Colors.TextSecondary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = parent,
		}).LayoutOrder = layoutOrder * 100 + 3 + i
	end

	if #self._networkTraffic == 0 then
		Theme.CreateLabel({
			Text = "  (no network traffic)",
			Size = UDim2.new(1, 0, 0, 14),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = parent,
		}).LayoutOrder = layoutOrder * 100 + 4
	end
end


function ProfilerModule:_BuildTableHeader(parent: Frame, layoutOrder: number, columns: { string }, widths: { number })
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 16)
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local xOff = 0
	for i, col in ipairs(columns) do
		local w = widths[i] or 0.1
		Theme.CreateLabel({
			Text = col,
			Size = UDim2.new(w, -4, 1, 0),
			Position = UDim2.new(xOff, 2, 0, 0),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Bold,
			Alignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		xOff + = w
	end
end


function ProfilerModule:_BuildTableRow(parent: Frame, layoutOrder: number, cells: { { Text: string, Width: number, Color: Color3 } })
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 18)
	row.BackgroundColor3 = Theme.Colors.GlassTertiary
	row.BackgroundTransparency = 0.88
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	local xOff = 0
	for _, cell in ipairs(cells) do
		local w = cell.Width or 0.1
		Theme.CreateLabel({
			Text = cell.Text,
			Size = UDim2.new(w, -4, 1, 0),
			Position = UDim2.new(xOff, 4, 0, 0),
			Color = cell.Color or Theme.Colors.TextSecondary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		xOff + = w
	end
end


function ProfilerModule:Destroy()
	table.clear(self._taskPerf)
	table.clear(self._fsmPerf)
	table.clear(self._networkTraffic)
end

return ProfilerModule
