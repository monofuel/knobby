import
  std/[json, monotimes, nativesockets, net, os, osproc, posix, strformat, tempfiles, times],
  ./common

type
  DiscordRpcError* = object of IOError
    ## An explicit RPC rejection, distinct from a broken socket or response timeout.
  DiscordRpcClient* = ref object
    socket: Socket
    recvTimeoutMs*: int  ## Deadline for one whole request: send plus response.
    nonceCounter: int

  DiscordCreds* = object
    clientId*: string
    clientSecret*: string
    accessToken*: string
    refreshToken*: string

const
  HandshakeOp* = 0
  FrameOp* = 1
  CloseOp* = 2
  RpcVersion = 1
  FrameHeaderLen* = 8
  IpcSocketPrefix = "discord-ipc-"
  MaxIpcSocketIndex = 9
  DefaultRecvTimeoutMs = 5000
  MaxFrameBytes = 1024 * 1024
  MaxResponseFrames = 256
  TokenRequestTimeoutMs = 5500
  TokenEndpoint = "https://discord.com/api/oauth2/token"
  OauthScopes* = ["rpc", "rpc.voice.read", "rpc.voice.write"]

proc discordCredsPath*(): string =
  ## Return the path of the Discord OAuth credentials file.
  result = getConfigDir() / "knobby" / "discord_rpc.json"

proc encodeUint32Le*(value: int): string =
  ## Encode an integer as four little-endian bytes.
  result = newString(4)
  result[0] = chr(value and 0xff)
  result[1] = chr((value shr 8) and 0xff)
  result[2] = chr((value shr 16) and 0xff)
  result[3] = chr((value shr 24) and 0xff)

proc decodeUint32Le*(data: string, offset: int): int =
  ## Decode four little-endian bytes at the offset into an integer.
  result = ord(data[offset]) or
    (ord(data[offset + 1]) shl 8) or
    (ord(data[offset + 2]) shl 16) or
    (ord(data[offset + 3]) shl 24)

proc encodeFrame*(op: int, payload: string): string =
  ## Encode a Discord IPC frame: opcode and payload length as little-endian
  ## uint32 followed by the JSON payload.
  result = encodeUint32Le(op) & encodeUint32Le(payload.len) & payload

proc findDiscordSocketPath*(): string =
  ## Return the path of the first live Discord IPC socket, or an empty string
  ## when Discord is not running.
  let runtimeDir = getEnv("XDG_RUNTIME_DIR")
  if runtimeDir.len == 0:
    return ""
  for index in 0 .. MaxIpcSocketIndex:
    let path = runtimeDir / fmt"{IpcSocketPrefix}{index}"
    if access(path.cstring, F_OK) == 0:
      return path

proc newDiscordRpcClient*(socket: Socket, timeoutMs = DefaultRecvTimeoutMs): DiscordRpcClient =
  ## Wrap a connected socket with a bounded RPC response timeout. The socket
  ## becomes nonblocking so every read and write is bounded by poll deadlines.
  socket.getFd().setBlocking(false)
  result = DiscordRpcClient(socket: socket, recvTimeoutMs: timeoutMs)

proc connectDiscordRpc*(): DiscordRpcClient =
  ## Connect to the local Discord IPC socket.
  let path = findDiscordSocketPath()
  if path.len == 0:
    raise newException(IOError,
      "No Discord IPC socket found; is Discord running?")
  let socket = newSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP, buffered = false)
  socket.connectUnix(path)
  result = newDiscordRpcClient(socket)

proc close*(client: DiscordRpcClient) =
  ## Close the IPC connection.
  client.socket.close()

proc remainingMs(deadline: MonoTime): int =
  ## Return the whole milliseconds left before the deadline.
  result = int((deadline - getMonoTime()).inMilliseconds)

proc waitReady(client: DiscordRpcClient, events: cshort, deadline: MonoTime) =
  ## Wait until the socket is ready for the events or has hung up, raising
  ## IOError once the deadline passes.
  var ready = false
  while not ready:
    let remaining = deadline.remainingMs()
    if remaining <= 0:
      raise newException(IOError, "Discord RPC deadline exceeded.")
    var fds = [TPollfd(fd: client.socket.getFd().cint, events: events)]
    let count = poll(addr fds[0], 1, cint(remaining))
    if count < 0 and osLastError().int32 != EINTR:
      raise newException(IOError, "Discord IPC poll failed: " & osErrorMsg(osLastError()))
    ready = count > 0

