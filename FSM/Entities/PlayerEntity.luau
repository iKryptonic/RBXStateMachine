--!strict
--[=[
	@Name PlayerEntity
	@Description Persistent player-profile entity that stores long-lived progression, inventory,
	ability loadouts, talent selections, stats, and client-facing preferences for a single player.

	Schema Fields:
	- UserId: number (Replicate: true, Persist: true) -- Authoritative save owner and entity identity key.
	- Class: string (Replicate: true, Persist: true) -- Current class/archetype selection.
	- Level: number (Replicate: true, Persist: true) -- Persistent progression level.
	- XP: number (Replicate: true, Persist: true) -- Current experience toward the next level.
	- MaxXP: number (Replicate: true, Persist: true) -- Experience threshold for leveling.
	- Inventory: any (Replicate: true, Persist: true) -- Owned item/ability id list, including starter migration items.
	- BagContents: any (Replicate: true, Persist: true) -- Additional bag/container storage data.
	- Equipped: any (Replicate: true, Persist: true) -- Persistent equipment mapping/state.
	- WeaponEqp: string (Replicate: true, Persist: true) -- Selected weapon inventory id for spawn/equip flows.
	- LearnedAbilities: any (Replicate: true, Persist: true) -- Permanently learned active ability ids.
	- EquippedAbilities: any (Replicate: true, Persist: true) -- Recently added equipped active-ability loadout data.
	- AbilityCooldowns: any (Replicate: true, Persist: false) -- Session-only mirror of player-scoped ability cooldowns.
	- UnlockedAbilities: any (Replicate: true, Persist: true) -- Recently added passive/talent-driven unlock cache.
	- TalentSelections: any (Replicate: true, Persist: true) -- Recently added chosen talent ids by tier.
	- SkillPoints: number (Replicate: true, Persist: true) -- Spendable talent/skill points remaining.
	- StatPoints: number (Replicate: true, Persist: true) -- Unspent attribute points.
	- Strength: number (Replicate: true, Persist: true) -- Persistent strength allocation.
	- Agility: number (Replicate: true, Persist: true) -- Persistent agility allocation.
	- Vitality: number (Replicate: true, Persist: true) -- Persistent vitality allocation.
	- Endurance: number (Replicate: true, Persist: true) -- Persistent endurance allocation.
	- Intelligence: number (Replicate: true, Persist: true) -- Persistent intelligence allocation.
	- Luck: number (Replicate: true, Persist: true) -- Persistent luck allocation.
	- AbilityBindings: any (Replicate: true, Persist: true) -- Persistent hotkey-to-ability mapping.
	- QuickItemSlots: any (Replicate: true, Persist: true) -- Persistent consumable/quick-slot mapping.
	- ActionBar: any (Replicate: true, Persist: true) -- Persistent UI/action-bar ordering data.
	- Settings: any (Replicate: true, Persist: true) -- Persistent per-player gameplay/UI preferences.
	- Cooldowns: any (Replicate: true, Persist: false) -- Session-only generic cooldown cache.
	- Revision: number (Replicate: true, Persist: false) -- Session revision counter for live entity updates.
	- DataVersion: number (Replicate: false, Persist: true) -- Save schema version used for migrations.

	Used by:
	- LoadPlayerJob for creation, default seeding, and legacy-save migration.
	- PersistenceManager and PlayerEntity persistence tests for save serialization.
	- InventoryItemFSM, EquipJob, ToggleWeaponJob, and SpawnCharacterJob for inventory/loadout reads.
	- CastFSM and related UI/input systems for learned abilities, bindings, quick slots, and cooldown mirrors.

	Lifecycle:
	- Created by LoadPlayerJob as Player_<UserId> when a player joins.
	- Hydrated from persisted data on the server and replicated to clients for UI and command flows.
	- Updated throughout play by gameplay FSMs and helper systems.
	- Torn down with the player's session; persisted fields are serialized before teardown when persistence is enabled.

	Defaults and Migration:
	- GetContext seeds starter progression, starter inventory, empty tables, and default bindings/quick slots.
	- LoadPlayerJob backfills missing tables and invalid scalar values on older saves.
	- DataVersion defaults to 1 when absent.
	- EquippedAbilities, UnlockedAbilities, and TalentSelections were added recently for the ability/talent pass;
		legacy saves may omit them and are migrated to empty tables.
]=]

