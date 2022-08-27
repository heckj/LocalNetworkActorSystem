// Actor system which enables distributed actors to communicate over local network, e.g. on the same Wi-Fi network.

import Distributed
import Foundation
import Network
import os

@available(iOS 16.0, macOS 13.0, *)
public final class SampleLocalNetworkActorSystem: DistributedActorSystem,
    @unchecked /* state protected with locks */ Sendable
{
    public typealias ActorID = ActorIdentity
    public typealias InvocationEncoder = SampleLocalNetworkCallEncoder
    public typealias InvocationDecoder = SampleLocalNetworkCallDecoder
    public typealias SerializationRequirement = any Codable
    public typealias ResultHandler = BonjourResultHandler

    let nodeName: String
    let serviceName: String = "_tictacfish._tcp"

    // Internal semaphore for locking to protect state during actor calls
    private let lock = DispatchSemaphore(value: 1)

    private var managedActors: [ActorID: any DistributedActor] = [:]

    private let nwListener: NWListener
    private let browser: Browser

    var peers: [Peer]
    private var _receptionist: LocalNetworkReceptionist!

    
    // === Handle replies
    public typealias CallID = UUID
    private let replyLock = NSLock()
    private var inFlightCalls: [CallID: CheckedContinuation<Data, Error>] = [:]

    var _onPeersChanged: ([Peer]) -> Void = { _ in }

    public var receptionist: LocalNetworkReceptionist {
        _receptionist!
    }

    public init() {
        let nodeID = Int.random(in: 0 ..< Int.max)
        let nodeName = "peer_\(nodeID)"
        self.nodeName = nodeName

        nwListener = try! Self.makeNWListener(nodeName: nodeName, serviceName: serviceName)
        browser = Browser(nodeName: nodeName, serviceName: serviceName)

        peers = []

        // Initialize "system actors"
        _receptionist = LocalNetworkReceptionist(actorSystem: self)

        startNetworking()
    }

    private static func makeNWListener(nodeName _: String, serviceName _: String) throws -> NWListener {
        try NWListener(using: NetworkServiceConstants.networkParameters)
    }

    /// Start the server-side component accepting incoming connections.
    private func startNetworking() {
        // === Kick off the NWListener
        let txtRecord = NWTXTRecord([
            NetworkServiceConstants.txtRecordInstanceIDKey: nodeName,
        ])

        // The name is the unique thing, identifying a node in the peer to peer network
        nwListener.service = NWListener.Service(name: nodeName, type: serviceName, txtRecord: txtRecord)

        nwListener.newConnectionHandler = { (connection: NWConnection) in
            let con = Connection(connection: connection, deliverMessage: { data, nwMessage in
                self.decodeAndDeliver(data: data, nwMessage: nwMessage, from: connection)
            })
            _ = self.addPeer(connection: con, from: "listener")

            connection.start(queue: .main)
        }
        nwListener.start(queue: .main)

        // Kick off the browser for discovery
        browser.start { result in
            self.lock.wait()
            defer {
                self.lock.signal()
            }

            // -----
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 2

            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true

            // add the protocol framing
            let framerOptions = NWProtocolFramer.Options(definition: WireProtocol.definition)
            parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

            let connection = NWConnection(to: result.endpoint, using: parameters)
            // -----

            let peerConnection = Connection(connection: connection, deliverMessage: { data, nwMessage in
                self.decodeAndDeliver(data: data, nwMessage: nwMessage, from: connection)
            })

            _ = self.addPeer(connection: peerConnection, from: "browser")
        }
    }

    private func addPeer(connection: Connection, from _: String) -> Peer? {
        // Peer management should be vastly improved if we needed this sample to
        // extend into a production ready application. We must be able to tell peers
        // coming in from the same "node" on different connections, and only use one
        // of them for communication.

        if case let NWEndpoint.service(endpointName, _, _, _) = connection.connection.endpoint {
            if self.nodeName == endpointName {
                return nil
            }

            guard endpointName.starts(with: "peer_") else {
                return nil
            }
        }

        let peer = Peer(connection: connection)
        peers.append(peer)

        _onPeersChanged(peers)

        return peer
    }

    /// Receive inbound message `Data` and continue to decode, and invoke the local target.
    func decodeAndDeliver(data: Data?, nwMessage: NWProtocolFramer.Message, from _: NWConnection) {
        // log("receive-decode-deliver", "On connection [\(connection)]")
        guard let payload = data else {
            // log("receive-decode-deliver", "[error] On connection [\(connection)], no payload!")
            return
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = self

        // log("receive-decode-deliver", "Start decoding, on connection [\(connection)], data: \(String(data: payload, encoding: .utf8)!)")

        do {
            switch nwMessage.wireMessageType {
            case .invalid:
                log("receive-decode-deliver", "[error] Unknown message type! Data: \(payload))")
            case .remoteCall:
                let callEnvelope = try decoder.decode(RemoteCallEnvelope.self, from: payload)
                receiveInboundCall(envelope: callEnvelope)
            case .reply:
                let replyEnvelope = try decoder.decode(ReplyEnvelope.self, from: payload)
                receiveInboundReply(envelope: replyEnvelope)
            }
        } catch {
            log("receive-decode-deliver",
                "[error] Failed decoding: \(String(data: payload, encoding: .utf8)!)")
        }
    }

    func receiveInboundCall(envelope: RemoteCallEnvelope) {
        Task {
            guard let anyRecipient = resolveAny(id: envelope.recipient, resolveReceptionist: true) else {
                log("deadLetter", "[warn] \(#function) failed to resolve \(envelope.recipient)")
                return
            }
            let target = RemoteCallTarget(envelope.invocationTarget)
            let handler = Self.ResultHandler(callID: envelope.callID, system: self)

            do {
                var decoder = Self.InvocationDecoder(system: self, envelope: envelope)
                func doExecuteDistributedTarget<Act: DistributedActor>(recipient: Act) async throws {
                    try await executeDistributedTarget(
                        on: recipient,
                        target: target,
                        invocationDecoder: &decoder,
                        handler: handler
                    )
                }

                // As implicit opening of existential becomes part of the language,
                // this underscored feature is no longer necessary. Please refer to
                // SE-352 Implicitly Opened Existentials:
                // https://github.com/apple/swift-evolution/blob/main/proposals/0352-implicit-open-existentials.md
                try await _openExistential(anyRecipient, do: doExecuteDistributedTarget)
            } catch {
                log("inbound", "[error] failed to executeDistributedTarget [\(target)] on [\(anyRecipient)], error: \(error)")
                try! await handler.onThrow(error: error)
            }
        }
    }

    func receiveInboundReply(envelope: ReplyEnvelope) {
        log("receive-reply", "Receive reply: \(envelope)")
        replyLock.lock()
        guard let callContinuation = inFlightCalls.removeValue(forKey: envelope.callID) else {
            replyLock.unlock()
            return
        }
        replyLock.unlock()

        callContinuation.resume(returning: envelope.value)
    }

    func resolveAny(id: ActorID, resolveReceptionist: Bool = false) -> (any DistributedActor)? {
        lock.wait()
        defer { lock.signal() }

        if resolveReceptionist, id == ActorID(id: "receptionist") {
            return receptionist
        }

        return managedActors[id]
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor,
        Act.ID == ActorID
    {
        lock.wait()
        defer {
            lock.signal()
        }

        if actorType == LocalNetworkReceptionist.self {
            return nil
        }

        guard let found = managedActors[id] else {
            return nil // definitely remote, we don't know about this ActorID
        }

        guard let wellTyped = found as? Act else {
            throw SampleLocalNetworkActorSystemError.resolveFailedToMatchActorType(found: type(of: found), expected: Act.self)
        }

        return wellTyped
    }

    public func assignID<Act>(_: Act.Type) -> ActorID
        where Act: DistributedActor,
        Act.ID == ActorID
    {
        if Act.self == LocalNetworkReceptionist.self {
            return .init(id: "receptionist")
        }

        let uuid = UUID().uuidString
        let typeFullName = "\(Act.self)"
        guard typeFullName.split(separator: ".").last != nil else {
            return .init(id: uuid)
        }

        return .init(id: "\(uuid)")
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        lock.wait()
        defer {
            self.lock.signal()
        }

        managedActors[actor.id] = actor
    }

    public func resignID(_ id: ActorID) {
        lock.wait()
        defer {
            lock.signal()
        }

        managedActors.removeValue(forKey: id)
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        .init()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: RemoteCall implementations

@available(iOS 16.0, macOS 13.0, *)
extension SampleLocalNetworkActorSystem {
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing _: Err.Type,
        returning _: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error,
        Res: Codable
    {
        log("remoteCall", "remoteCall [\(target)] on remote \(actor.id)")
        
        // Discussion about the warning:
        //   Instance method 'lock' is unavailable from asynchronous contexts;
        //   Use async-safe scoped locking instead; this is an error in Swift 6
        // for the lock.lock() and lock.unlock() just below.
        // https://forums.swift.org/t/pitch-unavailability-from-asynchronous-contexts/53877
        lock.wait()

        // after switching to a DispatchSemaphore, it's reporting:
        //   Instance method 'wait' is unavailable from asynchronous contexts;
        //   Await a Task handle instead; this is an error in Swift 6
        
        guard !peers.isEmpty else {
            log("remoteCall", "No peers")

            lock.signal()
            throw SampleLocalNetworkActorSystemError.noPeers
        }

        let replyData = try await withCallIDContinuation(recipient: actor) { callID in
            // In this naive sample implementation, we are prepared to really just work
            // between two peers for the sample app purposes. In a real system implementation
            // we should select the right peer (connection) for the given actor (i.e.
            // since we know where it is located, based the ID to connection mappings),
            // and then select only that specific peer.
            //
            // In this naive implementation though, we simply broadcast the remote call.
            for peer in self.peers {
                self.sendRemoteCall(to: actor, target: target, invocation: invocation, callID: callID, peer: peer)
            }
            self.lock.signal()
        }

        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = self

        do {
            return try decoder.decode(Res.self, from: replyData)
        } catch {
            throw SampleLocalNetworkActorSystemError.failedDecodingResponse(data: replyData, error: error)
        }
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing _: Err.Type
    ) async throws
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error
    {
        
        log("system", "remoteCallVoid [\(target)] on remote \(actor.id)")
        lock.wait()

        guard !peers.isEmpty else {
            log("remoteCall", "No peers")
            
            lock.signal()
            // throw SampleLocalNetworkActorSystemError.noPeers
            return
        }

        _ = try await withCallIDContinuation(recipient: actor) { callID in
            // In this naive sample implementation, we are prepared to really just work
            // between two peers for the sample app purposes. In a real system implementation
            // we should select the right peer (connection) for the given actor (i.e.
            // since we know where it is located, based the ID to connection mappings),
            // and then select only that specific peer.
            //
            // In this naive implementation though, we simply broadcast the remote call.
            for peer in self.peers {
                self.sendRemoteCall(to: actor, target: target, invocation: invocation, callID: callID, peer: peer)
            }
            self.lock.signal()
        }
    }

    private func sendRemoteCall<Act>(
        to actor: Act,
        target: RemoteCallTarget,
        invocation: InvocationEncoder,
        callID: CallID,
        peer: Peer
    ) where Act: DistributedActor, Act.ID == ActorID {
        Task {
            let encoder = JSONEncoder()

            let callEnvelope = RemoteCallEnvelope(
                callID: callID,
                recipient: actor.id,
                invocationTarget: target.identifier,
                genericSubs: invocation.genericSubs,
                args: invocation.argumentData
            )
            let payload = try encoder.encode(callEnvelope)

            print("[remoteCall] Send to [\(actor.id)] message: \(String(data: payload, encoding: .utf8)!)")
            peer.connection.sendRemoteCall(payload)

            // This must be resumed by an incoming rely resuming the continuation stored for this 'callID'
        }
    }

    private func withCallIDContinuation<Act>(recipient _: Act, body: (CallID) -> Void) async throws -> Data
        where Act: DistributedActor
    {
        try await withCheckedThrowingContinuation { continuation in
            self.replyLock.lock()
            defer {
                self.replyLock.unlock()
            }
            let callID = UUID()
            self.inFlightCalls[callID] = continuation
            body(callID)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Reply handling

@available(iOS 16.0, macOS 13.0, *)
extension SampleLocalNetworkActorSystem {
    func sendReply(_ envelope: ReplyEnvelope) throws {
        lock.wait()
        defer {
            self.lock.signal()
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)

        // A more advanced implementation would pick the right connection rather than
        // send to all peers. For this sample app this is enough though, since we
        // assume two peers.
        for peer in peers {
            print("reply", "Sending reply for [\(envelope.callID)] on \(peer.connection.connection)")
            peer.connection.sendReply(data)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Other

@available(iOS 16.0, macOS 13.0, *)
extension SampleLocalNetworkActorSystem {
    func selectPeer(for _: ActorID) -> Peer? {
        // Naive implementation; would normally need to maintain an ID -> Peer mapping.
        peers.first
    }
}

@available(iOS 16.0, macOS 13.0, *)
extension SampleLocalNetworkActorSystem {
    func onPeersChanged(_ callback: @escaping @Sendable ([Peer]) -> Void) {
        lock.wait()
        defer {
            self.lock.signal()
        }

        _onPeersChanged = callback
    }
}

@available(iOS 16.0, macOS 13.0, *)
extension Logger {
    static let server = os.Logger(subsystem: "com.example.apple.swift.distributed", category: "server")
}

@available(iOS 16.0, macOS 13.0, *)
public struct BonjourResultHandler: Distributed.DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Codable

    let callID: SampleLocalNetworkActorSystem.CallID
    let system: SampleLocalNetworkActorSystem

    public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
        let encoder = JSONEncoder()
        let returnValue = try encoder.encode(value)
        let envelope = ReplyEnvelope(callID: callID, sender: nil, value: returnValue)
        try system.sendReply(envelope)
    }

    public func onReturnVoid() async throws {
        let envelope = ReplyEnvelope(callID: callID, sender: nil, value: "".data(using: .utf8)!)
        try system.sendReply(envelope)
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        log("handler", "onThrow: \(error)")
    }
}

public enum SampleLocalNetworkActorSystemError: Error, DistributedActorSystemError {
    case resolveFailedToMatchActorType(found: Any.Type, expected: Any.Type)
    case noPeers
    case notEnoughArgumentsInEnvelope(expected: Any.Type)
    case failedDecodingResponse(data: Data, error: Error)
}

// ==== ----------------------------------------------------------------------------------------------------------------

typealias ReceiveData = (Data) throws -> Void

enum NetworkServiceConstants {
    static let txtRecordInstanceIDKey = "instanceID"

    static var networkParameters: NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true // Bonjour

        // add the protocol framing
        let framerOptions = NWProtocolFramer.Options(definition: WireProtocol.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        return parameters
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct Peer: Sendable {
    let connection: Connection
}

@available(iOS 16.0, macOS 13.0, *)
struct RemoteCallEnvelope: Sendable, Codable {
    let callID: SampleLocalNetworkActorSystem.CallID
    let recipient: SampleLocalNetworkActorSystem.ActorID
    let invocationTarget: String
    let genericSubs: [String]
    let args: [Data]
}

@available(iOS 16.0, macOS 13.0, *)
struct ReplyEnvelope: Sendable, Codable {
    let callID: SampleLocalNetworkActorSystem.CallID
    let sender: SampleLocalNetworkActorSystem.ActorID?
    let value: Data
}
