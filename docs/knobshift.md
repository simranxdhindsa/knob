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

The vocal handoff:

1. The handoff point is where the outgoing song's last vocal line ends.
2. The incoming song's main verse is the first steady line at that song's
   normal singing level. Quieter intro ad-libs and spoken bits before it do
   not count (No Luck: ad-libs from 0s, main verse at 12s).
3. The incoming music comes in before the handoff: at least two bars (8 beats
   at the outgoing song's own tempo, about 5 seconds at 96 to 100 BPM), or
   earlier still when the incoming intro is longer, so the main verse starts
   around the handoff. It never comes in before the last line begins.
4. Until the handoff the outgoing voice stays up front (dipping only to 85%)
   while the incoming music rises underneath to 70% with its bass held back.
5. At the handoff the basslines swap and the outgoing song fades out, thinning
   upward through a rising filter. It is gone before the incoming main verse
   (with at least one bar of fade), so leftover shouts or ad-libs after its
   last line are never heard over the new verse.
6. Songs without vocals use their measured fade. With no voice and no fade,
   the songs meet cleanly at the audible end: `PRESERVING ENDING`.
7. Seeking past the planned start still blends over whatever music is left.

Measured on the playlist (Ghostface Killah, No Luck, Shaukeen, Why So, looping
back to the first song):

| Pair | New song comes in | Old song gone by | Tempo |
| --- | --- | --- | --- |
| Ghostface Killah into No Luck | 7.50s before the old voice ends | No Luck's main verse (its shouts at 2:05 and 2:08 fall after) | meet in the middle at 85 BPM |
| No Luck into Shaukeen | 11.95s before | one bar after the handoff | meet in the middle at 122 BPM |
| Shaukeen into Why So | 5.25s before | one bar after the handoff | glides 102.7 to 90 BPM |
| Why So into Ghostface Killah | 11.25s before | Why So's end | glides 90 to 100 BPM |

The volumes, tempo and bass are updated about 20 times a second. Each update
waits for its own deadline from the blend start, so the handoff lands exactly
on the planned end. After the handoff the incoming song's clock carries on from
where its deck really is, so the next plan is on time. The queue loops: the
last song mixes into the first.

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

- **Tempo glide (up to 15% apart):** both songs play at one shared tempo that
  glides from the outgoing tempo to the incoming one on the same curve as the
  volumes, so the old song audibly eases toward the new tempo. The big speed
  change falls on whichever song is quiet at the time. Pitch stays natural
  (`AVAudioUnitTimePitch`).
- **Meet in the middle (further apart, up to 20% per song):** over its last two
  bars before the blend the outgoing song slows or speeds to a tempo between
  the two. The incoming song comes in at that tempo, both stay locked there
  while they overlap, and once the outgoing song has gone the incoming song
  eases back to its own speed over two bars. Ghostface Killah (100 BPM) into
  No Luck (145, counted at half time as 72.4) meets at 85.1: Ghostface slows by
  15%, No Luck starts 18% fast. Pairs that would need more than 20% from
  either song blend at their own speeds and the log says why.
- **Beat lock:** the incoming song starts on one of its own beats, scheduled
  sample-accurately to land on the outgoing song's next beat.
- **Bass swap:** the incoming song's bass is held back with a high-pass filter
  (`AVAudioUnitEQ`, up to 200 Hz), and at the handoff the two basslines swap,
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
7. Keep a cache of analysis per file, so a song is analysed once.
8. Test with varied genres and listen for lyric cuts, beat drift, clipping,
   clicks, dropped frames, sleep and wake, and output changes.

## Test plan

- Local tracks with silence, no silence, and very short duration
- Missing and unreadable selected files
- Repeated play, stop, remove, and playlist loops
- Sleep/wake and output-device changes during a transition
- Listen for clicks, clipping, a volume dip, late starts, or skipped material
