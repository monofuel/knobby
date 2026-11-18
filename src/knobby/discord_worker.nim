import
  std/[json, locks, os, strutils, times],
  ./[controls_state, discord_rpc, runtime]

type
  DiscordCommand* = enum
    ToggleDiscordMute = "toggleMute", ToggleDiscordDeafen = "toggleDeafen"
  DiscordQueueError* = object of IOError
  QueuedDiscordCommand* = object
    command*: DiscordCommand
    queuedMs*: int64
  DiscordTransport* = object
    ## Injected RPC and presence operations; production wraps one Discord IPC client.
    socketPresent*: proc (): bool
    credentialsError*: proc (): string
    connect*: proc ()
    getVoice*: proc (): JsonNode
    setVoice*: proc (settings: JsonNode): JsonNode
    disconnect*: proc ()
    appRunning*: proc (): bool
    clock*: proc (): int64
  DiscordWorker* = object
    transport*: DiscordTransport
    publish*: proc (observation: DiscordObservation)
    log*: proc (message: string)
    observation*: DiscordObservation
    connected*: bool
    backoffMs*: int
    nextAttemptMs*, nextPollMs*, nextPresenceMs*: int64
    lastLog: string

const
  MaxDiscordCommands* = 8
  DiscordPollMs* = 1000
  DiscordPresenceMs* = 1000
  SocketWaitMs* = 1000
  InitialBackoffMs* = 1000
  MaxBackoffMs* = 30_000
  CommandMaxAgeMs* = 3000
  RpcTimeoutMs = 2000
  WorkerSleepMs = 20
  DiscordLaunchCommand* = "Discord"
  DiscordWindowClass* = "discord"
  DiscordProcessName = "Discord"
  DiscordWrappedProcessName = ".Discord-wrappe"

var
  queueLock: Lock
  queued {.guard: queueLock.}: seq[QueuedDiscordCommand]
  accepting {.guard: queueLock.}: bool
  rejectReason {.guard: queueLock.}: string
  discordThread: Thread[void]

initLock(queueLock)

proc queueDiscordCommand*(command: DiscordCommand, nowMs = controlClockMs()) {.gcsafe.} =
  ## Queue a toggle for the connected worker, raising DiscordQueueError with the
  ## reason when Discord is unavailable or earlier presses are still pending.
  {.cast(gcsafe).}:
    withLock queueLock:
      if not accepting:
        let reason = if rejectReason.len > 0: rejectReason else: "Discord control not connected"
        raise newException(DiscordQueueError, "Discord press ignored: " & reason & ".")
      if queued.len >= MaxDiscordCommands:
        raise newException(DiscordQueueError,
          "Discord press ignored: earlier Discord presses are still pending.")
      queued.add(QueuedDiscordCommand(command: command, queuedMs: nowMs))

proc takeDiscordCommands*(): seq[QueuedDiscordCommand] {.gcsafe.} =
  ## Transfer queued toggles to the worker in press order.
  {.cast(gcsafe).}:
    withLock queueLock:
      result = move(queued)
      queued = @[]

proc setDiscordAccepting*(ready: bool, reason = ""): int {.gcsafe.} =
  ## Open or close the queue, discarding pending toggles when it closes so they
  ## are never replayed later; return how many were discarded.
  {.cast(gcsafe).}:
    withLock queueLock:
      accepting = ready
      rejectReason = reason
      if not ready:
        result = queued.len
        queued = @[]

proc isDiscordProcessName*(comm: string): bool =
  ## Report whether a /proc comm value names the installed Discord client.
  comm.strip() in [DiscordProcessName, DiscordWrappedProcessName]

proc discordProcessRunning*(): bool =
  ## Report whether any process named Discord is running.
  for kind, path in walkDir("/proc"):
    let name = path.extractFilename()
    if kind == pcDir and name.len > 0 and name.allCharsInSet(Digits):
      try:
        if readFile(path / "comm").isDiscordProcessName(): return true
      except IOError, OSError:
        # Processes routinely exit between listing /proc and reading comm.
        discard

proc discordWindowId*(windowList: string): string =
  ## Return the first window from `wmctrl -lx` whose WM_CLASS class is exactly discord.
  for line in windowList.splitLines():
    let fields = line.splitWhitespace()
    if fields.len >= 3:
      let parts = fields[2].split('.')
      if parts.len >= 2 and parts[^1] == DiscordWindowClass:
        return fields[0]

proc boolField(data: JsonNode, field: string): tuple[known, value: bool] =
  ## Read a strictly boolean field, reporting absent or malformed values as unknown.
  let node = if data.isNil or data.kind != JObject: nil else: data{field}
  if not node.isNil and node.kind == JBool:
    result = (true, node.getBool())

proc hasVoiceState*(data: JsonNode): bool =
  ## Report whether voice settings include both boolean mute and deaf fields.
  data.boolField("mute").known and data.boolField("deaf").known

