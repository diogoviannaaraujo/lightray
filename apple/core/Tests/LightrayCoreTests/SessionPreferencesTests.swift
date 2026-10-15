import Foundation
import Testing

@testable import LightrayCore

@Test func preferencesAreScopedToThePairedHostAndSurviveANewStore() throws {
    let suite = "LightrayTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SessionPreferencesStore(defaults: defaults)
    var preferences = SessionPreferences()
    preferences.keyboardMapping = .commandControl
    preferences.showStatistics = false
    preferences.localCursor = true
    try store.save(preferences, hostID: 1)
    #expect(try SessionPreferencesStore(defaults: defaults).load(hostID: 1) == preferences)
    #expect(try store.load(hostID: 2) == SessionPreferences())
    store.reset(hostID: 1)
    #expect(try store.load(hostID: 1) == SessionPreferences())
}

@Test func corruptOrUnknownPreferenceRecordsReportErrors() throws {
    let suite = "LightrayTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SessionPreferencesStore(defaults: defaults)
    defaults.set(Data("invalid".utf8), forKey: "Lightray.session.1")
    #expect(throws: (any Error).self) { try store.load(hostID: 1) }
    let future = "{\"version\":2,\"preferences\":{\"keyboardMapping\":\"physical\",\"showStatistics\":true,\"localCursor\":false}}"
    defaults.set(Data(future.utf8), forKey: "Lightray.session.1")
    #expect(throws: SessionPreferencesStore.StoreError.self) { try store.load(hostID: 1) }
}

@Test func streamActivityRequiresAFrameAndExpiresWithoutProgress() {
    var activity = StreamActivity()
    #expect(activity.observe(decodedCount: 0, now: 0) == .waiting)
    #expect(activity.observe(decodedCount: 1, now: 100) == .live)
    #expect(activity.observe(decodedCount: 1, now: 2_000_099) == .live)
    #expect(activity.observe(decodedCount: 1, now: 2_000_100) == .interrupted)
    #expect(activity.observe(decodedCount: 2, now: 2_000_101) == .live)
}

@Test func streamActivityRejectsPreviousEpochsAndBackwardsClocks() {
    var activity = StreamActivity()
    _ = activity.observe(decodedCount: 10, now: 100)
    #expect(activity.observe(decodedCount: 0, now: 101) == .waiting)
    _ = activity.observe(decodedCount: 1, now: 102)
    #expect(activity.observe(decodedCount: 1, now: 99) == .waiting)
    #expect(activity.observe(decodedCount: 1, now: UInt64.max) == .waiting)
}
