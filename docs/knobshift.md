# KnobShift

KnobShift provides adaptive transitions for local, non-DRM audio files that a
person explicitly plays in Knob. It is not a system-wide clone of Apple Music
AutoMix.

## Product intent

KnobShift is not a fixed crossfade control. Its intended experience is a
local-music transition that feels arranged for the two songs:

1. KnobShift prepares both selected local tracks before playback.
2. It finds the outgoing song's final phrase and the end of its vocal activity.
3. It begins the incoming song's accompaniment at an appropriate musical cue,
   while the outgoing vocal is still allowed to finish naturally.
4. It fades the outgoing accompaniment away under the incoming accompaniment.
5. It introduces the incoming vocal at that song's own first vocal onset.
6. It reports the real plan and status: `ANALYZING`, `READY`, `KNOBMIX`, or
   `PRESERVING ENDING`.

The handoff length is chosen from the two tracks' analysis. It must not be a
generic 3, 5, 10 or 18-second rule. For example, an outgoing vocal ending
eight seconds before a track finishes may produce an eight-second stem mix,
while another song may need a clean end-to-start handoff.

## Compatibility

| Source | KnobShift support |
| --- | --- |
| Local non-DRM files played in Knob | Supported |
| Apple Music | Apple Music controls its own AutoMix |
| Spotify | Unsupported: its developer policy prohibits DJ-style overlap and mixing |
| YouTube and YouTube Music | Unsupported: no decoded-audio access or sample-accurate second deck |
| Other apps | Unsupported: Knob only receives their final mixed system audio |

## How KnobShift mixes today

KnobShift analyses each local file once, away from the audio callback, then plays
the queue on two `AVAudioPlayerNode` decks. Every transition time comes from the
two songs being mixed. There is no fixed crossfade length anywhere.

### What is measured per song

| Measurement | How | Used for |
| --- | --- | --- |
| Leading and trailing silence | Short RMS windows | Skipping dead air at both ends |
| Vocal start and vocal end | macOS's built-in on-device sound classifier (`SoundAnalysis`, labels singing, rapping, speech, choir and humming) | Where the mix may start, and when the new voice arrives |
| Fade start | A sustained drop in loudness before the end | Fallback for songs without vocals |
| Tempo and beat grid | Spectral flux, autocorrelation and a beat-path search (`State/KnobShiftBeats.swift`), then one grid placed on the kick drum | Tempo sync and lining up the first beats |
| Beat entry and music breaks | Bass loudness under about 120 Hz in half second steps (`State/KnobShiftSections.swift`): the beat enters where the bass comes in and stays for 4 seconds; a break is where it drops out for a second after 4 seconds of music | Ignoring a voice tag before the drums, and leaving a song that sings to the end at its last break |

The vocal detector judges voice against each song's own typical vocal level, so
a quiet ad-lib outro still counts as voice while a single shout after the last
line does not. Its settings (what counts as clear voice, and that a line must
hold for 3 seconds) decide what is vocal. They never decide the crossfade.

Example, measured on real files:

| Song | Voice starts | Voice really ends | Music after the voice |
| --- | --- | --- | --- |
| Ghostface Killah | 0:04.5 | 1:59.25 (ad-libs at 2:05 and 2:08 ignored) | 15.4s |
| Shaukeen | 0:10.5 | 2:38.25 | 11.4s |
| No Luck | 0:00 | 2:58.5 | 15.2s |
| Why So | 0:04.5 | 3:52.5 | 0.7s |

### How a transition is planned (`State/KnobShiftPlanner.swift`)

**Measured on Apple Music (2026-11-01)**, from a room recording of its AutoMix of
Naggnee into Sardaari, aligned against both files:

| | Apple Music | KnobShift since this change |
| --- | --- | --- |
| New song starts | Sardaari 0:00 at Naggnee 2:08.4, 8s before Naggnee's voice ends | 0:00.5 at 2:11.5 |
| New song opens up | about 2:23 | 2:22.1 |
| Old song gone | about 2:29, at its own fade (2:28.6) | 2:28.7 |
| Speed | both exactly normal speed, though 25% apart in tempo | none (sync only within 8%) |
| Old song's exit | treble goes first, the middle lingers | low pass closing to 1 kHz, bass swapped |

