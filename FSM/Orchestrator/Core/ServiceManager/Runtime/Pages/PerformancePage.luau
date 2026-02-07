--!strict
--[[
	@Name PerformancePage
	@Author iKrypto
	@Description Performance page controller. Displays global frame-time stats,
	a real-time graph (standard bars or heatmap), per-task list with sort/filter/
	search/pagination, and task-specific average/max/delayed metrics with bar
	indicators.
	
	@deprecated This legacy controller is retained for regression testing only.
	Use the new FSM/Entity pattern: FSM/PerformancePageFSM.luau + Entity/PerformancePageEntity.luau
]]

export type Deps = {
	EnsureToolbar: (Instance) -> Instance,
	CreateSearchBox: (Instance, string?, (string) -> ()) -> Instance,
	CreateButton: (Instance, string, Color3, (() -> ())?, number?) -> Instance,
	EnsurePagination: (Instance, any, (() -> ())) -> Instance?,
	COLORS: { [string]: Color3 },
	TaskCardReference: Instance,
	TaskDataReference: Instance,
}

type Constants = {
	SelectedTask: string?,
	SortMode: string,
	GraphHistory: { any },
	IsGraphPaused: boolean,
	GraphMode: string,
	Page: number,
	PageSize: number,
	Search: string,
	Filters: { [string]: boolean },
}

local PerformancePage = {}

