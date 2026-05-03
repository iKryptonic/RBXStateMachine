--!strict

--[=[
	@description Encapsulates crowd-control lock and flag mutation flows for FSMs that stun, knock, or otherwise restrict character actions. These helpers are usually used by crowd-control application, cleanup, and rollback states that must synchronize entity flags through UpdateEntity.
	Assumes character entities expose a boolean CCLock field and an UpdateEntity method that persists or replicates state changes.
]=]
local CrowdControlHelpers = {}

--[=[
	@description Attempts to acquire the entity's crowd-control lock so only one crowd-control workflow mutates flags at a time. If the persistence step fails, the lock is reverted before returning.
	@param charEntity any -- Character entity object with CCLock state and UpdateEntity persistence.
	@return boolean -- True when the lock is acquired and persisted, or false when the lock was already held or persistence failed.
	@return string? -- Failure reason when the lock cannot be acquired, otherwise nil.
	@reads charEntity.CCLock
	@writes charEntity.CCLock via UpdateEntity persistence
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
	@description Applies an arbitrary set of crowd-control related flags to the character entity and immediately persists the changes. Every key in the flags table is copied directly onto the entity, so callers should only pass validated field names and values.
	@param charEntity any -- Character entity object that will receive the provided flag values.
	@param flags { [string]: any } -- Map of entity field names to values that should be written.
	@return boolean -- True when UpdateEntity does not explicitly fail, or false when persistence returns false.
	@reads flags, charEntity.UpdateEntity
	@writes charEntity[flagName] for each provided flag via UpdateEntity persistence
]=]
function CrowdControlHelpers.applyFlags(charEntity: any, flags: { [string]: any }): boolean
	for flagName, flagValue in pairs(flags) do
		charEntity[flagName] = flagValue
	end
	return charEntity:UpdateEntity() ~= false
end

--[=[
	@description Releases the entity's crowd-control lock and persists the unlock operation. This is typically called by terminal or cleanup states after crowd-control work is complete.
	@param charEntity any -- Character entity object with CCLock state and UpdateEntity persistence.
	@return boolean -- True when UpdateEntity does not explicitly fail, or false when persistence returns false.
	@reads charEntity.UpdateEntity
	@writes charEntity.CCLock via UpdateEntity persistence
]=]
function CrowdControlHelpers.releaseCCLock(charEntity: any): boolean
	charEntity.CCLock = false
	return charEntity:UpdateEntity() ~= false
end

return CrowdControlHelpers
