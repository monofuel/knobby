import
  std/[json, os],
  ./[common, ipc]

const ActivationTimeoutMs* = 10000

proc activateExisting*(path: string, timeoutMs: int) =
  ## Ask a listening viewer to show its window and wait for its acknowledgement.
  let peer = connectLocal(path)
  defer: peer.close()
  peer.queueMessage(%*{"version": ProtocolVersion, "type": "activate"})
  let deadline = monotonicMs() + timeoutMs
  while monotonicMs() < deadline:
    for message in peer.pump():
      if message{"type"}.getStr() != "activated":
        raise newException(ValueError, "Unexpected GUI activation response.")
      return
    sleep(10)
  raise newException(IOError, "The GUI did not acknowledge window activation.")

proc activateViewer*() =
  ## Reuse a running viewer, or start its user service before retrying activation.
  let path = runtimePath("knobby-gui", "activate.sock")
  try:
    activateExisting(path, 250)
    return
  except OSError, IOError:
    discard runAudioCommand("systemctl", @["--user", "start", "--no-block", "knobby-gui.service"])
  let deadline = monotonicMs() + ActivationTimeoutMs
  var lastError = ""
  while monotonicMs() < deadline:
    try:
      activateExisting(path, int(min(1000'i64, deadline - monotonicMs())))
      return
    except OSError as error:
      lastError = error.msg
    except IOError as error:
      lastError = error.msg
    sleep(100)
  raise newException(IOError, "Cannot open Knobby. Check journalctl --user -u knobby-gui: " & lastError)
