# Teddy

Teddy is TED's native Flutter/Dart client, using retained Plezy widgets, settings styles and native playback. Its entry point is `lib/teddy_main.dart`. It connects directly to TED; unused upstream multi-server applications/integrations were removed. [The product contract](../ted/PROJECT.md) owns behavior, [the handoff](../ted/IMPLEMENTATION.md) owns implementation status and verification, and [the server README](../ted/README.md) owns installation.

## Build and run

From the Teddy folder:

```sh
devbox install
devbox run -- bash scripts/check-teddy.sh
devbox run -- bash scripts/build-teddy-macos.sh
```

The check script selects the child Apple environment where available, resolves the committed Dart lockfile, generates Freezed/JSON/Drift outputs, analyzes code and runs the curated native suite. For the complete retained Flutter suite, run `flutter test` inside this folder through Devbox with the same Apple environment. Generated model files are ignored; do not remove separately committed translations/native protocol outputs blindly.

The Mac release needs full Xcode in `/Applications/Xcode.app`, completed first-launch components/license and the macOS SDK. This machine uses Xcode 27.0/macOS 27.0 SDK; Devbox supplies Flutter 3.47.0/Dart 3.13.0, CocoaPods 1.16.2/Ruby and GNU rsync 3.4.4. To select another full installation use `TED_XCODE_DIR` pointing to Contents/Developer. The helper clears Nix compiler/linker overrides only for the child; it does not change global xcode-select or the Nix store.

The build script uses a fresh `.devbox/teddy-macos-builds` copy, disables upstream update checks/Sentry, verifies signatures and publishes `build/releases/<unique-id>/Teddy.app`. The latest actual path is recorded in `.devbox/teddy-macos-latest.txt`. Never rebuild or replace a running app bundle. After quitting the old instance, open the new one yourself:

```sh
open "$(cat .devbox/teddy-macos-latest.txt)"
```

Bundle ID is `com.entertainmentdistrict.teddy`; private builds retain ad-hoc signing. Notarization/store publication is not configured. Universal ARM 64/x86_64 packaging is build evidence, not Intel runtime verification. Windows, Linux, Android mobile/TV remain required platform checks; iOS is desirable later. Linux secure storage requires libsecret and an unlocked keyring. Other targets are not accepted merely because upstream supports them.

