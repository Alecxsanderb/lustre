//
//  AppPreferences.swift
//  Lustre
//
//  User preferences, read once from UserDefaults as a plain value.
//
//  Settings writes the same keys through `@AppStorage`; everything else gets a
//  snapshot from `ContentView` instead of reading UserDefaults itself, so
//  features stay unaware of where preferences live and tests can hand in any
//  values they like. The one write path outside Settings, the Viewer's display
//  toggles, also goes through `ContentView` (`ViewerDisplay.write(_:to:)`).
//

import Foundation

nonisolated struct AppPreferences: Equatable, Sendable {

    /// UserDefaults keys. Shared with `SettingsView`'s `@AppStorage`, so a
    /// rename here is a rename there — but it also orphans stored values, so
    /// don't rename.
    enum Key {
        static let initialSize = "viewer.initialSize"
        static let joystickSpeed = "viewer.simulatorJoystickSpeed"

        // Viewer display. The Viewer's menu writes these back as the user
        // changes them, and Settings edits them directly.
        static let gesturesEnabled = "viewer.gesturesEnabled"
        static let locksToSingleAxis = "viewer.locksToSingleAxis"
        static let showsPlacementIndicators = "viewer.showsPlacementIndicators"
        static let showsMeasuringTicks = "viewer.showsMeasuringTicks"
        static let rulerUnits = "viewer.rulerUnits"
        static let background = "viewer.background"
        static let occludesBehindSurfaces = "viewer.occludesBehindSurfaces"
        static let quality = "viewer.quality"
        static let expandedSection = "viewer.expandedSection"
        static let showsAdvancedRotation = "viewer.showsAdvancedRotation"
    }

    /// How big a file splat is made when it's first opened, and what Reset
    /// returns to. SfM captures have arbitrary units, so every size except
    /// Life size rescales the splat to fit.
    enum InitialSize: String, CaseIterable, Identifiable, Sendable {
        case tabletop
        case dollhouse
        case room
        case lifeSize

        var id: Self { self }

        var title: String {
            switch self {
            case .tabletop: "Tabletop"
            case .dollhouse: "Dollhouse"
            case .room: "Room"
            case .lifeSize: "Life Size"
            }
        }

        /// Meters the longest horizontal extent is fitted to. Nil means don't
        /// fit: render at the file's own units, which is only right for
        /// captures that are already metric.
        ///
        /// Dollhouse matches `SplatSceneState.autoFitExtent`, the behavior
        /// before this preference existed; a test pins the two together.
        var fitExtent: Float? {
            switch self {
            case .tabletop: 0.5
            case .dollhouse: 1.5
            case .room: 4
            case .lifeSize: nil
            }
        }
    }

    var initialSize: InitialSize

    /// Simulator joystick translation speed, meters per second. Has no effect
    /// on device, where walking is walking.
    var joystickSpeed: Float

    static let joystickSpeedRange: ClosedRange<Float> = 0.5...5.0

    /// How the Viewer looks and responds when a splat opens.
    var viewerDisplay: ViewerDisplay

    static let defaults = AppPreferences(initialSize: .dollhouse, joystickSpeed: 1.8)

    init(initialSize: InitialSize, joystickSpeed: Float, viewerDisplay: ViewerDisplay = .defaults) {
        self.initialSize = initialSize
        self.joystickSpeed = joystickSpeed
        self.viewerDisplay = viewerDisplay
    }

    /// Anything missing, unrecognized, or unusable falls back to the default
    /// rather than failing: a stale value from an older build must never stop
    /// a splat from opening.
    ///
    /// `locale` only decides the ruler units when none are stored; tests pass
    /// one so the result doesn't depend on the machine running them.
    init(reading store: UserDefaults, locale: Locale = .current) {
        let fallback = Self.defaults
        viewerDisplay = ViewerDisplay(reading: store, locale: locale)

        initialSize = store.string(forKey: Key.initialSize)
            .flatMap(InitialSize.init(rawValue:))
            ?? fallback.initialSize

        // `double(forKey:)` reads a missing key as 0, which would clamp to the
        // slowest speed instead of the default, so check the type first.
        if let stored = store.object(forKey: Key.joystickSpeed) as? NSNumber {
            joystickSpeed = Self.sanitizedJoystickSpeed(stored.doubleValue)
        } else {
            joystickSpeed = fallback.joystickSpeed
        }
    }

    /// Non-finite values mean the store is corrupt, so they get the default;
    /// finite ones out of range are clamped, keeping the user's intent.
    static func sanitizedJoystickSpeed(_ value: Double) -> Float {
        guard value.isFinite else { return defaults.joystickSpeed }
        let range = joystickSpeedRange
        return min(max(Float(value), range.lowerBound), range.upperBound)
    }
}

// MARK: - Viewer display

extension AppPreferences {

