import
  std/[options, os, posix, strutils],
  ./ipc

type
  StreamDeckKeys* = array[15, bool]
  StreamDeckKeyEvent* = object
    keyIndex*: int
    pressed*: bool
  StreamDeckIo* = object
    readReport*: proc (timeoutMs: int): string {.gcsafe.}
    writeReport*: proc (report: string): int {.gcsafe.}
    sendFeature*: proc (report: string): int {.gcsafe.}
    close*: proc () {.gcsafe.}
  StreamDeck* = ref object
    io: StreamDeckIo
    keys: StreamDeckKeys
    closed: bool
  ReportWrite* = enum
    ReportSent, ReportDeferred
  StreamDeckMonitor* = ref object
    readReport: proc (timeoutMs: int): string {.gcsafe.}
    closeTransport: proc () {.gcsafe.}
    keys: StreamDeckKeys
    closed: bool
  HidDeviceInfo {.importc: "struct hidraw_devinfo", header: "<linux/hidraw.h>", bycopy.} = object
    bustype: cuint
    vendor: cshort
    product: cshort

const
  StreamDeckKeyCount* = 15
  StreamDeckVendorId = 0x0fd9
  StreamDeckProductId = 0x0080
  UsbBus = 3
  HidrawClassPath = "/sys/class/hidraw"
  InputReportId = '\x01'
  KeyStateCommand = '\x00'
  InputHeaderBytes = 4
  InputBufferBytes = 512
  ImageReportBytes* = 1024
  ImageHeaderBytes = 8
  ImagePayloadBytes* = ImageReportBytes - ImageHeaderBytes
  OutputReportId = '\x02'
  KeyImageCommand = '\x07'
  FeatureReportBytes = 32
  FeatureReportId = '\x03'
  BrightnessCommand = '\x08'
  LogoCommand = '\x02'
  MaxBrightness = 100
  DefaultPollMs = 100
  DeferredImageRetries = 200
  DeferredImageRetryMs = 1

var RawInfoRequest {.importc: "HIDIOCGRAWINFO", header: "<linux/hidraw.h>".}: cuint

proc featureRequest(length: cint): cuint {.importc: "HIDIOCSFEATURE", header: "<linux/hidraw.h>".}
  ## Obtain the Linux ioctl request for a feature report of the given size.

proc parseKeyStates*(report: string): Option[StreamDeckKeys] =
  ## Decode a complete MK.2 key report, ignoring unrelated report types.
  if report.len == 0 or report[0] != InputReportId:
    return none(StreamDeckKeys)
  if report.len < 2:
    raise newException(ValueError, "Truncated Stream Deck input header.")
  if report[1] != KeyStateCommand:
    return none(StreamDeckKeys)
  if report.len < InputHeaderBytes:
    raise newException(ValueError, "Truncated Stream Deck key header.")
  let count = ord(report[2]) or (ord(report[3]) shl 8)
  if count != StreamDeckKeyCount or report.len < InputHeaderBytes + count:
    raise newException(ValueError, "Invalid Stream Deck key report length.")
  var keys: StreamDeckKeys
  for index in 0..<StreamDeckKeyCount:
    let value = ord(report[InputHeaderBytes + index])
    if value notin 0..1:
      raise newException(ValueError, "Invalid Stream Deck key state.")
    keys[index] = value == 1
  result = some(keys)

proc keyChanges*(previous: var StreamDeckKeys, current: StreamDeckKeys): seq[StreamDeckKeyEvent] =
  ## Return each changed key once and retain the complete new state.
  for index in 0..<StreamDeckKeyCount:
    if previous[index] != current[index]:
      result.add(StreamDeckKeyEvent(keyIndex: index, pressed: current[index]))
  previous = current

proc encodeKeyImageReports*(keyIndex: int, jpeg: string): seq[string] =
  ## Packetize an already rotated 72-by-72 JPEG into padded MK.2 reports.
  if keyIndex notin 0..<StreamDeckKeyCount:
    raise newException(ValueError, "Stream Deck key index must be between 0 and 14.")
  if jpeg.len == 0 or jpeg.len > ImagePayloadBytes * (high(uint16).int + 1):
    raise newException(ValueError, "Invalid Stream Deck JPEG payload size.")
  var offset = 0
  while offset < jpeg.len:
    let
      size = min(ImagePayloadBytes, jpeg.len - offset)
      page = offset div ImagePayloadBytes
    var report = newString(ImageReportBytes)
    report[0] = OutputReportId
    report[1] = KeyImageCommand
    report[2] = chr(keyIndex)
    report[3] = chr(ord(offset + size == jpeg.len))
    report[4] = chr(size and 0xff)
    report[5] = chr(size shr 8)
    report[6] = chr(page and 0xff)
    report[7] = chr(page shr 8)
    copyMem(addr report[ImageHeaderBytes], unsafeAddr jpeg[offset], size)
    result.add(report)
    offset += size

