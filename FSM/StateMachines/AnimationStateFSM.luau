--!strict

--[=[
	@module AnimationStateFSM
	@description Mirrors `BaseAnimation` and `ActionOverlay` from the character entity into `Idle`, `BaseAnimation`, `ActionOverlay`, and `Blending` runtime states.
]=]

local AnimationStateFSM = {
	Name = "AnimationStateFSM",
	className = "AnimationStateFSM",
	validStates = {"Idle","BaseAnimation","ActionOverlay","Blending","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Idle",
}

--[=[
	@description Resolves the CharacterEntity from the Orchestrator registry. Returns nil if the entity no longer exists.
]=]
local function getCharacterEntity(fsm: any): any?
	return fsm:GetEntity(fsm.CharacterEntityId)
end

--[=[
	@description Writes the derived observed state data back onto the active entity or FSM context.
	@param fsm any  -- AnimationStateFSM instance tracking the observed animation bucket for this character.
	@param state any  -- State name to write.
	@return nil -- Updates entity or FSM state in place.
]=]

local function writeObservedState(fsm: any, state: string)
	local charEntity = getCharacterEntity(fsm)
	if charEntity then
		charEntity.AnimationState = state
	end
	fsm.Context._observedState = state
end

--[=[
	@description Derives the observed animation bucket from blend timing plus the animation player's active base or action tracks.
	@param fsm any  -- AnimationStateFSM instance tracking the observed animation bucket for this character.
	@return string -- `Blending`, `ActionOverlay`, `BaseAnimation`, or `Idle`, based on the current animation player state.
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
	@description Re-runs observed-state detection and switches the FSM whenever the derived bucket changes.
	@param fsm any  -- AnimationStateFSM instance tracking the observed animation bucket for this character.
	@return nil -- Updates entity or FSM state in place.
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
	- OnHeartbeat switches to `BaseAnimation`, `ActionOverlay`, or `Blending` when those runtime signals become active.
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
	- OnHeartbeat switches to `Idle`, `ActionOverlay`, or `Blending` when base animation is no longer the derived state.
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
	- OnHeartbeat switches to `Idle`, `BaseAnimation`, or `Blending` when the overlay track disappears or a higher-priority bucket wins.
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
	- OnHeartbeat leaves `Blending` as soon as the blend window closes and another derived state becomes active.
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
	@param fsm any  -- AnimationStateFSM instance tracking the observed animation bucket for this character.
	@param duration any  -- Duration, in seconds.
	@return nil -- Updates FSM state as a side effect.
]=]

function AnimationStateFSM.MarkBlend(fsm: any, duration: number?)
	local seconds = if typeof(duration) == "number" and duration >= 0 then duration else 0.15
	fsm.Context._blendUntil = math.max(tonumber(fsm.Context._blendUntil) or 0, os.clock() + seconds)
	if fsm.IsActive and fsm.State ~= "Blending" then
		fsm.State = "Blending"
	end
end

return AnimationStateFSM
