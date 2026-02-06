import
  std/[os, osproc, strformat, strutils, tables]

type
  AudioOutputStream* = object
    id*: string
    appName*: string
    sinkId*: string
    sinkName*: string
    volume*: string

proc audioOutputsUsage*(): string =
  ## Return usage text for the audio outputs demo.
  result = "Usage: nim r examples/audio_outputs.nim"

proc ensureToolInstalled(toolName: string) =
  ## Ensure an external command-line tool is available on PATH.
  if findExe(toolName).len == 0:
    raise newException(OSError, fmt"Required tool '{toolName}' was not found on PATH.")

proc afterColon(text: string): string =
  ## Return the text after the first ':' character.
  let index = text.find(':')
  if index >= 0 and index + 1 < text.len:
    result = text[index + 1..^1].strip()

proc afterEquals(text: string): string =
  ## Return the text after the first '=' character.
  let index = text.find('=')
  if index >= 0 and index + 1 < text.len:
    result = text[index + 1..^1].strip()

proc extractPercent(text: string): string =
  ## Extract the first percentage token from a line of text.
  for token in text.splitWhitespace():
    let normalized = token.strip(chars = {',', ';'})
    if normalized.endsWith("%"):
      result = normalized
      break

proc parseSinkNames(output: string): Table[string, string] =
  ## Parse sink index to sink-name mapping from `pactl list short sinks`.
  for line in output.splitLines():
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    let columns = stripped.split('\t')
    if columns.len >= 2:
      result[columns[0]] = columns[1]

proc listAudioOutputStreams*(): seq[AudioOutputStream] =
  ## List currently active sink-input streams and their volume levels.
  ensureToolInstalled("pactl")
  let sinksRaw = execProcess(
    "pactl",
    args = @["list", "short", "sinks"],
    options = {poUsePath, poStdErrToStdOut}
  )
  let sinkNames = parseSinkNames(sinksRaw)
  let inputsRaw = execProcess(
    "pactl",
    args = @["list", "sink-inputs"],
    options = {poUsePath, poStdErrToStdOut}
  )

  var current = AudioOutputStream()
  for line in inputsRaw.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("Sink Input #"):
      if current.id.len > 0:
        if current.appName.len == 0:
          current.appName = "Unknown app"
        if current.volume.len == 0:
          current.volume = "Unknown"
        result.add(current)
      current = AudioOutputStream()
      current.id = stripped["Sink Input #".len..^1].strip()
    elif current.id.len > 0 and stripped.startsWith("Sink:"):
      current.sinkId = afterColon(stripped)
      if current.sinkId in sinkNames:
        current.sinkName = sinkNames[current.sinkId]
    elif current.id.len > 0 and stripped.startsWith("Volume:") and current.volume.len == 0:
      current.volume = extractPercent(stripped)
    elif current.id.len > 0 and stripped.startsWith("application.name ="):
      let rawName = afterEquals(stripped)
      current.appName = rawName.strip(chars = {'"'})
    elif current.id.len > 0 and current.appName.len == 0 and stripped.startsWith("media.name ="):
      let rawName = afterEquals(stripped)
      current.appName = rawName.strip(chars = {'"'})
    elif current.id.len > 0 and current.appName.len == 0 and stripped.startsWith("application.process.binary ="):
      let rawName = afterEquals(stripped)
      current.appName = rawName.strip(chars = {'"'})

  if current.id.len > 0:
    if current.appName.len == 0:
      current.appName = "Unknown app"
    if current.volume.len == 0:
      current.volume = "Unknown"
    result.add(current)

proc printAudioOutputStreams*() =
  ## Print active audio output streams in a readable format.
  let streams = listAudioOutputStreams()
  if streams.len == 0:
    echo "No active audio output streams found."
    return

  for stream in streams:
    let sinkLabel = if stream.sinkName.len > 0: stream.sinkName else: stream.sinkId
    echo fmt"[{stream.id}] {stream.appName} | volume={stream.volume} | sink={sinkLabel}"
