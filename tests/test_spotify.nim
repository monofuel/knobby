import
  std/[json, strutils, unittest, uri],
  ../src/knobby/spotify

proc device(id, name: string, restricted = false, kind = "Computer"): JsonNode =
  ## Describe one Spotify Connect device without contacting any service.
  %*{"id": id, "name": name, "is_restricted": restricted, "type": kind}

suite "Spotify playback controls":
  test "uses published album IDs and the exact requested playlist":
    check SpotifyZero == "spotify:album:1jrEpZYD1Pn4Dvrg933YIp"
    check SpotifyLowRoar == "spotify:album:2mR9yWuHj65NkxpgFdaC2b"
    check SpotifyAmbient == "spotify:playlist:40LVHt7vpqeCSaARDgcENV"

  test "PKCE matches the RFC 7636 known-answer example":
    check pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    let url = spotifyAuthorizationUrl(repeat('a', 32), "verifier", "state")
    check "code_challenge_method=S256" in url
    check "user-read-playback-state" in url
    check "client_secret" notin url
    expect ValueError: validateSpotifyClientId("invalid")

  test "accepts only exact state and callback without duplicate parameters":
    check spotifyCallbackCode(parseUri("/callback?code=good&state=expected"), "expected") == "good"
    for url in ["/wrong?code=good&state=expected", "/callback?code=good&state=wrong",
        "/callback?code=good&state=expected&state=expected", "/callback?state=expected",
        "/callback?error=access_denied&state=expected"]:
      expect ValueError: discard spotifyCallbackCode(parseUri(url), "expected")

  test "local device is selected even when another device is active":
    let devices = %*{"devices": [device("phone", "Phone", kind = "Smartphone"), device("local", "high-steel")]}
    devices["devices"][0]["is_active"] = %true
    check selectSpotifyDevice(devices, "high-steel") == "local"
    expect IOError: discard selectSpotifyDevice(devices, "absent")
    expect IOError: discard selectSpotifyDevice(%*{"devices": [device("a", "high-steel"), device("b", "high-steel")]}, "high-steel")
    expect IOError: discard selectSpotifyDevice(%*{"devices": [device("a", "high-steel", true)]}, "high-steel")
    expect IOError: discard selectSpotifyDevice(%*{"devices": [device("", "high-steel")]}, "high-steel")
    expect IOError: discard selectSpotifyDevice(%*{"devices": [device("a", "high-steel", kind = "Smartphone")]}, "high-steel")

  test "Play Here resumes existing context and music buttons specify the device directly":
    let here = spotifyPlaybackRequest("here", "local")
    check here.path == "/me/player"
    check parseJson(here.body) == %*{"device_ids": ["local"], "play": true}
    for (operation, context) in [("zero", SpotifyZero), ("low-roar", SpotifyLowRoar), ("ambient", SpotifyAmbient)]:
      let request = spotifyPlaybackRequest(operation, "local /device")
      check request.verb == "PUT"
      check request.path == "/me/player/play?device_id=local+%2Fdevice"
      check parseJson(request.body) == %*{"context_uri": context}
    expect ValueError: discard spotifyPlaybackRequest("unknown", "local")
    expect ValueError: discard spotifyPlaybackRequest("here", "")

  test "token rotation preserves refresh token and detects missing scopes":
    let previous = %*{"clientId": repeat('a', 32), "deviceName": "high-steel", "refreshToken": "old"}
    let response = %*{"access_token": "access", "expires_in": 3600, "scope": SpotifyScopes}
    let updated = updatedSpotifyTokens(previous, response, 100)
    check updated["refreshToken"].getStr() == "old"
    check updated["expiresAt"].getInt() == 3700
    check not previous.hasKey("accessToken")
    response["scope"] = %"user-read-playback-state"
    expect IOError: discard updatedSpotifyTokens(previous, response, 100)

  test "refresh occurs before playback and authorization errors never issue music commands":
    var calls: seq[string]
    let http: SpotifyHttp = proc(verb, url, body, contentType, token: string): JsonNode =
      calls.add(verb & " " & url)
      if url == SpotifyTokenUrl:
        check "grant_type=refresh_token" in body
        check token == ""
        return %*{"access_token": "fresh", "expires_in": 3600}
      raise newException(IOError, "Unexpected request.")
    var credentials = %*{"clientId": "client", "refreshToken": "old", "expiresAt": 100}
    check spotifyToken(credentials, http, 100) == "fresh"
    check calls == @["POST " & SpotifyTokenUrl]
    check spotifyToken(credentials, http, 101) == "fresh"
    check calls.len == 1

  test "button dispatch performs one fresh device lookup and exactly one explicit music operation":
    for operation in ["here", "zero", "low-roar", "ambient"]:
      var calls: seq[string]
      let http: SpotifyHttp = proc(verb, url, body, contentType, token: string): JsonNode =
        check token == "token"
        calls.add(verb & " " & url)
        if verb == "GET": return %*{"devices": [device("local", "high-steel")]}
        check verb == "PUT"
        check "volume" notin body and "shuffle" notin body and "repeat" notin body
        newJObject()
      executeSpotifyPlayback(operation, "high-steel", "token", http)
      check calls.len == 2
      check calls[0] == "GET " & SpotifyApi & "/me/player/devices"
    var calls = 0
    let unavailable: SpotifyHttp = proc(verb, url, body, contentType, token: string): JsonNode =
      inc calls
      %*{"devices": [device("phone", "phone", kind = "Smartphone")]}
    expect IOError: executeSpotifyPlayback("here", "high-steel", "token", unavailable)
    check calls == 1

  test "a playback refusal is not retried or transferred elsewhere":
    var calls = 0
    let http: SpotifyHttp = proc(verb, url, body, contentType, token: string): JsonNode =
      inc calls
      if verb == "GET": return %*{"devices": [device("local", "high-steel")]}
      raise newException(IOError, "Forbidden.")
    expect IOError: executeSpotifyPlayback("ambient", "high-steel", "token", http)
    check calls == 2
