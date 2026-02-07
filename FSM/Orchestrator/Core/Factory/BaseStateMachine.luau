--!strict
-- @Name BaseStateMachine
-- @Author iKrypto
-- @Description Abstract Base State Machine class for managing states and transitions in a StateMachine system.

local RunService = game:GetService("RunService")

local BaseStateMachine = {}

local Logger, Signal, Settings, Initialized;
function BaseStateMachine.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Settings = Util.Settings
	Logger = Util.Logger.new({ Name = "BaseStateMachine" })
	Signal = Util.Signal

	Logger:Log({ Level = "INFO", Message = "BaseStateMachine initialized" })
end

-- Metamethods for property syntax (fsm.State = "Name")
local function __index(t, k)
	if k == "State" then return rawget(t, "_state") end
	-- Support inheritance by looking up the key in the class (metatable) 
	local mt = getmetatable(t :: any) :: any
	if mt then
		local classMember = mt[k]
		if classMember then return classMember end
	end

	local context = rawget(t, "Context")
	if context and context[k] ~= nil then
		return context[k]
	end

	return rawget(t, k)
end
local function __newindex(t, k, v) 
	if k == "State" and type(v) == "string" then
		t:ChangeState({ Name = v, Args = t.Context and table.clone(t.Context) or nil })
		return
	end
	rawset(t, k, v) 
end

BaseStateMachine.__index = __index
BaseStateMachine.__newindex = __newindex
BaseStateMachine.__tostring = function(self)
	return string.format("BaseStateMachine(%s) %s : [%s]", self.Id or "-id-", self.Name or "-name-", self.State or "-state-")
end

-- Standard Priority Levels
BaseStateMachine.Priorities = {
	Render = 1,      -- Runs every frame
	High = 2,        -- Runs every 2 frames
	Medium = 5,      -- Runs every 5 frames
	Low = 10,        -- Runs every 10 frames
	Background = 30, -- Runs every 30 frames (0.5s at 60fps)
}

-- Centralized update loop variables
local ActiveMachines = {} :: { [any]: boolean }
local GlobalHeartbeat: RBXScriptConnection? = nil
local GlobalFrameCount = 0

-- Types are now imported from Types.luau

--[[
	@description Creates a new BaseStateMachine instance.
	@param params { Id: string, Name: string, ValidStates: { string }?, TerminalStates: { string }?, Context: any?, Priority: number? }
	@return BaseStateMachine
]]
function BaseStateMachine.new(params: { Id: string, Name: string, ValidStates: {string}?, TerminalStates: {string}?, InitialState: string?, Context: any?, Priority: number? })
	local self = setmetatable({}, BaseStateMachine)

	self.Id = params.Id
	self.Name = params.Name or "BaseStateMachine"
	self.Logger = (Logger and Logger.new({ Name = self.Name })) or error("BaseStateMachine: Logger not initialized. Did you call BaseStateMachine.Initialize(Util)?")
	self.Context = params.Context or {}

	self.Priority = params.Priority or BaseStateMachine.Priorities.Render
	self._offset = math.random(0, self.Priority - 1)
	self._accumulatedDt = 0
	self._states = {} :: { [string]: any }
	self._transitions = {} :: { [string]: {string} }
	self._cleanupTasks = {} :: { any }
	self._legacyCleanup = {} :: {[(() -> ())?]: any}?
	self._connection = nil :: RBXScriptConnection?

	self.CurrentState = nil :: any?
	self.State = nil :: string?
	self.StateDuration = 0
	self.TotalDuration = 0
	self.WaitSpan = 0
	self.TransitionCount = 0
	self._transitionId = 0

	self.validStates = {} :: { [string]: boolean }
	local validStatesList = params.ValidStates or (params :: any).validStates
	if validStatesList then
		for _, stateName in ipairs(validStatesList) do
			self.validStates[stateName] = true
		end
	end

	self.TerminalStates = {} :: { [string]: boolean }
	self._terminalStateNames = {} :: { string }
	local terminalStatesList = params.TerminalStates or (params :: any).terminalStates
	if terminalStatesList then
		for _, stateName in ipairs(terminalStatesList) do
			if not self.validStates[stateName] then
				self.Logger:Log({
					Level = "WARN",
					Message = string.format("TerminalState '%s' is not in ValidStates.", stateName)
				})
				continue
			end
			self.TerminalStates[stateName] = true
			table.insert(self._terminalStateNames, stateName)
		end
	end

	self.IsActive = false
