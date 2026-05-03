--!strict

--[=[
	@description Normalizes and appends animation, sound, and effect intent payloads for FSMs that drive presentation-side reactions. Combat, movement, and ability systems depend on these helpers to convert intent definitions into IntentSchema-compatible payloads before they are attached to character entities.
	Assumes an IntentSchema shared module is available and that character entities can accept appended intent data through that schema.
]=]
local ModuleLoader = require(script.Parent.ModuleLoader)

local IntentHelpers = {}

--[=[
	@description Builds a normalized intent payload for supported kinds. Animation intents require a non-empty name, sound intents require an id, and effect intents clone the original table while normalizing EffectName into Name.
	@param kind string -- Supported intent kind such as Animation, Sound, or Effect.
	@param rawIntent { [string]: any } -- Raw intent definition table supplied by gameplay data or FSM context.
	@return { [string]: any }? -- Normalized payload table for supported valid intents, or nil when required fields are missing or the kind is unsupported.
	@reads rawIntent.Name, rawIntent.AnimationName, rawIntent.Speed, rawIntent.FadeTime, rawIntent.SoundId, rawIntent.Id, rawIntent.Volume, rawIntent.Pitch, rawIntent.EffectName
	@writes Cloned payload table for effect intents only
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
	@description Appends a normalized intent entry to the target character entity through the shared IntentSchema module. When no targetCharId is provided, the sourceCharId is reused as the target.
	@param orchestrator any -- FSM orchestrator used to resolve the IntentSchema shared module.
	@param characterEntity any -- Character entity receiving the appended intent entry.
	@param kind string -- Intent kind string passed through to IntentSchema.
	@param payload { [string]: any } -- Normalized payload table expected by the given intent kind.
	@param sourceCharId string? -- Source character/entity id recorded on the intent.
	@param targetCharId string? -- Optional target character/entity id; defaults to sourceCharId when omitted.
	@param lockId string? -- Optional lock or correlation id forwarded to IntentSchema.AppendIntent.
	@return nil -- No explicit return value.
	@reads orchestrator shared module registry, payload, sourceCharId, targetCharId
	@writes characterEntity intent state through IntentSchema.AppendIntent
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
	@description Validates an optional raw intent definition, builds a normalized payload when possible, and appends it to the character entity. Non-table definitions, missing Kind values, and invalid payloads are silently ignored.
	@param orchestrator any -- FSM orchestrator used to resolve the IntentSchema shared module.
	@param characterEntity any -- Character entity that may receive an appended intent.
	@param intentDef any -- Optional raw intent definition table.
	@param sourceCharId string -- Source character/entity id recorded on successful appended intents.
	@param lockId string? -- Optional lock or correlation id forwarded to IntentSchema.AppendIntent.
	@param targetCharId string? -- Optional target character/entity id used when appending the intent.
	@return nil -- No explicit return value.
	@reads intentDef.Kind and any fields consumed by buildIntentPayload
	@writes characterEntity intent state through appendIntent when validation succeeds
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
