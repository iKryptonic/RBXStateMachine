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
	@description Implements `EntityHelpers.getHumanoidAndRoot`.
	@param subject any -- `subject` input parameter.
	@return (Humanoid?, BasePart?) -- Return value produced by the implementation, if any.
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
	@description Implements `EntityHelpers.getCharacterParts`.
	@param charEntity any -- `charEntity` input parameter.
	@return (Instance?, Humanoid?, BasePart?) -- Return value produced by the implementation, if any.
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
	@description Implements `EntityHelpers.validateCharacterAlive`.
	@param charEntity any -- `charEntity` input parameter.
	@return (boolean, string?) -- Return value produced by the implementation, if any.
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
	@description Implements `EntityHelpers.isCrowdControlled`.
	@param charEntity any -- `charEntity` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function EntityHelpers.isCrowdControlled(charEntity: any): boolean
	return charEntity.IsStunned == true or charEntity.IsKnocked == true
end
--[=[
	@description Implements `EntityHelpers.syncHumanoidFromEntity`.
	@param charEntity any -- `charEntity` input parameter.
	@return any -- Return value produced by the implementation, if any.
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
