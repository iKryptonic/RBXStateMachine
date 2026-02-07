--!strict
-- @Name PerformancePageFSM
-- @Author iKrypto
-- @Description Performance Page FSM managing frame stats, graph, and task metrics.
-- Migrated from legacy PerformancePage.luau controller pattern.

local BasePageFSM = require(script.Parent.BasePageFSM)

local PerformancePageFSM = BasePageFSM.Extend({
	className = "PerformancePageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ShowingDetails", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 7
})

-- Sort modes for performance metrics
local SORT_MODES = { "Name", "Avg", "Max", "Count" }

--[[
	@description Registers states for the performance page FSM.
	@return ()
]]
function PerformancePageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("ShowingDetails", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity
			fsm:Log({ Level = "DEBUG", Message = string.format("Showing task metrics: %s", tostring(entity.SelectedTask)) })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

--[[
	@description Hook for initializing performance UI elements.
	@param entity any
	@return ()
]]
function PerformancePageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing Performance Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "Performance container not found" })
		return
	end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local view = container.Parent
	
	if not view then return end
	
	-- Create toolbar
	local toolbar = view:FindFirstChild("Toolbar")
	if not toolbar then
		toolbar = Instance.new("Frame")
		toolbar.Name = "Toolbar"
		toolbar.Size = UDim2.new(1, 0, 0, 35)
		toolbar.BackgroundTransparency = 1
		toolbar.Parent = view
		
		local layout = Instance.new("UIListLayout", toolbar)
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, 5)
	end
	
	-- Search box
	local search = toolbar:FindFirstChild("Search")
	if not search then
		search = Instance.new("TextBox")
		search.Name = "Search"
		search.Size = UDim2.new(0, 120, 1, 0)
		search.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		search.TextColor3 = Color3.new(1, 1, 1)
		search.Font = Enum.Font.Gotham
		search.TextSize = 12
		search.PlaceholderText = "Search..."
		search.Text = entity.Search or ""
		search.Parent = toolbar
		search.LayoutOrder = -1
		
		Instance.new("UICorner", search).CornerRadius = UDim.new(0, 4)
		local pad = Instance.new("UIPadding", search)
		pad.PaddingLeft = UDim.new(0, 8)
		
		local debounceToken = 0
		entity:Manage(search:GetPropertyChangedSignal("Text"):Connect(function()
			debounceToken += 1
			local token = debounceToken
			task.delay(0.15, function()
				if token == debounceToken then
					entity:SetSearch(search.Text)
					entity:ResetPagination()
					entity:UpdateEntity()
					self:RequestRender()
				end
			end)
		end))
	end
	
	-- Active/Inactive filter buttons
	local filterData = {
		{ name = "Active", color = colors.Success or Color3.fromRGB(160, 255, 160) },
		{ name = "Inactive", color = colors.Error or Color3.fromRGB(255, 120, 120) }
	}
	
	for _, filter in ipairs(filterData) do
		local filterBtn = toolbar:FindFirstChild(filter.name .. "Filter")
		if not filterBtn then
			filterBtn = Instance.new("TextButton")
			filterBtn.Name = filter.name .. "Filter"
			filterBtn.Size = UDim2.new(0, 60, 1, 0)
			filterBtn.Text = filter.name
			filterBtn.TextColor3 = Color3.new(1, 1, 1)
			filterBtn.BackgroundColor3 = filter.color
			filterBtn.BackgroundTransparency = entity.Filters[filter.name] and 0 or 0.7
			filterBtn.Font = Enum.Font.GothamBold
			filterBtn.TextSize = 10
			filterBtn.BorderSizePixel = 0
			filterBtn.Parent = toolbar
			
			Instance.new("UICorner", filterBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(filterBtn.MouseButton1Click:Connect(function()
				entity:ToggleFilter(filter.name)
				filterBtn.BackgroundTransparency = entity.Filters[filter.name] and 0 or 0.7
				entity:ResetPagination()
				entity:UpdateEntity()
				self:RequestRender()
			end))
		end
	end
	
	-- Sort button
	local sortBtn = toolbar:FindFirstChild("SortBtn")
	if not sortBtn then
		sortBtn = Instance.new("TextButton")
		sortBtn.Name = "SortBtn"
		sortBtn.Size = UDim2.new(0, 80, 1, 0)
		sortBtn.Text = "SORT: " .. string.upper(entity.SortMode or "NAME")
		sortBtn.TextColor3 = Color3.new(1, 1, 1)
		sortBtn.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
		sortBtn.Font = Enum.Font.GothamBold
		sortBtn.TextSize = 10
		sortBtn.BorderSizePixel = 0
		sortBtn.Parent = toolbar
		
		Instance.new("UICorner", sortBtn).CornerRadius = UDim.new(0, 4)
		
		entity:Manage(sortBtn.MouseButton1Click:Connect(function()
			entity:CycleSortMode()
			sortBtn.Text = "SORT: " .. string.upper(entity.SortMode)
			entity:UpdateEntity()
			self:RequestRender()
		end))
	end
	entity.SortButton = sortBtn
	
	-- GlobalStats panel
	local globalStats = view:FindFirstChild("GlobalStats")
	if globalStats then
		globalStats.Position = UDim2.new(0, 0, 0, 40)
		container.Size = UDim2.new(1, 0, 1, -190)
		container.Position = UDim2.new(0, 0, 0, 150)
		entity.GlobalStats = globalStats
		
		-- Ensure StatsLabels container
		local statsLabels = globalStats:FindFirstChild("StatsLabels")
		if not statsLabels then
			statsLabels = Instance.new("Frame", globalStats)
			statsLabels.Name = "StatsLabels"
			statsLabels.Size = UDim2.new(0.3, 0, 1, -10)
			statsLabels.Position = UDim2.new(0, 5, 0, 5)
			statsLabels.BackgroundTransparency = 1
			
			local layout = Instance.new("UIListLayout", statsLabels)
			layout.Padding = UDim.new(0, 2)
		end
		entity.StatsLabels = statsLabels
		
		-- Ensure GraphContainer
		local graphContainer = globalStats:FindFirstChild("GraphContainer")
		if not graphContainer then
			graphContainer = Instance.new("Frame", globalStats)
			graphContainer.Name = "GraphContainer"
			graphContainer.Size = UDim2.new(0.7, -10, 1, -10)
			graphContainer.Position = UDim2.new(0.3, 5, 0, 5)
			graphContainer.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
			graphContainer.Active = true
			graphContainer.Selectable = false
			
			Instance.new("UICorner", graphContainer).CornerRadius = UDim.new(0, 4)
		end
		entity.GraphContainer = graphContainer
		
		-- Pause button
		local pauseBtn = globalStats:FindFirstChild("PauseBtn")
		if not pauseBtn then
			pauseBtn = Instance.new("TextButton", globalStats)
			pauseBtn.Name = "PauseBtn"
			pauseBtn.Size = UDim2.new(0, 60, 0, 20)
			pauseBtn.Position = UDim2.new(1, -65, 0, 5)
			pauseBtn.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
			pauseBtn.TextColor3 = Color3.new(1, 1, 1)
			pauseBtn.Font = Enum.Font.GothamBold
			pauseBtn.TextSize = 10
			pauseBtn.Text = "PAUSE"
			Instance.new("UICorner", pauseBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(pauseBtn.MouseButton1Click:Connect(function()
				entity:ToggleGraphPaused()
				pauseBtn.Text = entity.IsGraphPaused and "RESUME" or "PAUSE"
				pauseBtn.BackgroundColor3 = entity.IsGraphPaused and (colors.Warning or Color3.fromRGB(255, 200, 100)) or (colors.DarkBG or Color3.fromRGB(40, 40, 40))
			end))
		end
		entity.PauseButton = pauseBtn
		
		-- Mode button
		local modeBtn = globalStats:FindFirstChild("ModeBtn")
		if not modeBtn then
			modeBtn = Instance.new("TextButton", globalStats)
			modeBtn.Name = "ModeBtn"
			modeBtn.Size = UDim2.new(0, 90, 0, 20)
			modeBtn.Position = UDim2.new(1, -160, 0, 5)
			modeBtn.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
			modeBtn.TextColor3 = Color3.new(1, 1, 1)
			modeBtn.Font = Enum.Font.GothamBold
			modeBtn.TextSize = 10
			modeBtn.Text = "VIEW: " .. string.upper(entity.GraphMode)
			Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(modeBtn.MouseButton1Click:Connect(function()
				entity:CycleGraphMode()
				modeBtn.Text = "VIEW: " .. string.upper(entity.GraphMode)
				self:RequestRender()
			end))
		end
		entity.ModeButton = modeBtn
		
		-- Tooltip
		local tooltip = globalStats:FindFirstChild("Tooltip")
		if not tooltip then
			tooltip = Instance.new("Frame", globalStats)
			tooltip.Name = "Tooltip"
			tooltip.Visible = false
			tooltip.Size = UDim2.new(0, 110, 0, 35)
			tooltip.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
			tooltip.ZIndex = 10
			Instance.new("UICorner", tooltip).CornerRadius = UDim.new(0, 4)
			Instance.new("UIStroke", tooltip).Color = Color3.fromRGB(80, 80, 80)
			
			local tooltipLabel = Instance.new("TextLabel", tooltip)
			tooltipLabel.Name = "Label"
			tooltipLabel.Size = UDim2.new(1, -10, 1, 0)
			tooltipLabel.Position = UDim2.new(0, 5, 0, 0)
			tooltipLabel.BackgroundTransparency = 1
			tooltipLabel.TextColor3 = Color3.new(1, 1, 1)
			tooltipLabel.Font = Enum.Font.Code
			tooltipLabel.TextSize = 10
			tooltipLabel.RichText = true
			tooltipLabel.TextXAlignment = Enum.TextXAlignment.Left
		end
		entity.Tooltip = tooltip
		
		-- Graph hover handler
		if not graphContainer:FindFirstChild("Hover") then
			Instance.new("BoolValue", graphContainer).Name = "Hover"
			
			entity:Manage(graphContainer.InputChanged:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseMovement then
					local history = entity.GraphHistory
					if #history <= 0 then
						tooltip.Visible = false
						return
					end
					
					local relX = input.Position.X - graphContainer.AbsolutePosition.X
					local idx = math.clamp(math.floor((relX / math.max(1, graphContainer.AbsoluteSize.X)) * (#history - 1)) + 1, 1, #history)
					local entry = history[idx]
					
					if entry then
						local sampleValueMs = type(entry) == "table" and entry.Val or entry
						local sampleTaskCount = type(entry) == "table" and entry.Count or 0
						tooltip.Visible = true
						tooltip.Label.Text = string.format("Time: <font color='#A0FFA0'>%.2fms</font>\nTasks: <font color='#00C8FF'>%d</font>", sampleValueMs, sampleTaskCount)
						
						local maxX = math.max(0, graphContainer.AbsoluteSize.X - tooltip.AbsoluteSize.X)
						local posX = math.clamp(relX + 10, 0, maxX)
						tooltip.Position = UDim2.new(0, posX, 0, 10)
					end
				end
			end))
			
			entity:Manage(graphContainer.MouseLeave:Connect(function()
				tooltip.Visible = false
			end))
		end
	end
	
	-- TaskList panel
	local taskList = container:FindFirstChild("TaskList")
	if not taskList then
		taskList = Instance.new("ScrollingFrame")
		taskList.Name = "TaskList"
		taskList.Size = UDim2.new(0.65, -5, 1, 0)
		taskList.BackgroundTransparency = 1
		taskList.ScrollBarThickness = 2
		taskList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		taskList.Parent = container
		
		local layout = Instance.new("UIListLayout", taskList)
		layout.Padding = UDim.new(0, 5)
	end
	entity.TaskList = taskList
	
	-- TaskMetadata panel
	local metadataPanel = container:FindFirstChild("TaskMetadata")
	if not metadataPanel then
		metadataPanel = Instance.new("ScrollingFrame")
		metadataPanel.Name = "TaskMetadata"
		metadataPanel.Size = UDim2.new(0.35, 0, 1, 0)
		metadataPanel.Position = UDim2.new(0.65, 5, 0, 0)
		metadataPanel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		metadataPanel.ScrollBarThickness = 2
		metadataPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
		metadataPanel.Parent = container
		
		Instance.new("UICorner", metadataPanel).CornerRadius = UDim.new(0, 6)
		local layout = Instance.new("UIListLayout", metadataPanel)
		layout.Padding = UDim.new(0, 2)
		local padding = Instance.new("UIPadding", metadataPanel)
		padding.PaddingLeft = UDim.new(0, 5)
		padding.PaddingTop = UDim.new(0, 5)
	end
	entity.MetadataPanel = metadataPanel
	
	self:Log({ Level = "INFO", Message = "Performance Page UI initialized successfully" })
end

--[[
	@description Hook for fetching performance data.
	@param entity any
	@return ()
]]
function PerformancePageFSM:OnFetchData(entity: any)
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
	if not scheduler then return end
	
	-- Get frame stats
	local frameStats = scheduler.LastFrameStats or { FrameTime = 0, TaskCount = 0, Budget = 0 }
	self.Context._frameStats = frameStats
	
	-- Get performance stats
	local pm = scheduler.PerformanceManager
	local stats = pm and pm.Stats or {}
	local activeTasks = scheduler.Tasks or {}
	self.Context._perfStats = stats
	self.Context._activeTasks = activeTasks
	
	-- Update graph history (if not paused)
	if not entity.IsGraphPaused then
		local frameTimeMs = frameStats.FrameTime * 1000
		table.insert(entity.GraphHistory, { Val = frameTimeMs, Count = frameStats.TaskCount })
		if #entity.GraphHistory > 60 then
			table.remove(entity.GraphHistory, 1)
		end
	end
	
	self:Log({ Level = "DEBUG", Message = string.format("Frame: %.2fms, Tasks: %d", frameStats.FrameTime * 1000, frameStats.TaskCount) })
end

--[[
	@description Hook for rendering performance UI.
	@param entity any
	@return ()
]]
function PerformancePageFSM:OnRenderUI(entity: any)
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	
	-- Render global stats
	self:RenderGlobalStats(entity)
	
	-- Render graph
	self:RenderGraph(entity)
	
	-- Render task list
	self:RenderTaskList(entity)
	
	-- Render selected task metadata
	if entity.SelectedTask then
		self:RenderTaskMetadata(entity)
	end
end

--[[
	@description Renders global frame statistics.
	@param entity any
	@return ()
]]
function PerformancePageFSM:RenderGlobalStats(entity: any)
	local statsLabels = entity.StatsLabels
	if not statsLabels then return end
	
	local frameStats = self.Context._frameStats or {}
	local frameTimeMs = (frameStats.FrameTime or 0) * 1000
	local budgetMs = (frameStats.Budget or 0) * 1000
	local usagePercent = budgetMs > 0 and (frameTimeMs / budgetMs * 100) or 0
	
	local function setLabel(name: string, text: string)
		local label = statsLabels:FindFirstChild(name)
		if not label then
			label = Instance.new("TextLabel", statsLabels)
			label.Name = name
			label.Size = UDim2.new(1, 0, 0, 20)
			label.BackgroundTransparency = 1
			label.TextColor3 = Color3.new(1, 1, 1)
			label.Font = Enum.Font.Code
			label.TextSize = 12
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.RichText = true
		end
		label.Text = text
	end
	
	setLabel("Rate", string.format("TASKS/FRAME: <font color='#A0FFA0'><b>%d</b></font>", frameStats.TaskCount or 0))
	setLabel("Time", string.format("FRAME TIME:  <font color='#%s'><b>%.2fms</b></font>", frameTimeMs > budgetMs and "FF7878" or "00C8FF", frameTimeMs))
	setLabel("Budget", string.format("BUDGET:      <font color='#CCCCCC'>%.2fms</font>", budgetMs))
	setLabel("Usage", string.format("USAGE:       <font color='#%s'><b>%.1f%%</b></font>", 
		usagePercent > 100 and "FF7878" or (usagePercent > 80 and "FFDC8C" or "A0FFA0"), usagePercent))
end

--[[
	@description Renders the performance graph.
	@param entity any
	@return ()
]]
function PerformancePageFSM:RenderGraph(entity: any)
	local graphContainer = entity.GraphContainer
	if not graphContainer then return end
	
	local colors = self.Context.COLORS or {}
	local frameStats = self.Context._frameStats or {}
	local budgetMs = (frameStats.Budget or 0) * 1000
	local history = entity.GraphHistory
	
	-- Calculate max values
	local maxVal = math.max(budgetMs * 1.2, 0.1)
	local maxCount = 1
	for _, sample in ipairs(history) do
		local val = type(sample) == "table" and sample.Val or sample
		local cnt = type(sample) == "table" and sample.Count or 0
		maxVal = math.max(maxVal, val)
		maxCount = math.max(maxCount, cnt)
	end
	
	-- Budget line
	local budgetLine = graphContainer:FindFirstChild("BudgetLine")
	if not budgetLine then
		budgetLine = Instance.new("Frame", graphContainer)
		budgetLine.Name = "BudgetLine"
		budgetLine.Size = UDim2.new(1, 0, 0, 1)
		budgetLine.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
		budgetLine.BorderSizePixel = 0
		budgetLine.ZIndex = 2
	end
	budgetLine.Visible = entity.GraphMode ~= "Heatmap"
	budgetLine.Position = UDim2.new(0, 0, 1 - (budgetMs / maxVal), 0)
	
	-- Heatmap frame
	local heatmap = graphContainer:FindFirstChild("Heatmap")
	if not heatmap then
		heatmap = Instance.new("Frame", graphContainer)
		heatmap.Name = "Heatmap"
		heatmap.Size = UDim2.new(1, 0, 1, 0)
		heatmap.BackgroundTransparency = 0
		heatmap.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		heatmap.BorderSizePixel = 0
		heatmap.ZIndex = 1
		Instance.new("UIGradient", heatmap)
	end
	
	-- Update gradient
	local gradient = heatmap:FindFirstChildOfClass("UIGradient")
	if gradient and #history > 0 then
		local points = {}
		local total = #history
		local maxPoints = 20
		local count = math.max(math.min(total, maxPoints), 2)
		
		for i = 1, count do
			local t = (count == 1) and 0 or (i - 1) / (count - 1)
			local sourceIndex = total <= 1 and 1 or math.clamp(math.floor((i - 1) * (total - 1) / (count - 1) + 1), 1, total)
			local entry = history[sourceIndex]
			local sampleValueMs = type(entry) == "table" and entry.Val or entry or 0
			local sampleTaskCount = type(entry) == "table" and entry.Count or 0
			
			local color
			if entity.GraphMode == "Heatmap" then
				local intensity = math.clamp(sampleTaskCount / maxCount, 0, 1)
				color = Color3.fromHSV((1 - intensity) * 0.6, 0.8, 1)
			else
				local intensity = math.clamp(sampleValueMs / maxVal, 0, 1)
				color = (sampleValueMs > budgetMs) and (colors.Error or Color3.fromRGB(255, 120, 120)) or Color3.fromHSV(0.55 - (intensity * 0.2), 0.8, 1)
			end
			
			table.insert(points, ColorSequenceKeypoint.new(t, color))
		end
		
		if #points >= 2 then
			gradient.Color = ColorSequence.new(points)
		end
	end
end

--[[
	@description Renders the task list with performance metrics.
	@param entity any
	@return ()
]]
function PerformancePageFSM:RenderTaskList(entity: any)
	local taskList = entity.TaskList
	if not taskList then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local stats = self.Context._perfStats or {}
	local activeTasks = self.Context._activeTasks or {}
	local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
	local pm = scheduler and scheduler.PerformanceManager
	
	-- Build combined task list
	local keys = {}
	for k in pairs(stats) do keys[k] = true end
	for k in pairs(activeTasks) do keys[k] = true end
	
	-- Filter and sort
	local sorted = {}
	local searchText = (entity.Search or ""):lower()
	
	for k in pairs(keys) do
		local isActive = activeTasks[k] ~= nil
		
		-- Search filter
		if searchText ~= "" and not tostring(k):lower():find(searchText, 1, true) then
			continue
		end
		
		-- Active/Inactive filter
		if isActive and not entity.Filters.Active then continue end
		if not isActive and not entity.Filters.Inactive then continue end
		
		table.insert(sorted, k)
	end
	
	-- Sort
	table.sort(sorted, function(a, b)
		if not pm then return a < b end
		
		if entity.SortMode == "Avg" then
			return pm:GetTaskAverage(a) > pm:GetTaskAverage(b)
		elseif entity.SortMode == "Max" then
			return pm:GetTaskMaximum(a) > pm:GetTaskMaximum(b)
		elseif entity.SortMode == "Count" then
			local sA = stats[a] and stats[a].RunCount or 0
			local sB = stats[b] and stats[b].RunCount or 0
			return sA > sB
		else
			return a < b
		end
	end)
	
	-- Pagination
	local pageSize = entity.PageSize or 10
	local maxPage = math.max(1, math.ceil(#sorted / pageSize))
	if entity.Page > maxPage then entity.Page = maxPage end
	
	local startIndex = (entity.Page - 1) * pageSize + 1
	local endIndex = startIndex + pageSize - 1
	
	-- Clear old cards
	for _, child in ipairs(taskList:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	
	-- Render cards
	for i = startIndex, endIndex do
		local taskName = sorted[i]
		if not taskName then break end
		
		local isActive = activeTasks[taskName] ~= nil
		
		local card = Instance.new("TextButton")
		card.Name = taskName
		card.Size = UDim2.new(1, -10, 0, 40)
		card.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
		card.Text = taskName
		card.TextColor3 = Color3.new(1, 1, 1)
		card.Font = Enum.Font.Gotham
		card.TextSize = 11
		card.TextXAlignment = Enum.TextXAlignment.Left
		card.TextTruncate = Enum.TextTruncate.AtEnd
		card.Parent = taskList
		
		Instance.new("UICorner", card).CornerRadius = UDim.new(0, 4)
		local padding = Instance.new("UIPadding", card)
		padding.PaddingLeft = UDim.new(0, 10)
		padding.PaddingRight = UDim.new(0, 30)
		
		-- Status dot
		local statusDot = Instance.new("Frame", card)
		statusDot.Name = "StatusDot"
		statusDot.Size = UDim2.new(0, 8, 0, 8)
		statusDot.Position = UDim2.new(1, -15, 0.5, -4)
		statusDot.BackgroundColor3 = isActive and (colors.Success or Color3.fromRGB(160, 255, 160)) or (colors.Error or Color3.fromRGB(255, 120, 120))
		Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)
		
		-- Click handler
		entity:Manage(card.MouseButton1Click:Connect(function()
			entity:SelectTask(taskName)
			entity:UpdateEntity()
			self:RenderTaskMetadata(entity)
		end))
	end
	
	self:Log({ Level = "DEBUG", Message = string.format("Rendered %d performance task cards", math.min(#sorted, pageSize)) })
end

--[[
	@description Renders task metadata with metrics.
	@param entity any
	@return ()
]]
function PerformancePageFSM:RenderTaskMetadata(entity: any)
	local metadataPanel = entity.MetadataPanel
	if not metadataPanel then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
	local pm = scheduler and scheduler.PerformanceManager
	
	-- Clear panel
	for _, child in ipairs(metadataPanel:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	
	if not entity.SelectedTask or not pm then return end
	
	-- Calculate global max for bar scaling
	local globalMaxAvg, globalMaxMax = 0, 0
	for name in pairs(pm.Stats or {}) do
		local avg = pm:GetTaskAverage(name)
		local max = pm:GetTaskMaximum(name)
		if avg > globalMaxAvg then globalMaxAvg = avg end
		if max > globalMaxMax then globalMaxMax = max end
	end
	if globalMaxAvg == 0 then globalMaxAvg = 1 end
	if globalMaxMax == 0 then globalMaxMax = 1 end
	
	-- Format time helper
	local function formatTime(t)
		return t < 0.001 and (math.floor(t * 1e6) .. "ns") or t < 1 and (math.floor(t * 1e3) .. "ms") or (math.floor(t) .. "s")
	end
	
	-- Metrics to display
	local metrics = {
		{ key = "Average", val = pm:GetTaskAverage(entity.SelectedTask), max = globalMaxAvg, format = true },
		{ key = "Max", val = pm:GetTaskMaximum(entity.SelectedTask), max = globalMaxMax, format = true },
		{ key = "Delayed", val = pm:GetDelayedExecutionCount(entity.SelectedTask), max = 0, format = false },
	}
	
	for i, metric in ipairs(metrics) do
		local row = Instance.new("Frame")
		row.Name = metric.key
		row.Size = UDim2.new(1, -10, 0, 40)
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		row.Parent = metadataPanel
		
		local title = Instance.new("TextLabel", row)
		title.Name = "Title"
		title.Size = UDim2.new(0.4, 0, 0, 20)
		title.BackgroundTransparency = 1
		title.Text = string.upper(metric.key)
		title.TextColor3 = Color3.fromRGB(150, 150, 150)
		title.Font = Enum.Font.GothamBold
		title.TextSize = 10
		title.TextXAlignment = Enum.TextXAlignment.Left
		
		local valueText = metric.format and formatTime(metric.val) or tostring(metric.val)
		local value = Instance.new("TextLabel", row)
		value.Name = "Value"
		value.Size = UDim2.new(0.6, 0, 0, 20)
		value.Position = UDim2.new(0.4, 0, 0, 0)
		value.BackgroundTransparency = 1
		value.Text = string.format("<b>%s</b>", valueText)
		value.TextColor3 = Color3.new(1, 1, 1)
		value.Font = Enum.Font.Gotham
		value.TextSize = 10
		value.TextXAlignment = Enum.TextXAlignment.Left
		value.RichText = true
		
		-- Progress bar for metrics with max
		if metric.max > 0 then
			local barBg = Instance.new("Frame", row)
			barBg.Name = "Bar"
			barBg.Size = UDim2.new(1, 0, 0, 4)
			barBg.Position = UDim2.new(0, 0, 0, 24)
			barBg.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
			Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)
			
			local pct = math.clamp(metric.val / metric.max, 0, 1)
			local fill = Instance.new("Frame", barBg)
			fill.Name = "Fill"
			fill.Size = UDim2.new(pct, 0, 1, 0)
			fill.BackgroundColor3 = pct > 0.8 and (colors.Error or Color3.fromRGB(255, 120, 120)) or (pct > 0.5 and (colors.Warning or Color3.fromRGB(255, 200, 100)) or (colors.Accent or Color3.fromRGB(0, 200, 255)))
			Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
		end
	end
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function PerformancePageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function PerformancePageFSM:OnCleanup()
	self.Context._frameStats = nil
	self.Context._perfStats = nil
	self.Context._activeTasks = nil
	BasePageFSM.OnCleanup(self)
end

return PerformancePageFSM
