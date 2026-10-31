import
  std/unittest,
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
