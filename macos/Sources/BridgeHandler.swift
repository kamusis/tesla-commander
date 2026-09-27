import Foundation
import WebKit

/// Handles bidirectional JavaScript communication between WKWebView and native Swift.
public final class BridgeHandler: NSObject, WKScriptMessageHandler {
    public weak var webView: WKWebView?
    private let client: TessieClient

    public init(client: TessieClient) {
        self.client = client
        super.init()
    }

    /// Invoked when JavaScript executes `window.webkit.messageHandlers.teslaNative.postMessage(...)`
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "teslaNative",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            return
        }

        let params = body["params"] as? [String: Any] ?? [:]
        handleNativeAction(action: action, params: params)
    }

    /// Dispatches a command action to Tessie API or refreshes the full state.
    public func handleNativeAction(action: String, params: [String: Any]) {
        if action == "refresh" {
            Task { @MainActor in
                await refreshVehicleState(manual: true)
            }
            return
        }

        if action == "fetch_driving_path" {
            guard let from = params["from"] as? Int,
                  let to = params["to"] as? Int,
                  let driveId = params["driveId"] as? Int else {
                return
            }
            if driveId < 0 {
                return
            }
            Task {
                do {
                    let points = try await client.fetchDrivingPath(from: from, to: to, details: true)
                    await MainActor.run {
                        self.sendDrivingPathToUI(driveId: driveId, points: points)
                    }
                } catch {
                    await MainActor.run {
                        self.showToast(message: "拉取轨迹失败: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        Task {
            do {
                let res = try await client.executeCommand(action: action, params: params)
                let msg = res.success ? "\(action) 已成功响应" : "响应: \(res.message)"
                await MainActor.run {
                    self.showToast(message: "指令已下发: \(msg)")
                }
            } catch {
                await MainActor.run {
                    self.showToast(message: "指令执行异常: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Fetches complete snapshot and syncs into dashboard.
    @MainActor
    public func refreshVehicleState(manual: Bool = false) async {
        if manual {
            showToast(message: "正在拉取全量数据快照...")
        }
        do {
            async let stateTask = client.fetchState()
            async let locationTask = client.fetchLocation()
            async let chargesTask = client.fetchCharges(limit: 8)
            async let drivesTask = client.fetchDrives(limit: 20)
            let (state, location, charges, drives) = try await (stateTask, locationTask, chargesTask, drivesTask)

            var frame: [String: Any] = [:]
            frame["vin"] = client.vin

            // 1. Location & GPS
            if let address = location["address"] as? String {
                frame["address"] = address
            }
            if let savedLoc = location["saved_location"] as? String {
                frame["saved_location"] = savedLoc
            } else {
                frame["saved_location"] = ""
            }
            if let lat = location["latitude"] as? Double {
                frame["latitude"] = lat
            }
            if let lng = location["longitude"] as? Double {
                frame["longitude"] = lng
            }

            // 2. Charge State
            if let chargeState = state["charge_state"] as? [String: Any] {
                if let battery = chargeState["battery_level"] as? Double ?? (chargeState["battery_level"] as? Int).map(Double.init) {
                    frame["battery_level"] = battery
                }
                if let range = chargeState["battery_range"] as? Double {
                    frame["battery_range"] = range
                }
                if let power = chargeState["charger_power"] as? Double {
                    frame["charger_power"] = power
                }
                if let chargingState = chargeState["charging_state"] as? String {
                    frame["charging_state"] = chargingState
                }
                if let chargeAmps = chargeState["charger_actual_current"] as? Double ?? (chargeState["charger_actual_current"] as? Int).map(Double.init) {
                    frame["charge_amps"] = chargeAmps
                }
                if let limit = chargeState["charge_limit_soc"] as? Int {
                    frame["charge_limit_soc"] = limit
                }
                if let timeToFull = chargeState["time_to_full_charge"] as? Double {
                    frame["time_to_full_charge"] = timeToFull
                }
            }

            // 3. Climate State
            if let climateState = state["climate_state"] as? [String: Any] {
                if let insideTemp = climateState["inside_temp"] as? Double {
                    frame["inside_temp"] = insideTemp
                }
                if let outsideTemp = climateState["outside_temp"] as? Double {
                    frame["outside_temp"] = outsideTemp
                }
                if let isClimateOn = climateState["is_climate_on"] as? Bool {
                    frame["is_climate_on"] = isClimateOn
                }
                if let targetTemp = climateState["driver_temp_setting"] as? Double {
                    frame["target_temp"] = targetTemp
                }
            }

            // 4. Drive State
            if let driveState = state["drive_state"] as? [String: Any] {
                if frame["latitude"] == nil, let lat = driveState["latitude"] as? Double {
                    frame["latitude"] = lat
                }
                if frame["longitude"] == nil, let lng = driveState["longitude"] as? Double {
                    frame["longitude"] = lng
                }
                if let speed = driveState["speed"] as? Double {
                    frame["speed"] = speed
                }
                if let shift = driveState["shift_state"] as? String {
                    frame["shift_state"] = shift
                }
            }

            // 5. Vehicle State
            if let vehicleState = state["vehicle_state"] as? [String: Any] {
                if let tpms = vehicleState["tpms_pressure_fl"] as? Double {
                    frame["tpms_pressure_fl"] = tpms
                }
                if let tpmsFr = vehicleState["tpms_pressure_fr"] as? Double {
                    frame["tpms_pressure_fr"] = tpmsFr
                }
                if let tpmsRl = vehicleState["tpms_pressure_rl"] as? Double {
                    frame["tpms_pressure_rl"] = tpmsRl
                }
                if let tpmsRr = vehicleState["tpms_pressure_rr"] as? Double {
                    frame["tpms_pressure_rr"] = tpmsRr
                }
                if let odo = vehicleState["odometer"] as? Double {
                    frame["odometer"] = odo
                }
                if let locked = vehicleState["locked"] as? Bool {
                    frame["locked"] = locked
                }
                if let sentry = vehicleState["sentry_mode"] as? Bool {
                    frame["sentry_mode"] = sentry
                }
                if let version = vehicleState["car_version"] as? String {
                    frame["car_version"] = version
                }
                let fd = vehicleState["fd_window"] as? Int ?? 0
                let fp = vehicleState["fp_window"] as? Int ?? 0
                let rd = vehicleState["rd_window"] as? Int ?? 0
                let rp = vehicleState["rp_window"] as? Int ?? 0
                frame["windows_closed"] = (fd == 0 && fp == 0 && rd == 0 && rp == 0)
            }

            // 6. Historical Drives & Charges
            frame["charges"] = charges.reversed().compactMap { c -> [String: Any]? in
                guard let energy = c["energy_added"] as? Double else { return nil }
                let startedAt = c["started_at"] as? Int ?? (c["starting_time"] as? Int ?? 0)
                let dateStr: String
                if startedAt > 0 {
                    let d = Date(timeIntervalSince1970: TimeInterval(startedAt))
                    let f = DateFormatter()
                    f.dateFormat = "MM/dd HH:mm"
                    dateStr = f.string(from: d)
                } else {
                    dateStr = "--"
                }
                return ["date": dateStr, "energy": energy]
            }

            frame["drives"] = drives.reversed().compactMap { d -> [String: Any]? in
                guard let energy = d["energy_used"] as? Double else { return nil }
                let startedAt = d["started_at"] as? Int ?? (d["starting_time"] as? Int ?? 0)
                let dateStr: String
                if startedAt > 0 {
                    let dt = Date(timeIntervalSince1970: TimeInterval(startedAt))
                    let f = DateFormatter()
                    f.dateFormat = "MM/dd HH:mm"
                    dateStr = f.string(from: dt)
                } else {
                    dateStr = "--"
                }
                return ["date": dateStr, "energy": energy]
            }

            frame["detailed_drives"] = buildDetailedDrives(from: drives)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            frame["last_updated"] = formatter.string(from: Date())

            self.sendTelemetryFrame(frame)
            if manual {
                self.showToast(message: "已同步全量实时数据 (200 OK)")
            }
        } catch {
            self.showToast(message: "同步快照失败: \(error.localizedDescription)")
        }
    }

    /// Reconciles raw Tessie drives by detecting odometer jumps and inserting synthetic compensated drives.
    private func buildDetailedDrives(from rawDrives: [[String: Any]]) -> [[String: Any]] {
        var results: [[String: Any]] = []

        let startFormatter = DateFormatter()
        startFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "HH:mm"
        let fullFormatter = DateFormatter()
        fullFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let crossFormatter = DateFormatter()
        crossFormatter.dateFormat = "MM-dd HH:mm"

        for i in 0..<rawDrives.count {
            let d = rawDrives[i]
            let driveId = d["id"] as? Int ?? 0
            guard driveId > 0 else { continue }

            let startedAt = d["started_at"] as? Int ?? (d["starting_time"] as? Int ?? 0)
            let endedAt = d["ended_at"] as? Int ?? (d["ending_time"] as? Int ?? 0)
            let dtStart = startedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(startedAt)) : nil
            let dtEnd = endedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(endedAt)) : nil

            let startTimeStr = dtStart != nil ? startFormatter.string(from: dtStart!) : "--"
            let endTimeStr = dtEnd != nil ? fullFormatter.string(from: dtEnd!) : "--"

            let timeRange: String
            if let d1 = dtStart, let d2 = dtEnd {
                if Calendar.current.isDate(d1, inSameDayAs: d2) {
                    timeRange = "\(startFormatter.string(from: d1)) ~ \(endFormatter.string(from: d2))"
                } else {
                    timeRange = "\(startFormatter.string(from: d1)) ~ \(crossFormatter.string(from: d2))"
                }
            } else if dtStart != nil {
                timeRange = "\(startTimeStr) ~ 进行中"
            } else {
                timeRange = "--"
            }

            let durationMin = (endedAt > startedAt && startedAt > 0) ? Int(round(Double(endedAt - startedAt) / 60.0)) : 0
            let miles = d["odometer_distance"] as? Double ?? 0
            let km = round(miles * 1.60934 * 10) / 10.0
            let energy = round((d["energy_used"] as? Double ?? 0) * 100) / 100.0
            let startLoc = d["starting_saved_location"] as? String ?? d["starting_location"] as? String ?? "未知起点"
            let endLoc = d["ending_saved_location"] as? String ?? d["ending_location"] as? String ?? "未知终点"
            let startBat = d["starting_battery"] as? Int ?? 0
            let endBat = d["ending_battery"] as? Int ?? 0
            let avgSpeed = round((d["average_speed"] as? Double ?? Double(d["average_speed"] as? Int ?? 0)) * 1.60934)
            let maxSpeed = round((d["max_speed"] as? Double ?? Double(d["max_speed"] as? Int ?? 0)) * 1.60934)
            let insideTemp = d["average_inside_temperature"] as? Double ?? 0.0
            let outsideTemp = d["average_outside_temperature"] as? Double ?? 0.0

            let normalDrive: [String: Any] = [
                "id": driveId,
                "is_synthetic": false,
                "started_at": startedAt,
                "ended_at": endedAt,
                "date": startTimeStr,
                "start_time": startTimeStr,
                "end_time": endTimeStr,
                "time_range": timeRange,
                "duration_min": durationMin,
                "distance_km": km,
                "energy_kwh": energy,
                "start_location": startLoc,
                "end_location": endLoc,
                "start_latitude": d["starting_latitude"] as? Double ?? 0.0,
                "start_longitude": d["starting_longitude"] as? Double ?? 0.0,
                "end_latitude": d["ending_latitude"] as? Double ?? 0.0,
                "end_longitude": d["ending_longitude"] as? Double ?? 0.0,
                "start_battery": startBat,
                "end_battery": endBat,
                "avg_speed_kmh": avgSpeed,
                "max_speed_kmh": maxSpeed,
                "inside_temp": insideTemp,
                "outside_temp": outsideTemp
            ]
            results.append(normalDrive)

            // Check odometer gap between current drive and previous (older) drive
            if i + 1 < rawDrives.count {
                let prev = rawDrives[i + 1]
                let currStartOdo = d["starting_odometer"] as? Double ?? 0.0
                let prevEndOdo = prev["ending_odometer"] as? Double ?? 0.0
                let gapMiles = currStartOdo - prevEndOdo

                // Gap threshold: >= 0.2 miles (~320m) and < 1000 miles (safety bound)
                if currStartOdo > 0 && prevEndOdo > 0 && gapMiles >= 0.2 && gapMiles < 1000.0 {
                    let prevEndedAt = prev["ended_at"] as? Int ?? (prev["ending_time"] as? Int ?? 0)
                    let gapKm = round(gapMiles * 1.60934 * 10) / 10.0

                    // Estimate duration based on typical city speed (25 km/h)
                    let estimatedDurationSec = max(180, Int((gapKm / 25.0) * 3600.0))
                    let synEnd = startedAt > 0 ? startedAt : Int(Date().timeIntervalSince1970)
                    let synStart = max(prevEndedAt, synEnd - estimatedDurationSec)
                    let synDurationMin = max(1, Int(round(Double(synEnd - synStart) / 60.0)))

                    let dtSynStart = Date(timeIntervalSince1970: TimeInterval(synStart))
                    let dtSynEnd = Date(timeIntervalSince1970: TimeInterval(synEnd))
                    let synStartStr = startFormatter.string(from: dtSynStart)
                    let synEndStr = fullFormatter.string(from: dtSynEnd)
                    let synTimeRange: String
                    if Calendar.current.isDate(dtSynStart, inSameDayAs: dtSynEnd) {
                        synTimeRange = "\(startFormatter.string(from: dtSynStart)) ~ \(endFormatter.string(from: dtSynEnd)) (推算)"
                    } else {
                        synTimeRange = "\(startFormatter.string(from: dtSynStart)) ~ \(crossFormatter.string(from: dtSynEnd)) (推算)"
                    }

                    let synStartLoc = prev["ending_saved_location"] as? String ?? prev["ending_location"] as? String ?? "未知地点"
                    let synEndLoc = d["starting_saved_location"] as? String ?? d["starting_location"] as? String ?? "未知地点"
                    let synStartBat = prev["ending_battery"] as? Int ?? 0
                    let synEndBat = d["starting_battery"] as? Int ?? synStartBat
                    let synAvgSpeed = round(gapKm / (Double(max(60, synEnd - synStart)) / 3600.0))

                    // Deterministic negative ID to ensure distinct identity and prevent collision
                    let synId = -(abs(driveId) * 10 + 9)

                    let syntheticDrive: [String: Any] = [
                        "id": synId,
                        "is_synthetic": true,
                        "started_at": synStart,
                        "ended_at": synEnd,
                        "date": synStartStr,
                        "start_time": synStartStr,
                        "end_time": synEndStr,
                        "time_range": synTimeRange,
                        "duration_min": synDurationMin,
                        "distance_km": gapKm,
                        "energy_kwh": 0.0,
                        "start_location": synStartLoc,
                        "end_location": synEndLoc,
                        "start_latitude": prev["ending_latitude"] as? Double ?? 0.0,
                        "start_longitude": prev["ending_longitude"] as? Double ?? 0.0,
                        "end_latitude": d["starting_latitude"] as? Double ?? 0.0,
                        "end_longitude": d["starting_longitude"] as? Double ?? 0.0,
                        "start_battery": synStartBat,
                        "end_battery": synEndBat,
                        "avg_speed_kmh": synAvgSpeed,
                        "max_speed_kmh": synAvgSpeed,
                        "inside_temp": 0.0,
                        "outside_temp": 0.0,
                        "note": "冷启动离线补偿行程 (仪表盘跳变 \(gapKm) km)"
                    ]
                    results.append(syntheticDrive)
                }
            }
        }
        return results
    }

    /// Sends loaded driving path GPS points to UI.
    @MainActor
    public func sendDrivingPathToUI(driveId: Int, points: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: points),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }
        let js = "if (window.onDrivingPathLoaded) { window.onDrivingPathLoaded(\(driveId), \(jsonStr)); }"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Evaluates `window.updateTelemetryFrame(...)` inside the web view.
    public func sendTelemetryFrame(_ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }

        let js = "if (window.updateTelemetryFrame) { window.updateTelemetryFrame(\(jsonStr)); }"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Evaluates `window.setStreamingStatus(...)` inside the web view.
    public func sendStreamingStatus(connected: Bool) {
        let js = "if (window.setStreamingStatus) { window.setStreamingStatus(\(connected ? "true" : "false")); }"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Evaluates `window.showToast(...)` inside the web view.
    public func showToast(message: String) {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        let js = "if (typeof showToast === 'function') { showToast('\(escaped)'); }"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
