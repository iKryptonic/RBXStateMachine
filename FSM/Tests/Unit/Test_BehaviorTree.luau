--!strict
-- @Name Test_BehaviorTree
-- @Author iKrypto
-- @Description Unit tests for Behavior Tree component.

local BT = require(game:FindFirstChild("BehaviorTree", true) :: any)
local TestBase = require(script:FindFirstChild("TestBase") :: any)

local Test_BehaviorTree = {}

function Test_BehaviorTree.Run()
	local tester = TestBase.new("BehaviorTree")

	tester:RunTest("Condition Node", function(t)
		local successNode = BT.Condition(function(ctx) return true end)
		local failureNode = BT.Condition(function(ctx) return false end)
		
		t:AssertEquals(successNode({}), BT.BehaviorTreeStatus.Success, "Should return Success when predicate is true")
		t:AssertEquals(failureNode({}), BT.BehaviorTreeStatus.Failure, "Should return Failure when predicate is false")
	end)

	tester:RunTest("Selector Node", function(t)
		local node1 = BT.Condition(function() return false end)
		local node2 = BT.Condition(function() return true end)
		local node3 = BT.Condition(function() return false end)
		
		local selector = BT.Selector({node1, node2, node3})
		t:AssertEquals(selector({}), BT.BehaviorTreeStatus.Success, "Should succeed if any child succeeds")
		
		local failingSelector = BT.Selector({node1, node3})
		t:AssertEquals(failingSelector({}), BT.BehaviorTreeStatus.Failure, "Should fail if all children fail")
		
		local emptySelector = BT.Selector({})
		t:AssertEquals(emptySelector({}), BT.BehaviorTreeStatus.Failure, "Empty selector should fail")
	end)

	tester:RunTest("Sequence Node", function(t)
		local node1 = BT.Condition(function() return true end)
		local node2 = BT.Condition(function() return true end)
		local node3 = BT.Condition(function() return false end)
		
		local sequence = BT.Sequence({node1, node2})
		t:AssertEquals(sequence({}), BT.BehaviorTreeStatus.Success, "Should succeed if all children succeed")
		
		local failingSequence = BT.Sequence({node1, node3, node2})
		t:AssertEquals(failingSequence({}), BT.BehaviorTreeStatus.Failure, "Should fail if any child fails")
		
		local emptySequence = BT.Sequence({})
		t:AssertEquals(emptySequence({}), BT.BehaviorTreeStatus.Success, "Empty sequence should succeed")
	end)

	tester:RunTest("Inverter Node", function(t)
		local success = BT.Condition(function() return true end)
		local failure = BT.Condition(function() return false end)
		
		t:AssertEquals(BT.Inverter(success)({}), BT.BehaviorTreeStatus.Failure, "Should invert Success to Failure")
		t:AssertEquals(BT.Inverter(failure)({}), BT.BehaviorTreeStatus.Success, "Should invert Failure to Success")
	end)
	
	tester:RunTest("Succeeder Node", function(t)
		local failure = BT.Condition(function() return false end)
		t:AssertEquals(BT.Succeeder(failure)({}), BT.BehaviorTreeStatus.Success, "Should convert Failure to Success")
		
		local running = function() return BT.BehaviorTreeStatus.Running end
		t:AssertEquals(BT.Succeeder(running)({}), BT.BehaviorTreeStatus.Running, "Succeeder should not convert Running")
	end)

	tester:RunTest("SetState Action", function(t)
		local mockFSM = { State = "Idle" }
		local action = BT.SetState("Active")
		
		local status = action(mockFSM)
		t:AssertEquals(status, BT.BehaviorTreeStatus.Success, "Action should return Success")
		t:AssertEquals(mockFSM.State, "Active", "Should have updated FSM state")
	end)

	tester:RunTest("Complex Nested Tree", function(t)
		-- (val > 10 AND SetState) OR (val > 0 AND SetState)
		local tree = BT.Selector({
			BT.Sequence({
				BT.Condition(function(ctx) return ctx.val > 10 end),
				BT.SetState("High")
			}),
			BT.Sequence({
				BT.Condition(function(ctx) return ctx.val > 0 end),
				BT.SetState("Low")
			})
		})
		
		local mockFSM = { State = "Idle", val = 5 }
		tree(mockFSM)
		t:AssertEquals(mockFSM.State, "Low", "Should have fallen through to the second sequence")
		
		mockFSM.val = 15
		tree(mockFSM)
		t:AssertEquals(mockFSM.State, "High", "Should have succeeded on the first sequence")
	end)

	return tester:PrintSummary()
end

return Test_BehaviorTree
