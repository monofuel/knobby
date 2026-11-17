import
  std/[atomics, json, os, strutils, unittest],
  knobby/[button_client, button_config, button_runtime, ipc]

const
  FailTitle = "FAIL"
  BlockTitle = "BLOCK"
  ServerPollMs = 10
  ShortTimeoutMs = 200

var
  gateOpen: Atomic[bool]
  serverStopping: Atomic[bool]
  serverThread: Thread[string]

proc fakePrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Return an empty page per menu, failing or blocking when a menu title asks for it.
  result = %*{"version": 1, "menus": {}}
  for menu in config["menus"]:
    if menu["title"].getStr() == FailTitle:
      raise newException(IOError, "ffmpeg exploded")
    if menu["title"].getStr() == BlockTitle:
      while not gateOpen.load():
        sleep(2)
    result["menus"][menu["id"].getStr()] = newJObject()

proc fakeImport(source: string): string {.gcsafe.} =
  ## Pretend to import an asset.
  "assets/" & sha256Hex(source)[0..15] & ".png"

proc serve(path: string) {.thread.} =
  ## Mimic the daemon state server: dedicated config requests plus subscribed status frames.
  let server = newLocalServer(path)
  defer: server.close()
  while not serverStopping.load():
    {.cast(gcsafe).}:
      let state = %*{"version": ProtocolVersion, "type": "state",
        "state": {"buttonConfig": buttonRuntimeStatus()}}
      for request in server.pollRequests():
        let kind = request.message{"type"}.getStr()
        if kind == "subscribe":
          request.peer.subscribed = true
          request.peer.queueMessage(state)
        elif kind.startsWith("config."):
          request.peer.queueMessage(processConfigRequest(request.message))
        else:
          request.peer.close()
      server.broadcast(state)
    sleep(ServerPollMs)

proc menuConfig(title: string): JsonNode =
  ## Build a two-menu configuration whose second menu title controls the fake media service.
  %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main", "mixer": [
      {"key": 2, "title": "More", "action": {"kind": "menu", "menu": "more", "target": "both"}}]},
    {"id": "more", "title": title}]}

proc startDaemon(directory: string): string =
  ## Initialize the runtime in private directories and serve it on a private socket.
  removeDir(directory)
  createDir(directory)
  gateOpen.store(true)
  serverStopping.store(false)
  initializeButtons(newButtonPaths(directory / "config", directory / "state"),
    ButtonServices(prepare: fakePrepare, importAsset: fakeImport))
  startButtonWorker()
  result = directory / "daemon.sock"
  createThread(serverThread, serve, result)
  for _ in 0..<1000:
    if fileExists(result):
      break
    sleep(2)

proc stopDaemon(directory: string) =
  ## Stop the fake server and runtime worker, then remove private files.
  gateOpen.store(true)
  serverStopping.store(true)
  joinThread(serverThread)
  stopButtonWorker()
  removeDir(directory)

proc envelope(config: JsonNode, base: string): JsonNode =
  ## Build an apply payload.
  %*{"envelope": {"baseRevision": base, "config": config}}