proc encodeBrightnessReport*(percent: int): string =
  ## Encode a backlight percentage between zero and one hundred.
  if percent notin 0..MaxBrightness:
    raise newException(ValueError, "Stream Deck brightness must be between 0 and 100.")
  result = newString(FeatureReportBytes)
  result[0] = FeatureReportId
  result[1] = BrightnessCommand
  result[2] = chr(percent)

proc newStreamDeck*(io: StreamDeckIo): StreamDeck =
  ## Create an owning session with injectable report I/O and released keys.
  if io.readReport.isNil or io.writeReport.isNil or io.sendFeature.isNil or io.close.isNil:
    raise newException(ValueError, "Stream Deck I/O callbacks must all be supplied.")
  result = StreamDeck(io: io)

proc ensureOpen(deck: StreamDeck) =
  ## Reject access through a session whose descriptor has been closed.
  if deck.closed:
    raise newException(IOError, "Stream Deck session is closed.")

proc close*(deck: StreamDeck) =
  ## Close the owned transport once, including after a device disconnect.
  if deck.closed:
    return
  deck.closed = true
  deck.keys = default(StreamDeckKeys)
  deck.io.close()

proc setBrightness*(deck: StreamDeck, percent: int) =
  ## Set backlight brightness and reject an incomplete feature transfer.
  deck.ensureOpen()
  let report = encodeBrightnessReport(percent)
  if deck.io.sendFeature(report) != report.len:
    raise newException(IOError, "Incomplete Stream Deck brightness report.")

proc showLogo*(deck: StreamDeck) =
  ## Restore the Elgato logo without resetting firmware or updating flash.
  deck.ensureOpen()
  var report = newString(FeatureReportBytes)
  report[0] = FeatureReportId
  report[1] = LogoCommand
  if deck.io.sendFeature(report) != report.len:
    raise newException(IOError, "Incomplete Stream Deck logo report.")

proc trySendReport*(deck: StreamDeck, report: string): ReportWrite =
  ## Write one complete output report, or report that the transport would block.
  ## A zero-byte write means the report was not accepted and may be retried;
  ## any other short write is an incomplete transfer and raises IOError.
  deck.ensureOpen()
  let written = deck.io.writeReport(report)
  if written == 0 and report.len > 0:
    result = ReportDeferred
  elif written == report.len:
    result = ReportSent
  else:
    raise newException(IOError, "Incomplete Stream Deck image report.")

proc setKeyImage*(deck: StreamDeck, keyIndex: int, jpeg: string) =
  ## Upload a prepared JPEG, retrying a deferred report briefly and failing on short writes.
  deck.ensureOpen()
  for report in encodeKeyImageReports(keyIndex, jpeg):
    var attempts = 0
    while deck.trySendReport(report) == ReportDeferred:
      inc attempts
      if attempts > DeferredImageRetries:
        raise newException(IOError, "Stream Deck output stayed busy.")
      sleep(DeferredImageRetryMs)

proc pollKeys*(deck: StreamDeck, timeoutMs = DefaultPollMs): seq[StreamDeckKeyEvent] =
  ## Poll for changed keys, returning no events on timeout or unrelated reports.
  deck.ensureOpen()
  if timeoutMs < 0:
    raise newException(ValueError, "Stream Deck polling needs a finite nonnegative timeout.")
  let states = parseKeyStates(deck.io.readReport(timeoutMs))
  if states.isSome:
    result = keyChanges(deck.keys, states.get())

proc matchesStreamDeckIdentity*(uevent: string): bool =
  ## Match the USB MK.2 vendor and product in a sysfs HID identity record.
  for line in uevent.splitLines():
    if line.startsWith("HID_ID="):
      let fields = line["HID_ID=".len..^1].split(':')
      return fields.len == 3 and fields[0] == "0003" and
        fields[1].toUpperAscii() == "00000FD9" and fields[2] == "00000080"

proc discoverStreamDeck*(classPath = HidrawClassPath): string =
  ## Find one MK.2 hidraw node, returning an empty path while it is absent.
  if not dirExists(classPath):
    return ""
  for _, path in walkDir(classPath):
    let identityPath = path / "device" / "uevent"
    if fileExists(identityPath):
      var identity: string
      try:
        identity = readFile(identityPath)
      except IOError:
        if not fileExists(identityPath):
          continue
        raise
      if matchesStreamDeckIdentity(identity):
        if result.len > 0:
          raise newException(ValueError, "Multiple Stream Deck MK.2 devices found; the demo supports one.")
        result = "/dev" / path.lastPathPart()

