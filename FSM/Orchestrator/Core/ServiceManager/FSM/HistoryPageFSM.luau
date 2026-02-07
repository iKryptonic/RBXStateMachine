--!strict
-- @Name HistoryPageFSM
-- @Author iKrypto
-- @Description History Page FSM managing execution history display and drill-down.
-- Migrated from legacy HistoryPage.luau controller pattern.

local BasePageFSM = require(script.Parent.BasePageFSM)

local HistoryPageFSM = BasePageFSM.Extend({
	className = "HistoryPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ShowingDetails", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 6
})

-- Sort modes
local SORT_MODES = { "Time", "Duration" }

--[[
	@description Registers states for the history page FSM.
	@return ()
]]
function HistoryPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("ShowingDetails", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity
			fsm:Log({ Level = "DEBUG", Message = string.format("Showing history details: %s", entity.SelectedEntry and entity.SelectedEntry.Name or "nil") })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

--[[
	@description Helper to escape rich text characters.
	@param str string
	@return string
]]
local function escapeRichText(str: string): string
	return str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

--[[
	@description Helper to format duration.
	@param duration number
	@return string
]]
local function formatDuration(duration: number): string
	if duration < 0.001 then
		return math.floor(duration * 1e6) .. "ns"
	else
		return math.floor(duration * 1e3) .. "ms"
	end
end

--[[
	@description Hook for initializing history UI elements.
	@param entity any
	@return ()
]]
function HistoryPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing History Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "History container not found" })
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
		search.PlaceholderText = "Search History..."
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
	
	-- Filter buttons
	local filterData = {
		{ name = "Completed", color = colors.Success or Color3.fromRGB(160, 255, 160) },
		{ name = "Failed", color = colors.Error or Color3.fromRGB(255, 120, 120) },
		{ name = "Cancelled", color = Color3.fromRGB(150, 150, 150) }
	}
	
	for _, filter in ipairs(filterData) do
		local filterBtn = toolbar:FindFirstChild(filter.name .. "Filter")
		if not filterBtn then
			filterBtn = Instance.new("TextButton")
			filterBtn.Name = filter.name .. "Filter"
			filterBtn.Size = UDim2.new(0, 70, 1, 0)
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
		sortBtn.Text = "SORT: " .. string.upper(entity.SortMode or "TIME")
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
	
	-- History list
	local historyList = container:FindFirstChild("HistoryList")
	if not historyList then
		historyList = Instance.new("ScrollingFrame")
		historyList.Name = "HistoryList"
		historyList.Size = UDim2.new(1, 0, 1, 0)
		historyList.BackgroundTransparency = 1
		historyList.ScrollBarThickness = 2
		historyList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		historyList.Parent = container
		
		local layout = Instance.new("UIListLayout", historyList)
		layout.Padding = UDim.new(0, 5)
		local padding = Instance.new("UIPadding", historyList)
		padding.PaddingLeft = UDim.new(0, 5)
	end
	entity.HistoryList = historyList
	
	-- Details panel (overlay)
	local details = view:FindFirstChild("Details")
	if not details then
		details = Instance.new("Frame", view)
		details.Name = "Details"
		details.Size = UDim2.new(1, 0, 1, -35)
		details.Position = UDim2.new(0, 0, 0, 35)
		details.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
		details.Visible = false
		
		Instance.new("UICorner", details).CornerRadius = UDim.new(0, 6)
		
		-- Back button
		local backBtn = Instance.new("TextButton", details)
		backBtn.Name = "Back"
		backBtn.Size = UDim2.new(0, 80, 0, 30)
		backBtn.Position = UDim2.new(0, 10, 0, 10)
		backBtn.Text = "← BACK"
		backBtn.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
		backBtn.TextColor3 = Color3.new(1, 1, 1)
		backBtn.Font = Enum.Font.GothamBold
		backBtn.TextSize = 11
		Instance.new("UICorner", backBtn).CornerRadius = UDim.new(0, 4)
		
		entity:Manage(backBtn.MouseButton1Click:Connect(function()
			entity:ClearSelection()
			entity:UpdateEntity()
			self:RequestRender()
		end))
		
		-- Content container
		local content = Instance.new("ScrollingFrame", details)
		content.Name = "Content"
		content.Size = UDim2.new(1, -20, 1, -50)
		content.Position = UDim2.new(0, 10, 0, 45)
		content.BackgroundTransparency = 1
		content.ScrollBarThickness = 2
		content.AutomaticCanvasSize = Enum.AutomaticSize.Y
		
		local layout = Instance.new("UIListLayout", content)
		layout.Padding = UDim.new(0, 5)
	end
	entity.Details = details
	entity.DetailsContent = details:FindFirstChild("Content")
	
	self:Log({ Level = "INFO", Message = "History Page UI initialized successfully" })
end