<<<<<<< HEAD
	self.initialState = params.InitialState or (validStatesList and validStatesList[1]) or nil

	if self.initialState and next(self.validStates) and not self.validStates[self.initialState] then
		self.Logger:Log({
			Level = "WARN",
			Message = string.format("InitialState '%s' is not in ValidStates.", self.initialState)
		})
		self.initialState = nil
=======
	self.InitialState = params.InitialState or (validStatesList and validStatesList[1]) or nil

	if self.InitialState and next(self.validStates) and not self.validStates[self.InitialState] then
		self.Logger:Log({
			Level = "WARN",
			Message = string.format("InitialState '%s' is not in ValidStates.", self.InitialState)
		})
		self.InitialState = nil
>>>>>>> master
	end

	self._completed = (Signal and Signal.new()) or error("BaseStateMachine: Signal not initialized. Did you call BaseStateMachine.Initialize(Util)?")
	self._failed = (Signal and Signal.new()) or error("BaseStateMachine: Signal not initialized. Did you call BaseStateMachine.Initialize(Util)?")
	self._cancelled = (Signal and Signal.new()) or error("BaseStateMachine: Signal not initialized. Did you call BaseStateMachine.Initialize(Util)?")
	self._stateChanged = (Signal and Signal.new()) or error("BaseStateMachine: Signal not initialized. Did you call BaseStateMachine.Initialize(Util)?")

	self.Completed = self._completed
	self.Failed = self._failed
	self.Cancelled = self._cancelled
	self.StateChanged = self._stateChanged
	return self
end

local function isTerminalState(self: any, stateName: string): boolean
	local setTable = rawget(self, "TerminalStates")
	if type(setTable) == "table" and setTable[stateName] == true then
		return true
	end
	local listTable = rawget(self, "_terminalStateNames")
	if type(listTable) == "table" then
		for _, name in ipairs(listTable) do
			if name == stateName then
				return true
			end
		end
	end
	return false
end

--[[
	@description Creates a BaseStateMachine subclass (class table) from a definition.
	@param extensionParams { className: string, validStates: { string }?, terminalStates: { string }?, context: { [any]: any }?, Priority: number? }
	@return any -- Subclass (class table) with a .new constructor
]]
function BaseStateMachine.Extend(extensionParams: {className: string, validStates: {string}?, terminalStates: {string}?, InitialState: string?, context: { [any]: any }?, Priority: number?})
	-- This is the Class Table (where methods like MyClass:Method() will live)
	local Subclass = {}
	Subclass.Definition = extensionParams

	-- Static inheritance: make Subclass inherit from BaseStateMachine
	setmetatable(Subclass, { __index = BaseStateMachine })

	--[[
		@description Creates a new instance of this subclass StateMachine.
		@param ... any -- Typically a single table containing { Id/StateMachineId, ...context }
		@return BaseStateMachine
	]]
	function Subclass.new(...)
		local fsmArguments = {...}
		local ctorArgs = fsmArguments[1] or {} :: any
		-- Create the instance data using the base constructor
		-- We use dot syntax here to ensure we get the raw table structure from Base
		local newInstance = BaseStateMachine.new({
			Id = ctorArgs.Id or ctorArgs.StateMachineId,
			Name = extensionParams.className,
			ValidStates = extensionParams.validStates or extensionParams.ValidStates,
			TerminalStates = extensionParams.terminalStates or extensionParams.TerminalStates,
			InitialState = extensionParams.InitialState or extensionParams.initialState or (extensionParams.validStates and extensionParams.validStates[1]) or nil,
			Context = ctorArgs,
			Priority = extensionParams.Priority or BaseStateMachine.Priorities.Render
		})

		-- Define the metatable for this specific instance
		local instanceMetatable = {
			-- Custom __index to handle Context shortcuts and Inheritance
			__index = function(t, k)
				-- A. State Shortcut
				if k == "State" then 
					return rawget(t, "_state") 
				end

				if k:lower() == "super" then
					return BaseStateMachine;
				end

				-- B. Class Member Lookup (Subclass -> BaseClass)
				-- We look up 'k' in the Subclass table. 
				-- Because Subclass has a metatable pointing to BaseStateMachine, 
				-- this covers both Subclass methods AND BaseStateMachine methods.
				local classMember = Subclass[k]
				if classMember then
					return classMember
				end

				-- C. Context Shortcut
				-- Check if the key exists in the internal Context table
				local context = rawget(t, "Context")
				if context and context[k] ~= nil then
					return context[k]
				end

				-- D. Fallback (usually nil, unless rawget finds something ignored above)
				return nil
			end,
			__newindex = function(t, k, v)
				if k == "State" and type(v) == "string" then
					t:ChangeState({ Name = v })
				else
					rawset(t, k, v)
				end
			end,
			-- Custom tostring
			__tostring = function(self)
				return string.format("%s(%s) %s : [%s]", 
					extensionParams.className or "BaseStateMachine", 
					self.Id or "-id-", 
					self.Name or "-name-", 
					self.State or "-state-"
				)
			end
		}

		-- A. SETUP METATABLE FIRST
		setmetatable(newInstance :: any, instanceMetatable)

		-- B. NOW REGISTER STATES (Object now recognizes overrides)
		if newInstance.RegisterStates then
			newInstance.RegisterStates(newInstance)
		else
			newInstance.Logger:Log({ 
				Level = "WARN", 
				Message = string.format("Subclass '%s' did not implement 'RegisterStates'.", extensionParams.className),
				OperationId = newInstance.Id 
			})
		end

		return newInstance
	end

	return Subclass
