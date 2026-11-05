# Changelog

What's new in each version of Knob, written for people who use it: new features first, then
fixes. Knob updates itself, so installed copies get every version below on their own.

## 4.1

Knob 4.1 keeps the orange microphone dot away, makes low volumes easier to hear, and adds a Playlists view.

### New features

- A new Playlists view from the queue: open any playlist, pick songs or add them all, and imported songs wait there until you add them
- Knob no longer uses your Mac's audio input to carry sound, so the orange microphone dot stays off while Knob is on. Turning Knob on asks you to install a small update to its audio device, once
- Songs Knob could not find now show YouTube matches to pick from, or you can paste a link, and Retry tries them all at once
- All Songs in Playlists shows every playlist's songs in one list, and one tap shuffles them all and starts playing
- Low volumes in Knob are louder, so small steps are easier to hear, and 100% stays exactly as loud as before

### Fixes

- Check for Updates shows its result in the panel instead of a window, so the panel stays open
- Pausing during a mix now freezes both songs, and Play carries the same mix on from that moment
- Shuffle stays on after you restart Knob, in the same order, and turning it off still gives your own order
- The KnobShift window comes back where you left it, at the size you left it
- KnobShift on your Mac spreads the real colours of the cover across the whole window, and black and white covers no longer turn pink
- On iPhone in light mode, the background keeps the cover's own colours instead of turning pale yellow or pink
- New headphones and speakers show in Knob as soon as you connect them, with no need to restart it

## 4.0

Knob 4.0 is the biggest update yet. Knob comes to iPhone, and KnobMix now works the way a DJ does:
it starts at the old song's last hook and brings the next singer in over the old one.

### New features

- Knob comes to iPhone: the KnobShift player and Knob's sound controls, with the song's cover and colours filling the screen in light and dark (for now it is built from Knob's source, it is not on the App Store)
- Add Spotify and YouTube songs from your iPhone, and sync your playlists from your Mac over your home network
- The iPhone shows live whether your Mac can be seen, and Sync turns on by itself the moment your Mac appears
- KnobMix starts at the old song's last hook, wherever it falls, instead of waiting for the very end
- The old voice is pressed down into a hall while the next singer comes in over it, about half way to the old singer's last words
- The next song starts just before its first verse instead of from its intro, and arrives through reverb and a slight slow start that clear away
- Mix length now follows each pair of songs and their tempo
- After a song with no singing, the echo and reverb clear away just before the next singer starts
- When the beats lock, both songs' beats play together until the old singer's last words
- KnobShift shows on your lock screen and in Apple's media controls, and Next does a KnobMix
- The song you played last comes back in the player, ready to play from where you stopped
- Every preset has an icon, and presets you save get their own
- If YouTube blocks downloads, you can choose to continue with your own YouTube sign in from your browser; it is off unless you turn it on
- Knob prepares two songs at a time on your Mac, so big playlists are ready sooner
- The KnobShift player on your Mac has the iPhone's modern look: the song's cover and colours fill the window, and the orange Play dial lights its marks as the song plays; turn its ring to move through the song
- The sound visualiser moves smoothly, and shows under the effects only, so the equalizer stays clear
- Your playlists in the queue now hide behind a button, so the queue shows your songs first

### Fixes

- A song still downloading on your Mac is never copied to your iPhone half finished
- Sync always talks to the Knob with your full music, and shows your Mac's latest playlists each time you open it
- A song your Mac could not download now says why on your iPhone, instead of showing Downloading on your Mac forever
- Songs keep coming to your iPhone for as long as your Mac is downloading them, and carry on when you come back to the app
- The refresh button on a playlist opens the song picker again, so songs you added on Spotify or YouTube can be downloaded
- Removing a playlist takes all its songs with it, instead of leaving rows that say Could not read this file
- Recently removed playlists say plainly how many days you can still restore them
- A song whose voice ends a couple of seconds before it does no longer squeezes the whole mix into its last 2 seconds; it leaves at an earlier break instead
- The new singer no longer keeps a reverb after an echo out mix
- Songs without a clear last chorus now mix over about 12 seconds, so the next song no longer arrives all at once
- Fixed a mix where the next song played only its beats for a while: its voice now always starts on time
- Fixed vocals being heard twice during a mix
- After an iPhone update, your songs are ready at once instead of being prepared again one by one
- Songs Spotify or YouTube could not find are no longer searched for again every time Knob starts; Retry still tries them
- Mix effects always rise from nothing instead of starting at full strength
- KnobMix now finds a song's last chorus even when the music does not break before it
- A song on iPhone is no longer treated as an instrumental when its voice could not be read
- A song whose voice could not be read is read again by itself, and if that fails too its row offers Retry
- Song covers show in grey while a song is prepared, then come up to full colour when it is ready
- When YouTube pauses a long download, the songs now say YouTube paused instead of Not found
- The orange glow stays inside the analyser screen and no longer blows out

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
