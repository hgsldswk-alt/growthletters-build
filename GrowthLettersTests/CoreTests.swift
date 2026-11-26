import CoreImage
import ImageIO
import PDFKit
import UIKit
import XCTest

final class CoreTests: XCTestCase {
    func testHistoricalAgeAppearsOnlyWhenBirthdayIsKnown() throws {
        let day = CivilDay(2026, 11, 23)
        let legacy = ["id": UUID().uuidString, "nickname": "Mia"]
        var child = try JSONDecoder().decode(Child.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(child.historyAge(on: day))
        XCTAssertNil(child.gender)
        XCTAssertEqual(child.invitation, L.t("incoming.invitation"))
        child.birthday = CivilDay(2024, 8, 23)
        child.gender = .girl
        XCTAssertEqual(child.historyAge(on: day), L.f("age.written.both", 2, 3))
        XCTAssertEqual(child.historyAge(on: CivilDay(2024, 8, 22)), L.t("age.before"))
        XCTAssertEqual(child.historyAge(on: CivilDay(2024, 9, 23)), L.f("age.written.months", 1))
        XCTAssertEqual(child.historyAge(on: CivilDay(2025, 8, 23)), L.f("age.written.years", 1))
        XCTAssertEqual(child.invitation, L.t("incoming.invitation.girl"))
    }

    func testCivilAgeAcrossCalendarAndZones() throws {
        XCTAssertEqual(CivilDay(2024, 8, 23).age(on: CivilDay(2026, 11, 23)), .months(27))
        XCTAssertEqual(CivilDay(2024, 8, 23).age(on: CivilDay(2026, 11, 22)), .months(26))
        XCTAssertEqual(CivilDay(2024, 3, 1).age(on: CivilDay(2024, 2, 29)), .beforeBirth)
        XCTAssertEqual(CivilDay(2024, 1, 31).age(on: CivilDay(2024, 2, 29)), .months(1))
        XCTAssertEqual(CivilDay(2024, 2, 29).age(on: CivilDay(2025, 2, 28)), .months(12))
        XCTAssertFalse(CivilDay(2025, 2, 29).valid)
        XCTAssertFalse(CivilDay(2025, 4, 31).valid)
        XCTAssertNil(Child().birthday)
        let japan = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let day = CivilDay(2026, 11, 23)
        XCTAssertEqual(CivilDay(day.date(in: japan), timeZone: japan), day)
        XCTAssertEqual(CivilDay(day.date(in: pacific), timeZone: pacific), day)
        XCTAssertEqual(try JSONDecoder().decode(CivilDay.self, from: JSONEncoder().encode(day)).iso, "2026-11-23")
        XCTAssertNotEqual(L.t("write.save"), "write.save")
    }

    func testTrialEndsAtThirtyDaysAndPurchaseRestorationDoesNotRestartIt() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var access = Entitlement(firstOpen: start)
        XCTAssertTrue(access.hasPro(at: start, free: false))
        XCTAssertTrue(access.hasPro(at: start.addingTimeInterval(Entitlement.duration - 1), free: false))
        let expiry = start.addingTimeInterval(Entitlement.duration)
        XCTAssertFalse(access.hasPro(at: expiry, free: false))
        access.trialClaimedAt = start.addingTimeInterval(200)
        access.limitStart(to: start.addingTimeInterval(200))
        XCTAssertEqual(access.trialStart, start)
        access.applyVerifiedPurchase(true)
        XCTAssertTrue(access.hasPro(at: expiry, free: false))
        access.applyVerifiedPurchase(false)
        XCTAssertFalse(access.hasPro(at: expiry, free: false))
        access.limitStart(to: start.addingTimeInterval(-86_400))
        XCTAssertEqual(access.trialStart, start.addingTimeInterval(-86_400))
        XCTAssertTrue(access.hasPro(at: expiry, free: true))
    }

