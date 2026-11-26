import Foundation

enum Launch {
    static let freePeriod = false
    static let args = ProcessInfo.processInfo.arguments
    static let uiTesting = args.contains("-ui-testing")
    static var isFree: Bool { freePeriod && !["-paid-mode", "-paywall", "-expired"].contains(where: args.contains) }
    static let proID = "com.hgsldswk.growthletters.pro"
    static let trialID = "com.hgsldswk.growthletters.trial"
    static let previewURL = URL(string: "https://www.apple.com/app-store/")!

    static var storeURL: URL? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id" + id)
    }
}
