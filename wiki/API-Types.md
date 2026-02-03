# API: Types

Derived from the in-repo cheatsheet (`FSM/README.md`).

## 🧾 Types

`Types.luau` exports type aliases/interfaces only (no runtime functions). It’s the source-of-truth for the shapes referenced above (e.g. `PropertyDef`, `Task`, `ScheduleTaskParams`, `PersistenceConfig`, `EntityPersistence`).

If you’re using `--!strict`, prefer importing Types in your own modules when you want autocomplete/type safety for schemas, scheduler tasks, or persistence configs.
