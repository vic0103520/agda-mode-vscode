open Mocha
open Test__Util

// Mock State.t to satisfy Connection__Manager
let makeMockState = () => {
  let logChannel = Chan.make()
  let channels = {
    State.inputMethod: Chan.make(),
    responseHandled: Chan.make(),
    commandHandled: Chan.make(),
    log: logChannel,
  }
  
  let mockPlatform = Mock.Platform.makeBasic()
  let mockEditor = %raw(`{
    document: { fileName: "test.agda" }
  }`)
  let mockUri = VSCode.Uri.file("/test/path")
  let mockMemento = Memento.make(None)

  State.make(
    mockPlatform,
    channels,
    mockUri, // globalStorageUri
    mockUri, // extensionUri
    mockMemento,
    mockEditor,
    None // semanticTokens
  )
}

describe("Connection Manager Integration", () => {
  This.timeout(10000)
  
  let agdaMockPath = ref("")
  let agdaMockPath2 = ref("")

  Async.before(async () => {
    Config.inTestingMode := true
    // Setup Agda mocks
    agdaMockPath := await Endpoint.Agda.mock(~version="2.6.4", ~name="agda-manager-test")
    agdaMockPath2 := await Endpoint.Agda.mock(~version="2.7.0.1", ~name="agda-manager-test-2")
    
    // Ensure config points to our mock to avoid "agda not found" errors during makeWithFallback
    await Config.Connection.setAgdaPaths(Chan.make(), [agdaMockPath.contents])
  })

  Async.beforeEach(async () => {
    await Connection__Manager.disconnect(Chan.make())
  })

  Async.after(async () => {
    // Cleanup
    if agdaMockPath.contents != "" {
      await Endpoint.Agda.destroy(agdaMockPath.contents)
    }
    if agdaMockPath2.contents != "" {
      await Endpoint.Agda.destroy(agdaMockPath2.contents)
    }
    // Disconnect manager to clean up process
    await Connection__Manager.disconnect(Chan.make())
  })

  Async.it("should share the same connection across multiple states", async () => {
    let state1 = makeMockState()
    let state2 = makeMockState()

    // Acquire connection for state1
    let conn1Result = await Connection__Manager.acquire(state1)
    
    let conn1 = switch conn1Result {
    | Ok(c) => c
    | Error(e) => failwith("Failed to acquire connection 1: " ++ Connection.Error.toString(e)->fst)
    }

    // Acquire connection for state2
    let conn2Result = await Connection__Manager.acquire(state2)

    let conn2 = switch conn2Result {
    | Ok(c) => c
    | Error(e) => failwith("Failed to acquire connection 2: " ++ Connection.Error.toString(e)->fst)
    }

    // Verify identity
    Assert.equal(conn1, conn2)
    
    // Verify it's the expected Agda connection
    switch conn1 {
    | Agda(_, path, _) => Assert.equal(path, agdaMockPath.contents)
    | _ => failwith("Expected Agda connection")
    }
  })

  Async.it("should reconnect if explicitly disconnected", async () => {
    let state = makeMockState()
    
    // Acquire first connection
    let conn1Result = await Connection__Manager.acquire(state)
    let conn1 = switch conn1Result { | Ok(c) => c | Error(_) => failwith("fail") }

    // Explicit disconnect
    await Connection__Manager.disconnect(state.channels.log)

    // Acquire again
    let conn2Result = await Connection__Manager.acquire(state)
    let conn2 = switch conn2Result { | Ok(c) => c | Error(_) => failwith("fail") }

    // Should be different instances now
    Assert.notEqual(conn1, conn2)
  })

  Async.it("should update global connection when switching versions", async () => {
    let state = makeMockState()
    
    // 1. Establish initial connection (v2.6.4)
    let _ = await Connection__Manager.acquire(state)
    
    // 2. Switch to new version (v2.7.0.1)
    let switchResult = await Connection__Manager.switchConnection(state, agdaMockPath2.contents)
    
    let newConn = switch switchResult {
    | Ok(c) => c
    | Error(e) => failwith("Failed to switch: " ++ Connection.Error.toString(Establish(e))->fst)
    }

    // 3. Verify the new connection is active in the manager
    let activeConn = Connection__Manager.getConnection()
    
    Assert.deepStrictEqual(Some(newConn), activeConn)
    
    switch newConn {
    | Agda(_, path, version) => 
        Assert.equal(path, agdaMockPath2.contents)
        Assert.equal(version, "2.7.0.1")
    | _ => failwith("Expected Agda connection")
    }

    // 4. Verify subsequent acquires get the new connection
    let state2 = makeMockState()
    let acquiredResult = await Connection__Manager.acquire(state2)
    
    switch acquiredResult {
    | Ok(acquiredConn) => Assert.equal(acquiredConn, newConn)
    | Error(_) => failwith("Failed to acquire new connection")
    }
  })
})
