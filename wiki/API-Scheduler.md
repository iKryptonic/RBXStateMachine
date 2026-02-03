# API: Scheduler

Derived from the in-repo cheatsheet (`FSM/README.md`).

## ⚡ Scheduler

Frame-budgeted asynchronous task manager with priority-based fairness.

The Scheduler is for “run this function later / repeatedly” work, while keeping frame time stable.

Use it for periodic tasks (datastore resets, cleanup loops, telemetry, batch processing) where you don’t want to accidentally spawn too much work in one frame. It also exposes an admin-gated RemoteFunction API for inspection/control in live sessions (ServiceManager compatibility).

When *not* to use it:

- If you need strict real-time guarantees (e.g. physics-critical work), prefer direct RunService connections.
- If a task must run exactly once at an exact time, consider `task.delay` for simple cases.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(settings: any?): Scheduler` | Creates a new scheduler instance. |
| `Initialize` | `(settings: any?): Scheduler` | Applies settings and returns `self`. |
| `Clear` | `(): ()` | Clears all tasks/heaps/history/stats. |
| `Schedule` | `(params: { TaskName: string, TaskAction: () -> (), TaskExecutionDelay: number?, IsRecurringTask: boolean?, Priority: number?, Event: string?, FetchData: (() -> ())? }): Task?` | Adds a task. |
| `AddToHistory` | `(taskObj: any, status: any, duration: any, err: string?): ()` | Adds an entry to History (best-effort; used by ServiceManager). |
| `Deschedule` | `(name: string): ()` | Cancels a pending task. |
| `GetTask` | `(name: string): Task?` | Retrieves a task by name. |
| `GetTaskCount` | `(): number` | Counts scheduled tasks. |
| `ExecuteTask` | `(taskOrName: string | Task): ()` | Runs a task immediately outside the budget. |
| `GetSyncData` | `(): any` | Returns a serializable snapshot (tasks/logs/settings/history/stats). |
| `CheckAdmin` | `(player: Player): boolean` | (Server) Validates access for admin-only APIs. |
| `ExposeAPI` | `(): ()` | (Server) Installs `SchedulerClientFunction` RemoteFunction. |
| `ResetTask` | `(name: string): ()` | Resets a task's performance counters. |
| `GenerateKey` | `(): string` | Returns a GUID. |
| `Start` | `(): ()` | Connects `Step(...)` to RunService events. |
| `Step` | `(eventName: string?): ()` | Runs due tasks for a given event (frame-budgeted). |

Internal (advanced; used by the scheduler runtime):

- `_internalExecute(t: Task): ()`
- `_heapPush(heap: { Task }, item: Task): ()`
- `_heapPop(heap: { Task }): Task`

### ⚖️ Task Fairness (Aging)

To prevent **Priority Starvation**, the Scheduler implements an aging mechanism:

- **Frame Budget**: Limits task launches to a specific duration.
- **Aging Factor**: Deferred tasks gain an effective priority boost.
- **FIFO tie-breaker**: Same effective priority executes in `NextRun` order.
