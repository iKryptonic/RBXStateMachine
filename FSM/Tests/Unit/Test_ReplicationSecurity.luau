--!strict
-- @Name Test_ReplicationSecurity
-- @Author iKrypto
-- @Description Unit tests for replication remotes, snapshots, and security gates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local Settings = require(game:FindFirstChild("Settings", true) :: any)
local TestBase = require(script:FindFirstChild("TestBase") :: any)

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
		local oldShared = shared.FSM
		shared.FSM = shared.FSM or {}
		shared.FSM.Scheduler = { CheckAdmin = function() return false end }

		Orchestrator.StartServiceManagerAPI()

		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerRemoteName) :: RemoteFunction
		local response = svcRemote.OnServerInvoke({}, "Scheduler", "Schedule", { TaskName = "X", TaskAction = function() end })
		t:AssertEquals(response, "Unauthorized", "Should block scheduler actions for non-admin")

		shared.FSM = oldShared
	end)

	tester:RunTest("Entity snapshot payload", function(t)
		local DummyEntity = BaseEntity.Extend({ Name = "SnapshotEntity", Schema = { Value = { Type = "number", Replicate = true } } })
		function DummyEntity:ApplyChanges(_) end

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
		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerRemoteName) :: RemoteFunction
		local snapshot = svcRemote.OnServerInvoke({}, "RequestEntitySnapshot")

		local found = false
		for _, entry in ipairs(snapshot) do
			if entry.Id == "Snapshot_01" then
				found = true
				t:AssertEquals(entry.Data.Value, 7, "Snapshot should include entity data")
			end
		end
		t:Assert(found, "Snapshot should include entity")

		Orchestrator.DeleteEntity("Snapshot_01")
		part:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_ReplicationSecurity
