import
  std/[json, os, posix, sets, strutils, times, unittest],
  knobby/button_media

const
  FixtureDirectory = currentSourcePath().parentDir() / "fixtures" / "buttons"
  # Captured from: ffprobe -f gif -show_entries stream=time_base:packet=pts,duration
  # on fixtures/buttons/disposal.gif.
  DisposalPackets = """{"packets":[{"pts":0,"duration":10},{"pts":10,"duration":20},
    {"pts":30,"duration":30},{"pts":60,"duration":40}],
    "streams":[{"time_base":"1/100"}]}"""

proc deckKey(key: int, title = "", visual: JsonNode = nil,
    action = %*{"kind": "none"}): JsonNode =
  ## Build one Deck entry in the shared configuration shape.
  result = %*{"key": key, "title": title, "action": action}
  if not visual.isNil:
    result["visual"] = visual

proc buttonConfig(menus: JsonNode, root = "root"): JsonNode =
  ## Wrap menus in the shared configuration envelope.
  result = %*{"version": 1, "root": root, "menus": menus}

proc builtinMenu(id: string): JsonNode =
  ## Build a menu whose Deck keys all use the compiled numbered images.
  var deck = newJArray()
  for key in 1..DeckKeyCount:
    deck.add(deckKey(key, $key, %*{"builtinNumber": key, "showTitle": false}))
  result = %*{"id": id, "title": id, "mixer": [], "deck": deck}

proc cleanupWork(): string =
  ## Return a fresh private directory for cache cleanup tests.
  result = getTempDir() / "knobby-media-cleanup [ü] %d " & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc makeEntry(directory: string, ageSeconds: int) =
  ## Create a cache entry directory whose modification time is ageSeconds old.
  createDir(directory)
  writeFile(directory / "pressed.jpg", "jpeg")
  setLastModificationTime(directory, getTime() - initDuration(seconds = ageSeconds))

proc planFor(plans: seq[MenuPlan], menu: string, key: int): KeyPlan =
  ## Find the plan of one key.
  for plan in plans:
    if plan.id == menu:
      return plan.keys[key - 1]
  raise newException(KeyError, menu)

suite "button media source validation":
  test "recognizes supported signatures from real fixture bytes":
    check sourceKindFromBytes(readFile(FixtureDirectory / "disposal.gif")) == GifSource
    check sourceKindFromBytes("\x89PNG\r\n\x1a\nrest") == PngSource
    check sourceKindFromBytes("\xff\xd8\xff\xe0rest") == JpegSource

  test "rejects unsupported formats with field context":
    expect MediaError:
      discard sourceKindFromBytes(readFile(FixtureDirectory / "wide.ppm"))
    try:
      discard sourceKindFromBytes("", "source")
      check false
    except MediaError as error:
      check error.field == "source"
      check "PNG, JPEG or GIF" in error.msg

  test "stream probes enforce codec and dimensions":
    let ok = parseStreamProbe(PngSource,
      """{"streams":[{"codec_name":"png","width":4096,"height":12}]}""")
    check ok.width == 4096
    check ok.height == 12
    expect MediaError:
      discard parseStreamProbe(PngSource,
        """{"streams":[{"codec_name":"png","width":4097,"height":12}]}""")
    expect MediaError:
      discard parseStreamProbe(GifSource,
        """{"streams":[{"codec_name":"png","width":4,"height":4}]}""")
    expect MediaError:
      discard parseStreamProbe(JpegSource, """{"streams":[]}""")

  test "managed asset paths":
    check isManagedAsset("assets/8ef460a3.gif")
    check not isManagedAsset("assets/.hidden")
    check not isManagedAsset("assets/../buttons.json")
    check not isManagedAsset("/tmp/x.png")
    check not isManagedAsset("assets/")

