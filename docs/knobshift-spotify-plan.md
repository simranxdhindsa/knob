# KnobShift and Spotify playlists: plan

Status: built 2026-11-02, spotDL bundled (the user's choice). The approved build plan differs from sections 2 and 9 here: spotDL ships inside Knob.app, removed playlists are restorable for 30 days, and Spotify login is included. Remaining before release: fetch and pin the helpers, then the live tests in section 10.

## 1. What the user gets

1. In KnobShift, the user clicks **ADD FROM SPOTIFY** and pastes a Spotify playlist,
   album or song link.
2. The songs appear in the queue straight away, **in the same order as on Spotify**,
   each with its cover art, title and artists exactly as Spotify shows them.
3. Each song has a progress ring that moves through three states:
   - **Finding:** the song is being matched.
   - **Downloading.**
   - **Preparing:** KnobShift's usual analysis.

   A song that fails shows a plain reason and a Retry button.
4. Songs can be played and mixed as soon as they are ready. The rest keep arriving
   in the background.
5. **Update playlist** fetches any songs added on Spotify since the last time.
6. Shuffle and drag to reorder work exactly as they do now. Turning shuffle off
   returns to the Spotify order, or to the user's own order once they have dragged
   songs.
7. Everything plays through KnobShift's normal mixing: beat lock, vocal separation,
   exit styles and KnobMix Now.

## 2. How it works, and the boundary

spotDL (MIT, `spotDL/spotify-downloader`) reads the playlist's song list from Spotify. It
then **finds each song on YouTube and downloads the audio from there**. Spotify's own
audio is never touched. Spotify's player is DRM protected and gives no access to its
audio, which is why KnobShift cannot play Spotify directly.

Downloading copyrighted songs from YouTube breaks YouTube's and Spotify's terms. In many
countries it is not legal without the rights holder's permission. So:

- **Knob does not bundle, install or download spotDL.** The user installs it themselves
  (`pipx install spotdl` or `brew install spotdl`). KnobShift only looks for it on the
  Mac and runs it. Without it, the Spotify button does not appear.
- **The `spotify-downloader/` checkout never enters Knob's repository**, so it is added to
  `.gitignore`. It is also never copied into `Knob.app` or the installer.
- The first use shows a one time notice: songs come from YouTube, and the user is
  responsible for having the right to keep them. It has a single "I understand" button,
  confirmed inline in the window.
- Nothing about this feature appears in the README or release notes unless the user
  decides otherwise.

## 3. Requirements

| Need | Version | Checked by |
| --- | --- | --- |
| spotDL | 4.6 or newer | `spotdl --version` |
| Python | 3.11 to 3.15 | comes with spotDL |
| FFmpeg | any recent | `ffmpeg -version` (`spotdl --download-ffmpeg` can fetch it) |
| Internet | | first request |
| Disk space | about 3 to 5 MB per song | free space check before starting |
| Spotify login | only for private playlists and Liked Songs (`--user-auth`) | asked only when needed |

KnobShift looks for `spotdl` in Homebrew, pipx and the user's PATH. It shows one plain
sentence for each thing that is missing, with the command to install it.

## 4. The download, exactly

One folder per playlist: `~/Music/KnobShift/Spotify/<playlist name>/`.

```
spotdl sync "<link>" \
  --save-file "<folder>/playlist.spotdl" \
  --format m4a --bitrate disable \
  --output "{list-position} {title} - {artists}.{output-ext}" \
  --m3u "playlist.m3u8" \
  --threads 4 --print-errors
```

Why these choices:

- **m4a with `--bitrate disable`:** YouTube's own audio is kept without converting it a
  second time. macOS plays m4a natively, and it is normally 44.1 kHz, which KnobShift's
  vocal separation needs. Opus is avoided because macOS does not play it reliably.
- **`sync` with a save file:** running it again later adds new songs, and removes songs
  the user deleted on Spotify unless `--sync-without-deleting` is chosen.
- **`--m3u`:** writes the playlist in Spotify's order, and KnobShift reads that order back.
- **`{list-position}` in the file name:** keeps the order visible in Finder too.

spotDL runs as a separate process, off the main thread. KnobShift reads its output line
by line to move each song's ring along. Quitting Knob or removing the playlist stops it
cleanly.

## 5. Order and arranging

1. **Spotify order is the starting order.** KnobShift reads `playlist.m3u8` (or the
   positions in `playlist.spotdl`) and queues the songs in that order, including songs
   still downloading.
2. **Shuffle** works as today. It shows the shuffled order in the queue, and turning it
   off returns to the order below.
3. **Drag to reorder** changes the user's own order for that playlist. It is saved, so it
   survives relaunching.
4. **Update playlist** puts new Spotify songs where they sit on Spotify. When the user
   has their own order, new songs go at the end.
5. **Duplicates:** a song already in the queue, with the same file or the same Spotify
   ID, is not added twice.
6. **Several playlists:** each is a block in the queue. Mixing runs across them like any
   other songs.

## 6. Titles, artists and cover art "like Spotify"

spotDL writes Spotify's data into each file's tags. These include the title, every
artist, album, album artist, track number, year, cover art, genre and Spotify ID.
KnobShift changes how it names songs:

- **Today:** the name and artist come from the file name, `Title - Artist`.
- **After:** they are read from the file's tags (`AVAsset` metadata: title, artist, album,
  artwork), falling back to the file name. Multiple artists show joined like Spotify:
  "Karan Aujla, Ikky". Featured artists stay in the title as Spotify writes them, for
  example "Jee Karuga (feat. Sargi Maan)".
