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
	@description Attempts to spend stamina from the character entity. This is a thin wrapper over deductResource for callers that want a stamina-specific API.
	@param charEntity any -- Character entity table that owns the Stamina field.
	@param cost number -- Stamina cost to spend.
	@return boolean -- True when Stamina was reduced, or false when available stamina is lower than cost.
	@reads charEntity.Stamina
	@writes charEntity.Stamina
]=]
function ResourceHelpers.deductStamina(charEntity: any, cost: number): boolean
	return deductResource(charEntity, "Stamina", cost)
end

--[=[
	@description Attempts to spend mana from the character entity. This is a thin wrapper over deductResource for callers that want a mana-specific API.
	@param charEntity any -- Character entity table that owns the Mana field.
	@param cost number -- Mana cost to spend.
	@return boolean -- True when Mana was reduced, or false when available mana is lower than cost.
	@reads charEntity.Mana
	@writes charEntity.Mana
]=]
function ResourceHelpers.deductMana(charEntity: any, cost: number): boolean
	return deductResource(charEntity, "Mana", cost)
end

--[=[
	@description Restores a resource field by a positive amount and clamps the result to the entity's configured maximum field. Missing or invalid current and max values are treated as zero.
	@param charEntity any -- Character entity table whose resource field will be restored.
	@param field string -- Entity field name containing the current resource value.
	@param amount number -- Amount to add before clamping to the maximum.
	@param maxField string -- Entity field name containing the resource cap.
	@return number -- New clamped resource value written back to the entity.
	@reads charEntity[field], charEntity[maxField]
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
	@description Clamps Health, Stamina, and Mana fields into their configured min/max ranges using fallback maxima when max fields are missing. This is typically called after stat recalculation, damage, or restoration to keep entity state internally consistent.
	@param charEntity any -- Character entity table whose Health, Stamina, and Mana values should be normalized.
	@return nil -- No explicit return value.
	@reads charEntity.Health, charEntity.MaxHealth, charEntity.Stamina, charEntity.MaxStamina, charEntity.Mana, charEntity.MaxMana
	@writes charEntity.Health, charEntity.Stamina, charEntity.Mana
]=]
function ResourceHelpers.clampResources(charEntity: any)
	charEntity.Health = math.clamp(tonumber(charEntity.Health) or 0, 0, tonumber(charEntity.MaxHealth) or 100)
	charEntity.Stamina = math.clamp(tonumber(charEntity.Stamina) or 0, 0, tonumber(charEntity.MaxStamina) or 100)
	charEntity.Mana = math.clamp(tonumber(charEntity.Mana) or 0, 0, tonumber(charEntity.MaxMana) or 50)
end

return ResourceHelpers
