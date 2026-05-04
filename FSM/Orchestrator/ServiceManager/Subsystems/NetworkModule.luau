--!strict


local Theme = require(script.Parent.Parent.Theme)
local SearchAutocomplete = require(script.Parent.Parent.SearchAutocomplete)

local NetworkModule = {}
NetworkModule.__index = NetworkModule

local SORT_MODES = {"Name","Type","Subscribers","Messages" }

local TYPE_COLORS: { [string]: Color3 } = {
	EntityCommand = Color3.fromRGB(100, 200, 255), -- Cyan-blue
	RemoteFunction = Color3.fromRGB(180, 140, 255), -- Purple
	RemoteEvent = Color3.fromRGB(120, 170, 255), -- Lighter blue
	NetworkCommand = Color3.fromRGB(255, 180, 80), -- Orange
	EventBus = Color3.fromRGB(60, 210, 120), -- Green
	ServerRequest = Color3.fromRGB(255, 100, 100), -- Red
	Unknown = Color3.fromRGB(140, 140, 160), -- Gray
}


function NetworkModule.new(): any
	local self = setmetatable({}, NetworkModule)
	self._commandCache = {} :: { [string]: any }
	self._eventBusCache = {} :: { [string]: any }
	self._serverCallbacks = {} :: { [string]: any }
	self._searchText = ""
	self._sortMode = "Name"
	self._selectedItem = nil :: string?
	self._nexusRef = nil :: any?
	return self
end


