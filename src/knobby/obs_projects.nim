type
  ObsProject* = enum
    MinecraftProject, FirefoxProject

  ObsProjectSpec* = object
    id*, label*, profile*, collection*, scene*, video*, audio*, mic*, recordDirectory*: string

const
  ObsProjectOperations* = ["selectMinecraft", "selectFirefox", "firefox1080"]
  ObsProjects* = [
    ObsProjectSpec(id: "minecraft", label: "Minecraft AI Demos", profile: "Minecraft AI Demos",
      collection: "Minecraft AI Demos", scene: "Minecraft", video: "Minecraft Video",
      audio: "Minecraft Audio", mic: "Commentary", recordDirectory: "Videos/Minecraft-AI"),
    ObsProjectSpec(id: "firefox", label: "Firefox Demos", profile: "Firefox Demos",
      collection: "Firefox Demos", scene: "Firefox", video: "Firefox Video",
      audio: "Firefox Audio", mic: "Commentary", recordDirectory: "Videos/Firefox-Demos")]

proc projectSpec*(project: ObsProject): ObsProjectSpec =
  ## Return the matched recording profile, collection, sources, and destination for one demo setup.
  ObsProjects[ord(project)]

proc projectId*(profile, collection: string): string =
  ## Identify a supported setup only when both the actual profile and collection match.
  for spec in ObsProjects:
    if profile == spec.profile and collection == spec.collection: return spec.id

proc projectForOperation*(operation: string): ObsProject =
  ## Resolve an explicit setup-selection operation, refusing unknown operations.
  case operation
  of "selectMinecraft": MinecraftProject
  of "selectFirefox": FirefoxProject
  else: raise newException(ValueError, "Unknown OBS setup operation: " & operation)
