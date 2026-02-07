--!strict
-- @Name VisualizePageFSM
-- @Author iKrypto
-- @Description Visualize Page FSM managing force-directed graph display of FSMs.
-- Migrated from legacy VisualizePage.luau controller pattern.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")

local BasePageFSM = require(script.Parent.BasePageFSM)

local VisualizePageFSM = BasePageFSM.Extend({
	className = "VisualizePageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"Simulating", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 9
})

-- Physics Constants
local NODE_RADIUS = 30
local REPULSION_FORCE = 40000
local SPRING_LENGTH = 120
local SPRING_STIFFNESS = 0.08
local DAMPING = 0.60
local CENTER_GRAVITY = 0.02
local MAX_VELOCITY = 200
local MIN_ENERGY = 0.2

--[[
	@description Registers states for the visualize page FSM.
	@return ()
]]
function VisualizePageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("Simulating", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Simulation running..." })
		end
	})
end

--[[
	@description Converts world-space position to screen-space UDim2.
	@param entity any
	@param pos Vector2
	@return UDim2
]]
local function worldToScreen(entity: any, pos: Vector2): UDim2
	local scaled = (pos * entity.Zoom) + entity.Pan
	return UDim2.fromOffset(scaled.X, scaled.Y)
end

--[[
	@description Performs one physics simulation step.
	@param entity any
	@param dt number
	@return ()
]]
local function stepPhysics(entity: any, dt: number)
	-- 1. Apply Forces
	for id, node in pairs(entity.Nodes) do
		if node.IsDragging then
			node.Velocity = Vector2.zero
			continue
		end
		
		local force = Vector2.zero
		
		-- Repulsion (all nodes repel)
		for otherId, otherNode in pairs(entity.Nodes) do
			if id ~= otherId then
				local diff = node.Position - otherNode.Position
				local dist = diff.Magnitude
				local effectiveDist = math.max(dist, 50)
				local direction = (dist > 0.01) and diff.Unit or Vector2.new(math.random()-0.5, math.random()-0.5).Unit
				
				local magnitude = REPULSION_FORCE / (effectiveDist * effectiveDist)
				force += direction * magnitude
			end
		end
		
		-- Center Gravity
		local distToCenter = -node.Position
		force += distToCenter * CENTER_GRAVITY
		
		-- Cap Max Force
		if force.Magnitude > 1000 then
			force = force.Unit * 1000
		end
		
		node.Force = force
	end
	
	-- Attraction (Springs)
	for _, edge in ipairs(entity.Edges) do
		local u = entity.Nodes[edge.Source]
		local v = entity.Nodes[edge.Target]
		if u and v then
			local diff = v.Position - u.Position
			local dist = diff.Magnitude
			if dist > 0.01 then
				local displacement = dist - SPRING_LENGTH
				local springForce = diff.Unit * (displacement * SPRING_STIFFNESS)
				
				if not u.IsDragging then u.Force += springForce end
				if not v.IsDragging then v.Force -= springForce end
			end
		end
	end
	
	-- 2. Integration
	local totalEnergy = 0
	for _, node in pairs(entity.Nodes) do
		if node.IsDragging then continue end
		
		node.Velocity = (node.Velocity + node.Force * dt) * DAMPING
		
		if node.Velocity.Magnitude > MAX_VELOCITY then
			node.Velocity = node.Velocity.Unit * MAX_VELOCITY
		end
		
		node.Position += node.Velocity
		totalEnergy += node.Velocity.Magnitude
	end
	
	-- Sleep condition
	if totalEnergy < MIN_ENERGY and entity.Alpha < 0.01 then
		entity.Running = false
	end
	entity.Alpha = math.max(0, entity.Alpha - dt * 0.5)
end

