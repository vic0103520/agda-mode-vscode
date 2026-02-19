# Specification: Window-scoped Connection Sharing

This document outlines the design and implementation for sharing a single Agda connection across all Agda files within a single VS Code window (Workspace).

## 1. Problem: Redundant Connections
Previously, the extension spawned a dedicated Agda or Agda Language Server (ALS) process for every unique Agda file opened. This led to inefficient resource utilization and redundant type-checking of dependencies.
- **Per-File Registry**: `src/Registry.res` maintained a dictionary keyed by file path, treating every file as an isolated entity.
- **State-Owned Connections**: `src/State/State.res` previously defined the connection as a mutable field within the per-file `State.t`.
- **Process Spawning**: `src/Connection/Transport/Connection__Transport__Process.res` executed a new OS process for every connection.

## 2. Reference: Emacs `agda2-mode.el`
The original Emacs `agda-mode` implements a centralized, global process model where all buffers share a single Agda instance per Emacs session.
- **Global Process Variables**: Uses global variables to ensure a singleton process.
- **Ownership Lock**: Implements a strict locking mechanism to prevent concurrent buffer interference.

## 3. Implemented Solution: Window-scoped Singleton
We implemented a single, global `Connection.t` shared by all `State.t` instances within the VS Code window. This provides the efficiency of Emacs while maintaining VS Code's window-level isolation.

### A. Connection Registry (`src/Registry__Connection.res`)
A singleton manager handles the `Connection.t` lifecycle using a state machine: `Empty | Connecting | Active | Closing`.

**Atomic Transitions via Event Loop:**
Transitions from `Empty` to `Connecting` are atomic because the state update occurs synchronously before the first `await` in the acquisition flow. The ReScript/JavaScript single-threaded event loop guarantees that subsequent callers will see the `Connecting` state and wait on the established promise, preventing redundant process spawning.

**Implemented Resource Structure:**
```rescript
module Resource = {
  type t = {
    connection: Connection.t,
    mutable users: Belt.Set.String.t, // Track all State instances (by ID) using the connection
    mutable currentOwnerId: option<ownerId>, // For reentrant locking checks
    mutable queue: promise<unit>,           // Serializes requests from different editors
  }
}

type status =
  | Empty
  | Connecting(promise<result<Connection.t, Connection.Error.t>>)
  | Active(Resource.t)
  | Closing(promise<unit>)
```

### B. Request Serialization & Reentrancy
We use a **Promise-based Request Queue** (`execute` function) to manage access to the shared connection.
- **Top-level Requests**: Commands from different editors wait on `resource.queue`. When a request enters, it appends itself to the queue promise chain.
- **Recursive Requests**: Before waiting, the system checks `resource.currentOwnerId`. If the requesting editor ID matches the current owner, it bypasses the queue for immediate reentrant execution.

### C. Reference Counting & Lifecycle
The global connection is reference-counted via the `users` set.
1.  **Spawned**: On the first `acquire` call. The status transitions to `Connecting`.
2.  **Shared**: Subsequent files waiting during `Connecting` or joining an `Active` state simply add their ID to the `users` set.
3.  **Destroyed**: When `release` is called and the `users` set becomes empty, the connection is destroyed.
4.  **Restart**: Triggered by `shutdown`, which waits for pending operations and then forcefully closes the connection, resetting the state to `Empty`.

### D. Internal Process State & Performance
By sharing a single process, the system benefits from Agda's internal **Module Cache**. 
- Dependencies checked in one file remain in memory, making subsequent loads of other files in the same workspace near-instant.
- The Agda interaction protocol handles per-file context switching by using the absolute file path included in each command.

### E. Robust Cleanup & Testing
- **Synchronous Crash Trapping**: In unit tests, we use "mock" connection objects created via `Obj.magic`. These objects lack the internal structure (like the `chan` property) expected by the real `Connection.destroy` logic.
- **Robust `terminate` Helper**: The destruction logic is wrapped in a synchronous `try...catch` block. This ensures that even if a mock object crashes the destruction logic, the Registry successfully completes its transition to `Empty`, preventing the manager from hanging or leaking state into the next test.
- **Test Isolation**: A global `Async.beforeEach` hook in `test/tests/Test.res` calls `Registry__Connection.shutdown()` before every test to ensure zero state leakage and clean OS process cleanup.

### F. State Refactoring
- **`src/State/State.res`**: The `mutable connection` field was removed. `State.make` now accepts an explicit `id` (the file path) to identify itself to the Registry.
- **`src/State/State__Connection.res`**: Refactored to utilize the Registry's `acquire` and `execute` methods.
