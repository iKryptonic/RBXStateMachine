--!strict
-- @Name Test_Signal
-- @Author iKrypto
-- @Description Unit tests for Signal implementation.

local Signal = require(game:FindFirstChild("Signal", true) :: any)
local TestBase = require(script:FindFirstChild("TestBase") :: any)

local Test_Signal = {}

function Test_Signal.Run()
	local tester = TestBase.new("Signal")

	tester:RunTest("Connect + Fire", function(t)
		local sig = Signal.new()
		local received = nil
		sig:Connect(function(v) received = v end)
		sig:Fire(42)
		-- Allow async handler
		task.wait()
		t:AssertEquals(received, 42, "Handler should receive value")
		sig:Destroy()
	end)

	tester:RunTest("Once", function(t)
		local sig = Signal.new()
		local count = 0
		sig:Once(function() count += 1 end)
		sig:Fire()
		sig:Fire()
		task.wait()
		t:AssertEquals(count, 1, "Once should only fire once")
		sig:Destroy()
	end)

	tester:RunTest("Disconnect", function(t)
		local sig = Signal.new()
		local count = 0
		local conn = sig:Connect(function() count += 1 end)
		conn:Disconnect()
		sig:Fire()
		task.wait()
		t:AssertEquals(count, 0, "Disconnected handler should not fire")
		sig:Destroy()
	end)

	tester:RunTest("Wait", function(t)
		local sig = Signal.new()
		local got = nil
		task.spawn(function()
			got = sig:Wait()
		end)
		sig:Fire("ok")
		task.wait()
		t:AssertEquals(got, "ok", "Wait should resume with fired value")
		sig:Destroy()
	end)

	tester:RunTest("Destroy clears handlers", function(t)
		local sig = Signal.new()
		local count = 0
		sig:Connect(function() count += 1 end)
		sig:Destroy()
		sig:Fire()
		task.wait()
		t:AssertEquals(count, 0, "Destroyed signal should not invoke handlers")
	end)

	return tester:PrintSummary()
end

return Test_Signal
