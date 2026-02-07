--!strict
-- @Name FSMsPageFSM
-- @Author iKrypto
-- @Description FSMs Page FSM managing state machine display, selection, and actions.
-- Migrated from legacy FSMsPage.luau controller pattern.

local BasePageFSM = require(script.Parent.BasePageFSM)

local FSMsPageFSM = BasePageFSM.Extend({
	className = "FSMsPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ShowingDetails", "ExecutingAction", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 11
})

--[[
	@description Registers states for the FSMs page FSM.
	@return ()
]]
--[[
	@description Registers base lifecycle states for FSM listing.
]]
function FSMsPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("ShowingDetails", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity
			fsm:Log({ Level = "DEBUG", Message = string.format("Showing FSM details: %s", tostring(entity.SelectedStateMachine)) })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
	
	self:AddState("ExecutingAction", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Executing FSM action..." })
			fsm:ChangeState({ Name = "Rendering" })
		end
	})
end

--[[
	@description Creates a labeled section frame.
	@return Frame
]]
local function createSection(name: string, titleText: string, color: Color3, parent: Instance): Frame
	local section = Instance.new("Frame")
	section.Name = name
	section.Size = UDim2.new(1, 0, 0.33, -5)
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
	@description Hook for initializing FSMs UI elements.
	@param entity any
	@return ()
]]
--[[
	@description Initializes the FSMs Page UI elements.
	@param entity any -- The FSMsPageEntity instance.
]]
function FSMsPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing FSMs Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "FSMs container not found" })
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
			entity:ResetPagination()
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
			serviceManager.ArchivedFSMs = {}
			entity.SelectedStateMachine = nil
			entity:UpdateEntity()
			self:RequestRender()
			if serviceManager.Toast then
				serviceManager:Toast("Cleared Ended StateMachines", "Success")
			end
		end))
	end
	
	-- Container sizing
	local containerAny = container :: any
	containerAny.Size = UDim2.new(1, 0, 1, -40)
	containerAny.Position = UDim2.new(0, 0, 0, 40)
	
	-- StateMachineList frame
	local smList = container:FindFirstChild("StateMachineList")
	if not smList then
		smList = Instance.new("Frame")
		smList.Name = "StateMachineList"
		smList.Size = UDim2.new(0.65, -5, 1, 0)
		smList.BackgroundTransparency = 1
		smList.Parent = container
	end
	entity.StateMachineList = smList
	
	-- Metadata panel
	local metadataPanel = container:FindFirstChild("StateMachineMetadata")
	if not metadataPanel then
		metadataPanel = Instance.new("ScrollingFrame")
		metadataPanel.Name = "StateMachineMetadata"
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
	local activeSection = smList:FindFirstChild("ActiveSection")
	if not activeSection then
		activeSection = createSection("ActiveSection", "ACTIVE JOBS", colors.Success or Color3.fromRGB(160, 255, 160), smList)
		activeSection.Size = UDim2.new(1, 0, 1, 0)
	end
	entity.ActiveSection = activeSection
	
	local failedSection = smList:FindFirstChild("FailedSection")
	if not failedSection then
		failedSection = createSection("FailedSection", "FAILED JOBS", colors.Error or Color3.fromRGB(255, 120, 120), smList)
		failedSection.Position = UDim2.new(0, 0, 0.4, 5)
		failedSection.Visible = false
	end
	entity.FailedSection = failedSection
	
	local archivedSection = smList:FindFirstChild("ArchivedSection")
	if not archivedSection then
		archivedSection = createSection("ArchivedSection", "COMPLETED JOBS", colors.Default or Color3.fromRGB(220, 220, 220), smList)
		archivedSection.Position = UDim2.new(0, 0, 0.7, 5)
		archivedSection.Visible = false
	end
	entity.ArchivedSection = archivedSection
	
	self:Log({ Level = "INFO", Message = "FSMs Page UI initialized successfully" })
end

--[[
	@description Hook for fetching FSM data.
	@param entity any
	@return ()
]]
function FSMsPageFSM:OnFetchData(entity: any)
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local fsmService = serviceManager.Services and serviceManager.Services.FSM
	local stateMachines = fsmService and fsmService.StateMachines or {}
	
	local displayList = {}
	for smId, smData in pairs(stateMachines) do
		displayList[smId] = smData
	end
	
	if entity.ShowArchived then
		for smId, smData in pairs(serviceManager.ArchivedFSMs or {}) do
			displayList[smId] = smData
		end
	end
	
	self.Context._fsmList = displayList
	self:Log({ Level = "DEBUG", Message = string.format("Fetched %d state machines", (function() local c = 0 for _ in pairs(displayList) do c += 1 end return c end)()) })
end

