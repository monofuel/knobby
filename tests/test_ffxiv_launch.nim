import
  std/[json, os, strutils, tempfiles, unittest],
  knobby/[actions, bindings]

proc writeHelper(path, body: string) =
  ## Create an inert executable used only by the isolated command dispatcher.
  writeFile(path, "#!/bin/sh\nset -eu\n" & body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc capturedFfxivCommand(running: bool): tuple[launch, focus: seq[string]] =
  ## Capture production dispatch with no real process lookup, application launch or focus change.
  let
    directory = createTempDir("knobby-ffxiv-route-", "")
    oldPath = getEnv("PATH")
    oldCapture = getEnv("KNOBBY_FFXIV_CAPTURE")
    oldPresent = getEnv("KNOBBY_FFXIV_PRESENT")
  defer:
    putEnv("PATH", oldPath)
    putEnv("KNOBBY_FFXIV_CAPTURE", oldCapture)
    putEnv("KNOBBY_FFXIV_PRESENT", oldPresent)
    removeDir(directory)
  writeHelper(directory / "pgrep", "exit \"$KNOBBY_FFXIV_PRESENT\"\n")
  writeHelper(directory / "systemd-run", "printf '%s\\n' \"$@\" > \"$KNOBBY_FFXIV_CAPTURE/launch\"\n")
  writeHelper(directory / "wmctrl", "printf '%s\\n' \"$@\" > \"$KNOBBY_FFXIV_CAPTURE/focus\"\n")
  putEnv("PATH", directory)
  putEnv("KNOBBY_FFXIV_CAPTURE", directory)
  putEnv("KNOBBY_FFXIV_PRESENT", if running: "0" else: "1")
  executeButtonAction(%*{"kind": "ffxiv"})
  for (name, destination) in [("launch", addr result.launch), ("focus", addr result.focus)]:
    if fileExists(directory / name):
      destination[] = readFile(directory / name).strip().splitLines()

suite "FFXIV shortcut dispatch":
  test "the absent-game path requests the existing regular Steam shortcut":
    let
      captured = capturedFfxivCommand(false)
      regularGameId = (2222931220'u64 shl 32) or 0x02000000'u64
    check captured.focus.len == 0
    check captured.launch[^3..^1] == @["/bin/sh", "-c", "steam steam://rungameid/" & $regularGameId]
    check "9332724227821797376" notin captured.launch.join(" ")
    check "15551716329877667840" notin captured.launch.join(" ")

  test "a running game keeps the existing focus behavior without launching Steam":
    let captured = capturedFfxivCommand(true)
    check captured.launch.len == 0
    check captured.focus == @["-a", "FINAL FANTASY XIV"]
    check buttonBinding(10).action == LaunchFfxiv
