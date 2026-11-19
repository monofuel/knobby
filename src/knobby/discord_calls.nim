import
  std/[json, locks, monotimes, os, strutils, times],
  ./[common, runtime]

type
  DiscordCallState* = enum
    CallIdle = "idle", CallRinging = "ringing", CallUnavailable = "unavailable"
  DiscordCallQueueError* = object of IOError
  CallTimeoutError* = object of IOError
  AtspiRef* = object
    ## One accessible object: its owning bus name and object path.
    bus*, path*: string
  CallTransport* = object
    ## Injected AT-SPI access; production wraps busctl and /proc.
    resolveAddress*: proc (): string
    call*: proc (address: string, args: seq[string], timeoutMs: int): JsonNode
    processName*: proc (pid: int): string
    clock*: proc (): int64
  DiscordApp* = object
    ## Cached Discord accessibility root, verified by name and process.
    known*: bool
    address*: string
    root*: AtspiRef
    pid*: int
  CallButton* = object
    target*: AtspiRef
    name*: string
    role*: int
    states*: seq[int64]
  CallDialog* = object
    target*: AtspiRef
    name*, description*: string
    role*: int
    states*: seq[int64]
    buttons*: seq[CallButton]
  CallScan* = object
    ## Classified incoming-call dialogs with at most one answer target per kind.
    state*: DiscordCallState
    voiceFound*, videoFound*: bool
    voice*, video*: CallButton
    error*: string
  DiscordCallStatus* = object
    published*: bool
    state*: DiscordCallState
    voiceAvailable*, videoAvailable*: bool
    error*: string
    observedMs*: int64
    updatedMs*: int64
    voiceTarget*, videoTarget*: AtspiRef
  QueuedCall* = object
    video*: bool
    queuedMs*: int64
    target*: AtspiRef
  CallWorker* = object
    transport*: CallTransport
    publish*: proc (status: DiscordCallStatus): int
    log*: proc (message: string)
    app*: DiscordApp
    scan*: CallScan
    status*: DiscordCallStatus
    nextPollMs*, nextDiscoveryMs*: int64
    discoveryBackoffMs*: int
    lastLog: string
  Operation = object
    transport: CallTransport
    address: string
    deadlineMs: int64
    calls: int

const
  CallPollMs* = 1000
  CallStaleMs* = 3000
  MaxPressAgeMs* = 3000
  MaxQueuedCalls* = 2
  OperationBudgetMs* = 2000
  BusctlTimeoutMs* = 300
  BusctlExitMarginMs = 25
  InitialDiscoveryBackoffMs* = 1000
  MaxDiscoveryBackoffMs* = 10_000
  MaxCallsPerOperation* = 256
  MaxApps* = 64
  MaxDialogs* = 4
  MaxDialogButtons* = 16
  MaxRootChildren = 64
  MaxActions = 8
  MaxReplyBytes = 256 * 1024
  WorkerSleepMs = 20
  DiscordAppName* = "Discord"
  DiscordProcessNames = ["Discord", ".Discord-wrappe"]
  RegistryBus = "org.a11y.atspi.Registry"
  RootPath = "/org/a11y/atspi/accessible/root"
  AccessibleIface = "org.a11y.atspi.Accessible"
  ActionIface = "org.a11y.atspi.Action"
  CollectionIface = "org.a11y.atspi.Collection"
  DBusName = "org.freedesktop.DBus"
  DBusPath = "/org/freedesktop/DBus"
  MatchSignature = "(aiia{ss}iaiiasib)uib"
  AlertRole* = 2
  DialogRole* = 16
  PushButtonRole* = 43
  EnabledState* = 8
  SensitiveState* = 24
  ShowingState* = 25
  VisibleState* = 30
  # Role bitsets for MatchRule: word 0 bit 2 (alert) and bit 16 (dialog);
  # word 1 bit 11 (push button, role 43).
  DialogRoleWords = ["65540", "0", "0", "0"]
  ButtonRoleWords = ["0", "2048", "0", "0"]
  ButtonStates = [EnabledState, SensitiveState, ShowingState, VisibleState]
  PressActionNames = ["press", "click"]
  VoiceCaptions* = ["accept voice call", "accept call", "answer call",
    "join voice call", "join call", "join with voice", "join with audio"]
  VideoCaptions* = ["accept video call", "answer with video", "join video call",
    "join with video"]
  DeclineCaptions* = ["decline", "decline call", "reject", "reject call"]
  IncomingPhrases = ["incoming call", "incoming voice call", "incoming video call"]

