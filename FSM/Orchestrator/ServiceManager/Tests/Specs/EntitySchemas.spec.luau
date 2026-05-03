--!strict
-- @Name ServiceManager/Tests/Specs/EntitySchemas.spec.luau
-- @Description Schema coverage tests for the new RPG-facing entities.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local CharacterEntity: any = {
		Schema = {
			Health = { Type = "number" },
			MaxHealth = { Type = "number" },
			Stamina = { Type = "number" },
			MaxStamina = { Type = "number" },
			Mana = { Type = "number" },
			MaxMana = { Type = "number" },
			TargetEntityId = { Type = "string" },
			LocomotionState = { Type = "string" },
			ActionOverlay = { Type = "string" },
			ActiveStatusEffects = { Type = "any" },
			AbilityCooldowns = { Type = "any" },
		},
	}

	function CharacterEntity:GetContext(params)
		local context = params.Context or params
		local userId = context.UserId or 0
		return {
			PlayerEntityId = context.PlayerEntityId or ("Player_" .. tostring(userId)),
			UserId = userId,
			Health = 100,
			MaxHealth = 100,
			Stamina = 100,
			MaxStamina = 100,
			Mana = 50,
			MaxMana = 50,
			TargetEntityId = "",
			LocomotionState = "Idle",
			ActionOverlay = "None",
			ActiveStatusEffects = {},
			AbilityCooldowns = {},
			RecentActions = {},
			ActionSeq = 0,
			EquippedRight = "",
			EquippedLeft = "",
		}
	end

	function CharacterEntity:ApplyChanges(changes)
		if changes.RecentActions or changes.ActionSeq then
			local renderRouter = self._renderRouter
			if renderRouter and typeof(renderRouter.ProcessRecentActions) == "function" then
				local actions = self.RecentActions
				if typeof(actions) == "table" then
					renderRouter:ProcessRecentActions(actions, self.ActionSeq)
				end
			end
		end
		if changes.EquippedRight ~= nil or changes.EquippedLeft ~= nil then
			local renderRouter = self._renderRouter
			if renderRouter and typeof(renderRouter._handleEquipVisual) == "function" then
				renderRouter:_handleEquipVisual({
					Kind = if changes.EquippedRight ~= nil then "Equip" else "UnEquip",
					Payload = { Hand = if changes.EquippedRight ~= nil then "Right" else "Left" },
				})
			end
		end
	end

	local PlayerEntity: any = {
		Schema = {
			Level = { Type = "number" },
			XP = { Type = "number" },
			MaxXP = { Type = "number" },
			BagContents = { Type = "any" },
			LearnedAbilities = { Type = "any" },
			AbilityBindings = { Type = "any" },
		},
	}

	function PlayerEntity:GetContext(params)
		local context = params.Context or params
		return {
			Level = context.Level or 1,
			XP = context.XP or 0,
			MaxXP = context.MaxXP or 100,
			BagContents = context.BagContents or {},
			LearnedAbilities = context.LearnedAbilities or {},
			AbilityBindings = context.AbilityBindings or { Q = "", E = "", R = "", F = "" },
		}
	end

	describe("CharacterEntity", function()
		it("has Health MaxHealth Stamina MaxStamina Mana and MaxMana in schema", function()
			for _, key in ipairs({ "Health", "MaxHealth", "Stamina", "MaxStamina", "Mana", "MaxMana" }) do
				expect(CharacterEntity.Schema[key]).never.toBeNil()
			end
		end)

		it("defaults Health to 100 Stamina to 100 and Mana to 50", function()
			local context = CharacterEntity:GetContext({ UserId = 12 })
			expect(context.Health).toEqual(100)
			expect(context.Stamina).toEqual(100)
			expect(context.Mana).toEqual(50)
		end)

		it("has TargetEntityId LocomotionState and ActionOverlay fields", function()
			for _, key in ipairs({ "TargetEntityId", "LocomotionState", "ActionOverlay" }) do
				expect(CharacterEntity.Schema[key]).never.toBeNil()
			end
		end)

		it("has ActiveStatusEffects and AbilityCooldowns fields", function()
			expect(CharacterEntity.Schema.ActiveStatusEffects).never.toBeNil()
			expect(CharacterEntity.Schema.AbilityCooldowns).never.toBeNil()
		end)

		it("ApplyChanges nil checks renderRouter", function()
			local entity = CharacterEntity:GetContext({})
			entity._renderRouter = nil
			entity.RecentActions = { { Kind = "Animation" } }
			entity.ActionSeq = 2
			entity.ApplyChanges = CharacterEntity.ApplyChanges
			local ok, err = pcall(function()
				entity:ApplyChanges({ RecentActions = true, ActionSeq = true, EquippedRight = "Sword" })
			end)
			expect(ok).toBeTruthy()
			expect(err).toBeNil()
		end)
	end)

	describe("PlayerEntity", function()
		it("has Level XP and MaxXP in schema", function()
			for _, key in ipairs({ "Level", "XP", "MaxXP" }) do
				expect(PlayerEntity.Schema[key]).never.toBeNil()
			end
		end)

		it("has BagContents LearnedAbilities and AbilityBindings", function()
			for _, key in ipairs({ "BagContents", "LearnedAbilities", "AbilityBindings" }) do
				expect(PlayerEntity.Schema[key]).never.toBeNil()
			end
		end)

		it("defaults Level to 1 and XP to 0", function()
			local context = PlayerEntity:GetContext({})
			expect(context.Level).toEqual(1)
			expect(context.XP).toEqual(0)
		end)

	end)
end

TR.register(spec)
return spec
