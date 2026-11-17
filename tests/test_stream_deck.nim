import
  std/[options, os, strutils, unittest],
  knobby/stream_deck,
  ../examples/stream_deck as deckDemo

type
  FakeDeck = ref object
    reports: seq[string]
    writes: seq[string]
    features: seq[string]
    reads: int
    closes: int
    disconnect: bool
    shortWrite: bool
    shortFeature: bool
    failClose: bool

const
  TestIdentity = "HID_ID=0003:00000FD9:00000080\nHID_NAME=Elgato Stream Deck MK.2\n"
  AssetDirectory = currentSourcePath().parentDir().parentDir() / "assets" / "stream_deck"

proc jpegFrame(jpeg: string): string =
  ## Extract the baseline frame header before the compressed scan begins.
  doAssert jpeg[0..1] == "\xff\xd8"
  var offset = 2
  while offset + 4 <= jpeg.len:
    doAssert jpeg[offset] == '\xff'
    let
      marker = jpeg[offset + 1]
      size = (ord(jpeg[offset + 2]) shl 8) or ord(jpeg[offset + 3])
    doAssert size >= 2 and offset + size + 2 <= jpeg.len
    if marker == '\xc0':
      return jpeg[offset + 4..<offset + size + 2]
    doAssert marker != '\xda'
    offset += size + 2
  raise newException(ValueError, "Missing baseline JPEG frame header.")

proc keyReport(pressed: openArray[int]): string =
  ## Construct a synthetic report containing the complete state of fifteen keys.
  result = newString(19)
  result[0] = '\x01'
  result[2] = '\x0f'
  for key in pressed:
    result[4 + key] = '\x01'

proc transport(fake: FakeDeck): StreamDeckIo =
  ## Supply fake transport operations that cannot access a real device.
  result = StreamDeckIo(
    readReport: proc (timeoutMs: int): string =
      ## Consume queued synthetic reports or simulate a quiet or missing device.
      inc fake.reads
      if fake.reports.len > 0:
        result = fake.reports[0]
        fake.reports.delete(0)
      elif fake.disconnect:
        raise newException(OSError, "Synthetic disconnect."),
    writeReport: proc (report: string): int =
      ## Record one output report and optionally simulate a short write.
      fake.writes.add(report)
      result = if fake.shortWrite: report.len - 1 else: report.len,
    sendFeature: proc (report: string): int =
      ## Record a feature request and optionally simulate a short transfer.
      fake.features.add(report)
      result = if fake.shortFeature: report.len - 1 else: report.len,
    close: proc () =
      ## Count descriptor releases and optionally simulate a close failure.
      inc fake.closes
      if fake.failClose:
        raise newException(OSError, "Synthetic close failure."))

suite "Stream Deck input protocol":
  test "decode simultaneous keys and padded reports":
    let state = parseKeyStates(keyReport([0, 7, 14]) & newString(20)).get()
    for index in 0..<StreamDeckKeyCount:
      check state[index] == (index in [0, 7, 14])

  test "ignore unrelated reports without changing a held key":
    let fake = FakeDeck(reports: @[keyReport([2]), "\x02", "\x01\x09"])
    let deck = newStreamDeck(fake.transport())
    defer: deck.close()
    check deck.pollKeys() == @[StreamDeckKeyEvent(keyIndex: 2, pressed: true)]
    check deck.pollKeys().len == 0
    check deck.pollKeys().len == 0
    fake.reports.add(keyReport([]))
    check deck.pollKeys() == @[StreamDeckKeyEvent(keyIndex: 2, pressed: false)]

  test "reject incomplete, wrong-length and invalid-state key reports":
    for truncated in ["\x01", "\x01\x00", keyReport([])[0..^2]]:
      expect ValueError:
        discard parseKeyStates(truncated)
    var wrongLength = keyReport([])
    wrongLength[2] = '\x0e'
    expect ValueError:
      discard parseKeyStates(wrongLength)
    wrongLength = keyReport([])
    wrongLength[3] = '\x01'
    expect ValueError:
      discard parseKeyStates(wrongLength)
    var invalidState = keyReport([])
    invalidState[4] = '\x02'
    expect ValueError:
      discard parseKeyStates(invalidState)

  test "held keys do not repeat and releases are independent":
    let fake = FakeDeck(reports: @[keyReport([0, 14]), keyReport([0, 14]),
      keyReport([14]), keyReport([])])
    let deck = newStreamDeck(fake.transport())
    defer: deck.close()
    check deck.pollKeys() == @[
      StreamDeckKeyEvent(keyIndex: 0, pressed: true),
      StreamDeckKeyEvent(keyIndex: 14, pressed: true)]
    check deck.pollKeys().len == 0
    check deck.pollKeys() == @[StreamDeckKeyEvent(keyIndex: 0, pressed: false)]
    check deck.pollKeys() == @[StreamDeckKeyEvent(keyIndex: 14, pressed: false)]
    check deck.pollKeys().len == 0
    expect ValueError:
      discard deck.pollKeys(-1)

