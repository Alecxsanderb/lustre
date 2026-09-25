//
//  AppPreferences.swift
//  Lustre
//
//  User preferences, read once from UserDefaults as a plain value.
//
//  Settings writes the same keys through `@AppStorage`; everything else gets a
//  snapshot from `ContentView` instead of reading UserDefaults itself, so
//  features stay unaware of where preferences live and tests can hand in any
//  values they like.
//

import Foundation

nonisolated struct AppPreferences: Equatable, Sendable {

    /// UserDefaults keys. Shared with `SettingsView`'s `@AppStorage`, so a
    /// rename here is a rename there — but it also orphans stored values, so
    /// don't rename.
    enum Key {
        static let initialSize = "viewer.initialSize"
        static let joystickSpeed = "viewer.simulatorJoystickSpeed"
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

    static let defaults = AppPreferences(initialSize: .dollhouse, joystickSpeed: 1.8)

    init(initialSize: InitialSize, joystickSpeed: Float) {
        self.initialSize = initialSize
        self.joystickSpeed = joystickSpeed
    }

    /// Anything missing, unrecognized, or unusable falls back to the default
    /// rather than failing: a stale value from an older build must never stop
    /// a splat from opening.
    init(reading store: UserDefaults) {
        let fallback = Self.defaults

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