proc isRetryable(error: OSErrorCode): bool =
  ## Report whether a nonblocking socket call should wait and try again.
  result = error.int32 in [EINTR, EAGAIN, EWOULDBLOCK]

proc recvExactly(client: DiscordRpcClient, size: int, deadline: MonoTime): string =
  ## Read exactly the requested number of bytes before the deadline. Each read
  ## is nonblocking, so end of stream and peer resets raise instead of looping.
  result = newString(size)
  var received = 0
  while received < size:
    client.waitReady(POLLIN, deadline)
    let count = recv(client.socket.getFd(), addr result[received],
      size - received, 0)
    if count == 0:
      raise newException(IOError, "Discord IPC socket closed.")
    if count < 0:
      let error = osLastError()
      if not error.isRetryable():
        raise newException(IOError, "Discord IPC receive failed: " & osErrorMsg(error))
    else:
      received += count

proc sendAll(client: DiscordRpcClient, data: string, deadline: MonoTime) =
  ## Write all bytes before the deadline without SIGPIPE. Each write is
  ## nonblocking, so a closed or stalled reader raises instead of spinning.
  var written = 0
  while written < data.len:
    client.waitReady(POLLOUT, deadline)
    let count = send(client.socket.getFd(), unsafeAddr data[written],
      data.len - written, MSG_NOSIGNAL)
    if count < 0:
      let error = osLastError()
      if not error.isRetryable():
        raise newException(IOError, "Discord IPC send failed: " & osErrorMsg(error))
    else:
      written += count

proc sendFrame(client: DiscordRpcClient, op: int, payload: JsonNode, deadline: MonoTime) =
  ## Send one IPC frame before the deadline.
  client.sendAll(encodeFrame(op, $payload), deadline)

proc recvFrame(client: DiscordRpcClient, deadline: MonoTime): (int, JsonNode) =
  ## Receive one IPC frame as its opcode and parsed payload.
  let header = client.recvExactly(FrameHeaderLen, deadline)
  let size = decodeUint32Le(header, 4)
  if size > MaxFrameBytes:
    raise newException(IOError, "Discord RPC frame exceeds size limit.")
  let payload = client.recvExactly(size, deadline)
  result = (decodeUint32Le(header, 0), parseJson(payload))

proc request(client: DiscordRpcClient, cmd: string, args: JsonNode): JsonNode =
  ## Send a command frame and return the matching response payload, skipping
  ## unrelated dispatch events and raising on an error response.
  inc client.nonceCounter
  let nonce = $client.nonceCounter
  let deadline = getMonoTime() + initDuration(milliseconds = client.recvTimeoutMs)
  client.sendFrame(FrameOp, %*{"cmd": cmd, "args": args, "nonce": nonce}, deadline)
  for frame in 0..<MaxResponseFrames:
    let (op, payload) = client.recvFrame(deadline)
    if op == CloseOp:
      raise newException(IOError, fmt"Discord closed the connection: {payload}")
    if op == FrameOp and payload{"nonce"}.getStr() == nonce:
      if payload{"evt"}.getStr() == "ERROR":
        let errorData = payload{"data"}
        raise newException(DiscordRpcError,
          fmt"Discord RPC error for {cmd}: {errorData}")
      return payload
  raise newException(IOError, "Discord RPC response frame limit exceeded.")

proc handshake*(client: DiscordRpcClient, clientId: string): JsonNode =
  ## Perform the IPC handshake and return the READY dispatch payload.
  let deadline = getMonoTime() + initDuration(milliseconds = client.recvTimeoutMs)
  client.sendFrame(HandshakeOp, %*{"v": RpcVersion, "client_id": clientId}, deadline)
  let (op, payload) = client.recvFrame(deadline)
  if op != FrameOp:
    raise newException(IOError, fmt"Discord rejected the handshake: {payload}")
  result = payload

proc authorize*(client: DiscordRpcClient, clientId: string): string =
  ## Ask Discord for an OAuth authorization code; blocks until the user
  ## approves the popup inside Discord.
  var scopes = newJArray()
  for scope in OauthScopes:
    scopes.add(%scope)
  let response = client.request("AUTHORIZE",
    %*{"client_id": clientId, "scopes": scopes})
  result = response{"data"}{"code"}.getStr()

proc authenticate*(client: DiscordRpcClient, accessToken: string): JsonNode =
  ## Authenticate the RPC connection with an OAuth access token.
  result = client.request("AUTHENTICATE", %*{"access_token": accessToken})

