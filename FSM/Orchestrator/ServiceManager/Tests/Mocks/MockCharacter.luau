--!strict

local Players = game:GetService("Players")

local MockHumanoid = {}
local MockCharacter = {}
local MockPlayer = {}

local DEFAULT_WALK_SPEED = 16

local function createPart(name: string, size: Vector3, cframe: CFrame, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Anchored = false
	part.CanCollide = false
	part.CFrame = cframe
	part.Parent = parent
	return part
end

function MockHumanoid.new(parent: Instance?, overrides: any?): Humanoid
	local config = overrides or {}
	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.MaxHealth = tonumber(config.MaxHealth) or 100
	humanoid.Health = tonumber(config.Health) or humanoid.MaxHealth
	humanoid.WalkSpeed = tonumber(config.WalkSpeed) or DEFAULT_WALK_SPEED
	if parent then
		humanoid.Parent = parent
	end
	if config.State ~= nil then
		pcall(function()
			humanoid:ChangeState(config.State)
		end)
	end
	return humanoid
end

function MockCharacter.new(name: string?, parent: Instance?, overrides: any?): (Model, Humanoid, BasePart, BasePart, BasePart)
	local config = overrides or {}
	local model = Instance.new("Model")
	model.Name = name or "MockCharacter"

	local root = createPart("HumanoidRootPart", Vector3.new(2, 2, 1), CFrame.new(0, 5, 0), model)
	local torso = createPart("Torso", Vector3.new(2, 2, 1), root.CFrame, model)
	local head = createPart("Head", Vector3.new(2, 1, 1), root.CFrame * CFrame.new(0, 1.5, 0), model)
	local rightArm = createPart("Right Arm", Vector3.new(1, 2, 1), root.CFrame * CFrame.new(1.5, 0, 0), model)
	local leftArm = createPart("Left Arm", Vector3.new(1, 2, 1), root.CFrame * CFrame.new(-1.5, 0, 0), model)
	local rightHand = createPart("RightHand", Vector3.new(1, 1, 1), rightArm.CFrame * CFrame.new(0, -1.5, 0), model)
	local leftHand = createPart("LeftHand", Vector3.new(1, 1, 1), leftArm.CFrame * CFrame.new(0, -1.5, 0), model)
	local humanoid = MockHumanoid.new(model, config.Humanoid)

	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.C0 = CFrame.new()
	rootJoint.Parent = root

	model.PrimaryPart = root
	if parent then
		model.Parent = parent
	end

	return model, humanoid, root, rightHand, leftHand
end

function MockPlayer.new(userId: number, character: Model?, parent: Instance?): (any, Instance)
	local playerGui = Instance.new("Folder")
	playerGui.Name = "PlayerGui"

	local player: any = {
		UserId = userId,
		Name = string.format("MockPlayer_%d", userId),
		DisplayName = string.format("MockPlayer_%d", userId),
		Character = character,
		Parent = parent or Players,
		PlayerGui = playerGui,
	}

	function player:IsA(className: string)
		return className == "Player"
	end

	function player:FindFirstChild(name: string)
		if name == "PlayerGui" then
			return self.PlayerGui
		elseif name == "Character" then
			return self.Character
		end
		return nil
	end

	function player:FindFirstChildOfClass(className: string)
		if className == "PlayerGui" then
			return self.PlayerGui
		end
		return nil
	end

	function player:WaitForChild(name: string, _timeout: number?)
		local child = self:FindFirstChild(name)
		if child ~= nil then
			return child
		end
		error(string.format("MockPlayer missing child %s", tostring(name)))
	end

	function player:SetCharacter(nextCharacter: Model?)
		self.Character = nextCharacter
	end

	return player, playerGui
end

return {
	MockCharacter = MockCharacter,
	MockPlayer = MockPlayer,
	MockHumanoid = MockHumanoid,
	newCharacter = MockCharacter.new,
	newPlayer = MockPlayer.new,
	newHumanoid = MockHumanoid.new,
}
