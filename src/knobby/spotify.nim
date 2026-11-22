import
  std/[base64, json, os, strutils, sysrand, uri],
  ./button_config

type
  SpotifyConsentDeclinedError* = object of ValueError
    ## An explicit consent refusal, distinguished from an unrelated loopback request.
  SpotifyRequest* = object
    verb*, path*, body*: string
  SpotifyHttp* = proc(verb, url, body, contentType, token: string): JsonNode {.closure.}

const
  SpotifyApi* = "https://api.spotify.com/v1"
  SpotifyTokenUrl* = "https://accounts.spotify.com/api/token"
  SpotifyRedirect* = "http://127.0.0.1:43821/callback"
  SpotifyScopes* = "user-read-playback-state user-modify-playback-state"
  SpotifyZero* = "spotify:album:1jrEpZYD1Pn4Dvrg933YIp"
  SpotifyLowRoar* = "spotify:album:2mR9yWuHj65NkxpgFdaC2b"
  SpotifyAmbient* = "spotify:playlist:40LVHt7vpqeCSaARDgcENV"
  RefreshMarginSeconds = 60

proc spotifyCredentialsPath*(): string =
  ## Locate only Knobby's own Spotify authorization, outside button configuration.
  getConfigDir() / "knobby/spotify/credentials.json"

proc base64Url*(bytes: string): string =
  ## Encode unpadded URL-safe base64 for PKCE and state values.
  base64.encode(bytes).replace('+', '-').replace('/', '_').strip(chars = {'='})

proc randomSpotifySecret*(): string =
  ## Generate a cryptographically random 256-bit verifier or authorization state.
  let bytes = urandom(32)
  var raw = newString(bytes.len)
  for index, value in bytes: raw[index] = char(value)
  base64Url(raw)

proc pkceChallenge*(verifier: string): string =
  ## Produce the RFC 7636 SHA-256 challenge from an authorization verifier.
  let hex = sha256Hex(verifier)
  var bytes = newString(hex.len div 2)
  for index in 0..<bytes.len:
    bytes[index] = char(parseHexInt(hex[index * 2..index * 2 + 1]))
  base64Url(bytes)

proc validateSpotifyClientId*(value: string) =
  ## Require a Spotify public application ID without accepting credentials in its place.
  if value.len != 32 or value.contains(AllChars - HexDigits):
    raise newException(ValueError, "Spotify Client ID must contain 32 hexadecimal characters; no client secret is needed.")

proc spotifyAuthorizationUrl*(clientId, verifier, state: string): string =
  ## Build the user's explicit consent URL without launching a browser.
  validateSpotifyClientId(clientId)
  "https://accounts.spotify.com/authorize?" & encodeQuery([
    ("client_id", clientId), ("response_type", "code"),
    ("redirect_uri", SpotifyRedirect), ("scope", SpotifyScopes),
    ("code_challenge_method", "S256"), ("code_challenge", pkceChallenge(verifier)),
    ("state", state)])

proc spotifyCallbackCode*(url: Uri, expectedState: string): string =
  ## Validate the exact loopback callback and CSRF state before accepting an authorization code.
  if url.path != "/callback":
    raise newException(ValueError, "Unexpected Spotify callback path.")
  var code, state, error: string
  var seen: seq[string]
  for key, value in decodeQuery(url.query):
    if key in seen: raise newException(ValueError, "Repeated Spotify callback parameter.")
    seen.add(key)
    case key
    of "code": code = value
    of "state": state = value
    of "error": error = value
    else: discard
  if expectedState.len == 0 or state != expectedState:
    raise newException(ValueError, "Spotify authorization state did not match.")
  if error.len > 0:
    raise newException(SpotifyConsentDeclinedError, "Spotify consent was declined; no playback was changed.")
  if code.len == 0 or code.len > 4096:
    raise newException(ValueError, "Spotify authorization code is missing or too long.")
  code

