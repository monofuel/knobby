import
  std/[atomics, os, tempfiles],
  knobby/stream_deck,
  ./generate_stream_deck_assets

const
  ProbeBrightness = 30
  Variants = [
    (pixelFormat: "yuvj444p", huffman: "optimal"),
    (pixelFormat: "yuvj444p", huffman: "default"),
    (pixelFormat: "yuvj420p", huffman: "optimal"),
    (pixelFormat: "yuvj420p", huffman: "default")]

var stopping: Atomic[bool]

proc requestStop() {.noconv.} =
  ## Ask the polling loop to stop without device I/O in the signal handler.
  stopping.store(true)

proc main() =
  ## Compare JPEG encodings on four cleared keys without changing demo assets.
  let
    font = findFont()
    directory = createTempDir("knobby-jpeg-probe-", "")
    path = discoverStreamDeck()
  defer: removeDir(directory)
  if path.len == 0:
    raise newException(IOError, "Connect a Stream Deck MK.2 before running the probe.")
  let blankPath = directory / "blank.jpg"
  generateKeyImage(blankPath, " ", font, huffman = "default")
  var images: array[Variants.len, string]
  for index, variant in Variants:
    let filename = directory / ($index & ".jpg")
    generateKeyImage(filename, $(index + 1), font,
      pixelFormat = variant.pixelFormat, huffman = variant.huffman)
    images[index] = readFile(filename)
  let deck = openStreamDeck(path)
  defer: deck.close()
  setControlCHook(requestStop)
  deck.setBrightness(ProbeBrightness)
  for index in 0..<StreamDeckKeyCount:
    deck.setKeyImage(index, readFile(blankPath))
  for index, image in images:
    deck.setKeyImage(index, image)
    echo "Key " & $(index + 1) & ": " & Variants[index].pixelFormat &
      ", Huffman " & Variants[index].huffman
  echo "Compare the first four keys in the top row. Ctrl+C restores the logo."
  while not stopping.load():
    for event in deck.pollKeys():
      let state = if event.pressed: "pressed" else: "released"
      echo "Key " & $(event.keyIndex + 1) & " " & state
  deck.showLogo()

when isMainModule:
  main()
