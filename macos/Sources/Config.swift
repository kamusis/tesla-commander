import Foundation

/// Resolves environment variables and configuration for Tesla Commander.
/// Priority:
/// 1. Direct process environment (`ProcessInfo`)
/// 2. Local `.env` files in working directory or parent directories
/// 3. Standard user shell configuration files (`.zshenv`, `.zshrc`, `.bashrc`, etc.)
public final class Config {
    public static let shared = Config()

    public let token: String
    public let vin: String

    private init() {
        let resolvedToken = Config.lookupEnv("TESSIE_ACCESS_TOKEN")
            ?? Config.lookupEnv("TESSIE_API_KEY")
            ?? ""

        let resolvedVin = Config.lookupEnv("MY_TESLA_VIN")
            ?? Config.lookupEnv("TESLA_VIN")
            ?? ""

        self.token = resolvedToken
        self.vin = resolvedVin
    }

    /// Searches for a key across process environment and profile files.
    public static func lookupEnv(_ key: String) -> String? {
        // 1. Process environment
        if let val = ProcessInfo.processInfo.environment[key], !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return val.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Candidate configuration files
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let cwd = fileManager.currentDirectoryPath

        let candidatePaths = [
            (cwd as NSString).appendingPathComponent(".env"),
            ((cwd as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".env"),
            (home as NSString).appendingPathComponent(".zshenv"),
            (home as NSString).appendingPathComponent(".zshrc"),
            (home as NSString).appendingPathComponent(".bashrc"),
            (home as NSString).appendingPathComponent(".bash_profile"),
            (home as NSString).appendingPathComponent(".profile"),
            (home as NSString).appendingPathComponent(".config/tesla-commander/config"),
            (home as NSString).appendingPathComponent(".config/fish/config.fish")
        ]

        for path in candidatePaths {
            guard fileManager.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }

            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                }

                // Match export KEY="val" or KEY=val
                if let val = extractValue(from: trimmed, key: key) {
                    return val
                }
            }
        }

        return nil
    }

    private static func extractValue(from line: String, key: String) -> String? {
        var str = line
        if str.hasPrefix("export ") {
            str = String(str.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else if str.hasPrefix("set -gx ") {
            // Fish shell syntax
            str = String(str.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            let parts = str.components(separatedBy: .whitespaces)
            if parts.count >= 2 && parts[0] == key {
                return cleanQuotes(parts.dropFirst().joined(separator: " "))
            }
        }

        guard let equalIndex = str.firstIndex(of: "=") else { return nil }
        let k = String(str[..<equalIndex]).trimmingCharacters(in: .whitespaces)
        if k == key {
            let v = String(str[str.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)
            return cleanQuotes(v)
        }

        return nil
    }

    private static func cleanQuotes(_ raw: String) -> String {
        var res = raw
        if (res.hasPrefix("\"") && res.hasSuffix("\"")) || (res.hasPrefix("'") && res.hasSuffix("'")) {
            res = String(res.dropFirst().dropLast())
        }
        return res.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
