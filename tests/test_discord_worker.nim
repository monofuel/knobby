import
  std/[json, strutils, unittest],
  knobby/[controls_state, discord_worker]

type
  FakeDiscord = ref object
    socket, running: bool
    credentialsError: string
    connects, disconnects, gets: int
    connectFailure, getFailure, setFailure: string
    voice: JsonNode
    sets: seq[JsonNode]
    setReply: JsonNode
    useSetReply: bool

proc newFakeDiscord(): FakeDiscord =
  ## Create a running, authorized Discord fake that is unmuted and hearing audio.
  FakeDiscord(socket: true, running: true, voice: %*{"mute": false, "deaf": false})

proc transport(fake: FakeDiscord): DiscordTransport =
  ## Expose the fake through the worker's injected transport without any socket I/O.
  result.socketPresent = proc (): bool = fake.socket
  result.credentialsError = proc (): string = fake.credentialsError
  result.connect = proc () =
    inc fake.connects
    if fake.connectFailure.len > 0: raise newException(IOError, fake.connectFailure)
  result.getVoice = proc (): JsonNode =
    inc fake.gets
    if fake.getFailure.len > 0: raise newException(IOError, fake.getFailure)
    fake.voice.copy()
  result.setVoice = proc (settings: JsonNode): JsonNode =
    fake.sets.add(settings)
    if fake.setFailure.len > 0: raise newException(IOError, fake.setFailure)
    for key, value in settings: fake.voice[key] = value
    if fake.useSetReply: fake.setReply else: fake.voice.copy()
  result.disconnect = proc () = inc fake.disconnects
  result.appRunning = proc (): bool = fake.running

proc newWorker(fake: FakeDiscord, logs: ref seq[string] = nil): DiscordWorker =
  ## Build a worker around the fake that records log lines without publishing globally.
  newDiscordWorker(fake.transport(), nil, proc (message: string) =
    ## Keep log lines for assertions.
    if not logs.isNil: logs[].add(message))

proc withPublished(observation: DiscordObservation): DiscordObservation =
  ## Mark a captured observation as published, as the shared state does.
  result = observation
  result.published = true

proc status(worker: DiscordWorker, nowMs: int64): JsonNode =
  ## Render the worker's observation through the shared status contract.
  discordStatus(worker.observation.withPublished(), nowMs)

proc reset() =
  ## Close the global queue so tests start without leftover presses.
  discard setDiscordAccepting(false, "")
  discard takeDiscordCommands()

