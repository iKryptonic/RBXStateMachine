--!strict
-- @Name LogsPageFSM
-- @Author iKrypto
-- @Description Logs Page FSM managing log retrieval, filtering, and rendering.
-- Migrated from legacy LogsPage.luau controller pattern.

local BasePageFSM = require(script.Parent.BasePageFSM)

local LogsPageFSM = BasePageFSM.Extend({
	className = "LogsPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"Filtering", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 6
})

--[[
	@description Normalizes heterogeneous log entry formats into a uniform
	{Type: number, Message: string, Time: number} array.
	@param raw any -- Raw log history array from the Logger.
	@return { {Type: number, Message: string, Time: number} }
]]
local function normalizeLogBuffer(raw: any): { { Type: number, Message: string, Time: number } }
	local buffer = {}
	for _, entry in ipairs(raw or {}) do
		if entry.Type and entry.Message then
			table.insert(buffer, entry)
		elseif entry.Level and entry.Message then
			local level = tostring(entry.Level)
			local levelNumber = (level == "ERROR" and 3) or (level == "WARN" and 2) or 1
			table.insert(buffer, {
				Type = levelNumber,
				Message = entry.Message,
				Time = entry.Timestamp or entry.Time or os.time(),
			})
		end
	end
	return buffer
end

--[[
	@description Escapes XML/HTML special characters for Roblox RichText rendering.
	@param text string -- Raw text to sanitize.
	@return string -- Escaped text safe for RichText labels.
]]
local function escapeRichText(text: string): string
	text = tostring(text)
	text = text:gsub("&", "&amp;")
	text = text:gsub("<", "&lt;")
	text = text:gsub(">", "&gt;")
	return text
end

--[[
	@description Registers states for the logs page FSM.
	@return ()
]]
function LogsPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	-- Add custom Filtering state
	self:AddState("Filtering", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Filtering logs..." })
			-- Transition to Rendering after filters are applied
			fsm:ChangeState({ Name = "Rendering" })
		end
	})
end

--[[
	@description Hook for initializing logs UI elements.
	@param entity any
	@return ()
]]
function LogsPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing Logs Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "Logs container not found" })
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
		
		-- Wire debounced search
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
	
	-- Create filter buttons
	local filterLevels = { { name = "INFO", level = 1, color = colors.Accent or Color3.fromRGB(0, 200, 255) }, 
	                       { name = "WARN", level = 2, color = colors.Warning or Color3.fromRGB(255, 220, 140) },
	                       { name = "ERROR", level = 3, color = colors.Error or Color3.fromRGB(255, 120, 120) } }
	
	for _, filter in ipairs(filterLevels) do
		local filterButton = toolbar:FindFirstChild(filter.name .. "Filter")
		if not filterButton then
			filterButton = Instance.new("TextButton")
			filterButton.Name = filter.name .. "Filter"
			filterButton.Parent = toolbar
			filterButton.Size = UDim2.new(0, 60, 1, 0)
			filterButton.Text = filter.name
			filterButton.TextColor3 = Color3.new(1, 1, 1)
			filterButton.BackgroundColor3 = filter.color
			filterButton.BackgroundTransparency = entity.Filters[filter.name] and 0 or 0.5
			filterButton.Font = Enum.Font.GothamBold
			filterButton.TextSize = 10
			filterButton.BorderSizePixel = 0
			
			Instance.new("UICorner", filterButton).CornerRadius = UDim.new(0, 4)
			
			entity.FilterButtons[filter.name] = filterButton
			
			-- Hook click event
			entity:Manage(filterButton.MouseButton1Click:Connect(function()
				entity:ToggleFilter(filter.name)
				filterButton.BackgroundTransparency = entity.Filters[filter.name] and 0 or 0.5
				entity:UpdateEntity()
				self:RequestRender()
			end))
		end
	end
	
	-- Create Clear button
	local clearButton = toolbar:FindFirstChild("ClearButton")
	if not clearButton then
		clearButton = Instance.new("TextButton")
		clearButton.Name = "ClearButton"
		clearButton.Parent = toolbar
		clearButton.Size = UDim2.new(0, 60, 1, 0)
		clearButton.Text = "CLEAR"
		clearButton.TextColor3 = Color3.new(1, 1, 1)
		clearButton.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
		clearButton.Font = Enum.Font.GothamBold
		clearButton.TextSize = 10
		clearButton.BorderSizePixel = 0
		
		Instance.new("UICorner", clearButton).CornerRadius = UDim.new(0, 4)
		
		entity.ClearButton = clearButton
		
		-- Hook clear event
		entity:Manage(clearButton.MouseButton1Click:Connect(function()
			if serviceManager.Mode == "server" then
				if serviceManager.ActiveService == "FSM" then
					if serviceManager.Orchestrator and serviceManager.Orchestrator.Request then
						serviceManager.Orchestrator.Request("ConsoleCommand", "clearlogs")
					end
				else
					local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
					if scheduler then
						scheduler:ConsoleCommand("clearlogs")
					end
				end
			else
				local service = serviceManager.Services and serviceManager.Services[serviceManager.ActiveService]
				if service and service.Logger then
					service.Logger.History = {}
				end
			end
			entity.LastBufferHash = ""
			entity:UpdateEntity()
			self:RequestRender()
			if serviceManager.Toast then
				serviceManager:Toast("Logs Cleared", "Success")
			end
		end))
	end
	
	-- Adjust container position for toolbar
	local containerAny = container :: any
	containerAny.Size = UDim2.new(1, -10, 1, -50)
	containerAny.Position = UDim2.new(0, 5, 0, 45)
	
	entity.Viewport = container
	entity.Content = container
	
	self:Log({ Level = "INFO", Message = "Logs Page UI initialized successfully" })
