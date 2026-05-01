--!nocheck
-- @Name Test_PoolReuseReset
-- @Description Verifies that the Factory's pool-reuse path fully resets entity state.

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_PoolReuseReset = {}

function Test_PoolReuseReset.Run()
	local tester = TestBase.new("PoolReuseReset")

	if not Orchestrator or not BaseEntity then
		tester:RunTest("Framework loaded", function(t)
			t:SkipTest("Framework not initialized")
		end)
		return tester:PrintSummary()
	end

	local TestEntity = BaseEntity.Extend({
		Name = "PoolResetEntity",
		Schema = { Val = { Type = "number" } },
	})
	function TestEntity:ApplyChanges(changes) end
	function TestEntity:GetContext() return {} end
	function TestEntity:OnCleanup() end

	local createdParts = {}
	local function newPart()
		local p = Instance.new("Part")
		table.insert(createdParts, p)
		return p
	end
	local function cleanupParts()
		for _, p in ipairs(createdParts) do
			pcall(function() p:Destroy() end)
		end
		createdParts = {}
	end

	tester:RunTest("Pool reuse resets Version to 0", function(t)
		local original = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Version_A",
			Context = { Instance = newPart() },
		})
		t:AssertNotNil(original, "Should create original entity")
		original.Val = 5
		original:UpdateEntity()
		-- Wait briefly for any deferred updates to settle.
		task.wait(0.05)
		t:Assert(original._privateProperties.Version > 0, "Version should be > 0 before pooling")

		Orchestrator.PoolEntity("PRR_Version_A")

		local reused = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Version_B",
			Context = { Instance = newPart() },
		})
		t:AssertEquals(reused, original, "Should reuse pooled entity")
		t:AssertEquals(reused._privateProperties.Version, 0, "Version should be reset to 0 on reuse")

		Orchestrator.DeleteEntity("PRR_Version_B")
	end)

	tester:RunTest("Pool reuse clears Data and Pending tables", function(t)
		local original = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Data_A",
			Context = { Instance = newPart() },
		})
		original.Val = 99
		original:UpdateEntity()
		task.wait(0.05)

		Orchestrator.PoolEntity("PRR_Data_A")

		local reused = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Data_B",
			Context = { Instance = newPart() },
		})
		t:AssertEquals(reused, original, "Should reuse pooled entity")
		t:Assert(next(reused._privateProperties.Data) == nil, "Data should be empty after reuse")
		t:Assert(next(reused._privateProperties.Pending) == nil, "Pending should be empty after reuse")

		Orchestrator.DeleteEntity("PRR_Data_B")
	end)

	tester:RunTest("Pool reuse resets EntityLocked to false", function(t)
		local original = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Lock_A",
			Context = { Instance = newPart() },
		})
		if type(original.AcquireLock) == "function" then
			pcall(function() original:AcquireLock("foo") end)
		else
			original._privateProperties.EntityLocked = true
		end
		t:AssertEquals(original._privateProperties.EntityLocked, true, "EntityLocked should be true before pooling")

		Orchestrator.PoolEntity("PRR_Lock_A")

		local reused = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Lock_B",
			Context = { Instance = newPart() },
		})
		t:AssertEquals(reused, original, "Should reuse pooled entity")
		t:AssertEquals(reused._privateProperties.EntityLocked, false, "EntityLocked should be reset to false on reuse")

		Orchestrator.DeleteEntity("PRR_Lock_B")
	end)

	tester:RunTest("Pool reuse clears Context (only new context keys remain)", function(t)
		local original = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Ctx_A",
			Context = { Instance = newPart(), CustomKey = "old-value", AnotherKey = 123 },
		})
		t:AssertEquals(original._privateProperties.Context.CustomKey, "old-value", "Old context should be set")
		t:AssertEquals(original._privateProperties.Context.AnotherKey, 123, "Old context should be set")

		Orchestrator.PoolEntity("PRR_Ctx_A")

		local reused = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Ctx_B",
			Context = { Instance = newPart(), NewKey = "new-value" },
		})
		t:AssertEquals(reused, original, "Should reuse pooled entity")
		t:AssertEquals(reused._privateProperties.Context.CustomKey, nil, "Old context CustomKey should be cleared")
		t:AssertEquals(reused._privateProperties.Context.AnotherKey, nil, "Old context AnotherKey should be cleared")
		t:AssertEquals(reused._privateProperties.Context.NewKey, "new-value", "New context key should be present")
		t:AssertEquals(reused._privateProperties.Context.EntityId, "PRR_Ctx_B", "EntityId in context should be the new id")

		Orchestrator.DeleteEntity("PRR_Ctx_B")
	end)

	tester:RunTest("Pool reuse creates fresh signals (different Signal instances)", function(t)
		local original = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Sig_A",
			Context = { Instance = newPart() },
		})
		local oldStateUpdated = original.StateUpdated
		local oldDestroyed = original.Destroyed
		t:AssertNotNil(oldStateUpdated, "Original should have StateUpdated signal")
		t:AssertNotNil(oldDestroyed, "Original should have Destroyed signal")

		Orchestrator.PoolEntity("PRR_Sig_A")

		local reused = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Sig_B",
			Context = { Instance = newPart() },
		})
		t:AssertEquals(reused, original, "Should reuse pooled entity")
		t:AssertNotEquals(reused.StateUpdated, oldStateUpdated, "StateUpdated should be a fresh signal instance")
		t:AssertNotEquals(reused.Destroyed, oldDestroyed, "Destroyed should be a fresh signal instance")

		Orchestrator.DeleteEntity("PRR_Sig_B")
	end)

	tester:RunTest("Pool reuse: old StateUpdated listeners do not fire on reused entity", function(t)
		local original = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Listener_A",
			Context = { Instance = newPart() },
		})

		local oldFired = false
		local conn = original.StateUpdated:Connect(function() oldFired = true end)

		Orchestrator.PoolEntity("PRR_Listener_A")

		local reused = Orchestrator.CreateEntity({
			EntityClass = TestEntity,
			EntityId = "PRR_Listener_B",
			Context = { Instance = newPart() },
		})
		t:AssertEquals(reused, original, "Should reuse pooled entity")

		reused.Val = 7
		reused:UpdateEntity()
		task.wait(0.1)

		t:Assert(not oldFired, "Old StateUpdated listener must NOT fire on reused entity")

		if conn and conn.Disconnect then pcall(function() conn:Disconnect() end) end
		Orchestrator.DeleteEntity("PRR_Listener_B")
	end)

	cleanupParts()
	return tester:PrintSummary()
end

return Test_PoolReuseReset
