import Foundation

/// Candidate destination resolved by AI or mapping engines.
public struct NavCandidate: Codable {
    public let name: String
    public let address: String
    public let lat: Double
    public let lng: Double
    public let distanceKm: Double?
    public let engine: String

    public init(name: String, address: String, lat: Double, lng: Double, distanceKm: Double? = nil, engine: String) {
        self.name = name
        self.address = address
        self.lat = lat
        self.lng = lng
        self.distanceKm = distanceKm
        self.engine = engine
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "address": address,
            "lat": lat,
            "lng": lng,
            "engine": engine
        ]
        if let d = distanceKm {
            dict["distance_km"] = d
        }
        return dict
    }
}

/// Result returned from GeoResolver.
public struct GeoResolveResult {
    public let success: Bool
    public let query: String
    public let engine: String
    public let isFallback: Bool
    public let fallbackReason: String?
    public let candidates: [NavCandidate]
    public let errorMessage: String?

    public init(
        success: Bool,
        query: String,
        engine: String,
        isFallback: Bool = false,
        fallbackReason: String? = nil,
        candidates: [NavCandidate] = [],
        errorMessage: String? = nil
    ) {
        self.success = success
        self.query = query
        self.engine = engine
        self.isFallback = isFallback
        self.fallbackReason = fallbackReason
        self.candidates = candidates
        self.errorMessage = errorMessage
    }
}

/// Dual-engine Geographic Resolver for Tesla Commander:
/// 1. Vertex AI (Gemini 3.8 Flash) via VERTEX_API_KEY with spatial context & multi-candidate ranking.
/// 2. OpenStreetMap Nominatim fallback when Vertex AI is missing or encounters errors.
/// 3. Direct Coordinate parsing (lat,lng).
public final class GeoResolver {
    public static let shared = GeoResolver()

    private let vertexKey: String?

    public init(vertexKey: String? = nil) {
        self.vertexKey = vertexKey ?? Config.lookupEnv("VERTEX_API_KEY")
    }

