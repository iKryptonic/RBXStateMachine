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
	@description Attempts to spend stamina from a character entity by delegating to deductResource. The
	operation succeeds only when the entity's current Stamina value is at least the requested cost.

	@param charEntity any -- Character entity whose Stamina field should be reduced.
	@param cost number -- Amount of stamina to consume.
	@return boolean -- True when stamina was deducted, or false when the entity does not have enough stamina.
	@writes charEntity.Stamina
]=]

function ResourceHelpers.deductStamina(charEntity: any, cost: number): boolean
	return deductResource(charEntity, "Stamina", cost)
end
--[=[
	@description Attempts to spend mana from a character entity by delegating to deductResource. The helper
	refuses to overdraw the Mana field and leaves it unchanged when the requested cost cannot be paid.

	@param charEntity any -- Character entity whose Mana field should be reduced.
	@param cost number -- Amount of mana to consume.
	@return boolean -- True when mana was deducted, or false when available mana is below cost.
	@writes charEntity.Mana
]=]

function ResourceHelpers.deductMana(charEntity: any, cost: number): boolean
	return deductResource(charEntity, "Mana", cost)
end
--[=[
	@description Restores a numeric resource toward its configured maximum. Current and max values are read
	from the provided fields, coerced through tonumber, increased by the requested amount, and then capped
	so the resource never exceeds maxField.

	@param charEntity any -- Character entity whose resource field should be increased.
	@param field string -- Field name holding the current resource value to restore.
	@param amount number -- Amount to add before max clamping.
	@param maxField string -- Field name holding the maximum allowed value for the resource.
	@return number -- Final clamped value written back to charEntity[field].
	@writes charEntity[field]
]=]

function ResourceHelpers.restoreResource(charEntity: any, field: string, amount: number, maxField: string): number
	local current = tonumber(charEntity[field]) or 0
	local max = tonumber(charEntity[maxField]) or 0
	local newVal = math.min(current + amount, max)
	charEntity[field] = newVal
	return newVal
end
--[=[
	@description Clamps the entity's Health, Stamina, and Mana into safe runtime ranges using their matching
	max fields. Missing or non-numeric values fall back to default caps (100 health, 100 stamina, 50 mana)
	so malformed entity data is normalized instead of propagating impossible resource values.

	@param charEntity any -- Character entity whose primary resources should be normalized in place.
	@return nil
	@writes charEntity.Health, charEntity.Stamina, charEntity.Mana
]=]

function ResourceHelpers.clampResources(charEntity: any)
	charEntity.Health = math.clamp(tonumber(charEntity.Health) or 0, 0, tonumber(charEntity.MaxHealth) or 100)
	charEntity.Stamina = math.clamp(tonumber(charEntity.Stamina) or 0, 0, tonumber(charEntity.MaxStamina) or 100)
	charEntity.Mana = math.clamp(tonumber(charEntity.Mana) or 0, 0, tonumber(charEntity.MaxMana) or 50)
end

return ResourceHelpers
