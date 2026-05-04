--!strict


--[=[
	@Name CharacterSetupFSM
	@Author iKrypto
	@Description Client-side deterministic character bootstrap. Disables default Roblox
	animation, waits for entity replication, creates the controller bundle (dash, double
	jump, hit react), creates client FSMs (Locomotion, Action, Dash, Jump, Input, etc.),
	binds lifecycle events, and enters the Active state. TearingDown cleans up all
	connections and FSMs when the character dies or leaves.

	State flow:
	Validating → DisablingDefaults → AwaitingEntities → InitControllers
	→ InitFSMs → BindingEvents → Active → TearingDown → Completed

	Context fields:
	- Character: Model — the spawned character model
	- Humanoid: Humanoid — character humanoid
	- CharacterEntity: any — replicated character entity
	- Connections: table — event connections to disconnect on teardown
	- CreateControllerBundle: function — factory for dash/jump/hitreact controllers
	- CreateFSMBundle: function — factory for client FSMs

	Required params:
	- CharacterEntityId: string — character entity ID
	- PlayerEntityId: string — player entity ID
]=]

local CharacterSetupFSM = {
	Name = "CharacterSetupFSM",
	className = "CharacterSetupFSM",
	validStates = {
		"Validating",
		"DisablingDefaults",
		"AwaitingEntities",
		"InitControllers",
		"InitFSMs",
		"BindingEvents",
		"Active",
		"TearingDown",
		"Completed",
		"Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Validating",
}

--[=[
	@description Helper for the destroy managed step used by this state machine.
	@param value any -- Input consumed by `destroyManaged`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function destroyManaged(value: any)
	if value == nil then
		return
	end
	if typeof(value) == "RBXScriptConnection" then
		value:Disconnect()
		return
	end
	if typeof(value) == "Instance" then
		value:Destroy()
		return
	end
	if type(value) == "function" then
		value()
		return
	end
	if type(value) == "table" then
		if type(value.Cancel) == "function" and value.IsActive then
			value:Cancel()
			return
		end
		if type(value.Destroy) == "function" then
			value:Destroy()
			return
		end
		for _, child in pairs(value) do
			destroyManaged(child)
		end
	end
end

--[=[
	@description Helper for the restore defaults step used by this state machine.
	@param fsm any -- Input consumed by `restoreDefaults`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function restoreDefaults(fsm: any)
	local defaultAnimate = fsm.Context._defaultAnimate
	if defaultAnimate and defaultAnimate.Parent and fsm.Context._defaultAnimateWasDisabled == false then
		defaultAnimate.Disabled = false
	end

	local humanoid = fsm.Context.Humanoid
	local animator = fsm.Context._removedAnimator
	if humanoid and animator and animator.Parent == nil then
		animator.Parent = humanoid
	end
end

--[=[
	@description Returns the character model used by this state machine when it can be resolved.
	@param fsm any -- Input consumed by `getCharacterModel`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getCharacterModel(fsm: any): Model?
	local character = fsm.Context.Character or fsm.Context.Instance
	if character and character:IsA("Model") then
		return character
	end
	return nil
end

--[=[
	@description Returns the required parts used by this state machine when it can be resolved.
	@param character any -- Input consumed by `getRequiredParts`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getRequiredParts(character: Model)
	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
	local limbs = {
		RightArm = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand"),
		LeftArm = character:FindFirstChild("Left Arm") or character:FindFirstChild("LeftHand"),
		RightLeg = character:FindFirstChild("Right Leg") or character:FindFirstChild("RightLowerLeg"),
		LeftLeg = character:FindFirstChild("Left Leg") or character:FindFirstChild("LeftLowerLeg"),
	}

	return {
		Humanoid = character:FindFirstChildOfClass("Humanoid"),
		RootPart = character:FindFirstChild("HumanoidRootPart"),
		Torso = torso,
		Head = character:FindFirstChild("Head"),
		Limbs = limbs,
	}
end

--[=[
	@description Helper for the safe invoke step used by this state machine.
	@param factory any -- Input consumed by `safeInvoke`.
	@param fsm any -- Input consumed by `safeInvoke`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function safeInvoke(factory: any, fsm: any, ...: any): any
	if type(factory) ~= "function" then
		return nil
	end

	local ok, result = pcall(factory, fsm, ...)
	if not ok then
		fsm:Log({ Level = "WARN", Message = string.format("CharacterSetupFSM callback failed: %s", tostring(result)) })
		return nil
	end
	return result
end


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `CharacterSetupFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function CharacterSetupFSM:RegisterStates()


	--[=[
		@state Validating
		@description On enter, stores `Context.Character`, stores `Context.Humanoid`, stores `Context.RootPart`.
			Transitions:
			- `DisablingDefaults` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context.Character`, stores `Context.Humanoid`, stores `Context.RootPart`, stores `Context.Torso`, stores `Context.Head`.
	]=]

	self:AddState("Validating", {
		OnEnter = function(_, fsm)
			local character = getCharacterModel(fsm)
			if not character then
				fsm:Fail("CharacterSetupFSM requires a Character model in Context.Character or Context.Instance")
				return
			end

			local parts = getRequiredParts(character)
			local missing = {}
			if not parts.Humanoid then
				table.insert(missing,"Humanoid")
			end
			if not parts.RootPart then
				table.insert(missing,"HumanoidRootPart")
			end
			if not parts.Torso then
				table.insert(missing,"Torso")
			end
			if not parts.Head then
				table.insert(missing,"Head")
			end
			for limbName, limb in pairs(parts.Limbs) do
				if not limb then
					table.insert(missing, limbName)
				end
			end

			if #missing > 0 then
				fsm:Fail("Character missing required parts: " .. table.concat(missing,", "))
				return
			end

			fsm.Context.Character = character
			fsm.Context.Humanoid = parts.Humanoid
			fsm.Context.RootPart = parts.RootPart
			fsm.Context.Torso = parts.Torso
			fsm.Context.Head = parts.Head
			fsm.Context.Limbs = parts.Limbs
			fsm:Log({
				Level = "INFO",
				Message = string.format("CharacterSetupFSM validated %s", character:GetFullName()),
			})
			fsm.State = "DisablingDefaults"
		end,
	}, {"DisablingDefaults","Failed" })


	--[=[
		@state DisablingDefaults
		@description On enter, stores `Context._defaultAnimate`, stores `Context._defaultAnimateWasDisabled`, stores `Context._removedAnimator`.
			Transitions:
			- `AwaitingEntities` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._defaultAnimate`, stores `Context._defaultAnimateWasDisabled`, stores `Context._removedAnimator`, sets `_defaultAnimate`, sets `_defaultAnimateWasDisabled`.
	]=]

	self:AddState("DisablingDefaults", {
		OnEnter = function(_, fsm)
			local character = fsm.Context.Character
			local humanoid = fsm.Context.Humanoid
			local defaultAnimate = character and character:FindFirstChild("Animate")
			if defaultAnimate and defaultAnimate:IsA("LocalScript") then
				fsm.Context._defaultAnimate = defaultAnimate
				fsm.Context._defaultAnimateWasDisabled = defaultAnimate.Disabled
				defaultAnimate.Disabled = true
			end

			local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
			if animator then
				fsm.Context._removedAnimator = animator
				animator.Parent = nil
			end

			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"CharacterSetupFSM disabled defaults for %s",
					tostring(fsm.CharacterEntityId or character.Name)
				),
			})
			fsm.State = "AwaitingEntities"
		end,
	}, {"AwaitingEntities","Failed" })


	--[=[
		@state AwaitingEntities
		@description On enter, stores `Context._awaitStartedAt`, stores `Context.CharacterEntity`, stores `Context.PlayerEntity`.
			Transitions:
			- `Failed` when the scheduled transition completes.
			- `InitControllers` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._awaitStartedAt`, stores `Context.CharacterEntity`, stores `Context.PlayerEntity`, sets `_awaitStartedAt`, sets `CharacterEntity`.
	]=]

	self:AddState("AwaitingEntities", {
		OnEnter = function(_, fsm)
			fsm.Context._awaitStartedAt = os.clock()
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"CharacterSetupFSM awaiting entities for %s",
					tostring(fsm.CharacterEntityId or "unknown")
				),
			})
			fsm:ScheduleTransition(10,"Failed", {"Timed out waiting for CharacterEntity/PlayerEntity" })
		end,
		OnHeartbeat = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				return
			end

			local charEntity = if typeof(fsm.CharacterEntityId) == "string"
				then orchestrator.GetEntity(fsm.CharacterEntityId)
				else nil
			local playerEntity = if typeof(fsm.PlayerEntityId) == "string"
				then orchestrator.GetEntity(fsm.PlayerEntityId)
				else nil
			if charEntity and playerEntity then
				fsm:CancelScheduledTransition()
				fsm.Context.CharacterEntity = charEntity
				fsm.Context.PlayerEntity = playerEntity
				fsm:Log({
					Level = "INFO",
					Message = string.format(
						"CharacterSetupFSM resolved entities for %s",
						tostring(fsm.CharacterEntityId)
					),
				})
				fsm.State = "InitControllers"
			end
		end,
	}, {"InitControllers","Failed" })


	--[=[
		@state InitControllers
		@description On enter, stores `Context.ReferenceAnimationPlayer`, stores `Context.RenderRouter`, stores `Context.DashController`.
			Transitions:
			- `InitFSMs` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context.ReferenceAnimationPlayer`, stores `Context.RenderRouter`, stores `Context.DashController`, stores `Context.DoubleJumpController`, stores `Context.HitReactController`.
	]=]

	self:AddState("InitControllers", {
		OnEnter = function(_, fsm)
			local bundle = safeInvoke(fsm.Context.CreateControllerBundle, fsm) or {}
			fsm.Context.ReferenceAnimationPlayer = bundle.ReferenceAnimationPlayer
			fsm.Context.RenderRouter = bundle.RenderRouter
			fsm.Context.DashController = bundle.DashController
			fsm.Context.DoubleJumpController = bundle.DoubleJumpController
			fsm.Context.HitReactController = bundle.HitReactController
			fsm.Context.InputRouter = bundle.InputRouter
			fsm.Context.InventoryGui = bundle.InventoryGui
			fsm.Context.TargetingSystem = bundle.TargetingSystem
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"CharacterSetupFSM initialized controller bundle for %s",
					tostring(fsm.CharacterEntityId)
				),
			})
			fsm.State = "InitFSMs"
		end,
	}, {"InitFSMs","Failed" })


	--[=[
		@state InitFSMs
		@description On enter, stores `Context.LocomotionFSM`, stores `Context.ActionFSM`, stores `Context.DashFSM`.
			Transitions:
			- `BindingEvents` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context.LocomotionFSM`, stores `Context.ActionFSM`, stores `Context.DashFSM`, stores `Context.JumpFSM`, stores `Context.InputFSM`.
	]=]

	self:AddState("InitFSMs", {
		OnEnter = function(_, fsm)
			local bundle = safeInvoke(fsm.Context.CreateFSMBundle, fsm) or {}
			fsm.Context.LocomotionFSM = bundle.LocomotionFSM
			fsm.Context.ActionFSM = bundle.ActionFSM
			fsm.Context.DashFSM = bundle.DashFSM
			fsm.Context.JumpFSM = bundle.JumpFSM
			fsm.Context.InputFSM = bundle.InputFSM
			fsm.Context.InputModeFSM = bundle.InputModeFSM
			fsm.Context.AnimationStateFSM = bundle.AnimationStateFSM
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"CharacterSetupFSM initialized FSM bundle for %s",
					tostring(fsm.CharacterEntityId)
				),
			})
			fsm.State = "BindingEvents"
		end,
	}, {"BindingEvents","Failed" })


	--[=[
		@state BindingEvents
		@description On enter, stores `Context.Connections`, sets `Connections`, writes to the log.
			Transitions:
			- `Active` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context.Connections`, sets `Connections`, writes to the log.
	]=]

	self:AddState("BindingEvents", {
		OnEnter = function(_, fsm)
			fsm.Context.Connections = safeInvoke(fsm.Context.BindEvents, fsm) or {}
			fsm:Log({
				Level = "INFO",
				Message = string.format("CharacterSetupFSM bound events for %s", tostring(fsm.CharacterEntityId)),
			})
			fsm.State = "Active"
		end,
	}, {"Active","Failed" })


	--[=[
		@state Active
		@description On enter, sets `Parent`, writes to the log.
			Transitions:
			- `TearingDown` when this stage finishes its immediate work or falls through its guard checks.
			Writes: sets `Parent`, writes to the log.
	]=]

	self:AddState("Active", {
		OnEnter = function(_, fsm)
			fsm:Log({
				Level = "INFO",
				Message = string.format("CharacterSetupFSM active for %s", tostring(fsm.CharacterEntityId)),
			})
		end,
		OnHeartbeat = function(_, fsm)
			local character = fsm.Context.Character
			local humanoid = fsm.Context.Humanoid
			if not character or character.Parent == nil then
				fsm.State = "TearingDown"
				return
			end
			if humanoid and humanoid.Health <= 0 then
				fsm.State = "TearingDown"
			end
		end,
	}, {"TearingDown","Failed" })


	--[=[
		@state TearingDown
		@description On enter, writes to the log.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
			Writes: writes to the log.
	]=]

	self:AddState("TearingDown", {
		OnEnter = function(_, fsm)
			safeInvoke(fsm.Context.OnPreTeardown, fsm)
			destroyManaged(fsm.Context.Connections)
			destroyManaged({
				fsm.Context.InputRouter,
				fsm.Context.TargetingSystem,
				fsm.Context.InventoryGui,
				fsm.Context.RenderRouter,
				fsm.Context.ReferenceAnimationPlayer,
				fsm.Context.DashController,
				fsm.Context.DoubleJumpController,
				fsm.Context.HitReactController,
				fsm.Context.LocomotionFSM,
				fsm.Context.ActionFSM,
				fsm.Context.DashFSM,
				fsm.Context.JumpFSM,
				fsm.Context.InputFSM,
				fsm.Context.InputModeFSM,
				fsm.Context.AnimationStateFSM,
			})
			safeInvoke(fsm.Context.RestoreDefaults, fsm)
			restoreDefaults(fsm)
			fsm:Log({
				Level = "INFO",
				Message = string.format("CharacterSetupFSM tore down %s", tostring(fsm.CharacterEntityId)),
			})
			fsm.State = "Completed"
		end,
	}, {"Completed" })
	--[=[
	@state Completed
	@description Terminal success state entered after character controllers and child FSMs have been initialized and teardown-safe defaults restored. `OnEnter` records a final completion log for `CharacterEntityId`.
		Transitions: none.
		Writes: info log.
	]=]

	self:AddState("Completed", {
		OnEnter = function(_, fsm)
			fsm:Log({
				Level = "INFO",
				Message = string.format("CharacterSetupFSM completed for %s", tostring(fsm.CharacterEntityId)),
			})
		end,
	}, {})
	--[=[
	@state Failed
	@description Terminal failure state for setup errors while waiting on entities, wiring controllers, or initializing child FSMs. `OnEnter` logs the reason, destroys managed connections, invokes `RestoreDefaults`, and reapplies Roblox default character behavior.
		Transitions: none.
		Writes: error log, restored defaults, destroyed connections.
	]=]

	self:AddState("Failed", {
		OnEnter = function(_, fsm, reason)
			fsm:Log({
				Level = "ERROR",
				Message = string.format(
					"CharacterSetupFSM failed for %s: %s",
					tostring(fsm.CharacterEntityId),
					tostring(reason or "unknown error")
				),
			})
			destroyManaged(fsm.Context.Connections)
			safeInvoke(fsm.Context.RestoreDefaults, fsm)
			restoreDefaults(fsm)
		end,
	}, {})
end

return CharacterSetupFSM
