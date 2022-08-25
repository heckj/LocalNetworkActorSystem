// Encoder type that is used to encode remote calls.

import Distributed
import Foundation
import Network
import os

@available(iOS 16.0, macOS 13.0, *)
public class SampleLocalNetworkCallEncoder: DistributedTargetInvocationEncoder,
    @unchecked Sendable
{
    public typealias SerializationRequirement = Codable

    var genericSubs: [String] = []
    var argumentData: [Data] = []

    public func recordGenericSubstitution<T>(_: T.Type) throws {
        if let name = _mangledTypeName(T.self) {
            genericSubs.append(name)
        }
    }

    public func recordArgument<Value: SerializationRequirement>(_ argument: RemoteCallArgument<Value>) throws {
        let data = try JSONEncoder().encode(argument.value)
        argumentData.append(data)
    }

    public func recordReturnType<R: SerializationRequirement>(_: R.Type) throws {
        // noop, no need to record it in this system
    }

    public func recordErrorType<E: Error>(_: E.Type) throws {
        // noop, no need to record it in this system
    }

    public func doneRecording() throws {
        // noop, nothing to do in this system
    }
}
