# Notice

Knob is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License version 3 or (at your option) any later version. See [LICENSE](LICENSE).

Knob is a modified work. It includes code from earlier free-software projects and from Apple sample code. Their copyright and license notices are kept unchanged at the top of the files they apply to, and in `driver/apple-sample-license.txt`, as their licenses require.

Modified by Simran Dhindsa, October 2026: new macOS app, renamed throughout, macOS-only build.

Knob comes with no warranty, to the extent permitted by law.

## Third party components shipped inside Knob.app

- **Open-Unmix UMX-HQ** vocal model (`app/Resources/KnobShift/`), Copyright (c) 2019 Inria, MIT License (`OpenUnmix-LICENSE.txt` beside it).
- **spotDL 4.6.0** (`Contents/Helpers/spotdl`, fetched at build time by `packaging/fetch-spotdl.sh`), Copyright (c) 2021 spotDL Developers, MIT License, https://github.com/spotDL/spotify-downloader. Its single executable bundles Python and its libraries, including yt-dlp (Unlicense), under their own licenses.
- **FFmpeg 4.4** static build (`Contents/Helpers/ffmpeg`, fetched the same way) from https://github.com/eugeneware/ffmpeg-static, GNU GPL version 3; its source is available from https://ffmpeg.org.
- **Deno 2.9.8** (`Contents/Helpers/deno`, fetched the same way), Copyright (c) 2018 the Deno authors, MIT License, https://github.com/denoland/deno. yt-dlp runs it to read YouTube's pages.
- **yt-dlp 2026.10.26** (`Contents/Resources/yt-dlp`, fetched the same way, Apple silicon part only), The Unlicense (public domain), https://github.com/yt-dlp/yt-dlp. KnobShift uses it to read YouTube links and download their audio. Its folder carries `_internal/THIRD_PARTY_LICENSES.txt` for the libraries inside it.
