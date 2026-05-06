--!strict
--[=[
	@Name GuardNPCExample
	@Author GitHub Copilot
	@Description Reference implementation showing a BehaviorTree composing high-level
	guard AI decisions that drive FSM state transitions. The tree chooses Patrol,
	Investigate, Chase, and ReturnToPost while the FSM states own movement,
	timeouts, and WaitSpan-based pacing.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FactoryFolder = ReplicatedStorage:WaitForChild("Orchestrator")
	:WaitForChild("Core")
	:WaitForChild("Factory")
local BT: any = require(FactoryFolder:WaitForChild("BehaviorTree"))
local Status = BT.BehaviorTreeStatus

if type(BT.Action) ~= "function" then
	function BT.Action(action: (context: any) -> string): (context: any) -> string
		return function(context: any): string
			return action(context)
		end
	end
end

if type(BT.Decorator) ~= "function" then
	function BT.Decorator(wrapper: (context: any, child: (context: any) -> string) -> string, child: (context: any) -> string): (context: any) -> string
		return function(context: any): string
			return wrapper(context, child)
		end
	end
end

local GuardNPCExample = {}

local function getAnchorPart(instance: any): BasePart?
	if typeof(instance) ~= "Instance" then
		return nil
	end

	if instance:IsA("BasePart") then
		return instance
	end

	if instance:IsA("Model") then
		if instance.PrimaryPart then
			return instance.PrimaryPart
		end
		return instance:FindFirstChildWhichIsA("BasePart", true)
	end

	return nil
end

local function resolvePosition(candidate: any): Vector3?
	if typeof(candidate) == "Vector3" then
		return candidate
	end

	if typeof(candidate) == "Instance" then
		local part = getAnchorPart(candidate)
		return if part then part.Position else nil
	end

	if type(candidate) == "table" then
		local position = candidate.Position
		if typeof(position) == "Vector3" then
			return position
		end

		if type(candidate.GetPosition) == "function" then
			local ok, value = pcall(candidate.GetPosition, candidate)
			if ok and typeof(value) == "Vector3" then
				return value
			end
		end

		local instance = candidate.Instance or candidate.Model or candidate.RootPart
		if instance ~= nil then
			return resolvePosition(instance)
		end
	end

	return nil
end

local function normalizeWaypoints(rawWaypoints: any, fallback: Vector3): {Vector3}
	local waypoints = {} :: {Vector3}
	if type(rawWaypoints) == "table" then
		for _, entry in ipairs(rawWaypoints) do
			local position = resolvePosition(entry)
			if position then
				table.insert(waypoints, position)
			end
		end
	end

	if #waypoints == 0 then
		table.insert(waypoints, fallback)
	end

	return waypoints
end

local function getAlertColor(alertLevel: string): Color3
	if alertLevel == "Alert" then
		return Color3.fromRGB(255, 85, 85)
	elseif alertLevel == "Suspicious" then
		return Color3.fromRGB(255, 221, 87)
	end

	return Color3.fromRGB(85, 170, 127)
end

local GuardNPCEntity = {
	Name = "GuardNPCEntity",
	Mutable = true,
	Replication = {
		Enabled = true,
		RateLimit = 30,
	},
	Schema = {
		PatrolIndex = { Type = "number", Replicate = true, Description = "Current patrol waypoint index." },
		AlertLevel = { Type = "string", Replicate = true, Description = "Calm, Suspicious, or Alert." },
		TargetId = { Type = "string", Replicate = true, Description = "Current tracked target id, or an empty string." },
		_waypoints = { Type = "any" },
		_detectionRadius = { Type = "number" },
	},
}

--[[
	@description Builds the guard entity context from the NPC model and authoring data.
	@param params any -- Entity constructor payload with optional Instance, Waypoints, and DetectionRadius
	@return { [string]: any }
	@reads params.Context, params.Instance, self.PatrolIndex, self.AlertLevel, self.TargetId
	@writes None
]]
function GuardNPCEntity:GetContext(params: any)
	local context = if type(params.Context) == "table" then params.Context else {}
	local instance = context.Instance or params.Instance
	local anchorPart = getAnchorPart(instance)
	local origin = if anchorPart then anchorPart.Position else Vector3.zero
	local waypoints = normalizeWaypoints(context.Waypoints or params.Waypoints, origin)
	local detectionRadius = context.DetectionRadius or params.DetectionRadius or self._detectionRadius or 24

	return {
		Instance = instance,
		_anchorPart = anchorPart,
		_spawnPosition = origin,
		_waypoints = waypoints,
		_detectionRadius = detectionRadius,
		PatrolIndex = self.PatrolIndex or 1,
		AlertLevel = self.AlertLevel or "Calm",
		TargetId = self.TargetId or "",
	}
end

--[[
	@description Mirrors replicated AI state onto the NPC instance so the example is visible in Studio.
	@param changes { [string]: any } -- Delta committed by UpdateEntity
	@return ()
	@reads self.Instance, self.PatrolIndex, self.AlertLevel, self.TargetId
	@writes NPC attributes, anchor part color
]]
function GuardNPCEntity:ApplyChanges(changes: {[string]: any})
	local instance = self.Instance
	if typeof(instance) == "Instance" then
		instance:SetAttribute("PatrolIndex", self.PatrolIndex)
		instance:SetAttribute("AlertLevel", self.AlertLevel)
		instance:SetAttribute("TargetId", self.TargetId)
	end

	if changes.AlertLevel ~= nil then
		local anchorPart = getAnchorPart(instance)
		if anchorPart then
			anchorPart.Color = getAlertColor(self.AlertLevel)
		end
	end
end

--[[
	@description Returns the guard's current world position.
	@return Vector3
	@reads self.Instance, self._spawnPosition
	@writes None
]]
function GuardNPCEntity:GetPosition(): Vector3
	local part = getAnchorPart(self.Instance)
	if part then
		return part.Position
	end

	return self._spawnPosition or Vector3.zero
end

--[[
	@description Teleports the guard's visual instance to a world position.
	@param position Vector3 -- New world position for the guard
	@return ()
	@reads self.Instance
	@writes Model/BasePart transform
]]
function GuardNPCEntity:SetPosition(position: Vector3)
	local instance = self.Instance
	if typeof(instance) ~= "Instance" then
		return
	end

	if instance:IsA("Model") then
		local anchorPart = getAnchorPart(instance)
		if anchorPart then
			instance:PivotTo(CFrame.new(position, position + anchorPart.CFrame.LookVector))
		end
	elseif instance:IsA("BasePart") then
		instance.CFrame = CFrame.new(position, position + instance.CFrame.LookVector)
	end
end

--[[
	@description Moves the guard toward a destination using dt-scaled motion.
	@param destination Vector3 -- Desired position
	@param dt number -- Heartbeat delta time
	@param speed number -- Studs per second
	@return boolean -- True when the destination is reached this tick
	@reads self:GetPosition()
	@writes self:SetPosition()
]]
function GuardNPCEntity:MoveTowards(destination: Vector3, dt: number, speed: number): boolean
	local currentPosition = self:GetPosition()
	local offset = destination - currentPosition
	local distance = offset.Magnitude
	if distance <= 0.001 then
		self:SetPosition(destination)
		return true
	end

	local step = math.max(speed, 0) * math.max(dt, 0)
	if distance <= step then
		self:SetPosition(destination)
		return true
	end

	self:SetPosition(currentPosition + offset.Unit * step)
	return false
end

--[[
	@description Returns the guard's detection radius.
	@return number
	@reads self._detectionRadius
	@writes None
]]
function GuardNPCEntity:GetDetectionRadius(): number
	return self._detectionRadius or 24
end

--[[
	@description Returns the active patrol waypoint list.
	@return {Vector3}
	@reads self._waypoints
	@writes None
]]
function GuardNPCEntity:GetWaypoints(): {Vector3}
	return self._waypoints or {}
end

--[[
	@description Computes the closest patrol waypoint index to the guard's current position.
	@return number
	@reads self:GetWaypoints(), self:GetPosition()
	@writes None
]]
function GuardNPCEntity:GetNearestPatrolIndex(): number
	local waypoints = self:GetWaypoints()
	if #waypoints == 0 then
		return 1
	end

	local position = self:GetPosition()
	local nearestIndex = 1
	local nearestDistance = math.huge
	for index, waypoint in ipairs(waypoints) do
		local distance = (waypoint - position).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearestIndex = index
		end
	end

	return nearestIndex
end

--[[
	@description Returns the guard's shortest distance to any patrol waypoint.
	@return number
	@reads self:GetWaypoints(), self:GetPosition()
	@writes None
]]
function GuardNPCEntity:GetDistanceToPatrolRoute(): number
	local waypoints = self:GetWaypoints()
	if #waypoints == 0 then
		return math.huge
	end

	local position = self:GetPosition()
	local nearestDistance = math.huge
	for _, waypoint in ipairs(waypoints) do
		nearestDistance = math.min(nearestDistance, (waypoint - position).Magnitude)
	end

	return nearestDistance
end

local GuardAIFSM = {
	Name = "GuardAIFSM",
	ValidStates = { "Patrol", "Investigate", "Chase", "ReturnToPost", "Completed", "Failed" },
	TerminalStates = { "Completed", "Failed" },
	InitialState = "Patrol",
	Priority = 1,
}

--[[
	@description Returns the schema-backed guard entity used by this FSM.
	@return any
	@reads self.Context.GuardEntity
	@writes None
]]
function GuardAIFSM:_getGuardEntity()
	return self.Context.GuardEntity
end

--[[
	@description Returns the active target id from FSM context or replicated guard state.
	@return string
	@reads self.Context.TargetId, self.Context.GuardEntity
	@writes None
]]
function GuardAIFSM:_getTargetId(): string
	local targetId = self.Context.TargetId
	if type(targetId) == "string" and targetId ~= "" then
		return targetId
	end

	local guard = self:_getGuardEntity()
	if guard and type(guard.TargetId) == "string" then
		return guard.TargetId
	end

	return ""
end

--[[
	@description Resolves the current target's world position from the FSM context.
	@return Vector3?
	@reads self.Context.TargetId, self.Context.Targets
	@writes None
]]
function GuardAIFSM:_resolveTargetPosition(): Vector3?
	local targetId = self:_getTargetId()
	if targetId == "" then
		return nil
	end

	local targets = self.Context.Targets
	if type(targets) == "table" then
		return resolvePosition(targets[targetId])
	end

	return nil
end

--[[
	@description Returns the guard-to-target distance when a target is available.
	@return number?
	@reads self:_resolveTargetPosition(), self.Context.GuardEntity
	@writes None
]]
function GuardAIFSM:_getTargetDistance(): number?
	local guard = self:_getGuardEntity()
	local targetPosition = self:_resolveTargetPosition()
	if not guard or not targetPosition then
		return nil
	end

	return (targetPosition - guard:GetPosition()).Magnitude
end

--[[
	@description Commits guard schema changes only when values actually differ.
	@param changes { [string]: any } -- Schema fields to update
	@return ()
	@reads self.Context.GuardEntity
	@writes guard schema + replicated entity state
]]
function GuardAIFSM:_applyGuardChanges(changes: {[string]: any})
	local guard = self:_getGuardEntity()
	if not guard then
		return
	end

	local dirty = false
	for field, value in pairs(changes) do
		if guard[field] ~= value then
			guard[field] = value
			dirty = true
		end
	end

	if dirty then
		guard:UpdateEntity()
	end
end

--[[
	@description Applies an FSM transition requested by the behavior tree.
	@param targetState string -- State selected by the tree
	@return ()
	@reads self.State
	@writes self.State, self.Context.LastDecision
]]
function GuardAIFSM:_setStateFromTree(targetState: string)
	self.Context.LastDecision = targetState
	if self.State ~= targetState then
		self.State = targetState
	end
end

--[[
	@description Returns the distance threshold used by the return-to-post branch.
	@return number
	@reads self.Context.ReturnThreshold, guard detection radius
	@writes None
]]
function GuardAIFSM:_getReturnThreshold(): number
	local guard = self:_getGuardEntity()
	local detectionRadius = if guard then guard:GetDetectionRadius() else 24
	local configured = self.Context.ReturnThreshold
	if type(configured) == "number" and configured > 0 then
		return configured
	end
	return math.max(detectionRadius * 0.5, 6)
end

--[[
	@description Decides whether the Patrol fallback action should be allowed this frame.
	@return boolean
	@reads self.State
	@writes None
]]
function GuardAIFSM:_allowPatrolFallback(): boolean
	return self.State ~= "Investigate" and self.State ~= "Chase" and self.State ~= "ReturnToPost"
end

--[[
	@description Builds the guard decision tree once and reuses it every heartbeat.
	@return (context: any) -> string
	@reads BT node constructors
	@writes self._decisionTree
]]
function GuardAIFSM:_getDecisionTree()
	if self._decisionTree then
		return self._decisionTree
	end

	local function tagDecision(decisionName: string, child: (context: any) -> string)
		return BT.Decorator(function(context: any, runChild: (context: any) -> string): string
			local status = runChild(context)
			if status ~= Status.Failure then
				context.LastDecision = decisionName
			end
			return status
		end, child)
	end

	self._decisionTree = BT.Selector({
		tagDecision("Chase", BT.Sequence({
			BT.Condition(function(context: any): boolean
				local distance = context.FSM:_getTargetDistance()
				local guard = context.FSM:_getGuardEntity()
				return guard ~= nil
					and type(context.TargetId) == "string"
					and context.TargetId ~= ""
					and distance ~= nil
					and distance < guard:GetDetectionRadius()
			end),
			BT.Condition(function(context: any): boolean
				local guard = context.FSM:_getGuardEntity()
				return guard ~= nil and guard.AlertLevel == "Alert"
			end),
			BT.Action(function(context: any): string
				context.FSM:_setStateFromTree("Chase")
				return Status.Success
			end),
		})),
		tagDecision("Investigate", BT.Decorator(function(context: any, runChild: (context: any) -> string): string
			local status = runChild(context)
			if status == Status.Success then
				context.FSM:_applyGuardChanges({ AlertLevel = "Suspicious" })
			end
			return status
		end, BT.Sequence({
			BT.Condition(function(context: any): boolean
				return context.HeardNoise == true and typeof(context.NoisePosition) == "Vector3"
			end),
			BT.Action(function(context: any): string
				context.InvestigationPoint = context.NoisePosition
				context.FSM:_setStateFromTree("Investigate")
				return Status.Success
			end),
		}))),
		tagDecision("ReturnToPost", BT.Sequence({
			BT.Condition(function(context: any): boolean
				local guard = context.FSM:_getGuardEntity()
				return guard ~= nil and guard:GetDistanceToPatrolRoute() > context.FSM:_getReturnThreshold()
			end),
			BT.Action(function(context: any): string
				context.FSM:_setStateFromTree("ReturnToPost")
				return Status.Success
			end),
		})),
		tagDecision("Patrol", BT.Action(function(context: any): string
			if context.AllowPatrolFallback ~= false then
				context.FSM:_setStateFromTree("Patrol")
			end
			return Status.Success
		end)),
	})

	return self._decisionTree
end

--[[
	@description Evaluates the guard AI tree using the live FSM context.
	@return string
	@reads self.Context, guard replicated state
	@writes self.State, self.Context.LastDecision, self.Context.InvestigationPoint
]]
function GuardAIFSM:_evaluateAI(): string
	local guard = self:_getGuardEntity()
	if not guard then
		self:Fail("GuardAIFSM requires Context.GuardEntity")
		return Status.Failure
	end

	self.Context.FSM = self
	self.Context.GuardEntity = guard
	self.Context.TargetId = self:_getTargetId()
	self.Context.AllowPatrolFallback = self:_allowPatrolFallback()

	return self:_getDecisionTree()(self.Context)
end

--[[
	@description Registers the patrol, investigate, chase, and return states.
	@return ()
	@reads self.Context.GuardEntity
	@writes self state registry
]]
function GuardAIFSM:RegisterStates()
	self:AddState("Patrol", {
		OnEnter = function(_, fsm)
			local guard = fsm:_getGuardEntity()
			if not guard or #guard:GetWaypoints() == 0 then
				fsm:Fail("GuardNPCEntity requires at least one patrol waypoint")
				return
			end

			fsm.Context.PatrolPaused = false
			fsm.Context.HeardNoise = false
			fsm.Context.NoisePosition = nil
			fsm.Context.InvestigationPoint = nil
			fsm.Context.TargetId = guard.TargetId or ""
			fsm:_applyGuardChanges({ AlertLevel = "Calm", TargetId = fsm.Context.TargetId })
		end,
		OnHeartbeat = function(_, fsm, dt)
			fsm:_evaluateAI()
			if fsm.State ~= "Patrol" then
				return
			end
			if fsm.Context.PatrolPaused then
				return
			end

			local guard = fsm:_getGuardEntity()
			if not guard then
				fsm:Fail("Guard entity was destroyed during Patrol")
				return
			end

			local waypoints = guard:GetWaypoints()
			local patrolIndex = math.clamp(guard.PatrolIndex or 1, 1, #waypoints)
			local reached = guard:MoveTowards(waypoints[patrolIndex], dt, fsm.Context.PatrolSpeed or 8)
			if reached then
				local nextIndex = (patrolIndex % #waypoints) + 1
				fsm:_applyGuardChanges({ PatrolIndex = nextIndex })
				fsm.Context.PatrolPaused = true
				fsm.WaitSpan = 2
			end
		end,
	}, { "Patrol", "Investigate", "Chase", "ReturnToPost", "Completed", "Failed" })

	self:AddState("Investigate", {
		Timeout = 10,
		OnTimeout = "Patrol",
		OnEnter = function(_, fsm)
			local noisePosition = fsm.Context.NoisePosition
			if typeof(noisePosition) == "Vector3" then
				fsm.Context.InvestigationPoint = noisePosition
			end
			fsm:_applyGuardChanges({ AlertLevel = "Suspicious" })
		end,
		OnHeartbeat = function(_, fsm, dt)
			fsm:_evaluateAI()
			if fsm.State ~= "Investigate" then
				return
			end

			local guard = fsm:_getGuardEntity()
			local investigationPoint = fsm.Context.InvestigationPoint
			if not guard or typeof(investigationPoint) ~= "Vector3" then
				fsm.State = "Patrol"
				return
			end

			guard:MoveTowards(investigationPoint, dt, fsm.Context.InvestigateSpeed or 10)
		end,
	}, { "Patrol", "Chase", "ReturnToPost", "Completed", "Failed" })

	self:AddState("Chase", {
		OnEnter = function(_, fsm)
			fsm.Context.TargetId = fsm:_getTargetId()
			fsm:_applyGuardChanges({ AlertLevel = "Alert", TargetId = fsm.Context.TargetId })
		end,
		OnHeartbeat = function(_, fsm, dt)
			local guard = fsm:_getGuardEntity()
			if not guard then
				fsm:Fail("Guard entity was destroyed during Chase")
				return
			end

			local targetPosition = fsm:_resolveTargetPosition()
			if not targetPosition then
				fsm.Context.TargetId = ""
				fsm:_applyGuardChanges({ TargetId = "" })
				fsm.State = "ReturnToPost"
				return
			end

			local distance = (targetPosition - guard:GetPosition()).Magnitude
			if distance > guard:GetDetectionRadius() * 1.5 then
				fsm.Context.TargetId = ""
				fsm:_applyGuardChanges({ TargetId = "", AlertLevel = "Suspicious" })
				fsm.State = "ReturnToPost"
				return
			end

			guard:MoveTowards(targetPosition, dt, fsm.Context.ChaseSpeed or 14)
			fsm:_evaluateAI()
		end,
	}, { "Patrol", "Investigate", "ReturnToPost", "Completed", "Failed" })

	self:AddState("ReturnToPost", {
		OnEnter = function(_, fsm)
			local guard = fsm:_getGuardEntity()
			if not guard then
				fsm:Fail("Guard entity was destroyed during ReturnToPost")
				return
			end

			local nearestIndex = guard:GetNearestPatrolIndex()
			fsm.Context.ReturnPatrolIndex = nearestIndex
			fsm:_applyGuardChanges({ PatrolIndex = nearestIndex, AlertLevel = "Calm", TargetId = "" })
		end,
		OnHeartbeat = function(_, fsm, dt)
			fsm:_evaluateAI()
			if fsm.State ~= "ReturnToPost" then
				return
			end

			local guard = fsm:_getGuardEntity()
			if not guard then
				fsm:Fail("Guard entity was destroyed while returning to post")
				return
			end

			local waypoints = guard:GetWaypoints()
			local returnIndex = math.clamp(fsm.Context.ReturnPatrolIndex or 1, 1, #waypoints)
			local reached = guard:MoveTowards(waypoints[returnIndex], dt, fsm.Context.ReturnSpeed or 9)
			if reached then
				fsm.State = "Patrol"
			end
		end,
	}, { "Patrol", "Investigate", "Chase", "Completed", "Failed" })

	self:AddState("Completed", function(fsm)
		fsm:_applyGuardChanges({ AlertLevel = "Calm", TargetId = "" })
	end)

	self:AddState("Failed", function(fsm, reason)
		fsm:_applyGuardChanges({ AlertLevel = "Alert" })
		fsm:Log({
			Level = "ERROR",
			Message = string.format("GuardAIFSM failed: %s", tostring(reason)),
		})
	end)
end

--[[
	@description Creates a ready-to-use context payload for Orchestrator.CreateStateMachine.
	@param guardEntity any -- GuardNPCEntity instance to drive
	@param targets { [string]: any }? -- Optional target lookup table used by Chase
	@return { [string]: any }
	@reads guardEntity.TargetId
	@writes None
]]
function GuardNPCExample.CreateContext(guardEntity: any, targets: {[string]: any}?): {[string]: any}
	return {
		GuardEntity = guardEntity,
		Targets = targets or {},
		HeardNoise = false,
		NoisePosition = nil,
		InvestigationPoint = nil,
		TargetId = guardEntity and guardEntity.TargetId or "",
		PatrolSpeed = 8,
		InvestigateSpeed = 10,
		ChaseSpeed = 14,
		ReturnSpeed = 9,
	}
end

GuardNPCExample.GuardNPCEntity = GuardNPCEntity
GuardNPCExample.GuardAIFSM = GuardAIFSM

return GuardNPCExample
