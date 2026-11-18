import
  std/[json, strutils]

type
  MinecraftAudioError* = object of CatchableError
  AppStream* = object
    id*, clientId*, processId*: int
    name*, appName*, binary*: string
  AppClient* = object
    id*: int
    appName*, binary*: string
  AppAudioGraph* = object
    streams*: seq[AppStream]
    clients*: seq[AppClient]

const
  MinecraftAudioTarget* = "knobby-minecraft"
  MinecraftLaunchVariable* = "PULSE_PROP_OVERRIDE_application.name"
  MinecraftLaunchEnvironment* = MinecraftLaunchVariable & "=" &
    MinecraftAudioTarget
  # Selections the OBS application capture would also match for unrelated
  # Java programs, now or when they start later.
  GenericJavaNames = ["java", "javaw", ".java-wrapped", "java-wrapped"]
  NodeType = "PipeWire:Interface:Node"
  ClientType = "PipeWire:Interface:Client"
  OutputStreamClass = "Stream/Output/Audio"
  NodeNameKey = "node.name"
  MediaClassKey = "media.class"
  AppNameKey = "application.name"
  BinaryKey = "application.process.binary"
  ProcessIdKey = "application.process.id"
  ClientIdKey = "client.id"

proc propertyText(properties: JsonNode, key: string): string =
  ## Read a PipeWire property as text, accepting numeric JSON values.
  let value = properties{key}
  if value.isNil:
    result = ""
  elif value.kind == JString:
    result = value.getStr()
  elif value.kind == JInt:
    result = $value.getInt()
  else:
    result = ""

proc propertyId(properties: JsonNode, key: string): int =
  ## Read a PipeWire numeric property, using zero when it is absent.
  let text = properties.propertyText(key)
  result = if text.len == 0: 0 else: parseInt(text)

proc parseAppAudioGraph*(pwDump: string): AppAudioGraph =
  ## Parse pw-dump JSON into the output streams and clients OBS can target.
  for item in parseJson(pwDump):
    let properties = item{"info", "props"}
    if properties.isNil:
      continue
    let kind = item{"type"}.getStr()
    if kind == NodeType and
        properties.propertyText(MediaClassKey) == OutputStreamClass and
        properties.propertyText(NodeNameKey).len > 0:
      var stream = AppStream(
        id: item["id"].getInt(),
        clientId: properties.propertyId(ClientIdKey),
        processId: properties.propertyId(ProcessIdKey),
        name: properties.propertyText(NodeNameKey),
        appName: properties.propertyText(AppNameKey),
        binary: properties.propertyText(BinaryKey))
      if stream.appName.len == 0:
        stream.appName = stream.name
      result.streams.add(stream)
    elif kind == ClientType:
      result.clients.add(AppClient(
        id: item["id"].getInt(),
        appName: properties.propertyText(AppNameKey),
        binary: properties.propertyText(BinaryKey)))

proc sameName(selection, field: string): bool =
  ## Compare names as OBS does, where an absent field never matches.
  result = field.len > 0 and cmpIgnoreCase(selection, field) == 0

proc isTargeted*(graph: AppAudioGraph, stream: AppStream,
    selection: string): bool =
  ## Report whether OBS application capture with this TargetName links the stream.
  result = selection.sameName(stream.binary) or
    selection.sameName(stream.appName) or selection.sameName(stream.name)
  if not result and stream.clientId != 0:
    for client in graph.clients:
      if client.id == stream.clientId:
        result = selection.sameName(client.binary) or
          selection.sameName(client.appName)
        break

proc targetedStreams*(graph: AppAudioGraph,
    selection: string): seq[AppStream] =
  ## List every output stream the TargetName selection captures.
  for stream in graph.streams:
    if graph.isTargeted(stream, selection):
      result.add(stream)

proc hasMinecraftLaunchEnvironment*(environ: string): bool =
  ## Report whether NUL-separated process environment data labels Minecraft audio.
  result = MinecraftLaunchEnvironment in environ.split('\0')

proc verifyMinecraftAudioTarget*(graph: AppAudioGraph, minecraftPid: int,
    selection = MinecraftAudioTarget): seq[AppStream] =
  ## Return Minecraft's streams when the selection captures exactly all of them.
  ## Raise when it would miss Minecraft or include any other process.
  if minecraftPid <= 0:
    raise newException(MinecraftAudioError, "Minecraft is not running.")
  if selection.strip().len == 0:
    raise newException(MinecraftAudioError,
      "Minecraft audio has no target name.")
  for genericName in GenericJavaNames:
    if cmpIgnoreCase(selection, genericName) == 0:
      raise newException(MinecraftAudioError,
        "Target " & selection & " would capture every Java program.")
  for stream in graph.streams:
    let targeted = graph.isTargeted(stream, selection)
    if targeted and stream.processId != minecraftPid:
      raise newException(MinecraftAudioError,
        "Target " & selection & " also captures " & stream.appName &
        " (PID " & $stream.processId & ").")
    if stream.processId == minecraftPid and not targeted:
      raise newException(MinecraftAudioError,
        "Minecraft audio is not labeled " & selection & "; launch it with " &
        MinecraftLaunchEnvironment & ".")
    if targeted:
      result.add(stream)
  if result.len == 0:
    raise newException(MinecraftAudioError,
      "Minecraft (PID " & $minecraftPid & ") has no audio stream labeled " &
      selection & "; launch it with " & MinecraftLaunchEnvironment & ".")
