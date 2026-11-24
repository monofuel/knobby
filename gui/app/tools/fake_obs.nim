import
  std/[asyncdispatch, asynchttpserver, base64, json, monotimes, net, os, tables, times],
  crunchy, ws

const
  FakeSalt = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="
  FakeChallenge = "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="
  AuthFailedClose = "\x0f\xa9Authentication failed."
  AcceptPauseMs = 10
  PumpPollMs = 5
  UnknownRequestCode = 204
  ResourceNotFoundCode = 600
  OutputRunningCode = 500
  OutputNotRunningCode = 501
  SuccessCode = 100

type
  FakeCollection* = object
    ## Scenes, inputs, and program scene stored by one fake scene collection.
    scenes*: seq[string]
    inputs*: seq[tuple[name, kind: string]]
    programScene*: string

  FakeOverride* = proc (socket: WebSocket, requestType, requestId: string,
    data: JsonNode): Future[bool] {.gcsafe.}

  FakeObs* = ref object
    password*: string
    port*: int
    server: AsyncHttpServer
    sockets*: seq[WebSocket]
    identifies*: int
    rejectedIdentifies*: int
    requests*: seq[string]
    requestData*: seq[JsonNode]
    silent*: seq[string]
    hangupOn*: seq[string]
    override*: FakeOverride
    profile*, collection*, programScene*: string
    recordDirectories*: Table[string, string]
    persistentData*: Table[string, JsonNode]
    profiles*, collections*: seq[string]
    stored*: Table[string, FakeCollection]
    scenes*: seq[string]
    inputs*: seq[tuple[name, kind: string]]
    recording*, paused*, streaming*, reconnecting*, micMuted*: bool
    settings*: Table[string, JsonNode]
    items*: Table[string, JsonNode]
    stopped: bool

proc expectedAuth(password: string): string =
  ## Compute the OBS WebSocket 5 authentication string for the fake challenge.
  let secret = base64.encode(sha256(password & FakeSalt))
  base64.encode(sha256(secret & FakeChallenge))

proc sendOp*(socket: WebSocket, op: int, data: JsonNode) {.async.} =
  ## Send one OBS protocol message.
  await socket.send($(%*{"op": op, "d": data}))

proc respond*(socket: WebSocket, requestType, requestId: string,
    data: JsonNode = nil, ok = true, code = SuccessCode, comment = "") {.async.} =
  ## Send a RequestResponse.
  var payload = %*{
    "requestType": requestType,
    "requestId": requestId,
    "requestStatus": {"result": ok, "code": code}
  }
  if comment.len > 0:
    payload["requestStatus"]["comment"] = %comment
  if data != nil:
    payload["responseData"] = data
  await socket.sendOp(7, payload)

proc sendEvent*(socket: WebSocket, eventType: string, data: JsonNode) {.async.} =
  ## Send one OBS event.
  await socket.sendOp(5, %*{"eventType": eventType, "eventIntent": 1,
    "eventData": data})

proc broadcast*(fake: FakeObs, eventType: string, data: JsonNode) {.async.} =
  ## Send an event to every open connection.
  for socket in fake.sockets:
    if socket.readyState == Open:
      await socket.sendEvent(eventType, data)

proc hasInput(fake: FakeObs, name: string): bool =
  ## Check whether the fake collection has an input.
  for input in fake.inputs:
    if input.name == name:
      return true

proc kindOf(fake: FakeObs, name: string): string =
  ## Return an input kind.
  for input in fake.inputs:
    if input.name == name:
      return input.kind

proc recordEvent(fake: FakeObs, active: bool, state: string) {.async.} =
  ## Broadcast a RecordStateChanged event.
  await fake.broadcast("RecordStateChanged", %*{"outputActive": active,
    "outputState": "OBS_WEBSOCKET_OUTPUT_" & state, "outputPath": nil})

