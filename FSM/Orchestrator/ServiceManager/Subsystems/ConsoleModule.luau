--!strict
-- @Name ServiceManager/Subsystems/ConsoleModule.luau
-- @Author iKrypto
-- @Description Full interactive console / terminal subsystem with command registry,
-- history, autocomplete, and rich output formatting. Feature parity with legacy
-- ServiceManager Console page.

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Parent.Theme)

-- ══════════════════════════════════════════════════════════════
-- TYPES
-- ══════════════════════════════════════════════════════════════

type OutputLine = {
	Text: string,
	Color: Color3,
	Timestamp: number,
	Level: string, -- "INFO" | "WARN" | "ERROR" | "RESULT" | "SYSTEM"
}

type CommandDef = {
	Name: string,
	Description: string,
	Usage: string?,
	Handler: (args: { string }, nexus: any) -> string?,
}

-- ══════════════════════════════════════════════════════════════
-- MODULE
-- ══════════════════════════════════════════════════════════════

local ConsoleModule = {}
ConsoleModule.__index = ConsoleModule

local MAX_OUTPUT_LINES = 500
local MAX_HISTORY = 100

--[[
	Create the CONSOLE subsystem controller.
	Initializes the terminal buffers, command registry, history state, and
	autocomplete bookkeeping used by the interactive shell.
]]
function ConsoleModule.new(): any
	local self = setmetatable({}, ConsoleModule)
	self._outputBuffer = {} :: { OutputLine }
	self._commandHistory = {} :: { string }
	self._historyIndex = 0
	self._registeredCommands = {} :: { [string]: CommandDef }
	self._inputConnection = nil :: RBXScriptConnection?
	self._scrollFrame = nil :: ScrollingFrame?
	self._inputBox = nil :: TextBox?
	self._autocompleteFrame = nil :: Frame?
	self._lastRenderCount = 0
	self._needsFullRender = false
	self._acSelectedIndex = 0
	self._acSuggestions = {} :: { string }
	self._acButtons = {} :: { TextButton }
	self:_RegisterBuiltinCommands()
	return self
end

-- ══════════════════════════════════════════════════════════════
-- DATA
-- ══════════════════════════════════════════════════════════════

--[[
	Prime console state for display.
	The console is event-driven, so this hook only seeds the initial welcome lines
	when the output buffer is still empty.
]]
function ConsoleModule:FetchData(nexus: any)
	-- Console doesn't poll data; it's event-driven.
	-- Push a welcome message on first load if buffer is empty.
	if #self._outputBuffer == 0 then
		self:_PushLine("SYSTEM", "ServiceManager Console v1.0", Theme.Colors.Accent)
		self:_PushLine("SYSTEM", 'Type "help" for available commands.', Theme.Colors.TextMuted)
		self:_PushLine("SYSTEM", "", Theme.Colors.TextMuted)
	end
end

--[[
	Legacy subsystem hook retained for interface parity.
	CONSOLE rendering is produced by BuildRootLayer and its event handlers.
]]
function ConsoleModule:Render(nexus: any) end

-- ══════════════════════════════════════════════════════════════
-- OUTPUT BUFFER
-- ══════════════════════════════════════════════════════════════

function ConsoleModule:_PushLine(level: string, text: string, color: Color3?)
	local lineColor = color
	if not lineColor then
		if level == "ERROR" then lineColor = Theme.Colors.Danger
		elseif level == "WARN" then lineColor = Theme.Colors.Warning
		elseif level == "RESULT" then lineColor = Theme.Colors.Success
		elseif level == "SYSTEM" then lineColor = Theme.Colors.Accent
		else lineColor = Theme.Colors.TextSecondary
		end
	end

	table.insert(self._outputBuffer, {
		Text = text,
		Color = lineColor :: Color3,
		Timestamp = os.clock(),
		Level = level,
	})

	-- Trim buffer. Incremental rendering tracks how many of the CURRENT
	-- buffered lines have been materialized, so front-trims require a full
	-- rerender or the newest lines will never appear once the buffer is full.
	local trimmed = false
	while #self._outputBuffer > MAX_OUTPUT_LINES do
		table.remove(self._outputBuffer, 1)
		trimmed = true
	end
	if trimmed then
		self._needsFullRender = true
	end
end

-- ══════════════════════════════════════════════════════════════
-- COMMAND EXECUTION
-- ══════════════════════════════════════════════════════════════

--[[
	Parse, execute, and echo a user-entered console command.
	Writes both command input and handler output back into the scrolling terminal
	buffer so the shell remains self-contained and replayable.
]]
function ConsoleModule:ExecuteCommand(rawInput: string, nexus: any)
	if rawInput == "" then return end

	-- Echo the command
	self:_PushLine("INFO", "> " .. rawInput, Theme.Colors.TextPrimary)

	-- Add to history
	table.insert(self._commandHistory, rawInput)
	if #self._commandHistory > MAX_HISTORY then
		table.remove(self._commandHistory, 1)
	end
	self._historyIndex = #self._commandHistory + 1

	-- Parse command and args
	local parts = {}
	for word in rawInput:gmatch("%S+") do
		table.insert(parts, word)
	end

	local cmdName = string.lower(parts[1] or "")
	local args = {}
	for i = 2, #parts do
		table.insert(args, parts[i])
	end

	-- Look up command
	local cmd = self._registeredCommands[cmdName]
	if cmd then
		local ok, result = pcall(cmd.Handler, args, nexus)
		if ok then
			if result and result ~= "" then
				-- Split multi-line results
				for line in result:gmatch("[^\n]+") do
					self:_PushLine("RESULT", line, Theme.Colors.Success)
				end
			end
		else
			self:_PushLine("ERROR", "Error: " .. tostring(result))
		end
	else
		self:_PushLine("ERROR", string.format('Unknown command "%s". Type "help" for available commands.', cmdName))
	end

	-- Re-render output
	self:_RenderOutput()
