import
  std/[os, strformat],
  knobby/status,
  ../src/observers

proc main() =
  ## Check live read-only observers without opening a desktop window.
  startObservers()
  defer: stopObservers()
  sleep(3500)
  let state = readState()
  echo fmt"Mixer: {state.snapshot.mixer.port}; status: {state.mixerError}"
  echo fmt"Stream Deck connected: {state.deckConnected}; status: {state.deckError}"
  echo fmt"Mousepad present: {state.mousepadPresent}"
  echo fmt"Audio: {state.audio.master.name}; status: {state.audioError}"
  if state.mixerError.len > 0 or state.audioError.len > 0:
    raise newException(IOError, "Live daemon status or audio is unavailable.")

when isMainModule:
  main()
