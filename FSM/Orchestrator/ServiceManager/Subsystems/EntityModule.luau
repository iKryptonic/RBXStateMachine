--!strict
-- @Name ServiceManager/Subsystems/EntityModule.luau
-- @Author iKrypto
-- @Description Enhanced ENTITY subsystem with active/dead tracking, full object inspector
-- (Identity, State, Context, Data, Schema, Logs sections), sort options, search bar,
-- type badges, and detailed entity drill-down.

local Theme = require(script.Parent.Parent.Theme)
local SearchAutocomplete = require(script.Parent.Parent.SearchAutocomplete)

local EntityModule = {}
EntityModule.__index = EntityModule

local SORT_MODES = { "Name", "Type", "Age", "Status" }

--[[
	Create the ENTITY subsystem controller.
	Owns the live/dead entity caches plus the search and selection state used by
	the inspector and its nested drill-down layers.
]]
function EntityModule.new(): any
	local self = setmetatable({}, EntityModule)
	self._entityCache = {} :: { [string]: any }
	self._deadEntities = {} :: { [string]: any }
	self._searchText = ""
	self._sortMode = "Name"
	self._showDead = false
	self._selectedEntity = nil :: string?
	return self
end

--[[
	Refresh the entity snapshot for the current context and publish the latest
	list data into local caches and the shared store.
]]
function EntityModule:FetchData(nexus: any)
	local orchestrator = nexus._orchestrator
	if not orchestrator then return end

	local previousCache = self._entityCache
	local previousDead = self._deadEntities
	local newCache = {} :: { [string]: any }
	local newDead = {} :: { [string]: any }

	local function carryForwardDead()
		for id, dead in pairs(previousDead) do
			if not newCache[id] and not newDead[id] then
				newDead[id] = dead
			end
		end
	end

	local function markDisappearedAsDead()
		for id, cached in pairs(previousCache) do
			if not newCache[id] and not newDead[id] then
				local deadSnapshot = if type(cached) == "table" then table.clone(cached) else { Id = id }
				deadSnapshot.IsValid = false
				deadSnapshot.DiedAt = deadSnapshot.DiedAt or os.clock()
				newDead[id] = deadSnapshot
			end
		end
	end

	if nexus._contextMode == "client" then
		local factory = orchestrator.Factory
		if factory and factory.Registry then
			local registry = factory.Registry
			local entities = registry.Entities or registry._entities or {}
			for id, entity in pairs(entities) do
				local data = self:_ExtractEntityData(id, entity)
				if data.IsValid == false then
					newDead[id] = data
				else
					newCache[id] = data
				end
			end
			carryForwardDead()
			markDisappearedAsDead()
			self._entityCache = newCache
			self._deadEntities = newDead
		end
	else
		local serverData = nexus._serverData
		if serverData and serverData.Entities then
			local entityList = serverData.Entities.List or serverData.Entities
			for id, entityInfo in pairs(entityList) do
				if type(entityInfo) ~= "table" then continue end
				local data = {
					Id = id,
					ClassName = entityInfo.ClassName or entityInfo.Type or "Unknown",
					Version = entityInfo.Version or 0,
					IsValid = entityInfo.IsValid ~= false,
					CreatedAt = entityInfo.CreatedAt or 0,
					DiedAt = entityInfo.DiedAt,
					Data = entityInfo.Data or {},
					Schema = entityInfo.Schema or {},
					Context = entityInfo.Context or {},
					HasFSM = entityInfo.HasFSM or false,
					FSMId = entityInfo.FSMId,
					IsPersistent = entityInfo.IsPersistent or false,
					Tags = entityInfo.Tags or {},
					VersionHistory = entityInfo.VersionHistory or {},
				}
				if not data.IsValid then
					newDead[id] = data
				else
					newCache[id] = data
				end
			end
			carryForwardDead()
			markDisappearedAsDead()
			self._entityCache = newCache
			self._deadEntities = newDead
		end
	end

	nexus.Store:BatchUpdate(function()
		nexus.Store:Set("entity.list", self._entityCache)
		nexus.Store:Set("entity.dead", self._deadEntities)
	end)
end