proc handleRequest(fake: FakeObs, socket: WebSocket, requestType,
    requestId: string, data: JsonNode) {.async.} =
  ## Answer a request against the fake OBS state.
  template ok(response: JsonNode = nil) =
    await socket.respond(requestType, requestId, response)
  template fail(code: int, comment: string) =
    await socket.respond(requestType, requestId, nil, false, code, comment)
  let inputName = data{"inputName"}.getStr()
  case requestType
  of "GetVersion":
    ok(%*{"obsVersion": "32.1.2", "obsWebSocketVersion": "5.7.3", "rpcVersion": 1})
  of "GetProfileList":
    ok(%*{"currentProfileName": fake.profile, "profiles": fake.profiles})
  of "GetRecordDirectory":
    ok(%*{"recordDirectory": fake.recordDirectories.getOrDefault(fake.profile, "/recordings")})
  of "SetRecordDirectory":
    if fake.recording:
      fail(500, "Recording is active.")
    else:
      fake.recordDirectories[fake.profile] = data["recordDirectory"].getStr()
      ok()
  of "GetPersistentData":
    ok(%*{"slotValue": fake.persistentData.getOrDefault(fake.profile & data["slotName"].getStr(), newJNull())})
  of "SetPersistentData":
    fake.persistentData[fake.profile & data["slotName"].getStr()] = data["slotValue"]
    ok()
  of "GetSceneCollectionList":
    ok(%*{"currentSceneCollectionName": fake.collection,
      "sceneCollections": fake.collections})
  of "GetSceneList":
    var scenes = newJArray()
    for scene in fake.scenes:
      scenes.add(%*{"sceneName": scene})
    ok(%*{"currentProgramSceneName": fake.programScene, "scenes": scenes})
  of "GetCurrentProgramScene":
    ok(%*{"currentProgramSceneName": fake.programScene,
      "sceneName": fake.programScene})
  of "SetCurrentProgramScene":
    if data{"sceneName"}.getStr() notin fake.scenes:
      fail(ResourceNotFoundCode, "No scene was found.")
    else:
      fake.programScene = data{"sceneName"}.getStr()
      ok()
      await fake.broadcast("CurrentProgramSceneChanged", %*{"sceneName": fake.programScene})
  of "SetCurrentProfile":
    let profile = data{"profileName"}.getStr()
    if profile notin fake.profiles:
      fail(ResourceNotFoundCode, "No profile was found.")
    else:
      await fake.broadcast("CurrentProfileChanging", %*{"profileName": fake.profile})
      fake.profile = profile
      ok()
      await fake.broadcast("CurrentProfileChanged", %*{"profileName": profile})
  of "SetCurrentSceneCollection":
    let collection = data{"sceneCollectionName"}.getStr()
    if collection notin fake.collections:
      fail(ResourceNotFoundCode, "No scene collection was found.")
    else:
      await fake.broadcast("CurrentSceneCollectionChanging",
        %*{"sceneCollectionName": fake.collection})
      let previous = FakeCollection(scenes: fake.scenes, inputs: fake.inputs,
        programScene: fake.programScene)
      # Unstored collections keep the current content, matching tests that edit fields directly.
      if collection in fake.stored:
        let next = fake.stored[collection]
        fake.scenes = next.scenes
        fake.inputs = next.inputs
        fake.programScene = next.programScene
      fake.stored[fake.collection] = previous
      fake.collection = collection
      ok()
      await fake.broadcast("CurrentSceneCollectionChanged",
        %*{"sceneCollectionName": collection})
  of "GetInputList":
    var inputs = newJArray()
    for input in fake.inputs:
      inputs.add(%*{"inputName": input.name, "inputKind": input.kind})
    ok(%*{"inputs": inputs})
  of "GetRecordStatus":
    ok(%*{"outputActive": fake.recording, "outputPaused": fake.paused})
  of "GetStreamStatus":
    ok(%*{"outputActive": fake.streaming, "outputReconnecting": fake.reconnecting})
  of "GetInputMute":
    if fake.hasInput(inputName):
      ok(%*{"inputMuted": fake.micMuted})
    else:
      fail(ResourceNotFoundCode, "No source was found by the name of `" &
        inputName & "`.")
  of "SetInputMute":
    fake.micMuted = data{"inputMuted"}.getBool()
    ok()
    await fake.broadcast("InputMuteStateChanged",
      %*{"inputName": inputName, "inputMuted": fake.micMuted})
  of "StartRecord":
    if fake.recording:
      fail(OutputRunningCode, "")
    else:
      fake.recording = true
      ok()
      await fake.recordEvent(false, "STARTING")
      await fake.recordEvent(true, "STARTED")
  of "StopRecord":
    if not fake.recording:
      fail(OutputNotRunningCode, "")
    else:
      fake.recording = false
      fake.paused = false
      ok(%*{"outputPath": "/tmp/fake.mkv"})
      await fake.recordEvent(false, "STOPPING")
      await fake.recordEvent(false, "STOPPED")
  of "PauseRecord":
    fake.paused = true
    ok()
    await fake.recordEvent(true, "PAUSED")
  of "ResumeRecord":
    fake.paused = false
    ok()
    await fake.recordEvent(true, "RESUMED")
  of "GetInputSettings":
    ok(%*{"inputSettings": fake.settings.getOrDefault(inputName, newJObject()),
      "inputKind": fake.kindOf(inputName)})
  of "GetInputPropertiesListPropertyItems":
    ok(%*{"propertyItems": fake.items.getOrDefault(inputName, newJArray())})
  of "SetInputSettings":
    var current = fake.settings.getOrDefault(inputName, newJObject())
    for key, value in data{"inputSettings"}:
      current[key] = value
    fake.settings[inputName] = current
    ok()
  else:
    fail(UnknownRequestCode, "Your request type is not valid.")

