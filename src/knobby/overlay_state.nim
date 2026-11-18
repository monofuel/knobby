import
  std/[json, locks],
  ./ipc

type
  OverlayRequest* = object
    ## Transient help-overlay request; it is never persisted or replayed.
    expiresAtMs*, sequence*: int64

const
  MixerOverlayDurationMs* = 10_000'i64

var
  overlayLock: Lock
  shared: OverlayRequest

initLock(overlayLock)

proc visible*(request: OverlayRequest, nowMs: int64): bool =
  ## Report whether the request is still within its deadline on the host monotonic clock.
  request.expiresAtMs > 0 and nowMs < request.expiresAtMs

proc request*(request: var OverlayRequest, nowMs: int64) =
  ## Show the overlay, or restart its deadline when it is already showing.
  request.expiresAtMs = nowMs + MixerOverlayDurationMs
  inc request.sequence

proc dismiss*(request: var OverlayRequest, nowMs: int64) =
  ## Hide a visible overlay; an expired or hidden request is left unchanged.
  if request.visible(nowMs):
    request.expiresAtMs = 0
    inc request.sequence

proc press*(request: var OverlayRequest, requestsOverlay: bool, nowMs: int64) =
  ## Apply one fresh button press: the help action shows the overlay, any other press hides it.
  if requestsOverlay:
    request.request(nowMs)
  else:
    request.dismiss(nowMs)

proc toJson*(request: OverlayRequest, nowMs: int64): JsonNode =
  ## Encode the request for status; hidden requests report no deadline.
  let showing = request.visible(nowMs)
  %*{"visible": showing, "expiresAtMs": (if showing: request.expiresAtMs else: 0'i64),
    "durationMs": MixerOverlayDurationMs, "sequence": request.sequence}

proc pressMixerOverlay*(requestsOverlay: bool, nowMs = monotonicMs()) =
  ## Record a fresh button press against the shared request; this lock is never held while taking another.
  {.cast(gcsafe).}:
    withLock overlayLock:
      shared.press(requestsOverlay, nowMs)

proc mixerOverlayStatus*(nowMs = monotonicMs()): JsonNode =
  ## Return the shared request as the additive `overlay` status member.
  {.cast(gcsafe).}:
    withLock overlayLock:
      result = shared.toJson(nowMs)

proc resetMixerOverlay*() =
  ## Forget any request, as on a fresh daemon start.
  {.cast(gcsafe).}:
    withLock overlayLock:
      shared = OverlayRequest()
