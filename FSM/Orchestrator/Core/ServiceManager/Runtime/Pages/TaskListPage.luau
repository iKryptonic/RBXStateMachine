--!strict

-- Runtime/Pages/TaskListPage.luau
-- Extracted TaskList page controller.

export type Deps = {
	EnsureToolbar: (Instance) -> Instance,
	CreateSearchBox: (Instance, string?, (string) -> ()) -> Instance,
	CreateButton: (Instance, string, Color3, (() -> ())?, number?) -> Instance,
	COLORS: { [string]: Color3 },
	TaskCardReference: Instance,
	TaskDataReference: Instance,
}

type Constants = {
	SelectedTask: string?,
	Search: string,
	ShowArchived: boolean,
	SortMode: string,
}

local TaskListPage = {}

function TaskListPage.Create(ServiceManager: any, deps: Deps)
	local page: any = {
		Container = ServiceManager.GUI.BodyContainer:WaitForChild("TaskListView"):WaitForChild("Container"),
		Tab = ServiceManager.GUI.TabContainer:WaitForChild("TaskList"),
		Constants = ({ SelectedTask = (nil :: string?), Search = "", ShowArchived = true, SortMode = "Name" } :: Constants),
		Connections = {},
		StableConnections = {},
		DynamicConnections = {},
	}

	page.UpdateFunction = function(this)
		if not this.Container or not this.Constants then
			return
		end
		local constants = this.Constants :: Constants
		local view = this.Container.Parent
		if not view then return end

		-- --------------------------------------------------------------------------------
		-- ONE-TIME UI SETUP (Toolbar & Sections)
		-- --------------------------------------------------------------------------------
		local existingToolbar = view:FindFirstChild("Toolbar")
		if not existingToolbar then
			-- Toolbar was destroyed on tab switch; clear stable conns so we don't leak.
			ServiceManager:ClearConnections(this.StableConnections)
			this.StableConnections = {}

			local toolbar = deps.EnsureToolbar(view)
			deps.CreateSearchBox(toolbar, this.Constants.Search, function(text)
				this.Constants.Search = text
				this.UpdateFunction(this)
			end)

			local showArchivedBtn = deps.CreateButton(toolbar, "SHOW ENDED", this.Constants.ShowArchived and deps.COLORS.Accent or deps.COLORS.DarkBG, nil, 90)
			local showArchivedBtnAny = showArchivedBtn :: any
			local showArchivedConn = (showArchivedBtn :: any).MouseButton1Click:Connect(function()
				this.Constants.ShowArchived = not this.Constants.ShowArchived
				showArchivedBtnAny.BackgroundColor3 = this.Constants.ShowArchived and deps.COLORS.Accent or deps.COLORS.DarkBG

				local activeSection = (this.Container :: any).TaskList:FindFirstChild("ActiveSection")
				local archivedSection = (this.Container :: any).TaskList:FindFirstChild("ArchivedSection")
				if activeSection and archivedSection then
					local activeSectionAny = activeSection :: any
					local archivedSectionAny = archivedSection :: any
					activeSectionAny.Size = this.Constants.ShowArchived and UDim2.new(1, 0, 0.5, -5) or UDim2.new(1, 0, 1, 0)
					archivedSectionAny.Visible = this.Constants.ShowArchived
				end
				this.UpdateFunction(this)
			end)
			table.insert(this.StableConnections, showArchivedConn)
			table.insert(this.Connections, showArchivedConn)

			deps.CreateButton(toolbar, "CLEAR ENDED", deps.COLORS.DarkBG, function()
				ServiceManager.ArchivedTasks = {}
				this.UpdateFunction(this)
				this:Toast("Cleared Ended Tasks", "Success")
			end, 90)

			local sortBtn = deps.CreateButton(toolbar, "SORT: NAME", deps.COLORS.DarkBG, nil, 90)
			local sortBtnAny = sortBtn :: any
			local sortConn = (sortBtn :: any).MouseButton1Click:Connect(function()
				local modes = { "Name", "Priority", "Event" }
				local currentIdx = table.find(modes, this.Constants.SortMode) or 1
				this.Constants.SortMode = modes[(currentIdx % #modes) + 1]
				sortBtnAny.Text = "SORT: " .. tostring(this.Constants.SortMode):upper()
				this.UpdateFunction(this)
			end)
			table.insert(this.StableConnections, sortConn)
			table.insert(this.Connections, sortConn)

			-- Adjust Container size to fit toolbar
			local containerAny = this.Container :: any
			containerAny.Size = UDim2.new(1, 0, 1, -40)
			containerAny.Position = UDim2.new(0, 0, 0, 40)
		end

		-- Ensure Sections Exist
		local function createSection(name: string, titleText: string, color: Color3, parent: Instance)
			local section = deps.Create("Frame", {
				Name = name,
				Size = UDim2.new(1, 0, 0.5, -5),
				BackgroundColor3 = Color3.fromRGB(30, 30, 30),
				Parent = parent,
			})
			deps.Create("UICorner", { Parent = section })
			deps.Create("TextLabel", {
				Name = "Title",
				Size = UDim2.new(1, -20, 0, 30),
				Position = UDim2.new(0, 10, 0, 0),
				BackgroundTransparency = 1,
				Text = titleText,
				Font = Enum.Font.GothamBold,
				TextSize = 12,
				TextColor3 = color,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = section,
			})
			local list = deps.Create("ScrollingFrame", {
				Name = "List",
				Size = UDim2.new(1, 0, 1, -35),
				Position = UDim2.new(0, 0, 0, 35),
				BackgroundTransparency = 1,
				ScrollBarThickness = 2,
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.new(0, 0, 0, 0),
				Parent = section,
			})
			deps.Create("UIListLayout", { Padding = UDim.new(0, 5), Parent = list })
			deps.Create("UIPadding", { PaddingLeft = UDim.new(0, 5), Parent = list })
			return section
		end

		local activeSection = (this.Container :: any).TaskList:FindFirstChild("ActiveSection") or createSection("ActiveSection", "ACTIVE TASKS", deps.COLORS.Success, (this.Container :: any).TaskList)
		local archivedSection = (this.Container :: any).TaskList:FindFirstChild("ArchivedSection") or createSection("ArchivedSection", "ARCHIVED TASKS", deps.COLORS.Default, (this.Container :: any).TaskList)

		-- Apply Visibility
		local activeSectionAny = activeSection :: any
		local archivedSectionAny = archivedSection :: any
		activeSectionAny.Size = this.Constants.ShowArchived and UDim2.new(1, 0, 0.5, -5) or UDim2.new(1, 0, 1, 0)
		archivedSectionAny.Visible = this.Constants.ShowArchived

		-- --------------------------------------------------------------------------------
		-- HELPERS (Scoped to UpdateFunction)
		-- --------------------------------------------------------------------------------
		local function clearTaskMetadataPanel()
			ServiceManager:ClearConnections(this.DynamicConnections)
			this.DynamicConnections = {}

			for _, child in next, (this.Container :: any).TaskMetadata:GetChildren() do
				if child:IsA("Frame") or child:IsA("TextLabel") then
					child:Destroy()
				end
			end
			if (this.Container :: any):FindFirstChild("ActionsPanel") then
				local actionsPanel = (this.Container :: any).ActionsPanel
				actionsPanel:Destroy()
			end
		end
		
		local function createActionButton(name: string, color: Color3, order: number, callback: () -> ())
			local panel = (this.Container :: any):FindFirstChild("ActionsPanel")
			if not panel then
				panel = Instance.new("Frame")
				panel.Name = "ActionsPanel"
				panel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
				panel.Size = UDim2.new(1, 0, 0, 40)
				panel.Position = UDim2.new(0, 0, 1, -45)
				panel.Parent = this.Container
				Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 6)
				local listLayout = Instance.new("UIListLayout", panel)
				listLayout.FillDirection = Enum.FillDirection.Horizontal
				listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
				listLayout.Padding = UDim.new(0, 5)
				listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			end

			local btn = Instance.new("TextButton")
			btn.Text = name
			btn.BackgroundColor3 = color
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.Font = Enum.Font.GothamBold
			btn.TextSize = 12
			btn.Size = UDim2.new(0, 60, 0, 30)
			btn.LayoutOrder = order
			btn.Parent = panel
			Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

			local connection = btn.MouseButton1Click:Connect(callback)
			table.insert(this.DynamicConnections, connection)
			table.insert(this.Connections, connection)
		end

		local function updateSelectedTaskMetadata()
			local scheduler = ServiceManager.Services.Scheduler
			if not constants.SelectedTask or not scheduler then return end
			local taskName = constants.SelectedTask

			local taskData = (scheduler :: any).Tasks and (scheduler :: any).Tasks[taskName]
			local isArchived = false
			if not taskData then
				taskData = ServiceManager.ArchivedTasks[taskName]
				isArchived = true
			end

			if not taskData then
				constants.SelectedTask = nil
				clearTaskMetadataPanel()
				return
			end

			local container = (this.Container :: any).TaskMetadata
			for key, value in next, taskData do
				if typeof(value) == "function" then continue end
				local dataObject = container:FindFirstChild(key) or deps.TaskDataReference:Clone()
				dataObject.Name = key
				dataObject.Parent = container;
				local dataObjectAny = dataObject :: any
				dataObjectAny.Visible = true
				if dataObjectAny:FindFirstChild("Title") then
					local titleAny = dataObjectAny.Title :: any
					titleAny.Text = string.upper(key)
				end
				if dataObjectAny:FindFirstChild("Value") then
					local display = tostring(value)
					local color = "#ffffff"
					if typeof(value) == "boolean" then
						color = value and "#A0FFA0" or "#FF7878"
						display = value and "TRUE" or "FALSE"
					elseif typeof(value) == "number" then
						color = "#00C8FF"
						if (tostring(key):find("Time") or tostring(key):find("Delay")) and value > 1 then color = "#FFDC8C" end
					end
					local valueAny = dataObjectAny.Value :: any
					valueAny.Text = string.format("<b><font color='%s'>%s</font></b>", color, display)
				end
			end

			for _, child in next, container:GetChildren() do
				if child:IsA("Frame") and not taskData[child.Name] then
					child:Destroy()
				end
			end

			if not (this.Container :: any):FindFirstChild("ActionsPanel") then
				if isArchived then
					createActionButton("CLEAR", deps.COLORS.Error, 1, function()
						ServiceManager.ArchivedTasks[taskName] = nil
						constants.SelectedTask = nil
						clearTaskMetadataPanel()
						this.UpdateFunction(this)
						this:Toast("Cleared Task: " .. taskName, "Success")
					end)
				else
					createActionButton("EXECUTE", deps.COLORS.Success, 1, function()
						local schedulerAny = scheduler :: any
						schedulerAny:ExecuteTask(taskName)
						this:Toast("Executed Task: " .. taskName, "Success")
					end)
					createActionButton("RESET", deps.COLORS.Warning, 2, function()
						local schedulerAny = scheduler :: any
						schedulerAny:ResetTask(taskName)
						this:Toast("Reset Task: " .. taskName, "Success")
					end)
					createActionButton("KILL", deps.COLORS.Error, 3, function()
						local schedulerAny = scheduler :: any
						schedulerAny:Deschedule(taskName)
						constants.SelectedTask = nil
						clearTaskMetadataPanel()
						this:Toast("Killed Task: " .. taskName, "Error")
					end)
				end
			end
		end

		local function hookTaskCard(taskCard: any, taskName: string)
			-- Hook card selection
			if not taskCard:FindFirstChild("IsHooked") then
				local hookMarker = Instance.new("BoolValue")
				hookMarker.Name = "IsHooked"
				hookMarker.Parent = taskCard
				local conn = taskCard.MouseButton1Click:Connect(function()
					clearTaskMetadataPanel()
					constants.SelectedTask = taskName
					this.UpdateFunction(this)
				end)
				table.insert(this.Connections, conn)
			end

			-- Hook per-card buttons
			local taskCardAny = taskCard :: any
			local isArchived = taskCardAny:GetAttribute("IsArchived") == true
			
			local cancelBtn = taskCardAny:FindFirstChild("CancelButton")
			if cancelBtn and not cancelBtn:FindFirstChild("IsHooked") then
				local hookMarker = Instance.new("BoolValue")
				hookMarker.Name = "IsHooked"
				hookMarker.Parent = cancelBtn
				local conn = (cancelBtn :: any).MouseButton1Click:Connect(function()
					if isArchived then
						ServiceManager.ArchivedTasks[taskName] = nil
						this.UpdateFunction(this)
						this:Toast("Cleared Task: " .. taskName, "Success")
						return
					end

					local scheduler = ServiceManager.Services.Scheduler
					if scheduler then
						local schedulerAny = scheduler :: any
						schedulerAny:Deschedule(taskName)
					end
					if constants.SelectedTask == taskName then
						constants.SelectedTask = nil
						clearTaskMetadataPanel()
					end
					this:Toast("Descheduled Task: " .. taskName, "Warning")
				end)
				table.insert(this.Connections, conn)
			end

			local restoreBtn = taskCardAny:FindFirstChild("RestoreButton")
			if restoreBtn and not restoreBtn:FindFirstChild("IsHooked") then
				local hookMarker = Instance.new("BoolValue")
				hookMarker.Name = "IsHooked"
				hookMarker.Parent = restoreBtn
				local conn = (restoreBtn :: any).MouseButton1Click:Connect(function()
					local scheduler = ServiceManager.Services.Scheduler
					local taskData = ServiceManager.ArchivedTasks[taskName]
					if scheduler and taskData then
						local schedulerAny = scheduler :: any
						local taskAny = taskData :: any
						schedulerAny:ScheduleTestTask(taskName, taskAny.Delay or 0, true, taskAny.Priority or 1, taskAny.Event or "Heartbeat", "Restored Task")
						ServiceManager.ArchivedTasks[taskName] = nil
						this.UpdateFunction(this)
						this:Toast("Restored Task: " .. taskName, "Success")
					end
				end)
				table.insert(this.Connections, conn)
			end
		end

		local function updateTaskList()
			local scheduler = ServiceManager.Services.Scheduler
			if not scheduler then return end

			local tasks = (scheduler :: any).Tasks
			local displayList: any = {}
			for taskName, taskData in pairs(tasks or {}) do
				displayList[taskName] = taskData
			end
			if this.Constants.ShowArchived then
				for taskName, taskData in pairs(ServiceManager.ArchivedTasks) do
					displayList[taskName] = taskData
				end
			end

			local activeList = (activeSection :: any).List
			local archivedList = (archivedSection :: any).List

			-- Cleanup missing
			for _, child in next, activeList:GetChildren() do
				if child:IsA("Frame") and (not displayList[child.Name] or (displayList[child.Name] :: any).IsArchived) then child:Destroy() end
			end
			for _, child in next, archivedList:GetChildren() do
				if child:IsA("Frame") and (not displayList[child.Name] or not (displayList[child.Name] :: any).IsArchived) then child:Destroy() end
			end

			-- Sort
			local sorted: { any } = {}
			for taskName, taskData in pairs(displayList) do
				table.insert(sorted, { Name = taskName, Task = taskData })
			end
			table.sort(sorted, function(a, b)
				if this.Constants.SortMode == "Priority" then
					local pA, pB = (a.Task :: any).Priority or 1, (b.Task :: any).Priority or 1
					if pA == pB then return a.Name < b.Name end
					return pA > pB
				elseif this.Constants.SortMode == "Event" then
					local eA, eB = (a.Task :: any).Event or "", (b.Task :: any).Event or ""
					if eA == eB then return a.Name < b.Name end
					return eA < eB
				else
					return a.Name < b.Name
				end
			end)

			for _, item in ipairs(sorted) do
				local taskName, task = item.Name, item.Task
				if this.Constants.Search ~= "" and not tostring(taskName):lower():find(tostring(this.Constants.Search):lower(), 1, true) then
					continue
				end

				local isArchived = (task :: any).IsArchived == true
				local targetList = isArchived and archivedList or activeList
				
				local card = targetList:FindFirstChild(taskName)
				if card and card:GetAttribute("IsArchived") ~= isArchived then
					card:Destroy()
					card = nil
				end

				if not card then
					card = deps.TaskCardReference:Clone()
					local cardAny = card :: any
					cardAny:SetAttribute("IsArchived", isArchived)
					local label = cardAny:FindFirstChildWhichIsA("TextLabel")
					label.Text = taskName
					label.Size = UDim2.new(1, -80, 0.6, 0)
					label.TextTruncate = Enum.TextTruncate.AtEnd
					label.Position = UDim2.new(0, 5, 0, 0)
					cardAny.Name = taskName
					cardAny.Parent = targetList
					cardAny.Visible = true

					local cancelBtn = Instance.new("TextButton")
					cancelBtn.Name = "CancelButton"
					cancelBtn.Size = UDim2.new(0, 60, 0, 24)
					cancelBtn.AnchorPoint = Vector2.new(1, 0.5)
					cancelBtn.Position = UDim2.new(1, -10, 0.5, 0)
					cancelBtn.Font = Enum.Font.GothamBold
					cancelBtn.TextSize = 10
					Instance.new("UICorner", cancelBtn).CornerRadius = UDim.new(0, 4)
					cancelBtn.Parent = card

					if isArchived then
						label.Size = UDim2.new(1, -145, 0.6, 0)
						cancelBtn.Text = "CLEAR"
						cancelBtn.BackgroundColor3 = deps.COLORS.DarkBG
						
						local restoreBtn = Instance.new("TextButton")
						restoreBtn.Name = "RestoreButton"
						restoreBtn.Text = "ENABLE"
						restoreBtn.Size = UDim2.new(0, 60, 0, 24)
						restoreBtn.AnchorPoint = Vector2.new(1, 0.5)
						restoreBtn.Position = UDim2.new(1, -75, 0.5, 0)
						restoreBtn.BackgroundColor3 = deps.COLORS.Success
						restoreBtn.TextColor3 = Color3.new(1, 1, 1)
						restoreBtn.Font = Enum.Font.GothamBold
						restoreBtn.TextSize = 10
						Instance.new("UICorner", restoreBtn).CornerRadius = UDim.new(0, 4)
						restoreBtn.Parent = card
					else
						cancelBtn.Text = "CANCEL"
						cancelBtn.BackgroundColor3 = deps.COLORS.Error
						cancelBtn.TextColor3 = Color3.new(1, 1, 1)
					end

					local info = Instance.new("TextLabel")
					info.Size = isArchived and UDim2.new(1, -145, 0.4, 0) or UDim2.new(1, -80, 0.4, 0)
					info.Position = UDim2.new(0, 5, 0.6, 0)
					info.BackgroundTransparency = 1
					info.TextXAlignment = Enum.TextXAlignment.Left
					info.TextTruncate = Enum.TextTruncate.AtEnd
					info.TextSize = 10
					info.Font = Enum.Font.Gotham
					info.Name = "InfoLabel"
					info.Parent = card
				end

				hookTaskCard(card, taskName)

				local infoLabel = card:FindFirstChild("InfoLabel")
				if infoLabel and infoLabel:IsA("TextLabel") then
					if isArchived then
						infoLabel.Text = "DESCHEDULED"
						infoLabel.TextColor3 = deps.COLORS.Error
					else
						infoLabel.Text = string.format("P: %d | %s", (task :: any).Priority or 1, (task :: any).Event or "Heartbeat")
						infoLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
					end
				end
			end
		end

		updateTaskList()
		updateSelectedTaskMetadata()
	end

	return page
end

return TaskListPage
