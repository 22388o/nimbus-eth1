# Nimbus - Portal Network
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## Implementation of the Portal wire protocol as specified at:
## https://github.com/ethereum/portal-network-specs/blob/master/portal-wire-protocol.md

{.push raises: [Defect].}

import
  std/[sequtils, sets, algorithm],
  stew/[results, byteutils], chronicles, chronos, nimcrypto/hash, bearssl,
  ssz_serialization, metrics,
  eth/rlp, eth/p2p/discoveryv5/[protocol, node, enr, routing_table, random2,
    nodes_verification, lru],
  ../../content_db,
  "."/[portal_stream, portal_protocol_config],
  ./messages

export messages, routing_table

declareCounter portal_message_requests_incoming,
  "Portal wire protocol incoming message requests",
  labels = ["protocol_id", "message_type"]
declareCounter portal_message_decoding_failures,
  "Portal wire protocol message decoding failures",
  labels = ["protocol_id"]
declareCounter portal_message_requests_outgoing,
  "Portal wire protocol outgoing message requests",
  labels = ["protocol_id", "message_type"]
declareCounter portal_message_response_incoming,
  "Portal wire protocol incoming message responses",
  labels = ["protocol_id", "message_type"]

const requestBuckets = [1.0, 3.0, 5.0, 7.0, 9.0, Inf]
declareHistogram portal_lookup_node_requests,
  "Portal wire protocol amount of requests per node lookup",
  labels = ["protocol_id"], buckets = requestBuckets
declareHistogram portal_lookup_content_requests,
  "Portal wire protocol amount of requests per node lookup",
  labels = ["protocol_id"], buckets = requestBuckets
declareCounter portal_lookup_content_failures,
  "Portal wire protocol content lookup failures",
  labels = ["protocol_id"]

const contentKeysBuckets = [0.0, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, Inf]
declareHistogram portal_content_keys_offered,
  "Portal wire protocol amount of content keys per offer message send",
  labels = ["protocol_id"], buckets = contentKeysBuckets
declareHistogram portal_content_keys_accepted,
  "Portal wire protocol amount of content keys per accept message received",
  labels = ["protocol_id"], buckets = contentKeysBuckets
declareCounter portal_gossip_offers_successful,
  "Portal wire protocol successful content offers from neighborhood gossip",
  labels = ["protocol_id"]
declareCounter portal_gossip_offers_failed,
  "Portal wire protocol failed content offers from neighborhood gossip",
  labels = ["protocol_id"]

# Note: These metrics are to get some idea on how many enrs are send on average.
# Relevant issue: https://github.com/ethereum/portal-network-specs/issues/136
const enrsBuckets = [0.0, 1.0, 3.0, 5.0, 8.0, 9.0, Inf]
declareHistogram portal_nodes_enrs_packed,
  "Portal wire protocol amount of enrs packed in a nodes message",
  labels = ["protocol_id"], buckets = enrsBuckets
# This one will currently hit the max numbers because all neighbours are send,
# not only the ones closer to the content.
declareHistogram portal_content_enrs_packed,
  "Portal wire protocol amount of enrs packed in a content message",
  labels = ["protocol_id"], buckets = enrsBuckets

logScope:
  topics = "portal_wire"

const
  alpha = 3 ## Kademlia concurrency factor
  enrsResultLimit* = 32 ## Maximum amount of ENRs in the total Nodes messages
  ## that will be processed
  refreshInterval = 5.minutes ## Interval of launching a random query to
  ## refresh the routing table.
  revalidateMax = 10000 ## Revalidation of a peer is done between 0 and this
  ## value in milliseconds
  initialLookups = 1 ## Amount of lookups done when populating the routing table

  # TalkResp message is a response message so the session is established and a
  # regular discv5 packet is assumed for size calculation.
  # Regular message = IV + header + message
  # talkResp message = rlp: [request-id, response]
  talkRespOverhead =
    16 + # IV size
    55 + # header size
    1 + # talkResp msg id
    3 + # rlp encoding outer list, max length will be encoded in 2 bytes
    9 + # request id (max = 8) + 1 byte from rlp encoding byte string
    3 + # rlp encoding response byte string, max length in 2 bytes
    16 # HMAC
  discv5MaxSize = 1280

  # These are the concurrent offers per Portal wire protocol that is running.
  # Using the `offerQueue` allows for limiting the amount of offers send and
  # thus how many streams can be started.
  # TODO:
  # More thought needs to go into this as it is currently on a per network
  # basis. Keep it simple like that? Or limit it better at the stream transport
  # level? In the latter case, this might still need to be checked/blocked at
  # the very start of sending the offer, because blocking/waiting too long
  # between the received accept message and actually starting the stream and
  # sending data could give issues due to timeouts on the other side.
  # And then there are still limits to be applied also for FindContent and the
  # incoming directions.
  concurrentOffers = 50