--[[
	@description Factory that creates the Performance page with frame-time graph,
	global stats, per-task list, and task detail panel.
	@param ServiceManager any -- The root ServiceManager instance.
	@param deps Deps -- Injected dependencies.
	@return any -- A page table.
]]
function PerformancePage.Create(ServiceManager: any, deps: Deps)
	local page: any = {
		Container = ServiceManager.GUI.BodyContainer:WaitForChild("PerformanceView"):WaitForChild("Container"),
		Tab = ServiceManager.GUI.TabContainer:WaitForChild("Performance"),
		Constants = ({
			SelectedTask = (nil :: string?),
			SortMode = "Name",
			GraphHistory = {},
			IsGraphPaused = false,
			GraphMode = "Standard",
			Page = 1,
			PageSize = 10,
			Search = "",
			Filters = { Active = true, Inactive = true },
		} :: Constants),
		Connections = {},
		StableConnections = {},
		DynamicConnections = {},
	}

	page.UpdateFunction = function(this)
		if not this.Container then return end
		local constants = this.Constants :: Constants
		local View = this.Container.Parent

		if View and not View:FindFirstChild("Toolbar") then
			-- Toolbar destroyed on tab switch; clear stable conns to avoid leaking old disconnected ones.
			ServiceManager:ClearConnections(this.StableConnections)
			this.StableConnections = {}
			this.Connections = {}

			local Toolbar = deps.EnsureToolbar(View)
			deps.CreateSearchBox(Toolbar, this.Constants.Search, function(text)
				this.Constants.Search = text
				this.Constants.Page = 1
				this.UpdateFunction(this)
			end)

			--[[
				@description Creates a named filter toggle button (Active/Inactive) on the toolbar.
				@param Name string -- Filter category label.
				@param Color Color3 -- Button accent color.
				@return ()
			]]
			local function createFilter(Name: string, Color: Color3)
				local Btn = deps.CreateButton(Toolbar, Name, Color, nil, 60)
				local btnAny = Btn :: any
				btnAny.BackgroundTransparency = constants.Filters[Name] and 0 or 0.7
				local conn = btnAny.MouseButton1Click:Connect(function()
					constants.Filters[Name] = not constants.Filters[Name]
					btnAny.BackgroundTransparency = constants.Filters[Name] and 0 or 0.7
					constants.Page = 1
					this.UpdateFunction(this)
				end)
				table.insert(this.StableConnections, conn)
				table.insert(this.Connections, conn)
			end
			createFilter("Active", deps.COLORS.Success)
			createFilter("Inactive", deps.COLORS.Error)

			local SortBtn = deps.CreateButton(Toolbar, "SORT: NAME", deps.COLORS.DarkBG, nil, 80)
			local sortBtnAny = SortBtn :: any
			local sortConn = sortBtnAny.MouseButton1Click:Connect(function()
				local modes = {"Name", "Avg", "Max", "Count"}
				local currentIdx = table.find(modes, constants.SortMode) or 1
				constants.SortMode = modes[(currentIdx % #modes) + 1]
				sortBtnAny.Text = "SORT: " .. constants.SortMode:upper()
				this.UpdateFunction(this)
			end)
			table.insert(this.StableConnections, sortConn)
			table.insert(this.Connections, sortConn)

			local GlobalStats = View:FindFirstChild("GlobalStats")
			if GlobalStats then
				local globalStatsAny = GlobalStats :: any
				globalStatsAny.Position = UDim2.new(0, 0, 0, 40)
				local containerAny = this.Container :: any
				containerAny.Size = UDim2.new(1, 0, 1, -190)
				containerAny.Position = UDim2.new(0, 0, 0, 150)
			end
		end

		local GlobalStats = View and View:FindFirstChild("GlobalStats")
		if GlobalStats then
			local scheduler = ServiceManager.Services.Scheduler
			local frameStats = scheduler and (scheduler :: any).LastFrameStats or { FrameTime = 0, TaskCount = 0, Budget = 0 }
			local labelsContainer = (GlobalStats :: any).StatsLabels
			local graphContainer = (GlobalStats :: any).GraphContainer

			--[[
				@description Creates or updates a named stat label in the GlobalStats panel.
				@param labelName string -- Unique label identifier.
				@param labelText string -- Rich-text content.
				@param labelColor Color3? -- Optional override text color.
				@return ()
			]]
			local function setLabel(labelName: string, labelText: string, labelColor: Color3?)
				local label = labelsContainer:FindFirstChild(labelName) or Instance.new("TextLabel", labelsContainer)
				label.Name = labelName
				label.Size = UDim2.new(1, 0, 0, 20)
				label.BackgroundTransparency = 1
				label.TextColor3 = labelColor or Color3.new(1, 1, 1)
				label.Font = Enum.Font.Code
				label.TextSize = 12
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.RichText = true
				label.Text = labelText
			end

			local FrameTimeMs = (frameStats :: any).FrameTime * 1000
			local BudgetMs = (frameStats :: any).Budget * 1000
			local UsagePercent = (BudgetMs > 0) and (FrameTimeMs / BudgetMs * 100) or 0

			setLabel("Rate", string.format("TASKS/FRAME: <font color='#A0FFA0'><b>%d</b></font>", (frameStats :: any).TaskCount))
			setLabel("Time", string.format("FRAME TIME:  <font color='#%s'><b>%.2fms</b></font>", FrameTimeMs > BudgetMs and "FF7878" or "00C8FF", FrameTimeMs))
			setLabel("Budget", string.format("BUDGET:      <font color='#CCCCCC'>%.2fms</font>", BudgetMs))
			setLabel("Usage", string.format("USAGE:       <font color='#%s'><b>%.1f%%</b></font>", UsagePercent > 100 and "FF7878" or (UsagePercent > 80 and "FFDC8C" or "A0FFA0"), UsagePercent))

			if not (GlobalStats :: any):FindFirstChild("PauseBtn") then
				local PauseBtn = Instance.new("TextButton", GlobalStats)
				PauseBtn.Name = "PauseBtn"
				PauseBtn.Size = UDim2.new(0, 60, 0, 20)
				PauseBtn.Position = UDim2.new(1, -65, 0, 5)
				PauseBtn.BackgroundColor3 = deps.COLORS.DarkBG
				PauseBtn.TextColor3 = Color3.new(1, 1, 1)
				PauseBtn.Font = Enum.Font.GothamBold
				PauseBtn.TextSize = 10
				PauseBtn.Text = "PAUSE"
				Instance.new("UICorner", PauseBtn).CornerRadius = UDim.new(0, 4)

				local pauseConn = PauseBtn.MouseButton1Click:Connect(function()
					this.Constants.IsGraphPaused = not this.Constants.IsGraphPaused
					PauseBtn.Text = this.Constants.IsGraphPaused and "RESUME" or "PAUSE"
					PauseBtn.BackgroundColor3 = this.Constants.IsGraphPaused and deps.COLORS.Warning or deps.COLORS.DarkBG
				end)
				table.insert(this.StableConnections, pauseConn)
				table.insert(this.Connections, pauseConn)
			end

			if not (GlobalStats :: any):FindFirstChild("ModeBtn") then
				local ModeBtn = Instance.new("TextButton", GlobalStats)
				ModeBtn.Name = "ModeBtn"
				ModeBtn.Size = UDim2.new(0, 90, 0, 20)
				ModeBtn.Position = UDim2.new(1, -160, 0, 5)
				ModeBtn.BackgroundColor3 = deps.COLORS.DarkBG
				ModeBtn.TextColor3 = Color3.new(1, 1, 1)
				ModeBtn.Font = Enum.Font.GothamBold
				ModeBtn.TextSize = 10
				ModeBtn.Text = "VIEW: STANDARD"
				Instance.new("UICorner", ModeBtn).CornerRadius = UDim.new(0, 4)

				local modeConn = ModeBtn.MouseButton1Click:Connect(function()
					this.Constants.GraphMode = (this.Constants.GraphMode == "Standard") and "Heatmap" or "Standard"
					ModeBtn.Text = "VIEW: " .. this.Constants.GraphMode:upper()
				end)
				table.insert(this.StableConnections, modeConn)
				table.insert(this.Connections, modeConn)
			end

			local Tooltip = (GlobalStats :: any):FindFirstChild("Tooltip")
			if not Tooltip then
				Tooltip = Instance.new("Frame", GlobalStats)
				Tooltip.Name = "Tooltip"
				Tooltip.Visible = false
				Tooltip.Size = UDim2.new(0, 110, 0, 35)
				Tooltip.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
				Tooltip.ZIndex = 10
				Instance.new("UICorner", Tooltip).CornerRadius = UDim.new(0, 4)
				Instance.new("UIStroke", Tooltip).Color = Color3.fromRGB(80, 80, 80)
				local label = Instance.new("TextLabel", Tooltip)
				label.Name = "Label"
				label.Size = UDim2.new(1, -10, 1, 0)
				label.Position = UDim2.new(0, 5, 0, 0)
				label.BackgroundTransparency = 1
				label.TextColor3 = Color3.new(1, 1, 1)
				label.Font = Enum.Font.Code
				label.TextSize = 10
				label.RichText = true
				label.TextXAlignment = Enum.TextXAlignment.Left
			end

			if not this.Constants.IsGraphPaused then
				table.insert(this.Constants.GraphHistory, { Val = FrameTimeMs, Count = (frameStats :: any).TaskCount })
				if #this.Constants.GraphHistory > 60 then table.remove(this.Constants.GraphHistory, 1) end
			end

			local MaxVal = math.max(BudgetMs * 1.2, 0.1)
			for _, sample in ipairs(this.Constants.GraphHistory) do
				MaxVal = math.max(MaxVal, type(sample) == "table" and (sample :: any).Val or (sample :: any))
			end
			local MaxCount = 1
			for _, sample in ipairs(this.Constants.GraphHistory) do
				local val = type(sample) == "table" and (sample :: any).Val or (sample :: any)
				local cnt = type(sample) == "table" and (sample :: any).Count or 0
				MaxVal = math.max(MaxVal, val)
				MaxCount = math.max(MaxCount, cnt)
			end

			local BudgetLine = graphContainer:FindFirstChild("BudgetLine") or Instance.new("Frame", graphContainer)
			BudgetLine.Name = "BudgetLine"
			BudgetLine.Size = UDim2.new(1, 0, 0, 1)
			BudgetLine.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
			BudgetLine.BorderSizePixel = 0
			BudgetLine.Position = UDim2.new(0, 0, 1 - (BudgetMs / MaxVal), 0)

			if this.Constants.GraphMode == "Heatmap" then
				BudgetLine.Visible = false
			else
				BudgetLine.Visible = true
				BudgetLine.Position = UDim2.new(0, 0, 1 - (BudgetMs / MaxVal), 0)
			end
			BudgetLine.ZIndex = 2

			for _, child in ipairs(graphContainer:GetChildren()) do
				if child.Name:match("^Bar") then
					child:Destroy()
				end
			end
			local Heatmap = graphContainer:FindFirstChild("Heatmap")
			if not Heatmap then
				Heatmap = Instance.new("Frame", graphContainer)
				Heatmap.Name = "Heatmap"
				Heatmap.Size = UDim2.new(1, 0, 1, 0)
				Heatmap.BackgroundTransparency = 0
				Heatmap.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
				Heatmap.BorderSizePixel = 0
				Heatmap.ZIndex = 1
				local gradient = Instance.new("UIGradient", Heatmap)
				gradient.Rotation = 0
			end
			local Gradient = Heatmap:FindFirstChildOfClass("UIGradient")
			if Gradient then
				local points: { any } = {}
				local history = this.Constants.GraphHistory
				local total = #history
				local maxPoints = 20
				local count = math.max(math.min(total, maxPoints), 2)
				for i = 1, count do
					local t = (count == 1) and 0 or (i - 1) / (count - 1)
					local sourceIndex
					if total <= 1 then
						sourceIndex = 1
					else
						sourceIndex = math.clamp(math.floor((i - 1) * (total - 1) / (count - 1) + 1), 1, total)
					end
					local entry = history[sourceIndex]
					local sampleValueMs = type(entry) == "table" and (entry :: any).Val or (entry :: any) or 0
					local sampleTaskCount = type(entry) == "table" and (entry :: any).Count or 0
					local color
					if this.Constants.GraphMode == "Heatmap" then
						local intensity = math.clamp(sampleTaskCount / MaxCount, 0, 1)
						color = Color3.fromHSV((1 - intensity) * 0.6, 0.8, 1)
					else
						local intensity = math.clamp(sampleValueMs / MaxVal, 0, 1)
						color = (sampleValueMs > BudgetMs) and deps.COLORS.Error or Color3.fromHSV(0.55 - (intensity * 0.2), 0.8, 1)
					end
					points[#points + 1] = ColorSequenceKeypoint.new(t, color)
				end
				Gradient.Color = ColorSequence.new(points)
			end

			if not graphContainer:FindFirstChild("Hover") then
				-- Frames won't receive mouse input unless Active is true.
				(graphContainer :: any).Active = true
				(graphContainer :: any).Selectable = false

				local HoverMarker = Instance.new("BoolValue", graphContainer)
				HoverMarker.Name = "Hover"
				table.insert(this.Connections, graphContainer.InputChanged:Connect(function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.MouseMovement then
						if #this.Constants.GraphHistory <= 0 then
							(Tooltip :: any).Visible = false
							return
						end
						local relX = input.Position.X - graphContainer.AbsolutePosition.X
						local idx = math.clamp(math.floor((relX / math.max(1, graphContainer.AbsoluteSize.X)) * (#this.Constants.GraphHistory - 1)) + 1, 1, #this.Constants.GraphHistory)
						local entry = this.Constants.GraphHistory[idx]
						if entry then
							local sampleValueMs = type(entry) == "table" and (entry :: any).Val or (entry :: any)
							local sampleTaskCount = type(entry) == "table" and (entry :: any).Count or 0
							(Tooltip :: any).Visible = true
							((Tooltip :: any).Label :: any).Text = string.format("Time: <font color='#A0FFA0'>%.2fms</font>\nTasks: <font color='#00C8FF'>%d</font>", sampleValueMs, sampleTaskCount)
							local maxX = math.max(0, graphContainer.AbsoluteSize.X - (Tooltip :: any).AbsoluteSize.X)
							local maxY = math.max(0, graphContainer.AbsoluteSize.Y - (Tooltip :: any).AbsoluteSize.Y)
							local posX = math.clamp(relX + 10, 0, maxX)
							local posY = math.clamp(10, 0, maxY)
							;(Tooltip :: any).Position = UDim2.new(0, posX, 0, posY)
						end
					end
				end))
				table.insert(this.Connections, (graphContainer :: any).MouseLeave:Connect(function()
					(Tooltip :: any).Visible = false
				end))
			end
		end

		local Controls = deps.EnsurePagination(View, this.Constants, function() this.UpdateFunction(this) end)

		--[[
			@description Destroys all Frame/TextLabel children from the TaskMetadata panel.
			@return ()
		]]
		local function clearTaskMetadataPanel()
			for _, TaskData in next, (this.Container :: any).TaskMetadata:GetChildren() do
				if TaskData:IsA("Frame") or TaskData:IsA("TextLabel") then TaskData:Destroy() end
			end
		end

		--[[
			@description Attaches click handler to a performance task card for selection.
			@param TaskCard Instance -- The card Instance.
			@param TaskName string -- The task name key.
			@return ()
		]]
		local function hookTaskCard(TaskCard: Instance, TaskName: string)
			if (TaskCard :: any):FindFirstChild("IsHooked") then return end
			local HookMarker = Instance.new("BoolValue", TaskCard)
			HookMarker.Name = "IsHooked"
			local Connection = (TaskCard :: any).MouseButton1Click:Connect(function()
				constants.SelectedTask = nil
				clearTaskMetadataPanel()
				constants.SelectedTask = TaskName
				this.UpdateFunction(this)
			end)
			table.insert(this.Connections, Connection)
		end

		--[[
			@description Rebuilds the performance task list: merges Stats and active Tasks,
			applies search/filter/sort/pagination, creates or updates task cards.
			@return ()
		]]
		local function updateTaskList()
			local scheduler = ServiceManager.Services.Scheduler
			if not scheduler then return end
			local Stats = (scheduler :: any).PerformanceManager and (scheduler :: any).PerformanceManager.Stats or {}
			local ActiveTasks = (scheduler :: any).Tasks or {}

			local function CreateTaskCard(TaskName: string)
				local TaskCard = deps.TaskCardReference:Clone()
				;(TaskCard :: any):FindFirstChildWhichIsA("TextLabel").Text = TaskName
				;(TaskCard :: any).Name = TaskName
				;(TaskCard :: any).Parent = (this.Container :: any).TaskList
				;(TaskCard :: any).Visible = true

				local StatusDot = Instance.new("Frame", TaskCard)
				StatusDot.Name = "StatusDot"
				StatusDot.Size = UDim2.new(0, 8, 0, 8)
				StatusDot.Position = UDim2.new(1, -15, 0.5, -4)
				StatusDot.BackgroundColor3 = deps.COLORS.Success
				Instance.new("UICorner", StatusDot).CornerRadius = UDim.new(1, 0)
				return TaskCard
			end

			local Sorted: { string } = {}
			local keys: { [string]: boolean } = {}
			for k in pairs(Stats) do keys[k] = true end
			for k in pairs(ActiveTasks) do keys[k] = true end
			for k in pairs(keys) do
				local IsActive = ActiveTasks[k] ~= nil
				if this.Constants.Search ~= "" and not tostring(k):lower():find(tostring(this.Constants.Search):lower(), 1, true) then continue end
				if IsActive and not this.Constants.Filters.Active then continue end
				if (not IsActive) and not this.Constants.Filters.Inactive then continue end
				table.insert(Sorted, k)
			end

			local PM = (scheduler :: any).PerformanceManager
			table.sort(Sorted, function(a, b)
				if this.Constants.SortMode == "Avg" then
					return (PM :: any):GetTaskAverage(a) > (PM :: any):GetTaskAverage(b)
				elseif this.Constants.SortMode == "Max" then
					return (PM :: any):GetTaskMaximum(a) > (PM :: any):GetTaskMaximum(b)
				elseif this.Constants.SortMode == "Count" then
					local sA = Stats[a] and (Stats[a] :: any).RunCount or 0
					local sB = Stats[b] and (Stats[b] :: any).RunCount or 0
					return sA > sB
				else
					return a < b
				end
			end)

			local PageSize = this.Constants.PageSize or 10
			local MaxPage = math.ceil(#Sorted / PageSize)
			if MaxPage == 0 then MaxPage = 1 end
			if this.Constants.Page > MaxPage then this.Constants.Page = MaxPage end
			if Controls then
				(Controls :: any).PageLabel.Text = string.format("%d / %d", this.Constants.Page, MaxPage)
			end

			local StartIndex = (this.Constants.Page - 1) * PageSize + 1
			local EndIndex = StartIndex + PageSize - 1
			local VisibleTasks: { [string]: boolean } = {}

			for i = StartIndex, EndIndex do
				if Sorted[i] then VisibleTasks[Sorted[i]] = true end
			end

			for _, child in next, (this.Container :: any).TaskList:GetChildren() do
				if child:IsA("TextButton") and not VisibleTasks[child.Name] then child:Destroy() end
			end

			for i = StartIndex, EndIndex do
				local TaskName = Sorted[i]
				if not TaskName then break end
				local card = (this.Container :: any).TaskList:FindFirstChild(TaskName)
				if not card then
					card = CreateTaskCard(TaskName)
				end

				local IsActive = ActiveTasks[TaskName] ~= nil
				if (card :: any):FindFirstChild("StatusDot") then
					((card :: any).StatusDot :: any).BackgroundColor3 = IsActive and deps.COLORS.Success or deps.COLORS.Error
				end

				hookTaskCard(card, TaskName)
			end
		end

		--[[
			@description Populates the TaskMetadata panel with Average, Max, and Delayed
			metrics for the selected task, including proportional bar indicators.
			@return ()
		]]
		local function updateSelectedTaskMetadata()
			local scheduler = ServiceManager.Services.Scheduler
			if not constants.SelectedTask or not scheduler then return end
			local Selected = constants.SelectedTask
			local PM = (scheduler :: any).PerformanceManager
			if not PM or not (PM :: any).Tasks then return end

			local GlobalMaxAvg, GlobalMaxMax = 0, 0
			for name, _ in pairs((PM :: any).Stats or {}) do
				local avg = (PM :: any):GetTaskAverage(name)
				local max = (PM :: any):GetTaskMaximum(name)
				if avg > GlobalMaxAvg then GlobalMaxAvg = avg end
				if max > GlobalMaxMax then GlobalMaxMax = max end
			end
			if GlobalMaxAvg == 0 then GlobalMaxAvg = 1 end
			if GlobalMaxMax == 0 then GlobalMaxMax = 1 end

			--[[
				@description Formats a time value (seconds) into human-readable ns/ms/s.
				@param t number -- Time in seconds.
				@return string
			]]
			local function formatTime(t)
				return t < 0.001 and (math.floor(t * 1e6) .. "ns") or t < 1 and (math.floor(t * 1e3) .. "ms") or (math.floor(t) .. "s")
			end
			local DataKeys = {"Average", "Max", "Delayed"}
			local Data: any = {
				Average = { Val = (PM :: any):GetTaskAverage(Selected), Max = GlobalMaxAvg, Format = true },
				Max = { Val = (PM :: any):GetTaskMaximum(Selected), Max = GlobalMaxMax, Format = true },
				Delayed = { Val = (PM :: any):GetDelayedExecutionCount(Selected), Max = 0, Format = false },
			}

			local Container = (this.Container :: any).TaskMetadata
			for i, keyName in ipairs(DataKeys) do
				local metric = Data[keyName]
				local DataObject = Container:FindFirstChild(keyName) or deps.TaskDataReference:Clone()
				DataObject.Name = keyName
				DataObject.Parent = Container
				;(DataObject :: any).Visible = true
				;(DataObject :: any).LayoutOrder = i

				if (DataObject :: any):FindFirstChild("Title") then
					((DataObject :: any).Title :: any).Text = string.upper(keyName)
				end
				if (DataObject :: any):FindFirstChild("Value") then
					local val = metric.Val
					local text = metric.Format and formatTime(val) or tostring(val)
					;((DataObject :: any).Value :: any).Text = string.format("<b>%s</b>", text)

					if metric.Max > 0 then
						local Bar = (DataObject :: any):FindFirstChild("Bar")
						if not Bar then
							Bar = Instance.new("Frame", DataObject)
							Bar.Name = "Bar"
							;(Bar :: any).LayoutOrder = 3
							;(Bar :: any).Size = UDim2.new(1, 0, 0, 4)
							;(Bar :: any).BackgroundColor3 = Color3.fromRGB(60, 60, 60)
							Instance.new("UICorner", Bar).CornerRadius = UDim.new(1, 0)
							local Fill = Instance.new("Frame", Bar)
							Fill.Name = "Fill"
							Fill.BackgroundColor3 = deps.COLORS.Accent
							Instance.new("UICorner", Fill).CornerRadius = UDim.new(1, 0)
						end
						local pct = math.clamp(val / metric.Max, 0, 1)
						;((Bar :: any).Fill :: any).Size = UDim2.new(pct, 0, 1, 0)
						;((Bar :: any).Fill :: any).BackgroundColor3 = pct > 0.8 and deps.COLORS.Error or (pct > 0.5 and deps.COLORS.Warning or deps.COLORS.Accent)
					end
				end
			end

			for _, child in next, Container:GetChildren() do
				if child:IsA("Frame") and not Data[child.Name] then child:Destroy() end
			end
		end

		updateTaskList()
		updateSelectedTaskMetadata()
	end

	return page
end

return PerformancePage
