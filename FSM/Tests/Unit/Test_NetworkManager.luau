--!nocheck
-- @Name Test_NetworkManager
-- @Author iKrypto (audit)
-- @Description Unit tests for NetworkManager callback registration and event bus.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_NetworkManager = {}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

function Test_NetworkManager.Run()
	local tester = TestBase.new("NetworkManager")

	-- Try to get NetworkManager from the already-initialized Orchestrator
	local NetworkManager
	local ok, err = pcall(function()
		NetworkManager = require(game:FindFirstChild("NetworkManager", true) :: any)
	end)
	if not ok or not NetworkManager then
		tester:RunTest("NetworkManager available", function(t)
			t:SkipTest("NetworkManager module not found: " .. tostring(err))
		end)
		return tester:PrintSummary()
	end

	-- TEST 1: RegisterServerRequest stores sync handler (server only)
	tester:RunTest("RegisterServerRequest stores sync handler", function(t)
		if not RunService:IsServer() then
			t:SkipTest("Server-only test")
			return
		end

		local handlerCalled = false
		local testHandler = function(player, ...)
			handlerCalled = true
			return "OK"
		end

		NetworkManager.RegisterServerRequest("TestSyncRequest", testHandler, false)
		t:Assert(
			NetworkManager.ServerRequestCallbacksSync["TestSyncRequest"] == testHandler,
			"Sync handler should be stored"
		)

		-- Cleanup
		NetworkManager.ServerRequestCallbacksSync["TestSyncRequest"] = nil
	end)

	-- TEST 2: RegisterServerRequest stores async handler (server only)
	tester:RunTest("RegisterServerRequest stores async handler", function(t)
		if not RunService:IsServer() then
			t:SkipTest("Server-only test")
			return
		end

		local testHandler = function(player, ...) end
		NetworkManager.RegisterServerRequest("TestAsyncRequest", testHandler, true)
		t:Assert(
			NetworkManager.ServerRequestCallbacksAsync["TestAsyncRequest"] == testHandler,
			"Async handler should be stored"
		)

		-- Cleanup
		NetworkManager.ServerRequestCallbacksAsync["TestAsyncRequest"] = nil
	end)

	-- TEST 3: RegisterEntityCommand stores handler
	tester:RunTest("RegisterEntityCommand stores handler", function(t)
		local testHandler = function(player, ...) end
		NetworkManager.RegisterEntityCommand("TestEntity", "TestCommand", testHandler)

		t:Assert(
			NetworkManager.EntityCommandCallbacks["TestEntity"] ~= nil,
			"Entity callbacks should exist"
		)
		t:Assert(
			NetworkManager.EntityCommandCallbacks["TestEntity"]["TestCommand"] == testHandler,
			"Command handler should be stored"
		)

		-- Cleanup
		NetworkManager.EntityCommandCallbacks["TestEntity"] = nil
	end)

	-- TEST 4: UnregisterEntityCommands clears handlers (server only)
	tester:RunTest("UnregisterEntityCommands clears handlers", function(t)
		if not RunService:IsServer() then
			t:SkipTest("Server-only test")
			return
		end

		NetworkManager.RegisterEntityCommand("CleanupEntity", "Cmd1", function() end)
		NetworkManager.RegisterEntityCommand("CleanupEntity", "Cmd2", function() end)
		t:Assert(NetworkManager.EntityCommandCallbacks["CleanupEntity"] ~= nil, "Should have handlers")

		NetworkManager.UnregisterEntityCommands("CleanupEntity")
		t:Assert(
			NetworkManager.EntityCommandCallbacks["CleanupEntity"] == nil,
			"Should clear all handlers for entity"
		)
	end)

	-- TEST 5: EventBus registration creates signal
	tester:RunTest("EventBus registration creates signal", function(t)
		local busName = "NMTestBus_" .. tostring(os.clock())
		local bus = NetworkManager.RegisterEventBus(busName)
		t:Assert(bus ~= nil, "Should create event bus")
		t:Assert(type(bus.Connect) == "function", "Bus should have Connect method")
		t:Assert(type(bus.Fire) == "function", "Bus should have Fire method")

		-- Cleanup
		NetworkManager.UnregisterEventBus(busName)
	end)

	-- TEST 6: EventBus fire/listen round-trip
	tester:RunTest("EventBus fire and listen", function(t)
		local busName = "NMRoundTrip_" .. tostring(os.clock())
		local bus = NetworkManager.RegisterEventBus(busName)
		local received = nil

		bus:Connect(function(val)
			received = val
		end)

		NetworkManager.FireEventBus(busName, "hello")
		waitFor(function() return received ~= nil end, 1)
		t:AssertEquals(received, "hello", "Should receive fired payload")

		-- Cleanup
		NetworkManager.UnregisterEventBus(busName)
	end)

	-- TEST 7: Duplicate RegisterEventBus returns same bus
	tester:RunTest("Duplicate RegisterEventBus returns same bus", function(t)
		local busName = "NMDuplicate_" .. tostring(os.clock())
		local bus1 = NetworkManager.RegisterEventBus(busName)
		local bus2 = NetworkManager.RegisterEventBus(busName)
		t:AssertEquals(bus1, bus2, "Should return same bus on duplicate registration")

		-- Cleanup
		NetworkManager.UnregisterEventBus(busName)
	end)

	-- TEST 8: AwaitEventBus returns existing bus immediately
	tester:RunTest("AwaitEventBus returns existing bus", function(t)
		local busName = "NMAwait_" .. tostring(os.clock())
		local bus = NetworkManager.RegisterEventBus(busName)
		local awaited = NetworkManager.AwaitEventBus(busName, 0.1)
		t:AssertEquals(bus, awaited, "Should return existing bus immediately")

		-- Cleanup
		NetworkManager.UnregisterEventBus(busName)
	end)

	-- TEST 9: AwaitEventBus times out for missing bus
	tester:RunTest("AwaitEventBus timeout", function(t)
		local result = NetworkManager.AwaitEventBus("NMNonExistent_" .. tostring(os.clock()), 0.05)
		t:Assert(result == nil, "Should return nil on timeout")
	end)

	-- TEST 10: GetEventBus returns nil for unregistered bus
	tester:RunTest("GetEventBus returns nil for unknown", function(t)
		local result = NetworkManager.GetEventBus("NMUnknown_" .. tostring(os.clock()))
		t:Assert(result == nil, "Should return nil for unregistered bus")
	end)

	return tester:PrintSummary()
end

return Test_NetworkManager
