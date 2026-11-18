# Content keys use SHA-1 from the standard library; they identify cache entries
# and carry no security promise, so the deprecation in favour of an external
# package is not worth a dependency.
{.warning[Deprecated]: off.}

import
  std/[json, monotimes, os, osproc, posix, sequtils, sets, sha1, strutils, times, unicode],
  ./[common, controls_state, obs_state]

type
  MediaError* = object of ValueError
    field*: string

  MediaTimeoutError* = object of IOError
    ## Raised when a child process or the whole media operation runs out of time.

  PreparedCleanup* = object
    manifests*: int
    protectedKeys*: int
    removed*: seq[string]
    errors*: seq[string]

  OperationScope = tuple[deadline: MonoTime, timeoutMs: int]

  SourceKind* = enum
    PngSource = "png"
    JpegSource = "jpg"
    GifSource = "gif"

  SourceInfo* = object
    kind*: SourceKind
    width*: int
    height*: int

  FrameTiming* = object
    index*: int
    durationMs*: int

  TitleLayout* = object
    fontSize*: int
    lines*: seq[string]

  KeyPlanKind* = enum
    BuiltinKey
    TitleKey
    ArtworkKey

  StatePlan* = object
    state*: string
    image*: string

  KeyPlan* = object
    key*: int
    field*: string
    obsOperation*: string
    controlAction*: string
    states*: seq[StatePlan]
    case kind*: KeyPlanKind
    of BuiltinKey:
      builtinNumber*: int
    of TitleKey, ArtworkKey:
      title*: string
      image*: string

  MenuPlan* = object
    id*: string
    keys*: seq[KeyPlan]

  PreparedFrame = object
    path: string
    durationMs: int

  PreparedKey = object
    normal: seq[PreparedFrame]
    pressed: string

const
  MediaHelperVersion* = "1"
  ManifestVersion* = 1
  KeySize* = 72
  DeckKeyCount* = 15
  MaxSourceBytes* = 20 * 1024 * 1024
  MaxSourceDimension* = 4096
  MaxAnimationMs* = 30_000
  MaxSourceFrames* = 900
  MaxFramesPerSecond* = 30
  MaxPreparedBytes* = 128 * 1024 * 1024
  OperationTimeoutMs* = 90_000
  ChildTimeoutMs* = 90_000
  PreparedGraceSeconds* = 3600
  ContentKeyLength = 40
  MaxChildStdoutBytes* = 1024 * 1024
  MaxChildStderrBytes* = 64 * 1024
  ChildPollMs = 50
  StaleWorkSeconds = 3600
  DefaultFrameMs = 100
  BackTitle* = "Back"
  AssetPrefix = "assets/"
  MaxAssetNameBytes = 128
  WorkPrefix = ".tmp-"
  FramesFile = "frames.json"
  PressedFile = "pressed.jpg"
  TitleFile = "title.txt"
  SourceStem = "source."
  NormalPattern = "normal-%04d.jpg"
  NormalBackground = "black"
  PressedBackground = "0xc0c0c0"
  PressedOverlay = "white@0.35"
  TitleBox = "black@0.6"
  TitleMargin = 4
  TitleSizes = [24, 18, 14, 11]
  OverlaySizes = [14, 11]
  OverlayMaxLines = 2
  GlyphWidthRatio = 0.62
  LineHeightRatio = 1.25
  Ellipsis = "…"
  PngSignature = "\x89PNG\r\n\x1a\n"
  JpegSignature = "\xff\xd8\xff"
  GifSignatures = ["GIF87a", "GIF89a"]
  EncoderArgs = ["-c:v", "mjpeg", "-threads", "1", "-pix_fmt", "yuvj420p",
    "-huffman", "optimal", "-q:v", "2", "-f", "image2"]
  # Any change to how keys are rendered must change this string so cached
  # output from older renderers is never reused.
  RenderSettings = "contain-premultiplied-black;neighbor-upscale-area-downscale;" &
    "rotate180;yuvj420p;huffman-optimal;q2;title-white-on-black;" &
    "pressed-black-on-c0c0c0;pressed-art-white35;overlay-box-black60"

var
  # A zero timeout means no media operation is active on this thread.
  operationDeadline {.threadvar.}: MonoTime
  operationTimeoutMs {.threadvar.}: int

proc renameFile(source, destination: cstring): cint {.importc: "rename",
    header: "<stdio.h>".}
  ## Rename a path atomically, failing instead of replacing a non-empty directory.

proc raiseMedia(field, message: string) {.noreturn.} =
  ## Raise a MediaError whose message carries the field context.
  var error = newException(MediaError,
    if field.len > 0: field & ": " & message else: message)
  error.field = field
  raise error

proc enterOperationDeadline(timeoutMs: int): OperationScope =
  ## Start or narrow this thread's operation deadline and return the previous
  ## scope. A nested scope can only shorten the deadline, never extend it.
  if timeoutMs <= 0:
    raise newException(ValueError, "Media operation timeout must be positive: " &
      $timeoutMs & " ms.")
  result = (operationDeadline, operationTimeoutMs)
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  if operationTimeoutMs == 0 or deadline < operationDeadline:
    operationDeadline = deadline
    operationTimeoutMs = timeoutMs

