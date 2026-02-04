--!strict
-- @Name Test_Mocking
-- @Author iKrypto
-- @Description Unit tests demonstrating mock/spying usage.

local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local Mocker = require(script.Parent:WaitForChild("Mocks"):WaitForChild("Mocker") :: any)
local EntityPersistence = require(game:FindFirstChild("EntityPersistence", true) :: any)

local Test_Mocking = {}

function Test_Mocking.Run()
	local tester = TestBase.new("Mocking")

	tester:RunTest("Spy counts calls", function(t)
		local mocker = Mocker.new()
		local spy = mocker:Spy(function(a, b)
			return a + b
		end)

		local result = spy.Fn(2, 3)
		t:AssertEquals(result, 5, "Spy should return function result")
		t:AssertEquals(spy.CallCount, 1, "Spy should track call count")
		t:AssertEquals(spy.Calls[1][1], 2, "Spy should capture args")
		t:AssertEquals(spy.Calls[1][2], 3, "Spy should capture args")
	end)

	tester:RunTest("Stub replaces function and restores", function(t)
		local mocker = Mocker.new()
		local obj = {
			Value = 0,
			Increment = function(self, n)
				self.Value += n
			end
		}

		mocker:Stub(obj, "Increment", function(self, n)
			self.Value += (n * 2)
		end)

		obj:Increment(3)
		t:AssertEquals(obj.Value, 6, "Stubbed function should be used")

		mocker:RestoreAll()
		obj:Increment(3)
		t:AssertEquals(obj.Value, 9, "Original function should be restored")
	end)

	tester:RunTest("Mock dependency with verify", function(t)
		local mocker = Mocker.new()
		local dependency = {
			Send = function(_, _) end,
		}

		local spy = mocker:Spy(function(_, payload)
			return payload and payload.Id
		end)
		mocker:Stub(dependency, "Send", spy.Fn)

		local result = dependency:Send({ Id = "ABC" })
		t:AssertEquals(result, "ABC", "Mock should return stubbed value")
		t:AssertEquals(spy.CallCount, 1, "Mock should capture call count")
		t:AssertEquals(spy.Calls[1][2].Id, "ABC", "Mock should capture payload")

		mocker:RestoreAll()
	end)

	tester:RunTest("Mock persistence datastore calls", function(t)
		local mocker = Mocker.new()
		local fakeStore = {}
		local ds = {
			SetAsync = function(_, key, value)
				fakeStore[key] = value
				return true, value, nil
			end,
			GetAsync = function(_, key)
				return true, fakeStore[key], nil
			end,
			EnableRetry = function() end,
			SetRetryConfig = function() end,
		}

		local setSpy = mocker:Spy(ds.SetAsync)
		mocker:Stub(ds, "SetAsync", setSpy.Fn)

		local handler = { get = function() return ds end }
		local persistence = EntityPersistence.new({
			DataStoreName = "MockStore",
			KeyPrefix = "Mock",
			DataStoreHandler = handler,
		})

		local entity = {
			Serialize = function()
				return { Value = 42 }
			end,
		}

		local ok = persistence:Save(entity, "Key1")
		t:AssertEquals(ok, true, "Save should succeed")
		t:AssertEquals(setSpy.CallCount, 1, "SetAsync should be called once")
		t:AssertEquals(setSpy.Calls[1][2], "Mock:Key1", "Key should include prefix")

		mocker:RestoreAll()
	end)

	tester:RunTest("Spy supports varargs", function(t)
		local mocker = Mocker.new()
		local spy = mocker:Spy(function(...)
			return select("#", ...)
		end)

		local count = spy.Fn(1, 2, 3, 4)
		t:AssertEquals(count, 4, "Spy should pass through varargs")
		t:AssertEquals(spy.CallCount, 1, "Spy should count vararg call")
		t:AssertEquals(#spy.Calls[1], 4, "Spy should store all args")
	end)

	tester:RunTest("Stub no-op on nil target", function(t)
		local mocker = Mocker.new()
		mocker:Stub(nil, "X", function() end)
		mocker:RestoreAll()
		t:Assert(true, "Should not error on nil target")
	end)

	tester:RunTest("RestoreAll idempotent", function(t)
		local mocker = Mocker.new()
		local obj = { Ping = function() return "ok" end }

		mocker:Stub(obj, "Ping", function() return "stub" end)
		t:AssertEquals(obj:Ping(), "stub", "Stub should be active")

		mocker:RestoreAll()
		t:AssertEquals(obj:Ping(), "ok", "Should restore original function")
		mocker:RestoreAll()
		t:AssertEquals(obj:Ping(), "ok", "Second restore should be no-op")
	end)

	return tester:PrintSummary()
end

return Test_Mocking