var
  callLock: Lock
  callShared {.guard: callLock.}: DiscordCallStatus
  callQueue {.guard: callLock.}: seq[QueuedCall]
  callsThread: Thread[void]

initLock(callLock)

proc callClockMs*(): int64 =
  ## Return the monotonic millisecond clock used for call freshness.
  getMonoTime().ticks div 1_000_000

proc wallMs(): int64 =
  ## Return wall-clock milliseconds for display timestamps.
  int64(epochTime() * 1000)

proc callKind(video: bool): string =
  ## Name the answer kind for messages.
  if video: "video" else: "voice"

proc normalizeCaption*(text: string): string =
  ## Collapse whitespace and lowercase ASCII so captions compare exactly but robustly.
  text.splitWhitespace().join(" ").toLowerAscii()

proc hasState*(words: seq[int64], state: int): bool =
  ## Test one AT-SPI state bit in a GetState word array.
  let word = state div 32
  word < words.len and ((words[word] shr (state mod 32)) and 1) == 1

proc isUsableButton*(button: CallButton): bool =
  ## Require a push button that is enabled, sensitive, showing, and visible.
  result = button.role == PushButtonRole
  for state in ButtonStates:
    result = result and button.states.hasState(state)

proc isShowingDialog(dialog: CallDialog): bool =
  ## Require a showing, visible dialog or alert.
  dialog.role in [DialogRole, AlertRole] and dialog.states.hasState(ShowingState) and
    dialog.states.hasState(VisibleState)

proc announcesIncomingCall(dialog: CallDialog): bool =
  ## Report whether the dialog's own name or description says a call is incoming.
  let text = normalizeCaption(dialog.name) & " | " & normalizeCaption(dialog.description)
  for phrase in IncomingPhrases:
    if phrase in text: return true

proc classifyDialogs*(dialogs: seq[CallDialog]): CallScan =
  ## Find one exact voice and video answer button in exactly one incoming-call
  ## dialog. A dialog counts only when it announces an incoming call, or offers
  ## a decline/reject button beside a call-specific answer caption. Anything
  ## ambiguous leaves that answer kind unavailable.
  var incoming: seq[tuple[voice, video: seq[CallButton]]]
  for dialog in dialogs:
    if dialog.isShowingDialog():
      var
        voice, video: seq[CallButton]
        declines = false
      for button in dialog.buttons:
        if button.isUsableButton():
          let caption = normalizeCaption(button.name)
          if caption in VoiceCaptions: voice.add(button)
          elif caption in VideoCaptions: video.add(button)
          elif caption in DeclineCaptions: declines = true
      if dialog.announcesIncomingCall() or (declines and voice.len + video.len > 0):
        incoming.add((voice, video))
  if incoming.len == 0:
    result.state = CallIdle
  elif incoming.len > 1:
    result.state = CallRinging
    result.error = "Multiple incoming call dialogs are open"
  else:
    result.state = CallRinging
    let found = incoming[0]
    var problems: seq[string]
    if found.voice.len == 1:
      result.voiceFound = true
      result.voice = found.voice[0]
    elif found.voice.len > 1:
      problems.add("multiple voice answer buttons")
    if found.video.len == 1:
      result.videoFound = true
      result.video = found.video[0]
    elif found.video.len > 1:
      problems.add("multiple video answer buttons")
    if found.voice.len == 0 and found.video.len == 0:
      problems.add("no answer buttons")
    if problems.len > 0:
      result.error = "Incoming call dialog has " & problems.join(" and ")

