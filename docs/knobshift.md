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
| Tempo and beat grid | Onset autocorrelation | Shown in the log only for now (not yet accurate enough to beat-match) |

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

1. The outgoing song keeps its voice: the blend starts where its last vocal
   line ends. With no vocals, it starts where the song's fade starts.
2. The blend runs until the outgoing song's last audible moment, so its length
   is simply the music left after the voice. Trailing silence is skipped.
3. The incoming song starts after its own silent lead-in and rises under the
   outgoing music. Its voice enters at its own first line, over the outgoing
   music only, so two vocals never overlap.
4. With no vocal end and no fade (for example a song sung to the very end),
   the songs meet cleanly at the audible end: `PRESERVING ENDING`.
5. Seeking past the planned start still blends over whatever music is left.

Ghostface Killah into Shaukeen therefore blends from 1:59.25 to 2:14.68
(15.43s), 18.4 seconds before the end of the file, and Shaukeen's voice
arrives at 68% of the blend.

The blend is an equal-power curve, updated about 20 times a second. Each update
waits for its own deadline from the blend start, so the handoff lands exactly
on the planned end. After the handoff the incoming song's clock carries on from
where its deck really is, so the next plan is on time.

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
4. Next: accurate tempo, beats and downbeats, then beat-aligned starts and a
   bounded tempo ramp (`AVAudioUnitTimePitch`) when two songs are close.
5. Next: a bass swap during the blend (`AVAudioUnitEQ`), so two basslines never
   stack.
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
