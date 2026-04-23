import Foundation
import Combine
import UIKit
import CoreLocation
import Photos

// MARK: - Visual Memory model

struct VisualMemory: Identifiable, Encodable {
    let id:            UUID
    let timestamp:     Date
    let imageFileName: String
    let aiSummary:     String    // short title, e.g. "Cozy café on Dizengoff"
    let aiDescription: String    // 1-2 sentence rich description
    let aiTags:        [String]  // searchable tags
    let aiObjects:     [String]  // object inventory: ["keys on coffee table", "remote on sofa", …]
    let locationName:  String?
    let latitude:      Double?
    let longitude:     Double?
    var userNote:      String?

    init(imageFileName: String,
         aiSummary:     String,
         aiDescription: String,
         aiTags:        [String],
         aiObjects:     [String] = [],
         locationName:  String?,
         latitude:      Double?,
         longitude:     Double?,
         userNote:      String? = nil) {
        id            = UUID()
        timestamp     = Date()
        self.imageFileName = imageFileName
        self.aiSummary     = aiSummary
        self.aiDescription = aiDescription
        self.aiTags        = aiTags
        self.aiObjects     = aiObjects
        self.locationName  = locationName
        self.latitude      = latitude
        self.longitude     = longitude
        self.userNote      = userNote
    }
}

// Custom Decodable so older persisted memories (without aiObjects) still load.
extension VisualMemory: Decodable {
    init(from decoder: Decoder) throws {
        let c         = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,   forKey: .id)
        timestamp     = try c.decode(Date.self,   forKey: .timestamp)
        imageFileName = try c.decode(String.self, forKey: .imageFileName)
        aiSummary     = try c.decode(String.self, forKey: .aiSummary)
        aiDescription = try c.decode(String.self, forKey: .aiDescription)
        aiTags        = try c.decode([String].self, forKey: .aiTags)
        aiObjects     = (try? c.decode([String].self, forKey: .aiObjects)) ?? []
        locationName  = try? c.decode(String.self, forKey: .locationName)
        latitude      = try? c.decode(Double.self, forKey: .latitude)
        longitude     = try? c.decode(Double.self, forKey: .longitude)
        userNote      = try? c.decode(String.self, forKey: .userNote)
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, imageFileName, aiSummary, aiDescription
        case aiTags, aiObjects, locationName, latitude, longitude, userNote
    }
}

// MARK: - VisualMemoryStore

@MainActor
final class VisualMemoryStore: ObservableObject {

    static let shared = VisualMemoryStore()
    private init() { load() }

    @Published private(set) var memories: [VisualMemory] = []

    // MARK: Persistence paths

    private var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("VisualMemories", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    func imageURL(for memory: VisualMemory) -> URL {
        folder.appendingPathComponent(memory.imageFileName)
    }

    // MARK: Save

    /// Saves image + metadata. Also saves to the Camera Roll.
    func save(image: UIImage,
              aiSummary:     String,
              aiDescription: String,
              aiTags:        [String],
              aiObjects:     [String] = [],
              locationName:  String?,
              latitude:      Double?,
              longitude:     Double?,
              userNote:      String? = nil) {

        let fileName = "vm_\(UUID().uuidString).jpg"
        let fileURL  = folder.appendingPathComponent(fileName)

        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: fileURL)
        }

        saveToPhotoLibrary(
            image: image,
            latitude: latitude,
            longitude: longitude
        )

        let vm = VisualMemory(
            imageFileName: fileName,
            aiSummary:     aiSummary,
            aiDescription: aiDescription,
            aiTags:        aiTags,
            aiObjects:     aiObjects,
            locationName:  locationName,
            latitude:      latitude,
            longitude:     longitude,
            userNote:      userNote
        )

