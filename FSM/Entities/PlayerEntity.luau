--!strict
-- @Name PlayerEntity
-- @Author iKrypto
-- @Description Entity implementation for player-level persistent data

local PlayerEntity = {
	Name = "PlayerEntity",
	Mutable = true,
	Replication = { Enabled = true, RateLimit = 30 },
	Schema = {
		UserId = { Type = "number", Replicate = true, Persist = true },
		Class = { Type = "string", Replicate = true, Persist = true },
		Level = { Type = "number", Replicate = true, Persist = true },
		XP = { Type = "number", Replicate = true, Persist = true },
		MaxXP = { Type = "number", Replicate = true, Persist = true },
		Inventory = { Type = "any", Replicate = true, Persist = true },
		BagContents = { Type = "any", Replicate = true, Persist = true },
		Equipped = { Type = "any", Replicate = true, Persist = true },
		EquipSlots = { Type = "any", Replicate = true, Persist = true },
		WeaponEqp = { Type = "string", Replicate = true, Persist = true },
		LearnedAbilities = { Type = "any", Replicate = true, Persist = true },
		SkillPoints = { Type = "number", Replicate = true, Persist = true },
		StatPoints = { Type = "number", Replicate = true, Persist = true },
		Strength = { Type = "number", Replicate = true, Persist = true },
		Agility = { Type = "number", Replicate = true, Persist = true },
		Vitality = { Type = "number", Replicate = true, Persist = true },
		Endurance = { Type = "number", Replicate = true, Persist = true },
		Intelligence = { Type = "number", Replicate = true, Persist = true },
		Luck = { Type = "number", Replicate = true, Persist = true },
		AbilityBindings = { Type = "any", Replicate = true, Persist = true },
		QuickItemSlots = { Type = "any", Replicate = true, Persist = true },
		ActionBar = { Type = "any", Replicate = true, Persist = true },
		Settings = { Type = "any", Replicate = true, Persist = true },
		Cooldowns = { Type = "any", Replicate = true, Persist = false },
		Revision = { Type = "number", Replicate = true, Persist = false },
		DataVersion = { Type = "number", Replicate = false, Persist = true },
	},
}

function PlayerEntity:GetContext(params: { [any]: any })
	local context = params.Context or params
	local userId = context.UserId
		or (context.Instance and context.Instance:IsA("Player") and context.Instance.UserId)
		or 0

	return {
		UserId = userId,
		Class = context.Class or "Beginner",
		Level = context.Level or 1,
		XP = context.XP or 0,
		MaxXP = context.MaxXP or 100,
		Inventory = context.Inventory or { "1", "2", "3", "4", "5", "6", "7" },
		BagContents = context.BagContents or {},
		Equipped = context.Equipped or {},
		EquipSlots = context.EquipSlots or {
			Head = "",
			Chest = "",
			Legs = "",
			Feet = "",
			MainHand = "",
			OffHand = "",
			Accessory1 = "",
			Accessory2 = "",
			Accessory3 = "",
		},
		WeaponEqp = context.WeaponEqp or "1",
		LearnedAbilities = context.LearnedAbilities or {},
		SkillPoints = context.SkillPoints or 0,
		StatPoints = context.StatPoints or 0,
		Strength = context.Strength or 0,
		Agility = context.Agility or 0,
		Vitality = context.Vitality or 0,
		Endurance = context.Endurance or 0,
		Intelligence = context.Intelligence or 0,
		Luck = context.Luck or 0,
		AbilityBindings = context.AbilityBindings or { Q = "", E = "", R = "", F = "" },
		QuickItemSlots = context.QuickItemSlots or { "", "", "", "" },
		ActionBar = context.ActionBar or {},
		Settings = context.Settings or {},
		Cooldowns = context.Cooldowns or {},
		Revision = 0,
		DataVersion = context.DataVersion or 1,
	}
end

function PlayerEntity:ApplyChanges(_changes: { [string]: any })
	-- PlayerEntity is pure data — no visual rendering
end

return PlayerEntity
