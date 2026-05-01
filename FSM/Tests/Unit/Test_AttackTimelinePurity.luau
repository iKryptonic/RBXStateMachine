--!nocheck
-- @Name Test_AttackTimelinePurity
-- @Author Copilot
-- @Description Unit tests ensuring combo keyframe arrays remain pure data.

local TestBase = require((script.Parent:FindFirstChild("TestBase") or script.Parent.Parent:FindFirstChild("TestBase")) :: any)

local Test_AttackTimelinePurity = {}

local function isAllowedPrimitive(value)
	local valueType = typeof(value)
	return valueType == "string" or valueType == "number"
end

local function timelineIsPure(combo)
	if typeof(combo) ~= "table" then
		return false
	end
	if typeof(combo.t) ~= "number" or combo.t <= 0 then
		return false
	end

	for _, entry in ipairs(combo) do
		if typeof(entry) ~= "table" then
			return false
		end
		for _, value in ipairs(entry) do
			if not isAllowedPrimitive(value) then
				return false
			end
		end
	end

	return true
end

function Test_AttackTimelinePurity.Run()
	local tester = TestBase.new("AttackTimelinePurity")

	tester:RunTest("Sample combo keyframe arrays are pure data", function(t)
		local slashCombo = {
			t = 24,
			{ "Sound", 1, "541909814", 0.5, 1 },
			{ "Effect", 8, "HitSpark", 1 },
			{ "Damage", 12, "1248511833", 0.5, 1 },
		}
		local slamCombo = {
			t = 36,
			{ "Animation", 1, "GroundSlam" },
			{ "Effect", 18, "GroundSlam", 1 },
			{ "Damage", 24, "541909814", 0.75, 1 },
		}

		t:Assert(timelineIsPure(slashCombo), "Slash combo timeline should contain only primitive keyframe data")
		t:Assert(timelineIsPure(slamCombo), "Slam combo timeline should contain only primitive keyframe data")
		t:Assert(slashCombo.t > 0, "Slash combo should define a positive total frame count")
		t:Assert(slamCombo.t > 0, "Slam combo should define a positive total frame count")
	end)

	tester:RunTest("Validator rejects functions, instances, threads, and invalid totals", function(t)
		local invalidFunctionCombo = {
			t = 12,
			{ "Damage", 6, function() end },
		}
		local invalidInstanceCombo = {
			t = 12,
			{ "Effect", 4, Instance.new("Folder") },
		}
		local invalidThreadCombo = {
			t = 12,
			{ "Sound", 2, coroutine.create(function() end) },
		}
		local invalidTotalFramesCombo = {
			t = 0,
			{ "Damage", 2, "541909814" },
		}

		t:Assert(not timelineIsPure(invalidFunctionCombo), "Functions should not appear in combo keyframe arrays")
		t:Assert(not timelineIsPure(invalidInstanceCombo), "Instances should not appear in combo keyframe arrays")
		t:Assert(not timelineIsPure(invalidThreadCombo), "Threads should not appear in combo keyframe arrays")
		t:Assert(not timelineIsPure(invalidTotalFramesCombo), "Timeline total frame count should be a positive number")

		invalidInstanceCombo[1][3]:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_AttackTimelinePurity