function EntityModule:_ExtractEntityData(id: string, entity: any): any
	local className = "Unknown"
	local version = 0
	local isValid = true
	local createdAt = 0
	local data = {}
	local schema = {}
	local context = {}
	local hasFSM = false
	local fsmId = nil
	local isPersistent = false
	local tags = {}
	local versionHistory = {} :: { any }

	if type(entity) == "table" then
		-- Check _privateProperties first (primary entity storage)
		local pp = entity._privateProperties
		if pp and type(pp) == "table" then
			className = pp.Name or pp.ClassName or className
			version = pp.Version or version
			isValid = if pp.IsValid ~= nil then pp.IsValid else isValid
			createdAt = pp.CreatedAt or createdAt
			hasFSM = pp.StateMachine ~= nil or entity.StateMachine ~= nil
			fsmId = pp.FSMId or fsmId
			isPersistent = pp.IsPersistent or isPersistent
			tags = pp.Tags or tags

			if pp.Data and type(pp.Data) == "table" then
				for k, v in pairs(pp.Data) do
					data[tostring(k)] = v
				end
			end

			if pp.Schema and type(pp.Schema) == "table" then
				for k, v in pairs(pp.Schema) do
					schema[tostring(k)] = v
				end
			end

			if pp.Context and type(pp.Context) == "table" then
				for k, v in pairs(pp.Context) do
					context[tostring(k)] = v
				end
			end

			-- Version history (rich form: { Version, Time, Changes }) — flatten
			-- to flat per-field entries the UI consumes
			if pp._versionHistory and type(pp._versionHistory) == "table" then
				for _, entry in ipairs(pp._versionHistory) do
					if type(entry) == "table" and type(entry.Changes) == "table" then
						for fieldName, change in pairs(entry.Changes) do
							local fromValue = if type(change) == "table" then change.From else nil
							local toValue = if type(change) == "table" then change.To else nil
							table.insert(versionHistory, {
								Version = entry.Version,
								Time = entry.Time,
								Field = fieldName,
								From = fromValue,
								To = toValue,
							})
						end
					end
				end
			end
		else
			-- Fallback to top-level properties
			className = entity.ClassName or entity._className or entity.Name or entity.Type or className
			version = entity.Version or entity._version or version
			isValid = if entity.IsValid ~= nil then entity.IsValid elseif entity._isValid ~= nil then entity._isValid else isValid
			createdAt = entity.CreatedAt or entity._createdAt or createdAt
			hasFSM = entity.StateMachine ~= nil or entity._stateMachine ~= nil
			fsmId = entity.FSMId or entity._fsmId
			isPersistent = entity.IsPersistent or entity._isPersistent or isPersistent
			tags = entity.Tags or entity._tags or tags

			if entity.Data or entity._data then
				local raw = entity.Data or entity._data
				if type(raw) == "table" then
					for k, v in pairs(raw) do
						data[tostring(k)] = v
					end
				end
			end

			if entity.Schema or entity._schema then
				local raw = entity.Schema or entity._schema
				if type(raw) == "table" then
					for k, v in pairs(raw) do
						schema[tostring(k)] = v
					end
				end
			end

			if entity.Context or entity._context then
				local raw = entity.Context or entity._context
				if type(raw) == "table" then
					for k, v in pairs(raw) do
						context[tostring(k)] = v
					end
				end
			end
		end

		-- Check for persistence from schema fields
		if not isPersistent and type(schema) == "table" then
			for _, def in pairs(schema) do
				if type(def) == "table" and def.Persist then
					isPersistent = true
					break
				end
			end
		end
	end

	return {
		Id = id,
		ClassName = className,
		Version = version,
		IsValid = isValid,
		CreatedAt = createdAt,
		DiedAt = nil,
		Data = data,
		Schema = schema,
		Context = context,
		HasFSM = hasFSM,
		FSMId = fsmId,
		IsPersistent = isPersistent,
		Tags = tags,
		VersionHistory = versionHistory,
	}
end

--[[
	Legacy subsystem hook retained for interface parity.
	ENTITY rendering is performed by BuildRootLayer and detail-layer builders.
]]
function EntityModule:Render(_nexus: any) end

-- ══════════════════════════════════════════════════════════════
-- SORTING / FILTERING
-- ══════════════════════════════════════════════════════════════