function NetworkModule:FetchData(nexus: any)
	local orchestrator = nexus._orchestrator
	if not orchestrator then return end

	if nexus._contextMode == "client" then
		local nm = orchestrator.NetworkManager
		if nm then
			self._commandCache = {}
			self._eventBusCache = {}
			self._serverCallbacks = {}

			-- Event Buses (Signal objects)
			local buses = nm.EventBuses or {}
			local busStats = nm._busStats or {}
			for name, bus in pairs(buses) do
				local subCount = 0
				pcall(function()
					if type(bus) == "table" then
						if bus._handlers then subCount = #bus._handlers
						elseif bus._connections then subCount = #bus._connections
						elseif bus._listeners then subCount = #bus._listeners end
					end
				end)
				local stats = busStats[name] or {}
				self._eventBusCache[name] = {
					Name = name,
					Type = "EventBus",
					Subscribers = subCount,
					MessageCount = stats.Count or 0,
					LastFired = stats.LastFired or 0,
					RecentCalls = stats.RecentCalls or {},
					Properties = {},
				}
			end

			-- Server Request Callbacks (sync)
			local syncCbs = nm.ServerRequestCallbacksSync or {}
			for name, _ in pairs(syncCbs) do
				self._commandCache[name] = {
					Name = name,
					Type = "ServerRequest",
					Handler = true,
					Subscribers = 0,
					MessageCount = 0,
					LastInvoked = 0,
					IsRemote = true,
					Validator = false,
					Properties = { Mode = "Sync" },
				}
				self._serverCallbacks[name] = {
					Name = name,
					Type = "ServerRequest",
					HasCallback = true,
				}
			end

			-- Server Request Callbacks (async)
			local asyncCbs = nm.ServerRequestCallbacksAsync or {}
			for name, _ in pairs(asyncCbs) do
				if not self._commandCache[name] then
					self._commandCache[name] = {
						Name = name,
						Type = "ServerRequest",
						Handler = true,
						Subscribers = 0,
						MessageCount = 0,
						LastInvoked = 0,
						IsRemote = true,
						Validator = false,
						Properties = { Mode = "Async" },
					}
				end
				self._serverCallbacks[name] = {
					Name = name,
					Type = "ServerRequest",
					HasCallback = true,
				}
			end

			-- Entity Command Callbacks
			local entityCbs = nm.EntityCommandCallbacks or {}
			for entityId, commands in pairs(entityCbs) do
				if type(commands) == "table" then
					for cmdName, _ in pairs(commands) do
						local fullName = entityId ..":" .. cmdName
						self._commandCache[fullName] = {
							Name = fullName,
							Type = "EntityCommand",
							Handler = true,
							Subscribers = 0,
							MessageCount = 0,
							LastInvoked = 0,
							IsRemote = false,
							Validator = false,
							Properties = { EntityId = entityId, Command = cmdName },
						}
					end
				end
			end

			-- Remote instances
			local remoteNames = {"OrchestratorEvent","OrchestratorFunction","EntityUpdateEvent","EntityCommandEvent" }
			local remoteStats = nm._remoteStats or {}
			for _, remoteName in ipairs(remoteNames) do
				local remote = nm[remoteName]
				if remote then
					-- Pull stats for this remote
					local statsKey = "Remote:" .. remoteName
					local stats = remoteStats[statsKey] or { Count = 0, LastFired = 0, RecentCalls = {} }
					-- Use accurate type based on the underlying instance class
					local realType = "RemoteFunction"
					if typeof(remote) == "Instance" then
						if remote:IsA("RemoteEvent") then realType = "RemoteEvent"
						elseif remote:IsA("RemoteFunction") then realType = "RemoteFunction"
						end
					end
					self._commandCache["Remote:" .. remoteName] = {
						Name = remoteName,
						Type = realType,
						Handler = true,
						Subscribers = 0,
						MessageCount = stats.Count or 0,
						LastInvoked = stats.LastFired or 0,
						RecentCalls = stats.RecentCalls or {},
						IsRemote = true,
						Validator = false,
						Properties = { ClassName = typeof(remote) == "Instance" and remote.ClassName or "Signal" },
					}
				end
			end
		end
	else
		local serverData = nexus._serverData
		if serverData and serverData.Network then
			self._commandCache = {}
			self._eventBusCache = {}
			self._serverCallbacks = {}

			local cmds = serverData.Network.Commands or serverData.Network.List or {}
			for name, cmdInfo in pairs(cmds) do
				if type(cmdInfo) ~= "table" then continue end
				self._commandCache[name] = {
					Name = cmdInfo.Name or name,
					Type = cmdInfo.Type or "Unknown",
					Handler = cmdInfo.HasHandler or false,
					Subscribers = cmdInfo.Subscribers or 0,
					MessageCount = cmdInfo.MessageCount or 0,
					LastInvoked = cmdInfo.LastInvoked or 0,
					RecentCalls = cmdInfo.RecentCalls or {},
					IsRemote = cmdInfo.IsRemote or false,
					Validator = cmdInfo.HasValidator or false,
					Properties = cmdInfo.Properties or {},
				}
			end

			local buses = serverData.Network.EventBuses or {}
			for name, busInfo in pairs(buses) do
				if type(busInfo) ~= "table" then continue end
				self._eventBusCache[name] = {
					Name = busInfo.Name or name,
					Type = "EventBus",
					Subscribers = busInfo.Subscribers or 0,
					MessageCount = busInfo.MessageCount or 0,
					LastFired = busInfo.LastFired or 0,
					RecentCalls = busInfo.RecentCalls or {},
					Properties = busInfo.Properties or {},
				}
			end

			-- Remote instances from server snapshot
			local remotes = serverData.Network.Remotes or {}
			for name, remoteInfo in pairs(remotes) do
				if type(remoteInfo) ~= "table" then continue end
				self._commandCache["Remote:" .. name] = {
					Name = remoteInfo.Name or name,
					Type = remoteInfo.Type or "RemoteFunction",
					Handler = true,
					Subscribers = 0,
					MessageCount = remoteInfo.MessageCount or 0,
					LastInvoked = remoteInfo.LastFired or 0,
					RecentCalls = remoteInfo.RecentCalls or {},
					IsRemote = true,
					Validator = false,
					Properties = { ClassName = remoteInfo.ClassName or "Signal" },
				}
			end

			-- Server callbacks from snapshot
			local cbs = serverData.Network.ServerCallbacks or {}
			for name, cbInfo in pairs(cbs) do
				self._serverCallbacks[name] = {
					Name = if type(cbInfo) == "table" then (cbInfo.Name or name) else name,
					Type = "ServerRequest",
					HasCallback = true,
				}
			end
		end
	end

	nexus.Store:BatchUpdate(function()
		nexus.Store:Set("network.commands", self._commandCache)
		nexus.Store:Set("network.buses", self._eventBusCache)
		nexus.Store:Set("network.callbacks", self._serverCallbacks)
	end)
end


function NetworkModule:_DetectCommandType(name: string, cmd: any): string
	if type(cmd) ~= "table" then return"Unknown" end
	if cmd.Type then return cmd.Type end

	local nameLower = string.lower(name)
	if nameLower:find("entity") then return"EntityCommand" end
	if cmd.IsRemote or cmd._isRemote then return"RemoteFunction" end
	if cmd.ServerRequestCallbacks or cmd._serverCallback then return"ServerRequest" end
	if cmd.Subscribers or cmd._subscribers then return"EventBus" end
	return"NetworkCommand"
