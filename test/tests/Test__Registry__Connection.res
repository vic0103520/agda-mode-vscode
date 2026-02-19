open Mocha
open Test__Util

let setup = async () => {
  // Reset the singleton status for testing
  await Registry__Connection.shutdown()
}

// Helper to count running agda processes specifically spawned by this test runner
let countChildAgdaProcesses = async () => {
  let myPid = %raw("process.pid")
  let command = OS.onUnix 
    ? "pgrep -P " ++ string_of_int(myPid) ++ " -f agda | wc -l" 
    : "wmic process where \"Name='agda.exe' and ParentProcessId=" ++ string_of_int(myPid) ++ "\" get ProcessId /FORMAT:LIST | find /C \"ProcessId\""
  
  let (promise, resolve, _) = Util.Promise_.pending()
  
  NodeJs.ChildProcess.exec(command, (error, stdout, _stderr) => {
    if Js.Nullable.isNullable(error) {
      let output = stdout->NodeJs.Buffer.toString->String.trim
      if output == "" {
        resolve(0)
      } else {
        try {
          resolve(int_of_string(output))
        } catch {
        | _ => resolve(0)
        }
      }
    } else {
      // pgrep/find returns exit code 1 if no matches are found, which Node.js treats as an error.
      // This means 0 processes found.
      resolve(0)
    }
  })->ignore
  await promise
}

describe("Registry__Connection", () => {
  Async.it("Singleton: acquire returns the same connection for different owners", async () => {
    await setup()
    let makeCalled = ref(0)
    let dummyConnection: Connection.t = Obj.magic("dummy-connection")

    let make = async () => {
      makeCalled := makeCalled.contents + 1
      Ok(dummyConnection)
    }

    // Proving that two owners share the same process
    let res1 = await Registry__Connection.acquire("owner1", make)
    let res2 = await Registry__Connection.acquire("owner2", make)

    Assert.deepStrictEqual(res1, Ok(dummyConnection))
    Assert.deepStrictEqual(res2, Ok(dummyConnection))
    Assert.deepStrictEqual(makeCalled.contents, 1)

    let view = Registry__Connection.inspect()
    Assert.deepStrictEqual(view.userCount, 2)
    Assert.deepStrictEqual(view.status, "Active")
  })

  Async.it("Serialization: concurrent execution is queued", async () => {
    await setup()
    let dummyConnection: Connection.t = Obj.magic("dummy-connection")
    let make = async () => Ok(dummyConnection)
    let _ = await Registry__Connection.acquire("owner1", make)

    let executionOrder = []
    let task1 = async _ => {
      executionOrder->Array.push("task1-start")
      await Util.Promise_.setTimeout(50)
      executionOrder->Array.push("task1-end")
      Ok()
    }
    let task2 = async _ => {
      executionOrder->Array.push("task2-start")
      Ok()
    }

    // Proving that if we call execute twice, the second waits for the first
    let p1 = Registry__Connection.execute("owner1", task1)
    let p2 = Registry__Connection.execute("owner2", task2)

    let _ = await p1
    let _ = await p2

    // Verify that task2 started after task1 ended
    Assert.deepStrictEqual(executionOrder, ["task1-start", "task1-end", "task2-start"])
  })

  Async.it("Reentrancy: nested execution from same owner is allowed", async () => {
    await setup()
    let dummyConnection: Connection.t = Obj.magic("dummy-connection")
    let make = async () => Ok(dummyConnection)
    let _ = await Registry__Connection.acquire("owner1", make)

    let executionOrder = []
    let task = async _ => {
      executionOrder->Array.push("outer-start")
      // Nested call from same owner
      let _ = await Registry__Connection.execute("owner1", async _ => {
        executionOrder->Array.push("inner")
        Ok()
      })
      executionOrder->Array.push("outer-end")
      Ok()
    }

    // Proving that an owner already holding the lock can execute again without blocking
    let _ = await Registry__Connection.execute("owner1", task)

    Assert.deepStrictEqual(executionOrder, ["outer-start", "inner", "outer-end"])
  })

  Async.it("Reference Counting: connection is destroyed only when all users release it", async () => {
    await setup()
    let dummyConnection: Connection.t = Obj.magic("dummy-connection")
    let make = async () => Ok(dummyConnection)

    let _ = await Registry__Connection.acquire("owner1", make)
    let _ = await Registry__Connection.acquire("owner2", make)

    Assert.deepStrictEqual(Registry__Connection.inspect().userCount, 2)

    // Proving that status moves to Empty only after last user releases
    await Registry__Connection.release("owner1")
    Assert.deepStrictEqual(Registry__Connection.inspect().userCount, 1)
    Assert.deepStrictEqual(Registry__Connection.inspect().status, "Active")

    await Registry__Connection.release("owner2")
    Assert.deepStrictEqual(Registry__Connection.inspect().status, "Empty")
  })

  describe("Real-world Scenario", () => {
    This.timeout(30000)

    Async.it("should share a single OS process between two different Agda files", async () => {
      await setup()
      
      // Initial state: 0 processes spawned by this test
      let initialCount = await countChildAgdaProcesses()
      Assert.strictEqual(initialCount, 0)
      
      // Load first file
      let agdaA = await AgdaMode.makeAndLoad("GotoDefinition.agda")
      let count1 = await countChildAgdaProcesses()
      Assert.strictEqual(count1, 1)
      
      // Load second file
      let agdaB = await AgdaMode.makeAndLoad("Lib.agda")
      let count2 = await countChildAgdaProcesses()
      
      // VERIFY: The second file should reuse the exact same process (count stays 1)
      Assert.strictEqual(count2, 1)
      
      // Verify registry
      let view = Registry__Connection.inspect()
      Assert.deepStrictEqual(view.userCount, 2)
      Assert.deepStrictEqual(view.status, "Active")

      // Cleanup
      await AgdaMode.quit(agdaA)
      await AgdaMode.quit(agdaB)
      
      // Verify clean termination
      let finalCount = await countChildAgdaProcesses()
      Assert.strictEqual(finalCount, 0)
    })
  })
})
