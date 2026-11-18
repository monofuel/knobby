import
  std/[monotimes, os, strutils, tempfiles, times, unittest],
  knobby/[common, discord_rpc]

const
  ProbeArgument = "--knobby-spawn-probe"
  ReadyVariable = "KNOBBY_TOKEN_FIXTURE_READY"
  FixtureDelayMs = 700
  ProbeLimitMs = 400
  FixtureWaitMs = 5000

proc fakeCurl() =
  ## Emulate curl using only fixture files, never contacting Discord or an audio device.
  if paramStr(1) == ProbeArgument:
    echo "ready"
  else:
    var output = ""
    for index in 1..<paramCount():
      if paramStr(index) == "--output": output = paramStr(index + 1)
    writeFile(getEnv(ReadyVariable), "ready")
    sleep(FixtureDelayMs)
    const Payload = "{\"access_token\":\"fixture-access\",\"refresh_token\":\"fixture-refresh\"}"
    if output.len > 0: writeFile(output, Payload)
    else: echo Payload

proc refreshFixture() {.thread.} =
  ## Exercise the real token refresh path with fixture credentials and a fake curl binary.
  {.cast(gcsafe).}:
    var creds = DiscordCreds(clientId: "fixture", clientSecret: "fixture",
      refreshToken: "fixture-old")
    refreshTokens(creds)

proc refreshProbeLatency(): int64 =
  ## Measure an unrelated subprocess while a token request waits for the network.
  let
    directory = createTempDir("knobby-token-refresh-", "")
    previousPath = getEnv("PATH")
    previousConfig = getEnv("XDG_CONFIG_HOME")
    ready = directory / "ready"
  defer:
    putEnv("PATH", previousPath)
    putEnv("XDG_CONFIG_HOME", previousConfig)
    delEnv(ReadyVariable)
    removeDir(directory)
  copyFile(getAppFilename(), directory / "curl")
  setFilePermissions(directory / "curl", {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("PATH", directory & ":" & previousPath)
  putEnv("XDG_CONFIG_HOME", directory / "config")
  putEnv(ReadyVariable, ready)
  var worker: Thread[void]
  createThread(worker, refreshFixture)
  defer: joinThread(worker)
  let deadline = getMonoTime() + initDuration(milliseconds = FixtureWaitMs)
  while not fileExists(ready) and getMonoTime() < deadline: sleep(5)
  if not fileExists(ready):
    raise newException(IOError, "Token refresh fixture did not start.")
  let started = getMonoTime()
  let output = runAudioCommand(directory / "curl", @[ProbeArgument]).strip()
  result = (getMonoTime() - started).inMilliseconds
  if output != "ready":
    raise newException(IOError, "Audio command fixture did not answer.")

when isMainModule:
  if paramCount() > 0:
    fakeCurl()
  else:
    suite "Discord OAuth worker isolation":
      test "token refresh does not hold the audio subprocess lock":
        check refreshProbeLatency() < ProbeLimitMs
