module Error = Connection__Error

type t = {
  mutable connection: option<Connection.t>,
  mutable connecting: option<promise<result<Connection.t, Error.t>>>,
  mutable pendingRequest: option<promise<result<unit, Error.t>>>,
  mutable spawnCount: int,
}

// Singleton instance to ensure only one Agda process runs at a time.
let instance = {
  connection: None,
  connecting: None,
  pendingRequest: None,
  spawnCount: 0,
}

// Disconnects and destroys the current shared connection.
// Called during "Restart" or when the last Agda document is closed.
let disconnect = async (log) => {
  // Reset the queue so subsequent requests don't wait on old promises
  instance.pendingRequest = None
  instance.connecting = None
  switch instance.connection {
  | Some(conn) =>
    instance.connection = None
    try {
      let _ = await Connection.destroy(Some(conn), log)
    } catch {
    | _ => () // Ignore errors during destruction (e.g. if already destroyed)
    }
    ()
  | None => ()
  }
}

// A task queue that ensures requests are sent to the shared Agda process sequentially.
// This prevents race conditions and interleaved responses when multiple tabs 
// trigger Agda commands simultaneously.
let schedule = (task: unit => promise<result<unit, Error.t>>): promise<result<unit, Error.t>> => {
  let prev = switch instance.pendingRequest {
  | Some(p) => p
  | None => Promise.resolve(Ok())
  }
  
  // Chain the new task after the previous one completes (regardless of its success/failure).
  // This ensures the queue never stalls even if one request fails.
  let next = async () => {
    try {
      let _ = await prev
    } catch {
    | _ => () // ignore previous result
    }
    await task()
  }
  
  let promise = next()
  instance.pendingRequest = Some(promise)
  promise
}

// Gets the existing shared connection or creates a new one if none exists.
// Handles concurrent calls by caching the "connecting" promise to prevent race conditions.
let acquire = async (state: State.t) => {
  switch instance.connection {
  | Some(conn) => Ok(conn)
  | None =>
    switch instance.connecting {
    | Some(promise) => await promise
    | None =>
      let promise = Connection.makeWithFallback(
        state.platformDeps,
        state.memento,
        state.globalStorageUri,
        Config.Connection.getAgdaPaths(),
        ["als", "agda"],
        state.channels.log,
      )
      instance.connecting = Some(promise)
      let result = await promise
      instance.connecting = None
      
      switch result {
      | Ok(conn) =>
        instance.spawnCount = instance.spawnCount + 1
        instance.connection = Some(conn)
        Ok(conn)
      | Error(e) => Error(e)
      }
    }
  }
}

// Helper to retrieve the Agda version string from the currently active shared connection.
let getAgdaVersion = () =>
  switch instance.connection {
  | Some(Agda(_, _, version)) => Some(version)
  | Some(ALS(_, _, Some((_alsVersion, agdaVersion, _lspOptions)))) => Some(agdaVersion)
  | _ => None
  }

// Forces a connection switch (used by the Switch Version UI).
// Tears down the existing process and establishes a new one.
let switchConnection = async (state: State.t, path: string) => {
  // destroy old
  await disconnect(state.channels.log)
  
  // create new
  switch await Connection.make(path) {
  | Ok(conn) =>
    instance.spawnCount = instance.spawnCount + 1
    instance.connection = Some(conn)
    Ok(conn)
  | Error(e) => Error(Error.Establish(e))
  }
}

let getConnection = () => instance.connection

// For testing only
let getSpawnCount = () => instance.spawnCount
let resetSpawnCount = () => instance.spawnCount = 0
