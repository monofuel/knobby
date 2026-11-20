import
  std/[json, os, osproc, sequtils, strutils, unittest],
  knobby/[ipc, obs_state, obs_worker, status]

const
  Ready = """{"type":"status","connected":true,"workspaceReady":true,"minecraftReady":true,"recording":false,"paused":false,"micMuted":true,"transitioning":false,"error":""}"""
  WaitMs = 8000

var fixtureNumber = 0

proc fixture(script: string): tuple[directory, helper: string] =
  ## Build a private process fixture without OBS, audio, or hardware access.
  inc fixtureNumber
  result.directory = getTempDir() / ("knobby-obs-worker-" & $getCurrentProcessId() & "-" & $fixtureNumber)
  createDir(result.directory)
  result.helper = result.directory / "helper"
  let content = script.replace("@READY@", quoteShell(Ready))
    .replace("@EVENTS@", quoteShell(result.directory / "events"))
    .replace("@STARTS@", quoteShell(result.directory / "starts"))
  writeFile(result.helper, "#!/bin/sh\n" & content)
  setFilePermissions(result.helper, {fpUserRead, fpUserWrite, fpUserExec})

proc awaitCondition(condition: proc (): bool) =
  ## Wait a bounded interval for a real worker/process boundary to become observable.
  let deadline = monotonicMs() + WaitMs
  while not condition():
    if monotonicMs() > deadline: raise newException(IOError, "OBS worker fixture timed out.")
    sleep(10)

proc lineCount(path: string): int =
  ## Count complete events retained by the private helper fixture.
  if fileExists(path): result = readFile(path).splitLines().filterIt(it.len > 0).len

suite "OBS process supervision":
  setup:
    initializeState("obs-worker-test", [47, 127, 127, 127])
    setObsStatus(unavailableObsStatus())

  test "queues commands and publishes the helper's authoritative state":
    let f = fixture("""
printf '%s\n' @READY@
while IFS= read -r line; do
  printf '%s\n' "$line" >> @EVENTS@
  id=${line#*\"id\":\"}
  id=${id%%\"*}
  printf '{"type":"result","id":"%s","ok":true,"error":""}\n' "$id"
done
""")
    startObsWorker(f.helper)
    defer:
      stopObsWorker()
      removeDir(f.directory)
    awaitCondition(proc (): bool = readObsStatus(){"connected"}.getBool())
    let id = queueObsOperation("micToggle")
    awaitCondition(proc (): bool = lineCount(f.directory / "events") == 1)
    let command = parseJson(readFile(f.directory / "events").strip())
    check command["id"].getStr() == id
    check command["operation"].getStr() == "micToggle"
    check readObsStatus()["micMuted"].getBool()
    check readFaderPositions() == [47, 127, 127, 127]

  test "commands whose result was lost are not replayed after helper restart":
    let f = fixture("""
printf 'start\n' >> @STARTS@
printf '%s\n' @READY@
while IFS= read -r line; do
  printf '%s\n' "$line" >> @EVENTS@
  exit 0
done
""")
    startObsWorker(f.helper)
    defer:
      stopObsWorker()
      removeDir(f.directory)
    awaitCondition(proc (): bool = readObsStatus(){"connected"}.getBool())
    discard queueObsOperation("recordToggle")
    awaitCondition(proc (): bool = lineCount(f.directory / "starts") >= 2)
    check lineCount(f.directory / "events") == 1
    check "not replayed" in readKnobbyState().actionError

  test "a closed helper input pipe cannot terminate the daemon":
    let f = fixture("""
exec 0<&-
printf '%s\n' @READY@
sleep 3
""")
    startObsWorker(f.helper)
    defer:
      stopObsWorker()
      removeDir(f.directory)
    awaitCondition(proc (): bool = readObsStatus(){"connected"}.getBool())
    discard queueObsOperation("recordToggle")
    awaitCondition(proc (): bool = readObsStatus(){"error"}.getStr().len > 0)
    check not readObsStatus()["connected"].getBool()
    check readFaderPositions() == [47, 127, 127, 127]

  test "setup selection needs a live connection while the Firefox launcher does not":
    let f = fixture("""
IFS= read -r line
printf '%s\n' "$line" >> @EVENTS@
sleep 3
""")
    startObsWorker(f.helper)
    defer:
      stopObsWorker()
      removeDir(f.directory)
    for operation in ["selectMinecraft", "selectFirefox"]:
      expect IOError: discard queueObsOperation(operation)
    discard queueObsOperation("firefox1080")
    awaitCondition(proc (): bool = lineCount(f.directory / "events") == 1)
    check "firefox1080" in readFile(f.directory / "events")

  test "a stalled helper becomes unavailable without claiming recording stopped":
    let f = fixture("""
printf '%s\n' @READY@
IFS= read -r line
""")
    startObsWorker(f.helper)
    defer:
      stopObsWorker()
      removeDir(f.directory)
    awaitCondition(proc (): bool = readObsStatus(){"connected"}.getBool())
    awaitCondition(proc (): bool = "stopped reporting" in readObsStatus(){"error"}.getStr())
    check not readObsStatus()["connected"].getBool()
    expect IOError: discard queueObsOperation("recordToggle")
