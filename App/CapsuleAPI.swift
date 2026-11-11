import Foundation

struct Capsule: Identifiable, Decodable, Sendable, Equatable {
    let id: String
    /// "sealed", "ready" (unlocked, never opened) or "opened", as the server saw it.
    let status: String
    let sealedAt: Date
    let unlocksAt: Date
    let openedAt: Date?
    let secondsRemaining: Int
    let serverNow: Date
    /// Only present once the capsule has been opened. The server never sends it while sealed.
    let message: String?
}

enum OpenResult: Sendable {
    case opened(Capsule)
    case stillSealed(Capsule)
}

struct APIError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "The vault answered \(status): \(body)" }
}

struct CapsuleAPI: Sendable {
    let baseURL: URL

    /// UI tests (and CI) point the app at a different server with the API_URL environment variable.
    static let live = CapsuleAPI(
        baseURL: URL(string: ProcessInfo.processInfo.environment["API_URL"] ?? "http://localhost:8787")!
    )

    func list() async throws -> [Capsule] {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "capsules"))
        try Self.expect(response, data, [200])
        return try Self.decoder().decode([Capsule].self, from: data)
    }

    func seal(message: String, seconds: Int) async throws -> Capsule {
        var request = URLRequest(url: baseURL.appending(path: "capsules"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": message,
            "unlockInSeconds": seconds,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.expect(response, data, [201])
        return try Self.decoder().decode(Capsule.self, from: data)
    }

    /// Asks the server to open a capsule. The server decides; a sealed capsule comes back as 423 Locked.
    func open(id: String) async throws -> OpenResult {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "capsules/\(id)"))
        try Self.expect(response, data, [200, 423])
        let capsule = try Self.decoder().decode(Capsule.self, from: data)
        return (response as? HTTPURLResponse)?.statusCode == 423 ? .stillSealed(capsule) : .opened(capsule)
    }

    private static func expect(_ response: URLResponse, _ data: Data, _ codes: Set<Int>) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard codes.contains(status) else {
            throw APIError(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
        }
        return decoder
    }
}