    /// The Viewer's display and control toggles, stored so switching splats
    /// doesn't reset them.
    ///
    /// One stored value per setting. The Viewer's menu writes changes back
    /// ("last used wins") and Settings edits the same keys, so there is no
    /// separate "default" and "current" to drift apart. Only explicit user
    /// actions write: the Viewer falling back because something is
    /// unavailable (no AR, so no occlusion) must never overwrite a stored
    /// `true`.
    nonisolated struct ViewerDisplay: Equatable, Sendable {
        var areGesturesEnabled: Bool
        var locksToSingleAxis: Bool
        var showsPlacementIndicators: Bool
        /// Stored independently of the indicators, so turning those off and
        /// on again brings the ticks back the way they were.
        var showsMeasuringTicks: Bool
        var rulerUnits: RulerUnits
        var background: ViewerBackground
        var occludesBehindSurfaces: Bool
        /// What a splat opens at. The Viewer can change it for the splat on
        /// screen, but that doesn't write back: a re-read that big should be
        /// a deliberate default, not a side effect of one heavy file.
        var quality: SplatQuality
        /// Last used only; Settings doesn't show it. Nil means every section
        /// was collapsed.
        var expandedSection: ViewerMenuSection?
        /// Last used only; Settings doesn't show it.
        var showsAdvancedRotation: Bool

        /// Matches `ViewerUIState`'s initial values, which is what the Viewer
        /// did before any of this was stored; a test pins the two together.
        /// Reading an empty store differs only in `rulerUnits`, which comes
        /// from the locale (`defaultRulerUnits(for:)`).
        static let defaults = ViewerDisplay(
            areGesturesEnabled: true,
            locksToSingleAxis: false,
            showsPlacementIndicators: false,
            showsMeasuringTicks: true,
            rulerUnits: .meters,
            background: .camera,
            occludesBehindSurfaces: false,
            quality: .full,
            expandedSection: .placement,
            showsAdvancedRotation: false)

        /// Stored for "every section collapsed", which a missing key can't
        /// express: missing means "never set", and reads as the default.
        static let noExpandedSection = "none"

        /// Feet where the locale measures in US customary units, meters
        /// everywhere else (including the UK, which measures rooms in meters).
        static func defaultRulerUnits(for locale: Locale) -> RulerUnits {
            locale.measurementSystem == .us ? .feet : .meters
        }

        init(areGesturesEnabled: Bool,
             locksToSingleAxis: Bool,
             showsPlacementIndicators: Bool,
             showsMeasuringTicks: Bool,
             rulerUnits: RulerUnits,
             background: ViewerBackground,
             occludesBehindSurfaces: Bool,
             quality: SplatQuality,
             expandedSection: ViewerMenuSection?,
             showsAdvancedRotation: Bool) {
            self.areGesturesEnabled = areGesturesEnabled
            self.locksToSingleAxis = locksToSingleAxis
            self.showsPlacementIndicators = showsPlacementIndicators
            self.showsMeasuringTicks = showsMeasuringTicks
            self.rulerUnits = rulerUnits
            self.background = background
            self.occludesBehindSurfaces = occludesBehindSurfaces
            self.quality = quality
            self.expandedSection = expandedSection
            self.showsAdvancedRotation = showsAdvancedRotation
        }

        /// Per-field fallback, like `AppPreferences(reading:)`: one bad value
        /// costs that setting, not the rest.
        init(reading store: UserDefaults, locale: Locale = .current) {
            let fallback = Self.defaults

            // `bool(forKey:)` reads a missing key as false, which is wrong for
            // the settings that default to true, so check the type first.
            func bool(_ key: String, _ defaultValue: Bool) -> Bool {
                store.object(forKey: key) as? Bool ?? defaultValue
            }
            func value<T: RawRepresentable>(_ key: String, _ defaultValue: T) -> T where T.RawValue == String {
                store.string(forKey: key).flatMap(T.init(rawValue:)) ?? defaultValue
            }

            areGesturesEnabled = bool(Key.gesturesEnabled, fallback.areGesturesEnabled)
            locksToSingleAxis = bool(Key.locksToSingleAxis, fallback.locksToSingleAxis)
            showsPlacementIndicators = bool(Key.showsPlacementIndicators, fallback.showsPlacementIndicators)
            showsMeasuringTicks = bool(Key.showsMeasuringTicks, fallback.showsMeasuringTicks)
            rulerUnits = value(Key.rulerUnits, Self.defaultRulerUnits(for: locale))
            background = value(Key.background, fallback.background)
            occludesBehindSurfaces = bool(Key.occludesBehindSurfaces, fallback.occludesBehindSurfaces)
            quality = value(Key.quality, fallback.quality)
            showsAdvancedRotation = bool(Key.showsAdvancedRotation, fallback.showsAdvancedRotation)

            switch store.string(forKey: Key.expandedSection) {
            case Self.noExpandedSection: expandedSection = nil
            case let raw?: expandedSection = ViewerMenuSection(rawValue: raw) ?? fallback.expandedSection
            case nil: expandedSection = fallback.expandedSection
            }
        }

        /// Writes every field. Callers pass the whole value, so the stored
        /// set always describes one coherent configuration.
        static func write(_ display: ViewerDisplay, to store: UserDefaults) {
            store.set(display.areGesturesEnabled, forKey: Key.gesturesEnabled)
            store.set(display.locksToSingleAxis, forKey: Key.locksToSingleAxis)
            store.set(display.showsPlacementIndicators, forKey: Key.showsPlacementIndicators)
            store.set(display.showsMeasuringTicks, forKey: Key.showsMeasuringTicks)
            store.set(display.rulerUnits.rawValue, forKey: Key.rulerUnits)
            store.set(display.background.rawValue, forKey: Key.background)
            store.set(display.occludesBehindSurfaces, forKey: Key.occludesBehindSurfaces)
            store.set(display.quality.rawValue, forKey: Key.quality)
            store.set(display.expandedSection?.rawValue ?? noExpandedSection, forKey: Key.expandedSection)
            store.set(display.showsAdvancedRotation, forKey: Key.showsAdvancedRotation)
        }
    }
}
