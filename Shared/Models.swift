import Foundation

struct CivilDay: Codable, Comparable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, timeZone: TimeZone = .current) {
        let parts = Self.calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }

    static func calendar(_ timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static var today: Self { Self(.now) }

    var valid: Bool {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return false }
        let zone = TimeZone(secondsFromGMT: 0)!
        return Self(date(in: zone), timeZone: zone) == self
    }

    func date(in zone: TimeZone = .current) -> Date {
        Self.calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    var display: String {
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar()
        formatter.dateStyle = .medium
        return formatter.string(from: date())
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    func anniversary(_ targetYear: Int) -> Self {
        let leap = targetYear.isMultiple(of: 4) && (!targetYear.isMultiple(of: 100) || targetYear.isMultiple(of: 400))
        return Self(targetYear, month, month == 2 && day == 29 && !leap ? 28 : day)
    }

    func age(on written: Self) -> Age {
        guard written >= self else { return .beforeBirth }
        var months = (written.year - year) * 12 + written.month - month
        let leapDay = month == 2 && day == 29 && written.month == 2
        let daysInMonth = Self.calendar().range(of: .day, in: .month, for: written.date())?.count ?? 31
        let boundary = leapDay ? anniversary(written.year).day : min(day, daysInMonth)
        if written.day < boundary { months -= 1 }
        return .months(max(0, months))
    }
}

enum Age: Equatable {
    case beforeBirth
    case months(Int)

    var display: String {
        switch self {
        case .beforeBirth: L.t("age.before")
        case .months(let count) where count < 12: L.f("age.months", count)
        case .months(let count) where count.isMultiple(of: 12): L.f("age.years", count / 12)
        case .months(let count): L.f("age.both", count / 12, count % 12)
        }
    }

    var historyDisplay: String {
        switch self {
        case .beforeBirth: L.t("age.before")
        case .months(let count) where count < 12: L.f("age.written.months", count)
        case .months(let count) where count.isMultiple(of: 12): L.f("age.written.years", count / 12)
        case .months(let count): L.f("age.written.both", count / 12, count % 12)
        }
    }
}

struct Child: Identifiable, Codable, Equatable, Sendable {
    enum Gender: String, CaseIterable, Codable, Sendable {
        case boy, girl
    }

    var id = UUID()
    var nickname = ""
    var birthday: CivilDay?
    var gender: Gender?
    var name: String { nickname.isEmpty ? L.t("child.default") : nickname }

    func historyAge(on day: CivilDay) -> String? {
        birthday?.age(on: day).historyDisplay
    }

    var invitation: String {
        switch gender {
        case .boy: L.t("incoming.invitation.boy")
        case .girl: L.t("incoming.invitation.girl")
        case nil: L.t("incoming.invitation")
        }
    }
}

struct Letter: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let childID: UUID
    var day: CivilDay
    var body: String
    var sender: String?
    var sourceID: UUID?
    var photo: UUID?
    var cachedSummary: String? = nil
    var revision: UUID? = nil

    var summary: String {
        if let cachedSummary { return cachedSummary }
        let lines = body.split(whereSeparator: \.isNewline)
        let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let isGreeting = first.hasSuffix(",") || first.hasSuffix("，") || first.hasSuffix("：")
        let text = isGreeting && lines.count > 1 ? String(lines[1]) : first
        return String(text.prefix(68))
    }

    static func validBody(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.utf8.count <= 256_000 && !body.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

struct Draft: Codable, Equatable, Sendable {
    var id = UUID()
    var day: CivilDay = .today
    var body = ""
    var photo: UUID?
    var hasChosenDay: Bool? = nil
}

struct OpeningReminder: Codable, Equatable, Sendable {
    var day: CivilDay
    var enabled: Bool

    var delivery: Date {
        CivilDay.calendar().date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 9)) ?? .distantPast
    }
}

enum Milestone: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case tenth, firstBirthday
    var id: String { rawValue }
}

struct Library: Codable, Sendable {
    var children: [Child]
    var activeID: UUID
    var primaryID: UUID
    var letters: [Letter] = []
    var drafts: [UUID: Draft] = [:]
    var reminders: [UUID: OpeningReminder] = [:]
    var milestones: [UUID: Set<Milestone>] = [:]
    var received: Set<UUID> = []
    var deletedIDs: Set<UUID> = []
    var undoLetter: Letter?
    var milestonePrompts = true
    var widgetEnabled = false
    var review = ReviewProgress()

    init(children: [Child] = [Child()]) {
        precondition(!children.isEmpty)
        self.children = children
        activeID = children[0].id
        primaryID = children[0].id
    }

    var active: Child { children.first { $0.id == activeID } ?? children[0] }

    func letters(for id: UUID) -> [Letter] {
        letters.filter { $0.childID == id }.sorted { ($0.day, $0.id.uuidString) > ($1.day, $1.id.uuidString) }
    }

    mutating func add(_ letter: Letter, checkMilestones: Bool) throws -> Set<Milestone> {
        guard !letters.contains(where: { $0.id == letter.id }), !deletedIDs.contains(letter.id) else { return [] }
        if let id = letter.sourceID {
            guard received.insert(id).inserted else { throw GrowthError.duplicate }
        }
        letters.append(letter)
        return checkMilestones ? registerMilestones(for: letter) : []
    }

    mutating func registerMilestones(for letter: Letter) -> Set<Milestone> {
        var new: Set<Milestone> = []
        if letters(for: letter.childID).count >= 10 { new.insert(.tenth) }
        if let birth = children.first(where: { $0.id == letter.childID })?.birthday,
           birth.anniversary(birth.year + 1) == letter.day { new.insert(.firstBirthday) }
        let existing = milestones[letter.childID, default: []]
        milestones[letter.childID] = existing.union(new)
        return new.subtracting(existing)
    }

    func birthdayMilestones(on day: CivilDay) -> Set<UUID> {
        let childrenWithLetters = Set(letters.map(\.childID))
        return Set(children.compactMap { child in
            guard let birth = child.birthday, birth.anniversary(birth.year + 1) == day,
                  childrenWithLetters.contains(child.id), milestones[child.id]?.contains(.firstBirthday) != true else {
                return nil
            }
            return child.id
        })
    }
}

enum GrowthError: Error {
    case invalid, version, tooLarge, duplicate, storage, photo, notification, purchase, noLetters

    var message: String {
        switch self {
        case .invalid: L.t("error.invalid")
        case .version: L.t("error.version")
        case .tooLarge: L.t("error.size")
        case .duplicate: L.t("error.duplicate")
        case .storage: L.t("error.storage")
        case .photo: L.t("error.photo")
        case .notification: L.t("error.notification")
        case .purchase: L.t("error.purchase")
        case .noLetters: L.t("empty.letters")
        }
    }
}
