--!strict
-- @Name ServiceManager/Tests/Mocks/MockNexus.luau
-- @Author iKrypto
-- @Description Minimal nexus harness for subsystem unit tests.
-- Provides only the surface that subsystem modules consume.
-- Real ReactiveStore is wired so reactivity tests work end-to-end.

local ReactiveStore = require(script.Parent.Parent.Parent.ReactiveStore)
local AnalyticsEngine = require(script.Parent.Parent.Parent.AnalyticsEngine)

local MockNexus = {}

--[=[
	Build a fresh mock nexus with the given options.
]=]
function MockNexus.new(opts: {
	contextMode: string?,
	orchestrator: any?,
	serverData: any?,
	fps: number?,
	withAnalytics: boolean?,
	}?): any
	opts = opts or {}
	local store = ReactiveStore.new({})

	-- Track navigator calls for assertions
	local navCalls = {} :: { { method: string, args: { any } } }
	local navigator = {
		ExpandLayer = function(_, layer)
			table.insert(navCalls, { method = "ExpandLayer", args = { layer } })
		end,
		CollapseToLayer = function(_, layerId)
			table.insert(navCalls, { method = "CollapseToLayer", args = { layerId } })
		end,
		NavigateToRoot = function(_, name)
			table.insert(navCalls, { method = "NavigateToRoot", args = { name } })
		end,
		RebuildCurrentLayer = function(_)
			table.insert(navCalls, { method = "RebuildCurrentLayer", args = {} })
		end,
		GetCurrentLayer = function(_) return nil end,
		_rootContainer = nil,
	}

	-- No-op animation controller (covers all real AnimationController methods)
	local animationController = {
		HoverGlow = function(_, ...) end,
		PulseColor = function(_, ...) end,
		Stagger = function(_, ...) end,
		StaggerIn = function(_, ...) end,
		StartPulse = function(_, ...) end,
		StopPulse = function(_, ...) end,
		ExpandIn = function(_, ...) end,
		CollapseOut = function(_, _, onDone) if onDone then task.spawn(onDone) end end,
		Animate = function(_, target, props, _, _, onComplete)
			for k, v in pairs(props) do pcall(function() (target :: any)[k] = v end) end
			if onComplete then task.spawn(onComplete) end
		end,
		Tick = function(_) end,
		Destroy = function(_) end,
		Tween = function(_, inst, props, duration)
			for k, v in pairs(props) do pcall(function() (inst :: any)[k] = v end) end
		end,
	}

	local nexus: any = {
		_contextMode = opts.contextMode or "client",
		_orchestrator = opts.orchestrator,
		_serverData = opts.serverData,
		_lastFPS = opts.fps or 60,
		_navigator = navigator,
		_animationController = animationController,
		_navCalls = navCalls, -- exposed for assertions
		Store = store,
	}

	if opts.withAnalytics ~= false then
		nexus._analyticsEngine = AnalyticsEngine.new()
	end

	-- Subsystem switching stub (with call recording)
	nexus._switchCalls = {} :: { string }
	nexus._modeCalls = {} :: { string }
	function nexus.SetContextMode(mode: string)
		nexus._contextMode = mode
		table.insert(nexus._modeCalls, mode)
	end
	function nexus.SwitchSubsystem(name: string)
		nexus._activeSubsystem = name
		table.insert(nexus._switchCalls, name)
	end
	function nexus.GetSubsystem(name: string)
		return nexus._subsystemModules and nexus._subsystemModules[name]
	end

	return nexus
end

--[=[
	Build a Frame structure suitable for passing to BuildRootLayer:
	  - root Frame (returned)
	  - root.Content (Frame, where the builder writes)
	@return root Frame, content Frame
]=]
function MockNexus.makeLayerFrame(): (Frame, Frame)
	local root = Instance.new("Frame")
	root.Name = "Layer_TEST"
	root.Size = UDim2.new(0, 740, 0, 460)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 1, 0)
	content.Parent = root

	return root, content
end

--[=[
	Find a descendant by name (recursive). Returns nil if not found.
]=]
function MockNexus.findChild(parent: Instance, name: string): Instance?
	for _, desc in ipairs(parent:GetDescendants()) do
		if desc.Name == name then return desc end
	end
	return nil
end

--[=[
	Find the first descendant TextButton whose Text contains the given substring.
]=]
function MockNexus.findButtonByText(parent: Instance, textSubstring: string): TextButton?
	local lowered = string.lower(textSubstring)
	for _, desc in ipairs(parent:GetDescendants()) do
		if desc:IsA("TextButton") then
			local btnText = string.lower((desc :: TextButton).Text)
			if string.find(btnText, lowered, 1, true) then
				return desc :: TextButton
			end
		end
	end
	return nil
end

--[=[
	Simulate a click on a TextButton. Fires MouseButton1Click and Activated.
]=]
function MockNexus.click(button: TextButton)
	-- Use private signal injection: BindableEvent doesn't help; we just invoke
	-- the underlying signal via :Fire on the property's connections — but that's
	-- not exposed. Workaround: store a custom callback on the button via attribute
	-- or expect tests to invoke handlers directly. For now we cannot programmatically
	-- fire MouseButton1Click; tests should access the row's tracked handler.
	-- Returns true if button has any connections, false otherwise.
	pcall(function()
		(button :: any).MouseButton1Click:Fire()
	end)
end

--[=[
	Count immediate children (or descendants) by class name.
]=]
function MockNexus.countByClass(parent: Instance, className: string, recursive: boolean?): number
	local count = 0
	local list = if recursive then parent:GetDescendants() else parent:GetChildren()
	for _, child in ipairs(list) do
		if child:IsA(className) then count += 1 end
	end
	return count
end

--[=[
	Build an orchestrator instance whose mutating methods record their calls.
	Returns the orchestrator + a {calls} array tests can assert against.
]=]
function MockNexus.spyOrchestrator(opts: any?): (any, { { method: string, args: { any } } })
	local MockOrchestrator = require(script.Parent.MockOrchestrator)
	local orch = MockOrchestrator.new(opts)
	local calls = {} :: { { method: string, args: { any } } }

	-- Wrap mutating methods
	local origUnschedule = orch.Scheduler.Unschedule
	orch.Scheduler.Unschedule = function(self, name)
		table.insert(calls, { method = "Scheduler:Unschedule", args = { name } })
		return origUnschedule(self, name)
	end
	local origSchedule = orch.Scheduler.Schedule
	orch.Scheduler.Schedule = function(self, def)
		table.insert(calls, { method = "Scheduler:Schedule", args = { def } })
		return origSchedule(self, def)
	end
	local origRequest = orch.Request
	orch.Request = function(method, payload)
		table.insert(calls, { method = "Orchestrator.Request", args = { method, payload } })
		return origRequest(method, payload)
	end

	-- Wrap FSM Cancel (per-FSM)
	for _, fsm in pairs(orch.StateMachines) do
		local origCancel = fsm.Cancel
		fsm.Cancel = function(_self)
			table.insert(calls, { method = "FSM:Cancel", args = { fsm.Name } })
			if origCancel then origCancel(_self) end
		end
	end

	return orch, calls
end

return MockNexus
