--!nocheck
-- @Name Test_EquipJob
-- @Author iKrypto
-- @Description Unit tests for EquipJob module loading and request validation flow.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TestBase = require((script.Parent:FindFirstChild("TestBase") or script.Parent.Parent:FindFirstChild("TestBase")) :: any)

local Test_EquipJob = {}

local function findModule(moduleName: string, ancestorNames: { string }): ModuleScript
	for _, descendant in ipairs(game:GetDescendants()) do
		if descendant:IsA("ModuleScript") and descendant.Name == moduleName then
			local current = descendant.Parent
			local matches = true
			for _, ancestorName in ipairs(ancestorNames) do
				if not current or current.Name ~= ancestorName then
					matches = false
					break
				end
				current = current.Parent
			end
			if matches then
				return descendant
			end
		end
	end
	error("Module not found: " .. moduleName)
end

local function cloneStateMachineModule(moduleName: string): ModuleScript
	local source = findModule(moduleName, { "StateMachines", "FSM", "RBXStateMachine" })
	local clone = source:Clone()
	clone.Name = moduleName .. "_TestClone"
	clone.Parent = ServerStorage
	return clone
end

local function loadEquipJob(orchestrator)
	local oldShared = {
		StateMachine = shared.StateMachine,
		fsm = shared.fsm,
		FSM = shared.FSM,
	}

	shared.StateMachine = {
		EquipJob = {
			Name = "EquipJob",
		},
	}
	shared.fsm = orchestrator
	shared.FSM = nil

	local clone = cloneStateMachineModule("EquipJob")
	local ok, result = pcall(require, clone)

	local function cleanup()
		shared.StateMachine = oldShared.StateMachine
		shared.fsm = oldShared.fsm
		shared.FSM = oldShared.FSM
		if clone.Parent then
			clone:Destroy()
		end
	end

	return ok, result, cleanup
end

local function setupAssets(assetIds: { string })
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local createdAssetsRoot = false
	if not assets then
		assets = Instance.new("Folder")
		assets.Name = "Assets"
		assets.Parent = ReplicatedStorage
		createdAssetsRoot = true
	end

	local createdAssets = {}
	for _, assetId in ipairs(assetIds) do
		if not assets:FindFirstChild(assetId) then
			local asset = Instance.new("Folder")
			asset.Name = assetId
			asset.Parent = assets
			table.insert(createdAssets, asset)
		end
	end

	return function()
		for _, asset in ipairs(createdAssets) do
			if asset.Parent then
				asset:Destroy()
			end
		end
		if createdAssetsRoot and assets.Parent then
			assets:Destroy()
		end
	end
end

local function captureStates(job)
	local states = {}
	job.AddState = function(self, name, definition, transitions)
		if type(definition) == "function" then
			definition = { OnEnter = definition }
		end
		states[name] = {
			Definition = definition,
			Transitions = transitions,
		}
	end
	job:RegisterStates()
	return states
end

function Test_EquipJob.Run()
	local tester = TestBase.new("EquipJob")

	tester:RunTest("Module loads and exposes expected API", function(t)
		local ok, job, cleanup = loadEquipJob({ GetEntity = function() return nil end })
		t:Assert(ok, "EquipJob should require without error when shared.StateMachine.EquipJob is registered")
		if not ok then
			cleanup()
			return
		end
		t:AssertEquals(job.Name, "EquipJob", "EquipJob should keep its declared Name")
		t:Assert(type(job.RegisterStates) == "function", "EquipJob should expose RegisterStates")
		if type(job.RegisterStates) ~= "function" then
			cleanup()
			return
		end

		local states = captureStates(job)
		t:Assert(states.ValidateRequest ~= nil, "EquipJob should register ValidateRequest")
		t:Assert(states.CommitState ~= nil, "EquipJob should register CommitState")
		t:Assert(states.ReleaseEquipLock ~= nil, "EquipJob should register ReleaseEquipLock")
		cleanup()
	end)

	tester:RunTest("ValidateRequest checks required context fields", function(t)
		local entities = {
			Char_01 = {
				EntityId = "Char_01",
			},
			Player_01 = {
				EntityId = "Player_01",
				Inventory = { "Sword01", "Shield01", "Ghost01" },
			},
		}
		local orchestrator = {
			GetEntity = function(entityId)
				return entities[entityId]
			end,
		}
		local cleanupAssets = setupAssets({ "Sword01", "Shield01", "Hammer01" })
		local ok, job, cleanup = loadEquipJob(orchestrator)
		local function cleanupAll()
			cleanupAssets()
			cleanup()
		end
		t:Assert(ok, "EquipJob should load for validation tests")
		if not ok then
			cleanupAll()
			return
		end
		if type(job.RegisterStates) ~= "function" then
			t:Assert(false, "EquipJob should expose RegisterStates for validation tests")
			cleanupAll()
			return
		end

		local states = captureStates(job)
		local validateRequest = states.ValidateRequest.Definition.OnEnter

		local function runValidate(context)
			local fsm = {
				CharacterEntityId = context.CharacterEntityId,
				PlayerEntityId = context.PlayerEntityId,
				ItemId = context.ItemId,
				Hand = context.Hand,
				Context = {},
				Failure = nil,
				State = nil,
			}
			function fsm:Fail(reason)
				self.Failure = reason
			end
			validateRequest(nil, fsm)
			return fsm
		end

		local missingCharacter = runValidate({ CharacterEntityId = "Missing", PlayerEntityId = "Player_01", ItemId = "Sword01" })
		t:AssertEquals(missingCharacter.Failure, "CharacterEntity not found", "ValidateRequest should require a valid character entity")

		local missingPlayer = runValidate({ CharacterEntityId = "Char_01", PlayerEntityId = "Missing", ItemId = "Sword01" })
		t:AssertEquals(missingPlayer.Failure, "PlayerEntity not found", "ValidateRequest should require a valid player entity")

		local missingItem = runValidate({ CharacterEntityId = "Char_01", PlayerEntityId = "Player_01", ItemId = nil })
		t:AssertEquals(missingItem.Failure, "No ItemId provided", "ValidateRequest should require ItemId")

		local missingAsset = runValidate({ CharacterEntityId = "Char_01", PlayerEntityId = "Player_01", ItemId = "Ghost01" })
		t:AssertEquals(missingAsset.Failure, "Asset not found for item: Ghost01", "ValidateRequest should reject items whose assets are missing")

		local invalidHand = runValidate({ CharacterEntityId = "Char_01", PlayerEntityId = "Player_01", ItemId = "Sword01", Hand = "Foot" })
		t:AssertEquals(invalidHand.Failure, "Invalid hand: Foot", "ValidateRequest should reject invalid hands")

		local missingInventoryItem = runValidate({ CharacterEntityId = "Char_01", PlayerEntityId = "Player_01", ItemId = "Hammer01", Hand = "Right" })
		t:AssertEquals(missingInventoryItem.Failure, "Item Hammer01 not in inventory", "ValidateRequest should reject items not present in inventory")

		local success = runValidate({ CharacterEntityId = "Char_01", PlayerEntityId = "Player_01", ItemId = "Sword01" })
		t:AssertEquals(success.Failure, nil, "ValidateRequest should accept a valid request")
		t:AssertEquals(success.Context.Hand, "Right", "ValidateRequest should default Hand to Right")
		t:AssertEquals(success.Context.ItemId, "Sword01", "ValidateRequest should store ItemId in context")
		t:AssertEquals(success.State, "AcquireEquipLock", "ValidateRequest should advance to AcquireEquipLock on success")
		cleanupAll()
	end)

	return tester:PrintSummary()
end

return Test_EquipJob