type
  ToContentIdHandler* =
    proc(contentKey: ByteList): Option[ContentId] {.raises: [Defect], gcsafe.}

  ContentValidationHandler* =
    proc(content: openArray[byte], contentKey: ByteList):
      bool {.raises: [Defect], gcsafe.}

  PortalProtocolId* = array[2, byte]

  RadiusCache* = LRUCache[NodeId, UInt256]

  ContentInfo* = object
    contentKey*: ByteList
    content*: seq[byte]

  OfferRequestType = enum
    Direct, Database

  OfferRequest = object
    dst: Node
    case kind: OfferRequestType
    of Direct:
      contentList: List[ContentInfo, contentKeysLimit]
    of Database:
      contentKeys: ContentKeysList

  PortalProtocol* = ref object of TalkProtocol
    protocolId*: PortalProtocolId
    routingTable*: RoutingTable
    baseProtocol*: protocol.Protocol
    contentDB*: ContentDB
    toContentId: ToContentIdHandler
    validateContent: ContentValidationHandler
    dataRadius*: UInt256
    bootstrapRecords*: seq[Record]
    lastLookup: chronos.Moment
    refreshLoop: Future[void]
    revalidateLoop: Future[void]
    stream*: PortalStream
    radiusCache: RadiusCache
    offerQueue: AsyncQueue[OfferRequest]
    offerWorkers: seq[Future[void]]

  PortalResult*[T] = Result[T, cstring]

  FoundContentKind* = enum
    Nodes,
    Content

  FoundContent* = object
    src*: Node
    case kind*: FoundContentKind
    of Content:
      content*: seq[byte]
    of Nodes:
      nodes*: seq[Node]

  ContentLookupResult* = object
    content*: seq[byte]
    # List of nodes which do not have requested content, and for which
    # content is in their range
    nodesInterestedInContent*: seq[Node]

proc init*(
  T: type ContentInfo,
  contentKey: ByteList,
  content: seq[byte]): T =
  ContentInfo(
    contentKey: contentKey,
    content: content
  )

proc init*(
  T: type ContentLookupResult,
  content: seq[byte],
  nodesInterestedInContent: seq[Node]): T =
  ContentLookupResult(
    content: content,
    nodesInterestedInContent: nodesInterestedInContent
  )

func `$`(id: PortalProtocolId): string =
  id.toHex()

proc addNode*(p: PortalProtocol, node: Node): NodeStatus =
  p.routingTable.addNode(node)

proc addNode*(p: PortalProtocol, r: Record): bool =
  let node = newNode(r)
  if node.isOk():
    p.addNode(node[]) == Added
  else:
    false

func localNode*(p: PortalProtocol): Node = p.baseProtocol.localNode

func neighbours*(p: PortalProtocol, id: NodeId, seenOnly = false): seq[Node] =
  p.routingTable.neighbours(id = id, seenOnly = seenOnly)

proc inRange(
  p: PortalProtocol,
  nodeId: NodeId,
  nodeRadius: Uint256,
  contentId: ContentId): bool =
  let distance = p.routingTable.distance(nodeId, contentId)
  distance <= nodeRadius

func inRange*(p: PortalProtocol, contentId: ContentId): bool =
  p.inRange(p.localNode.id, p.dataRadius, contentId)

func truncateEnrs(
    nodes: seq[Node], maxSize: int, enrOverhead: int): List[ByteList, 32] =
  var enrs: List[ByteList, 32]
  var totalSize = 0
  for n in nodes:
    let enr = ByteList.init(n.record.raw)
    if totalSize + enr.len() + enrOverhead <= maxSize:
      let res = enrs.add(enr) # 32 limit will not be reached
      totalSize = totalSize + enr.len()
    else:
      break

  enrs

func handlePing(
    p: PortalProtocol, ping: PingMessage, srcId: NodeId): seq[byte] =
  # TODO: This should become custom per Portal Network
  # TODO: Need to think about the effect of malicious actor sending lots of
  # pings from different nodes to clear the LRU.
  let customPayloadDecoded =
    try: SSZ.decode(ping.customPayload.asSeq(), CustomPayload)
    except MalformedSszError, SszSizeMismatchError:
      # invalid custom payload, send empty back
      return @[]
  p.radiusCache.put(srcId, customPayloadDecoded.dataRadius)

  let customPayload = CustomPayload(dataRadius: p.dataRadius)
  let p = PongMessage(enrSeq: p.baseProtocol.localNode.record.seqNum,
    customPayload: ByteList(SSZ.encode(customPayload)))

  encodeMessage(p)

proc handleFindNodes(p: PortalProtocol, fn: FindNodesMessage): seq[byte] =
  if fn.distances.len == 0:
    let enrs = List[ByteList, 32](@[])
    encodeMessage(NodesMessage(total: 1, enrs: enrs))
  elif fn.distances.contains(0):
    # A request for our own record.
    let enr = ByteList(rlp.encode(p.baseProtocol.localNode.record))
    encodeMessage(NodesMessage(total: 1, enrs: List[ByteList, 32](@[enr])))
  else:
    let distances = fn.distances.asSeq()
    if distances.all(proc (x: uint16): bool = return x <= 256):
      let
        nodes = p.routingTable.neighboursAtDistances(distances, seenOnly = true)

      # TODO: Total amount of messages is set fixed to 1 for now, else we would
      # need to either move the send of the talkresp messages here, or allow for
      # returning multiple messages.
      # On the long run, it might just be better to use a stream in these cases?
      # Size calculation is done to truncate the ENR results in order to not go
      # over the discv5 packet size limits. ENRs are sorted so the closest nodes
      # will still be passed.
      const
        portalNodesOverhead = 1 + 1 + 4 # msg id + total + container offset
        maxPayloadSize = discv5MaxSize - talkRespOverhead - portalNodesOverhead
        enrOverhead = 4 # per added ENR, 4 bytes offset overhead

      let enrs = truncateEnrs(nodes, maxPayloadSize, enrOverhead)
      portal_nodes_enrs_packed.observe(enrs.len().int64)

      encodeMessage(NodesMessage(total: 1, enrs: enrs))
    else:
      # invalid request, send empty back
      let enrs = List[ByteList, 32](@[])
      encodeMessage(NodesMessage(total: 1, enrs: enrs))

