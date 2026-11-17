import
  std/[json, os, strutils, unittest],
  knobby/[bindings, button_config]

proc baseConfig(): JsonNode =
  ## Build a two-menu fixture with linked navigation and an imported Deck image.
  %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main",
      "mixer": [{"key": 2, "title": "Tools", "action": {"kind": "menu", "menu": "tools", "target": "both"}}],
      "deck": [{"key": 3, "title": "Play", "action": {"kind": "command", "command": "playerctl play"},
        "visual": {"image": "assets/abc123.png"}}]},
    {"id": "tools", "title": "Tools",
      "mixer": [{"key": 4, "title": "Home", "action": {"kind": "home"}}],
      "deck": []}]}

proc rejectedField(config: JsonNode): string =
  ## Return the field named by a validation failure, failing the test if validation passes.
  try:
    validateButtonConfig(config)
  except ButtonConfigError as error:
    check error.msg.startsWith(error.field)
    return error.field
  checkpoint("configuration unexpectedly validated")
  fail()

suite "Button configuration":
  test "SHA-256 matches published vectors":
    check sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex(repeat('a', 1000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"

  test "defaults preserve the compiled mixer bindings and numbered Deck page":
    let defaults = defaultButtonConfig()
    validateButtonConfig(defaults)
    check defaults["root"].getStr() == RootMenuId
    for binding in ButtonBindings:
      let entry = buttonAt(defaults, RootMenuId, "mixer", binding.note)
      check entry["title"].getStr() == binding.label
    check buttonAt(defaults, RootMenuId, "mixer", 12)["action"]["kind"].getStr() == "grok"
    check buttonAt(defaults, RootMenuId, "mixer", 9)["action"]["kind"].getStr() == "claude"
    check buttonAt(defaults, RootMenuId, "mixer", 10)["action"]["kind"].getStr() == "ffxiv"
    check buttonAt(defaults, RootMenuId, "mixer", 11)["action"]["kind"].getStr() == "microphones"
    check buttonAt(defaults, RootMenuId, "mixer", 8)["action"]["kind"].getStr() == "discord"
    for note in [1, 2, 3, 4, 5, 6, 7]:
      check buttonAt(defaults, RootMenuId, "mixer", note) ==
        %*{"key": note, "title": "Unassigned", "action": {"kind": "none"}}
    for key in 1..DeckKeyCount:
      let entry = buttonAt(defaults, RootMenuId, "deck", key)
      check entry["visual"] == %*{"builtinNumber": key, "showTitle": false}
      check entry["action"]["kind"].getStr() == "none"

  test "revisions ignore formatting, entry order, and defaulted display fields":
    let config = baseConfig()
    var reordered = parseJson(pretty(config))
    reordered["menus"][0]["deck"][0]["visual"]["showTitle"] = %false
    reordered["menus"][0]["mixer"].add(%*{"key": 1, "action": {"kind": "none"}, "title": ""})
    var plain = baseConfig()
    plain["menus"][0]["mixer"].elems.insert(%*{"title": "", "key": 1, "action": {"kind": "none"}}, 0)
    check configRevision(reordered) == configRevision(plain)
    check configRevision(baseConfig()) == configRevision(parseJson(pretty(baseConfig())))
    var renamed = baseConfig()
    renamed["menus"][0]["mixer"][0]["title"] = %"Tools 2"
    check configRevision(renamed) != configRevision(baseConfig())
    check configRevision(baseConfig()).len == 64

  test "canonical form sorts entries and materializes showTitle from the image":
    var config = baseConfig()
    config["menus"][0]["deck"].add(%*{"key": 2, "title": "x", "action": {"kind": "none"},
      "visual": {"builtinNumber": 2}})
    let canonical = canonicalButtonConfig(config)
    let deck = canonical["menus"][0]["deck"]
    check deck[0]["key"].getInt() == 2
    check deck[0]["visual"]["showTitle"].getBool()
    check deck[1]["visual"] == %*{"image": "assets/abc123.png", "showTitle": false}
    check canonicalButtonConfig(canonical) == canonical
    let envelope = configEnvelope(config)
    check envelope["baseRevision"].getStr() == configRevision(config)
    check parseConfigEnvelope(envelope).config == canonical

  test "non-root key 1 is Back on both devices and only accepts an explicit Back":
    let config = baseConfig()
    for device in ["mixer", "deck"]:
      check buttonAt(config, "tools", device, 1) ==
        %*{"key": 1, "title": "Back", "action": {"kind": "back"}}
    check buttonAt(config, RootMenuId, "deck", 1)["action"]["kind"].getStr() == "none"
    var titled = baseConfig()
    titled["menus"][1]["deck"].add(%*{"key": 1, "title": "Zurück ↩", "action": {"kind": "back"}})
    check buttonAt(titled, "tools", "deck", 1)["title"].getStr() == "Zurück ↩"
    var rebound = baseConfig()
    rebound["menus"][1]["mixer"].add(%*{"key": 1, "action": {"kind": "grok"}})
    check rejectedField(rebound) == "menus[1].mixer[1].action"
    var rootKey = baseConfig()
    rootKey["menus"][0]["mixer"].add(%*{"key": 1, "action": {"kind": "grok"}})
    validateButtonConfig(rootKey)

  test "Unicode titles are accepted while invalid UTF-8 and controls are rejected":
    var unicode = baseConfig()
    unicode["menus"][1]["title"] = %"音量 🎧 Ñandú"
    unicode["menus"][0]["mixer"][0]["title"] = %"ツール"
    validateButtonConfig(unicode)
    check menuAt(unicode, "tools")["title"].getStr() == "音量 🎧 Ñandú"
    var broken = baseConfig()
    broken["menus"][0]["mixer"][0]["title"] = %"bad \xff byte"
    check rejectedField(broken) == "menus[0].mixer[0].title"
    var control = baseConfig()
    control["menus"][0]["deck"][0]["title"] = %"two\nlines"
    check rejectedField(control) == "menus[0].deck[0].title"
    var long = baseConfig()
    long["menus"][0]["title"] = %repeat("é", MaxTitleRunes + 1)
    check rejectedField(long) == "menus[0].title"
    long["menus"][0]["title"] = %repeat("é", MaxTitleRunes)
    validateButtonConfig(long)

  test "structural errors name the offending field":
    var config = baseConfig()
    config["version"] = %2
    check rejectedField(config) == "version"
    config = baseConfig()
    config["root"] = %"missing"
    check rejectedField(config) == "root"
    config = baseConfig()
    config["menus"][1]["id"] = %"tööls"
    check rejectedField(config) == "menus[1].id"
    config = baseConfig()
    config["menus"][1]["id"] = %"root"
    check rejectedField(config) == "menus[1].id"
    config = baseConfig()
    config["menus"][0]["mixer"].add(%*{"key": 2, "action": {"kind": "none"}})
    check rejectedField(config) == "menus[0].mixer[1].key"
    config = baseConfig()
    config["menus"][0]["mixer"][0]["key"] = %13
    check rejectedField(config) == "menus[0].mixer[0].key"
    config = baseConfig()
    config["menus"][0]["deck"][0]["key"] = %16
    check rejectedField(config) == "menus[0].deck[0].key"
    config = baseConfig()
    config["menus"][0]["mixer"][0]["action"] = %*{"kind": "launch"}
    check rejectedField(config) == "menus[0].mixer[0].action.kind"
    config = baseConfig()
    config["menus"][0]["mixer"][0]["action"]["menu"] = %"nowhere"
    check rejectedField(config) == "menus[0].mixer[0].action.menu"
    config = baseConfig()
    config["menus"][0]["mixer"][0]["action"].delete("target")
    check rejectedField(config) == "menus[0].mixer[0].action.target"
    config = baseConfig()
    config["menus"][0]["deck"][0]["action"]["command"] = %"   "
    check rejectedField(config) == "menus[0].deck[0].action.command"
    config = baseConfig()
    config["menus"][0]["deck"][0]["action"]["command"] = %"echo \0 hidden"
    check rejectedField(config) == "menus[0].deck[0].action.command"
    config = baseConfig()
    config["menus"][0]["mixer"][0]["action"]["command"] = %"stray"
    check rejectedField(config) == "menus[0].mixer[0].action.command"
    config = baseConfig()
    config["menus"][0]["mixer"][0]["colour"] = %"red"
    check rejectedField(config) == "menus[0].mixer[0].colour"
    config = baseConfig()
    config["menus"][0]["mixer"][0]["visual"] = %*{"builtinNumber": 1}
    check rejectedField(config) == "menus[0].mixer[0].visual"
    config = baseConfig()
    config["menus"] = newJArray()
    check rejectedField(config) == "menus"

  test "Deck images must be managed asset paths":
    for path in ["assets/../buttons.json", "/tmp/a.png", "assets/sub/a.png", "assets/.hidden",
        "a.png", "assets/"]:
      check not isManagedAssetPath(path)
      var config = baseConfig()
      config["menus"][0]["deck"][0]["visual"]["image"] = %path
      check rejectedField(config) == "menus[0].deck[0].visual.image"
    check isManagedAssetPath("assets/9f86d081.gif")
    var both = baseConfig()
    both["menus"][0]["deck"][0]["visual"]["builtinNumber"] = %3
    check rejectedField(both) == "menus[0].deck[0].visual.builtinNumber"

  test "oversized configurations are rejected before they can exceed IPC frames":
    var config = baseConfig()
    for index in 0..<MaxMenus - 2:
      var menu = %*{"id": "m" & $index, "title": "", "mixer": [], "deck": []}
      for key in 2..MixerKeyCount:
        menu["mixer"].add(%*{"key": key, "action": {"kind": "command",
          "command": repeat("x", MaxCommandBytes)}})
      config["menus"].add(menu)
    check rejectedField(config) == ""

  test "envelopes require a base revision and configuration object":
    expect ButtonConfigError: discard parseConfigEnvelope(%*{"config": baseConfig()})
    expect ButtonConfigError: discard parseConfigEnvelope(%*{"baseRevision": "", "config": baseConfig()})
    expect ButtonConfigError: discard parseConfigEnvelope(%*{"baseRevision": "x", "config": []})

  test "last-applied records reject tampered revisions":
    let record = encodeLastApplied(baseConfig())
    check decodeLastApplied(record) == canonicalButtonConfig(baseConfig())
    var tampered = parseJson(record)
    tampered["config"]["menus"][1]["title"] = %"Changed"
    expect ValueError: discard decodeLastApplied($tampered)

  test "paths honour XDG directories and explicit test directories":
    let
      oldConfig = getEnv("XDG_CONFIG_HOME")
      oldState = getEnv("XDG_STATE_HOME")
    defer:
      putEnv("XDG_CONFIG_HOME", oldConfig)
      putEnv("XDG_STATE_HOME", oldState)
    putEnv("XDG_CONFIG_HOME", "/xdg/config")
    putEnv("XDG_STATE_HOME", "/xdg/state")
    check buttonConfigPath() == "/xdg/config/knobby/buttons.json"
    let paths = newButtonPaths()
    check paths.assetDirectory() == "/xdg/config/knobby/assets"
    check paths.preparedDirectory() == "/xdg/state/knobby/prepared"
    check paths.lastAppliedPath() == "/xdg/state/knobby/last-applied.json"
    check paths.guiDraftPath() == "/xdg/state/knobby/gui-draft.json"
    putEnv("XDG_CONFIG_HOME", "")
    check buttonConfigDirectory() == getHomeDir() / ".config/knobby"
    check newButtonPaths("/a", "/b").configPath() == "/a/buttons.json"

  test "atomic writes replace content and leave the old file on failure":
    let directory = getTempDir() / ("knobby-config-" & $getCurrentProcessId())
    removeDir(directory)
    defer:
      setFilePermissions(directory, {fpUserRead, fpUserWrite, fpUserExec})
      removeDir(directory)
    let path = directory / "nested" / "buttons.json"
    writeFileAtomic(path, "first")
    writeFileAtomic(path, "second")
    check readFile(path) == "second"
    setFilePermissions(path.parentDir(), {fpUserRead, fpUserExec})
    expect CatchableError: writeFileAtomic(path, "third")
    setFilePermissions(path.parentDir(), {fpUserRead, fpUserWrite, fpUserExec})
    check readFile(path) == "second"
    var leftovers = 0
    for _ in walkFiles(path.parentDir() / "*.tmp-*"): inc leftovers
    check leftovers == 0
