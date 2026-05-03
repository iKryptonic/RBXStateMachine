--!nocheck
-- @Name Test_BoundedDiscovery
-- @Author iKrypto
-- @Description Unit tests for bounded discovery loops with resolution and timeout behavior.

local TestBase = require((script.Parent:FindFirstChild("TestBase") or script.Parent.Parent:FindFirstChild("TestBase")) :: any)

local Test_BoundedDiscovery = {}

local function boundedDiscover(container: Instance, childName: string, intervalSeconds: number, timeoutSeconds: number)
	local startedAt = os.clock()
	while (os.clock() - startedAt) < timeoutSeconds do
		local child = container:FindFirstChild(childName)
		if child then
			return child, os.clock() - startedAt
		end
		task.wait(intervalSeconds)
	end

	local child = container:FindFirstChild(childName)
	if child then
		return child, os.clock() - startedAt
	end
	return nil, os.clock() - startedAt
end

function Test_BoundedDiscovery.Run()
	local tester = TestBase.new("BoundedDiscovery")

	tester:RunTest("Discovery resolves when the part appears within the retry window", function(t)
		local folder = Instance.new("Folder")
		folder.Name = "DiscoveryResolveFolder"
		folder.Parent = workspace

		task.delay(0.15, function()
			local part = Instance.new("Part")
			part.Name = "LatePart"
			part.Parent = folder
		end)

		local discovered, elapsed = boundedDiscover(folder, "LatePart", 0.05, 3)
		t:Assert(discovered ~= nil, "Bounded discovery should find the part once it appears")
		t:Assert(elapsed >= 0.10, "Discovery should wait until after the delayed spawn")
		t:Assert(elapsed < 3, "Discovery should finish before the timeout window")

		folder:Destroy()
	end)

	tester:RunTest("Discovery times out cleanly when the part never appears", function(t)
		local folder = Instance.new("Folder")
		folder.Name = "DiscoveryTimeoutFolder"
		folder.Parent = workspace

		local discovered, elapsed = boundedDiscover(folder, "NeverAppears", 0.05, 3)
		t:AssertEquals(discovered, nil, "Bounded discovery should return nil when the part never appears")
		t:Assert(elapsed >= 2.95, string.format("Timeout should run for about 3 seconds (got %.3f)", elapsed))
		t:Assert(elapsed < 3.5, string.format("Timeout should remain bounded near 3 seconds (got %.3f)", elapsed))

		folder:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_BoundedDiscovery
