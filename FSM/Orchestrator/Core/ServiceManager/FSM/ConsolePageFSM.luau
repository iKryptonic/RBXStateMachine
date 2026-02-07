--!strict
-- @Name ConsolePageFSM
-- @Author iKrypto
-- @Description Console Page FSM managing CLI with command system and scroll engine.
-- Migrated from legacy ConsolePage.luau controller pattern.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local BasePageFSM = require(script.Parent.BasePageFSM)

local ConsolePageFSM = BasePageFSM.Extend({
	className = "ConsolePageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ExecutingCommand", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 11
})

-- Console constants
local CONSOLE_MAX_LIMIT = 500

--[[
	@description Registers states for the console page FSM.
	@return ()
]]
function ConsolePageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("ExecutingCommand", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Executing console command..." })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

--[[
	@description Wraps text in rich-text font tag with Color3.
	@param text string
	@param col Color3
	@return string
]]
local function colorText(text: string, col: Color3): string
	local r, g, b = math.floor(col.R * 255), math.floor(col.G * 255), math.floor(col.B * 255)
	return string.format('<font color="rgb(%d,%d,%d)">%s</font>', r, g, b, text)
end

--[[
	@description Recursively formats a table into multiline string.
	@param tbl any
	@param indent number?
	@param colors table
	@return string
]]
local function formatTable(tbl: any, indent: number?, colors: any): string
	indent = indent or 0
	local result = ""
	local space = string.rep("  ", indent or 0)
	
	if type(tbl) ~= "table" then
		return space .. tostring(tbl)
	end
	
	for k, v in pairs(tbl) do
		if type(v) == "table" then
			result = result .. space .. colorText(tostring(k), colors.Accent or Color3.fromRGB(0, 200, 255)) .. ":\n" .. formatTable(v, (indent or 0) + 1, colors) .. "\n"
		else
			result = result .. space .. colorText(tostring(k), colors.Accent or Color3.fromRGB(0, 200, 255)) .. ": " .. tostring(v) .. "\n"
		end
	end
	return result
end

--[[
	@description Tokenizes command-line input with quote and escape support.
	@param input string
	@return {string}
]]
local function tokenize(input: string): {string}
	local tokens = {}
	local currentToken = ""
	local inQuote = false
	local escape = false
	
	for i = 1, #input do
		local char = input:sub(i, i)
		
		if escape then
			currentToken = currentToken .. char
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
			currentToken = currentToken .. char
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
	@description Parses command-line into args and flags.
	@param input string
	@return {string}, {[string]: any}
]]
local function parse(input: string)
	local rawTokens = tokenize(input)
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

