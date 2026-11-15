import
  std/[json, unittest],
  knobby/razer_lighting

type
  FakeRazer = ref object
    owner: string
    devices: seq[tuple[serial: string, vendorId, productId: int]]
    calls: seq[seq[string]]
    failEffect: bool

proc runner(fake: FakeRazer): BusctlRunner =
  ## Simulate OpenRazer D-Bus responses without hardware or subprocesses.
  result = proc (args: seq[string]): JsonNode {.gcsafe.} =
    ## Record a call and return the fake device or daemon response.
    fake.calls.add(args)
    case args[4]
    of "GetNameOwner":
      result = %*{"data": [fake.owner]}
    of "getDevices":
      var serials: seq[string]
      for device in fake.devices:
        serials.add(device.serial)
      result = %*{"data": [serials]}
    of "getVidPid":
      for device in fake.devices:
        if args[2] == "/org/razer/device/" & device.serial:
          return %*{"data": [[device.vendorId, device.productId]]}
      raise newException(IOError, "Device disappeared.")
    of "setBreathDual":
      if fake.failEffect:
        raise newException(IOError, "Synthetic lighting failure.")
      result = newJNull()
    of "setBrightness":
      result = newJNull()
    else:
      raise newException(ValueError, "Unexpected D-Bus method: " & args[4])

proc writes(fake: FakeRazer): seq[seq[string]] =
  ## Return calls that change brightness or lighting effects.
  for args in fake.calls:
    if args[4] in ["setBrightness", "setBreathDual"]:
      result.add(args)

suite "OpenRazer mousepad lighting":
  test "only the Goliathus receives the dim grey preset":
    let fake = FakeRazer(owner: ":1.3", devices: @[
      ("mouse", 0x1532, 0x0098),
      ("other-vendor", 0x1234, 0x0c02),
      ("mousepad", 0x1532, 0x0c02)])
    var state: MousepadLightingState
    state.syncMousepadLighting(fake.runner())
    check fake.writes() == @[
      @["call", "org.razer", "/org/razer/device/mousepad",
        "razer.device.lighting.brightness", "setBrightness", "d", "25"],
      @["call", "org.razer", "/org/razer/device/mousepad",
        "razer.device.lighting.chroma", "setBreathDual", "yyyyyy",
        "72", "72", "72", "96", "96", "96"]]

  test "quiet polls preserve the running hardware animation":
    let fake = FakeRazer(owner: ":1.3", devices: @[("pad", 0x1532, 0x0c02)])
    var state: MousepadLightingState
    state.syncMousepadLighting(fake.runner())
    state.syncMousepadLighting(fake.runner())
    check fake.writes().len == 2

  test "reapply after unplugging or restarting OpenRazer":
    let fake = FakeRazer(owner: ":1.3", devices: @[("pad", 0x1532, 0x0c02)])
    var state: MousepadLightingState
    state.syncMousepadLighting(fake.runner())
    fake.devices.setLen(0)
    state.syncMousepadLighting(fake.runner())
    fake.devices = @[("pad", 0x1532, 0x0c02)]
    state.syncMousepadLighting(fake.runner())
    fake.owner = ":1.42"
    state.syncMousepadLighting(fake.runner())
    check fake.writes().len == 6

  test "failed effects remain eligible for retry":
    let fake = FakeRazer(owner: ":1.3", devices: @[("pad", 0x1532, 0x0c02)],
      failEffect: true)
    var state: MousepadLightingState
    expect IOError:
      state.syncMousepadLighting(fake.runner())
    fake.failEffect = false
    state.syncMousepadLighting(fake.runner())
    check fake.writes().len == 4