suite "Button configuration client":
  let directory = getTempDir() / ("knobby-client-" & $getCurrentProcessId())

  test "export, validate, and apply through dedicated connections":
    let path = startDaemon(directory)
    defer: stopDaemon(directory)
    let exported = requireConfigResult(requestConfig("config.get", path = path))
    check exported["envelope"]["baseRevision"].getStr() == buttonRuntimeStatus()["revision"].getStr()
    check exported["source"].getStr() == "defaults"
    let validated = requireConfigResult(requestConfig("config.validate",
      %*{"config": menuConfig("More")}, path))
    check validated["revision"].getStr() == configRevision(menuConfig("More"))
    let record = runConfigOperation("config.apply",
      envelope(menuConfig("More"), exported["envelope"]["baseRevision"].getStr()), path = path)
    check record["status"].getStr() == "succeeded"
    check buttonRuntimeStatus()["revision"].getStr() == configRevision(menuConfig("More"))
    let again = requireConfigResult(requestConfig("config.get", path = path))
    check again["envelope"] == configEnvelope(menuConfig("More"))
    let imported = runConfigOperation("config.importAsset", %*{"source": "/tmp/cat.png"}, path = path)
    check isManagedAssetPath(imported["path"].getStr())

  test "waiting after an operation already finished still returns its result":
    let path = startDaemon(directory)
    defer: stopDaemon(directory)
    let reply = requireConfigResult(requestConfig("config.preview",
      %*{"config": menuConfig("More")}, path))
    let id = reply["operationId"].getStr()
    for _ in 0..<1000:
      let record = buttonOperation(id)
      if not record.isNil and record["status"].getStr() == "succeeded":
        break
      sleep(5)
    check buttonOperation(id)["status"].getStr() == "succeeded"
    let record = waitConfigOperation(id, path = path)
    check record["id"].getStr() == id
    check fileExists(record["manifestPath"].getStr())

  test "rejections and failed operations carry codes and fields":
    let path = startDaemon(directory)
    defer: stopDaemon(directory)
    try:
      discard runConfigOperation("config.apply", envelope(menuConfig("More"), "stale"), path = path)
      fail()
    except ConfigRequestError as error:
      check error.code == "stale"
      check error.field == "baseRevision"
      check parseJson(error.reply)["revision"].getStr() == buttonRuntimeStatus()["revision"].getStr()
    let base = buttonRuntimeStatus()["revision"].getStr()
    try:
      discard runConfigOperation("config.apply", envelope(menuConfig(FailTitle), base), path = path)
      fail()
    except ConfigRequestError as error:
      check error.code == "prepare"
      check "ffmpeg exploded" in error.msg
      check parseJson(error.reply)["status"].getStr() == "failed"
    var invalid = menuConfig("More")
    invalid["menus"][1]["title"] = %"\x01"
    let rejected = requestConfig("config.validate", %*{"config": invalid}, path)
    check not rejected["ok"].getBool()
    try:
      discard requireConfigResult(rejected)
      fail()
    except ConfigRequestError as error:
      check error.field == "menus[1].title"
    check buttonRuntimeStatus()["revision"].getStr() == base

  test "waits time out without losing the eventual result":
    let path = startDaemon(directory)
    defer: stopDaemon(directory)
    gateOpen.store(false)
    let reply = requireConfigResult(requestConfig("config.apply",
      envelope(menuConfig(BlockTitle), buttonRuntimeStatus()["revision"].getStr()), path))
    let id = reply["operationId"].getStr()
    expect IOError:
      discard waitConfigOperation(id, ShortTimeoutMs, path)
    check requestConfig("config.preview", %*{"config": menuConfig("More")}, path)["code"].getStr() == "busy"
    gateOpen.store(true)
    check waitConfigOperation(id, path = path)["status"].getStr() == "succeeded"

  test "unknown sessions and evicted operations fail instead of waiting forever":
    let path = startDaemon(directory)
    defer: stopDaemon(directory)
    let session = buttonRuntimeStatus()["session"].getStr()
    expect IOError:
      discard waitConfigOperation("restarted.1-1", ShortTimeoutMs * 10, path)
    var ids: seq[string]
    for _ in 0..MaxRecentOperations:
      ids.add(runConfigOperation("config.preview", %*{"config": menuConfig("More")},
        path = path)["id"].getStr())
    check ids[0] == session & "-1"
    try:
      discard waitConfigOperation(ids[0], ShortTimeoutMs * 10, path)
      fail()
    except IOError as error:
      check "no longer retained" in error.msg
    expect ValueError:
      discard waitConfigOperation("nonsense", ShortTimeoutMs, path)

  test "requests to an absent daemon fail promptly":
    expect OSError:
      discard requestConfig("config.get", path = getTempDir() / "knobby-no-such-daemon.sock")