--[[
	@description Hook for initializing visualize UI elements.
	@param entity any
	@return ()
]]
function VisualizePageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing Visualize Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "Visualize container not found" })
		return
	end
	
	local colors = self.Context.COLORS or {}
	local view = container.Parent
	
	if not view then return end
	
	-- Ensure sidebar FSM list
	local listFrame = view:FindFirstChild("StateMachineList")
	if not listFrame then
		container.Size = UDim2.new(1, -150, 1, 0)
		container.Position = UDim2.new(0, 150, 0, 0)
		container.ClipsDescendants = true
		container.BackgroundTransparency = 1
		
		listFrame = Instance.new("ScrollingFrame")
		listFrame.Name = "StateMachineList"
		listFrame.Size = UDim2.new(0, 145, 1, -35)
		listFrame.BackgroundTransparency = 1
		listFrame.ScrollBarThickness = 4
		listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
		listFrame.Parent = view
		
		local layout = Instance.new("UIListLayout", listFrame)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 2)
		
		-- Search box
		local search = Instance.new("TextBox")
		search.Name = "Search"
		search.Size = UDim2.new(0, 145, 0, 25)
		search.Position = UDim2.new(0, 0, 1, -30)
		search.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		search.TextColor3 = Color3.new(1, 1, 1)
		search.PlaceholderText = "Search..."
		search.Font = Enum.Font.Gotham
		search.TextSize = 12
		search.Parent = view
		Instance.new("UICorner", search).CornerRadius = UDim.new(0, 4)
		
		entity:Manage(search:GetPropertyChangedSignal("Text"):Connect(function()
			local term = search.Text:lower()
			for _, btn in ipairs(listFrame:GetChildren()) do
				if btn:IsA("TextButton") then
					btn.Visible = (term == "") or btn.Text:lower():find(term, 1, true)
				end
			end
		end))
	end
	entity.StateMachineList = listFrame
	
	-- Ensure world frame
	local world = container:FindFirstChild("World")
	if not world then
		world = Instance.new("Frame")
		world.Name = "World"
		world.Size = UDim2.fromScale(1, 1)
		world.BackgroundTransparency = 1
		world.ClipsDescendants = false
		world.Parent = container
	end
	entity.World = world
	
	-- Hook input handlers
	self:HookInput(entity)
	
	-- Start render loop
	self:StartRenderLoop(entity)
	
	self:Log({ Level = "INFO", Message = "Visualize Page UI initialized successfully" })
end

--[[
	@description Hooks input handlers for pan, zoom, and node dragging.
	@param entity any
	@return ()
]]
function VisualizePageFSM:HookInput(entity: any)
	local container = entity.Container
	if not container then return end
	
	local colors = self.Context.COLORS or {}
	local dragStart = Vector2.zero
	local panStart = Vector2.zero
	local isPanning = false
	
	entity:Manage(container.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.MouseButton3 then
			isPanning = true
			dragStart = UserInputService:GetMouseLocation()
			panStart = entity.Pan
		end
		if input.KeyCode == Enum.KeyCode.R then
			entity.Pan = Vector2.zero
			entity.Zoom = 1
		end
	end))
	
	entity:Manage(UserInputService.InputChanged:Connect(function(input)
		if isPanning and input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = UserInputService:GetMouseLocation() - dragStart
			entity.Pan = panStart + delta
		elseif input.UserInputType == Enum.UserInputType.MouseWheel then
			local zoomSpeed = 0.1
			entity.Zoom = math.clamp(entity.Zoom + (input.Position.Z * zoomSpeed), 0.2, 3)
		end
		
		-- Node Dragging
		for _, node in pairs(entity.Nodes) do
			if node.IsDragging then
				local mouse = UserInputService:GetMouseLocation()
				local centerScreen = container.AbsoluteSize / 2
				local globalOffset = Vector2.new(centerScreen.X, centerScreen.Y) + container.AbsolutePosition
				
				local targetPos = (mouse - entity.Pan - globalOffset) / entity.Zoom
				node.Position = targetPos
				node.Velocity = Vector2.zero
			end
		end
	end))
	
	entity:Manage(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.MouseButton3 then
			isPanning = false
		end
	end))
end

--[[
	@description Starts the render loop for physics and graph updates.
	@param entity any
	@return ()
]]
function VisualizePageFSM:StartRenderLoop(entity: any)
	local serviceManager = self.Context.ServiceManager
	
	if entity._renderConnection then
		entity._renderConnection:Disconnect()
	end
	
	entity._renderConnection = RunService.RenderStepped:Connect(function(dt)
		if serviceManager.ActivePage ~= "Visualize" then return end
		
		if entity.Running or entity.Alpha > 0 then
			stepPhysics(entity, math.min(dt, 0.1))
		end
		self:UpdateRender(entity)
	end)
	
	entity:Manage(entity._renderConnection)
end

