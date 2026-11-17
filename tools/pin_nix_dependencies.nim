import
  std/[json, os, osproc, streams, strutils]

const RepoDirectory = currentSourcePath().parentDir().parentDir()

proc main() =
  ## Cache archive hashes for the exact GUI revisions recorded in Nimby's lock.
  setCurrentDir(RepoDirectory)
  let lines = readFile("gui/app/nimby.lock").strip().splitLines()
  var hashes = newJObject()
  for start in countup(0, lines.high, 4):
    var jobs: seq[tuple[revision: string, process: Process]]
    for index in start..min(start + 3, lines.high):
      let
        fields = lines[index].splitWhitespace()
        repo = fields[2].strip(chars = {'/'}).replace("https://github.com/", "")
        url = "https://codeload.github.com/" & repo & "/tar.gz/" & fields[3]
      jobs.add((fields[3], startProcess("nix", args = @["store", "prefetch-file",
        "--unpack", "--name", "source", "--json", url], options = {poUsePath})))
    for job in jobs:
      let output = job.process.outputStream.readAll()
      let code = job.process.waitForExit()
      job.process.close()
      if code != 0:
        raise newException(IOError, "Archive prefetch failed for " & job.revision)
      hashes[job.revision] = parseJson(output)["hash"]
  createDir("nix")
  writeFile("nix/dependency-hashes.json", hashes.pretty() & "\n")

when isMainModule:
  main()
