import
  std/[json, monotimes, net, os, posix, strformat, times],
  ./common

type
  DiscordRpcClient* = ref object
    socket: Socket
    recvTimeoutMs*: int
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
  ## Wrap a connected socket with a bounded RPC response timeout.
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

proc recvExactly(client: DiscordRpcClient, size: int, deadline: MonoTime): string =
  ## Read exactly the requested number of bytes from the socket.
  while result.len < size:
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining <= 0:
      raise newException(IOError, "Discord RPC response deadline exceeded.")
    let chunk = client.socket.recv(size - result.len, int(remaining))
    if chunk.len == 0:
      raise newException(IOError, "Discord IPC socket closed.")
    result.add(chunk)

proc sendFrame(client: DiscordRpcClient, op: int, payload: JsonNode) =
  ## Send one IPC frame.
  client.socket.send(encodeFrame(op, $payload))

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
  client.sendFrame(FrameOp, %*{"cmd": cmd, "args": args, "nonce": nonce})
  let deadline = getMonoTime() + initDuration(milliseconds = client.recvTimeoutMs)
  for frame in 0..<MaxResponseFrames:
    let (op, payload) = client.recvFrame(deadline)
    if op == CloseOp:
      raise newException(IOError, fmt"Discord closed the connection: {payload}")
    if op == FrameOp and payload{"nonce"}.getStr() == nonce:
      if payload{"evt"}.getStr() == "ERROR":
        let errorData = payload{"data"}
        raise newException(IOError,
          fmt"Discord RPC error for {cmd}: {errorData}")
      return payload
  raise newException(IOError, "Discord RPC response frame limit exceeded.")

proc handshake*(client: DiscordRpcClient, clientId: string): JsonNode =
  ## Perform the IPC handshake and return the READY dispatch payload.
  client.sendFrame(HandshakeOp, %*{"v": RpcVersion, "client_id": clientId})
  let (op, payload) = client.recvFrame(getMonoTime() +
    initDuration(milliseconds = client.recvTimeoutMs))
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

proc getVoiceMute*(client: DiscordRpcClient): bool =
  ## Return whether the Discord client is currently self-muted.
  let response = client.request("GET_VOICE_SETTINGS", newJObject())
  result = response{"data"}{"mute"}.getBool()

proc setVoiceMute*(client: DiscordRpcClient, muted: bool) =
  ## Set the Discord client's self-mute state.
  discard client.request("SET_VOICE_SETTINGS", %*{"mute": muted})

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
  ## POST a grant to the Discord OAuth token endpoint through curl.
  var args = @[
    "-s", "--connect-timeout", "3", "--max-time", "5", "-X", "POST", TokenEndpoint,
    "-H", "Content-Type: application/x-www-form-urlencoded",
    "--data-urlencode", fmt"client_id={creds.clientId}",
    "--data-urlencode", fmt"client_secret={creds.clientSecret}"
  ]
  for param in grantParams:
    args.add("--data-urlencode")
    args.add(param)
  let response = parseJson(runCommand("curl", args))
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

var cachedClient: DiscordRpcClient

proc connectAuthenticated(): DiscordRpcClient =
  ## Connect and authenticate a fresh RPC client, refreshing expired tokens
  ## as needed.
  var creds = loadDiscordCreds()
  result = connectDiscordRpc()
  try:
    discard result.handshake(creds.clientId)
    try:
      discard result.authenticate(creds.accessToken)
    except IOError:
      refreshTokens(creds)
      discard result.authenticate(creds.accessToken)
  except CatchableError:
    result.close()
    raise


proc dropCachedClient() =
  ## Close and forget the cached RPC connection.
  if cachedClient != nil:
    cachedClient.close()
    cachedClient = nil

proc toggleDiscordMute*(): bool =
  ## Toggle the Discord client's self-mute and return the new mute state.
  ## The authenticated connection is kept open across calls because Discord
  ## rate-limits handshakes per client id: reconnecting on every press makes
  ## the second press hang, so a fresh connection is only made when the
  ## cached one has died (Discord restarted or closed the socket).
  if cachedClient == nil:
    cachedClient = connectAuthenticated()
  try:
    result = not cachedClient.getVoiceMute()
    cachedClient.setVoiceMute(result)
  except CatchableError:
    dropCachedClient()
    cachedClient = connectAuthenticated()
    result = not cachedClient.getVoiceMute()
    cachedClient.setVoiceMute(result)
