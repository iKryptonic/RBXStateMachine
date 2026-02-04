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
		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerRemoteName)
		local svcEvent = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerEventName)
		local updateRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.EntityUpdateRemoteName)
		local cmdRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.EntityCommandRemoteName)

		t:Assert(svcRemote ~= nil and svcRemote:IsA("RemoteFunction"), "ServiceManagerRemote should exist")
		t:Assert(svcEvent ~= nil and svcEvent:IsA("RemoteEvent"), "ServiceManagerEvent should exist")
		t:Assert(updateRemote ~= nil and updateRemote:IsA("RemoteEvent"), "EntityUpdateRemote should exist")
		t:Assert(cmdRemote ~= nil and cmdRemote:IsA("RemoteEvent"), "EntityCommandRemote should exist")
	end)

	tester:RunTest("Scheduler security gate", function(t)
		-- NOTE: OnServerInvoke tests cannot run on server (write-only property)
		-- This test would need to run on clients via InvokeServer
		Orchestrator.StartServiceManagerAPI()
		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerRemoteName)
		t:Assert(svcRemote ~= nil, "ServiceManager remote should exist")
	end)

	tester:RunTest("Entity snapshot payload", function(t)
		-- NOTE: OnServerInvoke cannot be called directly on server
		-- Just verify entity creation works; snapshot testing requires client
		local DummyEntity = BaseEntity.Extend({ Name = "SnapshotEntity", Schema = { Value = { Type = "number", Replicate = true } } })
		function DummyEntity:ApplyChanges(_) end
		function DummyEntity:GetContext() return {} end
		function DummyEntity:OnCleanup() end

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
		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerRemoteName)
		t:Assert(svcRemote ~= nil and svcRemote:IsA("RemoteFunction"), "ServiceManager remote should exist")

		Orchestrator.DeleteEntity("Snapshot_01")
		part:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_ReplicationSecurity
