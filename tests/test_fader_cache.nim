import
  std/[json, os, unittest],
  knobby/fader_cache

const TestPositions: FaderPositions = [0, 127, -1, 63]

suite "Fader display cache":
  let directory = getTempDir() / ("knobby-fader-cache-" & $getCurrentProcessId())
  setup:
    createDir(directory)
    let path = directory / "faders.json"
  teardown:
    removeDir(directory)

  test "absent and partially unknown positions round trip":
    check loadFaderCache(path) == UnknownFaders
    writeFaderCache(path, TestPositions)
    check loadFaderCache(path) == TestPositions
    check not fileExists(path & ".tmp")
    writeFaderCache(path, [33, -1, 12, 127])
    check loadFaderCache(path) == [33, -1, 12, 127]

  test "unsupported and malformed caches are rejected":
    for content in ["null", "[]", "{}", "{\"version\":2,\"faders\":[0,0,0,0]}",
        "{\"version\":true,\"faders\":[0,0,0,0]}",
        "{\"version\":1,\"faders\":[0,0,0]}",
        "{\"version\":1,\"faders\":[0,0,0,0,0]}",
        "{\"version\":1,\"faders\":[-2,0,0,0]}",
        "{\"version\":1,\"faders\":[0,128,0,0]}",
        "{\"version\":1,\"faders\":[0,true,0,0]}",
        "{\"version\":1,\"faders\":[0,1.5,0,0]}"]:
      expect ValueError: discard decodeFaderCache(content)
    writeFile(path, "{")
    expect JsonParsingError: discard loadFaderCache(path)
    createDir(path & ".directory")
    expect IOError: discard loadFaderCache(path & ".directory")

  test "bursts and continuous movement write at most once per two seconds":
    var writer = newFaderCacheWriter(path, UnknownFaders, 0)
    for timeMs in 0'i64..<FaderSaveIntervalMs:
      writer.flush([int(timeMs mod 128), -1, -1, -1], timeMs)
    check not fileExists(path)
    writer.flush(TestPositions, 2000)
    check loadFaderCache(path) == TestPositions
    for timeMs in 2001'i64..<4000:
      writer.flush([int(timeMs mod 128), -1, -1, -1], timeMs)
      check loadFaderCache(path) == TestPositions
    writer.flush([42, -1, 127, 0], 4000)
    check loadFaderCache(path) == [42, -1, 127, 0]

  test "unchanged state produces no writes even on shutdown":
    var writer = newFaderCacheWriter(path, UnknownFaders, 0)
    writer.flush(UnknownFaders, 10000)
    check not fileExists(path)
    writer.flush(TestPositions, 10000)
    moveFile(path, path & ".saved")
    writer.flush(TestPositions, 20000)
    writer.flush(TestPositions, 20001, force = true)
    check not fileExists(path)
    check loadFaderCache(path & ".saved") == TestPositions

  test "failed replacement preserves the saved file and dirty state with bounded retries":
    writeFaderCache(path, TestPositions)
    var writer = newFaderCacheWriter(path, TestPositions, 0)
    let latest: FaderPositions = [30, 40, 50, 60]
    createDir(path & ".tmp")
    expect IOError: writer.flush(latest, 2000)
    check loadFaderCache(path) == TestPositions
    removeDir(path & ".tmp")
    writer.flush(latest, 3999)
    check loadFaderCache(path) == TestPositions
    writer.flush(latest, 4000)
    check loadFaderCache(path) == latest

  test "shutdown flush bypasses the deadline without persisting transient state":
    var writer = newFaderCacheWriter(path, UnknownFaders, 0)
    writer.flush(TestPositions, 10, force = true)
    check loadFaderCache(path) == TestPositions
    let node = parseFile(path)
    check node.len == 2
    check node.hasKey("version") and node.hasKey("faders")
