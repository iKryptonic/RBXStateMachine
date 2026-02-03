# API: Scheduler

The **Scheduler** is a high-performance, frame-budgeted task manager. It ensures your game logic runs efficiently without overwhelming the CPU.

---

## 🔧 Core Methods

### `Schedule(params)`
*   **Summary**: Adds a task to the priority queue.
*   **Parameters**:
    *   `TaskName` (string): Unique identifier.
    *   `TaskAction` (function): The code to run.
    *   `TaskExecutionDelay` (number?): Wait time before first run.
    *   `IsRecurringTask` (boolean?): If true, repeats after `Delay`.
    *   `Priority` (number?): Execution importance (Higher = Higher Priority).
    *   `Event` (string?): RunService event (Heartbeat, Stepped, RenderStepped).
*   **Return**: `Task?`

### `Deschedule(name)`
*   **Summary**: Removes a pending task from the queue by its name.

### `ExecuteTask(taskOrName)`
*   **Summary**: Runs a task **immediately and synchronously**, bypassing the frame budget. 
*   **Warning**: Use only for high-priority user input or critical frame-start logic.

---

## ⚙️ Administration & Sync

### `Initialize(settings?)`
*   **Summary**: Configures the scheduler's [Performance Management](API-Settings#scheduler-settings).

### `GetSyncData()`
*   **Layer**: Server-Only
*   **Summary**: Returns a serialized snapshot of all active tasks, history, and performance histograms for the [ServiceManager](API-Orchestrator).

### `ExposeAPI()`
*   **Layer**: Server-Only
*   **Summary**: Creates the `SchedulerClientFunction` RemoteFunction and begins listening for authorized remote commands (e.g., from the Debug Console).

---

## 📊 Performance Tracking

### `ResetTask(name)`
*   **Summary**: Zeroes out the execution time and run count data for a specific task.

### `GetTaskCount()`
*   **Summary**: Returns the number of currently tracked tasks in the heap.

---

## 📋 Full Method Inventory

| Method | Role |
| :--- | :--- |
| `Start()` | Connects the scheduler to RunService signals. |
| `Step(eventName)`| Internal entry point for the frame-budgeting loop. |
| `Clear()` | Resets the scheduler entirely. |
| `CheckAdmin(player)`| Authorization logic for the remote API. |

> [!NOTE]
> **Aging Logic**: The Scheduler uses an internal `ConsecutiveDelays` counter. If a task is skipped due to budget, its "Effective Priority" increases, ensuring it eventually runs regardless of its base Priority.
