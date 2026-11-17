import
  std/[math, os, tables],
  chroma, jsony, pixie,
  silky/atlas

const
  AssetDirectory = currentSourcePath().parentDir().parentDir() / "assets"
  Sidebar = rgbx(28, 32, 40, 255)
  Foreground = rgbx(234, 237, 242, 255)
  HeaderX = 22
  HeaderY = 30

proc checkGlyph(frame: Image) =
  ## Compare the header's first glyph against its native atlas pixels after blending.
  let
    bytes = readFile(AssetDirectory / "atlas.png")
    atlas = extractAtlasJsonFromPng(bytes).fromJson(SilkyAtlas)
    texture = decodeImage(bytes)
    font = atlas.fonts["Title"]
    glyph = font.entries["K"][0]
    left = HeaderX + glyph.boundsX.int
    top = round(HeaderY.float32 + font.ascent + glyph.boundsY).int
  var inkPixels = 0
  for y in 0..<glyph.boundsHeight.int:
    for x in 0..<glyph.boundsWidth.int:
      let
        alpha = texture[glyph.x + x, glyph.y + y].a.int
        actual = frame[left + x, top + y]
      if alpha > 0:
        inc inkPixels
      for (actualChannel, foregroundChannel, backgroundChannel) in [
          (actual.r, Foreground.r, Sidebar.r),
          (actual.g, Foreground.g, Sidebar.g),
          (actual.b, Foreground.b, Sidebar.b)]:
        let expected = (foregroundChannel.int * alpha +
          backgroundChannel.int * (255 - alpha) + 127) div 255
        doAssert abs(actualChannel.int - expected) <= 1,
          "Header glyph was resampled or misplaced at " & $x & ", " & $y
  doAssert inkPixels > 20, "The reference glyph must contain visible ink."

proc main() =
  ## Require unchanged native text pixels across default, small, odd, and large windows.
  doAssert paramCount() == 1
  let
    directory = paramStr(1)
    initial = readImage(directory / "0.png")
  initial.checkGlyph()
  for (name, width, height) in [("42", 960, 640), ("46", 1183, 761), ("50", 1600, 1000)]:
    let resized = readImage(directory / (name & ".png"))
    doAssert resized.width == width and resized.height == height
    resized.checkGlyph()
    for (left, top, width, height) in [(20, 28, 165, 38), (20, 94, 150, 22),
        (214, 28, 280, 38)]:
      for y in top..<top + height:
        for x in left..<left + width:
          doAssert resized[x, y] == initial[x, y],
            "Text pixels changed after resize to " & $resized.width & "x" & $resized.height

when isMainModule:
  main()
