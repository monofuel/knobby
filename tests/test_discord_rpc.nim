import
  std/[net, nativesockets, posix, unittest],
  knobby/discord_rpc

suite "uint32 little-endian codec":
  test "round-trips values":
    for value in [0, 1, 8, 255, 256, 0x12345678]:
      check decodeUint32Le(encodeUint32Le(value), 0) == value

  test "encodes little-endian byte order":
    let encoded = encodeUint32Le(0x01020304)
    check encoded == "\x04\x03\x02\x01"

suite "encodeFrame":
  test "lays out opcode, length, and payload":
    let payload = """{"v":1}"""
    let frame = encodeFrame(HandshakeOp, payload)
    check frame.len == FrameHeaderLen + payload.len
    check decodeUint32Le(frame, 0) == HandshakeOp
    check decodeUint32Le(frame, 4) == payload.len
    check frame[FrameHeaderLen .. ^1] == payload

  test "handles an empty payload":
    let frame = encodeFrame(CloseOp, "")
    check frame.len == FrameHeaderLen
    check decodeUint32Le(frame, 4) == 0


proc rpcPair(): tuple[client: DiscordRpcClient, peer: Socket] =
  ## Create a local socket pair without connecting to Discord.
  var handles: array[2, cint]
  doAssert socketpair(posix.AF_UNIX, posix.SOCK_STREAM, 0, handles) == 0
  result.client = newDiscordRpcClient(newSocket(SocketHandle(handles[0]),
    net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP, buffered = false), 30)
  result.peer = newSocket(SocketHandle(handles[1]),
    net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP, buffered = false)

suite "RPC failure bounds":
  test "incomplete frames time out":
    let pair = rpcPair()
    defer:
      pair.client.close()
      pair.peer.close()
    pair.peer.send("\x01")
    expect CatchableError:
      discard pair.client.getVoiceSettings()

  test "oversized frame rejected before reading payload":
    let pair = rpcPair()
    defer:
      pair.client.close()
      pair.peer.close()
    pair.peer.send(encodeUint32Le(FrameOp) & encodeUint32Le(2 * 1024 * 1024))
    expect IOError:
      discard pair.client.getVoiceSettings()

  test "unrelated responses cannot keep a request alive forever":
    let pair = rpcPair()
    defer:
      pair.client.close()
      pair.peer.close()
    var frames = ""
    for index in 0..<256:
      frames.add(encodeFrame(FrameOp, "{}"))
    pair.peer.send(frames)
    expect IOError:
      discard pair.client.getVoiceSettings()