proc selectSpotifyDevice*(devices: JsonNode, deviceName: string): string =
  ## Select exactly one unrestricted computer by its configured name, never the active remote device.
  if deviceName.len == 0: raise newException(ValueError, "Configure this computer's Spotify device name.")
  var matches: seq[JsonNode]
  for device in devices{"devices"}.getElems():
    if device{"name"}.getStr() == deviceName and device{"type"}.getStr().toLowerAscii() == "computer":
      matches.add(device)
  if matches.len == 0:
    raise newException(IOError, "Open Spotify desktop on " & deviceName & "; its playback device is unavailable.")
  if matches.len != 1:
    raise newException(IOError, "Several Spotify computers are named " & deviceName & "; give this computer a unique Spotify device name.")
  if matches[0]{"is_restricted"}.getBool() or matches[0]{"id"}.getStr().len == 0:
    raise newException(IOError, "Spotify does not allow controlling this computer's playback device.")
  matches[0]["id"].getStr()

proc spotifyPlaybackRequest*(operation, deviceId: string): SpotifyRequest =
  ## Describe one explicit playback operation without changing shuffle, repeat, or volume.
  if deviceId.len == 0: raise newException(ValueError, "Spotify playback requires this computer's exact device ID.")
  result.verb = "PUT"
  if operation == "here":
    result.path = "/me/player"
    result.body = $(%*{"device_ids": [deviceId], "play": true})
  else:
    let context = case operation
      of "zero": SpotifyZero
      of "low-roar": SpotifyLowRoar
      of "ambient": SpotifyAmbient
      else: raise newException(ValueError, "Unknown Spotify action: " & operation)
    result.path = "/me/player/play?device_id=" & encodeUrl(deviceId)
    result.body = $(%*{"context_uri": context})

proc updatedSpotifyTokens*(previous, response: JsonNode, now: int64): JsonNode =
  ## Validate a token response and retain an existing refresh token when it is not rotated.
  if response{"access_token"}.getStr().len == 0 or response{"expires_in"}.getInt() <= 0:
    raise newException(IOError, "Spotify authorization returned no valid access token.")
  if response.hasKey("scope"):
    let granted = response["scope"].getStr().splitWhitespace()
    for scope in SpotifyScopes.splitWhitespace():
      if scope notin granted: raise newException(IOError, "Spotify playback permissions were not granted; reconnect Knobby.")
  result = parseJson($previous)
  result["accessToken"] = response["access_token"]
  result["expiresAt"] = %(now + response["expires_in"].getBiggestInt())
  if response{"refresh_token"}.getStr().len > 0:
    result["refreshToken"] = response["refresh_token"]
  if result{"refreshToken"}.getStr().len == 0:
    raise newException(IOError, "Spotify returned no refresh token; reconnect Knobby.")

proc spotifyToken*(credentials: var JsonNode, http: SpotifyHttp, now: int64): string =
  ## Refresh expiring authorization before a command, without replaying a failed playback request.
  if credentials{"accessToken"}.getStr().len == 0 or credentials{"expiresAt"}.getBiggestInt() <= now + RefreshMarginSeconds:
    if credentials{"refreshToken"}.getStr().len == 0:
      raise newException(IOError, "Connect Spotify to Knobby using the Spotify setup card in Needs You.")
    let response = http("POST", SpotifyTokenUrl,
      encodeQuery([("grant_type", "refresh_token"),
        ("refresh_token", credentials["refreshToken"].getStr()),
        ("client_id", credentials["clientId"].getStr())]),
      "application/x-www-form-urlencoded", "")
    credentials = updatedSpotifyTokens(credentials, response, now)
  credentials["accessToken"].getStr()

proc executeSpotifyPlayback*(operation, deviceName, token: string, http: SpotifyHttp) =
  ## Resolve the local computer afresh and submit exactly one human-requested playback operation.
  if operation notin ["here", "zero", "low-roar", "ambient"]:
    raise newException(ValueError, "Unknown Spotify action: " & operation)
  let
    devices = http("GET", SpotifyApi & "/me/player/devices", "", "", token)
    request = spotifyPlaybackRequest(operation, selectSpotifyDevice(devices, deviceName))
  discard http(request.verb, SpotifyApi & request.path, request.body, "application/json", token)