--[[
	@description Updates visual positions of nodes and edges.
	@param entity any
	@return ()
]]
function VisualizePageFSM:UpdateRender(entity: any)
	local container = entity.Container
	if not container then return end
	
	local centerScreen = container.AbsoluteSize / 2
	local globalOffset = Vector2.new(centerScreen.X, centerScreen.Y)
	
	for _, node in pairs(entity.Nodes) do
		if node.Frame then
			local pos = worldToScreen(entity, node.Position)
			node.Frame.Position = UDim2.fromOffset(pos.X.Offset + globalOffset.X, pos.Y.Offset + globalOffset.Y)
		end
	end
	
	for _, edge in ipairs(entity.Edges) do
		if edge.Frame then
			local u = entity.Nodes[edge.Source]
			local v = entity.Nodes[edge.Target]
			if u and v then
				local p1 = (u.Position * entity.Zoom) + entity.Pan + globalOffset
				local p2 = (v.Position * entity.Zoom) + entity.Pan + globalOffset
				
				local diff = p2 - p1
				local dist = diff.Magnitude
				local mid = (p1 + p2) / 2
				local angle = math.atan2(diff.Y, diff.X) * (180 / math.pi)
				
				edge.Frame.Size = UDim2.new(0, dist, 0, 2)
				edge.Frame.Position = UDim2.fromOffset(mid.X, mid.Y)
				edge.Frame.Rotation = angle
				edge.Frame.Visible = true
			end
		end
	end
end

--[[
	@description Hook for fetching FSM data.
	@param entity any
	@return ()
]]
function VisualizePageFSM:OnFetchData(entity: any)
	local serviceManager = self.Context.ServiceManager
	if not serviceManager then return end
	
	local fsms = {}
	local fsmService = serviceManager.Services and serviceManager.Services.FSM
	if fsmService and fsmService.StateMachines then
		for id, data in pairs(fsmService.StateMachines) do fsms[id] = data end
	end
	for id, data in pairs(serviceManager.ArchivedFSMs or {}) do fsms[id] = data end
	
	self.Context._fsms = fsms
	self:Log({ Level = "DEBUG", Message = string.format("Fetched %d FSMs for visualization", 0) })
end

--[[
	@description Hook for rendering visualize UI.
	@param entity any
	@return ()
]]
function VisualizePageFSM:OnRenderUI(entity: any)
	-- Update FSM sidebar list
	self:RenderFSMList(entity)
	
	-- Update node highlights if graph exists
	if entity.SelectedID and self.Context._fsms then
		local fsmData = self.Context._fsms[entity.SelectedID]
		if fsmData then
			self:UpdateNodeHighlights(entity, fsmData.State)
		end
	end
end

--[[
	@description Renders the FSM sidebar list.
	@param entity any
	@return ()
]]
function VisualizePageFSM:RenderFSMList(entity: any)
	local listFrame = entity.StateMachineList
	if not listFrame then return end
	
	local colors = self.Context.COLORS or {}
	local fsms = self.Context._fsms or {}
	
	local sorted = {}
	for id, data in pairs(fsms) do
		table.insert(sorted, { Id = id, Name = data.Name or id })
	end
	table.sort(sorted, function(a, b) return a.Name < b.Name end)
	
	-- Diff against existing buttons
	local existing = {}
	for _, child in ipairs(listFrame:GetChildren()) do
		if child:IsA("TextButton") then existing[child.Name] = child end
	end
	
	for i, item in ipairs(sorted) do
		local btn = existing[item.Id]
		if not btn then
			btn = Instance.new("TextButton")
			btn.Name = item.Id
			btn.Text = item.Name
			btn.Size = UDim2.new(1, -5, 0, 25)
			btn.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.Font = Enum.Font.Gotham
			btn.TextSize = 11
			btn.Parent = listFrame
			Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
			
			entity:Manage(btn.MouseButton1Click:Connect(function()
				entity:SelectFSM(item.Id)
				self:BuildGraphData(entity, item.Id)
			end))
		end
		
		btn.BackgroundColor3 = (item.Id == entity.SelectedID) and (colors.Accent or Color3.fromRGB(0, 200, 255)) or (colors.DarkBG or Color3.fromRGB(40, 40, 40))
		btn.LayoutOrder = i
		existing[item.Id] = nil
	end
	
	-- Remove stale buttons
	for _, btn in pairs(existing) do btn:Destroy() end
end

