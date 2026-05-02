--!strict

local ModuleLoader = require(script.Parent.ModuleLoader)

local IntentHelpers = {}

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
