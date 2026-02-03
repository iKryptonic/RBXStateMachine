--!strict
-- @Name Test_E2E_Server
-- @Author iKrypto
-- @Description End-to-end server test: Entities + FSM + Scheduler integration.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestBase = require(script:FindFirstChild("TestBase") :: any)
local Fixtures = require(script.Parent:WaitForChild("Fixtures"):WaitForChild("Setup") :: any)

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local Settings = require(game:FindFirstChild("Settings", true) :: any)

local Test_E2E_Server = {}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

function Test_E2E_Server.Run()
	local tester = TestBase.new("E2E_Server")

	tester:RunTest("Entities + FSM + Scheduler", function(t)
		local install = Fixtures.Install()
		if not install.Ok then
			t:Assert(true, "Skipping: fixtures unavailable (" .. tostring(install.Reason) .. ")")
			return
		end

		local oldShared = {
			FSM = shared.FSM,
			Entity = shared.Entity,
			StateMachine = shared.StateMachine,
			Logger = shared.Logger,
			Signal = shared.Signal,
			Scheduler = shared.Scheduler,
		}
		if not shared.FSM then
			Orchestrator:RegisterComponents()
		end

		local part = Instance.new("Part")
		part.Name = "E2E_Part"
		part.Parent = workspace

		local entity = Orchestrator.CreateEntity({
			EntityClass = "DummyEntity",
			EntityId = "E2E_Entity",
			Context = { Instance = part },
			Persistent = false,
		})
		t:Assert(entity ~= nil, "Should create E2E entity")

		local fsm = Orchestrator.CreateStateMachine({
			StateMachineClass = "DummyFSM",
			StateMachineId = "E2E_FSM",
			Context = { Entity = entity },
		})
		t:Assert(fsm ~= nil, "Should create E2E FSM")

		local completed = false
		fsm.Completed:Connect(function() completed = true end)
		fsm:Start({ State = "Idle" })

		local okFsm = waitFor(function() return completed end, 3)
		t:Assert(okFsm, "FSM should complete via DummyFSM")

		-- Scheduler integration: schedule entity update
		local scheduler = shared.FSM and shared.FSM.Scheduler
		t:Assert(scheduler ~= nil, "Scheduler should exist in shared.FSM")

		local updated = false
		scheduler:Schedule({
			TaskName = "E2E_UpdateEntity",
			TaskExecutionDelay = 0.1,
			TaskAction = function()
				entity.Value = 0.75
				entity.Label = "E2E"
				entity:UpdateEntity()
				updated = true
			end
		})
		scheduler:Start()

		local okSched = waitFor(function() return updated and entity.Value == 0.75 end, 2)
		t:Assert(okSched, "Scheduler should execute entity update")

		-- Register request handler for client replication test
		Orchestrator.RegisterRequestHandler("E2E_GetReplicationTarget", function()
			return { EntityId = "E2E_Entity", Value = 0.75 }
		end)

		-- Register command handler to validate command pipeline (client-driven)
		local commandReceived = false
		Orchestrator.RegisterCommandHandler("E2E_Entity", "Ping", function()
			commandReceived = true
		end)

		if #Players:GetPlayers() > 0 then
			local okCmd = waitFor(function() return commandReceived end, 5)
			t:Assert(okCmd, "Should receive command from client via EntityCommandRemote")
		else
			t:Assert(true, "No client available; skipping command pipeline")
		end

		Orchestrator.CancelStateMachine("E2E_FSM")
		Orchestrator.DeleteEntity("E2E_Entity")
		part:Destroy()

		if install.Cleanup then install.Cleanup() end
		shared.FSM = oldShared.FSM
		shared.Entity = oldShared.Entity
		shared.StateMachine = oldShared.StateMachine
		shared.Logger = oldShared.Logger
		shared.Signal = oldShared.Signal
		shared.Scheduler = oldShared.Scheduler
	end)

	tester:RunTest("Remotes and replication readiness", function(t)
		local svcRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerRemoteName)
		local updateRemote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.EntityUpdateRemoteName)
		t:Assert(svcRemote ~= nil, "ServiceManagerRemote should exist")
		t:Assert(updateRemote ~= nil, "EntityUpdateRemote should exist")
	end)

	return tester:PrintSummary()
end

return Test_E2E_Server
