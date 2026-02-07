--!strict
-- @Name Test_BaseStateMachine
-- @Author iKrypto
-- @Description Unit tests for BaseStateMachine logic, transitions, and edge cases.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BaseStateMachine = require(game:FindFirstChild("BaseStateMachine", true))
local TestBase = require(script.Parent:FindFirstChild("TestBase"))

local Test_BaseStateMachine = {}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

--[[
	@summary Executes the BaseStateMachine unit test suite.
	@return boolean -- True when the suite passes
]]
function Test_BaseStateMachine.Run()
	local tester = TestBase.new("BaseStateMachine")

	-- TEST 1: Basic State Transitions
	tester:RunTest("Basic Transitions", function(t)
		local fsm = BaseStateMachine.new({ Id = "Test1", Name = "BasicFSM", ValidStates = {"Idle", "Work"} })

		function fsm:OnCleanup()
			-- Override to prevent errors during test
		end

		fsm:AddState("Idle", function() end, {"Work"})
		fsm:AddState("Work", function() end, {"Idle"})

		fsm:Start({ State = "Idle" })
		t:AssertEquals(fsm.State, "Idle", "Initial state should be Idle")

		fsm:ChangeState({ Name = "Work" })
		t:AssertEquals(fsm.State, "Work", "Should transition to Work")

		fsm:Destroy()
	end)

	-- TEST 2: Invalid Transitions
	tester:RunTest("Invalid Transitions", function(t)
		local fsm = BaseStateMachine.new({ Id = "Test2", Name = "StrictFSM", ValidStates = {"A", "B", "C"} })

		function fsm:OnCleanup()
			-- Override to prevent errors during test
		end

		fsm:AddState("A", function() end, {"B"}) -- A can only go to B
		fsm:AddState("B", function() end, {"C"})
		fsm:AddState("C", function() end, {})

		fsm:Start({ State = "A" })
		fsm:ChangeState({ Name = "C" }) -- Invalid: A -> C not allowed

		t:AssertEquals(fsm.State, "A", "Should remain in A after invalid transition attempt")

		fsm:Destroy()
	end)

	-- TEST 3: WaitSpan Delay
	tester:RunTest("WaitSpan Delay", function(t)
		local fsm = BaseStateMachine.new({ Id = "Test3", Name = "DelayFSM", ValidStates = {"Start", "End"} })

		function fsm:OnCleanup()
			-- Override to prevent errors during test
		end

		fsm:AddState("Start", function() end, {"End"})
		fsm:AddState("End", function() end, {})

		fsm:Start({ State = "Start" })

		fsm.WaitSpan = 0.5
		local startTime = os.clock()
		fsm:ChangeState({ Name = "End" })

		t:AssertEquals(fsm.State, "Start", "Should wait before transitioning")

		task.wait(0.6)
		t:AssertEquals(fsm.State, "End", "Should have transitioned after delay")
		t:Assert(os.clock() - startTime >= 0.5, "Delay should be at least 0.5s")

		fsm:Destroy()
	end)

	-- TEST 4: Terminal States
	tester:RunTest("Terminal States", function(t)
		local fsm = BaseStateMachine.new({ Id = "Test4", Name = "TerminalFSM", ValidStates = {"Run", "Finish"}, TerminalStates = {"Finish"} })

		function fsm:OnCleanup()
			-- Override to prevent errors during test
		end

		fsm:AddState("Run", function() end, {"Finish"})
		fsm:AddState("Finish", function() end, {})

		local completed = false
		fsm.Completed:Connect(function() completed = true end)

		fsm:Start({ State = "Run" })
		fsm:ChangeState({ Name = "Finish" })

		task.wait() -- Allow events
		t:AssertEquals(completed, true, "Completed event should fire on terminal state")
		t:AssertEquals(fsm.IsActive, false, "FSM should be inactive")

		fsm:Destroy()
	end)

	-- TEST 5: Context & Cleanup
	tester:RunTest("Context & Cleanup", function(t)
		local contextData = { Score = 100 }
		local fsm = BaseStateMachine.new({ Id = "Test5", Name = "ContextFSM", Context = contextData })

		function fsm:OnCleanup()
			-- Override to prevent errors during test
		end


		t:AssertEquals(fsm.Context.Score, 100, "Context should be passed correctly")

		local mockObj = { Destroyed = false, Destroy = function(s) s.Destroyed = true end }
		fsm:Manage(mockObj)

		fsm:Destroy()
		t:AssertEquals(mockObj.Destroyed, true, "Managed objects should be destroyed")
	end)

	-- TEST 6: Race Condition / Interruption
	tester:RunTest("Transition Interruption", function(t)
		local fsm = BaseStateMachine.new({ Id = "Test6", Name = "RaceFSM", ValidStates = {"A", "B", "C"} })

		function fsm:OnCleanup()
			-- Override to prevent errors during test
		end

		fsm:AddState("A", function() end, {"B", "C"})
		fsm:AddState("B", function() end, {})
		fsm:AddState("C", function() end, {})

		fsm:Start({ State = "A" })

		fsm.WaitSpan = 0.5
		-- Schedule transition to B in 0.5s
		fsm:ChangeState({ Name = "B" })

		-- Immediately override to C
		fsm:ChangeState({ Name = "C" })

		t:AssertEquals(fsm.State, "C", "Should switch to C immediately")

		task.wait(0.6)
		t:AssertEquals(fsm.State, "C", "Should NOT switch to B after delay (Delay should be invalidated)")

		fsm:Destroy()
	end)

	-- TEST 7: Transition Counts
	tester:RunTest("Transition Counts", function(t)
		local fsm = BaseStateMachine.new({ Id = "Test7", Name = "CountFSM", ValidStates = {"A", "B"} })

		function fsm:OnCleanup()
			-- Override to prevent errors during test
		end

		fsm:AddState("A", function() end, {"A", "B"})
		fsm:AddState("B", function() end, {})

		fsm:Start({ State = "A" })
		t:AssertEquals(fsm.TransitionCount, 1, "Initial count 1")

		fsm:ChangeState({ Name = "A" })
		t:AssertEquals(fsm.TransitionCount, 2, "Self-transition increments count")

		fsm:ChangeState({ Name = "B" })
		t:AssertEquals(fsm.TransitionCount, 1, "New state resets count")

		fsm:Destroy()
	end)
	
	tester:RunTest("Subclassing", function(t)
		local SubFSM = BaseStateMachine.Extend({ className = "SubFSM", validStates = {"A", "B"} })
		
		function SubFSM:RegisterStates()
			self:AddState("A", function() end)
		end
		function SubFSM:OnCleanup() end
		
		local fsm = SubFSM.new({ Id = "Sub1" })
		t:AssertEquals(tostring(fsm):match("SubFSM"), "SubFSM", "ToString should contain class name")
		
		fsm:Start({ State = "A" })
		t:AssertEquals(fsm.State, "A", "Subclass should register states")
		fsm:Destroy()
	end)

	tester:RunTest("Hierarchical FSM", function(t)
		local ChildFSM = BaseStateMachine.Extend({ className = "ChildFSM", validStates = {"ChildStart", "ChildEnd"} })
		function ChildFSM:RegisterStates()
			self:AddState("ChildStart", function(fsm) fsm.State = "ChildEnd" end, {"ChildEnd"})
			self:AddState("ChildEnd", function(fsm) fsm:Finish() end)
		end
		function ChildFSM:OnCleanup() end
		
		local ParentFSM = BaseStateMachine.Extend({ className = "ParentFSM", validStates = {"ParentStart", "ParentNext"} })
		function ParentFSM:RegisterStates()
			self:AddSubMachine("ParentStart", ChildFSM, {
				InitialState = "ChildStart",
				Transitions = { OnCompleted = "ParentNext" }
			})
			self:AddState("ParentNext", function(fsm) fsm:Finish() end)
		end
		function ParentFSM:OnCleanup() end
		
		local fsm = ParentFSM.new({ Id = "HFSM" })
		fsm:Start({ State = "ParentStart" })
		
		local ok = waitFor(function() return fsm.State == "ParentNext" end, 2)
		t:Assert(ok, "Parent should transition when child completes")
		fsm:Destroy()
	end)
	
	tester:RunTest("Legacy Cleanup", function(t)
		local fsm = BaseStateMachine.new({ Id = "Legacy", Name = "LegacyFSM", ValidStates = {"A", "B"} })
		local cleaned = false
		function fsm:OnCleanup() end
		
		fsm:AddState("A", function()
			return function() cleaned = true end
		end, {"B"})
		fsm:AddState("B", function() end)
		
		fsm:Start({ State = "A" })
		fsm:ChangeState({ Name = "B" })
		
		t:Assert(cleaned, "Legacy cleanup function should run on state change")
		fsm:Destroy()
	end)
	
	tester:RunTest("Explicit Fail/Cancel", function(t)
		local fsm = BaseStateMachine.new({ Id = "FailFSM", Name = "FailFSM", ValidStates = {"A"} })
		function fsm:OnCleanup() end
		fsm:AddState("A", function() end)
		fsm:Start({ State = "A" })
		
		local failed = false
		fsm.Failed:Connect(function() failed = true end)
		fsm:Fail("Reason")
		
		waitFor(function() return failed end, 1)
		t:Assert(failed, "Fail should fire Failed event")
		t:AssertEquals(fsm.IsActive, false, "Fail should stop FSM")
		
		local fsm2 = BaseStateMachine.new({ Id = "CancelFSM", Name = "CancelFSM", ValidStates = {"A"} })
		function fsm2:OnCleanup() end
		fsm2:AddState("A", function() end)
		fsm2:Start({ State = "A" })
		
		local cancelled = false
		fsm2.Cancelled:Connect(function() cancelled = true end)
		fsm2:Cancel()
		
		waitFor(function() return cancelled end, 1)
		t:Assert(cancelled, "Cancel should fire Cancelled event")
		
		fsm:Destroy()
		fsm2:Destroy()
	end)

	tester:RunTest("Priority Time-Slicing", function(t)
		local highPrio = BaseStateMachine.new({ Id = "High", Name = "HighPrio", Priority = 1 })
		local lowPrio = BaseStateMachine.new({ Id = "Low", Name = "LowPrio", Priority = 5 })
		function highPrio:OnCleanup() end
		function lowPrio:OnCleanup() end
		
		local highCount, lowCount = 0, 0
		
		highPrio:AddState("Run", { OnHeartbeat = function() highCount += 1 end })
		lowPrio:AddState("Run", { OnHeartbeat = function() lowCount += 1 end })
		
		highPrio:Start({ State = "Run" })
		lowPrio:Start({ State = "Run" })
		
		local start = os.clock()
		while os.clock() - start < 0.5 do task.wait() end
		
		highPrio:Destroy()
		lowPrio:Destroy()
		
		t:Assert(highCount > lowCount, string.format("High priority (%d) should run more often than Low priority (%d)", highCount, lowCount))
		t:Assert(highCount / (lowCount + 1) >= 1.5, string.format("Ratio (%.2f) should reflect priority difference", highCount / (lowCount + 1)))
	end)

	-- TEST 8: Hierarchical Cancellation
	tester:RunTest("Hierarchical Cancellation", function(t)
		-- Define a simple child FSM
		local ChildFSM = BaseStateMachine.Extend({ className = "ChildFSM", validStates = {"Running"} })
		function ChildFSM:RegisterStates()
			self:AddState("Running", function() end)
		end
		function ChildFSM:OnCleanup() end
		
		-- 1. Parent Cancel -> Child Cancel
		local ParentFSM = BaseStateMachine.Extend({ className = "ParentFSM", validStates = {"SubState"} })
		function ParentFSM:RegisterStates()
			self:AddSubMachine("SubState", ChildFSM, {
				InitialState = "Running",
				Transitions = { OnCompleted = "SubState" },
				StoreReference = "ChildRef"
			})
		end
		function ParentFSM:OnCleanup() end
		
		local parent = ParentFSM.new({ Id = "Parent1" })
		parent:Start({ State = "SubState" })
		
		waitFor(function() return parent.Context.ChildRef ~= nil end, 1)
		local child = parent.Context.ChildRef
		t:Assert(child and child.IsActive, "Child should be active")
		
		local childCancelled = false
		child.Cancelled:Connect(function() childCancelled = true end)
		
		parent:Cancel()
		task.wait()
		
		t:Assert(childCancelled, "Cancelling parent should cancel child")
		t:AssertEquals(child.IsActive, false, "Child should be inactive")
		parent:Destroy()
		
		-- 2. Child Cancel -> Parent Cancel (Default propagation)
		local parent2 = ParentFSM.new({ Id = "Parent2" })
		parent2:Start({ State = "SubState" })
		
		waitFor(function() return parent2.Context.ChildRef ~= nil end, 1)
		local child2 = parent2.Context.ChildRef
		
		local parentCancelled = false
		parent2.Cancelled:Connect(function() parentCancelled = true end)
		
		child2:Cancel()
		task.wait()
		
		t:Assert(parentCancelled, "Cancelling child should cancel parent by default")
		parent2:Destroy()
		
		-- 3. Child Cancel -> Parent Transition (Handled propagation)
		local ParentFSM_Handled = BaseStateMachine.Extend({ className = "ParentFSM_Handled", validStates = {"SubState", "Recovered"} })
		function ParentFSM_Handled:RegisterStates()
			self:AddSubMachine("SubState", ChildFSM, {
				InitialState = "Running",
				Transitions = { OnCancelled = "Recovered" },
				StoreReference = "ChildRef"
			})
			self:AddState("Recovered", function() end)
		end
		function ParentFSM_Handled:OnCleanup() end
		
		local parent3 = ParentFSM_Handled.new({ Id = "Parent3" })
		parent3:Start({ State = "SubState" })
		
		waitFor(function() return parent3.Context.ChildRef ~= nil end, 1)
		local child3 = parent3.Context.ChildRef
		
		child3:Cancel()
		task.wait()
		
		t:AssertEquals(parent3.State, "Recovered", "Parent should transition on child cancellation if configured")
		parent3:Destroy()
	end)

	-- TEST 9: Object State Features
	tester:RunTest("Object State Features", function(t)
		local fsm = BaseStateMachine.new({ Id = "ObjFSM", Name = "ObjFSM", ValidStates = {"A", "B"} })
		local enteredArgs = nil
		local leftA = false
		
		function fsm:OnCleanup() end

		fsm:AddState("A", {
			OnEnter = function(self, machine, arg1)
				enteredArgs = arg1
			end,
			OnLeave = function(self, machine)
				leftA = true
			end,
			Transitions = {
				{ TargetState = "B", Condition = function(machine, dt) return machine.Context.GoToB end }
			}
		}, {"B"})
		fsm:AddState("B", function() end)
		
		fsm:Start({ State = "A", Args = {"Hello"} })
		t:AssertEquals(enteredArgs, "Hello", "Arguments should be passed to OnEnter")
		
		-- Trigger condition
		fsm.Context.GoToB = true
		
		-- Wait for heartbeat update (condition check)
		waitFor(function() return fsm.State == "B" end, 1)
		
		t:AssertEquals(fsm.State, "B", "Condition should trigger transition")
		t:Assert(leftA, "OnLeave should be called")
		
		fsm:Destroy()
	end)

	-- TEST 10: Implicit & Special Terminal States
	tester:RunTest("Implicit & Special Terminal States", function(t)
		-- 1. Implicit Failed
		local fsm1 = BaseStateMachine.new({ Id = "FailTest", TerminalStates = {"Failed"} })
		function fsm1:OnCleanup() end
		fsm1:AddState("Start", function() end, {"Failed"})
		fsm1:Start({ State = "Start" })
		
		local failed = false
		fsm1.Failed:Connect(function() failed = true end)
		fsm1:ChangeState({ Name = "Failed" })
		
		waitFor(function() return failed end, 1)
		t:Assert(failed, "Transition to 'Failed' should trigger Fail()")
		fsm1:Destroy()
		
		-- 2. Implicit Cancelled
		local fsm2 = BaseStateMachine.new({ Id = "CancelTest", TerminalStates = {"Cancelled"} })
		function fsm2:OnCleanup() end
		fsm2:AddState("Start", function() end, {"Cancelled"})
		fsm2:Start({ State = "Start" })
		
		local cancelled = false
		fsm2.Cancelled:Connect(function() cancelled = true end)
		fsm2:ChangeState({ Name = "Cancelled" })
		
		waitFor(function() return cancelled end, 1)
		t:Assert(cancelled, "Transition to 'Cancelled' should trigger Cancel()")
		fsm2:Destroy()
		
		-- 3. Implicit Completed (Custom Name)
		local fsm3 = BaseStateMachine.new({ Id = "DoneTest", TerminalStates = {"Done"} })
		function fsm3:OnCleanup() end
		fsm3:AddState("Start", function() end, {"Done"})
		fsm3:Start({ State = "Start" })
		
		local completed = false
		fsm3.Completed:Connect(function() completed = true end)
		fsm3:ChangeState({ Name = "Done" })
		
		waitFor(function() return completed end, 1)
		t:Assert(completed, "Transition to implicit terminal state should trigger Finish()")
		fsm3:Destroy()
	end)

	-- TEST 11: SubMachine Defaults & Mapping
	tester:RunTest("SubMachine Defaults & Mapping", function(t)
		local ChildFSM = BaseStateMachine.Extend({ className = "Child", validStates = {"Run"} })
		function ChildFSM:RegisterStates()
			self:AddState("Run", function() end)
		end
		function ChildFSM:OnCleanup() end
		
		-- Case A: Default Failure Propagation
		local ParentA = BaseStateMachine.Extend({ className = "ParentA", validStates = {"Sub"} })
		function ParentA:RegisterStates()
			self:AddSubMachine("Sub", ChildFSM, { 
				InitialState = "Run", 
				Transitions = {},
				StoreReference = "Child"
			})
		end
		function ParentA:OnCleanup() end
		local fsmA = ParentA.new({ Id = "A" })
		local failedA = false
		fsmA.Failed:Connect(function() failedA = true end)
		fsmA:Start({ State = "Sub" })
		
		waitFor(function() return fsmA.Context.Child end, 1)
		fsmA.Context.Child:Fail("Test")
		
		waitFor(function() return failedA end, 1)
		t:Assert(failedA, "Child failure should propagate to parent by default")
		fsmA:Destroy()
		
		-- Case B: Mapped Failure
		local ParentB = BaseStateMachine.Extend({ className = "ParentB", validStates = {"Sub", "Recover"} })
		function ParentB:RegisterStates()
			self:AddSubMachine("Sub", ChildFSM, { 
				InitialState = "Run", 
				Transitions = { OnFailed = "Recover" },
				StoreReference = "Child"
			})
			self:AddState("Recover", function() end)
		end
		function ParentB:OnCleanup() end
		local fsmB = ParentB.new({ Id = "B" })
		fsmB:Start({ State = "Sub" })
		
		waitFor(function() return fsmB.Context.Child end, 1)
		fsmB.Context.Child:Fail("Test")
		
		waitFor(function() return fsmB.State == "Recover" end, 1)
		t:AssertEquals(fsmB.State, "Recover", "Child failure should trigger mapped transition")
		fsmB:Destroy()
	end)

	-- TEST 12: Manage Types & Context Shortcut
	tester:RunTest("Manage Types & Context Shortcut", function(t)
		local fsm = BaseStateMachine.new({ Id = "ManageTest", Context = { Foo = "Bar" } })
		function fsm:OnCleanup() end
		
		-- Context Shortcut
		t:AssertEquals(fsm.Foo, "Bar", "Should access Context via __index")
		
		-- Manage Types
		local cleanupCount = 0
		
		-- 1. Function
		fsm:Manage(function() cleanupCount += 1 end)
		
		-- 2. Table with Destroy
		local tbl = { Destroy = function() cleanupCount += 1 end }
		fsm:Manage(tbl)
		
		-- 3. RBXScriptConnection
		local bindable = Instance.new("BindableEvent")
		local conn = bindable.Event:Connect(function() end)
		fsm:Manage(conn)
		
		-- 4. Instance
		local folder = Instance.new("Folder")
		folder.Parent = ReplicatedStorage
		fsm:Manage(folder)
		
		fsm:Destroy()
		
		t:AssertEquals(cleanupCount, 2, "Function and Table cleanup should run")
		t:AssertEquals(conn.Connected, false, "Connection should be disconnected")
		t:AssertEquals(folder.Parent, nil, "Instance should be destroyed")
		bindable:Destroy()
	end)

	-- TEST 13: WaitSpan Cancel on Destroy
	tester:RunTest("WaitSpan Cancel on Destroy", function(t)
		local fsm = BaseStateMachine.new({ Id = "WaitDestroy", ValidStates = {"A", "B"} })
		function fsm:OnCleanup() end
		fsm:AddState("A", function() end, {"B"})
		fsm:AddState("B", function() end)
		
		fsm:Start({ State = "A" })
		
		fsm.WaitSpan = 0.5
		fsm:ChangeState({ Name = "B" })
		
		fsm:Destroy()
		
		task.wait(0.6)
		t:AssertEquals(fsm.IsActive, false, "Should be inactive")
		-- If the transition fired, it might have errored or changed state (if we could check it).
		-- The main check here is that no error occurred during the wait.
	end)

	-- TEST 14: InitialState used when Start called without State param
	tester:RunTest("InitialState default on Start", function(t)
		local fsm = BaseStateMachine.new({
			Id = "InitStateTest",
			Name = "InitStateFSM",
			ValidStates = {"Alpha", "Beta"},
			InitialState = "Alpha"
		})
		function fsm:OnCleanup() end

		fsm:AddState("Alpha", function() end, {"Beta"})
		fsm:AddState("Beta", function() end, {})

		-- Start WITHOUT passing a State — should use InitialState
		fsm:Start({})
		t:AssertEquals(fsm.State, "Alpha", "Should start in InitialState when no State param given")

		fsm:Destroy()
	end)

	-- TEST 15: InitialState defaults to first ValidState
	tester:RunTest("InitialState defaults to first ValidState", function(t)
		local fsm = BaseStateMachine.new({
			Id = "DefaultInitState",
			Name = "DefaultInitFSM",
			ValidStates = {"First", "Second"},
		})
		function fsm:OnCleanup() end

		fsm:AddState("First", function() end, {"Second"})
		fsm:AddState("Second", function() end, {})

		-- Start without State — should default to first ValidState
		fsm:Start({})
		t:AssertEquals(fsm.State, "First", "Should default to first ValidState")

		fsm:Destroy()
	end)

	-- TEST 16: Extended FSM InitialState via class definition
	tester:RunTest("Extended FSM InitialState", function(t)
		local ExtFSM = BaseStateMachine.Extend({
			className = "ExtInitFSM",
			validStates = {"Setup", "Run"},
			InitialState = "Setup",
		})
		function ExtFSM:RegisterStates()
			self:AddState("Setup", function() end, {"Run"})
			self:AddState("Run", function() end)
		end
		function ExtFSM:OnCleanup() end

		local fsm = ExtFSM.new({ Id = "ExtInit1" })
		fsm:Start({}) -- No State given
		t:AssertEquals(fsm.State, "Setup", "Extended FSM should use class-level InitialState")

		fsm:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_BaseStateMachine
