import
  std/[json, os, strutils],
  ./ipc

type
  ConfigRequestError* = object of CatchableError
    code*, field*, reply*: string

const
  RequestTimeoutMs* = 10000
  OperationTimeoutMs* = 120000
  ClientPollMs = 5
  ResultType = "result"
  StateType = "state"
  SubscribeType = "subscribe"
  StatusKey = "buttonConfig"
  SucceededStatus = "succeeded"
  FailedStatus = "failed"

proc daemonSocketPath*(): string =
  ## Locate the daemon's per-user request and state socket.
  runtimePath("knobby", "daemon.sock")

proc requestConfig*(kind: string, payload: JsonNode = nil, path = daemonSocketPath(),
    timeoutMs = RequestTimeoutMs): JsonNode =
  ## Send one request on a dedicated connection and return its result, accepted or rejected.
  var message = %*{"version": ProtocolVersion, "type": kind}
  if not payload.isNil:
    if payload.kind != JObject:
      raise newException(ValueError, "Request payload must be a JSON object.")
    for key, value in payload:
      if key notin ["version", "type"]:
        message[key] = value
  let peer = connectLocal(path)
  defer: peer.close()
  peer.queueMessage(message)
  let deadline = monotonicMs() + timeoutMs
  while monotonicMs() < deadline:
    for reply in peer.pump():
      if reply{"type"}.getStr() != ResultType:
        raise newException(IOError, "Unexpected Knobby reply type: " & reply{"type"}.getStr())
      return reply
    sleep(ClientPollMs)
  raise newException(IOError, "Knobby did not answer " & kind & " within " & $timeoutMs & " ms.")

proc findOperation(status: JsonNode, id: string): JsonNode =
  ## Find an operation in the current slot or the bounded recent results.
  let current = status{"operation"}
  if not current.isNil and current.kind == JObject and current{"id"}.getStr() == id:
    return current
  for record in status{"recent"}.getElems():
    if record{"id"}.getStr() == id:
      return record

proc waitConfigOperation*(id: string, timeoutMs = OperationTimeoutMs,
    path = daemonSocketPath()): JsonNode =
  ## Wait for a terminal operation record, including one that finished before the wait began.
  let separator = id.rfind('-')
  if separator <= 0:
    raise newException(ValueError, "Invalid operation id: " & id)
  let
    session = id[0..<separator]
    sequence = parseInt(id[separator + 1..^1])
    peer = connectLocal(path)
  defer: peer.close()
  peer.queueMessage(%*{"version": ProtocolVersion, "type": SubscribeType})
  let deadline = monotonicMs() + timeoutMs
  while monotonicMs() < deadline:
    for message in peer.pump():
      let status = message{"state"}{StatusKey}
      if message{"type"}.getStr() == StateType and not status.isNil:
        if status{"session"}.getStr() != session:
          raise newException(IOError, "Knobby restarted before operation " & id & " finished.")
        let record = findOperation(status, id)
        if not record.isNil and record{"status"}.getStr() in [SucceededStatus, FailedStatus]:
          return record
        if record.isNil and status{"lastOperationSequence"}.getInt() >= sequence:
          raise newException(IOError, "Operation " & id & " is no longer retained by Knobby.")
    sleep(ClientPollMs)
  raise newException(IOError, "Operation " & id & " did not finish within " & $timeoutMs & " ms.")

proc readButtonStatus*(path = daemonSocketPath(), timeoutMs = RequestTimeoutMs): JsonNode =
  ## Return the daemon's current button runtime status from one state message.
  let peer = connectLocal(path)
  defer: peer.close()
  peer.queueMessage(%*{"version": ProtocolVersion, "type": SubscribeType})
  let deadline = monotonicMs() + timeoutMs
  while monotonicMs() < deadline:
    for message in peer.pump():
      let status = message{"state"}{StatusKey}
      if message{"type"}.getStr() == StateType and not status.isNil:
        return status
    sleep(ClientPollMs)
  raise newException(IOError, "Knobby sent no state within " & $timeoutMs & " ms.")

proc waitDeckPage*(generation: int64, timeoutMs = RequestTimeoutMs,
    path = daemonSocketPath()): JsonNode =
  ## Wait until the physical Deck acknowledges uploading a page at least as new as generation.
  let peer = connectLocal(path)
  defer: peer.close()
  peer.queueMessage(%*{"version": ProtocolVersion, "type": SubscribeType})
  let deadline = monotonicMs() + timeoutMs
  while monotonicMs() < deadline:
    for message in peer.pump():
      let status = message{"state"}{StatusKey}
      if message{"type"}.getStr() == StateType and not status.isNil and
          status{"deckReady"}.getBool() and status{"deckReadGeneration"}.getBiggestInt() >= generation:
        return status
    sleep(ClientPollMs)
  raise newException(IOError, "The Stream Deck did not confirm page " & $generation &
    " within " & $timeoutMs & " ms.")

proc requestError(node: JsonNode): ref ConfigRequestError =
  ## Convert a rejected reply or failed record into an error carrying its field metadata.
  result = newException(ConfigRequestError, node{"error"}.getStr("Knobby rejected the request."))
  result.code = node{"code"}.getStr()
  result.field = node{"field"}.getStr()
  result.reply = $node

proc requireConfigResult*(reply: JsonNode): JsonNode =
  ## Return an accepted reply, raising ConfigRequestError for a rejection.
  if not reply{"ok"}.getBool():
    raise requestError(reply)
  result = reply

proc runConfigOperation*(kind: string, payload: JsonNode, timeoutMs = OperationTimeoutMs,
    path = daemonSocketPath()): JsonNode =
  ## Submit apply, preview, or importAsset and return its succeeded record; call off render threads.
  let reply = requireConfigResult(requestConfig(kind, payload, path))
  result = waitConfigOperation(reply["operationId"].getStr(), timeoutMs, path)
  if result{"status"}.getStr() != SucceededStatus:
    raise requestError(result)
