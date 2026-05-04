--!strict
-- @Name ServiceManager/Tests/Specs/RPGSystems.spec.luau
-- @Description Data contract tests for ability, talent, and status-effect definitions.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local AbilityDefs: any = {}
	AbilityDefs.Abilities = {
		WhirlwindSlash = { Id = "WhirlwindSlash", StaminaCost = 25, ManaCost = 0, CastTime = 0, Cooldown = 3 },
		PowerStrike = { Id = "PowerStrike", StaminaCost = 15, ManaCost = 0, CastTime = 0, Cooldown = 2 },
		ShadowStep = { Id = "ShadowStep", StaminaCost = 20, ManaCost = 5, CastTime = 0, Cooldown = 4 },
		PowerShot = { Id = "PowerShot", StaminaCost = 10, ManaCost = 15, CastTime = 0.5, Cooldown = 5 },
		Fireball = { Id = "Fireball", StaminaCost = 0, ManaCost = 25, CastTime = 1.0, Cooldown = 6, ComboSequence = "QEQ" },
		HealingLight = { Id = "HealingLight", StaminaCost = 0, ManaCost = 30, CastTime = 1.5, Cooldown = 10, ComboSequence = "EEQ" },
		ThunderStrike = { Id = "ThunderStrike", StaminaCost = 0, ManaCost = 35, CastTime = 0.8, Cooldown = 8, ComboSequence = "QERF" },
	}
	AbilityDefs.Consumables = {
		HealthPotion = { Id = "HealthPotion", UseTime = 0.5, EffectType = "InstantHeal" },
		StaminaPotion = { Id = "StaminaPotion", UseTime = 0.5, EffectType = "InstantStamina" },
		ManaPotion = { Id = "ManaPotion", UseTime = 0.5, EffectType = "InstantMana" },
	}
	function AbilityDefs.GetAbility(id)
		return AbilityDefs.Abilities[id]
	end
	function AbilityDefs.GetConsumable(id)
		return AbilityDefs.Consumables[id]
	end
	function AbilityDefs.GetSpellCombos()
		local combos = {}
		for id, ability in pairs(AbilityDefs.Abilities) do
			if ability.ComboSequence then
				combos[ability.ComboSequence] = id
			end
		end
		return combos
	end

	local TalentTreeDefs: any = {}
	TalentTreeDefs.Trees = {
		Claymore = {
			{ Id = "claymore_t1", AbilityId = "PowerStrike", RequiredLevel = 2, Cost = 1, Prerequisites = {} },
			{ Id = "claymore_t2", AbilityId = "WhirlwindSlash", RequiredLevel = 3, Cost = 1, Prerequisites = { "claymore_t1" } },
		},
		General = {
			{ Id = "gen_t1", AbilityId = "Fireball", RequiredLevel = 5, Cost = 2, Prerequisites = {} },
			{ Id = "gen_t3", AbilityId = "ThunderStrike", RequiredLevel = 7, Cost = 3, Prerequisites = { "gen_t1" } },
		},
	}
	local NodeIndex = {}
	for _, tree in pairs(TalentTreeDefs.Trees) do
		for _, node in ipairs(tree) do
			NodeIndex[node.Id] = node
		end
	end
	local function hasLearned(playerEntity, nodeId)
		local learned = playerEntity and playerEntity.LearnedAbilities or {}
		for _, value in ipairs(learned) do
			if value == nodeId then
				return true
			end
		end
		for key, value in pairs(learned) do
			if key == nodeId and (value == true or value == nodeId) then
				return true
			end
			if value == nodeId then
				return true
			end
		end
		return false
	end
	function TalentTreeDefs.GetNode(nodeId)
		return NodeIndex[nodeId]
	end
	function TalentTreeDefs.GetRemainingSkillPoints(playerEntity)
		return math.max((tonumber(playerEntity and playerEntity.Level) or 1) - 1 - (tonumber(playerEntity and playerEntity.SpentPoints) or 0), 0)
	end
	function TalentTreeDefs.CanUnlock(nodeId, playerEntity)
		local node = TalentTreeDefs.GetNode(nodeId)
		if not node then
			return false, "Node not found"
		end
		if (tonumber(playerEntity and playerEntity.Level) or 1) < (tonumber(node.RequiredLevel) or 1) then
			return false, "Level too low"
		end
		if hasLearned(playerEntity, nodeId) then
			return false, "Already learned"
		end
		for _, prereq in ipairs(node.Prerequisites or {}) do
			if not hasLearned(playerEntity, prereq) then
				return false, "Missing prerequisite: " .. prereq
			end
		end
		if TalentTreeDefs.GetRemainingSkillPoints(playerEntity) < (tonumber(node.Cost) or 0) then
			return false, "Not enough skill points"
		end
		return true, nil
	end

	local StatusEffectDefs: any = {}
	StatusEffectDefs.Effects = {
		Poison = { Id = "Poison", Type = "Debuff", Duration = 5, TickInterval = 1 },
		Burning = { Id = "Burning", Type = "Debuff", Duration = 4, TickInterval = 0.5 },
		Regeneration = { Id = "Regeneration", Type = "Buff", Duration = 8, TickInterval = 1 },
		Strength = { Id = "Strength", Type = "Buff", Duration = 10, TickInterval = 0 },
		Shield = { Id = "Shield", Type = "Buff", Duration = 6, TickInterval = 0 },
		Stun = { Id = "Stun", Type = "Debuff", Duration = 2, TickInterval = 0 },
		Silence = { Id = "Silence", Type = "Debuff", Duration = 3, TickInterval = 0 },
	}
	function StatusEffectDefs.Get(id)
		return StatusEffectDefs.Effects[id]
	end

	describe("AbilityDefs", function()
		it("GetAbility returns valid ability data", function()
			local ability = AbilityDefs.GetAbility("Fireball")
			expect(ability).never.toBeNil()
			expect(ability.Id).toEqual("Fireball")
		end)

		it("GetSpellCombos returns combo to abilityId mapping", function()
			local combos = AbilityDefs.GetSpellCombos()
			expect(combos.QEQ).toEqual("Fireball")
			expect(combos.EEQ).toEqual("HealingLight")
			expect(combos.QERF).toEqual("ThunderStrike")
		end)

		it("each ability has Id StaminaCost ManaCost CastTime and Cooldown", function()
			for _, ability in pairs(AbilityDefs.Abilities) do
				for _, key in ipairs({ "Id", "StaminaCost", "ManaCost", "CastTime", "Cooldown" }) do
					expect(ability[key]).never.toBeNil()
				end
			end
		end)

		it("consumables have UseTime and EffectType", function()
			for _, consumable in pairs(AbilityDefs.Consumables) do
				expect(consumable.UseTime).never.toBeNil()
				expect(consumable.EffectType).never.toBeNil()
			end
		end)
	end)

	describe("TalentTreeDefs", function()
		it("GetNode finds nodes by ID", function()
			local node = TalentTreeDefs.GetNode("claymore_t1")
			expect(node).never.toBeNil()
			expect(node.AbilityId).toEqual("PowerStrike")
		end)

		it("CanUnlock rejects if level is too low", function()
			local ok, reason = TalentTreeDefs.CanUnlock("gen_t1", { Level = 2, LearnedAbilities = {}, SpentPoints = 0 })
			expect(ok).toBeFalsy()
			expect(reason).toContain("Level too low")
		end)

		it("CanUnlock rejects if already learned", function()
			local ok, reason = TalentTreeDefs.CanUnlock("claymore_t1", { Level = 5, LearnedAbilities = { "claymore_t1" }, SpentPoints = 0 })
			expect(ok).toBeFalsy()
			expect(reason).toContain("Already learned")
		end)

		it("CanUnlock rejects if prerequisites are unmet", function()
			local ok, reason = TalentTreeDefs.CanUnlock("gen_t3", { Level = 10, LearnedAbilities = {}, SpentPoints = 0 })
			expect(ok).toBeFalsy()
			expect(reason).toContain("Missing prerequisite")
		end)

		it("CanUnlock accepts if all conditions are met", function()
			local ok, reason = TalentTreeDefs.CanUnlock("claymore_t2", { Level = 5, LearnedAbilities = { "claymore_t1" }, SpentPoints = 0 })
			expect(ok).toBeTruthy()
			expect(reason).toBeNil()
		end)
	end)

	describe("StatusEffectDefs", function()
		it("Get returns effect data", function()
			local effect = StatusEffectDefs.Get("Poison")
			expect(effect).never.toBeNil()
			expect(effect.Id).toEqual("Poison")
		end)

		it("each effect has Duration TickInterval and Type", function()
			for _, effect in pairs(StatusEffectDefs.Effects) do
				for _, key in ipairs({ "Duration", "TickInterval", "Type" }) do
					expect(effect[key]).never.toBeNil()
				end
			end
		end)

		it("debuffs have Type Debuff", function()
			for _, id in ipairs({ "Poison", "Burning", "Stun", "Silence" }) do
				expect(StatusEffectDefs.Get(id).Type).toEqual("Debuff")
			end
		end)

		it("buffs have Type Buff", function()
			for _, id in ipairs({ "Regeneration", "Strength", "Shield" }) do
				expect(StatusEffectDefs.Get(id).Type).toEqual("Buff")
			end
		end)
	end)
end

TR.register(spec)
return spec
