import
  std/[asyncdispatch, json, os, strutils, tempfiles],
  ws,
  obs_client, ./fake_obs

const
  Password = "correct horse"

proc expectFailure[T](future: Future[T], timeoutMs = 5000): ref Exception =
  ## Drive a future to failure and return its error.
  doAssert pump(proc (): bool = future.finished, timeoutMs)
  doAssert future.failed, "expected the OBS operation to fail"
  result = future.readError()

proc connected(fake: FakeObs, password = Password,
    onEvent: ObsEventHandler = nil): ObsClient =
  ## Connect a client to the fake server.
  waitFor connectObs(fake.url, password, onEvent)

proc testAuthentication() =
  ## Accept the right password and reject wrong or missing passwords.
  let fake = newFakeObs(Password)
  defer: fake.stop()
  let client = fake.connected()
  doAssert client.isOpen
  doAssert (waitFor client.request("GetVersion"))["rpcVersion"].getInt() == 1
  client.close()
  doAssert not client.isOpen

  let wrong = expectFailure(connectObs(fake.url, "wrong"))
  doAssert wrong of ObsAuthError, wrong.msg
  doAssert "4009" in wrong.msg
  doAssert Password notin wrong.msg

  let missing = expectFailure(connectObs(fake.url, ""))
  doAssert missing of ObsAuthError, missing.msg
  doAssert fake.identifies == 1
  doAssert pump(proc (): bool = fake.rejectedIdentifies == 2)

proc testNoAuthentication() =
  ## Connect to a server without authentication.
  let fake = newFakeObs()
  defer: fake.stop()
  let client = fake.connected("")
  doAssert (waitFor client.request("GetRecordStatus"))["outputActive"].getBool() == false
  client.close()

proc testRefused() =
  ## Report a missing server as a connection error.
  let error = expectFailure(connectObs("ws://127.0.0.1:" & $closedPort(), ""))
  doAssert error of ObsConnectionError, error.msg

proc testOutOfOrderAndEvents() =
  ## Match responses by id regardless of order and deliver interleaved events.
  let fake = newFakeObs(Password)
  defer: fake.stop()
  var
    heldId = ""
    events: seq[string]
  fake.override = proc (socket: WebSocket, requestType, requestId: string,
      data: JsonNode): Future[bool] {.async, gcsafe.} =
    if requestType == "First":
      heldId = requestId
      result = true
    elif requestType == "Second":
      await socket.sendEvent("CurrentProfileChanged", %*{"profileName": "x"})
      await socket.respond("Second", requestId, %*{"value": 2})
      await socket.respond("First", heldId, %*{"value": 1})
      await socket.respond("Ghost", "999", %*{"value": 3})
      result = true
  let client = fake.connected(onEvent = proc (eventType: string,
      data: JsonNode) {.closure, gcsafe.} =
    events.add(eventType & ":" & data{"profileName"}.getStr()))
  let
    first = client.request("First")
    second = client.request("Second")
  doAssert pump(proc (): bool = first.finished and second.finished)
  doAssert first.read()["value"].getInt() == 1
  doAssert second.read()["value"].getInt() == 2
  doAssert events == @["CurrentProfileChanged:x"]
  doAssert client.isOpen
  client.close()

proc testRequestFailure() =
  ## Raise a typed error carrying the OBS status code.
  let fake = newFakeObs(Password)
  defer: fake.stop()
  let client = fake.connected()
  let error = expectFailure(client.request("NoSuchRequest"))
  doAssert error of ObsRequestError
  doAssert (ref ObsRequestError)(error).code == 204
  doAssert (ref ObsRequestError)(error).requestType == "NoSuchRequest"
  doAssert client.isOpen
  client.close()

proc testTimeout() =
  ## Bound unanswered requests and ignore their late responses.
  let fake = newFakeObs(Password)
  defer: fake.stop()
  var lateSocket: WebSocket
  var lateId = ""
  fake.override = proc (socket: WebSocket, requestType, requestId: string,
      data: JsonNode): Future[bool] {.async, gcsafe.} =
    if requestType == "Slow":
      lateSocket = socket
      lateId = requestId
      result = true
  let client = fake.connected()
  let error = expectFailure(client.request("Slow"), ObsRequestTimeoutMs + 2000)
  doAssert error of ObsTimeoutError, error.msg
  waitFor lateSocket.respond("Slow", lateId, %*{"late": true})
  doAssert (waitFor client.request("GetVersion"))["rpcVersion"].getInt() == 1
  doAssert client.isOpen
  client.close()

proc testDisconnectWithoutReplay() =
  ## Fail in-flight and later requests on disconnect, never resending them.
  let fake = newFakeObs(Password)
  defer: fake.stop()
  fake.hangupOn = @["StartRecord"]
  let client = fake.connected()
  let error = expectFailure(client.request("StartRecord"))
  doAssert error of ObsConnectionError, error.msg
  doAssert not client.isOpen
  doAssert client.closeReason.len > 0
  let after = expectFailure(client.request("GetVersion"))
  doAssert after of ObsConnectionError
  fake.hangupOn = @[]
  let second = fake.connected()
  doAssert (waitFor second.request("GetVersion"))["rpcVersion"].getInt() == 1
  pumpFor(100)
  doAssert fake.count("StartRecord") == 1
  doAssert fake.count("GetVersion") == 1
  second.close()

proc testOversizedMessage() =
  ## Close the connection when OBS sends a message over 1 MiB.
  let fake = newFakeObs(Password)
  defer: fake.stop()
  fake.override = proc (socket: WebSocket, requestType, requestId: string,
      data: JsonNode): Future[bool] {.async, gcsafe.} =
    if requestType == "Huge":
      await socket.respond("Huge", requestId, %*{"blob": repeat('x', 1024 * 1024)})
      result = true
  let client = fake.connected()
  let error = expectFailure(client.request("Huge"))
  doAssert error of ObsConnectionError
  doAssert "1 MiB" in error.msg, error.msg
  doAssert not client.isOpen

proc testLoadSettings() =
  ## Read port and password only when authentication is required.
  let directory = createTempDir("knobby_obs_", "")
  defer: removeDir(directory)
  let
    configDir = directory / "obs-studio/plugin_config/obs-websocket"
    configPath = configDir / "config.json"
  createDir(configDir)
  writeFile(configPath, $(%*{"auth_required": true, "server_enabled": true,
    "server_password": "secret", "server_port": 4466}))
  doAssert loadObsSettings(configPath) == ("ws://127.0.0.1:4466", "secret")
  writeFile(configPath, $(%*{"auth_required": false,
    "server_password": "unused", "server_port": 4455}))
  doAssert loadObsSettings(configPath) == ("ws://127.0.0.1:4455", "")
  let previous = getEnv("XDG_CONFIG_HOME")
  putEnv("XDG_CONFIG_HOME", directory)
  defer: putEnv("XDG_CONFIG_HOME", previous)
  doAssert loadObsSettings() == ("ws://127.0.0.1:4455", "")

proc main() =
  ## Run the OBS client tests against a local fake server.
  testAuthentication()
  testNoAuthentication()
  testRefused()
  testOutOfOrderAndEvents()
  testRequestFailure()
  testTimeout()
  testDisconnectWithoutReplay()
  testOversizedMessage()
  testLoadSettings()

when isMainModule:
  main()
