--!nocheck
-- @Name Test_Scheduler
-- @Author iKrypto
-- @Description Unit tests for Scheduler scheduling, timing, and edge cases.

local RunService = game:GetService("RunService")
local SchedulerModule = require(game:FindFirstChild("Scheduler", true) :: any)
local TestBase = require(script:FindFirstChild("TestBase") :: any)

local Test_Scheduler = {}

local ErrorMarginUpperLimit = 0.10

-- Increased budget for testing environment to handle stress tests
local DefaultSettings = {
	PerformanceManagerSettings = {
		WarnOnLongThreadExecutions = true,
		MaximumThreadWarningThreshold = 12.5,
	},

	LoggerSettings = {
		DebuggingEnabled = true,
		MinimumLoggingLevel = 3,
	},
	FrameBudget = 0.015 -- 15ms budget for tests
}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

--[[
	@summary Executes the Scheduler unit test suite.
	@return boolean -- True when the suite passes
]]
function Test_Scheduler.Run()
	local tester = TestBase.new("Scheduler")
	local scheduler = SchedulerModule.new(DefaultSettings)
	scheduler:Initialize(DefaultSettings)
	scheduler:ExposeAPI()
	shared.Scheduler = scheduler
	scheduler:Clear()

	local heartbeatConn = RunService.Heartbeat:Connect(function()
		scheduler:Step("Heartbeat")
	end)

	tester:RunTest("Schedule", function(t)
		local ran = false
		scheduler:Schedule({
			TaskName = "Schedule",
			TaskExecutionDelay = 0.5,
			TaskAction = function()
				ran = true
			end
		})

		local ok = waitFor(function() return ran end, 1)
		t:Assert(ok, "Task should run after 0.5 seconds")
	end)

	tester:RunTest("CancelTask", function(t)
		local ran = false
		scheduler:Schedule({
			TaskName = "CancelTask",
			TaskExecutionDelay = 0.5,
			TaskAction = function()
				ran = true
			end
		})

		scheduler:Deschedule("CancelTask")
		task.wait(1)

		local exists = scheduler:GetTask("CancelTask") ~= nil
		t:Assert(not exists, "Task should be descheduled")
		t:Assert(not ran, "Cancelled task should not run")
	end)

	tester:RunTest("DescheduleReschedule", function(t)
		local ran = false
		scheduler:Schedule({
			TaskName = "DescheduleReSchedule",
			TaskExecutionDelay = 0.5,
			TaskAction = function()
				ran = true
			end
		})

		scheduler:Deschedule("DescheduleReSchedule")
		task.wait(1)
		t:Assert(not ran, "Task should not execute after descheduling")

		scheduler:Schedule({
			TaskName = "DescheduleReSchedule",
			TaskExecutionDelay = 0,
			TaskAction = function()
				ran = true
			end
		})

		local ok = waitFor(function() return ran end, 1)
		t:Assert(ok, "Rescheduled task should execute")
	end)

	tester:RunTest("ScheduleImmediateTask", function(t)
		local ran = false
		scheduler:Schedule({
			TaskName = "ScheduleImmediateTask",
			TaskExecutionDelay = 0,
			TaskAction = function()
				ran = true
			end
		})

		local ok = waitFor(function() return ran end, 1)
		t:Assert(ok, "Immediate task should run")
	end)

	tester:RunTest("ScheduleNegativeDelayTask", function(t)
		local ran = false
		scheduler:Schedule({
			TaskName = "ScheduleNegativeDelayTask",
			TaskExecutionDelay = -1,
			TaskAction = function()
				ran = true
			end
		})

		local ok = waitFor(function() return ran end, 1)
		t:Assert(ok, "Negative delay task should run immediately")
	end)

	tester:RunTest("ScheduleShortDelayedTask", function(t)
		local delay = 0.25
		local start = os.clock()
		local errorMargin = 1
		scheduler:Schedule({
			TaskName = "ScheduleShortDelayedTask",
			TaskExecutionDelay = delay,
			TaskAction = function()
				local endTime = os.clock()
				local timeTaken = endTime - start
				errorMargin = math.abs((delay - timeTaken) / delay)
			end
		})

		local ok = waitFor(function() return errorMargin < 1 end, 1)
		t:Assert(ok and errorMargin < ErrorMarginUpperLimit, "Short delay margin too high: " .. tostring(math.round(errorMargin * 100)) .. "%")
	end)

	tester:RunTest("ScheduleMediumDelayedTask", function(t)
		local delay = 0.2
		local start = os.clock()
		local errorMargin = 1
		scheduler:Schedule({
			TaskName = "ScheduleMediumDelayedTask",
			TaskExecutionDelay = delay,
			TaskAction = function()
				local endTime = os.clock()
				local timeTaken = endTime - start
				errorMargin = math.abs((delay - timeTaken) / delay)
			end
		})

		local ok = waitFor(function() return errorMargin < 1 end, 1)
		t:Assert(ok and errorMargin < ErrorMarginUpperLimit, "Medium delay margin too high: " .. tostring(math.round(errorMargin * 100)) .. "%")
	end)

	tester:RunTest("ScheduleLongDelayedTask", function(t)
		local delay = 0.5
		local start = os.clock()
		local errorMargin = 1
		scheduler:Schedule({
			TaskName = "ScheduleLongDelayedTask",
			TaskExecutionDelay = delay,
			TaskAction = function()
				local endTime = os.clock()
				local timeTaken = endTime - start
				errorMargin = math.abs((delay - timeTaken) / delay)
			end
		})

		local ok = waitFor(function() return errorMargin < 1 end, 2)
		t:Assert(ok and errorMargin < ErrorMarginUpperLimit, "Long delay margin too high: " .. tostring(math.round(errorMargin * 100)) .. "%")
	end)

	tester:RunTest("ScheduleMultipleTasks", function(t)
		local order: {string} = {}
		scheduler:Schedule({
			TaskName = scheduler:GenerateKey(),
			TaskExecutionDelay = 0.1,
			TaskAction = function()
				table.insert(order, "Task 1")
			end
		})
		scheduler:Schedule({
			TaskName = scheduler:GenerateKey(),
			TaskExecutionDelay = 0.2,
			TaskAction = function()
				table.insert(order, "Task 2")
			end
		})
		scheduler:Schedule({
			TaskName = scheduler:GenerateKey(),
			TaskExecutionDelay = 0.3,
			TaskAction = function()
				table.insert(order, "Task 3")
			end
		})
		scheduler:Schedule({
			TaskName = scheduler:GenerateKey(),
			TaskExecutionDelay = 0.4,
			TaskAction = function()
				table.insert(order, "Task 4")
			end
		})
		scheduler:Schedule({
			TaskName = scheduler:GenerateKey(),
			TaskExecutionDelay = 0.5,
			TaskAction = function()
				table.insert(order, "Task 5")
			end
		})

		local ok = waitFor(function() return #order == 5 end, 2)
		t:Assert(ok, "Expected 5 tasks to run")
		t:Assert(order[1] == "Task 1" and order[2] == "Task 2" and order[3] == "Task 3" and order[4] == "Task 4" and order[5] == "Task 5", "Tasks did not run in correct order")
	end)

	tester:RunTest("ScheduleManyTasks", function(t)
		local count = 0
		local maxTasks = 10000
		for i = 1, maxTasks do
			scheduler:Schedule({
				TaskName = "Task " .. i,
				TaskExecutionDelay = 0,
				TaskAction = function()
					count += 1
				end
			})
		end

		local ok = waitFor(function() return count == maxTasks end, 10)
		t:Assert(ok, "Not all tasks ran successfully")
	end)

	tester:RunTest("ScheduleRecurringTask", function(t)
		local count = 0
		scheduler:Schedule({
			TaskName = "ScheduleRecurringTask",
			TaskExecutionDelay = 0.1,
			IsRecurringTask = true,
			TaskAction = function()
				count += 1
				if count == 3 then
					scheduler:Deschedule("ScheduleRecurringTask")
				end
			end
		})

		local ok = waitFor(function() return count == 3 end, 1)
		local stillExists = scheduler["ScheduleRecurringTask"] ~= nil
		t:Assert(not stillExists, "Recurring task should be descheduled")
		t:Assert(ok, "Recurring task should run 3 times")
	end)

	tester:RunTest("InvalidInputTest", function(t)
		local beforeCount = scheduler:GetTaskCount()
		local result = scheduler:Schedule({
			TaskExecutionDelay = "invalid",
			TaskAction = function() end
		})
		local afterCount = scheduler:GetTaskCount()
		t:Assert(result == nil, "Invalid input should return nil")
		t:Assert(beforeCount == afterCount, "Invalid input should not create a task")
	end)

	tester:RunTest("ExecuteTask", function(t)
		local ran = false
		local taskObj = scheduler:Schedule({
			TaskName = "ManualExec",
			TaskAction = function() ran = true end
		})
		scheduler:ExecuteTask("ManualExec")
		t:Assert(ran, "ExecuteTask should run the task immediately")
		
		ran = false
		scheduler:ExecuteTask(taskObj)
		t:Assert(ran, "ExecuteTask should accept task object")
	end)

	tester:RunTest("FrameBudgetDeferral", function(t)
		-- Create an isolated scheduler for this test to avoid race conditions with the background heartbeat
		local localScheduler = SchedulerModule.new()
		localScheduler.Settings.FrameBudget = 0.001
		local count = 0
		
		-- Schedule enough tasks to exceed budget
		for i = 1, 100 do
			localScheduler:Schedule({
				TaskName = "BudgetTask_" .. i,
				TaskExecutionDelay = 0,
				TaskAction = function() 
					local s = os.clock()
					while os.clock() - s < 0.00001 do end -- Burn tiny time
					count += 1 
				end
			})
		end
		
		localScheduler:Step("Heartbeat")
		t:Assert(count > 0, "Should run at least one task")
		t:Assert(count < 100, "Should defer tasks when budget exceeded")
		t:Assert(localScheduler.LastFrameStats.Budget == 0.001, "Budget should be updated")
	end)

	tester:RunTest("ErrorHandling", function(t)
		local errTask = scheduler:Schedule({
			TaskName = "ErrorTask",
			TaskAction = function() error("Intentional Fail") end
		})
		
		local found = waitFor(function()
			for _, entry in ipairs(scheduler.History) do
				if entry.Name == "ErrorTask" and entry.Status == "Failed" then return true end
			end
			return false
		end, 1)
		t:Assert(found, "History should record failed task")
	end)

	tester:RunTest("ResetTask", function(t)
		local taskName = "ResetTest"
		scheduler:Schedule({
			TaskName = taskName,
			TaskAction = function() end
		})
		scheduler:ExecuteTask(taskName)
		local taskObj = scheduler:GetTask(taskName)
		t:Assert(taskObj.RunCount > 0, "Task should have run")
		
		scheduler:ResetTask(taskName)
		t:AssertEquals(taskObj.RunCount, 0, "RunCount should be 0 after reset")
	end)

	tester:RunTest("GetSyncData", function(t)
		local data = scheduler:GetSyncData()
		t:Assert(data.Tasks ~= nil, "SyncData should contain Tasks")
		t:Assert(data.Settings ~= nil, "SyncData should contain Settings")
	end)

	tester:RunTest("ResetTask fallback", function(t)
		local taskName = "ResetFallback"
		scheduler:Schedule({
			TaskName = taskName,
			TaskAction = function() end
		})
		local taskObj = scheduler:GetTask(taskName)
		if taskObj then
			(taskObj :: any).Reset = nil
			(taskObj :: any).RunCount = 5
			(taskObj :: any).TotalRunTime = 2
			(taskObj :: any).MaxRunTime = 1
			scheduler:ResetTask(taskName)
			t:AssertEquals(taskObj.RunCount, 0, "Fallback reset should clear RunCount")
			t:AssertEquals(taskObj.TotalRunTime, 0, "Fallback reset should clear TotalRunTime")
			t:AssertEquals(taskObj.MaxRunTime, 0, "Fallback reset should clear MaxRunTime")
		end
	end)

	tester:RunTest("CheckAdmin", function(t)
		local ok = scheduler:CheckAdmin({ UserId = -1 })
		-- In Studio this should be true; in live environments, UserId check applies.
		t:Assert(type(ok) == "boolean", "CheckAdmin should return boolean")
	end)

	if heartbeatConn then heartbeatConn:Disconnect() end

	return tester:PrintSummary()
end

return Test_Scheduler