proc restoreOperationDeadline(scope: OperationScope) =
  ## Restore the deadline that was active before a scope started.
  operationDeadline = scope.deadline
  operationTimeoutMs = scope.timeoutMs

template withOperationDeadline*(timeoutMs: int, body: untyped) =
  ## Run body with one overall deadline shared by every media check and child
  ## process on this thread. The previous deadline is restored afterwards,
  ## including when body raises.
  bind enterOperationDeadline, restoreOperationDeadline
  let previousScope = enterOperationDeadline(timeoutMs)
  try:
    body
  finally:
    restoreOperationDeadline(previousScope)

proc hasOperationDeadline*(): bool =
  ## Report whether a media operation deadline is active on this thread.
  result = operationTimeoutMs > 0

proc raiseOperationTimeout(context: string) {.noreturn.} =
  ## Raise the error reported when the overall operation runs out of time.
  raise newException(MediaTimeoutError, context &
    "The button media operation exceeded its " & $operationTimeoutMs & " ms deadline.")

proc checkOperationDeadline*() =
  ## Raise MediaTimeoutError when this thread's operation deadline has passed.
  if hasOperationDeadline() and getMonoTime() >= operationDeadline:
    raiseOperationTimeout("")

proc contentKey*(data: string): string =
  ## Return the lowercase SHA-1 hex digest used for content addressing.
  result = toLowerAscii($secureHash(data))

proc sourceKindFromBytes*(data: string, field = ""): SourceKind =
  ## Identify a supported image by its signature, rejecting anything else.
  if data.startsWith(PngSignature):
    result = PngSource
  elif data.startsWith(JpegSignature):
    result = JpegSource
  elif data.startsWith(GifSignatures[0]) or data.startsWith(GifSignatures[1]):
    result = GifSource
  else:
    raiseMedia(field, "Unsupported image format; use PNG, JPEG or GIF.")

proc demuxerName(kind: SourceKind): string =
  ## Return the FFmpeg demuxer forced for a source kind.
  case kind
  of PngSource: "png_pipe"
  of JpegSource: "jpeg_pipe"
  of GifSource: "gif"

proc expectedCodec(kind: SourceKind): string =
  ## Return the codec ffprobe must report for a source kind.
  case kind
  of PngSource: "png"
  of JpegSource: "mjpeg"
  of GifSource: "gif"

proc isManagedAsset*(path: string): bool =
  ## Report whether a relative path names a managed assets/<name> file.
  if not path.startsWith(AssetPrefix):
    return false
  let name = path[AssetPrefix.len..^1]
  result = name.len in 1..MaxAssetNameBytes and name[0] != '.'
  for character in name:
    if character notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'}:
      result = false

proc parseStreamProbe*(kind: SourceKind, text: string, field = ""): SourceInfo =
  ## Parse ffprobe stream JSON and enforce codec and dimension limits.
  let
    root = parseJson(text)
    streams = root{"streams"}
  if streams.isNil or streams.kind != JArray or streams.len == 0:
    raiseMedia(field, "The image contains no picture.")
  let stream = streams[0]
  if stream{"codec_name"}.getStr() != expectedCodec(kind):
    raiseMedia(field, "The image content does not match its " & $kind & " signature.")
  result = SourceInfo(kind: kind, width: stream{"width"}.getInt(),
    height: stream{"height"}.getInt())
  if result.width <= 0 or result.height <= 0:
    raiseMedia(field, "The image has no usable dimensions.")
  if result.width > MaxSourceDimension or result.height > MaxSourceDimension:
    raiseMedia(field, "The image is " & $result.width & "x" & $result.height &
      "; the limit is " & $MaxSourceDimension & "x" & $MaxSourceDimension & ".")

proc parseTimeBase(text: string): tuple[num, den: int] =
  ## Parse an ffprobe "num/den" time base.
  let parts = text.split('/')
  if parts.len != 2:
    raise newException(ValueError, "Invalid time base: " & text)
  result = (parseInt(parts[0]), parseInt(parts[1]))
  if result.num <= 0 or result.den <= 0:
    raise newException(ValueError, "Invalid time base: " & text)

proc parsePacketDurations*(text: string, field = ""): seq[int] =
  ## Convert ffprobe packet JSON into per-frame display durations in ms.
  let
    root = parseJson(text)
    timeBase = parseTimeBase(root{"streams"}[0]{"time_base"}.getStr())
    packets = root{"packets"}
  if packets.isNil or packets.len == 0:
    raiseMedia(field, "The animation contains no frames.")
  if packets.len > MaxSourceFrames:
    raiseMedia(field, "The animation has more than " & $MaxSourceFrames & " frames.")
  for index, packet in packets.getElems():
    var ticks = packet{"duration"}.getInt(0)
    if ticks <= 0 and index + 1 < packets.len:
      ticks = packets[index + 1]{"pts"}.getInt(0) - packet{"pts"}.getInt(0)
    let milliseconds = (ticks * 1000 * timeBase.num + timeBase.den div 2) div timeBase.den
    result.add(if milliseconds > 0: milliseconds else: DefaultFrameMs)

