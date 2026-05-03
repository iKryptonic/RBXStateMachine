--!nocheck
-- @Name Test_DamageJob_HitNonceDedup
-- @Author iKrypto
-- @Description Unit tests for the hit nonce deduplication concept used by DamageJob.

local TestBase = require((script.Parent:FindFirstChild("TestBase") or script.Parent.Parent:FindFirstChild("TestBase")) :: any)

local Test_DamageJob_HitNonceDedup = {}

local NONCE_EXPIRY = 3

local function cleanupExpiredNonces(processedNonces, now)
	for attackerUserId, nonceMap in pairs(processedNonces) do
		for nonce, expiry in pairs(nonceMap) do
			if now >= expiry then
				nonceMap[nonce] = nil
			end
		end
		if next(nonceMap) == nil then
			processedNonces[attackerUserId] = nil
		end
	end
end

local function rememberNonce(processedNonces, attackerUserId, nonce, now)
	cleanupExpiredNonces(processedNonces, now)
	local nonceMap = processedNonces[attackerUserId]
	if not nonceMap then
		nonceMap = {}
		processedNonces[attackerUserId] = nonceMap
	end
	if nonceMap[nonce] ~= nil then
		return false
	end
	nonceMap[nonce] = now + NONCE_EXPIRY
	return true
end

function Test_DamageJob_HitNonceDedup.Run()
	local tester = TestBase.new("DamageJob_HitNonceDedup")

	tester:RunTest("First nonce insert succeeds and duplicate is rejected", function(t)
		local processedNonces = {}
		local inserted = rememberNonce(processedNonces, 101, "swing:nonce:1", 10)
		t:Assert(inserted, "First nonce insert should succeed")
		t:Assert(processedNonces[101] ~= nil and processedNonces[101]["swing:nonce:1"] ~= nil, "Inserted nonce should be stored")

		local duplicate = rememberNonce(processedNonces, 101, "swing:nonce:1", 10.5)
		t:Assert(not duplicate, "Duplicate nonce should be rejected before expiry")

		local newNonce = rememberNonce(processedNonces, 101, "swing:nonce:2", 10.5)
		t:Assert(newNonce, "Different nonce should be accepted for the same attacker")
	end)

	tester:RunTest("Expired nonces are cleaned up after the expiry window", function(t)
		local processedNonces = {}
		rememberNonce(processedNonces, 202, "hit:1", 0)
		rememberNonce(processedNonces, 202, "hit:2", 1)

		cleanupExpiredNonces(processedNonces, 2.5)
		t:Assert(processedNonces[202] ~= nil and processedNonces[202]["hit:1"] ~= nil, "Nonce should still exist before expiry")

		cleanupExpiredNonces(processedNonces, 3.01)
		t:Assert(processedNonces[202] ~= nil and processedNonces[202]["hit:1"] == nil, "Expired nonce should be removed once its window passes")
		t:Assert(processedNonces[202]["hit:2"] ~= nil, "Later nonce should remain until its own expiry")

		cleanupExpiredNonces(processedNonces, 4.01)
		t:AssertEquals(processedNonces[202], nil, "Attacker nonce bucket should be removed when all nonces expire")
	end)

	return tester:PrintSummary()
end

return Test_DamageJob_HitNonceDedup
