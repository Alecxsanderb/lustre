//
//  SettingsView.swift
//  Lustre
//
//  App preferences, plus the version and how much space the library takes.
//
//  Writes straight to UserDefaults through `@AppStorage`, under the keys
//  `AppPreferences` reads. Nothing here talks to the Viewer: the next splat
//  opened picks the values up, because `ContentView` reads a fresh snapshot
//  each time it builds one. The Viewer Display keys are also written by the
//  Viewer's own menu (last used wins), so this edits the same values rather
//  than a separate default.
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

    // Viewer display. Defaults come from `ViewerDisplay`, so a missing key
    // shows what the Viewer would actually open with.
    @AppStorage(AppPreferences.Key.gesturesEnabled)
    private var gesturesEnabled = Display.defaults.areGesturesEnabled

    @AppStorage(AppPreferences.Key.locksToSingleAxis)
    private var locksToSingleAxis = Display.defaults.locksToSingleAxis

    @AppStorage(AppPreferences.Key.showsPlacementIndicators)
    private var showsPlacementIndicators = Display.defaults.showsPlacementIndicators

    @AppStorage(AppPreferences.Key.showsMeasuringTicks)
    private var showsMeasuringTicks = Display.defaults.showsMeasuringTicks

    @AppStorage(AppPreferences.Key.rulerUnits)
    private var rulerUnitsRawValue = Display.defaultRulerUnits(for: .current).rawValue

    @AppStorage(AppPreferences.Key.background)
    private var backgroundRawValue = Display.defaults.background.rawValue

    @AppStorage(AppPreferences.Key.occludesBehindSurfaces)
    private var occludesBehindSurfaces = Display.defaults.occludesBehindSurfaces

    @AppStorage(AppPreferences.Key.quality)
    private var qualityRawValue = Display.defaults.quality.rawValue

    private typealias Display = AppPreferences.ViewerDisplay

    var body: some View {
        Form {
            viewerSection
            viewerDisplaySection

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

    private var viewerDisplaySection: some View {
        Section {
            Toggle("Touch controls", isOn: $gesturesEnabled)

            // Mirrors the Viewer, which only offers the lock while touch
            // controls are on. Disabled rather than hidden, and stored
            // either way.
            Toggle("Lock to one axis", isOn: $locksToSingleAxis)
                .disabled(!gesturesEnabled)

            Toggle(isOn: $showsPlacementIndicators) {
                Text("Position indicators")
                Text("Axis bars at the splat's center and outlines of detected surfaces. Turning this on enables surface detection, which costs performance.")
            }

            // Marks on the indicator bars, so meaningless without them. Kept
            // visible and stored independently, so turning the indicators
            // back on restores them as they were.
            Group {
                Toggle("Measuring notches", isOn: $showsMeasuringTicks)
                LabeledContent("Units") {
                    Picker("Units", selection: rulerUnits) {
                        ForEach(RulerUnits.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .disabled(!showsMeasuringTicks)
            }
            .padding(.leading, 16)
            .disabled(!showsPlacementIndicators)

            LabeledContent("Background") {
                Picker("Background", selection: background) {
                    ForEach(ViewerBackground.allCases) { background in
                        Text(background.title).tag(background)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Toggle(isOn: $occludesBehindSurfaces) {
                Text("Hide splats behind surfaces")
                Text("Needs the camera background and a device with AR support.")
            }

            Picker(selection: quality) {
                ForEach(SplatQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            } label: {
                Text("Detail")
                Text("What splats open at. Changing it in the Viewer only lasts for that splat.")
            }
        } header: {
            Text("Viewer Display")
        } footer: {
            Text("Changes you make in the Viewer's menu also update these.")
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

    // Unknown stored values read as the default, matching `ViewerDisplay`.
    private var rulerUnits: Binding<RulerUnits> {
        Binding {
            RulerUnits(rawValue: rulerUnitsRawValue) ?? Display.defaultRulerUnits(for: .current)
        } set: {
            rulerUnitsRawValue = $0.rawValue
        }
    }

    private var background: Binding<ViewerBackground> {
        Binding {
            ViewerBackground(rawValue: backgroundRawValue) ?? Display.defaults.background
        } set: {
            backgroundRawValue = $0.rawValue
        }
    }

    private var quality: Binding<SplatQuality> {
        Binding {
            SplatQuality(rawValue: qualityRawValue) ?? Display.defaults.quality
        } set: {
            qualityRawValue = $0.rawValue
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