proc statusJson*(status: DiscordCallStatus): JsonNode =
  ## Render the parent-facing status contract.
  %*{"state": $status.state, "voiceAvailable": status.voiceAvailable,
    "videoAvailable": status.videoAvailable, "error": status.error,
    "updatedMs": status.updatedMs}

proc pressStillValid(status: DiscordCallStatus, press: QueuedCall): bool =
  ## Keep a queued press only while its answer kind remains available.
  status.state == CallRinging and
    (if press.video: status.videoAvailable else: status.voiceAvailable)

proc publishDiscordCallStatus*(status: DiscordCallStatus): int {.gcsafe.} =
  ## Store the newest observation and discard queued presses whose call or
  ## control has disappeared, so they never replay later; return the discard count.
  {.cast(gcsafe).}:
    withLock callLock:
      deepCopy(callShared, status)
      var kept: seq[QueuedCall]
      for press in callQueue:
        if status.pressStillValid(press): kept.add(press)
      result = callQueue.len - kept.len
      callQueue = kept

proc freshStatus(status: DiscordCallStatus, nowMs: int64): DiscordCallStatus =
  ## Downgrade unobserved or stale observations to unavailable.
  result = status
  if not status.published:
    result = DiscordCallStatus(state: CallUnavailable,
      error: "Discord call status not observed yet")
  elif nowMs < status.observedMs or nowMs - status.observedMs > CallStaleMs:
    result.state = CallUnavailable
    result.voiceAvailable = false
    result.videoAvailable = false
    result.error = "Discord call status is stale"

proc readDiscordCallStatus*(nowMs = callClockMs()): JsonNode {.gcsafe.} =
  ## Return {state, voiceAvailable, videoAvailable, error, updatedMs}; stale
  ## or missing observations read as unavailable.
  var status: DiscordCallStatus
  {.cast(gcsafe).}:
    withLock callLock: deepCopy(status, callShared)
  statusJson(status.freshStatus(nowMs))

proc queueDiscordCall*(video: bool, nowMs = callClockMs()) {.gcsafe.} =
  ## Queue one explicit answer press, raising DiscordCallQueueError with the
  ## reason when no fresh incoming call offers that answer kind.
  {.cast(gcsafe).}:
    withLock callLock:
      let
        status = callShared.freshStatus(nowMs)
        kind = callKind(video)
      if status.state == CallUnavailable:
        raise newException(DiscordCallQueueError, "Discord " & kind &
          " answer ignored: " & status.error & ".")
      if status.state != CallRinging:
        raise newException(DiscordCallQueueError, "Discord " & kind &
          " answer ignored: no incoming call.")
      if not status.pressStillValid(QueuedCall(video: video)):
        let reason = if status.error.len > 0: status.error
          else: "the incoming call has no " & kind & " answer button"
        raise newException(DiscordCallQueueError, "Discord " & kind &
          " answer ignored: " & reason & ".")
      if callQueue.len >= MaxQueuedCalls:
        raise newException(DiscordCallQueueError, "Discord " & kind &
          " answer ignored: an earlier answer press is still pending.")
      callQueue.add(QueuedCall(video: video, queuedMs: nowMs,
        target: if video: status.videoTarget else: status.voiceTarget))

proc takeDiscordCalls*(): seq[QueuedCall] {.gcsafe.} =
  ## Transfer queued answer presses to the worker in press order.
  {.cast(gcsafe).}:
    withLock callLock:
      result = move(callQueue)
      callQueue = @[]

proc newOperation(transport: CallTransport, address: string): Operation =
  ## Start one bounded AT-SPI operation.
  Operation(transport: transport, address: address,
    deadlineMs: transport.clock() + OperationBudgetMs)

