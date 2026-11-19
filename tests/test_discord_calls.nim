import
  std/[json, sequtils, strutils, tables, unittest],
  knobby/discord_calls

type
  FakeBus = ref object
    replies: Table[string, seq[JsonNode]]
    failures: Table[string, string]
    calls: seq[string]
    comm: Table[int, string]
    nowMs: int64
    stepMs: int64

const
  Address = "unix:path=/fake/bus"
  AppBus = ":1.50"
  OtherBus = ":1.51"
  Root = "/org/a11y/atspi/accessible/root"
  DiscordPid = 4242
  ShowingWord = (1'i64 shl 25) or (1'i64 shl 30)
  UsableWord = (1'i64 shl 8) or (1'i64 shl 24) or ShowingWord
  DialogMatch = "call :1.50 " & Root & " org.a11y.atspi.Collection GetMatches " &
    "(aiia{ss}iaiiasib)uib 0 1 0 1 4 65540 0 0 0 2 0 1 false 1 5 true"

proc methodReply(value: JsonNode): JsonNode =
  ## Shape a busctl method reply whose data is the argument array.
  %*{"type": "x", "data": [value]}

proc propertyReply(value: JsonNode): JsonNode =
  ## Shape a busctl get-property reply whose data is a scalar.
  %*{"type": "x", "data": value}

proc refsNode(bus: string, paths: seq[string]): JsonNode =
  ## Build an a(so) reference list.
  result = newJArray()
  for path in paths: result.add(%*[bus, path])

proc set(bus: FakeBus, key: string, replies: varargs[JsonNode]) =
  ## Queue replies for a request; the last one repeats.
  bus.replies[key] = @replies

proc transport(bus: FakeBus): CallTransport =
  ## Wrap the fake in the injected transport.
  result.resolveAddress = proc (): string = Address
  result.call = proc (address: string, args: seq[string], timeoutMs: int): JsonNode =
    doAssert address == Address
    doAssert timeoutMs > 0 and timeoutMs <= BusctlTimeoutMs
    let key = args.join(" ")
    bus.calls.add(key)
    bus.nowMs += bus.stepMs
    if key in bus.failures: raise newException(OSError, bus.failures[key])
    if key notin bus.replies: raise newException(OSError, "no such object: " & key)
    let queued = bus.replies[key]
    result = queued[0]
    if queued.len > 1: bus.replies[key] = queued[1..^1]
  result.processName = proc (pid: int): string = bus.comm.getOrDefault(pid, "")
  result.clock = proc (): int64 = bus.nowMs

proc addApps(bus: FakeBus) =
  ## Register one unrelated app and one verified Discord app.
  bus.set("call org.a11y.atspi.Registry " & Root & " org.a11y.atspi.Accessible GetChildren",
    methodReply(%*[[OtherBus, Root], [AppBus, Root]]))
  bus.set("get-property " & OtherBus & " " & Root & " org.a11y.atspi.Accessible Name",
    propertyReply(%"Firefox"))
  bus.set("get-property " & AppBus & " " & Root & " org.a11y.atspi.Accessible Name",
    propertyReply(%"Discord"))
  bus.set("call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus " &
    "GetConnectionUnixProcessID s " & AppBus, methodReply(%DiscordPid))
  bus.comm[DiscordPid] = ".Discord-wrappe"
  bus.set("call " & AppBus & " " & Root & " org.a11y.atspi.Accessible GetChildren",
    methodReply(refsNode(AppBus, @["/frame"])))
  bus.set("call " & AppBus & " /frame org.a11y.atspi.Accessible GetAttributes",
    methodReply(newJObject()))

proc addButton(bus: FakeBus, path, name: string, word = UsableWord, actions = @["press"]) =
  ## Describe one push button and its actions.
  bus.set("get-property " & AppBus & " " & path & " org.a11y.atspi.Accessible Name",
    propertyReply(%name))
  bus.set("call " & AppBus & " " & path & " org.a11y.atspi.Accessible GetRole",
    methodReply(%PushButtonRole))
  bus.set("call " & AppBus & " " & path & " org.a11y.atspi.Accessible GetState",
    methodReply(%*[word, 0]))
  bus.set("get-property " & AppBus & " " & path & " org.a11y.atspi.Action NActions",
    propertyReply(%actions.len))
  for index, action in actions:
    bus.set("call " & AppBus & " " & path & " org.a11y.atspi.Action GetName i " & $index,
      methodReply(%action))
    bus.set("call " & AppBus & " " & path & " org.a11y.atspi.Action DoAction i " & $index,
      methodReply(%true))

