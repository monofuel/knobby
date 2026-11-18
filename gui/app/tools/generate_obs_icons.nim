import
  std/[os, strutils, tables],
  pixie

type
  Tone = enum
    ## Frame and accent palette shared by every icon variant.
    GreenTone, RedTone, AmberTone, GreyTone
  Sprite = seq[string]
  Icon = object
    name, label: string
    tone: Tone
    sprite: Sprite
    colors: Table[char, ColorRGBX]

const
  OutputDirectory = currentSourcePath().parentDir().parentDir().parentDir().parentDir() /
    "assets" / "obs"
  Size = 72
  Border = 4
  Texel = 4
  SpriteScale = 2
  SpriteTop = 10
  FontScale = 2
  GlyphHeight = 7
  GlyphGap = 1
  LabelTop = 50
  LabelBandTop = 45
  Seed = 0x2f6e2b1'u32
  Font = {
    '0': @[".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    '1': @["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    '8': @[".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    'A': @[".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    'B': @["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    'C': @[".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    'D': @["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    'E': @["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    'F': @["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    'I': @["###", ".#.", ".#.", ".#.", ".#.", ".#.", "###"],
    'K': @["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    'M': @["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    'N': @["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
    'O': @[".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    'P': @["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    'R': @["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    'S': @[".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    'T': @["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    'U': @["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."]}.toTable
  RecordSprite = @[
    "................",
    ".....######.....",
    "...##rrrrrr##...",
    "..#rrrrrrrrrr#..",
    "..#rrhhrrrrrr#..",
    ".#rrhhrrrrrrrr#.",
    ".#rrhrrrrrrrrr#.",
    ".#rrrrrrrrrrrr#.",
    ".#rrrrrrrrrrrd#.",
    ".#rrrrrrrrrrrd#.",
    ".#rrrrrrrrrrdd#.",
    "..#rrrrrrrrdd#..",
    "..#rrrrrrddd#...",
    "...##rrdddd##...",
    ".....######.....",
    "................"]
  RecordRingSprite = @[
    "................",
    ".....######.....",
    "...##rrrrrr##...",
    "..#rr######rr#..",
    "..#r#......#r#..",
    ".#r#........#r#.",
    ".#r#........#r#.",
    ".#r#........#r#.",
    ".#r#........#r#.",
    ".#r#........#r#.",
    ".#r#........#r#.",
    "..#r#......#r#..",
    "..#rr######rr#..",
    "...##rrrrrr##...",
    ".....######.....",
    "................"]
  RecordPausedSprite = @[
    "................",
    ".....######.....",
    "...##rrrrrr##...",
    "..#rrrrrrrrrr#..",
    "..#rrrrrrrrrr#..",
    ".#rrrhhrrhhrrr#.",
    ".#rrrhhrrhhrrr#.",
    ".#rrrhhrrhhrrr#.",
    ".#rrrhhrrhhrrr#.",
    ".#rrrhhrrhhrrd#.",
    ".#rrrhhrrhhrdd#.",
    "..#rrrrrrrrdd#..",
    "..#rrrrrrrddd#..",
    "...##rrdddd##...",
    ".....######.....",
    "................"]
  PauseSprite = @[
    "................",
    "...####..####...",
    "...#hh#..#hh#...",
    "...#hr#..#hr#...",
    "...#rr#..#rr#...",
    "...#rr#..#rr#...",
    "...#rr#..#rr#...",
    "...#rr#..#rr#...",
    "...#rr#..#rr#...",
    "...#rr#..#rr#...",
    "...#rr#..#rr#...",
    "...#rd#..#rd#...",
    "...#dd#..#dd#...",
    "...####..####...",
    "................",
    "................"]
  MicSprite = @[
    "......####......",
    ".....#hhrr#.....",
    ".....#hrrr#.....",
    ".....#rrrr#.....",
    ".....#rrrr#.....",
    "...s.#rrrd#.s...",
    "...s.#rrdd#.s...",
    "...s..####..s...",
    "...ss......ss...",
    "....ss....ss....",
    "......ssss......",
    ".......ss.......",
    ".......ss.......",
    ".....ssssss.....",
    "................",
    "................"]
  MicMutedSprite = @[
    "......####....xx",
    ".....#hhrr#..xx.",
    ".....#hrrr#.xx..",
    ".....#rrrr#xx...",
    ".....#rrrrxx....",
    "...s.#rrrxx.s...",
    "...s.#rrxx#.s...",
    "...s..#xx#..s...",
    "...ss.xx...ss...",
    "....sxx...ss....",
    "....xxssss......",
    "...xx..ss.......",
    "..xx...ss.......",
    ".xx..ssssss.....",
    "xx..............",
    "................"]
  CameraSprite = @[
    "................",
    "..####..####....",
    ".#hhrr##hhrr#...",
    ".#hrrr##hrrr#...",
    "..####..####....",
    "##########......",
    "#hhhrrrrrr#.##..",
    "#hrrrrrrrr##d#..",
    "#rrrr##rrr#dd#..",
    "#rrr#ll#rr#dd#..",
    "#rrrr##rrr##d#..",
    "#rrrrrrrrd#.##..",
    "#ddddddddd#.....",
    "##########......",
    "................",
    "................"]
  BackSprite = @[
    "................",
    "......##........",
    ".....#h#........",
    "....#hr#........",
    "...#hrr#######..",
    "..#hrrrrrrrrrr#.",
    ".#hrrrrrrrrrrr#.",
    ".#rrrrrrrrrrrr#.",
    "..#rrrdddddddd#.",
    "...#rrd#######..",
    "....#rd#........",
    ".....#d#........",
    "......##........",
    "................",
    "................",
    "................"]
  OpenSprite = @[
    "................",
    "..############..",
    "..#hhhhhhhhhh#..",
    "..#hrrrrrrrrr#..",
    "..############..",
    "..#llllllllll#..",
    "..#llllllllll#..",
    "..#lllll#llll#..",
    "..#llll#h#lll#..",
    "..#lll#hrr#ll#..",
    "..#ll#hrrrr#l#..",
    "..#lll##r##ll#..",
    "..#llll#d#lll#..",
    "..#llll###lll#..",
    "..############..",
    "................"]
  BarrierSprite = @[
    "................",
    ".....######.....",
    "...##rrrrrr##...",
    "..#rr######rr#..",
    "..#r#....#rr#...",
    ".#r#....#rr#r#..",
    ".#r#...#rr#.#r#.",
    ".#r#..#rr#..#r#.",
    ".#r#.#rr#...#r#.",
    ".#r##rr#....#r#.",
    "..##rr#....#r#..",
    "..#rr#....#r#...",
    "..#rr######r#...",
    "...##rrrrrr##...",
    ".....######.....",
    "................"]

proc rgb(value: string): ColorRGBX =
  ## Parse a #RRGGBB palette entry into an opaque pixel.
  let hex = value.strip(chars = {'#'})
  rgbx(fromHex[uint8](hex[0..1]), fromHex[uint8](hex[2..3]), fromHex[uint8](hex[4..5]), 255)

proc shade(color: ColorRGBX, amount: int): ColorRGBX =
  ## Lighten or darken a pixel by a fixed amount per channel.
  rgbx(uint8(clamp(color.r.int + amount, 0, 255)), uint8(clamp(color.g.int + amount, 0, 255)),
    uint8(clamp(color.b.int + amount, 0, 255)), 255)

proc frameColor(tone: Tone): ColorRGBX =
  ## Return the frame color that announces an icon's state at a glance.
  case tone
  of GreenTone: rgb("#4c8a2a")
  of RedTone: rgb("#b3261e")
  of AmberTone: rgb("#d9901f")
  of GreyTone: rgb("#5b5d61")

proc labelColor(tone: Tone): ColorRGBX =
  ## Return the label ink that matches a state tone.
  case tone
  of GreenTone: rgb("#b6f08e")
  of RedTone: rgb("#ff8a78")
  of AmberTone: rgb("#ffd36a")
  of GreyTone: rgb("#a4a6aa")

proc noise(x, y: int): uint32 =
  ## Return a deterministic per-texel hash so regenerated icons are byte-identical.
  var value = Seed xor (uint32(x) * 0x9e3779b1'u32) xor (uint32(y) * 0x85ebca77'u32)
  value = value xor (value shr 15)
  value = value * 0x2c1b3c6d'u32
  value xor (value shr 12)

proc fillStone(image: Image, tone: Tone) =
  ## Fill the key with a block-textured stone face, a darker label band, and a beveled frame.
  let
    stone = if tone == GreyTone: [rgb("#3c3d40"), rgb("#434447"), rgb("#38393b"), rgb("#47484b")]
      else: [rgb("#5a5b5e"), rgb("#636467"), rgb("#55565a"), rgb("#6b6c6f")]
    band = [rgb("#26272a"), rgb("#2b2c2f"), rgb("#232427"), rgb("#2f3033")]
  for y in 0..<Size:
    for x in 0..<Size:
      let
        index = int(noise(x div Texel, y div Texel) mod 4)
        palette = if y >= LabelBandTop + Border div 2: band else: stone
      image[x, y] = palette[index]
  let
    frame = tone.frameColor()
    light = frame.shade(48)
    dark = frame.shade(-56)
  for y in 0..<Size:
    for x in 0..<Size:
      let edge = min(min(x, y), min(Size - 1 - x, Size - 1 - y))
      if edge >= Border: continue
      if edge == 0:
        image[x, y] = rgb("#111214")
      elif x - 1 < Border and y >= x and Size - 1 - y >= x or y - 1 < Border and x >= y and Size - 1 - x >= y:
        image[x, y] = if edge == 1: light else: frame
      else:
        image[x, y] = if edge == 1: dark else: frame
  for x in Border..<Size - Border:
    image[x, LabelBandTop] = frame.shade(-80)
    image[x, LabelBandTop + 1] = frame.shade(-80)

proc drawSprite(image: Image, sprite: Sprite, colors: Table[char, ColorRGBX]) =
  ## Draw a 16x16 sprite at a whole-pixel scale; "." stays transparent.
  let
    width = sprite[0].len * SpriteScale
    left = (Size - width) div 2
  for row, line in sprite:
    for column, symbol in line:
      if symbol == '.': continue
      let color = colors[symbol]
      for dy in 0..<SpriteScale:
        for dx in 0..<SpriteScale:
          image[left + column * SpriteScale + dx, SpriteTop + row * SpriteScale + dy] = color

proc labelWidth(text: string): int =
  ## Measure a label in logical font pixels, including inter-glyph gaps.
  for index, character in text:
    if index > 0: result += GlyphGap
    result += Font[character][0].len

proc drawLabel(image: Image, text: string, color: ColorRGBX) =
  ## Draw a centered label with a hard one-texel shadow and no antialiasing.
  let
    width = labelWidth(text) * FontScale
    left = (Size - width) div 2
  doAssert width <= Size - 2 * Border - 2, "Label is too wide: " & text
  let shadow = color.shade(-150)
  for (offset, ink) in [(FontScale, shadow), (0, color)]:
    var x = left
    for character in text:
      let glyph = Font[character]
      for row in 0..<GlyphHeight:
        for column, symbol in glyph[row]:
          if symbol != '#': continue
          for dy in 0..<FontScale:
            for dx in 0..<FontScale:
              image[x + column * FontScale + dx + offset, LabelTop + row * FontScale + dy + offset] = ink
      x += (glyph[0].len + GlyphGap) * FontScale

proc palette(outline, fill, highlight, dark: string, extra: openArray[(char, string)] = []):
    Table[char, ColorRGBX] =
  ## Build a sprite palette: outline, fill, highlight, and shadow plus optional extras.
  result = {'#': rgb(outline), 'r': rgb(fill), 'h': rgb(highlight), 'd': rgb(dark)}.toTable
  for (key, value) in extra: result[key] = rgb(value)

proc icons(): seq[Icon] =
  ## Describe every OBS key face: names are the asset contract consumed by configuration.
  let
    redstone = palette("#2a0605", "#d42a1e", "#ff7a5c", "#8a130d")
    ring = palette("#2a0605", "#c0322a", "#ff7a5c", "#8a130d")
    amber = palette("#2e1c04", "#f0a32a", "#ffe08a", "#b06a12")
    emerald = palette("#0f2a0a", "#5fb83a", "#a6e67a", "#2f7a1c", [('s', "#c8cace")])
    stone = palette("#1a1b1d", "#9a9ca0", "#c8cace", "#66686c")
    pale = palette("#1a1b1d", "#d9dbe0", "#ffffff", "#9a9ca0")
    greyed = palette("#1e1f21", "#6a6c70", "#84868a", "#4c4d50")
    coin = palette("#2e1c04", "#f0a32a", "#3a2408", "#b06a12")
    camera = palette("#0f2a0a", "#5fb83a", "#a6e67a", "#2f7a1c", [('l', "#d9dbe0")])
    openFace = palette("#0f2a0a", "#5fb83a", "#a6e67a", "#2f7a1c", [('l', "#2a3b4c")])
    muted = palette("#2a0605", "#d42a1e", "#ff7a5c", "#8a130d", [('x', "#f2f2f2"), ('s', "#8e9094")])
  @[
    Icon(name: "menu-obs", label: "OBS", tone: GreenTone, sprite: CameraSprite, colors: camera),
    Icon(name: "minecraft-launch", label: "PRISM", tone: GreyTone, sprite: OpenSprite, colors: openFace),
    Icon(name: "minecraft-1080-needed", label: "1080", tone: AmberTone, sprite: OpenSprite, colors: openFace),
    Icon(name: "minecraft-1080", label: "1080", tone: GreenTone, sprite: OpenSprite, colors: openFace),
    Icon(name: "back", label: "BACK", tone: GreenTone, sprite: BackSprite, colors: pale),
    Icon(name: "record-idle", label: "REC", tone: GreenTone, sprite: RecordRingSprite, colors: ring),
    Icon(name: "record-recording", label: "REC", tone: RedTone, sprite: RecordSprite, colors: redstone),
    Icon(name: "record-paused", label: "REC", tone: AmberTone, sprite: RecordPausedSprite, colors: coin),
    Icon(name: "record-unavailable", label: "REC", tone: GreyTone, sprite: RecordRingSprite, colors: greyed),
    Icon(name: "pause-idle", label: "PAUSE", tone: GreyTone, sprite: PauseSprite, colors: greyed),
    Icon(name: "pause-running", label: "PAUSE", tone: GreenTone, sprite: PauseSprite, colors: pale),
    Icon(name: "pause-paused", label: "PAUSE", tone: AmberTone, sprite: PauseSprite, colors: amber),
    Icon(name: "mic-enabled", label: "MIC", tone: GreenTone, sprite: MicSprite, colors: emerald),
    Icon(name: "mic-muted", label: "MUTED", tone: RedTone, sprite: MicMutedSprite, colors: muted),
    Icon(name: "obs-idle", label: "OBS", tone: GreyTone, sprite: OpenSprite, colors: openFace),
    Icon(name: "obs-open", label: "OBS", tone: GreenTone, sprite: OpenSprite, colors: openFace),
    Icon(name: "unavailable", label: "OFF", tone: GreyTone, sprite: BarrierSprite, colors: stone)]

proc render(icon: Icon): Image =
  ## Render one 72x72 key face at native pixels.
  result = newImage(Size, Size)
  result.fillStone(icon.tone)
  result.drawSprite(icon.sprite, icon.colors)
  result.drawLabel(icon.label, icon.tone.labelColor())

proc main() =
  ## Regenerate the committed OBS key faces without network access or system fonts.
  createDir(OutputDirectory)
  for icon in icons():
    for line in icon.sprite:
      doAssert line.len == icon.sprite[0].len, icon.name & " sprite rows differ in width."
    icon.render().writeFile(OutputDirectory / (icon.name & ".png"))

when isMainModule:
  main()