suite "Stream Deck output protocol":
  test "encode image boundaries, final flags, padding and lossless payload":
    for size in [1, ImagePayloadBytes - 1, ImagePayloadBytes, ImagePayloadBytes + 1,
        ImagePayloadBytes * 2, ImagePayloadBytes * 2 + 3]:
      let
        jpeg = repeat("J", size)
        reports = encodeKeyImageReports(14, jpeg)
      var reconstructed = ""
      for index, report in reports:
        let payloadSize = ord(report[4]) or (ord(report[5]) shl 8)
        check report.len == ImageReportBytes
        check report[0..2] == "\x02\x07\x0e"
        check ord(report[3]) == ord(index == reports.high)
        check (ord(report[6]) or (ord(report[7]) shl 8)) == index
        reconstructed.add(report[8..<8 + payloadSize])
        for padding in 8 + payloadSize..<report.len:
          check report[padding] == '\x00'
      check reconstructed == jpeg

  test "encode image page indexes above a single byte":
    let reports = encodeKeyImageReports(0, repeat("J", ImagePayloadBytes * 256 + 1))
    check reports.len == 257
    check reports[^1][6..7] == "\x00\x01"

  test "reject invalid keys and empty images":
    for key in [-1, 15]:
      expect ValueError:
        discard encodeKeyImageReports(key, "JPEG")
    expect ValueError:
      discard encodeKeyImageReports(0, "")

  test "encode brightness as a zero-padded feature report":
    for brightness in [0, 30, 100]:
      let report = encodeBrightnessReport(brightness)
      check report.len == 32
      check report[0..1] == "\x03\x08"
      check ord(report[2]) == brightness
      check report[3..^1] == newString(29)
    for brightness in [-1, 101]:
      expect ValueError:
        discard encodeBrightnessReport(brightness)

  test "short writes abort a report without sending its remainder":
    let fake = FakeDeck(shortWrite: true, shortFeature: true)
    let deck = newStreamDeck(fake.transport())
    defer: deck.close()
    expect IOError:
      deck.setKeyImage(0, repeat("J", ImagePayloadBytes + 1))
    check fake.writes.len == 1
    expect IOError:
      deck.setBrightness(30)
    expect IOError:
      deck.showLogo()

suite "Stream Deck discovery and session ownership":
  test "input-only monitors read and close without any output callbacks":
    let fake = FakeDeck(reports: @[keyReport([0, 14]), keyReport([])])
    let io = fake.transport()
    let monitor = newStreamDeckMonitor(io.readReport, io.close)
    check monitor.pollKeys(0).len == 2
    check monitor.pollKeys(0).len == 2
    monitor.close()
    monitor.close()
    check fake.closes == 1
    check fake.writes.len == 0
    check fake.features.len == 0
    expect IOError: discard monitor.pollKeys(0)
    static:
      doAssert not compiles(monitor.showLogo())
      doAssert not compiles(monitor.setBrightness(30))

  test "match only the USB MK.2 identity":
    check matchesStreamDeckIdentity(TestIdentity)
    check not matchesStreamDeckIdentity("HID_ID=0003:00001532:00000C02")
    check not matchesStreamDeckIdentity("HID_ID=0005:00000FD9:00000080")
    check not matchesStreamDeckIdentity("HID_ID=garbage")
    check not matchesStreamDeckIdentity("HID_NAME=Stream Deck MK.2")

  test "discover absent, renumbered and ambiguous nodes using fake sysfs":
    let root = getTempDir() / ("knobby-deck-test-" & $getCurrentProcessId())
    createDir(root)
    defer: removeDir(root)
    check discoverStreamDeck(root).len == 0
    createDir(root / "hidraw41" / "device")
    writeFile(root / "hidraw41" / "device" / "uevent", TestIdentity)
    check discoverStreamDeck(root) == "/dev/hidraw41"
    moveDir(root / "hidraw41", root / "hidraw42")
    check discoverStreamDeck(root) == "/dev/hidraw42"
    createDir(root / "hidraw43" / "device")
    writeFile(root / "hidraw43" / "device" / "uevent", TestIdentity)
    expect ValueError:
      discard discoverStreamDeck(root)

  test "closed sessions are idempotent and reconnect starts with fresh keys":
    let fake = FakeDeck(reports: @[keyReport([1])], disconnect: true)
    let deck = newStreamDeck(fake.transport())
    discard deck.pollKeys()
    expect OSError:
      discard deck.pollKeys()
    deck.close()
    deck.close()
    check fake.closes == 1
    expect IOError:
      discard deck.pollKeys()
    fake.reports.add(keyReport([1]))
    let reconnected = newStreamDeck(fake.transport())
    check reconnected.pollKeys() == @[StreamDeckKeyEvent(keyIndex: 1, pressed: true)]
    reconnected.close()
    check fake.closes == 2