Apple's long overlap let the old voice run on over the new song for 4 to 12
seconds, which sounded wrong, so since 2026-11-03 KnobMix follows DJ practice
instead: two voices are never heard together, and a mix is short.

The rules (`KnobShiftPlan`, checked by `--knobshift-mix-check`):

1. **Length.** About 8 seconds, in whole bars of the old song's beat, never more
   than 10 (`length(bar:)` keeps it to 6 to 9.5 so a tempo glide stays under 10).
   A long outro is skipped, never filled.
2. **Old voice first.** The new song's beats come in at most 2 seconds before the
   old voice ends (one bar on fast songs), quietly and beats only. The new song
   opens up fully only once the old voice has ended.
3. **Old song leaves.** After its voice the old song plays out with its exit
   effects for the rest of the mix, then is gone.
4. **New voice last.** The new song's main verse lands as the old song is gone.
   Its separated voice is held silent until the mix's last 2 seconds; the old
   separated voice clears within half a second of its end (`voiceLevels`).
5. **Singing to the end.** When the singing runs right to the end (under a bar
   of music after it), the voice is cut in the last minute, at least four bars
   before the end (`cutPoint`): at the last music break, else where a sung line
   ends, else where the song starts fading under the voice. Example: Why So sings
   through its fade to 3:52.5, so it is cut at its 3:41.25 line ending.
6. **Vocal throw.** A cut voice (singing to the end, or KnobMix Now) and tempos
   more than 8% apart leave as a vocal throw of about 5 seconds after the cut,
   in whole beats (`throwLength`, `throwLevels`): the old music fades slowly in
   time with the new beats, the old separated voice alone slows like tape to 85%
   speed as heard, its pitch falling, into a hall rising to 60%, and is gone
   before the new voice comes in. Without a separated voice the old song echoes
   out within the first 40%.
7. **Matching wider tempos.** Up to 8% apart the old song eases on its own. In a
   vocal throw the songs also lock up to 20% apart, meeting in the middle: the
   new beats run up to 8% off their own speed while only they play, the old song
   carries the rest (up to 12%, or alone when the new beats have under a bar to
   themselves). The shared tempo reaches the new song's own only in the last 10%
   of the mix, so the old voice is never rushed by the whole gap. Strong beats
   meet strong beats (every second beat from each song's beat entry,
   `strongBeat`), so a song counted at double or half time never puts its kick
   on the other's snare. Further apart, the old music drops within about half a
   second.
8. **Exit effects.** Beat locked mixes use the tape slowdown into a hall: the
   hall starts on the old voice's last word and rises to 35% on the beat pulse,
   and the slowdown is a wind down over the last 1.5 seconds of the exit (never
   more than its last half, `windDown`). In a vocal throw the voice slows instead
   of the whole deck. A closing low pass and the bass swap apply to every exit.
   No flanger, by choice.
9. Songs without vocals mix over the last 6 to 9.5 seconds of their fade. With
   no voice and no fade, the songs meet cleanly at the audible end.

Measured on real songs with the real planner (`--knobshift-sync-check`) and the
muted engine (`--knobshift-check`):

| Pair | Mix | Beats |
| --- | --- | --- |
| Low Fade into Bodyguard (female first verse) | 8.0s, old voice gone at 2.4s, new voice from 6.5s | locked |
| Bodyguard into Kaali Hoodie | 8.3s | locked |
| Jee Karuga into Why So | 7.7s | locked |
| Sardaari into Bodyguard | 3.3s, cut at its 3:36.9 break | locked |
| Putt Jam Te Lau into Sardaari | 4.0s, cut at its 3:30.6 break | locked |
| Kaali Hoodie into Jee Karuga | 1.7s echo out, old sound gone at 0.7s | 172 and 186 BPM, not locked |
| Why So into Sardaari | 0.8s, Why So sings to its last second with no break | 90 and 82.5 BPM, not locked |

**Main verse.** The incoming song's main verse is the first steady line at that
song's normal singing level; quieter intro ad-libs do not count, and neither does
any voice before the beat comes in (a tag or shout over the intro). The verse is
placed on the four bar phrase grid counted from the beat entry, because the
classifier hears a line up to a bar late. Example: Sardaari has a loud tag at
0:02 to 0:05 and drums from 0:06, so its verse lands at 0:17.6, not 0:01.5.
Before the handoff the incoming bass and melody range are held back, so only its
beats mix under the old voice.

