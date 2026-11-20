import
  std/os,
  ./setup_workflow_layout

proc main() =
  ## Organize Deck navigation with the workflow Menu layout, which replaces the shared key prefix.
  runWorkflowSetup(commandLineParams())

when isMainModule:
  main()