proc handleFindContent(
    p: PortalProtocol, fc: FindContentMessage, srcId: NodeId): seq[byte] =
  let contentIdOpt = p.toContentId(fc.contentKey)
  if contentIdOpt.isSome():
    const
      portalContentOverhead = 1 + 1 # msg id + SSZ Union selector
      maxPayloadSize = discv5MaxSize - talkRespOverhead - portalContentOverhead
      enrOverhead = 4 # per added ENR, 4 bytes offset overhead

    let
      contentId = contentIdOpt.get()
      # TODO: Should we first do a simple check on ContentId versus Radius
      # before accessing the database?
      maybeContent = p.contentDB.get(contentId)
    if maybeContent.isSome():
      let content = maybeContent.get()
      if content.len <= maxPayloadSize:
        encodeMessage(ContentMessage(
          contentMessageType: contentType, content: ByteList(content)))
      else:
        let connectionId = p.stream.addContentRequest(srcId, content)

        encodeMessage(ContentMessage(
          contentMessageType: connectionIdType, connectionId: connectionId))
    else:
      # Don't have the content, send closest neighbours to content id.
      let
        closestNodes = p.routingTable.neighbours(
          NodeId(contentId), seenOnly = true)
        enrs = truncateEnrs(closestNodes, maxPayloadSize, enrOverhead)
      portal_content_enrs_packed.observe(enrs.len().int64)

      encodeMessage(ContentMessage(contentMessageType: enrsType, enrs: enrs))
  else:
    # Return empty response when content key validation fails
    # TODO: Better would be to return no message at all, needs changes on
    # discv5 layer.
    @[]

proc handleOffer(p: PortalProtocol, o: OfferMessage, srcId: NodeId): seq[byte] =
  var contentKeysBitList = ContentKeysBitList.init(o.contentKeys.len)
  var contentKeys = ContentKeysList.init(@[])
  # TODO: Do we need some protection against a peer offering lots (64x) of
  # content that fits our Radius but is actually bogus?
  # Additional TODO, but more of a specification clarification: What if we don't
  # want any of the content? Reply with empty bitlist and a connectionId of
  # all zeroes but don't actually allow an uTP connection?
  for i, contentKey in o.contentKeys:
    let contentIdOpt = p.toContentId(contentKey)
    if contentIdOpt.isSome():
      let contentId = contentIdOpt.get()
      if p.inRange(contentId):
        if not p.contentDB.contains(contentId):
          contentKeysBitList.setBit(i)
          discard contentKeys.add(contentKey)
    else:
      # Return empty response when content key validation fails
      return @[]

  let connectionId =
    if contentKeysBitList.countOnes() != 0:
      p.stream.addContentOffer(srcId, contentKeys)
    else:
      # When the node does not accept any of the content offered, reply with an
      # all zeroes bitlist and connectionId.
      # Note: What to do in this scenario is not defined in the Portal spec.
      Bytes2([byte 0x00, 0x00])

  encodeMessage(
    AcceptMessage(connectionId: connectionId, contentKeys: contentKeysBitList))

proc messageHandler(protocol: TalkProtocol, request: seq[byte],
    srcId: NodeId, srcUdpAddress: Address): seq[byte] =
  doAssert(protocol of PortalProtocol)

  logScope:
    protocolId = p.protocolId

  let p = PortalProtocol(protocol)

  let decoded = decodeMessage(request)
  if decoded.isOk():
    let message = decoded.get()
    trace "Received message request", srcId, srcUdpAddress, kind = message.kind
    # Received a proper Portal message, check if this node exists in the base
    # routing table and add if so.
    # When the node exists in the base discv5 routing table it is likely that
    # it will/would end up in the portal routing tables too but that is not
    # certain as more nodes might exists on the base layer, and it will depend
    # on the distance, order of lookups, etc.
    # Note: Could add a findNodes with distance 0 call when not, and perhaps,
    # optionally pass ENRs if the message was a discv5 handshake containing the
    # ENR.
    let node = p.baseProtocol.getNode(srcId)
    if node.isSome():
      discard p.routingTable.addNode(node.get())

    portal_message_requests_incoming.inc(
      labelValues = [$p.protocolId, $message.kind])

    case message.kind
    of MessageKind.ping:
      p.handlePing(message.ping, srcId)
    of MessageKind.findnodes:
      p.handleFindNodes(message.findNodes)
    of MessageKind.findcontent:
      p.handleFindContent(message.findcontent, srcId)
    of MessageKind.offer:
      p.handleOffer(message.offer, srcId)
    else:
      # This would mean a that Portal wire response message is being send over a
      # discv5 talkreq message.
      debug "Invalid Portal wire message type over talkreq", kind = message.kind
      @[]
  else:
    portal_message_decoding_failures.inc(labelValues = [$p.protocolId])
    debug "Packet decoding error", error = decoded.error, srcId, srcUdpAddress
    @[]

proc processContent(
    stream: PortalStream, contentKeys: ContentKeysList, content: seq[byte])
    {.gcsafe, raises: [Defect].}

