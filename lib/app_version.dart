/// Versão do app, vinda do build do GitHub (`--dart-define=APP_VERSION=1.5.N`). Fora dele: a do pubspec.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.5.0');
