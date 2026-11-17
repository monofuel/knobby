import
  std/[json, os]

type
  FaderPositions* = array[4, int]
  FaderCacheWriter* = object
    path: string
    saved: FaderPositions
    nextAttemptMs: int64

const
  UnknownFaders*: FaderPositions = [-1, -1, -1, -1]
  FaderCacheVersion = 1
  FaderSaveIntervalMs* = 2000'i64

proc faderCachePath*(): string =
  ## Locate the display cache in persistent user state, outside systemd runtime directories.
  let stateDirectory = getEnv("XDG_STATE_HOME", getHomeDir() / ".local/state")
  (if stateDirectory.len == 0: getHomeDir() / ".local/state" else: stateDirectory) /
    "knobby/faders.json"

proc validatePositions(positions: FaderPositions) =
  ## Reject positions that cannot be represented by the mixer protocol.
  for value in positions:
    if value notin -1..127:
      raise newException(ValueError, "Invalid cached MIDI fader position: " & $value)

proc decodeFaderCache*(data: string): FaderPositions =
  ## Decode only a supported cache with exactly four integer MIDI values.
  let node = parseJson(data)
  if node.kind != JObject or not node.hasKey("version") or
      node["version"].kind != JInt or node["version"].getInt() != FaderCacheVersion or
      not node.hasKey("faders") or node["faders"].kind != JArray or node["faders"].len != 4:
    raise newException(ValueError, "Invalid or unsupported fader cache.")
  for index in 0..<result.len:
    let value = node["faders"][index]
    if value.kind != JInt or value.getBiggestInt() notin -1'i64..127'i64:
      raise newException(ValueError, "Invalid cached MIDI fader position.")
    result[index] = value.getInt()

proc loadFaderCache*(path: string): FaderPositions =
  ## Return unknown positions for an absent cache and propagate malformed or unreadable files.
  if not fileExists(path) and not dirExists(path):
    return UnknownFaders
  decodeFaderCache(readFile(path))

proc writeFaderCache*(path: string, positions: FaderPositions) =
  ## Atomically replace the cache using a closed temporary file on the same filesystem.
  validatePositions(positions)
  let
    temporary = path & ".tmp"
    content = $(%*{"version": FaderCacheVersion, "faders": positions})
  createDir(path.parentDir())
  writeFile(temporary, content)
  moveFile(temporary, path)

proc newFaderCacheWriter*(path: string, saved: FaderPositions,
    timeMs: int64): FaderCacheWriter =
  ## Start a writer with a known saved baseline and a monotonic write deadline.
  FaderCacheWriter(path: path, saved: saved, nextAttemptMs: timeMs + FaderSaveIntervalMs)

proc flush*(writer: var FaderCacheWriter, positions: FaderPositions,
    timeMs: int64, force = false) =
  ## Save changed positions at most once per interval, except for a final forced flush.
  if positions == writer.saved or (not force and timeMs < writer.nextAttemptMs):
    return
  writer.nextAttemptMs = timeMs + FaderSaveIntervalMs
  writeFaderCache(writer.path, positions)
  writer.saved = positions