proc selectFrames*(durationsMs: seq[int], field = ""): seq[FrameTiming] =
  ## Pick displayed frames so playback never exceeds MaxFramesPerSecond.
  ## Frames starting too soon after the previous displayed frame are merged
  ## into it. A single displayed frame is static and has duration 0.
  if durationsMs.len == 0:
    raiseMedia(field, "The animation contains no frames.")
  if durationsMs.len > MaxSourceFrames:
    raiseMedia(field, "The animation has more than " & $MaxSourceFrames & " frames.")
  var total = 0
  for duration in durationsMs:
    total += duration
  if total > MaxAnimationMs:
    raiseMedia(field, "The animation lasts " & $total & " ms; the limit is " &
      $MaxAnimationMs & " ms.")
  var
    starts: seq[int]
    start = 0
  for index, duration in durationsMs:
    if result.len == 0 or (start - starts[^1]) * MaxFramesPerSecond >= 1000:
      result.add(FrameTiming(index: index))
      starts.add(start)
    start += duration
  while result.len > 1 and (total - starts[^1]) * MaxFramesPerSecond < 1000:
    result.setLen(result.len - 1)
    starts.setLen(starts.len - 1)
  if result.len == 1:
    result[0].durationMs = 0
  else:
    for position in 0..<result.len:
      let finish = if position + 1 < result.len: starts[position + 1] else: total
      result[position].durationMs = finish - starts[position]

proc containSize*(width, height: int): tuple[width, height: int] =
  ## Scale dimensions proportionally to fit inside the key, at least 1 pixel.
  if width >= height:
    result = (KeySize, max(1, (height * KeySize + width div 2) div width))
  else:
    result = (max(1, (width * KeySize + height div 2) div height), KeySize)

proc cleanTitle*(title: string): string =
  ## Replace control characters with spaces and collapse whitespace runs.
  var words: seq[string]
  var current = ""
  for rune in title.runes:
    if rune.int32 < 0x20 or rune.int32 == 0x7f or rune.isWhiteSpace():
      if current.len > 0:
        words.add(current)
        current = ""
    else:
      current.add($rune)
  if current.len > 0:
    words.add(current)
  result = words.join(" ")

proc wrapTitle(words: seq[string], width: int): seq[string] =
  ## Greedily wrap words to a rune width, splitting words that are too long.
  var line = ""
  for word in words:
    var rest = word
    while rest.runeLen > width:
      if line.len > 0:
        result.add(line)
        line = ""
      result.add(rest.runeSubStr(0, width))
      rest = rest.runeSubStr(width)
    if line.len == 0:
      line = rest
    elif line.runeLen + 1 + rest.runeLen <= width:
      line.add(" " & rest)
    else:
      result.add(line)
      line = rest
  if line.len > 0:
    result.add(line)

proc layoutTitle*(title: string, sizes: openArray[int], maxWidth, maxHeight,
    maxLines: int): TitleLayout =
  ## Choose the largest font size whose estimated wrapped text fits the box.
  ## The smallest size truncates with an ellipsis when nothing fits.
  let words = strutils.splitWhitespace(cleanTitle(title))
  result.fontSize = sizes[^1]
  if words.len == 0:
    return
  for size in sizes:
    let
      width = max(1, int(maxWidth.float / (size.float * GlyphWidthRatio)))
      lineLimit = max(1, min(maxLines, int(maxHeight.float / (size.float * LineHeightRatio))))
      lines = wrapTitle(words, width)
    result = TitleLayout(fontSize: size, lines: lines)
    if lines.len <= lineLimit:
      return
    if size == sizes[^1]:
      result.lines.setLen(lineLimit)
      var last = result.lines[^1]
      if last.runeLen >= width:
        last = last.runeSubStr(0, width - 1)
      result.lines[^1] = last & Ellipsis

proc escapeFilterValue*(value: string): string =
  ## Escape a value for a filter option and then for the filtergraph parser.
  var option = ""
  for character in value:
    if character in {'\\', '\'', ':'}:
      option.add('\\')
    option.add(character)
  for character in option:
    if character in {'\\', '\'', '[', ']', ',', ';'}:
      result.add('\\')
    result.add(character)

proc deckEntry(menu: JsonNode, key: int): tuple[entry: JsonNode, position: int] =
  ## Find a deck entry by key, returning nil when the slot is absent.
  result = (nil, -1)
  let deck = menu{"deck"}
  if deck.isNil:
    return
  for position, entry in deck.getElems():
    if entry{"key"}.getInt() == key:
      return (entry, position)