end

--[[
	@description Registers a new state definition with the StateMachine.
	@param name string
	@param state any
	@param validOutcomes { string }?
	@return ()
]]
function BaseStateMachine:AddState(name: string, state: any, validOutcomes: {string}?)
	if next(self.validStates) and not self.validStates[name] then
		self.Logger:Log
		{ 
			Level = "ERROR", 
			Message = string.format("State '%s' is not in the validStates list.", name), 
			OperationId = self.Id 
		}
		return
	end
	self._states[name] = state
	self._transitions[name] = validOutcomes or {}
end

--[[
	@description Registers a state that wraps another StateMachine.
	@param name string
	@param subMachineClass any -- The StateMachine class definition
	@param config any
	@return ()
]]
function BaseStateMachine:AddSubMachine(name: string, subMachineClass: any, config: any)
	local subMachineState = {}:: any;
	local transitions = config.Transitions;
	local initialSubState = config.InitialState;
	local storeReference = config.StoreReference; -- Uses config.StoreReference as defined in type

	local FailureMessage = (if not transitions then 
		"AddSubMachine called without transitions configuration."
		elseif not initialSubState then
		"AddSubMachine called without initial sub-state configuration."
		else 
		"");

	if FailureMessage ~= "" then
		self.Logger:Log
		{ 
			Level = "ERROR", 
			Message = FailureMessage, 
			OperationId = self.Id 
		}
		return
	end

	function subMachineState:OnEnter(fsm)
		self._connections = {}
		self.Machine = subMachineClass.new({
			StateMachineId = fsm.Id::string .. "." .. name,
			Context = fsm.Context -- Shared context allows data passing
		})

		-- Store reference in context if requested
		if storeReference then
			fsm.Context[storeReference] = self.Machine
		end

		-- Handle Completion
		table.insert(self._connections, self.Machine.Completed:Connect(function()
			if transitions.OnCompleted then
				fsm.State = transitions.OnCompleted
			else
				fsm:Finish() -- Default: Propagate completion up
			end
		end))

		-- Handle Failure
		table.insert(self._connections, self.Machine.Failed:Connect(function(reason)
			if transitions.OnFailed then
				fsm.State = transitions.OnFailed
			else
				fsm:Fail(reason) -- Default: Propagate failure up
			end
		end))

		-- Handle Cancellation
		table.insert(self._connections, self.Machine.Cancelled:Connect(function()
			if transitions.OnCancelled then
				fsm.State = transitions.OnCancelled
			else
				fsm:Cancel() -- Default: Propagate cancellation up
			end
		end))

		self.Machine:Start({ State = initialSubState})
	end

	function subMachineState:OnLeave(fsm)
		if self._connections then
			for _, conn in ipairs(self._connections) do
				conn:Disconnect()
			end
			self._connections = nil
		end
		if self.Machine and self.Machine.IsActive then
			self.Machine:Cancel()
		end
		self.Machine = nil
	end

	local validOutcomes = {}
	if transitions.OnCompleted then table.insert(validOutcomes, transitions.OnCompleted) end
	if transitions.OnFailed then table.insert(validOutcomes, transitions.OnFailed) end
	if transitions.OnCancelled then table.insert(validOutcomes, transitions.OnCancelled) end

	self:AddState(name, subMachineState, validOutcomes)
