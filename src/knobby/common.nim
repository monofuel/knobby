import
  std/[atomics, locks, monotimes, os, osproc, posix, strutils, times]

const
  AppName* = "Knobby"
  AppDescription* = "MIDI controller daemon."
  ReconnectPollIntervalMs* = 1000
  DevelopmentFont = currentSourcePath().parentDir().parentDir().parentDir() /
    "gui/app/assets/DejaVuSans.ttf"

var spawnLock: Lock
initLock(spawnLock)

proc knobbyFontPath*(): string =
  ## Locate the same bundled font in an installed package or development checkout.
  for candidate in [getAppDir() / "../share/knobby/DejaVuSans.ttf", DevelopmentFont]:
    if fileExists(candidate):
      return candidate
  raise newException(IOError, "Knobby's bundled DejaVu Sans font is unavailable.")

proc runCommand*(command: string, args: seq[string]): string =
  ## Run a command and capture its output. Holds the spawn lock so a fork on
  ## another thread can never inherit this command's half-set-up pipes, which
  ## would block the output read from ever reaching end-of-file.
  withLock spawnLock:
    result = execProcess(
      command,
      args = args,
      options = {poUsePath, poStdErrToStdOut}
    )

proc spawnCommand*(command: string, args: seq[string],
    options: set[ProcessOption] = {poUsePath, poStdErrToStdOut}): Process =
  ## Start a long-running command, holding the spawn lock (see runCommand).
  withLock spawnLock:
    result = startProcess(command, args = args, options = options)

proc runShellCommand*(command: string): tuple[output: string, exitCode: int] =
  ## Run a shell command line, holding the spawn lock (see runCommand).
  withLock spawnLock:
    result = execCmdEx(command)

const
  AudioCommandTimeoutMs = 1000
  AudioCommandPollMs = 5

proc runAudioCommand*(command: string, args: seq[string]): string =
  ## Return stdout within a deadline, draining stderr separately and retaining it on failure.
  withLock spawnLock:
    let
      process = startProcess(command, args = args,
        options = {poUsePath})
      started = getMonoTime()
      handles = [process.outputHandle.cint, process.errorHandle.cint]
    defer:
      if running(process):
        kill(process)
      discard waitForExit(process)
      close(process)
    for handle in handles:
      let flags = fcntl(handle, F_GETFL, 0)
      if flags < 0 or fcntl(handle, F_SETFL, flags or O_NONBLOCK) < 0:
        raiseOSError(osLastError())
    var
      buffer: array[4096, char]
      captured: array[2, string]
      ended: array[2, bool]
    while not (ended[0] and ended[1]):
      var received = false
      for pipe, handle in handles:
        if ended[pipe]: continue
        let size = posix.read(handle, addr buffer[0], buffer.len)
        if size > 0:
          received = true
          for index in 0..<int(size):
            captured[pipe].add(buffer[index])
        elif size == 0:
          ended[pipe] = true
        elif errno != EAGAIN and errno != EINTR:
          raiseOSError(osLastError())
      if (getMonoTime() - started).inMilliseconds >= AudioCommandTimeoutMs:
        raise newException(OSError, command & " " & args.join(" ") &
          ": timed out after " & $AudioCommandTimeoutMs & " ms.")
      if not received and not (ended[0] and ended[1]):
        sleep(AudioCommandPollMs)
    while running(process):
      if (getMonoTime() - started).inMilliseconds >= AudioCommandTimeoutMs:
        raise newException(OSError, command & " " & args.join(" ") & ": timed out.")
      sleep(AudioCommandPollMs)
    let exitCode = waitForExit(process)
    if exitCode != 0:
      raise newException(OSError, command & " " & args.join(" ") &
        ": exit " & $exitCode & ": " & captured[0].strip() & "\n" & captured[1].strip())
    result = move(captured[0])


const
  ProgressTimeoutMs = 30000
  ProgressCheckMs = 1000

var
  lastProgress: Atomic[int64]
  progressThread: Thread[void]

proc markProgress*() =
  ## Record main-loop progress without depending on subprocess locks.
  lastProgress.store(getMonoTime().ticks div 1_000_000)

proc watchProgress() {.thread.} =
  ## Exit a stalled daemon so systemd can restart it.
  while true:
    sleep(ProgressCheckMs)
    if getMonoTime().ticks div 1_000_000 - lastProgress.load() > ProgressTimeoutMs:
      stderr.writeLine("Knobby main loop stalled for 30 seconds; exiting for restart.")
      quit(1)

proc startProgressWatchdog*() =
  ## Start the watchdog only in the daemon, not in library consumers or tests.
  markProgress()
  createThread(progressThread, watchProgress)
