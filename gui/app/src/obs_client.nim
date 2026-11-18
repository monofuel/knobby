import
  std/[asyncdispatch, asyncnet, base64, json, nativesockets, net, os, sha1,
    strutils, sysrand, tables, uri],
  crunchy, ws

const
  ObsProfileName* = "Minecraft AI Demos"
  ObsCollectionName* = "Minecraft AI Demos"
  ObsSceneName* = "Minecraft"
  ObsVideoName* = "Minecraft Video"
  ObsAudioName* = "Minecraft Audio"
  ObsMicName* = "Commentary"
  ObsRequestTimeoutMs* = 3000
  ObsSubprotocol = "obswebsocket.json"
  ObsRpcVersion = 1
  ObsHost = "127.0.0.1"
  DefaultObsPort = 4455
  ObsConfigRelativePath = "obs-studio/plugin_config/obs-websocket/config.json"
  MaxMessageBytes = 1024 * 1024
  WebSocketVersion = "13"
  WebSocketKeyBytes = 16
  WebSocketAcceptGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  DefaultWebSocketPort = 80
  MaxHandshakeLineBytes = 8192
  MaxHandshakeHeaders = 64
  AuthFailedCloseCode = 4009
  OpHello = 0
  OpIdentify = 1
  OpIdentified = 2
  OpEvent = 5
  OpRequest = 6
  OpRequestResponse = 7
  # General, Config, Scenes, Inputs, and Outputs; high-volume meters stay off.
  EventSubscriptions = 1 or 2 or 4 or 8 or 64
  FrameContinuation = 0x0
  FrameText = 0x1
  FrameBinary = 0x2
  FrameClose = 0x8
  FramePing = 0x9
  FramePong = 0xa

type
  ObsError* = object of CatchableError
  ObsConnectionError* = object of ObsError
  ObsAuthError* = object of ObsError
  ObsTimeoutError* = object of ObsError
  ObsRequestError* = object of ObsError
    requestType*: string
    code*: int

  ObsEventHandler* = proc (eventType: string, data: JsonNode) {.closure, gcsafe.}

  ObsClient* = ref object
    onEvent*: ObsEventHandler
    socket: WebSocket
    password: string
    pending: Table[string, Future[JsonNode]]
    identified: Future[void]
    nextRequestId: int
    open: bool
    closeMessage: string
    outbox: seq[tuple[text: string, opcode: Opcode]]
    sending: bool

proc connectionError(message: string): ref ObsConnectionError =
  ## Build a fresh connection error so each failed future owns its exception.
  newException(ObsConnectionError, message)

proc shutdown(client: ObsClient, message: string, authFailure = false) =
  ## Close the socket once and fail every waiter; nothing is retried or replayed.
  if not client.open:
    return
  client.open = false
  client.closeMessage = message
  client.outbox.setLen(0)
  let pending = client.pending
  client.pending.clear()
  for future in pending.values:
    if not future.finished:
      future.fail(connectionError(message))
  if not client.identified.finished:
    if authFailure:
      client.identified.fail(newException(ObsAuthError, message))
    else:
      client.identified.fail(connectionError(message))
  if not client.socket.tcpSocket.isClosed():
    client.socket.hangup()

proc flushOutbox(client: ObsClient) {.async.} =
  ## Send queued frames one at a time so concurrent requests never interleave bytes.
  while client.open and client.outbox.len > 0:
    let frame = client.outbox[0]
    client.outbox.delete(0)
    await client.socket.send(frame.text, frame.opcode)
    if client.socket.readyState == Closed:
      client.shutdown("The OBS WebSocket connection failed while sending.")
  client.sending = false

proc enqueue(client: ObsClient, text: string, opcode = Opcode.Text) =
  ## Queue one outgoing frame and start the writer when it is idle.
  if not client.open:
    return
  client.outbox.add((text, opcode))
  if not client.sending:
    client.sending = true
    asyncCheck client.flushOutbox()

proc sendMessage(client: ObsClient, op: int, data: JsonNode) =
  ## Queue one OBS WebSocket protocol message.
  client.enqueue($(%*{"op": op, "d": data}))

proc recvExactly(client: ObsClient, size: int): Future[string] {.async.} =
  ## Read exactly size bytes or report that OBS closed the connection.
  result = await client.socket.tcpSocket.recv(size)
  if result.len != size:
    raise connectionError("OBS closed the WebSocket connection.")

