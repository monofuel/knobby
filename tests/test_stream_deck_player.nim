import
  std/[json, os, strutils, tables, unittest],
  knobby/[stream_deck, stream_deck_page, stream_deck_player]

type
  TimedReport = object
    atMs: int64
    report: string
  Packet = object
    atMs: int64
    report: string
  FakeDeck = ref object
    nowMs: int64
    inputs: seq[TimedReport]
    packets: seq[Packet]
    features: seq[string]
    readTimeouts: seq[int]
    writeCostMs: int64
    deferWrites: Table[int, int]
    deferForever: bool
    deferredAttempts: int
    closes: int
    disconnectAtMs: int64
    failClose: bool
    afterWrite: proc (count: int)
  Upload = object
    startMs: int64
    endMs: int64
    key: int
    jpeg: string

const
  FrameMs = 100
  StopNever = high(int64)
  JpegStart = "\xff\xd8"

proc keyReport(pressed: openArray[int]): string =
  ## Construct a synthetic report containing the complete state of fifteen keys.
  result = newString(19)
  result[0] = '\x01'
  result[2] = '\x0f'
  for key in pressed:
    result[4 + key] = '\x01'

proc newFakeDeck(): FakeDeck =
  ## Create a fake device whose clock only moves through reads and writes.
  FakeDeck(disconnectAtMs: StopNever)

proc transport(fake: FakeDeck): StreamDeckIo =
  ## Supply fake report I/O that advances virtual time instead of touching hardware.
  result = StreamDeckIo(
    readReport: proc (timeoutMs: int): string =
      ## Return the next due report, waiting virtually up to the timeout.
      fake.readTimeouts.add(timeoutMs)
      if fake.inputs.len > 0 and fake.inputs[0].atMs <= fake.nowMs + timeoutMs:
        fake.nowMs = max(fake.nowMs, fake.inputs[0].atMs)
        result = fake.inputs[0].report
        fake.inputs.delete(0)
      else:
        fake.nowMs += timeoutMs
      if fake.nowMs >= fake.disconnectAtMs:
        raise newException(OSError, "Synthetic disconnect."),
    writeReport: proc (report: string): int =
      ## Accept a report after its transfer time, or defer it to simulate EAGAIN.
      let index = fake.packets.len
      if fake.deferForever or fake.deferWrites.getOrDefault(index, 0) > 0:
        if not fake.deferForever:
          dec fake.deferWrites[index]
        inc fake.deferredAttempts
        result = 0
      else:
        fake.nowMs += fake.writeCostMs
        fake.packets.add(Packet(atMs: fake.nowMs, report: report))
        if not fake.afterWrite.isNil:
          {.cast(gcsafe).}: fake.afterWrite(fake.packets.len)
        result = report.len,
    sendFeature: proc (report: string): int =
      ## Record brightness and logo requests.
      fake.features.add(report)
      result = report.len,
    close: proc () =
      ## Count descriptor releases and optionally fail the close itself.
      inc fake.closes
      if fake.failClose:
        raise newException(OSError, "Synthetic close failure."))

proc fakeOptions(fake: FakeDeck, diagnostics: ref seq[string] = nil): PlayerOptions =
  ## Use the fake clock and capture diagnostics instead of writing to stderr.
  result = defaultPlayerOptions()
  result.clock = proc (): int64 = fake.nowMs
  result.onDiagnostic = proc (message: string) =
    ## Retain diagnostics for assertions.
    if not diagnostics.isNil:
      diagnostics[].add(message)

proc uploads(fake: FakeDeck): seq[Upload] =
  ## Reassemble complete images, failing if packets of two images interleave.
  var current = -1
  var page = 0
  var upload: Upload
  for packet in fake.packets:
    let
      report = packet.report
      key = ord(report[2])
      size = ord(report[4]) or (ord(report[5]) shl 8)
      index = ord(report[6]) or (ord(report[7]) shl 8)
    doAssert report[0..1] == "\x02\x07"
    if current == -1:
      doAssert index == 0, "an image must start at its first packet"
      current = key
      page = 0
      upload = Upload(startMs: packet.atMs, key: key)
    doAssert key == current, "packets of different images interleaved"
    doAssert index == page, "packets were skipped or repeated"
    upload.jpeg.add(report[8..<8 + size])
    inc page
    if report[3] == '\x01':
      upload.endMs = packet.atMs
      result.add(upload)
      current = -1
  doAssert current == -1, "an image upload was left incomplete"

