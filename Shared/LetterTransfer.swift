import Foundation

struct IncomingLetter: Codable, Equatable, Sendable {
    static let prefix = "GL1:"
    static let codeLimit = 3_000
    static let fileLimit = 6_000_000
    var version = 1
    var id = UUID()
    var day: CivilDay
    var body: String
    var sender: String
    var photo: Data?
    var recipient: String?

    var previewText: String {
        let lines = body.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "\n")
        return lines.count > 120 ? String(lines.prefix(119)) + "…" : lines
    }

    func suggestedChild(in children: [Child]) -> UUID? {
        let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
        let matches = children.filter { child in
            let name = child.nickname
            guard !name.isEmpty else { return false }
            if let recipient {
                return name.compare(recipient.trimmingCharacters(in: .whitespacesAndNewlines), options: options) == .orderedSame
            }
            if name.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
                return body.range(of: name, options: options) != nil
            }
            let boundary = #"[^\p{L}\p{M}\p{N}_]"#
            let foldedName = name.folding(options: options, locale: .current)
            let pattern = "(?:^|\(boundary))\(NSRegularExpression.escapedPattern(for: foldedName))(?:$|\(boundary))"
            return body.folding(options: options, locale: .current)
                .range(of: pattern, options: .regularExpression) != nil
        }
        return matches.count == 1 ? matches.first?.id : nil
    }

    func validated() throws -> Self {
        guard version == 1 else { throw GrowthError.version }
        let names = [sender, recipient ?? ""]
        guard day.valid, Letter.validBody(body), names.allSatisfy({
            $0.utf8.count <= 240 && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else {
            throw GrowthError.invalid
        }
        var copy = self
        if let photo {
            guard photo.count <= PhotoCodec.jpegLimit else { throw GrowthError.tooLarge }
            copy.photo = try PhotoCodec.clean(photo)
        }
        return copy
    }

    func code() throws -> String? {
        guard photo == nil else { return nil }
        let payload = try JSONEncoder().encode(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let code = Self.prefix + payload
        return code.utf8.count <= Self.codeLimit ? code : nil
    }

    static func read(code: String) throws -> Self {
        let text = code.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{FEFF}")))
        guard text.utf8.count <= codeLimit else { throw GrowthError.tooLarge }
        guard text.hasPrefix(prefix) else {
            throw text.range(of: "^GL[0-9]+:", options: .regularExpression) == nil ? GrowthError.invalid : GrowthError.version
        }
        let payload = text.dropFirst(prefix.count)
        guard !payload.isEmpty, payload.utf8.count % 4 != 1, payload.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw GrowthError.invalid }
        let base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64 + padding) else { throw GrowthError.invalid }
        let incoming = try read(file: bytes)
        guard incoming.photo == nil else { throw GrowthError.invalid }
        return incoming
    }

    static func read(file: Data) throws -> Self {
        guard file.count <= fileLimit else { throw GrowthError.tooLarge }
        let header = try? JSONDecoder().decode(TransferVersion.self, from: file)
        if let header, header.version != 1 { throw GrowthError.version }
        guard let letter = try? JSONDecoder().decode(Self.self, from: file) else { throw GrowthError.invalid }
        return try letter.validated()
    }
}

struct TransferVersion: Decodable { let version: Int }

enum TransferFiles {
    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GrowthLetters-Exports", isDirectory: true)
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resource.isRegularFile == true, let size = resource.fileSize else { throw GrowthError.invalid }
        guard size <= limit else { throw GrowthError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(1_048_576, limit + 1 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= limit else { throw GrowthError.tooLarge }
        }
        return result
    }

    static func folder() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        return url
    }

    static func cleanAbandoned(in directory: URL? = nil) {
        try? FileManager.default.removeItem(at: directory ?? root)
    }

    static func write(_ data: Data, named name: String) throws -> URL {
        let directory = try folder()
        let file = directory.appendingPathComponent(name)
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
