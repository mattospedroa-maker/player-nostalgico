/// Versão do app, vinda do build do GitHub (`--dart-define=APP_VERSION=1.6.N`). Fora dele: a do pubspec.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.6.0');