end

--[[
	@description Registers a disposable object for cleanup when the FSM is destroyed.
	@param object any
	@return any
]]
function BaseStateMachine:Manage(object: any)
	table.insert(self._cleanupTasks, object)
	return object
end

-- RUNTIME

--[[
	@description Disables the internal RunService connection, allowing external drivers (like a Scheduler) to call Step().
	@return ()
]]
function BaseStateMachine.DisableInternalLoop()
	if GlobalHeartbeat then
		GlobalHeartbeat:Disconnect()
		GlobalHeartbeat = nil
	end
	BaseStateMachine._ExternalLoop = true
end

--[[
	@description Manual step function to drive the StateMachine updates.
	@param dt number
	@return ()
]]
function BaseStateMachine.Step(dt: number)
	GlobalFrameCount += 1
	for machine in pairs(ActiveMachines) do
		if machine.IsActive then
			-- Accumulate delta time for skipped frames
			machine._accumulatedDt += dt

			if (GlobalFrameCount + machine._offset) % machine.Priority == 0 then
				local stepDt = machine._accumulatedDt
				machine._accumulatedDt = 0
				-- OPTIMIZATION: Run Render priority inline to avoid task.spawn overhead
				-- This requires Render priority state machines to NOT yield.
				if machine.Priority == 1 then
					local success, err = xpcall(function()
						machine:_Update(stepDt)
					end, function(e) return debug.traceback(tostring(e)) end)
					if not success then
						machine.Logger:Log({ 
							Level = "ERROR", 
							Message = string.format("Runtime Error in %s: %s", machine.Name, tostring(err)), 
							OperationId = machine.Id 
						})
					end
				else
					-- Isolate errors to prevent one machine from crashing the loop
					local success, err = xpcall(function() task.spawn(machine._Update, machine, stepDt) end, function(e) return debug.traceback(tostring(e)) end)
					if not success then
						machine.Logger:Log({ 
							Level = "ERROR", 
							Message = string.format("Runtime Error in %s: %s", machine.Name, tostring(err)), 
							OperationId = machine.Id 
						})
					end
				end
			end
		end
	end
end

--[[
	@description Begins execution of the StateMachine.
	@param params { State: string, Args: { any }? }
	@return ()
]]
function BaseStateMachine:Start(params: { State: string?, Args: {any}? }?)
	if self.IsActive then return end
	self.IsActive = true
	local startParams = params or {}
	
	local startState = startParams.State or self.InitialState
	if not startState then
		-- validation already warned if InitialState was bad, but if it's nil entirely:
		self.Logger:Log({ Level = "ERROR", Message = "No Start State provided and no InitialState defined." })
		self.IsActive = false
		return
	end

	-- self.InitialState is just a property, we don't necessarily overwrite it here unless we want to track "what it started with this time"
	-- effectively current runtime initial state
	-- self.InitialState = startState
	-- Register to centralized loop
	ActiveMachines[self] = true
	if not GlobalHeartbeat and not BaseStateMachine._ExternalLoop then
		GlobalHeartbeat = RunService.Heartbeat:Connect(BaseStateMachine.Step)
	end

	self.Logger:Log
	{ 
		Level = "DEBUG", 
		Message = "StateMachine Started. Initial State: " .. tostring(startState), 
		OperationId = self.Id 
	}

	self:ChangeState
	{ 
		Name = startState, 
		Args = startParams.Args 
	}
end

--[[
	@description Internal update step called by the centralized loop.
	@param dt number
	@return ()
]]
function BaseStateMachine:_Update(dt: number)
	if not self.IsActive then return end

	self.TotalDuration += dt
	self.StateDuration += dt

	-- Call OnHeartbeat for object-based states
	local currentState = self.CurrentState
	if typeof(currentState) == "table" then
		if currentState.Transitions then
			for _, transition in ipairs(currentState.Transitions) do
				if transition.Condition(self, dt) then
					self:ChangeState({ Name = transition.TargetState, Args = transition.Args })
					return
				end
			end
		end
		if currentState.OnHeartbeat then
			currentState:OnHeartbeat(self, dt)
		end
	end
end

