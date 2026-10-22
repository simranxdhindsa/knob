# Precision controls and startup recovery

Hold **Shift** while dragging a volume/effect knob or an EQ fader to move at one-tenth speed. Shift can be pressed or released during the same drag without jumping the value. Faders follow movement from the point where you grabbed them.

Click a numeric value to type an exact setting:

- Volume: 0 to 100 percent.
- Effects: 0 to 10.
- Equalizer: -12 to +12 dB, above each frequency's fader.

Press Enter or leave the field to apply. Escape cancels. Invalid, non-finite and out-of-range input leaves the previous setting intact; the field highlights and its tooltip explains the allowed range. Simply focusing and leaving a field does not round the stored setting. Decimal separators follow the Mac's locale. Double-click an effect knob or EQ fader to reset it to zero.

## When startup fails

Knob gives specific guidance for missing audio access, an unavailable output, audio that fails to start flowing, and failure to take over the output. A failed startup is stopped before the recovery controls appear.

- **Retry** checks the available devices again and uses the Mac's current physical output. Choose a different output in macOS Sound settings first if needed.
- **Sound Settings** opens output settings. For an audio permission failure, **Microphone Settings** opens the relevant privacy settings instead. Knob uses this permission to read its virtual audio device.
- **Open Log** opens the engine log for troubleshooting.

Diagnosis reads only the log bytes written after the current launch started, so yesterday's errors do not describe today's attempt. Unknown errors keep a generic explanation with access to the log. A timeout message identifies the symptom; it does not assume a particular hardware or permission fault.

## Verification

Run `sh tests/precision-startup-build.sh` for modifier transitions, numeric validation, and error classification. Optionally pass a captured missing-output engine error file to check classification against a real failure.

Use the app's `--snapshot DIR` mode for light/dark panels and each startup recovery message. These are rendered previews, not evidence of successful live interaction or audio playback.

Live checks: Shift-drag each type of control; type a value and press Enter; cancel with Escape; enter an invalid value; change Shift mid-drag; retry after reconnecting an output; verify sound and the volume level remain correct. Startup failures must be reproduced against the real engine before claiming their underlying cause is fixed.