proc readMessage(client: ObsClient): Future[tuple[opcode: int, data: string]] {.async.} =
  ## Read one complete WebSocket message, answering pings and bounding its size.
  var
    message = ""
    started = false
  while true:
    let
      header = await client.recvExactly(2)
      first = header[0].uint8
      second = header[1].uint8
      final = (first and 0x80) != 0
      frameOpcode = int(first and 0x0f)
    if (first and 0x70) != 0:
      raise connectionError("OBS sent a WebSocket frame with reserved bits set.")
    if (second and 0x80) != 0:
      raise connectionError("OBS sent a masked WebSocket frame.")
    var length = uint64(second and 0x7f)
    if length == 126:
      let extended = await client.recvExactly(2)
      length = (uint64(extended[0].uint8) shl 8) or uint64(extended[1].uint8)
    elif length == 127:
      let extended = await client.recvExactly(8)
      length = 0
      for byte in extended:
        length = (length shl 8) or uint64(byte.uint8)
    if length > uint64(MaxMessageBytes - message.len):
      raise connectionError("OBS sent a WebSocket message larger than 1 MiB.")
    let payload =
      if length == 0: ""
      else: await client.recvExactly(int(length))
    case frameOpcode
    of FramePing:
      client.enqueue(payload, Opcode.Pong)
    of FramePong:
      discard
    of FrameClose:
      return (FrameClose, payload)
    of FrameText, FrameBinary:
      if started:
        raise connectionError("OBS interrupted a fragmented WebSocket message.")
      started = true
      result.opcode = frameOpcode
      message = payload
      if final:
        result.data = move(message)
        return
    of FrameContinuation:
      if not started:
        raise connectionError("OBS sent an unexpected WebSocket continuation.")
      message.add(payload)
      if final:
        result.data = move(message)
        return
    else:
      raise connectionError("OBS sent an unknown WebSocket opcode " &
        $frameOpcode & ".")

proc describeClose(payload: string): tuple[message: string, authFailure: bool] =
  ## Describe an OBS close frame, recognizing authentication rejection.
  if payload.len < 2:
    return ("OBS closed the WebSocket connection.", false)
  let
    code = (int(payload[0].uint8) shl 8) or int(payload[1].uint8)
    reason = payload[2 .. ^1]
    suffix = if reason.len > 0: ": " & reason else: ""
  if code == AuthFailedCloseCode:
    result = ("OBS rejected the WebSocket password (close " & $code & ")" &
      suffix & ".", true)
  else:
    result = ("OBS closed the WebSocket connection (close " & $code & ")" &
      suffix & ".", false)

proc authenticationString(password, salt, challenge: string): string =
  ## Compute the OBS WebSocket 5 authentication response.
  let secret = base64.encode(sha256(password & salt))
  result = base64.encode(sha256(secret & challenge))

proc handleHello(client: ObsClient, data: JsonNode) =
  ## Answer Hello with Identify, authenticating when OBS requires it.
  var identify = %*{
    "rpcVersion": ObsRpcVersion,
    "eventSubscriptions": EventSubscriptions
  }
  let auth = data{"authentication"}
  if auth != nil and auth.kind == JObject:
    if client.password.len == 0:
      client.shutdown("OBS requires a WebSocket password, but none is configured.",
        authFailure = true)
      return
    identify["authentication"] = %authenticationString(client.password,
      auth{"salt"}.getStr(), auth{"challenge"}.getStr())
  client.sendMessage(OpIdentify, identify)

proc handleResponse(client: ObsClient, data: JsonNode) =
  ## Complete the matching pending request; unknown or late responses are ignored.
  let requestId = data{"requestId"}.getStr()
  if requestId notin client.pending:
    return
  let future = client.pending[requestId]
  client.pending.del(requestId)
  let status = data{"requestStatus"}
  if status != nil and status{"result"}.getBool(false):
    let response = data{"responseData"}
    future.complete(if response == nil: newJObject() else: response)
  else:
    let
      requestType = data{"requestType"}.getStr()
      code = status{"code"}.getInt(0)
      comment = status{"comment"}.getStr()
      detail = if comment.len > 0: ": " & comment else: ""
      error = (ref ObsRequestError)(
        msg: "OBS rejected " & requestType & " (code " & $code & ")" & detail & ".",
        requestType: requestType, code: code)
    future.fail(error)

