module Error = Connection__Error

type t = {
  mutable connection: option<Connection.t>,
  mutable pendingRequest: option<promise<result<unit, Error.t>>>,
}

// Singleton instance to ensure only one Agda process runs at a time
let instance = {
  connection: None,
  pendingRequest: None,
}

// Disconnects and destroys the current connection
let disconnect = async (log) => {
  instance.pendingRequest = None
  switch instance.connection {
  | Some(conn) =>
    let _ = await Connection.destroy(Some(conn), log)
    instance.connection = None
  | None => ()
  }
}

// A task queue that ensures requests are sent to Agda sequentially.
// This prevents race conditions where multiple tabs might try to talk to the same process simultaneously.
let schedule = (task: unit => promise<result<unit, Error.t>>): promise<result<unit, Error.t>> => {
  let prev = switch instance.pendingRequest {
  | Some(p) => p
  | None => Promise.resolve(Ok())
  }
  
  // Chain the new task after the previous one completes (regardless of success/failure)
  let next = async () => {
    try {
      let _ = await prev
    } catch {
    | _ => () // ignore previous errors so the queue doesn't stall
    }
    await task()
  }
  
  let promise = next()
  instance.pendingRequest = Some(promise)
  promise
}

// Gets the existing connection or creates a new one if none exists.
// Shared by all State instances.
let acquire = async (state: State.t) => {
  switch instance.connection {
  | Some(conn) => Ok(conn)
  | None =>
    let result = await Connection.makeWithFallback(
      state.platformDeps,
      state.memento,
      state.globalStorageUri,
      Config.Connection.getAgdaPaths(),
      ["als", "agda"],
      state.channels.log,
    )
    switch result {
    | Ok(conn) =>
      instance.connection = Some(conn)
      Ok(conn)
    | Error(e) => Error(e)
    }
  }
}

// Helper to get version from the active connection
let getAgdaVersion = () =>
  switch instance.connection {
  | Some(Agda(_, _, version)) => Some(version)
  | Some(ALS(_, _, Some((_alsVersion, agdaVersion, _lspOptions)))) => Some(agdaVersion)
  | _ => None
  }

// Global switch version: tears down the old process and starts a new one
let switchConnection = async (state: State.t, path: string) => {
  // destroy old
  await disconnect(state.channels.log)
  
  // create new
  switch await Connection.make(path) {
  | Ok(conn) =>
    instance.connection = Some(conn)
    Ok(conn)
  | Error(e) => Error(e)
  }
}

let getConnection = () => instance.connection