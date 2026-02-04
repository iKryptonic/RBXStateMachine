--!nocheck
-- @Name Test_DataStoreHandler
-- @Author iKrypto
-- @Description Coverage/integration tests for DataStoreHandler wrapper behavior (throttling, retry config, basic API).

local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local DataStoreHandler = require(game:FindFirstChild("DataStoreHandler", true) :: any)

local Test_DataStoreHandler = {}

function Test_DataStoreHandler.Run()
	local tester = TestBase.new("DataStoreHandler")

	tester:RunTest("get() returns wrapper + basic methods", function(t)
		local db = DataStoreHandler.get("FSM_TestCoverage_DB")
		t:Assert(db ~= nil, "Should return db wrapper")
		t:Assert(type(db.GetAsync) == "function", "Wrapper should expose GetAsync")
		t:Assert(type(db.SetAsync) == "function", "Wrapper should expose SetAsync")
		t:Assert(type(db.UpdateAsync) == "function", "Wrapper should expose UpdateAsync")
		t:Assert(type(db.RemoveAsync) == "function", "Wrapper should expose RemoveAsync")
		t:Assert(type(db.IncrementAsync) == "function", "Wrapper should expose IncrementAsync")

		local name = db:GetDBName()
		t:AssertEquals(name, "FSM_TestCoverage_DB", "GetDBName should match")
	end)

	tester:RunTest("Throttle non-get requests on same key", function(t)
		local db = DataStoreHandler.get("FSM_TestCoverage_Throttle")

		-- First attempt may succeed or fail depending on studio settings; we only care it returns a tuple.
		local ok1, _val1, _err1 = db:SetAsync("K", "V")
		t:Assert(type(ok1) == "boolean", "SetAsync should return boolean ok")

		-- Immediate second attempt should be throttled before any datastore call.
		local ok2, _val2, err2 = db:SetAsync("K", "V2")
		t:AssertEquals(ok2, false, "Second SetAsync should be throttled")
		t:Assert(err2 == "Throttled", "Throttle error should be 'Throttled'")

		local ok3, _val3, err3 = db:IncrementAsync("K", 1)
		t:AssertEquals(ok3, false, "IncrementAsync should be throttled")
		t:Assert(err3 == "Throttled", "Throttle error should be 'Throttled'")

		local ok4, _val4, err4 = db:RemoveAsync("K")
		t:AssertEquals(ok4, false, "RemoveAsync should be throttled")
		t:Assert(err4 == "Throttled", "Throttle error should be 'Throttled'")

		local ok5, _val5, err5 = db:UpdateAsync("K", function(old) return old end)
		t:AssertEquals(ok5, false, "UpdateAsync should be throttled")
		t:Assert(err5 == "Throttled", "Throttle error should be 'Throttled'")
	end)

	tester:RunTest("Retry config toggles without error", function(t)
		local db = DataStoreHandler.get("FSM_TestCoverage_Retry")
		db:SetRetryConfig({ enabled = true, retries = 1, baseDelay = 0, jitter = 0 })
		db:EnableRetry(true)

		-- This call may fail in Studio if API services are disabled; it should not throw.
		local ok = pcall(function()
			local _okGet, _val, _err = db:GetAsync("SomeKey")
			return _okGet
		end)
		t:Assert(ok, "GetAsync should not throw with retry enabled")
	end)

	tester:RunTest("CachingTime accepts 0+", function(t)
		local db = DataStoreHandler.get("FSM_TestCoverage_Cache")
		db:SetCachingTime(0)
		db:SetCachingTime(1)
		t:Assert(true, "SetCachingTime should accept values")
	end)

	return tester:PrintSummary()
end

return Test_DataStoreHandler
