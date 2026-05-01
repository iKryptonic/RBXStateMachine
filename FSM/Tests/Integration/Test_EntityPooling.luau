--!nocheck
-- @Name Test_EntityPooling
-- @Author iKrypto (audit)
-- @Description Integration tests for entity pooling lifecycle through Orchestrator.

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local TestUtils = require(script.Parent.Parent:FindFirstChild("TestUtils") :: any)

local Test_EntityPooling = {}

local waitFor = TestUtils.WaitFor

function Test_EntityPooling.Run()
	local tester = TestBase.new("EntityPooling")

	-- Define poolable entity
	local PoolEntity = BaseEntity.Extend({
		Name = "PoolEntity",
		Schema = {
			Val = { Type = "number" },
			Label = { Type = "string" },
		},
	})
	function PoolEntity:ApplyChanges(changes) end
	function PoolEntity:GetContext() return {} end

	-- TEST 1: PoolEntity removes from active registry
	tester:RunTest("PoolEntity removes from active registry", function(t)
		local part = Instance.new("Part")
		local entity = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolTest_01",
			Context = { Instance = part },
		})
		t:Assert(entity ~= nil, "Entity should be created")
		t:Assert(Orchestrator.GetEntity("PoolTest_01") ~= nil, "Should be in active registry")

		Orchestrator.PoolEntity("PoolTest_01")
		t:Assert(Orchestrator.GetEntity("PoolTest_01") == nil, "Should be removed from active registry")

		part:Destroy()
	end)

	-- TEST 2: Pooled entity can be reused
	tester:RunTest("Pooled entity can be reused", function(t)
		local part = Instance.new("Part")

		-- Create and pool
		local original = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolReuse_01",
			Context = { Instance = part },
		})
		original.Val = 42
		original:UpdateEntity()

		Orchestrator.PoolEntity("PoolReuse_01")

		-- Reuse: Factory automatically returns a pooled instance when the EntityClass matches.
		local reused = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolReuse_02",
			Context = { Instance = part },
		})

		t:Assert(reused ~= nil, "Should get a reused entity")
		t:AssertEquals(reused, original, "Reused entity should be the same proxy reference as the pooled one")
		t:Assert(Orchestrator.GetEntity("PoolReuse_02") ~= nil, "Reused entity should be in active registry")
		-- Data should be cleared on reuse
		t:Assert(reused.Val == nil, "Pooled entity data should be cleared")

		Orchestrator.DeleteEntity("PoolReuse_02")
		part:Destroy()
	end)

	-- TEST 3: Pool miss creates new entity
	tester:RunTest("Pool miss creates new entity", function(t)
		local part1 = Instance.new("Part")
		local part2 = Instance.new("Part")

		-- Create one entity, pool it, and reuse it to drain the pool
		local first = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolMiss_A",
			Context = { Instance = part1 },
		})
		Orchestrator.PoolEntity("PoolMiss_A")

		local reused = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolMiss_B",
			Context = { Instance = part1 },
		})
		t:AssertEquals(reused, first, "Sanity: reused entity is the pooled one")

		-- Pool is now empty; creating another entity must produce a fresh proxy.
		local fresh = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolMiss_C",
			Context = { Instance = part2 },
		})
		t:Assert(fresh ~= nil, "Should create a new entity when pool is empty")
		t:AssertNotEquals(fresh, first, "Pool miss should produce a new instance (different reference)")

		Orchestrator.DeleteEntity("PoolMiss_B")
		Orchestrator.DeleteEntity("PoolMiss_C")
		part1:Destroy()
		part2:Destroy()
	end)

	-- TEST: Pool reuse resets state on the reused entity
	tester:RunTest("Pool reuse resets state", function(t)
		local part = Instance.new("Part")

		local original = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolReset_01",
			Context = { Instance = part },
		})
		original.Val = 7
		original.Label = "before"
		original:UpdateEntity()

		Orchestrator.PoolEntity("PoolReset_01")

		local reused = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolReset_02",
			Context = { Instance = part },
		})

		t:AssertNotNil(reused, "Should get a reused entity")
		t:AssertNotNil(reused._privateProperties, "Reused entity should expose _privateProperties")
		t:AssertEquals(reused._privateProperties.Version, 0, "Version should reset to 0 on reuse")
		t:AssertEquals(reused._privateProperties.EntityLocked, false, "EntityLocked should reset to false on reuse")
		t:Assert(next(reused._privateProperties.Data) == nil, "Data table should be empty on reuse")
		t:Assert(next(reused._privateProperties.Pending) == nil, "Pending table should be empty on reuse")

		Orchestrator.DeleteEntity("PoolReset_02")
		part:Destroy()
	end)

	-- TEST 4: Multiple entities of same class pool independently
	tester:RunTest("Multiple entities pool independently", function(t)
		local part1 = Instance.new("Part")
		local part2 = Instance.new("Part")

		local e1 = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolMulti_01",
			Context = { Instance = part1 },
		})
		local e2 = Orchestrator.CreateEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolMulti_02",
			Context = { Instance = part2 },
		})

		Orchestrator.PoolEntity("PoolMulti_01")
		Orchestrator.PoolEntity("PoolMulti_02")

		t:Assert(Orchestrator.GetEntity("PoolMulti_01") == nil, "First entity should be pooled")
		t:Assert(Orchestrator.GetEntity("PoolMulti_02") == nil, "Second entity should be pooled")

		part1:Destroy()
		part2:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_EntityPooling
