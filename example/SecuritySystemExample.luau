--!strict
--[=[
	@Name SecuritySystemExample
	@Author Copilot
	@Description Demonstrates hierarchical FSM composition with `AddSubMachine()` by
	nesting `PatrolSubFSM` inside the parent `Armed` state and `AlarmSubFSM` inside the
	parent `Breach` state. The parent and child machines share one Context table so patrol,
	breach, and lockdown data flows across the hierarchy without custom plumbing.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseStateMachine = require(
	ReplicatedStorage
		:WaitForChild("Orchestrator")
		:WaitForChild("Core")
		:WaitForChild("Factory")
		:WaitForChild("BaseStateMachine")
)

local PatrolSubFSM = BaseStateMachine.Extend({
	Name = "PatrolSubFSM",
	className = "PatrolSubFSM",
	ValidStates = { "WaypointA", "WaypointB", "WaypointC", "CheckCycles", "Completed" },
	TerminalStates = { "Completed" },
	InitialState = "WaypointA",
})

local AlarmSubFSM = BaseStateMachine.Extend({
	Name = "AlarmSubFSM",
	className = "AlarmSubFSM",
	ValidStates = { "Sounding", "Escalating", "Notified", "Completed" },
	TerminalStates = { "Completed" },
	InitialState = "Sounding",
})

local SecuritySystemFSM = BaseStateMachine.Extend({
	Name = "SecuritySystemFSM",
	className = "SecuritySystemFSM",
	ValidStates = { "Idle", "Armed", "Breach", "Lockdown", "Reset" },
	TerminalStates = {},
	InitialState = "Idle",
})

--[[
	@description Ensures the shared example Context contains namespaced tables used by the
	parent and child machines.
	@param context table -- Shared parent/child context table.
	@return table, table, table -- Security, Patrol, and Alarm namespaces.
	@reads context.Security, context.Patrol, context.Alarm
	@writes context.Security, context.Patrol, context.Alarm
]]
local function ensureNamespaces(context: { [string]: any }): ({ [string]: any }, { [string]: any }, { [string]: any })
	local security = context.Security
	if type(security) ~= "table" then
		security = {}
		context.Security = security
	end

	local patrol = context.Patrol
	if type(patrol) ~= "table" then
		patrol = {}
		context.Patrol = patrol
	end

	local alarm = context.Alarm
	if type(alarm) ~= "table" then
		alarm = {}
		context.Alarm = alarm
	end

	return security, patrol, alarm
end

--[[
	@description Prepares the shared Context for the next parent arming cycle. By default
	this example alternates between a clean patrol and a simulated breach so both child
	completion and failure paths are easy to observe.
	@param context table -- Shared parent/child context table.
	@return ()
	@reads context.Security, context.Patrol, context.Alarm, context.SimulateBreach
	@writes context.Security, context.Patrol, context.Alarm, context.SimulateBreach,
		context.PatrolMachine, context.AlarmMachine
]]
local function prepareNextArmingCycle(context: { [string]: any })
	local security, patrol, alarm = ensureNamespaces(context)

	if security.UseAutoBreachDemo == nil then
		security.UseAutoBreachDemo = true
	end

	security.ArmingCount = (security.ArmingCount or 0) + 1
	security.SystemState = "Idle"
	security.ActiveSubsystem = nil
	security.LastOutcome = "Waiting"

	patrol.RequiredCycles = patrol.RequiredCycles or 3
	patrol.CycleCount = 0
	patrol.LastWaypoint = nil
	patrol.NextWaypoint = nil
	patrol.FailureReason = nil
	patrol.Status = "Standing by"

	alarm.CurrentStage = nil
	alarm.BreachReason = nil
	alarm.NotificationsSent = 0

	context.PatrolMachine = nil
	context.AlarmMachine = nil

	if security.UseAutoBreachDemo then
		context.SimulateBreach = security.ArmingCount % 2 == 0
	end

	security.NextPatrolMode = if context.SimulateBreach then "Breach drill" else "Routine patrol"
end

--[[
	@description Updates the shared Context for a patrol waypoint and optionally fails the
	child FSM when breach simulation is enabled.
	@param fsm any -- Patrol child FSM instance.
	@param waypointName string -- Current patrol waypoint.
	@return boolean -- True when the patrol failed and no further work should run.
	@reads fsm.Context, fsm.Context.SimulateBreach
	@writes fsm.Context.Security, fsm.Context.Patrol
]]
local function beginPatrolWaypoint(fsm: any, waypointName: string): boolean
	local context = fsm.Context :: { [string]: any }
	local security, patrol = ensureNamespaces(context)

	security.SystemState = "Armed"
	security.ActiveSubsystem = "Patrol"
	security.LastObservedWaypoint = waypointName

	patrol.IsActive = true
	patrol.LastWaypoint = waypointName
	patrol.Status = string.format("Patrolling %s", waypointName)

	if context.SimulateBreach then
		local reason = string.format("Breach detected while patrolling %s", waypointName)
		patrol.FailureReason = reason
		security.LastBreachReason = reason
		security.LastOutcome = "BreachDetected"
		fsm:Fail(reason)
		return true
	end

	security.LastOutcome = "Patrolling"
	return false
end

--[[
	@description Registers a patrol waypoint that waits two seconds before moving to the
	next waypoint, unless a simulated breach forces the child FSM to fail immediately.
	@param machineDefinition any -- PatrolSubFSM definition table.
	@param waypointName string -- Current patrol waypoint.
	@param nextWaypoint string -- Target waypoint after the timed delay.
	@return ()
	@reads None
	@writes machineDefinition states and transitions
]]
local function registerPatrolWaypoint(machineDefinition: any, waypointName: string, nextWaypoint: string)
	machineDefinition:AddState(waypointName, function(fsm)
		if beginPatrolWaypoint(fsm, waypointName) then
			return
		end

		local context = fsm.Context :: { [string]: any }
		local _, patrol = ensureNamespaces(context)
		patrol.NextWaypoint = nextWaypoint
		fsm:ScheduleTransition(2, nextWaypoint)
	end, { nextWaypoint })
end

--[[
	@description Registers the waypoint patrol loop and completion check used by the
	security system's Armed state.
	@return ()
	@reads self.Context
	@writes self._states, self._transitions
]]
function PatrolSubFSM:RegisterStates()
	registerPatrolWaypoint(self, "WaypointA", "WaypointB")
	registerPatrolWaypoint(self, "WaypointB", "WaypointC")
	registerPatrolWaypoint(self, "WaypointC", "CheckCycles")

	self:AddState("CheckCycles", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security, patrol = ensureNamespaces(context)

		patrol.CycleCount = (patrol.CycleCount or 0) + 1
		patrol.Status = string.format("Completed patrol cycle %d", patrol.CycleCount)
		security.LastPatrolCycles = patrol.CycleCount

		if patrol.CycleCount >= (patrol.RequiredCycles or 3) then
			security.LastOutcome = "PatrolCompleted"
			fsm.State = "Completed"
			return
		end

		security.LastOutcome = "RestartingPatrol"
		fsm.State = "WaypointA"
	end, { "WaypointA", "Completed" })

	self:AddState("Completed", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security, patrol = ensureNamespaces(context)
		security.LastOutcome = "PatrolCompleted"
		patrol.IsActive = false
		patrol.Status = "Route complete"
	end)
end

--[[
	@description Marks the patrol child machine as inactive when it tears down.
	@return ()
	@reads self.Context
	@writes self.Context.Security, self.Context.Patrol
]]
function PatrolSubFSM:OnCleanup()
	local context = self.Context :: { [string]: any }
	local security, patrol = ensureNamespaces(context)
	patrol.IsActive = false
	if security.ActiveSubsystem == "Patrol" then
		security.ActiveSubsystem = nil
	end
end

--[[
	@description Registers the alarm escalation pipeline used by the parent Breach state.
	@return ()
	@reads self.Context
	@writes self._states, self._transitions
]]
function AlarmSubFSM:RegisterStates()
	self:AddState("Sounding", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security, patrol, alarm = ensureNamespaces(context)
		security.SystemState = "Breach"
		security.ActiveSubsystem = "Alarm"
		security.LastOutcome = "AlarmSounding"
		alarm.IsActive = true
		alarm.CurrentStage = "Sounding"
		alarm.BreachReason = security.LastBreachReason or patrol.FailureReason
		fsm:ScheduleTransition(1, "Escalating")
	end, { "Escalating" })

	self:AddState("Escalating", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security, _, alarm = ensureNamespaces(context)
		security.LastOutcome = "AlarmEscalating"
		alarm.CurrentStage = "Escalating"
		fsm:ScheduleTransition(1, "Notified")
	end, { "Notified" })

	self:AddState("Notified", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security, _, alarm = ensureNamespaces(context)
		security.LastOutcome = "AuthoritiesNotified"
		alarm.CurrentStage = "Notified"
		alarm.NotificationsSent = (alarm.NotificationsSent or 0) + 1
		fsm:ScheduleTransition(1, "Completed")
	end, { "Completed" })

	self:AddState("Completed", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security, _, alarm = ensureNamespaces(context)
		security.LastOutcome = "AlarmCompleted"
		alarm.IsActive = false
		alarm.CurrentStage = "Completed"
	end)
end

--[[
	@description Marks the alarm child machine as inactive when it tears down.
	@return ()
	@reads self.Context
	@writes self.Context.Security, self.Context.Alarm
]]
function AlarmSubFSM:OnCleanup()
	local context = self.Context :: { [string]: any }
	local security, _, alarm = ensureNamespaces(context)
	alarm.IsActive = false
	if security.ActiveSubsystem == "Alarm" then
		security.ActiveSubsystem = nil
	end
end

--[[
	@description Registers the parent security system states and wires the Patrol and Alarm
	sub-machines into `Armed` and `Breach` using `AddSubMachine()`.
	@return ()
	@reads self.Context
	@writes self._states, self._transitions
]]
function SecuritySystemFSM:RegisterStates()
	self:AddState("Idle", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security = ensureNamespaces(context)
		prepareNextArmingCycle(context)
		security.LastOutcome = "Idle"
		fsm:ScheduleTransition(3, "Armed")
	end, { "Armed" })

	self:AddSubMachine("Armed", PatrolSubFSM, {
		Transitions = {
			OnCompleted = "Idle",
			OnFailed = "Breach",
			OnCancelled = "Reset",
		},
		InitialState = "WaypointA",
		StoreReference = "PatrolMachine",
	})

	self:AddSubMachine("Breach", AlarmSubFSM, {
		Transitions = {
			OnCompleted = "Lockdown",
			OnFailed = "Reset",
			OnCancelled = "Reset",
		},
		InitialState = "Sounding",
		StoreReference = "AlarmMachine",
	})

	self:AddState("Lockdown", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security, _, alarm = ensureNamespaces(context)
		security.SystemState = "Lockdown"
		security.ActiveSubsystem = nil
		security.LastOutcome = "LockdownEngaged"
		alarm.CurrentStage = "Completed"
		fsm:ScheduleTransition(10, "Reset")
	end, { "Reset" })

	self:AddState("Reset", function(fsm)
		local context = fsm.Context :: { [string]: any }
		local security, patrol, alarm = ensureNamespaces(context)
		security.SystemState = "Reset"
		security.ActiveSubsystem = nil
		security.LastOutcome = "Resetting"
		security.LastResetAt = os.clock()

		patrol.CycleCount = 0
		patrol.LastWaypoint = nil
		patrol.NextWaypoint = nil
		patrol.FailureReason = nil
		patrol.Status = "Reset complete"

		alarm.CurrentStage = nil
		alarm.IsActive = false

		context.SimulateBreach = false
		context.PatrolMachine = nil
		context.AlarmMachine = nil
		fsm.State = "Idle"
	end, { "Idle" })
end

--[[
	@description Clears stored child references if the parent machine is stopped early.
	@return ()
	@reads self.Context
	@writes self.Context.Security, self.Context.PatrolMachine, self.Context.AlarmMachine
]]
function SecuritySystemFSM:OnCleanup()
	local context = self.Context :: { [string]: any }
	local security = ensureNamespaces(context)
	security.SystemState = "Stopped"
	security.ActiveSubsystem = nil
	context.PatrolMachine = nil
	context.AlarmMachine = nil
end

return { SecuritySystemFSM, PatrolSubFSM, AlarmSubFSM }
