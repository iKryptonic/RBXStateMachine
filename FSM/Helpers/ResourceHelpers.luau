--!strict

local ResourceHelpers = {}

local function deductResource(charEntity: any, field: string, cost: number): boolean
	local current = tonumber(charEntity[field]) or 0
	if current < cost then
		return false
	end
	charEntity[field] = current - cost
	return true
end

function ResourceHelpers.deductStamina(charEntity: any, cost: number): boolean
	return deductResource(charEntity, "Stamina", cost)
end

function ResourceHelpers.deductMana(charEntity: any, cost: number): boolean
	return deductResource(charEntity, "Mana", cost)
end

function ResourceHelpers.restoreResource(charEntity: any, field: string, amount: number, maxField: string): number
	local current = tonumber(charEntity[field]) or 0
	local max = tonumber(charEntity[maxField]) or 0
	local newVal = math.min(current + amount, max)
	charEntity[field] = newVal
	return newVal
end

function ResourceHelpers.clampResources(charEntity: any)
	charEntity.Health = math.clamp(tonumber(charEntity.Health) or 0, 0, tonumber(charEntity.MaxHealth) or 100)
	charEntity.Stamina = math.clamp(tonumber(charEntity.Stamina) or 0, 0, tonumber(charEntity.MaxStamina) or 100)
	charEntity.Mana = math.clamp(tonumber(charEntity.Mana) or 0, 0, tonumber(charEntity.MaxMana) or 50)
end

return ResourceHelpers
