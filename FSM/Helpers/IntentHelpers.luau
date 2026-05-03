--!strict

--[=[
	@description Normalizes and appends animation, sound, and effect intent payloads for FSMs that drive presentation-side reactions. Combat, movement, and ability systems depend on these helpers to convert intent definitions into IntentSchema-compatible payloads before they are attached to character entities.
	Assumes an IntentSchema shared module is available and that character entities can accept appended intent data through that schema.
]=]
local ModuleLoader = require(script.Parent.ModuleLoader)

local IntentHelpers = {}
--[=[
	@description Normalizes raw intent definitions into the payload shape expected by IntentSchema. Each
	supported kind applies its own validation and defaults: Animation requires a name plus default speed/
	fade, Sound requires an id and coerces it to a string, and Effect clones the original table while
	normalizing EffectName into Name.

	@param kind string -- Intent kind to normalize (currently Animation, Sound, or Effect).
	@param rawIntent { [string]: any } -- Raw intent definition that may contain alternate field names and optional tuning values.
	@return { [string]: any }? -- Normalized payload table for the requested kind, or nil when the definition is incomplete or unsupported.
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
	@description Appends a fully formed presentation intent onto a character entity through the shared
	IntentSchema module. The helper packages kind, payload, source id, and target id into the schema's
	expected envelope and defaults TargetCharId to the source when no explicit target is supplied.

	@param orchestrator any -- Orchestrator used to resolve the shared IntentSchema module.
	@param characterEntity any -- Character entity that will receive the appended intent entry.
	@param kind string -- Intent category recorded in the schema entry.
	@param payload { [string]: any } -- Already-normalized intent payload to attach.
	@param sourceCharId string? -- Character id that originated the intent.
	@param targetCharId string? -- Optional target character id; defaults to sourceCharId when omitted.
	@param lockId string? -- Optional lock identifier forwarded to IntentSchema.AppendIntent.
	@return nil
	@writes characterEntity intent state via IntentSchema.AppendIntent
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
	@description Safely appends an intent definition only when it is well formed. Non-table values,
	definitions without a string Kind, and payloads that fail buildIntentPayload validation are ignored;
	otherwise the normalized payload is forwarded to appendIntent.

	@param orchestrator any -- Orchestrator used to resolve IntentSchema when an intent is actually appended.
	@param characterEntity any -- Character entity that should receive the optional intent.
	@param intentDef any -- Raw intent definition table that may or may not describe a supported intent.
	@param sourceCharId string -- Character id treated as the source of the intent.
	@param lockId string? -- Optional lock identifier passed through to appendIntent.
	@param targetCharId string? -- Optional explicit target character id for the intent envelope.
	@return nil
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
