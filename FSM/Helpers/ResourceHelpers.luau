--!strict

--[=[
	@description Provides small resource accounting utilities for FSMs that spend or restore health-adjacent entity resources. These helpers are typically used by combat, ability, and movement state machines before committing transitions that depend on stamina or mana.
	Assumes character entities expose numeric Health, MaxHealth, Stamina, MaxStamina, Mana, and MaxMana fields or values coercible with tonumber.
]=]
local ResourceHelpers = {}

--[=[
	@description Deducts a numeric resource field from a character entity when enough value is available. Missing or non-numeric fields are treated as zero, so insufficient data fails the deduction instead of throwing.
	@param charEntity any -- Character entity table whose resource field will be reduced.
	@param field string -- Entity field name containing the current resource value.
	@param cost number -- Amount to subtract from the resource.
	@return boolean -- True when the deduction succeeds, or false when the current value is below cost.
	@reads charEntity[field]
	@writes charEntity[field]
]=]
local function deductResource(charEntity: any, field: string, cost: number): boolean
	local current = tonumber(charEntity[field]) or 0
	if current < cost then
		return false
	end
	charEntity[field] = current - cost
	return true
end
--[=[
	@description Implements `ResourceHelpers.deductStamina`.
	@param charEntity any -- `charEntity` input parameter.
	@param cost number -- `cost` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function ResourceHelpers.deductStamina(charEntity: any, cost: number): boolean
	return deductResource(charEntity, "Stamina", cost)
end
--[=[
	@description Implements `ResourceHelpers.deductMana`.
	@param charEntity any -- `charEntity` input parameter.
	@param cost number -- `cost` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function ResourceHelpers.deductMana(charEntity: any, cost: number): boolean
	return deductResource(charEntity, "Mana", cost)
end
--[=[
	@description Implements `ResourceHelpers.restoreResource`.
	@param charEntity any -- `charEntity` input parameter.
	@param field string -- `field` input parameter.
	@param amount number -- `amount` input parameter.
	@param maxField string -- `maxField` input parameter.
	@return number -- Return value produced by the implementation, if any.
]=]

function ResourceHelpers.restoreResource(charEntity: any, field: string, amount: number, maxField: string): number
	local current = tonumber(charEntity[field]) or 0
	local max = tonumber(charEntity[maxField]) or 0
	local newVal = math.min(current + amount, max)
	charEntity[field] = newVal
	return newVal
end
--[=[
	@description Implements `ResourceHelpers.clampResources`.
	@param charEntity any -- `charEntity` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ResourceHelpers.clampResources(charEntity: any)
	charEntity.Health = math.clamp(tonumber(charEntity.Health) or 0, 0, tonumber(charEntity.MaxHealth) or 100)
	charEntity.Stamina = math.clamp(tonumber(charEntity.Stamina) or 0, 0, tonumber(charEntity.MaxStamina) or 100)
	charEntity.Mana = math.clamp(tonumber(charEntity.Mana) or 0, 0, tonumber(charEntity.MaxMana) or 50)
end

return ResourceHelpers
