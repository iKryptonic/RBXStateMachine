--!strict

local CrowdControlHelpers = {}

function CrowdControlHelpers.acquireCCLock(charEntity: any): (boolean, string?)
	if charEntity.CCLock then
		return false, "CCLock already held"
	end

	charEntity.CCLock = true
	if charEntity:UpdateEntity() == false then
		charEntity.CCLock = false
		return false, "Failed to acquire CCLock"
	end
	return true, nil
end

function CrowdControlHelpers.applyFlags(charEntity: any, flags: { [string]: any }): boolean
	for flagName, flagValue in pairs(flags) do
		charEntity[flagName] = flagValue
	end
	return charEntity:UpdateEntity() ~= false
end

function CrowdControlHelpers.releaseCCLock(charEntity: any): boolean
	charEntity.CCLock = false
	return charEntity:UpdateEntity() ~= false
end

return CrowdControlHelpers
