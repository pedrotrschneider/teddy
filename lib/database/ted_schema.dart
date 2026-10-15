/// TED data stays separate from upstream lossy watch-action rows. Forward-only
/// schema changes preserve original event envelopes and device-owned downloads.
const tedDownloadQueueSchema = '''CREATE TABLE ted_download_queue (
  id TEXT PRIMARY KEY, scope TEXT NOT NULL, media TEXT NOT NULL, value TEXT NOT NULL,
  UNIQUE(scope,media)
)''';
const tedSeasonSourcesSchema = '''CREATE TABLE ted_season_sources (
  scope TEXT NOT NULL, show_id TEXT NOT NULL, season INTEGER NOT NULL,
  value TEXT NOT NULL, PRIMARY KEY(scope,show_id,season)
)''';
const tedTrackLanguagesSchema = '''CREATE TABLE ted_track_languages (
 scope TEXT NOT NULL, title TEXT NOT NULL, audio TEXT NOT NULL DEFAULT '', subtitle TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(scope,title)
)''';
const tedSourceCacheSchema = '''CREATE TABLE ted_source_cache (
 scope TEXT NOT NULL, media TEXT NOT NULL, saved_at INTEGER NOT NULL, value TEXT NOT NULL,
 PRIMARY KEY(scope,media)
)''';
const tedHomeCacheSchema = '''CREATE TABLE ted_home_cache (
 scope TEXT NOT NULL, row_id TEXT NOT NULL, value TEXT NOT NULL,
 PRIMARY KEY(scope,row_id)
)''';
const tedSchema = [
  tedHomeCacheSchema,
  tedSourceCacheSchema,
  tedTrackLanguagesSchema,
  'CREATE TABLE ted_installation (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  '''CREATE TABLE ted_sessions (
    id TEXT PRIMARY KEY, scope TEXT NOT NULL, media TEXT NOT NULL,
    registration TEXT, last_event TEXT, closed INTEGER NOT NULL DEFAULT 0,
    qualified INTEGER NOT NULL DEFAULT 0
  )''',
  '''CREATE TABLE ted_reports (
    ordinal INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
    session_id TEXT NOT NULL REFERENCES ted_sessions(id), envelope TEXT NOT NULL
  )''',
  '''CREATE TABLE ted_downloads (
    id TEXT PRIMARY KEY, scope TEXT NOT NULL, media TEXT NOT NULL, value TEXT NOT NULL,
    UNIQUE(scope,media)
  )''',
  tedDownloadQueueSchema,
  tedSeasonSourcesSchema,
];