The log gives the exact clock time of every planned mix, for example "the mix
starts at 12:23:36 AM, in 6s", and the time the voices hand over.

Measured on the playlist (Ghostface Killah, No Luck, Shaukeen, Why So, looping
back to the first song):

| Pair | New song starts at | Blend | Tempo |
| --- | --- | --- | --- |
| Ghostface Killah into No Luck | 0:07.20 (skips its intro) | 1:54.45 to 2:04.05, Ghostface skips its last 10.6s | old song slows 28%, new beats 18% fast until its vocals |
| No Luck into Shaukeen | 0:08.69 | 2:55.19 to 3:01.81 | old song slows 29%, new beats 19% fast until its vocals |
| Shaukeen into Why So | 0:00.58 | 2:33.58 to 2:42.92 | old song slows 12%, new beats 14% fast until its vocals |
| Why So into Ghostface Killah | 0:05.92 | 3:47.17 to 3:53.22 | old song speeds up 11%, new beats 10% slow until its vocals |

The volumes, tempo and bass are updated about 20 times a second. Each update
waits for its own deadline from the blend start, so the handoff lands exactly
on the planned end. After the handoff the incoming song's clock carries on from
where its deck really is, so the next plan is on time. The queue loops: the
last song mixes into the first.

### KnobMix Now

The KNOBMIX NOW button under the transport mixes into the next song on request,
but never at a random moment. It finds the next good mixing point in the playing
song: the start of the next four bar phrase (counted from where the beat comes
in) or the next break in the music, whichever comes first, at least two bars
away so the new song's beats can come in underneath first. In practice that is
about 4 to 15 seconds. The planner then runs as usual with that point as the
handoff, so beat lock, tempo glide and the beats only entry all apply. While it
waits the button reads WAITING FOR THE BEAT. If the planned mix would come
sooner anyway, or is already easing in, the press changes nothing.

Check: `Knob --knobshift-mixnow-check A B SECONDS` seeks to SECONDS, presses the
button muted, and reports where the mix landed. On Putt Jam Te Lau into
Sardaari, pressed at 1:01 it handed over on the phrase at 1:13.2; pressed at
1:36, at 1:46.7.

### Tempo sync, beat lock and bass swap

Each song gets an exact beat grid. The beat tracker can follow the kick in one
section and a hi-hat triplet or off-beat in the next, so its beats jump by part
of a beat between sections. Produced tracks keep one tempo, so KnobShift then
searches for one continuous grid across the whole song, trying tempos within
±0.3% and 96 positions within the beat, and keeps the grid with the most kick
drum (bass below about 170 Hz) on its beats. Measured: Ghostface Killah 100.00
BPM, Why So 90.00, Shaukeen 102.68, with drum hits 3 to 4 ms from the grid.
Songs whose tempo really changes keep one grid per drum section. A test track
made at exactly 120 BPM reads 120.0, with every beat within 3 ms.

During a blend (`State/KnobShiftSync.swift`, `State/KnobShiftModel+Blend.swift`):

- **The new voice is never stretched.** The incoming song may run off its own
  speed only while just its beats play under the old voice, and it is back at
  exactly its own speed when its vocals start. The outgoing song carries the
  rest of the tempo change (up to 30%), which is the audible "slow down".
- **Close tempos (within 15%):** the shared tempo starts at the outgoing tempo
  and reaches the incoming tempo at the handoff.
- **Further apart:** over its last two bars before the blend the outgoing song
  eases to a tempo between the two, the incoming beats come in there (at most
  20% off), and both glide on to the incoming tempo by the handoff. When the
  incoming song has less than a bar of beats before its vocals, it plays at its
  own speed throughout and the outgoing song eases all the way first.
- **Beat lock:** the incoming song starts on one of its own beats, scheduled
  sample-accurately to land on the outgoing song's next beat.
- **Bass swap:** the incoming song's bass is held back with a high-pass filter
  (`AVAudioUnitEQ`, up to 200 Hz), along with its melody range, and at the
  handoff the two basslines swap,
  so two kicks and basslines never stack.
- **Rising filter:** as the outgoing song fades, its filter keeps rising to
  2 kHz, so it thins out upward into the next song.
- The blend still ends when the outgoing music runs out, even though that song
  plays slightly faster or slower during the glide.

