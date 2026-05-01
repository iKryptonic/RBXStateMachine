--!strict
-- @Name ServiceManager/Subsystems/FSMModule.luau
-- @Author iKrypto
-- @Description Enhanced FSM subsystem with active/failed/archived sections, cancel/retry
-- actions, per-FSM performance metrics, state graph visualization, transition history,
-- stall detection, and detailed drill-down layers.

local Theme = require(script.Parent.Parent.Theme)
local SearchAutocomplete = require(script.Parent.Parent.SearchAutocomplete)

local FSMModule = {}
FSMModule.__index = FSMModule

local SORT_MODES = { "Name", "State", "Transitions", "Age", "Errors" }

--[[
	Create the FSM subsystem controller.
	Tracks live, failed, completed, and archived machines plus client-side shadow
	state used to keep the inspector populated during local observation.
]]
function FSMModule.new(): any
	local self = setmetatable({}, FSMModule)
	self._fsmCache = {} :: { [string]: any }
	self._failedFSMs = {} :: { [string]: any }
	self._completedFSMs = {} :: { [string]: any }
	self._archivedFSMs = {} :: { [string]: any }
	self._clientShadow = {} :: { [string]: any } -- shadow of FSMs we've seen (client mode)
	self._clientShadowConnected = false
	self._searchText = ""
	self._sortMode = "Name"
	self._showFailed = true
	self._showCompleted = true
	self._showArchived = false
	self._selectedFSM = nil :: string?
	return self
end

function FSMModule:_EnsureClientShadow(orchestrator: any)
	if self._clientShadowConnected then return end
	self._clientShadowConnected = true

	pcall(function()
		local factory = orchestrator.Factory
		if not factory or not factory.Registry then return end
		local registry = factory.Registry

		-- Seed with existing FSMs
		local machines = {}
		if type(registry.GetAllStateMachines) == "function" then
			local ok, result = pcall(registry.GetAllStateMachines)
			if ok and type(result) == "table" then machines = result end
		end
		for id, fsm in pairs(machines) do
			self._clientShadow[id] = fsm
		end

		-- Watch for new FSMs
		if registry.StateMachineRegistered then
			registry.StateMachineRegistered:Connect(function(id: string, fsm: any)
				self._clientShadow[id] = fsm
			end)
		end
	end)
end

--[[
	Refresh the FSM snapshot for the currently selected context and publish the
	latest active / failed / completed collections into the subsystem caches.
]]
function FSMModule:FetchData(nexus: any)
	local orchestrator = nexus._orchestrator
	if not orchestrator then return end

	self._fsmCache = {}
	self._failedFSMs = {}
	self._completedFSMs = {}

	local function placeData(id: string, data: any)
		if data.Status == "failed" or data.Status == "error" then
			self._failedFSMs[id] = data
		elseif data.Status == "completed" then
			self._completedFSMs[id] = data
		else
			self._fsmCache[id] = data
		end
	end

	-- Show ONLY FSMs that belong to the active context. The user expectation
	-- is that the GUI's context toggle (CLIENT / SERVER) acts as a strict
	-- filter — the server-side TrafficLightFSM should NOT appear in client
	-- mode just because we polled it for the server tab. (It only appears
	-- when the user explicitly switches the GUI to server context.)
	local mode = nexus._contextMode

	-- ── Client (local-VM) FSMs from the live Factory registry ──
	if mode == "client" then
		local factory = orchestrator.Factory
		if factory and factory.Registry then
			self:_EnsureClientShadow(orchestrator)

			local registry = factory.Registry
			local liveMachines = {}
			if type(registry.GetAllStateMachines) == "function" then
				local ok, result = pcall(registry.GetAllStateMachines)
				if ok and type(result) == "table" then liveMachines = result end
			end
			for id, fsm in pairs(liveMachines) do
				self._clientShadow[id] = fsm
			end

			for id, fsm in pairs(self._clientShadow) do
				local fsmData = self:_ExtractFSMData(id, fsm)
				fsmData.Origin = "client"
				placeData(id, fsmData)
			end
		end
	end

	-- ── Server FSMs from the snapshot (only when in server context) ──
	-- The server poll itself still runs on a 5s cadence even in client mode
	-- (so detail drill-downs into a previously-viewed server FSM remain
	-- responsive), but the LIST surface is context-strict.
	if mode == "server" then
		local serverData = nexus._serverData
		if serverData and serverData.FSM then
			local fsmList = serverData.FSM.List or serverData.FSM.StateMachines or {}
			for id, fsmInfo in pairs(fsmList) do
				if type(fsmInfo) ~= "table" then continue end

				local status = fsmInfo.Status
				if not status or status == "" then
					if fsmInfo.IsActive == false then
						status = if (fsmInfo.Error) then "failed" else "completed"
					else
						status = "active"
					end
				end

				local data = {
					Id = id,
					CurrentState = fsmInfo.CurrentState or fsmInfo.State or "unknown",
					States = fsmInfo.States or fsmInfo.validStates or {},
					Transitions = fsmInfo.Transitions or fsmInfo.TransitionCount or 0,
					Status = status,
					CreatedAt = fsmInfo.CreatedAt or 0,
					LastTransition = fsmInfo.LastTransition or fsmInfo.LastTransitionTime or 0,
					TransitionHistory = fsmInfo.TransitionHistory or {},
					_transitions = fsmInfo._transitions,
					Error = fsmInfo.Error,
					IsStalled = fsmInfo.IsStalled or false,
					EntityId = fsmInfo.EntityId,
					Name = fsmInfo.Name,
					Origin = "server",
				}

				placeData(id, data)
			end
		end
	end

	nexus.Store:BatchUpdate(function()
		nexus.Store:Set("fsm.list", self._fsmCache)
		nexus.Store:Set("fsm.failed", self._failedFSMs)
		nexus.Store:Set("fsm.completed", self._completedFSMs)
	end)
end

function FSMModule:_ExtractFSMData(id: string, fsm: any): any
	local currentState = "unknown"
	local states = {}
	local transitions = 0
	local status = "active"
	local createdAt = 0
	local lastTransition = 0
	local transitionHistory = {}
	local errorMsg = nil
	local isStalled = false
	local entityId = nil

	if type(fsm) == "table" then
		currentState = fsm.State or fsm.CurrentState or fsm._currentState or "unknown"
		local rawStates = fsm._states or fsm.States or {}
		if type(rawStates) == "table" then
			states = {}
			for name, _ in pairs(rawStates) do
				table.insert(states, name)
			end
		end
		transitions = fsm.TransitionCount or fsm._transitionCount or 0
		-- Derive status from IsActive and error state
		errorMsg = fsm.Error or fsm._error
		if fsm.IsActive == false then
			status = if errorMsg then "failed" else "completed"
		elseif fsm._failed then
			status = "failed"
		else
			status = "active"
		end
		createdAt = fsm.CreatedAt or fsm._createdAt or 0
		lastTransition = fsm.LastTransitionTime or fsm._lastTransitionTime or 0
		transitionHistory = fsm.TransitionHistory or fsm._transitionHistory or {}
		isStalled = fsm.IsStalled or fsm._isStalled or false
		entityId = fsm.EntityId or fsm._entityId or (fsm.Context and type(fsm.Context) == "table" and fsm.Context.EntityId)
	end

	-- Detect stall: no transition in >30 seconds while still "active"
	if status == "active" and lastTransition > 0 and (os.clock() - lastTransition) > 30 then
		isStalled = true
	end

	-- Extract per-FSM memory from Perf table
	local memLastKB = 0
	local memLastDeltaKB = 0
	local memMaxDeltaKB = 0
	local memTotalDeltaKB = 0
	if type(fsm) == "table" and type(fsm.Perf) == "table" then
		local perf = fsm.Perf
		memLastKB = perf.LastMemKB or 0
		memLastDeltaKB = perf.LastMemKBDelta or 0
		memMaxDeltaKB = perf.MaxMemKBDelta or 0
		memTotalDeltaKB = perf.TotalMemKBDelta or 0
	end

	return {
		Id = id,
		CurrentState = currentState,
		States = states,
		Transitions = transitions,
		Status = status,
		CreatedAt = createdAt,
		LastTransition = lastTransition,
		TransitionHistory = transitionHistory,
		_transitions = (type(fsm) == "table" and fsm._transitions) or nil,
		Error = errorMsg,
		IsStalled = isStalled,
		EntityId = entityId,
		MemLastKB = memLastKB,
		MemLastDeltaKB = memLastDeltaKB,
		MemMaxDeltaKB = memMaxDeltaKB,
		MemTotalDeltaKB = memTotalDeltaKB,
	}
end

--[[
	Legacy subsystem hook retained for interface parity.
	FSM UI is rendered through BuildRootLayer and drill-down builders.
]]
function FSMModule:Render(_nexus: any) end

-- ══════════════════════════════════════════════════════════════
-- SORTING / FILTERING
-- ══════════════════════════════════════════════════════════════

function FSMModule:_GetSortedFiltered(source: { [string]: any }): { { Id: string, Data: any } }
	local result = {}
	for id, data in pairs(source) do
		if self._searchText ~= "" then
			local lower = string.lower(self._searchText)
			if not string.lower(id):find(lower, 1, true)
				and not string.lower(data.CurrentState or ""):find(lower, 1, true) then
				continue
			end
		end
		table.insert(result, { Id = id, Data = data })
	end

	local mode = self._sortMode
	table.sort(result, function(a, b)
		if mode == "Name" then return a.Id < b.Id
		elseif mode == "State" then return (a.Data.CurrentState or "") < (b.Data.CurrentState or "")
		elseif mode == "Transitions" then return (a.Data.Transitions or 0) > (b.Data.Transitions or 0)
		elseif mode == "Age" then return (a.Data.CreatedAt or 0) < (b.Data.CreatedAt or 0)
		elseif mode == "Errors" then return (a.Data.Error and 1 or 0) > (b.Data.Error and 1 or 0)
		end
		return a.Id < b.Id
	end)
	return result
end

-- ══════════════════════════════════════════════════════════════
-- ROOT LAYER
-- ══════════════════════════════════════════════════════════════

