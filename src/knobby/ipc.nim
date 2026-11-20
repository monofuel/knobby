import
  std/[json, monotimes, net, nativesockets, options, os, posix]

type
  Peer* = ref object
    socket: Socket
    input, output, pending: string
    offset: int
    progress: int64
    closed*: bool
    subscribed*: bool
  LocalServer* = ref object
    socket: Socket
    path: string
    ownership: cint
    peers: seq[Peer]
  Request* = object
    peer*: Peer
    message*: JsonNode

const
  ProtocolVersion* = 5
  MaxFrameBytes* = 1024 * 1024
  PeerTimeoutMs* = 2000
  MaxPeers = 8
  ChunkBytes = 8192
  LockExclusive = 2
  LockNonblocking = 4

proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}
  ## Acquire an advisory process lock that is released when the descriptor closes.

proc monotonicMs*(): int64 =
  ## Return a local monotonic timestamp for deadlines and freshness checks.
  getMonoTime().ticks div 1_000_000

proc runtimePath*(directory, name: string): string =
  ## Locate a per-user endpoint without persistent or global fallback paths.
  let root = getEnv("XDG_RUNTIME_DIR")
  if root.len == 0:
    raise newException(IOError, "XDG_RUNTIME_DIR is unset.")
  root / directory / name

proc acquireOwnership*(path: string): cint =
  ## Lock one endpoint before removing a stale socket or opening hardware.
  createDir(path.parentDir())
  result = posix.open(path.cstring, O_CREAT or O_RDWR or O_CLOEXEC, Mode(0o600))
  if result < 0:
    raiseOSError(osLastError(), path)
  if flock(result, LockExclusive or LockNonblocking) < 0:
    let error = osLastError()
    discard posix.close(result)
    raiseOSError(error, "Already owned by another Knobby process: " & path)

proc encodeMessage*(message: JsonNode): string =
  ## Frame versioned JSON with a four-byte little-endian payload length.
  let payload = $message
  if payload.len == 0 or payload.len > MaxFrameBytes:
    raise newException(ValueError, "IPC message exceeds the frame limit.")
  result = newString(4)
  for index in 0..3:
    result[index] = chr((payload.len shr (index * 8)) and 255)
  result.add(payload)

proc takeMessage*(buffer: var string): Option[JsonNode] =
  ## Consume one complete frame, retaining incomplete headers and payloads.
  if buffer.len < 4:
    return none(JsonNode)
  var size = 0
  for index in 0..3:
    size = size or (ord(buffer[index]) shl (index * 8))
  if size <= 0 or size > MaxFrameBytes:
    raise newException(ValueError, "Invalid IPC frame length.")
  if buffer.len < size + 4:
    return none(JsonNode)
  let message = parseJson(buffer[4..<size + 4])
  if message.kind != JObject or message{"version"}.getInt(-1) != ProtocolVersion:
    raise newException(ValueError, "Incompatible Knobby IPC version; reopen the viewer after updating Knobby.")
  buffer = buffer[size + 4..^1]
  result = some(message)

proc close*(peer: Peer) =
  ## Close a local connection exactly once.
  if not peer.closed:
    peer.closed = true
    peer.socket.close()

proc newPeer(socket: Socket): Peer =
  ## Wrap a nonblocking, close-on-exec socket with bounded framing buffers.
  socket.getFd().setBlocking(false)
  if fcntl(cint(socket.getFd()), F_SETFD, FD_CLOEXEC) < 0:
    raiseOSError(osLastError())
  Peer(socket: socket, progress: monotonicMs())

proc connectLocal*(path: string): Peer =
  ## Connect locally without blocking when a server's backlog is full.
  let socket = newSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP, buffered = false)
  try:
    result = newPeer(socket)
    socket.connectUnix(path)
  except:
    socket.close()
    raise

proc queueMessage*(peer: Peer, message: JsonNode) =
  ## Retain at most the active frame and the newest pending snapshot.
  let frame = encodeMessage(message)
  if peer.output.len == 0:
    peer.output = frame
    peer.progress = monotonicMs()
  else:
    peer.pending = frame

