--!strict
-- @Name ReplicateIntentJob
-- @Author iKrypto

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplicateIntentJob = {
	Name = "ReplicateIntentJob",
	className = "ReplicateIntentJob",
	validStates = { "Validate", "NormalizePayload", "CheckAllowList", "ApplyToEntity", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local function getSharedModule(orchestrator: any, name: string)
	local getModule = orchestrator and orchestrator.GetModule
	if type(getModule) == "function" then
		local module = getModule(name)
		if module ~= nil then
			return module
		end
	end

	local sharedFolder = game:GetService("ReplicatedStorage"):FindFirstChild("shared")
	if sharedFolder then
		local mod = sharedFolder:FindFirstChild(name)
		if mod then
			return require(mod)
		end
	end

	local replicatedMod = ReplicatedStorage:FindFirstChild(name, true)
	if replicatedMod then
		return require(replicatedMod)
	end

	error("Shared module not found: " .. name)
end

local function normalizeScalar(value: any)
	local valueType = typeof(value)
	if valueType == "number" then
		return math.clamp(value, -1e6, 1e6)
	elseif valueType == "table" then
		return nil
	elseif valueType == "Instance" or valueType == "userdata" or valueType == "function" or valueType == "thread" then
		return nil
	end
	return value
end

local function sanitizePayload(intentSchema: any, payload: any, seen: { [table]: boolean }): (any?, string?)
	if payload == nil then
		return nil, nil
	end

	if typeof(payload) ~= "table" then
		return nil, "Payload must be a table"
	end

	if seen[payload] then
		return nil, "Payload cannot contain cyclic references"
	end
	seen[payload] = true

	local clamped = intentSchema.ClampNumericFields(payload)
	local sanitized = {}
	for key, value in pairs(clamped) do
		if typeof(key) ~= "string" then
			seen[payload] = nil
			return nil, "Payload keys must be strings"
		end

		local valueType = typeof(value)
		if valueType == "number" and value ~= value then
			seen[payload] = nil
			return nil, "Payload contains NaN"
		end
		if valueType == "table" then
			local nested, nestedErr = sanitizePayload(intentSchema, value, seen)
			if nestedErr then
				seen[payload] = nil
				return nil, nestedErr
			end
			sanitized[key] = nested
		elseif
			valueType == "Instance"
			or valueType == "userdata"
			or valueType == "function"
			or valueType == "thread"
		then
			seen[payload] = nil
			return nil, "Payload contains non-serializable values"
		else
			sanitized[key] = normalizeScalar(value)
		end
	end

	if not intentSchema.ValidatePayload(sanitized) then
		seen[payload] = nil
		return nil, "Payload validation failed"
	end

	seen[payload] = nil
	return sanitized, nil
end

local function validateAllowedPayload(kind: string, payload: { [string]: any }, allowLists: any): string?
	if kind == "Animation" then
		local name = payload.Name
		if allowLists.AllowAllAnimations == true then
			return nil
		end
		if typeof(name) ~= "string" or allowLists.ValidAnimationNames[name] ~= true then
			return "Animation intent uses an allowlist-blocked animation"
		end
	elseif kind == "Effect" then
		local name = payload.Name
		if typeof(name) ~= "string" or allowLists.ValidEffectNames[name] ~= true then
			return "Effect intent uses an allowlist-blocked effect"
		end
	elseif kind == "Sound" then
		local soundId = payload.SoundId
		if typeof(soundId) ~= "string" or allowLists.ValidSoundIds[soundId] ~= true then
			return "Sound intent uses an allowlist-blocked sound"
		end
	else
		return "Unsupported client intent kind"
	end

	return nil
end

function ReplicateIntentJob:RegisterStates()
	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				fsm:Fail("Orchestrator unavailable")
				return
			end

			if typeof(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("CharacterEntityId is required")
				return
			end

			if typeof(fsm.Kind) ~= "string" or fsm.Kind == "" then
				fsm:Fail("Kind is required")
				return
			end

			local characterEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not characterEntity then
				fsm:Fail("Character entity not found")
				return
			end

			local AllowLists = getSharedModule(fsm:GetOrchestrator(), "AllowLists")
			if not AllowLists.IsValidClientIntent(fsm.Kind) then
				fsm:Fail("Client intent kind is not allowed")
				return
			end
			if AllowLists.IsServerOnlyIntent(fsm.Kind) then
				fsm:Fail("Server-only intent kind cannot be replicated from client")
				return
			end

			fsm.Context._characterEntity = characterEntity
			fsm.State = "NormalizePayload"
		end,
	}, { "NormalizePayload", "Failed" })

	self:AddState("NormalizePayload", {
		OnEnter = function(_, fsm)
			local intentSchema = getSharedModule(fsm:GetOrchestrator(), "IntentSchema")
			local payload, err = sanitizePayload(intentSchema, fsm.Payload or {}, {})
			if err then
				fsm:Fail(err)
				return
			end

			local normalizedPayload = if typeof(payload) == "table" then payload else {}
			if fsm.Kind == "Animation" then
				normalizedPayload.Name = normalizedPayload.Name or normalizedPayload.AnimationName
				normalizedPayload.Speed = if typeof(normalizedPayload.Speed) == "number"
					then normalizedPayload.Speed
					else 1
				normalizedPayload.FadeTime = if typeof(normalizedPayload.FadeTime) == "number"
					then normalizedPayload.FadeTime
					else 0.1
			elseif fsm.Kind == "Effect" then
				normalizedPayload.Name = normalizedPayload.Name or normalizedPayload.EffectName
			elseif fsm.Kind == "Sound" then
				local soundId = normalizedPayload.SoundId or normalizedPayload.Id
				if soundId ~= nil then
					normalizedPayload.SoundId = tostring(soundId)
				end
				normalizedPayload.Volume = if typeof(normalizedPayload.Volume) == "number"
					then normalizedPayload.Volume
					else 0.5
				normalizedPayload.Pitch = if typeof(normalizedPayload.Pitch) == "number"
					then normalizedPayload.Pitch
					else 1
			end

			fsm.Context._normalizedPayload = normalizedPayload
			fsm.State = "CheckAllowList"
		end,
	}, { "CheckAllowList", "Failed" })

	self:AddState("CheckAllowList", {
		OnEnter = function(_, fsm)
			local AllowLists = getSharedModule(fsm:GetOrchestrator(), "AllowLists")
			local payload = fsm.Context._normalizedPayload
			if typeof(payload) ~= "table" then
				fsm:Fail("Normalized payload missing")
				return
			end

			local err = validateAllowedPayload(fsm.Kind, payload, AllowLists)
			if err then
				fsm:Fail(err)
				return
			end

			fsm.State = "ApplyToEntity"
		end,
	}, { "ApplyToEntity", "Failed" })

	self:AddState("ApplyToEntity", {
		OnEnter = function(_, fsm)
			local IntentSchema = getSharedModule(fsm:GetOrchestrator(), "IntentSchema")
			local characterEntity = fsm.Context._characterEntity
			local payload = fsm.Context._normalizedPayload
			if not characterEntity or typeof(payload) ~= "table" then
				fsm:Fail("Replication context missing")
				return
			end

			IntentSchema.AppendIntent(characterEntity, {
				Kind = fsm.Kind,
				Payload = payload,
				SourceCharId = fsm.CharacterEntityId,
				TargetCharId = fsm.CharacterEntityId,
			})
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })

	self:AddState("Completed", function() end, {})
	self:AddState("Failed", function() end, {})
end

function ReplicateIntentJob:OnCleanup() end

return ReplicateIntentJob
