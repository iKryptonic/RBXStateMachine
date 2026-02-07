--!strict
--[[
	@Name ConsolePage
	@Author iKrypto
	@Description Console page controller. Provides a developer CLI with a custom
	scroll engine (viewport + content offsetting), tokenizer, command registry
	with tab-completion, output formatting, and input history navigation.
	
	@deprecated This legacy controller is retained for regression testing only.
	Use the new FSM/Entity pattern: FSM/ConsolePageFSM.luau + Entity/ConsolePageEntity.luau
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type Deps = {
	EscapeRichText: (string) -> string,
	COLORS: { [string]: Color3 },
}

local ConsolePage = {}

--[[
	@description Factory that creates the Console page with a full CLI: viewport,
	custom scrollbar, command system, autocomplete, and input handling.
	@param ServiceManager any -- The root ServiceManager instance.
	@param deps Deps -- Injected dependencies (EscapeRichText, COLORS).
	@return any -- A page table with Container, Tab, Constants, Connections, UpdateFunction.
]]
function ConsolePage.Create(ServiceManager: any, deps: Deps)
	local owner = Players.LocalPlayer
	if not owner then
		error("[ServiceManager/ConsolePage] LocalPlayer required")
	end

	local page: any = {
		Container = ServiceManager.GUI.BodyContainer:WaitForChild("ConsoleView"):WaitForChild("Container"),
		Tab = ServiceManager.GUI.TabContainer:WaitForChild("Console"),
		Constants = {
			LineCount = 0,
			CONSOLE_MAX_LIMIT = 500,
			CommandHistory = {},
			HistoryIndex = 0,
			Initialized = false,
			SuggestionIndex = 1,
		},
		Connections = {},
	}

	-- --------------------------------------------------------------------------------
	-- HELPERS
	-- --------------------------------------------------------------------------------
	--[[
		@description Wraps text in a rich-text font tag with the given Color3.
		@param text string -- The text to colorize.
		@param col Color3 -- The RGB color.
		@return string -- Rich-text formatted string.
	]]
	local function color(text: string, col: Color3)
		local r, g, b = math.floor(col.R * 255), math.floor(col.G * 255), math.floor(col.B * 255)
		return string.format('<font color="rgb(%d,%d,%d)">%s</font>', r, g, b, text)
	end

	--[[
		@description Recursively formats a table into a multiline indented string
		with rich-text colored keys.
		@param tbl any -- The table (or value) to format.
		@param indent number? -- Current indentation level (default 0).
		@return string -- Formatted string representation.
	]]
	local function formatTable(tbl: any, indent: number?): string
		indent = indent or 0
		local result = ""
		local space = string.rep("  ", indent or 0)
		
		if type(tbl) ~= "table" then
			return space .. tostring(tbl)
		end

		for k, v in pairs(tbl) do
			if type(v) == "table" then
				result = result .. space .. color(tostring(k), deps.COLORS.Accent) .. ":\n" .. formatTable(v, (indent or 0) + 1) .. "\n"
			else
				result = result .. space .. color(tostring(k), deps.COLORS.Accent) .. ": " .. tostring(v) .. "\n"
			end
		end
		return result
	end

	-- --------------------------------------------------------------------------------
	-- UI OUTPUT
	-- --------------------------------------------------------------------------------
	page.UpdateFunction = function(this)
		if not this.Container then return end
		
		-- One-time initialization of structure and events
		if not this.Constants.ViewInitialized then
			this.Constants.ViewInitialized = true
			this.Connections = this.Connections or {}
			this.Constants.CommandHistory = this.Constants.CommandHistory or {}

			local InputBox = this.Container:WaitForChild("UserInput")
			
			-- --------------------------------------------------------------------------------
			-- ENGINE SETUP
			-- --------------------------------------------------------------------------------
			local Viewport = this.Container:FindFirstChild("Viewport")
			if not Viewport then
				-- Cleanup old if exists
				local oldObj = this.Container:FindFirstChild("TextContainer")
				if oldObj then oldObj:Destroy() end
			
				Viewport = Instance.new("Frame")
				Viewport.Name = "Viewport"
				Viewport.Parent = this.Container
				Viewport.Size = UDim2.new(1, -12, 1, -50) -- Room for input & toolbar
				Viewport.Position = UDim2.new(0, 5, 0, 5)
				Viewport.BackgroundTransparency = 1
				Viewport.ClipsDescendants = true
				
				local Content = Instance.new("Frame")
				Content.Name = "Content"
				Content.Parent = Viewport
				Content.Size = UDim2.new(1, 0, 0, 0)
				Content.Position = UDim2.new(0, 0, 0, 0)
				Content.BackgroundTransparency = 1
				Content.AutomaticSize = Enum.AutomaticSize.Y
				
				local Layout = Instance.new("UIListLayout", Content)
				Layout.SortOrder = Enum.SortOrder.LayoutOrder
			end
			
			local Content = Viewport:WaitForChild("Content")
			local ListLayout = Content:FindFirstChildOfClass("UIListLayout")

			-- Ensure Suggestions Frame
			local SuggestionsFrame = this.Container:FindFirstChild("Suggestions")
			if not SuggestionsFrame then
				SuggestionsFrame = Instance.new("Frame")
				SuggestionsFrame.Name = "Suggestions"
				SuggestionsFrame.Parent = this.Container
				SuggestionsFrame.Size = UDim2.new(1, -20, 0, 0) -- Height dynamic
				SuggestionsFrame.Position = UDim2.new(0, 10, 1, -40) -- Above input
				SuggestionsFrame.AnchorPoint = Vector2.new(0, 1)
				SuggestionsFrame.BackgroundColor3 = deps.COLORS.PanelBG
				SuggestionsFrame.BorderSizePixel = 0
				SuggestionsFrame.Visible = false
				SuggestionsFrame.ZIndex = 10
				
				local uiStroke = Instance.new("UIStroke")
				uiStroke.Color = deps.COLORS.Stroke
				uiStroke.Parent = SuggestionsFrame
				
				local uiList = Instance.new("UIListLayout")
				uiList.SortOrder = Enum.SortOrder.LayoutOrder
				uiList.Parent = SuggestionsFrame
			end

			--[[
				@description Destroys all TextLabel children from the console Content
				frame and resets the line counter.
				@return ()
			]]
			local function clearConsole()
				this.Constants.LineCount = 0
				for _, item in Content:GetChildren() do
					if item:IsA("TextLabel") then item:Destroy() end
				end
			end
			
			-- Create Custom Scrollbar
			local ScrollTrack = this.Container:FindFirstChild("ScrollTrack")
			if not ScrollTrack then
				ScrollTrack = Instance.new("Frame")
				ScrollTrack.Name = "ScrollTrack"
				ScrollTrack.Parent = this.Container
				ScrollTrack.Size = UDim2.new(0, 6, 1, -10)
				ScrollTrack.Position = UDim2.new(1, -6, 0, 5)
				ScrollTrack.BackgroundColor3 = deps.COLORS.InputBG
				ScrollTrack.BorderSizePixel = 0
				Instance.new("UICorner", ScrollTrack).CornerRadius = UDim.new(1, 0)
				
				local Thumb = Instance.new("TextButton")
				Thumb.Name = "Thumb"
				Thumb.Parent = ScrollTrack
				Thumb.Size = UDim2.new(1, 0, 0.2, 0)
				Thumb.BackgroundColor3 = deps.COLORS.Stroke
				Thumb.Text = ""
				Thumb.AutoButtonColor = false
				Instance.new("UICorner", Thumb).CornerRadius = UDim.new(1, 0)
			end
			
			local ScrollThumb = ScrollTrack:WaitForChild("Thumb")
			this.Constants.ScrollY = (this.Constants :: any).ScrollY or 0
			this.Constants.FollowTail = if (this.Constants :: any).FollowTail == nil then true else (this.Constants :: any).FollowTail
			local currentScrollY = (this.Constants :: any).ScrollY :: number
			local followTail = (this.Constants :: any).FollowTail :: boolean
			local isDragging = false
			local dragStartY = 0
			local startScrollY = 0

			--[[
				@description Returns the Y-axis content height from the UIListLayout
				or the Content frame's AbsoluteSize.
				@return number
			]]
			local function getContentHeight(): number
				if ListLayout then
					return ListLayout.AbsoluteContentSize.Y
				end
				return Content.AbsoluteSize.Y
			end

			--[[
				@description Returns the viewport frame's absolute Y size.
				@return number
			]]
			local function getViewportHeight(): number
				return Viewport.AbsoluteSize.Y
			end
			
			--[[
				@description Clamps scroll position, applies Content offset, and updates
				the custom scrollbar thumb size and position.
				@return ()
			]]
			local function updateVisuals()
				local contentH = getContentHeight()
				local viewportH = getViewportHeight()
				
				-- Clamp
				local maxScroll = math.max(0, contentH - viewportH)
				currentScrollY = math.clamp(currentScrollY, 0, maxScroll)
				;(this.Constants :: any).ScrollY = currentScrollY
				
				-- Apply
				Content.Position = UDim2.new(0, 0, 0, -currentScrollY)
				
				-- Thumb
				if maxScroll <= 0 then
					ScrollThumb.Visible = false
					ScrollTrack.Visible = false
				else
					ScrollThumb.Visible = true
					ScrollTrack.Visible = true
					local ratio = viewportH / contentH
					local thumbH = math.max(20, ratio * ScrollTrack.AbsoluteSize.Y)
					ScrollThumb.Size = UDim2.new(1, 0, 0, thumbH)
					
					local trackH = ScrollTrack.AbsoluteSize.Y
					if trackH > thumbH then
						local pct = currentScrollY / maxScroll
						local thumbY = pct * (trackH - thumbH)
						ScrollThumb.Position = UDim2.new(0, 0, 0, thumbY)
					end
				end
			end
			
			--[[
				@description Sets the scroll position and updates visuals. Determines
				whether auto-follow-tail is active based on proximity to bottom.
				@param val number -- Desired scroll offset.
				@return ()
			]]
			local function setScroll(val: number)
				currentScrollY = val
				updateVisuals()
				followTail = ((math.max(0, getContentHeight() - getViewportHeight()) - currentScrollY) < 20)
				;(this.Constants :: any).FollowTail = followTail
			end

			--[[
				@description Returns true if within 20px of the maximum scroll.
				@return boolean
			]]
			local function isNearBottom(): boolean
				local contentH = getContentHeight()
				local viewportH = getViewportHeight()
				local maxScroll = math.max(0, contentH - viewportH)
				return (maxScroll - currentScrollY) < 20
			end

			--[[
				@description Asynchronously scrolls to the bottom of the console by
				hooking layout changes and deferring a frame.
				@return ()
			]]
			local function snapToBottomAsync()
				local finished = false
				local conn: any = nil

				local function snapToBottom()
					if finished then return end
					finished = true
					if conn then
						conn:Disconnect()
						conn = nil
					end
					local newViewportH = getViewportHeight()
					local newMax = math.max(0, getContentHeight() - newViewportH)
					setScroll(newMax)
				end

				if ListLayout then
					conn = ListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(snapToBottom)
				else
					conn = Content:GetPropertyChangedSignal("AbsoluteSize"):Connect(snapToBottom)
				end
				task.defer(function()
					RunService.RenderStepped:Wait()
					snapToBottom()
				end)
			end
			
			-- Logic: MouseWheel
			table.insert(this.Connections, Viewport.InputChanged:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseWheel then
					local delta = -input.Position.Z * 40 -- Sensible speed
					setScroll(currentScrollY + delta)
				end
			end))
			
			-- Hook Resizing
			table.insert(this.Connections, Viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateVisuals))
			table.insert(this.Connections, Content:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateVisuals))
			
			-- Drag Logic
			table.insert(this.Connections, ScrollThumb.MouseButton1Down:Connect(function(x, y)
				isDragging = true
				dragStartY = y
				startScrollY = currentScrollY
				
				local contentH = Content.AbsoluteSize.Y
				local viewportH = Viewport.AbsoluteSize.Y
				local ratio = contentH / viewportH -- Approximation for drag speed
			end))
			
			table.insert(this.Connections, UIS.InputChanged:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseMovement and isDragging then
					local delta = input.Position.Y - dragStartY
					
					local trackH = ScrollTrack.AbsoluteSize.Y
					local thumbH = ScrollThumb.AbsoluteSize.Y
					local activeH = trackH - thumbH
					
					if activeH > 0 then
						local contentH = Content.AbsoluteSize.Y
						local viewportH = Viewport.AbsoluteSize.Y
						local maxScroll = math.max(0, contentH - viewportH)
						
						local pct = delta / activeH
						setScroll(startScrollY + (pct * maxScroll))
					end
				end
			end))
			
			table.insert(this.Connections, UIS.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					isDragging = false
				end
			end))

			-- Line Renderer
			--[[
				@description Creates a new TextLabel line in the console with color
				based on output type (0=Prompt, 1=Success, 2=Warning, 3=Error).
				Auto-scrolls if near bottom.
				@param text string -- The line text (may include rich text).
				@param outputType number? -- Color type indicator.
				@return ()
			]]
			local function writeLine(text: string, outputType: number?)
				local shouldAutoScroll = followTail or isNearBottom()
				local lineLabel = ServiceManager.GUI.References.ConsoleLineReference:Clone()
				
				-- Robust Styling
				lineLabel.AutomaticSize = Enum.AutomaticSize.Y
				lineLabel.TextWrapped = true
				lineLabel.Size = UDim2.new(1, 0, 0, 0)
				
				-- Color logic
				if outputType == 1 then text = color(text, deps.COLORS.Success) -- Success
				elseif outputType == 2 then text = color(text, deps.COLORS.Warning) -- Warn
				elseif outputType == 3 then text = color(text, deps.COLORS.Error) -- Error
				elseif outputType == 0 then text = color(text, deps.COLORS.Prompt) -- Prompt
				end 
				-- Default is plain white/grey handled by rich text or label color

				this.Constants.LineCount += 1
				lineLabel.LayoutOrder = this.Constants.LineCount
				lineLabel.Text = text
				lineLabel.Parent = Content
				lineLabel.Visible = true
				if shouldAutoScroll then
					followTail = true
					snapToBottomAsync()
				end
			end

			--[[
				@description Logs multiline text into the console, optionally escaping
				rich text. Handles smart auto-scroll.
				@param text string -- The message to log.
				@param typeVal number? -- Log level / color type.
				@param raw boolean? -- If true, skip HTML escaping.
				@return ()
			]]
			local function log(text: string, typeVal: number?, raw: boolean?)
				-- Smart Scroll Logic
				local isAtBottom = isNearBottom()

				if not raw then text = deps.EscapeRichText(text) end
				for line in text:gmatch("[^\r\n]+") do
					writeLine(line, typeVal)
				end
				
				-- Auto-scroll needs to wait for the layout/AutomaticSize pass.
				if isAtBottom then
					snapToBottomAsync()
				else
					updateVisuals() -- Re-clamp if needed
				end
			end

			-- --------------------------------------------------------------------------------
			-- COMMAND SYSTEM
			-- --------------------------------------------------------------------------------
			local Registry = {}
			
			--[[
				@description Registers a console command with name, description, group,
				action function, and optional tab-completion function.
				@param name string -- Command keyword.
				@param desc string -- Human-readable description.
				@param group string -- Grouping label (Core, Scheduler, FSM).
				@param fn (args: {string}, flags: {[string]: any}) -> string? -- Action.
				@param completion ((args: {string}, currentToken: string) -> {string})? -- Tab-complete.
				@return ()
			]]
			local function register(name: string, desc: string, group: string, fn: (args: {string}, flags: {[string]: any}) -> string?, completion: ((args: {string}, currentToken: string) -> {string})?)
				Registry[name] = { Description = desc, Group = group, Action = fn, Completion = completion }
			end

			--[[
				@description Tokenizes a command-line input string. Supports quoted strings,
				escape characters, and trailing-space detection for autocomplete.
				@param input string -- Raw user input.
				@return {string} -- Array of tokens.
			]]
			local function tokenize(input: string): {string}
				local tokens = {}
				local currentToken = ""
				local inQuote = false
				local escape = false
				
				for i = 1, #input do
					local char = input:sub(i, i)
					
					if escape then
						currentToken ..= char
						escape = false
					elseif char == "\\" then
						escape = true
					elseif char == '"' then
						inQuote = not inQuote
					elseif char:match("%s") and not inQuote then
						if #currentToken > 0 then
							table.insert(tokens, currentToken)
							currentToken = ""
						end
					else
						currentToken ..= char
					end
				end
				
				if #currentToken > 0 then
					table.insert(tokens, currentToken)
				end
				
				-- Handle trailing space for autocomplete detection
				if input:match("%s$") and not inQuote then
					table.insert(tokens, "") 
				end

				return tokens
			end

			--[[
				@description Parses a command-line string into positional args and a
				flag table. Flags start with `-`.
				@param input string -- Raw user input.
				@return {string}, {[string]: any} -- Args array and flags map.
			]]
			local function parse(input: string)
				local rawTokens = tokenize(input)
				-- Remove the empty trailing token if it exists (it's for autocomplete only)
				if rawTokens[#rawTokens] == "" then
					table.remove(rawTokens)
				end

				local args = {}
				local flags = {}
				
				for _, token in ipairs(rawTokens) do
					if token:sub(1, 1) == "-" then
						local flagName = token:gsub("^-+", "")
						flags[flagName] = true
					else
						table.insert(args, token)
					end
				end
				return args, flags
			end

			-- MODULE: CORE
			register("help", "Lists all commands", "Core", function(args)
				local lines = {"Available Commands:"}
				local sorted = {}
				for k, v in pairs(Registry) do table.insert(sorted, {k, v}) end
				table.sort(sorted, function(a,b) return a[1] < b[1] end)
				
				for _, item in ipairs(sorted) do
					local name, data = item[1], item[2]
					table.insert(lines, string.format("  %s %s - %s", 
						color(name, deps.COLORS.Accent), 
						string.rep(" ", 15 - #name), 
						data.Description
					))
				end
				return table.concat(lines, "\n")
			end)

			register("clear", "Clears the console", "Core", function() clearConsole(); return nil end)
			register("echo", "Prints text", "Core", function(args) return table.concat(args, " ") end)
			register("version", "Shows version", "Core", function() return "ServiceManager CLI v3.1" end)
			register("switch", "Switch context (client/server)", "Core", function(args)
				local target = args[1] and args[1]:lower()
				if target == "client" or target == "server" then
					if type(ServiceManager.SetMode) == "function" then
						ServiceManager:SetMode(target)
					else
						ServiceManager.Mode = target
						local store = (ServiceManager :: any).Store
						if store and store.MarkDirty then
							store:MarkDirty()
						end
					end
					return "Context shifted to " .. color(target:upper(), deps.COLORS.Success)
				end
				return "Usage: switch <client|server>"
			end, function(args, current)
				if #args == 1 then return {"client", "server"} end
				return {}
			end)

			-- MODULE: SCHEDULER (Tasks)
			register("task", "Manage tasks (list, run, kill, info)", "Scheduler", function(args, flags)
				local action = args[1]
				local scheduler = ServiceManager.Services.Scheduler
				if ServiceManager.Mode == "server" then return "Task management currently client-only (WIP)" end -- Stub for safety if not bridged yet

				if not action or action == "list" or action == "ls" then
					local taskList = {}
					for name, t in pairs(scheduler.Tasks) do
						table.insert(taskList, string.format("  %s [%s] (P:%d)", color(name, deps.COLORS.Accent), t.Status or "idle", t.Priority or 1))
					end
					if #taskList == 0 then return "No tasks active." end
					return "Active Tasks:\n" .. table.concat(taskList, "\n")
					
				elseif action == "run" then
					local name = args[2]
					if not name then return "Usage: task run <name>" end
					scheduler:ExecuteTask(name)
					return "Task execution requested: " .. name
					
				elseif action == "kill" or action == "stop" then
					local name = args[2]
					if not name then return "Usage: task kill <name>" end
					scheduler:Deschedule(name)
					return "Task descheduled: " .. name
					
				elseif action == "info" then
					local name = args[2]
					if not name then return "Usage: task info <name>" end
					local t = scheduler.Tasks[name]
					if not t then return "Task not found." end
					return formatTable(t)
				end
				return "Unknown task action. Try: list, run, kill, info"
			end, function(args, current)
				if #args == 1 then
					return {"list", "run", "kill", "info"}
				elseif #args == 2 and (args[1] == "run" or args[1] == "kill" or args[1] == "info" or args[1] == "stop") then
					local suggestions = {}
					local scheduler = ServiceManager.Services.Scheduler
					if scheduler and scheduler.Tasks then
						for name, _ in pairs(scheduler.Tasks) do table.insert(suggestions, name) end
					end
					return suggestions
				end
				return {}
			end)
			
			-- MODULE: FSM
			register("fsm", "Manage State Machines (list, cancel, inspect)", "FSM", function(args)
				local action = args[1]
				local fsmService = ServiceManager.Services.FSM -- Direct access
				-- Simplify: Use ServiceManager.Sidecar or direct access depending on mode
				local machines = (ServiceManager.Mode == "server" and ServiceManager.ServerData.FSM.StateMachines) 
								or (fsmService and fsmService.StateMachines) or {}

				if not action or action == "list" or action == "ls" then
					local list = {}
					for id, m in pairs(machines) do
						table.insert(list, string.format("  %s (%s) - %s", color(tostring(id), deps.COLORS.Accent), tostring(m.Name), tostring(m.State)))
					end
					if #list == 0 then return "No StateMachines running." end
					return "StateMachines:\n" .. table.concat(list, "\n")
				elseif action == "cancel" then
					if ServiceManager.Mode == "server" then return "Cannot cancel server FSMs from client console yet." end
					local id = args[2]
					if not id then return "Usage: fsm cancel <id>" end
					fsmService:CancelStateMachine(id)
					return "Signal sent to cancel FSM: " .. id
				end
				return "Unknown fsm action. Try: list, cancel"
			end, function(args, current)
				if #args == 1 then
					return {"list", "cancel"}
				elseif #args == 2 and args[1] == "cancel" then
					local suggestions = {}
					local fsmService = ServiceManager.Services.FSM
					if fsmService and fsmService.StateMachines then
						for id, _ in pairs(fsmService.StateMachines) do table.insert(suggestions, tostring(id)) end
					end
					return suggestions
				end
				return {}
			end)

			-- --------------------------------------------------------------------------------
			-- INPUT HANDLING
			-- --------------------------------------------------------------------------------
			--[[
				@description Executes a console command: adds to history, echoes input,
				parses tokens, runs the registered action or falls back to server.
				@param text string -- Raw user input.
				@return ()
			]]
			local function execute(text: string)
				if text:match("^%s*$") then return end
				
				-- Add to history
				table.insert(this.Constants.CommandHistory, text)
				this.Constants.HistoryIndex = #this.Constants.CommandHistory + 1
				
				-- Echo input
				writeLine(string.format("%s@%s:~$ %s", owner.Name, ServiceManager.Mode, text), 0)
				
				-- Parse
				local args, flags = parse(text)
				local cmdName = table.remove(args, 1)
				
				if not cmdName then return end
				cmdName = cmdName:lower()
				
				local cmd = Registry[cmdName]
				if cmd then
					-- Execute Local
					local ok, result = pcall(cmd.Action, args, flags)
					if not ok then
						writeLine("Runtime Error: " .. tostring(result), 3)
					elseif result then
						writeLine(tostring(result)) -- Rich text allowed in result
					end
				else
					-- Server fallback?
					if ServiceManager.Mode == "server" then
						writeLine("Sending to server...", 2)
						task.spawn(function()
							if ServiceManager.Orchestrator and ServiceManager.Orchestrator.Request then
								local res = ServiceManager.Orchestrator.Request("ConsoleCommand", text)
								if res then writeLine(res) end
							end
						end)
					else
						writeLine("Unknown command: " .. cmdName, 3)
					end
				end
			end
			
			-- Autocomplete
			--[[
				@description Updates the autocomplete suggestions UI based on the
				current input text, matching command names or sub-command completions.
				@return ()
			]]
			local function updateSuggestions()
				local text = InputBox.Text
				local tokens = tokenize(text)
				local currentToken = tokens[#tokens] or ""
				
				-- Clear existing
				for _, c in SuggestionsFrame:GetChildren() do if c:IsA("TextButton") then c:Destroy() end end
				SuggestionsFrame.Visible = false
				
				if text:match("^%s*$") or not currentToken then return end
				
				local candidates = {}
				
				if #tokens <= 1 then
					-- Command completion
					for name, _ in pairs(Registry) do
						if name:lower():sub(1, #currentToken) == currentToken:lower() then
							table.insert(candidates, name)
						end
					end
				else
					-- Sub-command completion
					local cmdName = tokens[1]:lower()
					local cmd = Registry[cmdName]
					if cmd and cmd.Completion then
						local args = {unpack(tokens, 2)}
						local suggestions = cmd.Completion(args, currentToken)
						for _, cand in ipairs(suggestions) do
							if cand:lower():sub(1, #currentToken) == currentToken:lower() then
								table.insert(candidates, cand)
							end
						end
					end
				end
				
				-- Render candidates
				table.sort(candidates)
				local count = 0
				for _, cand in ipairs(candidates) do
					if count > 5 then break end
					count += 1
					local btn = Instance.new("TextButton")
					btn.Size = UDim2.new(1, 0, 0, 20)
					btn.BackgroundTransparency = 1
					btn.Text = "  " .. cand
					btn.TextColor3 = deps.COLORS.Default
					btn.Font = Enum.Font.Code
					btn.TextSize = 14
					btn.TextXAlignment = Enum.TextXAlignment.Left
					btn.Parent = SuggestionsFrame
					btn.LayoutOrder = count
					
					local conn = btn.MouseButton1Click:Connect(function()
						-- Replace last token
						tokens[#tokens] = cand
						
						-- Reconstruct Text: Simple join for now
						local newText = table.concat(tokens, " ") .. " "
						InputBox.Text = newText
						InputBox:CaptureFocus()
						SuggestionsFrame.Visible = false
					end)
					table.insert(this.Connections, conn)
				end
				
				if count > 0 then
					SuggestionsFrame.Size = UDim2.new(1, -20, 0, count * 20)
					SuggestionsFrame.Position = UDim2.new(0, 10, 1, -35 - (count * 20))
					SuggestionsFrame.Visible = true
				end
			end

			-- Hook Events
			table.insert(this.Connections, InputBox:GetPropertyChangedSignal("Text"):Connect(updateSuggestions))
			
			table.insert(this.Connections, InputBox.FocusLost:Connect(function(enter)
				SuggestionsFrame.Visible = false
				if enter then
					execute(InputBox.Text)
					InputBox.Text = ""
					task.defer(function()  InputBox:CaptureFocus() InputBox.Text = "" end)
				end
			end))
			
			-- Initial Welcome
			if not this.Constants.Initialized then
				log([[<font size="16" color="#00C8FF"><b>ServiceManager CLI</b></font>
Type 'help' for commands.
Mode: ]] .. ServiceManager.Mode:upper(), nil, true)
				this.Constants.Initialized = true
			end
		end -- End One-time Initialization
	end

	return page
end


return ConsolePage