proc handleMessage(client: ObsClient, text: string) =
  ## Dispatch one OBS protocol message by opcode.
  var message: JsonNode
  try:
    message = parseJson(text)
  except JsonParsingError:
    client.shutdown("OBS sent malformed JSON: " & getCurrentExceptionMsg())
    return
  let data = message{"d"}
  if message.kind != JObject or data == nil or data.kind != JObject:
    client.shutdown("OBS sent a message without an op and d object.")
    return
  case message{"op"}.getInt(-1)
  of OpHello:
    client.handleHello(data)
  of OpIdentified:
    if not client.identified.finished:
      client.identified.complete()
  of OpEvent:
    if client.onEvent != nil:
      let eventData = data{"eventData"}
      client.onEvent(data{"eventType"}.getStr(),
        if eventData == nil: newJObject() else: eventData)
  of OpRequestResponse:
    client.handleResponse(data)
  else:
    discard

proc readLoop(client: ObsClient) {.async.} =
  ## Receive messages until OBS or Knobby closes the connection.
  while client.open:
    var message: tuple[opcode: int, data: string]
    try:
      message = await client.readMessage()
    except CatchableError:
      # Every read failure ends this connection; waiters receive the reason.
      client.shutdown(getCurrentExceptionMsg())
      return
    if not client.open:
      return
    if message.opcode == FrameClose:
      let close = describeClose(message.data)
      client.shutdown(close.message, close.authFailure)
    elif message.opcode == FrameBinary:
      client.shutdown("OBS sent a binary message on the JSON protocol.")
    else:
      client.handleMessage(message.data)

proc webSocketAccept(key: string): string =
  ## Compute the RFC 6455 Sec-WebSocket-Accept value for a client key.
  let digest = Sha1Digest(secureHash(key & WebSocketAcceptGuid))
  result = base64.encode(digest)

proc headerHasToken(value, token: string): bool =
  ## Check whether a comma-separated header value contains a token, ignoring case.
  for part in value.split(','):
    if cmpIgnoreCase(part.strip(), token) == 0:
      return true

proc ensureNotAbandoned(socket: AsyncSocket) =
  ## Stop an upgrade whose socket was closed after its timeout.
  if socket.isClosed():
    raise connectionError("The OBS WebSocket upgrade was abandoned.")

proc readHandshakeLine(socket: AsyncSocket): Future[string] {.async.} =
  ## Read one bounded HTTP response line, failing if OBS hangs up mid-response.
  socket.ensureNotAbandoned()
  result = await socket.recvLine(maxLength = MaxHandshakeLineBytes)
  if result.len == 0:
    raise connectionError("OBS closed the connection during the WebSocket upgrade.")

proc upgrade(socket: AsyncSocket, uri: Uri, port: Port, key: string) {.async.} =
  ## Connect the caller-owned socket and complete the client WebSocket upgrade.
  await socket.connect(uri.hostname, port)
  let
    path = (if uri.path.len > 0: uri.path else: "/") &
      (if uri.query.len > 0: "?" & uri.query else: "")
    request = "GET " & path & " HTTP/1.1\c\L" &
      "Host: " & uri.hostname & ":" & $port & "\c\L" &
      "Upgrade: websocket\c\L" &
      "Connection: Upgrade\c\L" &
      "Sec-WebSocket-Key: " & key & "\c\L" &
      "Sec-WebSocket-Version: " & WebSocketVersion & "\c\L" &
      "Sec-WebSocket-Protocol: " & ObsSubprotocol & "\c\L\c\L"
  socket.ensureNotAbandoned()
  await socket.send(request)
  let status = (await socket.readHandshakeLine()).splitWhitespace()
  if status.len < 2 or not status[0].startsWith("HTTP/1.") or status[1] != "101":
    raise connectionError("OBS refused the WebSocket upgrade: " & status.join(" "))
  var headers = initTable[string, string]()
  while true:
    let line = await socket.readHandshakeLine()
    if line == "\c\L":
      break
    if headers.len >= MaxHandshakeHeaders:
      raise connectionError("OBS sent too many WebSocket upgrade headers.")
    let separator = line.find(':')
    if separator <= 0:
      raise connectionError("OBS sent a malformed WebSocket upgrade header.")
    headers[line[0 ..< separator].strip().toLowerAscii()] =
      line[separator + 1 .. ^1].strip()
  if cmpIgnoreCase(headers.getOrDefault("upgrade"), "websocket") != 0 or
      not headerHasToken(headers.getOrDefault("connection"), "upgrade"):
    raise connectionError("OBS did not upgrade the connection to a WebSocket.")
  if headers.getOrDefault("sec-websocket-accept") != webSocketAccept(key):
    raise connectionError("OBS sent an invalid Sec-WebSocket-Accept value.")
  if headers.getOrDefault("sec-websocket-protocol") != ObsSubprotocol:
    raise connectionError("OBS did not accept the " & ObsSubprotocol &
      " WebSocket subprotocol.")

