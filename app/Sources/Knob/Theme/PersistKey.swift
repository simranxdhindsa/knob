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
    /// Paths for the local files the user has added to KnobShift's queue.
    case knobShiftQueue = "knob.shift.queue"
    /// Full screen on the Mac shows the record deck.
    case knobShiftVinyl = "knob.shift.vinyl"
    /// The iPhone on its side on a charger shows the clock beside the record.
    case knobShiftBedside = "knob.shift.bedside"
    /// The guide's tips that are done with (DeckTip), by name.
    case knobShiftTipsSeen = "knob.shift.tipsSeen"
    /// While shuffle is on, the shuffled order; `knobShiftQueue` keeps the user's own order.
    case knobShiftShuffledQueue = "knob.shift.shuffledQueue"
    /// Whether the saved arranged order (`knobShiftShuffledQueue`) is Mix Order rather than shuffle.
    case knobShiftMixOrdered = "knob.shift.mixOrdered"
    /// The song last in the player and where it was, so the next launch has it ready to play.
    case knobShiftLastSong = "knob.shift.lastSong"
    case knobShiftLastPosition = "knob.shift.lastPosition"
    /// Songs synced from the Mac and taken out of the iPhone's queue, as "playlist/song".
    case knobShiftPhoneDeclined = "knob.shift.phone.declined"
    /// The queue shows its Spotify and YouTube playlist rows; off by default, a header button shows them.
    case knobShiftShowPlaylists = "knob.shift.showPlaylists"
    /// Whether the dedicated KnobShift window was visible when Knob last quit.
    case knobShiftWindowOpen = "knob.shift.windowOpen"
    case knobShiftSpotifyNoticeAccepted = "knob.shift.spotify.noticeAccepted"
    case knobShiftYouTubeNoticeAccepted = "knob.shift.youtube.noticeAccepted"
    /// The YouTube dashboard shows only music (category 10); on by default.
    case knobShiftYouTubeMusicOnly = "knob.shift.youtube.musicOnly"
    /// The browser whose YouTube sign in downloads may use once YouTube blocks them; off by default.
    case knobShiftYouTubeBrowser = "knob.shift.youtube.browser"
}