--[[
	Build or rebuild the FSM overview layer inside the navigator host frame.
	Seeds the summary strip, filters, and top-level machine rows that drill into
	history, graph, and step-detail layers.
]]
function FSMModule:BuildRootLayer(frame: Frame, context: any)
	local nexus = context.Nexus
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = contentFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 6)
	pad.Parent = contentFrame

	-- Summary strip
	self:_BuildSummaryStrip(contentFrame)

	-- Toolbar
	self:_BuildToolbar(contentFrame, nexus)

	local itemsToAnimate = {}

	-- Active FSMs section
	local activeSorted = self:_GetSortedFiltered(self._fsmCache)
	Theme.CreateLabel({
		Text = string.format("ACTIVE STATE MACHINES (%d)", #activeSorted),
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 20

	for i, item in ipairs(activeSorted) do
		local row = self:_BuildFSMRow(contentFrame, item.Id, item.Data, nexus, 20 + i)
		table.insert(itemsToAnimate, row)
	end

	-- Failed FSMs section
	if self._showFailed then
		local failedSorted = self:_GetSortedFiltered(self._failedFSMs)
		if #failedSorted > 0 then
			Theme.CreateLabel({
				Text = string.format('<font color="#F05050">FAILED STATE MACHINES (%d)</font>', #failedSorted),
				Size = UDim2.new(1, 0, 0, 18),
				Color = Theme.Colors.Danger,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 200

			for i, item in ipairs(failedSorted) do
				local row = self:_BuildFSMRow(contentFrame, item.Id, item.Data, nexus, 200 + i)
				table.insert(itemsToAnimate, row)
			end
		end
	end

	-- Completed FSMs section
	if self._showCompleted then
		local completedSorted = self:_GetSortedFiltered(self._completedFSMs)
		if #completedSorted > 0 then
			Theme.CreateLabel({
				Text = string.format('<font color="#3CD278">COMPLETED STATE MACHINES (%d)</font>', #completedSorted),
				Size = UDim2.new(1, 0, 0, 18),
				Color = Theme.Colors.Success,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 300

			for i, item in ipairs(completedSorted) do
				local row = self:_BuildFSMRow(contentFrame, item.Id, item.Data, nexus, 300 + i)
				row.BackgroundTransparency = 0.9
				table.insert(itemsToAnimate, row)
			end
		end
	end

	-- Archived section
	if self._showArchived then
		local archivedCount = 0
		for _ in pairs(self._archivedFSMs) do archivedCount += 1 end
		if archivedCount > 0 then
			Theme.CreateLabel({
				Text = string.format("ARCHIVED (%d)", archivedCount),
				Size = UDim2.new(1, 0, 0, 18),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 400

			local order = 401
			for id, data in pairs(self._archivedFSMs) do
				local row = self:_BuildFSMRow(contentFrame, id, data, nexus, order)
				row.BackgroundTransparency = 0.92
				table.insert(itemsToAnimate, row)
				order += 1
			end
		end
	end

	if nexus._animationController and #itemsToAnimate > 0 then
		nexus._animationController:StaggerIn(
			itemsToAnimate,
			{ BackgroundTransparency = 1, Position = UDim2.new(0.03, 0, 0, 0) },
			{ BackgroundTransparency = 0.85, Position = UDim2.new(0, 0, 0, 0) },
			Theme.Tween.Fast
		)
	end
end

function FSMModule:_BuildSummaryStrip(parent: Frame)
	local strip = Instance.new("Frame")
	strip.Name = "FSMSummary"
	strip.Size = UDim2.new(1, 0, 0, 44)
	strip.BackgroundColor3 = Theme.Colors.CardBG
	strip.BackgroundTransparency = 0.6
	strip.BorderSizePixel = 0
	strip.LayoutOrder = 0
	strip.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	corner.Parent = strip

	local innerLayout = Instance.new("UIListLayout")
	innerLayout.FillDirection = Enum.FillDirection.Horizontal
	innerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	innerLayout.Padding = UDim.new(0, 12)
	innerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	innerLayout.Parent = strip

	local innerPad = Instance.new("UIPadding")
	innerPad.PaddingLeft = UDim.new(0, 12)
	innerPad.Parent = strip

	local activeCount, failedCount, stalledCount, totalTransitions = 0, 0, 0, 0
	for _, d in pairs(self._fsmCache) do
		activeCount += 1
		totalTransitions += (d.Transitions or 0)
		if d.IsStalled then stalledCount += 1 end
	end
	for _ in pairs(self._failedFSMs) do failedCount += 1 end

	local metrics = {
		{ Label = "ACTIVE", Value = tostring(activeCount), Color = Theme.Colors.Success },
		{ Label = "FAILED", Value = tostring(failedCount), Color = Theme.Colors.Danger },
		{ Label = "STALLED", Value = tostring(stalledCount), Color = Theme.Colors.Warning },
		{ Label = "TRANSITIONS", Value = tostring(totalTransitions), Color = Theme.Colors.Cyan },
	}

	for i, m in ipairs(metrics) do
		local cell = Instance.new("Frame")
		cell.Size = UDim2.new(0, 80, 1, 0)
		cell.BackgroundTransparency = 1
		cell.LayoutOrder = i
		cell.Parent = strip

		Theme.CreateLabel({
			Text = m.Value,
			Size = UDim2.new(1, 0, 0, 18),
			Position = UDim2.new(0, 0, 0, 3),
			Color = m.Color,
			FontSize = Theme.TextSize.Heading,
			FontFace = Theme.Font.Bold,
			Parent = cell,
		})
		Theme.CreateLabel({
			Text = m.Label,
			Size = UDim2.new(1, 0, 0, 12),
			Position = UDim2.new(0, 0, 0, 24),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Bold,
			Parent = cell,
		})
	end
end

function FSMModule:_BuildToolbar(parent: Frame, nexus: any)
	local toolbar = Instance.new("Frame")
	toolbar.Name = "FSMToolbar"
	toolbar.Size = UDim2.new(1, 0, 0, 30)
	toolbar.BackgroundTransparency = 1
	toolbar.LayoutOrder = 10
	toolbar.Parent = parent

	local tbLayout = Instance.new("UIListLayout")
	tbLayout.FillDirection = Enum.FillDirection.Horizontal
	tbLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tbLayout.Padding = UDim.new(0, 6)
	tbLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tbLayout.Parent = toolbar

	-- Search
	local searchFrame = Instance.new("Frame")
	searchFrame.Size = UDim2.new(0, 180, 0, 26)
	searchFrame.BackgroundColor3 = Theme.Colors.GlassOverlay
	searchFrame.BackgroundTransparency = 0.3
	searchFrame.BorderSizePixel = 0
	searchFrame.LayoutOrder = 1
	searchFrame.Parent = toolbar

	local sCorner = Instance.new("UICorner")
	sCorner.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	sCorner.Parent = searchFrame

	Theme.CreateLabel({
		Text = "🔍",
		Size = UDim2.new(0, 22, 1, 0),
		Position = UDim2.new(0, 4, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		Alignment = Enum.TextXAlignment.Center,
		Parent = searchFrame,
	})

	local searchBox = Instance.new("TextBox")
	searchBox.Size = UDim2.new(1, -30, 1, -4)
	searchBox.Position = UDim2.new(0, 26, 0, 2)
	searchBox.BackgroundTransparency = 1
	searchBox.Text = self._searchText
	searchBox.PlaceholderText = "Search FSMs..."
	searchBox.PlaceholderColor3 = Theme.Colors.TextMuted
	searchBox.TextColor3 = Theme.Colors.TextPrimary
	searchBox.TextSize = Theme.TextSize.Caption
	searchBox.FontFace = Theme.Font.Mono
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.ClearTextOnFocus = false
	searchBox.BorderSizePixel = 0
	searchBox.Parent = searchFrame

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		self._searchText = searchBox.Text
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	-- Attach search autocomplete
	if self._searchAC then self._searchAC:Destroy(); self._searchAC = nil end
	self._searchAC = SearchAutocomplete.new({
		TextBox = searchBox,
		ParentFrame = parent,
		GetSuggestions = function(text: string): { string }
			local lower = string.lower(text)
			local matches = {}
			for id, _ in pairs(self._fsmCache) do
				if string.find(string.lower(id), lower, 1, true) then
					table.insert(matches, id)
				end
			end
			for id, _ in pairs(self._failedFSMs) do
				if string.find(string.lower(id), lower, 1, true) then
					table.insert(matches, id)
				end
			end
			for id, _ in pairs(self._completedFSMs) do
				if string.find(string.lower(id), lower, 1, true) then
					table.insert(matches, id)
				end
			end
			table.sort(matches)
			return matches
		end,
		OnSelect = function(selected: string)
			self._searchText = selected
			if nexus then nexus._lastDataRefresh = 0 end
		end,
	})

	-- Sort cycle
	local sortBtn = Instance.new("TextButton")
	sortBtn.Size = UDim2.new(0, 90, 0, 26)
	sortBtn.BackgroundColor3 = Theme.Colors.GlassTertiary
	sortBtn.BackgroundTransparency = 0.4
	sortBtn.Text = "↓ " .. self._sortMode
	sortBtn.TextColor3 = Theme.Colors.TextSecondary
	sortBtn.TextSize = Theme.TextSize.Caption
	sortBtn.FontFace = Theme.Font.Bold
	sortBtn.AutoButtonColor = false
	sortBtn.BorderSizePixel = 0
	sortBtn.LayoutOrder = 2
	sortBtn.Parent = toolbar

	Instance.new("UICorner", sortBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	sortBtn.MouseButton1Click:Connect(function()
		local idx = table.find(SORT_MODES, self._sortMode) or 1
		idx = if idx >= #SORT_MODES then 1 else idx + 1
		self._sortMode = SORT_MODES[idx]
		sortBtn.Text = "↓ " .. self._sortMode
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	-- Failed toggle
	local failedBtn = Instance.new("TextButton")
	failedBtn.Size = UDim2.new(0, 60, 0, 26)
	failedBtn.BackgroundColor3 = if self._showFailed then Theme.Colors.Danger else Theme.Colors.GlassTertiary
	failedBtn.BackgroundTransparency = if self._showFailed then 0.5 else 0.6
	failedBtn.Text = "Failed"
	failedBtn.TextColor3 = if self._showFailed then Theme.Colors.TextOnAccent else Theme.Colors.TextMuted
	failedBtn.TextSize = Theme.TextSize.Caption
	failedBtn.FontFace = Theme.Font.Bold
	failedBtn.AutoButtonColor = false
	failedBtn.BorderSizePixel = 0
	failedBtn.LayoutOrder = 3
	failedBtn.Parent = toolbar
	Instance.new("UICorner", failedBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)
	failedBtn.MouseButton1Click:Connect(function()
		self._showFailed = not self._showFailed
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	-- Completed toggle
	local completedBtn = Instance.new("TextButton")
	completedBtn.Size = UDim2.new(0, 80, 0, 26)
	completedBtn.BackgroundColor3 = if self._showCompleted then Theme.Colors.Success else Theme.Colors.GlassTertiary
	completedBtn.BackgroundTransparency = if self._showCompleted then 0.5 else 0.6
	completedBtn.Text = "Completed"
	completedBtn.TextColor3 = if self._showCompleted then Theme.Colors.TextOnAccent else Theme.Colors.TextMuted
	completedBtn.TextSize = Theme.TextSize.Caption
	completedBtn.FontFace = Theme.Font.Bold
	completedBtn.AutoButtonColor = false
	completedBtn.BorderSizePixel = 0
	completedBtn.LayoutOrder = 4
	completedBtn.Parent = toolbar
	Instance.new("UICorner", completedBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)
	completedBtn.MouseButton1Click:Connect(function()
		self._showCompleted = not self._showCompleted
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	-- Archive toggle
	local archiveBtn = Instance.new("TextButton")
	archiveBtn.Size = UDim2.new(0, 70, 0, 26)
	archiveBtn.BackgroundColor3 = if self._showArchived then Theme.Colors.Accent else Theme.Colors.GlassTertiary
	archiveBtn.BackgroundTransparency = if self._showArchived then 0.5 else 0.6
	archiveBtn.Text = "Archive"
	archiveBtn.TextColor3 = if self._showArchived then Theme.Colors.TextOnAccent else Theme.Colors.TextMuted
	archiveBtn.TextSize = Theme.TextSize.Caption
	archiveBtn.FontFace = Theme.Font.Bold
	archiveBtn.AutoButtonColor = false
	archiveBtn.BorderSizePixel = 0
	archiveBtn.LayoutOrder = 5
	archiveBtn.Parent = toolbar
	Instance.new("UICorner", archiveBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)
	archiveBtn.MouseButton1Click:Connect(function()
		self._showArchived = not self._showArchived
		if nexus then nexus._lastDataRefresh = 0 end
	end)
end

-- ══════════════════════════════════════════════════════════════
-- FSM ROW
-- ══════════════════════════════════════════════════════════════

function FSMModule:_BuildFSMRow(parent: Frame, id: string, fsmData: any, nexus: any, order: number): Frame
	local statusColor = if fsmData.Status == "failed" then Theme.Colors.Danger
		elseif fsmData.IsStalled then Theme.Colors.Warning
		elseif fsmData.Status == "active" then Theme.Colors.Success
		else Theme.Colors.TextMuted

	local stateCount = if type(fsmData.States) == "table" then #fsmData.States else 0

	local accentRgb = string.format("rgb(%d,%d,%d)",
		math.floor(Theme.Colors.Accent.R * 255),
		math.floor(Theme.Colors.Accent.G * 255),
		math.floor(Theme.Colors.Accent.B * 255))

	local stats: { Theme.RowStat } = {
		{ Text = string.format("%d states", stateCount), Color = Theme.Colors.TextMuted, Width = 60, Mono = false, FontSize = Theme.TextSize.Caption },
		{ Text = string.format("↔ %d", fsmData.Transitions or 0), Color = Theme.Colors.Cyan, Width = 50 },
	}

	-- Origin badge so users know which VM the FSM is running in.
	-- This is critical when a server FSM is invisible from client context
	-- and vice versa — the badge tells the user which context to switch to.
	local origin = fsmData.Origin
	if origin == "server" then
		table.insert(stats, { Text = "SRV", Color = Theme.Colors.Purple, Width = 28, FontSize = Theme.TextSize.Tiny })
	elseif origin == "client" then
		table.insert(stats, { Text = "CLI", Color = Theme.Colors.Cyan, Width = 28, FontSize = Theme.TextSize.Tiny })
	end

	-- State badge with accent color
	local stateText = fsmData.CurrentState or "?"
	table.insert(stats, 1, {
		Text = string.format('<font color="%s"><b>%s</b></font>', accentRgb, stateText),
		Width = 80,
		Mono = false,
	})

	if fsmData.EntityId then
		table.insert(stats, { Text = "◇", Color = Theme.Colors.Purple, Width = 14, Mono = false })
	end
	if fsmData.Error then
		table.insert(stats, { Text = "ERR", Color = Theme.Colors.Danger, Width = 30, FontSize = Theme.TextSize.Tiny })
	end

	-- Stall warning prepended to title via rich text
	local titleText = id
	if fsmData.IsStalled then
		titleText = '<font color="#F5C846">↑ </font>' .. id
	end

	local row = Theme.CreateRow({
		Name = "FSM_" .. id,
		Size = UDim2.new(1, 0, 0, 38),
		StatusColor = statusColor,
		Title = titleText,
		BackgroundColor = if fsmData.Status == "failed" then Theme.Colors.Danger
			elseif fsmData.IsStalled then Theme.Colors.Warning
			else Theme.Colors.GlassTertiary,
		BackgroundTransparency = if fsmData.Status == "failed" or fsmData.IsStalled then 0.88 else 0.85,
		LayoutOrder = order,
		Stats = stats,
		Parent = parent,
		OnClick = function()
			self._selectedFSM = id
			if nexus._navigator then
				nexus._navigator:ExpandLayer({
					Id = "fsm.detail." .. id,
					ParentId = "FSM",
					Label = id,
					Builder = function(f, ctx) self:_BuildFSMDetailLayer(f, ctx) end,
					Context = { Nexus = nexus, FSMId = id, FSMData = fsmData },
				})
			end
		end,
	})

	-- Pulse status dot for active machines
	local dot = row:FindFirstChild("StatusDot")
	if dot and fsmData.Status == "active" and not fsmData.IsStalled and nexus._animationController then
		nexus._animationController:StartPulse("fsm_" .. id, dot, "BackgroundTransparency", 0.6)
	end

	-- Hover glow
	local btn = row:FindFirstChild("ClickOverlay")
	if btn and nexus._animationController then
		nexus._animationController:HoverGlow(btn, Theme.Colors.Accent)
	end

	return row
end

-- ══════════════════════════════════════════════════════════════
-- FSM DETAIL LAYER
-- ══════════════════════════════════════════════════════════════

function FSMModule:_BuildFSMDetailLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	local fsmId = context.FSMId or "Unknown"
	local fsmData = context.FSMData or {}
	local nexus = context.Nexus

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 5)
	layout.Parent = contentFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.Parent = contentFrame

	-- Header
	local headerIcon = if fsmData.Status == "failed" then "●" elseif fsmData.IsStalled then "●" else "●"
	Theme.CreateLabel({
		Text = string.format('%s %s', headerIcon, fsmId),
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	-- Action bar
	local actionBar = Instance.new("Frame")
	actionBar.Size = UDim2.new(1, 0, 0, 30)
	actionBar.BackgroundTransparency = 1
	actionBar.LayoutOrder = 1
	actionBar.Parent = contentFrame

	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection = Enum.FillDirection.Horizontal
	actionLayout.Padding = UDim.new(0, 6)
	actionLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	actionLayout.Parent = actionBar

	if fsmData.Status == "failed" then
		local retryBtn = Theme.CreateIconButton({
			Label = "Retry",
			Size = UDim2.new(0, 70, 0, 26),
			Color = Theme.Colors.Success,
			Parent = actionBar,
		})
		retryBtn.LayoutOrder = 1
		retryBtn.MouseButton1Click:Connect(function()
			local orch = nexus._orchestrator
			if orch and orch.Factory and orch.Factory.Registry then
				local machines = orch.Factory.Registry.StateMachines or orch.Factory.Registry._stateMachines or {}
				local fsm = machines[fsmId]
				if fsm and fsm.Retry then
					pcall(fsm.Retry, fsm)
				elseif fsm and fsm.Reset then
					pcall(fsm.Reset, fsm)
				end
			end
			nexus._lastDataRefresh = 0
		end)
	end

	local cancelBtn = Theme.CreateIconButton({
		Label = "Cancel",
		Size = UDim2.new(0, 80, 0, 26),
		Color = Theme.Colors.Danger,
		Parent = actionBar,
	})
	cancelBtn.LayoutOrder = 2
	cancelBtn.MouseButton1Click:Connect(function()
		local orch = nexus._orchestrator
		if orch and orch.Factory and orch.Factory.Registry then
			local machines = orch.Factory.Registry.StateMachines or orch.Factory.Registry._stateMachines or {}
			local fsm = machines[fsmId]
			if fsm and fsm.Cancel then
				pcall(fsm.Cancel, fsm)
			end
		end
		self._archivedFSMs[fsmId] = fsmData
		if nexus._navigator then nexus._navigator:CollapseToLayer("FSM") end
	end)

	local vizBtn = Theme.CreateIconButton({
		Label = "◆ Visualize",
		Size = UDim2.new(0, 90, 0, 26),
		Color = Theme.Colors.Accent,
		Parent = actionBar,
	})
	vizBtn.LayoutOrder = 3
	vizBtn.MouseButton1Click:Connect(function()
		if nexus._navigator then
			nexus._navigator:ExpandLayer({
				Id = "fsm.visualizer." .. fsmId,
				ParentId = "fsm.detail." .. fsmId,
				Label = "Graph",
				Builder = function(f, ctx) self:_BuildGraphLayer(f, ctx) end,
				Context = { Nexus = nexus, FSMId = fsmId, FSMData = fsmData },
			})
		end
	end)

	-- Properties
	Theme.CreateLabel({
		Text = "IDENTITY",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 5

	local props = {
		{ Key = "Current State", Value = fsmData.CurrentState or "?", Color = Theme.Colors.Accent },
		{ Key = "Status", Value = fsmData.Status or "unknown", Color = if fsmData.Status == "active" then Theme.Colors.Success elseif fsmData.Status == "failed" then Theme.Colors.Danger else Theme.Colors.TextPrimary },
		{ Key = "Transitions", Value = tostring(fsmData.Transitions or 0), Color = Theme.Colors.Cyan },
		{ Key = "States Count", Value = tostring(if type(fsmData.States) == "table" then #fsmData.States else 0), Color = Theme.Colors.TextPrimary },
		{ Key = "Is Stalled", Value = tostring(fsmData.IsStalled), Color = if fsmData.IsStalled then Theme.Colors.Warning else Theme.Colors.TextMuted },
		{ Key = "Entity", Value = fsmData.EntityId or "none", Color = Theme.Colors.Purple },
	}
	for i, p in ipairs(props) do
		self:_BuildPropRow(contentFrame, p.Key, p.Value, p.Color, 5 + i)
	end

	-- Memory section
	local memLastKB = fsmData.MemLastKB or 0
	local memMaxDelta = fsmData.MemMaxDeltaKB or 0
	local memTotalDelta = fsmData.MemTotalDeltaKB or 0
	local memLastDelta = fsmData.MemLastDeltaKB or 0
	if memLastKB > 0 or memMaxDelta > 0 or memTotalDelta > 0 then
		Theme.CreateLabel({
			Text = "MEMORY",
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Parent = contentFrame,
		}).LayoutOrder = 12

		local fmtKB = function(kb: number): string
			if math.abs(kb) >= 1024 then return string.format("%.2f MB", kb / 1024) end
			return string.format("%.2f KB", kb)
		end

		local memProps = {
			{ Key = "Heap Snapshot", Value = fmtKB(memLastKB), Color = Theme.Colors.TextPrimary },
			{ Key = "Last Δ", Value = fmtKB(memLastDelta), Color = if memLastDelta > 10 then Theme.Colors.Warning else Theme.Colors.TextSecondary },
			{ Key = "Peak Δ", Value = fmtKB(memMaxDelta), Color = Theme.Colors.Orange },
			{ Key = "Cumulative Δ", Value = fmtKB(memTotalDelta), Color = Theme.Colors.Cyan },
		}
		for i, mp in ipairs(memProps) do
			self:_BuildPropRow(contentFrame, mp.Key, mp.Value, mp.Color, 12 + i)
		end
	end

	-- Error message
	if fsmData.Error then
		Theme.CreateLabel({
			Text = "ERROR",
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.Danger,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Parent = contentFrame,
		}).LayoutOrder = 30

		local errBox = Instance.new("Frame")
		errBox.Size = UDim2.new(1, 0, 0, 40)
		errBox.BackgroundColor3 = Theme.Colors.Danger
		errBox.BackgroundTransparency = 0.85
		errBox.BorderSizePixel = 0
		errBox.LayoutOrder = 31
		errBox.Parent = contentFrame
		Instance.new("UICorner", errBox).CornerRadius = UDim.new(0, Theme.Radius.Xs)

		Theme.CreateLabel({
			Text = tostring(fsmData.Error),
			Size = UDim2.new(1, -12, 1, -4),
			Position = UDim2.new(0, 6, 0, 2),
			Color = Theme.Colors.Danger,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Mono,
			Parent = errBox,
		})
	end

	-- State list
	if type(fsmData.States) == "table" and #fsmData.States > 0 then
		Theme.CreateLabel({
			Text = "STATES",
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Parent = contentFrame,
		}).LayoutOrder = 50

		for i, stateName in ipairs(fsmData.States) do
			local isCurrent = (stateName == fsmData.CurrentState)
			self:_BuildPropRow(
				contentFrame,
				if isCurrent then "▸ " .. stateName else "  " .. stateName,
				if isCurrent then "ACTIVE" else "",
				if isCurrent then Theme.Colors.Success else Theme.Colors.TextMuted,
				50 + i
			)
		end
	end

	-- Transition history
	if type(fsmData.TransitionHistory) == "table" and #fsmData.TransitionHistory > 0 then
		Theme.CreateLabel({
			Text = "TRANSITION HISTORY",
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Parent = contentFrame,
		}).LayoutOrder = 100

		local historyCount = math.min(#fsmData.TransitionHistory, 20)
		for j = 1, historyCount do
			local idx = #fsmData.TransitionHistory - historyCount + j
			local entry = fsmData.TransitionHistory[idx]
			if entry then
				local from = entry.From or "?"
				local to = entry.To or "?"
				self:_BuildPropRow(contentFrame, from .. " → " .. to, entry.Time and string.format("%.2fs", entry.Time) or "", Theme.Colors.Cyan, 100 + j)
			end
		end
	end
end

-- ══════════════════════════════════════════════════════════════
-- STATE GRAPH VISUALIZER
-- ══════════════════════════════════════════════════════════════

--[=[
	Choose a layout strategy based on node count and return positions
	in normalized [0,1] coordinates.
	@param states { string }
	@param currentState string?
	@return { [string]: { X: number, Y: number } }
]=]
function FSMModule:_ComputeNodeLayout(states: { string }, currentState: string?): { [string]: { X: number, Y: number } }
	local positions = {}
	local n = #states

	if n == 0 then return positions end

	if n == 1 then
		positions[states[1]] = { X = 0.5, Y = 0.5 }
		return positions
	end

	if n <= 6 then
		-- Circle layout for small FSMs
		local radiusX = 0.34
		local radiusY = 0.36
		for i, name in ipairs(states) do
			local angle = ((i - 1) / n) * math.pi * 2 - math.pi / 2
			positions[name] = {
				X = 0.5 + math.cos(angle) * radiusX,
				Y = 0.5 + math.sin(angle) * radiusY,
			}
		end
		return positions
	end

	if n <= 20 then
		-- Grid layout for medium FSMs
		local cols = math.ceil(math.sqrt(n))
		local rows = math.ceil(n / cols)
		local hPad = 0.1
		local vPad = 0.12
		for i, name in ipairs(states) do
			local r = math.floor((i - 1) / cols)
			local c = (i - 1) % cols
			positions[name] = {
				X = hPad + c * (1 - 2 * hPad) / math.max(cols - 1, 1),
				Y = vPad + r * (1 - 2 * vPad) / math.max(rows - 1, 1),
			}
		end
		return positions
	end

	-- Large FSM: focus on current state + 1-hop neighborhood; remaining states stacked
	local center = currentState or states[1]
	positions[center] = { X = 0.5, Y = 0.5 }
	local visible = { center }
	-- Place remaining around the center in a circle
	local remaining = {}
	for _, s in ipairs(states) do
		if s ~= center then table.insert(remaining, s) end
	end
	local maxNeighbors = math.min(#remaining, 12)
	for i = 1, maxNeighbors do
		local angle = ((i - 1) / maxNeighbors) * math.pi * 2 - math.pi / 2
		positions[remaining[i]] = {
			X = 0.5 + math.cos(angle) * 0.36,
			Y = 0.5 + math.sin(angle) * 0.38,
		}
		table.insert(visible, remaining[i])
	end
	-- Mark hidden states with sentinel positions (off-screen) so edges still render
	-- but they won't be drawn as nodes. Caller checks for these.
	for i = maxNeighbors + 1, #remaining do
		positions[remaining[i]] = { X = -10, Y = -10 } -- off-screen
	end
	return positions
end

function FSMModule:_BuildGraphLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	-- ── Live re-snapshot ──
	if context.PlaybackMode ~= "step" then
		local nexus = context.Nexus
		local fsmId = context.FSMId
		if nexus and fsmId then
			local fresh: any = nil
			-- Local-VM live FSM (client-origin)
			local orchestrator = nexus._orchestrator
			if orchestrator then
				local fsms
				if type(orchestrator.GetStateMachines) == "function" then
					local ok, result = pcall(orchestrator.GetStateMachines)
					if ok and type(result) == "table" then fsms = result end
				end
				fsms = fsms or orchestrator.StateMachines
				local liveFsm = fsms and fsms[fsmId]
				if liveFsm then
					fresh = self:_ExtractFSMData(fsmId, liveFsm)
					fresh.Origin = "client"
				end
			end
			-- Otherwise pull from the server snapshot (server-origin FSM)
			if not fresh and nexus._serverData and nexus._serverData.FSM then
				local list = nexus._serverData.FSM.List or nexus._serverData.FSM.StateMachines or {}
				local serverFsm = list[fsmId]
				if serverFsm and type(serverFsm) == "table" then
					fresh = {
						Id = fsmId,
						CurrentState = serverFsm.CurrentState or serverFsm.State or "unknown",
						States = serverFsm.States or serverFsm.validStates or (context.FSMData and context.FSMData.States) or {},
						Transitions = serverFsm.Transitions or serverFsm.TransitionCount or 0,
						Status = serverFsm.Status or "active",
						CreatedAt = serverFsm.CreatedAt or 0,
						LastTransition = serverFsm.LastTransition or serverFsm.LastTransitionTime or 0,
						TransitionHistory = serverFsm.TransitionHistory or {},
						_transitions = serverFsm._transitions or (context.FSMData and context.FSMData._transitions),
						Error = serverFsm.Error,
						IsStalled = serverFsm.IsStalled or false,
						EntityId = serverFsm.EntityId,
						Name = serverFsm.Name,
						Origin = "server",
					}
				end
			end
			if fresh then
				context.FSMData = fresh
			end
		end
	end

	local fsmData = context.FSMData or {}
	local states = fsmData.States or {}
	local history = fsmData.TransitionHistory or {}
	local historyN = #history

	-- ── Playback state (persists across RebuildCurrentLayer via context) ──
	-- PlaybackMode: "live" (follow real-time fsmData.CurrentState) or "step"
	-- PlaybackStep: 1..historyN — the entry whose .To is the rendered state
	-- Default: live for active FSMs, step (at last entry) for completed FSMs
	if context.PlaybackMode == nil then
		if fsmData.Status == "active" then
			context.PlaybackMode = "live"
			context.PlaybackStep = nil
		else
			context.PlaybackMode = "step"
			context.PlaybackStep = historyN
		end
	end

	-- Set LiveUpdate flag so ServiceBrain re-renders this drill-down every tick
	-- when in live mode. Clear it when in step mode so the user can scrub
	-- through history without the brain rubber-banding back to live state.
	context.LiveUpdate = (context.PlaybackMode == "live")

	-- ── Compute effective state to render + highlighted edge ──
	local effectiveCurrentState: string
	local highlightedEdgeKey: string? = nil
	local stepEntry: any = nil

	if context.PlaybackMode == "step" and historyN > 0 then
		local stepIdx = math.clamp(context.PlaybackStep or historyN, 1, historyN)
		context.PlaybackStep = stepIdx
		stepEntry = history[stepIdx]
		effectiveCurrentState = stepEntry.To
		if stepEntry.From and stepEntry.To then
			highlightedEdgeKey = stepEntry.From .. "->" .. stepEntry.To
		end
	else
		effectiveCurrentState = fsmData.CurrentState
		-- In live mode, briefly highlight the most recent transition edge
		if historyN > 0 then
			local last = history[historyN]
			if last and last.From and last.To then
				highlightedEdgeKey = last.From .. "->" .. last.To
			end
		end
	end

	if type(states) ~= "table" or #states == 0 then
		local emptyContainer = Instance.new("Frame")
		emptyContainer.Size = UDim2.new(1, 0, 1, 0)
		emptyContainer.BackgroundTransparency = 1
		emptyContainer.Parent = contentFrame
		Theme.CreateLabel({
			Text = '<font color="#666">◆</font>  <b>No states available for visualization</b>',
			Size = UDim2.new(1, 0, 0, 24),
			Position = UDim2.new(0, 0, 0.4, 0),
			Color = Theme.Colors.TextSecondary,
			FontSize = Theme.TextSize.Body,
			Alignment = Enum.TextXAlignment.Center,
			Parent = emptyContainer,
		})
		Theme.CreateLabel({
			Text = "FSM may have completed; reopen this view after a transition to see the graph.",
			Size = UDim2.new(1, 0, 0, 18),
			Position = UDim2.new(0, 0, 0.46, 0),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			Alignment = Enum.TextXAlignment.Center,
			Parent = emptyContainer,
		})
		return
	end

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 10)
	pad.Parent = contentFrame

	-- Header with refresh button (drill-down is a snapshot; click refresh to update)
	local headerRow = Instance.new("Frame")
	headerRow.Size = UDim2.new(1, 0, 0, 26)
	headerRow.BackgroundTransparency = 1
	headerRow.Parent = contentFrame

	Theme.CreateLabel({
		Text = string.format('<font color="#3898FF">◆</font> State Graph — <b>%s</b>  <font color="#666">(%d states, %s active)</font>',
			tostring(context.FSMId or ""), #states, tostring(fsmData.CurrentState or "—")),
		Size = UDim2.new(1, -100, 1, 0),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = headerRow,
	})

	local refreshBtn = Instance.new("TextButton")
	refreshBtn.Size = UDim2.new(0, 88, 0, 22)
	refreshBtn.Position = UDim2.new(1, -90, 0, 2)
	refreshBtn.BackgroundColor3 = Theme.Colors.GlassTertiary
	refreshBtn.BackgroundTransparency = 0.4
	refreshBtn.BorderSizePixel = 0
	refreshBtn.Text = "Refresh"
	refreshBtn.TextColor3 = Theme.Colors.TextSecondary
	refreshBtn.TextSize = Theme.TextSize.Caption
	refreshBtn.FontFace = Theme.Font.Bold
	refreshBtn.AutoButtonColor = false
	refreshBtn.Parent = headerRow
	Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	-- ── Playback toolbar (⏮ ◀ Live/Step ▶ ⏭ + step indicator) ──
	-- Lives between the header and the layout/legend row. Lets the user
	-- step backward and forward through TransitionHistory to inspect the
	-- FSM at any point in time. Default is Live for active FSMs and Step
	-- (positioned at the last entry) for completed/failed FSMs.
	local playbackBar = Instance.new("Frame")
	playbackBar.Name = "PlaybackBar"
	playbackBar.Size = UDim2.new(1, 0, 0, 26)
	playbackBar.Position = UDim2.new(0, 0, 0, 28)
	playbackBar.BackgroundColor3 = Theme.Colors.GlassTertiary
	playbackBar.BackgroundTransparency = 0.55
	playbackBar.BorderSizePixel = 0
	playbackBar.Parent = contentFrame
	Instance.new("UICorner", playbackBar).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	local pbPad = Instance.new("UIPadding")
	pbPad.PaddingLeft = UDim.new(0, 8)
	pbPad.PaddingRight = UDim.new(0, 8)
	pbPad.Parent = playbackBar

	local pbLayout = Instance.new("UIListLayout")
	pbLayout.FillDirection = Enum.FillDirection.Horizontal
	pbLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pbLayout.Padding = UDim.new(0, 4)
	pbLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	pbLayout.Parent = playbackBar

	local function rebuildLayer()
		local nexus = context.Nexus
		if nexus and nexus._navigator then
			nexus._navigator:RebuildCurrentLayer()
		end
	end

	local function setStep(newStep: number?)
		if newStep == nil then
			context.PlaybackMode = "live"
			context.PlaybackStep = nil
		else
			context.PlaybackMode = "step"
			context.PlaybackStep = math.clamp(newStep, 1, math.max(historyN, 1))
		end
		rebuildLayer()
	end

	local function pbButton(label: string, order: number, enabled: boolean, onClick: () -> ())
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, 32, 0, 20)
		b.BackgroundColor3 = Theme.Colors.GlassPrimary
		b.BackgroundTransparency = if enabled then 0.4 else 0.85
		b.BorderSizePixel = 0
		b.Text = label
		b.TextColor3 = if enabled then Theme.Colors.TextPrimary else Theme.Colors.TextMuted
		b.TextSize = Theme.TextSize.Caption
		b.FontFace = Theme.Font.Bold
		b.AutoButtonColor = false
		b.LayoutOrder = order
		b.Active = enabled
		b.Parent = playbackBar
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, Theme.Radius.Xs)
		if enabled then b.MouseButton1Click:Connect(onClick) end
		return b
	end

	local curStep = context.PlaybackStep or historyN
	local isLive = context.PlaybackMode == "live"

	pbButton("⏮", 1, historyN > 0, function() setStep(1) end)
	pbButton("◀", 2, historyN > 0 and (isLive or curStep > 1), function()
		setStep(if isLive then math.max(historyN - 1, 1) else curStep - 1)
	end)

	-- Live/Step toggle
	local liveBtn = Instance.new("TextButton")
	liveBtn.Size = UDim2.new(0, 56, 0, 20)
	liveBtn.BackgroundColor3 = if isLive then Theme.Colors.Success else Theme.Colors.GlassPrimary
	liveBtn.BackgroundTransparency = 0.3
	liveBtn.BorderSizePixel = 0
	liveBtn.Text = if isLive then "● LIVE" else "STEP"
	liveBtn.TextColor3 = Theme.Colors.TextPrimary
	liveBtn.TextSize = Theme.TextSize.Tiny
	liveBtn.FontFace = Theme.Font.Bold
	liveBtn.AutoButtonColor = false
	liveBtn.LayoutOrder = 3
	liveBtn.Parent = playbackBar
	Instance.new("UICorner", liveBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)
	liveBtn.MouseButton1Click:Connect(function()
		setStep(if isLive then historyN else nil)
	end)

	pbButton("▶", 4, historyN > 0 and not isLive and curStep < historyN, function()
		setStep(curStep + 1)
	end)
	pbButton("⏭", 5, historyN > 0 and not isLive, function() setStep(historyN) end)

	-- Step indicator label
	local stepText
	if historyN == 0 then
		stepText = "no transitions yet"
	elseif isLive then
		stepText = string.format("watching live  ·  %d transitions", historyN)
	else
		stepText = string.format("step %d of %d  ·  click history to jump", curStep, historyN)
	end
	Theme.CreateLabel({
		Text = stepText,
		Size = UDim2.new(0, 280, 1, 0),
		Color = Theme.Colors.TextSecondary,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Parent = playbackBar,
	}).LayoutOrder = 6

	-- Determine layout style label
	local layoutMode = "circle"
	if #states > 6 and #states <= 20 then layoutMode = "grid"
	elseif #states > 20 then layoutMode = "neighborhood" end

	-- Layout label + small legend showing color key for nodes
	local subRow = Instance.new("Frame")
	subRow.Size = UDim2.new(1, 0, 0, 16)
	subRow.Position = UDim2.new(0, 0, 0, 58)
	subRow.BackgroundTransparency = 1
	subRow.Parent = contentFrame

	local subLayout = Instance.new("UIListLayout")
	subLayout.FillDirection = Enum.FillDirection.Horizontal
	subLayout.SortOrder = Enum.SortOrder.LayoutOrder
	subLayout.Padding = UDim.new(0, 10)
	subLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	subLayout.Parent = subRow

	Theme.CreateLabel({
		Text = string.format("Layout: <b>%s</b>", layoutMode),
		Size = UDim2.new(0, 110, 1, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Tiny,
		Parent = subRow,
	}).LayoutOrder = 1

	-- Legend pills
	local function legendPill(text: string, color: Color3, order: number)
		local pill = Instance.new("Frame")
		pill.Size = UDim2.new(0, 90, 0, 14)
		pill.BackgroundTransparency = 1
		pill.LayoutOrder = order
		pill.Parent = subRow

		local dot = Instance.new("Frame")
		dot.Size = UDim2.new(0, 8, 0, 8)
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.new(0, 0, 0.5, 0)
		dot.BackgroundColor3 = color
		dot.BorderSizePixel = 0
		dot.Parent = pill
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

		Theme.CreateLabel({
			Text = text,
			Size = UDim2.new(1, -14, 1, 0),
			Position = UDim2.new(0, 14, 0, 0),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Tiny,
			Parent = pill,
		})
	end
	legendPill("● Active", Theme.Colors.Accent, 2)
	legendPill("○ State", Theme.Colors.GlassSecondary, 3)
	legendPill("→ Highlighted", Theme.Colors.Warning, 4)

	-- ── Main area: graph (left) + step detail panel (right) ──
	-- The detail panel only renders content in step mode (when stepEntry != nil).
	-- Layout offsets: header(26) + spacing(2) + playback(26) + spacing(4) + sub(16) = 74
	local PANEL_HEIGHT = 110
	local TOP_OFFSET = 78
	local DETAIL_W = 260
	local hasDetailPanel = stepEntry ~= nil

	-- Graph canvas
	local graphContainer = Instance.new("Frame")
	graphContainer.Name = "Graph"
	graphContainer.Size = UDim2.new(1, if hasDetailPanel then -DETAIL_W - 8 else 0, 1, -TOP_OFFSET - PANEL_HEIGHT - 8)
	graphContainer.Position = UDim2.new(0, 0, 0, TOP_OFFSET)
	graphContainer.BackgroundColor3 = Theme.Colors.CardBG
	graphContainer.BackgroundTransparency = 0.6
	graphContainer.BorderSizePixel = 0
	graphContainer.ClipsDescendants = true
	graphContainer.Parent = contentFrame
	Instance.new("UICorner", graphContainer).CornerRadius = UDim.new(0, Theme.Radius.Sm)

	-- Edge geometry (pixel length + rotation) is computed from `parent.AbsoluteSize`
	-- at draw time. When the user resizes the window, the nodes follow (their
	-- positions are scale-based) but the edges keep their original pixel length,
	-- so they no longer connect node centers cleanly. We rebuild the layer on
	-- a debounced AbsoluteSize change to re-derive edge geometry.
	if context.Nexus and context.Nexus._navigator then
		context._lastResizeRebuild = context._lastResizeRebuild or 0
		graphContainer:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			-- Debounce: rebuild at most once per 0.15s of resize spam.
			local now = os.clock()
			if now - (context._lastResizeRebuild or 0) < 0.15 then return end
			context._lastResizeRebuild = now
			task.defer(function()
				if context.Nexus and context.Nexus._navigator then
					context.Nexus._navigator:RebuildCurrentLayer()
				end
			end)
		end)
	end

	if hasDetailPanel then
		self:_BuildStepDetailPanel(contentFrame, stepEntry, curStep, historyN, TOP_OFFSET, DETAIL_W, PANEL_HEIGHT)
	end

	-- Compute layout (use effective current state so neighborhood mode centers on it)
	local nodePositions = self:_ComputeNodeLayout(states, effectiveCurrentState)

	-- Tally transition counts to size edges
	local edgeCounts: { [string]: number } = {}
	if type(history) == "table" then
		for _, entry in ipairs(history) do
			if entry.From and entry.To then
				local key = entry.From .. "->" .. entry.To
				edgeCounts[key] = (edgeCounts[key] or 0) + 1
			end
		end
	end
	-- Also include _transitions if present (declared transitions)
	if type(fsmData._transitions) == "table" then
		for from, toSet in pairs(fsmData._transitions) do
			if type(toSet) == "table" then
				for _, to in ipairs(toSet) do
					local key = from .. "->" .. to
					edgeCounts[key] = edgeCounts[key] or 0
				end
			elseif type(toSet) == "string" then
				local key = from .. "->" .. toSet
				edgeCounts[key] = edgeCounts[key] or 0
			end
		end
	end

	-- Find max count for edge thickness scaling
	local maxCount = 0
	for _, c in pairs(edgeCounts) do
		if c > maxCount then maxCount = c end
	end

	-- De-clutter: when there are many transitions, only show ×N labels for
	-- counts above a threshold. Highlighted edges always show their count.
	local labelMinCount = if maxCount > 30 then math.max(2, math.floor(maxCount * 0.1)) else 2

	-- Draw edges first (under nodes). Highlight the active step's edge.
	for edgeKey, count in pairs(edgeCounts) do
		local arrow = string.find(edgeKey, "->")
		if not arrow then continue end
		local from = edgeKey:sub(1, arrow - 1)
		local to = edgeKey:sub(arrow + 2)
		local fp = nodePositions[from]
		local tp = nodePositions[to]
		if not fp or not tp then continue end
		if fp.X < 0 or tp.X < 0 then continue end

		local isHighlighted = (edgeKey == highlightedEdgeKey)
		if from == to then
			self:_DrawSelfLoop(graphContainer, fp, count, maxCount, isHighlighted)
		else
			self:_DrawDirectedEdge(graphContainer, fp, tp, count, maxCount, isHighlighted, labelMinCount)
		end
	end

	-- Draw nodes
	for _, stateName in ipairs(states) do
		local pos = nodePositions[stateName]
		if not pos then continue end
		if pos.X < 0 then continue end -- off-screen for large FSMs

		local isCurrent = (stateName == effectiveCurrentState)
		local nodeColor = if isCurrent then Theme.Colors.Accent else Theme.Colors.GlassSecondary
		local nodeSize = if isCurrent then 60 else 44

		local nodeBtn = Instance.new("TextButton")
		nodeBtn.Name = "Node_" .. stateName
		nodeBtn.Size = UDim2.new(0, nodeSize, 0, nodeSize)
		nodeBtn.Position = UDim2.new(pos.X, -nodeSize / 2, pos.Y, -nodeSize / 2)
		nodeBtn.BackgroundColor3 = nodeColor
		nodeBtn.BackgroundTransparency = if isCurrent then 0.15 else 0.55
		nodeBtn.BorderSizePixel = 0
		nodeBtn.Text = ""
		nodeBtn.AutoButtonColor = false
		nodeBtn.ZIndex = 5
		nodeBtn.Parent = graphContainer
		Instance.new("UICorner", nodeBtn).CornerRadius = UDim.new(1, 0)

		if isCurrent then
			local stroke = Instance.new("UIStroke")
			stroke.Color = Theme.Colors.Accent
			stroke.Thickness = 3
			stroke.Transparency = 0.2
			stroke.Parent = nodeBtn

			-- Pulsing ring for active state
			local pulseRing = Instance.new("Frame")
			pulseRing.Size = UDim2.new(1.4, 0, 1.4, 0)
			pulseRing.Position = UDim2.new(-0.2, 0, -0.2, 0)
			pulseRing.BackgroundTransparency = 1
			pulseRing.BorderSizePixel = 0
			pulseRing.ZIndex = 4
			pulseRing.Parent = nodeBtn
			local pc = Instance.new("UICorner")
			pc.CornerRadius = UDim.new(1, 0)
			pc.Parent = pulseRing
			local pStroke = Instance.new("UIStroke")
			pStroke.Color = Theme.Colors.Accent
			pStroke.Thickness = 2
			pStroke.Transparency = 0.6
			pStroke.Parent = pulseRing
		end

		-- Label inside the circle gets clipped if the state name is long
		-- (e.g. "Maintenance" in a 44px circle truncates to "Mainten…").
		-- For non-current short names we keep the in-circle label; otherwise
		-- we place it just below the node so it's fully readable.
		local fitsInCircle = #stateName <= 6
		if fitsInCircle then
			Theme.CreateLabel({
				Text = stateName,
				Size = UDim2.new(1, 0, 1, 0),
				Color = if isCurrent then Theme.Colors.TextOnAccent else Theme.Colors.TextPrimary,
				FontSize = if isCurrent then Theme.TextSize.Caption else Theme.TextSize.Tiny,
				FontFace = if isCurrent then Theme.Font.Bold else Theme.Font.SemiBold,
				Alignment = Enum.TextXAlignment.Center,
				Parent = nodeBtn,
			}).ZIndex = 6
		else
			-- For long names: small dot label inside (initial) + full label below
			Theme.CreateLabel({
				Text = string.sub(stateName, 1, 1),
				Size = UDim2.new(1, 0, 1, 0),
				Color = if isCurrent then Theme.Colors.TextOnAccent else Theme.Colors.TextPrimary,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Alignment = Enum.TextXAlignment.Center,
				Parent = nodeBtn,
			}).ZIndex = 6

			local fullLbl = Theme.CreateLabel({
				Text = stateName,
				Size = UDim2.new(0, 96, 0, 14),
				Position = UDim2.new(0.5, -48, 1, 2),
				Color = if isCurrent then Theme.Colors.Accent else Theme.Colors.TextPrimary,
				FontSize = Theme.TextSize.Tiny,
				FontFace = if isCurrent then Theme.Font.Bold else Theme.Font.SemiBold,
				Alignment = Enum.TextXAlignment.Center,
				Parent = nodeBtn,
			})
			fullLbl.ZIndex = 6
		end
	end

	-- Refresh button rebuilds the layer with current FSM data
	refreshBtn.MouseButton1Click:Connect(function()
		local nexus = context.Nexus
		if nexus and nexus._navigator then
			-- Re-snapshot the FSM
			local fsmId = context.FSMId
			if nexus._orchestrator and fsmId then
				-- Use GetStateMachines() to get a fresh registry snapshot
				-- (orchestrator.StateMachines field is bound once at init).
				local fsms = if nexus._orchestrator.GetStateMachines
					then nexus._orchestrator.GetStateMachines()
					else (nexus._orchestrator.StateMachines or {})
				local newFsm = fsms[fsmId]
				if newFsm then
					context.FSMData = self:_ExtractFSMData(fsmId, newFsm)
				end
			end
			nexus._navigator:RebuildCurrentLayer()
		end
	end)

	-- ─── TRANSITION HISTORY PANEL ───
	-- A scrollable list of recent transitions with directional arrows.
	-- Renders BELOW the graph as a fixed-height bottom strip. The graph
	-- container is shrunk at the bottom of this function to make room.
	local PANEL_HEIGHT = 110

	local historyPanel = Instance.new("Frame")
	historyPanel.Name = "TransitionHistoryRoot"
	historyPanel.Size = UDim2.new(1, 0, 0, PANEL_HEIGHT)
	historyPanel.AnchorPoint = Vector2.new(0, 1)
	historyPanel.Position = UDim2.new(0, 0, 1, 0)
	historyPanel.BackgroundColor3 = Theme.Colors.GlassPrimary
	historyPanel.BackgroundTransparency = 0.7
	historyPanel.BorderSizePixel = 0
	historyPanel.Parent = contentFrame
	Instance.new("UICorner", historyPanel).CornerRadius = UDim.new(0, Theme.Radius.Sm)

	-- Header inside the panel
	local historyHeader = Instance.new("Frame")
	historyHeader.Size = UDim2.new(1, 0, 0, 18)
	historyHeader.BackgroundTransparency = 1
	historyHeader.Parent = historyPanel
	Theme.CreateLabel({
		Text = string.format('<font color="#3898FF">≡</font>  <b>Transition History</b>  <font color="#666">(%d)</font>',
			(fsmData.TransitionHistory and #fsmData.TransitionHistory) or 0),
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = historyHeader,
	})

	local historyScroll = Instance.new("ScrollingFrame")
	historyScroll.Name = "TransitionHistory"
	historyScroll.Size = UDim2.new(1, 0, 1, -18)
	historyScroll.Position = UDim2.new(0, 0, 0, 18)
	historyScroll.BackgroundTransparency = 1
	historyScroll.BorderSizePixel = 0
	historyScroll.ScrollBarThickness = 4
	historyScroll.ScrollBarImageColor3 = Theme.Colors.Accent
	historyScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	historyScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	historyScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	historyScroll.Parent = historyPanel

	local hpLayout = Instance.new("UIListLayout")
	hpLayout.SortOrder = Enum.SortOrder.LayoutOrder
	hpLayout.Padding = UDim.new(0, 2)
	hpLayout.Parent = historyScroll

	local hpPad = Instance.new("UIPadding")
	hpPad.PaddingTop = UDim.new(0, 4)
	hpPad.PaddingBottom = UDim.new(0, 4)
	hpPad.PaddingLeft = UDim.new(0, 8)
	hpPad.PaddingRight = UDim.new(0, 8)
	hpPad.Parent = historyScroll

	local transitions = fsmData.TransitionHistory or {}
	if #transitions == 0 then
		Theme.CreateLabel({
			Text = "(no transitions recorded yet — interactions will appear here)",
			Size = UDim2.new(1, 0, 0, 18),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Center,
			Parent = historyScroll,
		}).LayoutOrder = 1
	else
		-- Render newest first; rows are click-to-jump.
		local maxEntries = math.min(#transitions, 60)
		for idx = #transitions, math.max(1, #transitions - maxEntries + 1), -1 do
			local entry = transitions[idx]
			local order = (#transitions - idx) + 1

			local row = Instance.new("TextButton")
			row.Name = "Transition_" .. order
			row.Size = UDim2.new(1, 0, 0, 18)
			row.AutoButtonColor = false
			row.Text = ""
			row.BorderSizePixel = 0
			row.LayoutOrder = order
			row.Parent = historyScroll

			local isSelected = (context.PlaybackMode == "step" and curStep == idx)
			row.BackgroundColor3 = if isSelected then Theme.Colors.Accent else Theme.Colors.GlassSecondary
			row.BackgroundTransparency = if isSelected then 0.55 else 0.92

			-- Index badge
			Theme.CreateLabel({
				Text = string.format("#%d", idx),
				Size = UDim2.new(0, 28, 1, 0),
				Position = UDim2.new(0, 4, 0, 0),
				Color = if isSelected then Theme.Colors.TextOnAccent else Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Tiny,
				FontFace = Theme.Font.Mono,
				Alignment = Enum.TextXAlignment.Left,
				Parent = row,
			})

			-- From → To with arrow (directional indicator)
			local fromState = tostring(entry.From or "?")
			local toState = tostring(entry.To or "?")
			local isCurrent = (toState == effectiveCurrentState)
			Theme.CreateLabel({
				Text = string.format(
					'<font color="#9DC9FF">%s</font>  <font color="#3898FF">▶</font>  <font color="%s">%s</font>',
					fromState,
					if isCurrent then "#3CD278" else "#9DC9FF",
					toState),
				Size = UDim2.new(1, -110, 1, 0),
				Position = UDim2.new(0, 36, 0, 0),
				Color = Theme.Colors.TextPrimary,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Mono,
				Parent = row,
			})

			-- Timestamp (relative)
			local timeStr = "—"
			if entry.Time then
				local ago = os.clock() - entry.Time
				if ago < 1 then timeStr = string.format("%.0fms", ago * 1000)
				elseif ago < 60 then timeStr = string.format("%.1fs", ago)
				else timeStr = string.format("%.0fm", ago / 60)
				end
			end
			Theme.CreateLabel({
				Text = timeStr,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.new(0, 60, 1, 0),
				Color = if isSelected then Theme.Colors.TextOnAccent else Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Tiny,
				FontFace = Theme.Font.Mono,
				Alignment = Enum.TextXAlignment.Right,
				Parent = row,
			})

			row.MouseButton1Click:Connect(function() setStep(idx) end)
		end
	end

	-- Graph container size already accounts for the history panel via
	-- `1, -TOP_OFFSET - PANEL_HEIGHT - 8` so no resize needed here.
end

--[=[
	Build the right-side "step details" panel showing what happened at the
	currently-selected transition step. Renders Time, WaitSpan, Args, and a
	sanitized Context snapshot. Read-only, scrollable.

	@param parent Frame -- contentFrame
	@param entry { From, To, Time, Args, WaitSpan, ContextSnapshot, TransitionId }
	@param stepIdx number
	@param totalSteps number
	@param topOffset number -- y pixel offset of the panel
	@param panelW number -- pixel width
	@param bottomReserve number -- pixels reserved at bottom for the history panel
]=]
function FSMModule:_BuildStepDetailPanel(parent: Frame, entry: any, stepIdx: number, totalSteps: number, topOffset: number, panelW: number, bottomReserve: number)
	local panel = Instance.new("Frame")
	panel.Name = "StepDetailPanel"
	panel.Size = UDim2.new(0, panelW, 1, -topOffset - bottomReserve - 8)
	panel.Position = UDim2.new(1, -panelW, 0, topOffset)
	panel.BackgroundColor3 = Theme.Colors.GlassPrimary
	panel.BackgroundTransparency = 0.6
	panel.BorderSizePixel = 0
	panel.Parent = parent
	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, Theme.Radius.Sm)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Colors.BorderSubtle
	stroke.Thickness = 1
	stroke.Transparency = 0.6
	stroke.Parent = panel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 1, 0)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Theme.Colors.Accent
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = scroll

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = scroll

	local order = 0
	local function lbl(text: string, color: Color3, size: number, font: Font)
		order += 1
		Theme.CreateLabel({
			Text = text,
			Size = UDim2.new(1, 0, 0, size + 2),
			Color = color,
			FontSize = size,
			FontFace = font,
			Alignment = Enum.TextXAlignment.Left,
			Parent = scroll,
		}).LayoutOrder = order
	end

	lbl(string.format("STEP %d / %d", stepIdx, totalSteps), Theme.Colors.Accent, Theme.TextSize.Caption, Theme.Font.Bold)

	local fromState = tostring(entry.From or "(initial)")
	local toState = tostring(entry.To or "?")
	lbl(string.format('<b>%s</b>  <font color="#3898FF">▶</font>  <b>%s</b>', fromState, toState),
		Theme.Colors.TextPrimary, Theme.TextSize.Body, Theme.Font.Mono)

	if entry.Time then
		local ago = os.clock() - entry.Time
		lbl(string.format("at t-%.2fs", ago), Theme.Colors.TextMuted, Theme.TextSize.Tiny, Theme.Font.Mono)
	end

	if entry.WaitSpan then
		lbl(string.format("WaitSpan: <b>%.3fs</b>", entry.WaitSpan), Theme.Colors.Cyan, Theme.TextSize.Tiny, Theme.Font.Mono)
	end

	if entry.TransitionId then
		lbl(string.format("TransitionId: <b>%s</b>", tostring(entry.TransitionId)), Theme.Colors.TextMuted, Theme.TextSize.Tiny, Theme.Font.Mono)
	end

	if entry.Args and type(entry.Args) == "table" and #entry.Args > 0 then
		lbl("ARGS", Theme.Colors.TextMuted, Theme.TextSize.Tiny, Theme.Font.Bold)
		for i, a in ipairs(entry.Args) do
			if type(a) == "table" then
				order += 1
				self:_BuildContextEntryRow(scroll, string.format("[%d]", i), a, 0, order, nil)
			else
				lbl(string.format("[%d] %s", i, tostring(a)), Theme.Colors.TextSecondary, Theme.TextSize.Tiny, Theme.Font.Mono)
			end
		end
	end

	if entry.ContextSnapshot and type(entry.ContextSnapshot) == "table" then
		lbl("CONTEXT SNAPSHOT", Theme.Colors.TextMuted, Theme.TextSize.Tiny, Theme.Font.Bold)
		local count = 0
		for k, v in pairs(entry.ContextSnapshot) do
			count += 1
			if count > 60 then break end
			order += 1
			self:_BuildContextEntryRow(scroll, tostring(k), v, 0, order, nil)
		end
		if count == 0 then
			lbl("(empty)", Theme.Colors.TextMuted, Theme.TextSize.Tiny, Theme.Font.Mono)
		end
	end
end

--[=[
	Render a single Context-snapshot key/value row. Table values become
	click-to-expand buttons that insert nested rows inline. Supports
	arbitrary depth via shift-on-expand: when expanding, all rows after this
	one get their LayoutOrder incremented by the number of inserted rows.
	Collapsing destroys the captured subtree (including transitively-expanded
	descendants) and shifts back.

	@param parent Instance — the ScrollingFrame all rows are siblings in
	@param key string — display key
	@param value any — sanitized value (scalar or recursive table)
	@param depth number — current nesting depth, controls indent
	@param layoutOrder number — initial LayoutOrder; expansion shifts later rows
	@param parentSubtree { Instance }? — when present, this row registers itself
	                                     into the parent's subtree so collapsing
	                                     the ancestor cleans up grandchildren too.
]=]
function FSMModule:_BuildContextEntryRow(parent: Instance, key: string, value: any, depth: number, layoutOrder: number, ancestorSubtrees: { { Instance } }?)
	local indent = depth * 14
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 16)
	row.BackgroundTransparency = 1
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local indentPad = Instance.new("UIPadding")
	indentPad.PaddingLeft = UDim.new(0, indent)
	indentPad.Parent = row

	-- Register self into EVERY ancestor's subtree so collapsing ANY ancestor
	-- destroys this row (handles arbitrary nesting cleanup correctly).
	-- Without this, only the IMMEDIATE parent's collapse would clean us up,
	-- leaving grandchildren orphaned when an ancestor higher up collapses.
	if ancestorSubtrees then
		for _, st in ipairs(ancestorSubtrees) do
			table.insert(st, row)
		end
	end

	if type(value) == "table" then
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, 0, 1, 0)
		btn.BackgroundColor3 = Theme.Colors.GlassTertiary
		btn.BackgroundTransparency = 0.85
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.Parent = row
		Instance.new("UICorner", btn).CornerRadius = UDim.new(0, Theme.Radius.Xs)

		local n = 0
		for _ in pairs(value) do n += 1 end

		local function buildLabel(chev: string)
			return string.format(
				'<font color="#9DC9FF">%s</font> <font color="#666">%s</font> <font color="#3CD278">{%d keys}</font>',
				key, chev, n)
		end

		local label = Theme.CreateLabel({
			Text = buildLabel("▸"),
			Size = UDim2.new(1, -8, 1, 0),
			Position = UDim2.new(0, 4, 0, 0),
			Color = Theme.Colors.TextPrimary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = btn,
		})

		btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.6 end)
		btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0.85 end)

		-- mySubtree tracks ALL rows added under this one (direct children +
		-- transitively expanded grandchildren). When collapsing, we destroy
		-- everything in this list and shift downstream rows back by the size.
		local mySubtree: { Instance } = {}
		local expanded = false

		-- Build the descent list: children inherit ALL of our ancestor
		-- subtrees PLUS our own. This guarantees grandchildren register
		-- in every ancestor's subtree, not just their immediate parent's.
		local descentSubtrees: { { Instance } } = {}
		if ancestorSubtrees then
			for _, st in ipairs(ancestorSubtrees) do
				table.insert(descentSubtrees, st)
			end
		end
		table.insert(descentSubtrees, mySubtree)

		btn.MouseButton1Click:Connect(function()
			expanded = not expanded
			-- Always use row.LayoutOrder (LIVE), not the captured `layoutOrder`.
			-- If a sibling row above us was expanded earlier, our LayoutOrder
			-- has already shifted while `layoutOrder` parameter stayed stale.
			local myOrder = row.LayoutOrder
			if expanded then
				local reservedCount = n
				for _, c in ipairs(parent:GetChildren()) do
					if c:IsA("Frame") and c ~= row and c.LayoutOrder > myOrder then
						c.LayoutOrder += reservedCount
					end
				end
				local subIdx = 0
				for k, v in pairs(value) do
					subIdx += 1
					self:_BuildContextEntryRow(parent, tostring(k), v, depth + 1, myOrder + subIdx, descentSubtrees)
				end
				label.Text = buildLabel("▾")
			else
				local removedCount = #mySubtree
				for _, c in ipairs(mySubtree) do
					if c.Parent then c:Destroy() end
				end
				-- Also remove these rows from any ancestor subtrees they
				-- registered into, so re-expand later doesn't double-track them.
				if ancestorSubtrees then
					for _, st in ipairs(ancestorSubtrees) do
						local kept: { Instance } = {}
						local destroyed: { [Instance]: boolean } = {}
						for _, c in ipairs(mySubtree) do destroyed[c] = true end
						for _, c in ipairs(st) do
							if not destroyed[c] then table.insert(kept, c) end
						end
						table.clear(st)
						for _, c in ipairs(kept) do table.insert(st, c) end
					end
				end
				table.clear(mySubtree)
				for _, c in ipairs(parent:GetChildren()) do
					if c:IsA("Frame") and c ~= row and c.LayoutOrder > myOrder + removedCount then
						c.LayoutOrder -= removedCount
					end
				end
				label.Text = buildLabel("▸")
			end
		end)
	else
		Theme.CreateLabel({
			Text = string.format('<font color="#9DC9FF">%s</font> = <font color="#FFFFFF">%s</font>',
				key, tostring(value)),
			Size = UDim2.new(1, 0, 1, 0),
			Color = Theme.Colors.TextSecondary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
	end
end

--[=[
	Draw a directed edge with an arrowhead from `fp` to `tp`.
	Edge thickness scales with frequency (`count` relative to `maxCount`).
	@param parent Frame
	@param fp { X, Y } normalized position of source node
	@param tp { X, Y } normalized position of target node
	@param count number transition count
	@param maxCount number max transition count across all edges
	@param isHighlighted boolean? -- highlight in warning color (active step)
	@param labelMinCount number? -- minimum count to show ×N label (de-clutter)
]=]
function FSMModule:_DrawDirectedEdge(parent: Frame, fp: { X: number, Y: number }, tp: { X: number, Y: number }, count: number, maxCount: number, isHighlighted: boolean?, labelMinCount: number?)
	-- Compute geometry in normalized coords
	local dx = tp.X - fp.X
	local dy = tp.Y - fp.Y
	local dist = math.sqrt(dx * dx + dy * dy)
	if dist < 0.001 then return end

	local angle = math.atan2(dy, dx)
	local angleDeg = math.deg(angle)

	-- Approximate parent pixel dims by reading AbsoluteSize
	local absSize = parent.AbsoluteSize
	local lenPx = dist * absSize.X
	local pxDx = dx * absSize.X
	local pxDy = dy * absSize.Y
	lenPx = math.sqrt(pxDx * pxDx + pxDy * pxDy)
	angleDeg = math.deg(math.atan2(pxDy, pxDx))

	-- Shorten the edge so it doesn't overlap node circles
	local nodeRadiusPx = 22
	local trimmed = math.max(lenPx - 2 * nodeRadiusPx, 8)
	local midX = (fp.X + tp.X) / 2
	local midY = (fp.Y + tp.Y) / 2

	-- Edge thickness: 1px base + scale factor
	local thickness = 1
	if maxCount > 0 then
		thickness = 1 + math.min(count / math.max(maxCount, 1) * 3, 3)
	end
	if isHighlighted then thickness = math.max(thickness + 1.5, 3) end

	local edgeColor: Color3
	local edgeTransparency: number
	if isHighlighted then
		edgeColor = Theme.Colors.Warning
		edgeTransparency = 0
	elseif count > 0 then
		edgeColor = Theme.Colors.Accent
		edgeTransparency = 0.2
	else
		edgeColor = Theme.Colors.BorderPrimary
		edgeTransparency = 0.65
	end

	local line = Instance.new("Frame")
	line.Size = UDim2.new(0, trimmed, 0, thickness)
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.Position = UDim2.new(midX, 0, midY, 0)
	line.Rotation = angleDeg
	line.BackgroundColor3 = edgeColor
	line.BackgroundTransparency = edgeTransparency
	line.BorderSizePixel = 0
	line.ZIndex = if isHighlighted then 4 else 2
	line.Parent = parent

	-- Arrowhead: small triangle at the tip end.
	local arrowSize = if isHighlighted then 12 else 8
	local nodeRadiusFracX = nodeRadiusPx / math.max(absSize.X, 1)
	local nodeRadiusFracY = nodeRadiusPx / math.max(absSize.Y, 1)
	local arrowX = tp.X - math.cos(angle) * nodeRadiusFracX
	local arrowY = tp.Y - math.sin(angle) * nodeRadiusFracY

	local arrow = Instance.new("TextLabel")
	arrow.Size = UDim2.new(0, arrowSize, 0, arrowSize)
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.new(arrowX, 0, arrowY, 0)
	arrow.BackgroundTransparency = 1
	arrow.Text = "▶"
	arrow.TextColor3 = edgeColor
	arrow.TextSize = arrowSize + 4
	arrow.FontFace = Theme.Font.Bold
	arrow.Rotation = angleDeg
	arrow.TextXAlignment = Enum.TextXAlignment.Center
	arrow.ZIndex = if isHighlighted then 5 else 3
	arrow.Parent = parent

	-- Frequency label (when above threshold OR highlighted)
	local minCount = labelMinCount or 2
	if count >= minCount or isHighlighted then
		local freqLbl = Instance.new("TextLabel")
		freqLbl.Size = UDim2.new(0, 24, 0, 14)
		freqLbl.AnchorPoint = Vector2.new(0.5, 0.5)
		freqLbl.Position = UDim2.new(midX, 0, midY, -8)
		freqLbl.BackgroundColor3 = if isHighlighted then Theme.Colors.Warning else Theme.Colors.GlassPrimary
		freqLbl.BackgroundTransparency = if isHighlighted then 0 else 0.3
		freqLbl.BorderSizePixel = 0
		freqLbl.Text = "×" .. tostring(count)
		freqLbl.TextColor3 = if isHighlighted then Theme.Colors.TextOnAccent else Theme.Colors.TextSecondary
		freqLbl.TextSize = Theme.TextSize.Tiny
		freqLbl.FontFace = Theme.Font.Mono
		freqLbl.ZIndex = if isHighlighted then 6 else 4
		freqLbl.Parent = parent
		Instance.new("UICorner", freqLbl).CornerRadius = UDim.new(0, Theme.Radius.Xs)
	end
end

--[=[
	Draw a self-loop arc above the node with a count badge.
	@param parent Frame
	@param pos { X, Y } normalized node position
	@param count number transition count
	@param maxCount number
	@param isHighlighted boolean? -- highlight the loop in warning color
]=]
function FSMModule:_DrawSelfLoop(parent: Frame, pos: { X: number, Y: number }, count: number, maxCount: number, isHighlighted: boolean?)
	local ringColor = if isHighlighted then Theme.Colors.Warning else Theme.Colors.Accent
	local ring = Instance.new("Frame")
	ring.Name = "SelfLoopRing"
	ring.Size = UDim2.new(0, 22, 0, 22)
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.new(pos.X, 0, pos.Y, -34)
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.ZIndex = if isHighlighted then 5 else 4
	ring.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color = ringColor
	stroke.Thickness = if isHighlighted then 2.5 else 1.5
	stroke.Transparency = if isHighlighted then 0 else 0.3
	stroke.Parent = ring

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ring

	-- Direction arrowhead at the bottom of the ring (pointing into the node)
	local arrow = Instance.new("TextLabel")
	arrow.Size = UDim2.new(0, 10, 0, 10)
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.new(pos.X, 0, pos.Y, -22)
	arrow.BackgroundTransparency = 1
	arrow.Text = "↓"
	arrow.TextColor3 = ringColor
	arrow.TextSize = 12
	arrow.FontFace = Theme.Font.Bold
	arrow.ZIndex = if isHighlighted then 6 else 5
	arrow.Parent = parent

	if count > 1 then
		local badge = Instance.new("TextLabel")
		badge.Size = UDim2.new(0, 22, 0, 12)
		badge.AnchorPoint = Vector2.new(0.5, 0.5)
		badge.Position = UDim2.new(pos.X, 14, pos.Y, -34)
		badge.BackgroundColor3 = Theme.Colors.GlassPrimary
		badge.BackgroundTransparency = 0.3
		badge.BorderSizePixel = 0
		badge.Text = "×" .. tostring(count)
		badge.TextColor3 = Theme.Colors.TextSecondary
		badge.TextSize = Theme.TextSize.Tiny
		badge.FontFace = Theme.Font.Mono
		badge.ZIndex = 4
		badge.Parent = parent
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, Theme.Radius.Xs)
		bc.Parent = badge
	end
end

-- ══════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════

function FSMModule:_BuildPropRow(parent: Frame, key: string, value: string, color: Color3, order: number)
	local propRow = Instance.new("Frame")
	propRow.Size = UDim2.new(1, 0, 0, 24)
	propRow.BackgroundColor3 = Theme.Colors.GlassTertiary
	propRow.BackgroundTransparency = 0.88
	propRow.BorderSizePixel = 0
	propRow.LayoutOrder = order
	propRow.Parent = parent
	Instance.new("UICorner", propRow).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 8)
	p.PaddingRight = UDim.new(0, 8)
	p.Parent = propRow

	Theme.CreateLabel({ Text = key, Size = UDim2.new(0.45, 0, 1, 0), Color = Theme.Colors.TextSecondary, FontSize = Theme.TextSize.Caption, Parent = propRow })
	Theme.CreateLabel({ Text = value, Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0.48, 0, 0, 0), Color = color, FontSize = Theme.TextSize.Body, FontFace = Theme.Font.Mono, Alignment = Enum.TextXAlignment.Right, Parent = propRow })
end

--[[
	Release autocomplete resources and clear all cached FSM snapshots.
]]
function FSMModule:Destroy()
	if self._searchAC then self._searchAC:Destroy(); self._searchAC = nil end
	table.clear(self._fsmCache)
	table.clear(self._failedFSMs)
	table.clear(self._completedFSMs)
	table.clear(self._archivedFSMs)
end

return FSMModule
