import
  std/[asyncdispatch, asynchttpserver, httpcore, json, nativesockets, net, os, osproc, posix,
    streams, strutils, tempfiles, times, uri],
  ../src/knobby/[ipc, spotify]

const
  Usage = "Usage: knobby-spotify here|zero|low-roar|ambient|status\n" &
    "       knobby-spotify authorize --client-id CLIENT_ID [--device-name NAME]"
  RequestTimeoutMs = 10000
  AuthorizationTimeoutMs = 300000
  MaxResponseBytes = 1024 * 1024
  OwnerPermissions = {fpUserRead, fpUserWrite}

proc privateDirectory(): string =
  ## Create Knobby's Spotify-only owner-private storage directory.
  result = spotifyCredentialsPath().parentDir()
  if symlinkExists(result): raise newException(IOError, "Spotify credential directory must not be a symbolic link.")
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc saveCredentials(credentials: JsonNode) =
  ## Atomically save private authorization without placing tokens in configuration or logs.
  let
    directory = privateDirectory()
    (file, path) = createTempFile("credentials-", ".json", directory)
  defer: file.close()
  defer:
    if fileExists(path): removeFile(path)
  setFilePermissions(path, OwnerPermissions)
  file.write($credentials)
  file.flushFile()
  if fsync(cint(file.getFileHandle())) != 0: raiseOSError(osLastError())
  moveFile(path, spotifyCredentialsPath())

proc loadCredentials(): JsonNode =
  ## Load only this integration's private authorization, failing clearly before playback.
  let path = spotifyCredentialsPath()
  if not fileExists(path):
    raise newException(IOError, "Connect Spotify to Knobby using the Spotify setup card in Needs You.")
  if symlinkExists(path) or getFileSize(path) > MaxResponseBytes:
    raise newException(IOError, "Invalid Knobby Spotify credential file.")
  setFilePermissions(path, OwnerPermissions)
  try:
    result = parseFile(path)
  except JsonParsingError:
    raise newException(IOError, "Knobby Spotify authorization is invalid; reconnect using the setup card.")

proc curlQuote(value: string): string =
  ## Quote a curl configuration value without allowing inserted options or exposing it in argv.
  if '\0' in value: raise newException(ValueError, "Invalid Spotify request value.")
  "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\r", "\\r").replace("\n", "\\n") & "\""

proc spotifyHttp(verb, url, body, contentType, token: string): JsonNode =
  ## Make a bounded TLS request with sensitive headers and grant data supplied through stdin.
  if not (url.startsWith(SpotifyApi & "/") or url == SpotifyTokenUrl):
    raise newException(ValueError, "Unexpected Spotify API endpoint.")
  let (file, responsePath) = createTempFile("response-", ".json", privateDirectory())
  file.close()
  defer: removeFile(responsePath)
  let process = startProcess("curl", args = @["-q", "--silent", "--show-error",
      "--connect-timeout", "3", "--max-time", "8", "--max-filesize", $MaxResponseBytes,
      "--proto", "=https", "--config", "-", "--output", responsePath,
      "--write-out", "%{http_code}"], options = {poUsePath, poStdErrToStdOut})
  defer:
    if process.running():
      process.kill()
      discard process.waitForExit()
    process.close()
  var config = "url = " & curlQuote(url) & "\nrequest = " & curlQuote(verb) & "\n"
  if contentType.len > 0: config.add("header = " & curlQuote("Content-Type: " & contentType) & "\n")
  if token.len > 0: config.add("header = " & curlQuote("Authorization: Bearer " & token) & "\n")
  if body.len > 0: config.add("data-raw = " & curlQuote(body) & "\n")
  process.inputStream.write(config)
  process.inputStream.close()
  let code = process.waitForExit(RequestTimeoutMs)
  if code != 0: raise newException(IOError, "Spotify request failed or timed out; no command will be replayed.")
  let httpStatus = process.outputStream.readAll().strip()
  case httpStatus
  of "200", "201", "202", "204": discard
  of "401": raise newException(IOError, "Spotify authorization expired or was revoked; reconnect Knobby.")
  of "403": raise newException(IOError, "Spotify refused control; check Premium and the Knobby app's authorized users and scopes.")
  of "404": raise newException(IOError, "Spotify's target device or music is unavailable; open Spotify desktop and try again.")
  of "429": raise newException(IOError, "Spotify is rate limiting requests; wait before pressing again.")
  else: raise newException(IOError, "Spotify rejected the request (HTTP " & httpStatus & "); no command will be replayed.")
  if getFileSize(responsePath) > MaxResponseBytes: raise newException(IOError, "Spotify response exceeded its size limit.")
  let payload = readFile(responsePath)
  try:
    result = if payload.len == 0: newJObject() else: parseJson(payload)
  except JsonParsingError:
    raise newException(IOError, "Spotify returned an invalid response; no command will be replayed.")

