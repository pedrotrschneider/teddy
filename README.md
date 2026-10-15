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

Java 21 JDK (including `java`, `javac`, and `keytool`) is installed through this project's Devbox. After dependency changes, exit any old Devbox shell and enter `devbox shell` again, or use `devbox run -- keytool -help`. This avoids macOS's `/usr/bin/java` and `/usr/bin/keytool` launchers, which require a separately registered system runtime. No system Java installation is needed for signing-key generation.

## Profiles and authentication

Every launch starts at **Who's watching?**, with circular profiles and a plus circle. Choose a profile before authentication/sync/download work starts, then the configured Startup Section opens. Switch Profile/Add profile retains the same read-only server address; Change server permits a new origin and preserves earlier servers' profiles. Only one context authenticates at once.

Switching pauses/fences downloads and retains copies/reports/caches. Explicit Sign Out removes that profile's owned device data and credentials, including pending reports, without deleting server history, another profile or the installation ID. Expired credentials do not automatically delete downloads or deny offline local playback. A changed localhost/LAN URL is a different scope; the owner's preserved tunnel is documented in the home-server record.

Credentials live in one verified OS-backed bundle using flutter_secure_storage10.3.4. Refresh is serialized, single-use and family-preserving. Uncertain rotation/persistence requires fresh login. Request keychain access retries denied OS access; permission success must not hide a different write/verification error. Do not reset secure storage as a generic fix.

## Browsing and navigation

Sidebar: Search, Home, Movies, Shows, Downloads; footer Reload, Settings, Account. Enter/click activates destinations; hover/focus alone does not. Keyboard focus is a white outline independent of current-page selection. The sidebar collapses to equal-width desktop/TV icons unless hovered, focused or configured always-open.

Home persists Continue Watching, New Releases, Next Up, Popular Movies and Popular Shows locally per server/account/device. Cached rows appear while independent updates run; complete empty success replaces them, failures preserve usable snapshots. No per-row Loading labels. A first uncached load can show one progress line. Below 15% playback does not create new viewing/resume/CW; completion still uses 90%, with explicit watched/Next exceptions. Older saved progress remains intact.

Movies/Shows use a desktop grid or TV static spotlight plus one horizontally paginated row. Filters align with banner text/cards. Search uses only Type and query. Missing TV spotlight metadata fetches after 100 ms; cache hits show immediately. Use shared Home poster sizing and gold IMDb score before year.

Right from sidebar restores the remembered media section, not filters or always the first row. Up accesses filters where present. Holding Left stops at the first card until a new press exits to sidebar. Home's first actual visible row reveals the hero while keeping the row visible; Up there does nothing. Mouse hover is visual only and never changes keyboard focus/selection/scroll. Wheel/drag/click remain normal.

Media/person/Settings pages keep sidebar and fixed top-left Back. Episode Back/Escape follows episode→season→show→caller even when opened from Home. Dialogs consume Escape first. Window reactivation must recover keyboard navigation without a mouse click.

## Details, cast and sources

Movie details has resume/play, restart, download and watched actions with RD/Stremio source controls. Show details has download/watch actions and first-focus season cards (Specials last). Season has download/watch actions and episode thumbnails; title is prominent, episode tuple smaller, then release date. Episode combines the show hero/logo with episode art/description and movie-style play actions. Every media detail has release date. Keyboard focus on action rows reveals the hero; season focus reveals full cards.

Cast rows use portraits; season/episode reuse show cast. Person pages show originating media backdrop, portrait/basic data left and vertically centered biography right, with selectable Read more. Watched includes qualified started/retained viewing; Other follows, empty Watched is hidden. Late row insertion must keep focused content visible. Filmography uses English names, character captions/art when available, poster fallback and full watch badges. Badges stack top-right: white current, colored joint; watched/total pills expand and full completion uses a checkmark.

Stremio sources load on entry; Play stays disabled until usable. Sources use the server's administrator connection, not personal history links. Explicit torrent identity or supported binge group resolves through RD; direct URLs are fallback only without identity. Green RD Direct Play and rainbow In RD Account describe verified identity/readiness, never authorize playback alone.

Favorites then Recent take precedence; shared recent retains three and matches binge groups. The device's last-season preference is separate. Picker results cache 12 hours per context/media; Reload refetches for streaming and bulk downloads. All deduplicates favorites/recents/other streams. Gold favorites and cyan recents, dark modal/lighter cards, clear keyboard focus; unavailable add-on messages are scoped rather than flooding usable results.

## Player