proc new*(T: type PortalProtocol,
    baseProtocol: protocol.Protocol,
    protocolId: PortalProtocolId,
    contentDB: ContentDB,
    toContentId: ToContentIdHandler,
    validateContent: ContentValidationHandler,
    dataRadius = UInt256.high(),
    bootstrapRecords: openArray[Record] = [],
    distanceCalculator: DistanceCalculator = XorDistanceCalculator,
    config: PortalProtocolConfig = defaultPortalProtocolConfig
    ): T =

  let proto = PortalProtocol(
    protocolHandler: messageHandler,
    protocolId: protocolId,
    routingTable: RoutingTable.init(
      baseProtocol.localNode, config.bitsPerHop, config.tableIpLimits,
      baseProtocol.rng, distanceCalculator),
    baseProtocol: baseProtocol,
    contentDB: contentDB,
    toContentId: toContentId,
    validateContent: validateContent,
    dataRadius: dataRadius,
    bootstrapRecords: @bootstrapRecords,
    radiusCache: RadiusCache.init(256),
    offerQueue: newAsyncQueue[OfferRequest](concurrentOffers))

  proto.baseProtocol.registerTalkProtocol(@(proto.protocolId), proto).expect(
    "Only one protocol should have this id")

  let stream = PortalStream.new(
    processContent, udata = proto, rng = proto.baseProtocol.rng)

  proto.stream = stream

  proto

# Sends the discv5 talkreq nessage with provided Portal message, awaits and
# validates the proper response, and updates the Portal Network routing table.
proc reqResponse[Request: SomeMessage, Response: SomeMessage](
    p: PortalProtocol,
    dst: Node,
    request: Request
    ): Future[PortalResult[Response]] {.async.} =
  logScope:
    protocolId = p.protocolId

  trace "Send message request", dstId = dst.id, kind = messageKind(Request)
  portal_message_requests_outgoing.inc(
    labelValues = [$p.protocolId, $messageKind(Request)])

  let talkresp =
    await talkreq(p.baseProtocol, dst, @(p.protocolId), encodeMessage(request))

  # Note: Failure of `decodeMessage` might also simply mean that the peer is
  # not supporting the specific talk protocol, as according to specification
  # an empty response needs to be send in that case.
  # See: https://github.com/ethereum/devp2p/blob/master/discv5/discv5-wire.md#talkreq-request-0x05
  let messageResponse = talkresp
    .flatMap(proc (x: seq[byte]): Result[Message, cstring] = decodeMessage(x))
    .flatMap(proc (m: Message): Result[Response, cstring] =
      getInnerMessageResult[Response](
        m, cstring"Invalid message response received")
    )

  if messageResponse.isOk():
    trace "Received message response", srcId = dst.id,
      srcAddress = dst.address, kind = messageKind(Response)
    portal_message_response_incoming.inc(
      labelValues = [$p.protocolId, $messageKind(Response)])

    p.routingTable.setJustSeen(dst)
  else:
    debug "Error receiving message response", error = messageResponse.error,
      srcId = dst.id, srcAddress = dst.address
    p.routingTable.replaceNode(dst)

  return messageResponse

proc pingImpl*(p: PortalProtocol, dst: Node):
    Future[PortalResult[PongMessage]] {.async.} =
  let customPayload = CustomPayload(dataRadius: p.dataRadius)
  let ping = PingMessage(enrSeq: p.baseProtocol.localNode.record.seqNum,
    customPayload: ByteList(SSZ.encode(customPayload)))

  return await reqResponse[PingMessage, PongMessage](p, dst, ping)

proc findNodesImpl*(p: PortalProtocol, dst: Node, distances: List[uint16, 256]):
    Future[PortalResult[NodesMessage]] {.async.} =
  let fn = FindNodesMessage(distances: distances)

  # TODO Add nodes validation
  return await reqResponse[FindNodesMessage, NodesMessage](p, dst, fn)

proc findContentImpl*(p: PortalProtocol, dst: Node, contentKey: ByteList):
    Future[PortalResult[ContentMessage]] {.async.} =
  let fc = FindContentMessage(contentKey: contentKey)

  return await reqResponse[FindContentMessage, ContentMessage](p, dst, fc)

proc offerImpl*(p: PortalProtocol, dst: Node, contentKeys: ContentKeysList):
    Future[PortalResult[AcceptMessage]] {.async.} =
  let offer = OfferMessage(contentKeys: contentKeys)

  return await reqResponse[OfferMessage, AcceptMessage](p, dst, offer)

proc recordsFromBytes*(rawRecords: List[ByteList, 32]): PortalResult[seq[Record]] =
  var records: seq[Record]
  for r in rawRecords.asSeq():
    var record: Record
    if record.fromBytes(r.asSeq()):
      records.add(record)
    else:
      # If any of the ENRs is invalid, fail immediatly. This is similar as what
      # is done on the discovery v5 layer.
      return err("Deserialization of an ENR failed")

  ok(records)

proc ping*(p: PortalProtocol, dst: Node):
    Future[PortalResult[PongMessage]] {.async.} =
  let pongResponse = await p.pingImpl(dst)

  if pongResponse.isOK():
    let pong = pongResponse.get()
    # TODO: This should become custom per Portal Network
    let customPayloadDecoded =
      try: SSZ.decode(pong.customPayload.asSeq(), CustomPayload)
      except MalformedSszError, SszSizeMismatchError:
        # invalid custom payload
        return err("Pong message contains invalid custom payload")

    p.radiusCache.put(dst.id, customPayloadDecoded.dataRadius)

  return pongResponse