proc toggleSettings*(command: DiscordCommand, muted, deafened: bool): JsonNode =
  ## Choose the settings for a toggle from the freshly observed state. Unmuting
  ## while deafened also undeafens, matching Discord's own microphone button.
  case command
  of ToggleDiscordMute:
    if deafened: %*{"mute": false, "deaf": false} else: %*{"mute": not muted}
  of ToggleDiscordDeafen: %*{"deaf": not deafened}

proc note(worker: var DiscordWorker, message: string) =
  ## Log a state change once, suppressing identical repeats.
  if message != worker.lastLog:
    worker.lastLog = message
    if not worker.log.isNil: worker.log(message)

proc newDiscordWorker*(transport: DiscordTransport,
    publish: proc (observation: DiscordObservation),
    log: proc (message: string)): DiscordWorker =
  ## Create a disconnected worker that attempts its first connection immediately.
  DiscordWorker(transport: transport, publish: publish, log: log, backoffMs: InitialBackoffMs)

proc clockMs(worker: DiscordWorker, fallback: int64): int64 =
  ## Re-read production time after blocking calls while allowing deterministic test clocks.
  if worker.transport.clock.isNil: fallback else: worker.transport.clock()

proc applyVoice(worker: var DiscordWorker, data: JsonNode, nowMs: int64) =
  ## Record observed mute and deafen flags, keeping absent fields unknown.
  let
    mute = data.boolField("mute")
    deaf = data.boolField("deaf")
    before = (worker.observation.muteKnown and worker.observation.deafKnown,
      worker.observation.muted, worker.observation.deafened)
  worker.observation.muteKnown = mute.known
  worker.observation.muted = mute.value
  worker.observation.deafKnown = deaf.known
  worker.observation.deafened = deaf.value
  worker.observation.observedMs = nowMs
  worker.observation.updatedMs = int64(epochTime() * 1000)
  if mute.known and deaf.known:
    worker.observation.error = ""
    if before != (true, mute.value, deaf.value):
      worker.note("Discord " & (if mute.value: "muted" else: "unmuted") &
        (if deaf.value: ", deafened." else: ", hearing audio."))
  else:
    worker.observation.error = "Discord did not report mute and deafen state"
    worker.note(worker.observation.error & ".")

proc dropConnection(worker: var DiscordWorker, reason: string, nowMs: int64) =
  ## Close the link, discard pending toggles, and schedule a backed-off reconnect.
  let discarded = setDiscordAccepting(false, reason)
  if worker.connected:
    try:
      worker.transport.disconnect()
    except CatchableError as error:
      worker.note("Closing Discord RPC failed: " & error.msg)
  worker.connected = false
  worker.observation.connected = false
  worker.observation.muteKnown = false
  worker.observation.deafKnown = false
  worker.observation.error = reason
  worker.nextAttemptMs = nowMs + worker.backoffMs
  worker.backoffMs = min(worker.backoffMs * 2, MaxBackoffMs)
  worker.note("Discord control unavailable: " & reason &
    (if discarded > 0: "; discarded " & $discarded & " pending presses." else: "."))

proc waitUnavailable(worker: var DiscordWorker, reason: string, nowMs, retryMs: int64) =
  ## Report a missing prerequisite without counting it as a failed handshake.
  discard setDiscordAccepting(false, reason)
  worker.observation.connected = false
  worker.observation.muteKnown = false
  worker.observation.deafKnown = false
  worker.observation.error = reason
  worker.nextAttemptMs = nowMs + retryMs
  worker.note("Discord control unavailable: " & reason & ".")

proc poll(worker: var DiscordWorker, nowMs: int64) =
  ## Query actual voice settings, dropping the link when Discord stops answering.
  worker.nextPollMs = nowMs + DiscordPollMs
  try:
    let data = worker.transport.getVoice()
    let receivedMs = worker.clockMs(nowMs)
    worker.applyVoice(data, receivedMs)
    worker.nextPollMs = receivedMs + DiscordPollMs
  except CatchableError as error:
    worker.dropConnection("Discord voice status failed: " & error.msg, nowMs)

proc tryConnect(worker: var DiscordWorker, nowMs: int64) =
  ## Connect with saved credentials only; never request interactive authorization.
  let
    socketPresent = worker.transport.socketPresent()
    credentialsError = if socketPresent: worker.transport.credentialsError() else: ""
  if not socketPresent:
    worker.waitUnavailable("Discord is not running", nowMs, SocketWaitMs)
  elif credentialsError.len > 0:
    worker.waitUnavailable(credentialsError, nowMs, MaxBackoffMs)
  else:
    var failure = ""
    try:
      worker.transport.connect()
    except CatchableError as error:
      failure = error.msg
    if failure.len > 0:
      worker.dropConnection("Discord RPC connection failed: " & failure, nowMs)
    else:
      worker.connected = true
      worker.observation.connected = true
      worker.note("Discord RPC connected.")
      worker.poll(nowMs)
      if worker.connected:
        worker.backoffMs = InitialBackoffMs
        discard setDiscordAccepting(true)

