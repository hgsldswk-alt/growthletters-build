import Foundation

struct Backup: Sendable {
    static let limit = 192 * 1024 * 1024
    private static let maxLetters = 25_000

    struct Manifest: Codable, Sendable {
        var version = 1
        var trialStart: Date
        var children: [Child]
        var letters: [Letter]
        var reminders: [UUID: OpeningReminder]
        var milestones: [UUID: Set<Milestone>]
        var received: Set<UUID>
    }

    let manifest: Manifest
    let photos: [UUID: Data]

    private static func bodyPath(_ id: UUID) -> String { "letters/\(id.uuidString).txt" }
    private static func photoPath(_ id: UUID) -> String { "photos/\(id.uuidString).jpg" }

    static func make(library: Library, trialStart: Date, body: (Letter) throws -> String = { $0.body },
                     photo: (UUID) throws -> Data?) throws -> Data {
        guard library.letters.count <= maxLetters, library.children.count <= 1_000 else { throw GrowthError.tooLarge }
        var records = library.letters
        var zip = StoredZIP.Writer()
        var copied: Set<UUID> = []
        for index in records.indices {
            try Task.checkCancellation()
            let letter = records[index]
            try zip.add(bodyPath(letter.id), Data(try body(letter).utf8))
            records[index].body = ""
            records[index].cachedSummary = nil
            if let id = letter.photo, copied.insert(id).inserted {
                guard let image = try photo(id) else { throw GrowthError.storage }
                try zip.add(photoPath(id), image)
            }
        }
        let manifest = Manifest(trialStart: trialStart, children: library.children, letters: records,
                                reminders: library.reminders, milestones: library.milestones, received: library.received)
        try zip.add("manifest.json", try JSONEncoder().encode(manifest))
        return try zip.finish()
    }

    static func read(_ data: Data) throws -> Self {
        var entries = try StoredZIP.read(data)
        guard let encoded = entries.removeValue(forKey: "manifest.json"),
              let header = try? JSONDecoder().decode(TransferVersion.self, from: encoded) else { throw GrowthError.invalid }
        guard header.version == 1 else { throw GrowthError.version }
        guard var manifest = try? JSONDecoder().decode(Manifest.self, from: encoded),
              manifest.letters.count <= maxLetters, !manifest.children.isEmpty, manifest.children.count <= 1_000,
              manifest.trialStart.timeIntervalSinceReferenceDate.isFinite else { throw GrowthError.invalid }
        let children = Set(manifest.children.map(\.id))
        guard children.count == manifest.children.count,
              manifest.children.allSatisfy({ $0.nickname.utf8.count <= 240 && ($0.birthday?.valid ?? true) }),
              manifest.reminders.allSatisfy({ children.contains($0.key) && $0.value.day.valid }),
              manifest.milestones.keys.allSatisfy(children.contains) else { throw GrowthError.invalid }

        var photos: [UUID: Data] = [:]
        var letterIDs: Set<UUID> = []
        var sourceIDs: Set<UUID> = []
        for index in manifest.letters.indices {
            let record = manifest.letters[index]
            guard letterIDs.insert(record.id).inserted, children.contains(record.childID), record.day.valid,
                  (record.sender?.utf8.count ?? 0) <= 240, record.body.isEmpty,
                  let raw = entries.removeValue(forKey: bodyPath(record.id)),
                  let text = String(data: raw, encoding: .utf8), Letter.validBody(text) else { throw GrowthError.invalid }
            if let source = record.sourceID, !sourceIDs.insert(source).inserted { throw GrowthError.invalid }
            manifest.letters[index].body = text
            if let id = record.photo, photos[id] == nil {
                guard let image = entries.removeValue(forKey: photoPath(id)), image.count <= PhotoCodec.jpegLimit else {
                    throw GrowthError.invalid
                }
                photos[id] = try PhotoCodec.clean(image)
            }
        }
        guard entries.isEmpty else { throw GrowthError.invalid }
        return Self(manifest: manifest, photos: photos)
    }

    func withFreshPhotoIDs() -> Self {
        let ids = Dictionary(uniqueKeysWithValues: photos.keys.map { ($0, UUID()) })
        var updated = manifest
        for index in updated.letters.indices {
            updated.letters[index].photo = updated.letters[index].photo.flatMap { ids[$0] }
        }
        return Self(manifest: updated, photos: Dictionary(uniqueKeysWithValues: photos.compactMap { id, data in
            ids[id].map { ($0, data) }
        }))
    }

    func merge(into library: inout Library) throws {
        let childIDs = Set(library.children.map(\.id))
        let pristine = library.children.count == 1 && library.active.nickname.isEmpty && library.active.birthday == nil
            && library.active.gender == nil
            && library.letters.isEmpty && library.drafts.isEmpty && library.reminders.isEmpty && library.received.isEmpty
        if pristine, !manifest.children.contains(where: { childIDs.contains($0.id) }) {
            library.children = manifest.children
            library.activeID = manifest.children[0].id
            library.primaryID = library.activeID
        } else {
            library.children.append(contentsOf: manifest.children.filter { !childIDs.contains($0.id) })
        }

        var letterIDs = Set(library.letters.map(\.id)).union(library.deletedIDs)
        for letter in manifest.letters where letterIDs.insert(letter.id).inserted {
            if let source = letter.sourceID, !library.received.insert(source).inserted { continue }
            library.letters.append(letter)
        }
        library.received.formUnion(manifest.received)
        for (child, reminder) in manifest.reminders where library.reminders[child] == nil {
            library.reminders[child] = OpeningReminder(day: reminder.day, enabled: false)
        }
        for (child, milestones) in manifest.milestones {
            library.milestones[child, default: []].formUnion(milestones)
        }
    }
}

