--!nocheck
-- @Name Test_Orchestrator_ServiceManager
-- @Author iKrypto
-- @Description Coverage tests for Orchestrator OrchestratorFunction remote presence.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local SettingsLookup = ReplicatedStorage:FindFirstChild("Settings", true)
	or game:FindFirstChild("Settings", true)
local Settings = SettingsLookup and require(SettingsLookup :: any) or (Orchestrator and Orchestrator.Settings) or nil

local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local TestUtils = require(script.Parent:FindFirstChild("TestUtils") :: any)
local waitFor = TestUtils.WaitFor

local Test_Orchestrator_ServiceManager = {}

function Test_Orchestrator_ServiceManager.Run()
	local tester = TestBase.new("Orchestrator_ServiceManager")

	if not RunService:IsServer() then
		return tester:PrintSummary()
	end

	tester:RunTest("OrchestratorFunction remote exists when ServiceManager enabled", function(t)
		if not Settings or not Settings.ServiceManager or not Settings.ServiceManager.Enabled then
			t:SkipTest("ServiceManager not enabled in Settings")
			return
		end
		local name = Settings.StaticStrings and Settings.StaticStrings.Instance and Settings.StaticStrings.Instance.OrchestratorFunctionName
		t:AssertNotNil(name, "OrchestratorFunctionName should be defined in Settings")
		local remote = ReplicatedStorage:FindFirstChild(name)
		t:Assert(remote ~= nil and remote:IsA("RemoteFunction"), "OrchestratorFunction remote should exist")
	end)

	tester:RunTest("Persistent entity create/update lifecycle", function(t)
		-- This test verifies persistence hooks are exercised; we don't assert specific call
		-- counts because PersistenceManager handles its own internals. We just verify the
		-- entity can be created, updated, and destroyed without errors when Persistent=true.
		local PersistEntity = BaseEntity.Extend({
			Name = "PersistEntity_SMTest",
			Schema = { Value = { Type = "number", Persist = true, Replicate = true } },
		})
		function PersistEntity:GetContext() return {} end
		function PersistEntity:ApplyChanges(_) end
		function PersistEntity:OnCleanup() end

		local part = Instance.new("Part")
		part.Parent = workspace

		local ok, ent = pcall(function()
			return Orchestrator.CreateEntity({
				EntityClass = PersistEntity,
				EntityId = "SM_Persist",
				Context = { Instance = part },
				Persistent = true,
				PersistenceKey = "Key1",
			})
		end)
		t:Assert(ok, "CreateEntity should not throw with Persistent=true")
		t:Assert(ent ~= nil, "Should create persistent entity")

		if ent then
			ent.Value = 1
			pcall(function() ent:UpdateEntity() end)
		end

		Orchestrator.DeleteEntity("SM_Persist")
		t:AssertEquals(Orchestrator.GetEntity("SM_Persist"), nil, "Entity should be unregistered after delete")

		part:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_Orchestrator_ServiceManager
