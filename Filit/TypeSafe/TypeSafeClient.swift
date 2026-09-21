import Foundation

enum TypeSafeError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case decoding
    case emptyCandidates

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Missing TypeSafe API key"
        case .http(let code, let body): return "TypeSafe HTTP \(code): \(body)"
        case .decoding: return "Could not decode TypeSafe response"
        case .emptyCandidates: return "No candidates to send"
        }
    }
}

final class TypeSafeClient: @unchecked Sendable {
    static let noneOption = "none"

    private let keychain: KeychainStore
    private let session: URLSession
    private let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    init(keychain: KeychainStore, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    func pickCandidate(
        field: FieldContext,
        sourceExcerpt: String?,
        candidates: [Candidate]
    ) async throws -> PickResult {
        guard let apiKey = keychain.apiKey, !apiKey.isEmpty else {
            throw TypeSafeError.missingAPIKey
        }
        guard !candidates.isEmpty else { throw TypeSafeError.emptyCandidates }

        var criteria: [String: Any] = [:]
        for c in candidates {
            criteria[c.id] = c.value
        }
        criteria[Self.noneOption] = "None of these candidates belongs in the focused field."

        var state: [String: Any] = [
            "field": [
                "label": field.label,
                "placeholder": field.placeholder,
                "role": field.role,
                "description": field.description,
                "nearby": field.nearby,
            ] as [String: String],
            "candidates": candidates.map { ["id": $0.id, "value": $0.value, "origin": $0.origin] },
        ]
        if let sourceExcerpt, !sourceExcerpt.isEmpty {
            state["source_excerpt"] = sourceExcerpt
        }

        let body: [String: Any] = [
            "state": state,
            "model": "jev-latest",
            "questions": [
                "pick": [
                    "type": "choice",
                    "instructions": [
                        "question": "Which candidate value belongs in the focused field?",
                        "guidance": "Use `field` label, placeholder, and nearby text to decide. Prefer verbatim `candidates` values. Choose none if nothing fits.",
                    ],
                    "criteria": criteria,
                ] as [String: Any],
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TypeSafeError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TypeSafeError.http(http.statusCode, text)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let answers = json["answers"] as? [String: Any],
            let pick = answers["pick"] as? [String: Any],
            let choice = pick["choice"] as? String
        else {
            throw TypeSafeError.decoding
        }

        let usageDict = json["usage"] as? [String: Any]
        let usage = TokenUsage(
            inputTokens: usageDict?["input_tokens"] as? Int ?? 0,
            outputTokens: usageDict?["output_tokens"] as? Int ?? 0
        )
        return PickResult(choice: choice, usage: usage)
    }
}
