--!strict
--[[
	@Name VisualizePage
	@Author iKrypto
	@Description Force-directed graph visualizer for FSMs. Implements physics-based
	layout (Coulomb repulsion + Hooke spring attraction), interactive panning/
	zooming, node dragging, sidebar FSM list, and live state highlighting.
	
	@deprecated This legacy controller is retained for regression testing only.
	Use the new FSM/Entity pattern: FSM/VisualizePageFSM.luau + Entity/VisualizePageEntity.luau
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

export type Ops = {
	COLORS: { [string]: Color3 },
}

-- -- Physics Types -- --

type Node = {
	Id: string,
	Text: string,
	Position: Vector2,
	Velocity: Vector2,
	Force: Vector2,
	IsDragging: boolean,
	Mass: number,
	Neighbors: { string }, -- List of connected Node Ids
	Frame: Frame?,
}

type Edge = {
	Source: string,
	Target: string,
	Frame: Frame?,
}

type GraphState = {
	Nodes: { [string]: Node },
	Edges: { Edge },
	Center: Vector2,
	Zoom: number,
	Pan: Vector2,
	-- Simulation
	Running: boolean,
	Alpha: number, -- Cooling factor
}

export type Page = {
	Container: Frame,
	Tab: GuiObject,
	State: GraphState,
	Constants: GraphState,
	Connections: { RBXScriptConnection },
	UpdateNodes: (any, any) -> (),
	UpdateFunction: (any) -> (),
	Cleanup: (any) -> (),
	SimConnection: RBXScriptConnection?,
}

-- -- Constants -- --
local NODE_RADIUS = 30 -- Visual radius (approx)
local REPULSION_FORCE = 40000 
local SPRING_LENGTH = 120
local SPRING_STIFFNESS = 0.08
local DAMPING = 0.60
local CENTER_GRAVITY = 0.02
local MAX_VELOCITY = 200
local MIN_ENERGY = 0.2

local VisualizePage = {}

--[[
	@description Factory that creates the Visualize page with a force-directed
	graph renderer, physics simulation, pan/zoom input, and FSM sidebar.
	@param ServiceManager any -- The root ServiceManager instance.
	@param ops Ops -- Injected dependencies (COLORS).
	@return any -- A page table of type Page.
]]
function VisualizePage.Create(ServiceManager: any, ops: Ops)
	local page: any = {
		Container = (ServiceManager.GUI.BodyContainer:WaitForChild("VisualizeView"):WaitForChild("GraphContainer") :: Frame),
		Tab = (ServiceManager.GUI.TabContainer:WaitForChild("Visualize") :: GuiObject),
		Constants = {
			Nodes = {},
			Edges = {},
			Center = Vector2.new(0,0),
			Zoom = 1,
			Pan = Vector2.new(0,0),
			Running = false,
			Alpha = 1,
		},
		Connections = {},
		SimConnection = nil,
	}

	-- -- Utilities -- --

	--[[
		@description Converts a world-space position to screen-space UDim2
		by applying zoom and pan transform.
		@param constants GraphState -- Current graph state (Zoom, Pan).
		@param pos Vector2 -- World-space position.
		@return UDim2
	]]
	local function worldToScreen(constants: GraphState, pos: Vector2): UDim2
		local scaled = (pos * constants.Zoom) + constants.Pan
		return UDim2.fromOffset(scaled.X, scaled.Y)
	end

	-- -- Physics Simulation -- --

	--[[
		@description Performs one physics simulation step. Applies Coulomb repulsion
		between all node pairs (O(N²)), center gravity, Hooke's law spring
		attraction on edges, then integrates velocity/position with damping.
		Puts the simulation to sleep when total energy drops below MIN_ENERGY.
		@param constants GraphState -- Mutable graph state.
		@param dt number -- Delta time in seconds.
		@return ()
	]]
	local function stepPhysics(constants: GraphState, dt: number)
		-- 1. Apply Forces
		for id, node in pairs(constants.Nodes) do
			if node.IsDragging then
				node.Velocity = Vector2.zero
				continue
			end

			local force = Vector2.zero

			-- Repulsion (all nodes repel)
			for otherId, otherNode in pairs(constants.Nodes) do
				if id ~= otherId then
					local diff = node.Position - otherNode.Position
					local dist = diff.Magnitude
					-- Clamp distance to avoid force singularities and extremely high values
					local effectiveDist = math.max(dist, 50) 
					local direction = (dist > 0.01) and diff.Unit or Vector2.new(math.random()-0.5, math.random()-0.5).Unit

					-- Coulomb's Law
					local magnitude = REPULSION_FORCE / (effectiveDist * effectiveDist)
					force += direction * magnitude
				end
			end

			-- Center Gravity (Pull to origin)
			local distToCenter = -node.Position
			force += distToCenter * CENTER_GRAVITY

			-- Cap Max Force
			if force.Magnitude > 1000 then -- explicit max force cap
				force = force.Unit * 1000
			end

			node.Force = force
		end

		-- Attraction (Springs)
		for _, edge in ipairs(constants.Edges) do
			local u = constants.Nodes[edge.Source]
			local v = constants.Nodes[edge.Target]
			if u and v then
				local diff = v.Position - u.Position
				local dist = diff.Magnitude
				if dist > 0.01 then
					local displacement = dist - SPRING_LENGTH
					local force = diff.Unit * (displacement * SPRING_STIFFNESS)

					if not u.IsDragging then u.Force += force end
					if not v.IsDragging then v.Force -= force end
				end
			end
		end

		-- 2. Integration
		local totalEnergy = 0
		for _, node in pairs(constants.Nodes) do
			if node.IsDragging then continue end

			node.Velocity = (node.Velocity + node.Force * dt) * DAMPING
			
			-- Cap velocity
			if node.Velocity.Magnitude > MAX_VELOCITY then
				node.Velocity = node.Velocity.Unit * MAX_VELOCITY
			end

			node.Position += node.Velocity
			totalEnergy += node.Velocity.Magnitude
		end

		-- Sleep condition
		if totalEnergy < MIN_ENERGY and constants.Alpha < 0.01 then
			constants.Running = false
		end
		constants.Alpha = math.max(0, constants.Alpha - dt * 0.5)
	end


	-- -- Rendering -- --

	--[[
		@description Updates the visual positions of all node and edge frames
		based on the current graph state (zoom, pan, node positions).
		@param this Page -- The page instance.
		@return ()
	]]
	local function updateRender(this: Page)
		local constants = this.Constants
		local centerScreen = this.Container.AbsoluteSize / 2
		local globalOffset = Vector2.new(centerScreen.X, centerScreen.Y)

		for _, node in pairs(constants.Nodes) do
			if node.Frame then
				local pos = worldToScreen(constants, node.Position)
				node.Frame.Position = UDim2.fromOffset(pos.X.Offset + globalOffset.X, pos.Y.Offset + globalOffset.Y)
			end
		end

		for _, edge in ipairs(constants.Edges) do
			if edge.Frame then
				local u = constants.Nodes[edge.Source]
				local v = constants.Nodes[edge.Target]
				if u and v then
					-- Calculate positions with Global Offset included for the line math
					local p1 = (u.Position * constants.Zoom) + constants.Pan + globalOffset
					local p2 = (v.Position * constants.Zoom) + constants.Pan + globalOffset
					
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

	-- -- Core Page Methods -- --

	--[[
		@description Disconnects all connections, stops the simulation, and
		destroys all graph UI elements.
		@param this Page -- The page instance.
		@return ()
	]]
	page.Cleanup = function(this: Page)
		ServiceManager:ClearConnections(this.Connections)
		if this.SimConnection then
			this.SimConnection:Disconnect()
			this.SimConnection = nil
		end
		
		-- Clean UI
		if this.Container then
			for _, child in ipairs(this.Container:GetChildren()) do
				if child.Name ~= "StateMachineList" and child.Name ~= "Search" and child.Name ~= "Toolbar" then -- Preserve non-graph elements if any
					child:Destroy()
				end
			end
		end
		
		this.Constants.Nodes = {}
		this.Constants.Edges = {}
		this.Constants.Running = false
	end

	--[[
		@description Updates the visual highlighting of graph nodes. Tweens the
		UIStroke of the current-state node to accent color and dims all others.
		@param this Page -- The page instance.
		@param currentState any -- The FSM's current state name.
		@return ()
	]]
	page.UpdateNodes = function(this: Page, currentState: any)
		local constants = this.Constants
		local currentName = tostring(currentState)
		
		for id, node in pairs(constants.Nodes) do
			if node.Frame then
				local stroke = node.Frame:FindFirstChild("UIStroke") :: UIStroke
				if stroke then
					if id == currentName then
						TweenService:Create(stroke, TweenInfo.new(0.3), { Color = ops.COLORS.Accent, Thickness = 3, Transparency = 0 }):Play()
						node.Frame.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
					else
						TweenService:Create(stroke, TweenInfo.new(0.3), { Color = ops.COLORS.Stroke, Thickness = 2, Transparency = 0.5 }):Play()
						node.Frame.BackgroundColor3 = ops.COLORS.DarkBG
					end
				end
			end
		end
	end

	--[[
		@description Extracts FSM topology (states/transitions), creates Node and
		Edge objects with random initial positions, builds graph UI (node frames,
		labels, badges for initial/terminal states, drag handles, edge lines).
		@param this Page -- The page instance.
		@param stateMachineId string -- The FSM to visualize.
		@return boolean -- False if no data found, true on success.
	]]
	local function buildGraphData(this: Page, stateMachineId: string)
		local fsmService = ServiceManager.Services.FSM
		local stateMachineData = (fsmService and fsmService.StateMachines and fsmService.StateMachines[stateMachineId]) 
			or ServiceManager.ArchivedFSMs[stateMachineId]

		if not stateMachineData then return false end

		-- Data extraction logic
		local transitionsData = (stateMachineData.Graph and stateMachineData.Graph.Transitions)
			or (stateMachineData.Graph and not stateMachineData.Graph.Transitions and stateMachineData.Graph)
			or stateMachineData._transitions
			or {}


		local rawState = stateMachineData.State
		local initialState = stateMachineData.InitialState 
			or stateMachineData.initial 
			or (stateMachineData.Graph and stateMachineData.Graph.InitialState)
			or (stateMachineData.Definition and stateMachineData.Definition.InitialState)

		local validStates = stateMachineData.ValidStates or (stateMachineData.Graph and stateMachineData.Graph.ValidStates) or {}

		-- Reset State
		this.Constants.Nodes = {}
		this.Constants.Edges = {}
		this.Constants.Pan = Vector2.zero
		this.Constants.Zoom = 1
		
		-- Clear World
		local world = this.Container:FindFirstChild("World")
		if world then world:Destroy() end
		world = Instance.new("Frame")
		world.Name = "World"
		world.Size = UDim2.fromScale(1,1)
		world.BackgroundTransparency = 1
		world.ClipsDescendants = false
		world.Parent = this.Container

		-- Identify Nodes & Compute Topology
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
		
		-- Add from transitions AND compute out-degree
		for src, outs in pairs(transitionsData) do
			addNode(src)
			local srcName = tostring(src)
			
			if type(outs) == "table" then
				if #outs > 0 then -- Array style
					for _, dst in ipairs(outs) do 
						addNode(dst) 
						outDegree[srcName] += 1
					end
				else -- Map style
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
		
		-- Add from ValidStates
		if type(validStates) == "table" then
			for k, v in pairs(validStates) do
				addNode(type(k)=="number" and v or k)
			end
		end
		
		-- Create Nodes
		local count = 0
		for id, _ in pairs(nodeSet) do count += 1 end
		local radius = math.sqrt(count) * 80 -- Initial scatter radius
		
		for id, _ in pairs(nodeSet) do
			local angle = math.random() * math.pi * 2
			local dist = math.random() * radius
			local pos = Vector2.new(math.cos(angle) * dist, math.sin(angle) * dist)
			
			local frame = Instance.new("Frame")
			frame.Name = "Node_" .. id
			frame.BackgroundColor3 = ops.COLORS.DarkBG
			frame.Parent = world
			
			Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)
			
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 2
			stroke.Color = ops.COLORS.Stroke
			stroke.Transparency = 0.5
			stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			stroke.Parent = frame
			
			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(1, -20, 1, 0)
			label.Position = UDim2.fromOffset(10, 0)
			label.BackgroundTransparency = 1
			label.Text = id
			label.TextColor3 = Color3.new(1,1,1)
			label.Font = Enum.Font.GothamBold
			label.TextSize = 12
			label.Parent = frame
			
			-- Auto-size
			local txtSize = game:GetService("TextService"):GetTextSize(id, 12, Enum.Font.GothamBold, Vector2.new(1000, 30))
			frame.Size = UDim2.fromOffset(math.max(60, txtSize.X + 24), 32)
			frame.AnchorPoint = Vector2.new(0.5, 0.5)

			-- Visual Badges
            -- Initial State
			if tostring(initialState) == id then
				-- Start Badge (S)
				local badge = Instance.new("Frame")
				badge.Name = "StartBadge"
				badge.Size = UDim2.fromOffset(14, 14)
				badge.Position = UDim2.new(0, -6, 0, -6)
				badge.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
				badge.Parent = frame
				Instance.new("UICorner", badge).CornerRadius = UDim.new(1, 0)
                Instance.new("UIStroke", badge).Color = Color3.new(0,0,0)

                local icon = Instance.new("TextLabel")
                icon.Size = UDim2.fromScale(1,1)
                icon.BackgroundTransparency = 1
                icon.Text = "S"
                icon.TextColor3 = Color3.new(0,0,0)
                icon.Font = Enum.Font.GothamBold
                icon.TextSize = 9
                icon.Parent = badge

				-- Entry Arrow (Visual)
				local entryArrow = Instance.new("TextLabel")
				entryArrow.Name = "EntryArrow"
				entryArrow.Text = "START ►" 
				entryArrow.TextColor3 = Color3.fromRGB(150, 255, 150)
				entryArrow.BackgroundTransparency = 1
				entryArrow.Size = UDim2.fromOffset(60, 20)
				entryArrow.Position = UDim2.new(0, -70, 0.5, 0) -- Left of the node
				entryArrow.AnchorPoint = Vector2.new(0, 0.5) 
				entryArrow.Font = Enum.Font.GothamBold
				entryArrow.TextSize = 12
				entryArrow.TextXAlignment = Enum.TextXAlignment.Right
				entryArrow.Parent = frame
			end
			
            -- Terminal State (0 OutDegree)
			if (outDegree[id] or 0) == 0 then
				local badge = Instance.new("Frame")
				badge.Name = "EndBadge"
				badge.Size = UDim2.fromOffset(14, 14)
				badge.Position = UDim2.new(1, -8, 1, -8) -- Bottom right
				badge.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
				badge.Parent = frame
				Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 3)
                Instance.new("UIStroke", badge).Color = Color3.new(0,0,0)
                
                local icon = Instance.new("TextLabel")
                icon.Size = UDim2.fromScale(1,1)
                icon.BackgroundTransparency = 1
                icon.Text = "E"
                icon.TextColor3 = Color3.new(0,0,0)
                icon.Font = Enum.Font.GothamBold
                icon.TextSize = 9
                icon.Parent = badge
			end

			-- Interaction
			local dragInput = Instance.new("TextButton")
			dragInput.Size = UDim2.fromScale(1,1)
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
			
			dragInput.MouseButton1Down:Connect(function() 
				nodeObj.IsDragging = true 
				this.Constants.Running = true -- Wake up sim
				this.Constants.Alpha = 1
			end)
			
			dragInput.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					nodeObj.IsDragging = false
				end
			end)
			
			this.Constants.Nodes[id] = nodeObj
		end

		-- Create Edges
		local addedEdges = {}
		local function addEdge(src, dst)
			local key = src .. ">" .. dst
			if addedEdges[key] then return end
			if not this.Constants.Nodes[src] or not this.Constants.Nodes[dst] then return end
			
			addedEdges[key] = true
			
			local line = Instance.new("Frame")
			line.Name = key
			line.BackgroundColor3 = Color3.fromRGB(150, 150, 150) -- Brighter lines
			line.BorderSizePixel = 0
			line.AnchorPoint = Vector2.new(0.5, 0.5)
			line.ZIndex = 0 -- Behind nodes
			line.Parent = world
			
			local arrow = Instance.new("TextLabel")
			arrow.Name = "Arrow"
			arrow.BackgroundTransparency = 1
			arrow.Text = "►"
			arrow.TextColor3 = Color3.fromRGB(200, 200, 200)
			arrow.Size = UDim2.fromOffset(16, 16)
			arrow.AnchorPoint = Vector2.new(0.5, 0.5)
			arrow.Position = UDim2.new(0.65, 0, 0.5, 0) -- 65% along the path
			arrow.Font = Enum.Font.Gotham
			arrow.TextSize = 14
			arrow.Parent = line
			
			table.insert(this.Constants.Edges, { Source = src, Target = dst, Frame = line })
		end
		
		for src, outs in pairs(transitionsData) do
			if type(outs) == "table" then
				if #outs > 0 then
					for _, dst in ipairs(outs) do addEdge(tostring(src), tostring(dst)) end
				else
					for k, v in pairs(outs) do addEdge(tostring(src), tostring(type(v)=="string" and v or k)) end
				end
			else
				addEdge(tostring(src), tostring(outs))
			end
		end

		this.Constants.Running = true
		this.Constants.Alpha = 1
		
		-- Initial Highlight
		this:UpdateNodes(rawState)
		
		return true
	end

	page.UpdateFunction = function(this: Page)
		-- Detect sidebar creation (first run)
		if not this.Container.Parent:FindFirstChild("StateMachineList") then
			-- Sidebar Layout
			this.Container.Size = UDim2.new(1, -150, 1, 0)
			this.Container.Position = UDim2.new(0, 150, 0, 0)
			this.Container.ClipsDescendants = true
			this.Container.BackgroundTransparency = 1
			
			local listFrame = Instance.new("ScrollingFrame")
			listFrame.Name = "StateMachineList"
			listFrame.Size = UDim2.new(0, 145, 1, -35)
			listFrame.BackgroundTransparency = 1
			listFrame.ScrollBarThickness = 4
			listFrame.Parent = this.Container.Parent
			
			local layout = Instance.new("UIListLayout", listFrame)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Padding = UDim.new(0, 2)
			
			local search = Instance.new("TextBox")
			search.Name = "Search"
			search.Size = UDim2.new(0, 145, 0, 25)
			search.Position = UDim2.new(0, 0, 1, -30)
			search.BackgroundColor3 = Color3.fromRGB(30,30,30)
			search.TextColor3 = Color3.new(1,1,1)
			search.PlaceholderText = "Search..."
			search.Font = Enum.Font.Gotham
			search.TextSize = 12
			search.Parent = this.Container.Parent
			Instance.new("UICorner", search).CornerRadius = UDim.new(0, 4)
			
			-- Handle Search
			search:GetPropertyChangedSignal("Text"):Connect(function()
				local term = search.Text:lower()
				for _, btn in ipairs(listFrame:GetChildren()) do
					if btn:IsA("TextButton") then
						btn.Visible = (term == "") or btn.Text:lower():find(term, 1, true)
					end
				end
			end)
		end
		
		-- Update List content
		local listFrame = this.Container.Parent:FindFirstChild("StateMachineList")
		local currentSelection = this.Constants.SelectedID
		
		-- Populate FSM List
		local fsms = {}
		local fsmService = ServiceManager.Services.FSM
		if fsmService and fsmService.StateMachines then
			for id, data in pairs(fsmService.StateMachines) do fsms[id] = data end
		end
		for id, data in pairs(ServiceManager.ArchivedFSMs) do fsms[id] = data end
		
		local sorted = {}
		for id, data in pairs(fsms) do table.insert(sorted, {Id=id, Name=data.Name or id}) end
		table.sort(sorted, function(a,b) return a.Name < b.Name end)
		
		-- Diff List
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
				btn.BackgroundColor3 = ops.COLORS.DarkBG
				btn.TextColor3 = Color3.new(1,1,1)
				btn.Font = Enum.Font.Gotham
				btn.TextSize = 11
				btn.Parent = listFrame
				Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
				
				btn.MouseButton1Click:Connect(function()
					this.Constants.SelectedID = item.Id
					buildGraphData(this, item.Id)
					this:UpdateFunction()
					
					-- Hook state updates
					if this.Constants.StateConnection then this.Constants.StateConnection:Disconnect() end
					-- Should hook into FSM StateChanged signal if available, or poll
					-- For now, ServiceManager updates entire page on poll cycle
				end)
			end
			
			btn.BackgroundColor3 = (item.Id == currentSelection) and ops.COLORS.Accent or ops.COLORS.DarkBG
			btn.LayoutOrder = i
			existing[item.Id] = nil
		end
		
		for _, btn in pairs(existing) do btn:Destroy() end
		
		-- Render Highlight Update (if graph already exists)
		if currentSelection and fsms[currentSelection] then
			this:UpdateNodes(fsms[currentSelection].State)
		end
	end
	
	-- -- Input Handling -- --
	--[[
		@description Sets up pan (right/middle mouse drag), zoom (scroll wheel),
		reset (R key), and node dragging input handlers on the graph container.
		@param this Page -- The page instance.
		@return ()
	]]
	local function hookInput(this: Page)
		local container = this.Container
		
		-- Pan / Zoom
		local dragStart = Vector2.zero
		local panStart = Vector2.zero
		local isPanning = false
		
		table.insert(this.Connections, container.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.MouseButton3 then
				isPanning = true
				dragStart = UserInputService:GetMouseLocation()
				panStart = this.Constants.Pan
			end
			if input.KeyCode == Enum.KeyCode.R then
				-- Reset View
				TweenService:Create(container, TweenInfo.new(0.5), {Position = UDim2.new(0,150,0,0)}):Play() -- Hack to refresh? No, just update state
				this.Constants.Pan = Vector2.zero
				this.Constants.Zoom = 1
			end
		end))
		
		table.insert(this.Connections, UserInputService.InputChanged:Connect(function(input)
			if isPanning and input.UserInputType == Enum.UserInputType.MouseMovement then
				local delta = UserInputService:GetMouseLocation() - dragStart
				this.Constants.Pan = panStart + delta
			elseif input.UserInputType == Enum.UserInputType.MouseWheel then
				-- Zoom towards mouse? Simple zoom for now
				local zoomSpeed = 0.1
				local newZoom = math.clamp(this.Constants.Zoom + (input.Position.Z * zoomSpeed), 0.2, 3)
				this.Constants.Zoom = newZoom
			end
			
			-- Node Dragging Logic
			for _, node in pairs(this.Constants.Nodes) do
				if node.IsDragging then
					local mouse = UserInputService:GetMouseLocation()
					local centerScreen = container.AbsoluteSize / 2
					local globalOffset = Vector2.new(centerScreen.X, centerScreen.Y) + container.AbsolutePosition
					
					-- Inverse of worldToScreen: (Mouse - Pan - ScreenCenter) / Zoom
					local targetPos = (mouse - this.Constants.Pan - globalOffset) / this.Constants.Zoom
					node.Position = targetPos
					node.Velocity = Vector2.zero
				end
			end
		end))
		
		table.insert(this.Connections, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.MouseButton3 then
				isPanning = false
			end
		end))
	end

	-- -- Initialization -- --
	hookInput(page)
	
	page.SimConnection = RunService.RenderStepped:Connect(function(dt)
		if ServiceManager.ActivePage ~= "Visualize" then return end
		
		if page.Constants.Running or page.Constants.Alpha > 0 then
			stepPhysics(page.Constants, math.min(dt, 0.1))
		end
		updateRender(page)
	end)

	return page
end

return VisualizePage