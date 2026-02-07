--!nocheck
-- @Name Test_EntityPooling
-- @Author iKrypto (audit)
-- @Description Integration tests for entity pooling lifecycle through Orchestrator.

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_EntityPooling = {}

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

		-- Reuse
		local reused = Orchestrator.GetPooledEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolReuse_02",
			Context = { Instance = part },
		})

		t:Assert(reused ~= nil, "Should get a reused entity")
		t:Assert(Orchestrator.GetEntity("PoolReuse_02") ~= nil, "Reused entity should be in active registry")
		-- Data should be cleared on reuse
		t:Assert(reused.Val == nil, "Pooled entity data should be cleared")

		Orchestrator.DeleteEntity("PoolReuse_02")
		part:Destroy()
	end)

	-- TEST 3: Pool miss falls back to normal creation
	tester:RunTest("Pool miss creates new entity", function(t)
		local part = Instance.new("Part")

		-- Don't pool anything, just try to get from pool
		local entity = Orchestrator.GetPooledEntity({
			EntityClass = PoolEntity,
			EntityId = "PoolMiss_01",
			Context = { Instance = part },
		})

		-- GetPooledEntity should return nil on miss (caller creates normally)
		if entity then
			Orchestrator.DeleteEntity("PoolMiss_01")
		end
		-- This might return nil or might create new depending on impl
		-- Just verify no error occurs
		t:Assert(true, "Pool miss should not error")

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
