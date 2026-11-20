type
  ObsProject* = enum
    MinecraftProject, FirefoxProject, WowProject

  ObsProjectSpec* = object
    id*, label*, profile*, collection*, scene*, video*, audio*, mic*, recordDirectory*: string

const
  SharedDemoProfileName* = "Demo Recording"
  SharedDemoRecordDirectory* = "Videos/Demos"
  ObsProjectOperations* = ["selectMinecraft", "selectFirefox", "selectWow"]
  # Minecraft and Firefox keep their original per-setup profiles as accepted legacy pairs.
  ObsProjects* = [
    ObsProjectSpec(id: "minecraft", label: "Minecraft AI Demos", profile: "Minecraft AI Demos",
      collection: "Minecraft AI Demos", scene: "Minecraft", video: "Minecraft Video",
      audio: "Minecraft Audio", mic: "Commentary", recordDirectory: "Videos/Minecraft-AI"),
    ObsProjectSpec(id: "firefox", label: "Firefox Demos", profile: "Firefox Demos",
      collection: "Firefox Demos", scene: "Firefox", video: "Firefox Video",
      audio: "Firefox Audio", mic: "Commentary", recordDirectory: "Videos/Firefox-Demos"),
    ObsProjectSpec(id: "wow", label: "WoW Demos", profile: SharedDemoProfileName,
      collection: "WoW Demos", scene: "WoW", video: "WoW Video",
      audio: "WoW Audio", mic: "Commentary", recordDirectory: SharedDemoRecordDirectory)]

proc projectSpec*(project: ObsProject): ObsProjectSpec =
  ## Return the matched recording profile, collection, sources, and destination for one demo setup.
  ObsProjects[ord(project)]

proc acceptsProfile*(spec: ObsProjectSpec, profile: string): bool =
  ## Report whether a profile records this setup: the shared demo profile or its own legacy one.
  profile == SharedDemoProfileName or profile == spec.profile

proc projectId*(profile, collection: string): string =
  ## Identify a supported setup only when the collection matches and the profile is accepted for it.
  for spec in ObsProjects:
    if collection == spec.collection and spec.acceptsProfile(profile): return spec.id

proc preferredProfile*(spec: ObsProjectSpec, installed: openArray[string]): string =
  ## Choose the shared demo profile when it is installed, otherwise the setup's legacy profile.
  result = if SharedDemoProfileName in installed: SharedDemoProfileName else: spec.profile

proc projectForOperation*(operation: string): ObsProject =
  ## Resolve an explicit setup-selection operation, refusing unknown operations.
  case operation
  of "selectMinecraft": MinecraftProject
  of "selectFirefox": FirefoxProject
  of "selectWow": WowProject
  else: raise newException(ValueError, "Unknown OBS setup operation: " & operation)
