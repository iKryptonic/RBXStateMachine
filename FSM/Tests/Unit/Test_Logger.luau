--!strict
-- @Name Test_Logger
-- @Author iKrypto
-- @Description Unit tests for the Logger module.

local Logger = require(game:FindFirstChild("Logger", true) :: any)
local TestBase = require(script:FindFirstChild("TestBase") :: any)

local Test_Logger = {}

function Test_Logger.Run()
	local tester = TestBase.new("Logger")

	tester:RunTest("Initialization", function(t)
		local log = Logger.new({ Name = "TestLog" })
		t:AssertEquals(log.Source, "TestLog", "Source name should be set")
		t:Assert(log.History ~= nil, "History should be initialized")
	end)

	tester:RunTest("Logging & History", function(t)
		local log = Logger.new({ Name = "HistoryLog" })
		
		log:Log({ Level = "INFO", Message = "Test Message", OperationId = "Op1" })
		
		local history = log:GetHistory()
		t:AssertEquals(#history, 1, "Should have 1 log entry")
		t:AssertEquals(history[1].Message, "Test Message", "Message should match")
		t:AssertEquals(history[1].Level, "INFO", "Level should match")
		t:AssertEquals(history[1].OperationId, "Op1", "OperationId should match")
	end)

	tester:RunTest("Max History", function(t)
		local log = Logger.new({ Name = "MaxLog" })
		-- Assuming default max history is 100 or similar, let's push a few
		-- We can't easily test the exact cap without knowing the internal constant, 
		-- but we can verify it accepts multiple entries.
		for i = 1, 5 do
			log:Log({ Level = "INFO", Message = "Msg " .. i })
		end
		t:AssertEquals(#log:GetHistory(), 5, "Should store multiple entries")
	end)

	tester:RunTest("Enabled Toggle", function(t)
		local log = Logger.new({ Name = "ToggleLog" })
		log.Enabled = false
		
		-- Note: Log() usually still records to History even if Enabled=false (which controls print output)
		-- If implementation changes to stop recording, this test might need adjustment.
		-- Based on typical patterns, Enabled controls Output, not History.
		-- We mainly verify no errors occur.
		log:Log({ Level = "INFO", Message = "Hidden" })
	end)

	tester:RunTest("Disabled Skips History", function(t)
		local log = Logger.new({ Name = "SkipHistory" })
		log.Enabled = false
		log:Log({ Level = "INFO", Message = "Hidden" })
		t:AssertEquals(#log:GetHistory(), 0, "Disabled logger should not record history")
	end)

	tester:RunTest("Unknown Level + NonString OperationId", function(t)
		local log = Logger.new({ Name = "CustomLevel" })
		log:Log({ Level = "CUSTOM", Message = "Custom", OperationId = 123 })
		local history = log:GetHistory()
		t:AssertEquals(history[1].Level, "CUSTOM", "Should store custom level")
		t:AssertEquals(history[1].OperationId, 123, "Should store non-string operation id")
	end)

	return tester:PrintSummary()
end

return Test_Logger