        memories.insert(vm, at: 0)
        persist()
        print("[VisualMemory] Saved: '\(aiSummary)' | objects: \(aiObjects.count) | tags: \(aiTags)")
    }

    /// Public helper for raw capture flows (before AI "Remember This").
    /// Saves directly to Camera Roll with location metadata when available.
    func saveCaptureToPhotoLibrary(
        image: UIImage,
        latitude: Double?,
        longitude: Double?
    ) {
        saveToPhotoLibrary(image: image, latitude: latitude, longitude: longitude)
    }

    // MARK: Update (user note)

    func updateNote(id: UUID, note: String?) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].userNote = note
        persist()
    }

    // MARK: Delete

    func delete(_ memory: VisualMemory) {
        try? FileManager.default.removeItem(at: imageURL(for: memory))
        memories.removeAll { $0.id == memory.id }
        persist()
    }

    // MARK: AI context

    /// Compact summary for the background system prompt.
    /// Groups "today" memories first so the AI always knows what happened today.
    func contextForAI(limit: Int = 20) -> String? {
        guard !memories.isEmpty else { return nil }

        let calendar = Calendar.current
        let todayMems  = memories.filter { calendar.isDateInToday($0.timestamp) }
        let olderMems  = memories.filter { !calendar.isDateInToday($0.timestamp) }

        var lines: [String] = []

        if !todayMems.isEmpty {
            lines.append("TODAY'S VISUAL MEMORIES:")
            lines += todayMems.map { memoryLine($0, long: true) }
        }

        let remaining = limit - todayMems.count
        if remaining > 0 && !olderMems.isEmpty {
            if !todayMems.isEmpty { lines.append("EARLIER VISUAL MEMORIES:") }
            lines += olderMems.prefix(remaining).map { memoryLine($0, long: false) }
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Returns a focused context block for the query — and the matched memories for UI thumbnails.
    /// Two-pass strategy:
    ///   Pass 1 — scan aiObjects of every memory for a direct keyword hit.
    ///            If found, format as explicit "FOUND: object is at location" lines.
    ///   Pass 2 — fall back to the broader keyword search across all fields.
    ///            If no direct object match, tell the AI the item was NOT spotted.
    /// Returns nil only when no memory at all matches any keyword.
    func contextForQuery(_ query: String, limit: Int = 5) -> (context: String, memories: [VisualMemory])? {
        let keywords = extractKeywords(from: query)
        guard !keywords.isEmpty else { return nil }

        // ── Pass 1: direct object search ─────────────────────────────────────
        // Collect every (objectString, VisualMemory) pair where the object text
        // contains at least one of our search keywords.
        var objectHits: [(obj: String, mem: VisualMemory)] = []
        for mem in memories {
            for obj in mem.aiObjects {
                let objLow = obj.lowercased()
                if keywords.contains(where: { objLow.contains($0) }) {
                    objectHits.append((obj, mem))
                }
            }
        }

        if !objectHits.isEmpty {
            // Sort: today first, then by recency
            let sorted = objectHits.sorted {
                let aT = Calendar.current.isDateInToday($0.mem.timestamp)
                let bT = Calendar.current.isDateInToday($1.mem.timestamp)
                if aT != bT { return aT }
                return $0.mem.timestamp > $1.mem.timestamp
            }
            let matchedMems = sorted.prefix(limit).map(\.mem)
            var lines = ["OBJECT LOCATIONS CONFIRMED IN VISUAL MEMORIES:"]
            for hit in sorted.prefix(limit) {
                let loc  = hit.mem.locationName.map { " at \($0)" } ?? ""
                let date = hit.mem.timestamp.formatted(date: .long, time: .shortened)
                lines.append("✓ \(hit.obj) — seen in \"\(hit.mem.aiSummary)\"\(loc) on \(date)")
            }
            print("[VisualMemory] \(sorted.count) direct object match(es)")
            let uniqueMems = Array(NSOrderedSet(array: matchedMems) as! NSOrderedSet).compactMap { $0 as? VisualMemory }
            return (lines.joined(separator: "\n"), Array(uniqueMems.prefix(limit)))
        }

        // ── Pass 2: broad keyword match across all fields ────────────────────
        let broadMatches = keywordSearch(query)
        if !broadMatches.isEmpty {
            let ctx = broadMatches.prefix(limit).map { memoryLine($0, long: true) }.joined(separator: "\n")
            print("[VisualMemory] \(broadMatches.count) broad match(es) — no direct object hit")
            // Tell the AI clearly that the specific item wasn't spotted in the objects list
            let note = "NOTE: The search term was found in memories but NOT as a specific located object. " +
                       "Be honest — only report a location if you see it explicitly listed below.\n\n"
            return (note + ctx, Array(broadMatches.prefix(limit)))
        }

        return nil
    }

    // MARK: Search

    /// UI search — filters by any keyword in the query (3+ char words).
    func search(_ query: String) -> [VisualMemory] {
        keywordSearch(query)
    }

    // MARK: Private helpers

    /// Strips stop words and returns meaningful search keywords from the query.
    func extractKeywords(from query: String) -> [String] {
        let stopWords: Set<String> = ["the","and","for","not","but","you","can","are",
                                      "was","did","that","this","with","have","had","from",
                                      "see","saw","she","him","her","they","has","what",
                                      "where","when","who","how","its","any","all"]
        return query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    /// Splits query into meaningful keywords and returns memories matching ANY of them.
    private func keywordSearch(_ query: String) -> [VisualMemory] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return memories }
        let keywords = extractKeywords(from: raw)

        guard !keywords.isEmpty else { return memories }

        return memories.filter { vm in
            let base    = [vm.aiSummary, vm.aiDescription,
                           vm.locationName ?? "", vm.userNote ?? ""].joined(separator: " ")
            let tags    = vm.aiTags.joined(separator: " ")
            let objects = vm.aiObjects.joined(separator: " ")
            let hay     = "\(base) \(tags) \(objects)".lowercased()
            return keywords.contains { hay.contains($0) }
        }
        // Sort: today's memories first, then by recency
        .sorted {
            let aToday = Calendar.current.isDateInToday($0.timestamp)
            let bToday = Calendar.current.isDateInToday($1.timestamp)
            if aToday != bToday { return aToday }
            return $0.timestamp > $1.timestamp
        }
    }

    private func memoryLine(_ m: VisualMemory, long: Bool) -> String {
        let loc  = m.locationName.map { " at \($0)" } ?? ""
        let date = long
            ? m.timestamp.formatted(date: .long, time: .shortened)
            : m.timestamp.formatted(date: .abbreviated, time: .omitted)
        var line = "• \(m.aiSummary)\(loc) (\(date))"
        if long && !m.aiDescription.isEmpty { line += " — \(m.aiDescription)" }
        let tags = m.aiTags.prefix(5).joined(separator: ", ")
        if !tags.isEmpty { line += " [tags: \(tags)]" }
        // Object inventory: lets the AI answer "where are my keys?" accurately
        if long && !m.aiObjects.isEmpty {
            line += " [objects: \(m.aiObjects.joined(separator: "; "))]"
        }
        return line
    }

    // MARK: Load image

    func loadImage(for memory: VisualMemory) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: memory).path)
    }

    // MARK: Private helpers

    private func persist() {
        if let data = try? JSONEncoder().encode(memories) {
            try? data.write(to: indexURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([VisualMemory].self, from: data) else { return }
        memories = decoded
        print("[VisualMemory] Loaded \(memories.count) memories")
    }

    /// Saves the image to the camera roll using add-only permission.
    /// Album grouping is intentionally omitted — reading the album list requires full library
    /// access (NSPhotoLibraryUsageDescription) which is more invasive than needed. Images land
    /// in "Recents" in Photos; the app keeps its own indexed copy in Documents/VisualMemories/.
    private func saveToPhotoLibrary(
        image: UIImage,
        latitude: Double?,
        longitude: Double?
    ) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                print("[VisualMemory] Camera roll permission denied (\(status.rawValue))")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetChangeRequest.creationRequestForAsset(from: image)
                req.creationDate = Date()
                if let lat = latitude, let lon = longitude {
                    req.location = CLLocation(latitude: lat, longitude: lon)
                }
            }, completionHandler: { _, error in
                if let error {
                    print("[VisualMemory] Camera roll save failed: \(error.localizedDescription)")
                } else {
                    print("[VisualMemory] Camera roll save OK")
                }
            })
        }
    }
}