proc addDialog(bus: FakeBus, path, name: string, buttons: seq[(string, string)]) =
  ## Describe one showing dialog and its scoped buttons.
  bus.set("call " & AppBus & " " & path & " org.a11y.atspi.Accessible GetRole",
    methodReply(%DialogRole))
  bus.set("call " & AppBus & " " & path & " org.a11y.atspi.Accessible GetState",
    methodReply(%*[ShowingWord, 0]))
  bus.set("get-property " & AppBus & " " & path & " org.a11y.atspi.Accessible Name",
    propertyReply(%name))
  bus.set("get-property " & AppBus & " " & path & " org.a11y.atspi.Accessible Description",
    propertyReply(%""))
  bus.set("call " & AppBus & " " & path & " org.a11y.atspi.Collection GetMatches " &
    "(aiia{ss}iaiiasib)uib 0 1 0 1 4 0 2048 0 0 2 0 1 false 1 17 true",
    methodReply(refsNode(AppBus, buttons.mapIt(it[0]))))
  for (buttonPath, caption) in buttons: bus.addButton(buttonPath, caption)

proc showDialogs(bus: FakeBus, paths: seq[string]) =
  ## Set which dialogs the app root reports.
  bus.set(DialogMatch, methodReply(refsNode(AppBus, paths)))

proc newFakeBus(): FakeBus =
  ## Create a fake with Discord registered and no dialogs open.
  result = FakeBus(nowMs: 10_000)
  result.addApps()
  result.showDialogs(@[])

proc button(name: string, word = UsableWord): CallButton =
  ## Build a classified button fixture.
  CallButton(target: AtspiRef(bus: AppBus, path: "/" & name), name: name,
    role: PushButtonRole, states: @[word, 0])

proc dialog(name: string, buttons: seq[CallButton]): CallDialog =
  ## Build a showing dialog fixture.
  CallDialog(target: AtspiRef(bus: AppBus, path: "/dialog"), name: name,
    role: DialogRole, states: @[ShowingWord, 0], buttons: buttons)

proc ringing(): DiscordCallStatus =
  ## A fresh ringing status offering both answer kinds.
  DiscordCallStatus(published: true, state: CallRinging, voiceAvailable: true,
    videoAvailable: true, observedMs: 10_000)

proc resetShared() =
  ## Clear the shared queue between tests.
  discard publishDiscordCallStatus(DiscordCallStatus())
  discard takeDiscordCalls()

proc ignoreLog(message: string) =
  ## Discard worker log lines in tests.
  discard

proc doActions(bus: FakeBus): seq[string] =
  ## List DoAction requests sent so far.
  bus.calls.filterIt("DoAction" in it)

suite "Discord incoming call classification":
  test "no dialogs is idle":
    check classifyDialogs(@[]).state == CallIdle

  test "incoming dialog separates voice and video answers":
    let scan = classifyDialogs(@[dialog("Incoming Call",
      @[button("Join Call"), button("Join Video Call"), button("Decline")])])
    check scan.state == CallRinging
    check scan.voiceFound and scan.videoFound
    check scan.voice.name == "Join Call"
    check scan.video.name == "Join Video Call"
    check scan.error == ""

  test "decline sibling with a call caption qualifies without incoming text":
    let scan = classifyDialogs(@[dialog("", @[button("Accept Video Call"), button("Reject")])])
    check scan.state == CallRinging
    check scan.videoFound and not scan.voiceFound

  test "friend request Accept and Decline is not a call":
    check classifyDialogs(@[dialog("Friend Request",
      @[button("Accept"), button("Decline")])]).state == CallIdle

  test "start call, camera, and Join Call outside an incoming dialog are ignored":
    check classifyDialogs(@[dialog("Voice Settings",
      @[button("Start Call"), button("Start Video Call"), button("Turn On Camera"),
        button("Join Call")])]).state == CallIdle

  test "disabled or hidden answer buttons are not available":
    let scan = classifyDialogs(@[dialog("Incoming Call",
      @[button("Join Call", ShowingWord), button("Join Video Call", 0)])])
    check scan.state == CallRinging
    check not scan.voiceFound and not scan.videoFound
    check "no answer buttons" in scan.error

  test "duplicate voice candidates are ambiguous":
    let scan = classifyDialogs(@[dialog("Incoming Call",
      @[button("Join Call"), button("Accept Call"), button("Join Video Call")])])
    check not scan.voiceFound
    check scan.videoFound
    check "multiple voice" in scan.error

  test "two incoming dialogs disable both answers":
    let scan = classifyDialogs(@[dialog("Incoming Call", @[button("Join Call")]),
      dialog("Incoming Video Call", @[button("Join Video Call")])])
    check scan.state == CallRinging
    check not scan.voiceFound and not scan.videoFound