proc findNodes*(
    p: PortalProtocol, dst: Node, distances: seq[uint16]):
    Future[PortalResult[seq[Node]]] {.async.} =
  let nodesMessage = await p.findNodesImpl(dst, List[uint16, 256](distances))
  if nodesMessage.isOk():
    let records = recordsFromBytes(nodesMessage.get().enrs)
    if records.isOk():
      # TODO: distance function is wrong here for state, fix + tests
      return ok(verifyNodesRecords(
        records.get(), dst, enrsResultLimit, distances))
    else:
      return err(records.error)
  else:
    return err(nodesMessage.error)

proc findContent*(p: PortalProtocol, dst: Node, contentKey: ByteList):
    Future[PortalResult[FoundContent]] {.async.} =
  let contentMessageResponse = await p.findContentImpl(dst, contentKey)

  if contentMessageResponse.isOk():
    let m = contentMessageResponse.get()
    case m.contentMessageType:
    of connectionIdType:
      # uTP protocol uses BE for all values in the header, incl. connection id
      let nodeAddress = NodeAddress.init(dst)
      if nodeAddress.isNone():
        # It should not happen as we are already after succesfull talkreq/talkresp
        # cycle
        error "Trying to connect to node with unknown address",
          id = dst.id
        return err("Trying to connect to node with unknown address")

      let connectionResult =
        await p.stream.connectTo(
          nodeAddress.unsafeGet(),
          uint16.fromBytesBE(m.connectionId)
        )

      if connectionResult.isErr():
        debug "Utp connection error while trying to find content",
          error = connectionResult.error
        return err("Error connecting uTP socket")

      let socket = connectionResult.get()
      # Read all bytes from the socket
      # This will either end with a FIN, or because the read action times out.
      # A FIN does not necessarily mean that the data read is complete. Further
      # validation is required, using a length prefix here might be beneficial for
      # this.
      let readData = socket.read()
      if await readData.withTimeout(p.stream.readTimeout):
        let content = readData.read
        await socket.destroyWait()
        return ok(FoundContent(src: dst, kind: Content, content: content))
      else:
        socket.close()
        return err("Reading data from socket timed out, content request failed")
    of contentType:
      return ok(FoundContent(src: dst, kind: Content, content: m.content.asSeq()))
    of enrsType:
      let records = recordsFromBytes(m.enrs)
      if records.isOk():
        let verifiedNodes =
          verifyNodesRecords(records.get(), dst, enrsResultLimit)

        return ok(FoundContent(src: dst, kind: Nodes, nodes: verifiedNodes))
      else:
        return err("Content message returned invalid ENRs")

proc getContentKeys(o: OfferRequest): ContentKeysList =
  case o.kind
  of Direct:
    var contentKeys:ContentKeysList
    for info in o.contentList:
      discard contentKeys.add(info.contentKey)
    return contentKeys
  of Database:
    return o.contentKeys

proc offer(p: PortalProtocol, o: OfferRequest):
  Future[PortalResult[void]] {.async.} =
  ## Offer triggers offer-accept interaction with one peer
  ## Whole flow has two phases:
  ## 1. Come to an agreement on what content to transfer, by using offer and accept
  ## messages.
  ## 2. Open uTP stream from content provider to content receiver and transfer
  ## agreed content.
  ## There are two types of possible offer requests:
  ## Direct - when caller provides content to transfer. This way, content is
  ## guaranteed to be transferred as it stays in memory until whole transfer
  ## is completed.
  ## Database - when caller provides keys of content to be transferred. This
  ## way content is provided from database just before it is transferred through
  ## uTP socket. This is useful when there is a lot of content to be transferred
  ## to many peers, and keeping it all in memory could exhaust node resources.
  ## Main drawback is that content may be deleted from the node database
  ## by the cleanup process before it will be transferred, so this way does not
  ## guarantee content transfer.
  let contentKeys = getContentKeys(o)
  portal_content_keys_offered.observe(contentKeys.len().int64)

  let acceptMessageResponse = await p.offerImpl(o.dst, contentKeys)

  if acceptMessageResponse.isOk():
    let m = acceptMessageResponse.get()
    let acceptedKeysAmount = m.contentKeys.countOnes()
    portal_content_keys_accepted.observe(acceptedKeysAmount.int64)
    if acceptedKeysAmount == 0:
      # Don't open an uTP stream if no content was requested
      return ok()

    let nodeAddress = NodeAddress.init(o.dst)
    if nodeAddress.isNone():
      # It should not happen as we are already after succesfull talkreq/talkresp
      # cycle
      error "Trying to connect to node with unknown address",
        id = o.dst.id
      return err("Trying to connect to node with unknown address")

    let connectionResult =
      await p.stream.connectTo(
        nodeAddress.unsafeGet(),
        uint16.fromBytesBE(m.connectionId)
      )

    if connectionResult.isErr():
      debug "Utp connection error while trying to offer content",
        error = connectionResult.error
      return err("Error connecting uTP socket")

    let clientSocket = connectionResult.get()

    case o.kind
    of Direct:
      for i, b in m.contentKeys:
        if b:
          let dataWritten = await clientSocket.write(o.contentList[i].content)
          if dataWritten.isErr:
            debug "Error writing requested data", error = dataWritten.error
            # No point in trying to continue writing data
            clientSocket.close()
            return err("Error writing requested data")
    of Database:
      for i, b in m.contentKeys:
        if b:
          let contentIdOpt = p.toContentId(o.contentKeys[i])
          if contentIdOpt.isSome():
            let
              contentId = contentIdOpt.get()
              maybeContent = p.contentDB.get(contentId)
            if maybeContent.isSome():
              let content = maybeContent.get()
              let dataWritten = await clientSocket.write(content)
              if dataWritten.isErr:
                debug "Error writing requested data", error = dataWritten.error
                # No point in trying to continue writing data
                clientSocket.close()
                return err("Error writing requested data")

    await clientSocket.closeWait()
    return ok()
  else:
    return err("No accept response")

