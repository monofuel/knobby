import
  std/[json, strutils],
  ./bindings

type
  AudioLevel* = object
    name*: string
    channels*: seq[string]
    muted*: bool
    appName*, mediaRole*, processId*: string
  AudioStatus* = object
    master*: AudioLevel
    streams*, microphones*: seq[AudioLevel]

proc parseLevel(node: JsonNode): AudioLevel =
  ## Preserve individual channel levels instead of averaging distinct outputs.
  result.name = node{"description"}.getStr(node{"name"}.getStr())
  result.muted = node{"mute"}.getBool()
  let properties = node{"properties"}
  if not properties.isNil:
    result.appName = properties{"application.name"}.getStr(properties{"media.name"}.getStr("Unknown app"))
    result.mediaRole = properties{"media.role"}.getStr()
    result.processId = properties{"application.process.id"}.getStr()
  let volume = node{"volume"}
  if not volume.isNil:
    for channel, level in volume:
      result.channels.add(channel & " " & level{"value_percent"}.getStr("Unknown"))

proc parseAudioStatus*(data, defaultSink: string): AudioStatus =
  ## Decode pactl's full JSON list and the independently queried default sink.
  let root = parseJson(data)
  for sink in root["sinks"]:
    if sink["name"].getStr() == defaultSink.strip():
      result.master = parseLevel(sink)
  for stream in root["sink_inputs"]:
    result.streams.add(parseLevel(stream))
  for source in root["sources"]:
    if not source["name"].getStr().endsWith(".monitor"):
      result.microphones.add(parseLevel(source))

proc matchesFader*(level: AudioLevel, controller: int, steamGame: bool): bool =
  ## Use the dispatcher's matching rules for a displayed application stream.
  for (cc, _, names, games) in AppFaderBindings:
    if cc == controller:
      return matchesAudioTarget(level.appName, level.mediaRole, steamGame, names, games)

proc levelText*(level: AudioLevel): string =
  ## Format observable channel volumes and mute state for a read-only label.
  if level.name.len == 0 and level.channels.len == 0:
    return "Unavailable"
  result = level.channels.join(" / ")
  if result.len == 0:
    result = "Volume unavailable"
  if level.muted:
    result.add(" (muted)")
