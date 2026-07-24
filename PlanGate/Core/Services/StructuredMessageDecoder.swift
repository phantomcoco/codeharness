import CryptoKit
import Foundation

public struct StructuredMessageDecoder: Sendable {
    public init() {}

    public func jsonEnvelopeData(from text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let json = Self.firstBalancedJSONObject(in: trimmed),
              let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw AppFailure.planDecodingFailed("No valid JSON object found in model output.")
        }
        return data
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    public func decodeEnvelopeHeader(_ data: Data) throws -> ModelMessageType {
        PlanGateTrace.log("message.decodeHeader.start bytes=\(data.count)")
        struct Header: Decodable { let protocolVersion: Int; let type: ModelMessageType }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.protocolVersion == 1 else { throw AppFailure.unsupportedProtocolVersion(header.protocolVersion) }
            PlanGateTrace.log("message.decodeHeader.done type=\(header.type)")
            return header.type
        } catch let error as AppFailure {
            throw error
        } catch {
            throw AppFailure.planDecodingFailed(Self.describeDecodingError(error))
        }
    }

    public func decodePlan(_ text: String, requestID: UUID, task: PlanGateTask, workspace: Workspace, model: ModelConfiguration, guidance: BehaviorGuidance, date: Date) throws -> ProposedPlan {
        PlanGateTrace.log("message.decodePlan.start requestID=\(requestID) chars=\(text.count)")
        let data = try jsonEnvelopeData(from: text)
        guard try decodeEnvelopeHeader(data) == .plan else { throw AppFailure.wrongMessageForState("expected plan") }
        do {
            let envelope = try JSONDecoder().decode(ModelEnvelope<PlanPayload>.self, from: data)
            guard envelope.requestID == requestID else { throw AppFailure.wrongMessageForState("request id mismatch") }
            let plan = ProposedPlan(
                taskID: task.id,
                taskText: task.text,
                workspaceCanonicalPath: workspace.canonicalRootURL.path,
                modelIdentifier: model.identifier,
                guidanceDigest: guidance.digest,
                summary: envelope.payload.summary,
                actions: envelope.payload.actions,
                createdAt: date
            )
            PlanGateTrace.log("message.decodePlan.done requestID=\(requestID) actions=\(plan.actions.count)")
            return plan
        } catch let error as AppFailure {
            throw error
        } catch {
            throw AppFailure.planDecodingFailed(Self.describeDecodingError(error))
        }
    }

    public func decodeAct(_ text: String, requestID: UUID) throws -> ActPayload {
        PlanGateTrace.log("message.decodeAct.start requestID=\(requestID) chars=\(text.count)")
        let data = try jsonEnvelopeData(from: text)
        guard try decodeEnvelopeHeader(data) == .act else { throw AppFailure.wrongMessageForState("expected act") }
        let envelope = try JSONDecoder().decode(ModelEnvelope<ActPayload>.self, from: data)
        guard envelope.requestID == requestID else { throw AppFailure.wrongMessageForState("request id mismatch") }
        PlanGateTrace.log("message.decodeAct.done requestID=\(requestID) actionID=\(envelope.payload.actionID)")
        return envelope.payload
    }

    private static func describeDecodingError(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let value = codingPath.map { key in
                if let index = key.intValue { return "\(index)" }
                return key.stringValue
            }.joined(separator: ".")
            return value.isEmpty ? "<root>" : value
        }

        switch error {
        case DecodingError.keyNotFound(let key, let context):
            let prefix = path(context.codingPath)
            let fullPath = prefix == "<root>" ? key.stringValue : "\(prefix).\(key.stringValue)"
            return "Missing key \(fullPath): \(context.debugDescription)"
        case DecodingError.typeMismatch(_, let context):
            return "Type mismatch at \(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.valueNotFound(_, let context):
            return "Missing value at \(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            return "Data corrupted at \(path(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}