proc readNativeReport(handle: cint, timeoutMs: int): string =
  ## Poll a hidraw descriptor, distinguishing quiet input from disconnects.
  var descriptor = TPollfd(fd: handle, events: POLLIN)
  let ready = poll(addr descriptor, Tnfds(1), cint(timeoutMs))
  if ready < 0:
    if errno == EINTR:
      return ""
    raiseOSError(osLastError())
  if ready == 0:
    return ""
  if (descriptor.revents and (POLLERR or POLLHUP or POLLNVAL)) != 0:
    raiseOSError(OSErrorCode(ENODEV), "Stream Deck disconnected.")
  var buffer: array[InputBufferBytes, char]
  let size = posix.read(handle, addr buffer[0], buffer.len)
  if size < 0:
    if errno == EAGAIN or errno == EINTR:
      return ""
    raiseOSError(osLastError())
  if size == 0:
    raiseOSError(OSErrorCode(ENODEV), "Stream Deck closed its input.")
  result = newString(size)
  copyMem(addr result[0], addr buffer[0], size)

proc openNativeStreamDeck(path: string, flags: cint): StreamDeck =
  ## Open and revalidate a Linux USB MK.2 before issuing device commands.
  let handle = posix.open(path.cstring, flags or O_NONBLOCK or O_CLOEXEC)
  if handle < 0:
    raiseOSError(osLastError(), path)
  try:
    var info: HidDeviceInfo
    if posix.ioctl(FileHandle(handle), uint(RawInfoRequest), addr info) < 0:
      raiseOSError(osLastError(), path)
    if info.bustype != UsbBus or info.vendor.int != StreamDeckVendorId or
        info.product.int != StreamDeckProductId:
      raise newException(ValueError, "The opened hidraw node is not a Stream Deck MK.2: " & path)
    result = newStreamDeck(StreamDeckIo(
      readReport: proc (timeoutMs: int): string =
        ## Read a single complete report from the owned descriptor.
        readNativeReport(handle, timeoutMs),
      writeReport: proc (report: string): int =
        ## Write one complete output report through hidraw.
        ## A nonblocking write that would block returns zero so callers retry the same report.
        result = posix.write(handle, report.cstring, report.len)
        if result < 0:
          let code = osLastError()
          if code.int32 notin [EAGAIN.int32, EWOULDBLOCK.int32, EINTR.int32]:
            raiseOSError(code, path)
          result = 0,
      sendFeature: proc (report: string): int =
        ## Send a feature report using the kernel's HID ioctl.
        result = posix.ioctl(FileHandle(handle), uint(featureRequest(cint(report.len))), report.cstring)
        if result < 0:
          raiseOSError(osLastError(), path),
      close: proc () =
        ## Release the descriptor when its session ends.
        if posix.close(handle) < 0:
          raiseOSError(osLastError(), path)))
  except:
    if posix.close(handle) < 0:
      stderr.writeLine("Closing Stream Deck failed: " & osErrorMsg(osLastError()))
    raise

proc openStreamDeck*(path: string): StreamDeck =
  ## Open the MK.2 for the existing display-control demo.
  let ownership = acquireOwnership(runtimePath("knobby-devices", "stream-deck.lock"))
  try:
    result = openNativeStreamDeck(path, O_RDWR)
    let closeNative = result.io.close
    result.io.close = proc () =
      ## Release both the display descriptor and its cross-process ownership lock.
      defer: discard posix.close(ownership)
      closeNative()
  except:
    discard posix.close(ownership)
    raise

proc newStreamDeckMonitor*(readReport: proc (timeoutMs: int): string {.gcsafe.},
    closeTransport: proc () {.gcsafe.}): StreamDeckMonitor =
  ## Own an input-only transport without exposing any display-setting methods.
  if readReport.isNil or closeTransport.isNil:
    raise newException(ValueError, "Monitor callbacks must be supplied.")
  StreamDeckMonitor(readReport: readReport, closeTransport: closeTransport)

proc openStreamDeckMonitor*(path: string): StreamDeckMonitor =
  ## Open a separate O_RDONLY descriptor; never send output or feature reports.
  let deck = openNativeStreamDeck(path, O_RDONLY)
  newStreamDeckMonitor(deck.io.readReport, proc () =
    ## Close the owned native descriptor without restoring or changing its display.
    deck.close())

proc pollKeys*(monitor: StreamDeckMonitor, timeoutMs = DefaultPollMs): seq[StreamDeckKeyEvent] =
  ## Observe edges from this reader's independent kernel input queue.
  if monitor.closed:
    raise newException(IOError, "Stream Deck monitor is closed.")
  if timeoutMs < 0:
    raise newException(ValueError, "Polling needs a finite nonnegative timeout.")
  let states = parseKeyStates(monitor.readReport(timeoutMs))
  if states.isSome:
    result = keyChanges(monitor.keys, states.get())

proc close*(monitor: StreamDeckMonitor) =
  ## Release an input observer exactly once without issuing a device command.
  if monitor.closed:
    return
  monitor.closed = true
  monitor.keys = default(StreamDeckKeys)
  monitor.closeTransport()