proc writeJpeg(directory, name: string, bytes = 40): string =
  ## Write a distinguishable fake prepared JPEG and return its absolute path.
  result = directory / name
  writeFile(result, JpegStart & name & repeat("x", bytes))

proc framePage(generation: int64, menu: string, frames: openArray[string],
    pressed: string, durationMs = FrameMs, key = 1): JsonNode =
  ## Build a page with one animated key and builtin numbers elsewhere.
  result = builtinDeckPage(generation, menu)
  var normal = newJArray()
  for path in frames:
    normal.add(%*{"path": path, "durationMs": durationMs})
  result["keys"][$key] = %*{"normal": normal, "pressed": pressed}

proc pageReader(pages: ref seq[JsonNode], calls: ref seq[int64]): proc (previousGeneration: int64): JsonNode =
  ## Serve the newest queued page whose generation is newer than the caller's.
  result = proc (previousGeneration: int64): JsonNode =
    ## Record the request and return the newest page when it changed.
    calls[].add(previousGeneration)
    if pages[].len > 0 and pages[^1]["generation"].getBiggestInt() != previousGeneration:
      result = pages[^1]

proc ignoreKey(event: StreamDeckKeyEvent) =
  ## Accept key edges in tests that do not inspect them.
  discard

suite "Stream Deck player scheduler":
  test "frames follow elapsed monotonic time and loop":
    let ends = frameEnds([100, 50, 200])
    check ends == @[100, 150, 350]
    check frameIndexAt(ends, 0) == 0
    check frameIndexAt(ends, 99) == 0
    check frameIndexAt(ends, 100) == 1
    check frameIndexAt(ends, 149) == 1
    check frameIndexAt(ends, 150) == 2
    check frameIndexAt(ends, 350) == 0
    check frameIndexAt(ends, 350 * 1000 + 120) == 1
    check msUntilNextFrame(ends, 0) == 100
    check msUntilNextFrame(ends, 120) == 30
    check msUntilNextFrame(ends, 349) == 1

  test "late ticks skip obsolete frames instead of replaying them":
    let ends = frameEnds([10, 10, 10, 10, 10])
    check frameIndexAt(ends, 5) == 0
    check frameIndexAt(ends, 47) == 4

  test "single frames never schedule a change":
    let ends = frameEnds([100])
    check frameIndexAt(ends, 12345) == 0
    check msUntilNextFrame(ends, 12345) == high(int64)

  test "invalid durations are rejected":
    for durations in [newSeq[int](), @[0], @[-5], @[MaxFrameDurationMs + 1]]:
      expect ValueError:
        discard frameEnds(durations)

suite "Stream Deck transport retries":
  test "a deferred report is retried as the same report and short writes still fail":
    let fake = newFakeDeck()
    fake.deferWrites[1] = 3
    let deck = newStreamDeck(fake.transport())
    let jpeg = JpegStart & repeat("J", ImagePayloadBytes * 2)
    deck.setKeyImage(4, jpeg)
    check fake.deferredAttempts == 3
    check fake.uploads().len == 1
    check fake.uploads()[0].jpeg == jpeg
    check deck.trySendReport(encodeKeyImageReports(0, "J")[0]) == ReportSent
    fake.deferForever = true
    check deck.trySendReport(encodeKeyImageReports(0, "J")[0]) == ReportDeferred
    expect IOError:
      deck.setKeyImage(0, "J")
    deck.close()