proc getVoiceSettings*(client: DiscordRpcClient): JsonNode =
  ## Return the data object of a GET_VOICE_SETTINGS response, or nil when absent.
  result = client.request("GET_VOICE_SETTINGS", newJObject()){"data"}

proc setVoiceSettings*(client: DiscordRpcClient, settings: JsonNode): JsonNode =
  ## Apply voice settings and return the data object Discord reports, or nil when absent.
  result = client.request("SET_VOICE_SETTINGS", settings){"data"}

proc discordCredsExist*(): bool =
  ## Report whether the Discord OAuth credentials file exists.
  result = fileExists(discordCredsPath())

proc loadDiscordCreds*(): DiscordCreds =
  ## Load Discord OAuth credentials from the knobby config file.
  let data = parseJson(readFile(discordCredsPath()))
  result = DiscordCreds(
    clientId: data{"clientId"}.getStr(),
    clientSecret: data{"clientSecret"}.getStr(),
    accessToken: data{"accessToken"}.getStr(),
    refreshToken: data{"refreshToken"}.getStr()
  )

proc saveDiscordCreds*(creds: DiscordCreds) =
  ## Write Discord OAuth credentials to the knobby config file.
  let path = discordCredsPath()
  createDir(path.parentDir())
  writeFile(path, pretty(%*{
    "clientId": creds.clientId,
    "clientSecret": creds.clientSecret,
    "accessToken": creds.accessToken,
    "refreshToken": creds.refreshToken
  }))

proc requestToken(creds: DiscordCreds, grantParams: seq[string]): JsonNode =
  ## POST a grant without holding the shared subprocess lock during network I/O.
  let
    runtimeDirectory = getEnv("XDG_RUNTIME_DIR")
    directory = if runtimeDirectory.len > 0: runtimeDirectory / "knobby" else: getTempDir()
  createDir(directory)
  let (responseFile, responsePath) = createTempFile("knobby-discord-token-", ".json", directory)
  responseFile.close()
  defer: removeFile(responsePath)
  var args = @[
    "-s", "--connect-timeout", "3", "--max-time", "5", "-X", "POST", TokenEndpoint,
    "--output", responsePath,
    "-H", "Content-Type: application/x-www-form-urlencoded",
    "--data-urlencode", fmt"client_id={creds.clientId}",
    "--data-urlencode", fmt"client_secret={creds.clientSecret}"
  ]
  for param in grantParams:
    args.add("--data-urlencode")
    args.add(param)
  let process = spawnCommand("curl", args, {poUsePath, poParentStreams})
  defer:
    if process.running():
      process.kill()
      discard process.waitForExit()
    process.close()
  let started = getMonoTime()
  let exitCode = process.waitForExit(TokenRequestTimeoutMs)
  if exitCode == 28 or (getMonoTime() - started).inMilliseconds >= TokenRequestTimeoutMs:
    raise newException(IOError, "Discord token request timed out.")
  if exitCode != 0:
    raise newException(IOError, "Discord token request failed: curl exited " & $exitCode & ".")
  let response = parseJson(readFile(responsePath))
  if "access_token" notin response:
    raise newException(IOError, fmt"Discord token request failed: {response}")
  result = response

proc storeTokens(creds: var DiscordCreds, response: JsonNode) =
  ## Save the tokens from a token endpoint response into the credentials file.
  creds.accessToken = response{"access_token"}.getStr()
  creds.refreshToken = response{"refresh_token"}.getStr()
  saveDiscordCreds(creds)

proc exchangeAuthCode*(creds: var DiscordCreds, code: string) =
  ## Exchange an RPC authorization code for tokens and save them.
  let response = creds.requestToken(
    @["grant_type=authorization_code", fmt"code={code}"])
  creds.storeTokens(response)

proc refreshTokens*(creds: var DiscordCreds) =
  ## Refresh the OAuth tokens and save them.
  let response = creds.requestToken(
    @["grant_type=refresh_token", fmt"refresh_token={creds.refreshToken}"])
  creds.storeTokens(response)

proc connectAuthenticated*(timeoutMs = DefaultRecvTimeoutMs): DiscordRpcClient =
  ## Connect and authenticate with saved credentials, refreshing expired tokens
  ## without ever requesting interactive authorization.
  var creds = loadDiscordCreds()
  result = connectDiscordRpc()
  result.recvTimeoutMs = timeoutMs
  try:
    discard result.handshake(creds.clientId)
    try:
      discard result.authenticate(creds.accessToken)
    except DiscordRpcError:
      refreshTokens(creds)
      discard result.authenticate(creds.accessToken)
  except CatchableError:
    result.close()
    raise
