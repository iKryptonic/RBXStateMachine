--!strict
-- @Name Test_OrchestratorDiscovery
-- @Author iKrypto
-- @Description Unit tests for Orchestrator discovery scanning and auto-registration.

local ServerStorage = game:GetService("ServerStorage")
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local Fixtures = require(script.Parent:WaitForChild("Fixtures"):WaitForChild("Setup") :: any)

local Test_OrchestratorDiscovery = {}

local function cloneOrchestrator(): ModuleScript
	local source = game:FindFirstChild("Orchestrator", true) :: ModuleScript
	local clone = source:Clone()
	clone.Name = "Orchestrator_TestClone"
	clone.Parent = ServerStorage
	return clone
end

function Test_OrchestratorDiscovery.Run()
	local tester = TestBase.new("OrchestratorDiscovery")

	tester:RunTest("Discovery + Auto-Registration", function(t)
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

		shared.FSM = nil
		shared.Entity = nil
		shared.StateMachine = nil
		shared.__TestFlags = {}

		local orchestratorClone = cloneOrchestrator()
		local Orchestrator = require(orchestratorClone)
		Orchestrator:RegisterComponents()

		t:Assert(shared.Entity ~= nil and shared.Entity.DummyEntity ~= nil, "Entity registry should compile DummyEntity")
		t:Assert(shared.StateMachine ~= nil and shared.StateMachine.DummyFSM ~= nil, "StateMachine registry should compile DummyFSM")

		local flags = shared.__TestFlags or {}
		t:Assert(flags.DummyEntityLoaded == true, "DummyEntity subclass should be auto-required")
		t:Assert(flags.DummyFSMLoaded == true, "DummyFSM subclass should be auto-required")

		if orchestratorClone and orchestratorClone.Parent then
			orchestratorClone:Destroy()
		end
		if install.Cleanup then install.Cleanup() end

		shared.FSM = oldShared.FSM
		shared.Entity = oldShared.Entity
		shared.StateMachine = oldShared.StateMachine
		shared.Logger = oldShared.Logger
		shared.Signal = oldShared.Signal
		shared.Scheduler = oldShared.Scheduler
	end)

	return tester:PrintSummary()
end

return Test_OrchestratorDiscovery