proc requireDesktop() =
  ## Require an already-running desktop without D-Bus auto-activation or launching Spotify.
  let process = startProcess("busctl", args = @["--user", "--auto-start=no", "--timeout=2",
    "get-property", "org.mpris.MediaPlayer2.spotify", "/org/mpris/MediaPlayer2",
    "org.mpris.MediaPlayer2.Player", "CanControl"], options = {poUsePath, poStdErrToStdOut})
  defer:
    if process.running():
      process.kill()
      discard process.waitForExit()
    process.close()
  if process.waitForExit(3000) != 0 or process.outputStream.readAll().strip() != "b true":
    raise newException(IOError, "Open Spotify desktop on this computer before using its playback buttons.")

proc authorize(clientId, deviceName: string) =
  ## Await explicitly granted account consent on a temporary loopback listener without playing music.
  validateSpotifyClientId(clientId)
  let
    verifier = randomSpotifySecret()
    state = randomSpotifySecret()
    server = newAsyncHttpServer(maxBody = 8192)
    code = newFuture[string]("Spotify authorization")
  server.listen(Port(43821), "127.0.0.1")
  defer: server.close()
  proc callback(request: asynchttpserver.Request) {.async, gcsafe.} =
    ## Accept only the matching callback and keep malformed requests from completing consent.
    if request.reqMethod != HttpGet:
      await request.respond(Http405, "Use the Spotify consent link.")
    elif request.url.path != "/callback":
      await request.respond(Http404, "Not found.")
    else:
      try:
        let received = spotifyCallbackCode(request.url, state)
        await request.respond(Http200, "Spotify consent received. Return to Knobby setup; no playback was changed.")
        if not code.finished: code.complete(received)
      except SpotifyConsentDeclinedError as error:
        await request.respond(Http400, "Spotify consent was declined. No playback was changed.")
        if not code.finished: code.fail(newException(IOError, error.msg))
      except ValueError:
        await request.respond(Http400, "Spotify consent did not match this setup. Return to the original consent link.")
  echo "Open this link and grant Knobby playback control (expires in 5 minutes):\n" &
    spotifyAuthorizationUrl(clientId, verifier, state)
  proc waitForConsent() {.async.} =
    ## Accept requests until consent arrives, with an overall deadline owned by the caller.
    while not code.finished:
      await server.acceptRequest(callback)
  let listener = waitForConsent()
  if not waitFor withTimeout(code, AuthorizationTimeoutMs):
    raise newException(IOError, "Spotify consent timed out; run authorize again when ready.")
  let response = spotifyHttp("POST", SpotifyTokenUrl, encodeQuery([
    ("grant_type", "authorization_code"), ("client_id", clientId),
    ("redirect_uri", SpotifyRedirect), ("code_verifier", verifier), ("code", code.read())]),
    "application/x-www-form-urlencoded", "")
  let credentials = updatedSpotifyTokens(%*{"clientId": clientId, "deviceName": deviceName}, response, getTime().toUnix())
  saveCredentials(credentials)
  echo "Spotify authorization saved. Checking this computer's playback device without playing music."
  let devices = spotifyHttp("GET", SpotifyApi & "/me/player/devices", "", "", credentials["accessToken"].getStr())
  discard selectSpotifyDevice(devices, deviceName)
  echo "Spotify connected to Knobby for " & deviceName & ". No playback was changed."
  discard listener

proc main() =
  ## Run one requested action or a read-only status check, never replaying or queuing music.
  let args = commandLineParams()
  if args.len == 0 or args[0] notin ["here", "zero", "low-roar", "ambient", "status", "authorize"]:
    quit(Usage, 2)
  let lock = acquireOwnership(privateDirectory() / "operation.lock")
  defer: discard posix.close(lock)
  if args[0] == "authorize":
    if args.len notin [3, 5] or args[1] != "--client-id" or (args.len == 5 and args[3] != "--device-name"):
      quit(Usage, 2)
    authorize(args[2], if args.len == 5: args[4] else: nativesockets.getHostname())
  elif args.len != 1:
    quit(Usage, 2)
  elif args[0] == "status" and not fileExists(spotifyCredentialsPath()):
    echo $(%*{"authorized": false, "action": "Connect Spotify using the setup card in Needs You."})
  else:
    var credentials = loadCredentials()
    let before = $credentials
    let token = spotifyToken(credentials, spotifyHttp, getTime().toUnix())
    if $credentials != before: saveCredentials(credentials)
    if args[0] == "status":
      let devices = spotifyHttp("GET", SpotifyApi & "/me/player/devices", "", "", token)
      discard selectSpotifyDevice(devices, credentials["deviceName"].getStr())
      echo $(%*{"authorized": true, "deviceName": credentials["deviceName"], "available": true})
    else:
      requireDesktop()
      executeSpotifyPlayback(args[0], credentials["deviceName"].getStr(), token, spotifyHttp)
      echo "Spotify accepted " & args[0] & " on " & credentials["deviceName"].getStr() & "."

when isMainModule:
  try:
    main()
  except CatchableError as error:
    stderr.writeLine("Spotify: " & error.msg)
    quit(1)
