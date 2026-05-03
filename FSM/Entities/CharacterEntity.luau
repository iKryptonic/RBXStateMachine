--!strict
--[=[
    @Name CharacterEntity
    @Description Ephemeral in-world combat entity for an active character spawn. It mirrors runtime
    health/resources, equipment hands, movement/combat locks, and animation-observable state.

    Schema Fields:
    - PlayerEntityId: string (Replicate: true, Persist: false) -- Link back to the owning PlayerEntity.
    - UserId: number (Replicate: true, Persist: false) -- Runtime owner user id.
    - Health: number (Replicate: true, Persist: false) -- Current health value.
    - MaxHealth: number (Replicate: true, Persist: false) -- Derived health cap.
    - Stamina: number (Replicate: true, Persist: false) -- Current stamina value.
    - MaxStamina: number (Replicate: true, Persist: false) -- Derived stamina cap.
    - Mana: number (Replicate: true, Persist: false) -- Current mana value.
    - MaxMana: number (Replicate: true, Persist: false) -- Derived mana cap.
    - TargetEntityId: string (Replicate: true, Persist: false) -- Current combat target.
    - IsBlocking: boolean (Replicate: true, Persist: false) -- Block stance flag.
    - CanAnimate: boolean (Replicate: true, Persist: false) -- Master animation enable switch.
    - IsStunned: boolean (Replicate: true, Persist: false) -- Stun crowd-control flag.
    - IsKnocked: boolean (Replicate: true, Persist: false) -- Knockdown/knockback control flag.
    - CanMove: boolean (Replicate: true, Persist: false) -- Movement permission flag.
    - MoveSpeedCap: number (Replicate: true, Persist: false) -- Active walk speed cap.
    - MouseLocked: boolean (Replicate: true, Persist: false) -- Runtime camera/mouse lock preference.
    - EquippedRight: string (Replicate: true, Persist: false) -- Right-hand equipped item id.
    - EquippedLeft: string (Replicate: true, Persist: false) -- Left-hand equipped item id.
    - EquipLock: any (Replicate: false, Persist: false) -- Server-only equip mutation guard payload.
    - CombatLock: boolean (Replicate: false, Persist: false) -- Server-only combat lock flag.
    - CCLock: boolean (Replicate: false, Persist: false) -- Server-only crowd-control lock flag.
    - AbilityCooldowns: any (Replicate: false, Persist: false) -- Server-only cast cooldown state.
    - ActiveStatusEffects: any (Replicate: true, Persist: false) -- Replicated active buff/debuff entries.
    - ActiveCastId: string (Replicate: true, Persist: false) -- Currently executing cast id.
    - ActionSeq: number (Replicate: true, Persist: false) -- Monotonic action replication sequence.
    - RecentActions: any (Replicate: true, Persist: false) -- Recent action payloads for render routing.
    - LocomotionState: string (Replicate: true, Persist: false) -- Client-observed base movement state.
    - ActionOverlay: string (Replicate: true, Persist: false) -- Client-observed overlay/action state.
    - AnimationState: string (Replicate: true, Persist: false) -- High-level animation blend state.
    - SprintIntent: boolean (Replicate: false, Persist: false) -- Local/server sprint request flag.
    - InputMode: string (Replicate: false, Persist: false) -- Current runtime input/combat mode.
    - Instance: any (Replicate: false, Persist: false) -- Live character model reference.

    Used by:
    - LoadPlayerJob and SpawnCharacterJob for creation, spawn reset, and humanoid synchronization.
    - AttackJob, CastFSM, BlockJob, CrowdControlFSM, MovementConstraintJob, and DamageJob for combat state.
    - EquipJob, UnEquipJob, ToggleWeaponJob, and InventoryItemFSM for hand equipment state.
    - LocomotionFSM, ActionFSM, AnimationStateFSM, DashFSM, and render routing for replicated animation observability.

    Lifecycle:
    - Created when a character spawn is prepared and linked to a PlayerEntity.
    - Reset to runtime defaults on each spawn/respawn rather than restored from persistence.
    - Mutated heavily during combat, movement, and status-effect gameplay.
    - Destroyed with the current character or player teardown, then recreated for the next spawn.

    Defaults and Migration:
    - GetContext seeds fresh combat state for a newly spawned character.
    - LoadPlayerJob re-applies canonical defaults to protect against stale runtime state between respawns.
    - No fields persist; migration concerns are about spawn reset consistency rather than save format upgrades.
]=]

local RunService = game:GetService("RunService")

