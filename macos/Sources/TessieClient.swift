import Foundation

/// Native REST API client for Tessie endpoints using Swift async/await and URLSession.
public final class TessieClient {
    private let baseURL = "https://api.tessie.com"
    private let token: String
    public private(set) var vin: String
    private let session: URLSession

    public init(token: String, vin: String = "") {
        self.token = token
        self.vin = vin
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        self.session = URLSession(configuration: config)
    }

    /// Lists all vehicles associated with the account.
    public func fetchVehicles() async throws -> [[String: Any]] {
        let resp = try await request(path: "/vehicles", method: "GET")
        return resp["results"] as? [[String: Any]] ?? []
    }

    /// Dynamically resolves active VIN if not explicitly configured in environment.
    public func resolveVin() async throws -> String {
        if !self.vin.isEmpty {
            return self.vin
        }
        let vehicles = try await fetchVehicles()
        if let active = vehicles.first(where: { ($0["is_active"] as? Bool) == true }),
           let v = active["vin"] as? String {
            self.vin = v
            return v
        }
        if let first = vehicles.first, let v = first["vin"] as? String {
            self.vin = v
            return v
        }
        throw NSError(domain: "TessieClientError", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active Tesla vehicle found in account."])
    }

    /// Fetches complete latest vehicle state.
    public func fetchState() async throws -> [String: Any] {
        let activeVin = try await resolveVin()
        return try await request(path: "/\(activeVin)/state", method: "GET")
    }

    /// Fetches current GPS coordinates and street address.
    public func fetchLocation() async throws -> [String: Any] {
        let activeVin = try await resolveVin()
        return try await request(path: "/\(activeVin)/location", method: "GET")
    }

    /// Fetches historical driving sessions.
    public func fetchDrives(limit: Int = 20) async throws -> [[String: Any]] {
        let activeVin = try await resolveVin()
        let resp = try await request(path: "/\(activeVin)/drives", method: "GET", queryParams: ["limit": "\(limit)"])
        return resp["results"] as? [[String: Any]] ?? []
    }

    /// Fetches GPS breadcrumb path points for a driving session during a timeframe.
    public func fetchDrivingPath(from: Int, to: Int, details: Bool = true) async throws -> [[String: Any]] {
        let activeVin = try await resolveVin()
        let queryParams = [
            "from": "\(from)",
            "to": "\(to)",
            "details": details ? "true" : "false",
            "simplify": "false"
        ]
        let resp = try await request(path: "/\(activeVin)/path", method: "GET", queryParams: queryParams)
        return resp["results"] as? [[String: Any]] ?? []
    }

    /// Fetches historical charging sessions.
    public func fetchCharges(limit: Int = 10) async throws -> [[String: Any]] {
        let activeVin = try await resolveVin()
        let resp = try await request(path: "/\(activeVin)/charges", method: "GET", queryParams: ["limit": "\(limit)"])
        return resp["results"] as? [[String: Any]] ?? []
    }

    /// Dispatches a high-level UI command to vehicle via Tessie.
    public func executeCommand(action: String, params: [String: Any] = [:]) async throws -> (success: Bool, message: String) {
        let activeVin = try await resolveVin()
        var endpoint = ""
        var queryParams: [String: String] = [:]

        switch action {
        case "honk":
            endpoint = "/\(activeVin)/command/honk"
        case "flash":
            endpoint = "/\(activeVin)/command/flash_lights"
        case "lock":
            endpoint = "/\(activeVin)/command/lock"
        case "unlock":
            endpoint = "/\(activeVin)/command/unlock"
        case "start_climate":
            endpoint = "/\(activeVin)/command/start_climate"
        case "stop_climate":
            endpoint = "/\(activeVin)/command/stop_climate"
        case "set_temperature":
            endpoint = "/\(activeVin)/command/set_temperature"
            if let temp = params["temperature"] as? Double {
                queryParams["temperature"] = String(format: "%.1f", temp)
            }
        case "nav":
            endpoint = "/\(activeVin)/command/share"
            if let dest = params["destination"] as? String {
                queryParams["value"] = dest
                queryParams["locale"] = "ja-JP"
                queryParams["wait_for_completion"] = "true"
            }
        case "set_charge_limit":
            endpoint = "/\(activeVin)/command/set_charge_limit"
            if let limit = params["limit"] as? Int {
                queryParams["percent"] = "\(limit)"
            }
        case "stop_charging":
            endpoint = "/\(activeVin)/command/stop_charging"
        case "start_charging":
            endpoint = "/\(activeVin)/command/start_charging"
        case "vent":
            endpoint = "/\(activeVin)/command/vent_windows"
        case "close_windows":
            endpoint = "/\(activeVin)/command/close_windows"
        case "sentry_on":
            endpoint = "/\(activeVin)/command/enable_sentry"
        case "sentry_off":
            endpoint = "/\(activeVin)/command/disable_sentry"
        case "wake":
            endpoint = "/\(activeVin)/wake"
        default:
            endpoint = "/\(activeVin)/command/\(action)"
        }

        let resp = try await request(path: endpoint, method: "POST", queryParams: queryParams)

        let result = resp["result"] as? Bool ?? (resp["state"] != nil)
        let reason = resp["reason"] as? String ?? resp["error"] as? String ?? "OK"
        return (result, reason)
    }

    private func request(path: String, method: String, queryParams: [String: String]? = nil) async throws -> [String: Any] {
        var components = URLComponents(string: "\(baseURL)\(path)")
        if let queryParams = queryParams, !queryParams.isEmpty {
            components?.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("TeslaCommander-macOS/2.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "TessieClientError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        if data.isEmpty {
            return [:]
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json
    }
}
