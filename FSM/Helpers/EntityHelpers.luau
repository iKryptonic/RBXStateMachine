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
	@description Extracts a Humanoid and root BasePart from either a character Instance or an entity that can be resolved to one. Non-Model subjects and characters without valid base-part roots return nil values.
	@param subject any -- Character Model instance or entity table accepted by resolveCharacter.
	@return Humanoid? -- The character's Humanoid instance when present.
	@return BasePart? -- HumanoidRootPart when present, otherwise PrimaryPart if it is a BasePart.
	@reads subject, resolved character descendants Humanoid and HumanoidRootPart, character.PrimaryPart
	@writes None
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
	@description Resolves the entity's character model and returns the model, humanoid, and root together for callers that need all three. Nil is returned for every value when the entity cannot be resolved to a character model.
	@param charEntity any -- Entity table expected to reference a character instance.
	@return Instance? -- Character model instance when resolved.
	@return Humanoid? -- Character humanoid when present.
	@return BasePart? -- Character root part when present.
	@reads charEntity.Instance, Players.LocalPlayer.Character, character humanoid/root descendants
	@writes None
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
	@description Validates that the entity has a character model, a living humanoid, and a root part suitable for action-oriented FSM states. Failure reasons are returned as user-readable strings for state failure or logging paths.
	@param charEntity any -- Entity table expected to represent an actor character.
	@return boolean -- True when the character exists, is alive, and has a root part.
	@return string? -- Failure reason when validation fails, otherwise nil.
	@reads charEntity.Instance, Players.LocalPlayer.Character, humanoid.Health, root existence
	@writes None
]=]
function EntityHelpers.validateCharacterAlive(charEntity: any): (boolean, string?)
	local character, humanoid, root = EntityHelpers.getCharacterParts(charEntity)
	if not character then
		return false, "Character model not found"
	end
	if not humanoid or humanoid.Health <= 0 then
		return false, "Character cannot act"
	end
	if not root then
		return false, "HumanoidRootPart not found"
	end
	return true, nil
end

--[=[
	@description Reports whether the entity is currently under simple crowd-control flags checked by common FSM guards. The helper only inspects IsStunned and IsKnocked flags.
	@param charEntity any -- Entity table containing crowd-control state flags.
	@return boolean -- True when either IsStunned or IsKnocked is explicitly true.
	@reads charEntity.IsStunned, charEntity.IsKnocked
	@writes None
]=]
function EntityHelpers.isCrowdControlled(charEntity: any): boolean
	return charEntity.IsStunned == true or charEntity.IsKnocked == true
end

--[=[
	@description Pushes entity health values onto the resolved humanoid so Roblox character health mirrors replicated entity state. MaxHealth is updated first when valid, then entity Health is clamped into the humanoid's current max before being assigned.
	@param charEntity any -- Entity table containing Health and MaxHealth fields and optionally Instance.
	@return nil -- No explicit return value.
	@reads charEntity.Instance, Players.LocalPlayer.Character, charEntity.MaxHealth, charEntity.Health, humanoid.MaxHealth
	@writes humanoid.MaxHealth, charEntity.Health, humanoid.Health
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
