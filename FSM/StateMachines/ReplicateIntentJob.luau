--!strict
--[=[
	@Name ReplicateIntentJob
	@Author iKrypto
	@Description Validates a client-authored replication intent, recursively sanitizes and normalizes its payload, enforces shared allow lists, appends the normalized intent to the character entity, and finishes in the terminal `Completed` state. Invalid requests fail fast without mutating the entity. Historical integrations must target `Completed`; the deprecated `Complete` spelling is intentionally not used.

	State flow diagram:
	Validate → NormalizePayload → CheckAllowList → ApplyToEntity → Completed
				↘ Failed

	Context fields:
	- _characterEntity: any -- resolved character entity receiving the replicated intent.
	- _normalizedPayload: table -- sanitized payload with defaults applied per intent kind.

	Required params:
	- CharacterEntityId: string -- target character entity id.
	- Kind: string -- client intent kind (`Animation`, `Effect`, or `Sound`).
	- Payload: table? -- raw client payload that will be sanitized and normalized.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))

--[=[
	@module ReplicateIntentJob
	@description Collects pending intents from an entity, sanitizes them for replication, and publishes the payload through the orchestrator.
]=]

local ReplicateIntentJob = {
	Name = "ReplicateIntentJob",
	className = "ReplicateIntentJob",
	validStates = {"Validate","NormalizePayload","CheckAllowList","ApplyToEntity","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Validate",
}

--[=[
	@description Normalizes scalar payload values by clamping large numbers and rejecting non-serializable Luau runtime types.
	@param value any -- Scalar payload value to normalize.
	@return any -- Sanitized scalar value or nil when the value type is not serializable.
]=]
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

--[=[
	@description Recursively clamps and validates a payload table, rejects cyclic references and non-string keys, and returns a sanitized table accepted by `IntentSchema.ValidatePayload`.
	@param intentSchema any -- Shared intent schema module providing clamp and validation helpers.
	@param payload any -- Raw payload value supplied by the caller.
	@param seen table -- Recursion guard used to detect cyclic tables.
	@return any? -- Sanitized payload table or nil.
	@return string? -- Validation error string when sanitization fails.
]=]
local function sanitizePayload(intentSchema: any, payload: any, seen: { [table]: boolean }): (any?, string?)
	if payload == nil then
		return nil, nil
	end

	if typeof(payload) ~= "table" then
		return nil,"Payload must be a table"
	end

	if seen[payload] then
		return nil,"Payload cannot contain cyclic references"
	end
	seen[payload] = true

	local clamped = intentSchema.ClampNumericFields(payload)
	local sanitized = {}
	for key, value in pairs(clamped) do
		if typeof(key) ~= "string" then
			seen[payload] = nil
			return nil,"Payload keys must be strings"
		end

		local valueType = typeof(value)
		if valueType == "number" and value ~= value then
			seen[payload] = nil
			return nil,"Payload contains NaN"
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
			return nil,"Payload contains non-serializable values"
		else
			sanitized[key] = normalizeScalar(value)
		end
	end

	if not intentSchema.ValidatePayload(sanitized) then
		seen[payload] = nil
		return nil,"Payload validation failed"
	end

	seen[payload] = nil
	return sanitized, nil
end

--[=[
	@description Checks the normalized payload against allow-listed animation names, effect names, and sound ids for the specified intent kind.
	@param kind string -- Intent kind being validated.
	@param payload table -- Normalized payload fields.
	@param allowLists any -- Shared allow-list module contents.
	@return string? -- Nil when allowed, otherwise an explanatory failure reason.
]=]
local function validateAllowedPayload(kind: string, payload: { [string]: any }, allowLists: any): string?
	if kind == "Animation" then
		local name = payload.Name
		if allowLists.AllowAllAnimations == true then
			return nil
		end
		if typeof(name) ~= "string" or allowLists.ValidAnimationNames[name] ~= true then
			return"Animation intent uses an allowlist-blocked animation"
		end
	elseif kind == "Effect" then
		local name = payload.Name
		if typeof(name) ~= "string" or allowLists.ValidEffectNames[name] ~= true then
			return"Effect intent uses an allowlist-blocked effect"
		end
	elseif kind == "Sound" then
		local soundId = payload.SoundId
		if typeof(soundId) ~= "string" or allowLists.ValidSoundIds[soundId] ~= true then
			return"Sound intent uses an allowlist-blocked sound"
		end
	else
		return"Unsupported client intent kind"
	end

	return nil
end


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `ReplicateIntentJob`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function ReplicateIntentJob:RegisterStates()


	--[=[
	@state Validate
	@description Validates the required runtime context and prerequisites.
		Transitions:
		- `NormalizePayload` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: stores `Context._characterEntity`, sets `_characterEntity`.
	]=]

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

			local AllowLists = ModuleLoader.requireSharedModule(fsm:GetOrchestrator(),"AllowLists")
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
	}, {"NormalizePayload","Failed" })


	--[=[
	@state NormalizePayload
	@description On enter, stores `Context._normalizedPayload`, sets `Name`, sets `Speed`.
		Transitions:
		- `CheckAllowList` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: stores `Context._normalizedPayload`, sets `Name`, sets `Speed`, sets `FadeTime`, sets `SoundId`.
	]=]

	self:AddState("NormalizePayload", {
		OnEnter = function(_, fsm)
			local intentSchema = ModuleLoader.requireSharedModule(fsm:GetOrchestrator(),"IntentSchema")
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
	}, {"CheckAllowList","Failed" })


	--[=[
	@state CheckAllowList
	@description Runs the `check allow list` stage of `ReplicateIntentJob`.
		Transitions:
		- `ApplyToEntity` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: none.
	]=]

	self:AddState("CheckAllowList", {
		OnEnter = function(_, fsm)
			local AllowLists = ModuleLoader.requireSharedModule(fsm:GetOrchestrator(),"AllowLists")
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
	}, {"ApplyToEntity","Failed" })


	--[=[
	@state ApplyToEntity
	@description On enter, emits an intent.
		Transitions:
		- `Completed` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: emits an intent.
	]=]

	self:AddState("ApplyToEntity", {
		OnEnter = function(_, fsm)
			local IntentSchema = ModuleLoader.requireSharedModule(fsm:GetOrchestrator(),"IntentSchema")
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
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success sink reached after the sanitized intent payload has been appended to the character entity. `OnEnter` is a no-op because the entity mutation already occurred in `ApplyToEntity`.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink for payload normalization, allow-list, or entity-resolution errors. `OnEnter` is a no-op and `OnCleanup` performs no extra rollback.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Failed", function() end, {})
end


--[=[
	@description Restores any mutable runtime state that still needs cleanup if the FSM stops before its normal completion path.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

function ReplicateIntentJob:OnCleanup() end

return ReplicateIntentJob