proc offer*(p: PortalProtocol, dst: Node, contentKeys: ContentKeysList):
    Future[PortalResult[void]] {.async.} =
    let req = OfferRequest(dst: dst, kind: Database, contentKeys: contentKeys)
    let res = await p.offer(req)
    return res

proc offer*(p: PortalProtocol, dst: Node, content: seq[ContentInfo]):
    Future[PortalResult[void]] {.async.} =
    if len(content) > contentKeysLimit:
      return err("Cannot offer more than 64 content items")

    let contentList = List[ContentInfo, contentKeysLimit].init(content)
    let req = OfferRequest(dst: dst, kind: Direct, contentList: contentList)
    let res = await p.offer(req)
    return res

proc offerWorker(p: PortalProtocol) {.async.} =
  while true:
    let req = await p.offerQueue.popFirst()

    let res = await p.offer(req)
    if res.isOk():
      portal_gossip_offers_successful.inc(labelValues = [$p.protocolId])
    else:
      portal_gossip_offers_failed.inc(labelValues = [$p.protocolId])

proc offerQueueEmpty*(p: PortalProtocol): bool =
  p.offerQueue.empty()

proc lookupWorker(
    p: PortalProtocol, dst: Node, target: NodeId): Future[seq[Node]] {.async.} =
  let distances = lookupDistances(target, dst.id)
  let nodesMessage = await p.findNodes(dst, distances)
  if nodesMessage.isOk():
    let nodes = nodesMessage.get()
    # Attempt to add all nodes discovered
    for n in nodes:
      discard p.routingTable.addNode(n)

    return nodes
  else:
    return @[]

proc lookup*(p: PortalProtocol, target: NodeId): Future[seq[Node]] {.async.} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # `closestNodes` holds the k closest nodes to target found, sorted by distance
  # Unvalidated nodes are used for requests as a form of validation.
  var closestNodes = p.routingTable.neighbours(target, BUCKET_SIZE,
    seenOnly = false)

  var asked, seen = initHashSet[NodeId]()
  asked.incl(p.baseProtocol.localNode.id) # No need to ask our own node
  seen.incl(p.baseProtocol.localNode.id) # No need to discover our own node
  for node in closestNodes:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[seq[Node]]](alpha)
  var requestAmount = 0'i64

  while true:
    var i = 0
    # Doing `alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.lookupWorker(n, target))
        requestAmount.inc()
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query = await one(pendingQueries)
    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let nodes = query.read
    # TODO: Remove node on timed-out query?
    for n in nodes:
      if not seen.containsOrIncl(n.id):
        # If it wasn't seen before, insert node while remaining sorted
        closestNodes.insert(n, closestNodes.lowerBound(n,
          proc(x: Node, n: Node): int =
            cmp(p.routingTable.distance(x.id, target),
              p.routingTable.distance(n.id, target))
        ))

        if closestNodes.len > BUCKET_SIZE:
          closestNodes.del(closestNodes.high())

  portal_lookup_node_requests.observe(requestAmount)
  p.lastLookup = now(chronos.Moment)
  return closestNodes

proc triggerPoke*(
    p: PortalProtocol,
    nodes: seq[Node],
    contentKey: ByteList,
    content: seq[byte]) =
  ## Triggers asynchronous offer-accept interaction to provided nodes.
  ## Provided content should be in range of provided nodes.
  for node in nodes:
    if not p.offerQueue.full():
      try:
        let
          ci = ContentInfo(contentKey: contentKey, content: content)
          list = List[ContentInfo, contentKeysLimit].init(@[ci])
          req = OfferRequest(dst: node, kind: Direct, contentList: list)
        p.offerQueue.putNoWait(req)
      except AsyncQueueFullError as e:
        # Should not occur as full() check is done.
        raiseAssert(e.msg)
    else:
      # Offer queue is full, do not start more offer-accept interactions
      return