proc sendToggle(worker: var DiscordWorker, command: DiscordCommand, nowMs: int64) =
  ## Send one toggle; a failed send is never retried because its effect is uncertain.
  let settings = toggleSettings(command, worker.observation.muted, worker.observation.deafened)
  var
    reported: JsonNode
    failure = ""
  try:
    reported = worker.transport.setVoice(settings)
  except CatchableError as error:
    failure = error.msg
  if failure.len > 0:
    worker.dropConnection("Discord " & $command & " failed and was not retried: " & failure, nowMs)
  elif reported.hasVoiceState():
    let receivedMs = worker.clockMs(nowMs)
    worker.applyVoice(reported, receivedMs)
    worker.nextPollMs = receivedMs + DiscordPollMs
  else:
    worker.poll(nowMs)

proc execute(worker: var DiscordWorker, queuedCommand: QueuedDiscordCommand, nowMs: int64) =
  ## Toggle from freshly read state so changes made in Discord's own UI are respected.
  let command = queuedCommand.command
  if nowMs - queuedCommand.queuedMs > CommandMaxAgeMs:
    worker.note("Discord " & $command & " dropped after waiting too long.")
  else:
    worker.poll(nowMs)
    if worker.connected:
      if worker.observation.muteKnown and worker.observation.deafKnown:
        let dispatchMs = worker.clockMs(nowMs)
        if dispatchMs - queuedCommand.queuedMs > CommandMaxAgeMs:
          worker.note("Discord " & $command & " dropped after waiting too long.")
        else:
          worker.sendToggle(command, dispatchMs)
      else:
        worker.note("Discord " & $command & " ignored: mute and deafen state unknown.")

proc step*(worker: var DiscordWorker, nowMs: int64) =
  ## Advance presence, connection, queued toggles, and polling by one bounded pass.
  if nowMs >= worker.nextPresenceMs:
    worker.observation.running = worker.transport.appRunning()
    worker.nextPresenceMs = nowMs + DiscordPresenceMs
  if not worker.connected and nowMs >= worker.nextAttemptMs:
    worker.tryConnect(nowMs)
  if worker.connected:
    for queuedCommand in takeDiscordCommands():
      if worker.connected:
        worker.execute(queuedCommand, worker.clockMs(nowMs))
    if worker.connected and nowMs >= worker.nextPollMs:
      worker.poll(nowMs)
  if not worker.publish.isNil:
    worker.publish(worker.observation)

proc shutdown*(worker: var DiscordWorker) =
  ## Close the queue and the link when the daemon stops.
  discard setDiscordAccepting(false, "Knobby is stopping")
  if worker.connected:
    worker.connected = false
    worker.transport.disconnect()

proc rpcTransport*(): DiscordTransport =
  ## Wrap one persistent authenticated Discord IPC client owned by the caller's thread.
  var client: DiscordRpcClient
  result.socketPresent = proc (): bool =
    ## Check for a Discord IPC socket without connecting.
    findDiscordSocketPath().len > 0
  result.credentialsError = proc (): string =
    ## Require credentials saved by the one-time authorization example.
    if discordCredsExist(): ""
    else: "No Discord RPC credentials at " & discordCredsPath() &
      "; run examples/discord_auth.nim once"
  result.connect = proc () =
    ## Handshake and authenticate with saved tokens.
    client = connectAuthenticated(RpcTimeoutMs)
  result.getVoice = proc (): JsonNode =
    ## Read the current voice settings.
    client.getVoiceSettings()
  result.setVoice = proc (settings: JsonNode): JsonNode =
    ## Apply voice settings and return Discord's reported settings.
    client.setVoiceSettings(settings)
  result.disconnect = proc () =
    ## Close and forget the client.
    if not client.isNil:
      let closing = client
      client = nil
      closing.close()
  result.appRunning = discordProcessRunning
  result.clock = controlClockMs

proc writeDiscordLog(message: string) =
  ## Write a Discord lifecycle message to the service log.
  stderr.writeLine(message)

proc runDiscord() {.thread.} =
  ## Own the only Discord RPC connection. Discord rate-limits handshakes per
  ## client id, so the link persists and reconnects back off.
  {.cast(gcsafe).}:
    var worker = newDiscordWorker(rpcTransport(), publishDiscordObservation, writeDiscordLog)
    while not shouldStop():
      worker.step(controlClockMs())
      sleep(WorkerSleepMs)
    worker.shutdown()

proc startDiscordWorker*() =
  ## Start the Discord worker; faders and other actions never wait on it.
  createThread(discordThread, runDiscord)

proc stopDiscordWorker*() =
  ## Join the Discord worker after the daemon stop flag is set.
  joinThread(discordThread)