suite "button media frame timing":
  test "packet delays convert to milliseconds":
    check parsePacketDurations(DisposalPackets) == @[100, 200, 300, 400]

  test "missing durations fall back to timestamps then the default":
    let text = """{"packets":[{"pts":0},{"pts":7},{"pts":20,"duration":0}],
      "streams":[{"time_base":"1/100"}]}"""
    check parsePacketDurations(text) == @[70, 130, 100]

  test "more than the frame limit is rejected":
    var packets = newJArray()
    for index in 0..MaxSourceFrames:
      packets.add(%*{"pts": index * 4, "duration": 4})
    expect MediaError:
      discard parsePacketDurations($(%*{"packets": packets,
        "streams": [{"time_base": "1/100"}]}))

  test "static images have one zero-length frame":
    let frames = selectFrames(@[100])
    check frames.len == 1
    check frames[0].durationMs == 0

  test "timings are kept when already under the frame rate cap":
    let frames = selectFrames(@[100, 200, 300, 400])
    check frames.len == 4
    check frames[3].index == 3
    check frames[2].durationMs == 300

  test "fast animations are merged down to thirty frames per second":
    var durations: seq[int]
    for index in 0..<50:
      durations.add(20)
    let frames = selectFrames(durations)
    var total = 0
    for frame in frames:
      check frame.durationMs * MaxFramesPerSecond >= 1000
      total += frame.durationMs
    check total == 1000
    check frames.len == 25
    check frames[1].index == 2

  test "a short trailing frame merges into its predecessor":
    let frames = selectFrames(@[50, 10])
    check frames.len == 1
    check frames[0].durationMs == 0
    let three = selectFrames(@[100, 100, 10])
    check three.len == 2
    check three[1].durationMs == 110

  test "duration and frame limits":
    check selectFrames(@[15_000, 15_000]).len == 2
    expect MediaError:
      discard selectFrames(@[15_000, 15_001])
    expect MediaError:
      discard selectFrames(newSeq[int](MaxSourceFrames + 1))
    expect MediaError:
      discard selectFrames(@[])

suite "button media layout":
  test "contain keeps proportions inside the key":
    check containSize(8, 4) == (72, 36)
    check containSize(4, 8) == (36, 72)
    check containSize(4096, 1) == (72, 1)
    check containSize(1, 4096) == (1, 72)
    check containSize(4, 4) == (72, 72)

  test "titles are cleaned of control characters":
    check cleanTitle("  a\tb\n\x01c  ") == "a b c"
    check cleanTitle("Wörld 🎧") == "Wörld 🎧"

  test "short titles use the largest size":
    let layout = layoutTitle("Back", [24, 18, 14, 11], 64, 64, 4)
    check layout.fontSize == 24
    check layout.lines == @["Back"]

  test "longer titles wrap at smaller sizes":
    let layout = layoutTitle("Open Discord voice", [24, 18, 14, 11], 64, 64, 4)
    check layout.fontSize < 24
    check layout.lines.len > 1
    check layout.lines.join(" ") == "Open Discord voice"

  test "very long titles truncate with an ellipsis":
    let layout = layoutTitle(repeat("ü", 64), [14, 11], 64, 36, 2)
    check layout.fontSize == 11
    check layout.lines.len == 2
    check layout.lines[^1].endsWith("…")

  test "empty titles produce no lines":
    check layoutTitle(" \t ", [24], 64, 64, 4).lines.len == 0

  test "filter values escape both FFmpeg parsing levels":
    check escapeFilterValue("/a b/c.ttf") == "/a b/c.ttf"
    check escapeFilterValue("a:b") == "a\\\\:b"
    check escapeFilterValue("x'y") == "x\\\\\\'y"
    check escapeFilterValue("[x],y;z") == "\\[x\\]\\,y\\;z"

