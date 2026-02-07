--!nocheck
-- @Name Test_Scheduler_Extended
-- @Author iKrypto (audit)
-- @Description Extended unit tests for Scheduler covering _taskCount, Clear, Start, and naming safety.

local RunService = game:GetService("RunService")
local SchedulerModule = require(game:FindFirstChild("Scheduler", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_Scheduler_Extended = {}

local DefaultSettings = {
	FrameBudget = 0.015,
	PriorityWeight = 0.001,
}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

function Test_Scheduler_Extended.Run()
	local tester = TestBase.new("Scheduler_Extended")

	-- TEST 1: Schedule increments _taskCount
	tester:RunTest("Schedule increments _taskCount", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)
		t:AssertEquals(scheduler:GetTaskCount(), 0, "Initial count should be 0")

		scheduler:Schedule({
			TaskName = "CountTask1",
			TaskExecutionDelay = 10,
			TaskAction = function() end,
		})
		t:AssertEquals(scheduler:GetTaskCount(), 1, "Count should be 1 after scheduling")

		scheduler:Schedule({
			TaskName = "CountTask2",
			TaskExecutionDelay = 10,
			TaskAction = function() end,
		})
		t:AssertEquals(scheduler:GetTaskCount(), 2, "Count should be 2 after scheduling")
	end)

	-- TEST 2: Overwriting a task keeps count accurate
	tester:RunTest("Overwrite keeps count accurate", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)

		scheduler:Schedule({
			TaskName = "SameKey",
			TaskExecutionDelay = 10,
			TaskAction = function() end,
		})
		t:AssertEquals(scheduler:GetTaskCount(), 1, "Count should be 1")

		scheduler:Schedule({
			TaskName = "SameKey",
			TaskExecutionDelay = 10,
			TaskAction = function() end,
		})
		t:AssertEquals(scheduler:GetTaskCount(), 1, "Count should still be 1 after overwrite")
	end)

	-- TEST 3: _taskCount decrements on non-recurring task completion
	tester:RunTest("Task completion decrements count", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)
		local ran = false

		scheduler:Schedule({
			TaskName = "OneShotCount",
			TaskExecutionDelay = 0,
			TaskAction = function() ran = true end,
		})
		t:AssertEquals(scheduler:GetTaskCount(), 1, "Count should be 1 before execution")

		scheduler:Step("Heartbeat")
		waitFor(function() return ran end, 1)

		t:AssertEquals(scheduler:GetTaskCount(), 0, "Count should be 0 after one-shot task runs")
	end)

	-- TEST 4: Clear resets all state without error
	tester:RunTest("Clear resets all state", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)

		scheduler:Schedule({
			TaskName = "ClearTest1",
			TaskExecutionDelay = 10,
			TaskAction = function() end,
		})
		scheduler:Schedule({
			TaskName = "ClearTest2",
			TaskExecutionDelay = 10,
			TaskAction = function() end,
		})
		t:AssertEquals(scheduler:GetTaskCount(), 2, "Count should be 2 before Clear")

		local ok, err = pcall(function()
			scheduler:Clear()
		end)
		t:Assert(ok, "Clear should not error: " .. tostring(err))
		t:AssertEquals(scheduler:GetTaskCount(), 0, "Count should be 0 after Clear")
		t:Assert(next(scheduler.Tasks) == nil, "Tasks should be empty after Clear")
		t:Assert(next(scheduler._heaps) == nil, "Heaps should be empty after Clear")
	end)

	-- TEST 5: Start is idempotent
	tester:RunTest("Start is idempotent", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)

		scheduler:Start()
		local firstConn = scheduler._connections.Heartbeat
		t:Assert(firstConn ~= nil, "Heartbeat connection should exist after Start")

		scheduler:Start()
		local secondConn = scheduler._connections.Heartbeat
		t:AssertEquals(firstConn, secondConn, "Second Start should not create new connection")

		-- Cleanup
		for _, conn in pairs(scheduler._connections) do
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			end
		end
	end)

	-- TEST 6: _connections is separate from _running
	tester:RunTest("Connections separate from running tasks", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)

		scheduler:Start()
		t:Assert(scheduler._connections.Heartbeat ~= nil, "Should have Heartbeat connection")

		-- Schedule a task named "Heartbeat" - should not interfere
		scheduler:Schedule({
			TaskName = "Heartbeat",
			TaskExecutionDelay = 10,
			TaskAction = function() end,
		})
		t:Assert(scheduler:GetTask("Heartbeat") ~= nil, "Task named 'Heartbeat' should be scheduled")
		t:Assert(scheduler._connections.Heartbeat ~= nil, "Connection should still exist")

		-- Cleanup
		for _, conn in pairs(scheduler._connections) do
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			end
		end
	end)

	-- TEST 7: GenerateKey returns unique values
	tester:RunTest("GenerateKey uniqueness", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)
		local keys = {}
		for _ = 1, 100 do
			local key = scheduler:GenerateKey()
			t:Assert(keys[key] == nil, "Key should be unique: " .. tostring(key))
			keys[key] = true
		end
	end)

	-- TEST 8: Recurring task count stays stable
	tester:RunTest("Recurring task count stable", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)
		local count = 0

		scheduler:Schedule({
			TaskName = "RecurringCount",
			TaskExecutionDelay = 0,
			IsRecurringTask = true,
			TaskAction = function()
				count += 1
			end,
		})
		t:AssertEquals(scheduler:GetTaskCount(), 1, "Count should be 1 for recurring task")

		scheduler:Step("Heartbeat")
		waitFor(function() return count >= 1 end, 1)

		t:AssertEquals(scheduler:GetTaskCount(), 1, "Count should stay 1 after recurring task runs")

		scheduler:Deschedule("RecurringCount")
	end)

	-- TEST 9: AddToHistory ring buffer wrapping
	tester:RunTest("History ring buffer wraps", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)

		for i = 1, 110 do
			scheduler:AddToHistory({ Name = "Task_" .. i }, "Completed", 0.001)
		end

		-- Ring buffer has 100 slots; after 110 entries, earliest should be overwritten
		local hasTask110 = false
		for _, entry in pairs(scheduler.History) do
			if entry and entry.Name == "Task_110" then hasTask110 = true end
		end
		t:Assert(hasTask110, "Latest entries should be in history")
	end)

	-- TEST 10: Invalid Schedule returns nil and keeps count
	tester:RunTest("Invalid Schedule returns nil", function(t)
		local scheduler = SchedulerModule.new(DefaultSettings)

		local result = scheduler:Schedule({ TaskAction = function() end })
		t:Assert(result == nil, "Missing TaskName should return nil")
		t:AssertEquals(scheduler:GetTaskCount(), 0, "Count should stay 0")

		local result2 = scheduler:Schedule({ TaskName = "NoAction" })
		t:Assert(result2 == nil, "Missing TaskAction should return nil")
		t:AssertEquals(scheduler:GetTaskCount(), 0, "Count should stay 0")
	end)

	return tester:PrintSummary()
end

return Test_Scheduler_Extended
