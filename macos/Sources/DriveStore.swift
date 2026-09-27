import Foundation

/// Persistent local storage and incremental sync manager for Tesla driving sessions and GPS breadcrumb paths.
/// Stores drives metadata in `~/Library/Application Support/TeslaCommander/drives_history.json`
/// and detailed GPS trajectories in `~/Library/Application Support/TeslaCommander/paths/<driveId>.json`.
public final class DriveStore {
    public static let shared = DriveStore()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.kamusis.TeslaCommander.DriveStore", qos: .utility)

    private let baseDirectory: URL
    private let historyFileURL: URL
    private let pathsDirectory: URL

    private let fullySyncedKey = "com.kamusis.TeslaCommander.drivesFullySynced"

    /// Indicates whether the full lifetime driving history has been fetched and archived.
    public var isFullySynced: Bool {
        get {
            UserDefaults.standard.bool(forKey: fullySyncedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: fullySyncedKey)
        }
    }

    /// Resets the local drive store completely for a full re-sync.
    public func resetStore() {
        queue.sync {
            inMemoryDrives.removeAll()
            isFullySynced = false
            try? fileManager.removeItem(at: historyFileURL)
            print("[DriveStore] Cleared local drives history for full re-sync.")
        }
    }

    // In-memory cache of stored drives keyed by positive Drive ID
    private var inMemoryDrives: [Int: [String: Any]] = [:]
    private var isLoaded = false

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        
        self.baseDirectory = appSupport.appendingPathComponent("TeslaCommander", isDirectory: true)
        self.historyFileURL = self.baseDirectory.appendingPathComponent("drives_history.json")
        self.pathsDirectory = self.baseDirectory.appendingPathComponent("paths", isDirectory: true)

        ensureDirectories()
        loadFromDiskSync()
    }

    /// Creates base and paths directories if they do not exist.
    private func ensureDirectories() {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: pathsDirectory.path) {
            try? fileManager.createDirectory(at: pathsDirectory, withIntermediateDirectories: true)
        }
    }

    /// Synchronously loads existing drives from disk into memory cache on initialization.
    private func loadFromDiskSync() {
        guard fileManager.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            isLoaded = true
            return
        }

        var map: [Int: [String: Any]] = [:]
        for item in jsonArray {
            if let id = extractDriveId(item) {
                map[id] = item
            }
        }
        self.inMemoryDrives = map
        self.isLoaded = true
        print("[DriveStore] Loaded \(map.count) drives from local cache: \(historyFileURL.path)")
    }

    // MARK: - Drives Metadata Management

    /// Returns all locally cached raw drives, sorted descending by start time.
    public func loadDrives() -> [[String: Any]] {
        return queue.sync {
            return sortedDrivesList()
        }
    }

    /// Returns the total count of locally cached drives.
    public func getDriveCount() -> Int {
        return queue.sync {
            return inMemoryDrives.count
        }
    }

    /// Returns the timestamp (seconds since epoch) of the oldest drive currently in local storage.
    public func getOldestDriveTimestamp() -> Int? {
        return queue.sync {
            let timestamps = inMemoryDrives.values.compactMap { extractStartedAt($0) }.filter { $0 > 0 }
            return timestamps.min()
        }
    }

    /// Returns the timestamp (seconds since epoch) of the newest drive currently in local storage.
    public func getNewestDriveTimestamp() -> Int? {
        return queue.sync {
            let timestamps = inMemoryDrives.values.compactMap { extractStartedAt($0) }.filter { $0 > 0 }
            return timestamps.max()
        }
    }

    /// Merges incoming raw drives from Tessie cloud into local store.
    /// Deduplicates strictly by drive `id`, updates changed records, and persists to disk.
    /// - Parameter incoming: Array of raw drive dictionaries from Tessie API.
    /// - Returns: Tuple of the full merged drives list (sorted descending) and the count of newly added drives.
    public func mergeDrives(incoming: [[String: Any]]) -> (merged: [[String: Any]], newCount: Int) {
        return queue.sync {
            var newCount = 0
            var hasUpdates = false

            for drive in incoming {
                guard let id = extractDriveId(drive) else { continue }
                if inMemoryDrives[id] == nil {
                    inMemoryDrives[id] = drive
                    newCount += 1
                    hasUpdates = true
                } else {
                    // Update existing record if new data is more complete (e.g. ended trip, enriched location)
                    inMemoryDrives[id] = drive
                    hasUpdates = true
                }
            }

            let sorted = sortedDrivesList()

            if hasUpdates {
                saveToDisk(sorted)
            }

            return (sorted, newCount)
        }
    }

    /// Persists sorted drives array to local JSON file atomically.
    private func saveToDisk(_ drives: [[String: Any]]) {
        ensureDirectories()
        do {
            let data = try JSONSerialization.data(withJSONObject: drives, options: [.prettyPrinted])
            try data.write(to: historyFileURL, options: .atomic)
            print("[DriveStore] Successfully persisted \(drives.count) drives to disk.")
        } catch {
            print("[DriveStore] Error writing drives to disk: \(error.localizedDescription)")
        }
    }

    /// Helper to sort in-memory drives descending by started_at.
    private func sortedDrivesList() -> [[String: Any]] {
        return inMemoryDrives.values.sorted { d1, d2 in
            let t1 = extractStartedAt(d1)
            let t2 = extractStartedAt(d2)
            return t1 > t2
        }
    }

    // MARK: - GPS Breadcrumb Path Caching

    /// Returns cached GPS path points for a given drive ID, or nil if not cached locally.
    public func getCachedPath(driveId: Int) -> [[String: Any]]? {
        guard driveId > 0 else { return nil }
        return queue.sync {
            let pathFile = pathsDirectory.appendingPathComponent("\(driveId).json")
            guard fileManager.fileExists(atPath: pathFile.path),
                  let data = try? Data(contentsOf: pathFile),
                  let points = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            return points
        }
    }

    /// Saves GPS path points for a drive ID to local disk cache.
    public func savePath(driveId: Int, points: [[String: Any]]) {
        guard driveId > 0, !points.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureDirectories()
            let pathFile = self.pathsDirectory.appendingPathComponent("\(driveId).json")
            do {
                let data = try JSONSerialization.data(withJSONObject: points, options: [])
                try data.write(to: pathFile, options: .atomic)
                print("[DriveStore] Cached GPS path for drive \(driveId) (\(points.count) points)")
            } catch {
                print("[DriveStore] Failed to cache path for drive \(driveId): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func extractDriveId(_ d: [String: Any]) -> Int? {
        if let id = d["id"] as? Int, id > 0 { return id }
        if let num = d["id"] as? NSNumber, num.intValue > 0 { return num.intValue }
        return nil
    }

    private func extractStartedAt(_ d: [String: Any]) -> Int {
        if let t = d["started_at"] as? Int, t > 0 { return t }
        if let t = d["starting_time"] as? Int, t > 0 { return t }
        if let num = d["started_at"] as? NSNumber, num.intValue > 0 { return num.intValue }
        if let num = d["starting_time"] as? NSNumber, num.intValue > 0 { return num.intValue }
        return 0
    }
}
