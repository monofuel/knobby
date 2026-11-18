import
  std/[asyncdispatch, asyncnet, base64, json, nativesockets, net, os, posix,
    sha1, strutils, tempfiles],
  ws,
  obs_client, ./fake_obs

const
  Password = "correct horse"
  LeakAttempts = 1200
  LeakBatch = 50
  LeakSlackFds = 8
  LeakFdLimit = 1024
  LeakTimeoutMs = 40
  SettleMs = 5000
  AcceptGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type
  UpgradeBehavior = enum
    HangBeforeResponse, NotUpgraded, WrongAccept, WrongProtocol,
    MissingUpgrade, GarbageStatus, HangupMidHeaders, UpgradeThenSilence

  FakeUpgradeServer = ref object
    listener: AsyncSocket
    behavior: UpgradeBehavior
    held: seq[AsyncSocket]
    stopped: bool

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

proc openFdCount(): int =
  ## Count this process's open file descriptors.
  for _ in walkDir("/proc/self/fd"):
    inc result

proc activeRegistrations(): int =
  ## Count descriptors with pending operations in the async dispatcher.
  getGlobalDispatcher().getIoHandler().count

proc lowerFdLimit(): RLimit =
  ## Lower the soft descriptor limit to 1024 and return the previous limit.
  doAssert getrlimit(RLIMIT_NOFILE, result) == 0
  var lowered = result
  lowered.rlim_cur = min(result.rlim_cur, LeakFdLimit)
  doAssert setrlimit(RLIMIT_NOFILE, lowered) == 0

proc restoreFdLimit(previous: RLimit) =
  ## Restore the descriptor limit saved by lowerFdLimit.
  var limit = previous
  doAssert setrlimit(RLIMIT_NOFILE, limit) == 0

proc readRequestKey(socket: AsyncSocket): Future[string] {.async.} =
  ## Read an HTTP upgrade request and return its Sec-WebSocket-Key.
  while true:
    let line = await socket.recvLine()
    if line.len == 0 or line == "\c\L":
      return
    if line.toLowerAscii().startsWith("sec-websocket-key:"):
      result = line.split(':', 1)[1].strip()

proc serveUpgrade(server: FakeUpgradeServer, socket: AsyncSocket) {.async.} =
  ## Answer one client according to the server's misbehavior.
  let
    key = await socket.readRequestKey()
    accept = base64.encode(Sha1Digest(secureHash(key & AcceptGuid)))
    upgraded = "HTTP/1.1 101 Switching Protocols\c\LUpgrade: websocket\c\L" &
      "Connection: Upgrade\c\L"
  if socket.isClosed():
    return
  case server.behavior
  of HangBeforeResponse:
    server.held.add(socket)
  of NotUpgraded:
    await socket.send("HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L")
    socket.close()
  of WrongAccept:
    await socket.send(upgraded & "Sec-WebSocket-Accept: bogus\c\L" &
      "Sec-WebSocket-Protocol: obswebsocket.json\c\L\c\L")
    socket.close()
  of WrongProtocol:
    await socket.send(upgraded & "Sec-WebSocket-Accept: " & accept & "\c\L" &
      "Sec-WebSocket-Protocol: chat\c\L\c\L")
    socket.close()
  of MissingUpgrade:
    await socket.send("HTTP/1.1 101 Switching Protocols\c\L" &
      "Sec-WebSocket-Accept: " & accept & "\c\L\c\L")
    socket.close()
  of GarbageStatus:
    await socket.send("garbage\c\L\c\L")
    socket.close()
  of HangupMidHeaders:
    await socket.send("HTTP/1.1 101 Switching Protocols\c\LUpgrade: web")
    socket.close()
  of UpgradeThenSilence:
    await socket.send(upgraded & "Sec-WebSocket-Accept: " & accept & "\c\L" &
      "Sec-WebSocket-Protocol: obswebsocket.json\c\L\c\L")
    server.held.add(socket)

proc acceptUpgrades(server: FakeUpgradeServer) {.async.} =
  ## Accept clients until stopped.
  while not server.stopped:
    var socket: AsyncSocket
    try:
      socket = await server.listener.accept()
    except CatchableError:
      # Stopping closes the listener underneath a pending accept.
      if not server.stopped:
        raise
      return
    asyncCheck server.serveUpgrade(socket)

