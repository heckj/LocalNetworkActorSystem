// Decoder type that is used to decode remote calls.

import Distributed
import Foundation
import Network
import os

@available(iOS 16.0, macOS 13.0, *)
public class SampleLocalNetworkCallDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable

    let decoder: JSONDecoder
    let envelope: RemoteCallEnvelope
    var argumentsIterator: Array<Data>.Iterator

    init(system: SampleLocalNetworkActorSystem, envelope: RemoteCallEnvelope) {
        self.envelope = envelope
        argumentsIterator = envelope.args.makeIterator()

        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = system
        self.decoder = decoder
    }

    public func decodeGenericSubstitutions() throws -> [Any.Type] {
        envelope.genericSubs.compactMap { name in
            _typeByName(name)
        }
    }

    public func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard let data = argumentsIterator.next() else {
            throw SampleLocalNetworkActorSystemError.notEnoughArgumentsInEnvelope(expected: Argument.self)
        }

        return try decoder.decode(Argument.self, from: data)
    }

    public func decodeErrorType() throws -> Any.Type? {
        nil // not encoded, ok
    }

    public func decodeReturnType() throws -> Any.Type? {
        nil // not encoded, ok
    }
}