suite "Standalone Stream Deck demo":
  test "bundled assets use the hardware-verified 72-pixel baseline 4:2:0 format":
    for number in 1..StreamDeckKeyCount:
      for suffix in ["-normal.jpg", "-pressed.jpg"]:
        let frame = jpegFrame(readFile(AssetDirectory / ($number & suffix)))
        check frame == "\x08\x00\x48\x00\x48\x03\x01\x22\x00\x02\x11\x00\x03\x11\x00"

  test "highlight simultaneous presses, restore releases and show logo on exit":
    let
      fake = FakeDeck(reports: @[keyReport([0, 14]), keyReport([])])
      deck = newStreamDeck(fake.transport())
    var events: seq[StreamDeckKeyEvent]
    deckDemo.runDemoSession(deck, proc (): bool = fake.reads >= 2,
      proc (event: StreamDeckKeyEvent) =
        ## Retain demo events for assertions without launching any actions.
        events.add(event))
    check events == @[
      StreamDeckKeyEvent(keyIndex: 0, pressed: true),
      StreamDeckKeyEvent(keyIndex: 14, pressed: true),
      StreamDeckKeyEvent(keyIndex: 0, pressed: false),
      StreamDeckKeyEvent(keyIndex: 14, pressed: false)]
    var completeImages = 0
    for report in fake.writes:
      if report[3] == '\x01':
        inc completeImages
    check completeImages == 19
    check fake.features.len == 2
    check fake.features[0] == encodeBrightnessReport(30)
    check fake.features[1][0..1] == "\x03\x02"
    check fake.closes == 1

  test "disconnect closes the session without trying to write the logo":
    let fake = FakeDeck(disconnect: true)
    expect OSError:
      deckDemo.runDemoSession(newStreamDeck(fake.transport()), proc (): bool = false,
        proc (event: StreamDeckKeyEvent) =
          ## Reject unexpected input in the disconnected fake session.
          raise newException(ValueError, "Unexpected event."))
    check fake.closes == 1
    check fake.features.len == 1

  test "setup failure still closes the session":
    let fake = FakeDeck(shortWrite: true)
    expect IOError:
      deckDemo.runDemoSession(newStreamDeck(fake.transport()), proc (): bool = false,
        proc (event: StreamDeckKeyEvent) =
          ## Reject unexpected input before setup completes.
          raise newException(ValueError, "Unexpected event."))
    check fake.closes == 1

  test "cleanup failures preserve the original session error":
    let fake = FakeDeck(reports: @[keyReport([0])], failClose: true)
    expect ValueError:
      deckDemo.runDemoSession(newStreamDeck(fake.transport()), proc (): bool = false,
        proc (event: StreamDeckKeyEvent) =
          ## Simulate a callback failure before the close operation also fails.
          raise newException(ValueError, "Original callback error."))
    check fake.closes == 1

  test "an early stop restores the logo and closes without uploading images":
    let fake = FakeDeck()
    deckDemo.runDemoSession(newStreamDeck(fake.transport()), proc (): bool = true,
      proc (event: StreamDeckKeyEvent) =
        ## Reject unexpected input while stopping during setup.
        raise newException(ValueError, "Unexpected event."))
    check fake.writes.len == 0
    check fake.features.len == 2
    check fake.features[^1][0..1] == "\x03\x02"
    check fake.closes == 1
