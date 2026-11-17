import
  std/[json, os, osproc, streams, strutils],
  ./[bindings, common, runtime, status]

type
  BusctlRunner* = proc (args: seq[string]): JsonNode {.gcsafe.}
  MousepadLightingState* = object
    daemonOwner: string
    handledDevices: seq[string]

const
  RazerService = "org.razer"
  RazerManagerPath = "/org/razer"
  RazerDevicePath = "/org/razer/device/"
  RazerVendorId = 0x1532
  GoliathusExtendedId = 0x0c02
  LightingPollMs = 5000

var lightingThread: Thread[void]

proc runBusctl(args: seq[string]): JsonNode =
  ## Call D-Bus with a reply deadline and decode busctl's JSON response.
  let process = spawnCommand("busctl",
    @["--user", "--timeout=1s", "--json=short"] & args)
  defer:
    if running(process):
      kill(process)
    discard waitForExit(process)
    close(process)
  let
    output = process.outputStream.readAll()
    exitCode = waitForExit(process)
  if exitCode != 0:
    raise newException(OSError, "busctl: " & output.strip())
  result = if output.strip().len == 0: newJNull() else: parseJson(output)

proc syncMousepadLighting*(state: var MousepadLightingState, run: BusctlRunner) =
  ## Apply grey breathing to newly seen mousepads and after OpenRazer restarts.
  let owner = run(@["call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
    "org.freedesktop.DBus", "GetNameOwner", "s", RazerService])["data"][0].getStr()
  if state.daemonOwner != owner:
    state.handledDevices.setLen(0)
    state.daemonOwner = owner
  let devices = run(@["call", RazerService, RazerManagerPath,
    "razer.devices", "getDevices"])["data"][0]
  var handledDevices: seq[string]
  for device in devices:
    let serial = device.getStr()
    if serial notin state.handledDevices:
      let
        path = RazerDevicePath & serial
        ids = run(@["call", RazerService, path,
          "razer.device.misc", "getVidPid"])["data"][0]
      if ids.len == 2 and ids[0].getInt() == RazerVendorId and
          ids[1].getInt() == GoliathusExtendedId:
        discard run(@["call", RazerService, path,
          "razer.device.lighting.brightness", "setBrightness", "d", GreyBrightness])
        discard run(@["call", RazerService, path,
          "razer.device.lighting.chroma", "setBreathDual", "yyyyyy",
          DarkGrey, DarkGrey, DarkGrey, LightGrey, LightGrey, LightGrey])
    handledDevices.add(serial)
  state.handledDevices = handledDevices

proc watchMousepadLighting() {.thread.} =
  ## Retry optional lighting independently so OpenRazer failures cannot stop MIDI.
  var
    state: MousepadLightingState
    lastError = ""
  while not shouldStop():
    try:
      state.syncMousepadLighting(runBusctl)
      setComponentError("lighting", "")
      lastError.setLen(0)
    except CatchableError as error:
      setComponentError("lighting", error.msg)
      if error.msg != lastError:
        stderr.writeLine("Mousepad lighting unavailable: " & error.msg)
        lastError = error.msg
    sleep(LightingPollMs)

proc startMousepadLighting*() =
  ## Start optional OpenRazer lighting control without changing other Razer devices.
  if findExe("busctl").len == 0:
    stderr.writeLine("Mousepad lighting unavailable: busctl is not installed.")
    return
  createThread(lightingThread, watchMousepadLighting)