end


function NetworkModule:_CountSubscribers(obj: any): number
	if type(obj) ~= "table" then return 0 end
	local subs = obj.Subscribers or obj._subscribers or obj.Listeners or obj._listeners
	if type(subs) == "table" then
		local count = 0
		for _ in pairs(subs) do count + = 1 end
		return count
	end
	if type(subs) == "number" then return subs end
	return 0
end


function NetworkModule:_ExtractCmdProperties(cmd: any): { [string]: any }
	local props = {}
	if type(cmd) ~= "table" then return props end
	for k, v in pairs(cmd) do
		if type(k) == "string" and not k:sub(1, 1):match("_") then
			if type(v) ~= "function" and type(v) ~= "table" then
				props[k] = v
			end
		end
	end
	return props
end


function NetworkModule:_ExtractBusProperties(bus: any): { [string]: any }
	local props = {}
	if type(bus) ~= "table" then return props end
	for k, v in pairs(bus) do
		if type(k) == "string" and not k:sub(1, 1):match("_") then
			if type(v) ~= "function" and type(v) ~= "table" then
				props[k] = v
			end
		end
	end
	return props
end


function NetworkModule:Render(_nexus: any) end


function NetworkModule:_GetAllItems(): { { Name: string, Data: any } }
	local result = {}

	for name, data in pairs(self._commandCache) do
		if self._searchText ~= "" then
			local lower = string.lower(self._searchText)
			if not string.lower(name):find(lower, 1, true)
				and not string.lower(data.Type or ""):find(lower, 1, true) then
				continue
			end
		end
		table.insert(result, { Name = name, Data = data })
	end

	for name, data in pairs(self._eventBusCache) do
		if self._searchText ~= "" then
			local lower = string.lower(self._searchText)
			if not string.lower(name):find(lower, 1, true) and not ("eventbus"):find(lower, 1, true) then
				continue
			end
		end
		table.insert(result, { Name = name, Data = data })
	end

	-- _serverCallbacks intentionally NOT iterated here. Every entry in
	-- _serverCallbacks is also present in _commandCache (with strictly more
	-- info — RecentCalls, MessageCount, etc.), so iterating both produced
	-- duplicate cards. The cache is kept around so the dispatcher's
	-- `netDetail:<name>` lookup still resolves for legacy callers.

	local mode = self._sortMode
	table.sort(result, function(a, b)
		if mode == "Name" then return a.Name < b.Name
		elseif mode == "Type" then return (a.Data.Type or "") < (b.Data.Type or "")
		elseif mode == "Subscribers" then return (a.Data.Subscribers or 0) > (b.Data.Subscribers or 0)
		elseif mode == "Messages" then return (a.Data.MessageCount or 0) > (b.Data.MessageCount or 0)
		end
		return a.Name < b.Name
	end)
	return result
end


