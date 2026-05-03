--!strict

--[=[
	@description Provides targeting and damage-job orchestration helpers used by combat-oriented FSMs. Attack, hit-confirm, and ability systems depend on these helpers to find valid victim entities and to spawn DamageJob state machines with the expected context payload.
	Assumes the orchestrator can enumerate entities and create state machines, and that combat entities resolve to living characters through EntityHelpers.
]=]
local HttpService = game:GetService("HttpService")
local EntityHelpers = require(script.Parent.EntityHelpers)

local CombatHelpers = {}

--[=[
	@description Scans all known entities for living victims within a spherical radius around the supplied origin. The source entity is excluded, entities without a living humanoid or root part are ignored, and matches are returned sorted from nearest to farthest.
	@param orchestrator any -- FSM orchestrator that exposes GetAllEntities or GetEntities.
	@param sourceEntityId string -- Entity id that should be excluded from the victim list.
	@param origin Vector3 -- World-space center point of the scan.
	@param radius number -- Inclusive scan radius in studs.
	@return { any } -- Array of tables shaped like { Entity = entity, EntityId = string, Distance = number } sorted by ascending Distance.
	@reads orchestrator.GetAllEntities or orchestrator.GetEntities, each entity's character model, humanoid health, and root position
	@writes Local victim list only
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
	@description Filters scanVictims results down to targets positioned in front of the attacker's look vector. Targets exactly at the attacker's position are skipped because no forward direction can be derived from a zero-length offset.
	@param orchestrator any -- FSM orchestrator that exposes GetAllEntities or GetEntities.
	@param sourceEntityId string -- Entity id that should be excluded from the victim list.
	@param attackerRoot BasePart -- Attacker root part whose position and LookVector define the forward hemisphere.
	@param radius number -- Inclusive scan radius in studs.
	@return { any } -- Array of entity tables for victims located in front of attackerRoot.
	@reads orchestrator entity collection, attackerRoot.Position, attackerRoot.CFrame.LookVector, victim root positions
	@writes Local victim list only
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
	@description Creates and optionally starts a DamageJob state machine for a victim identified either by numeric user id or by a victim table containing UserId and EntityId fields. If no numeric victim user id can be resolved, no job is created.
	The spawned FSM is started in the Validate state when it exposes Start; startup errors are swallowed with pcall so attack flows can continue handling failure externally.
	@param orchestrator any -- FSM orchestrator expected to expose CreateStateMachine.
	@param attackerEntityId string -- Attacker character/entity id stored on the damage job context and state machine id.
	@param victim any -- Numeric user id or table containing at least UserId and optionally EntityId.
	@param attackName string -- Attack identifier forwarded to the DamageJob context.
	@param damage number? -- Optional base damage override forwarded to the DamageJob context.
	@param hitNonce string? -- Optional externally supplied nonce; a GUID is generated when omitted.
	@return any -- Newly created DamageJob state machine, or nil when victim does not resolve to a numeric user id.
	@reads victim.UserId, victim.EntityId, orchestrator.CreateStateMachine, sm.Start
	@writes Creates a DamageJob FSM instance and may transition it into the Validate state
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
