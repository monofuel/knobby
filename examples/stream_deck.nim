import
  std/[atomics, os, posix],
  knobby/stream_deck

const
  AssetDirectory = currentSourcePath().parentDir().parentDir() / "assets" / "stream_deck"
  DemoBrightness = 30
  ReconnectMs = 1000
  NormalImages = static:
    var images: array[StreamDeckKeyCount, string]
    for index in 0..<StreamDeckKeyCount:
      images[index] = staticRead(AssetDirectory / ($(index + 1) & "-normal.jpg"))
    images
  PressedImages = static:
    var images: array[StreamDeckKeyCount, string]
    for index in 0..<StreamDeckKeyCount:
      images[index] = staticRead(AssetDirectory / ($(index + 1) & "-pressed.jpg"))
    images

var stopping: Atomic[bool]

proc requestStop() {.noconv.} =
  ## Ask the polling loop to stop without performing I/O in a signal handler.
  stopping.store(true)

proc runDemoSession*(deck: StreamDeck, shouldStop: proc (): bool,
    onKey: proc (event: StreamDeckKeyEvent), onReady: proc () = nil) =
  ## Own one session, display numbered keys, and highlight changes until stopped.
  defer:
    try:
      deck.close()
    except OSError as error:
      stderr.writeLine("Closing Stream Deck failed: " & error.msg)
  deck.setBrightness(DemoBrightness)
  for index in 0..<StreamDeckKeyCount:
    if shouldStop():
      deck.showLogo()
      return
    deck.setKeyImage(index, NormalImages[index])
  if not onReady.isNil:
    onReady()
  while not shouldStop():
    for event in deck.pollKeys():
      let image = if event.pressed: PressedImages[event.keyIndex] else: NormalImages[event.keyIndex]
      deck.setKeyImage(event.keyIndex, image)
      onKey(event)
  deck.showLogo()

proc printKey(event: StreamDeckKeyEvent) =
  ## Print human-facing key numbers in the same order as their displayed labels.
  let state = if event.pressed: "pressed" else: "released"
  echo "Key " & $(event.keyIndex + 1) & " " & state

proc main() =
  ## Run the standalone MK.2 demo, reconnecting without invoking desktop actions.
  setControlCHook(requestStop)
  var lastError = ""
  while not stopping.load():
    try:
      let path = discoverStreamDeck()
      if path.len == 0:
        if lastError != "absent":
          echo "Waiting for Stream Deck MK.2. Press Ctrl+C to exit."
          lastError = "absent"
      else:
        let deck = openStreamDeck(path)
        runDemoSession(deck, proc (): bool = stopping.load(), printKey,
          proc () =
            ## Announce a connection only after its complete page is uploaded.
            echo "Stream Deck MK.2 connected at " & path & ". Keys 1-15; press Ctrl+C to exit."
            lastError.setLen(0))
    except OSError as error:
      if error.errorCode in [EACCES.int32, EPERM.int32]:
        stderr.writeLine("Cannot access Stream Deck as this user: " & error.msg)
        quit(1)
      if not stopping.load() and error.msg != lastError:
        stderr.writeLine("Stream Deck connection lost: " & error.msg)
        lastError = error.msg
    except IOError as error:
      if not stopping.load() and error.msg != lastError:
        stderr.writeLine("Stream Deck transfer failed: " & error.msg)
        lastError = error.msg
    if not stopping.load():
      sleep(ReconnectMs)

when isMainModule:
  main()
