--!strict
-- @Name TaskListPageFSM
-- @Author iKrypto
-- @Description TaskList Page FSM managing task display, selection, and actions.
-- Migrated from legacy TaskListPage.luau controller pattern.

local BasePageFSM = require(script.Parent.BasePageFSM)

local TaskListPageFSM = BasePageFSM.Extend({
	className = "TaskListPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ShowingDetails", "ExecutingAction", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 5
})

--[[
	@description Registers states for the task list page FSM.
	@return ()
]]
function TaskListPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("ShowingDetails", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity
			fsm:Log({ Level = "DEBUG", Message = string.format("Showing task details: %s", tostring(entity.SelectedTask)) })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
	
	self:AddState("ExecutingAction", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Executing task action..." })
			fsm:ChangeState({ Name = "Rendering" })
		end
	})
end

--[[
	@description Helper to create a section frame.
	@return Frame
]]
local function createSection(name: string, titleText: string, color: Color3, parent: Instance): Frame
	local section = Instance.new("Frame")
	section.Name = name
	section.Size = UDim2.new(1, 0, 0.5, -5)
	section.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	section.Parent = parent
	
	Instance.new("UICorner", section).CornerRadius = UDim.new(0, 6)
	
	local title = Instance.new("TextLabel", section)
	title.Name = "Title"
	title.Size = UDim2.new(1, -20, 0, 30)
	title.Position = UDim2.new(0, 10, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = titleText
	title.Font = Enum.Font.GothamBold
	title.TextSize = 12
	title.TextColor3 = color
	title.TextXAlignment = Enum.TextXAlignment.Left
	
	local list = Instance.new("ScrollingFrame", section)
	list.Name = "List"
	list.Size = UDim2.new(1, 0, 1, -35)
	list.Position = UDim2.new(0, 0, 0, 35)
	list.BackgroundTransparency = 1
	list.ScrollBarThickness = 2
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	
	local layout = Instance.new("UIListLayout", list)
	layout.Padding = UDim.new(0, 5)
	
	local padding = Instance.new("UIPadding", list)
	padding.PaddingLeft = UDim.new(0, 5)
	
	return section
end

--[[
	@description Hook for initializing task list UI elements.
	@param entity any
	@return ()
]]
function TaskListPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing TaskList Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "TaskList container not found" })
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
					entity:UpdateEntity()
					self:RequestRender()
				end
			end)
		end))
	end
	
	-- Show Ended button
	local showBtn = toolbar:FindFirstChild("ShowEndedBtn")
	if not showBtn then
		showBtn = Instance.new("TextButton")
		showBtn.Name = "ShowEndedBtn"
		showBtn.Size = UDim2.new(0, 90, 1, 0)
		showBtn.Text = "SHOW ENDED"
		showBtn.TextColor3 = Color3.new(1, 1, 1)
		showBtn.BackgroundColor3 = entity.ShowArchived and (colors.Accent or Color3.fromRGB(0, 200, 255)) or (colors.DarkBG or Color3.fromRGB(40, 40, 40))
		showBtn.Font = Enum.Font.GothamBold
		showBtn.TextSize = 10
		showBtn.BorderSizePixel = 0
		showBtn.Parent = toolbar
		
		Instance.new("UICorner", showBtn).CornerRadius = UDim.new(0, 4)
		
		entity:Manage(showBtn.MouseButton1Click:Connect(function()
			entity:ToggleShowArchived()
			showBtn.BackgroundColor3 = entity.ShowArchived and (colors.Accent or Color3.fromRGB(0, 200, 255)) or (colors.DarkBG or Color3.fromRGB(40, 40, 40))
			entity:UpdateEntity()
			self:RequestRender()
		end))
	end
	
	-- Clear Ended button
	local clearBtn = toolbar:FindFirstChild("ClearEndedBtn")
	if not clearBtn then
		clearBtn = Instance.new("TextButton")
		clearBtn.Name = "ClearEndedBtn"
		clearBtn.Size = UDim2.new(0, 90, 1, 0)
		clearBtn.Text = "CLEAR ENDED"
		clearBtn.TextColor3 = Color3.new(1, 1, 1)
		clearBtn.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
		clearBtn.Font = Enum.Font.GothamBold
		clearBtn.TextSize = 10
		clearBtn.BorderSizePixel = 0
		clearBtn.Parent = toolbar
		
		Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 4)
		
		entity:Manage(clearBtn.MouseButton1Click:Connect(function()
			serviceManager.ArchivedTasks = {}
			entity.SelectedTask = nil
			entity:UpdateEntity()
			self:RequestRender()
			if serviceManager.Toast then
				serviceManager:Toast("Cleared Ended Tasks", "Success")
			end
		end))
	end
	
	-- Sort button
	local sortBtn = toolbar:FindFirstChild("SortBtn")
	if not sortBtn then
		sortBtn = Instance.new("TextButton")
		sortBtn.Name = "SortBtn"
		sortBtn.Size = UDim2.new(0, 90, 1, 0)
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
	
	-- Container sizing
	local containerAny = container :: any
	containerAny.Size = UDim2.new(1, 0, 1, -40)
	containerAny.Position = UDim2.new(0, 0, 0, 40)
	
	-- TaskList frame
	local taskList = container:FindFirstChild("TaskList")
	if not taskList then
		taskList = Instance.new("Frame")
		taskList.Name = "TaskList"
		taskList.Size = UDim2.new(0.65, -5, 1, 0)
		taskList.BackgroundTransparency = 1
		taskList.Parent = container
	end
	entity.TaskList = taskList
	
	-- Metadata panel
	local metadataPanel = container:FindFirstChild("TaskMetadata")
	if not metadataPanel then
		metadataPanel = Instance.new("ScrollingFrame")
		metadataPanel.Name = "TaskMetadata"
		metadataPanel.Size = UDim2.new(0.35, 0, 1, -50)
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
	
	-- Create sections
	local activeSection = taskList:FindFirstChild("ActiveSection")
	if not activeSection then
		activeSection = createSection("ActiveSection", "ACTIVE TASKS", colors.Success or Color3.fromRGB(160, 255, 160), taskList)
	end
	entity.ActiveSection = activeSection
	
	local archivedSection = taskList:FindFirstChild("ArchivedSection")
	if not archivedSection then
		archivedSection = createSection("ArchivedSection", "ARCHIVED TASKS", colors.Default or Color3.fromRGB(220, 220, 220), taskList)
		archivedSection.Position = UDim2.new(0, 0, 0.5, 5)
	end
	entity.ArchivedSection = archivedSection
	
	self:Log({ Level = "INFO", Message = "TaskList Page UI initialized successfully" })