proc expired(op: Operation): bool =
  ## Report whether the operation has used its whole time budget.
  op.transport.clock() >= op.deadlineMs

proc request(op: var Operation, args: seq[string]): JsonNode =
  ## Run one busctl request within both the per-call and per-operation bounds.
  let remaining = op.deadlineMs - op.transport.clock()
  if remaining <= 0:
    raise newException(CallTimeoutError,
      "AT-SPI operation exceeded " & $OperationBudgetMs & " ms")
  inc op.calls
  if op.calls > MaxCallsPerOperation:
    raise newException(IOError,
      "AT-SPI operation exceeded " & $MaxCallsPerOperation & " requests")
  op.transport.call(op.address, args, int(min(remaining, BusctlTimeoutMs)))

proc firstArg(reply: JsonNode): JsonNode =
  ## Return a method reply's first result argument; busctl puts them in a data array.
  if reply.isNil or reply.kind != JObject or reply{"data"}.isNil or
      reply["data"].kind != JArray or reply["data"].len == 0:
    raise newException(IOError, "Malformed AT-SPI method reply")
  reply["data"][0]

proc propertyValue(reply: JsonNode): JsonNode =
  ## Return a get-property reply's scalar data value.
  if reply.isNil or reply.kind != JObject or reply{"data"}.isNil:
    raise newException(IOError, "Malformed AT-SPI property reply")
  reply["data"]

proc parseRefs(node: JsonNode, limit: int): seq[AtspiRef] =
  ## Parse an a(so) reference list, refusing replies longer than the limit.
  if node.kind != JArray:
    raise newException(IOError, "Malformed AT-SPI reference list")
  if node.len > limit:
    raise newException(IOError, "AT-SPI returned more than " & $limit & " objects")
  for item in node:
    if item.kind != JArray or item.len != 2 or item[0].kind != JString or
        item[1].kind != JString:
      raise newException(IOError, "Malformed AT-SPI reference")
    result.add(AtspiRef(bus: item[0].getStr(), path: item[1].getStr()))

proc parseStates(node: JsonNode): seq[int64] =
  ## Parse a GetState word array.
  if node.kind != JArray or node.len > 4:
    raise newException(IOError, "Malformed AT-SPI state set")
  for word in node:
    if word.kind != JInt: raise newException(IOError, "Malformed AT-SPI state word")
    result.add(word.getBiggestInt())

proc stringProperty(op: var Operation, target: AtspiRef, iface, name: string): string =
  ## Read one string property.
  let value = op.request(@["get-property", target.bus, target.path, iface, name]).propertyValue()
  if value.kind != JString: raise newException(IOError, "AT-SPI " & name & " is not a string")
  value.getStr()

proc intResult(op: var Operation, target: AtspiRef, iface, methodName: string,
    args: varargs[string]): int =
  ## Call a method whose first result is an integer.
  let value = op.request(@["call", target.bus, target.path, iface, methodName] & @args).firstArg()
  if value.kind != JInt: raise newException(IOError, "AT-SPI " & methodName & " is not an integer")
  value.getInt()

proc readStates(op: var Operation, target: AtspiRef): seq[int64] =
  ## Read an object's current state words.
  op.request(@["call", target.bus, target.path, AccessibleIface, "GetState"]).firstArg().parseStates()

proc matchArgs(roleWords: openArray[string], count: int): seq[string] =
  ## Build a Collection.GetMatches request for any of the given roles.
  result = @[MatchSignature, "0", "1", "0", "1", "4"]
  result.add(@roleWords)
  result.add(@["2", "0", "1", "false", "1", $count, "true"])