suite "button media plan":
  test "root menus are sparse and absent slots are blank":
    let plans = planButtonMedia(buttonConfig(%*[{"id": "root", "title": "Main",
      "mixer": [], "deck": [deckKey(4, "Four")]}]))
    check plans.len == 1
    check plans[0].keys.len == DeckKeyCount
    check plans.planFor("root", 1).kind == TitleKey
    check plans.planFor("root", 1).title == ""
    check plans.planFor("root", 4).title == "Four"
    check plans.planFor("root", 4).field == "menus[0].deck[0]"

  test "non-root key 1 renders Back":
    let plans = planButtonMedia(buttonConfig(%*[
      {"id": "root", "title": "Main", "mixer": [], "deck": []},
      {"id": "sub", "title": "Sub", "mixer": [], "deck": []},
      {"id": "named", "title": "Named", "mixer": [],
        "deck": [deckKey(1, "Up", action = %*{"kind": "back"})]},
      {"id": "art", "title": "Art", "mixer": [],
        "deck": [deckKey(1, "", %*{"image": "assets/a.png", "showTitle": true},
          %*{"kind": "back"})]}]))
    check plans.planFor("root", 1).title == ""
    check plans.planFor("sub", 1).kind == TitleKey
    check plans.planFor("sub", 1).title == BackTitle
    check plans.planFor("sub", 2).title == ""
    check plans.planFor("named", 1).title == "Up"
    check plans.planFor("art", 1).kind == ArtworkKey
    check plans.planFor("art", 1).title == BackTitle

  test "a non-default root id still distinguishes Back":
    let plans = planButtonMedia(buttonConfig(%*[
      {"id": "home", "title": "Home", "mixer": [], "deck": []},
      {"id": "root", "title": "Other", "mixer": [], "deck": []}], root = "home"))
    check plans.planFor("home", 1).title == ""
    check plans.planFor("root", 1).title == BackTitle

  test "builtin numbers pass through and images default to hidden titles":
    let plans = planButtonMedia(buttonConfig(%*[{"id": "root", "title": "Main",
      "mixer": [], "deck": [
        deckKey(1, "1", %*{"builtinNumber": 7, "showTitle": true}),
        deckKey(2, "Art", %*{"image": "assets/a.gif"}),
        deckKey(3, "Shown", %*{"image": "assets/a.gif", "showTitle": true}),
        deckKey(4, "Hidden", %*{"showTitle": false})]}]))
    check plans.planFor("root", 1).kind == BuiltinKey
    check plans.planFor("root", 1).builtinNumber == 7
    check plans.planFor("root", 2).kind == ArtworkKey
    check plans.planFor("root", 2).title == ""
    check plans.planFor("root", 2).image == "assets/a.gif"
    check plans.planFor("root", 3).title == "Shown"
    check plans.planFor("root", 4).kind == TitleKey
    check plans.planFor("root", 4).title == ""

  test "unmanaged image paths are rejected with the field":
    try:
      discard planButtonMedia(buttonConfig(%*[{"id": "root", "title": "Main",
        "mixer": [], "deck": [deckKey(5, "x", %*{"image": "../x.png"})]}]))
      check false
    except MediaError as error:
      check error.field == "menus[0].deck[0].visual.image"

  test "OBS keys plan their operation and mapped state images in a stable order":
    let
      obs = %*{"kind": "obs", "operation": "recordToggle"}
      plans = planButtonMedia(buttonConfig(%*[{"id": "root", "title": "Main",
        "mixer": [], "deck": [
          deckKey(2, "Rec", %*{"image": "assets/a.png", "states": {
            "unavailable": "assets/off.png", "recording": "assets/on.gif"}}, obs),
          deckKey(3, "3", %*{"builtinNumber": 3, "states": {"paused": "assets/p.png"}},
            %*{"kind": "obs", "operation": "pauseToggle"}),
          deckKey(4, "Cmd", %*{"states": {"muted": "assets/m.png"}},
            %*{"kind": "command", "command": "true"})]}]))
      rec = plans.planFor("root", 2)
    check rec.obsOperation == "recordToggle"
    check rec.states == @[StatePlan(state: "recording", image: "assets/on.gif"),
      StatePlan(state: "unavailable", image: "assets/off.png")]
    check plans.planFor("root", 3).kind == BuiltinKey
    check plans.planFor("root", 3).states == @[StatePlan(state: "paused", image: "assets/p.png")]
    check plans.planFor("root", 4).obsOperation == ""
    check plans.planFor("root", 4).states.len == 0
    check plans.planFor("root", 5).obsOperation == ""
    try:
      discard planButtonMedia(buttonConfig(%*[{"id": "root", "title": "Main",
        "mixer": [], "deck": [deckKey(5, "x", %*{"states": {"muted": "../m.png"}},
          %*{"kind": "obs", "operation": "micToggle"})]}]))
      check false
    except MediaError as error:
      check error.field == "menus[0].deck[0].visual.states.muted"

  test "control keys plan their exact action kind and mixed or deafened images":
    let
      plans = planButtonMedia(buttonConfig(%*[{"id": "root", "title": "Main",
        "mixer": [], "deck": [
          deckKey(2, "Mics", %*{"image": "assets/a.png", "states": {
            "mixed": "assets/mix.png", "unavailable": "assets/off.png"}},
            %*{"kind": "microphones"}),
          deckKey(3, "Deaf", %*{"builtinNumber": 3, "states": {"deafened": "assets/d.png"}},
            %*{"kind": "discordDeafen"})]}]))
      mics = plans.planFor("root", 2)
    check mics.controlAction == "microphones"
    check mics.obsOperation == ""
    check mics.states == @[StatePlan(state: "unavailable", image: "assets/off.png"),
      StatePlan(state: "mixed", image: "assets/mix.png")]
    check plans.planFor("root", 3).controlAction == "discordDeafen"
    check plans.planFor("root", 3).states == @[StatePlan(state: "deafened", image: "assets/d.png")]
    var menu = builtinMenu("root")
    menu["deck"][4]["action"] = %*{"kind": "discord"}
    let
      cache = getTempDir() / "knobby-media-control-unit-" & $getCurrentProcessId()
      manifest = prepareButtonMedia(buttonConfig(%*[menu]), "/nonexistent", cache,
        "/nonexistent/font.ttf")
    check manifest["menus"]["root"]["5"] == %*{"builtinNumber": 5, "controlAction": "discord"}
    check not dirExists(cache)

  test "builtin OBS keys without states carry their operation and need no rendering":
    var menu = builtinMenu("root")
    menu["deck"][4]["action"] = %*{"kind": "obs", "operation": "open"}
    let
      cache = getTempDir() / "knobby-media-obs-unit-" & $getCurrentProcessId()
      manifest = prepareButtonMedia(buttonConfig(%*[menu]), "/nonexistent", cache,
        "/nonexistent/font.ttf")
    check manifest["menus"]["root"]["5"] == %*{"builtinNumber": 5, "obsOperation": "open"}
    check not dirExists(cache)

  test "builtin-only configs need no rendering, font or cache files":
    let
      cache = getTempDir() / "knobby-media-unit-" & $getCurrentProcessId()
      manifest = prepareButtonMedia(buttonConfig(%*[builtinMenu("root"),
        builtinMenu("other")]), "/nonexistent", cache, "/nonexistent/font.ttf")
    check manifest["version"].getInt() == ManifestVersion
    check manifest["menus"].len == 2
    for menu in ["root", "other"]:
      for key in 1..DeckKeyCount:
        check manifest["menus"][menu][$key] == %*{"builtinNumber": key}
    check not dirExists(cache)

