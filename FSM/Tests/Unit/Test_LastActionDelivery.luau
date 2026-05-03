--!nocheck
--[=[
	@module Test_LastActionDelivery
	@description Defines the `Test_LastActionDelivery` module and its exported API.
]=]

local TestBase = require((script.Parent:FindFirstChild("TestBase") or script.Parent.Parent:FindFirstChild("TestBase")) :: any)

local Test_LastActionDelivery = {}

local function findModule(moduleName: string, ancestorNames: { string }): ModuleScript
	for _, descendant in ipairs(game:GetDescendants()) do
		if descendant:IsA("ModuleScript") and descendant.Name == moduleName then
			local current = descendant.Parent
			local matches = true
			for _, ancestorName in ipairs(ancestorNames) do
				if not current or current.Name ~= ancestorName then
					matches = false
					break
				end
				current = current.Parent
			end
			if matches then
				return descendant
			end
		end
	end
	error("Module not found: " .. moduleName)
end

local IntentSchema = require(findModule("IntentSchema", { "shared", "MainModule" }))

local function createMockEntity()
	return {
		ActionSeq = 0,
		RecentActions = {},
		UpdateEntity = function()
		end,
	}
end
--[=[
	@description Implements `Test_LastActionDelivery.Run`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function Test_LastActionDelivery.Run()
	local tester = TestBase.new("LastActionDelivery")

	tester:RunTest("AppendIntent increments ActionSeq and preserves delivery order", function(t)
		local entity = createMockEntity()

		IntentSchema.AppendIntent(entity, { Kind = "Animation", Payload = { Name = "SlashA" } })
		IntentSchema.AppendIntent(entity, { Kind = "Effect", Payload = { Name = "HitSpark" } })
		IntentSchema.AppendIntent(entity, { Kind = "Sound", Payload = { SoundId = "541909814" } })

		t:AssertEquals(entity.ActionSeq, 3, "ActionSeq should be 3 after three appends")
		t:AssertEquals(#entity.RecentActions, 3, "RecentActions should contain all three appended intents")
		t:Assert(entity.RecentActions[1].Seq < entity.RecentActions[2].Seq, "Seq values should increase monotonically")
		t:Assert(entity.RecentActions[2].Seq < entity.RecentActions[3].Seq, "Seq values should keep increasing")
		t:AssertEquals(entity.RecentActions[1].Kind, "Animation", "First appended intent should remain first")
		t:AssertEquals(entity.RecentActions[2].Kind, "Effect", "Second appended intent should remain second")
		t:AssertEquals(entity.RecentActions[3].Kind, "Sound", "Third appended intent should remain third")
	end)

	tester:RunTest("AppendIntent keeps only the last four actions", function(t)
		local entity = createMockEntity()
		local kinds = { "Animation", "Effect", "Sound", "HitReact", "Equip", "UnEquip" }

		for index, kind in ipairs(kinds) do
			IntentSchema.AppendIntent(entity, {
				Kind = kind,
				Payload = { Index = index },
			})
		end

		t:AssertEquals(entity.ActionSeq, 6, "ActionSeq should equal the total number of appended intents")
		t:AssertEquals(#entity.RecentActions, 4, "RecentActions should keep only the last four intents")
		t:AssertEquals(entity.RecentActions[1].Seq, 3, "Ring buffer should drop the oldest two intents")
		t:AssertEquals(entity.RecentActions[2].Seq, 4, "Ring buffer should keep seq 4")
		t:AssertEquals(entity.RecentActions[3].Seq, 5, "Ring buffer should keep seq 5")
		t:AssertEquals(entity.RecentActions[4].Seq, 6, "Ring buffer should keep seq 6")
		t:AssertEquals(entity.RecentActions[1].Kind, "Sound", "Oldest retained entry should be the third appended intent")
		t:AssertEquals(entity.RecentActions[4].Kind, "UnEquip", "Newest retained entry should be the last appended intent")
	end)

	return tester:PrintSummary()
end

return Test_LastActionDelivery
