On this page, you'll find a detailed FAQ covering various topics related to EeveeSpotify, answers to common questions, and more.

# Versions and Support

EeveeSpotify currently supports Spotify version **9.1.60** (the latest version compatible with iOS 16.1+). 

If you are jailbroken, install the latest .deb from the [releases page](https://github.com/jaydenjcpy/EeveeSpotifyReincarnated/releases), along with the latest Spotify from the App Store. After installation, open the EeveeSpotify settings (accessible from your Spotify profile settings) and reset data so it will properly patch Premium features.

For non-jailbroken devices, use the patched IPA files available in the releases. You can install these using:
- **TrollStore** (recommended for iOS 14-16.6.1, 17.0)
- **Sideloadly** (7-day signing)
- **AltStore** (7-day signing)
- **Signing services** with paid certificates

EeveeSpotify only supports iOS and iPadOS and is not planned to be supported on other platforms. You can sideload the iPadOS version on an Apple Silicon Mac, though.

New versions are released when compatible Spotify updates become available. Check the [releases page](https://github.com/jaydenjcpy/EeveeSpotifyReincarnated/releases) for the latest builds, or join the [Telegram channel](https://t.me/compiledipas) for IPA downloads and updates.

## CarPlay, Siri and Dynamic Island/Lockscreen

To use CarPlay, you need to either install the tweak on a jailbroken device, use TrollStore, or have a paid certificate with a CarPlay entitlement.

To use Siri, you need to either install the tweak on a jailbroken device, use TrollStore, or have a paid certificate with a Siri entitlement.

If you're using a paid certificate, to navigate to a song from the lock screen, control center, or Dynamic Island, and to use Spatial Audio or Siri, change the app and bundle identifiers to match your provisioning profile.

# Feature Requests

EeveeSpotify does not accept free feature requests. If you need something, feel free to implement it yourself, or submit a pull request if you think others may find it useful. If you're willing to pay for a feature, open an issue to discuss further opportunities.

Note that many Premium features are server-sided and will never work without a Premium subscription (e.g., very high quality audio, offline downloads on mobile data).

# Troubleshooting & Issues

## Accessing Settings

EeveeSpotify settings can be accessed from within the Spotify app:
1. Open Spotify
2. Tap your profile icon (top right)
3. Scroll down to find "EeveeSpotify" in the settings list
4. Tap to access all tweak settings

## Something Went Wrong

If you're unable to sign in and see an error, try these solutions:
1. Clear Spotify app data
2. Reinstall the app
3. Check your internet connection
4. If using a VPN, try disconnecting/reconnecting

## Lyrics Not Showing Up

If you see the "Couldn't load the lyrics for this song" message and no lyrics load:
1. Open EeveeSpotify settings
2. Go to the Lyrics section
3. Try changing the lyrics source
4. If that doesn't help, go to the Patching section and enable "Overwrite Configuration"
5. Reset data within the EeveeSpotify settings

## Premium Not Working

If all tracks are skipped, a song stops as soon as you play it, songs play in a random order, you see the "You discovered a Premium feature" popup when trying to play a song, or you encounter other restrictions:

**Region Issue**: You can only use Spotify abroad for 14 days. The solution:
1. Connect to a VPN server in any country
2. Change your region at accounts.spotify.com
3. Sign out of Spotify
4. Log back into Spotify with the VPN still enabled

This issue is solely related to your account region. Do not enable "Overwrite Configuration" unless you've also tried the region fix. If your region is already correct, still try connecting to a VPN, changing your region to somewhere else, signing out, and then logging back into the Spotify app.

## Downloading

Downloading is not, and will never be, implemented in EeveeSpotify. While it is technically possible to intercept the audio stream or use third-party APIs, downloading simply will not be included in EeveeSpotify.

However, opening a pull request is always welcome. If you are a developer and manage to implement downloading that works flawlessly and natively (without third-party menus, UI elements, etc.), you will be considered a true legend and mentioned at the top of the README and contributors screen.

You may see a "Download local playlist" option. This is specifically for downloading playlists that contain only local tracks from your PC within a Wi-Fi network.

Any issues regarding downloading of any kind will be closed.

## Spotify Connect

When using Spotify Connect, you may encounter ads, be unable to skip tracks, and experience other limitations. The music is streamed directly from Spotify's cloud to the connected device, while your phone acts only as a remote control. This is beyond EeveeSpotify's control. If you want to avoid these limitations, use Bluetooth instead.

## Ads on Homescreen

You may see ads on the home screen. This is a known issue and will not be fixed, as it is a real challenge to patch these server-sided ads.

## Ads in Podcasts

You may see ads in podcasts. This is Spotify's default behavior, even on Premium accounts. This won't be fixed - just skip the ads manually.

