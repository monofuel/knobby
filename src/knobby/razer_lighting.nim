import
  std/[algorithm, json, os, strutils],
  ./[bindings, common, runtime, status]

type
  BusctlRunner* = proc (args: seq[string]): JsonNode {.gcsafe.}
  MousepadLightingState* = object
    daemonOwner: string
    attachment: string
    handledDevices: seq[string]

const
  RazerService = "org.razer"
  RazerManagerPath = "/org/razer"
  RazerDevicePath = "/org/razer/device/"
  RazerVendorId = 0x1532
  GoliathusExtendedId = 0x0c02
  LightingPollMs = 5000
  UsbDevicesPath = "/sys/bus/usb/devices"
  RazerVendorText = "1532"
  GoliathusExtendedText = "0c02"

var lightingThread: Thread[void]

proc runBusctl(args: seq[string]): JsonNode =
  ## Bound the entire command as well as its D-Bus reply and decode stdout separately.
  let output = runAudioCommand("busctl",
    @["--user", "--timeout=1s", "--json=short"] & args)
  result = if output.strip().len == 0: newJNull() else: parseJson(output)

proc observeMousepadAttachment*(usbDevices = UsbDevicesPath): string =
  ## Identify each attached Goliathus by USB port and device number, empty when absent.
  ## The kernel assigns a new device number on every enumeration, so a replug
  ## changes the result even when it happens between two observations.
  var attachments: seq[string]
  for _, path in walkDir(usbDevices):
    if fileExists(path / "idVendor") and fileExists(path / "idProduct") and
        readFile(path / "idVendor").strip() == RazerVendorText and
        readFile(path / "idProduct").strip() == GoliathusExtendedText:
      attachments.add(path.lastPathPart() & "#" & readFile(path / "devnum").strip())
  attachments.sort()
  result = attachments.join(",")

proc syncMousepadLighting*(state: var MousepadLightingState, run: BusctlRunner,
    attachment: string) =
  ## Apply grey breathing to newly seen mousepads, after a USB reattachment,
  ## and after OpenRazer restarts.
  let owner = run(@["call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
    "org.freedesktop.DBus", "GetNameOwner", "s", RazerService])["data"][0].getStr()
  if state.daemonOwner != owner or state.attachment != attachment:
    state.handledDevices.setLen(0)
    state.daemonOwner = owner
    state.attachment = attachment
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
      state.syncMousepadLighting(runBusctl, observeMousepadAttachment())
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
