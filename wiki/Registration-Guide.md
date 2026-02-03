# Registration Guide

Detailed patterns for defining and loading components.

---

## 🚦 Registry-Implementation Split
The framework separates **What** a component is from **How** it acts.

### The Registry (Interface)
Defines the schema, network rules, and class mapping.
```lua
{ ComponentName = { Schema = { ... } } }
```

### The Implementation (Methods)
Defines the logic.
```lua
local Class = shared.Entity.ComponentName
function Class:ApplyChanges() ... end
```

---

## 🔄 Modes
1.  **Unified**: All classes in a single `*Registry.luau` file.
2.  **Extension**: Calling `.Extend()` directly in an implementation bit.
3.  **Discovery**: Automatic scanning of folders.

> [!WARNING]
> Do not `require` implementation modules manually in your bootstrap. Let the `Orchestrator` discover and require them.