--[[
	@description Hook for initializing console UI elements.
	@param entity any
	@return ()
]]
function ConsolePageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing Console Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "Console container not found" })
		return
	end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	
	local InputBox = container:FindFirstChild("UserInput")
	if not InputBox then
		self:Log({ Level = "ERROR", Message = "Console UserInput not found" })
		return
	end
	entity.InputBox = InputBox
	
	-- Build viewport
	local Viewport = container:FindFirstChild("Viewport")
	if not Viewport then
		local oldObj = container:FindFirstChild("TextContainer")
		if oldObj then oldObj:Destroy() end
		
		Viewport = Instance.new("Frame")
		Viewport.Name = "Viewport"
		Viewport.Parent = container
		Viewport.Size = UDim2.new(1, -12, 1, -50)
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
	entity.Viewport = Viewport
	entity.Content = Viewport:FindFirstChild("Content")
	entity.ListLayout = entity.Content:FindFirstChildOfClass("UIListLayout")
	
	-- Suggestions frame
	local SuggestionsFrame = container:FindFirstChild("Suggestions")
	if not SuggestionsFrame then
		SuggestionsFrame = Instance.new("Frame")
		SuggestionsFrame.Name = "Suggestions"
		SuggestionsFrame.Parent = container
		SuggestionsFrame.Size = UDim2.new(1, -20, 0, 0)
		SuggestionsFrame.Position = UDim2.new(0, 10, 1, -40)
		SuggestionsFrame.AnchorPoint = Vector2.new(0, 1)
		SuggestionsFrame.BackgroundColor3 = colors.PanelBG or Color3.fromRGB(35, 35, 35)
		SuggestionsFrame.BorderSizePixel = 0
		SuggestionsFrame.Visible = false
		SuggestionsFrame.ZIndex = 10
		
		Instance.new("UIStroke", SuggestionsFrame).Color = colors.Stroke or Color3.fromRGB(80, 80, 80)
		Instance.new("UIListLayout", SuggestionsFrame).SortOrder = Enum.SortOrder.LayoutOrder
	end
	entity.SuggestionsFrame = SuggestionsFrame
	
	-- Custom scrollbar
	local ScrollTrack = container:FindFirstChild("ScrollTrack")
	if not ScrollTrack then
		ScrollTrack = Instance.new("Frame")
		ScrollTrack.Name = "ScrollTrack"
		ScrollTrack.Parent = container
		ScrollTrack.Size = UDim2.new(0, 6, 1, -10)
		ScrollTrack.Position = UDim2.new(1, -6, 0, 5)
		ScrollTrack.BackgroundColor3 = colors.InputBG or Color3.fromRGB(30, 30, 30)
		ScrollTrack.BorderSizePixel = 0
		Instance.new("UICorner", ScrollTrack).CornerRadius = UDim.new(1, 0)
		
		local Thumb = Instance.new("TextButton")
		Thumb.Name = "Thumb"
		Thumb.Parent = ScrollTrack
		Thumb.Size = UDim2.new(1, 0, 0.2, 0)
		Thumb.BackgroundColor3 = colors.Stroke or Color3.fromRGB(80, 80, 80)
		Thumb.Text = ""
		Thumb.AutoButtonColor = false
		Instance.new("UICorner", Thumb).CornerRadius = UDim.new(1, 0)
	end
	entity.ScrollTrack = ScrollTrack
	entity.ScrollThumb = ScrollTrack:FindFirstChild("Thumb")
	
	-- Initialize scroll state
	entity.ScrollY = 0
	entity.FollowTail = true
	
	-- Initialize command registry
	self:RegisterCommands(entity)
	
	-- Hook input events
	self:HookInputEvents(entity)
	
	-- Hook scroll events
	self:HookScrollEvents(entity)
	
	-- Welcome message
	if not entity.Initialized then
		local owner = Players.LocalPlayer
		self:Log_(entity, [[<font size="16" color="#00C8FF"><b>ServiceManager CLI</b></font>
Type 'help' for commands.
Mode: ]] .. (serviceManager.Mode or "client"):upper(), nil, true)
		entity.Initialized = true
	end
	
	self:Log({ Level = "INFO", Message = "Console Page UI initialized successfully" })
end

