--!strict
-- @Name EntitiesPageFSM
-- @Author iKrypto
-- @Description Entities Page FSM managing entity display, selection, and metadata.
-- Migrated from legacy EntitiesPage.luau controller pattern.

local BasePageFSM = require(script.Parent.BasePageFSM)

local EntitiesPageFSM = BasePageFSM.Extend({
	className = "EntitiesPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ShowingDetails", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 10
})

--[[
	@description Registers states for the entities page FSM.
	@return ()
]]
--[[
	@description Registers base lifecycle states for entity listing.
]]
function EntitiesPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("ShowingDetails", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity
			fsm:Log({ Level = "DEBUG", Message = string.format("Showing details for entity: %s", tostring(entity.SelectedEntity)) })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

--[[
	@description Creates a labeled section frame with a scrollable list.
	@param name string
	@param titleText string
	@param color Color3
	@param parent Instance
	@return Instance
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
	@description Hook for initializing entities UI elements.
	@param entity any
	@return ()
]]
--[[
	@description Initializes the Entities Page UI elements.
	@param entity any -- The EntitiesPageEntity instance.
]]
function EntitiesPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing Entities Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "Entities container not found" })
		return
	end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local view = container.Parent
	
	if not view then return end
	
	-- Create toolbar if not exists
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
	
	-- Create search box
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
		local padding = Instance.new("UIPadding", search)
		padding.PaddingLeft = UDim.new(0, 8)
		
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
	
	-- Show Archived button
	local showArchivedBtn = toolbar:FindFirstChild("ShowArchivedBtn")
	if not showArchivedBtn then
		showArchivedBtn = Instance.new("TextButton")
		showArchivedBtn.Name = "ShowArchivedBtn"
		showArchivedBtn.Size = UDim2.new(0, 90, 1, 0)
		showArchivedBtn.Text = "SHOW ENDED"
		showArchivedBtn.TextColor3 = Color3.new(1, 1, 1)
		showArchivedBtn.BackgroundColor3 = entity.ShowArchived and (colors.Accent or Color3.fromRGB(0, 200, 255)) or (colors.DarkBG or Color3.fromRGB(40, 40, 40))
		showArchivedBtn.Font = Enum.Font.GothamBold
		showArchivedBtn.TextSize = 10
		showArchivedBtn.BorderSizePixel = 0
		showArchivedBtn.Parent = toolbar
		
		Instance.new("UICorner", showArchivedBtn).CornerRadius = UDim.new(0, 4)
		
		entity:Manage(showArchivedBtn.MouseButton1Click:Connect(function()
			entity:ToggleShowArchived()
			showArchivedBtn.BackgroundColor3 = entity.ShowArchived and (colors.Accent or Color3.fromRGB(0, 200, 255)) or (colors.DarkBG or Color3.fromRGB(40, 40, 40))
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
			serviceManager.ArchivedEntities = {}
			entity.SelectedEntity = nil
			entity:UpdateEntity()
			self:RequestRender()
			if serviceManager.Toast then
				serviceManager:Toast("Cleared Ended Entities", "Success")
			end
		end))
	end
	
	-- Adjust container position
	local containerAny = container :: any
	containerAny.Size = UDim2.new(1, 0, 1, -40)
	containerAny.Position = UDim2.new(0, 0, 0, 40)
	
	-- Ensure EntityList container
	local entityList = container:FindFirstChild("EntityList")
	if not entityList then
		entityList = Instance.new("Frame")
		entityList.Name = "EntityList"
		entityList.Size = UDim2.new(0.65, -5, 1, 0)
		entityList.BackgroundTransparency = 1
		entityList.Parent = container
	end
	entity.EntityList = entityList
	
	-- Ensure Metadata panel
	local metadataPanel = container:FindFirstChild("EntityMetadata")
	if not metadataPanel then
		metadataPanel = Instance.new("ScrollingFrame")
		metadataPanel.Name = "EntityMetadata"
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
	local activeSection = entityList:FindFirstChild("ActiveSection")
	if not activeSection then
		activeSection = createSection("ActiveSection", "ACTIVE ENTITIES", colors.Success or Color3.fromRGB(160, 255, 160), entityList)
	end
	entity.ActiveSection = activeSection
	
	local archivedSection = entityList:FindFirstChild("ArchivedSection")
	if not archivedSection then
		archivedSection = createSection("ArchivedSection", "ARCHIVED ENTITIES", colors.Default or Color3.fromRGB(220, 220, 220), entityList)
		archivedSection.Position = UDim2.new(0, 0, 0.5, 5)
		archivedSection.Visible = false
	end
	entity.ArchivedSection = archivedSection
	
	self:Log({ Level = "INFO", Message = "Entities Page UI initialized successfully" })
