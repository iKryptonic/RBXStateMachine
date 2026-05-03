--!strict
--[=[
	@module InsightsModule
	@description Defines the `InsightsModule` module and its exported API.
]=]

local Theme = require(script.Parent.Parent.Theme)

local InsightsModule = {}
InsightsModule.__index = InsightsModule
--[=[
	@description Implements `InsightsModule.new`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function InsightsModule.new(): any
	local self = setmetatable({}, InsightsModule)
	self._activeInsights = {} :: { any }
	self._historyInsights = {} :: { any }
	return self
end
--[=[
	@description Implements `InsightsModule.FetchData`.
	@param nexus any -- `nexus` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function InsightsModule:FetchData(nexus: any)
	local analytics = nexus._analyticsEngine
	if not analytics then return end

	-- Run insight analysis cycle if needed, so insights actually populate
	if analytics:HasPendingWork() then
		local ok, err = pcall(analytics.RunCycle, analytics, nexus)
		if not ok then
			warn("[InsightsModule] AnalyticsEngine cycle error: " .. tostring(err))
		end
	end

	self._activeInsights = analytics:GetActiveInsights()
	self._historyInsights = analytics:GetHistory()

	nexus.Store:BatchUpdate(function()
		nexus.Store:Set("insights.active", self._activeInsights)
		nexus.Store:Set("insights.history", self._historyInsights)
		nexus.Store:Set("insights.activeCount", #self._activeInsights)
	end)
end
--[=[
	@description Implements `InsightsModule.Render`.
	@param nexus any -- `nexus` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function InsightsModule:Render(nexus: any) end
--[=[
	@description Creates the result managed by `InsightsModule.BuildRootLayer`.
	@param frame Frame -- `frame` input parameter.
	@param context any -- `context` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function InsightsModule:BuildRootLayer(frame: Frame, context: any)
	local nexus = context.Nexus
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then
			child:Destroy()
		end
	end

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 5)
	layout.Parent = contentFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 8)
	pad.Parent = contentFrame

	-- Severity summary strip
	local severityCounts = { CRITICAL = 0, WARNING = 0, INFO = 0, SUGGESTION = 0 }
	for _, ins in ipairs(self._activeInsights) do
		local sev = ins.Severity or "INFO"
		severityCounts[sev] = (severityCounts[sev] or 0) + 1
	end

	local summaryFrame = Instance.new("Frame")
	summaryFrame.Name = "SeveritySummary"
	summaryFrame.Size = UDim2.new(1, 0, 0, 28)
	summaryFrame.BackgroundColor3 = Theme.Colors.GlassTertiary
	summaryFrame.BackgroundTransparency = 0.88
	summaryFrame.BorderSizePixel = 0
	summaryFrame.LayoutOrder = 0
	summaryFrame.Parent = contentFrame
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	sc.Parent = summaryFrame

	local summaryLayout = Instance.new("UIListLayout")
	summaryLayout.FillDirection = Enum.FillDirection.Horizontal
	summaryLayout.SortOrder = Enum.SortOrder.LayoutOrder
	summaryLayout.Padding = UDim.new(0, 6)
	summaryLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	summaryLayout.Parent = summaryFrame

	local sp = Instance.new("UIPadding")
	sp.PaddingLeft = UDim.new(0, 8)
	sp.Parent = summaryFrame

	local severityColors = {
		CRITICAL = Theme.Colors.Danger,
		WARNING = Theme.Colors.Warning,
		INFO = Theme.Colors.Accent,
		SUGGESTION = Theme.Colors.Purple,
	}

	local order = 0
	for _, sev in ipairs({ "CRITICAL", "WARNING", "INFO", "SUGGESTION" }) do
		local badge = Theme.CreateBadge(
			string.format("%s %d", sev:sub(1, 4), severityCounts[sev]),
			severityColors[sev]
		)
		badge.LayoutOrder = order
		badge.Parent = summaryFrame
		order += 1
	end

	-- Active insights header
	Theme.CreateLabel({
		Text = string.format("ACTIVE INSIGHTS (%d)", #self._activeInsights),
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 1

	-- Insight rows
	local items = {}
	if #self._activeInsights == 0 then
		-- Show empty-state placeholder
		local emptyFrame = Instance.new("Frame")
		emptyFrame.Size = UDim2.new(1, 0, 0, 60)
		emptyFrame.BackgroundColor3 = Theme.Colors.GlassTertiary
		emptyFrame.BackgroundTransparency = 0.92
		emptyFrame.BorderSizePixel = 0
		emptyFrame.LayoutOrder = 2
		emptyFrame.Parent = contentFrame
		Instance.new("UICorner", emptyFrame).CornerRadius = UDim.new(0, Theme.Radius.Sm)

		Theme.CreateLabel({
			Text = "No active insights — system operating normally",
			Size = UDim2.new(1, -20, 0, 18),
			Position = UDim2.new(0, 10, 0.5, -9),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Body,
			FontFace = Theme.Font.Regular,
			Alignment = Enum.TextXAlignment.Center,
			Parent = emptyFrame,
		})
	end
	for i, insight in ipairs(self._activeInsights) do
		local row = self:_BuildInsightRow(contentFrame, insight, nexus, i + 1)
		table.insert(items, row)
	end

	-- History header
	Theme.CreateLabel({
		Text = string.format("HISTORY (%d)", math.min(#self._historyInsights, 20)),
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Caption,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 500

	-- Last 20 history items
	local historyEnd = math.min(#self._historyInsights, 20)
	if historyEnd == 0 then
		Theme.CreateLabel({
			Text = "No insight history yet",
			Size = UDim2.new(1, 0, 0, 18),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			Alignment = Enum.TextXAlignment.Center,
			Parent = contentFrame,
		}).LayoutOrder = 501
	end
	for i = #self._historyInsights, math.max(1, #self._historyInsights - historyEnd + 1), -1 do
		local ins = self._historyInsights[i]
		local hRow = self:_BuildHistoryRow(contentFrame, ins, 500 + (#self._historyInsights - i + 1))
		table.insert(items, hRow)
	end

	if nexus._animationController and #items > 0 then
		nexus._animationController:StaggerIn(
			items,
			{ BackgroundTransparency = 1 },
			{ BackgroundTransparency = 0.85 },
			Theme.Tween.Fast
		)
	end
end
--[=[
	@description Implements `InsightsModule._BuildInsightRow`.
	@param parent Frame -- `parent` input parameter.
	@param insight any -- `insight` input parameter.
	@param nexus any -- `nexus` input parameter.
	@param order number -- `order` input parameter.
	@return Frame -- Return value produced by the implementation, if any.
]=]

function InsightsModule:_BuildInsightRow(parent: Frame, insight: any, nexus: any, order: number): Frame
	local severityColors = {
		CRITICAL = Theme.Colors.Danger,
		WARNING = Theme.Colors.Warning,
		INFO = Theme.Colors.Accent,
		SUGGESTION = Theme.Colors.Purple,
	}
	local color = severityColors[insight.Severity] or Theme.Colors.TextMuted

	local row = Instance.new("Frame")
	row.Name = "Insight_" .. insight.Id
	-- Taller row to accommodate ActionableHints inline
	local hasHints = type(insight.ActionableHints) == "table" and #insight.ActionableHints > 0
	row.Size = UDim2.new(1, 0, 0, if hasHints then 64 else 40)
	row.BackgroundColor3 = Theme.Colors.GlassTertiary
	row.BackgroundTransparency = 0.85
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent

	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	rc.Parent = row

	local rp = Instance.new("UIPadding")
	rp.PaddingLeft = UDim.new(0, 8)
	rp.PaddingRight = UDim.new(0, 8)
	rp.Parent = row

	-- Severity dot
	local dot = Instance.new("Frame")
	dot.Size = UDim2.new(0, 8, 0, 8)
	dot.Position = UDim2.new(0, 0, 0, 8)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	dot.Parent = row
	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(1, 0)
	dc.Parent = dot

	-- Pulse critical dots
	if insight.Severity == "CRITICAL" and nexus._animationController then
		nexus._animationController:StartPulse(
			"ins_" .. insight.Id,
			dot,
			"BackgroundTransparency",
			0.6
		)
	end

	-- Title
	Theme.CreateLabel({
		Text = insight.Title,
		Size = UDim2.new(0.65, 0, 0, 16),
		Position = UDim2.new(0, 14, 0, 3),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Body,
		FontFace = Theme.Font.Bold,
		Parent = row,
	})

	-- Subsystem badge
	local badge = Theme.CreateBadge(insight.Subsystem, color)
	badge.Position = UDim2.new(0.72, 0, 0, 4)
	badge.Parent = row

	-- Description (truncated)
	Theme.CreateLabel({
		Text = insight.Description,
		Size = UDim2.new(0.95, 0, 0, 14),
		Position = UDim2.new(0, 14, 0, 22),
		Color = Theme.Colors.TextSecondary,
		FontSize = Theme.TextSize.Caption,
		Parent = row,
	})

	-- Click to drill
	local btn = Instance.new("TextButton")
	btn.Name = "DrillOverlay"
	btn.Size = UDim2.new(1, 0, 0, 40) -- only top portion is the click area; hints below take over
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.ZIndex = 10
	btn.Parent = row

	btn.MouseButton1Click:Connect(function()
		if nexus._navigator then
			nexus._navigator:ExpandLayer({
				Id = "insights.detail." .. insight.Id,
				ParentId = "INSIGHTS",
				Label = insight.Title,
				Builder = function(f, ctx) self:_BuildInsightDetailLayer(f, ctx) end,
				Context = { Nexus = nexus, Insight = insight },
			})
		end
	end)

	if nexus._animationController then
		nexus._animationController:HoverGlow(btn, color)
	end

	-- ─── ACTIONABLE HINTS ───
	-- Render any ActionableHints as inline buttons that execute their command
	-- through the Console module (or a no-op if none registered).
	if hasHints then
		local hintBar = Instance.new("Frame")
		hintBar.Name = "HintBar"
		hintBar.Size = UDim2.new(1, -16, 0, 22)
		hintBar.Position = UDim2.new(0, 14, 0, 40)
		hintBar.BackgroundTransparency = 1
		hintBar.ZIndex = 11
		hintBar.Parent = row

		local hbLayout = Instance.new("UIListLayout")
		hbLayout.FillDirection = Enum.FillDirection.Horizontal
		hbLayout.SortOrder = Enum.SortOrder.LayoutOrder
		hbLayout.Padding = UDim.new(0, 6)
		hbLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		hbLayout.Parent = hintBar

		for hi, hint in ipairs(insight.ActionableHints) do
			local hintBtn = Instance.new("TextButton")
			hintBtn.Name = "Hint_" .. hi
			hintBtn.AutomaticSize = Enum.AutomaticSize.X
			hintBtn.Size = UDim2.new(0, 0, 1, 0)
			hintBtn.BackgroundColor3 = Theme.Colors.GlassOverlay
			hintBtn.BackgroundTransparency = 0.4
			hintBtn.BorderSizePixel = 0
			hintBtn.Text = "  " .. hint.Label .. "  "
			hintBtn.TextColor3 = Theme.Colors.Accent
			hintBtn.TextSize = Theme.TextSize.Caption
			hintBtn.FontFace = Theme.Font.Bold
			hintBtn.AutoButtonColor = false
			hintBtn.LayoutOrder = hi
			hintBtn.ZIndex = 12
			hintBtn.Parent = hintBar
			Instance.new("UICorner", hintBtn).CornerRadius = UDim.new(0, Theme.Radius.Xs)

			-- Add label-padding via UIPadding
			local hpad = Instance.new("UIPadding")
			hpad.PaddingLeft = UDim.new(0, 4)
			hpad.PaddingRight = UDim.new(0, 4)
			hpad.Parent = hintBtn

			hintBtn.MouseButton1Click:Connect(function()
				-- Execute via console module if available
				local consoleMod = nexus._subsystemModules and nexus._subsystemModules.CONSOLE
				if consoleMod and hint.Command and hint.Command ~= "" then
					if consoleMod.ExecuteCommand then
						pcall(consoleMod.ExecuteCommand, consoleMod, hint.Command, nexus)
					end
					-- Switch to console so user sees the result
					if nexus.SwitchSubsystem then
						pcall(nexus.SwitchSubsystem, "CONSOLE")
					end
				elseif hint.Command then
					-- Fallback: parse "switch X" pattern
					local sub = hint.Command:match("^switch%s+(%w+)")
					if sub and nexus.SwitchSubsystem then
						pcall(nexus.SwitchSubsystem, string.upper(sub))
					end
				end
			end)

			if nexus._animationController then
				nexus._animationController:HoverGlow(hintBtn, Theme.Colors.Accent)
			end
		end
	end

	return row
end
--[=[
	@description Implements `InsightsModule._BuildHistoryRow`.
	@param parent Frame -- `parent` input parameter.
	@param insight any -- `insight` input parameter.
	@param order number -- `order` input parameter.
	@return Frame -- Return value produced by the implementation, if any.
]=]

function InsightsModule:_BuildHistoryRow(parent: Frame, insight: any, order: number): Frame
	local row = Instance.new("Frame")
	row.Name = "History_" .. insight.Id
	row.Size = UDim2.new(1, 0, 0, 22)
	row.BackgroundColor3 = Theme.Colors.GlassTertiary
	row.BackgroundTransparency = 0.92
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent

	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, 2)
	rc.Parent = row

	local rp = Instance.new("UIPadding")
	rp.PaddingLeft = UDim.new(0, 6)
	rp.PaddingRight = UDim.new(0, 6)
	rp.Parent = row

	local elapsed = os.clock() - (insight.Timestamp or 0)
	local timeStr = if elapsed < 60 then string.format("%.0fs ago", elapsed)
		elseif elapsed < 3600 then string.format("%.0fm ago", elapsed / 60)
		else string.format("%.1fh ago", elapsed / 3600)

	Theme.CreateLabel({
		Text = string.format("%s · %s", insight.Severity:sub(1, 4), insight.Title),
		Size = UDim2.new(0.75, 0, 1, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Parent = row,
	})

	Theme.CreateLabel({
		Text = timeStr,
		Size = UDim2.new(0.25, 0, 1, 0),
		Position = UDim2.new(0.75, 0, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Alignment = Enum.TextXAlignment.Right,
		Parent = row,
	})

	return row
end
--[=[
	@description Implements `InsightsModule._BuildInsightDetailLayer`.
	@param frame Frame -- `frame` input parameter.
	@param context any -- `context` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function InsightsModule:_BuildInsightDetailLayer(frame: Frame, context: any)
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	-- Clear existing children (re-render safe)
	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then
			child:Destroy()
		end
	end

	local insight = context.Insight or {}
	local nexus = context.Nexus

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = contentFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.Parent = contentFrame

	local severityColors = {
		CRITICAL = Theme.Colors.Danger,
		WARNING = Theme.Colors.Warning,
		INFO = Theme.Colors.Accent,
		SUGGESTION = Theme.Colors.Purple,
	}
	local color = severityColors[insight.Severity] or Theme.Colors.TextMuted

	-- Header
	Theme.CreateLabel({
		Text = string.format('<font color="#%s">●</font> %s', 
			string.format("%02X%02X%02X", 
				math.floor(color.R * 255), math.floor(color.G * 255), math.floor(color.B * 255)),
			insight.Title or "Unknown"),
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Heading,
		FontFace = Theme.Font.Bold,
		Parent = contentFrame,
	}).LayoutOrder = 0

	-- Properties
	local props = {
		{ "Severity", insight.Severity, color },
		{ "Subsystem", insight.Subsystem, Theme.Colors.TextPrimary },
		{ "Description", insight.Description, Theme.Colors.TextSecondary },
		{ "Metric", tostring(insight.Metric or "N/A"), Theme.Colors.Cyan },
		{ "Threshold", tostring(insight.Threshold or "N/A"), Theme.Colors.Warning },
		{ "Timestamp", string.format("%.3fs", insight.Timestamp or 0), Theme.Colors.TextMuted },
	}

	for i, prop in ipairs(props) do
		local propRow = Instance.new("Frame")
		propRow.Size = UDim2.new(1, 0, 0, 22)
		propRow.BackgroundColor3 = Theme.Colors.GlassTertiary
		propRow.BackgroundTransparency = 0.9
		propRow.BorderSizePixel = 0
		propRow.LayoutOrder = i
		propRow.Parent = contentFrame

		local pc = Instance.new("UICorner")
		pc.CornerRadius = UDim.new(0, 2)
		pc.Parent = propRow

		local pp = Instance.new("UIPadding")
		pp.PaddingLeft = UDim.new(0, 8)
		pp.PaddingRight = UDim.new(0, 8)
		pp.Parent = propRow

		Theme.CreateLabel({
			Text = prop[1],
			Size = UDim2.new(0.35, 0, 1, 0),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Mono,
			Parent = propRow,
		})

		Theme.CreateLabel({
			Text = prop[2],
			Size = UDim2.new(0.6, 0, 1, 0),
			Position = UDim2.new(0.38, 0, 0, 0),
			Color = prop[3],
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Mono,
			Parent = propRow,
		})
	end

	-- Related IDs
	if insight.RelatedIds and #insight.RelatedIds > 0 then
		Theme.CreateLabel({
			Text = "RELATED",
			Size = UDim2.new(1, 0, 0, 16),
			Color = Theme.Colors.TextMuted,
			FontSize = Theme.TextSize.Caption,
			FontFace = Theme.Font.Bold,
			Parent = contentFrame,
		}).LayoutOrder = 100

		for j, relId in ipairs(insight.RelatedIds) do
			local relBadge = Theme.CreateBadge(relId, Theme.Colors.Accent)
			relBadge.LayoutOrder = 100 + j
			relBadge.Parent = contentFrame
		end
	end

	-- Dismiss button
	local dismissBtn = Theme.CreateIconButton({
		Label = "✕ DISMISS",
		Size = UDim2.new(0.4, 0, 0, 28),
		Color = Theme.Colors.Danger,
		Parent = contentFrame,
	})
	dismissBtn.LayoutOrder = 200

	dismissBtn.MouseButton1Click:Connect(function()
		local analytics = nexus._analyticsEngine
		if analytics then
			analytics:DismissInsight(insight.Id)
		end
		if nexus._navigator then
			nexus._navigator:CollapseToLayer("INSIGHTS")
		end
	end)
end
--[=[
	@description Implements `InsightsModule.Destroy`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function InsightsModule:Destroy()
	table.clear(self._activeInsights)
	table.clear(self._historyInsights)
end

return InsightsModule
