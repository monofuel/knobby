import
  std/[json, monotimes, strutils, times, unittest],
  knobby/common

suite "bounded audio commands":
  test "captures output larger than a pipe buffer":
    let output = runAudioCommand("/bin/sh",
      @["-c", "i=0; while [ $i -lt 10000 ]; do echo abcdefghijklmnop; i=$((i+1)); done"])
    check output.len == 170000

  test "reports stderr and nonzero exit":
    var message = ""
    try:
      discard runAudioCommand("/bin/sh", @["-c", "echo partial; echo failed >&2; exit 7"])
    except OSError as error:
      message = error.msg
    check "exit 7" in message
    check "partial" in message
    check "failed" in message

  test "successful stderr warnings cannot corrupt JSON stdout":
    let output = runAudioCommand("/bin/sh", @["-c",
      "echo 'Invalid non-ASCII character: 0xffffffe2' >&2; printf '%s' '{\"sinks\":[]}'"])
    check output == "{\"sinks\":[]}"
    check parseJson(output)["sinks"].len == 0

  test "drains stderr larger than a pipe buffer without losing stdout":
    let output = runAudioCommand("/bin/sh", @["-c",
      "i=0; while [ $i -lt 10000 ]; do echo abcdefghijklmnop >&2; i=$((i+1)); done; echo ready"])
    check output == "ready\n"

  test "drains large interleaved stdout and stderr":
    let output = runAudioCommand("/bin/sh", @["-c",
      "i=0; while [ $i -lt 10000 ]; do echo abcdefghijklmnop; echo diagnostic >&2; i=$((i+1)); done"])
    check output.len == 170000
    check output.count("abcdefghijklmnop\n") == 10000

  test "kills a command that closes output but keeps running":
    let started = getMonoTime()
    expect OSError:
      discard runAudioCommand("/bin/sh", @["-c", "exec 1>&- 2>&-; while :; do :; done"])
    check (getMonoTime() - started).inMilliseconds < 2500

  test "kills a command that never produces output":
    let started = getMonoTime()
    expect OSError:
      discard runAudioCommand("/bin/sh", @["-c", "while :; do :; done"])
    check (getMonoTime() - started).inMilliseconds < 2500
