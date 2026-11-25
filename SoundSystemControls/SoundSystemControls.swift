import AppIntents
import SwiftUI
import WidgetKit

@main
struct SoundSystemControls: WidgetBundle {
    var body: some Widget { OpenMixerControl() }
}

/// Control Center only allows buttons and toggles from other apps, so this opens the mixer.
struct OpenMixerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.SoundSystem.open-mixer") {
            ControlWidgetButton(action: OpenMixerIntent()) {
                Label("App Volumes", systemImage: "slider.vertical.3")
            }
        }
        .displayName("App Volumes")
        .description("Adjust or mute each app separately.")
    }
}