--[[
	@description Transitions the StateMachine to a new state.
	@param params { Name: string, Args: { any }? }
	@return ()
]]
function BaseStateMachine:ChangeState(params: { Name: string, Args: {any}? })
	if not self.IsActive then return end

	local name = params.Name
	local args = params.Args or {}

	-- Handle WaitSpan Delay
	local delay = self.WaitSpan
	self.WaitSpan = 0 -- Reset immediately

	if delay > 0 then
		self._transitionId += 1
		local transitionId = self._transitionId
		task.delay(delay, function()
			if self.IsActive and self._transitionId == transitionId then
				self:ChangeState({ Name = name, Args = args })
			end
		end)
		return
	end

	if next(self.validStates) and not self.validStates[name] then
		self.Logger:Log
		{ 
			Level = "ERROR", 
			Message = string.format("Cannot transition to state '%s': Not in validStates.", name), 
			OperationId = self.Id 
		}
		return
	end

	-- Invalidate any pending delayed transitions regardless of current state
	self._transitionId += 1

	-- Validate Transition
	if self.State then

		local allowed = self._transitions[self.State]
		if allowed and #allowed > 0 then
			local isLegal = false
			for _, outcome in ipairs(allowed) do
				if outcome == name then isLegal = true; break end
			end
			if not isLegal then
				self.Logger:Log
				{ 
					Level = "ERROR", 
					Message = string.format("Illegal transition from '%s' to '%s'", self.State, name), 
					OperationId = self.Id 
				}
				return
			end
		end

		local duration = math.floor(self.StateDuration * 1000) / 1000
		self.Logger:Log
		{ 
			Level = "DEBUG", 
			Message = string.format("Leaving '%s' (Duration: %.3fs)", tostring(self.State), duration), 
			OperationId = self.Id 
		}

		-- Execute OnLeave for the previous state
		if typeof(self.CurrentState) == "table" and self.CurrentState.OnLeave then
			self.CurrentState:OnLeave(self)
		end
	end

	local newState = self._states[name]

	-- Allow implicit terminal states (defined below) even if not registered
	if not newState and not self.TerminalStates[name] then 
		self.Logger:Log
		{ 
			Level = "ERROR", 
			Message = string.format("State '%s' is not registered in the FSM.", name), 
			OperationId = self.Id 
		}
		return 
	end

	-- Update Transition Count
	if name == self.State then
		self.TransitionCount += 1
	else
		self.Logger:Log
		{ 
			Level = "DEBUG", 
			Message = string.format("Transition: '%s' -> '%s'", tostring(self.State), name), 
			OperationId = self.Id 
		}

		self.StateDuration = 0
		self.TransitionCount = 1
	end

	-- Enter New State
	local oldStateName = self.State
	rawset(self, "_state", name)
	self._stateChanged:Fire(name, oldStateName)
	self.CurrentState = newState

	if self.CurrentState then
		if typeof(self.CurrentState) == "table" then
			-- It's a state object, call OnEnter
			if type(self.CurrentState.OnEnter) == "function" then
				self.CurrentState:OnEnter(self, table.unpack(args))
				self.Logger:Log
				{ 
					Level = "DEBUG", 
					Message = string.format("Entered state object '%s'.", name), 
					OperationId = self.Id 
				}
			end
		elseif typeof(self.CurrentState) == "function" then
			-- It's a legacy state function
			local cleanupFunction = self.CurrentState(self, table.unpack(args))
			if type(cleanupFunction) == "function" then
				if oldStateName ~= self.State then -- Only register if state didn't change during execution
					local Success, Result = pcall(cleanupFunction)

					if not Success then
						self.Logger:Log
						{ 
							Level = "ERROR", 
							Message = string.format("Error in cleanup function for state '%s': %s", name, tostring(Result)), 
							OperationId = self.Id 
						}
					else
						self.Logger:Log
						{ 
							Level = "DEBUG", 
							Message = string.format("Executed cleanup function for state '%s'.", name), 
							OperationId = self.Id 
						}
					end
				end
			else
				self.Logger:Log
				{ 
					Level = "DEBUG", 
					Message = string.format("State '%s' returned a non-function cleanup handler.", name), 
					OperationId = self.Id 
				}
			end
		end
	end

	-- Auto-Finish Terminal States
	-- Any state listed in TerminalStates is considered an end-state.
	-- Default behavior is to Complete unless explicitly Failed/Cancelled.
	if isTerminalState(self, name) then
		if name == "Failed" then
			self:Fail()
		elseif name == "Cancelled" then
			self:Cancel()
		else
			self:Finish()
		end
	end
end
-- END RUNTIME

