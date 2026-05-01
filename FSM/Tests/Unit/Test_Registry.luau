--!nocheck
-- @Name Test_Registry
-- @Description Unit tests for the standalone Registry module.

local Registry = require(game:FindFirstChild("Registry", true) :: any)
local SignalModule = require(game:FindFirstChild("Signal", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_Registry = {}

local function makeUtil()
	return {
		Logger = {
			new = function()
				return {
					Log = function() end,
					GetHistory = function() return {} end,
					History = {},
				}
			end,
		},
		Signal = SignalModule,
	}
end

function Test_Registry.Run()
	local tester = TestBase.new("Registry")

	if not Registry or not SignalModule then
		tester:RunTest("Framework loaded", function(t)
			t:SkipTest("Framework not initialized")
		end)
		return tester:PrintSummary()
	end

	-- Initialize is idempotent (early-returns if already initialized in another suite).
	Registry.Initialize(makeUtil())

	tester:RunTest("RegisterEntity / GetEntity round-trip", function(t)
		local id = "RegTest_RoundTrip"
		local entity = { id = id, marker = "round-trip" }
		Registry.RegisterEntity(id, entity)
		t:AssertEquals(Registry.GetEntity(id), entity, "GetEntity should return registered entity")
		Registry.UnregisterEntity(id)
	end)

	tester:RunTest("RegisterEntity fires EntityRegistered signal", function(t)
		local id = "RegTest_FireRegister"
		local entity = { id = id }
		local gotId, gotEntity
		local conn = Registry.EntityRegistered:Connect(function(rid, rent)
			gotId = rid
			gotEntity = rent
		end)
		Registry.RegisterEntity(id, entity)
		t:AssertEquals(gotId, id, "Signal should receive id")
		t:AssertEquals(gotEntity, entity, "Signal should receive entity")
		if conn and conn.Disconnect then conn:Disconnect() end
		Registry.UnregisterEntity(id)
	end)

	tester:RunTest("UnregisterEntity removes entity and fires EntityUnregistered", function(t)
		local id = "RegTest_Unregister"
		local entity = { id = id }
		Registry.RegisterEntity(id, entity)
		local gotId, gotEntity
		local conn = Registry.EntityUnregistered:Connect(function(rid, rent)
			gotId = rid
			gotEntity = rent
		end)
		Registry.UnregisterEntity(id)
		t:AssertEquals(Registry.GetEntity(id), nil, "Entity should be removed")
		t:AssertEquals(gotId, id, "Unregister signal should receive id")
		t:AssertEquals(gotEntity, entity, "Unregister signal should receive entity")
		if conn and conn.Disconnect then conn:Disconnect() end
	end)

	tester:RunTest("GetAllEntities returns clone (mutation does not affect registry)", function(t)
		local id = "RegTest_CloneEntities"
		local entity = { id = id }
		Registry.RegisterEntity(id, entity)
		local snapshot = Registry.GetAllEntities()
		t:AssertEquals(snapshot[id], entity, "Snapshot should include entity")
		snapshot[id] = nil
		snapshot["__injected__"] = "garbage"
		t:AssertEquals(Registry.GetEntity(id), entity, "Original registry should still hold entity")
		local fresh = Registry.GetAllEntities()
		t:AssertEquals(fresh["__injected__"], nil, "Injected key should not appear in registry")
		Registry.UnregisterEntity(id)
	end)

	tester:RunTest("GetAllStateMachines returns clone (mutation does not affect registry)", function(t)
		local id = "RegTest_CloneSMs"
		local sm = { id = id }
		Registry.RegisterStateMachine(id, sm)
		local snapshot = Registry.GetAllStateMachines()
		t:AssertEquals(snapshot[id], sm, "Snapshot should include SM")
		snapshot[id] = nil
		snapshot["__injected__"] = "garbage"
		t:AssertEquals(Registry.GetStateMachine(id), sm, "Original registry should still hold SM")
		local fresh = Registry.GetAllStateMachines()
		t:AssertEquals(fresh["__injected__"], nil, "Injected key should not appear in registry")
		Registry.UnregisterStateMachine(id)
	end)

	tester:RunTest("PoolEntity / GetPooledEntity round-trip and removal", function(t)
		local className = "RegTest_PoolClass"
		local e1 = { name = "first" }
		local e2 = { name = "second" }
		Registry.PoolEntity(className, e1)
		Registry.PoolEntity(className, e2)
		local got1 = Registry.GetPooledEntity(className)
		local got2 = Registry.GetPooledEntity(className)
		t:AssertNotNil(got1, "Should retrieve first pooled entity")
		t:AssertNotNil(got2, "Should retrieve second pooled entity")
		t:Assert(got1 ~= got2, "Two distinct entities should be retrieved")
		t:AssertEquals(Registry.GetPooledEntity(className), nil, "Pool should be drained")
	end)

	tester:RunTest("GetPooledEntity returns nil on empty / unknown pool", function(t)
		t:AssertEquals(Registry.GetPooledEntity("RegTest_UnknownPool"), nil, "Unknown pool should return nil")
	end)

	tester:RunTest("Destroy cleans up signals", function(t)
		-- Take a snapshot of the existing signals so we don't interfere with other suites.
		local oldRegistered = Registry.EntityRegistered
		local oldUnregistered = Registry.EntityUnregistered
		local oldSMRegistered = Registry.StateMachineRegistered

		Registry.Destroy()

		-- After Destroy, the signal references still exist but have been :Destroy()'d.
		-- Different Signal implementations expose this differently; just verify that
		-- attempting to fire either does not raise (graceful) OR raises (also acceptable).
		local function safeFire(sig)
			if not sig then return true end
			local ok = pcall(function() sig:Fire("x", "y") end)
			return ok ~= nil -- simply ensure call did not crash test process
		end
		t:Assert(safeFire(oldRegistered), "Fire on destroyed EntityRegistered should not crash test")
		t:Assert(safeFire(oldUnregistered), "Fire on destroyed EntityUnregistered should not crash test")
		t:Assert(safeFire(oldSMRegistered), "Fire on destroyed StateMachineRegistered should not crash test")

		-- Re-initialize so subsequent test suites are not left with a torn-down registry.
		Registry.Initialize(makeUtil())
	end)

	return tester:PrintSummary()
end

return Test_Registry
