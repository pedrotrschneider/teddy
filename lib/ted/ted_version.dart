/// Release CI overrides these; local builds use the committed major zero.
const teddyCompatibilityMajor = String.fromEnvironment('TEDDY_COMPATIBILITY_MAJOR', defaultValue: '0');
const teddyReleaseVersion = String.fromEnvironment('TEDDY_RELEASE_VERSION', defaultValue: '0.1.0-dev');
