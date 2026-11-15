import
  std/[os, unittest],
  knobby/midi_monitor

suite "MIDI session lifecycle":
  test "repeated sessions keep independent input buffers":
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

proc withFakeMonitor(script: string, callback: proc ()) =
  ## Run a test with synthetic MIDI output instead of the real ALSA tool.
  let
    directory = getTempDir() / ("knobby-failure-test-" & $getCurrentProcessId())
    previousPath = getEnv("PATH")
  createDir(directory)
  writeFile(directory / "aseqdump", "#!/bin/sh\n" & script)
  setFilePermissions(directory / "aseqdump", {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("PATH", directory & ":" & previousPath)
  defer:
    putEnv("PATH", previousPath)
    removeFile(directory / "aseqdump")
    removeDir(directory)
  callback()

suite "MIDI session failure handling":
  test "preserves final line without a newline":
    withFakeMonitor("printf 'last line'", proc () =
      var captured: seq[string]
      discard runSeqBatchSession("32:0", proc (lines: seq[string]) =
        captured.add(lines))
      check captured == @["last line"])

  test "callback failure cleans up a producer and permits a new session":
    withFakeMonitor("while :; do echo event; done", proc () =
      expect IOError:
        discard runSeqBatchSession("32:0", proc (lines: seq[string]) =
          raise newException(IOError, "synthetic callback failure")))
    withFakeMonitor("echo recovered", proc () =
      var captured: seq[string]
      discard runSeqBatchSession("32:0", proc (lines: seq[string]) =
        captured.add(lines))
      check captured == @["recovered"])

  test "rejects unbounded lines":
    withFakeMonitor("i=0; while [ $i -lt 7000 ]; do printf abcdefghijklmnop; i=$((i+1)); done", proc () =
      expect IOError:
        discard runSeqBatchSession("32:0", proc (lines: seq[string]) =
          discard))
