import
  std/[atomics, posix]

var stopping: Atomic[bool]

proc shouldStop*(): bool =
  ## Check the daemon's process-wide shutdown request without taking a lock.
  stopping.load()

proc requestStop*() =
  ## Ask independent workers to finish their bounded operations and release devices.
  stopping.store(true)

proc controlC() {.noconv.} =
  ## Request shutdown without doing I/O in the control-C handler.
  requestStop()

proc terminate(signal: cint) {.noconv.} =
  ## Convert systemd's termination signal into a cooperative shutdown request.
  requestStop()

proc installStopHooks*() =
  ## Handle interactive and service shutdown using the same worker stop flag.
  setControlCHook(controlC)
  posix.signal(SIGTERM, terminate)