proc matches(op: var Operation, scope: AtspiRef, roleWords: openArray[string],
    limit: int): seq[AtspiRef] =
  ## Find descendants of one scope by role, bounded and on the scope's own bus.
  let reply = op.request(@["call", scope.bus, scope.path, CollectionIface, "GetMatches"] &
    matchArgs(roleWords, limit + 1))
  for found in reply.firstArg().parseRefs(limit):
    if found.bus == scope.bus: result.add(found)

proc readButton(op: var Operation, target: AtspiRef): CallButton =
  ## Read a button's caption, role, and states.
  CallButton(target: target,
    name: op.stringProperty(target, AccessibleIface, "Name"),
    role: op.intResult(target, AccessibleIface, "GetRole"),
    states: op.readStates(target))

proc readDialogs(op: var Operation, app: DiscordApp): seq[CallDialog] =
  ## Query dialogs and alerts from the app root, then only their own buttons.
  for target in op.matches(app.root, DialogRoleWords, MaxDialogs):
    var dialog = CallDialog(target: target,
      role: op.intResult(target, AccessibleIface, "GetRole"),
      states: op.readStates(target))
    if dialog.isShowingDialog():
      dialog.name = op.stringProperty(target, AccessibleIface, "Name")
      dialog.description = op.stringProperty(target, AccessibleIface, "Description")
      for button in op.matches(target, ButtonRoleWords, MaxDialogButtons):
        dialog.buttons.add(op.readButton(button))
    result.add(dialog)

proc isDiscordComm(comm: string): bool =
  ## Report whether a /proc comm value names the installed Discord client.
  comm.strip() in DiscordProcessNames

proc wake(op: var Operation, root: AtspiRef) =
  ## Touch the frame's attributes, a read-only request that makes Chromium
  ## build its accessibility tree if it has not yet.
  let children = op.request(@["call", root.bus, root.path, AccessibleIface,
    "GetChildren"]).firstArg().parseRefs(MaxRootChildren)
  if children.len > 0:
    discard op.request(@["call", children[0].bus, children[0].path, AccessibleIface,
      "GetAttributes"])

proc discoverApp(op: var Operation): DiscordApp =
  ## Find exactly one registered application named Discord whose bus owner
  ## process is the Discord client.
  op.address = op.transport.resolveAddress()
  let apps = op.request(@["call", RegistryBus, RootPath, AccessibleIface,
    "GetChildren"]).firstArg().parseRefs(MaxApps)
  var found: seq[DiscordApp]
  for app in apps:
    var name = ""
    try:
      name = op.stringProperty(app, AccessibleIface, "Name")
    except CatchableError:
      # Applications routinely exit between the registry listing and this read.
      name = ""
    if op.expired():
      raise newException(CallTimeoutError,
        "AT-SPI discovery exceeded " & $OperationBudgetMs & " ms")
    if name == DiscordAppName:
      let pid = op.intResult(AtspiRef(bus: DBusName, path: DBusPath), DBusName,
        "GetConnectionUnixProcessID", "s", app.bus)
      if op.transport.processName(pid).isDiscordComm():
        found.add(DiscordApp(known: true, address: op.address, root: app, pid: pid))
  if found.len == 0:
    raise newException(IOError, "Discord is not exposing accessibility")
  if found.len > 1:
    raise newException(IOError, "Multiple Discord accessibility applications")
  op.wake(found[0].root)
  found[0]

proc pressActionIndex(op: var Operation, target: AtspiRef): int =
  ## Find the button's press or click action. Chromium leaves GetActions
  ## names blank, so each index is named individually.
  let count = op.request(@["get-property", target.bus, target.path, ActionIface,
    "NActions"]).propertyValue()
  if count.kind != JInt: raise newException(IOError, "AT-SPI NActions is not an integer")
  result = -1
  for index in 0..<min(count.getInt(), MaxActions):
    if result < 0:
      let name = op.request(@["call", target.bus, target.path, ActionIface, "GetName",
        "i", $index]).firstArg()
      if name.kind == JString and name.getStr() in PressActionNames:
        result = index
  if result < 0:
    raise newException(IOError, "Answer button has no press action")

