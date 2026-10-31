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

## Design

KnobShift analyses a chosen local file away from the audio callback, identifies
trailing silence, plans a conservative transition, then preloads the next local
track on a second `AVAudioPlayerNode`. The blend is equal-power to avoid an
obvious volume dip. If analysis is not confident, KnobShift uses ordinary
sequential playback. It does not use a fixed-duration fallback, because that
could cut a vocal or the final phrase.

The first version only uses duration and trailing silence. A song-aware mix
requires tempo, key, beat-grid, phrase, vocal-activity and timed-lyric analysis,
all confidence-gated before adding beat-matched or time-stretched transitions.
KnobShift must never claim to detect a last lyric from plain audio, or cut a
lyric or verse based on a low-confidence guess.

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
- `READY`: shows the planned outgoing cue, incoming cue and confidence.
- `KNOBMIX`: shows live progress from the planned stem handoff to completion.
- `PRESERVING ENDING`: no confident lyric or phrase boundary was available,
  so the current track will finish naturally.

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

1. Add persistent analysis records and a job queue for local files.
2. Add beat, bar, tempo, key and loudness analysis with confidence tests.
3. Add an on-device vocal/accompaniment separator and cache the stems.
4. Detect vocal activity boundaries and optional timed-lyric boundaries.
5. Add phrase-aware cue selection, four-stem host-time scheduling and bounded
   time stretching.
6. Add the honest `ANALYZING`, `READY`, `KNOBMIX` and `PRESERVING ENDING` UI.
7. Test with varied genres and manually listen for lyric cuts, beat drift,
   clipping, clicks, dropped frames, sleep/wake and output changes.

## Test plan

- Local tracks with silence, no silence, and very short duration
- Missing and unreadable selected files
- Repeated play, stop, remove, and playlist loops
- Sleep/wake and output-device changes during a transition
- Listen for clicks, clipping, a volume dip, late starts, or skipped material
