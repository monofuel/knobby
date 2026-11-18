import
  ./common

const
  OverlayService* = "knobby-overlay.service"

proc activateMixerOverlay*() =
  ## Start the standalone overlay renderer without waiting or focusing anything.
  ## The button runtime already recorded the request; a running renderer observes it.
  discard runAudioCommand("systemctl", @["--user", "start", "--no-block", OverlayService])
