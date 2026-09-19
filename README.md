![Banner](Images/banner.png?)

# EeveeSpotifyReincarnated

**Maintainers:** [jaydenjcpy](https://github.com/jaydenjcpy) & [faroukbmiled](https://github.com/faroukbmiled) & [Mod4](https://github.com/M0d-4) <br />
**Last Update:** `9/19/26` **Spotify Version:** `9.1.84`

This tweak makes Spotify think you have a Premium subscription, granting free listening, just like Spotilife, and provides some additional features like custom lyrics.

> [!NOTE]
> The original EeveeSpotify repository was disabled due to a [DMCA takedown](https://github.com/github/dmca/blob/master/2025/08/2025-08-14-spotify.md). This repository will not contain IPA packages in the repo itself.

## Custom Lyrics Support

**Spotify 9.1.56 and above** - Full custom lyrics functionality is available with the following providers:
- **Spicy Lyrics**
- **Musixmatch(Requires Musixmatch Token)**
- **PetitLyrics**
- **LRCLIB**
- **Genius**

> [!NOTE]
> All providers work now

## How to build an EeveeSpotify IPA using Github actions
> [!NOTE]
> If this your first time, complete following steps before starting:
>
> 1. Fork this repository using the fork button on the top right
> 2. On your forked repository, go to **Repository Settings** > **Actions**, enable **Read and Write** permissions.

<details>
  <summary>How to build the EeveeSpotify IPA</summary>
  <ol>
    <li>Click on <strong>Sync fork</strong>, and if your branch is out-of-date, click on <strong>Update branch</strong>.</li>
    <li>Navigate to the <strong>Actions tab</strong> in your forked repository and select <strong>Create IPA Packages</strong> if you're on desktop/widescreen. Tap on <strong>All Workflows</strong> and select <strong>Create IPA Packages</strong> if you're on mobile/portrait.</li>
    <li>Click the <strong>Run workflow</strong> button located on the right side.</li>
    <li>Prepare a decrypted .ipa file <em>(we cannot provide this due to legal reasons)</em>, then upload it to a file provider (e.g., filebin.net, filemail.com, or Dropbox is recommended). Paste the URL of the decrypted IPA file in the provided field.</li>
    <li><strong>NOTE:</strong> Make sure to provide a direct download link to the file, not a link to a webpage. Otherwise, the process will fail.</li>
    <li>Go to the releases page of the EeveeSpotify repository (<strong>NOT</strong> the fork). Hold and copy the link of the .deb file, which corresponds to your phone's architecture.</li>
    <li>Make sure all inputs are correct, then click <strong>Run workflow</strong> to start the process.</li>
    <li>Wait for the build to finish. You can download the EeveeSpotify IPA from the releases section of your forked repo. (If you can't find the releases section, go to your forked repo and add /releases to the URL, i.e., github.com/user/EeveeSpotifyReborn/releases.)</li>
  </ol>
</details>

## The History

In January 2024, Spotilife, the only tweak to get Spotify Premium, stopped working on new Spotify versions. [whoeevee](https://github.com/whoeevee) decompiled Spotilife, reverse-engineered Spotify, intercepted requests, etc., and created EeveeSpotify.

In August 2025, the original EeveeSpotify repository was disabled following a [DMCA takedown](https://github.com/github/dmca/blob/master/2025/08/2025-08-14-spotify.md) by Spotify.

In December 2025, whoeevee, the maintainer of the EeveeSpotify tweak at the time, announced he would be discontinuing the tweak because of the burden of keeping up with Spotify's constantly changing architectures. Soon after, [Skye (@Meeep1)](https://github.com/Meeep1) forked the original Eevee repo and continued developing the tweak to support newer Spotify versions, under the project name EeveeSpotifyRevivedPublic.

In March 2026, users of the latest EeveeSpotifyRevivedPublic release (v9.1.28) experienced constant logout issues and reported them to Skye, but EeveeSpotifyRevivedPublic hadn't released any newer updates. During March, I was constantly annoyed by the logout issue and decided to take matters into my own hands: I forked EeveeSpotifyRevivedPublic, fixed the logout issue, and that fork eventually became this repository — **EeveeSpotifyReincarnated** — continuing the legacy of EeveeSpotify for newer versions of Spotify.

Today, EeveeSpotifyReincarnated is maintained by [jaydenjcpy](https://github.com/jaydenjcpy), [faroukbmiled](https://github.com/faroukbmiled), and [Mod4](https://github.com/M0d-4), keeping the tweak alive as Spotify keeps changing.



## Restrictions

Please refrain from opening issues about the following features, as they are server-sided and will **NEVER** work:

- Very High audio quality
- Native playlist downloading (you can download podcast episodes though)
- Jam (hosting a Spotify Jam and joining it remotely requires Premium; only joining in-person works)
- AI DJ/Playlist
- Spotify Connect (When using Spotify Connect, the device will act as a remote control and stream directly to the connected device. This is a server-sided limitation and is beyond the control of EeveeSpotify, so it will behave as if you have a Free subscription while using this feature.)

## [Common Issues](https://github.com/jaydenjcpy/EeveeSpotifyReincarnated/blob/Master/common_issues.md)
Please check out the hyperlink above before opening an issue


## Lyrics Support

EeveeSpotify replaces Spotify monthly limited lyrics with one of the following four lyrics providers:

- Genius: Offers the best quality lyrics, provides the most songs, and updates lyrics the fastest. Does not and will never be time-synced.

- LRCLIB: The most open service, offering time-synced lyrics. However, it lacks lyrics for many songs.

- Musixmatch: The service Spotify uses. Provides time-synced lyrics for many songs, but you'll need a user token to use this source. To obtain the token, download Musixmatch from the App Store, sign up, then go to Settings > Get help > Copy debug info, and paste it into EeveeSpotify alert. You can also extract the token using MITM.

- PetitLyrics: Offers plenty of time-synced Japanese and some international lyrics.

If the tweak is unable to find a song or process the lyrics, you'll see a "Couldn't load the lyrics for this song" message. The lyrics might be wrong for some songs when using Genius due to how the tweak searches songs. While I've made it work in most cases, kindly refrain from opening issues about it.

## How It Works

EeveeSpotify intercepts Spotify requests to load user data, deserializes it, and modifies the parameters in real-time. This method works incredibly stable across supported Spotify versions.

The tweak also sets `trackRowsEnabled` to `true`, allowing you to see track rows and liked tracks on artist pages just like with Premium.

## Installation

For sideloaded IPAs, we recommend using **SideStore** or certificate-based signing tools like **Ksign** for best compatibility.

To open Spotify links in sideloaded app, use [OpenSpotifySafariExtension](https://github.com/BillyCurtis/OpenSpotifySafariExtension). Remember to activate it and allow access in Settings > Safari > Extensions.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening issues or pull requests.

Contributions are welcome — bug fixes, new features, and translations alike. If you'd like to translate the tweak into your language or improve an existing localization, see [TRANSLATING.md](TRANSLATING.md) for the workflow, the rules, and the `Tools/l10n_lint.py` checker that validates your translation before you open a PR.

## Credits
Thanks for all of the community's support, also, thanks to all the devs who worked along with us to revive this project Go check the other dev's out:

[jaydenjcpy](https://github.com/jaydenjcpy)

[Ryuk](https://github.com/faroukbmiled) 

[Mod4](https://github.com/M0d-4)

[estrogencat](https://github.com/estrogencat)

[Skye](https://github.com/Meeep1) 

[whoeevee](https://github.com/whoeevee) 

[Spikerko](https://github.com/Spikerko)

- This project is a fork of [Meeep1/EeveeSpotifyRevivedPublic](https://github.com/Meeep1/EeveeSpotifyRevivedPublic).

## Disclaimer

This project is an **independent modification (tweak)** for the Spotify app. We are **not affiliated, associated, authorized, endorsed by, or in any way officially connected with Spotify**, or any of its subsidiaries or affiliates. 

This tweak is created solely for **personal and educational purposes**. Use it at your own risk.

**We do not take any responsibility for any issues, damages, or consequences** resulting from the use or misuse of this tweak. If something breaks, it's not our problem.

## Star History

<a href="https://www.star-history.com/?repos=SideloadLabs%2FEeveeSpotifyReincarnated&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=SideloadLabs/EeveeSpotifyReincarnated&type=date&theme=dark&legend=top-left&sealed_token=C1hKWTv3UNdLAgsZjjCL7Rthp6YSGB4Mm9kIalnH1lgZXZnYVL09WbBt57E-FFzQXg8gZyFOW356S5XMTWmvQdIuEihF66WxqGuJTejmAdJx5XJHxC2l3A" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=SideloadLabs/EeveeSpotifyReincarnated&type=date&legend=top-left&sealed_token=C1hKWTv3UNdLAgsZjjCL7Rthp6YSGB4Mm9kIalnH1lgZXZnYVL09WbBt57E-FFzQXg8gZyFOW356S5XMTWmvQdIuEihF66WxqGuJTejmAdJx5XJHxC2l3A" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=SideloadLabs/EeveeSpotifyReincarnated&type=date&legend=top-left&sealed_token=C1hKWTv3UNdLAgsZjjCL7Rthp6YSGB4Mm9kIalnH1lgZXZnYVL09WbBt57E-FFzQXg8gZyFOW356S5XMTWmvQdIuEihF66WxqGuJTejmAdJx5XJHxC2l3A" />
 </picture>
</a>
