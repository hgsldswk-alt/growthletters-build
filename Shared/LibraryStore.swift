import Foundation
import SQLite3

actor LibraryStore {
    private let folder: URL?
    private var db: OpaquePointer?
    private var current: Library?
    private var draftRevisions: [UUID: Int] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(folder: URL?) { self.folder = folder }

    deinit { if let db { sqlite3_close_v2(db) } }

    func load(seed: Library = Library(), seedPhotos: [UUID: Data] = [:], resetTestData: Bool = false) throws -> Library {
        if let current { return current }
        if resetTestData, let folder, folder.lastPathComponent.hasPrefix("GrowthLettersUITest-"),
           FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try open()
        let statement = try prepare("SELECT data FROM library WHERE id = 1")
        let result = sqlite3_step(statement)
        let bytes = result == SQLITE_ROW ? Self.blob(statement) : Data()
        sqlite3_finalize(statement)
        switch result {
        case SQLITE_ROW:
            let library = try JSONDecoder().decode(Library.self, from: bytes)
            guard !library.children.isEmpty else { throw GrowthError.storage }
            let hasLegacyText = library.letters.contains(where: { !$0.body.isEmpty }) || library.undoLetter.map { !$0.body.isEmpty } == true
            let snapshot = hasLegacyText ? try write(library, photos: [:]) : library
            current = snapshot
            return snapshot
        case SQLITE_DONE:
            let snapshot = try write(seed, photos: seedPhotos)
            current = snapshot
            return snapshot
        default: throw GrowthError.storage
        }
    }

    @discardableResult
    func change(photos: [UUID: Data] = [:], _ update: @Sendable (inout Library) throws -> Void) throws -> Library {
        var next = try load()
        try update(&next)
        next = try write(next, photos: photos)
        current = next
        return next
    }

    func photo(_ id: UUID) throws -> Data? {
        _ = try load()
        let statement = try prepare("SELECT data FROM photos WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_text(statement, 1, id.uuidString, -1, transient))
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return Self.blob(statement)
        case SQLITE_DONE: return nil
        default: throw GrowthError.storage
        }
    }

    func persistDraft(_ draft: Draft, for child: UUID, today: CivilDay, revision: Int, photos: [UUID: Data]) throws {
        guard revision > draftRevisions[child, default: 0] else { return }
        _ = try change(photos: photos) { library in
            guard !library.letters.contains(where: { $0.id == draft.id }), !library.deletedIDs.contains(draft.id) else { return }
            if draft.body.isEmpty && draft.photo == nil && draft.day == today && draft.hasChosenDay != true {
                library.drafts[child] = nil
            } else {
                library.drafts[child] = draft
            }
        }
        draftRevisions[child] = revision
    }

    func backup(entitlement: Entitlement) throws -> Data {
        let library = try load()
        return try Backup.make(library: library, trialStart: entitlement.trialStart, body: { try self.body($0.id) },
                               photo: { try self.photo($0) })
    }

    func fullLetter(_ letter: Letter) throws -> Letter {
        var full = letter
        full.body = try body(letter.id)
        full.cachedSummary = nil
        return full
    }

    func search(_ query: String, in letters: [Letter]) throws -> Set<UUID> {
        let candidates = Set(letters.map(\.id))
        var found: Set<UUID> = []
        let statement = try prepare("SELECT id, body FROM texts")
        defer { sqlite3_finalize(statement) }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            try Task.checkCancellation()
            if let raw = sqlite3_column_text(statement, 0),
               let id = UUID(uuidString: String(decodingCString: raw, as: UTF8.self)), candidates.contains(id),
               String(decoding: Self.blob(statement, column: 1), as: UTF8.self).localizedStandardContains(query) {
                found.insert(id)
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw GrowthError.storage }
        return found
    }

    func stageBook(_ letters: [Letter]) throws -> ([Letter], BookPhotos) {
        let directory = try TransferFiles.folder()
        let staged = BookPhotos(folder: directory)
        var fullLetters: [Letter] = []
        var copied: Set<UUID> = []
        for letter in letters {
            try Task.checkCancellation()
            fullLetters.append(try fullLetter(letter))
            if let id = letter.photo, copied.insert(id).inserted {
                guard let data = try photo(id) else { throw GrowthError.storage }
                try data.write(to: staged.url(id), options: [.atomic, .completeFileProtection])
            }
        }
        return (fullLetters, staged)
    }

    private func open() throws {
        guard db == nil else { return }
        var path = ":memory:"
        if var folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            path = folder.appendingPathComponent("letters.sqlite").path
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close_v2(handle) }
            throw GrowthError.storage
        }
        db = handle
        do {
            try exec("PRAGMA journal_mode = DELETE")
            try exec("CREATE TABLE IF NOT EXISTS library (id INTEGER PRIMARY KEY CHECK (id = 1), data BLOB NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS photos (id TEXT PRIMARY KEY, data BLOB NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS texts (id TEXT PRIMARY KEY, body BLOB NOT NULL)")
            if folder != nil { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path) }
        } catch {
            if let db { sqlite3_close_v2(db) }
            db = nil
            throw error
        }
    }

    private func write(_ input: Library, photos: [UUID: Data]) throws -> Library {
        var library = input
        let livePhotos = Set(library.letters.compactMap(\.photo) + library.drafts.values.compactMap(\.photo) + [library.undoLetter?.photo].compactMap { $0 })
        let liveTexts = Set(library.letters.map(\.id) + [library.undoLetter?.id].compactMap { $0 })
        try exec("BEGIN IMMEDIATE")
        do {
            for (id, bytes) in photos where livePhotos.contains(id) {
                let statement = try prepare("INSERT INTO photos (id, data) VALUES (?, ?) ON CONFLICT(id) DO NOTHING")
                defer { sqlite3_finalize(statement) }
                try check(sqlite3_bind_text(statement, 1, id.uuidString, -1, transient))
                try bind(bytes, statement, at: 2)
                try done(statement)
            }
            for index in library.letters.indices where !library.letters[index].body.isEmpty {
                library.letters[index] = try storeBody(library.letters[index])
            }
            if let receipt = library.undoLetter, !receipt.body.isEmpty { library.undoLetter = try storeBody(receipt) }
            let data = try JSONEncoder().encode(library)
            let statement = try prepare("INSERT INTO library VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET data=excluded.data")
            defer { sqlite3_finalize(statement) }
            try bind(data, statement, at: 1)
            try done(statement)
            try prune(livePhotos, table: "photos")
            try prune(liveTexts, table: "texts")
            try exec("COMMIT")
            return library
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func body(_ id: UUID) throws -> String {
        let statement = try prepare("SELECT body FROM texts WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_text(statement, 1, id.uuidString, -1, transient))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw GrowthError.storage }
        return String(decoding: Self.blob(statement), as: UTF8.self)
    }

    private func storeBody(_ letter: Letter) throws -> Letter {
        let statement = try prepare("INSERT INTO texts (id, body) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET body=excluded.body")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_text(statement, 1, letter.id.uuidString, -1, transient))
        try bind(Data(letter.body.utf8), statement, at: 2)
        try done(statement)
        var header = letter
        header.cachedSummary = letter.summary
        header.body = ""
        return header
    }

    private func prune(_ live: Set<UUID>, table: String) throws {
        let select = try prepare("SELECT id FROM \(table)")
        defer { sqlite3_finalize(select) }
        var stale: [String] = []
        var found: Set<UUID> = []
        var step = sqlite3_step(select)
        while step == SQLITE_ROW {
            if let raw = sqlite3_column_text(select, 0) {
                let name = String(decodingCString: raw, as: UTF8.self)
                if let id = UUID(uuidString: name), live.contains(id) { found.insert(id) }
                else { stale.append(name) }
            }
            step = sqlite3_step(select)
        }
        guard step == SQLITE_DONE, live.isSubset(of: found) else { throw GrowthError.storage }

        guard !stale.isEmpty else { return }
        let remove = try prepare("DELETE FROM \(table) WHERE id = ?")
        defer { sqlite3_finalize(remove) }
        for name in stale {
            try check(sqlite3_bind_text(remove, 1, name, -1, transient))
            try done(remove)
            try check(sqlite3_reset(remove))
        }
    }

    private func exec(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil)) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw GrowthError.storage }
        return statement
    }

    private func bind(_ bytes: Data, _ statement: OpaquePointer, at index: Int32) throws {
        guard bytes.count <= Int32.max else { throw GrowthError.tooLarge }
        let result = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        try check(result)
    }

    private func check(_ code: Int32) throws {
        if code != SQLITE_OK { throw GrowthError.storage }
    }

    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw GrowthError.storage }
    }

    private static func blob(_ statement: OpaquePointer, column: Int32 = 0) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
