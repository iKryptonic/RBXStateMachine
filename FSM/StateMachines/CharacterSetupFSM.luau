--!strict
--[=[
	@Name CharacterSetupFSM
	@Author iKrypto
	@Description Client-side deterministic character bootstrap. Disables default Roblox
	animation (Animate script + Animator), waits for entity replication, creates the
	controller bundle (dash, double jump, hit react), creates client FSMs (Locomotion,
	Action, Dash, Jump, Input, etc.), binds lifecycle events, and enters the Active
	state. TearingDown cleans up all connections and FSMs when the character dies or leaves.

	State flow:
	Validating → DisablingDefaults → AwaitingEntities → InitControllers
	→ InitFSMs → BindingEvents → Active → TearingDown → Completed

	Context fields:
	- Character: Model — the spawned character model
	- Humanoid: Humanoid — character humanoid
	- CharacterEntity: any — replicated character entity
	- Connections: table — event connections to disconnect on teardown
	- _defaultAnimate: Script — reference to the disabled Animate script
	- _defaultAnimateWasDisabled: boolean — whether Animate was already disabled
	- _removedAnimator: Animator — reference to the removed Animator instance

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
	@description Disposes a managed resource by type. Disconnects RBXScriptConnections,
	destroys Instances, calls functions (cleanup callbacks), cancels active FSMs
	(tables with Cancel+IsActive), destroys tables with a Destroy method, and
	recursively cleans table children. Used by TearingDown to clean up everything
	registered during the character's lifetime.

	@param value any — The resource to dispose (connection, Instance, function, FSM, or table)
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
	@description Re-enables the default Animate script and re-parents the removed
	Animator back into the Humanoid. Called during teardown to restore Roblox's
	default animation system when the custom pipeline is no longer driving the character.

	@param fsm any — CharacterSetupFSM instance with Context._defaultAnimate and _removedAnimator
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
	@description Resolves the character Model from the FSM's Context. Checks
	Context.Character first, falls back to Context.Instance. Returns nil if
	neither is a valid Model.

	@param fsm any — CharacterSetupFSM instance
	@return Model? — The character model, or nil
]=]
local function getCharacterModel(fsm: any): Model?
	local character = fsm.Context.Character or fsm.Context.Instance
	if character and character:IsA("Model") then
		return character
	end
	return nil
end

--[=[
	@description Resolves standard R6/R15 body parts from a character Model.
	Returns a table with Humanoid, RootPart, Torso, Head, and Limbs (RightArm,
	LeftArm, RightLeg, LeftLeg) — handling both R6 names ("Right Arm") and R15
	names ("RightHand"). Any part that doesn't exist will be nil in the result.

	@param character Model — The character model to scan
	@return { Humanoid, RootPart, Torso, Head, Limbs } — Resolved body parts
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
	@description Safely invokes a callback with pcall, logging any errors without crashing the FSM.
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
	@description Resolves the character model and all required body parts, caches them in context, and fails with a missing-part list when setup cannot continue.
	Transitions:
	- `DisablingDefaults` when OnEnter finishes or falls through its guard checks.
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
	@description Disables the stock `Animate` LocalScript, detaches the humanoid's Animator, and records what must be restored later.
	Transitions:
	- `AwaitingEntities` when OnEnter finishes or falls through its guard checks.
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
	@description Starts a 10-second wait for both character and player entities; OnHeartbeat cancels the timeout and advances once both resolve.
	Transitions:
	- `Failed` when the scheduled transition completes.
	- `InitControllers` when OnEnter finishes or falls through its guard checks.
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
	@description Builds the controller bundle and caches the animation, dash, jump, hit-react, input, GUI, and targeting helpers returned by `CreateControllerBundle`.
	Transitions:
	- `InitFSMs` when OnEnter finishes or falls through its guard checks.
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
	@description Builds the locomotion, action, dash, jump, input, input-mode, and animation-state FSM bundle from `CreateFSMBundle`.
	Transitions:
	- `BindingEvents` when OnEnter finishes or falls through its guard checks.
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
	@description Stores the connections returned by `BindEvents` and logs that character event wiring is live.
	Transitions:
	- `Active` when OnEnter finishes or falls through its guard checks.
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
	@description Logs activation once, then OnHeartbeat tears down when the character is removed or the humanoid dies.
	Transitions:
	- `TearingDown` when OnEnter finishes or falls through its guard checks.
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
	@description Runs pre-teardown hooks, destroys tracked connections, controllers, and FSMs, restores defaults, and logs final cleanup.
	Transitions:
	- `Completed` when OnEnter finishes or falls through its guard checks.
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