proc planButtonMedia*(config: JsonNode): seq[MenuPlan] =
  ## Decide how every Deck key of every menu is presented, without I/O.
  let root = config{"root"}.getStr()
  for menuIndex, menu in config{"menus"}.getElems():
    var plan = MenuPlan(id: menu{"id"}.getStr())
    for key in 1..DeckKeyCount:
      let
        (entry, position) = deckEntry(menu, key)
        field = "menus[" & $menuIndex & "].deck[" & $position & "]"
        isBack = plan.id != root and key == 1
      if entry.isNil:
        plan.keys.add(KeyPlan(key: key, kind: TitleKey,
          title: if isBack: BackTitle else: ""))
        continue
      let
        visual = entry{"visual"}
        image = if visual.isNil: "" else: visual{"image"}.getStr()
        builtin = if visual.isNil: 0 else: visual{"builtinNumber"}.getInt(0)
        showTitle = if visual.isNil or visual{"showTitle"}.isNil: image.len == 0
          else: visual{"showTitle"}.getBool()
      var title = entry{"title"}.getStr()
      if isBack and title.len == 0:
        title = BackTitle
      if not showTitle:
        title = ""
      var keyPlan =
        if builtin > 0:
          KeyPlan(key: key, field: field, kind: BuiltinKey, builtinNumber: builtin)
        elif image.len > 0:
          if not isManagedAsset(image):
            raiseMedia(field & ".visual.image", "Image must be a managed assets/ path.")
          KeyPlan(key: key, field: field, kind: ArtworkKey, title: title, image: image)
        else:
          KeyPlan(key: key, field: field, kind: TitleKey, title: title)
      let
        action = entry{"action"}
        kind = action{"kind"}.getStr()
      if kind == "obs":
        keyPlan.obsOperation = action{"operation"}.getStr()
      elif kind.isControlAction():
        keyPlan.controlAction = kind
      if keyPlan.obsOperation.len > 0 or keyPlan.controlAction.len > 0:
        let states = if visual.isNil: nil else: visual{"states"}
        for state in VisualStates:
          if not states.isNil and states.hasKey(state):
            let stateImage = states[state].getStr()
            if not isManagedAsset(stateImage):
              raiseMedia(field & ".visual.states." & state,
                "State image must be a managed assets/ path.")
            keyPlan.states.add(StatePlan(state: state, image: stateImage))
      plan.keys.add(keyPlan)
    result.add(plan)

proc runTool*(args: seq[string], timeoutMs = ChildTimeoutMs,
    maxStdout = MaxChildStdoutBytes, maxStderr = MaxChildStderrBytes): string =
  ## Run a command without a shell and return its stdout. Stderr is kept
  ## separately for the error message. The child is killed when it exceeds
  ## timeoutMs, the remaining operation deadline or either output cap; both
  ## timeouts raise MediaTimeoutError. Completion is decided by process exit
  ## rather than pipe EOF, because pipes may be inherited by unrelated
  ## children spawned on other daemon threads.
  checkOperationDeadline()
  let
    started = getMonoTime()
    childDeadline = started + initDuration(milliseconds = timeoutMs)
    operationBound = hasOperationDeadline() and operationDeadline < childDeadline
    deadline = if operationBound: operationDeadline else: childDeadline
    process = spawnCommand(args[0], args[1..^1], options = {poUsePath})
    handles = [process.outputHandle.cint, process.errorHandle.cint]
    limits = [maxStdout, maxStderr]
  var
    captured: array[2, string]
    buffer: array[8192, char]
    exitCode = -1
    failure = ""
    timedOut = false
  process.inputStream.close()
  try:
    for handle in handles:
      let flags = fcntl(handle, F_GETFL, 0)
      if flags < 0 or fcntl(handle, F_SETFL, flags or O_NONBLOCK) < 0:
        raiseOSError(osLastError())
    while failure.len == 0 and not timedOut:
      let exited = peekExitCode(process)
      for pipe, handle in handles:
        while failure.len == 0:
          let size = posix.read(handle, addr buffer[0], buffer.len)
          if size <= 0:
            if size < 0 and errno != EAGAIN and errno != EINTR:
              raiseOSError(osLastError())
            break
          let start = captured[pipe].len
          captured[pipe].setLen(start + int(size))
          copyMem(addr captured[pipe][start], addr buffer[0], int(size))
          if captured[pipe].len > limits[pipe]:
            failure = args[0] & ": " & (if pipe == 0: "stdout" else: "stderr") &
              " exceeded " & $limits[pipe] & " bytes."
      if exited != -1:
        exitCode = exited
        break
      if getMonoTime() >= deadline:
        timedOut = true
      else:
        let waitMs = min(ChildPollMs, max(1, inMilliseconds(deadline - getMonoTime()).int))
        var pollers = [TPollfd(fd: handles[0], events: POLLIN),
          TPollfd(fd: handles[1], events: POLLIN)]
        discard posix.poll(addr pollers[0], 2, waitMs.cint)
  finally:
    if peekExitCode(process) == -1:
      kill(process)
      discard waitForExit(process)
    close(process)
  if failure.len > 0:
    raise newException(IOError, failure)
  if timedOut:
    if operationBound:
      raiseOperationTimeout(args[0] & ": ")
    raise newException(MediaTimeoutError, args[0] & ": timed out after " &
      $timeoutMs & " ms.")
  if exitCode != 0:
    raise newException(OSError, args[0] & " exited with " & $exitCode & ": " &
      captured[1].strip())
  result = move(captured[0])

