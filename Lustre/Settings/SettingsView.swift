//
//  SettingsView.swift
//  Lustre
//
//  App preferences, plus the version and how much space the library takes.
//
//  Writes straight to UserDefaults through `@AppStorage`, under the keys
//  `AppPreferences` reads. Nothing here talks to the Viewer: the next splat
//  opened picks the values up, because `ContentView` reads a fresh snapshot
//  each time it builds one.
//

import SwiftUI

struct SettingsView: View {
    /// Sum of every library file, computed by the caller so Settings doesn't
    /// need the library itself.
    let librarySizeInBytes: Int64

    @AppStorage(AppPreferences.Key.initialSize)
    private var initialSizeRawValue = AppPreferences.defaults.initialSize.rawValue

    @AppStorage(AppPreferences.Key.joystickSpeed)
    private var joystickSpeed = Double(AppPreferences.defaults.joystickSpeed)

    var body: some View {
        Form {
            viewerSection

            #if targetEnvironment(simulator)
            simulatorSection
            #endif

            Section("Storage") {
                LabeledContent("Library",
                               value: ByteCountFormatter.string(fromByteCount: librarySizeInBytes,
                                                                countStyle: .file))
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Build", value: Self.build)
            }
        }
        .navigationTitle("Settings")
    }

    private var viewerSection: some View {
        Section {
            Picker("Initial Size", selection: initialSize) {
                ForEach(AppPreferences.InitialSize.allCases) { size in
                    Text(Self.label(for: size)).tag(size)
                }
            }
        } header: {
            Text("Viewer")
        } footer: {
            Text("How big a splat appears when it opens, and what Reset returns to. Life Size keeps the file's own units, which suits captures that are already in meters. The sample room always opens at its real size.")
        }
    }

    #if targetEnvironment(simulator)
    private var simulatorSection: some View {
        Section {
            VStack(alignment: .leading) {
                LabeledContent("Joystick Speed",
                               value: joystickSpeed.formatted(.number.precision(.fractionLength(1))) + " m/s")
                Slider(value: $joystickSpeed, in: Self.joystickSpeedRange, step: 0.1)
                    .accessibilityLabel("Joystick Speed")
            }
        } header: {
            Text("Simulator")
        } footer: {
            Text("How fast the left joystick moves the camera. Only shown in the simulator; on a device you walk.")
        }
    }

    private static let joystickSpeedRange =
        Double(AppPreferences.joystickSpeedRange.lowerBound)...Double(AppPreferences.joystickSpeedRange.upperBound)
    #endif

    /// Unknown stored values read as the default, the same fallback
    /// `AppPreferences` applies, so the picker never shows no selection.
    private var initialSize: Binding<AppPreferences.InitialSize> {
        Binding {
            AppPreferences.InitialSize(rawValue: initialSizeRawValue) ?? AppPreferences.defaults.initialSize
        } set: {
            initialSizeRawValue = $0.rawValue
        }
    }

    private static func label(for size: AppPreferences.InitialSize) -> String {
        guard let extent = size.fitExtent else { return size.title }
        let meters = Measurement(value: Double(extent), unit: UnitLength.meters)
        return "\(size.title) (\(meters.formatted(.measurement(width: .abbreviated, usage: .asProvided))))"
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
}

#Preview {
    NavigationStack {
        SettingsView(librarySizeInBytes: 1_234_567_890)
    }
}
