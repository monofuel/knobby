import
  std/[json, strutils, unittest],
  minecraft_audio

const
  MinecraftPid = 2880870
  IdePid = 4242
  BrowserPid = 5151
  JavaBinary = ".java-wrapped"

proc client(id: int, appName, binary: string, pid: int): JsonNode =
  ## Build a pw-dump client entry like pipewire-pulse publishes.
  result = %*{"id": id, "type": "PipeWire:Interface:Client", "info": {"props": {
    "application.name": appName, "application.process.binary": binary,
    "application.process.id": pid, "client.api": "pipewire-pulse"}}}

proc stream(id, clientId: int, name, appName, binary: string,
    pid: JsonNode): JsonNode =
  ## Build a pw-dump playback stream node entry.
  result = %*{"id": id, "type": "PipeWire:Interface:Node", "info": {"props": {
    "media.class": "Stream/Output/Audio", "node.name": name,
    "application.process.binary": binary, "application.process.id": pid,
    "client.id": clientId, "media.name": "Playback Stream"}}}
  if appName.len > 0:
    result["info"]["props"]["application.name"] = %appName

proc sink(): JsonNode =
  ## Build a hardware sink that application capture never targets.
  result = %*{"id": 136, "type": "PipeWire:Interface:Node", "info": {"props": {
    "media.class": "Audio/Sink", "node.name": "alsa_output.speakers"}}}

proc graph(items: varargs[JsonNode]): AppAudioGraph =
  ## Parse fake pw-dump items through the production parser.
  result = parseAppAudioGraph($(%items))

proc desktop(): seq[JsonNode] =
  ## Mirror the observed desktop: unlabeled Minecraft, Firefox, and Spotify.
  result = @[sink(),
    client(81, "Firefox", "firefox", 490909),
    stream(60, 81, "Firefox", "Firefox", "firefox", %490909),
    client(123, "spotify", ".spotify-wrapped", 1129862),
    stream(108, 123, "spotify", "spotify", ".spotify-wrapped", %1129862),
    client(133, JavaBinary, JavaBinary, MinecraftPid),
    stream(95, 133, JavaBinary, JavaBinary, JavaBinary, %MinecraftPid)]

proc labeledDesktop(): seq[JsonNode] =
  ## Mirror the desktop after Minecraft launches with the label variable.
  result = desktop()[0 .. 4] & @[
    client(133, MinecraftAudioTarget, JavaBinary, MinecraftPid),
    stream(95, 133, MinecraftAudioTarget, MinecraftAudioTarget, JavaBinary,
      %MinecraftPid)]

proc rejection(audio: AppAudioGraph, pid: int, selection: string): string =
  ## Return the guard's refusal message, failing when it accepts.
  try:
    discard audio.verifyMinecraftAudioTarget(pid, selection)
  except MinecraftAudioError as error:
    return error.msg
  doAssert false, "selection " & selection & " was accepted"

suite "Minecraft application audio":
  test "parses only playback streams and clients":
    let audio = graph(desktop())
    check audio.streams.len == 3
    check audio.clients.len == 3
    check audio.streams[2].processId == MinecraftPid
    check audio.streams[2].clientId == 133

  test "unlabeled Minecraft is refused instead of capturing Java":
    let audio = graph(desktop())
    check "not labeled" in audio.rejection(MinecraftPid, MinecraftAudioTarget)
    check audio.targetedStreams(MinecraftAudioTarget).len == 0

  test "Java runtime names are refused even while currently unique":
    let audio = graph(desktop())
    check audio.targetedStreams(JavaBinary).len == 1
    for name in [JavaBinary, "JAVA", "java-wrapped", "javaw"]:
      check "every Java program" in audio.rejection(MinecraftPid, name)

  test "Java runtime names capture another Java program":
    let audio = graph(desktop() & @[
      client(140, JavaBinary, JavaBinary, IdePid),
      stream(141, 140, JavaBinary, JavaBinary, JavaBinary, %IdePid)])
    check audio.targetedStreams(JavaBinary).len == 2

  test "labeled Minecraft is captured alone":
    let audio = graph(labeledDesktop() & @[
      client(140, JavaBinary, JavaBinary, IdePid),
      stream(141, 140, JavaBinary, JavaBinary, JavaBinary, %IdePid)])
    let streams = audio.verifyMinecraftAudioTarget(MinecraftPid)
    check streams.len == 1
    check streams[0].id == 95
    check audio.targetedStreams(MinecraftAudioTarget).len == 1

  test "every Minecraft stream must be labeled":
    let audio = graph(labeledDesktop() & @[
      stream(96, 0, JavaBinary, JavaBinary, JavaBinary, %MinecraftPid)])
    check "not labeled" in audio.rejection(MinecraftPid, MinecraftAudioTarget)

  test "an inherited label in another process is refused":
    let audio = graph(labeledDesktop() & @[
      client(150, MinecraftAudioTarget, "firefox", BrowserPid),
      stream(151, 150, MinecraftAudioTarget, MinecraftAudioTarget, "firefox",
        %BrowserPid)])
    check "also captures" in audio.rejection(MinecraftPid, MinecraftAudioTarget)

  test "matching follows OBS client fallback and case rules":
    let audio = graph(@[
      client(133, MinecraftAudioTarget.toUpperAscii(), JavaBinary,
        MinecraftPid),
      stream(95, 133, JavaBinary, "", JavaBinary, %($MinecraftPid))])
    check audio.streams[0].appName == JavaBinary
    check audio.streams[0].processId == MinecraftPid
    check audio.verifyMinecraftAudioTarget(MinecraftPid).len == 1

  test "absent properties never match":
    let audio = graph(@[%*{"id": 7, "type": "PipeWire:Interface:Node",
      "info": {"props": {"media.class": "Stream/Output/Audio",
      "node.name": "anonymous"}}}])
    check audio.streams[0].binary.len == 0
    check audio.targetedStreams("").len == 0
    check "no target name" in audio.rejection(MinecraftPid, " ")

  test "Minecraft must be running with a stream":
    let audio = graph(@[sink()])
    check "not running" in audio.rejection(0, MinecraftAudioTarget)
    check "no audio stream" in audio.rejection(MinecraftPid,
      MinecraftAudioTarget)

  test "launch environment needs the overriding variable":
    check hasMinecraftLaunchEnvironment(
      "HOME=/home/user\0" & MinecraftLaunchEnvironment & "\0")
    check not hasMinecraftLaunchEnvironment(
      "PULSE_PROP_application.name=" & MinecraftAudioTarget & "\0")
    check not hasMinecraftLaunchEnvironment(
      MinecraftLaunchEnvironment & "-other\0")
