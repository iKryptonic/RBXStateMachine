--!strict

--[=[
	@description Provides targeting and damage-job orchestration helpers used by combat-oriented FSMs. Attack, hit-confirm, and ability systems depend on these helpers to find valid victim entities and to spawn DamageJob state machines with the expected context payload.
	Assumes the orchestrator can enumerate entities and create state machines, and that combat entities resolve to living characters through EntityHelpers.
]=]
local HttpService = game:GetService("HttpService")
local EntityHelpers = require(script.Parent.EntityHelpers)

local CombatHelpers = {}
--[=[
	@description Finds all living character entities within a spherical radius from an origin
	point, excluding the source entity. Returns entries sorted by distance (closest first).
	Each entry contains { Entity, EntityId, Distance }.

	@param orchestrator any — Orchestrator instance (must expose GetAllEntities or GetEntities)
	@param sourceEntityId string — Entity ID of the attacker (excluded from results)
	@param origin Vector3 — Center point for the radius scan
	@param radius number — Maximum distance in studs to include targets
	@return { { Entity: any, EntityId: string, Distance: number } } — Sorted victim list
	@reads All registered entities via orchestrator, each entity's character/humanoid/root
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
	@description Filters scanVictims results to only include targets in front of the attacker.
	Uses the attacker's LookVector dot product with the direction to each target —
	positive dot means the target is in the forward hemisphere.

	@param orchestrator any — Orchestrator instance
	@param sourceEntityId string — Attacker entity ID (excluded from results)
	@param attackerRoot BasePart — The attacker's HumanoidRootPart (provides position + facing)
	@param radius number — Maximum distance in studs
	@return { any } — Array of Entity tables (not wrapped in { Entity, Distance } like scanVictims)
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
	@description Creates and starts a DamageJob state machine for a confirmed hit. The helper accepts
	either a victim entity table or a raw user id, derives a stable Damage_<attacker>_<victim>_<nonce>
	identifier, and seeds the job context with attacker ids, victim ids, attack metadata, base damage,
	and a hit nonce for deduplication.

	@param orchestrator any -- Orchestrator that can create state machines through CreateStateMachine.
	@param attackerEntityId string -- Character/entity id credited as the attack source.
	@param victim any -- Victim entity table or numeric user id used to identify who should receive damage.
	@param attackName string -- Attack or ability name recorded in the DamageJob context.
	@param damage number? -- Optional base damage forwarded to the job for downstream calculations.
	@param hitNonce string? -- Optional unique hit id; when omitted a GUID is generated automatically.
	@return any -- Started DamageJob instance, or nil when the victim cannot be resolved to a numeric user id.
	@writes orchestrator state-machine registry via CreateStateMachine
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