local PlayerEntity = {
Name = "PlayerEntity",
Mutable = true,
Replication = { Enabled = true, RateLimit = 30 },
Schema = {
-- @field UserId number
-- Replicate: true, Persist: true
-- Default: resolved from Context.UserId, Context.Instance.UserId, or 0.
-- Authoritative save owner identifier; corrected by LoadPlayerJob if legacy data mismatches the live player.
UserId = { Type = "number", Replicate = true, Persist = true },

-- @field Class string
-- Replicate: true, Persist: true
-- Default: "Beginner".
-- Persistent class/archetype label used by progression and UI systems.
Class = { Type = "string", Replicate = true, Persist = true },

-- @field Level number
-- Replicate: true, Persist: true
-- Default: 1.
-- Persistent character progression level used for unlock gates and reward scaling.
Level = { Type = "number", Replicate = true, Persist = true },

-- @field XP number
-- Replicate: true, Persist: true
-- Default: 0.
-- Running experience total toward MaxXP.
XP = { Type = "number", Replicate = true, Persist = true },

-- @field MaxXP number
-- Replicate: true, Persist: true
-- Default: 100.
-- Current experience threshold required for the next level.
MaxXP = { Type = "number", Replicate = true, Persist = true },

-- @field Inventory any
-- Replicate: true, Persist: true
-- Default: starter inventory seeded in GetContext.
-- Owned item/ability ids; LoadPlayerJob also migrates older saves by ensuring all starter entries exist.
Inventory = { Type = "any", Replicate = true, Persist = true },

-- @field BagContents any
-- Replicate: true, Persist: true
-- Default: {}.
-- Auxiliary bag/container payload for inventory expansion systems.
BagContents = { Type = "any", Replicate = true, Persist = true },

-- @field Equipped any
-- Replicate: true, Persist: true
-- Default: {}.
-- Persistent equipment table used alongside weapon toggles and spawn/loadout restoration.
Equipped = { Type = "any", Replicate = true, Persist = true },

-- @field WeaponEqp string
-- Replicate: true, Persist: true
-- Default: "".
-- Selected weapon item id for SpawnCharacterJob/ToggleWeaponJob; migrated away from legacy placeholder value "1".
WeaponEqp = { Type = "string", Replicate = true, Persist = true },

-- @field LearnedAbilities any
-- Replicate: true, Persist: true
-- Default: {}.
-- Persistent list/map of abilities permanently learned and available to combat systems.
LearnedAbilities = { Type = "any", Replicate = true, Persist = true },

-- @field EquippedAbilities any
-- Replicate: true, Persist: true
-- Default: {}.
-- Recently added persistent active-ability loadout data; legacy saves are backfilled when missing.
EquippedAbilities = { Type = "any", Replicate = true, Persist = true },

-- @field AbilityCooldowns any
-- Replicate: true, Persist: false
-- Default: {}.
-- Session-only replicated cooldown mirror for ability UI/state; intentionally excluded from persistence.
AbilityCooldowns = { Type = "any", Replicate = true, Persist = false },

-- @field UnlockedAbilities any
-- Replicate: true, Persist: true
-- Default: {}.
-- Recently added persistent cache of talent/passive unlocked abilities; older saves are migrated to an empty table.
UnlockedAbilities = { Type = "any", Replicate = true, Persist = true },

-- @field TalentSelections any
-- Replicate: true, Persist: true
-- Default: {}.
-- Recently added persistent tier-to-talent selection map used by talent progression and passive effect computation.
TalentSelections = { Type = "any", Replicate = true, Persist = true },

-- @field SkillPoints number
-- Replicate: true, Persist: true
-- Default: 0.
-- Spendable skill/talent points; LoadPlayerJob recomputes this from talent definitions for migration correctness.
SkillPoints = { Type = "number", Replicate = true, Persist = true },

-- @field StatPoints number
-- Replicate: true, Persist: true
-- Default: 0.
-- Unallocated attribute points available to the player.
StatPoints = { Type = "number", Replicate = true, Persist = true },

-- @field Strength number
-- Replicate: true, Persist: true
-- Default: 0.
-- Persistent strength allocation used by derived stat computation.
Strength = { Type = "number", Replicate = true, Persist = true },

-- @field Agility number
-- Replicate: true, Persist: true
-- Default: 0.
-- Persistent agility allocation used by derived stat computation.
Agility = { Type = "number", Replicate = true, Persist = true },

-- @field Vitality number
-- Replicate: true, Persist: true
-- Default: 0.
-- Persistent vitality allocation used by derived stat computation.
Vitality = { Type = "number", Replicate = true, Persist = true },

-- @field Endurance number
-- Replicate: true, Persist: true
-- Default: 0.
-- Persistent endurance allocation used by derived stat computation.
Endurance = { Type = "number", Replicate = true, Persist = true },

-- @field Intelligence number
-- Replicate: true, Persist: true
-- Default: 0.
-- Persistent intelligence allocation used by derived stat computation.
Intelligence = { Type = "number", Replicate = true, Persist = true },

-- @field Luck number
-- Replicate: true, Persist: true
-- Default: 0.
-- Persistent luck allocation used by derived stat computation and loot/crit style systems.
Luck = { Type = "number", Replicate = true, Persist = true },

-- @field AbilityBindings any
-- Replicate: true, Persist: true
-- Default: { Q = "", E = "", R = "", F = "" }.
-- Persistent hotkey mapping for ability activation; LoadPlayerJob backfills any missing key slots.
AbilityBindings = { Type = "any", Replicate = true, Persist = true },

-- @field QuickItemSlots any
-- Replicate: true, Persist: true
-- Default: { "", "", "", "" }.
-- Persistent quick-access consumable/item slots; CastFSM also clears depleted entries during play.
QuickItemSlots = { Type = "any", Replicate = true, Persist = true },

-- @field ActionBar any
-- Replicate: true, Persist: true
-- Default: {}.
-- Persistent action-bar arrangement data for client HUD presentation.
ActionBar = { Type = "any", Replicate = true, Persist = true },

-- @field Settings any
-- Replicate: true, Persist: true
-- Default: {}.
-- Persistent per-player settings/preferences table; LoadPlayerJob normalizes missing values to an empty table.
Settings = { Type = "any", Replicate = true, Persist = true },

-- @field Cooldowns any
-- Replicate: true, Persist: false
-- Default: {}.
-- Session-only generic cooldown cache for runtime systems; intentionally not saved.
Cooldowns = { Type = "any", Replicate = true, Persist = false },

-- @field Revision number
-- Replicate: true, Persist: false
-- Default: 0.
-- Session revision counter for live synchronization/versioning and never restored from persistence.
Revision = { Type = "number", Replicate = true, Persist = false },

-- @field DataVersion number
-- Replicate: false, Persist: true
-- Default: 1.
-- Persisted schema version used to detect and backfill older save formats without replicating migration metadata to clients.
DataVersion = { Type = "number", Replicate = false, Persist = true },
},
}
--[=[
	@description Builds the default persistent profile payload for a PlayerEntity. The helper accepts either
	a raw context table or a wrapper with Context, resolves UserId from explicit input or Instance.UserId,
	and fills in starter progression, inventory, ability/talent tables, bindings, quick slots, and runtime
	cooldown mirrors when those values are not already supplied.

	@param params { [any]: any } -- Context table (or wrapper containing Context) with optional persisted profile overrides.
	@return any -- Player profile data table seeded with starter inventory/loadout defaults, persistent progression fields, and session-only runtime caches.
]=]

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
Inventory = context.Inventory or {"1","2","3","4","5","6","7","8","Kama","Gale","Artura","ArturaUnleash","GaleUnleash","KamaUnleash","Shade","ShadeUnleash","Zephyr","ZephyrUnleash" },
BagContents = context.BagContents or {},
Equipped = context.Equipped or {},
WeaponEqp = context.WeaponEqp or "",
LearnedAbilities = context.LearnedAbilities or {},
EquippedAbilities = context.EquippedAbilities or {},
AbilityCooldowns = context.AbilityCooldowns or {},
UnlockedAbilities = context.UnlockedAbilities or {},
TalentSelections = context.TalentSelections or {},
SkillPoints = context.SkillPoints or 0,
StatPoints = context.StatPoints or 0,
Strength = context.Strength or 0,
Agility = context.Agility or 0,
Vitality = context.Vitality or 0,
Endurance = context.Endurance or 0,
Intelligence = context.Intelligence or 0,
Luck = context.Luck or 0,
AbilityBindings = context.AbilityBindings or { Q = "", E = "", R = "", F = "" },
QuickItemSlots = context.QuickItemSlots or {"","","","" },
ActionBar = context.ActionBar or {},
Settings = context.Settings or {},
Cooldowns = context.Cooldowns or {},
Revision = 0,
DataVersion = context.DataVersion or 1,
}
end
--[=[
	@description Intentionally ignores replicated field changes because PlayerEntity is pure data with no
	client-side visual side effects. The method exists only to satisfy the entity interface expected by the
	orchestrator.

	@param _changes { [string]: any } -- Unused change-set payload supplied by the entity replication pipeline.
	@return nil
]=]

function PlayerEntity:ApplyChanges(_changes: { [string]: any })
-- PlayerEntity is pure data — no visual rendering
end

return PlayerEntity
