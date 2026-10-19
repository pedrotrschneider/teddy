/// Release CI overrides these; local builds use the committed alpha contract.
const teddyCompatibilityMajor = String.fromEnvironment('TEDDY_COMPATIBILITY_MAJOR', defaultValue: '0');
const teddyReleaseVersion = String.fromEnvironment('TEDDY_RELEASE_VERSION', defaultValue: '0.2.0-dev');

const teddyCompatibilityVersion = String.fromEnvironment('TEDDY_COMPATIBILITY_VERSION', defaultValue: '0.2');