proc probeSource*(path: string, kind: SourceKind, field = ""): SourceInfo =
  ## Probe a source file's first video stream with a forced demuxer.
  let output = runTool(@["ffprobe", "-v", "error", "-threads", "1",
    "-f", demuxerName(kind), "-select_streams", "v:0",
    "-show_entries", "stream=codec_name,width,height", "-of", "json",
    "file:" & path])
  result = parseStreamProbe(kind, output, field)

proc probeDurations*(path: string, field = ""): seq[int] =
  ## Read GIF frame delays from packets without decoding pixels. Reading stops
  ## one packet past the frame limit so oversized animations fail quickly.
  let output = runTool(@["ffprobe", "-v", "error", "-threads", "1",
    "-f", "gif", "-select_streams", "v:0", "-read_intervals",
    "%+#" & $(MaxSourceFrames + 1), "-show_entries",
    "stream=time_base:packet=pts,duration", "-of", "json", "file:" & path])
  result = parsePacketDurations(output, field)

proc decodeSource(path: string, kind: SourceKind, field: string) =
  ## Decode every frame once, failing on the first decoder error. Header
  ## probes alone accept truncated or mislabelled files.
  try:
    discard runTool(@["ffmpeg", "-nostdin", "-hide_banner", "-v", "error",
      "-threads", "1", "-xerror", "-f", demuxerName(kind), "-i", "file:" & path,
      "-map", "0:v:0", "-f", "null", "-"])
  except OSError as error:
    # Decoder failures describe the user's file, so they are rejections.
    raiseMedia(field, "The image could not be decoded: " & error.msg)

proc validateSource(path: string, kind: SourceKind, field: string):
    tuple[info: SourceInfo, frameCount: int, timings: seq[FrameTiming]] =
  ## Check dimensions, GIF frame limits and timing, then decode every frame.
  ## The cheap header and packet checks run before any pixels are decoded.
  result.info = probeSource(path, kind, field)
  if kind == GifSource:
    let durations = probeDurations(path, field)
    result.frameCount = durations.len
    result.timings = selectFrames(durations, field)
  else:
    result.frameCount = 1
    result.timings = @[FrameTiming(index: 0, durationMs: 0)]
  decodeSource(path, kind, field)

proc newWorkDirectory(parent, label: string): string =
  ## Create a private work directory that is published or removed later.
  createDir(parent)
  result = parent / WorkPrefix & label & "-" & $getCurrentProcessId() & "-" &
    $getMonoTime().ticks
  createDir(result)

proc removeStaleWork(directory: string) =
  ## Remove abandoned work directories left by interrupted preparations.
  if not dirExists(directory):
    return
  let cutoff = getTime() - initDuration(seconds = StaleWorkSeconds)
  for kind, path in walkDir(directory):
    checkOperationDeadline()
    if kind == pcDir and path.extractFilename.startsWith(WorkPrefix) and
        getLastModificationTime(path) < cutoff:
      removeDir(path)

proc readSource(path, field: string): string =
  ## Read a bounded regular source file.
  checkOperationDeadline()
  if not fileExists(path):
    raiseMedia(field, "Image file does not exist: " & path)
  let size = getFileSize(path)
  if size > MaxSourceBytes:
    raiseMedia(field, "The image is " & $size & " bytes; the limit is " &
      $MaxSourceBytes & " bytes.")
  result = readFile(path)
  if result.len > MaxSourceBytes:
    raiseMedia(field, "The image exceeds " & $MaxSourceBytes & " bytes.")

proc importButtonAsset*(source, configDir: string,
    timeoutMs = OperationTimeoutMs): string =
  ## Validate a PNG, JPEG or GIF and copy it to configDir/assets/<sha1>.<ext>.
  ## Returns the managed relative path. Existing identical assets are reused.
  ## The whole import, including every child process, shares one timeoutMs
  ## deadline and raises MediaTimeoutError when it runs out.
  const Field = "source"
  withOperationDeadline(timeoutMs):
    let
      data = readSource(source, Field)
      kind = sourceKindFromBytes(data, Field)
      name = contentKey(data) & "." & $kind
      assetDir = configDir / "assets"
      destination = assetDir / name
    result = AssetPrefix & name
    if not fileExists(destination) or contentKey(readFile(destination)) != contentKey(data):
      let work = newWorkDirectory(assetDir, "import")
      try:
        let copy = work / SourceStem & $kind
        writeFile(copy, data)
        discard validateSource(copy, kind, Field)
        checkOperationDeadline()
        moveFile(copy, destination)
      finally:
        removeDir(work)

