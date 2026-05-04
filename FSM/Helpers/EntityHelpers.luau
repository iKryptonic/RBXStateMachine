--!strict

--[=[
	@description Resolves entity-backed character instances and common humanoid data for client and server FSMs. Combat, movement, animation, and validation flows use these helpers to normalize access to character models, crowd-control flags, and humanoid health state.
	Assumes entity tables may expose Instance, IsStunned, IsKnocked, Health, MaxHealth, and related replicated fields; client-side callers may rely on Players.LocalPlayer.Character when Instance is absent.
]=]
local Players = game:GetService("Players")

local EntityHelpers = {}

--[=[
	@description Resolves a character model from an entity table. When entity.Instance is unavailable, this falls back to Players.LocalPlayer.Character for client-side FSMs.
	@param charEntity any -- Entity table that may expose an Instance field referencing a character model.
	@return Instance? -- Character instance when one can be resolved, or nil when no model is available.
	@reads charEntity.Instance, Players.LocalPlayer.Character
	@writes None
]=]
local function resolveCharacter(charEntity: any): Instance?
	if charEntity and charEntity.Instance then
		return charEntity.Instance
	end
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		return localPlayer.Character
	end
	return nil
end
--[=[
	@description Resolves the Humanoid and movement root for either a character model instance or an
	entity-like table. Table inputs are first normalized through resolveCharacter, then the helper looks
	for the first Humanoid plus HumanoidRootPart, falling back to PrimaryPart when no explicit root exists.

	@param subject any -- Character model instance or entity table that can be resolved to one.
	@return (Humanoid?, BasePart?) -- The resolved Humanoid and root BasePart, or nil values when the subject is not a character model.
	@reads subject, character children, character.PrimaryPart
]=]

function EntityHelpers.getHumanoidAndRoot(subject: any): (Humanoid?, BasePart?)
	local character = if typeof(subject) == "Instance" then subject else resolveCharacter(subject)
	if not character or not character:IsA("Model") then
		return nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and not root:IsA("BasePart") then
		root = nil
	end
	return humanoid, root :: BasePart?
end
--[=[
	@description Resolves an entity to its character model and then returns the three pieces most gameplay
	systems need: the model itself, its Humanoid, and its root part. Missing entities or subjects that do
	not resolve to a Model produce all-nil results.

	@param charEntity any -- Entity table whose Instance (or client fallback character) should represent a living character model.
	@return (Instance?, Humanoid?, BasePart?) -- Character model, Humanoid, and root BasePart in that order; nils when resolution fails.
	@reads charEntity.Instance, Players.LocalPlayer.Character, character descendants
]=]

function EntityHelpers.getCharacterParts(charEntity: any): (Instance?, Humanoid?, BasePart?)
	if not charEntity then
		return nil, nil, nil
	end
	local character = resolveCharacter(charEntity)
	if not character or not character:IsA("Model") then
		return nil, nil, nil
	end
	local humanoid, root = EntityHelpers.getHumanoidAndRoot(character)
	return character, humanoid, root
end
--[=[
	@description Verifies that an entity can participate in gameplay by checking for a character model,
	a living Humanoid, and a usable root part. The first missing requirement returns false together with
	a human-readable failure reason that callers can surface in logs or transition failures.

	@param charEntity any -- Entity table expected to resolve to an active character.
	@return (boolean, string?) -- True when the character model, Humanoid, and root part all exist and the Humanoid is alive; otherwise false plus a failure reason.
]=]

function EntityHelpers.validateCharacterAlive(charEntity: any): (boolean, string?)
	local character, humanoid, root = EntityHelpers.getCharacterParts(charEntity)
	if not character then
		return false,"Character model not found"
	end
	if not humanoid or humanoid.Health <= 0 then
		return false,"Character cannot act"
	end
	if not root then
		return false,"HumanoidRootPart not found"
	end
	return true, nil
end
--[=[
	@description Reports whether a character entity is currently under hard crowd control by checking the
	replicated stun and knock flags used throughout combat and movement FSMs.

	@param charEntity any -- Character entity exposing IsStunned and/or IsKnocked flags.
	@return boolean -- True when either IsStunned or IsKnocked is set to true.
	@reads charEntity.IsStunned, charEntity.IsKnocked
]=]

function EntityHelpers.isCrowdControlled(charEntity: any): boolean
	return charEntity.IsStunned == true or charEntity.IsKnocked == true
end
--[=[
	@description Pushes replicated health values from a character entity onto the live Humanoid. MaxHealth
	is applied first when valid, then Health is clamped into the Humanoid's current max range, written back
	onto the entity, and mirrored to Humanoid.Health so server and character model stay in sync.

	@param charEntity any -- Character entity whose Health and MaxHealth fields should drive the live Humanoid.
	@return nil
	@reads charEntity.Health, charEntity.MaxHealth, character humanoid
	@writes charEntity.Health, humanoid.MaxHealth, humanoid.Health
]=]

function EntityHelpers.syncHumanoidFromEntity(charEntity: any)
	local _, humanoid = EntityHelpers.getCharacterParts(charEntity)
	if humanoid then
		if typeof(charEntity.MaxHealth) == "number" and charEntity.MaxHealth > 0 then
			humanoid.MaxHealth = charEntity.MaxHealth
		end
		if typeof(charEntity.Health) == "number" then
			charEntity.Health = math.clamp(charEntity.Health, 0, humanoid.MaxHealth)
			humanoid.Health = charEntity.Health
		end
	end
end

return EntityHelpers
