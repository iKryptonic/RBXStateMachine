--!nocheck
-- @Name Test_Factory
-- @Author iKrypto
-- @Description Coverage/integration tests for Factory compilation and retrieval.

local TestBase = require(script:FindFirstChild("TestBase") :: any)
local Fixtures = require((script.Parent :: any):WaitForChild("Fixtures"):WaitForChild("Setup") :: any)

local Test_Factory = {}

function Test_Factory.Run()
	local tester = TestBase.new("Factory")

	tester:RunTest("Compiles registries when fixtures installed", function(t)
		local install = Fixtures.Install()
		if not install.Ok then
			t:Assert(true, "Skipping: fixtures unavailable (" .. tostring(install.Reason) .. ")")
			return
		end

		local Factory = require(game:FindFirstChild("Factory", true) :: any)

		local entities = Factory.GetAll("Entity")
		local sms = Factory.GetAll("StateMachine")
		t:Assert(type(entities) == "table", "GetAll(Entity) should return table")
		t:Assert(type(sms) == "table", "GetAll(StateMachine) should return table")
		t:Assert(entities.DummyEntity ~= nil, "DummyEntity should be compiled")
		t:Assert(sms.DummyFSM ~= nil, "DummyFSM should be compiled")

		local okGet, clsOrErr = pcall(function()
			return Factory.Get("Entity", "DummyEntity")
		end)
		t:Assert(okGet and clsOrErr ~= nil, "Factory.Get should return compiled class")

		local okBadType = pcall(function()
			Factory.Get("Nope", "X")
		end)
		t:Assert(okBadType == false, "Factory.Get should error on invalid type")

		local okMissingClass = pcall(function()
			Factory.Get("Entity", "Missing")
		end)
		t:Assert(okMissingClass == false, "Factory.Get should error on missing class")

		-- LoadSubclasses should be safe to call even if already loaded.
		local okLoad = pcall(function()
			Factory.LoadSubclasses()
		end)
		t:Assert(okLoad, "LoadSubclasses should not error")

		if install.Cleanup then install.Cleanup() end
	end)

	return tester:PrintSummary()
end

return Test_Factory