--[[
	@description Hook for fetching history data.
	@param entity any
	@return ()
]]
function HistoryPageFSM:OnFetchData(entity: any)
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local activeService = serviceManager.ActiveService
	local service = serviceManager.Services and serviceManager.Services[activeService]
	local history = service and service.History or {}
	
	self.Context._history = history
	self:Log({ Level = "DEBUG", Message = string.format("Fetched %d history entries", #history) })
end

--[[
	@description Hook for rendering history UI.
	@param entity any
	@return ()
]]
function HistoryPageFSM:OnRenderUI(entity: any)
	-- Check if showing details view
	if entity.SelectedEntry then
		self:RenderDetailsView(entity)
		return
	end
	
	-- Show list view
	self:RenderListView(entity)
end

--[[
	@description Renders the list view with paginated history entries.
	@param entity any
	@return ()
]]
function HistoryPageFSM:RenderListView(entity: any)
	local historyList = entity.HistoryList
	local container = entity.Container
	local details = entity.Details
	
	if not historyList then return end
	
	-- Show list, hide details
	if container then container.Visible = true end
	if details then details.Visible = false end
	
	local colors = self.Context.COLORS or {}
	local history = self.Context._history or {}
	local serviceManager = self.Context.ServiceManager
	
	-- Filter by status and search
	local filtered = {}
	local searchText = (entity.Search or ""):lower()
	
	for _, entry in ipairs(history) do
		local status = tostring(entry.Status)
		local name = tostring(entry.Name)
		
		-- Status filter
		if not entity.Filters[status] then continue end
		
		-- Search filter
		if searchText ~= "" and not name:lower():find(searchText, 1, true) then continue end
		
		table.insert(filtered, entry)
	end
	
	-- Sort
	table.sort(filtered, function(a, b)
		if entity.SortMode == "Duration" then
			return a.Duration > b.Duration
		else -- Time (default)
			return a.Time > b.Time
		end
	end)
	
	-- Pagination
	local pageSize = entity.PageSize or 8
	local maxPage = math.max(1, math.ceil(#filtered / pageSize))
	if entity.Page > maxPage then entity.Page = maxPage end
	if entity.Page < 1 then entity.Page = 1 end
	
	local startIndex = (entity.Page - 1) * pageSize + 1
	local endIndex = math.min(#filtered, startIndex + pageSize - 1)
	
	-- Clear old cards
	for _, child in ipairs(historyList:GetChildren()) do
		if child:IsA("TextButton") or child:IsA("Frame") then
			if child.Name ~= "UIListLayout" and child.Name ~= "UIPadding" then
				child:Destroy()
			end
		end
	end
	
	-- Render cards
	for i = startIndex, endIndex do
		local entry = filtered[i]
		if not entry then break end
		
		local status = tostring(entry.Status)
		local statusColor = (status == "Completed" and "#A0FFA0") or (status == "Failed" and "#FF7878") or "#CCCCCC"
		local timeStr = os.date("%H:%M:%S", entry.Time)
		local durStr = formatDuration(entry.Duration)
		
		local card = Instance.new("TextButton")
		card.Name = "HistoryEntry_" .. i
		card.Size = UDim2.new(1, -10, 0, 45)
		card.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
		card.Text = ""
		card.Parent = historyList
		
		Instance.new("UICorner", card).CornerRadius = UDim.new(0, 4)
		
		local label = Instance.new("TextLabel", card)
		label.Name = "Label"
		label.Size = UDim2.new(1, -20, 1, 0)
		label.Position = UDim2.new(0, 10, 0, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.Gotham
		label.TextSize = 11
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.RichText = true
		label.Text = string.format(
			"<b>%s</b> <font color='%s'>[%s]</font> <font color='#888888'>%s</font> (%s)",
			escapeRichText(tostring(entry.Name)),
			statusColor,
			escapeRichText(status:upper()),
			timeStr,
			durStr
		)
		
		entity:Manage(card.MouseButton1Click:Connect(function()
			entity:SelectEntry(entry)
			entity:UpdateEntity()
			self:RequestRender()
		end))
	end
	
	self:Log({ Level = "DEBUG", Message = string.format("Rendered %d history cards", endIndex - startIndex + 1) })
end

--[[
	@description Renders the details drill-down view.
	@param entity any
	@return ()
]]
function HistoryPageFSM:RenderDetailsView(entity: any)
	local container = entity.Container
	local details = entity.Details
	local content = entity.DetailsContent
	
	if not details or not content then return end
	
	-- Hide list, show details
	if container then container.Visible = false end
	details.Visible = true
	
	local colors = self.Context.COLORS or {}
	local entry = entity.SelectedEntry
	
	if not entry then return end
	
	-- Clear old content
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	
	-- Helper to add field row
	local function addField(title: string, value: any, hexColor: string?)
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 30)
		row.BackgroundTransparency = 1
		row.Parent = content
		
		local titleLabel = Instance.new("TextLabel", row)
		titleLabel.Name = "Title"
		titleLabel.Size = UDim2.new(0.3, 0, 1, 0)
		titleLabel.BackgroundTransparency = 1
		titleLabel.Text = title
		titleLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
		titleLabel.Font = Enum.Font.GothamBold
		titleLabel.TextSize = 11
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		
		local valueLabel = Instance.new("TextLabel", row)
		valueLabel.Name = "Value"
		valueLabel.Size = UDim2.new(0.7, 0, 1, 0)
		valueLabel.Position = UDim2.new(0.3, 0, 0, 0)
		valueLabel.BackgroundTransparency = 1
		valueLabel.Text = string.format("<b><font color='%s'>%s</font></b>", hexColor or "#ffffff", escapeRichText(tostring(value)))
		valueLabel.TextColor3 = Color3.new(1, 1, 1)
		valueLabel.Font = Enum.Font.Gotham
		valueLabel.TextSize = 11
		valueLabel.TextXAlignment = Enum.TextXAlignment.Left
		valueLabel.RichText = true
	end
	
	local status = tostring(entry.Status)
	local statusColor = (status == "Completed" and "#A0FFA0") or (status == "Failed" and "#FF7878") or "#CCCCCC"
	
	addField("TASK NAME", entry.Name)
	addField("STATUS", status:upper(), statusColor)
	addField("DURATION", formatDuration(entry.Duration))
	addField("TIMESTAMP", os.date("%c", entry.Time))
	
	if entry.Error and tostring(entry.Error) ~= "" then
		addField("ERROR OUTPUT", entry.Error, "#FF7878")
	end
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function HistoryPageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function HistoryPageFSM:OnCleanup()
	self.Context._history = nil
	BasePageFSM.OnCleanup(self)
end

return HistoryPageFSM
