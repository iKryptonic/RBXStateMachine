--!strict

local HttpService = game:GetService("HttpService")
local EntityHelpers = require(script.Parent.EntityHelpers)

local CombatHelpers = {}

function CombatHelpers.scanVictims(orchestrator: any, sourceEntityId: string, origin: Vector3, radius: number): { any }
	local victims = {}
	local getAllEntities = orchestrator and (orchestrator.GetAllEntities or orchestrator.GetEntities)
	local allEntities = if type(getAllEntities) == "function" then getAllEntities() else nil
	if not allEntities then
		return victims
	end

	for entityId, entity in pairs(allEntities) do
		if entityId == sourceEntityId then
			continue
		end
		local _, humanoid, root = EntityHelpers.getCharacterParts(entity)
		if not humanoid or humanoid.Health <= 0 or not root then
			continue
		end
		local distance = (root.Position - origin).Magnitude
		if distance <= radius then
			table.insert(victims, { Entity = entity, EntityId = entityId, Distance = distance })
		end
	end

	table.sort(victims, function(a, b)
		return a.Distance < b.Distance
	end)
	return victims
end

function CombatHelpers.scanForwardVictims(orchestrator: any, sourceEntityId: string, attackerRoot: BasePart, radius: number): { any }
	local victims = {}
	for _, entry in ipairs(CombatHelpers.scanVictims(orchestrator, sourceEntityId, attackerRoot.Position, radius)) do
		local _, _, root = EntityHelpers.getCharacterParts(entry.Entity)
		if root then
			local offset = root.Position - attackerRoot.Position
			if offset.Magnitude > 0 and attackerRoot.CFrame.LookVector:Dot(offset.Unit) > 0 then
				table.insert(victims, entry.Entity)
			end
		end
	end
	return victims
end

function CombatHelpers.createDamageJob(
	orchestrator: any,
	attackerEntityId: string,
	victim: any,
	attackName: string,
	damage: number?,
	hitNonce: string?
)
	local victimUserId = if typeof(victim) == "number" then victim else victim and victim.UserId
	if typeof(victimUserId) ~= "number" then
		return nil
	end

	local nonce = hitNonce or HttpService:GenerateGUID(false)
	local sm = orchestrator.CreateStateMachine({
		StateMachineClass = "DamageJob",
		StateMachineId = string.format("Damage_%s_%s_%s", attackerEntityId, tostring(victimUserId), nonce),
		Context = {
			AttackerCharEntityId = attackerEntityId,
			AttackerEntityId = attackerEntityId,
			VictimUserId = victimUserId,
			VictimEntityId = if typeof(victim) == "table" then victim.EntityId else nil,
			AttackName = attackName,
			BaseDamage = damage,
			HitNonce = nonce,
		},
	})
	if sm and type(sm.Start) == "function" then
		pcall(function()
			sm:Start({ State = "Validate" })
		end)
	end
	return sm
end

return CombatHelpers
