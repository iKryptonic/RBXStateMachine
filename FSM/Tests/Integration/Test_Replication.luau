--!nocheck
-- @Name Test_Replication
-- @Author iKrypto (audit)
-- @Description Integration tests for entity replication filtering and lifecycle broadcasts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local Mocker = require(script.Parent.Parent:FindFirstChild("Mocker", true) :: any)

local Test_Replication = {}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

function Test_Replication.Run()
	local tester = TestBase.new("Replication")

	-- Define test entity with mixed replicate flags
	local ReplicatedEntity = BaseEntity.Extend({
		Name = "ReplicatedEntity",
		Schema = {
			Health = { Type = "number", Replicate = true },
			Score = { Type = "number", Replicate = true },
			InternalFlag = { Type = "boolean", Replicate = false },
			PrivateData = { Type = "string" }, -- No Replicate key at all
		},
	})
	function ReplicatedEntity:ApplyChanges(changes)
		-- Accept all changes for testing
	end
	function ReplicatedEntity:GetContext() return {} end

	-- TEST 1: StateUpdated fires on UpdateEntity
	tester:RunTest("StateUpdated fires on UpdateEntity", function(t)
		local part = Instance.new("Part")
		local entity = ReplicatedEntity.new({ Name = "RepTest1", Instance = part })

		local firedChanges = nil
		entity.StateUpdated:Connect(function(changes)
			firedChanges = changes
		end)

		entity.Health = 100
		entity:UpdateEntity()

		waitFor(function() return firedChanges ~= nil end, 1)
		t:Assert(firedChanges ~= nil, "StateUpdated should fire")
		t:Assert(firedChanges.Health ~= nil, "Changes should contain Health")
		t:AssertEquals(firedChanges.Health, 100, "Health should be 100")

		entity:Destroy()
		part:Destroy()
	end)

	-- TEST 2: Entity version increments
	tester:RunTest("Version increments on UpdateEntity", function(t)
		local part = Instance.new("Part")
		local entity = ReplicatedEntity.new({ Name = "RepTest2", Instance = part })

		entity.Health = 50
		entity:UpdateEntity()
		local v1 = entity.Version

		entity.Health = 75
		entity:UpdateEntity()
		local v2 = entity.Version

		t:Assert(v2 > v1, string.format("Version should increment (%d > %d)", v2, v1))

		entity:Destroy()
		part:Destroy()
	end)

	-- TEST 3: Serialize only includes Persist=true fields
	tester:RunTest("Serialize filters Persist fields", function(t)
		local PersistEntity = BaseEntity.Extend({
			Name = "PersistEntity",
			Schema = {
				SaveMe = { Type = "number", Persist = true },
				DontSave = { Type = "number", Persist = false },
				NoFlag = { Type = "number" },
			},
		})
		function PersistEntity:ApplyChanges() end
		function PersistEntity:GetContext() return {} end

		local part = Instance.new("Part")
		local entity = PersistEntity.new({ Name = "PersistTest", Instance = part })

		entity.SaveMe = 42
		entity.DontSave = 99
		entity.NoFlag = 10
		entity:UpdateEntity()

		local serialized = entity:Serialize()
		t:Assert(serialized.SaveMe ~= nil, "Persist=true field should be serialized")
		t:Assert(serialized.DontSave == nil, "Persist=false field should NOT be serialized")
		t:Assert(serialized.NoFlag == nil, "Field without Persist should NOT be serialized")

		entity:Destroy()
		part:Destroy()
	end)

	-- TEST 4: Deserialize applies data
	tester:RunTest("Deserialize applies data", function(t)
		local part = Instance.new("Part")
		local entity = ReplicatedEntity.new({ Name = "DeserTest", Instance = part })

		entity:Deserialize({ Health = 200, Score = 50 })

		t:AssertEquals(entity.Health, 200, "Health should be deserialized")
		t:AssertEquals(entity.Score, 50, "Score should be deserialized")

		entity:Destroy()
		part:Destroy()
	end)

	-- TEST 5: Destroyed entity fires Destroyed signal
	tester:RunTest("Destroyed fires on Destroy", function(t)
		local part = Instance.new("Part")
		local entity = ReplicatedEntity.new({ Name = "DestroyTest", Instance = part })

		local destroyed = false
		entity.Destroyed:Connect(function()
			destroyed = true
		end)

		entity:Destroy()
		waitFor(function() return destroyed end, 1)
		t:Assert(destroyed, "Destroyed signal should fire")

		part:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_Replication
