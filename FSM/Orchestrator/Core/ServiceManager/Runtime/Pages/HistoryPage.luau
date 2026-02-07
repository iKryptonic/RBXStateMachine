--!strict

-- Runtime/Pages/HistoryPage.luau
-- Extracted History page controller.

export type Deps = {
	EnsurePagination: (Instance, any, (() -> ())) -> Instance?,
	EscapeRichText: (string) -> string,
	COLORS: { [string]: Color3 },
	TaskDataReference: Instance,
	TaskCardReference: Instance,
}

local HistoryPage = {}

function HistoryPage.Create(ServiceManager: any, deps: Deps)
	local page: any = {
		Container = ServiceManager.GUI.BodyContainer:WaitForChild("HistoryView"):WaitForChild("Container"),
		Tab = ServiceManager.GUI.TabContainer:WaitForChild("History"),
		Constants = {
			Page = 1,
			PageSize = 8,
			Search = "",
			Filters = { Completed = true, Failed = true, Cancelled = true },
			SelectedEntry = nil,
			LastHash = "",
		},
		Connections = {},
	}

	page.UpdateFunction = function(this)
		local service = ServiceManager.Services[ServiceManager.ActiveService]
		if not this.Container or not service then
			return
		end
		this.Connections = this.Connections or {}

		local history = service.History or {}
		local view = this.Container.Parent
		if not view then
			return
		end

		local controls = deps.EnsurePagination(view, this.Constants, function()
			this.UpdateFunction(this)
		end)
		local details = view:FindFirstChild("Details")

		-- Handle Details View
		if this.Constants.SelectedEntry then
			this.Container.Visible = false
			if controls then
				(controls :: any).Visible = false
			end
			local toolbar = view:FindFirstChild("Toolbar")
			if toolbar then
				(toolbar :: any).Visible = false
			end

			if details then
				(details :: any).Visible = true
				local content = (details :: any).Content

				if not (details :: any).Back:FindFirstChild("Hooked") then
					local hookMarker = Instance.new("BoolValue")
					hookMarker.Name = "Hooked"
					hookMarker.Parent = (details :: any).Back

					local backConn = (details :: any).Back.MouseButton1Click:Connect(function()
						this.Constants.SelectedEntry = nil
						this.UpdateFunction(this)
					end)
					table.insert(this.Connections, backConn)
				end

				for _, c in next, content:GetChildren() do
					if c:IsA("Frame") then
						c:Destroy()
					end
				end

				local entry = this.Constants.SelectedEntry
				local function addField(titleText: string, value: any, hexColor: string?)
					local fieldRow = deps.TaskDataReference:Clone()
					fieldRow.Parent = content
					local fieldGui = fieldRow :: any
					fieldGui.Visible = true
					fieldGui.Title.Text = titleText
					fieldGui.Value.Text = string.format(
						"<b><font color='%s'>%s</font></b>",
						hexColor or "#ffffff",
						deps.EscapeRichText(tostring(value))
					)
				end

				local status = tostring((entry :: any).Status)
				local statusColor = (status == "Completed" and "#A0FFA0") or (status == "Failed" and "#FF7878") or "#CCCCCC"
				addField("TASK NAME", (entry :: any).Name)
				addField("STATUS", status:upper(), statusColor)
				addField(
					"DURATION",
					((entry :: any).Duration < 0.001 and math.floor((entry :: any).Duration * 1e6) .. "ns")
						or math.floor((entry :: any).Duration * 1e3) .. "ms"
				)
				addField("TIMESTAMP", os.date("%c", (entry :: any).Time))

				if (entry :: any).Error and tostring((entry :: any).Error) ~= "" then
					addField("ERROR OUTPUT", (entry :: any).Error, "#FF7878")
				end
			end

			return
		else
			this.Container.Visible = true
			if controls then
				(controls :: any).Visible = true
			end
			local toolbar = view:FindFirstChild("Toolbar")
			if toolbar then
				(toolbar :: any).Visible = true
			end
			if details then
				(details :: any).Visible = false
			end
		end

		-- Build Toolbar if missing
		if not view:FindFirstChild("Toolbar") then
			local toolbar = Instance.new("Frame")
			toolbar.Name = "Toolbar"
			toolbar.Size = UDim2.new(1, 0, 0, 35)
			toolbar.BackgroundTransparency = 1
			toolbar.Parent = view

			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.Padding = UDim.new(0, 5)
			layout.Parent = toolbar

			-- Search Box
			local searchBox = Instance.new("TextBox")
			searchBox.Size = UDim2.new(0, 120, 1, 0)
			searchBox.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
			searchBox.TextColor3 = Color3.new(1, 1, 1)
			searchBox.Font = Enum.Font.Gotham
			searchBox.TextSize = 12
			searchBox.PlaceholderText = "Search History..."
			searchBox.Text = this.Constants.Search
			searchBox.Parent = toolbar

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 4)
			corner.Parent = searchBox

			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 8)
			pad.Parent = searchBox

			local searchConn = searchBox:GetPropertyChangedSignal("Text"):Connect(function()
				this.Constants.Search = searchBox.Text
				this.Constants.Page = 1
				this.UpdateFunction(this)
			end)
			table.insert(this.Connections, searchConn)

			-- Filter Buttons
			local function createFilter(name: string, color: Color3)
				local btn = Instance.new("TextButton")
				btn.Text = name
				btn.Size = UDim2.new(0, 70, 1, 0)
				btn.BackgroundColor3 = color
				btn.Font = Enum.Font.GothamBold
				btn.TextSize = 10
				btn.TextColor3 = Color3.new(1, 1, 1)
				btn.Parent = toolbar

				local btnCorner = Instance.new("UICorner")
				btnCorner.CornerRadius = UDim.new(0, 4)
				btnCorner.Parent = btn

				btn.BackgroundTransparency = this.Constants.Filters[name] and 0 or 0.7

				local btnConn = btn.MouseButton1Click:Connect(function()
					this.Constants.Filters[name] = not this.Constants.Filters[name]
					btn.BackgroundTransparency = this.Constants.Filters[name] and 0 or 0.7
					this.Constants.Page = 1
					this.UpdateFunction(this)
				end)
				table.insert(this.Connections, btnConn)
			end

			createFilter("Completed", deps.COLORS.Success)
			createFilter("Failed", deps.COLORS.Error)
			createFilter("Cancelled", Color3.fromRGB(150, 150, 150))

			local sortBtn = Instance.new("TextButton")
			sortBtn.Text = "SORT: TIME"
			sortBtn.Size = UDim2.new(0, 80, 1, 0)
			sortBtn.BackgroundColor3 = deps.COLORS.DarkBG
			sortBtn.TextColor3 = Color3.new(1, 1, 1)
			sortBtn.Font = Enum.Font.GothamBold
			sortBtn.TextSize = 10
			sortBtn.Parent = toolbar

			local sortCorner = Instance.new("UICorner")
			sortCorner.CornerRadius = UDim.new(0, 4)
			sortCorner.Parent = sortBtn

			local sortConn = sortBtn.MouseButton1Click:Connect(function()
				local modes = { "Time", "Duration" }
				local currentIdx = table.find(modes, this.Constants.SortMode) or 1
				this.Constants.SortMode = modes[(currentIdx % #modes) + 1]
				sortBtn.Text = "SORT: " .. tostring(this.Constants.SortMode):upper()
				this.UpdateFunction(this)
			end)
			table.insert(this.Connections, sortConn)

			-- Toolbar is destroyed on tab switch; force a rerender so list card
			-- buttons get rehooked even when stateHash matches.
			this.Constants.LastHash = ""
		end

		-- State Hashing to prevent unnecessary re-renders (fixes click registration)
		local stateHash = string.format(
			"%d_%s_%d_%s_%s_%s_%s_%s_%s",
			#history,
			history[1] and (tostring((history[1] :: any).Time) .. tostring((history[1] :: any).Name)) or "0",
			this.Constants.Page,
			this.Constants.Search,
			tostring(this.Constants.SelectedEntry),
			tostring(this.Constants.Filters.Completed),
			tostring(this.Constants.Filters.Failed),
			tostring(this.Constants.Filters.Cancelled),
			tostring(this.Constants.SortMode)
		)
		if this.Constants.LastHash == stateHash then
			return
		end
		this.Constants.LastHash = stateHash

		-- Filter Data
		local filtered = {}
		local searchText = tostring(this.Constants.Search or "")
		local searchLower = searchText:lower()

		for _, v in ipairs(history) do
			local status = tostring((v :: any).Status)
			local name = tostring((v :: any).Name)
			if this.Constants.Filters[status] and (searchText == "" or name:lower():find(searchLower, 1, true)) then
				table.insert(filtered, v)
			end
		end

		local sortMode = this.Constants.SortMode
		table.sort(filtered, function(a, b)
			if sortMode == "Duration" then
				return (a :: any).Duration > (b :: any).Duration
			else
				return (a :: any).Time > (b :: any).Time
			end
		end)

		-- Pagination Logic
		local maxPage = math.max(1, math.ceil(#filtered / this.Constants.PageSize))
		if this.Constants.Page > maxPage then
			this.Constants.Page = maxPage
		end
		if this.Constants.Page < 1 then
			this.Constants.Page = 1
		end

		local paginationControls = deps.EnsurePagination(view, this.Constants, function()
			this.UpdateFunction(this)
		end)
		if paginationControls then
			(paginationControls :: any).PageLabel.Text = string.format("%d / %d", this.Constants.Page, maxPage)
		end

		-- Render List
		for _, child in next, this.Container:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end

		local startIndex = (this.Constants.Page - 1) * this.Constants.PageSize + 1
		local endIndex = math.min(#filtered, startIndex + this.Constants.PageSize - 1)

		for i = startIndex, endIndex do
			local entry = filtered[i]
			if not entry then
				continue
			end

			local card = deps.TaskCardReference:Clone()
			card.Parent = (this.Container :: any)
			local cardGui = card :: any
			cardGui.Visible = true
			cardGui.Text = ""

			local status = tostring((entry :: any).Status)
			local statusColor = (status == "Completed" and "#A0FFA0") or (status == "Failed" and "#FF7878") or "#CCCCCC"
			local timeStr = os.date("%H:%M:%S", (entry :: any).Time)
			local durStr = ((entry :: any).Duration < 0.001 and math.floor((entry :: any).Duration * 1e6) .. "ns")
				or math.floor((entry :: any).Duration * 1e3) .. "ms"

			local label = card:FindFirstChild("TextLabel")
			if label then
				(label :: any).Text = string.format(
					"<b>%s</b> <font color='%s'>[%s]</font> <font color='#888888'>%s</font> (%s)",
					deps.EscapeRichText(tostring((entry :: any).Name)),
					statusColor,
					deps.EscapeRichText(status:upper()),
					timeStr,
					durStr
				)
			end

			local cardConn = (card :: any).MouseButton1Click:Connect(function()
				this.Constants.SelectedEntry = entry
				this.UpdateFunction(this)
			end)
			table.insert(this.Connections, cardConn)
		end
	end

	return page
end

return HistoryPage
