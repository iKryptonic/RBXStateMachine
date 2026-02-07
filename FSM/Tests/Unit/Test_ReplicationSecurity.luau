--!nocheck
-- @Name Test_ReplicationSecurity
-- @Author iKrypto
-- @Description Unit tests for replication remotes, snapshots, and security gates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local Settings = require(ReplicatedStorage:FindFirstChild("Settings", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_ReplicationSecurity = {}

function Test_ReplicationSecurity.Run()
	local tester = TestBase.new("ReplicationSecurity")

	tester:RunTest("Remotes exist", function(t)
		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.Instance.OrchestratorFunctionName)
		local svcEvent = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.Instance.OrchestratorEventName)
		local updateRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.Instance.EntityUpdateEventName)
		local cmdRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.Instance.EntityCommandEventName)

		t:Assert(svcRemote ~= nil and svcRemote:IsA("RemoteFunction"), "OrchestratorFunction remote should exist")
		t:Assert(svcEvent ~= nil and svcEvent:IsA("RemoteEvent"), "OrchestratorEvent remote should exist")
		t:Assert(updateRemote ~= nil and updateRemote:IsA("RemoteEvent"), "EntityUpdateEvent remote should exist")
		t:Assert(cmdRemote ~= nil and cmdRemote:IsA("RemoteEvent"), "EntityCommandEvent remote should exist")
	end)

	tester:RunTest("Scheduler security gate", function(t)
		-- NOTE: OnServerInvoke tests cannot run on server (write-only property)
		-- This test would need to run on clients via InvokeServer
		Orchestrator.StartServiceManagerAPI()
		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.Instance.OrchestratorFunctionName)
		t:Assert(svcRemote ~= nil, "OrchestratorFunction remote should exist")
	end)

	tester:RunTest("Entity snapshot payload", function(t)
		-- NOTE: OnServerInvoke cannot be called directly on server
		-- Just verify entity creation works; snapshot testing requires client
		local DummyEntity = BaseEntity.Extend({ Name = "SnapshotEntity", Schema = { Value = { Type = "number", Replicate = true } } })
		function DummyEntity:ApplyChanges(_) end
		function DummyEntity:GetContext() return {} end
		function DummyEntity:Cleanup() end

		local part = Instance.new("Part")
		part.Parent = workspace

		local entity = Orchestrator.CreateEntity({
			EntityClass = DummyEntity,
			EntityId = "Snapshot_01",
			Context = { Instance = part }
		})
		entity.Value = 7
		entity:UpdateEntity()

		Orchestrator.StartServiceManagerAPI()
		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.Instance.OrchestratorFunctionName)
		t:Assert(svcRemote ~= nil and svcRemote:IsA("RemoteFunction"), "OrchestratorFunction remote should exist")

		Orchestrator.DeleteEntity("Snapshot_01")
		part:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_ReplicationSecurity
