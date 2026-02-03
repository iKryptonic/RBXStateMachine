--!strict
-- @Interface BaseStateMachineInterface
-- @Description Detailed interface documentation for the BaseStateMachine class.
-- This file serves as a reference for types and method signatures.

export type LogLevel = "INFO" | "WARN" | "ERROR" | "DEBUG"

-- Definition of a state transition
export type Transition = {
	TargetState: string, -- The name of the state to transition to
	Condition: (any, number) -> boolean -- A function that returns true if the transition should occur
}

-- Definition of an object-based state
export type StateObject = {
	Machine: BaseStateMachine?, -- Reference to a sub-machine if one exists
	OnEnter: (any, ...any) -> (), -- Called when the state is entered
	OnHeartbeat: ((any, number) -> ())?, -- Called every frame while in this state
	OnLeave: ((any) -> ())?, -- Called when the state is exited
	Transitions: {Transition}?, -- List of automatic transitions
}

-- Configuration for a hierarchical sub-machine
export type SubStateConfig = {
	InitialState: string, -- The starting state of the sub-machine
	Transitions: {
		OnCompleted: string, -- State to go to if sub-machine completes
		OnFailed: string, -- State to go to if sub-machine fails
		OnCancelled: string? -- State to go to if sub-machine is cancelled
	},
	StoreReference: string? -- Optional Context key to store the sub-machine instance
}

-- A state can be a function (closure) or a StateObject
export type State = ((any, ...any) -> (() -> ())?) | StateObject

-- Objects that can be cleaned up
export type Disposable = Instance | RBXScriptConnection | { Destroy: (any) -> () } | () -> ()

-- The BaseStateMachine Class Interface
export type BaseStateMachine = {
	-- Properties
	Id: string, -- Unique identifier for this machine instance
	Name: string, -- Display name of the machine class
	Context: { [any]: any }, -- Shared data table accessible by all states
	IsActive: boolean, -- True if the machine is currently running
	State: string?, -- The name of the current state
	StateDuration: number, -- Time in seconds spent in the current state
	TotalDuration: number, -- Total time the machine has been running
	WaitSpan: number, -- Delay in seconds before the next transition is processed
	TransitionCount: number, -- Number of transitions that have occurred
	Priority: number, -- Update frequency (1 = every frame, 2 = every other frame, etc.)
	
	-- Signals
	Completed: RBXScriptSignal, -- Fired when Finish() is called
	Failed: RBXScriptSignal, -- Fired when Fail() is called
	Cancelled: RBXScriptSignal, -- Fired when Cancel() is called
	StateChanged: RBXScriptSignal, -- Fired when the state changes (newState, oldState)

	-- Methods

	--[[
		Starts the StateMachine.
		@param params Table containing:
			- State: The name of the initial state to enter.
			- Args: Optional array of arguments to pass to the initial state's OnEnter.
	]]
	Start: (self: BaseStateMachine, params: { State: string, Args: {any}? }) -> (),

	--[[
		Transitions the machine to a new state.
		@param params Table containing:
			- Name: The name of the target state.
			- Args: Optional array of arguments to pass to the new state's OnEnter.
	]]
	ChangeState: (self: BaseStateMachine, params: { Name: string, Args: {any}? }) -> (),

	--[[
		Stops the machine successfully. Fires the Completed signal.
	]]
	Finish: (self: BaseStateMachine) -> (),

	--[[
		Stops the machine with a failure. Fires the Failed signal.
		@param reason A string describing why the machine failed.
	]]
	Fail: (self: BaseStateMachine, reason: string) -> (),

	--[[
		Stops the machine immediately. Fires the Cancelled signal.
	]]
	Cancel: (self: BaseStateMachine) -> (),

	--[[
		Permanently destroys the machine and cleans up all managed resources.
	]]
	Destroy: (self: BaseStateMachine) -> (),

	--[[
		Registers an object to be cleaned up when the machine is destroyed.
		@param object An Instance, Connection, function, or object with a Destroy method.
		@return The object passed in.
	]]
	Manage: (self: BaseStateMachine, object: Disposable) -> Disposable,

	--[[
		Registers a nested StateMachine inside a state.
		@param name The name of the state that will run this sub-machine.
		@param subMachineClass The class definition of the sub-machine.
		@param config Configuration for transitions based on the sub-machine's result.
	]]
	AddSubMachine: (self: BaseStateMachine, name: string, subMachineClass: any, config: SubStateConfig) -> (),

	--[[
		Registers a logic state.
		@param name The unique name of the state.
		@param state The function or StateObject defining the behavior.
		@param validOutcomes Optional list of allowed states to transition to from here.
	]]
	AddState: (self: BaseStateMachine, name: string, state: State, validOutcomes: {string}?) -> (),

	--[[
		Logs a message to the internal history.
		@param params Table containing Level (INFO/WARN/ERROR) and Message.
	]]
	Log: (self: BaseStateMachine, params: { Level: LogLevel, Message: string, Data: any? }) -> (),

	--[[
		Virtual method called during cleanup. Override this in subclasses to clean up custom resources.
	]]
	OnCleanup: (self: BaseStateMachine) -> (),
	
	--[[
		Virtual method called during initialization. Override this to call AddState/AddSubMachine.
	]]
	RegisterStates: (self: BaseStateMachine) -> (),
}

return {}