    func testVerifiedRestorationAndRefundUseTheSameAccessRecord() throws {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let restore = first.addingTimeInterval(Entitlement.duration + 100)
        let refund = restore.addingTimeInterval(1)
        var record = AccessRecord(entitlement: Entitlement(firstOpen: first))
        XCTAssertFalse(record.entitlement.hasPro(at: restore, free: false))
        XCTAssertTrue(record.acceptVerified(productID: Launch.proID, signedAt: restore, originalDate: first, revoked: false))
        XCTAssertTrue(record.entitlement.hasPro(at: restore, free: false))
        XCTAssertTrue(record.acceptVerified(productID: Launch.proID, signedAt: refund, originalDate: first, revoked: true))

        var reopened = try JSONDecoder().decode(AccessRecord.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(reopened.entitlement.hasPro(at: refund, free: false))
        XCTAssertTrue(reopened.acceptVerified(productID: Launch.proID, signedAt: restore, originalDate: first, revoked: false))
        XCTAssertTrue(reopened.acceptVerified(productID: Launch.proID, signedAt: refund, originalDate: first, revoked: false))
        XCTAssertFalse(reopened.entitlement.hasPro(at: refund, free: false))
        XCTAssertEqual(reopened.entitlement.trialStart, first)
        XCTAssertFalse(reopened.acceptVerified(productID: "other", signedAt: refund, originalDate: first, revoked: false))
    }

    func testReviewRequiresThreeSeparateDaysAndOnlyOneRequestPerVersion() {
        var review = ReviewProgress()
        let zone = TimeZone(secondsFromGMT: 0)!
        let calendar = CivilDay.calendar(zone)
        let first = CivilDay(2026, 11, 21)
        review.record(first.date(in: zone), calendar: calendar)
        review.record(first.date(in: zone).addingTimeInterval(3600), calendar: calendar)
        review.record(CivilDay(2026, 11, 22).date(in: zone), calendar: calendar)
        XCTAssertFalse(review.eligible("1.0", idle: true))
        review.record(CivilDay(2026, 11, 23).date(in: zone), calendar: calendar)
        XCTAssertFalse(review.eligible("1.0", idle: false))
        XCTAssertTrue(review.eligible("1.0", idle: true))
        review.requestedVersions.insert("1.0")
        XCTAssertFalse(review.eligible("1.0", idle: true))
        XCTAssertTrue(review.eligible("1.1", idle: true))
    }

    func testReviewOpportunityAfterFailureRequiresAnotherSuccessfulSave() throws {
        var review = ReviewOpportunity()
        review.saved(eligible: true)
        let first = try XCTUnwrap(review.ticket)
        XCTAssertFalse(review.permits(first, unobstructed: false))
        review.cancel()
        XCTAssertFalse(review.permits(first, unobstructed: true))
        XCTAssertNil(review.ticket)
        review.saved(eligible: true)
        let next = try XCTUnwrap(review.ticket)
        XCTAssertNotEqual(first, next)
        XCTAssertTrue(review.permits(next, unobstructed: true))
        review.saved(eligible: false)
        XCTAssertFalse(review.permits(next, unobstructed: true))
    }

    func testIncomingRecipientCanBeMatchedFromCodeOrLegacyGreeting() throws {
        let ann = Child(nickname: "Ann")
        let anna = Child(nickname: "Anna")
        let xiaoyu = Child(nickname: "小雨")
        let children = [ann, anna, xiaoyu]
        var letter = IncomingLetter(day: CivilDay(2026, 11, 23), body: "Dear ANNA,\n\nI remember the walk.\nLove, Grandma",
                                    sender: "Grandma")
        let legacy = try IncomingLetter.read(code: XCTUnwrap(letter.code()))
        XCTAssertEqual(legacy.suggestedChild(in: children), anna.id)
        XCTAssertEqual(legacy.previewText, "Dear ANNA,\nI remember the walk.")
        XCTAssertNil(legacy.suggestedChild(in: children + [Child(nickname: "Anna")]))
        letter.body = "亲爱的小雨，你好！"
        XCTAssertEqual(letter.suggestedChild(in: children), xiaoyu.id)
        letter.recipient = " ＡＮＮ "
        let named = try IncomingLetter.read(code: XCTUnwrap(letter.code()))
        XCTAssertEqual(named.suggestedChild(in: children), ann.id)
    }

    func testStartupExportCleanupRemovesRecentAndOldFiles() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let exports = root.appendingPathComponent("GrowthLetters-Exports", isDirectory: true)
        try manager.createDirectory(at: exports, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let recent = exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: recent, withIntermediateDirectories: false)
        try Data("fresh".utf8).write(to: recent.appendingPathComponent("new.png"))
        let old = exports.appendingPathComponent("interrupted.tmp")
        try Data("old".utf8).write(to: old)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172_800)], ofItemAtPath: old.path)
        let saved = root.appendingPathComponent("saved.sqlite")
        try Data("kept".utf8).write(to: saved)
        TransferFiles.cleanAbandoned(in: exports)
        XCTAssertFalse(manager.fileExists(atPath: exports.path))
        XCTAssertTrue(manager.fileExists(atPath: saved.path))
    }

    func testCodeBoundariesAndReplay() throws {
        let incoming = IncomingLetter(day: CivilDay(2026, 11, 23), body: "Mia,\nLove from Grandma.", sender: "Grandma")
        let code = try XCTUnwrap(incoming.code())
        XCTAssertTrue(code.hasPrefix("GL1:"))
        XCTAssertEqual(try IncomingLetter.read(code: " " + code + "\n"), incoming)
        XCTAssertEqual(try IncomingLetter.read(code: "\u{200b}" + code + "\u{feff}"), incoming)
        XCTAssertThrowsError(try IncomingLetter.read(code: "GL2:abc"))
        XCTAssertThrowsError(try IncomingLetter.read(code: "GL1:xxxx!"))
        XCTAssertThrowsError(try IncomingLetter.read(code: "GL1:" + String(repeating: "a", count: 3000)))
        XCTAssertThrowsError(try IncomingLetter(day: CivilDay(2023, 2, 29), body: "Hello", sender: "").validated())
        XCTAssertNil(try IncomingLetter(day: incoming.day, body: String(repeating: "a", count: 3000), sender: "").code())

        var library = Library()
        let letter = Letter(childID: library.activeID, day: incoming.day, body: incoming.body, sourceID: incoming.id)
        _ = try library.add(letter, checkMilestones: true)
        XCTAssertThrowsError(try library.add(Letter(childID: library.activeID, day: letter.day, body: letter.body,
                                                     sourceID: incoming.id), checkMilestones: true))
    }

    func testMilestonesOnlyOnceAndDuplicateLocalSaveHasNoEffect() throws {
        let child = Child(nickname: "Mia", birthday: CivilDay(2024, 8, 23))
        var library = Library(children: [child])
        for _ in 0..<9 {
            _ = try library.add(Letter(childID: child.id, day: CivilDay(2025, 8, 22), body: "One moment"), checkMilestones: true)
        }
        let tenth = Letter(childID: child.id, day: CivilDay(2025, 8, 23), body: "Birthday")
        XCTAssertEqual(try library.add(tenth, checkMilestones: true), [.tenth, .firstBirthday])
        XCTAssertEqual(try library.add(tenth, checkMilestones: true), [])
        let next = Letter(childID: child.id, day: tenth.day, body: "Another letter")
        XCTAssertEqual(try library.add(next, checkMilestones: true), [])
        XCTAssertEqual(library.letters.count, 11)
    }

    func testBackupReadableMergeAndArchiveValidation() throws {
        let child = Child(nickname: "Mia", birthday: CivilDay(2024, 8, 23))
        var source = Library(children: [child])
        let image = try jpeg()
        let photo = UUID()
        let letter = Letter(childID: child.id, day: CivilDay(2026, 11, 23), body: "Hello Mia", photo: photo)
        _ = try source.add(letter, checkMilestones: true)
        source.reminders[child.id] = OpeningReminder(day: CivilDay(2027, 8, 23), enabled: true)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let zip = try Backup.make(library: source, trialStart: stamp) { $0 == photo ? image : nil }
        let files = try StoredZIP.read(zip)
        XCTAssertEqual(files["letters/\(letter.id.uuidString).txt"], Data("Hello Mia".utf8))
        XCTAssertEqual(files["photos/\(photo.uuidString).jpg"], image)
        let backup = try Backup.read(zip)
        var target = Library()
        try backup.merge(into: &target)
        try backup.merge(into: &target)
        XCTAssertEqual(target.children, [child])
        XCTAssertEqual(target.letters, [letter])
        XCTAssertEqual(backup.manifest.trialStart, stamp)
        XCTAssertEqual(target.reminders[child.id]?.enabled, false)
        var corrupt = zip
        corrupt[30 + "letters/\(letter.id.uuidString).txt".utf8.count] ^= 1
        XCTAssertThrowsError(try Backup.read(corrupt))
        var malicious = StoredZIP.Writer()
        try malicious.add("../manifest.json", Data())
        XCTAssertThrowsError(try StoredZIP.read(malicious.finish()))
    }

    func testDatabaseCommitsPhotoAndLetterTogether() async throws {
        let store = LibraryStore(folder: nil)
        let child = Child()
        _ = try await store.load(seed: Library(children: [child]))
        let photoID = UUID()
        let data = try jpeg()
        let letter = Letter(childID: child.id, day: CivilDay(2026, 11, 23), body: "Photo inside", photo: photoID)
        _ = try await store.change(photos: [photoID: data]) { _ = try $0.add(letter, checkMilestones: true) }
        let snapshot = try await store.change { _ = try $0.add(letter, checkMilestones: true) }
        let photo = try await store.photo(photoID)
        XCTAssertEqual(snapshot.letters.map(\.id), [letter.id])
        let full = try await store.fullLetter(try XCTUnwrap(snapshot.letters.first))
        XCTAssertEqual(full, letter)
        XCTAssertEqual(photo, data)
        do {
            _ = try await store.change { library in
                library.letters.removeAll()
                throw GrowthError.invalid
            }
            XCTFail("An invalid mutation committed")
        } catch {
            let library = try await store.load()
            XCTAssertEqual(library.letters.map(\.id), [letter.id])
        }
    }

    func testPDFKeepsSelectableTextAndPaginatesLongLetters() throws {
        let child = Child(nickname: "Mia")
        let body = Array(repeating: "A paragraph for Mia, with words to select and read.\n", count: 95).joined() + "End of this letter."
        let letter = Letter(childID: child.id, day: CivilDay(2026, 11, 23), body: body)
        let plan = try BookPlan(child: child, letters: [letter], paper: .a4, photos: nil)
        XCTAssertGreaterThan(plan.count, 3)
        let url = try plan.pdf()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, plan.count)
        XCTAssertTrue(document.string?.contains("End of this letter.") == true)
    }

    func testShareCardQRAtRealExportSize() throws {
        for url in [nil, URL(string: "https://apps.apple.com/app/id1234567890")] as [URL?] {
            let image = try CardArt.make(count: 10, nickname: nil, milestone: .tenth, storeURL: url)
            let bitmap = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(bitmap.width, 1080)
            XCTAssertEqual(bitmap.height, 1350)
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                   options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let codes = detector.features(in: CIImage(cgImage: bitmap)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertTrue(codes.contains((url ?? Launch.previewURL).absoluteString), "\(codes)")
        }
    }

    func testPhotoSanitizerClearsPrivateMetadata() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try jpeg() as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let raw = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(raw, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:23 10:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Private device"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let cleaned = try XCTUnwrap(CGImageSourceCreateWithData(try PhotoCodec.clean(raw as Data) as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(cleaned, 0, nil) as? [CFString: Any]
        XCTAssertNil(properties?[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties?[kCGImagePropertyIPTCDictionary])
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif?[kCGImagePropertyExifLensModel])
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
    }

    private func jpeg() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }
}