TV controls are larger, centered with right controls vertically aligned. One seekbar style, round focused thumb, no chapter-jump/aspect-ratio buttons. Left/right enters and seeks on timeline; Down focuses pause. Mouse movement reveals controls without keyboard focus transfer. Cursor hides when idle over video, windowed or fullscreen. Skip intro/credits prompts stay clear of timeline. Popups work with keyboard/mouse; Escape closes a popup or leaves playback.

Buffering pulses the media logo. Resume/unbuffered seeking must not trigger natural completion or retain imaginary buffered ranges. Next marks the current episode watched explicitly, navigates target details first and uses matching RD strategy or unique add-on/binge group; otherwise the target waits for selection. Download adjacency requires available local targets. Autoplay defaults off.

Audio override→original→English→default; enabled subtitles override→English→default. Remember language choices locally per title/show and cache original language offline. A known file <=30% expected runtime is rejected as a placeholder for viewing/download purposes.

Startup work already implemented: bounded validated session head/index-byte reuse, progressive header delivery, minimal initial buffer, selected Favorite/Recent ready-RD preparation on details and one matching next-episode prefetch at 50%. Selection/navigation cancels obsolete work. Preparation never records viewing or adds torrents merely through browsing. Further optimization is deferred investigation, not authorization to weaken validation.

## Downloads and local data

Downloads mixes movies/shows alphabetically, expands shows→seasons→episodes with increasing indentation and season-specific posters. Movies play immediately from local bytes. Sizes aggregate upward; trash removes only owned copies. Left enters sidebar without collapsing. Show/season progress says Downloading X of Y; movies/episodes show progress/speed; details buttons reflect transfer state.

Bulk show/season download asks All/Unwatched, then builds a source plan with explicit RD/unique binge-group continuation. Cancel discards all; Skip current advances; Skip remaining commits selected entries. Only commit starts downloads. Failed items/groups have Retry and Change selected source (failed entries only). Keep each selected release pinned through recovery.

Downloaded completion uses events after that copy's download timestamp, including playback of the same episode elsewhere; partial legitimate progress applies regardless of download time. Group counts include downloaded episodes only. Normal server watch state is unchanged. Cache episode thumbnails/original language for offline use.

Separate Drift tables retain downloads/checkpoints, scopes, exact durable reports and caches. Schema 31 adds persistent Home rows and a session qualification latch for the 15% threshold; historical resume remains eligible on upgrade. Reports remain until validated receipt, even after local-file deletion, except explicit profile Sign Out. Use the store/workflow APIs rather than editing SQLite manually.

Settings is one Plezy-style vertical page: General, Appearance, Video Playback, Downloads, Advanced, Backup, About. Changing download root moves owned files with journaled verified copies and fences playback/transfers. Range default 512 MiB (8–2048); simultaneous default 1 (1–10), shared admission across retries/bulk. Reducing limit lets active jobs finish. Reset/import/cache clear preserve credentials/history/device ID/reports/downloads; portable settings exclude device paths. See PROJECT for approved defaults and IMPLEMENTATION for known inherited-default discrepancies.

## Manual verification of the October 15 build

1. Quit old Teddy, open the immutable build from IMPLEMENTATION; choose a profile. Reopen Home after one successful fetch: all five cached shelves should render without row-loading labels and refresh in place. A successful empty personal shelf should disappear.
2. Use a previously unstarted movie/episode: stop below 15%; it should not gain resume/CW/history. Cross 15%, then seek back and stop: progress should remain. This intentionally changes real watch state; use a disposable account/title if preserving personal history matters.
3. In TED web, open movie/show details and toggle watched normally: the obsolete incomplete-state validation error should be gone. The library filter reads Mapped.
4. Switch profiles and return: caches/history must stay scoped; offline downloads must remain accessible. Do not Sign Out merely to test switching, as Sign Out intentionally deletes the profile's device data.

The current automated suites cover these boundaries; this checklist is for owner verification, not a claim that an agent operated the GUI. Keep private evidence under ignored `.devbox/`; do not commit credential bundles or database snapshots.

## Provenance

[UPSTREAM_README.md](UPSTREAM_README.md) records Plezy revision/license. Retain LICENSE, UPSTREAM.json, third_party notices and native dependency notices. Unused app integrations being removed does not authorize dropping shared player/widget copyrights. Contribution guidance is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Automated releases

Main pushes publish GitHub releases; develop pushes publish prereleases. PRs produce workflow artifacts only. Version allocation starts from `version.txt` (0.1); TED and Teddy must share their major version. See [release setup and compatibility](../ted/docs/releases.md) for the platform matrix, required Android signing secrets, limitations, and rerun behavior. Inherited upstream store-release scripts are not the Teddy release path.
