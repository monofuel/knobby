import
  std/[json, os, strutils]

type
  FirefoxDemoConfig* = object
    executable*, profileDirectory*, windowClass*, audioLabel*, startUrl*: string

const
  FirefoxDemoClass* = "knobby-firefox-demos"
  FirefoxDemoAudioLabel* = "knobby-firefox"

proc firefoxDemoConfigPath*(): string =
  ## Return the optional shared Firefox demo settings file, honoring XDG_CONFIG_HOME.
  getConfigDir() / "knobby/firefox-demo.json"

proc defaultFirefoxDemoConfig*(): FirefoxDemoConfig =
  ## Use a dedicated browser profile, class, and audio label without changing normal Firefox sessions.
  FirefoxDemoConfig(executable: "firefox",
    profileDirectory: getEnv("XDG_DATA_HOME", getHomeDir() / ".local/share") / "knobby/firefox-demos",
    windowClass: FirefoxDemoClass, audioLabel: FirefoxDemoAudioLabel, startUrl: "about:blank")

proc parseFirefoxDemoConfig*(node: JsonNode): FirefoxDemoConfig =
  ## Merge explicit string settings over the defaults, rejecting unknown or empty fields.
  if node.kind != JObject:
    raise newException(ValueError, "Firefox demo settings must be an object.")
  result = defaultFirefoxDemoConfig()
  for key, value in node:
    if value.kind != JString or value.getStr().strip().len == 0 or '\0' in value.getStr():
      raise newException(ValueError, "Firefox demo setting " & key & " must be a nonempty string without NUL.")
    case key
    of "executable": result.executable = value.getStr()
    of "profileDirectory": result.profileDirectory = value.getStr()
    of "windowClass": result.windowClass = value.getStr()
    of "audioLabel": result.audioLabel = value.getStr()
    of "startUrl": result.startUrl = value.getStr()
    else: raise newException(ValueError, "Unknown Firefox demo setting: " & key)
  if not result.profileDirectory.isAbsolute:
    raise newException(ValueError, "Firefox demo profileDirectory must be absolute.")

proc loadFirefoxDemoConfig*(): FirefoxDemoConfig =
  ## Load shared optional settings; absent settings use the dedicated demo defaults.
  let path = firefoxDemoConfigPath()
  if fileExists(path): parseFirefoxDemoConfig(parseFile(path))
  else: defaultFirefoxDemoConfig()