proc openWebSocket(url: string, timeoutMs: int): Future[WebSocket] {.async.} =
  ## Open an upgraded WebSocket, closing its only socket on any failure or timeout.
  let uri = parseUri(url)
  if uri.scheme != "ws" or uri.hostname.len == 0:
    raise connectionError("Unsupported OBS WebSocket URL " & url &
      "; expected ws://host:port.")
  let
    port = Port(if uri.port.len > 0: parseInt(uri.port) else: DefaultWebSocketPort)
    domain = if uri.hostname.isIpAddress() and
        uri.hostname.parseIpAddress().family == IpAddressFamily.IPv6: AF_INET6
      else: AF_INET
    key = base64.encode(urandom(WebSocketKeyBytes))
    socket = newAsyncSocket(domain)
    upgrading = socket.upgrade(uri, port, key)
  var opened = false
  try:
    opened = await withTimeout(upgrading, timeoutMs)
  except CatchableError:
    socket.close()
    raise connectionError("Could not connect to OBS at " & url & ": " &
      getCurrentExceptionMsg())
  if not opened:
    # Closing unregisters the descriptor and fails the abandoned connect or read.
    socket.close()
    raise newException(ObsTimeoutError, "OBS at " & url &
      " did not accept the WebSocket within " & $timeoutMs & " ms.")
  result = WebSocket(tcpSocket: socket, version: parseInt(WebSocketVersion),
    key: key, protocol: ObsSubprotocol, readyState: Open, masked: true)

proc connectObs*(url, password: string, onEvent: ObsEventHandler = nil,
    timeoutMs = ObsRequestTimeoutMs): Future[ObsClient] {.async.} =
  ## Connect and identify with OBS WebSocket 5, bounding each phase to timeoutMs.
  ## Every failure closes the connection's socket before raising.
  let client = ObsClient(
    onEvent: onEvent,
    socket: await openWebSocket(url, timeoutMs),
    password: password,
    identified: newFuture[void]("obs.identified"),
    open: true
  )
  asyncCheck client.readLoop()
  if not await withTimeout(client.identified, timeoutMs):
    client.shutdown("OBS did not identify the session within " &
      $timeoutMs & " ms.")
    raise newException(ObsTimeoutError, client.closeMessage)
  client.identified.read()
  result = client

proc request*(client: ObsClient, requestType: string,
    data: JsonNode = nil): Future[JsonNode] {.async.} =
  ## Send one request and return its responseData, raising a typed ObsError on failure.
  if not client.open:
    raise connectionError(if client.closeMessage.len > 0: client.closeMessage
      else: "OBS is not connected.")
  inc client.nextRequestId
  let
    requestId = $client.nextRequestId
    response = newFuture[JsonNode]("obs.request")
  var body = %*{"requestType": requestType, "requestId": requestId}
  if data != nil:
    body["requestData"] = data
  client.pending[requestId] = response
  client.sendMessage(OpRequest, body)
  if not await withTimeout(response, ObsRequestTimeoutMs):
    client.pending.del(requestId)
    raise newException(ObsTimeoutError, "OBS did not answer " & requestType &
      " within " & $ObsRequestTimeoutMs & " ms; its outcome is unknown.")
  result = response.read()

proc isOpen*(client: ObsClient): bool =
  ## Report whether the identified connection is still usable.
  client != nil and client.open

proc closeReason*(client: ObsClient): string =
  ## Describe why the connection closed, or return "" while it is open.
  client.closeMessage

proc close*(client: ObsClient) =
  ## Close the connection and fail every pending request; repeated calls do nothing.
  client.shutdown("The OBS connection was closed by Knobby.")

proc loadObsSettings*(configPath: string): tuple[url, password: string] =
  ## Read the OBS WebSocket server port and password from an obs-websocket config file.
  let config = parseFile(configPath)
  result.url = "ws://" & ObsHost & ":" & $config{"server_port"}.getInt(DefaultObsPort)
  if config{"auth_required"}.getBool(false):
    result.password = config{"server_password"}.getStr()

proc loadObsSettings*(): tuple[url, password: string] =
  ## Read the current user's local OBS WebSocket settings; the password is never logged.
  loadObsSettings(getConfigDir() / ObsConfigRelativePath)