suite "Configured Stream Deck sessions":
  test "nil reader shows the builtin numbered page, reports ready once and restores the logo":
    let fake = newFakeDeck()
    var readyAt: seq[int]
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 500,
      ignoreKey, nil, proc () = readyAt.add(fake.packets.len), fake.fakeOptions())
    let images = fake.uploads()
    check images.len == StreamDeckKeyCount
    for index, upload in images:
      check upload.key == index
      check upload.jpeg == builtinNormalImage(index + 1)
    check readyAt == @[fake.packets.len]
    check fake.features.len == 2
    check fake.features[0] == encodeBrightnessReport(30)
    check fake.features[1][0..1] == "\x03\x02"
    check fake.closes == 1
    for timeout in fake.readTimeouts:
      check timeout <= 20

  test "press shows a static pressed image while held and animation resumes on release":
    let
      directory = getTempDir() / "knobby-player-press"
      fake = newFakeDeck()
    createDir(directory)
    defer: removeDir(directory)
    let
      a = writeJpeg(directory, "a.jpg")
      b = writeJpeg(directory, "b.jpg")
      pressed = writeJpeg(directory, "pressed.jpg")
      pages = new seq[JsonNode]
      calls = new seq[int64]
    pages[].add(framePage(1, "root", [a, b], pressed))
    fake.inputs = @[TimedReport(atMs: 250, report: keyReport([0])),
      TimedReport(atMs: 640, report: keyReport([]))]
    var events: seq[StreamDeckKeyEvent]
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 900,
      proc (event: StreamDeckKeyEvent) = events.add(event),
      pageReader(pages, calls), nil, fake.fakeOptions())
    check events == @[StreamDeckKeyEvent(keyIndex: 0, pressed: true),
      StreamDeckKeyEvent(keyIndex: 0, pressed: false)]
    var keyOne: seq[Upload]
    for upload in fake.uploads():
      if upload.key == 0:
        keyOne.add(upload)
    var whileHeld = 0
    for upload in keyOne:
      if upload.startMs >= 250 and upload.startMs < 640:
        inc whileHeld
        check upload.jpeg == readFile(pressed)
      elif upload.startMs >= 640:
        let expected = if ((upload.startMs div FrameMs) mod 2) == 0: a else: b
        check upload.jpeg == readFile(expected)
    check whileHeld == 1
    check keyOne[^1].startMs >= 640
    check keyOne[^1].jpeg != readFile(pressed)
    check keyOne.len >= 7
    check calls[][0] == 0

  test "slow transfers skip obsolete frames and never queue them":
    let
      directory = getTempDir() / "knobby-player-skip"
      fake = newFakeDeck()
    createDir(directory)
    defer: removeDir(directory)
    var frames: seq[string]
    for index in 0..<10:
      frames.add(writeJpeg(directory, $index & ".jpg", ImagePayloadBytes + 10))
    let
      pages = new seq[JsonNode]
      calls = new seq[int64]
    pages[].add(framePage(1, "root", frames, frames[0], durationMs = 10))
    fake.writeCostMs = 8
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 2000,
      ignoreKey, pageReader(pages, calls), nil, fake.fakeOptions())
    var animated: seq[Upload]
    for upload in fake.uploads():
      if upload.key == 0:
        animated.add(upload)
    check animated.len in 60..150
    var skipped = 0
    var previous = -1
    for upload in animated:
      let due = ((upload.startMs - fake.writeCostMs) div 10) mod 10
      check upload.jpeg == readFile(frames[due])
      if previous >= 0 and due != (previous + 1) mod 10:
        inc skipped
      previous = due.int
    check skipped > 10

  test "input stays responsive between packets and during deferred writes":
    let
      directory = getTempDir() / "knobby-player-input"
      fake = newFakeDeck()
    createDir(directory)
    defer: removeDir(directory)
    let
      big = writeJpeg(directory, "big.jpg", ImagePayloadBytes * 8)
      pages = new seq[JsonNode]
      calls = new seq[int64]
    pages[].add(framePage(1, "root", [big], big))
    fake.writeCostMs = 5
    fake.deferWrites[2] = 50
    fake.inputs = @[TimedReport(atMs: 7, report: keyReport([3])),
      TimedReport(atMs: 30, report: keyReport([]))]
    var eventTimes: seq[int64]
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 400,
      proc (event: StreamDeckKeyEvent) = eventTimes.add(fake.nowMs),
      pageReader(pages, calls), nil, fake.fakeOptions())
    let first = fake.uploads()[0]
    check first.key == 0
    check eventTimes.len == 2
    check eventTimes[0] < 15
    check eventTimes[1] < first.endMs
    check fake.deferredAttempts == 50
    for timeout in fake.readTimeouts:
      check timeout <= 20

  test "a device that stays busy fails the session without a logo and closes it":
    let fake = newFakeDeck()
    fake.deferForever = true
    expect IOError:
      runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = false,
        ignoreKey, nil, nil, fake.fakeOptions())
    check fake.nowMs >= 2000
    check fake.features.len == 1
    check fake.closes == 1

  test "navigation finishes the image in flight and then sends only the newest page":
    let
      directory = getTempDir() / "knobby-player-navigation"
      fake = newFakeDeck()
    createDir(directory)
    defer: removeDir(directory)
    let
      big = writeJpeg(directory, "big.jpg", ImagePayloadBytes * 3)
      other = writeJpeg(directory, "other.jpg")
      pages = new seq[JsonNode]
      calls = new seq[int64]
    pages[].add(framePage(1, "root", [big], big))
    fake.afterWrite = proc (count: int) =
      ## Publish generation two in the middle of the first four-packet image.
      if count == 2:
        pages[].add(framePage(2, "stale", [other], other, key = 5))
    var ready: seq[int64]
    let reader = proc (previousGeneration: int64): JsonNode =
      ## Replace generation two with three before generation two finishes loading.
      if pages[].len == 2 and previousGeneration == 2:
        pages[].add(framePage(3, "media", [other], other, key = 7))
      result = pageReader(pages, calls)(previousGeneration)
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 300,
      ignoreKey, reader, proc () = ready.add(fake.nowMs), fake.fakeOptions())
    let images = fake.uploads()
    check images[0].key == 0
    check images[0].jpeg == readFile(big)
    check images.len == 1 + StreamDeckKeyCount
    for index, upload in images[1..^1]:
      check upload.key == index
      if index == 6:
        check upload.jpeg == readFile(other)
      else:
        check upload.jpeg == builtinNormalImage(index + 1)
    check ready.len == 1
    check 1'i64 in calls[]
    check 2'i64 in calls[]
    check calls[][^1] == 3

  test "key edges reach the callback while a page is loading":
    let
      directory = getTempDir() / "knobby-player-loading"
      fake = newFakeDeck()
    createDir(directory)
    defer: removeDir(directory)
    var frames: seq[string]
    for index in 0..<30:
      frames.add(writeJpeg(directory, $index & ".jpg"))
    let
      pages = new seq[JsonNode]
      calls = new seq[int64]
    pages[].add(framePage(1, "root", frames, frames[0]))
    fake.inputs = @[TimedReport(atMs: 0, report: keyReport([9]))]
    var events: seq[StreamDeckKeyEvent]
    var packetsAtEvent = -1
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 50,
      proc (event: StreamDeckKeyEvent) =
        ## Record when the edge arrived relative to page staging.
        events.add(event)
        packetsAtEvent = fake.packets.len,
      pageReader(pages, calls), nil, fake.fakeOptions())
    check events == @[StreamDeckKeyEvent(keyIndex: 9, pressed: true)]
    check packetsAtEvent == 0

  test "missing, oversized, corrupt and malformed media only affect their own keys":
    let
      directory = getTempDir() / "knobby-player-missing"
      fake = newFakeDeck()
      diagnostics = new seq[string]
    createDir(directory)
    defer: removeDir(directory)
    let
      good = writeJpeg(directory, "good.jpg")
      huge = directory / "huge.jpg"
      corrupt = directory / "corrupt.jpg"
      pages = new seq[JsonNode]
      calls = new seq[int64]
    writeFile(huge, JpegStart & repeat("x", MaxPreparedJpegBytes))
    writeFile(corrupt, "not a jpeg")
    var page = framePage(1, "root", [good], good)
    page["keys"]["2"] = %*{"normal": [{"path": directory / "absent.jpg", "durationMs": 100}],
      "pressed": good}
    page["keys"]["3"] = %*{"normal": [{"path": huge, "durationMs": 100}], "pressed": good}
    page["keys"]["4"] = %*{"normal": [{"path": corrupt, "durationMs": 100}], "pressed": good}
    page["keys"]["5"] = %*{"normal": [{"path": "relative.jpg", "durationMs": 100}]}
    page["keys"]["6"] = %*{"normal": [{"path": good, "durationMs": 0},
      {"path": good, "durationMs": 100}]}
    page["keys"]["7"] = %*{"builtinNumber": 99}
    page["keys"].delete("8")
    page["keys"]["16"] = %*{"builtinNumber": 1}
    pages[].add(page)
    var readyCount = 0
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 100,
      ignoreKey, pageReader(pages, calls), proc () = (inc readyCount),
      fake.fakeOptions(diagnostics))
    let images = fake.uploads()
    check images.len == StreamDeckKeyCount
    check readyCount == 1
    check images[0].jpeg == readFile(good)
    for key in 1..6:
      check images[key].jpeg == missingKeyImage()
    check images[7].jpeg == blankKeyImage()
    for key in 8..<StreamDeckKeyCount:
      check images[key].jpeg == builtinNormalImage(key + 1)
    check diagnostics[].len == 7
    check diagnostics[].join("\n").contains("absent.jpg")
    check diagnostics[].join("\n").contains("unknown key \"16\"")

  test "prepared static images accept zero duration and still support held keys":
    let
      directory = getTempDir() / "knobby-player-static-prepared"
      fake = newFakeDeck()
      diagnostics = new seq[string]
    createDir(directory)
    defer: removeDir(directory)
    let
      normal = writeJpeg(directory, "normal.jpg")
      pressed = writeJpeg(directory, "pressed.jpg", 128)
      pages = new seq[JsonNode]
      calls = new seq[int64]
    pages[].add(framePage(1, "root", [normal], pressed, durationMs = 0))
    fake.inputs = @[TimedReport(atMs: 150, report: keyReport([0])),
      TimedReport(atMs: 250, report: keyReport([]))]
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 400,
      ignoreKey, pageReader(pages, calls), nil, fake.fakeOptions(diagnostics))
    let images = fake.uploads()
    var keyImages: seq[string]
    for image in images:
      if image.key == 0: keyImages.add(image.jpeg)
    check keyImages == @[readFile(normal), readFile(pressed), readFile(normal)]
    check diagnostics[].len == 0

  test "frames are loaded once per generation and reused by the next generation":
    let
      directory = getTempDir() / "knobby-player-preload"
      fake = newFakeDeck()
      diagnostics = new seq[string]
    createDir(directory)
    let
      a = writeJpeg(directory, "a.jpg")
      b = writeJpeg(directory, "b.jpg")
      aBytes = readFile(a)
      bBytes = readFile(b)
      pages = new seq[JsonNode]
      calls = new seq[int64]
    pages[].add(framePage(1, "root", [a, b], a))
    let reader = proc (previousGeneration: int64): JsonNode =
      ## Delete the files once staged, then publish a page reusing them.
      if fake.nowMs >= 300 and dirExists(directory):
        removeDir(directory)
      if fake.nowMs >= 500 and pages[].len == 1:
        pages[].add(framePage(2, "again", [a, b], a, key = 2))
      result = pageReader(pages, calls)(previousGeneration)
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 900,
      ignoreKey, reader, nil, fake.fakeOptions(diagnostics))
    check diagnostics[].len == 0
    var
      reusedUploads = 0
      secondPageUploads = 0
    for upload in fake.uploads():
      check upload.jpeg != missingKeyImage()
      if upload.startMs >= 300 and upload.jpeg in [aBytes, bBytes]:
        inc reusedUploads
        if upload.startMs >= 500:
          check upload.key == 1
          inc secondPageUploads
    check reusedUploads >= 4
    check secondPageUploads >= 1
    check 2'i64 in calls[]

  test "stopping during staging restores the logo without a ready callback":
    let fake = newFakeDeck()
    fake.writeCostMs = 1
    var ready = false
    runConfiguredSession(newStreamDeck(fake.transport()),
      proc (): bool = fake.uploads().len >= 2,
      ignoreKey, nil, proc () = ready = true, fake.fakeOptions())
    check not ready
    check fake.uploads().len == 2
    check fake.features[^1][0..1] == "\x03\x02"
    check fake.closes == 1

  test "disconnects close once without writing the logo":
    let fake = newFakeDeck()
    fake.disconnectAtMs = 40
    expect OSError:
      runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = false,
        ignoreKey, nil, nil, fake.fakeOptions())
    check fake.closes == 1
    check fake.features.len == 1

  test "a close failure after another error preserves the original error":
    let fake = newFakeDeck()
    fake.failClose = true
    fake.inputs = @[TimedReport(atMs: 30, report: keyReport([0]))]
    expect ValueError:
      runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = false,
        proc (event: StreamDeckKeyEvent) =
          ## Fail inside the callback before the close also fails.
          raise newException(ValueError, "Original callback error."),
        nil, nil, fake.fakeOptions())
    check fake.closes == 1

  test "a clean stop reports a close failure instead of hiding it":
    let fake = newFakeDeck()
    fake.failClose = true
    expect OSError:
      runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = true,
        ignoreKey, nil, nil, fake.fakeOptions())
    check fake.closes == 1

  test "a reader without an initial page is rejected":
    let fake = newFakeDeck()
    expect ValueError:
      runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = false,
        ignoreKey, proc (previousGeneration: int64): JsonNode = nil, nil, fake.fakeOptions())
    check fake.closes == 1

