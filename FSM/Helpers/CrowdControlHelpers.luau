--!strict

--[=[
	@description Encapsulates crowd-control lock and flag mutation flows for FSMs that stun, knock, or otherwise restrict character actions. These helpers are usually used by crowd-control application, cleanup, and rollback states that must synchronize entity flags through UpdateEntity.
	Assumes character entities expose a boolean CCLock field and an UpdateEntity method that persists or replicates state changes.
]=]
local CrowdControlHelpers = {}
--[=[
	@description Acquires the character's crowd-control lock before a stun/knock mutation is applied. The
	helper refuses to proceed when another CC flow already holds the lock, and it rolls the in-memory flag
	back if UpdateEntity fails so callers do not keep a stale lock locally.

	@param charEntity any -- Character entity whose CCLock flag should be claimed and persisted.
	@return (boolean, string?) -- True when the lock is successfully persisted; otherwise false plus the reason acquisition failed.
	@writes charEntity.CCLock
]=]

function CrowdControlHelpers.acquireCCLock(charEntity: any): (boolean, string?)
	if charEntity.CCLock then
		return false,"CCLock already held"
	end

	charEntity.CCLock = true
	if charEntity:UpdateEntity() == false then
		charEntity.CCLock = false
		return false,"Failed to acquire CCLock"
	end
	return true, nil
end
--[=[
	@description Applies a batch of crowd-control-related fields to the character entity and then persists
	the updated entity in one UpdateEntity call. This is typically used to flip flags such as IsStunned,
	IsKnocked, or movement permissions after a CC lock has already been acquired.

	@param charEntity any -- Character entity that should receive the provided flag mutations.
	@param flags { [string]: any } -- Map of field names to values that should be written onto the entity.
	@return boolean -- True when UpdateEntity succeeds, or false when persistence/replication fails.
	@writes charEntity[flagName] for each provided flag
]=]

function CrowdControlHelpers.applyFlags(charEntity: any, flags: { [string]: any }): boolean
	for flagName, flagValue in pairs(flags) do
		charEntity[flagName] = flagValue
	end
	return charEntity:UpdateEntity() ~= false
end
--[=[
	@description Releases the character's crowd-control lock and persists the unlocked state through
	UpdateEntity. Callers typically use this after CC flags have been applied or rolled back.

	@param charEntity any -- Character entity whose CCLock flag should be cleared.
	@return boolean -- True when the unlocked state is persisted, or false when UpdateEntity reports failure.
	@writes charEntity.CCLock
]=]

function CrowdControlHelpers.releaseCCLock(charEntity: any): boolean
	charEntity.CCLock = false
	return charEntity:UpdateEntity() ~= false
end

return CrowdControlHelpers
