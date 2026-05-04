--!strict


local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Parent.Theme)
local SearchAutocomplete = require(script.Parent.Parent.SearchAutocomplete)

-- ══════════════════════════════════════════════════════════════
-- TYPES
-- ══════════════════════════════════════════════════════════════

type LogEntry = {
	Level: string,
	Message: string,
	Timestamp: number,
	Source: string?,
	CorrelationId: string?,
}

-- ══════════════════════════════════════════════════════════════
-- MODULE
-- ══════════════════════════════════════════════════════════════

local LogsModule = {}
LogsModule.__index = LogsModule

local MAX_DISPLAY_LOGS = 200
local LEVEL_ORDER = {"ALL","DEBUG","INFO","WARN","ERROR" }


function LogsModule.new(): any
	local self = setmetatable({}, LogsModule)
	self._logCache = {} :: { LogEntry }
	self._filteredLogs = {} :: { LogEntry }
	self._activeFilter = "ALL"
	self._searchText = ""
	self._autoScroll = true
	self._scrollFrame = nil :: ScrollingFrame?
	self._filterButtons = {} :: { [string]: TextButton }
	self._lastRenderedHash = ""
	self._lastLoggerCount = 0
	self._lastInternalLogCount = 0
	self._lastServerLogCount = 0
	return self
end


