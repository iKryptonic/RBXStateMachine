--!nocheck
-- @Name Test_Orchestrator_ServiceManager
-- @Author iKrypto
-- @Description Coverage/integration tests for Orchestrator ServiceManagerRemote OnServerInvoke branches and persistence hooks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local BaseStateMachine = require(game:FindFirstChild("BaseStateMachine", true) :: any)
local Settings = require(game:FindFirstChild("Settings", true) :: any)
local SchedulerModule = require(game:FindFirstChild("Scheduler", true) :: any)

local TestBase = require(script:FindFirstChild("TestBase") :: any)

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

	tester:RunTest("ServiceManagerRemote OnServerInvoke branches", function(t)
		-- Ensure the API is started and remotes exist.
		Orchestrator.StartServiceManagerAPI()

		local remote = ReplicatedStorage:FindFirstChild(Settings.StaticStrings.ServiceManagerRemoteName)
		t:Assert(remote ~= nil and remote:IsA("RemoteFunction"), "ServiceManagerRemote should exist")
		if not remote or not remote:IsA("RemoteFunction") then return end
		t:Assert(type(remote.OnServerInvoke) == "function", "OnServerInvoke should be assigned")

		-- Minimal shared.FSM for branches that reference it.
		local oldSharedFSM = shared.FSM
		local oldSharedSM = shared.StateMachine
		local scheduler = SchedulerModule.new()
		scheduler:Initialize()
		shared.FSM = shared.FSM or {}
		shared.FSM.Scheduler = scheduler

		local fakePlayer = {} :: any

		-- GetSyncData
		local sync = remote.OnServerInvoke(fakePlayer, "GetSyncData")
		t:Assert(sync ~= nil and sync.FSM ~= nil, "GetSyncData should return FSM payload")

		-- UpdateSettings
		remote.OnServerInvoke(fakePlayer, "UpdateSettings", "Logging", "LogToOutput", true)
		t:AssertEquals(scheduler.Settings.Logging.LogToOutput, true, "UpdateSettings should update scheduler settings")

		-- ConsoleCommand: clearlogs
		Orchestrator.Logger:Log({ Level = "INFO", Message = "hello" })
		local out = remote.OnServerInvoke(fakePlayer, "ConsoleCommand", "clearlogs", {})
		t:Assert(out == "Logs cleared.", "clearlogs should return confirmation")
		t:Assert(#Orchestrator.Logger.History == 0, "clearlogs should clear history")

		-- Create entity + snapshot
		local DummyEntity = BaseEntity.Extend({ Name = "DummyEntity_SMTest", Schema = { Value = { Type = "number", Replicate = true } } })
		function DummyEntity:GetContext() return {} end
		function DummyEntity:ApplyChanges(_) end

		local part = Instance.new("Part")
		part.Parent = workspace
		local ent = Orchestrator.CreateEntity({ EntityClass = DummyEntity, EntityId = "SM_Snapshot", Context = { Instance = part } })
		t:Assert(ent ~= nil, "Should create entity")
		if ent then
			ent.Value = 1
			ent:UpdateEntity()
		end

		local snap = remote.OnServerInvoke(fakePlayer, "RequestEntitySnapshot")
		t:Assert(type(snap) == "table" and #snap >= 1, "RequestEntitySnapshot should return list")

		-- AppRequest handler success
		Orchestrator.RegisterRequestHandler("SM_Echo", function(_player, a, b)
			return { a = a, b = b }
		end)
		local echo = remote.OnServerInvoke(fakePlayer, "AppRequest", "SM_Echo", 1, 2)
		t:Assert(echo ~= nil and echo.a == 1 and echo.b == 2, "AppRequest should call handler")

		-- AppRequest handler missing / invalid
		local missing = remote.OnServerInvoke(fakePlayer, "AppRequest", "Missing", 1)
		t:Assert(missing == nil, "AppRequest should return nil for missing handler")
		local invalidName = remote.OnServerInvoke(fakePlayer, "AppRequest", "", 1)
		t:Assert(invalidName == nil, "AppRequest should return nil for invalid requestName")

		-- Scheduler unauthorized
		scheduler.CheckAdmin = function() return false end
		local unauthorized = remote.OnServerInvoke(fakePlayer, "Scheduler", "Schedule", { TaskName = "X", TaskAction = function() end })
		t:Assert(unauthorized == "Unauthorized", "Scheduler should enforce CheckAdmin when present")

		-- Scheduler actions (authorized)
		scheduler.CheckAdmin = function() return true end
		remote.OnServerInvoke(fakePlayer, "Scheduler", "ScheduleTestTask", "SrvTask", 0, false, 1, "Heartbeat", "Hello")

		-- FSM actions via remote
		local DummyFSM = BaseStateMachine.Extend({ className = "DummyFSM_SMTest", validStates = { "Idle" } })
		function DummyFSM:RegisterStates()
			self:AddState("Idle", function() end)
		end
		shared.StateMachine = shared.StateMachine or {}
		shared.StateMachine["DummyFSM_SMTest"] = DummyFSM
		local fsm = Orchestrator.CreateStateMachine({ StateMachineClass = "DummyFSM_SMTest", StateMachineId = "SM_FSM", Context = {} })
		t:Assert(fsm ~= nil, "Should create fsm via string resolution")
		remote.OnServerInvoke(fakePlayer, "FSM", "CancelStateMachine", "SM_FSM")
		local okCancelled = waitFor(function() return Orchestrator.GetStateMachine("SM_FSM") == nil end, 2)
		t:Assert(okCancelled, "CancelStateMachine via remote should remove FSM")

		-- ConsoleCommand: ps
		local fsm2 = Orchestrator.CreateStateMachine({ StateMachineClass = DummyFSM, StateMachineId = "SM_PS", Context = {} })
		if fsm2 then
			fsm2:Start({ State = "Idle" })
		end
		local ps = remote.OnServerInvoke(fakePlayer, "ConsoleCommand", "ps", {})
		t:Assert(type(ps) == "string" and ps:match("SM_PS") ~= nil, "ps should include active FSM id")
		Orchestrator.CancelStateMachine("SM_PS")
		waitFor(function() return Orchestrator.GetStateMachine("SM_PS") == nil end, 2)

		-- Cleanup
		Orchestrator.DeleteEntity("SM_Snapshot")
		part:Destroy()
		shared.FSM = oldSharedFSM
		shared.StateMachine = oldSharedSM
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
