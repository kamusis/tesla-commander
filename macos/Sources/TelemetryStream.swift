import Foundation

/// Core streaming engine for Tesla Fleet Telemetry.
/// Connects to `wss://streaming.tessie.com/{vin}?access_token={token}`
/// via Apple's native `URLSessionWebSocketTask`.
public final class TelemetryStream {
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected: Bool = false
    private let session: URLSession
    private var vin: String = ""
    private var token: String = ""
    private var reconnectWorkItem: DispatchWorkItem?
    private var shouldReconnect: Bool = true

    /// Invoked whenever the connection state changes (true = connected, false = disconnected).
    public var onConnectionStateChange: ((Bool) -> Void)?

    /// Invoked with normalized telemetry metrics whenever a new streaming frame arrives.
    public var onTelemetryFrame: (([String: Any]) -> Void)?

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        disconnect()
    }

    /// Connects to Tessie Fleet Telemetry WebSocket service.
    public func connect(vin: String, token: String) {
        self.vin = vin
        self.token = token
        self.shouldReconnect = true
        reconnectWorkItem?.cancel()

        guard !vin.isEmpty && !token.isEmpty else {
            print("[TelemetryStream] Missing VIN or Access Token. Cannot connect.")
            return
        }

        guard let url = URL(string: "wss://streaming.tessie.com/\(vin)?access_token=\(token)") else {
            print("[TelemetryStream] Invalid WebSocket URL.")
            return
        }

        print("[TelemetryStream] Connecting to wss://streaming.tessie.com/\(vin)...")
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        listen()
        sendPing()
    }

    /// Disconnects from WebSocket and prevents auto-reconnection.
    public func disconnect() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        updateConnectionState(false)
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.updateConnectionState(true)
                self.handleMessage(message)
                // Continue listening for next frame
                self.listen()

            case .failure(let error):
                print("[TelemetryStream] WebSocket error: \(error.localizedDescription)")
                self.updateConnectionState(false)
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let rawData):
            data = rawData
        @unknown default:
            data = nil
        }

        guard let payloadData = data,
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return
        }

        // Process high-frequency metric items if present
        var normalizedFrame: [String: Any] = [:]

        if let dataItems = json["data"] as? [[String: Any]] {
            for item in dataItems {
                guard let key = item["key"] as? String,
                      let valDict = item["value"] as? [String: Any] else {
                    continue
                }

                let numVal = valDict["doubleValue"] as? Double
                    ?? (valDict["intValue"] as? Int).map { Double($0) }
                let strVal = valDict["stringValue"] as? String

                switch key {
                case "Soc":
                    if let val = numVal { normalizedFrame["battery_level"] = val }
                case "RatedRange", "IdealBatteryRange":
                    if let val = numVal { normalizedFrame["battery_range"] = val }
                case "ACChargingPower":
                    if let val = numVal { normalizedFrame["charger_power"] = val }
                case "InsideTemp":
                    if let val = numVal { normalizedFrame["inside_temp"] = val }
                case "TpmsPressureFl":
                    if let val = numVal { normalizedFrame["tpms_pressure_fl"] = val }
                case "TpmsPressureFr":
                    if let val = numVal { normalizedFrame["tpms_pressure_fr"] = val }
                case "TpmsPressureRl":
                    if let val = numVal { normalizedFrame["tpms_pressure_rl"] = val }
                case "TpmsPressureRr":
                    if let val = numVal { normalizedFrame["tpms_pressure_rr"] = val }
                case "Speed":
                    if let val = numVal { normalizedFrame["speed"] = val }
                case "Odometer":
                    if let val = numVal { normalizedFrame["odometer"] = val }
                case "Location":
                    if let locDict = valDict["locationValue"] as? [String: Any] {
                        if let lat = locDict["latitude"] as? Double { normalizedFrame["latitude"] = lat }
                        if let lng = locDict["longitude"] as? Double { normalizedFrame["longitude"] = lng }
                    }
                case "Gear", "ShiftState":
                    if let s = strVal { normalizedFrame["shift_state"] = s }
                default:
                    if let val = numVal {
                        normalizedFrame[key] = val
                    } else if let s = strVal {
                        normalizedFrame[key] = s
                    }
                }
            }
        }

        if !normalizedFrame.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            normalizedFrame["last_updated"] = formatter.string(from: Date())

            DispatchQueue.main.async { [weak self] in
                self?.onTelemetryFrame?(normalizedFrame)
            }
        }
    }

    private func sendPing() {
        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                print("[TelemetryStream] Ping failed: \(error.localizedDescription)")
            } else {
                // Schedule next ping in 30 seconds to keep connection alive
                DispatchQueue.global().asyncAfter(deadline: .now() + 30.0) { [weak self] in
                    self?.sendPing()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.shouldReconnect else { return }
            print("[TelemetryStream] Attempting reconnect...")
            self.connect(vin: self.vin, token: self.token)
        }

        self.reconnectWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }

    private func updateConnectionState(_ connected: Bool) {
        guard self.isConnected != connected else { return }
        self.isConnected = connected
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionStateChange?(connected)
        }
    }
}