function LogsModule:FetchData(nexus: any)
	local orchestrator = nexus._orchestrator
	if not orchestrator then return end

	local changed = false

	-- Gather from orchestrator Logger.History
	if orchestrator.Logger then
		local logBuffer = orchestrator.Logger.History or {}
		local lastCount = self._lastLoggerCount
		if #logBuffer > lastCount then
			for i = lastCount + 1, #logBuffer do
				local entry = logBuffer[i]
				if type(entry) == "table" then
					table.insert(self._logCache, {
						Level = entry.Level or "INFO",
						Message = entry.Message or tostring(entry),
						Timestamp = entry.Timestamp or os.time(),
						Source = entry.Source or entry.Subsystem or "Orchestrator",
						CorrelationId = entry.OperationId or entry.CorrelationId or nil,
					})
				end
			end
			self._lastLoggerCount = #logBuffer
			changed = true
		end
	end

	-- Gather from ServiceManager internal log buffer
	local internalLogs = nexus._logs or {}
	local lastInternalCount = self._lastInternalLogCount
	if #internalLogs > lastInternalCount then
		for i = lastInternalCount + 1, #internalLogs do
			local entry = internalLogs[i]
			if type(entry) == "table" then
				table.insert(self._logCache, {
					Level = entry.Level or "INFO",
					Message = entry.Message or "",
					Timestamp = entry.Timestamp or 0,
					Source = "ServiceManager",
				})
			end
		end
		self._lastInternalLogCount = #internalLogs
		changed = true
	end

	-- Server mode: include server logs
	if nexus._contextMode == "server" then
		local serverData = nexus._serverData
		if serverData and serverData.Logs then
			local serverLogs = serverData.Logs
			local lastServerCount = self._lastServerLogCount
			if #serverLogs > lastServerCount then
				for i = lastServerCount + 1, #serverLogs do
					local entry = serverLogs[i]
					if type(entry) == "table" then
						table.insert(self._logCache, {
							Level = entry.Level or "INFO",
							Message = entry.Message or "",
							Timestamp = entry.Timestamp or 0,
							Source = entry.Source or "Server",
							CorrelationId = entry.CorrelationId or nil,
						})
					end
				end
				self._lastServerLogCount = #serverLogs
				changed = true
			end
		end
	end

	if changed then
		-- Trim oldest entries
		while #self._logCache > MAX_DISPLAY_LOGS * 2 do
			table.remove(self._logCache, 1)
		end
		self:_ApplyFilters()
		-- Only re-render logs when new entries were actually added
		self:_RenderLogs()
	end

	nexus.Store:BatchUpdate(function()
		nexus.Store:Set("logs.count", #self._logCache)
		nexus.Store:Set("logs.filteredCount", #self._filteredLogs)
		nexus.Store:Set("logs.filter", self._activeFilter)
	end)
end


function LogsModule:Render(nexus: any) end


function LogsModule:_ApplyFilters()
	self._filteredLogs = {}

	for _, entry in ipairs(self._logCache) do
		-- Level filter
		if self._activeFilter ~= "ALL" and entry.Level ~= self._activeFilter then
			continue
		end

		-- Text search filter
		if self._searchText ~= "" then
			local lower = string.lower(self._searchText)
			local msgLower = string.lower(entry.Message)
			local srcLower = string.lower(entry.Source or "")
			if not msgLower:find(lower, 1, true) and not srcLower:find(lower, 1, true) then
				continue
			end
		end

		table.insert(self._filteredLogs, entry)
	end

	-- Limit display
	while #self._filteredLogs > MAX_DISPLAY_LOGS do
		table.remove(self._filteredLogs, 1)
	end
end


function LogsModule:BuildRootLayer(frame: Frame, context: any)
	local nexus = context.Nexus
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	-- Disable outer ScrollingFrame auto-sizing (logs uses absolute layout)
	if contentFrame:IsA("ScrollingFrame") then
		contentFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
		contentFrame.ScrollBarThickness = 0
	end

	-- Idempotent: if already built, don't rebuild (logs render incrementally via FetchData)
	if contentFrame:FindFirstChild("LogScroll") then
		return
	end

	-- Clear
	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then
			child:Destroy()
		end
	end

	-- Main layout: toolbar + scrolling log area
	local toolbarHeight = 68

	-- ── TOOLBAR ──
	local toolbar = Instance.new("Frame")
	toolbar.Name = "LogToolbar"
	toolbar.Size = UDim2.new(1, -8, 0, toolbarHeight)
	toolbar.Position = UDim2.new(0, 4, 0, 4)
	toolbar.BackgroundColor3 = Theme.Colors.GlassTertiary
	toolbar.BackgroundTransparency = 0.5
	toolbar.BorderSizePixel = 0
	toolbar.ZIndex = 10
	toolbar.Parent = contentFrame

	local toolCorner = Instance.new("UICorner")
	toolCorner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	toolCorner.Parent = toolbar

	-- Level filter buttons row
	local filterRow = Instance.new("Frame")
	filterRow.Size = UDim2.new(1, -16, 0, 24)
	filterRow.Position = UDim2.new(0, 8, 0, 6)
	filterRow.BackgroundTransparency = 1
	filterRow.Parent = toolbar

	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
	filterLayout.Padding = UDim.new(0, 4)
	filterLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	filterLayout.Parent = filterRow

	local levelColors = {
		ALL = Theme.Colors.TextSecondary,
		DEBUG = Theme.Colors.TextMuted,
		INFO = Theme.Colors.Accent,
		WARN = Theme.Colors.Warning,
		ERROR = Theme.Colors.Danger,
	}

	self._filterButtons = {}
	for i, level in ipairs(LEVEL_ORDER) do
		local isActive = self._activeFilter == level
		local color = levelColors[level] or Theme.Colors.TextMuted

		local btn = Instance.new("TextButton")
		btn.Name = "Filter_" .. level
		btn.Size = UDim2.new(0, 56, 0, 22)
		btn.BackgroundColor3 = color
		btn.BackgroundTransparency = if isActive then 0.3 else 0.8
		btn.Text = level
		btn.TextColor3 = if isActive then Theme.Colors.TextOnAccent else color
		btn.TextSize = Theme.TextSize.Badge
		btn.FontFace = Theme.Font.Bold
		btn.AutoButtonColor = false
		btn.BorderSizePixel = 0
		btn.LayoutOrder = i
		btn.ZIndex = 11
		btn.Parent = filterRow

		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, Theme.Radius.Xs)
		bc.Parent = btn

		self._filterButtons[level] = btn

		btn.MouseButton1Click:Connect(function()
			self._activeFilter = level
			self:_ApplyFilters()
			self:_UpdateFilterVisuals()
			self:_RenderLogs()
		end)
	end

	-- Log count + clear button
	local countLabel = Theme.CreateLabel({
		Text = string.format("%d logs", #self._filteredLogs),
		Size = UDim2.new(0, 80, 0, 22),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Mono,
		Alignment = Enum.TextXAlignment.Right,
		Parent = filterRow,
	})
	countLabel.LayoutOrder = 10
	countLabel.Name = "LogCount"

	local clearBtn = Instance.new("TextButton")
	clearBtn.Name = "ClearLogs"
	clearBtn.Size = UDim2.new(0, 48, 0, 22)
	clearBtn.BackgroundColor3 = Theme.Colors.Danger
	clearBtn.BackgroundTransparency = 0.7
	clearBtn.Text = "CLEAR"
	clearBtn.TextColor3 = Theme.Colors.Danger
	clearBtn.TextSize = Theme.TextSize.Badge
	clearBtn.FontFace = Theme.Font.Bold
	clearBtn.AutoButtonColor = false
	clearBtn.BorderSizePixel = 0
	clearBtn.LayoutOrder = 11
	clearBtn.ZIndex = 11
	clearBtn.Parent = filterRow

	local clearCorner = Instance.new("UICorner")
	clearCorner.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	clearCorner.Parent = clearBtn

	clearBtn.MouseButton1Click:Connect(function()
		table.clear(self._logCache)
		table.clear(self._filteredLogs)
		self._lastLoggerCount = 0
		self._lastInternalLogCount = 0
		self._lastServerLogCount = 0
		self:_RenderLogs()
	end)

	-- Search bar
	local searchBar = Instance.new("Frame")
	searchBar.Size = UDim2.new(1, -16, 0, 26)
	searchBar.Position = UDim2.new(0, 8, 0, 34)
	searchBar.BackgroundColor3 = Theme.Colors.GlassOverlay
	searchBar.BackgroundTransparency = 0.3
	searchBar.BorderSizePixel = 0
	searchBar.Parent = toolbar

	local searchCorner = Instance.new("UICorner")
	searchCorner.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	searchCorner.Parent = searchBar

	local searchIcon = Theme.CreateLabel({
		Text = "🔍",
		Size = UDim2.new(0, 24, 1, 0),
		Position = UDim2.new(0, 4, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		Alignment = Enum.TextXAlignment.Center,
		Parent = searchBar,
	})
	searchIcon.ZIndex = 11

	local searchInput = Instance.new("TextBox")
	searchInput.Name = "SearchInput"
	searchInput.Size = UDim2.new(1, -32, 1, -4)
	searchInput.Position = UDim2.new(0, 28, 0, 2)
	searchInput.BackgroundTransparency = 1
	searchInput.Text = self._searchText
	searchInput.PlaceholderText = "Filter logs..."
	searchInput.PlaceholderColor3 = Theme.Colors.TextMuted
	searchInput.TextColor3 = Theme.Colors.TextPrimary
	searchInput.TextSize = Theme.TextSize.Caption
	searchInput.FontFace = Theme.Font.Mono
	searchInput.TextXAlignment = Enum.TextXAlignment.Left
	searchInput.ClearTextOnFocus = false
	searchInput.BorderSizePixel = 0
	searchInput.ZIndex = 11
	searchInput.Parent = searchBar

	searchInput:GetPropertyChangedSignal("Text"):Connect(function()
		self._searchText = searchInput.Text
		self:_ApplyFilters()
		self:_RenderLogs()
	end)

	-- Attach search autocomplete with log source names
	if self._searchAC then self._searchAC:Destroy() end
	self._searchAC = SearchAutocomplete.new({
		TextBox = searchInput,
		ParentFrame = contentFrame,
		GetSuggestions = function(text: string): { string }
			local lower = string.lower(text)
			local seen = {} :: { [string]: boolean }
			local matches = {}
			for _, entry in ipairs(self._logCache) do
				local source = entry.Source or entry.Subsystem or ""
				if source ~= "" and not seen[source] and string.find(string.lower(source), lower, 1, true) then
					seen[source] = true
					table.insert(matches, source)
				end
				-- Also match on log level
				local level = entry.Level or ""
				if level ~= "" and not seen[level] and string.find(string.lower(level), lower, 1, true) then
					seen[level] = true
					table.insert(matches, level)
				end
			end
			table.sort(matches)
			return matches
		end,
		OnSelect = function(selected: string)
			self._searchText = selected
			self:_ApplyFilters()
			self:_RenderLogs()
		end,
	})

	-- ── LOG SCROLL AREA ──
	local logScroll = Instance.new("ScrollingFrame")
	logScroll.Name = "LogScroll"
	logScroll.Size = UDim2.new(1, -8, 1, -toolbarHeight - 12)
	logScroll.Position = UDim2.new(0, 4, 0, toolbarHeight + 8)
	logScroll.BackgroundColor3 = Color3.fromRGB(6, 6, 12)
	logScroll.BackgroundTransparency = 0.3
	logScroll.BorderSizePixel = 0
	logScroll.ScrollBarThickness = 4
	logScroll.ScrollBarImageColor3 = Theme.Colors.Purple
	logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	logScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	logScroll.ZIndex = 8
	logScroll.Parent = contentFrame
	self._scrollFrame = logScroll

	local logCorner = Instance.new("UICorner")
	logCorner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	logCorner.Parent = logScroll

	local logLayout = Instance.new("UIListLayout")
	logLayout.SortOrder = Enum.SortOrder.LayoutOrder
	logLayout.Padding = UDim.new(0, 1)
	logLayout.Parent = logScroll

	local logPad = Instance.new("UIPadding")
	logPad.PaddingLeft = UDim.new(0, 6)
	logPad.PaddingRight = UDim.new(0, 6)
	logPad.PaddingTop = UDim.new(0, 4)
	logPad.PaddingBottom = UDim.new(0, 4)
	logPad.Parent = logScroll

	-- Render initial logs
	self:_RenderLogs()
end


function LogsModule:_UpdateFilterVisuals()
	local levelColors = {
		ALL = Theme.Colors.TextSecondary,
		DEBUG = Theme.Colors.TextMuted,
		INFO = Theme.Colors.Accent,
		WARN = Theme.Colors.Warning,
		ERROR = Theme.Colors.Danger,
	}

	for level, btn in pairs(self._filterButtons) do
		local isActive = self._activeFilter == level
		local color = levelColors[level] or Theme.Colors.TextMuted
		TweenService:Create(btn, Theme.Tween.Fast, {
			BackgroundTransparency = if isActive then 0.3 else 0.8,
			TextColor3 = if isActive then Theme.Colors.TextOnAccent else color,
		}):Play()
	end
end


function LogsModule:_RenderLogs()
	local scroll = self._scrollFrame
	if not scroll then return end

	-- Clear existing log lines
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local levelColors = {
		DEBUG = Theme.Colors.TextMuted,
		INFO = Theme.Colors.Accent,
		WARN = Theme.Colors.Warning,
		ERROR = Theme.Colors.Danger,
	}

	local levelIcons = {
		DEBUG = "◌",
		INFO = "●",
		WARN = "↑",
		ERROR = "✕",
	}

	for i, entry in ipairs(self._filteredLogs) do
		local color = levelColors[entry.Level] or Theme.Colors.TextSecondary
		local icon = levelIcons[entry.Level] or "○"

		local row = Instance.new("Frame")
		row.Name = "Log_" .. tostring(i)
		row.Size = UDim2.new(1, 0, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.BackgroundColor3 = if entry.Level == "ERROR" then Theme.Colors.Danger
			elseif entry.Level == "WARN" then Theme.Colors.Warning
			else Theme.Colors.GlassTertiary
		row.BackgroundTransparency = if entry.Level == "ERROR" then 0.92
			elseif entry.Level == "WARN" then 0.93
			else 0.95
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.ZIndex = 9
		row.Parent = scroll

		local rowPad = Instance.new("UIPadding")
		rowPad.PaddingLeft = UDim.new(0, 4)
		rowPad.PaddingRight = UDim.new(0, 4)
		rowPad.PaddingTop = UDim.new(0, 1)
		rowPad.PaddingBottom = UDim.new(0, 1)
		rowPad.Parent = row

		-- Timestamp
		-- Compute elapsed time, handling both os.clock() and os.time() timestamps
		local ts = entry.Timestamp or 0
		local elapsed: number
		if ts > 1e9 then
			-- os.time() epoch timestamp
			elapsed = os.time() - ts
		else
			-- os.clock() relative timestamp
			elapsed = os.clock() - ts
		end
		if elapsed < 0 then elapsed = 0 end
		local timeStr
		if elapsed < 60 then
			timeStr = string.format("%.0fs", elapsed)
		elseif elapsed < 3600 then
			timeStr = string.format("%.0fm", elapsed / 60)
		else
			timeStr = string.format("%.1fh", elapsed / 3600)
		end

		-- Compose line: [TIME] ICON [SOURCE] Message
		local sourceTag = ""
		if entry.Source and entry.Source ~= "" then
			sourceTag = string.format('<font color="#8A8EA0">[%s]</font> ', entry.Source)
		end

		local colorHex = string.format("#%02X%02X%02X",
			math.floor(color.R * 255), math.floor(color.G * 255), math.floor(color.B * 255))

		local logText = string.format(
			'<font color="#525668">%5s</font> <font color="%s">%s</font> %s%s',
			timeStr, colorHex, icon, sourceTag, entry.Message
		)

		local logLabel = Instance.new("TextLabel")
		logLabel.Size = UDim2.new(1, 0, 0, 0)
		logLabel.AutomaticSize = Enum.AutomaticSize.Y
		logLabel.BackgroundTransparency = 1
		logLabel.Text = logText
		logLabel.TextColor3 = Theme.Colors.TextSecondary
		logLabel.TextSize = Theme.TextSize.Caption
		logLabel.FontFace = Theme.Font.Mono
		logLabel.TextXAlignment = Enum.TextXAlignment.Left
		logLabel.TextWrapped = true
		logLabel.RichText = true
		logLabel.ZIndex = 10
		logLabel.Parent = row
	end

	-- Update count label
	if scroll.Parent then
		local toolbar = scroll.Parent:FindFirstChild("LogToolbar")
		if toolbar then
			local filterRow = toolbar:FindFirstChildWhichIsA("Frame")
			if filterRow then
				local countLabel = filterRow:FindFirstChild("LogCount") :: TextLabel?
				if countLabel then
					countLabel.Text = string.format("%d logs", #self._filteredLogs)
				end
			end
		end
	end

	-- Auto-scroll
	if self._autoScroll then
		task.defer(function()
			if scroll then
				scroll.CanvasPosition = Vector2.new(0, scroll.AbsoluteCanvasSize.Y)
			end
		end)
	end
end


function LogsModule:Destroy()
	if self._searchAC then self._searchAC:Destroy(); self._searchAC = nil end
	table.clear(self._logCache)
	table.clear(self._filteredLogs)
	table.clear(self._filterButtons)
	self._scrollFrame = nil
end

return LogsModule