end

--[[
	@description Hook for fetching task data.
	@param entity any
	@return ()
]]
function TaskListPageFSM:OnFetchData(entity: any)
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
	local tasks = scheduler and scheduler.Tasks or {}
	
	local displayList = {}
	for taskName, taskData in pairs(tasks) do
		displayList[taskName] = taskData
	end
	
	if entity.ShowArchived then
		for taskName, taskData in pairs(serviceManager.ArchivedTasks or {}) do
			displayList[taskName] = taskData
		end
	end
	
	self.Context._taskList = displayList
	self:Log({ Level = "DEBUG", Message = string.format("Fetched %d tasks", (function() local c = 0 for _ in pairs(displayList) do c += 1 end return c end)()) })
end

--[[
	@description Hook for rendering task cards and metadata panel.
	@param entity any
	@return ()
]]
function TaskListPageFSM:OnRenderUI(entity: any)
	local activeSection = entity.ActiveSection
	local archivedSection = entity.ArchivedSection
	if not activeSection or not archivedSection then return end
	
	local activeList = activeSection:FindFirstChild("List")
	local archivedList = archivedSection:FindFirstChild("List")
	if not activeList or not archivedList then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local displayList = self.Context._taskList or {}
	
	-- Apply section visibility
	if entity.ShowArchived then
		activeSection.Size = UDim2.new(1, 0, 0.5, -5)
		archivedSection.Visible = true
	else
		activeSection.Size = UDim2.new(1, 0, 1, 0)
		archivedSection.Visible = false
	end
	
	-- Sort tasks
	local sorted = {}
	for taskName, taskData in pairs(displayList) do
		table.insert(sorted, { Name = taskName, Task = taskData })
	end
	table.sort(sorted, function(a, b)
		if entity.SortMode == "Priority" then
			local pA, pB = a.Task.Priority or 1, b.Task.Priority or 1
			if pA == pB then return a.Name < b.Name end
			return pA > pB
		elseif entity.SortMode == "Event" then
			local eA, eB = a.Task.Event or "", b.Task.Event or ""
			if eA == eB then return a.Name < b.Name end
			return eA < eB
		else
			return a.Name < b.Name
		end
	end)
	
	-- Filter by search
	local searchText = (entity.Search or ""):lower()
	local filtered = {}
	for _, item in ipairs(sorted) do
		if searchText == "" or tostring(item.Name):lower():find(searchText, 1, true) then
			table.insert(filtered, item)
		end
	end
	
	-- Clear old cards
	for _, child in ipairs(activeList:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextButton") then child:Destroy() end
	end
	for _, child in ipairs(archivedList:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextButton") then child:Destroy() end
	end
	
	-- Get card template
	local cardTemplate = nil
	if serviceManager.GUI and serviceManager.GUI.References then
		cardTemplate = serviceManager.GUI.References:FindFirstChild("TaskCard")
	end
	
	-- Render cards
	for _, item in ipairs(filtered) do
		local taskName = item.Name
		local taskData = item.Task
		local isArchived = taskData.IsArchived == true
		local targetList = isArchived and archivedList or activeList
		
		local card
		if cardTemplate then
			card = cardTemplate:Clone()
		else
			card = Instance.new("Frame")
			card.Size = UDim2.new(1, -10, 0, 50)
			card.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
			Instance.new("UICorner", card).CornerRadius = UDim.new(0, 4)
		end
		
		local cardAny = card :: any
		cardAny.Name = taskName
		cardAny.Parent = targetList
		cardAny.Visible = true
		cardAny:SetAttribute("IsArchived", isArchived)
		
		-- Label
		local label = cardAny:FindFirstChildWhichIsA("TextLabel")
		if label then
			label.Text = taskName
			label.Size = UDim2.new(1, isArchived and -145 or -80, 0.6, 0)
			label.Position = UDim2.new(0, 5, 0, 0)
			label.TextTruncate = Enum.TextTruncate.AtEnd
		end
		
		-- Cancel/Clear button
		local cancelBtn = Instance.new("TextButton", card)
		cancelBtn.Name = "CancelButton"
		cancelBtn.Size = UDim2.new(0, 60, 0, 24)
		cancelBtn.AnchorPoint = Vector2.new(1, 0.5)
		cancelBtn.Position = UDim2.new(1, -10, 0.5, 0)
		cancelBtn.Font = Enum.Font.GothamBold
		cancelBtn.TextSize = 10
		cancelBtn.TextColor3 = Color3.new(1, 1, 1)
		Instance.new("UICorner", cancelBtn).CornerRadius = UDim.new(0, 4)
		
		if isArchived then
			cancelBtn.Text = "CLEAR"
			cancelBtn.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
		else
			cancelBtn.Text = "CANCEL"
			cancelBtn.BackgroundColor3 = colors.Error or Color3.fromRGB(255, 120, 120)
		end
		
		entity:Manage(cancelBtn.MouseButton1Click:Connect(function()
			if isArchived then
				serviceManager.ArchivedTasks[taskName] = nil
				entity:UpdateEntity()
				self:RequestRender()
				if serviceManager.Toast then
					serviceManager:Toast("Cleared Task: " .. taskName, "Success")
				end
			else
				local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
				if scheduler and scheduler.Deschedule then
					scheduler:Deschedule(taskName)
				end
				if entity.SelectedTask == taskName then
					entity:ClearSelection()
				end
				entity:UpdateEntity()
				self:RequestRender()
				if serviceManager.Toast then
					serviceManager:Toast("Descheduled Task: " .. taskName, "Warning")
				end
			end
		end))
		
		-- Restore button for archived
		if isArchived then
			local restoreBtn = Instance.new("TextButton", card)
			restoreBtn.Name = "RestoreButton"
			restoreBtn.Text = "ENABLE"
			restoreBtn.Size = UDim2.new(0, 60, 0, 24)
			restoreBtn.AnchorPoint = Vector2.new(1, 0.5)
			restoreBtn.Position = UDim2.new(1, -75, 0.5, 0)
			restoreBtn.BackgroundColor3 = colors.Success or Color3.fromRGB(160, 255, 160)
			restoreBtn.TextColor3 = Color3.new(1, 1, 1)
			restoreBtn.Font = Enum.Font.GothamBold
			restoreBtn.TextSize = 10
			Instance.new("UICorner", restoreBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(restoreBtn.MouseButton1Click:Connect(function()
				local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
				if scheduler and scheduler.ScheduleTestTask then
					scheduler:ScheduleTestTask(
						taskName,
						taskData.Delay or 0,
						true,
						taskData.Priority or 1,
						taskData.Event or "Heartbeat",
						"Restored Task"
					)
					serviceManager.ArchivedTasks[taskName] = nil
					entity:UpdateEntity()
					self:RequestRender()
					if serviceManager.Toast then
						serviceManager:Toast("Restored Task: " .. taskName, "Success")
					end
				end
			end))
		end
		
		-- Info label
		local info = Instance.new("TextLabel", card)
		info.Name = "InfoLabel"
		info.Size = UDim2.new(1, isArchived and -145 or -80, 0.4, 0)
		info.Position = UDim2.new(0, 5, 0.6, 0)
		info.BackgroundTransparency = 1
		info.TextXAlignment = Enum.TextXAlignment.Left
		info.TextSize = 10
		info.Font = Enum.Font.Gotham
		info.TextTruncate = Enum.TextTruncate.AtEnd
		
		if isArchived then
			info.Text = "DESCHEDULED"
			info.TextColor3 = colors.Error or Color3.fromRGB(255, 120, 120)
		else
			info.Text = string.format("P: %d | %s", taskData.Priority or 1, taskData.Event or "Heartbeat")
			info.TextColor3 = Color3.fromRGB(150, 150, 150)
		end
		
		-- Card click for selection
		local clickArea = cardAny:FindFirstChildWhichIsA("TextButton") or card
		if clickArea == cancelBtn then
			-- Use the card background for click, not cancel button
			local bgClick = Instance.new("TextButton", card)
			bgClick.Name = "ClickArea"
			bgClick.Size = UDim2.new(0.6, 0, 1, 0)
			bgClick.BackgroundTransparency = 1
			bgClick.Text = ""
			bgClick.ZIndex = 0
			clickArea = bgClick
		end
		
		entity:Manage((card :: any).MouseButton1Click:Connect(function()
			entity:SelectTask(taskName)
			entity:UpdateEntity()
			self:RenderMetadataPanel(entity)
		end))
	end
	
	if entity.SelectedTask then
		self:RenderMetadataPanel(entity)
	end
	
	self:Log({ Level = "DEBUG", Message = string.format("Rendered %d task cards", #filtered) })
end

--[[
	@description Renders the metadata panel for the selected task.
	@param entity any
	@return ()
]]
function TaskListPageFSM:RenderMetadataPanel(entity: any)
	local metadataPanel = entity.MetadataPanel
	if not metadataPanel then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local displayList = self.Context._taskList or {}
	
	-- Clear panel
	for _, child in ipairs(metadataPanel:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	
	-- Clear actions panel
	local container = entity.Container
	if container then
		local actionsPanel = container:FindFirstChild("ActionsPanel")
		if actionsPanel then actionsPanel:Destroy() end
	end
	
	if not entity.SelectedTask then return end
	
	local taskData = displayList[entity.SelectedTask]
	local isArchived = taskData and taskData.IsArchived == true
	
	if not taskData then
		taskData = serviceManager.ArchivedTasks and serviceManager.ArchivedTasks[entity.SelectedTask]
		isArchived = true
	end
	
	if not taskData then
		entity:ClearSelection()
		return
	end
	
	-- Render properties
	for key, value in pairs(taskData) do
		if typeof(value) == "function" then continue end
		
		local row = Instance.new("Frame")
		row.Name = key
		row.Size = UDim2.new(1, -10, 0, 24)
		row.BackgroundTransparency = 1
		row.Parent = metadataPanel
		
		local keyLabel = Instance.new("TextLabel", row)
		keyLabel.Name = "Title"
		keyLabel.Size = UDim2.new(0.4, 0, 1, 0)
		keyLabel.BackgroundTransparency = 1
		keyLabel.Text = string.upper(key)
		keyLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
		keyLabel.Font = Enum.Font.GothamBold
		keyLabel.TextSize = 10
		keyLabel.TextXAlignment = Enum.TextXAlignment.Left
		
		local display = tostring(value)
		local color = "#ffffff"
		if typeof(value) == "boolean" then
			color = value and "#A0FFA0" or "#FF7878"
			display = value and "TRUE" or "FALSE"
		elseif typeof(value) == "number" then
			color = "#00C8FF"
			if (key:find("Time") or key:find("Delay")) and value > 1 then
				color = "#FFDC8C"
			end
		end
		
		local valueLabel = Instance.new("TextLabel", row)
		valueLabel.Name = "Value"
		valueLabel.Size = UDim2.new(0.6, 0, 1, 0)
		valueLabel.Position = UDim2.new(0.4, 0, 0, 0)
		valueLabel.BackgroundTransparency = 1
		valueLabel.Text = string.format("<b><font color='%s'>%s</font></b>", color, display)
		valueLabel.TextColor3 = Color3.new(1, 1, 1)
		valueLabel.Font = Enum.Font.Gotham
		valueLabel.TextSize = 10
		valueLabel.TextXAlignment = Enum.TextXAlignment.Left
		valueLabel.RichText = true
	end
	
	-- Action buttons
	if container and not container:FindFirstChild("ActionsPanel") then
		local actionsPanel = Instance.new("Frame")
		actionsPanel.Name = "ActionsPanel"
		actionsPanel.Size = UDim2.new(1, 0, 0, 40)
		actionsPanel.Position = UDim2.new(0, 0, 1, -45)
		actionsPanel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		actionsPanel.Parent = container
		
		Instance.new("UICorner", actionsPanel).CornerRadius = UDim.new(0, 6)
		local layout = Instance.new("UIListLayout", actionsPanel)
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.Padding = UDim.new(0, 5)
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		
		local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
		
		if isArchived then
			local clearBtn = Instance.new("TextButton", actionsPanel)
			clearBtn.Text = "CLEAR"
			clearBtn.Size = UDim2.new(0, 60, 0, 30)
			clearBtn.BackgroundColor3 = colors.Error or Color3.fromRGB(255, 120, 120)
			clearBtn.TextColor3 = Color3.new(1, 1, 1)
			clearBtn.Font = Enum.Font.GothamBold
			clearBtn.TextSize = 12
			Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(clearBtn.MouseButton1Click:Connect(function()
				serviceManager.ArchivedTasks[entity.SelectedTask] = nil
				entity:ClearSelection()
				entity:UpdateEntity()
				self:RequestRender()
				if serviceManager.Toast then
					serviceManager:Toast("Cleared Task: " .. entity.SelectedTask, "Success")
				end
			end))
		else
			-- EXECUTE button
			local execBtn = Instance.new("TextButton", actionsPanel)
			execBtn.Text = "EXECUTE"
			execBtn.Size = UDim2.new(0, 60, 0, 30)
			execBtn.BackgroundColor3 = colors.Success or Color3.fromRGB(160, 255, 160)
			execBtn.TextColor3 = Color3.new(1, 1, 1)
			execBtn.Font = Enum.Font.GothamBold
			execBtn.TextSize = 12
			execBtn.LayoutOrder = 1
			Instance.new("UICorner", execBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(execBtn.MouseButton1Click:Connect(function()
				if scheduler and scheduler.ExecuteTask then
					scheduler:ExecuteTask(entity.SelectedTask)
				end
				if serviceManager.Toast then
					serviceManager:Toast("Executed Task: " .. entity.SelectedTask, "Success")
				end
			end))
			
			-- RESET button
			local resetBtn = Instance.new("TextButton", actionsPanel)
			resetBtn.Text = "RESET"
			resetBtn.Size = UDim2.new(0, 60, 0, 30)
			resetBtn.BackgroundColor3 = colors.Warning or Color3.fromRGB(255, 200, 100)
			resetBtn.TextColor3 = Color3.new(1, 1, 1)
			resetBtn.Font = Enum.Font.GothamBold
			resetBtn.TextSize = 12
			resetBtn.LayoutOrder = 2
			Instance.new("UICorner", resetBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(resetBtn.MouseButton1Click:Connect(function()
				if scheduler and scheduler.ResetTask then
					scheduler:ResetTask(entity.SelectedTask)
				end
				if serviceManager.Toast then
					serviceManager:Toast("Reset Task: " .. entity.SelectedTask, "Success")
				end
			end))
			
			-- KILL button
			local killBtn = Instance.new("TextButton", actionsPanel)
			killBtn.Text = "KILL"
			killBtn.Size = UDim2.new(0, 60, 0, 30)
			killBtn.BackgroundColor3 = colors.Error or Color3.fromRGB(255, 120, 120)
			killBtn.TextColor3 = Color3.new(1, 1, 1)
			killBtn.Font = Enum.Font.GothamBold
			killBtn.TextSize = 12
			killBtn.LayoutOrder = 3
			Instance.new("UICorner", killBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(killBtn.MouseButton1Click:Connect(function()
				if scheduler and scheduler.Deschedule then
					scheduler:Deschedule(entity.SelectedTask)
				end
				entity:ClearSelection()
				entity:UpdateEntity()
				self:RequestRender()
				if serviceManager.Toast then
					serviceManager:Toast("Killed Task: " .. entity.SelectedTask, "Error")
				end
			end))
		end
	end
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function TaskListPageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function TaskListPageFSM:OnCleanup()
	self.Context._taskList = nil
	BasePageFSM.OnCleanup(self)
end

return TaskListPageFSM
