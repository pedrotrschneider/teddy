class MediaServerTimeouts {
  /// Reaching the server: DNS, TCP and TLS. Enforced by the transport, so it
  /// never cuts into the server's think time.
  static const connect = Duration(seconds: 10);

  /// Waiting on a server that was reached for its response headers — the
  /// server's think time. Covers a slow-but-working query (an Emby search
  /// that takes 11–15 s, #2581) while a server that accepted the connection
  /// and never answers still fails well before [receive].
  static const response = Duration(seconds: 30);

  /// Waiting on the response body once the headers arrived.
  static const receive = Duration(seconds: 120);

  static const homeHubDeadline = Duration(seconds: 15);

  static const libraryHubDeadline = Duration(seconds: 20);

  static const libraryLookup = Duration(seconds: 20);

  /// Per-server deadline for one leg of a global search
  /// (`DataAggregationService.searchAcrossServers`): a server's titles, and
  /// separately its people. Every server's results are shown together, so a
  /// server that accepted the connection and stopped answering would
  /// otherwise hold back all of them for the full [response] budget. Same
  /// budget as [libraryLookup], which searches the same libraries.
  static const searchServerDeadline = Duration(seconds: 20);

  /// Per-server deadline for one server's library list
  /// (`DataAggregationService.getMediaLibrariesFromAllServers`). A server
  /// that misses it counts as failed and is retried on the next pass instead
  /// of holding back the libraries, and the home hubs built from them, of
  /// every other server. Same budget as [homeHubDeadline].
  static const libraryListServerDeadline = Duration(seconds: 15);

  /// Timeout for probing a cached/preferred endpoint (used in
  /// [PlexServer.findBestWorkingConnection]).
  static const preferredEndpointProbe = Duration(milliseconds: 1500);

  /// How long the cached/preferred endpoint probe gets to answer before the
  /// full candidate race starts alongside it. A healthy cached endpoint
  /// answers well inside this window and wins deterministically; a stale one
  /// (e.g. a cached LAN address probed from outside the LAN) only delays
  /// discovery by this much instead of the full [preferredEndpointProbe].
  static const preferredEndpointHeadStart = Duration(milliseconds: 300);

  /// Timeout for the connection race where all candidates are tested in
  /// parallel (used in [PlexServer.findBestWorkingConnection]).
  static const connectionRace = Duration(seconds: 2);

  /// Per-server connection watchdog ceiling. The discovery path is no longer
  /// strictly serial (cached probe overlaps the race; the HTTPS upgrade runs
  /// off the critical path), so this is a generous upper bound rather than a
  /// sum of phases.
  static const perServerConnect = Duration(milliseconds: 6500);

  /// How long the startup splash waits for the initial bind when the OS
  /// reports no network. The bind still runs — `none` leaves loopback and
  /// LAN-without-WAN servers reachable (#2505) — but an airplane-mode launch
  /// must not sit through [perServerConnect]. Past the cap the offline shell
  /// opens and the bind keeps going, so a server that connects later still
  /// brings the app online.
  static const noNetworkStartupBind = Duration(seconds: 2);

  /// How long a caller waits for a Plex tune or a MediaBrowser Live TV
  /// PlaybackInfo that opens a source. Matches Plex web's value: a cold tuner
  /// can take well over ten seconds to return response headers.
  ///
  /// Only the wait: the request itself runs to [tuneTransport]. Servers finish
  /// opening a tuner whether or not the client is still connected (#2394), so
  /// the tune's answer must still arrive to be released.
  static const tune = Duration(seconds: 30);

  /// Per-phase HTTP timeout for a tune request, and for closing what one
  /// opened (the close queues behind other opens on the server). Bounds a dead
  /// connection, not the user's wait — see [tune].
  static const tuneTransport = Duration(minutes: 3);

  static const plexTvConnect = Duration(seconds: 15);

  static const plexTvReceive = Duration(seconds: 10);

  /// Authenticated health probe timeout. Health sweeps await every server, so
  /// a stale Plex endpoint must not hold the whole sweep for [response].
  static const plexProbe = Duration(seconds: 8);

  /// Whole-probe deadline for establishing what a server-side delete will
  /// destroy (see `resolveDeleteImpact`). Generous compared to
  /// interactive permission checks for two reasons: it runs behind a modal
  /// spinner *after* the user asked to delete, not while a menu is opening,
  /// and it may fan out one detail request per sibling episode when browse
  /// rows omit file paths.
  ///
  /// Unlike the permission probe, expiry cannot fail closed — Plex never
  /// sends file paths to restricted users, so refusing the delete would
  /// permanently remove a feature the server itself authorizes. Expiry
  /// instead downgrades the confirmation to its explicit "scope unverified"
  /// form.
  static const deleteImpactProbe = Duration(seconds: 10);
}
