--!strict

--[=[
	@description Provides targeting and damage-job orchestration helpers used by combat-oriented FSMs. Attack, hit-confirm, and ability systems depend on these helpers to find valid victim entities and to spawn DamageJob state machines with the expected context payload.
	Assumes the orchestrator can enumerate entities and create state machines, and that combat entities resolve to living characters through EntityHelpers.
]=]
local HttpService = game:GetService("HttpService")
local EntityHelpers = require(script.Parent.EntityHelpers)

local CombatHelpers = {}
--[=[
	@description Implements `CombatHelpers.scanVictims`.
	@param orchestrator any -- `orchestrator` input parameter.
	@param sourceEntityId string -- `sourceEntityId` input parameter.
	@param origin Vector3 -- `origin` input parameter.
	@param radius number -- `radius` input parameter.
	@return { any } -- Return value produced by the implementation, if any.
]=]

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
--[=[
	@description Implements `CombatHelpers.scanForwardVictims`.
	@param orchestrator any -- `orchestrator` input parameter.
	@param sourceEntityId string -- `sourceEntityId` input parameter.
	@param attackerRoot BasePart -- `attackerRoot` input parameter.
	@param radius number -- `radius` input parameter.
	@return { any } -- Return value produced by the implementation, if any.
]=]

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
--[=[
	@description Implements `CombatHelpers.createDamageJob`.
	@param orchestrator any -- `orchestrator` input parameter.
	@param attackerEntityId string -- `attackerEntityId` input parameter.
	@param victim any -- `victim` input parameter.
	@param attackName string -- `attackName` input parameter.
	@param damage number? -- `damage` input parameter.
	@param hitNonce string? -- `hitNonce` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

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