proc obsStatus(recording: bool, connected = true): JsonNode =
  ## Build a fake OBS helper status snapshot.
  %*{"connected": connected, "workspaceReady": connected, "minecraftReady": true,
    "recording": recording, "paused": false, "micMuted": false,
    "transitioning": false, "error": ""}

proc obsPage(base, basePressed, recording, recordingPressed: string,
    frames: openArray[string]): JsonNode =
  ## Build a page with a recordToggle key 1 and an animated key 2.
  result = framePage(1, "obs", frames, frames[0], key = 2)
  result["keys"]["1"] = %*{"normal": [{"path": base, "durationMs": 0}],
    "pressed": basePressed, "obsOperation": "recordToggle",
    "states": {"recording": {"normal": [{"path": recording, "durationMs": 0}],
      "pressed": recordingPressed}}}

suite "OBS indicators":
  test "status switches preloaded variants without a new page or clock reset":
    let
      directory = getTempDir() / "knobby-player-obs"
      fake = newFakeDeck()
    createDir(directory)
    defer: removeDir(directory)
    let
      base = writeJpeg(directory, "base.jpg")
      basePressed = writeJpeg(directory, "base-pressed.jpg")
      recording = writeJpeg(directory, "recording.jpg")
      recordingPressed = writeJpeg(directory, "recording-pressed.jpg")
      a = writeJpeg(directory, "a.jpg")
      b = writeJpeg(directory, "b.jpg")
      pages = new seq[JsonNode]
      calls = new seq[int64]
      expected = [readFile(recording), readFile(recordingPressed)]
    pages[].add(obsPage(base, basePressed, recording, recordingPressed, [a, b]))
    fake.inputs = @[TimedReport(atMs: 600, report: keyReport([0])),
      TimedReport(atMs: 700, report: keyReport([]))]
    var
      statusReads = 0
      ready = 0
      events: seq[StreamDeckKeyEvent]
      options = fake.fakeOptions()
    options.readIndicators = proc (): JsonNode =
      ## Report recording from 300 ms of virtual time onwards.
      inc statusReads
      obsStatus(recording = fake.nowMs >= 300)
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 900,
      proc (event: StreamDeckKeyEvent) = events.add(event),
      pageReader(pages, calls),
      proc () =
        ## Variants must already be in memory: remove their files once ready.
        inc ready
        removeFile(recording)
        removeFile(recordingPressed),
      options)
    check ready == 1
    check calls[][0] == 0
    for call in calls[][1..^1]:
      check call == 1
    check statusReads == calls[].len - 1
    check events.len == 2
    var keyOne, keyTwo: seq[Upload]
    for upload in fake.uploads():
      if upload.key == 0: keyOne.add(upload)
      elif upload.key == 1: keyTwo.add(upload)
    var firstRecording = -1'i64
    for upload in keyOne:
      if upload.startMs < 300:
        check upload.jpeg == readFile(base)
      elif upload.startMs >= 600 and upload.startMs < 700:
        check upload.jpeg == expected[1]
      else:
        check upload.jpeg == expected[0]
        if firstRecording < 0:
          firstRecording = upload.startMs
    check firstRecording in 300'i64..340'i64
    check keyOne[^1].jpeg == expected[0]
    for upload in keyTwo:
      let frame = if ((upload.startMs div FrameMs) mod 2) == 0: a else: b
      check upload.jpeg == readFile(frame)
    check keyTwo.len >= 8

  test "a replugged session starts with the current OBS state and missing variants stay local":
    let directory = getTempDir() / "knobby-player-obs-replug"
    createDir(directory)
    defer: removeDir(directory)
    let
      base = writeJpeg(directory, "base.jpg")
      recording = writeJpeg(directory, "recording.jpg")
      a = writeJpeg(directory, "a.jpg")
      page = obsPage(base, base, recording, recording, [a])
    page["keys"]["1"]["states"]["unavailable"] = %*{
      "normal": [{"path": directory / "absent.jpg", "durationMs": FrameMs}]}
    for (connected, shown) in [(true, readFile(recording)), (false, missingKeyImage()),
        (true, readFile(recording))]:
      let
        fake = newFakeDeck()
        pages = new seq[JsonNode]
        calls = new seq[int64]
        diagnostics = new seq[string]
      pages[].add(page)
      var options = fake.fakeOptions(diagnostics)
      options.readIndicators = proc (): JsonNode = obsStatus(true, connected)
      runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 300,
        ignoreKey, pageReader(pages, calls), nil, options)
      var keyOne: seq[string]
      for upload in fake.uploads():
        if upload.key == 0:
          keyOne.add(upload.jpeg)
      check keyOne == @[shown]
      check diagnostics[].len == 1
      check "key 1 state unavailable" in diagnostics[][0]
      check "absent.jpg" in diagnostics[][0]

  test "malformed OBS variants show the missing image for that key only":
    let directory = getTempDir() / "knobby-player-obs-bad"
    createDir(directory)
    defer: removeDir(directory)
    let
      a = writeJpeg(directory, "a.jpg")
      fake = newFakeDeck()
      pages = new seq[JsonNode]
      calls = new seq[int64]
      diagnostics = new seq[string]
    var page = framePage(1, "root", [a], a)
    page["keys"]["1"]["states"] = %*{"live": {"normal": [{"path": a, "durationMs": FrameMs}]}}
    page["keys"]["3"] = %*{"builtinNumber": 3, "obsOperation": 7}
    pages[].add(page)
    var options = fake.fakeOptions(diagnostics)
    options.readIndicators = proc (): JsonNode = obsStatus(false)
    runConfiguredSession(newStreamDeck(fake.transport()), proc (): bool = fake.nowMs >= 200,
      ignoreKey, pageReader(pages, calls), nil, options)
    var shown: array[StreamDeckKeyCount, string]
    for upload in fake.uploads():
      shown[upload.key] = upload.jpeg
    check shown[0] == missingKeyImage()
    check shown[1] == builtinNormalImage(2)
    check shown[2] == missingKeyImage()
    check diagnostics[].len == 2
    var nilOptions = fake.fakeOptions()
    nilOptions.readIndicators = nil
    expect ValueError:
      runConfiguredSession(newStreamDeck(newFakeDeck().transport()), proc (): bool = true,
        ignoreKey, nil, nil, nilOptions)