proc note(worker: var CallWorker, message: string) =
  ## Log a state change once, suppressing identical repeats.
  if message != worker.lastLog:
    worker.lastLog = message
    if not worker.log.isNil: worker.log(message)

proc publishStatus(worker: var CallWorker, state: DiscordCallState, error: string,
    voice = false, video = false) =
  ## Publish an observation stamped after the operation that produced it.
  worker.status = DiscordCallStatus(published: true, state: state,
    voiceAvailable: voice, videoAvailable: video, error: error,
    observedMs: worker.transport.clock(), updatedMs: wallMs(),
    voiceTarget: if voice: worker.scan.voice.target else: AtspiRef(),
    videoTarget: if video: worker.scan.video.target else: AtspiRef())
  if not worker.publish.isNil:
    let discarded = worker.publish(worker.status)
    if discarded > 0:
      worker.note("Discarded " & $discarded & " Discord answer presses: the call or its control disappeared.")

proc publishScan(worker: var CallWorker) =
  ## Publish the latest classified scan.
  worker.publishStatus(worker.scan.state, worker.scan.error,
    worker.scan.voiceFound, worker.scan.videoFound)

proc forgetApp(worker: var CallWorker, reason: string, nowMs: int64) =
  ## Drop the cached app after a failure and rediscover with bounded backoff.
  worker.app = DiscordApp()
  worker.scan = CallScan(state: CallUnavailable, error: reason)
  worker.nextDiscoveryMs = nowMs + worker.discoveryBackoffMs
  worker.discoveryBackoffMs = min(worker.discoveryBackoffMs * 2, MaxDiscoveryBackoffMs)
  worker.note("Discord call controls unavailable: " & reason & ".")
  worker.publishStatus(CallUnavailable, reason)

proc newCallWorker*(transport: CallTransport,
    publish: proc (status: DiscordCallStatus): int,
    log: proc (message: string)): CallWorker =
  ## Create a worker that discovers Discord on its first step.
  CallWorker(transport: transport, publish: publish, log: log,
    discoveryBackoffMs: InitialDiscoveryBackoffMs)

proc discover(worker: var CallWorker, nowMs: int64) =
  ## Find and cache the Discord application, backing off while it is absent.
  var
    op = newOperation(worker.transport, "")
    failure = ""
  try:
    worker.app = op.discoverApp()
  except CatchableError as error:
    failure = error.msg
  if failure.len > 0:
    worker.app = DiscordApp()
    worker.nextDiscoveryMs = nowMs + worker.discoveryBackoffMs
    worker.discoveryBackoffMs = min(worker.discoveryBackoffMs * 2, MaxDiscoveryBackoffMs)
    worker.note("Discord call controls unavailable: " & failure & ".")
    worker.publishStatus(CallUnavailable, failure)
  else:
    worker.nextPollMs = nowMs
    worker.note("Discord accessibility found on " & worker.app.root.bus & " (pid " &
      $worker.app.pid & ").")

proc rescan(worker: var CallWorker, op: var Operation) =
  ## Verify the owner process and classify the current dialogs.
  if not worker.transport.processName(worker.app.pid).isDiscordComm():
    raise newException(IOError, "Discord process exited")
  worker.scan = classifyDialogs(op.readDialogs(worker.app))

proc poll(worker: var CallWorker, nowMs: int64) =
  ## Classify dialogs with one GetMatches request while idle.
  worker.nextPollMs = nowMs + CallPollMs
  var
    op = newOperation(worker.transport, worker.app.address)
    failure = ""
  try:
    worker.rescan(op)
  except CatchableError as error:
    failure = error.msg
  if failure.len > 0:
    worker.forgetApp("Discord call scan failed: " & failure, nowMs)
  else:
    worker.discoveryBackoffMs = InitialDiscoveryBackoffMs
    worker.publishScan()