proc titleFilter(layout: TitleLayout, titlePath, fontPath, color: string,
    overlay: bool): string =
  ## Build a drawtext filter reading the title from a file, never inline.
  if layout.lines.len == 0:
    return ""
  result = ",drawtext=fontfile=" & escapeFilterValue(fontPath) &
    ":textfile=" & escapeFilterValue(titlePath) & ":expansion=none" &
    ":fontsize=" & $layout.fontSize & ":fontcolor=" & color & ":text_align=C" &
    ":x=(w-tw)/2"
  if overlay:
    result.add(":box=1:boxcolor=" & TitleBox & ":boxborderw=2:y=h-th-" & $TitleMargin)
  else:
    result.add(":y=(h-th)/2")

proc containFilter(info: SourceInfo): string =
  ## Composite onto black and fit the image proportionally inside the key.
  let
    size = containSize(info.width, info.height)
    scaler = if max(info.width, info.height) < KeySize: "neighbor" else: "area"
  result = "format=gbrap,premultiply=inplace=1,scale=" & $size.width & ":" &
    $size.height & ":flags=" & scaler & ",pad=" & $KeySize & ":" & $KeySize &
    ":(ow-iw)/2:(oh-ih)/2:color=black,format=rgb24"

proc ffmpegArgs(input: seq[string], filter: string, output: seq[string]): seq[string] =
  ## Assemble a single-threaded, quiet FFmpeg invocation.
  result = @["ffmpeg", "-nostdin", "-hide_banner", "-v", "error", "-y",
    "-threads", "1", "-filter_threads", "1", "-xerror"]
  result.add(input)
  result.add(@["-vf", filter & ",hflip,vflip,format=yuvj420p"])
  result.add(@EncoderArgs)
  result.add(output)

proc colorInput(color: string): seq[string] =
  ## Return a one-frame solid-colour lavfi input of key size.
  @["-f", "lavfi", "-i", "color=c=" & color & ":s=" & $KeySize & "x" & $KeySize & ":r=1"]

proc writeFrames(work: string, normal: seq[FrameTiming]) =
  ## Record displayed frame files and durations for a published entry.
  var frames = newJArray()
  for frame in normal:
    frames.add(%*{"file": "normal-" & align($(frame.index + 1), 4, '0') & ".jpg",
      "durationMs": frame.durationMs})
  writeFile(work / FramesFile, $(%*{"version": 1, "normal": frames,
    "pressed": PressedFile}))

proc loadPrepared(directory: string): PreparedKey =
  ## Load a published entry, raising IOError if any file is missing.
  let metaPath = directory / FramesFile
  if not fileExists(metaPath):
    raise newException(IOError, "Prepared entry is incomplete: " & directory)
  let meta = parseJson(readFile(metaPath))
  for frame in meta{"normal"}.getElems():
    let path = directory / frame{"file"}.getStr()
    if not fileExists(path):
      raise newException(IOError, "Prepared frame is missing: " & path)
    result.normal.add(PreparedFrame(path: path, durationMs: frame{"durationMs"}.getInt()))
  result.pressed = directory / meta{"pressed"}.getStr()
  if result.normal.len == 0 or not fileExists(result.pressed):
    raise newException(IOError, "Prepared entry is incomplete: " & directory)

proc isPrepared(directory: string): bool =
  ## Report whether a published entry exists with all of its files.
  let metaPath = directory / FramesFile
  if not fileExists(metaPath):
    return false
  let meta = parseJson(readFile(metaPath))
  result = meta{"normal"}.len > 0 and fileExists(directory / meta{"pressed"}.getStr())
  for frame in meta{"normal"}.getElems():
    if not fileExists(directory / frame{"file"}.getStr()):
      result = false

proc publish(work, destination: string) =
  ## Atomically rename a finished work directory into place. A concurrent
  ## identical entry wins; a damaged one is moved aside (it is already
  ## unusable) and replaced.
  if renameFile(work.cstring, destination.cstring) == 0:
    return
  let renameError = osLastError()
  if not dirExists(destination):
    raiseOSError(renameError)
  if isPrepared(destination):
    removeDir(work)
  else:
    let stale = destination.parentDir / WorkPrefix & "stale-" &
      destination.extractFilename & "-" & $getMonoTime().ticks
    if renameFile(destination.cstring, stale.cstring) != 0:
      raiseOSError(osLastError())
    if renameFile(work.cstring, destination.cstring) != 0:
      raiseOSError(osLastError())

