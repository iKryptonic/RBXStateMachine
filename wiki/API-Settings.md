# API: Settings & Configuration

Dynamic configuration for the framework's internal systems.

---

## ⚡ Scheduler Settings
| Key | Default | Description |
| :--- | :--- | :--- |
| `FrameBudget` | `0.015` | Max task time per frame (seconds). |
| `WarnOnLongThreadExecutions`| `true` | Log overhead warnings. |

## 💾 DataStore Settings
| Key | Default | Description |
| :--- | :--- | :--- |
| `DataStoreName` | `"EntityPersistence"` | Root store name. |
| `KeyPrefix` | `"Entity"` | Pre-pended to all keys. |

## 📡 Remote Names
*   `EntityUpdateRemoteName`: `"EntityUpdateRemote"`
*   `EntityCommandRemoteName`: `"EntityCommandRemote"`

---

## 🛠️ Application
Change these on the `shared.FSM.Settings` table before initialization.