suite "Discord call status and queue":
  setup: resetShared()

  test "unpublished and stale status read as unavailable":
    check readDiscordCallStatus(10_000)["state"].getStr() == "unavailable"
    discard publishDiscordCallStatus(ringing())
    let fresh = readDiscordCallStatus(10_500)
    check fresh["state"].getStr() == "ringing"
    check fresh["voiceAvailable"].getBool()
    let stale = readDiscordCallStatus(10_000 + CallStaleMs + 1)
    check stale["state"].getStr() == "unavailable"
    check not stale["videoAvailable"].getBool()

  test "queue rejects idle, stale, missing kind, and overflow":
    expect DiscordCallQueueError: queueDiscordCall(false, 10_000)
    var voiceOnly = ringing()
    voiceOnly.videoAvailable = false
    discard publishDiscordCallStatus(voiceOnly)
    expect DiscordCallQueueError: queueDiscordCall(true, 10_000)
    expect DiscordCallQueueError: queueDiscordCall(false, 10_000 + CallStaleMs + 1)
    for _ in 0..<MaxQueuedCalls: queueDiscordCall(false, 10_000)
    expect DiscordCallQueueError: queueDiscordCall(false, 10_000)
    check takeDiscordCalls().len == MaxQueuedCalls

  test "queued presses are discarded when the call disappears":
    discard publishDiscordCallStatus(ringing())
    queueDiscordCall(true, 10_000)
    check publishDiscordCallStatus(DiscordCallStatus(published: true,
      state: CallIdle, observedMs: 10_100)) == 1
    check takeDiscordCalls().len == 0

