# Changelog

What's new in each version of Knob, written for people who use it: new features first, then
fixes. Knob updates itself, so installed copies get every version below on their own.

## 3.1

### New features

- After a song with no singing, the echo and reverb clear away just before the next singer starts
- When the beats lock, both songs' beats play together until the old singer's last words

### Fixes

- A song whose voice ends a couple of seconds before it does no longer squeezes the whole mix into its last 2 seconds; it leaves at an earlier break instead
- The new singer no longer keeps a reverb after an echo out mix

## 3.0

Knob 3.0 brings YouTube to KnobShift: videos, playlists and YouTube Music albums join the queue
and mix into each other like every other song.

### New features

- Add music from YouTube: paste a video, playlist or YouTube Music album link from ADD MUSIC, tick the songs you want, and they download in the background and mix like every other song
- Sign in with Google to see your own YouTube in KnobShift: your liked music, your playlists, new music from channels you follow and what is popular in your country, with thumbnails
- Music only is on by default, so vlogs, Shorts and long mixes stay out of your lists; turn it off to see every video
- A YouTube video that is gone, private or blocked in your country is replaced by the closest match found by its name
- KnobMix mixes are about 8 seconds and never longer than 10, so a long outro is skipped instead of dragging on
- Two singers are never heard together: the old voice finishes its line and fades into a hall before the new voice comes in
- The long tape slowdown is back on every mix where the beats lock, and both songs slow down together so their beats stay in time
- A song that sings to its very end is cut at a break or at the end of a line, and its voice slows like tape into a hall while its music fades in time with the new beats
- Songs up to 20% apart in tempo now lock their beats by meeting in the middle, and the strong beats of both songs always land together

### Fixes

- Pressing ADD in the song picker closes the window, and the songs keep downloading in the background
- A song that keeps singing through its fade no longer mixes in its last seconds

## 2.0

Knob 2.0 brings KnobShift: a music player inside Knob that mixes every song into the next one
like a DJ, worked out fresh for each pair of songs.

### New features

- Select songs in the queue like in Music (click, Shift click, Command click, Command A) and remove them together with Delete, REMOVE or a right click, or empty the whole queue with the bin; double click plays a song
- Paste any Spotify playlist, album or song link and its songs download with no Spotify login or key, for everyone (playlists up to 100 songs; longer ones read in full when you are logged in)
- Knobs feel like a stepped studio pot on a trackpad: a light tick every 2.5%, a firmer click on each printed mark and the firmest at the ends
- KnobShift plays the songs on your Mac and mixes each one into the next, the way Apple Music's AutoMix does
- It listens to every song first, finding where the voice starts and ends, where the drums come in and where the music breaks, so two singers never clash
- The old singer finishes the line while the new song's beats come in underneath; the new verse lands just as the old song leaves
- On device AI separates the next song's voice from its music, so only its beats come in until its turn
- Songs close in tempo glide to the same speed with the beats locked together; the bass swaps over on a bar line
- Every pair of songs gets its own transition: Underwater fade, Lofi dip, Tape slowdown, Echo out or Reverb wash
- Transition effects build to a gentle peak where the old verse ends and fall away, two bars each way to the song's own beat, and breathe on the beat
- The old singer's voice leaves before the new singer comes in, so two voices are never heard together, and the new voice arrives through a reverb that clears
- KnobMix Now mixes into the next song sooner, waiting for the next phrase so the mix still lands on the beat
- Shuffle shows the new order in the queue, and songs can be dragged into any order
- Add your Spotify playlists, albums, songs and Liked Songs: tick the songs you want, and they download in the background with live progress, in Spotify's order
- Use your own free Spotify key (with Spotify Premium), so Spotify imports never wait on the shared daily limit
- Songs added in bulk appear at once and are prepared in the background, ready instantly next time
- Songs without cover art get a cover of their own, and during a mix the cover fades into the next song's
- The KnobShift tab in Knob's panel is a mini player with progress, previous, play and next, plus a button that opens the full player
- KnobShift stays smooth with thousands of songs in the queue

### Fixes

- Updating to this version works again: the previous update stopped with an Update Error on every Mac
- Speakers that were muted before Knob turned on no longer stay silent behind it: the mute moves onto Knob, where the volume knob shows it
- Knob's volume follows the same curve as your Mac's speakers, so 10% is as quiet as macOS's 10% instead of much louder; Knob updates its audio device with one password prompt the next time you turn it on
- The volume no longer gets stuck on Fixed after turning Knob on
- Tape slowdown eases the old song about 10% slower with its natural pitch, smoothly in and out, instead of a heavy pitch drop
- Spotify songs download again: Knob now includes Deno, which YouTube downloads need
- When YouTube pauses downloads from your Mac, the songs say YouTube paused and Knob tells you to try again in a few hours, instead of Not found
- Clicking the Dock icon brings back a minimised KnobShift window
- The ••• menu opens again on a click, and About Knob now shows inside the panel with a Back button
- ADD MUSIC opens its choices on a click again, now with the Apple logo for songs on your Mac and the Spotify mark for Spotify
- The old song's last word is no longer sung twice during a mix
- Transition effects ease in gently, start a second after the new song arrives and stay at half strength or less, so the old song never lurches or drags on
- Mixes are shorter and fit each song: six bars of its beat, between 8 and 14 seconds
- Spotify login, reading and downloads start in about 2 seconds instead of 20
- When Spotify pauses requests for the day, Knob says so and shows when to try again, instead of waiting silently
- The progress bar in the panel's mini player can be dragged to move through the song
- Spotify login finishes as soon as you agree in the browser and brings Knob back to the front
- A song is never added while its download is still being written, and stopping a download leaves nothing running in the background
- The KnobShift window no longer slows down while a song plays with a long queue
- The Add from Spotify window no longer bounces

## 0.1

The first versions of Knob: a volume control that works on HDMI monitors and other outputs
with no volume of their own, plus presets, effects and a 10 band equalizer, all in the menu
bar. Knob updates itself, so you never need to download it again.
