--!strict
-- @Name Test_Orchestrator
-- @Author iKrypto
-- @Description Unit tests for Orchestrator factory and registry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local BaseStateMachine = require(game:FindFirstChild("BaseStateMachine", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_Orchestrator = {}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

function Test_Orchestrator.Run()
	local tester = TestBase.new("Orchestrator")

	-- Define dummy classes
	local DummyEntity = BaseEntity.Extend({ Name = "DummyEntity", Schema = { Val = { Type = "number" } } })
	function DummyEntity:ApplyChanges(changes) end
	function DummyEntity:GetContext() return {} end
	function DummyEntity:Cleanup() end
	
	local DummyFSM = BaseStateMachine.Extend({ className = "DummyFSM", validStates = {"Idle"} })
	function DummyFSM:RegisterStates()
		self:AddState("Idle", function() end)
	end
	function DummyFSM:OnCleanup() end

	tester:RunTest("CreateEntity", function(t)
		local part = Instance.new("Part")
		local id = "TestEntity_01"
		
		local entity = Orchestrator.CreateEntity({
			EntityClass = DummyEntity,
			EntityId = id,
			Context = { Instance = part }
		})
		
		t:Assert(entity ~= nil, "Should create entity")
		t:AssertEquals(Orchestrator.GetEntity(id), entity, "Should retrieve entity by ID")
		t:AssertEquals(entity.Instance, part, "Entity should have correct instance")
		
		-- Duplicate creation should return same instance
		local entity2 = Orchestrator.CreateEntity({
			EntityClass = DummyEntity,
			EntityId = id,
			Context = { Instance = part }
		})
		t:AssertEquals(entity, entity2, "Should return existing instance on duplicate ID")
		
		Orchestrator.DeleteEntity(id)
		t:AssertEquals(Orchestrator.GetEntity(id), nil, "Should delete entity")
	end)

	tester:RunTest("CreateStateMachine", function(t)
		local id = "TestFSM_01"
		
		local fsm = Orchestrator.CreateStateMachine({
			StateMachineClass = DummyFSM,
			StateMachineId = id,
			Context = {}
		})
		
		t:Assert(fsm ~= nil, "Should create FSM")
		t:AssertEquals(Orchestrator.GetStateMachine(id), fsm, "Should retrieve FSM by ID")
		
		local fsm2 = Orchestrator.CreateStateMachine({
			StateMachineClass = DummyFSM,
			StateMachineId = id,
			Context = {}
		})
		t:AssertEquals(fsm, fsm2, "Should return existing instance on duplicate ID")
		
		Orchestrator.CancelStateMachine(id)
		
		waitFor(function() return Orchestrator.GetStateMachine(id) == nil end, 6)
		t:AssertEquals(Orchestrator.GetStateMachine(id), nil, "Should remove FSM from registry after cancel")
	end)
	
	tester:RunTest("RetryStateMachine", function(t)
		local id = "RetryFSM"
		-- Need to register class in shared.StateMachine for Retry to work
		shared.StateMachine["DummyFSM"] = DummyFSM
		
		local fsm = Orchestrator.CreateStateMachine({
			StateMachineClass = DummyFSM,
			StateMachineId = id,
			Context = { Data = 1 }
		})
		
		local originalFSM = fsm
		Orchestrator.RetryStateMachine(id)
		
		local newFSM = Orchestrator.GetStateMachine(id)
		t:Assert(newFSM ~= nil, "Should have a new FSM")
		t:AssertNotEquals(originalFSM, newFSM, "Should be a different instance")
		t:AssertEquals(newFSM.Context.Data, 1, "Should preserve context")
		
		Orchestrator.CancelStateMachine(id)
	end)

	tester:RunTest("Cleanup All", function(t)
		Orchestrator.CreateEntity({ EntityClass = DummyEntity, EntityId = "E1", Context = { Instance = Instance.new("Part") } })
		Orchestrator.CreateEntity({ EntityClass = DummyEntity, EntityId = "E2", Context = { Instance = Instance.new("Part") } })
		
		t:Assert(next(Orchestrator.GetEntities()) ~= nil, "Should have entities")
		
		Orchestrator.DeleteAllEntities()
		t:Assert(next(Orchestrator.GetEntities()) == nil, "Should have no entities")
		
		Orchestrator.CreateStateMachine({ StateMachineClass = DummyFSM, StateMachineId = "F1", Context = {} })
		Orchestrator.CreateStateMachine({ StateMachineClass = DummyFSM, StateMachineId = "F2", Context = {} })
		
		t:Assert(next(Orchestrator.GetStateMachines()) ~= nil, "Should have FSMs")
		
		Orchestrator.CancelAll()
		
		waitFor(function() return next(Orchestrator.GetStateMachines()) == nil end, 6)
		t:Assert(next(Orchestrator.GetStateMachines()) == nil, "Should have no FSMs")
	end)
	
	tester:RunTest("ServiceManager API", function(t)
		-- Ensure API is started
		Orchestrator.StartServiceManagerAPI()
		
		local remote = ReplicatedStorage:FindFirstChild("OrchestratorFunction")
		if not remote or not remote:IsA("RemoteFunction") then
			-- Skip if not running in a server context where remotes are created
			return
		end

		t:Assert(remote ~= nil, "OrchestratorFunction remote should exist")
	end)

	tester:RunTest("Pooling & Reuse", function(t)
		local part = Instance.new("Part")
		part.Name = "PoolPart"
		local entity = Orchestrator.CreateEntity({
			EntityClass = DummyEntity,
			EntityId = "Pool_01",
			Context = { Instance = part }
		})
		entity.Val = 99
		entity:UpdateEntity()

		Orchestrator.PoolEntity("Pool_01")
		t:Assert(Orchestrator.GetEntity("Pool_01") == nil, "Pooled entity should be removed from active registry")

		local reused = Orchestrator.GetPooledEntity({
			EntityClass = DummyEntity,
			EntityId = "Pool_02",
			Context = { Instance = part }
		})
		t:Assert(reused ~= nil, "Should reuse pooled entity")
		t:AssertEquals(Orchestrator.GetEntity("Pool_02"), reused, "Reused entity should be active")
		t:Assert(reused.Val == nil, "Pooled entity data should be cleared")

		Orchestrator.DeleteEntity("Pool_02")
		part:Destroy()
	end)

	tester:RunTest("EventBus registration + await", function(t)
		local busName = "TestBus"
		local bus = Orchestrator.RegisterEventBus(busName)
		t:Assert(bus ~= nil, "EventBus should register")

		local got = nil
		bus:Connect(function(v) got = v end)
		Orchestrator.FireEventBus(busName, 123)
		t:AssertEquals(got, 123, "EventBus should fire payload")

		local awaited = Orchestrator.AwaitEventBus(busName, 0.1)
		t:Assert(awaited ~= nil, "AwaitEventBus should return existing bus")

		local missing = Orchestrator.AwaitEventBus("MissingBus", 0.05)
		t:AssertEquals(missing, nil, "AwaitEventBus should return nil on timeout")
	end)

	return tester:PrintSummary()
end

return Test_Orchestrator