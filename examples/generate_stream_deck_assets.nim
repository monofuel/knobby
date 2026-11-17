import
  std/[os, osproc, strutils]

const
  AssetDirectory = currentSourcePath().parentDir().parentDir() / "assets" / "stream_deck"
  KeyCount = 15
  FontSize = 32

proc runTool(args: seq[string]): string =
  ## Run an asset-generation tool and report its unsuccessful exit.
  let (output, exitCode) = execCmdEx(quoteShellCommand(args))
  if exitCode != 0:
    raise newException(OSError, args[0] & " failed: " & output)
  result = output.strip()

proc findFont*(): string =
  ## Find DejaVu Sans Bold and require the installed asset-generation tools.
  for tool in ["ffmpeg", "fc-match"]:
    if findExe(tool).len == 0:
      raise newException(OSError, "Asset generation requires " & tool & ".")
  result = runTool(@["fc-match", "-f", "%{file}", "DejaVu Sans:style=Bold"])

proc generateKeyImage*(filename, text, font: string, pressed = false,
    pixelFormat = "yuvj420p", huffman = "optimal") =
  ## Render a rotated key JPEG with explicit sampling and Huffman settings.
  let
    background = if pressed: "0xc0c0c0" else: "black"
    foreground = if pressed: "black" else: "white"
    filter = "drawtext=fontfile='" & font & "':text='" & text &
      "':fontsize=" & $FontSize & ":fontcolor=" & foreground &
      ":x=(w-tw)/2:y=(h-th)/2,hflip,vflip"
  discard runTool(@["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-filter_threads", "1", "-f", "lavfi", "-i", "color=c=" & background & ":s=72x72",
    "-vf", filter, "-frames:v", "1", "-c:v", "mjpeg", "-threads", "1",
    "-pix_fmt", pixelFormat, "-huffman", huffman, "-q:v", "2", filename])

proc generateFallbackImages*(font: string) =
  ## Render the blank and missing-media fallback key JPEGs.
  generateKeyImage(AssetDirectory / "blank.jpg", " ", font)
  generateKeyImage(AssetDirectory / "missing.jpg", "?", font)

proc main() =
  ## Generate the thirty embedded numbered-key JPEGs and the fallback images.
  let font = findFont()
  createDir(AssetDirectory)
  generateFallbackImages(font)
  for number in 1..KeyCount:
    for pressed in [false, true]:
      let suffix = if pressed: "-pressed.jpg" else: "-normal.jpg"
      generateKeyImage(AssetDirectory / ($number & suffix), $number, font, pressed)

when isMainModule:
  main()
