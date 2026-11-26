import Foundation

struct WidgetSnapshot: Codable, Equatable {
    static let group = "group.com.hgsldswk.growthletters"
    static let key = "widget-snapshot"
    static let kind = "GrowthLettersWidget"

    var count: Int
    var opening: Date? = nil

    static var shared: UserDefaults? { UserDefaults(suiteName: group) }

    static func read() -> Self? {
        guard let data = shared?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func set(_ snapshot: Self?) {
        guard let snapshot else {
            shared?.removeObject(forKey: key)
            return
        }
        shared?.set(try? JSONEncoder().encode(snapshot), forKey: key)
    }
}