# TODO ContentLookup and Lookup look almost exactly the same, also lookups in other
# networks will probably be very similar. Extract lookup function to separate module
# and make it more generaic
proc contentLookup*(p: PortalProtocol, target: ByteList, targetId: UInt256):
    Future[Option[ContentLookupResult]] {.async.} =
  ## Perform a lookup for the given target, return the closest n nodes to the
  ## target. Maximum value for n is `BUCKET_SIZE`.
  # `closestNodes` holds the k closest nodes to target found, sorted by distance
  # Unvalidated nodes are used for requests as a form of validation.
  var closestNodes = p.routingTable.neighbours(targetId, BUCKET_SIZE,
    seenOnly = false)

  var asked, seen = initHashSet[NodeId]()
  asked.incl(p.baseProtocol.localNode.id) # No need to ask our own node
  seen.incl(p.baseProtocol.localNode.id) # No need to discover our own node
  for node in closestNodes:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[PortalResult[FoundContent]]](alpha)
  var requestAmount = 0'i64

  var nodesWithoutContent: seq[Node] = newSeq[Node]()

  while true:
    var i = 0
    # Doing `alpha` amount of requests at once as long as closer non queried
    # nodes are discovered.
    while i < closestNodes.len and pendingQueries.len < alpha:
      let n = closestNodes[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.findContent(n, target))
        requestAmount.inc()
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query = await one(pendingQueries)
    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let contentResult = query.read

    if contentResult.isOk():
      let content = contentResult.get()

      case content.kind
      of Nodes:
        let maybeRadius = p.radiusCache.get(content.src.id)
        if maybeRadius.isSome() and
            p.inRange(content.src.id, maybeRadius.unsafeGet(), targetId):
          # Only return nodes which may be interested in content.
          # No need to check for duplicates in nodesWithoutContent
          # as requests are never made two times to the same node.
          nodesWithoutContent.add(content.src)

        for n in content.nodes:
          if not seen.containsOrIncl(n.id):
            discard p.routingTable.addNode(n)
            # If it wasn't seen before, insert node while remaining sorted
            closestNodes.insert(n, closestNodes.lowerBound(n,
              proc(x: Node, n: Node): int =
                cmp(p.routingTable.distance(x.id, targetId),
                  p.routingTable.distance(n.id, targetId))
            ))

            if closestNodes.len > BUCKET_SIZE:
              closestNodes.del(closestNodes.high())

      of Content:
        # cancel any pending queries as we have find the content
        for f in pendingQueries:
          f.cancel()
        portal_lookup_content_requests.observe(requestAmount)
        return some(ContentLookupResult.init(content.content, nodesWithoutContent))
    else:
      # TODO: Should we do something with the node that failed responding our
      # query?
      discard

  portal_lookup_content_failures.inc()
  return none[ContentLookupResult]()

proc query*(p: PortalProtocol, target: NodeId, k = BUCKET_SIZE): Future[seq[Node]]
    {.async.} =
  ## Query k nodes for the given target, returns all nodes found, including the
  ## nodes queried.
  ##
  ## This will take k nodes from the routing table closest to target and
  ## query them for nodes closest to target. If there are less than k nodes in
  ## the routing table, nodes returned by the first queries will be used.
  var queryBuffer = p.routingTable.neighbours(target, k, seenOnly = false)

  var asked, seen = initHashSet[NodeId]()
  asked.incl(p.baseProtocol.localNode.id) # No need to ask our own node
  seen.incl(p.baseProtocol.localNode.id) # No need to discover our own node
  for node in queryBuffer:
    seen.incl(node.id)

  var pendingQueries = newSeqOfCap[Future[seq[Node]]](alpha)

  while true:
    var i = 0
    while i < min(queryBuffer.len, k) and pendingQueries.len < alpha:
      let n = queryBuffer[i]
      if not asked.containsOrIncl(n.id):
        pendingQueries.add(p.lookupWorker(n, target))
      inc i

    trace "Pending lookup queries", total = pendingQueries.len

    if pendingQueries.len == 0:
      break

    let query = await one(pendingQueries)
    trace "Got lookup query response"

    let index = pendingQueries.find(query)
    if index != -1:
      pendingQueries.del(index)
    else:
      error "Resulting query should have been in the pending queries"

    let nodes = query.read
    # TODO: Remove node on timed-out query?
    for n in nodes:
      if not seen.containsOrIncl(n.id):
        queryBuffer.add(n)

  p.lastLookup = now(chronos.Moment)
  return queryBuffer

proc queryRandom*(p: PortalProtocol): Future[seq[Node]] =
  ## Perform a query for a random target, return all nodes discovered.
  p.query(NodeId.random(p.baseProtocol.rng[]))

proc neighborhoodGossip*(
    p: PortalProtocol, contentKeys: ContentKeysList, content: seq[byte])
    {.async.} =
  let
    # for now only 1 item is considered
    contentInfo = ContentInfo(contentKey: contentKeys[0], content: content)
    contentList = List[ContentInfo, contentKeysLimit].init(@[contentInfo])
    contentIdOpt = p.toContentId(contentInfo.contentKey)

  if contentIdOpt.isNone():
    return

  let contentId = contentIdOpt.get()

  # Doing an lookup over the network to get the very closest nodes to the
  # content, instead of looking only at our own routing table. This should give
  # a bigger rate of success in case the content is not known yet and avoid
  # data being stopped in its propagation. However, perhaps this causes issues
  # in data getting propagated in a wider id range.
  let closestNodes = await p.lookup(NodeId(contentId))

  for node in closestNodes[0..7]: # selecting closest 8 nodes
    # Note: opportunistically not checking if the radius of the node is known
    # and thus if the node is in radius with the content.
    let req = OfferRequest(dst: node, kind: Direct, contentList: contentList)
    await p.offerQueue.addLast(req)

