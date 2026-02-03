--!strict
-- @Interface StateMachineFactoryInterface
-- @Description Formal interface definition for the StateMachine factory module.
-- This module is responsible for registering and retrieving StateMachine class definitions.

--[[
	@Interface StateMachineInstance
	@Description Represents an instantiated StateMachine object (runtime).
]]
export type StateMachineInstance = {
	Id: string,
	Name: string,
	State: string,
	Context: {[any]: any},
	WaitSpan: number,
	TransitionCount: number,

	Start: (self: StateMachineInstance, params: { State: string, Args: {any}? }) -> (),
	ChangeState: (self: StateMachineInstance, params: { Name: string, Args: {any}? }) -> (),
	AddState: (self: StateMachineInstance, name: string, state: any, validOutcomes: {string}?) -> (),
	AddSubMachine: (self: StateMachineInstance, name: string, subMachineClass: any, config: any) -> (),
	Manage: (self: StateMachineInstance, object: Instance | RBXScriptConnection | () -> () | {Destroy: (self: any) -> ()}) -> (),
	
	Finish: (self: StateMachineInstance) -> (),
	Fail: (self: StateMachineInstance, reason: string) -> (),
	Cancel: (self: StateMachineInstance) -> (),
	Destroy: (self: StateMachineInstance) -> (),
}

--[[
	@Interface StateMachineClass
	@Description Represents the static class definition of a StateMachine.
]]
export type StateMachineClass = {
	Extend: (definition: {[string]: any}) -> StateMachineClass,
	new: (params: {[string]: any}) -> StateMachineInstance,
	[any]: any
}

--[[
	@Interface StateMachineFactory
	@Description The static singleton used to manage StateMachine classes.
]]
export type StateMachineFactory = {
	--[[
		@Method Register
		@Description Registers a new StateMachine class definition under a specific name.
		This method looks for a ModuleScript in ReplicatedStorage.StateMachines with the matching name,
		and extends the provided class definition using BaseStateMachine.Extend.
		
		@Param stateMachineName string -- The unique name of the StateMachine (must match a ModuleScript in ReplicatedStorage.StateMachines).
		@Param class StateMachineClass -- The table definition containing the StateMachine's logic, states, and properties.
		@Return void
	]]
	Register: (stateMachineName: string, class: StateMachineClass) -> (),

	--[[
		@Method get
		@Description Retrieves a registered StateMachine class by its name.
		Throws an error if the StateMachine has not been registered.
		
		@Param stateMachineName string -- The name of the StateMachine to retrieve.
		@Return StateMachineClass -- The StateMachine class (subclass of BaseStateMachine).
	]]
	get: (stateMachineName: string) -> StateMachineClass
}

return {} :: StateMachineFactory