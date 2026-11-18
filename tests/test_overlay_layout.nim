import
  std/[json, strutils, unittest],
  knobby/bindings,
  ../gui/app/src/overlay_layout

const
  NowMs = 50_000'i64
  CharWidth = 8

proc fixedWidth(text: string): int =
  ## Measure text as if every byte were eight pixels wide.
  text.len * CharWidth

proc status(visible: bool, expiresAtMs: int64): JsonNode =
  ## Build a daemon buttonConfig status with an overlay member.
  %*{"initialized": true, "overlay": {"visible": visible, "expiresAtMs": expiresAtMs,
    "durationMs": 10000, "sequence": 1}}

proc monitor(name: string, x, width: int, primary = false): Monitor =
  ## Describe a full-height monitor on a 1200-pixel-tall screen.
  Monitor(name: name, primary: primary, bounds: PixelRect(x: x, y: 0, width: width, height: 1200))

suite "Overlay layout":
  test "cards follow the physical mixer orientation":
    let cards = overlayCards(bindingCatalog())
    var notes: seq[int]
    for card in cards: notes.add(card.note)
    check notes == @[12, 9, 6, 3, 11, 8, 5, 2, 10, 7, 4, 1]
    check cards[0].bounds == PixelRect(x: 0, y: 0, width: CardWidth, height: CardHeight)
    check cards[3].bounds.x == 3 * (CardWidth + CardGap)
    check cards[11].bounds == PixelRect(x: 3 * (CardWidth + CardGap), y: 2 * (CardHeight + CardGap),
      width: CardWidth, height: CardHeight)
    check cards[^1].bounds.right == OverlayWidth and cards[^1].bounds.bottom == OverlayHeight
    check cards[0].label == "Grok" and not cards[0].unassigned

  test "missing and unassigned labels say Unassigned":
    var catalog = bindingCatalog()
    catalog["buttons"][2]["label"] = %""
    let cards = overlayCards(catalog)
    check cards[3].note == 3 and cards[3].unassigned and cards[3].label == UnassignedLabel
    for card in overlayCards(nil):
      check card.unassigned and card.label == UnassignedLabel

  test "only a fresh, unexpired daemon request shows":
    check overlayShowing(status(true, NowMs + 1), NowMs)
    check not overlayShowing(status(true, NowMs), NowMs)
    check not overlayShowing(status(false, NowMs + 5000), NowMs)
    check not overlayShowing(nil, NowMs)
    check not overlayShowing(%*{"initialized": true}, NowMs)
    check not overlayShowing(%*{"overlay": "visible"}, NowMs)

  test "the primary monitor wins, otherwise the first":
    let monitors = [monitor("DP-2", 0, 1920), monitor("DP-1", 1920, 2560, true),
      monitor("HDMI-1", 4480, 1920)]
    check chooseMonitor(monitors).name == "DP-1"
    check chooseMonitor([monitors[2], monitors[0]]).name == "HDMI-1"
    expect ValueError:
      discard chooseMonitor([])

  test "panel struts only shrink the monitors they touch":
    let
      left = monitor("DP-2", 0, 1920)
      middle = monitor("DP-1", 1920, 2560, true)
      bottomPanel = Strut(bottom: 40, bottomStartX: 1920, bottomEndX: 4479)
      leftPanel = Strut(left: 64, leftStartY: 0, leftEndY: 1199)
    check usableArea(middle, 6400, 1200, [bottomPanel]) ==
      PixelRect(x: 1920, y: 0, width: 2560, height: 1160)
    check usableArea(left, 6400, 1200, [bottomPanel]) == left.bounds
    check usableArea(left, 6400, 1200, [leftPanel]) == PixelRect(x: 64, y: 0, width: 1856, height: 1200)
    check usableArea(middle, 6400, 1200, [leftPanel]) == middle.bounds
    check usableArea(middle, 6400, 1200, [Strut(bottom: 5000, bottomEndX: 6399)]) == middle.bounds

  test "the overlay sits at the bottom center with a margin":
    let usable = PixelRect(x: 1920, y: 0, width: 2560, height: 1160)
    check overlayOrigin(usable) ==
      (1920 + (2560 - OverlayWidth) div 2, 1160 - ScreenMargin - OverlayHeight)
    check overlayOrigin(PixelRect(x: 10, y: 20, width: 300, height: 200)) == (10, 20)

  test "labels wrap at words and fall back to the smaller font":
    check wrapLabel("Open the music player", 96, fixedWidth) == @["Open the", "music player"]
    check wrapLabel("Supercalifragilistic", 64, fixedWidth) == @["Supercal", "ifragili", "stic"]
    let
      fonts = [LabelFont(name: "Body", maxLines: 2, measure: proc (text: string): int = text.len * 12),
        LabelFont(name: "Small", maxLines: 3, measure: fixedWidth)]
      short = fitLabel("Grok", fonts)
      long = fitLabel("Spotify, Firefox and every game volume shortcut on this board", fonts)
      huge = fitLabel("word ".repeat(40), fonts)
    check short.font == "Body" and short.lines == @["Grok"]
    check long.font == "Small" and long.lines.len == 3
    check huge.font == "Small" and huge.lines.len == 3 and huge.lines[^1].endsWith("...")
    for line in huge.lines:
      check line.len * 8 <= LabelWidth