Each deck is player → time-stretch → bass filter → mixer (`State/KnobShiftDeck.swift`).
At normal speed the time-stretch unit is sample-identical to its input, and the
filter rests at 10 Hz, so both stay connected all the time; switching effects in
and out mid-song would cause a jump. Measured offline: no clicks while gliding
the speed, and under 5 ms of added delay at ±3%.

Ghostface Killah into Shaukeen: tempo sync 100.0 to 102.7 BPM, Shaukeen starts
at 0.974 speed on a Ghostface beat and ends at 1.000, bass swaps at the middle.
In simulation the beats stay within 1 ms for the whole blend, against 140 to 200
ms apart without sync.

KnobShift must never claim to detect a last lyric from plain audio. The vocal
end is where steady voice stops, not a lyric reading.

## Diagnostics

Every analysis step, plan decision, deck change, timing check and blend level
is logged:

- **In the player:** the KnobShift log sits under the visualizer (SHOW / HIDE).
  It groups entries under a heading per song and per transition, gives each
  kind of step an icon, and draws the blend as a live OUT / IN meter.
- **On disk:** `~/Library/Logs/Knob/knobshift.log` (`Knob (dev)` for the dev
  copy), next to `engine.log`. OPEN FILE in the player opens it. Columns are
  aligned and each song or transition starts with a heading line. It moves to
  `knobshift.old.log` past 1 MB.

Checks from Terminal (the second one is muted unless a volume is given):

```bash
build/Knob.app/Contents/MacOS/Knob --knobshift-analysis-check SONG       # every analysis step
build/Knob.app/Contents/MacOS/Knob --knobshift-check SONG_A SONG_B [VOL] # real two-song mix, VOL 0 to 100
build/Knob.app/Contents/MacOS/Knob --knobshift-sync-check SONG_A SONG_B  # beat alignment through the blend, no audio needed
```

The two-song check jumps to six seconds before the planned blend, waits for the
real handoff and fails if the clock restarts at zero after a blend.

## What is known about Apple Music AutoMix

Apple has published very little. Its own description says AutoMix uses key and
tempo analysis, time stretching and beat matching, and that transitions vary
with the music. It works only on Apple Music catalog songs (not uploads or
purchases), which suggests the analysis is prepared on Apple's side. No source
says it separates vocals. Reviewers report overlaps of up to about 20 seconds
and occasional cut-short endings. The closest public design is Spotify's patent
US11461389: candidate cue points near the end of one song and the start of the
next are scored on loudness, timbre, key and vocal overlap, with a plain
crossfade when nothing scores well. KnobShift's vocal-end rule follows the same
idea of avoiding vocal overlap.

## Song-aware mix architecture

Apple-style mixing is not a duration slider. For a local, non-DRM file,
KnobShift needs an offline analysis record keyed by the file's content hash:

1. **Rhythm:** BPM, beat positions, bar positions, downbeats and confidence.
2. **Harmony:** key, scale and compatibility with the next track.
3. **Structure:** intro, verse, chorus, breakdown and outro candidates with
   confidence, based on loudness, repetition and onset patterns.
4. **Vocals and lyrics:** vocal activity and, when the user provides a timed
   LRC or TTML lyric file, an exact final-lyric timestamp. Plain audio alone
   cannot reliably identify the last sung word.
5. **Stem separation:** an on-device local model separates each selected song
   into a vocal stem and accompaniment stem. Original files and generated stems
   remain on the Mac in a content-hash cache.
6. **Mix planner:** candidate pairs are scored by phrase alignment, compatible
   tempo and key, outgoing vocal boundary, incoming vocal onset, incoming
   downbeat and transition confidence. The selected plan contains source and
   destination cue points, a target tempo, independent vocal/accompaniment
   envelopes and an explicit fallback.
7. **Four-stem renderer:** outgoing vocal, outgoing accompaniment, incoming
   accompaniment and incoming vocal are independently scheduled ahead of time.
   A limited time-stretch unit aligns tempo while preserving pitch; gain
   envelopes, limiter headroom and sample-accurate host-time scheduling prevent
   clicks and volume jumps.

Until every required signal is confident, the renderer must choose a clean
end-to-start handoff. It must not use a generic 3 or 5-second blend.

## Player status

The player must report the actual state, never a marketing label:

