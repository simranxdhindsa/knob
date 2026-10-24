/// Every persisted setting. Views read and write these only through `@AppStorage`;
/// the model and engine helpers use `UserDefaults` with the same keys.
enum PersistKey: String {
    case selectedTab = "knob.ui.selectedTab"
    case lastPreset = "knob.ui.lastPreset"
    /// Show Knob in the Dock and the ⌘-Tab switcher (default true).
    case showInDock = "knob.ui.showInDock"
    /// Knob's volume while it was the output, for outputs without their own volume (HDMI).
    case lastVolume = "knob.audio.lastVolume"
    /// The physical output Knob raised to 100% underneath itself, until it is given back.
    case raisedOutputUID = "knob.audio.raisedOutputUID"
    /// The power switch as the user last set it. Quitting doesn't change it, so Knob comes back
    /// the way it was left.
    case powerOn = "knob.audio.powerOn"
    /// Knob has asked once for the Accessibility permission its 2% volume keys need.
    case askedKeyAccess = "knob.audio.askedKeyAccess"
}
