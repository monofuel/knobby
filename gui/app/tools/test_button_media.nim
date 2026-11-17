import
  std/[json, os, osproc, strutils, times, unittest],
  knobby/button_media

const
  RepositoryDirectory = currentSourcePath().parentDir() / ".." / ".." / ".."
  FixtureDirectory = RepositoryDirectory / "tests" / "fixtures" / "buttons"
  FontPath = RepositoryDirectory / "gui" / "app" / "assets" / "DejaVuSans.ttf"
  HelperSource = RepositoryDirectory / "tools" / "prepare_button_media.nim"
  # Deliberately awkward: filtergraph separators, quotes and spaces in paths.
  WorkName = "knobby media it [a],b;c:d'e %d "
  Red = (255, 0, 0)
  Green = (0, 255, 0)
  Blue = (0, 0, 255)
  Black = (0, 0, 0)
  PressedRed = (255, 89, 89)
  PressedGrey = (192, 192, 192)
  ColorTolerance = 48
  SourceBlock = 18

type
  Rgb = tuple[r, g, b: int]
  Pixels = object
    data: string

var
  work: string
  inputs: string
  configDir: string
  cacheDir: string

proc ffmpeg(args: varargs[string]) =
  ## Run FFmpeg to make an integration-test input.
  discard runTool(@["ffmpeg", "-nostdin", "-v", "error", "-y"] & @args)