proc renderKey(plan: KeyPlan, work, fontPath, sourceData: string) =
  ## Render normal frames, the pressed frame and frames.json into work.
  let
    font = absolutePath(fontPath)
    titlePath = work / TitleFile
    # The image2 muxer expands % sequences in the whole output path.
    pattern = work.replace("%", "%%") / NormalPattern
    normalOutput = @["-fps_mode", "passthrough", pattern]
    pressedOutput = @["-frames:v", "1", "-update", "1", work / PressedFile]
  if plan.kind == TitleKey:
    let
      layout = layoutTitle(plan.title, TitleSizes, KeySize - 2 * TitleMargin,
        KeySize - 2 * TitleMargin, TitleSizes.len)
      normalFilter = "format=rgb24" & titleFilter(layout, titlePath, font, "white", false)
      pressedFilter = "format=rgb24" & titleFilter(layout, titlePath, font, "black", false)
    writeFile(titlePath, layout.lines.join("\n"))
    discard runTool(ffmpegArgs(colorInput(NormalBackground), normalFilter,
      @["-frames:v", "1", pattern]))
    discard runTool(ffmpegArgs(colorInput(PressedBackground), pressedFilter,
      pressedOutput))
    writeFrames(work, @[FrameTiming(index: 0, durationMs: 0)])
  else:
    let
      field = plan.field & ".visual.image"
      kind = sourceKindFromBytes(sourceData, field)
      sourcePath = work / SourceStem & $kind
    writeFile(sourcePath, sourceData)
    let
      (info, frameCount, timings) = validateSource(sourcePath, kind, field)
      layout = layoutTitle(plan.title, OverlaySizes, KeySize - 2 * TitleMargin,
        KeySize div 2, OverlayMaxLines)
      overlay = titleFilter(layout, titlePath, font, "white", true)
      input = @["-f", demuxerName(kind), "-i", "file:" & sourcePath]
      normalFilter = containFilter(info) & overlay
      pressedFilter = containFilter(info) & ",drawbox=x=0:y=0:w=iw:h=ih:color=" &
        PressedOverlay & ":t=fill" & overlay
    writeFile(titlePath, layout.lines.join("\n"))
    if kind == GifSource:
      discard runTool(ffmpegArgs(input, normalFilter, normalOutput))
      var produced = 0
      for entryKind, path in walkDir(work):
        if path.extractFilename.startsWith("normal-"):
          inc produced
      if produced != frameCount:
        raise newException(IOError, "FFmpeg decoded " & $produced & " of " &
          $frameCount & " frames for " & field & ".")
      var kept = initHashSet[int]()
      for timing in timings:
        kept.incl(timing.index)
      for index in 0..<produced:
        if index notin kept:
          removeFile(work / "normal-" & align($(index + 1), 4, '0') & ".jpg")
    else:
      discard runTool(ffmpegArgs(input, normalFilter,
        @["-frames:v", "1", pattern]))
    discard runTool(ffmpegArgs(input, pressedFilter, pressedOutput))
    removeFile(sourcePath)
    writeFrames(work, timings)
  removeFile(titlePath)

proc prepareKey(plan: KeyPlan, configDir, cacheDir, fontPath,
    fontKey: string): PreparedKey =
  ## Return a cached rendering of a key, rendering and publishing it if needed.
  ## Reused entries get a fresh modification time so cache cleanup treats them
  ## as recently used.
  checkOperationDeadline()
  var
    sourceData = ""
    sourceKey = ""
  if plan.kind == ArtworkKey:
    sourceData = readSource(configDir / plan.image, plan.field & ".visual.image")
    sourceKey = contentKey(sourceData)
  let
    key = contentKey([MediaHelperVersion, RenderSettings, $plan.kind, sourceKey,
      fontKey, cleanTitle(plan.title)].join("\x00"))
    destination = cacheDir / key
  if not isPrepared(destination):
    let work = newWorkDirectory(cacheDir, key)
    try:
      renderKey(plan, work, fontPath, sourceData)
      publish(work, destination)
    except CatchableError:
      # The unpublished work directory must not survive a failed render.
      removeDir(work)
      raise
  else:
    setLastModificationTime(destination, getTime())
  result = loadPrepared(destination)