proc invoke(worker: var CallWorker, press: QueuedCall, nowMs: int64) =
  ## Rescan, revalidate the exact target, and invoke its press action at most
  ## once. A failed or uncertain action is reported and never retried.
  let kind = callKind(press.video)
  var
    op = newOperation(worker.transport, worker.app.address)
    target: CallButton
    found = false
    targetChanged = false
    fresh: CallButton
    index = -1
    failure = ""
  try:
    worker.rescan(op)
    found = if press.video: worker.scan.videoFound else: worker.scan.voiceFound
    if found:
      target = if press.video: worker.scan.video else: worker.scan.voice
      targetChanged = press.target.bus.len > 0 and target.target != press.target
      if not targetChanged:
        index = op.pressActionIndex(target.target)
        fresh = op.readButton(target.target)
  except CatchableError as error:
    failure = error.msg
  if failure.len > 0:
    worker.forgetApp("Discord " & kind & " answer not attempted: " & failure, nowMs)
  else:
    worker.publishScan()
    if targetChanged:
      worker.note("Discord " & kind & " answer ignored: the incoming answer control changed after the press.")
    elif not found:
      let reason = if worker.scan.error.len > 0: worker.scan.error
        elif worker.scan.state == CallRinging: "no " & kind & " answer button"
        else: "no incoming call"
      worker.note("Discord " & kind & " answer ignored: " & reason & ".")
    elif normalizeCaption(fresh.name) != normalizeCaption(target.name) or
        not fresh.isUsableButton():
      worker.note("Discord " & kind & " answer ignored: the button changed before pressing.")
    elif worker.transport.clock() - press.queuedMs > MaxPressAgeMs or op.expired():
      worker.note("Discord " & kind & " answer dropped after waiting too long.")
    else:
      var outcome = ""
      try:
        let reply = op.request(@["call", target.target.bus, target.target.path,
          ActionIface, "DoAction", "i", $index]).firstArg()
        outcome = if reply.kind == JBool and reply.getBool(): "sent"
          else: "reported failure; not retried"
      except CatchableError as error:
        outcome = "uncertain (" & error.msg & "); not retried"
      worker.note("Discord " & kind & " answer pressed \"" & target.name & "\": " &
        outcome & ".")
      worker.nextPollMs = worker.transport.clock()

proc answer(worker: var CallWorker, presses: seq[QueuedCall], nowMs: int64) =
  ## Act on the first fresh press only; later presses from the same batch are
  ## discarded rather than replayed against a changed call.
  var attempted = false
  for press in presses:
    let kind = callKind(press.video)
    if attempted:
      worker.note("Discord " & kind & " answer discarded: an earlier press was handled.")
    elif nowMs - press.queuedMs > MaxPressAgeMs:
      worker.note("Discord " & kind & " answer dropped after waiting too long.")
    elif not worker.app.known:
      worker.note("Discord " & kind & " answer ignored: Discord accessibility unavailable.")
    else:
      attempted = true
      worker.invoke(press, nowMs)

proc step*(worker: var CallWorker, nowMs: int64) =
  ## Advance discovery, queued presses, and dialog polling by one bounded pass.
  if not worker.app.known and nowMs >= worker.nextDiscoveryMs:
    worker.discover(nowMs)
  let presses = takeDiscordCalls()
  if presses.len > 0:
    worker.answer(presses, worker.transport.clock())
  if worker.app.known and nowMs >= worker.nextPollMs:
    worker.poll(nowMs)
  elif not worker.app.known and nowMs - worker.status.observedMs >= CallPollMs:
    worker.publishStatus(CallUnavailable, worker.status.error)

proc shutdown*(worker: var CallWorker) =
  ## Close the queue when the daemon stops.
  worker.publishStatus(CallUnavailable, "Knobby is stopping")