proc decode(path: string): Pixels =
  ## Decode a prepared JPEG to raw RGB, rotated upright as a preview would.
  result.data = runTool(@["ffmpeg", "-nostdin", "-v", "error", "-i", "file:" & path,
    "-vf", "hflip,vflip", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
  check result.data.len == KeySize * KeySize * 3

proc at(pixels: Pixels, x, y: int): Rgb =
  ## Return the upright pixel at x, y.
  let offset = (y * KeySize + x) * 3
  result = (pixels.data[offset].ord, pixels.data[offset + 1].ord,
    pixels.data[offset + 2].ord)

proc near(actual, expected: Rgb): bool =
  ## Compare colours with JPEG tolerance.
  result = abs(actual.r - expected.r) <= ColorTolerance and
    abs(actual.g - expected.g) <= ColorTolerance and
    abs(actual.b - expected.b) <= ColorTolerance

proc checkBlock(pixels: Pixels, sourceX, sourceY: int, expected: Rgb) =
  ## Check the centre of one upscaled 4x4 source pixel.
  let actual = pixels.at(sourceX * SourceBlock + SourceBlock div 2,
    sourceY * SourceBlock + SourceBlock div 2)
  if not near(actual, expected):
    checkpoint("pixel " & $sourceX & "," & $sourceY & " is " & $actual &
      ", expected " & $expected)
  check near(actual, expected)

proc jpegLayout(path: string): tuple[baseline, progressive, huffman: bool,
    width, height: int, sampling: seq[int]] =
  ## Walk JPEG markers up to the scan and report frame parameters.
  let data = readFile(path)
  check data.startsWith("\xff\xd8")
  var position = 2
  while position + 4 <= data.len:
    let marker = data[position + 1].ord
    if marker == 0xda:
      break
    let length = data[position + 2].ord shl 8 or data[position + 3].ord
    case marker
    of 0xc0, 0xc2:
      result.baseline = marker == 0xc0
      result.progressive = marker == 0xc2
      result.height = data[position + 5].ord shl 8 or data[position + 6].ord
      result.width = data[position + 7].ord shl 8 or data[position + 8].ord
      for component in 0..<data[position + 9].ord:
        result.sampling.add(data[position + 11 + component * 3].ord)
    of 0xc4:
      result.huffman = true
    else:
      discard
    position += 2 + length

proc checkEncoding(path: string) =
  ## Verify a prepared key matches the device JPEG requirements.
  let layout = jpegLayout(path)
  check layout.baseline
  check not layout.progressive
  check layout.huffman
  check layout.width == KeySize
  check layout.height == KeySize
  check layout.sampling == @[0x22, 0x11, 0x11]
  let probe = parseJson(runTool(@["ffprobe", "-v", "error", "-show_entries",
    "stream=codec_name,pix_fmt,width,height", "-of", "json", "file:" & path]))
  check probe["streams"][0]["codec_name"].getStr() == "mjpeg"
  check probe["streams"][0]["pix_fmt"].getStr() == "yuvj420p"

proc readPpm(path: string): tuple[width, height: int, data: string] =
  ## Read the binary PPM fixture into raw RGB.
  let
    text = readFile(path)
    header = text.splitWhitespace(maxsplit = 4)
  check header[0] == "P6"
  result.width = parseInt(header[1])
  result.height = parseInt(header[2])
  result.data = text[text.len - result.width * result.height * 3 .. ^1]

proc menuConfig(deck: JsonNode, extraMenus: JsonNode = newJArray()): JsonNode =
  ## Wrap Deck entries in a root menu plus optional extra menus.
  var menus = %*[{"id": "root", "title": "Main", "mixer": [], "deck": deck}]
  for menu in extraMenus:
    menus.add(menu)
  result = %*{"version": 1, "root": "root", "menus": menus}

proc artKey(key: int, image: string, title = "", showTitle = false): JsonNode =
  ## Build an artwork Deck entry.
  result = %*{"key": key, "title": title, "action": {"kind": "none"},
    "visual": {"image": image, "showTitle": showTitle}}

proc prepare(config: JsonNode): JsonNode =
  ## Prepare media into the shared integration cache.
  result = prepareButtonMedia(config, configDir, cacheDir, FontPath)

proc entryCount(directory: string): int =
  ## Count directory entries, including hidden work directories.
  if dirExists(directory):
    for entry in walkDir(directory):
      inc result

proc workEntries(directory: string): int =
  ## Count unpublished work directories.
  if dirExists(directory):
    for kind, path in walkDir(directory):
      if path.extractFilename.startsWith(".tmp-"):
        inc result

suite "button media FFmpeg integration":
  setup:
    work = getTempDir() / WorkName & $getCurrentProcessId()
    configDir = work / "config"
    cacheDir = work / "prepared"
    removeDir(work)
    createDir(configDir)
    inputs = getTempDir() / "knobby-media-inputs-" & $getCurrentProcessId()
    removeDir(inputs)
    createDir(inputs)

  teardown:
    removeDir(work)
    removeDir(inputs)

  test "GIF disposal, partial frames and transparency composite on black":
    let
      image = importButtonAsset(FixtureDirectory / "disposal.gif", configDir)
      manifest = prepare(menuConfig(%*[artKey(2, image)]))
      key = manifest["menus"]["root"]["2"]
      normal = key["normal"]
    check image.startsWith("assets/") and image.endsWith(".gif")
    check fileExists(configDir / image)
    check readFile(configDir / image) == readFile(FixtureDirectory / "disposal.gif")
    check normal.len == 4
    var durations: seq[int]
    for frame in normal:
      durations.add(frame["durationMs"].getInt())
      check isAbsolute(frame["path"].getStr())
      checkEncoding(frame["path"].getStr())
    check durations == @[100, 200, 300, 400]
    let frames = [decode(normal[0]["path"].getStr()), decode(normal[1]["path"].getStr()),
      decode(normal[2]["path"].getStr()), decode(normal[3]["path"].getStr())]
    for y in 0..3:
      for x in 0..3:
        frames[0].checkBlock(x, y, Red)
        frames[1].checkBlock(x, y, if x < 2 and y < 2: Green else: Red)
        frames[2].checkBlock(x, y, if x >= 2 and y >= 2: Blue else: Red)
        let fourth =
          if x == 3 and y == 3: Green
          elif x >= 2 and y >= 2: Black
          else: Red
        frames[3].checkBlock(x, y, fourth)
    checkEncoding(key["pressed"].getStr())
    let pressed = decode(key["pressed"].getStr())
    pressed.checkBlock(0, 0, PressedRed)
    pressed.checkBlock(3, 3, PressedRed)

  test "device orientation is rotated 180 degrees":
    let
      image = importButtonAsset(FixtureDirectory / "disposal.gif", configDir)
      manifest = prepare(menuConfig(%*[artKey(2, image)]))
      raw = runTool(@["ffmpeg", "-nostdin", "-v", "error", "-i",
        "file:" & manifest["menus"]["root"]["2"]["normal"][1]["path"].getStr(),
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
      corner = (KeySize - SourceBlock div 2) * (KeySize + 1) * 3
    # Upright green top-left lands bottom-right in the device JPEG.
    check near((raw[corner].ord, raw[corner + 1].ord, raw[corner + 2].ord), Green)
    check near((raw[27 * 3].ord, raw[27 * 3 + 1].ord, raw[27 * 3 + 2].ord), Red)

  test "wide images are contained proportionally with black bars":
    let
      ppm = readPpm(FixtureDirectory / "wide.ppm")
      png = inputs / "wide.png"
    ffmpeg("-f", "ppm_pipe", "-i", "file:" & FixtureDirectory / "wide.ppm", png)
    let
      image = importButtonAsset(png, configDir)
      manifest = prepare(menuConfig(%*[artKey(3, image)]))
      pixels = decode(manifest["menus"]["root"]["3"]["normal"][0]["path"].getStr())
      scale = KeySize div ppm.width
      top = (KeySize - ppm.height * scale) div 2
    check image.endsWith(".png")
    check manifest["menus"]["root"]["3"]["normal"][0]["durationMs"].getInt() == 0
    for x in [0, 35, 71]:
      check near(pixels.at(x, 2), Black)
      check near(pixels.at(x, KeySize - 3), Black)
    for y in 0..<ppm.height:
      for x in 0..<ppm.width:
        let
          offset = (y * ppm.width + x) * 3
          expected = (ppm.data[offset].ord, ppm.data[offset + 1].ord,
            ppm.data[offset + 2].ord)
          actual = pixels.at(x * scale + scale div 2, top + y * scale + scale div 2)
        if not near(actual, expected):
          checkpoint($x & "," & $y & " " & $actual & " != " & $expected)
        check near(actual, expected)

  test "JPEG and large PNG sources are downscaled":
    let
      jpeg = inputs / "photo.jpg"
      tall = inputs / "tall.png"
    ffmpeg("-f", "lavfi", "-i", "color=c=blue:s=640x480", "-frames:v", "1", jpeg)
    ffmpeg("-f", "lavfi", "-i", "color=c=0x00ff00:s=100x400", "-frames:v", "1", tall)
    let
      manifest = prepare(menuConfig(%*[
        artKey(4, importButtonAsset(jpeg, configDir)),
        artKey(5, importButtonAsset(tall, configDir))]))
      photo = decode(manifest["menus"]["root"]["4"]["normal"][0]["path"].getStr())
      narrow = decode(manifest["menus"]["root"]["5"]["normal"][0]["path"].getStr())
    check near(photo.at(36, 36), Blue)
    check near(photo.at(36, 2), Black)
    check near(narrow.at(36, 36), Green)
    check near(narrow.at(2, 36), Black)
    check near(narrow.at(36, 2), Green)

  test "titles, Back and blank keys render with Unicode and special text":
    let
      special = "Wörld ☃ %{n} :\\ 'q' [x],y;z"
      manifest = prepare(menuConfig(%*[
        {"key": 2, "title": special, "action": {"kind": "none"}},
        {"key": 3, "title": "Plain", "action": {"kind": "none"}}],
        %*[{"id": "sub", "title": "Sub", "mixer": [], "deck": []}]))
      root = manifest["menus"]["root"]
      sub = manifest["menus"]["sub"]
    check root.len == DeckKeyCount
    check sub.len == DeckKeyCount
    for key in 1..DeckKeyCount:
      checkEncoding(root[$key]["normal"][0]["path"].getStr())
      checkEncoding(root[$key]["pressed"].getStr())
    let
      titled = decode(root["2"]["normal"][0]["path"].getStr())
      blank = decode(root["1"]["normal"][0]["path"].getStr())
      blankPressed = decode(root["1"]["pressed"].getStr())
      back = decode(sub["1"]["normal"][0]["path"].getStr())
      backPressed = decode(sub["1"]["pressed"].getStr())
    var titledLight, backLight, backPressedDark = 0
    for y in 0..<KeySize:
      for x in 0..<KeySize:
        check near(blank.at(x, y), Black)
        check near(blankPressed.at(x, y), PressedGrey)
        if titled.at(x, y).r > 128: inc titledLight
        if back.at(x, y).r > 128: inc backLight
        if backPressed.at(x, y).r < 64: inc backPressedDark
    check titledLight > 40
    check backLight > 40
    check backPressedDark > 40
    check root["2"]["normal"][0]["path"] != root["3"]["normal"][0]["path"]
    check sub["2"]["normal"][0]["path"] == root["1"]["normal"][0]["path"]
    check readFile(sub["1"]["normal"][0]["path"].getStr()) !=
      readFile(root["1"]["normal"][0]["path"].getStr())

  test "artwork titles are optional overlays":
    let
      image = importButtonAsset(FixtureDirectory / "disposal.gif", configDir)
      manifest = prepare(menuConfig(%*[artKey(2, image),
        artKey(3, image, "Ünïcode", showTitle = true),
        artKey(4, image, "Hidden", showTitle = false)]))
      plain = manifest["menus"]["root"]["2"]
      titled = manifest["menus"]["root"]["3"]
    check manifest["menus"]["root"]["4"] == plain
    check titled["normal"].len == 4
    check readFile(titled["normal"][0]["path"].getStr()) !=
      readFile(plain["normal"][0]["path"].getStr())
    decode(titled["normal"][0]["path"].getStr()).checkBlock(0, 0, Red)

  test "prepared media is reused from the cache":
    let
      image = importButtonAsset(FixtureDirectory / "disposal.gif", configDir)
      config = menuConfig(%*[artKey(2, image),
        {"key": 3, "title": "Cached", "action": {"kind": "none"}}])
      first = prepare(config)
      entries = entryCount(cacheDir)
      firstPath = first["menus"]["root"]["2"]["pressed"].getStr()
      stamp = getLastModificationTime(firstPath)
    check importButtonAsset(FixtureDirectory / "disposal.gif", configDir) == image
    sleep(20)
    let second = prepare(config)
    check second == first
    check entryCount(cacheDir) == entries
    check getLastModificationTime(firstPath) == stamp
    check workEntries(cacheDir) == 0

  test "fast GIFs are limited to thirty frames per second":
    let gif = inputs / "fast.gif"
    ffmpeg("-f", "lavfi", "-i", "testsrc=s=16x16:r=50", "-t", "1", gif)
    let
      manifest = prepare(menuConfig(%*[artKey(2, importButtonAsset(gif, configDir))]))
      normal = manifest["menus"]["root"]["2"]["normal"]
    var total = 0
    for frame in normal:
      check frame["durationMs"].getInt() * MaxFramesPerSecond >= 1000
      total += frame["durationMs"].getInt()
    check normal.len == 25
    check total == 1000

  test "limits reject long, many-frame, oversized and huge sources":
    let
      long = inputs / "long.gif"
      many = inputs / "many.gif"
      wide = inputs / "wide.png"
      huge = inputs / "huge.png"
    ffmpeg("-f", "lavfi", "-i", "color=c=red:s=4x4:r=1", "-t", "31", long)
    ffmpeg("-f", "lavfi", "-i", "color=c=red:s=4x4:r=50", "-t", "19", many)
    ffmpeg("-f", "lavfi", "-i", "color=c=red:s=4097x2", "-frames:v", "1", wide)
    writeFile(huge, "\x89PNG\r\n\x1a\n" & repeat('\0', MaxSourceBytes))
    for (path, reason) in [(long, "ms"), (many, "frames"), (wide, "4097x2"),
        (huge, "bytes")]:
      try:
        discard importButtonAsset(path, configDir)
        checkpoint(path & " was accepted")
        check false
      except MediaError as error:
        check error.field == "source"
        check reason in error.msg
    check not dirExists(configDir / "assets") or
      entryCount(configDir / "assets") == 0

  test "invalid files are rejected and nothing is written":
    let
      text = inputs / "text.png"
      truncated = inputs / "truncated.gif"
      fake = inputs / "fake.png"
    writeFile(text, "not an image")
    writeFile(truncated, readFile(FixtureDirectory / "disposal.gif")[0..<20])
    writeFile(fake, "\x89PNG\r\n\x1a\n" & readFile(FixtureDirectory / "disposal.gif"))
    expect MediaError:
      discard importButtonAsset(FixtureDirectory / "wide.ppm", configDir)
    expect MediaError:
      discard importButtonAsset(text, configDir)
    expect MediaError:
      discard importButtonAsset(work / "missing.png", configDir)
    for path in [truncated, fake]:
      expect CatchableError:
        discard importButtonAsset(path, configDir)
    check not dirExists(configDir / "assets") or
      entryCount(configDir / "assets") == 0

  test "failed preparation is atomic":
    let good = prepare(menuConfig(%*[{"key": 2, "title": "Good",
      "action": {"kind": "none"}}]))
    let entries = entryCount(cacheDir)
    createDir(configDir / "assets")
    writeFile(configDir / "assets" / "broken.gif",
      readFile(FixtureDirectory / "disposal.gif")[0..<40])
    expect CatchableError:
      discard prepare(menuConfig(%*[{"key": 2, "title": "Good",
        "action": {"kind": "none"}}, artKey(3, "assets/broken.gif")]))
    expect MediaError:
      discard prepare(menuConfig(%*[artKey(3, "assets/missing.gif")]))
    check entryCount(cacheDir) == entries
    check workEntries(cacheDir) == 0
    check fileExists(good["menus"]["root"]["2"]["normal"][0]["path"].getStr())

  test "child processes are bounded and keep stderr separate":
    check runTool(@["sh", "-c", "printf out; printf err >&2"]) == "out"
    try:
      discard runTool(@["sh", "-c", "printf oops >&2; exit 3"])
      check false
    except OSError as error:
      check "oops" in error.msg
    expect IOError:
      discard runTool(@["sh", "-c", "yes"])
    let started = epochTime()
    expect IOError:
      discard runTool(@["sleep", "10"], timeoutMs = 300)
    check epochTime() - started < 5

  test "helper CLI prints only structured output on stdout":
    let helper = work / "prepare_button_media"
    let (buildOutput, buildCode) = execCmdEx(quoteShellCommand(["nim", "c",
      "--hints:off", "--verbosity:0", "-o:" & helper, HelperSource]))
    checkpoint(buildOutput)
    check buildCode == 0
    let imported = parseJson(runTool(@[helper, "import", "--source",
      FixtureDirectory / "disposal.gif", "--config-dir", configDir]))
    check imported["path"].getStr().startsWith("assets/")
    writeFile(work / "buttons.json", $menuConfig(%*[
      artKey(2, imported["path"].getStr(), "CLI", showTitle = true)]))
    let manifest = parseJson(runTool(@[helper, "prepare", "--config",
      work / "buttons.json", "--config-dir", configDir, "--cache-dir", cacheDir,
      "--font", FontPath]))
    check manifest["menus"]["root"]["2"]["normal"].len == 4
    discard runTool(@[helper, "prepare", "--config", work / "buttons.json",
      "--config-dir", configDir, "--cache-dir", cacheDir, "--font", FontPath,
      "--output", work / "manifest.json"])
    check parseJson(readFile(work / "manifest.json")) == manifest
    let
      rejectArgs = quoteShellCommand([helper, "import", "--source",
        FixtureDirectory / "wide.ppm", "--config-dir", configDir])
      failedStdout = execCmdEx(rejectArgs & " 2>/dev/null")
      failedStderr = execCmdEx(rejectArgs & " 2>&1 >/dev/null")
    check failedStdout.exitCode == 1
    check failedStdout.output == ""
    check failedStderr.output.startsWith("error: source: ")
    check "PNG, JPEG or GIF" in failedStderr.output
    let usage = execCmdEx(quoteShellCommand([helper, "prepare"]))
    check usage.exitCode == 2
