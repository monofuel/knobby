import
  std/[os, osproc, unittest],
  knobby/common

if commandLineParams() == @["--stall"]:
  startProgressWatchdog()
  sleep(35000)
  quit(2)
else:
  suite "main-loop watchdog":
    test "terminates a stalled process for service recovery":
      let child = startProcess(getAppFilename(), args = @["--stall"])
      defer:
        close(child)
      check waitForExit(child, 40000) == 1
