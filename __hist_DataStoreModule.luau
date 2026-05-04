warning: safe.directory ''%(prefix)///webserver/ssd/Scraper/ai_model_server'' not absolute
warning: safe.directory ''%(prefix)///webserver/ssd/Scraper/ai_model_server'' not absolute
warning: safe.directory ''Z:/Scraper/ai_model_server'' not absolute
--!strict
--[=[
	@module DataStoreModule
	@description Defines the `DataStoreModule` module and its exported API.
]=]

local Theme = require(script.Parent.Parent.Theme)
local SearchAutocomplete = require(script.Parent.Parent.SearchAutocomplete)

local DataStoreModule = {}
DataStoreModule.__index = DataStoreModule

local SORT_MODES = { "Name", "Keys", "Ops", "LastSync" }
--[=[
	@description Implements `DataStoreModule.new`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule.new(): any
	local self = setmetatable({}, DataStoreModule)
	self._storeCache = {} :: { [string]: any }
	self._searchText = ""
	self._sortMode = "Name"
	self._selectedStore = nil :: string?
	return self
end
--[=[
	@description Implements `DataStoreModule.FetchData`.
	@param nexus any -- `nexus` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:FetchData(nexus: any)
	local orchestrator = nexus._orchestrator
	if not orchestrator then return end

	if nexus._contextMode == "client" then
		local factory = orchestrator.Factory
		if factory then
			self._storeCache = {}
			-- Try to get DataStoreSystem entity which manages actual store instances
			local registry = factory.Registry
			if registry then
				local dsEntity = nil
				if type(registry.GetEntity) == "function" then
					local ok, result = pcall(registry.GetEntity, "DataStoreSystem")
					if ok then dsEntity = result end
				end
				if dsEntity then
					-- DataStoreEntity exposes its data via GetData or similar
					local data = if type(dsEntity.GetData) == "function" then dsEntity:GetData() else dsEntity.Data
					if data and type(data) == "table" then
						for name, store in pairs(data) do
							if type(store) == "table" then
								self._storeCache[name] = self:_ExtractStoreData(name, store)
							end
						end
					end
				end
			end
			-- Fallback: check PersistenceManager.Controller
			if next(self._storeCache) == nil then
				local persistence = factory.PersistenceManager or factory._persistenceManager
				if persistence then
					local controller = persistence.Controller
					if controller and type(controller.GetStores) == "function" then
						local ok, stores = pcall(controller.GetStores, controller)
						if ok and type(stores) == "table" then
							for name, store in pairs(stores) do
								self._storeCache[name] = self:_ExtractStoreData(name, store)
							end
						end
					end
				end
			end
		end
	else
		local serverData = nexus._serverData
		if serverData and serverData.DataStore then
			self._storeCache = {}
			local storeList = serverData.DataStore.List or serverData.DataStore.Stores or {}
			for name, storeInfo in pairs(storeList) do
				if type(storeInfo) ~= "table" then continue end
				self._storeCache[name] = {
					Name = name,
					Status = storeInfo.Status or "idle",
					CachedKeys = storeInfo.CachedKeys or 0,
					TotalOps = storeInfo.TotalOps or 0,
					PendingOps = storeInfo.PendingOps or 0,
					LastSync = storeInfo.LastSync or 0,
					RateLimit = storeInfo.RateLimit or {},
					Config = storeInfo.Config or {},
					Keys = storeInfo.Keys or {},
					Version = storeInfo.Version or 0,
					Errors = storeInfo.Errors or 0,
					OperationsLog = storeInfo.OperationsLog or {},
				}
			end
		end
	end

	nexus.Store:BatchUpdate(function()
		nexus.Store:Set("datastore.list", self._storeCache)
	end)
end
--[=[
	@description Implements `DataStoreModule._ExtractStoreData`.
	@param name string -- `name` input parameter.
	@param store any -- `store` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_ExtractStoreData(name: string, store: any): any
	if type(store) ~= "table" then
		return {
			Name = name,
			Status = "unknown",
			CachedKeys = 0,
			TotalOps = 0,
			PendingOps = 0,
			LastSync = 0,
			RateLimit = {},
			Config = {},
			Keys = {},
			Version = 0,
			Errors = 0,
			OperationsLog = {},
		}
	end

	local cachedKeys = 0
	local keys = {}
	local cache = store.Cache or store._cache or store.Data or store._data or {}
	if type(cache) == "table" then
		for k, v in pairs(cache) do
			cachedKeys += 1
			keys[tostring(k)] = v
		end
	end

	local pendingOps = 0
	local pending = store.PendingOperations or store._pendingOperations or store.Queue or store._queue or {}
	if type(pending) == "table" then
		for _ in pairs(pending) do pendingOps += 1 end
	end

	local config = {}
	if store.Config or store._config then
		local raw = store.Config or store._config
		if type(raw) == "table" then
			for k, v in pairs(raw) do
				if type(v) ~= "function" and type(v) ~= "table" then
					config[tostring(k)] = v
				end
			end
		end
	end

	local rateLimit = {}
	if store.RateLimit or store._rateLimit then
		local raw = store.RateLimit or store._rateLimit
		if type(raw) == "table" then
			rateLimit = {
				MaxRequests = raw.MaxRequests or raw._maxRequests or 0,
				Window = raw.Window or raw._window or 0,
				Current = raw.Current or raw._current or 0,
			}
		end
	end

	return {
		Name = name,
		Status = store.Status or store._status or "idle",
		CachedKeys = cachedKeys,
		TotalOps = store.TotalOperations or store._totalOperations or 0,
		PendingOps = pendingOps,
		LastSync = store.LastSync or store._lastSync or 0,
		RateLimit = rateLimit,
		Config = config,
		Keys = keys,
		Version = store.Version or store._version or 0,
		Errors = store.Errors or store._errors or 0,
		OperationsLog = store.OperationsLog or store._operationsLog or {},
	}
end
--[=[
	@description Implements `DataStoreModule.Render`.
	@param _nexus any -- `_nexus` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:Render(_nexus: any) end
--[=[
	@description Implements `DataStoreModule._GetSorted`.
	@param none nil -- This function does not accept explicit parameters.
	@return { { Name: string, Data: any } } -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_GetSorted(): { { Name: string, Data: any } }
	local result = {}
	for name, data in pairs(self._storeCache) do
		if self._searchText ~= "" then
			local lower = string.lower(self._searchText)
			if not string.lower(name):find(lower, 1, true)
				and not string.lower(data.Status or ""):find(lower, 1, true) then
				continue
			end
		end
		table.insert(result, { Name = name, Data = data })
	end

	local mode = self._sortMode
	table.sort(result, function(a, b)
		if mode == "Name" then return a.Name < b.Name
		elseif mode == "Keys" then return (a.Data.CachedKeys or 0) > (b.Data.CachedKeys or 0)
		elseif mode == "Ops" then return (a.Data.TotalOps or 0) > (b.Data.TotalOps or 0)
		elseif mode == "LastSync" then return (a.Data.LastSync or 0) > (b.Data.LastSync or 0)
		end
		return a.Name < b.Name
	end)
	return result
end
--[=[
	@description Creates the result managed by `DataStoreModule.BuildRootLayer`.
	@param frame Frame -- `frame` input parameter.
	@param context any -- `context` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:BuildRootLayer(frame: Frame, context: any)
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

	-- Stores
	local sorted = self:_GetSorted()
	Theme.CreateLabel({
		Text = string.format("DATA STORES (%d)", #sorted),
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 20

	local itemsToAnimate = {}
	for i, item in ipairs(sorted) do
		local row = self:_BuildStoreRow(contentFrame, item.Name, item.Data, nexus, 20 + i)
		table.insert(itemsToAnimate, row)
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
--[=[
	@description Implements `DataStoreModule._BuildSummaryStrip`.
	@param parent Frame -- `parent` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_BuildSummaryStrip(parent: Frame)
	local strip = Instance.new("Frame")
	strip.Name = "DSSummary"
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

	local storeCount, totalKeys, totalOps, totalPending, errorCount = 0, 0, 0, 0, 0
	for _, d in pairs(self._storeCache) do
		storeCount += 1
		totalKeys += (d.CachedKeys or 0)
		totalOps += (d.TotalOps or 0)
		totalPending += (d.PendingOps or 0)
		errorCount += (d.Errors or 0)
	end

	local metrics = {
		{ Label = "STORES", Value = tostring(storeCount), Color = Theme.Colors.Accent },
		{ Label = "KEYS", Value = tostring(totalKeys), Color = Theme.Colors.Cyan },
		{ Label = "OPS", Value = tostring(totalOps), Color = Theme.Colors.Success },
		{ Label = "PENDING", Value = tostring(totalPending), Color = Theme.Colors.Warning },
		{ Label = "ERRORS", Value = tostring(errorCount), Color = Theme.Colors.Danger },
	}

	for i, m in ipairs(metrics) do
		local cell = Instance.new("Frame")
		cell.Size = UDim2.new(0, 60, 1, 0)
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
--[=[
	@description Implements `DataStoreModule._BuildToolbar`.
	@param parent Frame -- `parent` input parameter.
	@param nexus any -- `nexus` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_BuildToolbar(parent: Frame, nexus: any)
	local toolbar = Instance.new("Frame")
	toolbar.Name = "DSToolbar"
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
		Text = "≡ƒöì",
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
	searchBox.PlaceholderText = "Search stores..."
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
			for name, _ in pairs(self._storeCache) do
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
	sortBtn.Size = UDim2.new(0, 90, 0, 26)
	sortBtn.BackgroundColor3 = Theme.Colors.GlassTertiary
	sortBtn.BackgroundTransparency = 0.4
	sortBtn.Text = "Γåô " .. self._sortMode
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
		sortBtn.Text = "Γåô " .. self._sortMode
		if nexus then nexus._lastDataRefresh = 0 end
	end)
end
--[=[
	@description Implements `DataStoreModule._BuildStoreRow`.
	@param parent Frame -- `parent` input parameter.
	@param name string -- `name` input parameter.
	@param storeData any -- `storeData` input parameter.
	@param nexus any -- `nexus` input parameter.
	@param order number -- `order` input parameter.
	@return Frame -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_BuildStoreRow(parent: Frame, name: string, storeData: any, nexus: any, order: number): Frame
	local statusColor = if storeData.Status == "syncing" then Theme.Colors.Warning
		elseif storeData.Status == "error" then Theme.Colors.Danger
		elseif storeData.Status == "ready" then Theme.Colors.Success
		else Theme.Colors.TextMuted

	local statusRgb = string.format("rgb(%d,%d,%d)",
		math.floor(statusColor.R * 255), math.floor(statusColor.G * 255), math.floor(statusColor.B * 255))

	local stats: { Theme.RowStat } = {
		{ Text = "v" .. tostring(storeData.Version or 0), Color = Theme.Colors.TextMuted, Width = 30, FontSize = Theme.TextSize.Tiny },
		{ Text = string.format("ops:%d", storeData.TotalOps or 0), Color = Theme.Colors.Success, Width = 64, FontSize = Theme.TextSize.Tiny },
		{ Text = string.format("ΓÇó %d", storeData.CachedKeys or 0), Color = Theme.Colors.Cyan, Width = 50 },
	}

	-- Status badge first
	table.insert(stats, 1, {
		Text = string.format('<font color="%s"><b>%s</b></font>', statusRgb, string.upper(storeData.Status or "idle")),
		Width = 70,
		Mono = false,
	})

	if (storeData.PendingOps or 0) > 0 then
		table.insert(stats, { Text = string.format("┬╖┬╖┬╖%d", storeData.PendingOps), Color = Theme.Colors.Warning, Width = 36, FontSize = Theme.TextSize.Tiny })
	end
	if (storeData.Errors or 0) > 0 then
		table.insert(stats, { Text = string.format("Γåæ%d", storeData.Errors), Color = Theme.Colors.Danger, Width = 30, FontSize = Theme.TextSize.Tiny })
	end

	local row = Theme.CreateRow({
		Name = "DS_" .. name,
		Size = UDim2.new(1, 0, 0, 38),
		StatusColor = statusColor,
		Title = name,
		BackgroundColor = if (storeData.Errors or 0) > 0 then Theme.Colors.Danger else Theme.Colors.GlassTertiary,
		BackgroundTransparency = if (storeData.Errors or 0) > 0 then 0.88 else 0.85,
		LayoutOrder = order,
		Stats = stats,
		Parent = parent,
		OnClick = function()
			self._selectedStore = name
			if nexus._navigator then
				nexus._navigator:ExpandLayer({
					Id = "datastore.detail." .. name,
					ParentId = "DATASTORE",
					Label = name,
					Builder = function(f, ctx) self:_BuildStoreDetailLayer(f, ctx) end,
					Context = { Nexus = nexus, StoreName = name, StoreData = storeData },
				})
			end
		end,
	})

	-- Pulse status dot when syncing
	local dot = row:FindFirstChild("StatusDot")
	if dot and storeData.Status == "syncing" and nexus._animationController then
		nexus._animationController:StartPulse("ds_" .. name, dot, "BackgroundTransparency", 0.6)
	end

	-- Hover glow
	local btn = row:FindFirstChild("ClickOverlay")
	if btn and nexus._animationController then
		nexus._animationController:HoverGlow(btn, Theme.Colors.Accent)
	end

	return row
end
--[=[
	@description Implements `DataStoreModule._BuildStoreDetailLayer`.
	@param frame Frame -- `frame` input parameter.
	@param context any -- `context` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_BuildStoreDetailLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	local storeName = context.StoreName or "Unknown"
	local storeData = context.StoreData or {}

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
	Theme.CreateLabel({
		Text = string.format('<font color="#3898FF">Γûª</font> %s', storeName),
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	-- ΓöÇΓöÇΓöÇ ACTION BAR ΓöÇΓöÇΓöÇ
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

	local reloadBtn = Theme.CreateIconButton({
		Label = "Reload",
		Size = UDim2.new(0, 90, 0, 26),
		Color = Theme.Colors.Accent,
		Parent = actionBar,
	})
	reloadBtn.Name = "ReloadButton"
	reloadBtn.LayoutOrder = 1
	reloadBtn.MouseButton1Click:Connect(function()
		if nexus then nexus._lastDataRefresh = 0 end
		if nexus and nexus._navigator then
			nexus._navigator:RebuildCurrentLayer()
		end
	end)

	local flushBtn = Theme.CreateIconButton({
		Label = "≡ƒùæ Flush",
		Size = UDim2.new(0, 80, 0, 26),
		Color = Theme.Colors.Warning,
		Parent = actionBar,
	})
	flushBtn.Name = "FlushButton"
	flushBtn.LayoutOrder = 2
	flushBtn.MouseButton1Click:Connect(function()
		-- Best-effort cache flush via orchestrator
		local orch = nexus and nexus._orchestrator
		if orch and orch.PersistenceManager then
			pcall(function()
				if orch.PersistenceManager.FlushCache then
					orch.PersistenceManager:FlushCache(storeName)
				end
			end)
		end
		if nexus then nexus._lastDataRefresh = 0 end
	end)

	local saveBtn = Theme.CreateIconButton({
		Label = "Γùå Save All",
		Size = UDim2.new(0, 100, 0, 26),
		Color = Theme.Colors.Success,
		Parent = actionBar,
	})
	saveBtn.Name = "SaveAllButton"
	saveBtn.LayoutOrder = 3
	saveBtn.MouseButton1Click:Connect(function()
		local orch = nexus and nexus._orchestrator
		if orch and orch.PersistenceManager and orch.PersistenceManager.SaveAll then
			pcall(function() orch.PersistenceManager:SaveAll() end)
		end
	end)

	-- ΓöÇΓöÇΓöÇ IDENTITY ΓöÇΓöÇΓöÇ
	Theme.CreateLabel({
		Text = "IDENTITY",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 5

	local statusColor = if storeData.Status == "ready" then Theme.Colors.Success
		elseif storeData.Status == "syncing" then Theme.Colors.Warning
		elseif storeData.Status == "error" then Theme.Colors.Danger
		else Theme.Colors.TextPrimary

	local idProps = {
		{ Key = "Store Name", Value = storeName, Color = Theme.Colors.Accent },
		{ Key = "Status", Value = storeData.Status or "idle", Color = statusColor },
		{ Key = "Version", Value = "v" .. tostring(storeData.Version or 0), Color = Theme.Colors.TextPrimary },
		{ Key = "Cached Keys", Value = tostring(storeData.CachedKeys or 0), Color = Theme.Colors.Cyan },
	}
	for i, p in ipairs(idProps) do
		self:_BuildPropRow(contentFrame, p.Key, p.Value, p.Color, 5 + i)
	end

	-- ΓöÇΓöÇΓöÇ OPERATIONS ΓöÇΓöÇΓöÇ
	Theme.CreateLabel({
		Text = "OPERATIONS",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 20

	local opProps = {
		{ Key = "Total Ops", Value = tostring(storeData.TotalOps or 0), Color = Theme.Colors.Success },
		{ Key = "Pending Ops", Value = tostring(storeData.PendingOps or 0), Color = if (storeData.PendingOps or 0) > 0 then Theme.Colors.Warning else Theme.Colors.TextMuted },
		{ Key = "Last Sync", Value = if (storeData.LastSync or 0) > 0 then string.format("%.1fs ago", os.clock() - storeData.LastSync) else "never", Color = Theme.Colors.TextSecondary },
		{ Key = "Errors", Value = tostring(storeData.Errors or 0), Color = if (storeData.Errors or 0) > 0 then Theme.Colors.Danger else Theme.Colors.TextMuted },
	}
	for i, p in ipairs(opProps) do
		self:_BuildPropRow(contentFrame, p.Key, p.Value, p.Color, 20 + i)
	end

	-- ΓöÇΓöÇΓöÇ RATE LIMIT ΓöÇΓöÇΓöÇ
	if type(storeData.RateLimit) == "table" then
		local hasRL = false
		for _ in pairs(storeData.RateLimit) do hasRL = true; break end
		if hasRL then
			Theme.CreateLabel({
				Text = "RATE LIMIT",
				Size = UDim2.new(1, 0, 0, 16),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 35

			local rlProps = {
				{ Key = "Max Requests", Value = tostring(storeData.RateLimit.MaxRequests or 0), Color = Theme.Colors.Accent },
				{ Key = "Window", Value = string.format("%.1fs", storeData.RateLimit.Window or 0), Color = Theme.Colors.TextPrimary },
				{ Key = "Current", Value = tostring(storeData.RateLimit.Current or 0), Color = Theme.Colors.Warning },
			}
			for i, p in ipairs(rlProps) do
				self:_BuildPropRow(contentFrame, p.Key, p.Value, p.Color, 35 + i)
			end
		end
	end

	-- ΓöÇΓöÇΓöÇ CONFIG ΓöÇΓöÇΓöÇ
	if type(storeData.Config) == "table" then
		local configCount = 0
		for _ in pairs(storeData.Config) do configCount += 1 end
		if configCount > 0 then
			Theme.CreateLabel({
				Text = string.format("CONFIG (%d)", configCount),
				Size = UDim2.new(1, 0, 0, 16),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 50

			local order = 51
			for key, val in pairs(storeData.Config) do
				self:_BuildPropRow(contentFrame, tostring(key), tostring(val), Theme.Colors.TextPrimary, order)
				order += 1
				if order > 65 then break end
			end
		end
	end

	-- ΓöÇΓöÇΓöÇ CACHED KEYS ΓöÇΓöÇΓöÇ
	if type(storeData.Keys) == "table" then
		local keyCount = 0
		for _ in pairs(storeData.Keys) do keyCount += 1 end
		if keyCount > 0 then
			Theme.CreateLabel({
				Text = string.format("CACHED KEYS (%d)", keyCount),
				Size = UDim2.new(1, 0, 0, 16),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 80

			local order = 81
			for key, value in pairs(storeData.Keys) do
				local valStr = self:_Stringify(value)
				local valColor = self:_TypeColor(value)
				self:_BuildPropRow(contentFrame, tostring(key), valStr, valColor, order)
				order += 1
				if order > 110 then break end
			end
		end
	end

	-- ΓöÇΓöÇΓöÇ OPERATIONS LOG ΓöÇΓöÇΓöÇ
	if type(storeData.OperationsLog) == "table" and #storeData.OperationsLog > 0 then
		Theme.CreateLabel({
			Text = string.format("OPERATIONS LOG (last %d)", math.min(#storeData.OperationsLog, 15)),
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Parent = contentFrame,
		}).LayoutOrder = 120

		local count = math.min(#storeData.OperationsLog, 15)
		for j = 1, count do
			local idx = #storeData.OperationsLog - count + j
			local entry = storeData.OperationsLog[idx]
			if entry and type(entry) == "table" then
				local opType = entry.Type or entry.Op or "?"
				local opKey = entry.Key or "?"
				local opColor = if opType == "SET" then Theme.Colors.Success
					elseif opType == "GET" then Theme.Colors.Cyan
					elseif opType == "DELETE" then Theme.Colors.Danger
					else Theme.Colors.TextSecondary
				self:_BuildPropRow(contentFrame, opType .. " " .. opKey, entry.Time and string.format("%.2fs", entry.Time) or "", opColor, 120 + j)
			end
		end
	end
end
--[=[
	@description Implements `DataStoreModule._Stringify`.
	@param value any -- `value` input parameter.
	@return string -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_Stringify(value: any): string
	local t = type(value)
	if t == "string" then return '"' .. value .. '"'
	elseif t == "number" then return tostring(value)
	elseif t == "boolean" then return tostring(value)
	elseif t == "table" then
		local count = 0
		for _ in pairs(value) do count += 1 end
		return string.format("{%d}", count)
	elseif t == "nil" then return "nil"
	else return tostring(value) end
end
--[=[
	@description Implements `DataStoreModule._TypeColor`.
	@param value any -- `value` input parameter.
	@return Color3 -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_TypeColor(value: any): Color3
	local t = type(value)
	if t == "string" then return Theme.Colors.Success
	elseif t == "number" then return Theme.Colors.Cyan
	elseif t == "boolean" then return Theme.Colors.Orange
	elseif t == "table" then return Theme.Colors.Purple
	else return Theme.Colors.TextMuted end
end
--[=[
	@description Implements `DataStoreModule._BuildPropRow`.
	@param parent Frame -- `parent` input parameter.
	@param key string -- `key` input parameter.
	@param value string -- `value` input parameter.
	@param color Color3 -- `color` input parameter.
	@param order number -- `order` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:_BuildPropRow(parent: Frame, key: string, value: string, color: Color3, order: number)
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
--[=[
	@description Implements `DataStoreModule.Destroy`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function DataStoreModule:Destroy()
	if self._searchAC then self._searchAC:Destroy(); self._searchAC = nil end
	table.clear(self._storeCache)
end

return DataStoreModule