--[[
	@description Virtual method called during destruction; subclasses should override.
	@return ()
]]
function BaseStateMachine:OnCleanup()
	self.Logger:Log
	{ 
		Level = "WARN", 
		Message = "Abstract Method 'OnCleanup' called.", 
		OperationId = self.Id 
	}
	self.Logger:Log
	{ 
		Level = "WARN", 
		Message = "Subclasses must implement 'OnCleanup' to handle cleanup tasks.", 
		OperationId = self.Id 
	}
end

--[[
	@description Virtual method called during initialization; subclasses should override to define states.
	@return ()
]]
function BaseStateMachine:RegisterStates()
	-- Virtual method intended to be overridden by subclasses
	self.Logger:Log
	{ 
		Level = "WARN", 
		Message = "Abstract Method 'RegisterStates' called.", 
		OperationId = self.Id 
	}
	self.Logger:Log
	{ 
		Level = "WARN", 
		Message = "Subclasses must implement 'RegisterStates' to define FSM states.", 
		OperationId = self.Id 
	}
end
-- END OVERRIDES

--[[
	@description Internal helper to stop the FSM and trigger cleanup.
	@return ()
]]
function BaseStateMachine:_Teardown()
	local wasActive = self.IsActive
	self.IsActive = false

	-- Execute OnLeave for the current state before tearing down
	if wasActive and typeof(self.CurrentState) == "table" and self.CurrentState.OnLeave then
		self.CurrentState:OnLeave(self)
	end

	ActiveMachines[self] = nil
	if next(ActiveMachines) == nil and GlobalHeartbeat then
		GlobalHeartbeat:Disconnect()
		GlobalHeartbeat = nil
	end
	self:OnCleanup()
end

--[[
	@description Ends the FSM execution with a 'Completed' status.
	@return ()
]]
function BaseStateMachine:Finish()
	if not self.IsActive then return end
	self:_Teardown()
	self._completed:Fire()
	self.Logger:Log
	{ 
		Level = "INFO", 
		Message = "StateMachine Completed Successfully.", 
		OperationId = self.Id 
	}
end

--[[
	@description Ends the FSM execution with a 'Failed' status.
	@param reason string
	@return ()
]]
function BaseStateMachine:Fail(reason: string)
	if not self.IsActive then return end
	-- Concat all error logs for reason
	local combinedReason = reason or ""
	local logs = self.Logger.History
	for _, logEntry in ipairs(logs) do
		if logEntry.Level == "ERROR" then
			combinedReason = combinedReason .. logEntry.Message::string .. " | "
		end
	end

	self:_Teardown()
	self._failed:Fire(combinedReason)
	self.Logger:Log
	{ 
		Level = "ERROR", 
		Message = "StateMachine Failed: " .. combinedReason .. " " .. tostring(self.Context), 
		OperationId = self.Id 
	}
end

--[[
	@description Ends the FSM execution with a 'Cancelled' status.
	@return ()
]]
function BaseStateMachine:Cancel()
	if self.IsActive then
		self:_Teardown()
	end

	self._cancelled:Fire()
	self.Logger:Log
	{ 
		Level = "WARN", 
		Message = "StateMachine Cancelled.", 
		OperationId = self.Id 
	}
end

--[[
	@description Completely destroys the StateMachine instance and all managed resources.
	@return ()
]]
function BaseStateMachine:Destroy()
	self:Log
	{
		Level = "INFO",
		Message = "Destroying StateMachine.",
		OperationId = self.Id
	}

	self:_Teardown()
	for _, task in ipairs(self._cleanupTasks) do
		if typeof(task) == "Instance" then task:Destroy()
		elseif typeof(task) == "RBXScriptConnection" then task:Disconnect()
		elseif type(task) == "function" then task()
		elseif type(task) == "table" and task.Destroy then task:Destroy()
		end
	end
	self._cleanupTasks = {}
	self._completed:Destroy()
	self._failed:Destroy()
	self._cancelled:Destroy()
	self._stateChanged:Destroy()
end

--[[
	@description Records a log entry for this StateMachine.
	@param params { Level: Logger.LogLevel, Message: string, Data: any? }
	@return ()
]]
function BaseStateMachine:Log(params: { Level: string, Message: string, Data: any? })
	self.Logger:Log
	{
		Level = params.Level,
		Message = params.Message,
		OperationId = self.Id,
		Data = params.Data
	}
end
-- END BUILT-INS

return BaseStateMachine