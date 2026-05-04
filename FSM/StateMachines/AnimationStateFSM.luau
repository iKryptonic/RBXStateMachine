--!strict


--[=[
	@Name AnimationStateFSM
	@Author iKrypto
	@Description Client-side animation state observer. Polls charEntity.AnimationState
	and LocomotionState to determine which base animation to play (idle, walk, run) and
	when to blend action overlays. Feeds the AnimationPlayer with current state so the
	render loop can drive the correct joint transforms.

	State flow:
	Idle ↔ BaseAnimation ↔ ActionOverlay → Blending → Idle
	Continuous polling — no terminal path during normal gameplay.

	Context fields:
	- AnimationPlayer: any — reference to the legacy AnimationPlayer instance
	- _observedState: string — last observed locomotion/action state
	- _blendUntil: number — timestamp when blend completes

	Required params:
	- CharacterEntityId: string — character entity to observe
]=]

local AnimationStateFSM = {
	Name = "AnimationStateFSM",
	className = "AnimationStateFSM",
	validStates = {"Idle","BaseAnimation","ActionOverlay","Blending","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Idle",
}

--[=[
	@description Returns the character entity used by this state machine when it can be resolved.
	@param fsm any -- Input consumed by `getCharacterEntity`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getCharacterEntity(fsm: any): any?
	return fsm:GetEntity(fsm.CharacterEntityId)
end

--[=[
	@description Writes the derived observed state data back onto the active entity or FSM context.
	@param fsm any -- Input consumed by `writeObservedState`.
	@param state any -- Input consumed by `writeObservedState`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function writeObservedState(fsm: any, state: string)
	local charEntity = getCharacterEntity(fsm)
	if charEntity then
		charEntity.AnimationState = state
	end
	fsm.Context._observedState = state
end

--[=[
	@description Resolves observed state from the current FSM context and available runtime data.
	@param fsm any -- Input consumed by `resolveObservedState`.
	@return string -- Resolved string value used by the FSM.
]=]

local function resolveObservedState(fsm: any): string
	local animationPlayer = fsm.Context.AnimationPlayer
	if not animationPlayer then
		return"Idle"
	end

	local blendUntil = tonumber(fsm.Context._blendUntil) or 0
	if blendUntil > os.clock() then
		return"Blending"
	end

	if animationPlayer._actionAnimation ~= nil and animationPlayer._actionName ~= "" then
		return"ActionOverlay"
	end
	if animationPlayer._baseName ~= nil and animationPlayer._baseName ~= "" then
		return"BaseAnimation"
	end
	return"Idle"
end

--[=[
	@description Synchronizes observed state with the latest derived runtime state.
	@param fsm any -- Input consumed by `syncObservedState`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function syncObservedState(fsm: any)
	local desiredState = resolveObservedState(fsm)
	if desiredState ~= fsm.State then
		fsm.State = desiredState
	end
end


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `AnimationStateFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function AnimationStateFSM:RegisterStates()


	--[=[
		@state Idle
		@description Writes the observed animation state as `Idle`.
			Transitions:
			- External transitions allow: `BaseAnimation`, `ActionOverlay`, `Blending`.
			Writes: none.
	]=]

	self:AddState("Idle", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm,"Idle")
		end,
		OnHeartbeat = function(_, fsm)
			syncObservedState(fsm)
		end,
	}, {"BaseAnimation","ActionOverlay","Blending" })


	--[=[
		@state BaseAnimation
		@description Writes the observed animation state as `BaseAnimation`.
			Transitions:
			- External transitions allow: `Idle`, `ActionOverlay`, `Blending`.
			Writes: none.
	]=]

	self:AddState("BaseAnimation", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm,"BaseAnimation")
		end,
		OnHeartbeat = function(_, fsm)
			syncObservedState(fsm)
		end,
	}, {"Idle","ActionOverlay","Blending" })


	--[=[
		@state ActionOverlay
		@description Writes the observed animation state as `ActionOverlay`.
			Transitions:
			- External transitions allow: `Idle`, `BaseAnimation`, `Blending`.
			Writes: none.
	]=]

	self:AddState("ActionOverlay", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm,"ActionOverlay")
		end,
		OnHeartbeat = function(_, fsm)
			syncObservedState(fsm)
		end,
	}, {"Idle","BaseAnimation","Blending" })


	--[=[
		@state Blending
		@description Writes the observed animation state as `Blending`.
			Transitions:
			- External transitions allow: `Idle`, `BaseAnimation`, `ActionOverlay`.
			Writes: none.
	]=]

	self:AddState("Blending", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm,"Blending")
		end,
		OnHeartbeat = function(_, fsm)
			syncObservedState(fsm)
		end,
	}, {"Idle","BaseAnimation","ActionOverlay" })
	--[=[
	@state Completed
	@description Terminal shutdown state for the animation observer. `OnEnter` forces the observed state back to `Idle`, mirrors that into `charEntity.AnimationState` and `fsm.Context._observedState`, and logs completion for the character.
		Transitions: none.
		Writes: `AnimationState`, `Context._observedState`, info log.
	]=]

	self:AddState("Completed", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm,"Idle")
			fsm:Log({
				Level = "INFO",
				Message = string.format("AnimationStateFSM completed for %s", tostring(fsm.CharacterEntityId)),
			})
		end,
	}, {})
	--[=[
	@state Failed
	@description Terminal error state for animation-state tracking. `OnEnter` logs the failure reason for `CharacterEntityId` and leaves the last observed state untouched.
		Transitions: none.
		Writes: error log.
	]=]

	self:AddState("Failed", {
		OnEnter = function(_, fsm, reason)
			fsm:Log({
				Level = "ERROR",
				Message = string.format(
					"AnimationStateFSM failed for %s: %s",
					tostring(fsm.CharacterEntityId),
					tostring(reason or "unknown error")
				),
			})
		end,
	}, {})
end


--[=[
	@description Marks transient runtime state needed by later heartbeat-driven transitions.
	@param fsm any -- Value consumed by `MarkBlend`.
	@param duration any -- Value consumed by `MarkBlend`.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

function AnimationStateFSM.MarkBlend(fsm: any, duration: number?)
	local seconds = if typeof(duration) == "number" and duration >= 0 then duration else 0.15
	fsm.Context._blendUntil = math.max(tonumber(fsm.Context._blendUntil) or 0, os.clock() + seconds)
	if fsm.IsActive and fsm.State ~= "Blending" then
		fsm.State = "Blending"
	end
end

return AnimationStateFSM
