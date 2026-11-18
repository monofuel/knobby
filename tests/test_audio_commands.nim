import
  std/[json, monotimes, os, strutils, tempfiles, times, unittest],
  knobby/common

const
  HelperWaitMs = 5000
  ParallelCommandLimitMs = 400

proc waitingHelper(marker: string) {.thread.} =
  ## Wait on a harmless subprocess while the test probes another worker's responsiveness.
  discard runAudioCommand("/bin/sh", @["-c", "echo ready > \"$1\"; sleep 0.7", "fixture", marker])

proc parallelCommandLatency(): int64 =
  ## Measure a fast command after a different worker has started waiting on a helper.
  let directory = createTempDir("knobby-parallel-audio-", "")
  defer: removeDir(directory)
  let marker = directory / "ready"
  var worker: Thread[string]
  createThread(worker, waitingHelper, marker)
  defer: joinThread(worker)
  let deadline = getMonoTime() + initDuration(milliseconds = HelperWaitMs)
  while not fileExists(marker) and getMonoTime() < deadline: sleep(5)
  if not fileExists(marker): raise newException(IOError, "Parallel command fixture did not start.")
  let started = getMonoTime()
  let output = runAudioCommand("/bin/sh", @["-c", "echo ready"])
  result = (getMonoTime() - started).inMilliseconds
  if output != "ready\n": raise newException(IOError, "Parallel command fixture did not answer.")

suite "bounded audio commands":
  test "a waiting desktop helper cannot hold the audio subprocess lock":
    check parallelCommandLatency() < ParallelCommandLimitMs

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
