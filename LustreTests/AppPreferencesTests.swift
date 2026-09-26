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

    /// A locale whose default ruler units match `ViewerDisplay.defaults`, so
    /// whole-value comparisons don't depend on the machine's region.
    private static let metric = Locale(identifier: "de_DE")
    private static let us = Locale(identifier: "en_US")

    @Test func emptyStoreReadsDefaults() {
        Self.withStore { store in
            #expect(AppPreferences(reading: store, locale: Self.metric) == .defaults)
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
            #expect(AppPreferences(reading: store, locale: Self.metric) == .defaults)
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

    // MARK: - Viewer display

    private typealias Display = AppPreferences.ViewerDisplay
    private typealias Key = AppPreferences.Key

    /// Every stored Bool, with how to read it back out of a display.
    private static let boolFields: [(key: String, path: KeyPath<Display, Bool>)] = [
        (Key.gesturesEnabled, \.areGesturesEnabled),
        (Key.locksToSingleAxis, \.locksToSingleAxis),
        (Key.showsPlacementIndicators, \.showsPlacementIndicators),
        (Key.showsMeasuringTicks, \.showsMeasuringTicks),
        (Key.occludesBehindSurfaces, \.occludesBehindSurfaces),
        (Key.showsAdvancedRotation, \.showsAdvancedRotation),
    ]

    @Test func emptyStoreReadsDisplayDefaults() {
        Self.withStore { store in
            #expect(Display(reading: store, locale: Self.metric) == .defaults)
            #expect(AppPreferences(reading: store, locale: Self.metric).viewerDisplay == .defaults)
        }
    }

    /// The defaults are "what the Viewer did before any of this was stored".
    @Test @MainActor func displayDefaultsMatchAFreshViewer() {
        let ui = ViewerUIState()
        let defaults = Display.defaults
        #expect(defaults.areGesturesEnabled == ui.areGesturesEnabled)
        #expect(defaults.locksToSingleAxis == ui.locksToSingleAxis)
        #expect(defaults.showsPlacementIndicators == ui.showsPlacementIndicators)
        #expect(defaults.showsMeasuringTicks == ui.showsMeasuringTicks)
        #expect(defaults.rulerUnits == ui.rulerUnits)
        #expect(defaults.background == ui.background)
        #expect(defaults.occludesBehindSurfaces == ui.occludesBehindSurfaces)
        #expect(defaults.quality == ui.quality)
        #expect(defaults.expandedSection == ui.expandedSection)
        #expect(defaults.showsAdvancedRotation == ui.showsAdvancedRotation)
    }

    @Test("Bools round-trip", arguments: 0..<6, [true, false])
    func boolRoundTrip(index: Int, value: Bool) {
        let field = Self.boolFields[index]
        Self.withStore { store in
            store.set(value, forKey: field.key)
            #expect(Display(reading: store)[keyPath: field.path] == value)
        }
    }

    /// `bool(forKey:)` would read these as false; gestures and ticks default
    /// to true, so that would silently switch them off.
    @Test("Missing Bools read their default", arguments: 0..<6)
    func missingBool(index: Int) {
        let field = Self.boolFields[index]
        Self.withStore { store in
            #expect(Display(reading: store)[keyPath: field.path] == Display.defaults[keyPath: field.path])
        }
        #expect(Display.defaults.areGesturesEnabled)
        #expect(Display.defaults.showsMeasuringTicks)
    }

    @Test("Wrong-type Bools read their default", arguments: 0..<6)
    func wrongTypeBool(index: Int) {
        let field = Self.boolFields[index]
        Self.withStore { store in
            store.set("yes", forKey: field.key)
            #expect(Display(reading: store)[keyPath: field.path] == Display.defaults[keyPath: field.path])
            store.set(7, forKey: field.key)
            #expect(Display(reading: store)[keyPath: field.path] == Display.defaults[keyPath: field.path])
        }
    }

    @Test("Ruler units round-trip", arguments: RulerUnits.allCases)
    func rulerUnitsRoundTrip(units: RulerUnits) {
        Self.withStore { store in
            store.set(units.rawValue, forKey: Key.rulerUnits)
            // The locale only matters when nothing is stored.
            #expect(Display(reading: store, locale: Self.us).rulerUnits == units)
            #expect(Display(reading: store, locale: Self.metric).rulerUnits == units)
        }
    }

    @Test("Backgrounds round-trip", arguments: ViewerBackground.allCases)
    func backgroundRoundTrip(background: ViewerBackground) {
        Self.withStore { store in
            store.set(background.rawValue, forKey: Key.background)
            #expect(Display(reading: store).background == background)
        }
    }

    @Test("Qualities round-trip", arguments: SplatQuality.allCases)
    func qualityRoundTrip(quality: SplatQuality) {
        Self.withStore { store in
            store.set(quality.rawValue, forKey: Key.quality)
            #expect(Display(reading: store).quality == quality)
        }
    }

    @Test("Expanded sections round-trip", arguments: ViewerMenuSection.allCases.map(Optional.some) + [nil])
    func expandedSectionRoundTrip(section: ViewerMenuSection?) {
        Self.withStore { store in
            var display = Display.defaults
            display.expandedSection = section
            Display.write(display, to: store)
            #expect(Display(reading: store).expandedSection == section)
        }
    }

    @Test func unknownDisplayValuesFallBack() {
        Self.withStore { store in
            store.set("yards", forKey: Key.rulerUnits)
            store.set("white", forKey: Key.background)
            store.set("Full", forKey: Key.quality)
            store.set("lighting", forKey: Key.expandedSection)
            #expect(Display(reading: store, locale: Self.metric) == .defaults)
        }
    }

    @Test func wrongTypeDisplayValuesFallBack() {
        Self.withStore { store in
            store.set(1, forKey: Key.rulerUnits)
            store.set(true, forKey: Key.background)
            store.set(2.5, forKey: Key.quality)
            store.set(["display"], forKey: Key.expandedSection)
            #expect(Display(reading: store, locale: Self.metric) == .defaults)
        }
    }

    @Test("Ruler units default from the locale", arguments: [
        ("en_US", RulerUnits.feet),
        ("en_GB", .meters),
        ("de_DE", .meters),
        ("ja_JP", .meters),
        ("en_US@measure=metric", .meters),
    ])
    func rulerUnitsFromLocale(identifier: String, expected: RulerUnits) {
        let locale = Locale(identifier: identifier)
        #expect(Display.defaultRulerUnits(for: locale) == expected)
        Self.withStore { store in
            #expect(Display(reading: store, locale: locale).rulerUnits == expected)
        }
    }

    @Test func writeThenReadRoundTrips() {
        let display = Display(areGesturesEnabled: false,
                              locksToSingleAxis: true,
                              showsPlacementIndicators: true,
                              showsMeasuringTicks: false,
                              rulerUnits: .feet,
                              background: .black,
                              occludesBehindSurfaces: true,
                              quality: .performance,
                              expandedSection: .display,
                              showsAdvancedRotation: true)
        // Every field differs from the defaults, so a field that isn't
        // written can't pass by accident.
        #expect(display.areGesturesEnabled != Display.defaults.areGesturesEnabled)
        #expect(display.showsMeasuringTicks != Display.defaults.showsMeasuringTicks)
        Self.withStore { store in
            Display.write(display, to: store)
            #expect(Display(reading: store, locale: Self.metric) == display)
            Display.write(.defaults, to: store)
            #expect(Display(reading: store, locale: Self.us) == .defaults)
        }
    }
}
