# API: Logger

Derived from the in-repo cheatsheet (`FSM/README.md`).

## 🪵 Logger

Structured logging with in-memory history.

Use `Logger` when you want consistent logs that can be queried later (in tests, dev tooling, or live debugging). Most components in this package use logging to explain why an operation failed (invalid state transition, schema mismatch, lock errors, etc.).

Tip: use `OperationId` to correlate logs across multiple calls (e.g. an entity ID or job ID).

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(params: { Name: string? }): Logger` | Creates a new logger instance. |
| `Log` | `(params: { Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string, OperationId: string?, Data: any? }): ()` | Records a log entry. |
| `GetHistory` | `(): table` | Returns the recent log history. |