suite "button media operation deadline":
  test "no deadline is active outside a scope":
    check not hasOperationDeadline()
    checkOperationDeadline()

  test "an expired scope raises and resets afterwards":
    withOperationDeadline(1):
      check hasOperationDeadline()
      sleep(5)
      expect MediaTimeoutError:
        checkOperationDeadline()
    check not hasOperationDeadline()
    checkOperationDeadline()

  test "the deadline resets when the scope raises":
    expect KeyError:
      withOperationDeadline(60_000):
        raise newException(KeyError, "boom")
    check not hasOperationDeadline()

  test "nested scopes only shorten the deadline":
    withOperationDeadline(1):
      sleep(5)
      withOperationDeadline(60_000):
        expect MediaTimeoutError:
          checkOperationDeadline()
      check hasOperationDeadline()
    withOperationDeadline(60_000):
      withOperationDeadline(1):
        sleep(5)
        expect MediaTimeoutError:
          checkOperationDeadline()
      checkOperationDeadline()
    check not hasOperationDeadline()

  test "non-positive timeouts are rejected":
    expect ValueError:
      withOperationDeadline(0):
        discard
    check not hasOperationDeadline()

  test "an expired operation never spawns another child":
    # Spawning this command would raise OSError instead of a timeout.
    withOperationDeadline(1):
      sleep(5)
      try:
        discard runTool(@["/nonexistent/knobby-tool"])
        check false
      except MediaTimeoutError as error:
        check "1 ms deadline" in error.msg

  test "an expired operation stops preparation before rendering":
    let cache = getTempDir() / "knobby-media-deadline-" & $getCurrentProcessId()
    removeDir(cache)
    withOperationDeadline(1):
      sleep(5)
      expect MediaTimeoutError:
        discard prepareButtonMedia(buttonConfig(%*[{"id": "root", "title": "root",
          "mixer": [], "deck": [deckKey(2, "Title")]}]), "/nonexistent", cache,
          FixtureDirectory / "disposal.gif", timeoutMs = 60_000)
    check not dirExists(cache)
    check not hasOperationDeadline()