// MARK: - LocationManager

@MainActor
final class LocationManager: NSObject, ObservableObject {

    static let shared = LocationManager()

    @Published var locationName: String?
    @Published var coordinate:   CLLocationCoordinate2D?
    @Published var authStatus:   CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var completion: ((String?, CLLocationCoordinate2D?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        // Hundred-metre accuracy is precise enough for a neighbourhood label
        // without draining the battery or requesting high-precision permission.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// One-shot location fetch — always requests a fresh GPS fix and reverse-geocodes it.
    /// The label uses neighbourhood + city (not street number) for a stable readable name.
    func fetchLocation(completion: @escaping (String?, CLLocationCoordinate2D?) -> Void) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // Completion fires later via locationManagerDidChangeAuthorization
        default:
            completion(nil, nil)
            self.completion = nil
        }
    }
}

// MARK: - CLLocationManagerDelegate (nonisolated bridge)

extension LocationManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in
            self.coordinate = loc.coordinate
            await self.reverseGeocode(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.completion?(nil, nil)
            self.completion = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            } else {
                self.completion?(nil, nil)
                self.completion = nil
            }
        }
    }

    @MainActor
    private func reverseGeocode(_ location: CLLocation) async {
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
           let p = placemarks.first {
            // Use neighbourhood + city (never the street number) for a stable readable label.
            // "Hashmona'im, Ramat Gan" is more meaningful and consistent than "Street 14, Street".
            let parts = [p.subLocality ?? p.thoroughfare, p.locality ?? p.name]
                .compactMap { $0 }
            let name = parts.prefix(2).joined(separator: ", ")
            self.locationName = name
            completion?(name, location.coordinate)
        } else {
            completion?(nil, location.coordinate)
        }
        completion = nil
    }
}