--[[
	@description Registers all console commands.
	@param entity any
	@return ()
]]
function ConsolePageFSM:RegisterCommands(entity: any)
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	
	entity.Registry = entity.Registry or {}
	
	local function register(name, desc, group, fn, completion)
		entity.Registry[name] = { Description = desc, Group = group, Action = fn, Completion = completion }
	end
	
	-- CORE
	register("help", "Lists all commands", "Core", function(args)
		local lines = {"Available Commands:"}
		local sorted = {}
		for k, v in pairs(entity.Registry) do table.insert(sorted, {k, v}) end
		table.sort(sorted, function(a,b) return a[1] < b[1] end)
		
		for _, item in ipairs(sorted) do
			local name, data = item[1], item[2]
			table.insert(lines, string.format("  %s %s - %s",
				colorText(name, colors.Accent or Color3.fromRGB(0, 200, 255)),
				string.rep(" ", 15 - #name),
				data.Description
			))
		end
		return table.concat(lines, "\n")
	end)
	
	register("clear", "Clears the console", "Core", function()
		self:ClearConsole(entity)
		return nil
	end)
	
	register("echo", "Prints text", "Core", function(args) return table.concat(args, " ") end)
	register("version", "Shows version", "Core", function() return "ServiceManager CLI v3.1" end)
	
	register("switch", "Switch context (client/server)", "Core", function(args)
		local target = args[1] and args[1]:lower()
		if target == "client" or target == "server" then
			if serviceManager.SetMode then
				serviceManager:SetMode(target)
			else
				serviceManager.Mode = target
			end
			return "Context shifted to " .. colorText(target:upper(), colors.Success or Color3.fromRGB(160, 255, 160))
		end
		return "Usage: switch <client|server>"
	end, function(args, current)
		if #args == 1 then return {"client", "server"} end
		return {}
	end)
	
	-- SCHEDULER
	register("task", "Manage tasks (list, run, kill, info)", "Scheduler", function(args, flags)
		local action = args[1]
		local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
		if not scheduler then return "Scheduler not available" end
		
		if not action or action == "list" or action == "ls" then
			local taskList = {}
			for name, t in pairs(scheduler.Tasks or {}) do
				table.insert(taskList, string.format("  %s [%s] (P:%d)",
					colorText(name, colors.Accent or Color3.fromRGB(0, 200, 255)),
					t.Status or "idle", t.Priority or 1))
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
			return formatTable(t, nil, colors)
		end
		return "Unknown task action. Try: list, run, kill, info"
	end, function(args, current)
		if #args == 1 then
			return {"list", "run", "kill", "info"}
		elseif #args == 2 and (args[1] == "run" or args[1] == "kill" or args[1] == "info" or args[1] == "stop") then
			local suggestions = {}
			local scheduler = serviceManager.Services and serviceManager.Services.Scheduler
			if scheduler and scheduler.Tasks then
				for name in pairs(scheduler.Tasks) do table.insert(suggestions, name) end
			end
			return suggestions
		end
		return {}
	end)
	
	-- FSM
	register("fsm", "Manage State Machines (list, cancel)", "FSM", function(args)
		local action = args[1]
		local fsmService = serviceManager.Services and serviceManager.Services.FSM
		local machines = fsmService and fsmService.StateMachines or {}
		
		if not action or action == "list" or action == "ls" then
			local list = {}
			for id, m in pairs(machines) do
				table.insert(list, string.format("  %s (%s) - %s",
					colorText(tostring(id), colors.Accent or Color3.fromRGB(0, 200, 255)),
					tostring(m.Name), tostring(m.State)))
			end
			if #list == 0 then return "No StateMachines running." end
			return "StateMachines:\n" .. table.concat(list, "\n")
		elseif action == "cancel" then
			local id = args[2]
			if not id then return "Usage: fsm cancel <id>" end
			if fsmService and fsmService.CancelStateMachine then
				fsmService:CancelStateMachine(id)
			end
			return "Signal sent to cancel FSM: " .. id
		end
		return "Unknown fsm action. Try: list, cancel"
	end, function(args, current)
		if #args == 1 then
			return {"list", "cancel"}
		elseif #args == 2 and args[1] == "cancel" then
			local suggestions = {}
			local fsmService = serviceManager.Services and serviceManager.Services.FSM
			if fsmService and fsmService.StateMachines then
				for id in pairs(fsmService.StateMachines) do table.insert(suggestions, tostring(id)) end
			end
			return suggestions
		end
		return {}
	end)
end

--[[
	@description Hooks input events for command execution and history.
	@param entity any
	@return ()
]]
function ConsolePageFSM:HookInputEvents(entity: any)
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	
	local InputBox = entity.InputBox
	if not InputBox then return end
	
	-- Text change -> update suggestions
	entity:Manage(InputBox:GetPropertyChangedSignal("Text"):Connect(function()
		self:UpdateSuggestions(entity)
	end))
	
	-- Focus lost -> execute command
	entity:Manage(InputBox.FocusLost:Connect(function(enter)
		if entity.SuggestionsFrame then
			entity.SuggestionsFrame.Visible = false
		end
		if enter then
			self:ExecuteCommand(entity, InputBox.Text)
			InputBox.Text = ""
			task.defer(function()
				InputBox:CaptureFocus()
				InputBox.Text = ""
			end)
		end
	end))
end

--[[
	@description Hooks scroll events for viewport.
	@param entity any
	@return ()
]]
function ConsolePageFSM:HookScrollEvents(entity: any)
	local Viewport = entity.Viewport
	if not Viewport then return end
	
	local Content = entity.Content
	local ScrollTrack = entity.ScrollTrack
	local ScrollThumb = entity.ScrollThumb
	local ListLayout = entity.ListLayout
	
	local isDragging = false
	local dragStartY = 0
	local startScrollY = 0
	
	local function getContentHeight()
		if ListLayout then
			return ListLayout.AbsoluteContentSize.Y
		end
		return Content and Content.AbsoluteSize.Y or 0
	end
	
	local function getViewportHeight()
		return Viewport.AbsoluteSize.Y
	end
	
	local function updateVisuals()
		local contentH = getContentHeight()
		local viewportH = getViewportHeight()
		local maxScroll = math.max(0, contentH - viewportH)
		entity.ScrollY = math.clamp(entity.ScrollY, 0, maxScroll)
		
		if Content then
			Content.Position = UDim2.new(0, 0, 0, -entity.ScrollY)
		end
		
		if maxScroll <= 0 then
			if ScrollThumb then ScrollThumb.Visible = false end
			if ScrollTrack then ScrollTrack.Visible = false end
		else
			if ScrollThumb then ScrollThumb.Visible = true end
			if ScrollTrack then ScrollTrack.Visible = true end
			
			local ratio = viewportH / contentH
			local thumbH = math.max(20, ratio * ScrollTrack.AbsoluteSize.Y)
			if ScrollThumb then
				ScrollThumb.Size = UDim2.new(1, 0, 0, thumbH)
				
				local trackH = ScrollTrack.AbsoluteSize.Y
				if trackH > thumbH then
					local pct = entity.ScrollY / maxScroll
					local thumbY = pct * (trackH - thumbH)
					ScrollThumb.Position = UDim2.new(0, 0, 0, thumbY)
				end
			end
		end
	end
	
	local function setScroll(val)
		entity.ScrollY = val
		updateVisuals()
		local maxScroll = math.max(0, getContentHeight() - getViewportHeight())
		entity.FollowTail = ((maxScroll - entity.ScrollY) < 20)
	end
	
	-- Mouse wheel
	entity:Manage(Viewport.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			local delta = -input.Position.Z * 40
			setScroll(entity.ScrollY + delta)
		end
	end))
	
	-- Resize hooks
	entity:Manage(Viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateVisuals))
	if Content then
		entity:Manage(Content:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateVisuals))
	end
	
	-- Drag logic
	if ScrollThumb then
		entity:Manage(ScrollThumb.MouseButton1Down:Connect(function(x, y)
			isDragging = true
			dragStartY = y
			startScrollY = entity.ScrollY
		end))
		
		entity:Manage(UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement and isDragging then
				local delta = input.Position.Y - dragStartY
				local trackH = ScrollTrack.AbsoluteSize.Y
				local thumbH = ScrollThumb.AbsoluteSize.Y
				local activeH = trackH - thumbH
				
				if activeH > 0 then
					local contentH = getContentHeight()
					local viewportH = getViewportHeight()
					local maxScroll = math.max(0, contentH - viewportH)
					local pct = delta / activeH
					setScroll(startScrollY + (pct * maxScroll))
				end
			end
		end))
		
		entity:Manage(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				isDragging = false
			end
		end))
	end
	
	-- Store update function for scroll-to-bottom
	entity._updateVisuals = updateVisuals
	entity._getContentHeight = getContentHeight
	entity._getViewportHeight = getViewportHeight
	entity._setScroll = setScroll