end

--[[
	@description Hook for fetching log data from service.
	@param entity any
	@return ()
]]
function LogsPageFSM:OnFetchData(entity: any)
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local buffer = {}
	local service = serviceManager.Services and serviceManager.Services[serviceManager.ActiveService]
	
	if serviceManager.ActiveService == "FSM" then
		if serviceManager.Mode == "server" then
			local raw = serviceManager.ServerData.FSM and serviceManager.ServerData.FSM.Logs and serviceManager.ServerData.FSM.Logs.History
			buffer = normalizeLogBuffer(raw)
		else
			local orchestrator = serviceManager.Orchestrator
			local raw = orchestrator and orchestrator.Logger and orchestrator.Logger.History
			buffer = normalizeLogBuffer(raw)
		end
	else
		-- Scheduler (or other non-FSM service)
		if serviceManager.Mode == "server" then
			local raw = serviceManager.ServerData.Scheduler and serviceManager.ServerData.Scheduler.Logger and serviceManager.ServerData.Scheduler.Logger.History
			buffer = normalizeLogBuffer(raw)
		else
			local logger = service and service.Logger
			if logger then
				buffer = normalizeLogBuffer(logger.History or logger.OutputBuffer)
			end
		end
	end
	
	-- Store buffer for rendering
	self.Context._logBuffer = buffer
	
	self:Log({ Level = "DEBUG", Message = string.format("Fetched %d log entries", #buffer) })
end

--[[
	@description Hook for rendering log entries with filtering.
	@param entity any
	@return ()
]]
function LogsPageFSM:OnRenderUI(entity: any)
	local container = entity.Content or entity.Container
	if not container then return end
	
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local buffer = self.Context._logBuffer or {}
	local searchText = entity.Search or ""
	
	-- Compute hash to avoid unnecessary re-renders
	local currentHash = tostring(#buffer) 
		.. tostring(buffer[1] and buffer[1].Time or 0) 
		.. tostring(searchText) 
		.. tostring(serviceManager.Mode) 
		.. tostring(serviceManager.ActiveService)
	
	if entity.LastBufferHash == currentHash then
		return
	end
	entity.LastBufferHash = currentHash
	
	-- Clear existing log lines
	for _, child in next, container:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	
	-- Get LogLineReference template
	local logLineRef = nil
	if serviceManager.GUI and serviceManager.GUI.References then
		logLineRef = serviceManager.GUI.References:FindFirstChild("LogLine")
	end
	
	-- Render filtered logs (reverse order - newest first)
	local renderedCount = 0
	for i = #buffer, 1, -1 do
		local log = buffer[i]
		
		-- Apply level filter
		local levelName = (log.Type == 1 and "INFO") or (log.Type == 2 and "WARN") or (log.Type == 3 and "ERROR") or "INFO"
		if entity.Filters[levelName] == false then
			continue
		end
		-- Legacy numeric filter support
		if entity.Filters[log.Type] == false then
			continue
		end
		
		-- Apply search filter
		if searchText ~= "" and not tostring(log.Message):lower():find(searchText:lower(), 1, true) then
			continue
		end
		
		-- Create log line
		local line
		if logLineRef then
			line = logLineRef:Clone()
		else
			line = Instance.new("TextLabel")
			line.Size = UDim2.new(1, 0, 0, 18)
			line.BackgroundTransparency = 1
			line.Font = Enum.Font.Code
			line.TextSize = 12
			line.TextXAlignment = Enum.TextXAlignment.Left
			line.RichText = true
		end
		
		local timeStr = os.date("%H:%M:%S", log.Time)
		local color = (log.Type == 1 and "#A0A0A0") or (log.Type == 2 and "#FFDC8C") or (log.Type == 3 and "#FF7878") or "#FFFFFF"
		local prefix = (log.Type == 1 and "[INFO]") or (log.Type == 2 and "[WARN]") or (log.Type == 3 and "[ERR]") or "[LOG]"
		
		local lineGui = line :: any
		lineGui.Text = string.format(
			"<font color='#555555'>%s</font> <font color='%s'><b>%s</b> %s</font>",
			timeStr,
			color,
			prefix,
			escapeRichText(tostring(log.Message))
		)
		lineGui.Visible = true
		lineGui.LayoutOrder = renderedCount
		line.Parent = container
		
		renderedCount += 1
	end
	
	-- Auto-scroll to bottom
	task.delay(0.05, function()
		if container and container:IsA("ScrollingFrame") then
			(container :: ScrollingFrame).CanvasPosition = Vector2.new(0, container.AbsoluteCanvasSize.Y)
		end
	end)
	
	self:Log({ Level = "DEBUG", Message = string.format("Rendered %d log entries", renderedCount) })
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function LogsPageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function LogsPageFSM:OnCleanup()
	self.Context._logBuffer = nil
	self:Log({ Level = "INFO", Message = "LogsPageFSM cleanup complete" })
	BasePageFSM.OnCleanup(self)
end

return LogsPageFSM
