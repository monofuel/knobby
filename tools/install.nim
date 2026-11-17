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
  for unit in ["knobby.service", "knobby-gui.service"]:
    copyFile(package / "share/knobby" / unit, unitDir / unit)
  copyFile(package / "share/knobby/knobby-gui.desktop", desktopDir / "knobby.desktop")
  for name in ["knobby", "knobby-gui", "knobby-assets"]:
    let launcher = binDir / name
    if symlinkExists(launcher):
      removeFile(launcher)
    elif fileExists(launcher):
      raise newException(IOError, "Refusing to replace an unrelated launcher: " & launcher)
    createSymlink(package / "bin" / name, launcher)
  run(@["systemctl", "--user", "daemon-reload"])
  run(@["systemctl", "--user", "enable", "knobby.service", "knobby-gui.service"])
  run(@["systemctl", "--user", "restart", "knobby.service"])
  echo "Installed. Existing GUI processes and drafts were left running."
  echo "To load a new editor/protocol: choose Quit viewer from the tray, then run ~/.local/bin/knobby-gui."

when isMainModule:
  main()
