--!strict
-- @Name LogsPageFSM
-- @Author iKrypto (AI Assistant)
-- @Description Logs Page FSM managing log retrieval, filtering, and rendering.

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
	
	-- Setup Viewport and Content
	local viewport = container:FindFirstChild("Viewport")
	if not viewport then
		viewport = Instance.new("ScrollingFrame")
		viewport.Name = "Viewport"
		viewport.Parent = container
		viewport.Size = UDim2.new(1, -10, 1, -50) -- Room for toolbar
		viewport.Position = UDim2.new(0, 5, 0, 45)
		viewport.BackgroundTransparency = 1
		viewport.BorderSizePixel = 0
		viewport.ScrollBarThickness = 6
		viewport.CanvasSize = UDim2.new(0, 0, 0, 0)
		viewport.AutomaticCanvasSize = Enum.AutomaticSize.Y
		
		local listLayout = Instance.new("UIListLayout", viewport)
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
		listLayout.Padding = UDim.new(0, 2)
	end
	
	entity.Viewport = viewport
	entity.Content = viewport -- For logs, viewport IS the content container
	
	-- Setup Toolbar with filter buttons
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	
	if serviceManager and serviceManager.EnsureToolbar then
		local toolbar = serviceManager.EnsureToolbar(container)
		entity.Toolbar = toolbar
		
		-- Create filter buttons
		local filterLevels = { "DEBUG", "INFO", "WARN", "ERROR" }
		for i, level in ipairs(filterLevels) do
			local filterButton = Instance.new("TextButton")
			filterButton.Name = level .. "Filter"
			filterButton.Parent = toolbar
			filterButton.Size = UDim2.new(0, 60, 0, 28)
			filterButton.Position = UDim2.new(0, 10 + (i - 1) * 65, 0, 6)
			filterButton.Text = level
			filterButton.TextColor3 = colors.Default or Color3.fromRGB(255, 255, 255)
			filterButton.BackgroundColor3 = colors.Accent or Color3.fromRGB(0, 200, 255)
			filterButton.BackgroundTransparency = entity.Filters[level] and 0 or 0.5
			filterButton.Font = Enum.Font.GothamBold
			filterButton.TextSize = 12
			filterButton.BorderSizePixel = 0
			
			local uiCorner = Instance.new("UICorner", filterButton)
			uiCorner.CornerRadius = UDim.new(0, 4)
			
			entity.FilterButtons[level] = filterButton
			
			-- Hook click event
			entity:Manage(filterButton.MouseButton1Click:Connect(function()
				entity:ToggleFilter(level)
				entity:UpdateEntity()
				self:RequestRender()
			end))
		end
		
		-- Create Clear button
		local clearButton = Instance.new("TextButton")
		clearButton.Name = "ClearButton"
		clearButton.Parent = toolbar
		clearButton.Size = UDim2.new(0, 60, 0, 28)
		clearButton.Position = UDim2.new(1, -70, 0, 6)
		clearButton.Text = "CLEAR"
		clearButton.TextColor3 = colors.Default or Color3.fromRGB(255, 255, 255)
		clearButton.BackgroundColor3 = colors.Error or Color3.fromRGB(255, 59, 48)
		clearButton.Font = Enum.Font.GothamBold
		clearButton.TextSize = 12
		clearButton.BorderSizePixel = 0
		
		local uiCorner = Instance.new("UICorner", clearButton)
		uiCorner.CornerRadius = UDim.new(0, 4)
		
		entity.ClearButton = clearButton
		
		-- Hook clear event
		entity:Manage(clearButton.MouseButton1Click:Connect(function()
			if entity.Content then
				for _, child in ipairs(entity.Content:GetChildren()) do
					if child:IsA("Frame") or child:IsA("TextLabel") then
						child:Destroy()
					end
				end
			end
		end))
	end
	
	self:Log({ Level = "INFO", Message = "Logs Page UI initialized successfully" })
end

--[[
	@description Hook for fetching log data.
	@param entity any
	@return ()
]]
function LogsPageFSM:OnFetchData(entity: any)
	-- Fetch logs from Logger service or ServiceManager
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then
		return
	end
	
	-- Logs are typically fetched from a Logger service buffer
	-- For now, this is a placeholder - actual implementation would
	-- read from ServiceManager.Services.Logger or similar
	
	self:Log({ Level = "DEBUG", Message = "Fetching logs from service..." })
end

--[[
	@description Hook for rendering log entries.
	@param entity any
	@return ()
]]
function LogsPageFSM:OnRenderUI(entity: any)
	if not entity.Content then
		return
	end
	
	-- Get logs from ServiceManager
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then
		return
	end
	
	-- Clear existing log lines
	for _, child in ipairs(entity.Content:GetChildren()) do
		if child:IsA("Frame") and child.Name == "LogLine" then
			child:Destroy()
		end
	end
	
	-- Render filtered logs
	-- This is a placeholder - actual implementation would:
	-- 1. Get log buffer from Logger service
	-- 2. Filter by entity.Filters
	-- 3. Apply entity.Search
	-- 4. Clone LogLineReference and populate
	
	self:Log({ Level = "DEBUG", Message = "Rendering filtered logs..." })
end

--[[
	@description Cleanup handler.
	@return ()
]]
function LogsPageFSM:OnCleanup()
	self:Log({ Level = "INFO", Message = "LogsPageFSM cleanup complete" })
	BasePageFSM.OnCleanup(self)
end

return LogsPageFSM