local CharacterEntity = {
Name = "CharacterEntity",
Mutable = true,
Replication = { Enabled = true, RateLimit = 60 },
Schema = {
-- @field PlayerEntityId string
-- Replicate: true, Persist: false
-- Default: "Player_<UserId>" when absent.
-- Runtime backlink to the owning PlayerEntity so combat and inventory systems can resolve persistent data.
PlayerEntityId = { Type = "string", Replicate = true, Persist = false },

-- @field UserId number
-- Replicate: true, Persist: false
-- Default: 0.
-- Runtime owner id for authorization, entity lookup, and per-player FSM routing.
UserId = { Type = "number", Replicate = true, Persist = false },

-- @field Health number
-- Replicate: true, Persist: false
-- Default: 100.
-- Current health pool for damage, healing, and death handling.
Health = { Type = "number", Replicate = true, Persist = false },

-- @field MaxHealth number
-- Replicate: true, Persist: false
-- Default: 100.
-- Runtime maximum health, later recomputed from stats and passive effects.
MaxHealth = { Type = "number", Replicate = true, Persist = false },

-- @field Stamina number
-- Replicate: true, Persist: false
-- Default: 100.
-- Current stamina resource used by movement/combat systems.
Stamina = { Type = "number", Replicate = true, Persist = false },

-- @field MaxStamina number
-- Replicate: true, Persist: false
-- Default: 100.
-- Runtime stamina cap derived from stats and passives.
MaxStamina = { Type = "number", Replicate = true, Persist = false },

-- @field Mana number
-- Replicate: true, Persist: false
-- Default: 50.
-- Current mana resource used for spell/ability casting.
Mana = { Type = "number", Replicate = true, Persist = false },

-- @field MaxMana number
-- Replicate: true, Persist: false
-- Default: 50.
-- Runtime mana cap derived from stats and passives.
MaxMana = { Type = "number", Replicate = true, Persist = false },

-- @field TargetEntityId string
-- Replicate: true, Persist: false
-- Default: "".
-- Current target entity identifier for combat actions and targeting UI.
TargetEntityId = { Type = "string", Replicate = true, Persist = false },

-- @field IsBlocking boolean
-- Replicate: true, Persist: false
-- Default: false.
-- Indicates whether the character is actively blocking incoming attacks.
IsBlocking = { Type = "boolean", Replicate = true, Persist = false },

-- @field CanAnimate boolean
-- Replicate: true, Persist: false
-- Default: true.
-- Master flag for whether animation systems should currently drive visuals.
CanAnimate = { Type = "boolean", Replicate = true, Persist = false },

-- @field IsStunned boolean
-- Replicate: true, Persist: false
-- Default: false.
-- Crowd-control stun state used by combat and movement restrictions.
IsStunned = { Type = "boolean", Replicate = true, Persist = false },

-- @field IsKnocked boolean
-- Replicate: true, Persist: false
-- Default: false.
-- Knocked/downed state used by crowd-control and animation logic.
IsKnocked = { Type = "boolean", Replicate = true, Persist = false },

-- @field CanMove boolean
-- Replicate: true, Persist: false
-- Default: true.
-- Broad movement allow/deny switch used by several control FSMs.
CanMove = { Type = "boolean", Replicate = true, Persist = false },

-- @field MoveSpeedCap number
-- Replicate: true, Persist: false
-- Default: 16.
-- Active humanoid walk-speed cap manipulated by attack, block, CC, and movement-constraint jobs.
MoveSpeedCap = { Type = "number", Replicate = true, Persist = false },

-- @field MouseLocked boolean
-- Replicate: true, Persist: false
-- Default: true.
-- Runtime camera/mouse lock state typically expected during combat control mode.
MouseLocked = { Type = "boolean", Replicate = true, Persist = false },

-- @field EquippedRight string
-- Replicate: true, Persist: false
-- Default: "".
-- Right-hand equipped item id mirrored for combat checks and visual equip replication.
EquippedRight = { Type = "string", Replicate = true, Persist = false },

-- @field EquippedLeft string
-- Replicate: true, Persist: false
-- Default: "".
-- Left-hand equipped item id mirrored for dual-wield checks and visual equip replication.
EquippedLeft = { Type = "string", Replicate = true, Persist = false },

-- @field EquipLock any
-- Replicate: false, Persist: false
-- Default: {}.
-- Server-only lock payload guarding equip mutations; intentionally hidden from clients and saves.
EquipLock = { Type = "any", Replicate = false, Persist = false },

-- @field CombatLock boolean
-- Replicate: false, Persist: false
-- Default: false.
-- Server-only guard preventing combat actions while sensitive transitions are in progress.
CombatLock = { Type = "boolean", Replicate = false, Persist = false },

-- @field CCLock boolean
-- Replicate: false, Persist: false
-- Default: false.
-- Server-only crowd-control lock used while CC state changes are being applied.
CCLock = { Type = "boolean", Replicate = false, Persist = false },

-- @field AbilityCooldowns any
-- Replicate: false, Persist: false
-- Default: {}.
-- Authoritative server-only cast cooldown table used by CastFSM; not replicated because it is enforcement state.
AbilityCooldowns = { Type = "any", Replicate = false, Persist = false },

-- @field ActiveStatusEffects any
-- Replicate: true, Persist: false
-- Default: {}.
-- Replicated active buff/debuff list read by status, damage, and UI/FX systems.
ActiveStatusEffects = { Type = "any", Replicate = true, Persist = false },

-- @field ActiveCastId string
-- Replicate: true, Persist: false
-- Default: "".
-- Currently executing cast definition id so animation/UI systems can observe active abilities.
ActiveCastId = { Type = "string", Replicate = true, Persist = false },

-- @field ActionSeq number
-- Replicate: true, Persist: false
-- Default: 0.
-- Monotonic sequence number paired with RecentActions so clients can process action batches in order.
ActionSeq = { Type = "number", Replicate = true, Persist = false },

-- @field RecentActions any
-- Replicate: true, Persist: false
-- Default: {}.
-- Recently emitted action payloads consumed by the client render router for remote animation/effect playback.
RecentActions = { Type = "any", Replicate = true, Persist = false },

-- @field LocomotionState string
-- Replicate: true, Persist: false
-- Default: "Idle".
-- Client-derived base locomotion label written by LocomotionFSM for remote animation decisions.
LocomotionState = { Type = "string", Replicate = true, Persist = false },

-- @field ActionOverlay string
-- Replicate: true, Persist: false
-- Default: "None".
-- Client-observable overlay label written by ActionFSM/DashFSM/InputFSM for action-layer animation playback.
ActionOverlay = { Type = "string", Replicate = true, Persist = false },

-- @field AnimationState string
-- Replicate: true, Persist: false
-- Default: "Idle".
-- High-level animation blend state written by AnimationStateFSM for remote render orchestration.
AnimationState = { Type = "string", Replicate = true, Persist = false },

-- @field SprintIntent boolean
-- Replicate: false, Persist: false
-- Default: false.
-- Runtime sprint request flag used for local/server decision-making without replicating raw input intent.
SprintIntent = { Type = "boolean", Replicate = false, Persist = false },

-- @field InputMode string
-- Replicate: false, Persist: false
-- Default: "Combat".
-- Runtime input mode label used to interpret local commands and overlays.
InputMode = { Type = "string", Replicate = false, Persist = false },

-- @field Instance any
-- Replicate: false, Persist: false
-- Default: assigned later via SetContext during spawn setup.
-- Live character model reference used for humanoid synchronization and client-side ApplyChanges handling.
Instance = { Type = "any", Replicate = false, Persist = false },
},
}
--[=[
	@description Builds the default runtime state for a freshly spawned CharacterEntity. The helper accepts
	either a raw context table or a wrapper with Context, derives UserId and PlayerEntityId when missing,
	and seeds combat resources, equipment state, locks, action replication fields, and animation labels to
	their spawn-time defaults.

	@param params { [any]: any } -- Context table (or wrapper containing Context) with optional UserId and PlayerEntityId overrides.
	@return any -- New character-entity data table containing baseline health, stamina, mana, locks, equipment, recent-action state, and animation fields.
]=]

