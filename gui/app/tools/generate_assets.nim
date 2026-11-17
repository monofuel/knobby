import
  std/os,
  silky/atlas

const
  AssetDirectory = currentSourcePath().parentDir().parentDir() / "assets"
  AtlasSize = 2048
  SubpixelSteps = 8

proc main() =
  ## Build the committed font atlas without opening a window or using OpenGL.
  let builder = newAtlasBuilder(AtlasSize, 2)
  for (name, size) in [("Small", 13'f32), ("Body", 16'f32), ("Title", 26'f32), ("Key", 30'f32)]:
    builder.addFont(AssetDirectory / "DejaVuSans.ttf", name, size,
      subpixelSteps = SubpixelSteps)
  builder.write(AssetDirectory / "atlas.png")

when isMainModule:
  main()
