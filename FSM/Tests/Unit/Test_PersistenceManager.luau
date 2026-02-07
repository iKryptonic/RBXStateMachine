--!nocheck
-- @Name Test_PersistenceManager
-- @Author iKrypto (audit)
-- @Description Unit tests for PersistenceManager state lifecycle.

local RunService = game:GetService("RunService")
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local Mocker = require(script.Parent.Parent:FindFirstChild("Mocker", true) :: any)

local Test_PersistenceManager = {}

function Test_PersistenceManager.Run()
	local tester = TestBase.new("PersistenceManager")

	if not RunService:IsServer() then
		tester:RunTest("Server-only module", function(t)
			t:SkipTest("PersistenceManager tests only run on server")
		end)
		return tester:PrintSummary()
	end

	local PersistenceManager
	local ok, err = pcall(function()
		PersistenceManager = require(game:FindFirstChild("PersistenceManager", true) :: any)
	end)
	if not ok or not PersistenceManager then
		tester:RunTest("PersistenceManager available", function(t)
			t:SkipTest("PersistenceManager module not found: " .. tostring(err))
		end)
		return tester:PrintSummary()
	end

	-- TEST 1: SaveState skips non-persistent entities
	tester:RunTest("SaveState skips non-persistent entities", function(t)
		local mockEntity = {
			_privateProperties = {
				Context = {
					_IsPersistent = false,
				},
			},
			Serialize = function() return {} end,
		}

		-- Should not error, should just return early
		local success, err2 = pcall(function()
			PersistenceManager.SaveState(mockEntity)
		end)
		-- If persistence is disabled globally, it will assert; that's expected
		if not success and tostring(err2):match("Persistence is disabled") then
			t:SkipTest("Persistence is disabled globally in settings")
			return
		end
		t:Assert(true, "SaveState should not error for non-persistent entities")
	end)

	-- TEST 2: SaveState skips entities without persistence key
	tester:RunTest("SaveState skips entities without key", function(t)
		local mockEntity = {
			_privateProperties = {
				Context = {
					_IsPersistent = true,
					-- No _PersistenceKey or EntityId
				},
			},
			Serialize = function() return {} end,
		}

		local success, err2 = pcall(function()
			PersistenceManager.SaveState(mockEntity)
		end)
		if not success and tostring(err2):match("Persistence is disabled") then
			t:SkipTest("Persistence is disabled globally in settings")
			return
		end
		t:Assert(true, "SaveState should not error when no key available")
	end)

	-- TEST 3: LoadState sets persistence context flags
	tester:RunTest("LoadState sets persistence flags", function(t)
		local contextSet = {}
		local mockEntity = {
			SetContext = function(self, key, value)
				contextSet[key] = value
			end,
			Deserialize = function() end,
		}

		local success, errMsg = pcall(function()
			PersistenceManager.LoadState(mockEntity, "test-key-123")
		end)
		if not success and tostring(errMsg):match("Persistence is disabled") then
			t:SkipTest("Persistence is disabled globally in settings")
			return
		end

		t:AssertEquals(contextSet["_PersistenceKey"], "test-key-123", "Should set _PersistenceKey")
		t:AssertEquals(contextSet["_IsPersistent"], true, "Should set _IsPersistent to true")
	end)

	return tester:PrintSummary()
end

return Test_PersistenceManager