proc session(fake: FakeObs, request: Request) {.async.} =
  ## Run the OBS handshake and request loop for one connection.
  let socket = await newWebSocket(request, "obswebsocket.json")
  var hello = %*{"obsWebSocketVersion": "5.7.3", "rpcVersion": 1}
  if fake.password.len > 0:
    hello["authentication"] = %*{"challenge": FakeChallenge, "salt": FakeSalt}
  await socket.sendOp(0, hello)
  var identifyText = ""
  try:
    identifyText = await socket.receiveStrPacket()
  except WebSocketError:
    # Clients that cannot authenticate hang up before identifying.
    inc fake.rejectedIdentifies
    return
  let identify = parseJson(identifyText)
  if fake.password.len > 0 and
      identify["d"]{"authentication"}.getStr() != expectedAuth(fake.password):
    inc fake.rejectedIdentifies
    await socket.send(AuthFailedClose, Opcode.Close)
    socket.hangup()
    return
  inc fake.identifies
  fake.sockets.add(socket)
  await socket.sendOp(2, %*{"negotiatedRpcVersion": 1})
  while socket.readyState == Open and not fake.stopped:
    var text = ""
    try:
      text = await socket.receiveStrPacket()
    except WebSocketError:
      break
    if text.len == 0:
      continue
    let
      message = parseJson(text)
      data = message["d"]
      requestType = data["requestType"].getStr()
      requestId = data["requestId"].getStr()
      requestData = data{"requestData"}
    fake.requests.add(requestType)
    fake.requestData.add(requestData)
    if requestType in fake.hangupOn:
      socket.hangup()
    elif requestType in fake.silent:
      discard
    elif fake.override == nil or not await fake.override(socket, requestType,
        requestId, requestData):
      await fake.handleRequest(socket, requestType, requestId,
        if requestData == nil: newJObject() else: requestData)

proc acceptLoop(fake: FakeObs) {.async.} =
  ## Accept HTTP upgrades until stopped.
  proc callback(request: Request) {.async, gcsafe.} =
    await fake.session(request)
  while not fake.stopped:
    if fake.server.shouldAcceptRequest():
      try:
        await fake.server.acceptRequest(callback)
      except CatchableError:
        # Stopping closes the listener underneath a pending accept.
        if not fake.stopped:
          raise
    else:
      await sleepAsync(AcceptPauseMs)

proc newFakeObs*(password = ""): FakeObs =
  ## Start a fake OBS 5 server on a free loopback port with a ready Minecraft workspace,
  ## a stored, complete Firefox Demos profile and scene collection, and a stored WoW
  ## collection. The shared demo profile is absent until a test installs it.
  result = FakeObs(
    password: password,
    server: newAsyncHttpServer(),
    profile: "Minecraft AI Demos",
    collection: "Minecraft AI Demos",
    profiles: @["Minecraft AI Demos", "Firefox Demos", "Untitled"],
    collections: @["Minecraft AI Demos", "Firefox Demos", "WoW Demos", "Untitled"],
    programScene: "Minecraft",
    scenes: @["Minecraft"],
    inputs: @[("Minecraft Video", "xcomposite_input"),
      ("Minecraft Audio", "pipewire_audio_application_capture"),
      ("Commentary", "pulse_input_capture")],
    micMuted: true
  )
  result.stored["Firefox Demos"] = FakeCollection(scenes: @["Firefox"],
    inputs: @[("Firefox Video", "xcomposite_input"),
      ("Firefox Audio", "pipewire_audio_application_capture"),
      ("Commentary", "pulse_input_capture")],
    programScene: "Firefox")
  result.stored["WoW Demos"] = FakeCollection(scenes: @["WoW"],
    inputs: @[("WoW Video", "xcomposite_input"),
      ("WoW Audio", "pipewire_audio_application_capture"),
      ("Commentary", "pulse_input_capture")],
    programScene: "WoW")
  result.stored["Untitled"] = FakeCollection(scenes: @["Scene"], programScene: "Scene")
  result.server.listen(Port(0), "127.0.0.1")
  result.port = result.server.getPort().int
  asyncCheck result.acceptLoop()

proc url*(fake: FakeObs): string =
  ## Return the fake server URL.
  "ws://127.0.0.1:" & $fake.port

proc dropConnections*(fake: FakeObs) =
  ## Hang up every client without a close frame.
  for socket in fake.sockets:
    if socket.readyState != Closed:
      socket.hangup()

proc stop*(fake: FakeObs) =
  ## Stop accepting and drop every connection.
  fake.stopped = true
  fake.dropConnections()
  fake.server.close()

proc count*(fake: FakeObs, requestType: string): int =
  ## Count received requests of one type.
  for received in fake.requests:
    if received == requestType:
      inc result

proc pump*(condition: proc (): bool, timeoutMs = 5000): bool =
  ## Drive the dispatcher until condition holds or the deadline passes.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not condition() and getMonoTime() < deadline:
    if hasPendingOperations(): poll(PumpPollMs) else: sleep(PumpPollMs)
  result = condition()

proc pumpFor*(milliseconds: int) =
  ## Drive the dispatcher for a fixed time.
  discard pump(proc (): bool = false, milliseconds)

proc closedPort*(): int =
  ## Return a loopback port with no listener.
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = socket.getLocalAddr()[1].int
  socket.close()
