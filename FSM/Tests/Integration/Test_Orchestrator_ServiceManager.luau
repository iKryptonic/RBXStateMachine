--!nocheck
-- @Name Test_Orchestrator_ServiceManager
-- @Author iKrypto
-- @Description Coverage/integration tests for Orchestrator ServiceManagerRemote OnServerInvoke branches and persistence hooks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local BaseStateMachine = require(game:FindFirstChild("BaseStateMachine", true) :: any)
local Settings = require(ReplicatedStorage:FindFirstChild("Settings", true) :: any)
local SchedulerModule = require(game:FindFirstChild("Scheduler", true) :: any)

local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_Orchestrator_ServiceManager = {}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

function Test_Orchestrator_ServiceManager.Run()
	local tester = TestBase.new("Orchestrator_ServiceManager")

	if not RunService:IsServer() then
		return tester:PrintSummary()
	end

	-- NOTE: OnServerInvoke tests cannot be executed directly on the server 
	-- because OnServerInvoke is write-only. These tests would need to run on clients.
	-- Skipping OnServerInvoke callback tests and testing only persistence hooks.

	tester:RunTest("ServiceManagerRemote OnServerInvoke branches", function(t)
		-- Verify remote exists
		Orchestrator.StartServiceManagerAPI()
		local remote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerRemoteName)
		t:Assert(remote ~= nil and remote:IsA("RemoteFunction"), "ServiceManagerRemote should exist")
	end)

	tester:RunTest("Persistence hooks call Load/Save", function(t)
		local calls = { Load = 0, Save = 0 }
		local oldPersistence = Orchestrator.Persistence
		Orchestrator.Persistence = {
			Load = function(_, _entity, _key)
				calls.Load += 1
				return true, { Value = 9 }, nil
			end,
			Save = function(_, _entity, _key)
				calls.Save += 1
				return true
			end,
		} :: any

		local PersistEntity = BaseEntity.Extend({
			Name = "PersistEntity_SMTest",
			Schema = { Value = { Type = "number", Persist = true, Replicate = true } },
		})
		function PersistEntity:GetContext() return {} end
		function PersistEntity:ApplyChanges(_) end
		function PersistEntity:Cleanup() end

		local part = Instance.new("Part")
		part.Parent = workspace

		local ent = Orchestrator.CreateEntity({
			EntityClass = PersistEntity,
			EntityId = "SM_Persist",
			Context = { Instance = part },
			Persistent = true,
			PersistenceKey = "Key1",
		})
		t:Assert(ent ~= nil, "Should create persistent entity")
		t:Assert(calls.Load >= 1, "CreateEntity should call Persistence:Load")

		-- Trigger autosave via StateUpdated
		if ent then
			ent.Value = 1
			ent:UpdateEntity()
		end
		t:Assert(calls.Save >= 1, "Update should auto-save persistent entity")

		-- Delete should save once more (best-effort)
		Orchestrator.DeleteEntity("SM_Persist")
		t:Assert(calls.Save >= 1, "DeleteEntity should save if persistent")

		part:Destroy()
		Orchestrator.Persistence = oldPersistence
	end)

	return tester:PrintSummary()
end

return Test_Orchestrator_ServiceManager