suite "button media prepared cache cleanup":
  setup:
    let
      work = cleanupWork()
      cache = work / "prepared"
      manifests = work / "manifests"
      keep = "a".repeat(40)
      wrapped = "b".repeat(40)
      stale = "c".repeat(40)
      recent = "d".repeat(40)
    createDir(cache)
    createDir(manifests)

  teardown:
    discard chmod(cache.cstring, 0o755)
    removeDir(work)

  test "content key names are lowercase 40-hex":
    check isContentKeyName(keep)
    check isContentKeyName("0123456789abcdef0123456789abcdef01234567")
    check not isContentKeyName("A".repeat(40))
    check not isContentKeyName("a".repeat(39))
    check not isContentKeyName("g".repeat(40))
    check not isContentKeyName(".tmp-" & keep)

  test "manifest keys come from any path component":
    let keys = manifestContentKeys(%*{"version": 1, "menus": {"root": {
      "1": {"builtinNumber": 1},
      "2": {"normal": [{"path": cache / keep / "normal-0001.jpg", "durationMs": 0}],
        "pressed": cache / keep / "pressed.jpg"}}},
      "wrapped": {"manifest": [cache / wrapped / "pressed.jpg"]},
      "asset": "assets/" & stale & ".png"})
    check keys == toHashSet([keep, wrapped])

  test "only old unreferenced content directories are removed":
    let outside = work / "outside" / stale
    makeEntry(cache / keep, 7200)
    makeEntry(cache / wrapped, 7200)
    makeEntry(cache / stale, 7200)
    makeEntry(cache / recent, 60)
    makeEntry(cache / "E".repeat(40), 7200)
    makeEntry(cache / ".tmp-" & stale, 7200)
    makeEntry(cache / "assets", 7200)
    makeEntry(outside, 7200)
    createSymlink(outside, cache / "f".repeat(40))
    writeFile(cache / "9".repeat(40), "not a directory")
    let
      active = $(%*{"version": 1, "menus": {"root": {"2": {
        "normal": [{"path": cache / keep / "normal-0001.jpg", "durationMs": 0}],
        "pressed": cache / keep / "pressed.jpg"}}}})
      preview = $(%*{"id": "op-1", "manifest": {"menus": {"root": {"2": {
        "pressed": cache / wrapped / "pressed.jpg"}}}}})
    writeFile(manifests / "last-applied.json", active)
    writeFile(manifests / "preview.json", preview)
    writeFile(manifests / "notes.txt", "ignored")
    let report = cleanPreparedCache(cache, manifests)
    check report.manifests == 2
    check report.protectedKeys == 2
    check report.removed == @[cache / stale]
    check report.errors.len == 0
    check not dirExists(cache / stale)
    for name in [keep, wrapped, recent, "E".repeat(40), ".tmp-" & stale, "assets"]:
      check fileExists(cache / name / "pressed.jpg")
    check fileExists(outside / "pressed.jpg")
    check symlinkExists(cache / "f".repeat(40))
    check fileExists(cache / "9".repeat(40))
    check readFile(manifests / "last-applied.json") == active
    check readFile(manifests / "preview.json") == preview
    for kind, path in walkDir(cache):
      check not path.extractFilename.startsWith(".tmp-delete-")

  test "missing, empty or invalid manifests delete nothing":
    makeEntry(cache / stale, 7200)
    expect IOError:
      discard cleanPreparedCache(cache, work / "missing")
    expect IOError:
      discard cleanPreparedCache(cache, manifests)
    writeFile(manifests / "last-applied.json", "{\"menus\":")
    expect JsonParsingError:
      discard cleanPreparedCache(cache, manifests)
    check dirExists(cache / stale)

  test "a missing cache directory is not an error":
    writeFile(manifests / "last-applied.json", "{}")
    let report = cleanPreparedCache(work / "absent", manifests)
    check report.manifests == 1
    check report.removed.len == 0

  test "removal failures are reported":
    makeEntry(cache / stale, 7200)
    writeFile(manifests / "last-applied.json", "{}")
    check chmod(cache.cstring, 0o555) == 0
    let report = cleanPreparedCache(cache, manifests)
    check report.removed.len == 0
    check report.errors.len == 1
    check (cache / stale) in report.errors[0]
    check dirExists(cache / stale)