function CharacterEntity:GetContext(params: { [any]: any })
local context = params.Context or params
local userId = context.UserId or 0
local playerEntityId = context.PlayerEntityId or ("Player_" .. tostring(userId))

return {
PlayerEntityId = playerEntityId,
UserId = userId,
Health = 100,
MaxHealth = 100,
Stamina = 100,
MaxStamina = 100,
Mana = 50,
MaxMana = 50,
TargetEntityId = "",
IsBlocking = false,
CanAnimate = true,
IsStunned = false,
IsKnocked = false,
CanMove = true,
MoveSpeedCap = 16,
MouseLocked = true,
EquippedRight = "",
EquippedLeft = "",
EquipLock = {},
CombatLock = false,
CCLock = false,
AbilityCooldowns = {},
ActiveStatusEffects = {},
ActiveCastId = "",
ActionSeq = 0,
RecentActions = {},
LocomotionState = "Idle",
ActionOverlay = "None",
AnimationState = "Idle",
SprintIntent = false,
InputMode = "Combat",
}
end
--[=[
	@description Applies replicated CharacterEntity deltas on the client by forwarding them into local
	rendering systems. RecentActions/ActionSeq changes are sent to the render router, equipment changes
	trigger equip-visual updates, and MoveSpeedCap updates are mirrored onto the live humanoid WalkSpeed.
	The method is a no-op on the server.

	@param changes { [string]: any } -- Replicated field changes that may affect action rendering, equip visuals, or local humanoid speed.
	@return nil
	@reads self._renderRouter, self.RecentActions, self.ActionSeq, self.Instance
	@writes humanoid.WalkSpeed on the client when MoveSpeedCap changes
]=]

function CharacterEntity:ApplyChanges(changes: { [string]: any })
if not RunService:IsClient() then
return
end

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

if changes.MoveSpeedCap ~= nil then
local character = self.Instance
if character then
local humanoid = character:FindFirstChildOfClass("Humanoid")
if humanoid then
humanoid.WalkSpeed = changes.MoveSpeedCap
end
end
end
end

return CharacterEntity