proc pump*(peer: Peer): seq[JsonNode] =
  ## Perform bounded nonblocking transfers; EOF and stalled writes are errors.
  if peer.closed:
    raise newException(IOError, "IPC connection is closed.")
  if peer.output.len > 0:
    let size = posix.send(posix.SocketHandle(peer.socket.getFd()), unsafeAddr peer.output[peer.offset],
      min(ChunkBytes, peer.output.len - peer.offset), MSG_NOSIGNAL)
    if size > 0:
      peer.offset += size
      peer.progress = monotonicMs()
      if peer.offset == peer.output.len:
        peer.output = move(peer.pending)
        peer.offset = 0
    elif size < 0 and errno notin [EAGAIN, EINTR]:
      raiseOSError(osLastError())
    if monotonicMs() - peer.progress > PeerTimeoutMs:
      raise newException(IOError, "IPC peer stopped reading.")
  var bytes: array[ChunkBytes, char]
  let size = posix.recv(posix.SocketHandle(peer.socket.getFd()), addr bytes[0], bytes.len, 0)
  if size == 0:
    raise newException(IOError, "IPC peer disconnected.")
  if size < 0 and errno notin [EAGAIN, EINTR]:
    raiseOSError(osLastError())
  if size > 0:
    if peer.input.len == 0:
      peer.progress = monotonicMs()
    let previous = peer.input.len
    peer.input.setLen(previous + size)
    copyMem(addr peer.input[previous], addr bytes[0], size)
  if peer.input.len > MaxFrameBytes + 4:
    raise newException(ValueError, "IPC input buffer limit exceeded.")
  for _ in 0..<MaxPeers:
    let message = takeMessage(peer.input)
    if message.isNone:
      break
    result.add(message.get())
  if peer.input.len > 0 and monotonicMs() - peer.progress > PeerTimeoutMs:
    raise newException(IOError, "Incomplete IPC request timed out.")

proc newLocalServer*(path: string): LocalServer =
  ## Exclusively own a runtime socket, recovering only a previous owner's endpoint.
  let ownership = acquireOwnership(path & ".lock")
  let socket = newSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP, buffered = false)
  try:
    if fileExists(path) or access(path.cstring, F_OK) == 0:
      removeFile(path)
    socket.bindUnix(path)
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    socket.listen(MaxPeers)
    socket.getFd().setBlocking(false)
    result = LocalServer(socket: socket, path: path, ownership: ownership)
  except:
    socket.close()
    discard posix.close(ownership)
    raise

proc pollRequests*(server: LocalServer): seq[Request] =
  ## Accept and service bounded clients without letting a bad peer stop the server.
  for _ in 0..<MaxPeers:
    var socket: Socket
    try:
      server.socket.accept(socket)
    except OSError as error:
      if error.errorCode in [EAGAIN.int32, EINTR.int32]:
        break
      raise
    if server.peers.len >= MaxPeers:
      socket.close()
    else:
      server.peers.add(newPeer(socket))
  var live: seq[Peer]
  for peer in server.peers:
    if not peer.subscribed and monotonicMs() - peer.progress > PeerTimeoutMs:
      peer.close()
    if not peer.closed:
      try:
        for message in peer.pump():
          result.add(Request(peer: peer, message: message))
      except CatchableError:
        peer.close()
    if not peer.closed:
      live.add(peer)
  server.peers = move(live)

proc broadcast*(server: LocalServer, message: JsonNode) =
  ## Update subscribed clients without accumulating historical state frames.
  for peer in server.peers:
    if peer.subscribed and not peer.closed:
      peer.queueMessage(message)

proc close*(server: LocalServer) =
  ## Release the endpoint before its ownership lock.
  for peer in server.peers:
    peer.close()
  server.socket.close()
  removeFile(server.path)
  discard posix.close(server.ownership)