suite "Discord worker":
  setup:
    reset()

  test "connects with saved credentials and reports actual mute and deafen":
    let fake = newFakeDiscord()
    fake.voice = %*{"mute": true, "deaf": false}
    var worker = newWorker(fake)
    worker.step(1000)
    check fake.connects == 1
    check worker.connected
    let current = worker.status(1000)
    check current["state"].getStr() == "ready"
    check current["muted"].getBool()
    check not current["deafened"].getBool()
    check current["running"].getBool()

  test "polls once per second and follows changes made in Discord's own UI":
    let fake = newFakeDiscord()
    var worker = newWorker(fake)
    worker.step(1000)
    check fake.gets == 1
    worker.step(1500)
    check fake.gets == 1
    fake.voice = %*{"mute": true, "deaf": true}
    worker.step(2000)
    check fake.gets == 2
    check worker.status(2000)["deafened"].getBool()
    check controlVisualState("discord", %*{"discord": worker.status(2000)}) == "deafened"

  test "absent or malformed voice fields are unavailable rather than false":
    let fake = newFakeDiscord()
    fake.voice = %*{"mute": false}
    var worker = newWorker(fake)
    worker.step(1000)
    check worker.connected
    var current = worker.status(1000)
    check current["state"].getStr() == "unavailable"
    check "mute and deafen" in current["error"].getStr()
    fake.voice = %*{"mute": "no", "deaf": false}
    worker.step(2000)
    check worker.status(2000)["state"].getStr() == "unavailable"
    fake.voice = %*{"mute": false, "deaf": false}
    worker.step(3000)
    check worker.status(3000)["state"].getStr() == "ready"

  test "toggles read fresh state so external changes are respected":
    let fake = newFakeDiscord()
    var worker = newWorker(fake)
    worker.step(1000)
    fake.voice = %*{"mute": true, "deaf": false}
    queueDiscordCommand(ToggleDiscordMute, 1100)
    worker.step(1100)
    check fake.sets == @[%*{"mute": false}]
    check not worker.status(1100)["muted"].getBool()

  test "slow successful queries cannot dispatch expired presses":
    let fake = newFakeDiscord()
    var
      clock = 1000'i64
      backend = fake.transport()
      slow = false
    let getVoice = backend.getVoice
    backend.clock = proc (): int64 = clock
    backend.getVoice = proc (): JsonNode =
      if slow: clock += CommandMaxAgeMs + 1
      getVoice()
    var worker = newDiscordWorker(backend, nil, nil)
    worker.step(clock)
    queueDiscordCommand(ToggleDiscordMute, clock)
    slow = true
    worker.step(clock)
    check fake.sets.len == 0
    check worker.observation.observedMs == clock

  test "each queued press checks the current clock after earlier commands":
    let fake = newFakeDiscord()
    var
      clock = 1000'i64
      backend = fake.transport()
    let setVoice = backend.setVoice
    backend.clock = proc (): int64 = clock
    backend.setVoice = proc (settings: JsonNode): JsonNode =
      clock += CommandMaxAgeMs + 1
      setVoice(settings)
    var worker = newDiscordWorker(backend, nil, nil)
    worker.step(clock)
    queueDiscordCommand(ToggleDiscordMute, clock)
    queueDiscordCommand(ToggleDiscordDeafen, clock)
    worker.step(clock)
    check fake.sets.len == 1

  test "unmuting while deafened also undeafens, and deafen toggles only deaf":
    let fake = newFakeDiscord()
    var worker = newWorker(fake)
    worker.step(1000)
    queueDiscordCommand(ToggleDiscordDeafen, 1000)
    worker.step(1010)
    check fake.sets[^1] == %*{"deaf": true}
    fake.voice = %*{"mute": true, "deaf": true}
    queueDiscordCommand(ToggleDiscordMute, 1020)
    worker.step(1020)
    check fake.sets[^1] == %*{"mute": false, "deaf": false}
    let current = worker.status(1020)
    check not current["muted"].getBool()
    check not current["deafened"].getBool()
    check toggleSettings(ToggleDiscordDeafen, true, true) == %*{"deaf": false}

  test "an incomplete SET reply is followed by a real query":
    let fake = newFakeDiscord()
    fake.useSetReply = true
    fake.setReply = %*{"mute": true}
    var worker = newWorker(fake)
    worker.step(1000)
    let before = fake.gets
    queueDiscordCommand(ToggleDiscordMute, 1000)
    worker.step(1010)
    check fake.gets == before + 2
    check worker.status(1010)["muted"].getBool()

  test "presses are rejected with the reason while Discord is unavailable":
    let fake = newFakeDiscord()
    fake.socket = false
    fake.running = false
    var worker = newWorker(fake)
    worker.step(1000)
    check fake.connects == 0
    try:
      queueDiscordCommand(ToggleDiscordMute, 1000)
      check false
    except DiscordQueueError as error:
      check "Discord is not running" in error.msg
    let current = worker.status(1000)
    check current["state"].getStr() == "unavailable"
    check not current["running"].getBool()
    check not current["muted"].getBool()

  test "missing credentials never prompt and are reported":
    let fake = newFakeDiscord()
    fake.credentialsError = "No Discord RPC credentials at /x; run examples/discord_auth.nim once"
    var worker = newWorker(fake)
    worker.step(1000)
    check fake.connects == 0
    check "credentials" in worker.status(1000)["error"].getStr()
    expect DiscordQueueError:
      queueDiscordCommand(ToggleDiscordDeafen, 1000)

  test "the queue is bounded":
    let fake = newFakeDiscord()
    var worker = newWorker(fake)
    worker.step(1000)
    for _ in 0..<MaxDiscordCommands:
      queueDiscordCommand(ToggleDiscordMute, 1000)
    try:
      queueDiscordCommand(ToggleDiscordMute, 1000)
      check false
    except DiscordQueueError as error:
      check "still pending" in error.msg
    check takeDiscordCommands().len == MaxDiscordCommands

  test "a failed toggle is never replayed and reconnects back off to thirty seconds":
    let
      fake = newFakeDiscord()
      logs = new seq[string]
    var worker = newWorker(fake, logs)
    worker.step(1000)
    queueDiscordCommand(ToggleDiscordMute, 1000)
    queueDiscordCommand(ToggleDiscordDeafen, 1000)
    fake.setFailure = "Discord RPC response deadline exceeded."
    worker.step(1010)
    check fake.sets.len == 1
    check not worker.connected
    check fake.disconnects == 1
    check worker.status(1010)["state"].getStr() == "unavailable"
    check "not retried" in worker.status(1010)["error"].getStr()
    check takeDiscordCommands().len == 0
    expect DiscordQueueError:
      queueDiscordCommand(ToggleDiscordMute, 1010)
    fake.setFailure = ""
    fake.connectFailure = "Discord closed the connection"
    var
      now = 1010'i64
      attempts: seq[int64]
    while now < 200_000:
      let before = fake.connects
      worker.step(now)
      if fake.connects > before: attempts.add(now)
      now += 10
    check attempts.len >= 6
    for index in 1..<attempts.len:
      check attempts[index] - attempts[index - 1] <= MaxBackoffMs + 10
    check attempts[^1] - attempts[^2] >= MaxBackoffMs
    check fake.sets.len == 1
    fake.connectFailure = ""
    while not worker.connected:
      worker.step(now)
      now += 10
    check fake.sets.len == 1
    check worker.backoffMs == InitialBackoffMs
    var connectedLogs = 0
    for line in logs[]:
      if line == "Discord RPC connected.": inc connectedLogs
    check connectedLogs == 2

  test "a status timeout drops the link without sending queued toggles":
    let fake = newFakeDiscord()
    var worker = newWorker(fake)
    worker.step(1000)
    queueDiscordCommand(ToggleDiscordMute, 1000)
    fake.getFailure = "Discord RPC response deadline exceeded."
    worker.step(1010)
    check fake.sets.len == 0
    check not worker.connected
    check "deadline" in worker.status(1010)["error"].getStr()

  test "stale presses are dropped instead of applied late":
    let fake = newFakeDiscord()
    var worker = newWorker(fake)
    worker.step(1000)
    queueDiscordCommand(ToggleDiscordMute, 1000)
    worker.step(1000 + CommandMaxAgeMs + 1)
    check fake.sets.len == 0

  test "observations go stale when the worker stops updating":
    let fake = newFakeDiscord()
    var worker = newWorker(fake)
    worker.step(1000)
    check worker.status(1000 + ControlStaleMs)["state"].getStr() == "ready"
    let stale = worker.status(1001 + ControlStaleMs)
    check stale["state"].getStr() == "unavailable"
    check stale["running"].getBool()
    check "stale" in stale["error"].getStr()

  test "identical failures are logged once":
    let
      fake = newFakeDiscord()
      logs = new seq[string]
    fake.socket = false
    var worker = newWorker(fake, logs)
    for now in countup(1000, 20_000, 500):
      worker.step(now)
    check logs[].len == 1

suite "Discord app helpers":
  test "window focus requires the exact discord WM_CLASS":
    let listing = """
0x02200003  0 firefox.firefox       high-steel discord - Mozilla Firefox
0x03a00007  0 discordcanary.discordcanary high-steel Canary
0x03c00004  0 discord.discord       high-steel #general - Discord
"""
    check discordWindowId(listing) == "0x03c00004"
    check discordWindowId("0x1  0 firefox.firefox host discord.discord") == ""
    check discordWindowId("") == ""

  test "process presence matches the installed client name":
    check isDiscordProcessName("Discord\n")
    check isDiscordProcessName(".Discord-wrappe\n")
    check not isDiscordProcessName("discord-canary")
    check not isDiscordProcessName("Discordo")
