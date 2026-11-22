import
  std/[os, osproc]

const RepoDirectory = currentSourcePath().parentDir().parentDir()

proc run(args: seq[string]) =
  ## Run an installation step with inherited output and fail before changing services.
  let process = startProcess(args[0], args = args[1..^1], options = {poUsePath, poParentStreams})
  defer: process.close()
  let code = process.waitForExit()
  if code != 0:
    raise newException(IOError, args[0] & " exited with status " & $code)

proc installObsPlugin(package: string) =
  ## Link the pinned application-audio plugin without replacing an unrelated installation.
  let
    root = getConfigDir() / "obs-studio/plugins/linux-pipewire-audio"
    marker = root / ".knobby-managed"
    plugin = package / "share/knobby/obs-audio-plugin"
  if dirExists(root) and not fileExists(marker):
    raise newException(IOError, "An unmanaged OBS audio plugin already exists: " & root)
  createDir(root / "bin/64bit")
  for (source, target) in [
      (plugin / "lib/obs-plugins/linux-pipewire-audio.so", root / "bin/64bit/linux-pipewire-audio.so"),
      (plugin / "share/obs/obs-plugins/linux-pipewire-audio", root / "data")]:
    if symlinkExists(target): removeFile(target)
    elif fileExists(target) or dirExists(target):
      raise newException(IOError, "Refusing to replace an unrelated OBS plugin file: " & target)
    createSymlink(source, target)
  writeFile(marker, "Knobby manages these plugin links.\n")

proc main() =
  ## Build and verify before switching the rooted installation and enabling services.
  let
    installDir = getHomeDir() / ".local/share/knobby"
    unitDir = getHomeDir() / ".config/systemd/user"
    binDir = getHomeDir() / ".local/bin"
    desktopDir = getHomeDir() / ".local/share/applications"
  setCurrentDir(RepoDirectory)
  for path in [installDir, unitDir, binDir, desktopDir]: createDir(path)
  run(@["nix", "build", ".#knobby", "--out-link", installDir / "current"])
  let package = installDir / "current"
  installObsPlugin(package)
  for unit in ["knobby.service", "knobby-gui.service", "knobby-overlay.service"]:
    copyFile(package / "share/knobby" / unit, unitDir / unit)
  copyFile(package / "share/knobby/knobby-gui.desktop", desktopDir / "knobby.desktop")
  for name in ["knobby", "knobby-gui", "knobby-overlay", "knobby-assets", "knobby-obs", "knobby-obs-setup",
      "knobby-obs-shared-setup", "knobby-spotify"]:
    let launcher = binDir / name
    if symlinkExists(launcher):
      removeFile(launcher)
    elif fileExists(launcher):
      raise newException(IOError, "Refusing to replace an unrelated launcher: " & launcher)
    createSymlink(package / "bin" / name, launcher)
  run(@["systemctl", "--user", "daemon-reload"])
  run(@["systemctl", "--user", "enable", "knobby.service", "knobby-gui.service"])
  run(@["systemctl", "--user", "restart", "knobby.service"])
  # The overlay has no install target and starts only on a Help press; stopping a
  # previous build lets the next press start the new one without showing anything now.
  run(@["systemctl", "--user", "stop", "knobby-overlay.service"])
  echo "Installed. Existing GUI processes and drafts were left running."
  echo "To load a new editor/protocol: choose Quit viewer from the tray, then run ~/.local/bin/knobby-gui."

when isMainModule:
  main()
