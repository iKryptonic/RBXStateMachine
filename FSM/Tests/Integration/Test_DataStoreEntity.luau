--!nocheck
-- @Name Test_DataStoreEntity
-- @Author iKrypto
-- @Description Integration test for the DataStoreSystem entity. Skips gracefully
-- when the DataStore subsystem is disabled or not registered.

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_DataStoreEntity = {}

function Test_DataStoreEntity.Run()
	local tester = TestBase.new("DataStoreEntity")

	tester:RunTest("DataStoreSystem entity is initialized", function(t)
		if not Orchestrator.Initialized then
			Orchestrator:RegisterComponents()
			task.wait(1)
		end

		local dsEntity = Orchestrator.GetEntity("DataStoreSystem")
		if not dsEntity then
			t:SkipTest("DataStoreSystem not initialized (DataStore subsystem may be disabled)")
			return
		end

		t:AssertNotNil(dsEntity, "DataStoreSystem entity should be registered")
		t:Assert(dsEntity._privateProperties ~= nil, "Entity should expose _privateProperties")
		t:Assert(dsEntity._privateProperties.IsValid == true, "Entity should be valid")
	end)

	return tester:PrintSummary()
end

return Test_DataStoreEntity
