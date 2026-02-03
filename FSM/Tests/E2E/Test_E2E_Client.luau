--!strict
-- @Name Test_E2E_Client
-- @Author iKrypto
-- @Description End-to-end client test for replication and command pipeline.

local RunService = game:GetService("RunService")
local Orchestrator = require(game:FindFirstChild("Orchestrator", true) :: any)
local TestBase = require(script:FindFirstChild("TestBase") :: any)

local Test_E2E_Client = {}

local function waitFor(predicate: () -> boolean, timeout: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeout do
		task.wait()
	end
	return predicate()
end

function Test_E2E_Client.Run()
	local tester = TestBase.new("E2E_Client")

	if not RunService:IsClient() then
		return tester:PrintSummary()
	end

	tester:RunTest("Replication + Command Pipeline", function(t)
		Orchestrator:RegisterComponents()

		local target = Orchestrator.Request("E2E_GetReplicationTarget")
		t:Assert(target ~= nil, "Should receive replication target from server")
		if not target then return end

		local ok = waitFor(function()
			local entity = Orchestrator.GetEntity(target.EntityId)
			return entity and entity.Value == target.Value
		end, 5)
		t:Assert(ok, "Client should receive replicated entity updates")

		-- Send command to server (handled by E2E server test)
		Orchestrator.SendCommand(target.EntityId, "Ping")
	end)

	return tester:PrintSummary()
end

return Test_E2E_Client