- `ANALYZING`: local file features are being calculated.
- `READY`: shows where the blend starts, how long it lasts and why (for
  example "after the last vocal line ends").
- `KNOBMIX`: the blend is running; the log shows its live OUT / IN levels.
- `PRESERVING ENDING`: no vocal end or fade was found before the audible end,
  so the current track finishes whole and the next one starts cleanly.

## Platform boundary

KnobShift can render this workflow only for local audio it decodes itself.
Apple Music's AutoMix is implemented by Apple for Apple Music catalog content;
Knob cannot insert itself into that protected playback path. Spotify's
developer policy prohibits apps from segueing, mixing or overlapping Spotify
content. YouTube's developer policy prohibits separating or modifying an
API-served video's audio component. Those sources may be launched or
controlled in their own players, but cannot be truthfully advertised as
KnobShift-mixable.

## Delivery sequence

1. Done: per-song analysis with silence, fade, tempo and vocal start and end.
2. Done: vocal-aware planning with no fixed crossfade length, and the honest
   `ANALYZING`, `READY`, `KNOBMIX` and `PRESERVING ENDING` states.
3. Done: full diagnostics in the player and in `knobshift.log`.
4. Done: exact beat grids on the kick drum, tempo sync with natural pitch, and
   beat-locked starts.
5. Done: a bass swap during the blend.
6. Later: on-device vocal and accompaniment separation for songs sung to the
   very end, so the outgoing vocal can finish over the incoming music. Only the
   intro and outro need separating. Needs a decision on downloading the model
   (about 80 to 400 MB) and a licence check of its weights.
7. Done: each song is analysed once. The result is saved in Knob's Application
   Support folder (`KnobShift Analysis/`, apart for the dev and installed
   copies) and reused while the file's path, size and date and the analysis
   version match, so opening Knob loads a queue in milliseconds instead of 4 to
   6 seconds per song (`State/KnobShiftAnalysisCache.swift`). Bump its
   `version` whenever the analysis changes.
8. Test with varied genres and listen for lyric cuts, beat drift, clipping,
   clicks, dropped frames, sleep and wake, and output changes.

## Test plan

- Local tracks with silence, no silence, and very short duration
- Missing and unreadable selected files
- Repeated play, stop, remove, and playlist loops
- Sleep/wake and output-device changes during a transition
- Listen for clicks, clipping, a volume dip, late starts, or skipped material

## Spotify playlists

See [knobshift-spotify-plan.md](knobshift-spotify-plan.md) for the original plan. spotDL (bundled, fetched by `packaging/fetch-spotdl.sh`) reads a Spotify list and downloads its songs into `~/Music/KnobShift/Spotify/<playlist>/`, one file per song named with its Spotify id. KnobShift queues them in Spotify's order, names them from their tags, and prepares and mixes them like any song.

### How an import goes

1. **Choose a list.** Paste a playlist, album or song link. Or log in and use Liked Songs or one of **Your playlists**.
   - *Your playlists* comes straight from Spotify's Web API (`/me/playlists`), using the token spotDL saved at login (scope `playlist-read-private`).
   - `State/KnobShiftSpotifyAccount.swift` refreshes that token the same way spotDL's Spotify library does and writes it back, so both keep working.
2. **Read.** `spotdl save` reads the song list without downloading anything. The sheet offers Cancel while it reads.
3. **Pick.** The song picker (`Views/KnobShiftSpotifyPicker.swift`) shows a tick box per song, with All, None and search.
   - Songs already in the queue are ticked and locked.
   - Songs unticked last time start unticked; they're kept in the playlist's `skipped` list.
4. **Queue.** The ticked songs appear in the queue at once, in one update. Songs already on disk go straight to preparing.
   - The chosen songs are written, exactly as spotDL describes them, to `knobshift-songs.spotdl` in the playlist folder.
   - Downloads and retries use that file (`spotdl download <file>`), so Spotify is never asked again.
5. **Download.** Downloads run one playlist at a time (`KnobShiftLane`); single-song retries have their own lane.
   - Progress shows "12 of 340" and the song spotDL is on, in the sheet and in the queue's playlist row (`Components/KnobShiftImportBar.swift`).
   - Progress reaches the views at most twice a second, and finished files at most once a second.
