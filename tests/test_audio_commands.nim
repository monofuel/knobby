import
  std/[monotimes, times, unittest],
  knobby/common

suite "bounded audio commands":
  test "captures output larger than a pipe buffer":
    let output = runAudioCommand("/bin/sh",
      @["-c", "i=0; while [ $i -lt 10000 ]; do echo abcdefghijklmnop; i=$((i+1)); done"])
    check output.len == 170000

  test "reports stderr and nonzero exit":
    expect OSError:
      discard runAudioCommand("/bin/sh", @["-c", "echo failed >&2; exit 7"])

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