suite "Discord call worker":
  setup: resetShared()

  test "discovery verifies Discord and idle polling sends one request":
    let bus = newFakeBus()
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    check worker.app.known
    check worker.app.root.bus == AppBus
    check worker.status.state == CallIdle
    let before = bus.calls.len
    worker.step(10_000 + CallPollMs)
    check bus.calls.len - before == 1
    check bus.calls[^1] == DialogMatch

  test "a Discord-named app owned by another process is rejected":
    let bus = newFakeBus()
    bus.comm[DiscordPid] = "python3"
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    check not worker.app.known
    check worker.status.state == CallUnavailable

  test "vanished app is forgotten and rediscovered":
    let bus = newFakeBus()
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    bus.failures[DialogMatch] = "object does not exist"
    worker.step(10_000 + CallPollMs)
    check not worker.app.known
    check worker.status.state == CallUnavailable
    bus.failures.del(DialogMatch)
    worker.step(10_000 + CallPollMs + InitialDiscoveryBackoffMs)
    check worker.app.known

  test "persistent scan failures back off rediscovery instead of spinning":
    let bus = newFakeBus()
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    bus.failures[DialogMatch] = "too many dialogs"
    worker.step(10_000 + CallPollMs)
    let before = bus.calls.len
    worker.step(10_000 + CallPollMs + 20)
    check bus.calls.len == before
    worker.step(10_000 + CallPollMs + InitialDiscoveryBackoffMs)
    check not worker.app.known
    check worker.discoveryBackoffMs == InitialDiscoveryBackoffMs * 4
    let nextAttempt = worker.nextDiscoveryMs
    let after = bus.calls.len
    worker.step(nextAttempt - 1)
    check bus.calls.len == after
    bus.failures.del(DialogMatch)
    worker.step(nextAttempt)
    check worker.app.known
    check worker.discoveryBackoffMs == InitialDiscoveryBackoffMs

  test "slow requests exceed the operation budget":
    let bus = newFakeBus()
    bus.stepMs = 400
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    check not worker.app.known
    check "exceeded" in worker.status.error

  test "voice and video presses invoke their own button once":
    let bus = newFakeBus()
    bus.addDialog("/dialog", "Incoming Call",
      @[("/voice", "Join Call"), ("/video", "Join Video Call"), ("/decline", "Decline")])
    bus.showDialogs(@["/dialog"])
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    check worker.status.state == CallRinging
    queueDiscordCall(true, bus.nowMs)
    worker.step(bus.nowMs)
    check bus.doActions() == @["call :1.50 /video org.a11y.atspi.Action DoAction i 0"]
    queueDiscordCall(false, bus.nowMs)
    worker.step(bus.nowMs)
    check bus.doActions().len == 2
    check bus.doActions()[1] == "call :1.50 /voice org.a11y.atspi.Action DoAction i 0"

  test "press action index comes from the action names":
    let bus = newFakeBus()
    bus.addDialog("/dialog", "Incoming Call", @[("/voice", "Join Call")])
    bus.addButton("/voice", "Join Call", actions = @["showContextMenu", "press"])
    bus.showDialogs(@["/dialog"])
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    queueDiscordCall(false, bus.nowMs)
    worker.step(bus.nowMs)
    check bus.doActions() == @["call :1.50 /voice org.a11y.atspi.Action DoAction i 1"]

  test "a queued press cannot answer a replacement incoming call":
    let bus = newFakeBus()
    bus.addDialog("/dialog", "Incoming Call", @[("/voice", "Join Call")])
    bus.showDialogs(@["/dialog"])
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    queueDiscordCall(false, bus.nowMs)
    bus.addDialog("/replacement", "Incoming Call", @[("/new-voice", "Join Call")])
    bus.showDialogs(@["/replacement"])
    worker.step(bus.nowMs)
    check bus.doActions().len == 0
    check takeDiscordCalls().len == 0

  test "failed action is invoked once and later presses in the batch are discarded":
    let bus = newFakeBus()
    bus.addDialog("/dialog", "Incoming Call", @[("/voice", "Join Call")])
    bus.showDialogs(@["/dialog"])
    bus.failures["call :1.50 /voice org.a11y.atspi.Action DoAction i 0"] = "timed out"
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    queueDiscordCall(false, bus.nowMs)
    queueDiscordCall(false, bus.nowMs)
    worker.step(bus.nowMs)
    check bus.doActions().len == 1
    check takeDiscordCalls().len == 0

  test "renamed button is revalidated and not pressed":
    let bus = newFakeBus()
    bus.addDialog("/dialog", "Incoming Call", @[("/voice", "Join Call")])
    bus.showDialogs(@["/dialog"])
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    bus.set("get-property " & AppBus & " /voice org.a11y.atspi.Accessible Name",
      propertyReply(%"Join Call"), propertyReply(%"Start Call"))
    queueDiscordCall(false, bus.nowMs)
    worker.step(bus.nowMs)
    check bus.doActions().len == 0

  test "expired presses are dropped without scanning or acting":
    let bus = newFakeBus()
    bus.addDialog("/dialog", "Incoming Call", @[("/voice", "Join Call")])
    bus.showDialogs(@["/dialog"])
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    queueDiscordCall(false, bus.nowMs)
    bus.nowMs += MaxPressAgeMs + 1
    let before = bus.calls.len
    worker.step(bus.nowMs)
    check bus.calls[before] == DialogMatch
    check bus.calls.filterIt("NActions" in it).len == 0
    check bus.doActions().len == 0

  test "press after the dialog closed does not act or replay":
    let bus = newFakeBus()
    bus.addDialog("/dialog", "Incoming Call", @[("/voice", "Join Call")])
    bus.showDialogs(@["/dialog"])
    var worker = newCallWorker(bus.transport(), publishDiscordCallStatus, ignoreLog)
    worker.step(10_000)
    queueDiscordCall(false, bus.nowMs)
    bus.showDialogs(@[])
    worker.step(bus.nowMs)
    check bus.doActions().len == 0
    check worker.status.state == CallIdle
    worker.step(bus.nowMs + CallPollMs)
    check bus.doActions().len == 0