--[[
	@description Builds graph data from FSM topology.
	@param entity any
	@param fsmId string
	@return boolean
]]
function VisualizePageFSM:BuildGraphData(entity: any, fsmId: string)
	local fsms = self.Context._fsms or {}
	local fsmData = fsms[fsmId]
	if not fsmData then return false end
	
	local colors = self.Context.COLORS or {}
	
	-- Extract transitions
	local transitionsData = (fsmData.Graph and fsmData.Graph.Transitions)
		or (fsmData.Graph and not fsmData.Graph.Transitions and fsmData.Graph)
		or fsmData._transitions
		or {}
	
	local rawState = fsmData.State
	local initialState = fsmData.InitialState
		or fsmData.initial
		or (fsmData.Graph and fsmData.Graph.InitialState)
		or (fsmData.Definition and fsmData.Definition.InitialState)
	
	local validStates = fsmData.ValidStates or (fsmData.Graph and fsmData.Graph.ValidStates) or {}
	
	-- Reset state
	entity.Nodes = {}
	entity.Edges = {}
	entity.Pan = Vector2.zero
	entity.Zoom = 1
	
	-- Clear world
	local world = entity.World
	if world then
		for _, child in ipairs(world:GetChildren()) do
			child:Destroy()
		end
	end
	
	-- Identify nodes and compute topology
	local nodeSet = {}
	local outDegree = {}
	local function addNode(n)
		if not n then return end
		local s = tostring(n)
		nodeSet[s] = true
		if not outDegree[s] then outDegree[s] = 0 end
	end
	
	addNode(rawState)
	if initialState then addNode(initialState) end
	
	for src, outs in pairs(transitionsData) do
		addNode(src)
		local srcName = tostring(src)
		
		if type(outs) == "table" then
			if #outs > 0 then
				for _, dst in ipairs(outs) do
					addNode(dst)
					outDegree[srcName] += 1
				end
			else
				for k, v in pairs(outs) do
					local dst = type(v) == "string" and v or k
					addNode(dst)
					outDegree[srcName] += 1
				end
			end
		else
			addNode(outs)
			outDegree[srcName] += 1
		end
	end
	
	if type(validStates) == "table" then
		for k, v in pairs(validStates) do
			addNode(type(k) == "number" and v or k)
		end
	end
	
	-- Create nodes
	local count = 0
	for _ in pairs(nodeSet) do count += 1 end
	local radius = math.sqrt(count) * 80
	
	for id in pairs(nodeSet) do
		local angle = math.random() * math.pi * 2
		local dist = math.random() * radius
		local pos = Vector2.new(math.cos(angle) * dist, math.sin(angle) * dist)
		
		local frame = Instance.new("Frame")
		frame.Name = "Node_" .. id
		frame.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
		frame.Parent = world
		
		Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)
		
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = colors.Stroke or Color3.fromRGB(80, 80, 80)
		stroke.Transparency = 0.5
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = frame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -20, 1, 0)
		label.Position = UDim2.fromOffset(10, 0)
		label.BackgroundTransparency = 1
		label.Text = id
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 12
		label.Parent = frame
		
		local txtSize = TextService:GetTextSize(id, 12, Enum.Font.GothamBold, Vector2.new(1000, 30))
		frame.Size = UDim2.fromOffset(math.max(60, txtSize.X + 24), 32)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		
		-- Initial state badge
		if tostring(initialState) == id then
			local badge = Instance.new("Frame")
			badge.Name = "StartBadge"
			badge.Size = UDim2.fromOffset(14, 14)
			badge.Position = UDim2.new(0, -6, 0, -6)
			badge.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
			badge.Parent = frame
			Instance.new("UICorner", badge).CornerRadius = UDim.new(1, 0)
			Instance.new("UIStroke", badge).Color = Color3.new(0, 0, 0)
			
			local icon = Instance.new("TextLabel", badge)
			icon.Size = UDim2.fromScale(1, 1)
			icon.BackgroundTransparency = 1
			icon.Text = "S"
			icon.TextColor3 = Color3.new(0, 0, 0)
			icon.Font = Enum.Font.GothamBold
			icon.TextSize = 9
		end
		
		-- Terminal state badge
		if (outDegree[id] or 0) == 0 then
			local badge = Instance.new("Frame")
			badge.Name = "EndBadge"
			badge.Size = UDim2.fromOffset(14, 14)
			badge.Position = UDim2.new(1, -8, 1, -8)
			badge.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
			badge.Parent = frame
			Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 3)
			Instance.new("UIStroke", badge).Color = Color3.new(0, 0, 0)
			
			local icon = Instance.new("TextLabel", badge)
			icon.Size = UDim2.fromScale(1, 1)
			icon.BackgroundTransparency = 1
			icon.Text = "E"
			icon.TextColor3 = Color3.new(0, 0, 0)
			icon.Font = Enum.Font.GothamBold
			icon.TextSize = 9
		end
		
		-- Drag handle
		local dragInput = Instance.new("TextButton")
		dragInput.Size = UDim2.fromScale(1, 1)
		dragInput.BackgroundTransparency = 1
		dragInput.Text = ""
		dragInput.Parent = frame
		
		local nodeObj = {
			Id = id,
			Text = id,
			Position = pos,
			Velocity = Vector2.zero,
			Force = Vector2.zero,
			IsDragging = false,
			Mass = 1,
			Neighbors = {},
			Frame = frame
		}
		
		entity:Manage(dragInput.MouseButton1Down:Connect(function()
			nodeObj.IsDragging = true
			entity.Running = true
			entity.Alpha = 1
		end))
		
		entity:Manage(dragInput.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				nodeObj.IsDragging = false
			end
		end))
		
		entity.Nodes[id] = nodeObj
	end
	
	-- Create edges
	local addedEdges = {}
	local function addEdge(src, dst)
		local key = src .. ">" .. dst
		if addedEdges[key] then return end
		if not entity.Nodes[src] or not entity.Nodes[dst] then return end
		
		addedEdges[key] = true
		
		local line = Instance.new("Frame")
		line.Name = key
		line.BackgroundColor3 = Color3.fromRGB(150, 150, 150)
		line.BorderSizePixel = 0
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.ZIndex = 0
		line.Parent = world
		
		local arrow = Instance.new("TextLabel", line)
		arrow.Name = "Arrow"
		arrow.BackgroundTransparency = 1
		arrow.Text = "►"
		arrow.TextColor3 = Color3.fromRGB(200, 200, 200)
		arrow.Size = UDim2.fromOffset(16, 16)
		arrow.AnchorPoint = Vector2.new(0.5, 0.5)
		arrow.Position = UDim2.new(0.65, 0, 0.5, 0)
		arrow.Font = Enum.Font.Gotham
		arrow.TextSize = 14
		
		table.insert(entity.Edges, { Source = src, Target = dst, Frame = line })
	end
	
	for src, outs in pairs(transitionsData) do
		if type(outs) == "table" then
			if #outs > 0 then
				for _, dst in ipairs(outs) do addEdge(tostring(src), tostring(dst)) end
			else
				for k, v in pairs(outs) do addEdge(tostring(src), tostring(type(v) == "string" and v or k)) end
			end
		else
			addEdge(tostring(src), tostring(outs))
		end
	end
	
	entity.Running = true
	entity.Alpha = 1
	
	self:UpdateNodeHighlights(entity, rawState)
	
	return true
end

--[[
	@description Updates node highlighting based on current FSM state.
	@param entity any
	@param currentState any
	@return ()
]]
function VisualizePageFSM:UpdateNodeHighlights(entity: any, currentState: any)
	local colors = self.Context.COLORS or {}
	local currentName = tostring(currentState)
	
	for id, node in pairs(entity.Nodes) do
		if node.Frame then
			local stroke = node.Frame:FindFirstChild("UIStroke")
			if stroke then
				if id == currentName then
					TweenService:Create(stroke, TweenInfo.new(0.3), {
						Color = colors.Accent or Color3.fromRGB(0, 200, 255),
						Thickness = 3,
						Transparency = 0
					}):Play()
					node.Frame.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
				else
					TweenService:Create(stroke, TweenInfo.new(0.3), {
						Color = colors.Stroke or Color3.fromRGB(80, 80, 80),
						Thickness = 2,
						Transparency = 0.5
					}):Play()
					node.Frame.BackgroundColor3 = colors.DarkBG or Color3.fromRGB(40, 40, 40)
				end
			end
		end
	end
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function VisualizePageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function VisualizePageFSM:OnCleanup()
	self.Context._fsms = nil
	BasePageFSM.OnCleanup(self)
end

return VisualizePageFSM
