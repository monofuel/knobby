import
  std/[json, os, unittest],
  knobby/razer_lighting

type
  FakeRazer = ref object
    owner: string
    devices: seq[tuple[serial: string, vendorId, productId: int]]
    calls: seq[seq[string]]
    failEffect: bool

const
  Attached = "1-4#7"

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
    state.syncMousepadLighting(fake.runner(), Attached)
    check fake.writes() == @[
      @["call", "org.razer", "/org/razer/device/mousepad",
        "razer.device.lighting.brightness", "setBrightness", "d", "25"],
      @["call", "org.razer", "/org/razer/device/mousepad",
        "razer.device.lighting.chroma", "setBreathDual", "yyyyyy",
        "72", "72", "72", "96", "96", "96"]]

  test "quiet polls preserve the running hardware animation":
    let fake = FakeRazer(owner: ":1.3", devices: @[("pad", 0x1532, 0x0c02)])
    var state: MousepadLightingState
    state.syncMousepadLighting(fake.runner(), Attached)
    state.syncMousepadLighting(fake.runner(), Attached)
    check fake.writes().len == 2

  test "reapply after unplugging or restarting OpenRazer":
    let fake = FakeRazer(owner: ":1.3", devices: @[("pad", 0x1532, 0x0c02)])
    var state: MousepadLightingState
    state.syncMousepadLighting(fake.runner(), Attached)
    fake.devices.setLen(0)
    state.syncMousepadLighting(fake.runner(), Attached)
    fake.devices = @[("pad", 0x1532, 0x0c02)]
    state.syncMousepadLighting(fake.runner(), Attached)
    fake.owner = ":1.42"
    state.syncMousepadLighting(fake.runner(), Attached)
    check fake.writes().len == 6

  test "failed effects remain eligible for retry":
    let fake = FakeRazer(owner: ":1.3", devices: @[("pad", 0x1532, 0x0c02)],
      failEffect: true)
    var state: MousepadLightingState
    expect IOError:
      state.syncMousepadLighting(fake.runner(), Attached)
    fake.failEffect = false
    state.syncMousepadLighting(fake.runner(), Attached)
    check fake.writes().len == 4

  test "a replug between polls reapplies to the same serial":
    let fake = FakeRazer(owner: ":1.3", devices: @[("pad", 0x1532, 0x0c02)])
    var state: MousepadLightingState
    state.syncMousepadLighting(fake.runner(), "1-4#7")
    state.syncMousepadLighting(fake.runner(), "1-4#7")
    state.syncMousepadLighting(fake.runner(), "1-4#9")
    check fake.writes().len == 4

  test "attachment identity follows the USB device number":
    let root = getTempDir() / ("knobby-usb-test-" & $getCurrentProcessId())
    proc device(name, vendor, product, devnum: string) =
      ## Create a synthetic sysfs USB device directory.
      createDir(root / name)
      writeFile(root / name / "idVendor", vendor & "\n")
      writeFile(root / name / "idProduct", product & "\n")
      writeFile(root / name / "devnum", devnum & "\n")
    defer: removeDir(root)
    createDir(root)
    check observeMousepadAttachment(root) == ""
    device("1-3", "1532", "0098", "5")
    createDir(root / "1-4:1.0")
    check observeMousepadAttachment(root) == ""
    device("1-4", "1532", "0c02", "7")
    check observeMousepadAttachment(root) == "1-4#7"
    writeFile(root / "1-4" / "devnum", "9\n")
    check observeMousepadAttachment(root) == "1-4#9"
    check observeMousepadAttachment(root / "missing") == ""
