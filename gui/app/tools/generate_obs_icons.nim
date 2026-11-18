import
  std/[math, os, strutils, tables],
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
  ChatBotMask = @[
    "......####......",
    "......####......",
    ".......##.......",
    ".......##.......",
    "..############..",
    ".##############.",
    ".##############.",
    "####..####..####",
    "####..####..####",
    ".##############.",
    ".##############.",
    ".####......####.",
    ".##############.",
    "..############.."]
  SymbolCenter = (Border + LabelBandTop) div 2
  GearCells = 16
  GearTeeth = 8
  GearToothHalfWidth = 0.24
  GearBodyRadius = 5.4
  GearToothRadius = 7.9
  GearHoleRadius = 2.4
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
    'H': @["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    'L': @["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    'M': @["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    'N': @["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
    'O': @[".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    'P': @["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    'R': @["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    'S': @[".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    'T': @["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    'U': @["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    'V': @["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    'X': @["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    'Y': @["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    '/': @["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."]}.toTable
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

proc drawSprite(image: Image, sprite: Sprite, colors: Table[char, ColorRGBX], top = SpriteTop) =
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
          image[left + column * SpriteScale + dx, top + row * SpriteScale + dy] = color

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

proc outlinedSprite(mask: seq[seq[bool]]): Sprite =
  ## Convert a padded fill mask into a sprite with outline, edge bevel, and dark enclosed holes.
  let
    height = mask.len
    width = mask[0].len
  var outside = newSeq[seq[bool]](height)
  for row in 0..<height: outside[row] = newSeq[bool](width)
  var pending = @[(0, 0)]
  while pending.len > 0:
    let (x, y) = pending.pop()
    if x < 0 or y < 0 or x >= width or y >= height or outside[y][x] or mask[y][x]: continue
    outside[y][x] = true
    pending.add([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])
  for y in 0..<height:
    var line = ""
    for x in 0..<width:
      let
        filled = proc (dx, dy: int): bool =
          x + dx in 0..<width and y + dy in 0..<height and mask[y + dy][x + dx]
        open = proc (dx, dy: int): bool =
          x + dx notin 0..<width or y + dy notin 0..<height or outside[y + dy][x + dx]
      if mask[y][x]:
        line.add(if open(0, -1) or open(-1, 0): 'h' elif open(0, 1) or open(1, 0): 'd' else: 'r')
      elif not outside[y][x]:
        line.add('e')
      elif filled(1, 0) or filled(-1, 0) or filled(0, 1) or filled(0, -1) or
          filled(1, 1) or filled(-1, -1) or filled(1, -1) or filled(-1, 1):
        line.add('#')
      else:
        line.add('.')
    result.add(line)

proc paddedMask(columns, rows: int): seq[seq[bool]] =
  ## Return an empty mask with a one-cell transparent margin for the outline.
  result = newSeq[seq[bool]](rows + 2)
  for row in 0..rows + 1: result[row] = newSeq[bool](columns + 2)

proc gearSprite(): Sprite =
  ## Build a symmetric settings gear from polar geometry.
  var mask = paddedMask(GearCells, GearCells)
  let center = (GearCells - 1) / 2
  for row in 0..<GearCells:
    for column in 0..<GearCells:
      let
        dx = column.float - center
        dy = row.float - center
        radius = hypot(dx, dy)
        step = 2 * PI / GearTeeth
        angle = floorMod(arctan2(dy, dx) + step / 2, step) - step / 2
        tooth = abs(angle) * radius <= GearToothHalfWidth * GearToothRadius
      mask[row + 1][column + 1] = radius >= GearHoleRadius and
        (radius <= GearBodyRadius or tooth and radius <= GearToothRadius)
  outlinedSprite(mask)

proc chatBotSprite(): Sprite =
  ## Build the original voice-chat bot face used as the Discord menu identity.
  var mask = paddedMask(ChatBotMask[0].len, ChatBotMask.len)
  for row, line in ChatBotMask:
    for column, symbol in line:
      mask[row + 1][column + 1] = symbol == '#'
  outlinedSprite(mask)

proc centeredTop(sprite: Sprite): int =
  ## Return the top edge that vertically centers a sprite's painted rows in the symbol area.
  var first, last = -1
  for row, line in sprite:
    if line.strip(chars = {'.'}).len > 0:
      if first < 0: first = row
      last = row
  SymbolCenter - (first + last + 1) * SpriteScale div 2

proc drawSlash(image: Image, sprite: Sprite, top: int) =
  ## Draw a light mute slash across a sprite on its texel grid with a dark edge.
  let
    columns = sprite[0].len
    rows = sprite.len
    left = (Size - columns * SpriteScale) div 2
    outline = rgb("#141518")
    light = rgb("#f2f2f2")
  for pass in 0..1:
    for row in 0..<rows:
      let column = columns - 2 - row * (columns - 3) div (rows - 1)
      for offset in -2..1:
        let edge = offset in [-2, 1]
        if edge != (pass == 0): continue
        let x = column + offset
        if x notin 0..<columns: continue
        for dy in 0..<SpriteScale:
          for dx in 0..<SpriteScale:
            image[left + x * SpriteScale + dx, top + row * SpriteScale + dy] =
              if edge: outline else: light

proc drawSymbol(image: Image, sprite: Sprite, colors: Table[char, ColorRGBX], slashed = false) =
  ## Draw a large centered symbol, optionally crossed by a mute slash.
  let top = sprite.centeredTop()
  image.drawSprite(sprite, colors, top)
  if slashed: image.drawSlash(sprite, top)

proc generateDiscordIcons() =
  ## Generate Discord-menu artwork using the same pixel style as OBS.
  const
    Directory = OutputDirectory.parentDir() / "discord"
    Headphones = @[
      "....########....", "...#hhrrrrrr#...", "..#hrr####rrr#..", "..#rr#....#rr#..",
      "..#rr#....#rr#..", "..#rr#....#rr#..", ".##rr#....#rr##.", ".#rrr#....#rrr#.",
      ".#rrr#....#rrr#.", ".#rrr#....#rrr#.", ".#rrd#....#drr#.", ".#ddd#....#ddd#.",
      "..###......###..", "................", "................", "................"]
  let
    bot = chatBotSprite()
    green = palette("#0f2a0a", "#5fb83a", "#a6e67a", "#2f7a1c")
    red = palette("#2a0605", "#d42a1e", "#ff7a5c", "#8a130d")
    grey = palette("#1e1f21", "#6a6c70", "#84868a", "#4c4d50", [('e', "#2a2b2e")])
    blurple = palette("#141633", "#5865f2", "#a3abff", "#3c45b0", [('e', "#141633")])
    steel = palette("#16181b", "#b4b8bf", "#eceef2", "#71757c", [('e', "#16181b")])
  createDir(Directory)
  for (prefix, sprite, colors) in [("system", gearSprite(), steel), ("discord", bot, blurple)]:
    for (suffix, label, tone, slashed) in [
        ("live", "LIVE", GreenTone, false),
        ("muted", "MUTED", RedTone, true),
        ("mixed", "MIXED", AmberTone, false),
        ("deafened", "DEAF", RedTone, true),
        ("unavailable", "N/A", GreyTone, false)]:
      if (prefix == "system" and suffix == "deafened") or
          (prefix == "discord" and suffix == "mixed"): continue
      let image = newImage(Size, Size)
      image.fillStone(tone)
      image.drawSymbol(sprite, if tone == GreyTone: grey else: colors, slashed)
      image.drawLabel(label, tone.labelColor())
      image.writeFile(Directory / (prefix & "-" & suffix & ".png"))
  for (name, label, tone, sprite, colors) in [
      ("menu-discord", "CHAT", GreenTone, bot, blurple),
      ("deafen-live", "HEAR", GreenTone, Headphones, green),
      ("deafen-muted", "DEAF", RedTone, Headphones, red),
      ("deafen-unavailable", "N/A", GreyTone, Headphones, grey),
      ("open-idle", "OPEN", GreyTone, bot, blurple),
      ("open-running", "READY", GreenTone, bot, blurple)]:
    let image = newImage(Size, Size)
    image.fillStone(tone)
    image.drawSymbol(sprite, colors, name == "deafen-muted")
    image.drawLabel(label, tone.labelColor())
    image.writeFile(Directory / (name & ".png"))
  render(Icon(label: "BACK", tone: GreenTone, sprite: BackSprite,
    colors: palette("#1a1b1d", "#d9dbe0", "#ffffff", "#9a9ca0"))).writeFile(Directory / "back.png")

proc main() =
  ## Regenerate the committed key faces without network access or system fonts.
  createDir(OutputDirectory)
  for icon in icons():
    for line in icon.sprite:
      doAssert line.len == icon.sprite[0].len, icon.name & " sprite rows differ in width."
    icon.render().writeFile(OutputDirectory / (icon.name & ".png"))
  generateDiscordIcons()

when isMainModule:
  main()
