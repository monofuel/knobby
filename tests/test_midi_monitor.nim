import
  std/[os, unittest],
  knobby/midi_monitor

suite "MIDI session lifecycle":
  test "repeated sessions use fresh queue storage":
    let
      directory = getTempDir() / ("knobby-session-test-" & $getCurrentProcessId())
      previousPath = getEnv("PATH")
    createDir(directory)
    writeFile(directory / "aseqdump", "#!/bin/sh\ni=0\nwhile [ $i -lt 512 ]; do\n echo '32:0 Control change 0, controller 19, value 123'\n i=$((i+1))\ndone\necho '0:1 Port unsubscribed 32:0 -> 128:0'\n")
    setFilePermissions(directory / "aseqdump", {fpUserRead, fpUserWrite, fpUserExec})
    putEnv("PATH", directory & ":" & previousPath)
    defer:
      putEnv("PATH", previousPath)
      removeFile(directory / "aseqdump")
      removeDir(directory)
    for session in 0..<100:
      var count = 0
      discard runSeqBatchSession("32:0", proc (lines: seq[string]) =
        count += lines.len)
      check count == 513
