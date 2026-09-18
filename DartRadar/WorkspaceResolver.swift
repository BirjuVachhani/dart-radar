import Foundation

/// Asks a Dart Tooling Daemon which workspace its IDE window has open.
///
/// This is deliberately NOT the process's project. One DTD serves a whole
/// editor window, and that window may hold many packages, so the answer is
/// ownership context ("this process belongs to the window editing X") rather
/// than a claim about which package the process is working on.
///
/// The daemon speaks JSON-RPC over a WebSocket and authenticates with a secret
/// that appears only in the URI of a sibling `dart devtools --dtd-uri` process.
enum WorkspaceResolver {
    /// Returns the first IDE workspace root, or nil if the daemon does not
    /// answer in time, rejects the secret, or reports no roots.
    static func workspaceRoot(dtd uri: URL, timeout: Duration = .seconds(3)) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await query(uri) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func query(_ uri: URL) async -> String? {
        // ws://127.0.0.1:<port>/<secret>
        let secret = uri.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !secret.isEmpty else { return nil }

        let task = URLSession.shared.webSocketTask(with: uri)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "1",
            "method": "FileSystem.getIDEWorkspaceRoots",
            "params": ["secret": secret],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: data, encoding: .utf8) else { return nil }

        do {
            try await task.send(.string(text))
            guard case .string(let reply) = try await task.receive() else { return nil }
            return firstRoot(in: reply)
        } catch {
            return nil  // daemon gone, secret rejected, or connection refused
        }
    }

    /// Parses `{"result":{"ideWorkspaceRoots":["file:///path", …]}}`.
    static func firstRoot(in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let roots = result["ideWorkspaceRoots"] as? [String],
              let first = roots.first,
              let url = URL(string: first), url.isFileURL else { return nil }
        // Trailing slashes come back on some roots; normalise for display.
        return url.standardizedFileURL.path
    }
}