- Cover art comes from the tags. That already works through `KnobShiftArtwork`.
- Songs the user adds from Finder benefit too, whenever their files have tags.

## 7. How each song is processed

1. **Downloaded** by spotDL into the playlist folder.
2. **Checked:** the file exists, plays, is longer than 30 seconds, and is not silent. A
   song that fails this check gets Retry.
3. **Analysed** by the existing pipeline: tempo, beat grid, voice start and end, line
   ends, drum entry, breaks and fade. The result is cached, so the next launch is
   instant.
4. **Mixed** like any song. Vocal separation runs only for the stretch of a mix, as now.

Matching mistakes are possible, because spotDL picks a YouTube video by title and
length. If a song's length differs from Spotify's by more than 7 seconds, KnobShift
marks it "May be a different version" in the log. The user can remove it or Retry.

## 8. Errors, in plain words (no dashes in any of it)

| Situation | Message |
| --- | --- |
| spotDL not installed | "Install spotDL to add Spotify playlists: brew install spotdl" |
| FFmpeg missing | "spotDL needs FFmpeg: brew install ffmpeg" |
| Not a Spotify link | "Paste a Spotify playlist, album or song link." |
| Private playlist | "This playlist is private. Log in to Spotify to add it." |
| No internet | "No internet connection. Your songs will continue when you are back online." |
| One song not found | the song's row shows "Not found" with Retry |
| Disk full | "Not enough space for this playlist." |
| Rate limited | "Spotify is busy. Trying again in a minute." |

## 9. Delivery phases (commit after each)

1. **Housekeeping.** Add `spotify-downloader/` to `.gitignore`. Read titles, artists and
   album from tags. Add this plan to the docs.
2. **Detection.** Find spotDL and FFmpeg and report what is missing. Add the
   `--knobshift-spotify-check` command line check.
3. **Import.** Add the link field, run `spotdl save` for the song list only, and show
   the queue rows in Spotify order immediately.
4. **Download.** Run `spotdl sync` into the playlist folder. Rings show Finding,
   Downloading and Preparing. Retry and stop work.
5. **Order and update.** Read the m3u order, save the user's own order, Update playlist,
   and skip duplicates.
6. **Polish.** The first use notice, error messages, snapshots in both themes, and the
   docs.

## 10. Tests

**Automatic checks** (command line, like the existing KnobShift checks):

- `--knobshift-spotify-check LINK`:
  - runs `spotdl save` only (no download);
  - checks the song count, the order, and that every song has a title and artists;
  - prints the list.
- **Tag reading:** on spotDL style files with two artists, a featured artist,
  non-English titles (ਖੀਰ ਤੇ ਵੈਰ), and a missing tag (falls back to the file name).
- **m3u order:** a file with positions 1 to 12 queues in that exact order, including
  when songs finish downloading out of order.
- **Duplicates:** importing the same playlist twice adds nothing.
- **Failure paths:**
  - spotDL missing (PATH emptied);
  - a bad link;
  - airplane mode;
  - a private playlist;
  - a song spotDL cannot find.

  Each should show the right sentence and not crash.
- **Stop and quit:** removing the playlist mid download, or quitting Knob, leaves no
  spotDL process running.

**Real use tests** (as in docs/uat-testing.md):

- **Small playlist.** Import a 3 song public playlist and check that:
  - the order matches Spotify;
  - the covers and artists match;
  - the first song plays before the others finish;
  - each mix sounds right.
- **Large playlist.** Import a 50 song playlist and check that:
  - the queue appears at once;
  - memory stays steady;
  - playback never stutters while downloading.
- **Update.** Add a song on Spotify, press Update playlist, and check it appears in the
  right place.
- **Order.** Shuffle, drag a song, relaunch Knob, and check the order survives.
- **Themes.** Take light and dark snapshots of every state:
  - empty;
  - importing;
  - partly ready;
  - failed song;
  - spotDL missing.

## 11. Decisions for the user

1. Keep spotDL user installed (recommended) or bundle it (not recommended, see section 2).
2. Download folder: `~/Music/KnobShift/Spotify` (proposed) or somewhere else.
3. When a playlist is removed from the queue, keep its files (proposed) or delete them.
4. Support private playlists and Liked Songs (needs Spotify login) now or later.
5. Use `--sync-without-deleting` by default (proposed: yes, so nothing disappears
   unexpectedly).