end

--[[
	@description Hook for fetching entity data.
	@param entity any
	@return ()
]]
function EntitiesPageFSM:OnFetchData(entity: any)
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local fsmService = serviceManager.Services and serviceManager.Services.FSM
	local entities = fsmService and fsmService.Entities or {}
	
	-- Build display list
	local displayList = {}
	for entityId, entityValue in pairs(entities) do
		if type(entityValue) == "boolean" and entityValue == true then
			displayList[tostring(entityId)] = { Name = tostring(entityId), IsArchived = false }
		else
			displayList[entityId] = entityValue
		end
	end
	
	if entity.ShowArchived then
		for entityId, entityValue in pairs(serviceManager.ArchivedEntities or {}) do
			if not displayList[entityId] then
				displayList[entityId] = entityValue
			end
		end
	end
	
	self.Context._entityList = displayList
	self:Log({ Level = "DEBUG", Message = string.format("Fetched %d entities", (function() local c=0 for _ in pairs(displayList) do c+=1 end return c end)()) })
end

--[[
	@description Hook for rendering entity cards and metadata panel.
	@param entity any
	@return ()
]]
function EntitiesPageFSM:OnRenderUI(entity: any)
	local activeSection = entity.ActiveSection
	local archivedSection = entity.ArchivedSection
	if not activeSection or not archivedSection then return end
	
	local activeList = activeSection:FindFirstChild("List")
	local archivedList = archivedSection:FindFirstChild("List")
	if not activeList or not archivedList then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local displayList = self.Context._entityList or {}
	
	-- Apply archived visibility
	if entity.ShowArchived then
		activeSection.Size = UDim2.new(1, 0, 0.5, -5)
		archivedSection.Visible = true
	else
		activeSection.Size = UDim2.new(1, 0, 1, 0)
		archivedSection.Visible = false
	end
	
	-- Sort entities
	local sorted = {}
	for entityId, entityValue in pairs(displayList) do
		table.insert(sorted, { Id = entityId, Entity = entityValue })
	end
	table.sort(sorted, function(a, b)
		return tostring(a.Entity.Name or a.Id) < tostring(b.Entity.Name or b.Id)
	end)
	
	-- Filter by search
	local searchText = entity.Search or ""
	local filtered = {}
	for _, item in ipairs(sorted) do
		local entityName = tostring(item.Entity.Name or item.Id)
		if searchText == "" or entityName:lower():find(searchText:lower(), 1, true) then
			table.insert(filtered, item)
		end
	end
	
	-- Pagination
	local pageSize = entity.PageSize or 10
	local maxPage = math.ceil(#filtered / pageSize)
	if maxPage == 0 then maxPage = 1 end
	if entity.Page > maxPage then entity.Page = maxPage end
	
	local startIndex = (entity.Page - 1) * pageSize + 1
	local endIndex = startIndex + pageSize - 1
	
	-- Clear old cards not in current page
	for _, child in ipairs(activeList:GetChildren()) do
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
		
		local entityId = item.Id
		local entityData = item.Entity
		local entityName = entityData.Name or entityId
		local isArchived = entityData.IsArchived == true
		local targetList = isArchived and archivedList or activeList
		
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
		cardAny.Name = entityId
		cardAny.Parent = targetList
		cardAny.Visible = true
		
		-- Update card label
		local label = cardAny:FindFirstChildWhichIsA("TextLabel")
		if label then
			label.Text = entityName
			label.Size = UDim2.new(1, -10, 0.6, 0)
			label.Position = UDim2.new(0, 5, 0, 0)
			label.TextTruncate = Enum.TextTruncate.AtEnd
		else
			cardAny.Text = entityName
		end
		
		-- Status indicator
		local info = cardAny:FindFirstChild("Info")
		if not info then
			info = Instance.new("TextLabel", card)
			info.Name = "Info"
			info.Size = UDim2.new(1, -10, 0.4, 0)
			info.Position = UDim2.new(0, 5, 0.6, 0)
			info.BackgroundTransparency = 1
			info.TextXAlignment = Enum.TextXAlignment.Left
			info.TextSize = 10
			info.Font = Enum.Font.Gotham
		end
		info.TextColor3 = isArchived and (colors.Error or Color3.fromRGB(255, 120, 120)) or Color3.fromRGB(150, 150, 150)
		info.Text = isArchived and "ARCHIVED" or "ACTIVE"
		
		-- Click handler
		entity:Manage(cardAny.MouseButton1Click:Connect(function()
			entity:SelectEntity(entityId)
			entity:UpdateEntity()
			self:RenderMetadataPanel(entity)
		end))
	end
	
	-- Render metadata if entity selected
	if entity.SelectedEntity then
		self:RenderMetadataPanel(entity)
	end
	
	self:Log({ Level = "DEBUG", Message = string.format("Rendered %d entity cards", math.min(#filtered, pageSize)) })
end

--[[
	@description Renders the metadata panel for the selected entity.
	@param entity any
	@return ()
]]
function EntitiesPageFSM:RenderMetadataPanel(entity: any)
	local metadataPanel = entity.MetadataPanel
	if not metadataPanel then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local displayList = self.Context._entityList or {}
	
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
	
	if not entity.SelectedEntity then return end
	
	local entityData = displayList[entity.SelectedEntity]
	local isArchived = entityData and entityData.IsArchived == true
	
	if not entityData then
		-- Check archived
		entityData = serviceManager.ArchivedEntities and serviceManager.ArchivedEntities[entity.SelectedEntity]
		isArchived = true
	end
	
	if not entityData then
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
	
	if type(entityData) == "table" then
		addProp("Name", entityData.Name or "Unknown")
		addProp("OwnerId", entityData.OwnerId or "None")
		addProp("IsValid", tostring(entityData.IsValid))
		addProp("Status", isArchived and "ARCHIVED" or "ACTIVE")
		
		-- Show data properties
		local data = entityData._privateProperties and entityData._privateProperties.Data or entityData.Data
		if data then
			for dataKey, dataValue in pairs(data) do
				addProp("Data." .. tostring(dataKey), dataValue)
			end
		end
	end
	
	-- Create CLEAR button for archived entities
	if isArchived and container then
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
		
		local clearBtn = Instance.new("TextButton", actionsPanel)
		clearBtn.Text = "CLEAR"
		clearBtn.Size = UDim2.new(0, 60, 0, 30)
		clearBtn.BackgroundColor3 = colors.Error or Color3.fromRGB(255, 120, 120)
		clearBtn.TextColor3 = Color3.new(1, 1, 1)
		clearBtn.Font = Enum.Font.GothamBold
		clearBtn.TextSize = 12
		
		Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 4)
		
		entity:Manage(clearBtn.MouseButton1Click:Connect(function()
			serviceManager.ArchivedEntities[entity.SelectedEntity] = nil
			entity:ClearSelection()
			entity:UpdateEntity()
			self:RequestRender()
			if serviceManager.Toast then
				serviceManager:Toast("Cleared Entity: " .. entity.SelectedEntity, "Success")
			end
		end))
	end
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function EntitiesPageFSM:RequestRender()
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
function EntitiesPageFSM:OnCleanup()
	self.Context._entityList = nil
	BasePageFSM.OnCleanup(self)
end

return EntitiesPageFSM
