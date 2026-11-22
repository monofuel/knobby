import
  std/[json, os, osproc, streams, strtabs, strutils, tempfiles, times]

const
  FakeCurl = """#!/bin/sh
set -eu
destination=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) destination="$2"; shift 2 ;;
    *) shift ;;
  esac
done
request=$(cat)
printf '%s\n' "$request" >> "$SPOTIFY_FIXTURE_DIR/requests"
touch "$SPOTIFY_FIXTURE_DIR/entered"
if [ -f "$SPOTIFY_FIXTURE_DIR/slow" ]; then sleep 1; fi
case "$request" in
  *accounts.spotify.com*)
    printf '%s' '{"access_token":"fixture-refreshed","refresh_token":"fixture-rotated","expires_in":3600}' > "$destination"
    printf 200 ;;
  *request\ =\ \"GET\"*)
    printf '%s' '{"devices":[{"id":"fixture-local","name":"high-steel","type":"Computer","is_restricted":false},{"id":"fixture-phone","name":"Phone","type":"Smartphone","is_active":true}]}' > "$destination"
    printf 200 ;;
  *)
    printf '%s' '{}' > "$destination"
    if [ -f "$SPOTIFY_FIXTURE_DIR/refuse" ]; then printf 403; else printf 204; fi ;;
esac
"""

proc run(binary: string, args: seq[string], env: StringTableRef): (int, string) =
  ## Exercise the actual CLI exclusively through fake HTTP and desktop executables.
  let process = startProcess(binary, args = args, env = env, options = {poStdErrToStdOut})
  defer:
    if process.running():
      process.kill()
      discard process.waitForExit()
    process.close()
  let code = process.waitForExit(10000)
  doAssert code != -1, "Spotify fixture command timed out."
  (code, process.outputStream.readAll())

proc main() =
  ## Verify CLI routing, credential persistence, and serialization with no real Spotify or audio access.
  doAssert paramCount() == 1
  let
    binary = absolutePath(paramStr(1))
    directory = createTempDir("knobby-spotify-cli-", "")
    fakeBin = directory / "bin"
    configDir = directory / "config"
    credsDir = configDir / "knobby/spotify"
    credentialsPath = credsDir / "credentials.json"
    env = newStringTable(modeCaseSensitive)
  defer: removeDir(directory)
  for key, value in envPairs(): env[key] = value
  createDir(fakeBin)
  createDir(configDir)
  env["XDG_CONFIG_HOME"] = configDir
  env["HOME"] = directory
  env["PATH"] = fakeBin & ":" & getEnv("PATH")
  env["SPOTIFY_FIXTURE_DIR"] = directory
  writeFile(fakeBin / "curl", FakeCurl)
  writeFile(fakeBin / "busctl", "#!/bin/sh\nprintf 'b true\\n'\n")
  for name in ["curl", "busctl"]:
    setFilePermissions(fakeBin / name, {fpUserRead, fpUserWrite, fpUserExec})
  let status = run(binary, @["status"], env)
  doAssert status[0] == 0 and not parseJson(status[1])["authorized"].getBool()
  doAssert not fileExists(directory / "requests")
  let absent = run(binary, @["here"], env)
  doAssert absent[0] == 1 and "Needs You" in absent[1]
  doAssert not fileExists(directory / "requests")
  createDir(credsDir)
  writeFile(credentialsPath, $(%*{"clientId": repeat('a', 32), "deviceName": "high-steel",
    "accessToken": "fixture-token", "refreshToken": "fixture-refresh", "expiresAt": getTime().toUnix() + 3600}))
  for action in ["here", "zero", "low-roar", "ambient"]:
    let reply = run(binary, @[action], env)
    doAssert reply[0] == 0, reply[1]
    doAssert "fixture-token" notin reply[1]
  let requests = readFile(directory / "requests")
  doAssert requests.count("request = \"GET\"") == 4
  doAssert requests.count("request = \"PUT\"") == 4
  doAssert "device_id=fixture-local" in requests and "device_id=fixture-phone" notin requests
  doAssert "device_ids" in requests and "play" in requests
  doAssert "1jrEpZYD1Pn4Dvrg933YIp" in requests
  doAssert "2mR9yWuHj65NkxpgFdaC2b" in requests
  doAssert "40LVHt7vpqeCSaARDgcENV" in requests
  doAssert not fileExists(directory / "response.json")
  let credentials = parseFile(credentialsPath)
  credentials["expiresAt"] = %0
  writeFile(credentialsPath, $credentials)
  doAssert run(binary, @["ambient"], env)[0] == 0
  doAssert parseFile(credentialsPath)["refreshToken"].getStr() == "fixture-rotated"
  doAssert getFilePermissions(credentialsPath) == {fpUserRead, fpUserWrite}
  doAssert getFilePermissions(credsDir) == {fpUserRead, fpUserWrite, fpUserExec}
  writeFile(directory / "requests", "")
  writeFile(directory / "refuse", "")
  let refused = run(binary, @["zero"], env)
  doAssert refused[0] == 1 and "Premium" in refused[1]
  doAssert readFile(directory / "requests").count("request = \"PUT\"") == 1
  removeFile(directory / "refuse")
  removeFile(directory / "entered")
  writeFile(directory / "slow", "")
  let first = startProcess(binary, args = @["here"], env = env, options = {poStdErrToStdOut})
  defer:
    if first.running():
      first.kill()
      discard first.waitForExit()
    first.close()
  for attempt in 0..<100:
    if fileExists(directory / "entered"): break
    sleep(20)
  doAssert fileExists(directory / "entered")
  let second = run(binary, @["ambient"], env)
  doAssert second[0] == 1 and "Already owned" in second[1]
  doAssert first.waitForExit(10000) == 0
  for kind, path in walkDir(credsDir):
    doAssert path.extractFilename() in ["credentials.json", "operation.lock"], "Leaked temporary credential or response file."
  echo "Spotify CLI verified through fake curl/busctl: local routing, refresh, errors, private files, and no command queue."

when isMainModule:
  main()
