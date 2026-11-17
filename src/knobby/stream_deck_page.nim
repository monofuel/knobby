import
  std/os,
  ./[bindings, stream_deck]

const
  AssetDirectory = currentSourcePath().parentDir().parentDir().parentDir() / "assets" / "stream_deck"
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

proc runDemoSession*(deck: StreamDeck, shouldStop: proc (): bool,
    onKey: proc (event: StreamDeckKeyEvent), onReady: proc () = nil) =
  ## Own the numbered page until stopped; close without masking an earlier failure.
  defer:
    try: deck.close()
    except OSError as error: stderr.writeLine("Closing Stream Deck failed: " & error.msg)
  deck.setBrightness(StreamDeckDemoBrightness)
  for index in 0..<StreamDeckKeyCount:
    if shouldStop():
      deck.showLogo()
      return
    deck.setKeyImage(index, NormalImages[index])
  if not onReady.isNil: onReady()
  while not shouldStop():
    for event in deck.pollKeys():
      onKey(event)
      deck.setKeyImage(event.keyIndex, if event.pressed: PressedImages[event.keyIndex] else: NormalImages[event.keyIndex])
  deck.showLogo()