function NetworkModule:BuildRootLayer(frame: Frame, context: any)
	local nexus = context.Nexus
	self._nexusRef = nexus -- store reference for summary strip click handlers
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

	-- Items grouped by type
	local allItems = self:_GetAllItems()
	local byType: { [string]: { { Name: string, Data: any } } } = {}
	for _, item in ipairs(allItems) do
		local t = item.Data.Type or "Unknown"
		if not byType[t] then byType[t] = {} end
		table.insert(byType[t], item)
	end

	local itemsToAnimate = {}
	local order = 20
	local typeOrder = {"EntityCommand","NetworkCommand","RemoteEvent","RemoteFunction","EventBus","ServerRequest","Unknown" }

	for _, typeName in ipairs(typeOrder) do
		local group = byType[typeName]
		if group and #group > 0 then
			local typeColor = TYPE_COLORS[typeName] or TYPE_COLORS.Unknown
			Theme.CreateLabel({
				Text = string.format('<font color="#%s">·</font> %s (%d)',
					string.format("%02X%02X%02X", math.floor(typeColor.R * 255), math.floor(typeColor.G * 255), math.floor(typeColor.B * 255)),
					typeName, #group),
				Size = UDim2.new(1, 0, 0, 18),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = order

			order + = 1
			for _, item in ipairs(group) do
				local row = self:_BuildNetworkRow(contentFrame, item.Name, item.Data, nexus, order)
				table.insert(itemsToAnimate, row)
				order + = 1
			end
			order + = 5
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


function NetworkModule:_BuildSummaryStrip(parent: Frame)
	local strip = Instance.new("Frame")
	strip.Name = "NetSummary"
	strip.Size = UDim2.new(1, 0, 0, 44)
	strip.BackgroundColor3 = Theme.Colors.CardBG
	strip.BackgroundTransparency = 0.6
	strip.BorderSizePixel = 0
	strip.LayoutOrder = 0
	strip.Parent = parent
	Instance.new("UICorner", strip).CornerRadius = UDim.new(0, Theme.Radius.Sm)

	local innerLayout = Instance.new("UIListLayout")
	innerLayout.FillDirection = Enum.FillDirection.Horizontal
	innerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	innerLayout.Padding = UDim.new(0, 12)
	innerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	innerLayout.Parent = strip

	local innerPad = Instance.new("UIPadding")
	innerPad.PaddingLeft = UDim.new(0, 12)
	innerPad.Parent = strip

	local cmdCount, busCount, cbCount, totalMsgs = 0, 0, 0, 0
	for _, d in pairs(self._commandCache) do
		cmdCount + = 1
		totalMsgs + = (d.MessageCount or 0)
	end
	for _, d in pairs(self._eventBusCache) do
		busCount + = 1
		totalMsgs + = (d.MessageCount or 0)
	end
	for _ in pairs(self._serverCallbacks) do cbCount + = 1 end

	local metrics = {
		{ Label = "COMMANDS", Value = tostring(cmdCount), Color = Theme.Colors.Accent, Filter = "commands" },
		{ Label = "BUSES", Value = tostring(busCount), Color = Theme.Colors.Success, Filter = "buses" },
		{ Label = "SRV CB", Value = tostring(cbCount), Color = Theme.Colors.Warning, Filter = "callbacks" },
		{ Label = "MESSAGES", Value = tostring(totalMsgs), Color = Theme.Colors.Cyan, Filter = nil },
	}

	for i, m in ipairs(metrics) do
		local cell = Instance.new("TextButton")
		cell.Size = UDim2.new(0, 75, 1, 0)
		cell.BackgroundTransparency = 1
		cell.Text = ""
		cell.AutoButtonColor = false
		cell.BorderSizePixel = 0
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

		-- Make metric cells clickable to filter the list by type
		if m.Filter then
			local filterType = m.Filter
			cell.MouseButton1Click:Connect(function()
				if filterType == "commands" then
					self._searchText = ""
					-- Scroll to commands section (force refresh)
				elseif filterType == "buses" then
					self._searchText = "EventBus"
				elseif filterType == "callbacks" then
					self._searchText = "ServerRequest"
				end
				if self._nexusRef then self._nexusRef._lastDataRefresh = 0 end
			end)
		end
	end
end


function NetworkModule:_BuildToolbar(parent: Frame, nexus: any)
	local toolbar = Instance.new("Frame")
	toolbar.Name = "NetToolbar"
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
	searchFrame.Size = UDim2.new(0, 200, 0, 26)
	searchFrame.BackgroundColor3 = Theme.Colors.GlassOverlay
	searchFrame.BackgroundTransparency = 0.3
	searchFrame.BorderSizePixel = 0
	searchFrame.LayoutOrder = 1
	searchFrame.Parent = toolbar
	Instance.new("UICorner", searchFrame).CornerRadius = UDim.new(0, Theme.Radius.Xs)

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
	searchBox.PlaceholderText = "Search commands..."
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
			for name, _ in pairs(self._commandCache) do
				if string.find(string.lower(name), lower, 1, true) then
					table.insert(matches, name)
				end
			end
			for name, _ in pairs(self._eventBusCache) do
				if string.find(string.lower(name), lower, 1, true) then
					table.insert(matches, name)
				end
			end
			for name, _ in pairs(self._serverCallbacks) do
				if string.find(string.lower(name), lower, 1, true) then
					table.insert(matches, name)
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

	-- Sort
	local sortBtn = Instance.new("TextButton")
	sortBtn.Size = UDim2.new(0, 95, 0, 26)
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
end


function NetworkModule:_BuildNetworkRow(parent: Frame, name: string, data: any, nexus: any, order: number): Frame
	local typeColor = TYPE_COLORS[data.Type] or TYPE_COLORS.Unknown

	local typeRgb = string.format("rgb(%d,%d,%d)",
		math.floor(typeColor.R * 255), math.floor(typeColor.G * 255), math.floor(typeColor.B * 255))

	local stats: { Theme.RowStat } = {
		{ Text = string.format("▸ %d", data.MessageCount or 0), Color = Theme.Colors.Cyan, Width = 64 },
	}

	if (data.Subscribers or 0) > 0 then
		table.insert(stats, 1, {
			Text = string.format("◐ %d", data.Subscribers),
			Color = Theme.Colors.Success,
			Width = 50,
		})
	end

	-- Type as colored badge stat (first/leftmost)
	table.insert(stats, 1, {
		Text = string.format('<font color="%s"><b>%s</b></font>', typeRgb, data.Type or "?"),
		Width = 90,
		Mono = false,
	})

	if data.Handler then
		table.insert(stats, { Text = "↯", Color = Theme.Colors.Warning, Width = 14, Mono = false })
	end
	if data.IsRemote then
		table.insert(stats, { Text = "↗", Color = Theme.Colors.Purple, Width = 16, Mono = false })
	end

	local row = Theme.CreateRow({
		Name = "Net_" .. name,
		Size = UDim2.new(1, 0, 0, 34),
		StatusColor = typeColor,
		Title = name,
		BackgroundColor = Theme.Colors.GlassTertiary,
		BackgroundTransparency = 0.85,
		LayoutOrder = order,
		Stats = stats,
		Parent = parent,
		OnClick = function()
			self._selectedItem = name
			if nexus._navigator then
				nexus._navigator:ExpandLayer({
					Id = "network.detail." .. name,
					ParentId = "NETWORK",
					Label = name,
					Builder = function(f, ctx) self:_BuildNetworkDetailLayer(f, ctx) end,
					Context = { Nexus = nexus, ItemName = name, ItemData = data },
				})
			end
		end,
	})

	-- Hover glow
	local btn = row:FindFirstChild("ClickOverlay")
	if btn and nexus._animationController then
		nexus._animationController:HoverGlow(btn, Theme.Colors.Accent)
	end

	return row
end


function NetworkModule:_BuildNetworkDetailLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	local itemName = context.ItemName or "Unknown"
	local itemData = context.ItemData or {}

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
	local typeColor = TYPE_COLORS[itemData.Type] or TYPE_COLORS.Unknown
	Theme.CreateLabel({
		Text = string.format('<font color="#%s">⬢</font> %s',
			string.format("%02X%02X%02X", math.floor(typeColor.R * 255), math.floor(typeColor.G * 255), math.floor(typeColor.B * 255)),
			itemName),
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	-- ─── ACTION BAR ───
	local nexus = context.Nexus
	local actionBar = Instance.new("Frame")
	actionBar.Name = "ActionBar"
	actionBar.Size = UDim2.new(1, 0, 0, 30)
	actionBar.BackgroundTransparency = 1
	actionBar.LayoutOrder = 1
	actionBar.Parent = contentFrame
	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection = Enum.FillDirection.Horizontal
	actionLayout.Padding = UDim.new(0, 6)
	actionLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	actionLayout.Parent = actionBar

	-- Fire / Trigger action — only sensible for fireable types (EventBus, RemoteEvent)
	local canFire = itemData.Type == "EventBus"
		or itemData.Type == "Signal"
		or itemData.Type == "RemoteEvent"
		or itemData.Type == "NetworkCommand"
	local fireBtn = Theme.CreateIconButton({
		Label = if canFire then"↯ Fire" else"↯ Fire (n/a)",
		Size = UDim2.new(0, 80, 0, 26),
		Color = if canFire then Theme.Colors.Warning else Theme.Colors.GlassTertiary,
		Parent = actionBar,
	})
	fireBtn.Name = "FireButton"
	fireBtn.LayoutOrder = 1
	fireBtn.AutoButtonColor = false
	if not canFire then
		fireBtn.TextTransparency = 0.5
	end
	fireBtn.MouseButton1Click:Connect(function()
		if not canFire then return end
		local orch = nexus and nexus._orchestrator
		if not orch then return end
		-- Best-effort fire: try EventBus path, then RemoteEvent
		local fired = false
		pcall(function()
			if itemData.Type == "EventBus" or itemData.Type == "Signal" then
				if orch.FireEventBus then
					orch.FireEventBus(itemName)
					fired = true
				end
			elseif itemData.Type == "RemoteEvent" then
				local nm = orch.NetworkManager
				if nm and nm.RemoteEvents then
					local re = nm.RemoteEvents[itemName]
					if re and re.FireServer then
						re:FireServer()
						fired = true
					end
				end
			end
		end)
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	-- View Calls — drills into recent invocation history
	local callsBtn = Theme.CreateIconButton({
		Label = "≡ View Calls",
		Size = UDim2.new(0, 110, 0, 26),
		Color = Theme.Colors.Accent,
		Parent = actionBar,
	})
	callsBtn.Name = "ViewCallsButton"
	callsBtn.LayoutOrder = 2
	callsBtn.MouseButton1Click:Connect(function()
		if nexus and nexus._navigator then
			-- Snapshot RecentCalls at click time. Otherwise the live ring buffer
			-- mutates while the layer is open; new calls insert and old ones drop
			-- as the buffer rotates, causing rows to shift indices unpredictably.
			local liveCalls = itemData.RecentCalls or itemData.CallHistory or {}
			local snapshotCalls = {}
			for i, e in ipairs(liveCalls) do
				if type(e) == "table" then
					-- Shallow-copy each entry too, so future mutations to call
					-- structures (e.g. server-side overwrite) don't bleed in.
					local copy = {}
					for k, v in pairs(e) do copy[k] = v end
					snapshotCalls[i] = copy
				else
					snapshotCalls[i] = e
				end
			end

			nexus._navigator:ExpandLayer({
				Id = "network.calls." .. itemName,
				ParentId = "network.detail." .. itemName,
				Label = "Calls",
				Builder = function(f, ctx) self:_BuildCallsHistoryLayer(f, ctx) end,
				Context = {
					Nexus = nexus,
					ItemName = itemName,
					ItemData = itemData,
					RecentCalls = snapshotCalls,
				},
			})
		end
	end)

	-- Copy ID — useful action for inspecting/scripting
	local copyBtn = Theme.CreateIconButton({
		Label = "≡ Copy",
		Size = UDim2.new(0, 70, 0, 26),
		Color = Theme.Colors.GlassTertiary,
		Parent = actionBar,
	})
	copyBtn.Name = "CopyButton"
	copyBtn.LayoutOrder = 3

	-- Identity
	Theme.CreateLabel({
		Text = "IDENTITY",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 5

	local props = {
		{ Key = "Name", Value = itemName, Color = Theme.Colors.Accent },
		{ Key = "Type", Value = itemData.Type or "Unknown", Color = typeColor },
		{ Key = "Has Handler", Value = tostring(itemData.Handler or false), Color = if itemData.Handler then Theme.Colors.Success else Theme.Colors.TextMuted },
		{ Key = "Is Remote", Value = tostring(itemData.IsRemote or false), Color = if itemData.IsRemote then Theme.Colors.Purple else Theme.Colors.TextMuted },
		{ Key = "Has Validator", Value = tostring(itemData.Validator or false), Color = if itemData.Validator then Theme.Colors.Cyan else Theme.Colors.TextMuted },
	}
	for i, p in ipairs(props) do
		self:_BuildPropRow(contentFrame, p.Key, p.Value, p.Color, 5 + i)
	end

	-- Stats
	Theme.CreateLabel({
		Text = "STATISTICS",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 20

	local stats = {
		{ Key = "Subscribers", Value = tostring(itemData.Subscribers or 0), Color = Theme.Colors.Success },
		{ Key = "Messages", Value = tostring(itemData.MessageCount or 0), Color = Theme.Colors.Cyan },
		{ Key = "Last Invoked", Value = (function()
			local t = itemData.LastInvoked or itemData.LastFired or 0
			if t > 0 then return string.format("%.1fs ago", os.clock() - t) end
			return"never"
		end)(), Color = Theme.Colors.TextSecondary },
	}
	for i, s in ipairs(stats) do
		self:_BuildPropRow(contentFrame, s.Key, s.Value, s.Color, 20 + i)
	end

	-- Properties
	if type(itemData.Properties) == "table" then
		local propCount = 0
		for _ in pairs(itemData.Properties) do propCount + = 1 end
		if propCount > 0 then
			Theme.CreateLabel({
				Text = string.format("PROPERTIES (%d)", propCount),
				Size = UDim2.new(1, 0, 0, 16),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 40

			local order = 41
			for key, value in pairs(itemData.Properties) do
				self:_BuildPropRow(contentFrame, tostring(key), tostring(value), Theme.Colors.TextPrimary, order)
				order + = 1
				if order > 60 then break end
			end
		end
	end
end


function NetworkModule:_BuildPropRow(parent: Frame, key: string, value: string, color: Color3, order: number)
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


function NetworkModule:Destroy()
	if self._searchAC then self._searchAC:Destroy(); self._searchAC = nil end
	table.clear(self._commandCache)
	table.clear(self._eventBusCache)
	table.clear(self._serverCallbacks)
end


function NetworkModule:_BuildCallsHistoryLayer(frame: Frame, context: any)
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
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.Parent = contentFrame

	local itemName = context.ItemName or "?"
	local calls = context.RecentCalls or {}

	Theme.CreateLabel({
		Text = string.format('<font color="#3898FF">≡</font> Recent Calls — %s  <font color="#666">(%d)</font>',
			itemName, #calls),
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	if #calls == 0 then
		Theme.CreateLabel({
			Text = "(no recent calls — invocations are tracked when a handler fires)",
			Size = UDim2.new(1, 0, 0, 24),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			Parent = contentFrame,
		}).LayoutOrder = 1
		return
	end

	for i = #calls, 1, -1 do
		local entry = calls[i]
		local order = (#calls - i) + 1

		-- Determine if this entry has any nested tables that warrant drill-down.
		-- NOTE: argsStruct.n may be nil after RemoteFunction serialization
		-- (Roblox drops the explicit `n` if the array length matches), so
		-- fall back to #argsStruct.
		local argsStruct = entry.ArgsStruct
		local hasNested = false
		local argsCount = 0
		if argsStruct then
			argsCount = argsStruct.n or #argsStruct
			for k = 1, argsCount do
				if type(argsStruct[k]) == "table" then hasNested = true; break end
			end
		end

		-- Build the row as a TextButton when expandable, plain Frame otherwise.
		local row: any = if hasNested then Instance.new("TextButton") else Instance.new("Frame")
		row.Name = "Call_" .. order
		row.Size = UDim2.new(1, 0, 0, 28)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.BackgroundColor3 = Theme.Colors.GlassTertiary
		row.BackgroundTransparency = 0.85
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		if hasNested then
			row.Text = ""
			row.AutoButtonColor = false
		end
		row.Parent = contentFrame
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, Theme.Radius.Xs)
		local rp = Instance.new("UIPadding")
		rp.PaddingLeft = UDim.new(0, 10)
		rp.PaddingRight = UDim.new(0, 10)
		rp.Parent = row

		local rowLayout = Instance.new("UIListLayout")
		rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowLayout.Padding = UDim.new(0, 2)
		rowLayout.Parent = row

		-- Header bar (fixed-height single-line summary)
		local header = Instance.new("Frame")
		header.Name = "Header"
		header.Size = UDim2.new(1, 0, 0, 24)
		header.BackgroundTransparency = 1
		header.LayoutOrder = 1
		header.Parent = row

		-- Index
		Theme.CreateLabel({
			Text = string.format("#%d", i),
			Size = UDim2.new(0, 32, 1, 0),
			Color = Theme.Colors.Accent,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Mono,
			Parent = header,
		})

		-- Direction badge (e.g. C→S, S→All) — only shown when present
		local dirText = entry.Direction
		local hasDir = type(dirText) == "string" and dirText ~= ""
		if hasDir then
			Theme.CreateLabel({
				Text = string.format('<font color="#9DC9FF">%s</font>', dirText),
				Size = UDim2.new(0, 78, 1, 0),
				Position = UDim2.new(0, 36, 0, 0),
				Color = Theme.Colors.TextPrimary,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Mono,
				Parent = header,
			})
		end

		-- Args summary (with chevron when expandable)
		local rawArgsStr = entry.Args
		if type(rawArgsStr) ~= "string" then rawArgsStr = tostring(rawArgsStr) end
		-- Escape angle brackets so RichText doesn't parse them as font tags.
		-- Historic call entries (captured before the [...] formatting fix)
		-- may still contain "<userdata:...>" / "<Vector3>" — escape defensively.
		local argsStr = rawArgsStr:gsub("<","&lt;"):gsub(">","&gt;")
		local chevron = hasNested and '<font color="#666">▸</font> ' or ''
		local argLabel = Theme.CreateLabel({
			Text = '<font color="#3898FF">▶</font>  ' .. chevron .. (argsStr or "()"),
			Size = UDim2.new(1, if hasDir then -190 else -110, 1, 0),
			Position = UDim2.new(0, if hasDir then 118 else 36, 0, 0),
			Color = Theme.Colors.TextPrimary,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = header,
		})

		-- Time
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
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.new(0, 60, 1, 0),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Right,
			Parent = header,
		})

		-- Click-to-expand for structured args (when ArgsStruct has nested tables)
		if hasNested then
			local detail: Frame? = nil
			local expanded = false
			row.MouseButton1Click:Connect(function()
				expanded = not expanded
				if expanded then
					detail = Instance.new("Frame")
					detail.Name = "ArgsDetail"
					detail.Size = UDim2.new(1, 0, 0, 0)
					detail.AutomaticSize = Enum.AutomaticSize.Y
					detail.BackgroundColor3 = Theme.Colors.BgPrimary
					detail.BackgroundTransparency = 0.4
					detail.BorderSizePixel = 0
					detail.LayoutOrder = 2
					detail.Parent = row
					Instance.new("UICorner", detail).CornerRadius = UDim.new(0, Theme.Radius.Xs)
					local dl = Instance.new("UIListLayout")
					dl.SortOrder = Enum.SortOrder.LayoutOrder
					dl.Padding = UDim.new(0, 1)
					dl.Parent = detail
					local dp = Instance.new("UIPadding")
					dp.PaddingLeft = UDim.new(0, 12)
					dp.PaddingRight = UDim.new(0, 8)
					dp.PaddingTop = UDim.new(0, 4)
					dp.PaddingBottom = UDim.new(0, 4)
					dp.Parent = detail

					self:_RenderStructuredArgs(detail, argsStruct, 0)
					argLabel.Text = '<font color="#3898FF">▶</font>  <font color="#666">▾</font> ' .. (argsStr or "()")
				else
					if detail then detail:Destroy(); detail = nil end
					argLabel.Text = '<font color="#3898FF">▶</font>  ' .. chevron .. (argsStr or "()")
				end
			end)
		end
	end
end


function NetworkModule:_RenderStructuredArgs(parent: Frame, args: any, depth: number)
	-- argCount must fall back to #args because RemoteFunction serialization
	-- strips the explicit .n key when the array length matches.
	local argCount = args.n or #args
	for i = 1, argCount do
		local v = args[i]
		self:_RenderStructuredArg(parent,"[" .. i .."]", v, depth, i)
	end
	if args.truncated then
		Theme.CreateLabel({
			Text = string.format('<font color="#888">… +%d more arguments truncated</font>', args.truncated),
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = parent,
		}).LayoutOrder = argCount + 1
	end
end


function NetworkModule:_RenderStructuredArg(parent: Frame, key: string, value: any, depth: number, layoutOrder: number)
	local indent = depth * 12
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 14)
	row.BackgroundTransparency = 1
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, indent)
	pad.Parent = row

	-- Escape angle brackets in keys/values so RichText labels render them
	-- visibly instead of treating them as font tags.
	local function escape(s: string): string
		return (s:gsub("<","&lt;"):gsub(">","&gt;"))
	end
	local safeKey = escape(tostring(key))

	local t = type(value)
	if t == "table" then
		local n = 0
		for _ in pairs(value) do n + = 1 end
		Theme.CreateLabel({
			Text = string.format('<font color="#9DC9FF">%s</font> = <font color="#3CD278">{%d keys}</font>',
				safeKey, n),
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			Color = Theme.Colors.TextPrimary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		if depth < 4 then
			local sortedKeys = {}
			for k in pairs(value) do table.insert(sortedKeys, k) end
			table.sort(sortedKeys, function(a, b) return tostring(a) < tostring(b) end)
			local idx = 0
			for _, k in ipairs(sortedKeys) do
				idx + = 1
				self:_RenderStructuredArg(parent, tostring(k), value[k], depth + 1, layoutOrder * 100 + idx)
			end
		end
	else
		local valueText
		if t == "string" then valueText = string.format("%q", value)
		elseif t == "nil" then valueText = "nil"
		else valueText = tostring(value) end
		Theme.CreateLabel({
			Text = string.format('<font color="#9DC9FF">%s</font> = <font color="#FFFFFF">%s</font>',
				safeKey, escape(valueText)),
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			Color = Theme.Colors.TextSecondary,
			FontSize = Theme.TextSize.Tiny,
			FontFace = Theme.Font.Mono,
			Alignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
	end
end

return NetworkModule
