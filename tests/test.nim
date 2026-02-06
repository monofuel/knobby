import
  std/unittest,
  knobby

suite "Knobby":
  test "exposes app name":
    check appName() == "Knobby"

  test "exposes daemon description":
    check daemonDescription().len > 0