Android's app and library modules, including Flutter's JNI plugin, use NDK `29.0.14206865` and CMake `4.1.2`, matching the release workflow's SDK installation (platform 36, build tools 36.1.0). The root library `finalizeDsl` policy applies these pins after plug-in defaults, so JNI cannot request Flutter's older NDK during Gradle configuration. Install the same versions for a local Android build. This workstation has no configured Android SDK; the Gradle API compile check does not establish a successful APK build. See [Android's module NDK configuration](https://developer.android.com/studio/projects/install-ndk#configure-specific-versions-of-the-ndk-in-your-project).

Java 21 JDK (including `java`, `javac`, and `keytool`) is installed through this project's Devbox. After dependency changes, exit any old Devbox shell and enter `devbox shell` again, or use `devbox run -- keytool -help`. This avoids macOS's `/usr/bin/java` and `/usr/bin/keytool` launchers, which require a separately registered system runtime. No system Java installation is needed for signing-key generation.

## Profiles and authentication

Set a profile picture in TED's web **Your account** panel using the pencil at the bottom left of the icon (JPEG, PNG, WebP or GIF, at most 20 MiB/40 megapixels; first frame, center crop). Teddy displays the saved picture in the chooser and sidebar, falling back to initials. Select a profile once to fetch its picture; the chooser reads local copies before sign-in and offline. The active profile checks on entry/Reload and roughly once a minute. Other saved profiles do not authenticate in the background. Switching retains pictures; Sign Out removes only that profile's local copy.

Every launch starts at **Who's watching?**, with circular profiles and a plus circle. Choose a profile before authentication/sync/download work starts, then the configured Startup Section opens. Switch Profile/Add profile retains the same read-only server address; Change server permits a new origin and preserves earlier servers' profiles. Only one context authenticates at once.

Switching pauses/fences downloads and retains copies/reports/caches. Explicit Sign Out removes that profile's owned device data and credentials, including pending reports, without deleting server history, another profile or the installation ID. Expired credentials do not automatically delete downloads or deny offline local playback. A changed localhost/LAN URL is a different scope; the owner's preserved tunnel is documented in the home-server record.

Credentials live in one verified OS-backed bundle using flutter_secure_storage10.3.4. Refresh is serialized, single-use and family-preserving. Uncertain rotation/persistence requires fresh login. Request keychain access retries denied OS access; permission success must not hide a different write/verification error. Do not reset secure storage as a generic fix.

## Browsing and navigation

Sidebar: Search, Home, Movies, Series, Watch List, Ratings, Downloads; footer Reload, Settings, Account. Enter/click activates destinations; hover/focus alone does not. Keyboard focus is a white outline independent of current-page selection. The sidebar collapses to equal-width desktop/TV icons unless hovered, focused or configured always-open.

Home persists Continue Watching, New Releases, Next Up, From your Watch List, Popular Movies and Popular Series locally per server/account/device. Cached rows appear while independent updates run; complete empty success replaces them, failures preserve usable snapshots. No per-row Loading labels. A first uncached load can show one progress line. Below 5% playback does not create new viewing/resume/CW; completion still uses 95%, with explicit watched/Next exceptions. Older saved progress remains intact. New Releases owns newly released next episodes; Next Up excludes those episodes, including while older cached shelves refresh.

Movies/Series use a desktop grid or TV static spotlight plus one horizontally paginated row. Filters align with banner text/cards. Search uses only Type and query. TV spotlights show Cinemeta summaries/artwork immediately and never fetch/poll descriptive provider metadata or artwork while navigating or dwelling; opening details loads enrichment. Cached user-edited posters remain available. Cinemeta spotlight backdrops use the shared disk cache, request limit and device-aware decode bounds on both axes. Use shared Home poster sizing and gold IMDb score before year. Catalog page success/failure logs include bounded mode/count/duration fields, excluding search terms and URLs.

Right from sidebar restores the remembered media section, not filters or always the first row. Up accesses filters where present. Holding Left stops at the first card until a new press exits to sidebar. Home's first actual visible row reveals the hero while keeping the row visible; Up there does nothing. Mouse hover is visual only and never changes keyboard focus/selection/scroll. Wheel/drag/click remain normal.

Media/person/Settings pages keep sidebar and fixed top-left Back. Episode Back/Escape follows episode→season→show→caller even when opened from Home. Dialogs consume Escape first. Window reactivation must recover keyboard navigation without a mouse click.

Appearance → UI scale adjusts the entire interface immediately from 50% to 150% (default 100%) and remembers the choice. Start with 75% or 80% on a TV where controls/cards look too large. Native video retains the full display resolution. Scale is included in portable settings backup/reset. Episode-row focus keeps full thumbnails and captions visible with a small bottom margin at any selected scale.

Appearance → Poster indicator size adjusts watched checks/counts, joint/other-account badges, Watch List bookmarks, ratings and +X together, from 75% to 300%. Default 200% doubles the original size independently of UI scale. Changes apply immediately and are included in portable settings/reset; crowded account columns shrink to a readable minimum before truncating. Direct joint-account badges show that joint's rating. Returning to Ratings preserves the row's position and focus while refreshed titles move into their chosen categories.

Other-account rating overlays are larger and sit slightly outside the avatar corner, keeping the initial visible. Absolute cinema uses shorter, separated palms with their original proportions. Sidebar pictures/initials stay circular through collapse and expansion.

## Details, cast and sources

Movie details has resume/play, restart, download and watched actions with RD/Stremio source controls. Movie/episode entry and returning from playback focus Play/Resume once usable. Show details has download/watch actions and first-focus season cards (Specials last). Season has download/watch actions and episode thumbnails; title is prominent, episode tuple smaller, then release date. Episode combines the show hero/logo with episode art/description and movie-style play actions. Every media detail has release date. Keyboard focus on action rows reveals the hero; season focus reveals full cards.

Cast rows use portraits. Series cast defaults to TVDB; season/episode cast uses verified TMDb episode regulars and guests, with the series cast as fallback when unavailable. Season-poster loading skips scoped cast. On whole-series details, the icon-only **⋮** is the final action and uses the same outlined button style as Download/Watch/Rate. Administrators can use **⋮ → Change metadata provider**, confirm TVDB/TMDB, and reload that series' shared metadata and season/episode organization. If manual overrides exist, choose **Remove overrides and use the new provider** (default) or **Keep my overrides**, including hidden old seasons. Confirmation returns once saved; the current series/verified structure updates in the background, and season/episode descriptions, artwork and cast remain lazy. The choice applies server-wide, including person filmographies. Display numbering may change while playback/history/download IDs stay stable; existing offline copies keep their saved presentation and use it for folders/adjacency. No movie/season/episode selector or title-specific exception is used.

Person pages show originating media backdrop, portrait/basic data left and vertically centered biography right, with selectable Read more. Watched includes qualified started/retained viewing from the active account and its authorized joint accounts; Other follows, empty Watched is hidden. This classification preserves separate personal and colored joint completion/progress badges. Late row insertion must keep focused content visible. Filmography uses English names, character captions/art when available, poster fallback and full watch badges. Verified cross-provider person IDs supply the selected provider's separate series credits; people are never merged by name. Badges stack top-right: white current, colored joint; watched/total pills expand and full completion uses a checkmark.

Media navigation and actions use Series consistently. Other enabled server users appear on artwork as profile pictures/initials with partial episode counts or playback progress. Each person includes joint history except joints shared with the active viewer; joint accounts retain only the active viewer’s existing colored badges. Peer avatars stack vertically within artwork, shrink to a readable minimum and end with +X for any hidden people. They use authenticated, bounded, account-scoped reads with initial fallback. These indicators do not change personal completion, resume or Person Watched rows. The matching alpha contract is required.

Stremio sources load on entry; Play stays disabled until usable. Sources use the server's administrator connection, not personal history links. Explicit torrent identity or supported binge group resolves through RD; direct URLs are fallback only without identity. Green RD Direct Play and rainbow In RD Account describe verified identity/readiness, never authorize playback alone.

TED selects only the requested episode/movie file when adding a torrent to RD, reusing valid existing file links and preserving other account selections. It no longer selects an entire pack first. Existing season entries returning a RAR remain unchanged while TED prepares the exact episode separately. This policy requires the latest server adapter; no Teddy rebuild is needed. Migration 44 retains individual-file ownership. No archive extraction or silent switch to another release occurs.

Partial add-on failures retain bounded background retries. Once choices are available, the selected release stays visible and Play/source selection remain usable during recovery or a later failure. A picker opened during recovery keeps its choices; selection matches renewed handles by verified source identity. Source diagnostics record network lookup time, choice count and partial status without private URLs. This does not shorten an individual slow provider's response time.

Favorites then Recent take precedence; shared recent retains three and matches binge groups. The device's last-season preference is separate. Picker results cache 12 hours per context/media; Reload refetches for streaming and bulk downloads. All deduplicates favorites/recents/other streams. Gold favorites and cyan recents, dark modal/lighter cards, clear keyboard focus; unavailable add-on messages are scoped rather than flooding usable results.

## Player

TV controls are larger, centered with right controls vertically aligned. One seekbar style, round focused thumb, no chapter-jump/aspect-ratio buttons. Left/right enters and seeks on timeline; Down focuses pause. Mouse movement reveals controls without keyboard focus transfer. Cursor hides when idle over video, windowed or fullscreen. Skip intro/credits prompts stay clear of timeline. Popups work with keyboard/mouse; Escape closes a popup or leaves playback.

Android defaults to MPV with direct MediaCodec hardware decoding into the native video surface. Keep Hardware Decoding enabled for supported 4K media. Video Playback → Android video player also offers the bundled ExoPlayer; decoder/backend changes take effect on the next video. The Hardware Decoding toggle controls MPV; ExoPlayer selects decoders automatically. After installing a build containing the October 16 Chromecast fixes, compare the same 4K source with hardware decoding enabled, then try ExoPlayer if MPV still stutters. Check motion, seeking, subtitles and HDR on the actual device; host Flutter tests cannot establish decoder throughput or display cadence.

Chromecast with Google TV 4K supports hardware H.264/HEVC/VP9; AV1 sources require software decoding on that model. MPV already routes AV1 without hardware support through its native software decoder. ExoPlayer may use an Android software MediaCodec component instead. A 1080p label alone does not establish hardware compatibility: for example, the Trix Fruits Basket complete-series pack contains 10-bit AV1 episodes. Select an H.264 or HEVC release for the hardware path on this device; sources are never silently replaced. See [Google's device codec list](https://developers.google.com/cast/docs/media). Device decoder logs remain necessary to measure a specific session's drops and selected decoder.

Buffering pulses the media logo. Resume/unbuffered seeking must not trigger natural completion or retain imaginary buffered ranges. Next marks the current episode watched explicitly, navigates target details first and uses matching RD strategy or unique add-on/binge group; otherwise the target waits for selection. Download adjacency requires available local targets. Autoplay defaults off.

Audio override→original→English→default; enabled subtitles override→English→default. Remember language choices locally per title/show and cache original language offline. A known file <=30% expected runtime is rejected as a placeholder for viewing/download purposes.

MPV configures the bundled subtitle fonts before opening media. This is required on Android for text subtitles without attached fonts, such as the supplied Judas JoJo S06E04 file's embedded SubRip tracks. Recoverable player errors reopen the same pinned stream at its retained position up to three times per player session, preserving pause, speed and track choices. Transient source-preparation failures also retry the exact selected source up to three times; Back cancels further attempts. Changed/unsupported sources, placeholder media and permanent RD refusals retain their specific error rather than silently choosing another release. ExoPlayer passes HTTP failures back to TED recovery without treating them as codec failures.

Playback diagnostics are written to `logs/teddy.log` below app support, with one rotated `teddy.log.1` (about 2 MiB each). Ordinary logging records preparation attempts/failure codes, player errors, restarts and outcomes, media/session/backend/position, and subtitle/font selection. It excludes private source URLs and credentials. For intermittent incidents retain both files plus the approximate time and title/source. Android logcat is a separate rotating system buffer and may no longer contain yesterday's playback messages; start a capture before a future session when possible. Android's current View Logs action displays the internal path rather than exporting it.

Startup work already implemented: bounded validated session head/index-byte reuse, progressive header delivery, minimal initial buffer, selected Favorite/Recent ready-RD preparation on details and one matching next-episode prefetch at 50%. Selection/navigation cancels obsolete work. Preparation never records viewing or adds torrents merely through browsing. Further optimization is deferred investigation, not authorization to weaken validation.

## Downloads and local data

Downloads mixes movies/shows alphabetically, expands shows→seasons→episodes with increasing indentation and season-specific posters. Movies play immediately from local bytes. Sizes aggregate upward; trash removes only owned copies. Left enters sidebar without collapsing. Show/season progress says Downloading X of Y; movies/episodes show progress/speed; details buttons reflect transfer state.

Bulk show/season download asks All/Unwatched, then builds a source plan with explicit RD/unique binge-group continuation. Cancel discards all; Skip current advances; Skip remaining commits selected entries. Only commit starts downloads. Failed items/groups have Retry and Change selected source (failed entries only). Keep each selected release pinned through recovery.

Downloaded completion uses events after that copy's download timestamp, including playback of the same episode elsewhere; partial legitimate progress applies regardless of download time. Group counts include downloaded episodes only. Normal server watch state is unchanged. Cache episode thumbnails/original language for offline use.

Separate Drift tables retain downloads/checkpoints, scopes, exact durable reports and caches. Schema 32 adds scoped profile pictures; schema 31 added persistent Home rows and a session qualification latch for the original minimum-viewing threshold (now 5%). Historical resume remains eligible on upgrade. Reports remain until validated receipt, even after local-file deletion, except explicit profile Sign Out. Use the store/workflow APIs rather than editing SQLite manually.

Settings is one Plezy-style vertical page: General, Appearance, Video Playback, Downloads, Advanced, Backup, About. Changing download root moves owned files with journaled verified copies and fences playback/transfers. Range default 512 MiB (8–2048); simultaneous default 1 (1–10), shared admission across retries/bulk. Reducing limit lets active jobs finish. Reset/import/cache clear preserve credentials/history/device ID/reports/downloads; portable settings exclude device paths. See PROJECT for approved defaults and IMPLEMENTATION for known inherited-default discrepancies.

## Manual verification of the October 15 build

1. Quit old Teddy, open the immutable build from IMPLEMENTATION; choose a profile. Reopen Home after one successful fetch: all five cached shelves should render without row-loading labels and refresh in place. A successful empty personal shelf should disappear.
2. Use a previously unstarted movie/episode: stop below 5%; it should not gain resume/CW/history. Cross 5%, then seek back and stop: progress should remain. This intentionally changes real watch state; use a disposable account/title if preserving personal history matters.
3. In TED web, open movie/show details and toggle watched normally: the obsolete incomplete-state validation error should be gone. The library filter reads Mapped.
4. Switch profiles and return: caches/history must stay scoped; offline downloads must remain accessible. Do not Sign Out merely to test switching, as Sign Out intentionally deletes the profile's device data.

The current automated suites cover these boundaries; this checklist is for owner verification, not a claim that an agent operated the GUI. Keep private evidence under ignored `.devbox/`; do not commit credential bundles or database snapshots.

## Provenance

[UPSTREAM_README.md](UPSTREAM_README.md) records Plezy revision/license. Retain LICENSE, UPSTREAM.json, third_party notices and native dependency notices. Unused app integrations being removed does not authorize dropping shared player/widget copyrights. Contribution guidance is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Automated releases

Main pushes publish GitHub releases; develop pushes publish prereleases. PRs produce workflow artifacts only. Version allocation starts from `version.txt` (0.3); TED and Teddy must share their MAJOR.MINOR during the 0.x alpha (major only from 1.0). See [release setup and compatibility](../ted/docs/releases.md) for the platform matrix, required Android signing secrets, limitations, and rerun behavior. Inherited upstream store-release scripts are not the Teddy release path.

## Updates

Settings → Look for Updates offers Stable (default) and Release Candidate channels, restricted to the installed compatibility version (same minor during 0.x, same major from 1.0). If TED requires a different version, the incompatibility popup offers Update Teddy to check for a newer release matching that server. This preserves the chosen channel and excludes unrelated versions and downgrades. Dismissing the popup leaves the update action available. Update to version… downloads and verifies the official package and installs it. Desktop Teddy restarts after closing downloads/storage; Android asks for installation permission/confirmation. Development builds do not auto-update. Already shipped clients need a maintenance release carrying this action or a manual update; the server cannot add it to an older binary.

Desktop installs must be in a writable, dedicated app folder; keep downloads outside it. Windows/Linux packages need the included teddy-release.json. The previous app and installer log are retained beside the app in .teddy-update-*/previous and install.log; close all Teddy processes before manually restoring a previous bundle. This first updater release itself must be installed manually. See [release documentation](../ted/docs/releases.md) for verification and platform limitations.

On Android, macOS, Windows and Linux, stale update downloads are cleaned at startup and every six hours while Teddy runs, with a 24-hour grace period and a due check on resume. Active preparation, previous app bundles, installer logs and uncertain recovery payloads are preserved. This also recognizes packages left by older Teddy versions. Cleanup affects only update staging, not downloaded media or account data.

Application artwork lives in icon.png. On macOS regenerate with `devbox run -- python3 scripts/generate-app-icons.py` (Python stdlib, sips and Devbox FFmpeg). This covers Mac/Windows launcher icons, Windows tiles and transparent taskbar variants, all Android TV banner densities, Android launcher/splash and white notification masks, and the iOS Icon Composer source. This replaces the old Android/MSIX generators that depended on deleted Plezy masters. Flutter bundles the same master; Linux bundles it directly. Provider/player logos and required third-party notices retain their own identities. TV launcher acceptance needs a new APK and installation; existing launchers may keep an earlier banner cached. iOS source artwork is updated, but iOS packaging/runtime remain unverified.

Watch List follows Movies and Series in the sidebar. Its Movies/Series selector works like Search without a search field. Save/remove and rating controls live on whole movie/series details. Ratings includes seven personal shelves and account-only Unrated; joint accounts keep their own independent lists and ratings. Viewing never removes a saved title. Use a matching cache-free TED 0.3 server with this build; older alpha contracts and the withdrawn cache prototype are incompatible.