enum StoredZIP {
    private static let checksumTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1 != 0 ? 0xedb88320 : 0) ^ (value >> 1) }
        return value
    }

    private static func crc(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { checksumTable[Int(($0 ^ UInt32($1)) & 255)] ^ ($0 >> 8) }
    }

    struct Writer {
        private var bytes = Data()
        private var directory = Data()
        private var count: UInt16 = 0

        mutating func add(_ name: String, _ contents: Data) throws {
            let path = Data(name.utf8)
            guard count < UInt16.max, path.count <= 128, bytes.count + directory.count + contents.count + path.count * 2 + 98 <= Backup.limit else {
                throw GrowthError.tooLarge
            }
            let offset = UInt32(bytes.count)
            let size = UInt32(contents.count)
            let checksum = StoredZIP.crc(contents)
            let length = UInt16(path.count)
            bytes.le(UInt32(0x04034b50))
            bytes.le(UInt16(20))
            bytes.zipCommon(checksum, size, length)
            bytes.le(UInt16(0))
            bytes.append(path)
            bytes.append(contents)

            directory.le(UInt32(0x02014b50))
            directory.le(UInt16(20))
            directory.le(UInt16(20))
            directory.zipCommon(checksum, size, length)
            for _ in 0..<4 { directory.le(UInt16(0)) }
            directory.le(UInt32(0))
            directory.le(offset)
            directory.append(path)
            count += 1
        }

        mutating func finish() throws -> Data {
            guard bytes.count + directory.count + 22 <= Backup.limit else { throw GrowthError.tooLarge }
            let offset = UInt32(bytes.count)
            bytes.append(directory)
            bytes.le(UInt32(0x06054b50))
            bytes.le(UInt32(0))
            bytes.le(count)
            bytes.le(count)
            bytes.le(UInt32(directory.count))
            bytes.le(offset)
            bytes.le(UInt16(0))
            return bytes
        }
    }

    static func read(_ bytes: Data) throws -> [String: Data] {
        guard bytes.count <= Backup.limit else { throw GrowthError.tooLarge }
        let end = bytes.count - 22
        guard end >= 0, bytes.u32(end) == 0x06054b50, bytes.u32(end + 4) == 0,
              bytes.u16(end + 8) == bytes.u16(end + 10), bytes.u16(end + 20) == 0 else { throw GrowthError.invalid }
        let central = bytes.u32(end + 16)
        guard central <= end, central + bytes.u32(end + 12) == end else { throw GrowthError.invalid }
        var directory = central
        var local = 0
        var entries: [String: Data] = [:]
        for _ in 0..<bytes.u16(end + 10) {
            guard directory + 46 <= end, local + 30 <= central else { throw GrowthError.invalid }
            let size = bytes.u32(directory + 24)
            let nameSize = bytes.u16(directory + 28)
            let contentStart = local + 30 + nameSize
            guard bytes.u32(directory) == 0x02014b50, bytes.u32(local) == 0x04034b50,
                  bytes.u32(directory + 8) == 0, bytes.u32(local + 6) == 0,
                  bytes.u32(directory + 30) == 0, bytes.u16(directory + 34) == 0, bytes.u16(local + 28) == 0,
                  bytes.u32(directory + 20) == size, bytes.u32(local + 18) == size, bytes.u32(local + 22) == size,
                  bytes.u32(directory + 42) == local, bytes.u16(local + 26) == nameSize,
                  (1...128).contains(nameSize), directory + 46 + nameSize <= end, contentStart + size <= central else {
                throw GrowthError.invalid
            }
            let path = bytes[(local + 30)..<contentStart]
            guard path.elementsEqual(bytes[(directory + 46)..<(directory + 46 + nameSize)]),
                  let name = String(data: path, encoding: .ascii), validName(name), entries[name] == nil else { throw GrowthError.invalid }
            let contents = Data(bytes[contentStart..<(contentStart + size)])
            let checksum = bytes.u32(directory + 16)
            guard bytes.u32(local + 14) == checksum, Int(crc(contents)) == checksum else { throw GrowthError.invalid }
            entries[name] = contents
            local = contentStart + size
            directory += 46 + nameSize
        }
        guard local == central, directory == end else { throw GrowthError.invalid }
        return entries
    }

    private static func validName(_ name: String) -> Bool {
        if name == "manifest.json" { return true }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, (parts[0] == "letters" && parts[1].hasSuffix(".txt")) ||
              (parts[0] == "photos" && parts[1].hasSuffix(".jpg")) else { return false }
        let id = String(parts[1].dropLast(4))
        return UUID(uuidString: id)?.uuidString == id
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ number: T) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func zipCommon(_ checksum: UInt32, _ size: UInt32, _ name: UInt16) {
        le(UInt32(0))
        le(UInt16(0))
        le(UInt16(33))
        le(checksum)
        le(size)
        le(size)
        le(name)
    }

    func u16(_ i: Int) -> Int { Int(self[i]) | (Int(self[i + 1]) << 8) }
    func u32(_ i: Int) -> Int { u16(i) | (u16(i + 2) << 16) }
}
