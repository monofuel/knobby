import
  std/[json, os, strutils]

type
  ButtonAction* = enum
    Unassigned, OpenGrok, OpenClaude, LaunchFfxiv, ToggleMicrophones, ToggleDiscord
  ButtonBinding* = object
    note*: int
    label*, description*: string
    action*: ButtonAction

const
  MasterFaderController* = 16
  AppFaderBindings* = [
    (17, "Browsers", @["Firefox", "Google Chrome", "Chrome", "Chromium"], false),
    (18, "Spotify", @["Spotify"], false),
    (19, "games", @["FINAL FANTASY XIV", "World of Warcraft"], true)]
  ButtonGrid* = [[12, 9, 6, 3], [11, 8, 5, 2], [10, 7, 4, 1]]
  ButtonBindings* = [
    ButtonBinding(note: 12, label: "Grok", description: "Open grok.com in Firefox.", action: OpenGrok),
    ButtonBinding(note: 9, label: "Claude", description: "Open claude.ai in Firefox.", action: OpenClaude),
    ButtonBinding(note: 10, label: "FFXIV", description: "Launch XIVLauncher through Steam, or focus the running game.", action: LaunchFfxiv),
    ButtonBinding(note: 11, label: "Microphones", description: "Toggle every real microphone together, using BenQ mute state.", action: ToggleMicrophones),
    ButtonBinding(note: 8, label: "Discord", description: "Toggle Discord self-mute through local RPC.", action: ToggleDiscord)]
  GrokCommand* = "firefox --new-window https://grok.com/"
  ClaudeCommand* = "firefox --new-window https://claude.ai/"
  FfxivLaunchCommand* = "steam steam://rungameid/9332724227821797376"
  BenqMicSource* = "alsa_input.usb-Generic_BenQ_EX3210U-00.iec958-stereo"
  GreyBrightness* = "25"
  DarkGrey* = "72"
  LightGrey* = "96"
  StreamDeckDemoBrightness* = 30
  SteamAppIdVariable = "SteamAppId="
  GameMediaRole = "game"
  ChromiumAppNames = ["google chrome", "chrome", "chromium"]
  ChromiumChannels = [" stable", " beta", " dev", " unstable", " canary"]

proc buttonBinding*(note: int): ButtonBinding =
  ## Look up a physical button's compiled action, including unassigned inputs.
  for binding in ButtonBindings:
    if binding.note == note:
      return binding
  result = ButtonBinding(note: note, label: "Unassigned", description: "No action assigned.")

proc isSteamGame*(processId: string): bool =
  ## Detect Steam's launch marker in a running process environment.
  if processId.len == 0:
    return false
  let path = "/proc" / processId / "environ"
  if not fileExists(path):
    return false
  var environ: string
  try:
    environ = readFile(path)
  except IOError:
    if not fileExists(path):
      return false
    raise
  result = environ.startsWith(SteamAppIdVariable) or ("\0" & SteamAppIdVariable) in environ

proc matchesAudioTarget*(appName, mediaRole: string, steamGame: bool,
    appNames: openArray[string], includeGames: bool): bool =
  ## Match an application or game stream against one compiled fader target.
  let lowerApp = appName.toLowerAscii()
  for name in appNames:
    let lowerName = name.toLowerAscii()
    if lowerName in ChromiumAppNames:
      var browser = lowerApp.replace('-', ' ').splitWhitespace().join(" ")
      for channel in ChromiumChannels:
        if browser.endsWith(channel):
          browser.setLen(browser.len - channel.len)
          break
      if lowerName == "chromium" and browser == "chromium browser":
        return true
      if browser == lowerName:
        return true
    elif lowerName in lowerApp:
      return true
  result = includeGames and (steamGame or mediaRole.toLowerAscii() == GameMediaRole)

proc bindingCatalog*(): JsonNode =
  ## Describe the same bindings consumed by the daemon, without credentials.
  result = %*{"buttons": [], "faders": []}
  for note in 1..12:
    let binding = buttonBinding(note)
    result["buttons"].add(%*{"note": note, "label": binding.label,
      "description": binding.description})
  result["faders"].add(%*{"controller": 16, "label": "Master", "description": "Volume of the current default output."})
  for (controller, label, apps, games) in AppFaderBindings:
    result["faders"].add(%*{"controller": controller, "label": label,
      "description": if games: "Named games, Steam-launched applications, and game-role streams." else: "All matching " & label & " streams.",
      "appNames": apps, "includeGames": games})
