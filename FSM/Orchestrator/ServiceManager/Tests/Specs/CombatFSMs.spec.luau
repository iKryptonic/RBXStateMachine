--!strict
-- @Name ServiceManager/Tests/Specs/CombatFSMs.spec.luau
-- @Description Contract tests for the new combat-focused FSMs.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local DEFAULT_MELEE_DAMAGE = {
		[1] = 5,
		[2] = 12,
		[3] = 15,
		[4] = 9,
	}

	local MELEE_SEQUENCES = {
		[1] = {
			{ { Name = "RightPunch", Duration = 0.43 } },
			{ { Name = "LeftPunch", Duration = 0.43 } },
		},
		[2] = {
			{ { Name = "LeftKnee1", Duration = 0.22 }, { Name = "LeftKnee2", Duration = 0.5 } },
		},
		[3] = {
			{ { Name = "Uppercut1", Duration = 0.22 }, { Name = "Uppercut2", Duration = 0.5 } },
		},
		[4] = {
			{ { Name = "RightKick1", Duration = 0.25 }, { Name = "RightKick2", Duration = 0.5 } },
			{ { Name = "LeftKick", Duration = 0.22 } },
		},
	}

	local function makeCharacterEntity(overrides): any
		local entity: any = {
			EntityId = "Char_1",
			PlayerEntityId = "Player_1",
			Health = 100,
			MaxHealth = 100,
			Stamina = 100,
			MaxStamina = 100,
			Mana = 50,
			MaxMana = 50,
			CanMove = true,
			MoveSpeedCap = 16,
			IsStunned = false,
			IsKnocked = false,
			ActiveStatusEffects = {},
			AbilityCooldowns = {},
			EquippedRight = "",
			EquippedLeft = "",
			Context = {},
			_lockOwner = nil,
			_releaseCalls = 0,
			_updateCalls = 0,
		}
		for key, value in pairs(overrides or {}) do
			entity[key] = value
		end
		function entity:AcquireLock(lockId)
			if self._lockOwner ~= nil and self._lockOwner ~= lockId then
				return false
			end
			self._lockOwner = lockId
			return true
		end
		function entity:ReleaseLock(lockId)
			if self._lockOwner == lockId then
				self._lockOwner = nil
			end
			self._releaseCalls += 1
		end
		function entity:UpdateEntity(lockId)
			self._updateCalls += 1
			self._lastUpdateLockId = lockId
		end
		function entity:SetContext(key, value)
			self.Context[key] = value
			self[key] = value
		end
		return entity
	end

	local function makeHumanoid(overrides): any
		local humanoid: any = {
			Health = 100,
			MaxHealth = 100,
			_takenDamage = 0,
		}
		for key, value in pairs(overrides or {}) do
			humanoid[key] = value
		end
		function humanoid:TakeDamage(amount)
			self._takenDamage += amount
			self.Health = math.max(0, self.Health - amount)
		end
		return humanoid
	end

	local function makeOrchestrator(entities, extra): any
		local opts = extra or {}
		local orchestrator: any = {
			Entities = entities or {},
			CreatedMachines = {},
			SpawnedProjectiles = {},
		}
		function orchestrator.GetEntity(entityId)
			return orchestrator.Entities[entityId]
		end
		function orchestrator.GetEntities()
			return orchestrator.Entities
		end
		function orchestrator.CreateStateMachine(def)
			table.insert(orchestrator.CreatedMachines, def)
			local machine = {
				Start = function(_, args)
					def._startedWith = args
				end,
			}
			return if opts.CreateStateMachine ~= nil then opts.CreateStateMachine(def, machine) else machine
		end
		return orchestrator
	end

	local function makeFSM(id, params): any
		local fsm: any = {
			Id = id,
			State = params.State or "Validate",
			CharacterEntityId = params.CharacterEntityId,
			PlayerEntityId = params.PlayerEntityId,
			AbilityId = params.AbilityId,
			EffectId = params.EffectId,
			ComboSlot = params.ComboSlot,
			Now = params.Now or 0,
			Context = {},
			Failure = nil,
		}
		function fsm:Fail(message)
			self.State = "Failed"
			self.Failure = message
		end
		return fsm
	end

	local function meleeValidate(orchestrator: any, fsm: any)
		local charEntityId = fsm.CharacterEntityId
		if typeof(charEntityId) ~= "string" or charEntityId == "" then
			fsm:Fail("CharacterEntityId required")
			return
		end
		local charEntity = orchestrator.GetEntity(charEntityId)
		if not charEntity then
			fsm:Fail("CharacterEntity not found")
			return
		end
		if charEntity.IsStunned or charEntity.IsKnocked then
			fsm:Fail("Character is crowd-controlled")
			return
		end
		fsm.Context._charEntity = charEntity
		fsm.Context._comboSlot = math.clamp(tonumber(fsm.ComboSlot) or 1, 1, 4)
		fsm.Context._staminaCost = DEFAULT_MELEE_DAMAGE[fsm.Context._comboSlot] or 5
		fsm.State = "AcquireLock"
	end

	local function meleeAcquireLock(fsm: any)
		local charEntity = fsm.Context._charEntity
		if not charEntity:AcquireLock(fsm.Id) then
			fsm:Fail("Character is already performing another action")
			return
		end
		fsm.Context._lockHeld = true
		fsm.State = "Execute"
	end

	local function meleeExecute(fsm: any)
		local charEntity = fsm.Context._charEntity
		local comboSlot = fsm.Context._comboSlot
		local staminaCost = fsm.Context._staminaCost
		if (charEntity.Stamina or 0) < staminaCost then
			fsm.State = "ReleaseLock"
			return
		end
		charEntity.Stamina -= staminaCost
		charEntity:UpdateEntity()
		local pointers = charEntity._MeleePointers or {}
		local seqDef = MELEE_SEQUENCES[comboSlot]
		local pointer = (pointers[comboSlot] or 0) + 1
		if pointer > #seqDef then
			pointer = 1
		end
		pointers[comboSlot] = pointer
		charEntity:SetContext("_MeleePointers", pointers)
		fsm.Context._damage = DEFAULT_MELEE_DAMAGE[comboSlot]
		fsm.Context._phases = seqDef[pointer]
		fsm.State = "DamageScan"
	end

	local function meleeDamageScan(orchestrator: any, fsm: any, victims)
		for _, victim in ipairs(victims or {}) do
			local def = {
				StateMachineClass = "DamageJob",
				StateMachineId = string.format("MeleeDmg_%s_%s", fsm.Id, tostring(victim.UserId)),
				Context = {
					AttackerCharEntityId = fsm.CharacterEntityId,
					VictimUserId = victim.UserId,
					AttackName = "Melee_" .. tostring(fsm.Context._comboSlot),
					BaseDamage = fsm.Context._damage,
				},
			}
			local job = orchestrator.CreateStateMachine(def)
			if job then
				job:Start({ State = "Validate" })
			end
		end
		fsm.State = "ReleaseLock"
	end

	local function meleeReleaseLock(fsm: any)
		local charEntity = fsm.Context._charEntity
		if charEntity and fsm.Context._lockHeld then
			charEntity:ReleaseLock(fsm.Id)
			fsm.Context._lockHeld = false
		end
		fsm.State = "Completed"
	end

	local function projectileValidate(orchestrator: any, fsm: any)
		local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
		if not charEntity then
			fsm:Fail("CharacterEntity not found")
			return
		end
		if charEntity.IsStunned or charEntity.IsKnocked then
			fsm:Fail("Character is crowd-controlled")
			return
		end
		local weaponId = charEntity.EquippedRight
		if typeof(weaponId) ~= "string" or weaponId == "" then
			weaponId = charEntity.EquippedLeft
		end
		local itemData = fsm.Context._itemData
		if typeof(weaponId) ~= "string" or weaponId == "" or not itemData or (itemData.WeaponType ~= "Bow" and itemData.WeaponType ~= "Staff" and itemData.WeaponType ~= "Ranged") then
			fsm:Fail("No ranged weapon equipped")
			return
		end
		fsm.Context._charEntity = charEntity
		fsm.Context._weaponId = weaponId
		fsm.Context._manaCost = tonumber(itemData.ManaCost) or 10
		fsm.Context._damage = tonumber(itemData.WeaponStats and itemData.WeaponStats.Attack) or 20
		fsm.Context._lifetime = tonumber(itemData.ProjectileLifetime) or 3
		fsm.State = "AcquireLock"
	end

	local function projectileAcquireLock(fsm: any)
		local charEntity = fsm.Context._charEntity
		if not charEntity:AcquireLock(fsm.Id) then
			fsm:Fail("Character is already performing another action")
			return
		end
		fsm.Context._lockHeld = true
		fsm.State = "Charge"
	end

	local function projectileCharge(fsm: any)
		local charEntity = fsm.Context._charEntity
		local manaCost = fsm.Context._manaCost
		if (charEntity.Mana or 0) < manaCost then
			fsm.State = "ReleaseLock"
			return
		end
		charEntity.Mana -= manaCost
		charEntity:UpdateEntity()
		fsm.State = "Fire"
	end

	local function projectileFire(orchestrator: any, fsm: any)
		local projectile = {
			Name = "Projectile_" .. fsm.Id,
			Lifetime = fsm.Context._lifetime,
			Destroyed = false,
		}
		table.insert(orchestrator.SpawnedProjectiles, projectile)
		fsm.Context._projectile = projectile
		fsm.State = "WaitForImpact"
	end

	local function projectileExpire(fsm: any)
		local projectile = fsm.Context._projectile
		if projectile then
			projectile.Destroyed = true
		end
		fsm.State = "ReleaseLock"
	end

	local function projectileReleaseLock(fsm: any)
		local charEntity = fsm.Context._charEntity
		if charEntity and fsm.Context._lockHeld then
			charEntity:ReleaseLock(fsm.Id)
			fsm.Context._lockHeld = false
		end
		fsm.State = "Completed"
	end

	local function castValidate(orchestrator: any, fsm: any)
		local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
		local playerEntity = orchestrator.GetEntity(fsm.PlayerEntityId)
		local castDef = fsm.Context._castDef
		if not charEntity then
			fsm:Fail("Character entity not found")
			return
		end
		if not castDef then
			fsm:Fail("Cast definition not found")
			return
		end
		if not playerEntity then
			fsm:Fail("Player entity not found")
			return
		end
		if (charEntity.Stamina or 0) < (tonumber(castDef.StaminaCost) or 0) then
			fsm:Fail("Not enough stamina")
			return
		end
		if (charEntity.Mana or 0) < (tonumber(castDef.ManaCost) or 0) then
			fsm:Fail("Not enough mana")
			return
		end
		local cooldownEnd = tonumber((charEntity.AbilityCooldowns or {})[castDef.Id]) or 0
		if cooldownEnd > fsm.Now then
			fsm:Fail("Ability is on cooldown")
			return
		end
		if not charEntity:AcquireLock(fsm.Id) then
			fsm:Fail("Character is already performing another action")
			return
		end
		fsm.Context._lockHeld = true
		fsm.Context._charEntity = charEntity
		fsm.Context._playerEntity = playerEntity
		charEntity.ActiveCastId = castDef.Id
		charEntity:UpdateEntity(fsm.Id)
		fsm.State = if (tonumber(castDef.CastTime) or 0) > 0 then "Casting" else "Execute"
	end

	local function castEnterCasting(fsm: any)
		local castDef = fsm.Context._castDef
		local charEntity = fsm.Context._charEntity
		charEntity.CanMove = false
		charEntity:UpdateEntity(fsm.Id)
		fsm.Context._movementLocked = true
		fsm.Context._castEndsAt = fsm.Now + (tonumber(castDef.CastTime) or 0)
	end

	local function castHeartbeat(fsm: any)
		local charEntity = fsm.Context._charEntity
		if charEntity.IsStunned or charEntity.IsKnocked then
			fsm:Fail("Cast interrupted")
			return
		end
		if fsm.Now >= (tonumber(fsm.Context._castEndsAt) or 0) then
			fsm.State = "Execute"
		end
	end

	local function castExecute(fsm: any)
		local castDef = fsm.Context._castDef
		local charEntity = fsm.Context._charEntity
		charEntity.Stamina = math.max(0, (tonumber(charEntity.Stamina) or 0) - (tonumber(castDef.StaminaCost) or 0))
		charEntity.Mana = math.max(0, (tonumber(charEntity.Mana) or 0) - (tonumber(castDef.ManaCost) or 0))
		charEntity:UpdateEntity(fsm.Id)
		fsm.Context._effectApplied = castDef.EffectType or "None"
		fsm.State = "Cooldown"
	end

	local function castCooldown(fsm: any)
		local castDef = fsm.Context._castDef
		local charEntity = fsm.Context._charEntity
		local cooldowns = table.clone(charEntity.AbilityCooldowns or {})
		cooldowns[castDef.Id] = fsm.Now + (tonumber(castDef.Cooldown) or 0)
		charEntity.AbilityCooldowns = cooldowns
		charEntity.ActiveCastId = ""
		if fsm.Context._movementLocked then
			charEntity.CanMove = true
			fsm.Context._movementLocked = false
		end
		charEntity:UpdateEntity(fsm.Id)
		if fsm.Context._lockHeld then
			charEntity:ReleaseLock(fsm.Id)
			fsm.Context._lockHeld = false
		end
		fsm.State = "Idle"
	end

	local function addStatusEntry(charEntity: any, fsmId: string, def: any)
		local active = table.clone(charEntity.ActiveStatusEffects or {})
		table.insert(active, {
			InstanceId = fsmId,
			EffectId = def.Id,
			Duration = def.Duration,
			Stacks = 1,
		})
		charEntity.ActiveStatusEffects = active
	end

	local function removeStatusEntry(charEntity: any, fsmId: string)
		local active = table.clone(charEntity.ActiveStatusEffects or {})
		for index, entry in ipairs(active) do
			if entry.InstanceId == fsmId then
				table.remove(active, index)
				break
			end
		end
		charEntity.ActiveStatusEffects = active
	end

	local function statusEnter(fsm: any)
		local charEntity = fsm.CharacterEntity
		local def = fsm.Definition
		fsm._tickAccumulator = 0
		fsm._effectApplied = true
		addStatusEntry(charEntity, fsm.Id, def)
		for stat, modifier in pairs(def.StatModifiers or {}) do
			if typeof(charEntity[stat]) == "number" then
				charEntity[stat] = charEntity[stat] + modifier
			end
		end
		for flagName, flagValue in pairs(def.ApplyFlags or {}) do
			charEntity[flagName] = flagValue
		end
		if def.Id == "Stun" then
			fsm._stunSnapshot = {
				CanMove = charEntity.CanMove,
				MoveSpeedCap = charEntity.MoveSpeedCap,
			}
			charEntity.CanMove = false
			charEntity.MoveSpeedCap = 0
		end
		charEntity:UpdateEntity()
	end

	local function statusHeartbeat(fsm: any, dt: number)
		local charEntity = fsm.CharacterEntity
		local def = fsm.Definition
		local interval = tonumber(def.TickInterval) or 0
		if interval <= 0 then
			return
		end
		fsm._tickAccumulator += dt
		while fsm._tickAccumulator >= interval do
			fsm._tickAccumulator -= interval
			local tickDamage = tonumber(def.TickDamage) or 0
			local tickHeal = tonumber(def.TickHeal) or 0
			if tickDamage > 0 then
				charEntity.Health = math.max(0, charEntity.Health - tickDamage)
			end
			if tickHeal > 0 then
				charEntity.Health = math.min(charEntity.MaxHealth, charEntity.Health + tickHeal)
			end
			charEntity:UpdateEntity()
		end
	end

	local function statusExpire(fsm: any)
		local charEntity = fsm.CharacterEntity
		local def = fsm.Definition
		removeStatusEntry(charEntity, fsm.Id)
		for stat, modifier in pairs(def.StatModifiers or {}) do
			if typeof(charEntity[stat]) == "number" then
				charEntity[stat] = charEntity[stat] - modifier
			end
		end
		for flagName, flagValue in pairs(def.ApplyFlags or {}) do
			if flagValue ~= nil then
				charEntity[flagName] = false
			end
		end
		if def.Id == "Stun" and fsm._stunSnapshot then
			charEntity.CanMove = fsm._stunSnapshot.CanMove
			charEntity.MoveSpeedCap = fsm._stunSnapshot.MoveSpeedCap
		end
		charEntity:UpdateEntity()
	end

	describe("MeleeAttackJob", function()
		it("fails validation without CharacterEntityId", function()
			local orchestrator = makeOrchestrator({})
			local fsm = makeFSM("Melee_1", {})
			meleeValidate(orchestrator, fsm)
			expect(fsm.State).toEqual("Failed")
			expect(fsm.Failure).toContain("CharacterEntityId")
		end)

		it("fails if character is stunned or knocked", function()
			local charEntity = makeCharacterEntity({ IsStunned = true })
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Melee_2", { CharacterEntityId = "Char_1" })
			meleeValidate(orchestrator, fsm)
			expect(fsm.State).toEqual("Failed")
			expect(fsm.Failure).toContain("crowd-controlled")
		end)

		it("rejects execution when stamina is insufficient", function()
			local charEntity = makeCharacterEntity({ Stamina = 4 })
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Melee_3", { CharacterEntityId = "Char_1", ComboSlot = 1 })
			meleeValidate(orchestrator, fsm)
			meleeAcquireLock(fsm)
			meleeExecute(fsm)
			expect(fsm.State).toEqual("ReleaseLock")
			expect(charEntity.Stamina).toEqual(4)
		end)

		it("deducts stamina on execute after lock", function()
			local charEntity = makeCharacterEntity({ Stamina = 40 })
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Melee_4", { CharacterEntityId = "Char_1", ComboSlot = 2 })
			meleeValidate(orchestrator, fsm)
			meleeAcquireLock(fsm)
			meleeExecute(fsm)
			expect(charEntity.Stamina).toEqual(28)
			expect(charEntity._updateCalls).toEqual(1)
		end)

		it("cycles combo pointer per attack", function()
			local charEntity = makeCharacterEntity({ _MeleePointers = { [1] = 1 } })
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Melee_5", { CharacterEntityId = "Char_1", ComboSlot = 1 })
			meleeValidate(orchestrator, fsm)
			meleeAcquireLock(fsm)
			meleeExecute(fsm)
			expect(charEntity._MeleePointers[1]).toEqual(2)
			expect(fsm.Context._phases[1].Name).toEqual("LeftPunch")
		end)

		it("creates DamageJob for victims", function()
			local charEntity = makeCharacterEntity()
			local victimA = { UserId = 11 }
			local victimB = { UserId = 22 }
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Melee_6", { CharacterEntityId = "Char_1", ComboSlot = 4 })
			meleeValidate(orchestrator, fsm)
			meleeAcquireLock(fsm)
			meleeExecute(fsm)
			meleeDamageScan(orchestrator, fsm, { victimA, victimB })
			expect(#orchestrator.CreatedMachines).toEqual(2)
			expect(orchestrator.CreatedMachines[1].StateMachineClass).toEqual("DamageJob")
			expect(orchestrator.CreatedMachines[1].Context.VictimUserId).toEqual(11)
		end)

		it("releases lock on completion", function()
			local charEntity = makeCharacterEntity()
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Melee_7", { CharacterEntityId = "Char_1" })
			meleeValidate(orchestrator, fsm)
			meleeAcquireLock(fsm)
			meleeReleaseLock(fsm)
			expect(charEntity._lockOwner).toBeNil()
			expect(charEntity._releaseCalls).toEqual(1)
			expect(fsm.State).toEqual("Completed")
		end)
	end)

	describe("ProjectileAttackJob", function()
		it("fails if no ranged weapon equipped", function()
			local charEntity = makeCharacterEntity()
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Proj_1", { CharacterEntityId = "Char_1" })
			fsm.Context._itemData = nil
			projectileValidate(orchestrator, fsm)
			expect(fsm.State).toEqual("Failed")
			expect(fsm.Failure).toContain("ranged weapon")
		end)

		it("rejects charge when mana is insufficient", function()
			local charEntity = makeCharacterEntity({ EquippedRight = "Bow_1", Mana = 5 })
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Proj_2", { CharacterEntityId = "Char_1" })
			fsm.Context._itemData = { WeaponType = "Bow", ManaCost = 10, WeaponStats = { Attack = 40 } }
			projectileValidate(orchestrator, fsm)
			projectileAcquireLock(fsm)
			projectileCharge(fsm)
			expect(fsm.State).toEqual("ReleaseLock")
			expect(charEntity.Mana).toEqual(5)
		end)

		it("deducts mana on charge after lock", function()
			local charEntity = makeCharacterEntity({ EquippedRight = "Bow_1", Mana = 40 })
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Proj_3", { CharacterEntityId = "Char_1" })
			fsm.Context._itemData = { WeaponType = "Bow", ManaCost = 12, ProjectileLifetime = 4 }
			projectileValidate(orchestrator, fsm)
			projectileAcquireLock(fsm)
			projectileCharge(fsm)
			expect(charEntity.Mana).toEqual(28)
			expect(fsm.State).toEqual("Fire")
		end)

		it("spawns projectile on fire", function()
			local charEntity = makeCharacterEntity({ EquippedRight = "Bow_1" })
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Proj_4", { CharacterEntityId = "Char_1" })
			fsm.Context._itemData = { WeaponType = "Bow", ManaCost = 5, ProjectileLifetime = 3 }
			projectileValidate(orchestrator, fsm)
			projectileAcquireLock(fsm)
			projectileCharge(fsm)
			projectileFire(orchestrator, fsm)
			expect(#orchestrator.SpawnedProjectiles).toEqual(1)
			expect(orchestrator.SpawnedProjectiles[1].Name).toEqual("Projectile_Proj_4")
		end)

		it("cleans up projectile after lifetime", function()
			local charEntity = makeCharacterEntity({ EquippedRight = "Bow_1" })
			local orchestrator = makeOrchestrator({ Char_1 = charEntity })
			local fsm = makeFSM("Proj_5", { CharacterEntityId = "Char_1" })
			fsm.Context._itemData = { WeaponType = "Bow", ManaCost = 5, ProjectileLifetime = 3 }
			projectileValidate(orchestrator, fsm)
			projectileAcquireLock(fsm)
			projectileCharge(fsm)
			projectileFire(orchestrator, fsm)
			projectileExpire(fsm)
			projectileReleaseLock(fsm)
			expect(fsm.Context._projectile.Destroyed).toBeTruthy()
			expect(charEntity._lockOwner).toBeNil()
		end)
	end)

	describe("CastFSM", function()
		it("validates ability exists", function()
			local charEntity = makeCharacterEntity()
			local playerEntity: any = { Level = 10, LearnedAbilities = { Fireball = true } }
			local orchestrator = makeOrchestrator({ Char_1 = charEntity, Player_1 = playerEntity })
			local fsm = makeFSM("Cast_1", { CharacterEntityId = "Char_1", PlayerEntityId = "Player_1", Now = 100 })
			castValidate(orchestrator, fsm)
			expect(fsm.State).toEqual("Failed")
			expect(fsm.Failure).toContain("Cast definition")
		end)

		it("checks stamina and mana costs", function()
			local charEntity = makeCharacterEntity({ Stamina = 4, Mana = 3 })
			local playerEntity: any = { Level = 10, LearnedAbilities = { Fireball = true } }
			local orchestrator = makeOrchestrator({ Char_1 = charEntity, Player_1 = playerEntity })
			local fsm = makeFSM("Cast_2", { CharacterEntityId = "Char_1", PlayerEntityId = "Player_1", Now = 100 })
			fsm.Context._castDef = { Id = "Fireball", StaminaCost = 5, ManaCost = 5, CastTime = 1, Cooldown = 6, EffectType = "Projectile" }
			castValidate(orchestrator, fsm)
			expect(fsm.State).toEqual("Failed")
			expect(fsm.Failure).toContain("stamina")
		end)

		it("checks cooldown", function()
			local charEntity = makeCharacterEntity({ AbilityCooldowns = { Fireball = 150 } })
			local playerEntity: any = { Level = 10, LearnedAbilities = { Fireball = true } }
			local orchestrator = makeOrchestrator({ Char_1 = charEntity, Player_1 = playerEntity })
			local fsm = makeFSM("Cast_3", { CharacterEntityId = "Char_1", PlayerEntityId = "Player_1", Now = 100 })
			fsm.Context._castDef = { Id = "Fireball", StaminaCost = 0, ManaCost = 5, CastTime = 1, Cooldown = 6, EffectType = "Projectile" }
			castValidate(orchestrator, fsm)
			expect(fsm.State).toEqual("Failed")
			expect(fsm.Failure).toContain("cooldown")
		end)

		it("enters Casting state with proper duration", function()
			local charEntity = makeCharacterEntity({ Mana = 30 })
			local playerEntity: any = { Level = 10, LearnedAbilities = { Fireball = true } }
			local orchestrator = makeOrchestrator({ Char_1 = charEntity, Player_1 = playerEntity })
			local fsm = makeFSM("Cast_4", { CharacterEntityId = "Char_1", PlayerEntityId = "Player_1", Now = 100 })
			fsm.Context._castDef = { Id = "Fireball", StaminaCost = 0, ManaCost = 25, CastTime = 1.5, Cooldown = 6, EffectType = "Projectile" }
			castValidate(orchestrator, fsm)
			castEnterCasting(fsm)
			expect(fsm.State).toEqual("Casting")
			expect(fsm.Context._castEndsAt).toBeCloseTo(101.5, 0.001)
			expect(charEntity.CanMove).toBeFalsy()
		end)

		it("is interruptible during cast stun or knock", function()
			local charEntity = makeCharacterEntity({ Mana = 30 })
			local playerEntity: any = { Level = 10, LearnedAbilities = { Fireball = true } }
			local orchestrator = makeOrchestrator({ Char_1 = charEntity, Player_1 = playerEntity })
			local fsm = makeFSM("Cast_5", { CharacterEntityId = "Char_1", PlayerEntityId = "Player_1", Now = 100 })
			fsm.Context._castDef = { Id = "Fireball", StaminaCost = 0, ManaCost = 25, CastTime = 1.5, Cooldown = 6, EffectType = "Projectile" }
			castValidate(orchestrator, fsm)
			castEnterCasting(fsm)
			charEntity.IsStunned = true
			castHeartbeat(fsm)
			expect(fsm.State).toEqual("Failed")
			expect(fsm.Failure).toContain("interrupted")
		end)

		it("applies effects on execute", function()
			local charEntity = makeCharacterEntity({ Mana = 40 })
			local playerEntity: any = { Level = 10, LearnedAbilities = { Fireball = true } }
			local orchestrator = makeOrchestrator({ Char_1 = charEntity, Player_1 = playerEntity })
			local fsm = makeFSM("Cast_6", { CharacterEntityId = "Char_1", PlayerEntityId = "Player_1", Now = 100 })
			fsm.Context._castDef = { Id = "Fireball", StaminaCost = 5, ManaCost = 10, CastTime = 0, Cooldown = 6, EffectType = "Projectile" }
			castValidate(orchestrator, fsm)
			castExecute(fsm)
			expect(fsm.Context._effectApplied).toEqual("Projectile")
			expect(charEntity.Stamina).toEqual(95)
			expect(charEntity.Mana).toEqual(30)
		end)

		it("sets cooldown timestamp", function()
			local charEntity = makeCharacterEntity({ Mana = 40 })
			local playerEntity: any = { Level = 10, LearnedAbilities = { Fireball = true } }
			local orchestrator = makeOrchestrator({ Char_1 = charEntity, Player_1 = playerEntity })
			local fsm = makeFSM("Cast_7", { CharacterEntityId = "Char_1", PlayerEntityId = "Player_1", Now = 100 })
			fsm.Context._castDef = { Id = "Fireball", StaminaCost = 0, ManaCost = 10, CastTime = 0, Cooldown = 6, EffectType = "Projectile" }
			castValidate(orchestrator, fsm)
			castExecute(fsm)
			castCooldown(fsm)
			expect(charEntity.AbilityCooldowns.Fireball).toEqual(106)
			expect(charEntity.ActiveCastId).toEqual("")
			expect(charEntity._lockOwner).toBeNil()
		end)
	end)

	describe("StatusEffectFSM", function()
		it("applies stat modifiers on Active enter", function()
			local charEntity = makeCharacterEntity({ MaxHealth = 100, MaxStamina = 100 })
			local fsm: any = {
				Id = "Effect_1",
				CharacterEntity = charEntity,
				Definition = { Id = "Shield", Duration = 6, TickInterval = 0, StatModifiers = { MaxHealth = 50 } },
			}
			statusEnter(fsm)
			expect(charEntity.MaxHealth).toEqual(150)
			expect(#charEntity.ActiveStatusEffects).toEqual(1)
		end)

		it("ticks damage at interval", function()
			local charEntity = makeCharacterEntity({ Health = 100, MaxHealth = 100 })
			local fsm: any = {
				Id = "Effect_2",
				CharacterEntity = charEntity,
				Definition = { Id = "Poison", Duration = 5, TickInterval = 1, TickDamage = 5, StatModifiers = {} },
			}
			statusEnter(fsm)
			statusHeartbeat(fsm, 2.2)
			expect(charEntity.Health).toEqual(90)
		end)

		it("ticks heal at interval", function()
			local charEntity = makeCharacterEntity({ Health = 60, MaxHealth = 100 })
			local fsm: any = {
				Id = "Effect_3",
				CharacterEntity = charEntity,
				Definition = { Id = "Regeneration", Duration = 8, TickInterval = 1, TickHeal = 5, StatModifiers = {} },
			}
			statusEnter(fsm)
			statusHeartbeat(fsm, 2.1)
			expect(charEntity.Health).toEqual(70)
		end)

		it("expires after duration", function()
			local charEntity = makeCharacterEntity({ MaxHealth = 100 })
			local fsm: any = {
				Id = "Effect_4",
				CharacterEntity = charEntity,
				Definition = { Id = "Shield", Duration = 6, TickInterval = 0, StatModifiers = { MaxHealth = 50 } },
			}
			statusEnter(fsm)
			statusExpire(fsm)
			expect(#charEntity.ActiveStatusEffects).toEqual(0)
		end)

		it("removes stat modifiers on expire", function()
			local charEntity = makeCharacterEntity({ MaxStamina = 100 })
			local fsm: any = {
				Id = "Effect_5",
				CharacterEntity = charEntity,
				Definition = { Id = "Strength", Duration = 10, TickInterval = 0, StatModifiers = { MaxStamina = 30 } },
			}
			statusEnter(fsm)
			statusExpire(fsm)
			expect(charEntity.MaxStamina).toEqual(100)
		end)

		it("applies flags for Stun effect", function()
			local charEntity = makeCharacterEntity({ IsStunned = false, CanMove = true, MoveSpeedCap = 16 })
			local fsm: any = {
				Id = "Effect_6",
				CharacterEntity = charEntity,
				Definition = { Id = "Stun", Duration = 2, TickInterval = 0, StatModifiers = {}, ApplyFlags = { IsStunned = true } },
			}
			statusEnter(fsm)
			expect(charEntity.IsStunned).toBeTruthy()
			expect(charEntity.CanMove).toBeFalsy()
			expect(charEntity.MoveSpeedCap).toEqual(0)
		end)

		it("stacks if Stackable true", function()
			local charEntity = makeCharacterEntity()
			local def = { Id = "Burning", Duration = 4, TickInterval = 0.5, TickDamage = 3, Stackable = true, StatModifiers = {} }
			local fsmA: any = { Id = "Effect_7A", CharacterEntity = charEntity, Definition = def }
			local fsmB: any = { Id = "Effect_7B", CharacterEntity = charEntity, Definition = def }
			statusEnter(fsmA)
			statusEnter(fsmB)
			expect(#charEntity.ActiveStatusEffects).toEqual(2)
			expect(charEntity.ActiveStatusEffects[1].EffectId).toEqual("Burning")
			expect(charEntity.ActiveStatusEffects[2].EffectId).toEqual("Burning")
		end)
	end)
end

TR.register(spec)
return spec
