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
  BlankImage = staticRead(AssetDirectory / "blank.jpg")
  MissingImage = staticRead(AssetDirectory / "missing.jpg")

proc builtinNormalImage*(number: int): string =
  ## Return the embedded numbered key JPEG for a one-based key number.
  if number notin 1..StreamDeckKeyCount:
    raise newException(ValueError, "Builtin Stream Deck images are numbered 1 to 15.")
  result = NormalImages[number - 1]

proc builtinPressedImage*(number: int): string =
  ## Return the embedded pressed numbered key JPEG for a one-based key number.
  if number notin 1..StreamDeckKeyCount:
    raise newException(ValueError, "Builtin Stream Deck images are numbered 1 to 15.")
  result = PressedImages[number - 1]

proc blankKeyImage*(): string =
  ## Return the embedded black JPEG shown on unassigned keys.
  BlankImage

proc missingKeyImage*(): string =
  ## Return the embedded JPEG shown when a key's prepared media cannot be used.
  MissingImage

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