end

-- ══════════════════════════════════════════════════════════════
-- BUILT-IN COMMANDS
-- ══════════════════════════════════════════════════════════════

function ConsoleModule:_RegisterBuiltinCommands()
	self:RegisterCommand({
		Name = "help",
		Description = "List all available commands",
		Handler = function(args, nexus)
			local lines = { "Available Commands:", "─────────────────────────────" }
			local sorted = {}
			for name, cmd in pairs(self._registeredCommands) do
				table.insert(sorted, cmd)
			end
			table.sort(sorted, function(a, b) return a.Name < b.Name end)
			for _, cmd in ipairs(sorted) do
				local usage = cmd.Usage or cmd.Name
				table.insert(lines, string.format("  %-16s %s", usage, cmd.Description))
			end
			return table.concat(lines, "\n")
		end,
	})

	self:RegisterCommand({
		Name = "clear",
		Description = "Clear the console output",
		Handler = function(args, nexus)
			table.clear(self._outputBuffer)
			self:_PushLine("SYSTEM", "Console cleared.", Theme.Colors.TextMuted)
			return nil
		end,
	})

	self:RegisterCommand({
		Name = "echo",
		Description = "Print a message to the console",
		Usage = "echo <message>",
		Handler = function(args, nexus)
			return table.concat(args, " ")
		end,
	})

	self:RegisterCommand({
		Name = "version",
		Description = "Show ServiceManager version",
		Handler = function(args, nexus)
			return "ServiceManager v1.0.0 | Glass Engine UI"
		end,
	})

	self:RegisterCommand({
		Name = "mode",
		Description = "Show or switch context mode (client/server)",
		Usage = "mode [client|server]",
		Handler = function(args, nexus)
			if #args == 0 then
				return "Current mode: " .. (nexus._contextMode or "client")
			end
			local target = string.lower(args[1])
			if target == "client" or target == "server" then
				if nexus.SetContextMode then
					nexus.SetContextMode(target)
				end
				return "Switched to " .. target .. " mode"
			end
			return 'Usage: mode [client|server]'
		end,
	})

	self:RegisterCommand({
		Name = "tasks",
		Description = "List scheduled tasks or get task info",
		Usage = "tasks [list|info <name>|run <name>|kill <name>]",
		Handler = function(args, nexus)
			local orch = nexus._orchestrator
			if not orch or not orch.Scheduler then
				return "No scheduler available"
			end

			local sub = string.lower(args[1] or "list")

			if sub == "list" then
				local lines = { "Scheduled Tasks:", "─────────────────────────────" }
				local tasks = orch.Scheduler.Tasks or {}
				local count = 0
				for name, taskDef in pairs(tasks) do
					count += 1
					local status = taskDef.Status or "idle"
					local execCount = taskDef.ExecutionCount or 0
					local statusIcon = if status == "running" then "●" elseif status == "error" then "✕" else "○"
					table.insert(lines, string.format("  %s %-24s %s (×%d)", statusIcon, name, status, execCount))
				end
				if count == 0 then
					table.insert(lines, "  (no tasks registered)")
				end
				return table.concat(lines, "\n")

			elseif sub == "info" then
				local taskName = args[2]
				if not taskName then return "Usage: tasks info <name>" end
				local taskDef = (orch.Scheduler.Tasks or {})[taskName]
				if not taskDef then return "Task not found: " .. taskName end
				local lines = {
					"Task: " .. taskName,
					"─────────────────────────────",
					"  Status:      " .. (taskDef.Status or "idle"),
					"  Priority:    " .. tostring(taskDef.Priority or 5),
					"  Recurring:   " .. tostring(taskDef.IsRecurringTask or false),
					"  Executions:  " .. tostring(taskDef.ExecutionCount or 0),
					"  Errors:      " .. tostring(taskDef.Errors or 0),
					"  Event:       " .. tostring(taskDef.Event or "N/A"),
				}
				if taskDef.Perf then
					table.insert(lines, string.format("  Avg Time:    %.3fms", (taskDef.Perf.AvgExecutionTime or 0) * 1000))
					table.insert(lines, string.format("  Max Time:    %.3fms", (taskDef.Perf.MaxExecutionTime or 0) * 1000))
				end
				return table.concat(lines, "\n")

			elseif sub == "run" then
				local taskName = args[2]
				if not taskName then return "Usage: tasks run <name>" end
				local taskDef = (orch.Scheduler.Tasks or {})[taskName]
				if not taskDef then return "Task not found: " .. taskName end
				if taskDef.TaskAction then
					local ok, err = pcall(taskDef.TaskAction)
					if ok then return "Task executed: " .. taskName
					else return "Task failed: " .. tostring(err)
					end
				end
				return "Task has no action handler"

			elseif sub == "kill" then
				local taskName = args[2]
				if not taskName then return "Usage: tasks kill <name>" end
				if orch.Scheduler.Unschedule then
					pcall(orch.Scheduler.Unschedule, orch.Scheduler, taskName)
					return "Task killed: " .. taskName
				end
				return "Unschedule not available"
			end

			return "Usage: tasks [list|info|run|kill] <name>"
		end,
	})

	self:RegisterCommand({
		Name = "fsm",
		Description = "List state machines or get FSM info",
		Usage = "fsm [list|info <id>|cancel <id>]",
		Handler = function(args, nexus)
			local orch = nexus._orchestrator
			if not orch then return "No orchestrator available" end

			local machines = orch.StateMachines or {}
			local sub = string.lower(args[1] or "list")

			if sub == "list" then
				local lines = { "State Machines:", "─────────────────────────────" }
				local count = 0
				for id, fsm in pairs(machines) do
					count += 1
					local active = if fsm.IsActive then "●" else "○"
					table.insert(lines, string.format("  %s %-20s [%s] P%d",
						active, fsm.Name or id, fsm.State or "none", fsm.Priority or 1))
				end
				if count == 0 then
					table.insert(lines, "  (no state machines registered)")
				end
				return table.concat(lines, "\n")

			elseif sub == "info" then
				local fsmId = args[2]
				if not fsmId then return "Usage: fsm info <id>" end
				local fsm = machines[fsmId]
				if not fsm then return "FSM not found: " .. fsmId end
				local lines = {
					"FSM: " .. (fsm.Name or fsmId),
					"─────────────────────────────",
					"  State:       " .. (fsm.State or "none"),
					"  Active:      " .. tostring(fsm.IsActive),
					"  Priority:    " .. tostring(fsm.Priority or 1),
					"  Duration:    " .. string.format("%.2fs", fsm.StateDuration or 0),
					"  Transitions: " .. tostring(fsm.TransitionCount or 0),
				}
				return table.concat(lines, "\n")

			elseif sub == "cancel" then
				local fsmId = args[2]
				if not fsmId then return "Usage: fsm cancel <id>" end
				local fsm = machines[fsmId]
				if not fsm then return "FSM not found: " .. fsmId end
				if fsm.Cancel then
					pcall(fsm.Cancel, fsm)
					return "FSM cancelled: " .. fsmId
				end
				return "FSM does not support cancel"
			end

			return "Usage: fsm [list|info|cancel] <id>"
		end,
	})

	self:RegisterCommand({
		Name = "entities",
		Description = "List registered entities",
		Usage = "entities [list|info <id>]",
		Handler = function(args, nexus)
			local orch = nexus._orchestrator
			if not orch then return "No orchestrator available" end

			local entities = orch.Entities or {}
			local sub = string.lower(args[1] or "list")

			if sub == "list" then
				local lines = { "Entities:", "─────────────────────────────" }
				local count = 0
				for id, entity in pairs(entities) do
					count += 1
					local name = "Unknown"
					local valid = false
					pcall(function()
						if entity._privateProperties then
							name = entity._privateProperties.Name or "Unknown"
							valid = entity._privateProperties.IsValid or false
						end
					end)
					local icon = if valid then "●" else "✕"
					table.insert(lines, string.format("  %s %-20s [%s]", icon, id, name))
				end
				if count == 0 then
					table.insert(lines, "  (no entities registered)")
				end
				return table.concat(lines, "\n")

			elseif sub == "info" then
				local entId = args[2]
				if not entId then return "Usage: entities info <id>" end
				local entity = entities[entId]
				if not entity then return "Entity not found: " .. entId end
				local pp = {}
				pcall(function() pp = entity._privateProperties or {} end)
				local lines = {
					"Entity: " .. entId,
					"─────────────────────────────",
					"  Class:    " .. tostring(pp.Name or "Unknown"),
					"  Valid:    " .. tostring(pp.IsValid or false),
					"  Version:  " .. tostring(pp.Version or 0),
				}
				if pp.Schema then
					local schemaCount = 0
					for _ in pairs(pp.Schema) do schemaCount += 1 end
					table.insert(lines, "  Schema:   " .. tostring(schemaCount) .. " fields")
				end
				return table.concat(lines, "\n")
			end

			return "Usage: entities [list|info] <id>"
		end,
	})

	self:RegisterCommand({
		Name = "network",
		Description = "Show network status",
		Handler = function(args, nexus)
			local orch = nexus._orchestrator
			if not orch or not orch.NetworkManager then
				return "No NetworkManager available"
			end
			local nm = orch.NetworkManager
			local lines = { "Network Status:", "─────────────────────────────" }

			local busCount = 0
			if nm.EventBuses then
				for _ in pairs(nm.EventBuses) do busCount += 1 end
			end

			local cmdCount = 0
			if nm.Commands then
				for _ in pairs(nm.Commands) do cmdCount += 1 end
			end

			local entCmdCount = 0
			if nm.EntityCommandCallbacks then
				for _ in pairs(nm.EntityCommandCallbacks) do entCmdCount += 1 end
			end

			local remoteCount = 0
			if nm.RemoteEvents then
				for _ in pairs(nm.RemoteEvents) do remoteCount += 1 end
			end

			table.insert(lines, "  Event Buses:     " .. tostring(busCount))
			table.insert(lines, "  Commands:        " .. tostring(cmdCount))
			table.insert(lines, "  Entity Commands: " .. tostring(entCmdCount))
			table.insert(lines, "  Remote Events:   " .. tostring(remoteCount))
			return table.concat(lines, "\n")
		end,
	})

	self:RegisterCommand({
		Name = "ds",
		Description = "Show datastore status",
		Handler = function(args, nexus)
			local orch = nexus._orchestrator
			if not orch then return "No orchestrator available" end
			local entities = orch.Entities or {}
			local lines = { "Persistent Entities:", "─────────────────────────────" }
			local count = 0
			for id, entity in pairs(entities) do
				pcall(function()
					local schema = entity._privateProperties and entity._privateProperties.Schema
					if schema then
						for _, def in pairs(schema) do
							if def.Persist then
								count += 1
								table.insert(lines, "  " .. id)
								break
							end
						end
					end
				end)
			end
			if count == 0 then
				table.insert(lines, "  (no persistent entities)")
			end
			return table.concat(lines, "\n")
		end,
	})

	self:RegisterCommand({
		Name = "perf",
		Description = "Show performance metrics",
		Handler = function(args, nexus)
			local orch = nexus._orchestrator
			local lines = { "Performance Metrics:", "─────────────────────────────" }
			lines[#lines+1] = string.format("  Memory:    %.2f MB", collectgarbage("count") / 1024)
			if orch and orch.Scheduler and orch.Scheduler.PerformanceManager then
				local pm = orch.Scheduler.PerformanceManager
				lines[#lines+1] = string.format("  FPS:       %.1f", pm.FPS or 0)
				lines[#lines+1] = string.format("  Budget:    %.2fms", (pm.FrameBudget or 0) * 1000)
				lines[#lines+1] = string.format("  Tasks/F:   %.1f", pm.TasksPerFrame or 0)
			end
			return table.concat(lines, "\n")
		end,
	})

	self:RegisterCommand({
		Name = "switch",
		Description = "Switch to a subsystem panel",
		Usage = "switch <subsystem>",
		Handler = function(args, nexus)
			if #args == 0 then
				return "Usage: switch <tasks|fsm|entity|network|datastore|insights|console|logs>"
			end
			local target = string.upper(args[1])
			local valid = { TASKS=true, FSM=true, ENTITY=true, NETWORK=true, DATASTORE=true, INSIGHTS=true, CONSOLE=true, LOGS=true }
			if valid[target] then
				if nexus.SwitchSubsystem then
					nexus.SwitchSubsystem(target)
				end
				return "Switched to " .. target
			end
			return "Unknown subsystem: " .. args[1] .. ". Valid: tasks, fsm, entity, network, datastore, insights, console, logs"
		end,
	})
end

--[[
	Register a console command definition under its lowercase command name.
]]
function ConsoleModule:RegisterCommand(def: CommandDef)
	self._registeredCommands[string.lower(def.Name)] = def
end

-- ══════════════════════════════════════════════════════════════
-- AUTOCOMPLETE
-- ══════════════════════════════════════════════════════════════

--[=[
	Subcommand grammar for built-in commands. Used by the position-aware
	autocomplete system: the current token index in the input determines
	which dimension of completions to show.

	Token 1 (command) → keys of _registeredCommands
	Token 2 (subcommand) → static list per command (or via dynamic provider)
	Token 3+ (args) → dynamic providers (task names, fsm ids, etc.)
]=]
ConsoleModule._subcommands = {
	tasks = { "list", "info", "run", "kill" },
	fsm = { "list", "info", "cancel" },
	entities = { "list", "info" },
	mode = { "client", "server" },
	switch = { "tasks", "fsm", "entity", "network", "datastore", "insights", "console", "logs" },
}

--[=[
	Dynamic providers: given a (command, subcommand) pair and the current
	nexus, return suggestions for the next argument.
]=]
ConsoleModule._dynamicProviders = {
	["tasks.info"] = function(nexus: any): { string }
		local out = {}
		local orch = nexus and nexus._orchestrator
		if orch and orch.Scheduler and orch.Scheduler.Tasks then
			for name, _ in pairs(orch.Scheduler.Tasks) do table.insert(out, name) end
		end
		table.sort(out)
		return out
	end,
	["tasks.run"] = function(nexus: any): { string }
		return ConsoleModule._dynamicProviders["tasks.info"](nexus)
	end,
	["tasks.kill"] = function(nexus: any): { string }
		return ConsoleModule._dynamicProviders["tasks.info"](nexus)
	end,
	["fsm.info"] = function(nexus: any): { string }
		local out = {}
		local orch = nexus and nexus._orchestrator
		if orch and orch.StateMachines then
			for id, _ in pairs(orch.StateMachines) do table.insert(out, id) end
		end
		table.sort(out)
		return out
	end,
	["fsm.cancel"] = function(nexus: any): { string }
		return ConsoleModule._dynamicProviders["fsm.info"](nexus)
	end,
	["entities.info"] = function(nexus: any): { string }
		local out = {}
		local orch = nexus and nexus._orchestrator
		if orch and orch.Entities then
			for id, _ in pairs(orch.Entities) do table.insert(out, id) end
		end
		table.sort(out)
		return out
	end,
}

--[=[
	Score a candidate against a query — higher score = better match.
	Prefix match scores 1000 + (1 - len ratio) for stable sort.
	Substring scores 500 + ...
	Fuzzy (subsequence) scores 100.
	No match returns -1.
]=]
local function scoreMatch(query: string, candidate: string): number
	local q = string.lower(query)
	local c = string.lower(candidate)
	if q == "" then return 0 end
	if c:sub(1, #q) == q then
		return 1000 - #c -- prefer shorter / more specific matches
	end
	local idx = c:find(q, 1, true)
	if idx then return 500 - idx end -- earlier substring wins
	-- Fuzzy subsequence
	local qi = 1
	for i = 1, #c do
		if qi > #q then break end
		if c:sub(i, i) == q:sub(qi, qi) then qi += 1 end
	end
	if qi > #q then return 100 end
	return -1
end

--[=[
	Compute completions for the current input. Returns a list of suggestions
	with (text, hint) pairs for richer rendering.
	@param input string — the full text in the input box
	@param nexus any — current nexus context (for dynamic providers)
	@return { { text: string, hint: string?, score: number } }
]=]
function ConsoleModule:_GetSmartCompletions(input: string, nexus: any): { { text: string, hint: string?, score: number } }
	-- Tokenize on whitespace; track whether input ends with space (next token starts)
	local tokens = {}
	for word in input:gmatch("%S+") do table.insert(tokens, word) end
	local trailingSpace = input:sub(-1) == " "

	-- Determine current token (the one being typed) and prefix tokens
	local currTokenIdx = if trailingSpace then #tokens + 1 else #tokens
	local currQuery = if trailingSpace then "" else (tokens[#tokens] or "")

	local results = {} :: { { text: string, hint: string?, score: number } }

	if currTokenIdx <= 1 then
		-- Suggest commands
		for name, cmd in pairs(self._registeredCommands) do
			local score = scoreMatch(currQuery, name)
			if score >= 0 then
				table.insert(results, { text = name, hint = cmd.Description, score = score })
			end
		end
	elseif currTokenIdx == 2 then
		-- Suggest subcommands for tokens[1]
		local cmdName = string.lower(tokens[1])
		local subs = (ConsoleModule :: any)._subcommands[cmdName]
		if subs then
			for _, sub in ipairs(subs) do
				local score = scoreMatch(currQuery, sub)
				if score >= 0 then
					table.insert(results, { text = sub, hint = nil, score = score })
				end
			end
		end
	else
		-- Token 3+: use dynamic provider keyed by command.subcommand
		local cmdName = string.lower(tokens[1] or "")
		local subName = string.lower(tokens[2] or "")
		local providerKey = cmdName .. "." .. subName
		local provider = (ConsoleModule :: any)._dynamicProviders[providerKey]
		if provider then
			local ok, candidates = pcall(provider, nexus)
			if ok and type(candidates) == "table" then
				for _, candidate in ipairs(candidates) do
					local score = scoreMatch(currQuery, candidate)
					if score >= 0 then
						table.insert(results, { text = candidate, hint = nil, score = score })
					end
				end
			end
		end
	end

	-- Sort by descending score
	table.sort(results, function(a, b) return a.score > b.score end)
	return results
end

function ConsoleModule:_GetCompletions(partial: string): { string }
	-- Legacy API kept for compatibility — returns only command names matching prefix
	if partial == "" then return {} end
	local matches = {}
	local lower = string.lower(partial)
	for name, _ in pairs(self._registeredCommands) do
		if name:sub(1, #lower) == lower then
			table.insert(matches, name)
		end
	end
	table.sort(matches)
	return matches
end

--[=[
	Highlight the matching prefix or substring within a candidate using RichText.
	@param candidate string
	@param query string
	@return string — RichText-formatted candidate with the match highlighted
]=]
function ConsoleModule:_HighlightMatch(candidate: string, query: string): string
	if query == "" then return candidate end
	local lowerC = string.lower(candidate)
	local lowerQ = string.lower(query)
	local startIdx = lowerC:find(lowerQ, 1, true)
	if not startIdx then return candidate end
	local endIdx = startIdx + #query - 1
	return string.format(
		"%s<u><b>%s</b></u>%s",
		candidate:sub(1, startIdx - 1),
		candidate:sub(startIdx, endIdx),
		candidate:sub(endIdx + 1)
	)
end

-- ══════════════════════════════════════════════════════════════
-- Z-AXIS LAYER BUILDERS
-- ══════════════════════════════════════════════════════════════

--[[
	Build or rebuild the CONSOLE root layer inside the supplied navigator frame.
	Creates the terminal output region, input box, and in-place autocomplete UI.
]]
function ConsoleModule:BuildRootLayer(frame: Frame, context: any)
	local nexus = context.Nexus
	local contentFrame = frame:FindFirstChild("Content") :: Frame
	if not contentFrame then return end

	-- Disable outer ScrollingFrame auto-sizing (console uses absolute layout)
	if contentFrame:IsA("ScrollingFrame") then
		contentFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
		contentFrame.ScrollBarThickness = 0
	end

	-- Idempotent: if already built, just re-render output
	if contentFrame:FindFirstChild("OutputScroll") then
		self:_RenderOutput()
		return
	end

	-- Clear
	for _, child in ipairs(contentFrame:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") then
			child:Destroy()
		end
	end

	-- Terminal background
	contentFrame.BackgroundColor3 = Color3.fromRGB(6, 6, 12)
	contentFrame.BackgroundTransparency = 0

	-- Output scroll area (fills most of the space)
	local outputScroll = Instance.new("ScrollingFrame")
	outputScroll.Name = "OutputScroll"
	outputScroll.Size = UDim2.new(1, -8, 1, -40)
	outputScroll.Position = UDim2.new(0, 4, 0, 2)
	outputScroll.BackgroundTransparency = 1
	outputScroll.BorderSizePixel = 0
	outputScroll.ScrollBarThickness = 4
	outputScroll.ScrollBarImageColor3 = Theme.Colors.Accent
	outputScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	outputScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	outputScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	outputScroll.ZIndex = 8
	outputScroll.Parent = contentFrame
	self._scrollFrame = outputScroll
	-- The previous OutputScroll (if any) was destroyed when the layer's
	-- container frame was rebuilt (e.g., on context switch / NavigateToRoot).
	-- Reset the incremental-render watermark so _RenderOutput() repopulates
	-- the new (empty) scroll from the full buffer instead of bailing out
	-- with "already rendered N" — which previously made the console appear
	-- to be cleared whenever the user toggled context or navigated away
	-- and back.
	self._lastRenderCount = 0

	local outputLayout = Instance.new("UIListLayout")
	outputLayout.SortOrder = Enum.SortOrder.LayoutOrder
	outputLayout.Padding = UDim.new(0, 1)
	outputLayout.Parent = outputScroll

	local outputPad = Instance.new("UIPadding")
	outputPad.PaddingLeft = UDim.new(0, 8)
	outputPad.PaddingRight = UDim.new(0, 8)
	outputPad.PaddingTop = UDim.new(0, 4)
	outputPad.PaddingBottom = UDim.new(0, 4)
	outputPad.Parent = outputScroll

	-- Input bar at bottom
	local inputBar = Instance.new("Frame")
	inputBar.Name = "InputBar"
	inputBar.Size = UDim2.new(1, -8, 0, 32)
	inputBar.Position = UDim2.new(0, 4, 1, -36)
	inputBar.BackgroundColor3 = Theme.Colors.GlassTertiary
	inputBar.BackgroundTransparency = 0.3
	inputBar.BorderSizePixel = 0
	inputBar.ZIndex = 10
	inputBar.Parent = contentFrame

	local inputCorner = Instance.new("UICorner")
	inputCorner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	inputCorner.Parent = inputBar

	local inputStroke = Instance.new("UIStroke")
	inputStroke.Color = Theme.Colors.BorderSubtle
	inputStroke.Thickness = 1
	inputStroke.Transparency = 0.4
	inputStroke.Parent = inputBar

	-- Prompt symbol
	local prompt = Theme.CreateLabel({
		Text = ">",
		Size = UDim2.new(0, 20, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		Color = Theme.Colors.Accent,
		FontSize = Theme.TextSize.Body,
		FontFace = Theme.Font.Mono,
		Parent = inputBar,
	})
	prompt.ZIndex = 11

	-- Text input
	local inputBox = Instance.new("TextBox")
	inputBox.Name = "CommandInput"
	inputBox.Size = UDim2.new(1, -36, 1, -4)
	inputBox.Position = UDim2.new(0, 28, 0, 2)
	inputBox.BackgroundTransparency = 1
	inputBox.Text = ""
	inputBox.PlaceholderText = 'Type a command... (try "help")'
	inputBox.PlaceholderColor3 = Theme.Colors.TextMuted
	inputBox.TextColor3 = Theme.Colors.TextPrimary
	inputBox.TextSize = Theme.TextSize.Body
	inputBox.FontFace = Theme.Font.Mono
	inputBox.TextXAlignment = Enum.TextXAlignment.Left
	inputBox.ClearTextOnFocus = false
	inputBox.BorderSizePixel = 0
	inputBox.ZIndex = 11
	inputBox.Parent = inputBar
	self._inputBox = inputBox

	-- Autocomplete popup
	local acFrame = Instance.new("Frame")
	acFrame.Name = "Autocomplete"
	acFrame.Size = UDim2.new(1, -8, 0, 0)
	acFrame.Position = UDim2.new(0, 4, 1, -36)
	acFrame.BackgroundColor3 = Theme.Colors.GlassOverlay
	acFrame.BackgroundTransparency = 0.05
	acFrame.BorderSizePixel = 0
	acFrame.Visible = false
	acFrame.ZIndex = 20
	acFrame.AutomaticSize = Enum.AutomaticSize.Y
	acFrame.ClipsDescendants = true
	acFrame.Parent = contentFrame
	self._autocompleteFrame = acFrame

	local acCorner = Instance.new("UICorner")
	acCorner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	acCorner.Parent = acFrame

	local acLayout = Instance.new("UIListLayout")
	acLayout.SortOrder = Enum.SortOrder.LayoutOrder
	acLayout.Padding = UDim.new(0, 1)
	acLayout.Parent = acFrame

	-- Wire input events
	inputBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			-- Trim leading/trailing whitespace before executing. Real-world
			-- platform input quirks (held Enter key, IME, focus race after
			-- task.defer(CaptureFocus)) can leave a stray leading space in
			-- the box right after the previous command's Enter — which then
			-- messes up tokenization and autocomplete on the NEXT input.
			-- We never want leading whitespace in a CLI prompt, so strip it.
			local text = inputBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
			inputBox.Text = ""
			self:ExecuteCommand(text, nexus)
			-- Mark that the next focus is the post-Enter recapture, so the
			-- Focused handler can scrub any in-flight character that Roblox
			-- routed to the freshly focused TextBox after CaptureFocus.
			self._postEnterRefocus = true
			-- Re-focus the input box so the user can keep typing commands.
			-- We use task.delay(0) to wait at least one full frame so Roblox's
			-- input pipeline finishes routing the in-flight Enter key BEFORE
			-- the box is re-focused. (task.defer can run in the same frame.)
			task.delay(0, function()
				if inputBox and inputBox.Parent then
					inputBox:CaptureFocus()
				end
			end)
		end
		if self._autocompleteFrame then
			self._autocompleteFrame.Visible = false
		end
	end)

	-- Autocomplete on text change
	inputBox:GetPropertyChangedSignal("Text"):Connect(function()
		-- Defensive: strip any leading whitespace that may appear from
		-- platform input quirks (held Enter key, IME, focus race after
		-- task.defer(CaptureFocus) following the previous Enter). The
		-- console never wants leading whitespace in the command bar; if
		-- it leaks in, autocomplete tokenizes the EMPTY first token and
		-- silently shows no/wrong suggestions until the user notices and
		-- backspaces. Strip silently so the user never sees the glitch.
		if inputBox.Text:sub(1, 1) == " " then
			local cleaned = inputBox.Text:gsub("^%s+", "")
			if cleaned ~= inputBox.Text then
				inputBox.Text = cleaned
				return -- re-fires the signal with the cleaned text; let that pass handle AC
			end
		end
		self:_UpdateAutocomplete(inputBox.Text, nexus)
	end)

	-- History navigation via input service
	if self._inputConnection then
		self._inputConnection:Disconnect()
	end
	self._inputConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if not inputBox:IsFocused() then return end
		local acVisible = self._autocompleteFrame and self._autocompleteFrame.Visible

		if input.KeyCode == Enum.KeyCode.Up then
			if acVisible and #self._acSuggestions > 0 then
				-- Navigate autocomplete up
				self:_AcNavigate(-1)
			else
				-- Navigate history up
				if self._historyIndex > 1 then
					self._historyIndex -= 1
					inputBox.Text = self._commandHistory[self._historyIndex] or ""
					inputBox.CursorPosition = #inputBox.Text + 1
				end
			end
		elseif input.KeyCode == Enum.KeyCode.Down then
			if acVisible and #self._acSuggestions > 0 then
				-- Navigate autocomplete down
				self:_AcNavigate(1)
			else
				-- Navigate history down
				if self._historyIndex < #self._commandHistory then
					self._historyIndex += 1
					inputBox.Text = self._commandHistory[self._historyIndex] or ""
				else
					self._historyIndex = #self._commandHistory + 1
					inputBox.Text = ""
				end
			end
		elseif input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.Return then
			if acVisible and self._acSelectedIndex > 0 and self._acSelectedIndex <= #self._acSuggestions then
				-- Select current autocomplete suggestion
				local selected = self._acSuggestions[self._acSelectedIndex]
				inputBox.Text = selected .. " "
				inputBox.CursorPosition = #inputBox.Text + 1
				if self._autocompleteFrame then self._autocompleteFrame.Visible = false end
				self._acSelectedIndex = 0
			end
		elseif input.KeyCode == Enum.KeyCode.Tab then
			-- Tab completion (single match)
			if acVisible and self._acSelectedIndex > 0 and self._acSelectedIndex <= #self._acSuggestions then
				local selected = self._acSuggestions[self._acSelectedIndex]
				inputBox.Text = selected .. " "
				inputBox.CursorPosition = #inputBox.Text + 1
				if self._autocompleteFrame then self._autocompleteFrame.Visible = false end
				self._acSelectedIndex = 0
			else
				local completions = self:_GetCompletions(inputBox.Text)
				if #completions == 1 then
					inputBox.Text = completions[1] .. " "
					inputBox.CursorPosition = #inputBox.Text + 1
				end
			end
		elseif input.KeyCode == Enum.KeyCode.Escape then
			if acVisible then
				if self._autocompleteFrame then self._autocompleteFrame.Visible = false end
				self._acSelectedIndex = 0
			end
		end
	end)

	-- Focus styling + post-Enter recapture cleanup
	inputBox.Focused:Connect(function()
		TweenService:Create(inputStroke, Theme.Tween.Fast, { Color = Theme.Colors.Accent, Transparency = 0 }):Play()
		-- If this Focused fire is from the post-Enter recapture, scrub any
		-- leading whitespace that Roblox routed to the box from the in-flight
		-- Enter/Return key event. We have to wait one frame because the
		-- character insertion happens AFTER Focused fires (Roblox processes
		-- the queued key event against the freshly focused box). The
		-- property-changed signal sometimes doesn't fire for this internal
		-- platform-injected character, so we check Text directly here.
		if self._postEnterRefocus then
			self._postEnterRefocus = false
			-- Wait two render frames: one for Roblox's input pipeline to
			-- finish, one for safety. Then hard-clear any leading whitespace.
			task.delay(0, function()
				task.delay(0, function()
					if inputBox and inputBox.Parent and inputBox.Text:match("^%s") then
						inputBox.Text = inputBox.Text:gsub("^%s+", "")
					end
				end)
			end)
		end
	end)
	inputBox.FocusLost:Connect(function()
		TweenService:Create(inputStroke, Theme.Tween.Fast, { Color = Theme.Colors.BorderSubtle, Transparency = 0.4 }):Play()
	end)

	-- Render existing output
	self:_RenderOutput()
end

function ConsoleModule:_UpdateAutocomplete(text: string, nexus: any)
	local acFrame = self._autocompleteFrame
	if not acFrame then return end

	-- Clear existing
	for _, child in ipairs(acFrame:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
		if child:IsA("TextLabel") and child.Name == "AcCount" then child:Destroy() end
	end
	table.clear(self._acButtons)

	if text == "" then
		acFrame.Visible = false
		self._acSuggestions = {}
		self._acSelectedIndex = 0
		return
	end

	-- Use smart position-aware completions
	local rich = self:_GetSmartCompletions(text, nexus)
	-- Maintain legacy `_acSuggestions` as flat string list for keyboard nav
	local completions = {}
	for _, item in ipairs(rich) do
		table.insert(completions, item.text)
	end

	if #completions == 0 then
		acFrame.Visible = false
		self._acSuggestions = {}
		self._acSelectedIndex = 0
		return
	end

	-- Determine the current token/query for prefix highlighting
	local tokens = {}
	for word in text:gmatch("%S+") do table.insert(tokens, word) end
	local trailingSpace = text:sub(-1) == " "
	local currQuery = if trailingSpace then "" else (tokens[#tokens] or "")

	self._acSuggestions = completions
	self._acSelectedIndex = 0
	acFrame.Visible = true

	-- Position above the input bar
	local visibleCount = math.min(#completions, 6)
	local height = visibleCount * 24 + 16 -- +16 for count badge
	acFrame.Position = UDim2.new(0, 4, 1, -36 - height - 4)

	-- Count badge ("3 of 14")
	local countLbl = Instance.new("TextLabel")
	countLbl.Name = "AcCount"
	countLbl.Size = UDim2.new(1, 0, 0, 14)
	countLbl.BackgroundTransparency = 1
	countLbl.Text = string.format("  %d of %d", visibleCount, #completions)
	countLbl.TextColor3 = Theme.Colors.TextMuted
	countLbl.TextSize = Theme.TextSize.Tiny
	countLbl.FontFace = Theme.Font.Mono
	countLbl.TextXAlignment = Enum.TextXAlignment.Left
	countLbl.LayoutOrder = 0
	countLbl.ZIndex = 21
	countLbl.Parent = acFrame

	for i, item in ipairs(rich) do
		if i > 6 then break end
		local highlighted = self:_HighlightMatch(item.text, currQuery)
		local hint = item.hint and ("  <font color=\"#666\">— " .. item.hint .. "</font>") or ""

		local acBtn = Instance.new("TextButton")
		acBtn.Size = UDim2.new(1, 0, 0, 24)
		acBtn.BackgroundColor3 = Theme.Colors.GlassTertiary
		acBtn.BackgroundTransparency = 0.5
		acBtn.Text = string.format("  %s%s", highlighted, hint)
		acBtn.TextColor3 = Theme.Colors.TextSecondary
		acBtn.TextSize = Theme.TextSize.Caption
		acBtn.FontFace = Theme.Font.Mono
		acBtn.TextXAlignment = Enum.TextXAlignment.Left
		acBtn.AutoButtonColor = false
		acBtn.BorderSizePixel = 0
		acBtn.LayoutOrder = i
		acBtn.ZIndex = 21
		acBtn.RichText = true
		acBtn.Parent = acFrame

		self._acButtons[i] = acBtn

		local capturedIndex = i
		local capturedText = item.text
		acBtn.MouseButton1Click:Connect(function()
			if self._inputBox then
				-- Replace just the current token with the selected text
				local before = ""
				if not trailingSpace and #tokens > 0 then
					-- Keep all tokens except last
					for ti = 1, #tokens - 1 do
						before = before .. tokens[ti] .. " "
					end
				else
					-- Keep all tokens
					for _, tok in ipairs(tokens) do
						before = before .. tok .. " "
					end
				end
				self._inputBox.Text = before .. capturedText .. " "
				self._inputBox.CursorPosition = #self._inputBox.Text + 1
				self._inputBox:CaptureFocus()
			end
			acFrame.Visible = false
			self._acSelectedIndex = 0
		end)

		acBtn.MouseEnter:Connect(function()
			self:_AcHighlight(self._acSelectedIndex, false)
			self._acSelectedIndex = capturedIndex
			self:_AcHighlight(capturedIndex, true)
		end)
		acBtn.MouseLeave:Connect(function()
			self:_AcHighlight(capturedIndex, false)
		end)
	end
end

function ConsoleModule:_AcNavigate(direction: number)
	local count = math.min(#self._acSuggestions, 6)
	if count == 0 then return end

	local oldIndex = self._acSelectedIndex
	local newIndex = self._acSelectedIndex + direction

	if newIndex < 1 then
		newIndex = count
	elseif newIndex > count then
		newIndex = 1
	end

	self:_AcHighlight(oldIndex, false)
	self._acSelectedIndex = newIndex
	self:_AcHighlight(newIndex, true)
end

function ConsoleModule:_AcHighlight(index: number, highlighted: boolean)
	local btn = self._acButtons[index]
	if not btn then return end

	if highlighted then
		btn.BackgroundTransparency = 0.15
		btn.TextColor3 = Theme.Colors.Accent
	else
		btn.BackgroundTransparency = 0.5
		btn.TextColor3 = Theme.Colors.TextSecondary
	end
end

function ConsoleModule:_RenderOutput()
	local scroll = self._scrollFrame
	if not scroll then return end

	if self._needsFullRender or #self._outputBuffer < self._lastRenderCount then
		for _, child in ipairs(scroll:GetChildren()) do
			if child:IsA("TextLabel") then child:Destroy() end
		end
		self._lastRenderCount = 0
		self._needsFullRender = false
	end

	-- Only render new lines since last render (incremental)
	local startIndex = self._lastRenderCount + 1
	if startIndex > #self._outputBuffer then
		return
	end

	for i = startIndex, #self._outputBuffer do
		local line = self._outputBuffer[i]
		local lbl = Instance.new("TextLabel")
		lbl.Name = "Line_" .. tostring(i)
		lbl.Size = UDim2.new(1, 0, 0, 0)
		lbl.AutomaticSize = Enum.AutomaticSize.Y
		lbl.BackgroundTransparency = 1
		lbl.Text = line.Text
		lbl.TextColor3 = line.Color
		lbl.TextSize = Theme.TextSize.Caption
		lbl.FontFace = Theme.Font.Mono
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.TextWrapped = true
		lbl.RichText = true
		lbl.LayoutOrder = i
		lbl.ZIndex = 9
		lbl.Parent = scroll
	end

	self._lastRenderCount = #self._outputBuffer

	-- Auto-scroll to bottom. Wait one frame so UIListLayout has a chance
	-- to compute AbsoluteCanvasSize for the new lines, then clamp to max
	-- via math.huge (Roblox clamps automatically).
	task.defer(function()
		if scroll and scroll.Parent then
			scroll.CanvasPosition = Vector2.new(0, math.huge)
		end
	end)
end

--[[
	Disconnect console input listeners and clear terminal state.
]]
function ConsoleModule:Destroy()
	if self._inputConnection then
		self._inputConnection:Disconnect()
		self._inputConnection = nil
	end
	table.clear(self._outputBuffer)
	table.clear(self._commandHistory)
	table.clear(self._registeredCommands)
	self._scrollFrame = nil
	self._inputBox = nil
	self._autocompleteFrame = nil
	self._needsFullRender = false
	table.clear(self._acButtons)
	table.clear(self._acSuggestions)
end

return ConsoleModule
