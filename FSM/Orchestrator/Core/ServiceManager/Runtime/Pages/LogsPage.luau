--!strict
--[[
	@Name LogsPage
	@Author iKrypto
	@Description Logs page controller. Renders timestamped log entries from
	the active service's Logger with INFO/WARN/ERROR level filters, search,
	and clear functionality. Supports both client and server modes.
	
	@deprecated This legacy controller is retained for regression testing only.
	Use the new FSM/Entity pattern: FSM/LogsPageFSM.luau + Entity/LogsPageEntity.luau
]]

local RS = game:GetService("ReplicatedStorage")

export type Deps = {
	EnsureToolbar: (Instance) -> Instance,
	CreateSearchBox: (Instance, string?, (string) -> ()) -> Instance,
	CreateButton: (Instance, string, Color3, (() -> ())?, number?) -> Instance,
	EscapeRichText: (string) -> string,
	COLORS: { [string]: Color3 },
	LogLineReference: Instance,
}

local LogsPage = {}

--[[
	@description Factory that creates the Logs page. Renders log entries from the
	active service's Logger with INFO/WARN/ERROR filters, search, and a clear button.
	Supports FSM and Scheduler log sources in both client and server modes.
	@param ServiceManager any -- The root ServiceManager instance.
	@param deps Deps -- Injected dependencies (toolbar, search, buttons, colors, templates).
	@return any -- A page table with Container, Tab, Constants, Connections, UpdateFunction.
]]
function LogsPage.Create(ServiceManager: any, deps: Deps)
	local page: any = {
		Container = ServiceManager.GUI.BodyContainer:WaitForChild("LogsView"):WaitForChild("Container"),
		Tab = ServiceManager.GUI.TabContainer:WaitForChild("Logs"),
		Constants = { Filters = { [1] = true, [2] = true, [3] = true }, LastBufferHash = "", Search = "" },
		Connections = {},
	}

	page.UpdateFunction = function(this)
		local service = ServiceManager.Services and ServiceManager.Services[ServiceManager.ActiveService]
		if not this.Container then
			return
		end
		this.Connections = this.Connections or {}

		local view = this.Container.Parent
		if view and not view:FindFirstChild("Toolbar") then
			local toolbar = deps.EnsureToolbar(view)
			local search = deps.CreateSearchBox(toolbar, this.Constants.Search, function(text)
				this.Constants.Search = text
				this.Constants.LastBufferHash = "" -- Force refresh
			end)
			local searchGui = search :: any
			searchGui.LayoutOrder = -1

		--[[
			@description Creates a filter toggle button for a specific log level.
			@param text string -- Button label (INFO, WARN, ERROR).
			@param level number -- Log level (1=INFO, 2=WARN, 3=ERROR).
			@param color Color3 -- Button accent color.
			@return ()
		]]
		local function createFilterBtn(text: string, level: number, color: Color3)
				local btn = deps.CreateButton(toolbar, text, color, nil, 60)
				local btnGui = btn :: any
				btnGui.BackgroundTransparency = 0.5

				local connection = btnGui.MouseButton1Click:Connect(function()
					this.Constants.Filters[level] = not this.Constants.Filters[level]
					btnGui.BackgroundTransparency = this.Constants.Filters[level] and 0 or 0.7
					this.Constants.LastBufferHash = ""
				end)
				table.insert(this.Connections, connection)

				btnGui.BackgroundTransparency = this.Constants.Filters[level] and 0 or 0.7
			end

			createFilterBtn("INFO", 1, deps.COLORS.Accent)
			createFilterBtn("WARN", 2, deps.COLORS.Warning)
			createFilterBtn("ERROR", 3, deps.COLORS.Error)

			local clearBtn = deps.CreateButton(toolbar, "CLEAR", deps.COLORS.DarkBG, nil, 60)
			local clearConn = (clearBtn :: any).MouseButton1Click:Connect(function()
				if ServiceManager.Mode == "server" then
					if ServiceManager.ActiveService == "FSM" then
						if ServiceManager.Orchestrator and ServiceManager.Orchestrator.Request then
							(ServiceManager.Orchestrator :: any).Request("ConsoleCommand", "clearlogs")
						end
					else
						local scheduler = ServiceManager.Services and ServiceManager.Services.Scheduler
						if scheduler then
							(scheduler :: any):ConsoleCommand("clearlogs")
						end
					end
				else
					if service and service.Logger then
						service.Logger.History = {}
					end
				end
				this.Constants.LastBufferHash = ""
				this:Toast("Logs Cleared", "Success")
			end)
			table.insert(this.Connections, clearConn)
		end

		--[[
			@description Normalizes heterogeneous log entry formats into a uniform
			{Type: number, Message: string, Time: number} array.
			@param raw any -- Raw log history array from the Logger.
			@return { {Type: number, Message: string, Time: number} }
		]]
		local function normalizeLogBuffer(raw: any)
			local buffer = {}
			for _, entry in ipairs(raw or {}) do
				if entry.Type and entry.Message then
					table.insert(buffer, entry)
				elseif entry.Level and entry.Message then
					local level = tostring(entry.Level)
					local levelNumber = (level == "ERROR" and 3) or (level == "WARN" and 2) or 1
					table.insert(buffer, {
						Type = levelNumber,
						Message = entry.Message,
						Time = entry.Timestamp or entry.Time or os.time(),
					})
				end
			end
			return buffer
		end

		local buffer = {}
		if ServiceManager.ActiveService == "FSM" then
			if ServiceManager.Mode == "server" then
				local raw = ServiceManager.ServerData.FSM and ServiceManager.ServerData.FSM.Logs and ServiceManager.ServerData.FSM.Logs.History
				buffer = normalizeLogBuffer(raw)
			else
				local orchestrator = ServiceManager.Orchestrator
				local raw = orchestrator and orchestrator.Logger and orchestrator.Logger.History
				buffer = normalizeLogBuffer(raw)
			end
		else
			-- Scheduler (or other non-FSM service). In server mode, read from replicated snapshots.
			if ServiceManager.Mode == "server" then
				local raw = ServiceManager.ServerData.Scheduler and ServiceManager.ServerData.Scheduler.Logger and ServiceManager.ServerData.Scheduler.Logger.History
				buffer = normalizeLogBuffer(raw)
			else
				local logger = service and service.Logger
				if not logger then
					return
				end
				buffer = normalizeLogBuffer(logger.History or logger.OutputBuffer)
			end
		end

		local searchText = this.Constants.Search or ""
		local currentHash = tostring(#buffer) .. tostring(buffer[1] and buffer[1].Time or 0) .. tostring(searchText) .. tostring(ServiceManager.Mode) .. tostring(ServiceManager.ActiveService)
		if this.Constants.LastBufferHash == currentHash then
			return
		end
		this.Constants.LastBufferHash = currentHash

		for _, child in next, this.Container:GetChildren() do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		for i = #buffer, 1, -1 do
			local log = buffer[i]
			if not this.Constants.Filters[log.Type] then
				continue
			end
			if searchText ~= "" and not tostring(log.Message):lower():find(searchText:lower(), 1, true) then
				continue
			end

			local line = deps.LogLineReference:Clone()
			local timeStr = os.date("%H:%M:%S", log.Time)
			local color = (log.Type == 1 and "#A0A0A0") or (log.Type == 2 and "#FFDC8C") or (log.Type == 3 and "#FF7878") or "#FFFFFF"
			local prefix = (log.Type == 1 and "[INFO]") or (log.Type == 2 and "[WARN]") or (log.Type == 3 and "[ERR]") or "[LOG]"

			local lineGui = line :: any
			lineGui.Text = string.format(
				"<font color='#555555'>%s</font> <font color='%s'><b>%s</b> %s</font>",
				timeStr,
				color,
				prefix,
				deps.EscapeRichText(tostring(log.Message))
			)
			lineGui.Visible = true
			line.Parent = (this.Container :: any)
		end

		task.delay(0.05, function()
			if this.Container then
				(this.Container :: any).CanvasPosition = Vector2.new(0, (this.Container :: any).AbsoluteCanvasSize.Y)
			end
		end)
	end

	return page
end

return LogsPage