6. **Hand over.** A file joins the queue only after spotDL prints `Downloaded "…"` or `Skipping … (file already exists)` for it, or after spotDL exits. spotDL converts straight into the playlist folder, so a file seen earlier may be half written.

### What can go wrong, and what happens

| Case | What KnobShift does |
| --- | --- |
| Song not found on YouTube | Its row says Not found. **Retry** on the playlist row tries all failed songs again. |
| No internet, Spotify busy (429) | The remaining rows say No internet or Spotify busy, with Retry. |
| spotDL silent for 15 minutes | It's stopped along with everything it started; the remaining rows say Stopped. |
| Not enough disk space | Nothing starts. The status gives the space needed (about 6 MB a song plus 500 MB) and the space free. |
| Cancel | spotDL and its children (Python, FFmpeg) get SIGTERM, then SIGKILL after 3 seconds. Unfinished files from the last few minutes are deleted. Waiting rows leave the queue and aren't resumed after a relaunch. |
| A file that won't read (broken download) | The file is deleted and its row says Download broke; Retry downloads it again. |
| Knob quits mid download | On the next launch, songs from `knobshift-songs.spotdl` with no file yet come back and continue. |
| A stray child keeps spotDL's output open | The result still arrives 2 seconds after spotDL exits; nothing waits forever. |
| Login | It finishes as soon as the token file appears, and Knob comes to the front. LOG IN turns into CANCEL while waiting, and it gives up after 3 minutes. |

spotDL runs with `COLUMNS=1000`, because its display otherwise wraps at 80 columns and splits song names across lines.

### Keeping it fast with thousands of songs

- **Playback values** (position, duration, blend) live in `KnobShiftClock`. Only the timelines (`Components/KnobShiftTimeline.swift`) redraw ten times a second, not the queue.
- **Values nothing shows** (the diagnostics list, the transition description) are not published, so they never redraw anything.
- **Bulk row changes** edit a copy of `pending` and assign it once. Changing a published array one row at a time copies the whole array on every change.
- **Duplicate checks** use sets.
- **The saved queue** is written at most about once a second (`KnobShiftModel+Persist.swift`).
- **spotDL output:** only its last 300 lines are kept in memory.

### Checks

- **Self test, offline:** `--knobshift-spotify-check selftest` with `KNOB_SPOTIFY_ROOT` set to a temporary folder. It covers message parsing, progress, selection, save files, the line collector, the lane, stopping process trees, and speed with 1,000 rows.
- **UAT:** `--knobshift-spotify-check uat 40` runs the whole flow against `tests/fake-spotdl.py` in a temporary folder. It covers picking, updating, cancelling, two playlists at once, a silent spotDL plus Retry, a stray child holding output, and quitting then reopening. It reports the longest main-thread stall, which must stay under 250 ms, and deletes its files and the test analysis cache when done. 30 to 40 songs are enough.
- **Real list, no download:** `--knobshift-spotify-check LINK`.
- **Test overrides:**
  - `KNOB_SPOTDL`, `KNOB_FFMPEG`: the helper paths.
  - `KNOB_SPOTDL_IDLE`: the silence limit, in seconds.
  - `KNOB_SONG_MB`: the space estimate per song.

## YouTube

yt-dlp (bundled in `Contents/Resources/yt-dlp`, fetched and pinned by `packaging/fetch-spotdl.sh`, Apple silicon only) reads a YouTube video, playlist, YouTube Music album or Liked videos and downloads each song into `~/Music/KnobShift/YouTube/<playlist>/`. Everything after reading the list is the Spotify code: the picker, queue rows, progress, Cancel, Retry, Update, remove and restore, and resume after a relaunch.

### How it fits the Spotify code

- **Ids.** A YouTube playlist's id is `yt:` plus YouTube's id, so `KnobShiftPlaylist.source` is read from the id and playlists saved before 3.0 load unchanged. Songs keep the video id in `spotifyId`.
- **Files.** Songs are saved as `07 Song - Artist [yt-VIDEOID].m4a`. The `yt-` keeps the id apart from Spotify's 22 character ids and from ordinary brackets (`KnobShiftPlaylists.songId(inFileName:)`), and the name shows through `Track.split`, so no tags are needed.
- **Song list.** yt-dlp's list is turned into spotDL's save file shape (`KnobShiftYouTubeParsing.listing`) and kept in `knobshift-songs.spotdl`, so resume and retry need no second read.
- **Branch points.** Only three places check the source: reading a list (`readYouTube`), downloading (`runDownload` hands YouTube playlists to `runYouTubeDownload`), and single song retries.
- **One lane.** YouTube downloads share the Spotify download lane, because spotDL downloads from YouTube too and the two must not hit YouTube at once.
- **Runner.** spotDL and yt-dlp both run through `State/KnobShiftHelperProcess.swift`: line output, cancel with every child, an idle limit, and stop on quit.

