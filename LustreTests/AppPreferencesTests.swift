//
//  AppPreferencesTests.swift
//  LustreTests
//

import Foundation
import Testing
@testable import Lustre

struct AppPreferencesTests {

    /// A throwaway domain per test, so nothing touches `.standard` and tests
    /// can run in parallel.
    private static func withStore(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "LustreTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }
        try body(store)
    }

    @Test func defaultsMatchTodaysBehavior() {
        #expect(AppPreferences.defaults.initialSize == .dollhouse)
        #expect(AppPreferences.defaults.joystickSpeed == 1.8)
        #expect(AppPreferences.joystickSpeedRange.contains(AppPreferences.defaults.joystickSpeed))
    }

    @Test @MainActor func dollhouseIsTheExistingAutoFit() {
        #expect(AppPreferences.InitialSize.dollhouse.fitExtent == SplatSceneState.autoFitExtent)
    }

    @Test func emptyStoreReadsDefaults() {
        Self.withStore { store in
            #expect(AppPreferences(reading: store) == .defaults)
        }
    }

    @Test("Initial size round-trips", arguments: AppPreferences.InitialSize.allCases)
    func initialSizeRoundTrip(size: AppPreferences.InitialSize) {
        Self.withStore { store in
            store.set(size.rawValue, forKey: AppPreferences.Key.initialSize)
            #expect(AppPreferences(reading: store).initialSize == size)
        }
    }

    @Test("Joystick speed round-trips", arguments: [0.5, 1.0, 2.75, 5.0])
    func joystickSpeedRoundTrip(speed: Double) {
        Self.withStore { store in
            store.set(speed, forKey: AppPreferences.Key.joystickSpeed)
            #expect(AppPreferences(reading: store).joystickSpeed == Float(speed))
        }
    }

    @Test("Unknown initial sizes fall back", arguments: ["", "huge", "Dollhouse", "life_size"])
    func unknownInitialSize(raw: String) {
        Self.withStore { store in
            store.set(raw, forKey: AppPreferences.Key.initialSize)
            #expect(AppPreferences(reading: store).initialSize == .dollhouse)
        }
    }

    @Test func wrongTypesFallBack() {
        Self.withStore { store in
            store.set(3, forKey: AppPreferences.Key.initialSize)
            store.set("fast", forKey: AppPreferences.Key.joystickSpeed)
            #expect(AppPreferences(reading: store) == .defaults)
        }
    }

    @Test("Out-of-range speeds clamp", arguments: [
        (0.0, Float(0.5)), (-3, 0.5), (0.1, 0.5), (5.01, 5), (1e9, 5),
    ])
    func speedClamps(stored: Double, expected: Float) {
        Self.withStore { store in
            store.set(stored, forKey: AppPreferences.Key.joystickSpeed)
            #expect(AppPreferences(reading: store).joystickSpeed == expected)
        }
    }

    @Test("Non-finite speeds get the default", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteSpeeds(stored: Double) {
        Self.withStore { store in
            store.set(stored, forKey: AppPreferences.Key.joystickSpeed)
            #expect(AppPreferences(reading: store).joystickSpeed == AppPreferences.defaults.joystickSpeed)
        }
    }

    @Test func sanitizingIsDirect() {
        #expect(AppPreferences.sanitizedJoystickSpeed(.nan) == AppPreferences.defaults.joystickSpeed)
        #expect(AppPreferences.sanitizedJoystickSpeed(2) == 2)
    }

    @Test("Fit extents", arguments: [
        (AppPreferences.InitialSize.tabletop, Float?.some(0.5)),
        (.dollhouse, 1.5),
        (.room, 4),
        (.lifeSize, nil),
    ])
    func fitExtent(size: AppPreferences.InitialSize, expected: Float?) {
        #expect(size.fitExtent == expected)
    }

    @Test func fitExtentsGrowInPickerOrder() {
        let extents = AppPreferences.InitialSize.allCases.compactMap(\.fitExtent)
        #expect(extents == extents.sorted())
        #expect(AppPreferences.InitialSize.allCases.last == .lifeSize)
    }
}