    /// Resolves natural language query to candidate destinations.
    public func resolve(
        query: String,
        currentLocation: (Double, Double)? = nil,
        locationDesc: String? = nil
    ) async -> GeoResolveResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GeoResolveResult(
                success: false,
                query: query,
                engine: "none",
                errorMessage: "查询关键词不能为空"
            )
        }

        // 1. Direct coordinate format check: "35.1548, 136.9894" or "35.1548,136.9894"
        let coordRegex = #"^[-+]?([1-8]?\d(\.\d+)?|90(\.0+)?),\s*[-+]?(180(\.0+)?|((1[0-7]\d)|([1-9]?\d))(\.\d+)?)$"#
        if let range = trimmed.range(of: coordRegex, options: .regularExpression), range.lowerBound == trimmed.startIndex && range.upperBound == trimmed.endIndex {
            let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]) {
                var dist: Double? = nil
                if let (cLat, cLng) = currentLocation {
                    dist = Self.haversineDistanceKm(lat1: cLat, lon1: cLng, lat2: lat, lon2: lng)
                }
                let cand = NavCandidate(
                    name: "自定义地理坐标",
                    address: String(format: "%.5f, %.5f", lat, lng),
                    lat: lat,
                    lng: lng,
                    distanceKm: dist,
                    engine: "direct_coordinates"
                )
                return GeoResolveResult(
                    success: true,
                    query: query,
                    engine: "direct_coordinates",
                    isFallback: false,
                    candidates: [cand]
                )
            }
        }

        // 2. Vertex AI Primary Engine
        var fallbackReason = "No VERTEX_API_KEY configured"
        let effectiveKey = vertexKey ?? Config.lookupEnv("VERTEX_API_KEY")
        if let key = effectiveKey, !key.isEmpty {
            do {
                let candidates = try await resolveViaVertex(
                    query: trimmed,
                    key: key,
                    currentLocation: currentLocation,
                    locationDesc: locationDesc
                )
                if !candidates.isEmpty {
                    return GeoResolveResult(
                        success: true,
                        query: query,
                        engine: "vertex_ai_gemini_3_8_flash",
                        isFallback: false,
                        candidates: candidates
                    )
                } else {
                    fallbackReason = "Vertex AI 未返回有效候选地址"
                }
            } catch {
                fallbackReason = "Vertex AI 解算异常: \(error.localizedDescription)"
                print("[GeoResolver] Vertex AI error: \(error), falling back to OpenStreetMap...")
            }
        }

        // 3. OpenStreetMap Nominatim Fallback
        do {
            let candidates = try await resolveViaOSM(
                query: trimmed,
                currentLocation: currentLocation
            )
            if !candidates.isEmpty {
                return GeoResolveResult(
                    success: true,
                    query: query,
                    engine: "openstreetmap_nominatim",
                    isFallback: true,
                    fallbackReason: fallbackReason,
                    candidates: candidates
                )
            } else {
                return GeoResolveResult(
                    success: false,
                    query: query,
                    engine: "openstreetmap_nominatim",
                    isFallback: true,
                    fallbackReason: fallbackReason,
                    errorMessage: "未能检索到与「\(trimmed)」匹配的目的地"
                )
            }
        } catch {
            return GeoResolveResult(
                success: false,
                query: query,
                engine: "openstreetmap_nominatim",
                isFallback: true,
                fallbackReason: fallbackReason,
                errorMessage: "地理检索失败: \(error.localizedDescription)"
            )
        }
    }

    /// Calls Vertex AI (Gemini 3.8 Flash) with relative spatial awareness.
    private func resolveViaVertex(
        query: String,
        key: String,
        currentLocation: (Double, Double)?,
        locationDesc: String?
    ) async throws -> [NavCandidate] {
        let endpoint = "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.8-flash:generateContent"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var context = ""
        if let (cLat, cLng) = currentLocation {
            context = "The vehicle is currently located at latitude \(cLat), longitude \(cLng)"
            if let desc = locationDesc, !desc.isEmpty {
                context += " (\(desc))"
            }
            context += ". Take this vehicle position into account if the query is relative (e.g. 'nearest', 'nearby', '附近的', '离我最近的', '附近的星巴克')."
        }

        let prompt = """
        The user wants to navigate their car in Japan to: "\(query)".
        \(context)
        Task: Identify matching destination(s) intended by the user. Provide up to 4 most relevant candidates.
        For each candidate, provide:
        - "name": official Japanese or common place/store name (e.g. "スターバックス コーヒー 栄レイヤード久屋大通パーク店")
        - "address": complete and precise Japanese street address
        - "lat": physical GPS latitude (number)
        - "lng": physical GPS longitude (number)
        Respond strictly in JSON format with schema:
        {"candidates": [{"name": string, "address": string, "lat": number, "lng": number}]}
        """

        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "thinkingConfig": ["thinkingBudget": 0]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 18.0

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "GeoResolver", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidateList = json["candidates"] as? [[String: Any]],
              let firstCand = candidateList.first,
              let content = firstCand["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let partText = parts.first?["text"] as? String,
              let innerData = partText.data(using: .utf8) else {
            throw NSError(domain: "GeoResolver", code: 422, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response structure from Vertex AI"])
        }

        var results: [NavCandidate] = []
        var items: [[String: Any]] = []
        if let innerJson = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] {
            if let cands = innerJson["candidates"] as? [[String: Any]] {
                items = cands
            } else if innerJson["lat"] != nil && innerJson["lng"] != nil {
                items = [innerJson]
            }
        } else if let innerArr = try? JSONSerialization.jsonObject(with: innerData) as? [[String: Any]] {
            items = innerArr
        }

        for item in items {
            let latVal: Double?
            if let d = item["lat"] as? Double {
                latVal = d
            } else if let num = item["lat"] as? NSNumber {
                latVal = num.doubleValue
            } else if let s = item["lat"] as? String {
                latVal = Double(s)
            } else {
                latVal = nil
            }

            let lngVal: Double?
            if let d = item["lng"] as? Double {
                lngVal = d
            } else if let num = item["lng"] as? NSNumber {
                lngVal = num.doubleValue
            } else if let s = item["lng"] as? String {
                lngVal = Double(s)
            } else {
                lngVal = nil
            }

            if let name = item["name"] as? String, let lat = latVal, let lng = lngVal {
                let addr = item["address"] as? String ?? ""
                var dist: Double? = nil
                if let (cLat, cLng) = currentLocation {
                    dist = Self.haversineDistanceKm(lat1: cLat, lon1: cLng, lat2: lat, lon2: lng)
                }
                results.append(NavCandidate(
                    name: name,
                    address: addr,
                    lat: lat,
                    lng: lng,
                    distanceKm: dist,
                    engine: "vertex_ai_gemini_3_8_flash"
                ))
            }
        }

        // Sort by distance if distance available
        if currentLocation != nil {
            results.sort { ($0.distanceKm ?? 999999) < ($1.distanceKm ?? 999999) }
        }

        return results
    }

    /// Queries OpenStreetMap Nominatim with viewbox bias around current location.
    private func resolveViaOSM(
        query: String,
        currentLocation: (Double, Double)?
    ) async throws -> [NavCandidate] {
        // Strip common prefix/suffix in Chinese/Japanese
        var cleaned = query
        let prefixes = ["离我最近的", "最近的", "附近的", "找一下", "帮我找", "去", "到", "近くの", "最寄りの"]
        for p in prefixes {
            if cleaned.hasPrefix(p) {
                cleaned = String(cleaned.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let suffixes = ["离我最近", "最近", "附近"]
        for s in suffixes {
            if cleaned.hasSuffix(s) {
                cleaned = String(cleaned.dropLast(s.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let searchQuery = cleaned.isEmpty ? query : cleaned

        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "q", value: searchQuery),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "countrycodes", value: "jp"),
            URLQueryItem(name: "limit", value: "4"),
            URLQueryItem(name: "addressdetails", value: "1")
        ]

        if let (cLat, cLng) = currentLocation {
            queryItems.append(URLQueryItem(name: "viewbox", value: String(format: "%.4f,%.4f,%.4f,%.4f", cLng - 0.2, cLat + 0.2, cLng + 0.2, cLat - 0.2)))
            queryItems.append(URLQueryItem(name: "bounded", value: "0"))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("TeslaCommander/2.0 (Tesla in Japan Navigation Resolver)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12.0

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            throw NSError(domain: "GeoResolverOSM", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "OSM request failed"])
        }

        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var results: [NavCandidate] = []
        for item in items {
            guard let latStr = item["lat"] as? String, let lat = Double(latStr),
                  let lonStr = item["lon"] as? String, let lng = Double(lonStr) else {
                continue
            }
            let name = item["name"] as? String ?? (item["display_name"] as? String)?.components(separatedBy: ",").first ?? searchQuery
            let address = item["display_name"] as? String ?? ""
            var dist: Double? = nil
            if let (cLat, cLng) = currentLocation {
                dist = Self.haversineDistanceKm(lat1: cLat, lon1: cLng, lat2: lat, lon2: lng)
            }
            results.append(NavCandidate(
                name: name,
                address: address,
                lat: lat,
                lng: lng,
                distanceKm: dist,
                engine: "openstreetmap_nominatim"
            ))
        }

        if currentLocation != nil {
            results.sort { ($0.distanceKm ?? 999999) < ($1.distanceKm ?? 999999) }
        }

        return results
    }

    /// Computes great-circle distance between two GPS coordinates in kilometers.
    public static func haversineDistanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return (r * c * 10).rounded() / 10.0
    }
}
