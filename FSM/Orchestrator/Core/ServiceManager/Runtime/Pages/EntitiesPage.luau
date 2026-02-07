--!strict
--[[
	@Name EntitiesPage
	@Author iKrypto
	@Description Entities page controller. Displays active and archived entities
	with toolbar (search, show-ended, clear-ended), pagination, entity metadata
	panel, and action buttons.
	
	@deprecated This legacy controller is retained for regression testing only.
	Use the new FSM/Entity pattern: FSM/EntitiesPageFSM.luau + Entity/EntitiesPageEntity.luau
]]

export type Deps = {
	EnsureToolbar: (Instance) -> Instance,
	CreateSearchBox: (Instance, string?, (string) -> ()) -> Instance,
	CreateButton: (Instance, string, Color3, (() -> ())?, number?) -> Instance,
	EnsurePagination: (Instance, any, (() -> ())) -> Instance?,
	Create: (string, any) -> Instance,
	COLORS: { [string]: Color3 },
	TaskCardReference: Instance,
	TaskDataReference: Instance,
}

type Constants = {
	SelectedEntity: string?,
	Search: string,
	SortMode: string,
	ShowArchived: boolean,
	Page: number,
	PageSize: number,
}

local EntitiesPage = {}

--[[
	@description Factory that creates the Entities page with Active/Archived
	sections, paginated list, search, and metadata drill-down.
	@param ServiceManager any -- The root ServiceManager instance.
	@param deps Deps -- Injected dependencies.
	@return any -- A page table.
]]
function EntitiesPage.Create(ServiceManager: any, deps: Deps)
	local page: any = {
		Container = ServiceManager.GUI.BodyContainer:WaitForChild("EntitiesView"):WaitForChild("Container"),
		Tab = ServiceManager.GUI.TabContainer:WaitForChild("Entities"),
		Constants = ({ SelectedEntity = (nil :: string?), Search = "", SortMode = "Name", ShowArchived = false, Page = 1, PageSize = 10 } :: Constants),
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
		-- ONE-TIME UI SETUP
		-- --------------------------------------------------------------------------------
		if not view:FindFirstChild("Toolbar") then
			ServiceManager:ClearConnections(this.StableConnections)
			this.StableConnections = {}

			local toolbar = deps.EnsureToolbar(view)
			deps.CreateSearchBox(toolbar, this.Constants.Search, function(text)
				this.Constants.Search = text
				this.Constants.Page = 1
				this.UpdateFunction(this)
			end)

			local showArchivedBtn = deps.CreateButton(toolbar, "SHOW ENDED", this.Constants.ShowArchived and deps.COLORS.Accent or deps.COLORS.DarkBG, nil, 90)
			local showArchivedBtnAny = showArchivedBtn :: any
			local showArchivedConn = (showArchivedBtn :: any).MouseButton1Click:Connect(function()
				this.Constants.ShowArchived = not this.Constants.ShowArchived
				showArchivedBtnAny.BackgroundColor3 = this.Constants.ShowArchived and deps.COLORS.Accent or deps.COLORS.DarkBG

				local activeSection = (this.Container :: any).EntityList:FindFirstChild("ActiveSection")
				local archivedSection = (this.Container :: any).EntityList:FindFirstChild("ArchivedSection")
				if activeSection and archivedSection then
					local activeSectionAny = activeSection :: any
					local archivedSectionAny = archivedSection :: any
					
					if this.Constants.ShowArchived then
						activeSectionAny.Size = UDim2.new(1, 0, 0.5, -5)
						archivedSectionAny.Visible = true
					else
						activeSectionAny.Size = UDim2.new(1, 0, 1, 0)
						archivedSectionAny.Visible = false
					end
				end
				this.Constants.Page = 1
				this.UpdateFunction(this)
			end)
			table.insert(this.StableConnections, showArchivedConn)
			table.insert(this.Connections, showArchivedConn)

			deps.CreateButton(toolbar, "CLEAR ENDED", deps.COLORS.DarkBG, function()
				ServiceManager.ArchivedEntities = {}
				this.UpdateFunction(this)
				this:Toast("Cleared Ended Entities", "Success")
			end, 90)

			-- Adjust Container size
			local containerAny = this.Container :: any
			containerAny.Size = UDim2.new(1, 0, 1, -40)
			containerAny.Position = UDim2.new(0, 0, 0, 40)

			deps.EnsurePagination(view, this.Constants, function()
				this.UpdateFunction(this)
			end)
		end

		-- Ensure EntityList Container Exists
		local entityList = (this.Container :: any):FindFirstChild("EntityList")
		if not entityList then
			entityList = deps.Create("Frame", {
				Name = "EntityList",
				Size = UDim2.new(1, 0, 1, -50),
				Position = UDim2.new(0, 0, 0, 50),
				BackgroundTransparency = 1,
				Parent = this.Container,
			})
		end

		-- Ensure Sections Exist
		--[[
			@description Creates a labeled section frame with a scrollable list.
			@param name string -- Section frame name.
			@param titleText string -- Section heading text.
			@param color Color3 -- Heading text color.
			@param parent Instance -- Parent container.
			@return Instance -- The created section Frame.
		]]
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

		local activeSection = (entityList :: any):FindFirstChild("ActiveSection") or createSection("ActiveSection", "ACTIVE ENTITIES", deps.COLORS.Success, entityList)
		local archivedSection = (entityList :: any):FindFirstChild("ArchivedSection") or createSection("ArchivedSection", "ARCHIVED ENTITIES", deps.COLORS.Default, entityList)

		-- Apply Visibility
		local activeSectionAny = activeSection :: any
		local archivedSectionAny = archivedSection :: any

		if this.Constants.ShowArchived then
			activeSectionAny.Size = UDim2.new(1, 0, 0.5, -5)
			archivedSectionAny.Visible = true
		else
			activeSectionAny.Size = UDim2.new(1, 0, 1, 0)
			archivedSectionAny.Visible = false
		end

		-- --------------------------------------------------------------------------------
		-- HELPERS
		-- --------------------------------------------------------------------------------
		--[[
			@description Clears the EntityMetadata panel and destroys the ActionsPanel.
			@return ()
		]]
		local function clearMetadataPanel()
			ServiceManager:ClearConnections(this.DynamicConnections)
			this.DynamicConnections = {}

			for _, child in next, (this.Container :: any).EntityMetadata:GetChildren() do
				if child:IsA("Frame") or child:IsA("TextLabel") then
					child:Destroy()
				end
			end
			if (this.Container :: any):FindFirstChild("ActionsPanel") then
				local actionsPanel = (this.Container :: any).ActionsPanel
				actionsPanel:Destroy()
			end
		end

		--[[
			@description Creates an action button in the ActionsPanel for entity metadata.
			@param name string -- Button label.
			@param color Color3 -- Button background color.
			@param order number -- LayoutOrder.
			@param callback () -> () -- Click callback.
			@return ()
		]]
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

		--[[
			@description Attaches click handler to an entity card for selection.
			Guards against double-hooking with an IsHooked marker.
			@param card any -- The card Instance.
			@param entityId string -- The entity identifier.
			@return ()
		]]
		local function hookEntityCard(card: any, entityId: string)
			if card:FindFirstChild("IsHooked") then return end
			local hookMarker = Instance.new("BoolValue")
			hookMarker.Name = "IsHooked"
			hookMarker.Parent = card
			local cardAny = card :: any
			local conn = cardAny.MouseButton1Click:Connect(function()
				clearMetadataPanel()
				constants.SelectedEntity = entityId
				this.UpdateFunction(this)
			end)
			table.insert(this.Connections, conn)
		end

		--[[
			@description Rebuilds the entity list across Active/Archived sections
			with search filtering and pagination.
			@return ()
		]]
		local function updateEntityList()
			local fsmService = ServiceManager.Services.FSM
			if not fsmService then return end
			local entities = (fsmService :: any).Entities or {}

			local displayList: any = {}
			for entityId, entityValue in pairs(entities) do
				if type(entityValue) == "boolean" and entityValue == true then
					displayList[tostring(entityId)] = { Name = tostring(entityId), IsArchived = false }
				else
					displayList[entityId] = entityValue
				end
			end
			if this.Constants.ShowArchived then
				for entityId, entityValue in pairs(ServiceManager.ArchivedEntities) do
					if not displayList[entityId] then
						displayList[entityId] = entityValue
					end
				end
			end

			local activeList = (activeSection :: any).List
			local archivedList = (archivedSection :: any).List

			-- Cleanup missing
			for _, child in next, activeList:GetChildren() do
				local v = displayList[child.Name]
				if child:IsA("TextButton") and (not v or (v :: any).IsArchived) then child:Destroy() end
			end
			for _, child in next, archivedList:GetChildren() do
				local v = displayList[child.Name]
				if child:IsA("TextButton") and (not v or not (v :: any).IsArchived) then child:Destroy() end
			end

			-- Sort
			local sorted: { any } = {}
			for entityId, entityValue in pairs(displayList) do
				table.insert(sorted, { Id = entityId, Entity = entityValue })
			end
			table.sort(sorted, function(a, b)
				return tostring((a.Entity :: any).Name) < tostring((b.Entity :: any).Name)
			end)

			-- Pagination
			local controls = view and view:FindFirstChild("Controls")
			local pageSize = this.Constants.PageSize or 10
			local filtered: { any } = {}
			for _, item in ipairs(sorted) do
				local entityName = tostring((item.Entity :: any).Name)
				if this.Constants.Search == "" or entityName:lower():find(tostring(this.Constants.Search):lower(), 1, true) then
					table.insert(filtered, item)
				end
			end

			local maxPage = math.ceil(#filtered / pageSize)
			if maxPage == 0 then maxPage = 1 end
			if this.Constants.Page > maxPage then this.Constants.Page = maxPage end
			if controls then
				(controls :: any).PageLabel.Text = string.format("%d / %d", this.Constants.Page, maxPage)
			end

			local startIndex = (this.Constants.Page - 1) * pageSize + 1
			local endIndex = startIndex + pageSize - 1

			for i = startIndex, endIndex do
				local item = filtered[i]
				if not item then break end
				local entityId, entity = item.Id, item.Entity
				local entityName = (entity :: any).Name

				local isArchived = (entity :: any).IsArchived == true
				local targetList = isArchived and archivedList or activeList

				local card = targetList:FindFirstChild(entityId)
				if not card then
					card = deps.TaskCardReference:Clone()
					local cardAny = card :: any
					local label = cardAny:FindFirstChildWhichIsA("TextLabel")
					local labelAny = label :: any
					labelAny.Text = entityName
					labelAny.Size = UDim2.new(1, -10, 0.6, 0)
					labelAny.TextTruncate = Enum.TextTruncate.AtEnd
					labelAny.Position = UDim2.new(0, 5, 0, 0)
					cardAny.Name = entityId
					cardAny.Parent = targetList
					cardAny.Visible = true
					if cardAny:FindFirstChild("StatusDot") then
						local statusDot = cardAny.StatusDot
						statusDot:Destroy()
					end

					local info = Instance.new("TextLabel", card)
					info.Size = UDim2.new(1, -10, 0.4, 0)
					info.Position = UDim2.new(0, 5, 0.6, 0)
					info.BackgroundTransparency = 1
					info.TextXAlignment = Enum.TextXAlignment.Left
					info.TextColor3 = isArchived and deps.COLORS.Error or Color3.fromRGB(150, 150, 150)
					info.TextTruncate = Enum.TextTruncate.AtEnd
					info.TextSize = 10
					info.Font = Enum.Font.Gotham
					info.Text = isArchived and "ARCHIVED" or "ACTIVE"
				end

				hookEntityCard(card, tostring(entityId))
			end
		end

		--[[
			@description Populates the metadata panel for the selected entity and
			creates a CLEAR action button if archived.
			@return ()
		]]
		local function updateSelectedEntityMetadata()
			local fsmService = ServiceManager.Services.FSM
			if not constants.SelectedEntity or not fsmService then return end
			local entityId = tostring(constants.SelectedEntity)
			local entities = (fsmService :: any).Entities or {}
			local isArchived = false
			local entityData: any = nil

			for entityKey, entityValue in pairs(entities) do
				if tostring(entityKey) == entityId then
					if type(entityValue) == "boolean" then
						entityData = entityKey
					else
						entityData = entityValue
					end
					break
				end
			end

			if not entityData then
				entityData = ServiceManager.ArchivedEntities[entityId]
				isArchived = true
			end

			if not entityData then
				constants.SelectedEntity = nil
				clearMetadataPanel()
				return
			end

			local container = (this.Container :: any).EntityMetadata
			--[[
				@description Adds or updates a key-value field in the entity metadata panel.
				@param key string -- The field name.
				@param value any -- The field value.
				@return ()
			]]
			local function addProp(key: string, value: any)
				local dataObject = container:FindFirstChild(key) or deps.TaskDataReference:Clone()
				dataObject.Name = key
				dataObject.Parent = container
				local dataObjectAny = dataObject :: any
				dataObjectAny.Visible = true
				if dataObjectAny:FindFirstChild("Title") then
					(dataObjectAny.Title :: any).Text = string.upper(key)
				end
				if dataObjectAny:FindFirstChild("Value") then
					(dataObjectAny.Value :: any).Text = string.format("<b><font color='#ffffff'>%s</font></b>", tostring(value))
				end
			end

			if type(entityData) == "table" or typeof(entityData) == "Instance" then
				addProp("Name", (entityData :: any).Name or "Unknown")
				addProp("OwnerId", (entityData :: any).OwnerId or "None")
				addProp("IsValid", tostring((entityData :: any).IsValid))

				if (entityData :: any)._privateProperties and (entityData :: any)._privateProperties.Data then
					for dataKey, dataValue in pairs((entityData :: any)._privateProperties.Data) do
						addProp("Data." .. tostring(dataKey), dataValue)
					end
				elseif (entityData :: any).Data then
					for dataKey, dataValue in pairs((entityData :: any).Data) do
						addProp("Data." .. tostring(dataKey), dataValue)
					end
				end
			end

			if isArchived and not (this.Container :: any):FindFirstChild("ActionsPanel") then
				createActionButton("CLEAR", deps.COLORS.Error, 1, function()
					ServiceManager.ArchivedEntities[entityId] = nil
					constants.SelectedEntity = nil
					clearMetadataPanel()
					this.UpdateFunction(this)
					this:Toast("Cleared Entity: " .. entityId, "Success")
				end)
			end
		end

		updateEntityList()
		updateSelectedEntityMetadata()
	end

	return page
end

return EntitiesPage