proc prepareButtonMedia*(config: JsonNode, configDir, cacheDir,
    fontPath: string, timeoutMs = OperationTimeoutMs,
    maxPreparedBytes = MaxPreparedBytes): JsonNode =
  ## Render every non-builtin Deck key of every menu and return the manifest
  ## {"version":1,"menus":{id:{"1".."15": entry}}}. Entries are either
  ## {"builtinNumber":n} or {"normal":[{"path","durationMs"}],"pressed":path}
  ## with absolute JPEG paths under cacheDir. OBS-bound entries add
  ## "obsOperation" and control-bound entries add "controlAction" naming the
  ## exact action kind; both add, for mapped visual states, "states":{state:{normal,
  ## pressed}}. Every variant counts toward maxPreparedBytes. The whole
  ## preparation, including every child process, shares one timeoutMs deadline and raises
  ## MediaTimeoutError when it runs out. Preparation never deletes published
  ## cache entries, so files referenced by the running config stay valid.
  withOperationDeadline(timeoutMs):
    let
      plans = planButtonMedia(config)
      cache = absolutePath(cacheDir)
    var
      fontKey = ""
      menus = newJObject()
      counted = initHashSet[string]()
      totalBytes = 0
    removeStaleWork(cache)
    proc prepared(keyPlan: KeyPlan): JsonNode =
      ## Render or reuse one visual, count its new files toward the budget, and
      ## return its {normal, pressed} manifest object.
      if fontKey.len == 0:
        if not fileExists(fontPath):
          raise newException(IOError, "Title font does not exist: " & fontPath)
        fontKey = contentKey(readFile(fontPath))
      let prepared = prepareKey(keyPlan, configDir, cache, fontPath, fontKey)
      var normal = newJArray()
      for frame in prepared.normal:
        normal.add(%*{"path": frame.path, "durationMs": frame.durationMs})
      for path in prepared.normal.mapIt(it.path) & @[prepared.pressed]:
        if path notin counted:
          counted.incl(path)
          totalBytes += getFileSize(path).int
      if totalBytes > maxPreparedBytes:
        raiseMedia(keyPlan.field, "Prepared media exceeds " & $maxPreparedBytes &
          " bytes in total.")
      result = %*{"normal": normal, "pressed": prepared.pressed}

    for plan in plans:
      var keys = newJObject()
      for keyPlan in plan.keys:
        var entry = if keyPlan.kind == BuiltinKey: %*{"builtinNumber": keyPlan.builtinNumber}
          else: prepared(keyPlan)
        if keyPlan.obsOperation.len > 0:
          entry["obsOperation"] = %keyPlan.obsOperation
        elif keyPlan.controlAction.len > 0:
          entry["controlAction"] = %keyPlan.controlAction
        if keyPlan.obsOperation.len > 0 or keyPlan.controlAction.len > 0:
          if keyPlan.states.len > 0:
            var states = newJObject()
            for statePlan in keyPlan.states:
              # Variants reuse the base title so overlays stay consistent.
              let title = if keyPlan.kind == BuiltinKey: "" else: keyPlan.title
              states[statePlan.state] = prepared(KeyPlan(key: keyPlan.key,
                field: keyPlan.field & ".visual.states." & statePlan.state,
                kind: ArtworkKey, title: title, image: statePlan.image))
            entry["states"] = states
        keys[$keyPlan.key] = entry
      menus[plan.id] = keys
    result = %*{"version": ManifestVersion, "menus": menus}

proc isContentKeyName*(name: string): bool =
  ## Report whether a name is a 40-character lowercase hex content key.
  result = name.len == ContentKeyLength and name.allIt(it in HexDigits - {'A'..'F'})

proc collectContentKeys(node: JsonNode, keys: var HashSet[string]) =
  ## Add every content key appearing as a path component of any string.
  case node.kind
  of JString:
    for component in node.getStr().split('/'):
      if isContentKeyName(component):
        keys.incl(component)
  of JArray:
    for item in node.getElems():
      collectContentKeys(item, keys)
  of JObject:
    for name, item in node.pairs:
      collectContentKeys(item, keys)
  else:
    discard

proc manifestContentKeys*(manifest: JsonNode): HashSet[string] =
  ## Return the prepared cache keys referenced anywhere in a JSON document.
  ## Any string path component that is a content key counts, so manifests
  ## wrapped in other JSON objects are protected too.
  result = initHashSet[string]()
  collectContentKeys(manifest, result)

proc cleanPreparedCache*(cacheDir, manifestDir: string): PreparedCleanup =
  ## Delete unreferenced prepared entries after a successful apply or preview.
  ## Every *.json file directly in manifestDir is a retained manifest; all
  ## content keys they reference are kept. Only real directories in cacheDir
  ## named by a content key, unreferenced and unmodified for
  ## PreparedGraceSeconds are removed; symlinks, files, work directories and
  ## other names are ignored. Raises before deleting anything when manifestDir
  ## is missing, holds no manifest or holds unreadable JSON. Failures removing
  ## individual entries are collected in errors while the rest continue. Call
  ## it from the worker that serializes preparations.
  if not dirExists(manifestDir):
    raise newException(IOError, "Manifest directory does not exist: " & manifestDir)
  var keys = initHashSet[string]()
  for kind, path in walkDir(manifestDir):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".json"):
      collectContentKeys(parseFile(path), keys)
      inc result.manifests
  if result.manifests == 0:
    raise newException(IOError, "No retained manifests in " & manifestDir &
      "; refusing to clean the prepared cache.")
  result.protectedKeys = keys.len
  if not dirExists(cacheDir):
    return
  let cutoff = getTime() - initDuration(seconds = PreparedGraceSeconds)
  for kind, path in walkDir(cacheDir):
    let name = path.extractFilename
    if kind != pcDir or not isContentKeyName(name) or name in keys:
      continue
    try:
      if getLastModificationTime(path) < cutoff:
        # Renaming first means readers never see a half-deleted entry; a
        # leftover work directory is removed by a later preparation.
        let doomed = cacheDir / WorkPrefix & "delete-" & name & "-" &
          $getCurrentProcessId() & "-" & $getMonoTime().ticks
        if renameFile(path.cstring, doomed.cstring) != 0:
          raiseOSError(osLastError(), path)
        result.removed.add(path)
        removeDir(doomed)
    except OSError as error:
      result.errors.add(path & ": " & error.msg)