proc busctlCall(address: string, args: seq[string], timeoutMs: int): JsonNode =
  ## Run busctl against the accessibility bus with a bounded method-call timeout.
  let output = runAudioCommand("busctl", @["--address=" & address,
    "--timeout=" & $max(1, timeoutMs - BusctlExitMarginMs) & "ms", "--json=short"] & args, timeoutMs)
  if output.len > MaxReplyBytes:
    raise newException(IOError, "AT-SPI reply exceeded " & $MaxReplyBytes & " bytes")
  parseJson(output)

proc resolveAtspiAddress(): string =
  ## Ask the session bus for the accessibility bus address.
  result = getEnv("AT_SPI_BUS_ADDRESS")
  if result.len == 0:
    let output = runAudioCommand("busctl", @["--user", "--timeout=" & $BusctlTimeoutMs & "ms",
      "--json=short", "call", "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress"],
      BusctlTimeoutMs)
    let value = parseJson(output).firstArg()
    if value.kind != JString or value.getStr().len == 0:
      raise newException(IOError, "Accessibility bus address unavailable")
    result = value.getStr()

proc procComm(pid: int): string =
  ## Read a process name, treating an exited process as unnamed.
  try:
    result = readFile("/proc/" & $pid & "/comm").strip()
  except IOError, OSError:
    # The owner may exit at any time; an empty name fails the identity check.
    result = ""

proc busctlTransport*(): CallTransport =
  ## Production AT-SPI access through busctl and /proc.
  CallTransport(resolveAddress: resolveAtspiAddress, call: busctlCall,
    processName: procComm, clock: callClockMs)

proc probeCaption(caption: string): string =
  ## Reveal only call-control captions; other button names may contain user content.
  let normalized = normalizeCaption(caption)
  if normalized in VoiceCaptions or normalized in VideoCaptions or
      normalized in DeclineCaptions: caption.strip()
  else: ""

proc probeDiscordCalls*(transport = busctlTransport()): JsonNode =
  ## Run one read-only discovery and dialog scan for live verification. It
  ## never invokes an action and redacts non-call button captions.
  var op = newOperation(transport, "")
  let app = op.discoverApp()
  var scanOp = newOperation(transport, app.address)
  let
    dialogs = scanOp.readDialogs(app)
    scan = classifyDialogs(dialogs)
  var dialogNodes = newJArray()
  for dialog in dialogs:
    var buttons = newJArray()
    for button in dialog.buttons:
      buttons.add(%*{"caption": probeCaption(button.name), "role": button.role,
        "usable": button.isUsableButton()})
    dialogNodes.add(%*{"role": dialog.role, "showing": dialog.isShowingDialog(),
      "announcesIncomingCall": dialog.announcesIncomingCall(), "buttons": buttons})
  %*{"app": {"bus": app.root.bus, "pid": app.pid, "comm": transport.processName(app.pid)},
    "state": $scan.state, "voiceAvailable": scan.voiceFound,
    "videoAvailable": scan.videoFound, "error": scan.error, "dialogs": dialogNodes,
    "requests": op.calls + scanOp.calls}

proc writeCallsLog(message: string) =
  ## Write a Discord call lifecycle message to the service log.
  stderr.writeLine(message)

proc runCalls() {.thread.} =
  ## Own the cached Discord accessibility identity and the answer queue.
  {.cast(gcsafe).}:
    var worker = newCallWorker(busctlTransport(), publishDiscordCallStatus, writeCallsLog)
    while not shouldStop():
      worker.step(callClockMs())
      sleep(WorkerSleepMs)
    worker.shutdown()

proc startDiscordCallsWorker*() =
  ## Start the call worker; faders and other actions never wait on it.
  createThread(callsThread, runCalls)

proc stopDiscordCallsWorker*() =
  ## Join the call worker after the daemon stop flag is set.
  joinThread(callsThread)

when isMainModule:
  echo pretty(probeDiscordCalls())
