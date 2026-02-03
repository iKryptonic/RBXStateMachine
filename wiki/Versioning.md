# Persistence Versions & Migrations

As your game grows, your Entity Schemas will change. A `Level` property might become `XP`, or a `Inventory` table might change structure. This guide explains how to handle these changes without losing player data.

---

## 📦 The Persistence Envelope

Every save in RBXStateMachine is wrapped in a "Versioned Envelope" before being sent to the DataStore.

**Internal JSON Structure:**
```json
{
    "version": 1,
    "updatedAt": 1706240000,
    "data": { ... your entity fields ... },
    "meta": { ... custom metadata ... }
}
```

The framework currently defaults to `version = 1`. You can leverage this metadata to perform manual migrations.

---

## 🔄 Migration Strategies

### 1. The "Default Value" Strategy (Soft Migration)
The simplest way to handle new fields is to define defaults in your `EntityRegistry`.
*   If a property exists in the Schema but is missing from the loaded data, the framework simply won't overwrite the default value.
*   **Best for**: Adding new features that didn't exist before.

### 2. The Logic-Based Migration (Hard Migration)
If you need to rename or reshape data, perform the logic inside your Entity's `Deserialize` method.

```lua
-- In WarriorEntity.luau
function WarriorEntity:Deserialize(data)
    -- Handle legacy 'Level' field before it gets mapped to 'Experience'
    if data.Level and not data.Experience then
        fsm.Logger:Log({ Level = "INFO", Message = "Migrating legacy level data." })
        data.Experience = data.Level * 1000
        data.Level = nil -- Clean up
    end

    -- Call the base deserializer to apply the cleaned data
    self.Super:Deserialize(data)
end
```

---

## ⚠️ Breaking Changes & Property Deletion

### Property Removal
If you remove a property from your Schema, the framework **automatically drops** that field during the next load.
*   **Safety**: This prevents your proxy from being polluted with "Shadow Data" that is no longer valid.
*   **Caution**: The data is still in the DataStore until the next `Save()` call. If you accidentally remove a property, restore it immediately to recover the data.

### Type Changes
If you change a property from `Type = "number"` to `Type = "string"`, the `Deserialize` call will fail with a **Type Mismatch** error.
*   **Solution**: You MUST intercept these changes in your implementation's `Deserialize` override and convert the types manually before calling the base method.

---

## 🛠️ Direct Database Patching

If you need to update thousands of records without waiting for players to log in, use the `Orchestrator.Persistence:Update()` method. It performs a transactional `UpdateAsync` on the raw DataStore.

```lua
-- Global script to fix a bug in 'Mana' calculation
Orchestrator.Persistence:Update("Player_12345", function(oldData)
    if oldData.Mana < 0 then
        oldData.Mana = 100
    end
    return oldData
end)
```