--[[
	@description Hook for rendering FSM cards and metadata panel.
	@param entity any
	@return ()
]]
function FSMsPageFSM:OnRenderUI(entity: any)
	local activeSection = entity.ActiveSection
	local failedSection = entity.FailedSection
	local archivedSection = entity.ArchivedSection
	if not activeSection or not failedSection or not archivedSection then return end
	
	local activeList = activeSection:FindFirstChild("List")
	local failedList = failedSection:FindFirstChild("List")
	local archivedList = archivedSection:FindFirstChild("List")
	if not activeList or not failedList or not archivedList then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local displayList = self.Context._fsmList or {}
	
	-- Apply section visibility
	if entity.ShowArchived then
		activeSection.Size = UDim2.new(1, 0, 0.4, -5)
		failedSection.Visible = true
		failedSection.Size = UDim2.new(1, 0, 0.3, -5)
		archivedSection.Visible = true
		archivedSection.Size = UDim2.new(1, 0, 0.3, -5)
	else
		activeSection.Size = UDim2.new(1, 0, 1, 0)
		failedSection.Visible = false
		archivedSection.Visible = false
	end
	
	-- Sort
	local sorted = {}
	for smId, smData in pairs(displayList) do
		table.insert(sorted, { Id = smId, FSM = smData })
	end
	table.sort(sorted, function(a, b)
		return tostring(a.FSM.Name or a.Id) < tostring(b.FSM.Name or b.Id)
	end)
	
	-- Filter by search
	local searchText = (entity.Search or ""):lower()
	local filtered = {}
	for _, item in ipairs(sorted) do
		local idMatch = tostring(item.Id):lower():find(searchText, 1, true)
		local nameMatch = item.FSM.Name and tostring(item.FSM.Name):lower():find(searchText, 1, true)
		if searchText == "" or idMatch or nameMatch then
			table.insert(filtered, item)
		end
	end
	
	-- Pagination
	local pageSize = entity.PageSize or 10
	local maxPage = math.max(1, math.ceil(#filtered / pageSize))
	if entity.Page > maxPage then entity.Page = maxPage end
	
	local startIndex = (entity.Page - 1) * pageSize + 1
	local endIndex = startIndex + pageSize - 1
	
	-- Clear old cards
	for _, child in ipairs(activeList:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	for _, child in ipairs(failedList:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	for _, child in ipairs(archivedList:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	
	-- Get card template
	local cardTemplate = nil
	if serviceManager.GUI and serviceManager.GUI.References then
		cardTemplate = serviceManager.GUI.References:FindFirstChild("TaskCard")
	end
	
	-- Render cards
	for i = startIndex, endIndex do
		local item = filtered[i]
		if not item then break end
		
		local smId = item.Id
		local smData = item.FSM
		local smName = smData.Name or "StateMachine"
		local smState = smData.State or "Unknown"
		local isArchived = smData.IsArchived == true
		local isFailed = isArchived and (smState == "Failed" or smState == "Error" or smState == "Cancelled")
		local targetList = isArchived and (isFailed and failedList or archivedList) or activeList
		
		local card
		if cardTemplate then
			card = cardTemplate:Clone()
		else
			card = Instance.new("TextButton")
			card.Size = UDim2.new(1, -10, 0, 50)
			card.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
			Instance.new("UICorner", card).CornerRadius = UDim.new(0, 4)
		end
		
		local cardAny = card :: any
		cardAny.Name = smId
		cardAny.Parent = targetList
		cardAny.Visible = true
		
		-- Label
		local label = cardAny:FindFirstChildWhichIsA("TextLabel")
		local displayText = (smName == smId) and smName or string.format("%s <font color='#888888' size='10'>%s</font>", smName, smId)
		if label then
			label.Text = displayText
			label.Size = UDim2.new(1, isArchived and -10 or -80, 0.6, 0)
			label.Position = UDim2.new(0, 5, 0, 0)
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.RichText = true
		else
			cardAny.Text = displayText
			cardAny.RichText = true
		end
		
		-- Info label
		local info = cardAny:FindFirstChild("Info")
		if not info then
			info = Instance.new("TextLabel", card)
			info.Name = "Info"
			info.Size = UDim2.new(1, isArchived and -10 or -80, 0.4, 0)
			info.Position = UDim2.new(0, 5, 0.6, 0)
			info.BackgroundTransparency = 1
			info.TextXAlignment = Enum.TextXAlignment.Left
			info.TextSize = 10
			info.Font = Enum.Font.Gotham
		end
		info.TextColor3 = isArchived and (colors.Error or Color3.fromRGB(255, 120, 120)) or Color3.fromRGB(150, 150, 150)
		info.Text = "State: " .. smState
		
		-- Click handler
		entity:Manage(cardAny.MouseButton1Click:Connect(function()
			entity:SelectStateMachine(smId)
			entity:UpdateEntity()
			self:RenderMetadataPanel(entity)
		end))
	end
	
	if entity.SelectedStateMachine then
		self:RenderMetadataPanel(entity)
	end
	
	self:Log({ Level = "DEBUG", Message = string.format("Rendered %d FSM cards", math.min(#filtered, pageSize)) })
end

--[[
	@description Renders the metadata panel for the selected FSM.
	@param entity any
	@return ()
]]
function FSMsPageFSM:RenderMetadataPanel(entity: any)
	local metadataPanel = entity.MetadataPanel
	if not metadataPanel then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local displayList = self.Context._fsmList or {}
	
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
	
	if not entity.SelectedStateMachine then return end
	
	local smData = displayList[entity.SelectedStateMachine]
	local isArchived = smData and smData.IsArchived == true
	
	if not smData then
		smData = serviceManager.ArchivedFSMs and serviceManager.ArchivedFSMs[entity.SelectedStateMachine]
		isArchived = true
	end
	
	if not smData then
		entity:ClearSelection()
		return
	end
	
	-- Helper to add property row
	local function addProp(key: string, value: any)
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
		
		local valueLabel = Instance.new("TextLabel", row)
		valueLabel.Name = "Value"
		valueLabel.Size = UDim2.new(0.6, 0, 1, 0)
		valueLabel.Position = UDim2.new(0.4, 0, 0, 0)
		valueLabel.BackgroundTransparency = 1
		valueLabel.Text = tostring(value)
		valueLabel.TextColor3 = Color3.new(1, 1, 1)
		valueLabel.Font = Enum.Font.Gotham
		valueLabel.TextSize = 10
		valueLabel.TextXAlignment = Enum.TextXAlignment.Left
		valueLabel.RichText = true
	end
	
	addProp("ID", entity.SelectedStateMachine)
	addProp("Name", smData.Name or "Unknown")
	addProp("State", smData.State or "Unknown")
	addProp("Status", isArchived and "ARCHIVED" or "ACTIVE")
	
	if smData.Error then
		addProp("Error", smData.Error)
	end
	
	if smData.Context and type(smData.Context) == "table" then
		for ctxKey, ctxValue in pairs(smData.Context) do
			if type(ctxValue) ~= "function" and type(ctxValue) ~= "table" then
				addProp("CTX." .. tostring(ctxKey), ctxValue)
			end
		end
	end
	
	-- Create action buttons
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
		
		local fsmService = serviceManager.Services and serviceManager.Services.FSM
		
		if isArchived then
			-- CLEAR button
			local clearBtn = Instance.new("TextButton", actionsPanel)
			clearBtn.Text = "CLEAR"
			clearBtn.Size = UDim2.new(0, 60, 0, 30)
			clearBtn.BackgroundColor3 = colors.Error or Color3.fromRGB(255, 120, 120)
			clearBtn.TextColor3 = Color3.new(1, 1, 1)
			clearBtn.Font = Enum.Font.GothamBold
			clearBtn.TextSize = 12
			Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(clearBtn.MouseButton1Click:Connect(function()
				serviceManager.ArchivedFSMs[entity.SelectedStateMachine] = nil
				entity:ClearSelection()
				entity:UpdateEntity()
				self:RequestRender()
				if serviceManager.Toast then
					serviceManager:Toast("Cleared StateMachine: " .. entity.SelectedStateMachine, "Success")
				end
			end))
		else
			-- CANCEL button
			local cancelBtn = Instance.new("TextButton", actionsPanel)
			cancelBtn.Text = "CANCEL"
			cancelBtn.Size = UDim2.new(0, 60, 0, 30)
			cancelBtn.BackgroundColor3 = colors.Error or Color3.fromRGB(255, 120, 120)
			cancelBtn.TextColor3 = Color3.new(1, 1, 1)
			cancelBtn.Font = Enum.Font.GothamBold
			cancelBtn.TextSize = 12
			cancelBtn.LayoutOrder = 1
			Instance.new("UICorner", cancelBtn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(cancelBtn.MouseButton1Click:Connect(function()
				if fsmService and fsmService.CancelStateMachine then
					fsmService:CancelStateMachine(entity.SelectedStateMachine)
				end
				if serviceManager.Toast then
					serviceManager:Toast("Cancelled StateMachine: " .. entity.SelectedStateMachine, "Error")
				end
			end))
			
			-- RETRY button (for failed states)
			local state = tostring(smData.State)
			if state == "Failed" or state == "Cancelled" then
				local retryBtn = Instance.new("TextButton", actionsPanel)
				retryBtn.Text = "RETRY"
				retryBtn.Size = UDim2.new(0, 60, 0, 30)
				retryBtn.BackgroundColor3 = colors.Warning or Color3.fromRGB(255, 200, 100)
				retryBtn.TextColor3 = Color3.new(1, 1, 1)
				retryBtn.Font = Enum.Font.GothamBold
				retryBtn.TextSize = 12
				retryBtn.LayoutOrder = 2
				Instance.new("UICorner", retryBtn).CornerRadius = UDim.new(0, 4)
				
				entity:Manage(retryBtn.MouseButton1Click:Connect(function()
					if fsmService and fsmService.RetryStateMachine then
						fsmService:RetryStateMachine(entity.SelectedStateMachine)
					end
					if serviceManager.Toast then
						serviceManager:Toast("Retrying StateMachine: " .. entity.SelectedStateMachine, "Warning")
					end
				end))
			end
		end
	end
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function FSMsPageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
--[[
	@description Delegates to the base FSM cleanup handler.
]]
function FSMsPageFSM:OnCleanup()
	self.Context._fsmList = nil
	BasePageFSM.OnCleanup(self)
end

return FSMsPageFSM
