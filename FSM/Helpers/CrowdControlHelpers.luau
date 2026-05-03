--!strict

--[=[
	@description Encapsulates crowd-control lock and flag mutation flows for FSMs that stun, knock, or otherwise restrict character actions. These helpers are usually used by crowd-control application, cleanup, and rollback states that must synchronize entity flags through UpdateEntity.
	Assumes character entities expose a boolean CCLock field and an UpdateEntity method that persists or replicates state changes.
]=]
local CrowdControlHelpers = {}
--[=[
	@description Implements `CrowdControlHelpers.acquireCCLock`.
	@param charEntity any -- `charEntity` input parameter.
	@return (boolean, string?) -- Return value produced by the implementation, if any.
]=]

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
--[=[
	@description Implements `CrowdControlHelpers.applyFlags`.
	@param charEntity any -- `charEntity` input parameter.
	@param flags { [string]: any } -- `flags` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function CrowdControlHelpers.applyFlags(charEntity: any, flags: { [string]: any }): boolean
	for flagName, flagValue in pairs(flags) do
		charEntity[flagName] = flagValue
	end
	return charEntity:UpdateEntity() ~= false
end
--[=[
	@description Implements `CrowdControlHelpers.releaseCCLock`.
	@param charEntity any -- `charEntity` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function CrowdControlHelpers.releaseCCLock(charEntity: any): boolean
	charEntity.CCLock = false
	return charEntity:UpdateEntity() ~= false
end

return CrowdControlHelpers
