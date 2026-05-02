--!strict

local Players = game:GetService("Players")

local EntityHelpers = {}

-- Resolve character model from entity, with LocalPlayer fallback for client FSMs
local function resolveCharacter(charEntity: any): Instance?
	if charEntity and charEntity.Instance then
		return charEntity.Instance
	end
	-- Fallback for client-side: entity.Instance may not be set
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		return localPlayer.Character
	end
	return nil
end

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

function EntityHelpers.isCrowdControlled(charEntity: any): boolean
	return charEntity.IsStunned == true or charEntity.IsKnocked == true
end

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
