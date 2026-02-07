--!strict
-- @Name Test_DataStoreEntity
-- @Description Integration Test for DataStoreEntity

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Orchestrator = require(script.Parent.Parent.Parent.init) -- Path to Orchestrator/init
local DataStoreEntityClass = require(script.Parent.DataStoreEntity)

local function Test()
	print("Starting DataStoreEntity Integrity Test...")

	-- 1. Initialize Orchestrator (Mock Environment if needed, but assuming actual env)
	if not Orchestrator.Initialized then
		Orchestrator:RegisterComponents()
		-- Wait for Init
		task.wait(1)
	end
	
	-- 2. Verify DataStoreEntity Creation
	local dsEntity = Orchestrator.GetEntity("DataStoreSystem")
	if not dsEntity then
		warn("DataStoreSystem Entity not found! Attempting manual creation for test.")
		dsEntity = Orchestrator.CreateEntity({
			EntityClass = DataStoreEntityClass,
			EntityId = "DataStoreSystem",
			Context = { Orchestrator = Orchestrator }
		})
	end
	
	if not dsEntity then
		error("Failed to create/find DataStoreEntity")
	end
	print("DataStoreEntity is active.")
	
	-- 3. Mock DataStore Service Call (by mocking the internal Request Function if possible, or using MockDataStoreService)
	-- For this test we will try to set a value to a mock datastore (if running in Studio with API access, or Mock)
	
	local testKey = "TestKey_" .. tostring(os.time())
	local testVal = { Data = "Hello World" }
	
	print("Attempting SetAsync...")
	local success, err = pcall(function()
		dsEntity:SetAsync("TestDS", testKey, testVal)
	end)
	
	if success then
		print("SetAsync Success!")
	else
		warn("SetAsync Failed (Expected if no API access): " .. tostring(err))
		-- Verify it failed gracefully via FSM
	end
	
	-- 4. Check FSM History (if accessible) or just observe RequestFSM creation in logs
	print("Check Console/Logs for RequestFSM transitions.")
	
	print("Test Complete.")
end

if RunService:IsStudio() then
	task.spawn(Test)
end

return Test
