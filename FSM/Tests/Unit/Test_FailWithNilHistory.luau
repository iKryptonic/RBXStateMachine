--!nocheck
-- @Name Test_FailWithNilHistory
-- @Description Tests BaseStateMachine:Fail behavior when Logger.History is empty/missing.

local BaseStateMachine = require(game:FindFirstChild("BaseStateMachine", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)
local TestUtils = require(script.Parent:FindFirstChild("TestUtils") :: any)

local Test_FailWithNilHistory = {}

local waitFor = TestUtils and TestUtils.WaitFor or function(pred, timeout)
	local t0 = os.clock()
	while not pred() and (os.clock() - t0) < (timeout or 1) do
		task.wait()
	end
end

function Test_FailWithNilHistory.Run()
	local tester = TestBase.new("FailWithNilHistory")

	if not BaseStateMachine then
		tester:RunTest("Framework loaded", function(t)
			t:SkipTest("Framework not initialized")
		end)
		return tester:PrintSummary()
	end

	local DummyFSM = BaseStateMachine.Extend({ className = "DummyFSM_FailNilHist", validStates = { "Idle" } })
	function DummyFSM:RegisterStates()
		self:AddState("Idle", function() end)
	end
	function DummyFSM:OnCleanup() end

	local function newRunningFSM(id)
		local fsm = DummyFSM.new({ Id = id, Name = id, ValidStates = { "Idle" } })
		fsm:AddState("Idle", function() end)
		fsm:Start({ State = "Idle" })
		-- Clear history so we deterministically test the "empty history" path.
		if fsm.Logger and fsm.Logger.History then
			while #fsm.Logger.History > 0 do
				table.remove(fsm.Logger.History)
			end
		end
		return fsm
	end

	tester:RunTest("Fail with reason and empty history fires Failed signal with reason", function(t)
		local fsm = newRunningFSM("FailNH_01")
		local fired, gotReason = false, nil
		fsm.Failed:Connect(function(reason)
			fired = true
			gotReason = reason
		end)
		fsm:Fail("boom")
		waitFor(function() return fired end, 1)
		t:Assert(fired, "Failed signal should fire")
		t:AssertEquals(gotReason, "boom", "Reason should equal provided reason when history empty")
		t:AssertEquals(fsm.IsActive, false, "FSM should no longer be active")
		fsm:Destroy()
	end)

	tester:RunTest("Fail with nil reason and empty history fires Failed signal with empty string", function(t)
		local fsm = newRunningFSM("FailNH_02")
		local fired, gotReason = false, nil
		fsm.Failed:Connect(function(reason)
			fired = true
			gotReason = reason
		end)
		fsm:Fail(nil)
		waitFor(function() return fired end, 1)
		t:Assert(fired, "Failed signal should fire even with nil reason")
		t:AssertEquals(gotReason, "", "Reason should be empty string when nil + empty history")
		fsm:Destroy()
	end)

	tester:RunTest("Fail when not active does nothing", function(t)
		local fsm = newRunningFSM("FailNH_03")
		fsm:Cancel() -- forces IsActive=false
		waitFor(function() return fsm.IsActive == false end, 1)

		local fired, gotReason = false, nil
		fsm.Failed:Connect(function(reason)
			fired = true
			gotReason = reason
		end)
		fsm:Fail("ignored")
		task.wait(0.05)
		t:Assert(not fired, "Failed signal should NOT fire when FSM is not active")
		t:AssertEquals(gotReason, nil, "Reason should remain nil since signal didn't fire")
		fsm:Destroy()
	end)

	tester:RunTest("Fail with multiple ERROR logs concatenates them with ' | '", function(t)
		local fsm = newRunningFSM("FailNH_04")
		fsm:Log({ Level = "ERROR", Message = "errA" })
		fsm:Log({ Level = "ERROR", Message = "errB" })
		fsm:Log({ Level = "INFO", Message = "ignored-info" })
		fsm:Log({ Level = "ERROR", Message = "errC" })

		local gotReason = nil
		fsm.Failed:Connect(function(reason) gotReason = reason end)
		fsm:Fail("base")
		waitFor(function() return gotReason ~= nil end, 1)

		t:AssertNotNil(gotReason, "Failed signal should fire with combined reason")
		gotReason = tostring(gotReason)
		t:Assert(gotReason:find("base", 1, true) ~= nil, "Combined reason should contain base reason")
		t:Assert(gotReason:find("errA", 1, true) ~= nil, "Combined reason should contain errA")
		t:Assert(gotReason:find("errB", 1, true) ~= nil, "Combined reason should contain errB")
		t:Assert(gotReason:find("errC", 1, true) ~= nil, "Combined reason should contain errC")
		t:Assert(gotReason:find(" | ", 1, true) ~= nil, "Parts should be joined with ' | '")
		t:Assert(gotReason:find("ignored-info", 1, true) == nil, "Non-ERROR logs must not appear in reason")
		fsm:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_FailWithNilHistory
