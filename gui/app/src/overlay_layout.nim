import
  std/[json, unicode],
  knobby/bindings

type
  PixelRect* = object
    x*, y*, width*, height*: int
  OverlayCard* = object
    note*: int
    label*: string
    unassigned*: bool
    bounds*: PixelRect
  Monitor* = object
    name*: string
    primary*: bool
    bounds*: PixelRect
  Strut* = object
    ## Reserved screen edges in root coordinates, following _NET_WM_STRUT_PARTIAL.
    left*, right*, top*, bottom*: int
    leftStartY*, leftEndY*, rightStartY*, rightEndY*: int
    topStartX*, topEndX*, bottomStartX*, bottomEndX*: int
  LabelLines* = object
    font*: string
    lines*: seq[string]
  Measure* = proc (text: string): int
  LabelFont* = object
    name*: string
    maxLines*: int
    measure*: Measure

const
  CardWidth* = 208
  CardHeight* = 92
  CardGap* = 12
  CardPadding* = 12
  NoteTop* = 8
  LabelTop* = 30
  LabelBottomPadding* = 8
  ScreenMargin* = 24
  GridColumns* = 4
  GridRows* = 3
  OverlayWidth* = GridColumns * CardWidth + (GridColumns - 1) * CardGap
  OverlayHeight* = GridRows * CardHeight + (GridRows - 1) * CardGap
  LabelWidth* = CardWidth - 2 * CardPadding
  LabelHeight* = CardHeight - LabelTop - LabelBottomPadding
  UnassignedLabel* = "Unassigned"
  Ellipsis = "..."

proc right*(rect: PixelRect): int =
  ## Return the first column past the rectangle.
  rect.x + rect.width

proc bottom*(rect: PixelRect): int =
  ## Return the first row past the rectangle.
  rect.y + rect.height

proc overlayCards*(catalog: JsonNode): seq[OverlayCard] =
  ## Place the twelve mixer buttons in physical order: 12 9 6 3 / 11 8 5 2 / 10 7 4 1.
  for row in 0..<GridRows:
    for column in 0..<GridColumns:
      let
        note = ButtonGrid[row][column]
        entry = if catalog.isNil: nil else: catalog{"buttons"}{note - 1}
        label = if entry.isNil: "" else: entry{"label"}.getStr()
        unassigned = label.len == 0 or label == UnassignedLabel
      result.add(OverlayCard(note: note, unassigned: unassigned,
        label: if unassigned: UnassignedLabel else: label,
        bounds: PixelRect(x: column * (CardWidth + CardGap), y: row * (CardHeight + CardGap),
          width: CardWidth, height: CardHeight)))

proc overlayShowing*(buttonConfig: JsonNode, nowMs: int64): bool =
  ## Show only a fresh daemon request whose monotonic deadline has not passed.
  ## A nil status means the daemon is disconnected or stale.
  if buttonConfig.isNil or buttonConfig.kind != JObject:
    return false
  let overlay = buttonConfig{"overlay"}
  if overlay.isNil or overlay.kind != JObject:
    return false
  overlay{"visible"}.getBool() and nowMs < overlay{"expiresAtMs"}.getBiggestInt()

proc chooseMonitor*(monitors: openArray[Monitor]): Monitor =
  ## Prefer the primary monitor, falling back to the first one listed.
  if monitors.len == 0:
    raise newException(ValueError, "No monitors are available for the overlay.")
  result = monitors[0]
  for monitor in monitors:
    if monitor.primary:
      return monitor

proc overlaps(start, finish, low, high: int): bool =
  ## Report whether the inclusive strut span meets the half-open monitor span.
  start < high and finish >= low

proc usableArea*(monitor: Monitor, rootWidth, rootHeight: int, struts: openArray[Strut]): PixelRect =
  ## Remove panel struts that touch this monitor from its bounds.
  var
    left = monitor.bounds.x
    top = monitor.bounds.y
    right = monitor.bounds.right
    bottom = monitor.bounds.bottom
  for strut in struts:
    if strut.left > 0 and overlaps(strut.leftStartY, strut.leftEndY, top, bottom):
      left = max(left, strut.left)
    if strut.right > 0 and overlaps(strut.rightStartY, strut.rightEndY, top, bottom):
      right = min(right, rootWidth - strut.right)
    if strut.top > 0 and overlaps(strut.topStartX, strut.topEndX, monitor.bounds.x, monitor.bounds.right):
      top = max(top, strut.top)
    if strut.bottom > 0 and overlaps(strut.bottomStartX, strut.bottomEndX, monitor.bounds.x, monitor.bounds.right):
      bottom = min(bottom, rootHeight - strut.bottom)
  if right <= left or bottom <= top:
    return monitor.bounds
  PixelRect(x: left, y: top, width: right - left, height: bottom - top)

proc overlayOrigin*(usable: PixelRect, width = OverlayWidth, height = OverlayHeight,
    margin = ScreenMargin): tuple[x, y: int] =
  ## Center horizontally at the bottom of the usable area, keeping the margin when it fits.
  result.x = usable.x + (usable.width - width) div 2
  result.y = usable.bottom - margin - height
  result.x = max(usable.x, result.x)
  result.y = max(usable.y, result.y)

proc breakWord(word: string, width: int, measure: Measure): seq[string] =
  ## Split one word wider than the label at rune boundaries.
  var current = ""
  for rune in word.runes:
    let candidate = current & $rune
    if current.len > 0 and measure(candidate) > width:
      result.add(current)
      current = $rune
    else:
      current = candidate
  if current.len > 0:
    result.add(current)

proc wrapLabel*(text: string, width: int, measure: Measure): seq[string] =
  ## Wrap at spaces, breaking only words that cannot fit on a line by themselves.
  var current = ""
  for word in text.splitWhitespace():
    let candidate = if current.len == 0: word else: current & " " & word
    if measure(candidate) <= width:
      current = candidate
    else:
      if current.len > 0:
        result.add(current)
      if measure(word) <= width:
        current = word
      else:
        let pieces = breakWord(word, width, measure)
        result.add(pieces[0..^2])
        current = pieces[^1]
  if current.len > 0:
    result.add(current)

proc fitLabel*(text: string, fonts: openArray[LabelFont]): LabelLines =
  ## Use the first font whose wrapped lines fit; otherwise shorten the last font's final line.
  for font in fonts:
    let lines = wrapLabel(text, LabelWidth, font.measure)
    if lines.len <= font.maxLines:
      return LabelLines(font: font.name, lines: lines)
  let last = fonts[^1]
  var lines = wrapLabel(text, LabelWidth, last.measure)
  lines.setLen(last.maxLines)
  var final = lines[^1]
  while final.len > 0 and last.measure(final & Ellipsis) > LabelWidth:
    final = final.runeSubStr(0, final.runeLen - 1)
  lines[^1] = final & Ellipsis
  LabelLines(font: last.name, lines: lines)
