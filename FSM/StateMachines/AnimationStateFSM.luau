--!strict
-- @Name AnimationStateFSM
-- @Author Copilot
-- @Description Supplementary client FSM for animation blending observability.

local AnimationStateFSM = {
	Name = "AnimationStateFSM",
	className = "AnimationStateFSM",
	validStates = { "Idle", "BaseAnimation", "ActionOverlay", "Blending", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Idle",
}

local function getCharacterEntity(fsm: any): any?
	return fsm:GetEntity(fsm.CharacterEntityId)
end

local function writeObservedState(fsm: any, state: string)
	local charEntity = getCharacterEntity(fsm)
	if charEntity then
		charEntity.AnimationState = state
	end
	fsm.Context._observedState = state
end

local function resolveObservedState(fsm: any): string
	local animationPlayer = fsm.Context.AnimationPlayer
	if not animationPlayer then
		return "Idle"
	end

	local blendUntil = tonumber(fsm.Context._blendUntil) or 0
	if blendUntil > os.clock() then
		return "Blending"
	end

	if animationPlayer._actionAnimation ~= nil and animationPlayer._actionName ~= "" then
		return "ActionOverlay"
	end
	if animationPlayer._baseName ~= nil and animationPlayer._baseName ~= "" then
		return "BaseAnimation"
	end
	return "Idle"
end

local function syncObservedState(fsm: any)
	local desiredState = resolveObservedState(fsm)
	if desiredState ~= fsm.State then
		fsm.State = desiredState
	end
end

function AnimationStateFSM:RegisterStates()
	self:AddState("Idle", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm, "Idle")
		end,
		OnHeartbeat = function(_, fsm)
			syncObservedState(fsm)
		end,
	}, { "BaseAnimation", "ActionOverlay", "Blending" })

	self:AddState("BaseAnimation", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm, "BaseAnimation")
		end,
		OnHeartbeat = function(_, fsm)
			syncObservedState(fsm)
		end,
	}, { "Idle", "ActionOverlay", "Blending" })

	self:AddState("ActionOverlay", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm, "ActionOverlay")
		end,
		OnHeartbeat = function(_, fsm)
			syncObservedState(fsm)
		end,
	}, { "Idle", "BaseAnimation", "Blending" })

	self:AddState("Blending", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm, "Blending")
		end,
		OnHeartbeat = function(_, fsm)
			syncObservedState(fsm)
		end,
	}, { "Idle", "BaseAnimation", "ActionOverlay" })

	self:AddState("Completed", {
		OnEnter = function(_, fsm)
			writeObservedState(fsm, "Idle")
			fsm:Log({
				Level = "INFO",
				Message = string.format("AnimationStateFSM completed for %s", tostring(fsm.CharacterEntityId)),
			})
		end,
	}, {})

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

function AnimationStateFSM.MarkBlend(fsm: any, duration: number?)
	local seconds = if typeof(duration) == "number" and duration >= 0 then duration else 0.15
	fsm.Context._blendUntil = math.max(tonumber(fsm.Context._blendUntil) or 0, os.clock() + seconds)
	if fsm.IsActive and fsm.State ~= "Blending" then
		fsm.State = "Blending"
	end
end

return AnimationStateFSM
