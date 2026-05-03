--!strict

--[=[
	@description Normalizes and appends animation, sound, and effect intent payloads for FSMs that drive presentation-side reactions. Combat, movement, and ability systems depend on these helpers to convert intent definitions into IntentSchema-compatible payloads before they are attached to character entities.
	Assumes an IntentSchema shared module is available and that character entities can accept appended intent data through that schema.
]=]
local ModuleLoader = require(script.Parent.ModuleLoader)

local IntentHelpers = {}
--[=[
	@description Implements `IntentHelpers.buildIntentPayload`.
	@param kind string -- `kind` input parameter.
	@param rawIntent { [string]: any } -- `rawIntent` input parameter.
	@return { [string]: any }? -- Return value produced by the implementation, if any.
]=]

function IntentHelpers.buildIntentPayload(kind: string, rawIntent: { [string]: any }): { [string]: any }?
	if kind == "Animation" then
		local name = rawIntent.Name or rawIntent.AnimationName
		if typeof(name) ~= "string" or name == "" then
			return nil
		end
		return {
			Name = name,
			Speed = if typeof(rawIntent.Speed) == "number" then rawIntent.Speed else 1,
			FadeTime = if typeof(rawIntent.FadeTime) == "number" then rawIntent.FadeTime else 0.1,
		}
	elseif kind == "Sound" then
		local soundId = rawIntent.SoundId or rawIntent.Id
		if soundId == nil then
			return nil
		end
		return {
			SoundId = tostring(soundId),
			Volume = if typeof(rawIntent.Volume) == "number" then rawIntent.Volume else 0.5,
			Pitch = if typeof(rawIntent.Pitch) == "number" then rawIntent.Pitch else 1,
		}
	elseif kind == "Effect" then
		local name = rawIntent.Name or rawIntent.EffectName
		if typeof(name) ~= "string" or name == "" then
			return nil
		end
		local payload = table.clone(rawIntent)
		payload.Name = name
		payload.EffectName = nil
		return payload
	end
	return nil
end
--[=[
	@description Implements `IntentHelpers.appendIntent`.
	@param orchestrator any -- `orchestrator` input parameter.
	@param characterEntity any -- `characterEntity` input parameter.
	@param kind string -- `kind` input parameter.
	@param payload { [string]: any } -- `payload` input parameter.
	@param sourceCharId string? -- `sourceCharId` input parameter.
	@param targetCharId string? -- `targetCharId` input parameter.
	@param lockId string? -- `lockId` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function IntentHelpers.appendIntent(
	orchestrator: any,
	characterEntity: any,
	kind: string,
	payload: { [string]: any },
	sourceCharId: string?,
	targetCharId: string?,
	lockId: string?
)
	local intentSchema = ModuleLoader.requireSharedModule(orchestrator, "IntentSchema")
	intentSchema.AppendIntent(characterEntity, {
		Kind = kind,
		Payload = payload,
		SourceCharId = sourceCharId,
		TargetCharId = targetCharId or sourceCharId,
	}, lockId)
end
--[=[
	@description Implements `IntentHelpers.appendOptionalIntent`.
	@param orchestrator any -- `orchestrator` input parameter.
	@param characterEntity any -- `characterEntity` input parameter.
	@param intentDef any -- `intentDef` input parameter.
	@param sourceCharId string -- `sourceCharId` input parameter.
	@param lockId string? -- `lockId` input parameter.
	@param targetCharId string? -- `targetCharId` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function IntentHelpers.appendOptionalIntent(
	orchestrator: any,
	characterEntity: any,
	intentDef: any,
	sourceCharId: string,
	lockId: string?,
	targetCharId: string?
)
	if typeof(intentDef) ~= "table" then
		return
	end

	local kind = intentDef.Kind
	if typeof(kind) ~= "string" then
		return
	end

	local payload = IntentHelpers.buildIntentPayload(kind, intentDef)
	if payload then
		IntentHelpers.appendIntent(orchestrator, characterEntity, kind, payload, sourceCharId, targetCharId, lockId)
	end
end

return IntentHelpers
