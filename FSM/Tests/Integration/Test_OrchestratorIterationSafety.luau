--!nocheck
-- @Name Test_OrchestratorIterationSafety
-- @Description Verifies DeleteAllEntities/CancelAll are safe against mutation-during-iteration,
--              and that GetEntities returns a defensive clone.

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local BaseStateMachine = require(game:FindFirstChild("BaseStateMachine", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local TestUtils = require(script.Parent:FindFirstChild("TestUtils") :: any)

local Test_OrchestratorIterationSafety = {}

local waitFor = TestUtils and TestUtils.WaitFor or function(pred, timeout)
	local t0 = os.clock()
	while not pred() and (os.clock() - t0) < (timeout or 1) do
		task.wait()
	end
end

function Test_OrchestratorIterationSafety.Run()
	local tester = TestBase.new("OrchestratorIterationSafety")

	if not Orchestrator or not BaseEntity or not BaseStateMachine then
		tester:RunTest("Framework loaded", function(t)
			t:SkipTest("Framework not initialized")
		end)
		return tester:PrintSummary()
	end

	local IterEntity = BaseEntity.Extend({
		Name = "IterSafetyEntity",
		Schema = { Val = { Type = "number" } },
	})
	function IterEntity:ApplyChanges(changes) end
	function IterEntity:GetContext() return {} end
	function IterEntity:OnCleanup() end

	local IterFSM = BaseStateMachine.Extend({ className = "IterSafetyFSM", validStates = { "Idle" } })
	function IterFSM:RegisterStates() self:AddState("Idle", function() end) end
	function IterFSM:OnCleanup() end

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

	tester:RunTest("DeleteAllEntities removes all entities even when Destroy auto-unregisters", function(t)
		-- Cleanly start from no entities.
		Orchestrator.DeleteAllEntities()
		t:Assert(next(Orchestrator.GetEntities()) == nil, "Should start empty")

		local N = 12
		for i = 1, N do
			local id = "IterSafe_E_" .. tostring(i)
			Orchestrator.CreateEntity({
				EntityClass = IterEntity,
				EntityId = id,
				Context = { Instance = newPart() },
			})
		end

		local activeBefore = 0
		for _ in pairs(Orchestrator.GetEntities()) do activeBefore += 1 end
		t:AssertEquals(activeBefore, N, "Should have N entities active before DeleteAllEntities")

		Orchestrator.DeleteAllEntities()
		t:Assert(next(Orchestrator.GetEntities()) == nil,
			"All entities should be removed after DeleteAllEntities, even when Destroy auto-unregisters during iteration")

		cleanupParts()
	end)

	tester:RunTest("CancelAll cancels all SMs even when Cancel auto-unregisters", function(t)
		-- Cleanly start from no SMs.
		Orchestrator.CancelAll()
		waitFor(function() return next(Orchestrator.GetStateMachines()) == nil end, 2)

		local N = 12
		for i = 1, N do
			local id = "IterSafe_F_" .. tostring(i)
			Orchestrator.CreateStateMachine({
				StateMachineClass = IterFSM,
				StateMachineId = id,
				Context = {},
			})
		end

		local activeBefore = 0
		for _ in pairs(Orchestrator.GetStateMachines()) do activeBefore += 1 end
		t:AssertEquals(activeBefore, N, "Should have N SMs active before CancelAll")

		Orchestrator.CancelAll()
		waitFor(function() return next(Orchestrator.GetStateMachines()) == nil end, 6)
		t:Assert(next(Orchestrator.GetStateMachines()) == nil,
			"All SMs should be removed after CancelAll, even when Cancel auto-unregisters during iteration")
	end)

	tester:RunTest("GetEntities returns clone — mutating it doesn't corrupt registry", function(t)
		Orchestrator.DeleteAllEntities()
		local idA, idB = "IterSafe_Clone_A", "IterSafe_Clone_B"
		Orchestrator.CreateEntity({
			EntityClass = IterEntity,
			EntityId = idA,
			Context = { Instance = newPart() },
		})
		Orchestrator.CreateEntity({
			EntityClass = IterEntity,
			EntityId = idB,
			Context = { Instance = newPart() },
		})

		local copy = Orchestrator.GetEntities()
		t:AssertNotNil(copy[idA], "Clone should contain idA")
		t:AssertNotNil(copy[idB], "Clone should contain idB")

		copy[idA] = nil
		copy["__bogus__"] = "garbage"

		t:AssertNotNil(Orchestrator.GetEntity(idA), "Mutating clone must not remove idA from registry")
		t:AssertNotNil(Orchestrator.GetEntity(idB), "idB should still be in registry")

		local fresh = Orchestrator.GetEntities()
		t:AssertEquals(fresh["__bogus__"], nil, "Bogus key from mutated clone must not appear in fresh snapshot")

		Orchestrator.DeleteAllEntities()
		cleanupParts()
	end)

	return tester:PrintSummary()
end

return Test_OrchestratorIterationSafety