end

--[[
	@description Clears the console content.
	@param entity any
	@return ()
]]
function ConsolePageFSM:ClearConsole(entity: any)
	entity.LineCount = 0
	local Content = entity.Content
	if Content then
		for _, item in ipairs(Content:GetChildren()) do
			if item:IsA("TextLabel") then item:Destroy() end
		end
	end
end

--[[
	@description Writes a line to the console.
	@param entity any
	@param text string
	@param outputType number?
	@return ()
]]
function ConsolePageFSM:WriteLine(entity: any, text: string, outputType: number?)
	local colors = self.Context.COLORS or {}
	local serviceManager = self.Context.ServiceManager
	local Content = entity.Content
	if not Content then return end
	
	local shouldAutoScroll = entity.FollowTail or (entity._getContentHeight and entity._getViewportHeight and 
		((math.max(0, entity._getContentHeight() - entity._getViewportHeight()) - entity.ScrollY) < 20))
	
	local lineLabel = serviceManager.GUI and serviceManager.GUI.References and serviceManager.GUI.References.ConsoleLineReference and serviceManager.GUI.References.ConsoleLineReference:Clone()
	if not lineLabel then
		lineLabel = Instance.new("TextLabel")
		lineLabel.BackgroundTransparency = 1
		lineLabel.TextColor3 = Color3.new(1, 1, 1)
		lineLabel.Font = Enum.Font.Code
		lineLabel.TextSize = 14
		lineLabel.TextXAlignment = Enum.TextXAlignment.Left
		lineLabel.RichText = true
	end
	
	lineLabel.AutomaticSize = Enum.AutomaticSize.Y
	lineLabel.TextWrapped = true
	lineLabel.Size = UDim2.new(1, 0, 0, 0)
	
	if outputType == 1 then text = colorText(text, colors.Success or Color3.fromRGB(160, 255, 160))
	elseif outputType == 2 then text = colorText(text, colors.Warning or Color3.fromRGB(255, 200, 100))
	elseif outputType == 3 then text = colorText(text, colors.Error or Color3.fromRGB(255, 120, 120))
	elseif outputType == 0 then text = colorText(text, colors.Prompt or Color3.fromRGB(0, 200, 255))
	end
	
	entity.LineCount = (entity.LineCount or 0) + 1
	lineLabel.LayoutOrder = entity.LineCount
	lineLabel.Text = text
	lineLabel.Parent = Content
	lineLabel.Visible = true
	
	if shouldAutoScroll and entity._setScroll and entity._getContentHeight and entity._getViewportHeight then
		entity.FollowTail = true
		task.defer(function()
			RunService.RenderStepped:Wait()
			local newMax = math.max(0, entity._getContentHeight() - entity._getViewportHeight())
			entity._setScroll(newMax)
		end)
	end