### Being gentle with YouTube

- **One at a time.** yt-dlp runs once per song, with a pause of 2 to 4 seconds between songs.
- **Stops early.** A bot check, no internet twice in a row or a full disk stops the rest of the playlist; the remaining rows say why, with Retry.
- **Name search.** A video that is gone, private, blocked in this country or age restricted is searched as `ytsearch1:<artist> <name>` (under 15 minutes) and saved under the original id, so it lands in the same row.
- **Safe arguments.** Pasted links are rebuilt from validated ids (`parseLink`). The link always comes after `--`, so nothing in it is read as an option.

### Signing in and the dashboard

Knob signs in the way TV apps do, with Google's device flow (`State/KnobShiftGoogleAuth.swift`). Nothing is read from any browser.

1. **Google key.** The person adds their own Google key in the YouTube sheet: an OAuth client of the type "TVs and Limited Input devices", with YouTube Data API v3 turned on and their account added as a test user. A key made for a TV launcher works as it is. Saving it asks Google for a code first, so a wrong key or key type is refused straight away.
2. **Code.** SIGN IN WITH GOOGLE shows a short code, copies it and opens google.com/device. Knob asks Google every few seconds until the code is entered. The scope is `youtube.readonly`.
3. **Storage.** The key and the refresh token live in `google-youtube.json` (owner only) in Knob's Application Support folder, beside yt-dlp's folder rather than inside it. The access token stays in memory. Sign out asks Google to forget the sign in; REMOVE deletes the key too. While Google keeps the app in test mode, a sign in lasts 7 days, then Knob signs out with a message.
4. **Old sign in.** Cookie files from the earlier browser sign in are deleted at launch.

The dashboard (`KnobShiftYouTubeAPI.swift`, `KnobShiftYouTubeHub.swift`, `KnobShiftModel+YouTubeDashboard.swift`, `Views/KnobShiftYouTubeDashboard.swift`):

| Row | Where it comes from | Daily allowance used |
|---|---|---|
| Liked music | `videos?myRating=like`, up to 200 | 1 per 50 |
| Your playlists | `playlists?mine=true`; a card opens `playlistItems` | 1 per 50 |
| New music from subscriptions | the 30 most relevant subscriptions (read once a day), each channel's public feed for the last 30 days, then categories and lengths | feeds are free, 1 per 50 videos |
| Popular music in the Mac's country | `chart=mostPopular&videoCategoryId=10` | 1 |

- **Music only** (on by default, `PersistKey.knobShiftYouTubeMusicOnly`) keeps category 10 between 1 and 15 minutes. The person's own playlists are never filtered.
- Rows are read at most every 2 hours. A row opens in the same song picker, under the ids `yt:LL`, `yt:KNOBNEW` and `yt:KNOBPOPULAR`; Update reads them again through Google (`updateYouTubeFromGoogle`).
- A pasted link to a private playlist of the person's own is read through Google instead of yt-dlp.
- Downloads never sign in. Private and signed in only videos are searched by name instead.

### Checks

- **Self test, offline:** `--knobshift-youtube-check selftest`. It covers links, title cleanup, list reading, file ids, sources and folders, yt-dlp arguments, error reading, Google's sign in answers, the YouTube Data API's answers, channel feeds and the music filter.
- **Dashboard UAT:** `--knobshift-youtube-check uat` (development builds). It goes through the dashboard with the same calls the buttons make, against a fake Google inside the app and in temporary folders: key, sign in and cancel, rows, Music only, picker into the queue, Update, cancel a read, a Google hiccup, a sign in running out, sign out and REMOVE.
- **Real list:** `--knobshift-youtube-check LINK`; add `--download` to download the first song into a temporary folder.
- **Test overrides:** `KNOB_YTDLP` and `KNOB_FFMPEG` (helper paths), `KNOB_YOUTUBE_ROOT` (the music folder).