proc newFakeUpgradeServer(behavior: UpgradeBehavior): FakeUpgradeServer =
  ## Start a loopback server that misbehaves during the WebSocket upgrade.
  result = FakeUpgradeServer(listener: newAsyncSocket(), behavior: behavior)
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(Port(0), "127.0.0.1")
  result.listener.listen()
  asyncCheck result.acceptUpgrades()

proc url(server: FakeUpgradeServer): string =
  ## Return the server's WebSocket URL.
  "ws://127.0.0.1:" & $server.listener.getLocalAddr()[1].int

proc releaseHeld(server: FakeUpgradeServer) =
  ## Close every server-side connection held open by a hanging behavior.
  for socket in server.held:
    socket.close()
  server.held.setLen(0)

proc stop(server: FakeUpgradeServer) =
  ## Stop accepting and close every server-side connection.
  server.stopped = true
  server.releaseHeld()
  server.listener.close()

proc settle(fdBaseline, registrationBaseline: int, label: string) =
  ## Require descriptors and dispatcher registrations to return near their baselines.
  let settled = pump(proc (): bool =
    openFdCount() <= fdBaseline + LeakSlackFds and
      activeRegistrations() <= registrationBaseline, SettleMs)
  doAssert settled, label & " left " & $(openFdCount() - fdBaseline) &
    " extra descriptors and " & $(activeRegistrations() - registrationBaseline) &
    " extra dispatcher registrations"

proc attemptFailures(url, password: string, timeoutMs: int,
    expected: proc (error: ref Exception): bool, label: string,
    server: FakeUpgradeServer = nil) =
  ## Run failing connections in concurrent batches and check every failure.
  let
    fdBaseline = openFdCount()
    registrationBaseline = activeRegistrations()
  var attempted = 0
  while attempted < LeakAttempts:
    var batch: seq[Future[ObsClient]]
    for _ in 0 ..< min(LeakBatch, LeakAttempts - attempted):
      batch.add(connectObs(url, password, timeoutMs = timeoutMs))
    attempted += batch.len
    doAssert pump(proc (): bool =
      for future in batch:
        if not future.finished:
          return false
      true, SettleMs), label & " attempts did not finish"
    for future in batch:
      doAssert future.failed, label & " unexpectedly connected"
      let error = future.readError()
      doAssert expected(error), label & ": " & $error.name & ": " & error.msg
    if server != nil:
      server.releaseHeld()
    settle(fdBaseline, registrationBaseline, label)

proc isConnectionError(error: ref Exception): bool =
  ## Accept a connection failure.
  error of ObsConnectionError

proc isTimeout(error: ref Exception): bool =
  ## Accept a timeout failure.
  error of ObsTimeoutError

proc isAuthError(error: ref Exception): bool =
  ## Accept an authentication failure.
  error of ObsAuthError

proc testDescriptorsBounded() =
  ## Keep descriptors bounded across more than 1024 attempts of every outcome.
  let previous = lowerFdLimit()
  defer: restoreFdLimit(previous)
  attemptFailures("ws://127.0.0.1:" & $closedPort(), "", ObsRequestTimeoutMs,
    isConnectionError, "refused")
  for behavior in [NotUpgraded, WrongAccept, WrongProtocol, MissingUpgrade,
      GarbageStatus, HangupMidHeaders]:
    let server = newFakeUpgradeServer(behavior)
    attemptFailures(server.url, "", ObsRequestTimeoutMs, isConnectionError,
      $behavior, server)
    server.stop()
  for behavior in [HangBeforeResponse, UpgradeThenSilence]:
    let server = newFakeUpgradeServer(behavior)
    attemptFailures(server.url, "", LeakTimeoutMs, isTimeout, $behavior, server)
    server.stop()

  let fake = newFakeObs(Password)
  defer: fake.stop()
  attemptFailures(fake.url, "wrong", ObsRequestTimeoutMs, isAuthError,
    "wrong password")
  attemptFailures(fake.url, "", ObsRequestTimeoutMs, isAuthError,
    "missing password")
  let
    fdBaseline = openFdCount()
    registrationBaseline = activeRegistrations()
  for attempt in 1 .. LeakAttempts:
    let client = fake.connected()
    doAssert (waitFor client.request("GetVersion"))["rpcVersion"].getInt() == 1
    client.close()
    if attempt mod LeakBatch == 0:
      settle(fdBaseline, registrationBaseline, "successful sessions")
  settle(fdBaseline, registrationBaseline, "successful sessions")

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
  testDescriptorsBounded()
  testLoadSettings()

when isMainModule:
  main()