end

--[[
	@description Logs multiline text to console.
	@param entity any
	@param text string
	@param typeVal number?
	@param raw boolean?
	@return ()
]]
function ConsolePageFSM:Log_(entity: any, text: string, typeVal: number?, raw: boolean?)
	local serviceManager = self.Context.ServiceManager
	
	if not raw and serviceManager.EscapeRichText then
		text = serviceManager:EscapeRichText(text)
	elseif not raw then
		text = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
	end
	
	for line in text:gmatch("[^\r\n]+") do
		self:WriteLine(entity, line, typeVal)
	end
end

--[[
	@description Executes a console command.
	@param entity any
	@param text string
	@return ()
]]
function ConsolePageFSM:ExecuteCommand(entity: any, text: string)
	if text:match("^%s*$") then return end
	
	local serviceManager = self.Context.ServiceManager
	local colors = self.Context.COLORS or {}
	local owner = Players.LocalPlayer
	
	-- Add to history
	entity.CommandHistory = entity.CommandHistory or {}
	table.insert(entity.CommandHistory, text)
	entity.HistoryIndex = #entity.CommandHistory + 1
	
	-- Echo input
	self:WriteLine(entity, string.format("%s@%s:~$ %s", owner and owner.Name or "Player", serviceManager.Mode or "client", text), 0)
	
	-- Parse
	local args, flags = parse(text)
	local cmdName = table.remove(args, 1)
	
	if not cmdName then return end
	cmdName = cmdName:lower()
	
	local cmd = entity.Registry and entity.Registry[cmdName]
	if cmd then
		local ok, result = pcall(cmd.Action, args, flags)
		if not ok then
			self:WriteLine(entity, "Runtime Error: " .. tostring(result), 3)
		elseif result then
			for line in tostring(result):gmatch("[^\r\n]+") do
				self:WriteLine(entity, line)
			end
		end
	else
		self:WriteLine(entity, "Unknown command: " .. cmdName, 3)
	end
end

--[[
	@description Updates autocomplete suggestions.
	@param entity any
	@return ()
]]
function ConsolePageFSM:UpdateSuggestions(entity: any)
	local colors = self.Context.COLORS or {}
	local InputBox = entity.InputBox
	local SuggestionsFrame = entity.SuggestionsFrame
	if not InputBox or not SuggestionsFrame then return end
	
	local text = InputBox.Text
	local tokens = tokenize(text)
	local currentToken = tokens[#tokens] or ""
	
	-- Clear existing
	for _, c in ipairs(SuggestionsFrame:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	SuggestionsFrame.Visible = false
	
	if text:match("^%s*$") or not currentToken then return end
	
	local candidates = {}
	
	if #tokens <= 1 then
		-- Command completion
		for name in pairs(entity.Registry or {}) do
			if name:lower():sub(1, #currentToken) == currentToken:lower() then
				table.insert(candidates, name)
			end
		end
	else
		-- Sub-command completion
		local cmdName = tokens[1]:lower()
		local cmd = entity.Registry and entity.Registry[cmdName]
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
		btn.TextColor3 = colors.Default or Color3.new(1, 1, 1)
		btn.Font = Enum.Font.Code
		btn.TextSize = 14
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.Parent = SuggestionsFrame
		btn.LayoutOrder = count
		
		entity:Manage(btn.MouseButton1Click:Connect(function()
			tokens[#tokens] = cand
			local newText = table.concat(tokens, " ") .. " "
			InputBox.Text = newText
			InputBox:CaptureFocus()
			SuggestionsFrame.Visible = false
		end))
	end
	
	if count > 0 then
		SuggestionsFrame.Size = UDim2.new(1, -20, 0, count * 20)
		SuggestionsFrame.Position = UDim2.new(0, 10, 1, -35 - (count * 20))
		SuggestionsFrame.Visible = true
	end
end

--[[
	@description Hook for fetching data (minimal for console).
	@param entity any
	@return ()
]]
function ConsolePageFSM:OnFetchData(entity: any)
	-- Console doesn't fetch data
end

--[[
	@description Hook for rendering console UI.
	@param entity any
	@return ()
]]
function ConsolePageFSM:OnRenderUI(entity: any)
	-- Console rendering is handled by event hooks
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function ConsolePageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

return ConsolePageFSM
