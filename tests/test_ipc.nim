import
  std/[json, net, options, os, strutils, unittest],
  knobby/[ipc, midi_events, status],
  ../gui/app/src/observers

const Subscribe = "subscribe"

proc request(kind: string): JsonNode =
  ## Construct a versioned fixture without any device or desktop side effects.
  %*{"version": ProtocolVersion, "type": kind}

suite "Local framed IPC":
  test "partial headers and bodies retain their bytes until a frame is complete":
    let message = request(Subscribe)
    let encoded = encodeMessage(message)
    var buffer = ""
    for index, byte in encoded:
      buffer.add(byte)
      let decoded = takeMessage(buffer)
      if index < encoded.high: check decoded.isNone
      else: check decoded.get() == message
    check buffer.len == 0
    buffer = encoded & encoded
    check takeMessage(buffer).get() == message
    check takeMessage(buffer).get() == message

  test "malformed lengths and versions fail before unbounded buffering":
    for header in ["\x00\x00\x00\x00", "\xff\xff\xff\x7f"]:
      var buffer = header
      expect ValueError: discard takeMessage(buffer)
    var invalid = encodeMessage(%*{"version": 999})
    expect ValueError: discard takeMessage(invalid)
    expect ValueError: discard encodeMessage(%*{"data": repeat("x", MaxFrameBytes)})

  test "one endpoint owner, request acknowledgement, EOF and stale recovery":
    let directory = getTempDir() / ("knobby-ipc-" & $getCurrentProcessId())
    createDir(directory)
    defer: removeDir(directory)
    let path = directory / "test.sock"
    let server = newLocalServer(path)
    expect OSError: discard newLocalServer(path)
    let client = connectLocal(path)
    defer: client.close()
    client.queueMessage(request("activate"))
    var replies: seq[JsonNode]
    for _ in 0..<200:
      for item in server.pollRequests():
        check item.message["type"].getStr() == "activate"
        item.peer.queueMessage(request("activated"))
      replies.add(client.pump())
      if replies.len > 0: break
      sleep(1)
    check replies == @[request("activated")]
    server.close()
    expect IOError: discard client.pump()
    let restarted = newLocalServer(path)
    restarted.close()

  test "bad clients cannot interrupt a second client's snapshot":
    let directory = getTempDir() / ("knobby-ipc-bad-" & $getCurrentProcessId())
    createDir(directory)
    defer: removeDir(directory)
    let path = directory / "test.sock"
    let server = newLocalServer(path)
    defer: server.close()
    let bad = newSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP, buffered = false)
    defer: bad.close()
    bad.connectUnix(path)
    bad.send("\x00\x00\x00\x00")
    let good = connectLocal(path)
    defer: good.close()
    good.queueMessage(request(Subscribe))
    var received: seq[JsonNode]
    for _ in 0..<200:
      for item in server.pollRequests(): item.peer.queueMessage(request("state"))
      received.add(good.pump())
      if received.len > 0: break
      sleep(1)
    check received == @[request("state")]

  test "authoritative positions survive a real socket subscription":
    let directory = getTempDir() / ("knobby-ipc-state-" & $getCurrentProcessId())
    createDir(directory)
    defer: removeDir(directory)
    let server = newLocalServer(directory / "daemon.sock")
    defer: server.close()
    initializeState("fixture-daemon")
    setMixerPort("32:0")
    observeMidi([MidiEvent(kind: ControlChange, controller: 16, value: 49),
      MidiEvent(kind: ControlChange, controller: 17, value: 127)])
    let client = connectLocal(directory / "daemon.sock")
    defer: client.close()
    client.queueMessage(request(Subscribe))
    var received: seq[JsonNode]
    for _ in 0..<200:
      for item in server.pollRequests():
        item.peer.queueMessage(%*{"version": ProtocolVersion, "type": "state",
          "state": encodeState(readKnobbyState())})
      received.add(client.pump())
      if received.len > 0: break
      sleep(1)
    require received.len == 1
    let viewer = viewerState(decodeSnapshot($received[0]["state"]))
    check viewer.faderPosition(0) == 49
    check viewer.faderPosition(1) == 127
    check viewer.faderCaption(0) == "MIDI 49"
    check viewer.faderCaption(1) == "MIDI 127"

  test "a stalled subscriber is dropped while other clients keep receiving":
    let directory = getTempDir() / ("knobby-ipc-stall-" & $getCurrentProcessId())
    createDir(directory)
    defer: removeDir(directory)
    let server = newLocalServer(directory / "daemon.sock")
    defer: server.close()
    let stalled = connectLocal(directory / "daemon.sock")
    defer: stalled.close()
    stalled.queueMessage(request(Subscribe))
    discard stalled.pump()
    var heldPeer: Peer
    for _ in 0..<100:
      for item in server.pollRequests():
        item.peer.subscribed = true
        heldPeer = item.peer
      if not heldPeer.isNil: break
      sleep(1)
    require not heldPeer.isNil
    let payload = %*{"version": ProtocolVersion, "type": "state", "data": repeat("x", 800000)}
    let deadline = monotonicMs() + PeerTimeoutMs + 1500
    while monotonicMs() < deadline and not heldPeer.closed:
      server.broadcast(payload)
      discard server.pollRequests()
      sleep(1)
    check heldPeer.closed
    let healthy = connectLocal(directory / "daemon.sock")
    defer: healthy.close()
    healthy.queueMessage(request(Subscribe))
    var received: seq[JsonNode]
    for _ in 0..<200:
      for item in server.pollRequests(): item.peer.queueMessage(request("state"))
      received.add(healthy.pump())
      if received.len > 0: break
      sleep(1)
    check received == @[request("state")]