proc processContent(
    stream: PortalStream, contentKeys: ContentKeysList, content: seq[byte])
    {.gcsafe, raises: [Defect].} =
  let p = getUserData[PortalProtocol](stream)

  # TODO:
  # - Implement a way to discern different content items (e.g. length prefixed)
  # - Check amount of content items according to ContentKeysList
  # - The above could also live in `PortalStream`
  # For now we only consider 1 item being offered
  if contentKeys.len() == 1:
    let contentKey = contentKeys[0]
    if p.validateContent(content, contentKey):
      let contentIdOpt = p.toContentId(contentKey)
      if contentIdOpt.isNone():
        return

      let contentId = contentIdOpt.get()
      # Store content, should we recheck radius?
      p.contentDB.put(contentId, content)

      info "Received valid offered content", contentKey

      asyncSpawn neighborhoodGossip(p, contentKeys, content)
    else:
      error "Received invalid offered content", contentKey

proc seedTable*(p: PortalProtocol) =
  ## Seed the table with specifically provided Portal bootstrap nodes. These are
  ## nodes that must support the wire protocol for the specific content network.
  # Note: We allow replacing the bootstrap nodes in the routing table as it is
  # possible that some of these are not supporting the specific portal network.
  # Other note: One could also pick nodes from the discv5 routing table to
  # bootstrap the portal networks, however it would require a flag in the ENR to
  # be added and there might be none in the routing table due to low amount of
  # Portal nodes versus other nodes.
  logScope:
    protocolId = p.protocolId

  for record in p.bootstrapRecords:
    if p.addNode(record):
      debug "Added bootstrap node", uri = toURI(record),
        protocolId = p.protocolId
    else:
      error "Bootstrap node could not be added", uri = toURI(record),
        protocolId = p.protocolId

proc populateTable(p: PortalProtocol) {.async.} =
  ## Do a set of initial lookups to quickly populate the table.
  # start with a self target query (neighbour nodes)
  logScope:
    protocolId = p.protocolId

  let selfQuery = await p.query(p.baseProtocol.localNode.id)
  trace "Discovered nodes in self target query", nodes = selfQuery.len

  for i in 0..<initialLookups:
    let randomQuery = await p.queryRandom()
    trace "Discovered nodes in random target query", nodes = randomQuery.len

  debug "Total nodes in routing table after populate",
    total = p.routingTable.len()

proc revalidateNode*(p: PortalProtocol, n: Node) {.async.} =
  let pong = await p.ping(n)

  if pong.isOK():
    let res = pong.get()
    if res.enrSeq > n.record.seqNum:
      # Request new ENR
      let nodesMessage = await p.findNodes(n, @[0'u16])
      if nodesMessage.isOk():
        let nodes = nodesMessage.get()
        if nodes.len > 0: # Normally a node should only return 1 record actually
          discard p.routingTable.addNode(nodes[0])

proc revalidateLoop(p: PortalProtocol) {.async.} =
  ## Loop which revalidates the nodes in the routing table by sending the ping
  ## message.
  try:
    while true:
      await sleepAsync(milliseconds(p.baseProtocol.rng[].rand(revalidateMax)))
      let n = p.routingTable.nodeToRevalidate()
      if not n.isNil:
        asyncSpawn p.revalidateNode(n)
  except CancelledError:
    trace "revalidateLoop canceled"

proc refreshLoop(p: PortalProtocol) {.async.} =
  ## Loop that refreshes the routing table by starting a random query in case
  ## no queries were done since `refreshInterval` or more.
  ## It also refreshes the majority address voted for via pong responses.
  logScope:
    protocolId = p.protocolId

  try:
    while true:
      # TODO: It would be nicer and more secure if this was event based and/or
      # steered from the routing table.
      while p.routingTable.len() == 0:
        p.seedTable()
        await p.populateTable()
        await sleepAsync(5.seconds)

      let currentTime = now(chronos.Moment)
      if currentTime > (p.lastLookup + refreshInterval):
        let randomQuery = await p.queryRandom()
        trace "Discovered nodes in random target query", nodes = randomQuery.len
        debug "Total nodes in routing table", total = p.routingTable.len()

      await sleepAsync(refreshInterval)
  except CancelledError:
    trace "refreshLoop canceled"

proc start*(p: PortalProtocol) =
  p.refreshLoop = refreshLoop(p)
  p.revalidateLoop = revalidateLoop(p)

  for i in 0 ..< concurrentOffers:
    p.offerWorkers.add(offerWorker(p))

proc stop*(p: PortalProtocol) =
  if not p.revalidateLoop.isNil:
    p.revalidateLoop.cancel()
  if not p.refreshLoop.isNil:
    p.refreshLoop.cancel()

  for worker in p.offerWorkers:
    worker.cancel()
  p.offerWorkers = @[]

proc resolve*(p: PortalProtocol, id: NodeId): Future[Option[Node]] {.async.} =
  ## Resolve a `Node` based on provided `NodeId`.
  ##
  ## This will first look in the own routing table. If the node is known, it
  ## will try to contact if for newer information. If node is not known or it
  ## does not reply, a lookup is done to see if it can find a (newer) record of
  ## the node on the network.
  if id == p.localNode.id:
    return some(p.localNode)

  let node = p.routingTable.getNode(id)
  if node.isSome():
    let nodesMessage = await p.findNodes(node.get(), @[0'u16])
    # TODO: Handle failures better. E.g. stop on different failures than timeout
    if nodesMessage.isOk() and nodesMessage[].len > 0:
      return some(nodesMessage[][0])

  let discovered = await p.lookup(id)
  for n in discovered:
    if n.id == id:
      if node.isSome() and node.get().record.seqNum >= n.record.seqNum:
        return node
      else:
        return some(n)

  return node
