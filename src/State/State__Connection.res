let sendRequest = async (
  state: State.t,
  handleResponse: Response.t => promise<unit>,
  request: Request.t,
): unit => {
  let sendRequestAndHandleResponses = async (
    connection,
    state: State.t,
    request,
    handler: Response.t => promise<unit>,
  ) => {
    let onResponse = async response => {
      await handler(response)
      state.channels.log->Chan.emit(ResponseHandled(response))
    }

    state.channels.log->Chan.emit(RequestSent(request))
    // only resolve the promise after:
    //  1. the result of connection has been displayed
    //  2. all responses have been handled
    switch await Connection.sendRequest(connection, state.document, request, onResponse) {
    | Error(error) => await State__View.Panel.displayConnectionError(state, error)
    | Ok() =>
      // display the connection state
      await State__View.Panel.displayConnectionStatus(state, Some(connection))
    }
  }

  // Schedule the request on the global queue to ensure that requests from
  // different tabs are sent to the shared Agda process sequentially.
  let _ = await Connection__Manager.schedule(async () => {
    switch await Connection__Manager.acquire(state) {
    | Error(error) => 
      await State__View.Panel.displayConnectionError(state, error)
      Error(error)
    | Ok(connection) =>
      await sendRequestAndHandleResponses(connection, state, request, handleResponse)
      Ok()
    }
  })
}

// like `sendRequest` but collects all responses, for testing
let sendRequestAndCollectResponses = async (state: State.t, request: Request.t): array<
  Response.t,
> => {
  let responses = ref([])
  let responseHandler = async response => {
    responses.contents->Array.push(response)
  }
  await state->sendRequest(responseHandler, request)
  responses.contents
}