import
  knobby/audio_outputs

proc main() =
  ## Run the active audio outputs demo.
  printAudioOutputStreams()

when isMainModule:
  main()