function EntityModule:_GetSorted(source: { [string]: any }): { { Id: string, Data: any } }
	local result = {}
	for id, data in pairs(source) do
		if self._searchText ~= "" then
			local lower = string.lower(self._searchText)
			if not string.lower(id):find(lower, 1, true)
				and not string.lower(data.ClassName or ""):find(lower, 1, true) then
				continue
			end
		end
		table.insert(result, { Id = id, Data = data })
	end

	local mode = self._sortMode
	table.sort(result, function(a, b)
		if mode == "Name" then return a.Id < b.Id
		elseif mode == "Type" then return (a.Data.ClassName or "") < (b.Data.ClassName or "")
		elseif mode == "Age" then return (a.Data.CreatedAt or 0) < (b.Data.CreatedAt or 0)
		elseif mode == "Status" then return (a.Data.IsValid and 1 or 0) > (b.Data.IsValid and 1 or 0)
		end
		return a.Id < b.Id
	end)
	return result
end

-- ══════════════════════════════════════════════════════════════
-- ROOT LAYER
-- ══════════════════════════════════════════════════════════════

--[[
	Build or rebuild the ENTITY overview layer inside the supplied navigator frame.
	Creates the summary strip, toolbar, and entity rows that fan out into the
	full inspector, table view, and version-history drill-downs.
]]
function EntityModule:BuildRootLayer(frame: Frame, context: any)
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

	-- Active entities
	local activeSorted = self:_GetSorted(self._entityCache)
	Theme.CreateLabel({
		Text = string.format("ACTIVE ENTITIES (%d)", #activeSorted),
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 20

	for i, item in ipairs(activeSorted) do
		local row = self:_BuildEntityRow(contentFrame, item.Id, item.Data, nexus, 20 + i, false)
		table.insert(itemsToAnimate, row)
	end

	-- Dead entities section
	if self._showDead then
		local deadSorted = self:_GetSorted(self._deadEntities)
		if #deadSorted > 0 then
			Theme.CreateLabel({
				Text = string.format('<font color="#F05050">DEAD ENTITIES (%d)</font>', #deadSorted),
				Size = UDim2.new(1, 0, 0, 18),
				Color = Theme.Colors.Danger,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 300

			for i, item in ipairs(deadSorted) do
				local row = self:_BuildEntityRow(contentFrame, item.Id, item.Data, nexus, 300 + i, true)
				table.insert(itemsToAnimate, row)
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

function EntityModule:_BuildSummaryStrip(parent: Frame)
	local strip = Instance.new("Frame")
	strip.Name = "EntitySummary"
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

	local liveCount, deadCount, persistCount, fsmCount = 0, 0, 0, 0
	local typeSet = {}
	for _, d in pairs(self._entityCache) do
		liveCount += 1
		if d.IsPersistent then persistCount += 1 end
		if d.HasFSM then fsmCount += 1 end
		typeSet[d.ClassName or "Unknown"] = true
	end
	for _ in pairs(self._deadEntities) do deadCount += 1 end

	local typeCount = 0
	for _ in pairs(typeSet) do typeCount += 1 end

	local metrics = {
		{ Label = "LIVE", Value = tostring(liveCount), Color = Theme.Colors.Success },
		{ Label = "DEAD", Value = tostring(deadCount), Color = Theme.Colors.Danger },
		{ Label = "TYPES", Value = tostring(typeCount), Color = Theme.Colors.Cyan },
		{ Label = "PERSIST", Value = tostring(persistCount), Color = Theme.Colors.Purple },
		{ Label = "WITH FSM", Value = tostring(fsmCount), Color = Theme.Colors.Orange },
	}

	for i, m in ipairs(metrics) do
		local cell = Instance.new("Frame")
		cell.Size = UDim2.new(0, 65, 1, 0)
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

function EntityModule:_BuildToolbar(parent: Frame, nexus: any)
	local toolbar = Instance.new("Frame")
	toolbar.Name = "EntityToolbar"
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
	searchBox.PlaceholderText = "Search entities..."
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
			for id, _ in pairs(self._entityCache) do
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

	-- Sort
	local sortBtn = Instance.new("TextButton")
	sortBtn.Size = UDim2.new(0, 80, 0, 26)
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

	-- Dead toggle
	local deadBtn = Instance.new("TextButton")
	deadBtn.Size = UDim2.new(0, 90, 0, 26)
	deadBtn.BackgroundColor3 = if self._showDead then Theme.Colors.Danger else Theme.Colors.GlassTertiary
	deadBtn.BackgroundTransparency = if self._showDead then 0.5 else 0.6
	deadBtn.Text = "✕ Dead"
	deadBtn.TextColor3 = if self._showDead then Theme.Colors.TextOnAccent else Theme.Colors.TextMuted
	deadBtn.TextSize = Theme.TextSize.Caption
	deadBtn.FontFace = Theme.Font.Bold
	deadBtn.AutoButtonColor = false
	deadBtn.BorderSizePixel = 0
	deadBtn.LayoutOrder = 3
	deadBtn.Parent = toolbar
	Instance.new("UICorner", deadBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)
	deadBtn.MouseButton1Click:Connect(function()
		self._showDead = not self._showDead
		if nexus then nexus._lastDataRefresh = 0 end
	end)
end

-- ══════════════════════════════════════════════════════════════
-- ENTITY ROW
-- ══════════════════════════════════════════════════════════════

function EntityModule:_BuildEntityRow(parent: Frame, id: string, entityData: any, nexus: any, order: number, isDead: boolean): Frame
	local statusColor = if isDead then Theme.Colors.Danger else Theme.Colors.Success

	-- Build right-anchored stats: data fields, tags, badges, version, type
	local dataCount = 0
	if type(entityData.Data) == "table" then
		for _ in pairs(entityData.Data) do dataCount += 1 end
	end

	local stats: { Theme.RowStat } = {
		{ Text = string.format("%d fields", dataCount), Color = Theme.Colors.TextMuted, Width = 60, Mono = false, FontSize = Theme.TextSize.Tiny },
	}

	if type(entityData.Tags) == "table" and #entityData.Tags > 0 then
		table.insert(stats, 1, {
			Text = "#" .. tostring(#entityData.Tags),
			Color = Theme.Colors.TextMuted,
			Width = 26,
			FontSize = Theme.TextSize.Tiny,
		})
	end

	if entityData.IsPersistent then
		table.insert(stats, 1, { Text = "◆", Color = Theme.Colors.Purple, Width = 16, Mono = false })
	end
	if entityData.HasFSM then
		table.insert(stats, 1, { Text = "⚙", Color = Theme.Colors.Orange, Width = 16, Mono = false })
	end

	table.insert(stats, 1, {
		Text = "v" .. tostring(entityData.Version or 0),
		Color = Theme.Colors.TextMuted,
		Width = 30,
		FontSize = Theme.TextSize.Tiny,
		Align = Enum.TextXAlignment.Center,
	})

	-- Type badge as colored stat
	local className = entityData.ClassName or "?"
	local cyanRgb = string.format("rgb(%d,%d,%d)", math.floor(Theme.Colors.Cyan.R * 255), math.floor(Theme.Colors.Cyan.G * 255), math.floor(Theme.Colors.Cyan.B * 255))
	table.insert(stats, 1, {
		Text = string.format('<font color="%s"><b>%s</b></font>', cyanRgb, className),
		Width = 90,
		Mono = false,
	})

	local row = Theme.CreateRow({
		Name = "Entity_" .. id,
		Size = UDim2.new(1, 0, 0, 38),
		StatusColor = statusColor,
		Title = id,
		TitleColor = if isDead then Theme.Colors.TextMuted else Theme.Colors.TextPrimary,
		BackgroundColor = if isDead then Theme.Colors.Danger else Theme.Colors.GlassTertiary,
		BackgroundTransparency = if isDead then 0.9 else 0.85,
		LayoutOrder = order,
		Stats = stats,
		Parent = parent,
		OnClick = function()
			self._selectedEntity = id
			if nexus._navigator then
				nexus._navigator:ExpandLayer({
					Id = "entity.detail." .. id,
					ParentId = "ENTITY",
					Label = id,
					Builder = function(f, ctx) self:_BuildEntityDetailLayer(f, ctx) end,
					Context = { Nexus = nexus, EntityId = id, EntityData = entityData, IsDead = isDead },
				})
			end
		end,
	})

	-- Pulse status dot when alive
	local dot = row:FindFirstChild("StatusDot")
	if dot and not isDead and nexus._animationController then
		nexus._animationController:StartPulse("entity_" .. id, dot, "BackgroundTransparency", 0.6)
	end

	-- Hover glow
	local btn = row:FindFirstChild("ClickOverlay")
	if btn and nexus._animationController then
		nexus._animationController:HoverGlow(btn, Theme.Colors.Accent)
	end

	return row
end

-- ══════════════════════════════════════════════════════════════
-- ENTITY DETAIL LAYER
-- ══════════════════════════════════════════════════════════════

function EntityModule:_BuildEntityDetailLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	local entityId = context.EntityId or "?"
	local entityData = context.EntityData or {}
	local isDead = context.IsDead or false

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
	local headerIcon = if isDead then "✕" else "◇"
	Theme.CreateLabel({
		Text = string.format('%s %s', headerIcon, entityId),
		Size = UDim2.new(1, 0, 0, 22),
		Color = if isDead then Theme.Colors.Danger else Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	-- ─── IDENTITY ───
	Theme.CreateLabel({
		Text = "IDENTITY",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 5

	local identityProps = {
		{ Key = "Entity Id", Value = entityId, Color = Theme.Colors.Accent },
		{ Key = "Class", Value = entityData.ClassName or "Unknown", Color = Theme.Colors.Cyan },
		{ Key = "Status", Value = if isDead then "DEAD" else "ALIVE", Color = if isDead then Theme.Colors.Danger else Theme.Colors.Success },
	}
	for i, p in ipairs(identityProps) do
		self:_BuildPropRow(contentFrame, p.Key, p.Value, p.Color, 5 + i)
	end

	-- Interactive Version button → drills into version history
	local versionRow = Instance.new("Frame")
	versionRow.Name = "VersionRow"
	versionRow.Size = UDim2.new(1, 0, 0, 28)
	versionRow.BackgroundColor3 = Theme.Colors.GlassTertiary
	versionRow.BackgroundTransparency = 0.85
	versionRow.BorderSizePixel = 0
	versionRow.LayoutOrder = 9
	versionRow.Parent = contentFrame
	Instance.new("UICorner", versionRow).CornerRadius = UDim.new(0, Theme.Radius.Xs)
	local vrPad = Instance.new("UIPadding")
	vrPad.PaddingLeft = UDim.new(0, 10)
	vrPad.PaddingRight = UDim.new(0, 10)
	vrPad.Parent = versionRow

	Theme.CreateLabel({
		Text = "Version",
		Size = UDim2.new(0.45, 0, 1, 0),
		Color = Theme.Colors.TextSecondary,
		FontSize = Theme.TextSize.Caption,
		Parent = versionRow,
	})

	local versionBtn = Instance.new("TextButton")
	versionBtn.Name = "VersionButton"
	versionBtn.AnchorPoint = Vector2.new(1, 0.5)
	versionBtn.Position = UDim2.new(1, 0, 0.5, 0)
	versionBtn.Size = UDim2.new(0, 220, 0, 22)
	versionBtn.BackgroundColor3 = Theme.Colors.GlassOverlay
	versionBtn.BackgroundTransparency = 0.4
	versionBtn.BorderSizePixel = 0
	versionBtn.AutoButtonColor = false
	versionBtn.FontFace = Theme.Font.Mono
	versionBtn.TextSize = Theme.TextSize.Body
	versionBtn.TextColor3 = Theme.Colors.Accent
	versionBtn.RichText = true
	local historyLen = 0
	if type(entityData.VersionHistory) == "table" then
		historyLen = #entityData.VersionHistory
	end
	versionBtn.Text = string.format('v%d  <font color="#888">— View History (%d) ▶</font>',
		entityData.Version or 0, historyLen)
	versionBtn.Parent = versionRow
	Instance.new("UICorner", versionBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)

	versionBtn.MouseButton1Click:Connect(function()
		local nexus = context.Nexus
		if nexus and nexus._navigator then
			nexus._navigator:ExpandLayer({
				Id = "entity.versions." .. entityId,
				ParentId = "entity.detail." .. entityId,
				Label = "Versions",
				Builder = function(f, ctx) self:_BuildVersionHistoryLayer(f, ctx) end,
				Context = {
					Nexus = nexus,
					EntityId = entityId,
					VersionHistory = entityData.VersionHistory or {},
					CurrentVersion = entityData.Version or 0,
				},
			})
		end
	end)
	if context.Nexus and context.Nexus._animationController then
		context.Nexus._animationController:HoverGlow(versionBtn, Theme.Colors.Accent)
	end

	-- ─── STATE ───
	Theme.CreateLabel({
		Text = "STATE",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 20

	local stateProps = {
		{ Key = "Is Valid", Value = tostring(entityData.IsValid), Color = if entityData.IsValid then Theme.Colors.Success else Theme.Colors.Danger },
		{ Key = "Persistent", Value = tostring(entityData.IsPersistent), Color = Theme.Colors.Purple },
		{ Key = "Has FSM", Value = tostring(entityData.HasFSM), Color = Theme.Colors.Orange },
	}
	if entityData.FSMId then
		table.insert(stateProps, { Key = "FSM Id", Value = entityData.FSMId, Color = Theme.Colors.Orange })
	end
	for i, p in ipairs(stateProps) do
		self:_BuildPropRow(contentFrame, p.Key, p.Value, p.Color, 20 + i)
	end

	-- ─── TAGS ───
	if type(entityData.Tags) == "table" and #entityData.Tags > 0 then
		Theme.CreateLabel({
			Text = string.format("TAGS (%d)", #entityData.Tags),
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Parent = contentFrame,
		}).LayoutOrder = 35

		local tagRow = Instance.new("Frame")
		tagRow.Size = UDim2.new(1, 0, 0, 22)
		tagRow.BackgroundTransparency = 1
		tagRow.LayoutOrder = 36
		tagRow.Parent = contentFrame

		local tagLayout = Instance.new("UIListLayout")
		tagLayout.FillDirection = Enum.FillDirection.Horizontal
		tagLayout.Padding = UDim.new(0, 4)
		tagLayout.Parent = tagRow

		for _, tag in ipairs(entityData.Tags) do
			local tagBadge = Theme.CreateBadge(tostring(tag), Theme.Colors.Purple)
			tagBadge.Parent = tagRow
		end
	end

	-- ─── CONTEXT ───
	if type(entityData.Context) == "table" then
		local ctxCount = 0
		for _ in pairs(entityData.Context) do ctxCount += 1 end
		if ctxCount > 0 then
			Theme.CreateLabel({
				Text = string.format("CONTEXT (%d)", ctxCount),
				Size = UDim2.new(1, 0, 0, 16),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 40

			local order = 41
			for key, value in pairs(entityData.Context) do
				self:_BuildPropRow(contentFrame, tostring(key), self:_Stringify(value), Theme.Colors.TextPrimary, order)
				order += 1
			end
		end
	end

	-- ─── DATA ───
	if type(entityData.Data) == "table" then
		local dataCount = 0
		for _ in pairs(entityData.Data) do dataCount += 1 end
		if dataCount > 0 then
			Theme.CreateLabel({
				Text = string.format("DATA (%d fields)", dataCount),
				Size = UDim2.new(1, 0, 0, 16),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 60

			local order = 61
			for key, value in pairs(entityData.Data) do
				local valStr = self:_Stringify(value)
				local valColor = self:_TypeColor(value)
				if type(value) == "table" then
					-- Clickable row for nested tables
					local propRow = Instance.new("Frame")
					propRow.Size = UDim2.new(1, 0, 0, 24)
					propRow.BackgroundColor3 = Theme.Colors.GlassTertiary
					propRow.BackgroundTransparency = 0.88
					propRow.BorderSizePixel = 0
					propRow.LayoutOrder = order
					propRow.Parent = contentFrame
					Instance.new("UICorner", propRow).CornerRadius = UDim.new(0, Theme.Radius.Xs)
					local pp = Instance.new("UIPadding")
					pp.PaddingLeft = UDim.new(0, 8)
					pp.PaddingRight = UDim.new(0, 8)
					pp.Parent = propRow
					Theme.CreateLabel({ Text = tostring(key), Size = UDim2.new(0.45, 0, 1, 0), Color = Theme.Colors.TextSecondary, FontSize = Theme.TextSize.Caption, Parent = propRow })
					Theme.CreateLabel({ Text = valStr .. " ▶", Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0.48, 0, 0, 0), Color = Theme.Colors.Purple, FontSize = Theme.TextSize.Body, FontFace = Theme.Font.Mono, Alignment = Enum.TextXAlignment.Right, Parent = propRow })
					local tableBtn = Instance.new("TextButton")
					tableBtn.Size = UDim2.new(1, 0, 1, 0)
					tableBtn.BackgroundTransparency = 1
					tableBtn.Text = ""
					tableBtn.ZIndex = 10
					tableBtn.Parent = propRow
					local capturedKey = key
					local capturedValue = value
					tableBtn.MouseButton1Click:Connect(function()
						if nexus and nexus._navigator then
							nexus._navigator:ExpandLayer({
								Id = "entity.data." .. entityId .. "." .. tostring(capturedKey),
								ParentId = "entity.detail." .. entityId,
								Label = tostring(capturedKey),
								Builder = function(f, ctx) self:_BuildTableViewLayer(f, ctx) end,
								Context = { Nexus = nexus, TableKey = tostring(capturedKey), TableData = capturedValue, EntityId = entityId },
							})
						end
					end)
				else
					self:_BuildPropRow(contentFrame, tostring(key), valStr, valColor, order)
				end
				order += 1
				if order > 90 then break end -- cap to prevent lag
			end
		end
	end

	-- ─── SCHEMA ───
	if type(entityData.Schema) == "table" then
		local schemaCount = 0
		for _ in pairs(entityData.Schema) do schemaCount += 1 end
		if schemaCount > 0 then
			Theme.CreateLabel({
				Text = string.format("SCHEMA (%d)", schemaCount),
				Size = UDim2.new(1, 0, 0, 16),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Caption,
				FontFace = Theme.Font.Bold,
				Parent = contentFrame,
			}).LayoutOrder = 100

			local order = 101
			for fieldName, fieldDef in pairs(entityData.Schema) do
				local badges = ""
				if type(fieldDef) == "table" then
					if fieldDef.Type then badges ..= fieldDef.Type .. " " end
					if fieldDef.Persist then badges ..= "◆ " end
					if fieldDef.Replicate then badges ..= "↗ " end
				else
					badges = tostring(fieldDef)
				end
				self:_BuildPropRow(contentFrame, tostring(fieldName), badges, Theme.Colors.Cyan, order)
				order += 1
				if order > 130 then break end
			end
		end
	end
end

-- ══════════════════════════════════════════════════════════════
-- HELPERS
-- ══════════════════════════════════════════════════════════════

function EntityModule:_Stringify(value: any): string
	local t = type(value)
	if t == "string" then return '"' .. value .. '"'
	elseif t == "number" then return tostring(value)
	elseif t == "boolean" then return tostring(value)
	elseif t == "table" then
		local count = 0
		for _ in pairs(value) do count += 1 end
		return string.format("{%d entries}", count)
	elseif t == "nil" then return "nil"
	else return tostring(value) end
end

function EntityModule:_TypeColor(value: any): Color3
	local t = type(value)
	if t == "string" then return Theme.Colors.Success
	elseif t == "number" then return Theme.Colors.Cyan
	elseif t == "boolean" then return Theme.Colors.Orange
	elseif t == "table" then return Theme.Colors.Purple
	else return Theme.Colors.TextMuted end
end

function EntityModule:_BuildPropRow(parent: Frame, key: string, value: string, color: Color3, order: number)
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

-- ══════════════════════════════════════════════════════════════
-- TABLE DRILL-DOWN LAYER
-- ══════════════════════════════════════════════════════════════

function EntityModule:_BuildTableViewLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then child:Destroy() end
	end

	local tableKey = context.TableKey or "?"
	local tableData = context.TableData or {}
	local entityId = context.EntityId or "?"
	local nexus = context.Nexus

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = contentFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.Parent = contentFrame

	-- Header
	local count = 0
	for _ in pairs(tableData) do count += 1 end
	Theme.CreateLabel({
		Text = string.format("📂 %s (%d entries)", tableKey, count),
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	-- Entries
	local order = 1
	for key, value in pairs(tableData) do
		if type(value) == "table" then
			-- Nested table: another clickable row
			local nestedCount = 0
			for _ in pairs(value) do nestedCount += 1 end
			local propRow = Instance.new("Frame")
			propRow.Size = UDim2.new(1, 0, 0, 24)
			propRow.BackgroundColor3 = Theme.Colors.GlassTertiary
			propRow.BackgroundTransparency = 0.85
			propRow.BorderSizePixel = 0
			propRow.LayoutOrder = order
			propRow.Parent = contentFrame
			Instance.new("UICorner", propRow).CornerRadius = UDim.new(0, Theme.Radius.Xs)
			local pp = Instance.new("UIPadding")
			pp.PaddingLeft = UDim.new(0, 8)
			pp.PaddingRight = UDim.new(0, 8)
			pp.Parent = propRow
			Theme.CreateLabel({ Text = tostring(key), Size = UDim2.new(0.45, 0, 1, 0), Color = Theme.Colors.TextSecondary, FontSize = Theme.TextSize.Caption, Parent = propRow })
			Theme.CreateLabel({ Text = string.format("{%d entries} ▶", nestedCount), Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0.48, 0, 0, 0), Color = Theme.Colors.Purple, FontSize = Theme.TextSize.Body, FontFace = Theme.Font.Mono, Alignment = Enum.TextXAlignment.Right, Parent = propRow })
			local capturedKey = key
			local capturedValue = value
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(1, 0, 1, 0)
			btn.BackgroundTransparency = 1
			btn.Text = ""
			btn.ZIndex = 10
			btn.Parent = propRow
			btn.MouseButton1Click:Connect(function()
				if nexus and nexus._navigator then
					nexus._navigator:ExpandLayer({
						Id = "entity.data." .. entityId .. "." .. tableKey .. "." .. tostring(capturedKey),
						ParentId = "entity.data." .. entityId .. "." .. tableKey,
						Label = tostring(capturedKey),
						Builder = function(f, ctx) self:_BuildTableViewLayer(f, ctx) end,
						Context = { Nexus = nexus, TableKey = tostring(capturedKey), TableData = capturedValue, EntityId = entityId },
					})
				end
			end)
		else
			self:_BuildPropRow(contentFrame, tostring(key), self:_Stringify(value), self:_TypeColor(value), order)
		end
		order += 1
		if order > 200 then break end
	end
end

--[[
	Release autocomplete resources and clear cached entity snapshots.
]]
function EntityModule:Destroy()
	if self._searchAC then self._searchAC:Destroy(); self._searchAC = nil end
	table.clear(self._entityCache)
	table.clear(self._deadEntities)
end

-- ══════════════════════════════════════════════════════════════
-- VERSION HISTORY LAYER (drill-down from entity detail)
-- ══════════════════════════════════════════════════════════════

--[=[
	Render a per-entity version history list. Each entry shows:
	  v<N>  field name  old → new   timestamp
	@param frame Frame — the layer frame containing a child named "Content"
	@param context { Nexus, EntityId, VersionHistory: { { Version, Time, Field, From, To } }, CurrentVersion }
]=]
function EntityModule:_BuildVersionHistoryLayer(frame: Frame, context: any)
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

	local entityId = context.EntityId or "?"
	local history = context.VersionHistory or {}
	local current = context.CurrentVersion or 0

	Theme.CreateLabel({
		Text = string.format('<font color="#3898FF">≡</font> Version History — %s  <font color="#666">(v%d, %d entries)</font>',
			entityId, current, #history),
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	if #history == 0 then
		Theme.CreateLabel({
			Text = "(no version history available — fields may not be tracked)",
			Size = UDim2.new(1, 0, 0, 24),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Body,
			Parent = contentFrame,
		}).LayoutOrder = 1
		return
	end

	-- Render newest first
	for i = #history, 1, -1 do
		local entry = history[i]
		local order = (#history - i) + 1

		local row = Instance.new("Frame")
		row.Name = "VersionEntry_" .. tostring(entry.Version or i)
		row.Size = UDim2.new(1, 0, 0, 30)
		row.BackgroundColor3 = if entry.Version == current then Theme.Colors.Accent else Theme.Colors.GlassTertiary
		row.BackgroundTransparency = if entry.Version == current then 0.7 else 0.85
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = contentFrame
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, Theme.Radius.Xs)
		local rp = Instance.new("UIPadding")
		rp.PaddingLeft = UDim.new(0, 10)
		rp.PaddingRight = UDim.new(0, 10)
		rp.Parent = row

		-- Version badge
		Theme.CreateLabel({
			Text = string.format("v%d", entry.Version or i),
			Size = UDim2.new(0, 36, 1, 0),
			Color = Theme.Colors.Accent,
			FontSize = Theme.TextSize.Body,
			FontFace = Theme.Font.Bold,
			Parent = row,
		})

		-- Field name + transition (with arrow)
		local fromStr = if entry.From == nil then "<font color=\"#888\">∅</font>" else tostring(entry.From)
		local toStr = if entry.To == nil then "<font color=\"#888\">∅</font>" else tostring(entry.To)
		Theme.CreateLabel({
			Text = string.format(
				'<font color="#9DC9FF">%s</font>  %s <font color="#3898FF">▶</font> %s',
				tostring(entry.Field or "?"), fromStr, toStr),
			Size = UDim2.new(1, -120, 1, 0),
			Position = UDim2.new(0, 42, 0, 0),
			Color = Theme.Colors.TextPrimary,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Mono,
			Parent = row,
		})

		-- Timestamp (relative)
		local timeStr
		if entry.Time then
			local ago = os.clock() - entry.Time
			if ago < 60 then timeStr = string.format("%.0fs ago", ago)
			elseif ago < 3600 then timeStr = string.format("%.0fm ago", ago / 60)
			else timeStr = string.format("%.1fh ago", ago / 3600)
			end
		else
			timeStr = "—"
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
			Parent = row,
		})
	end
end

return EntityModule
