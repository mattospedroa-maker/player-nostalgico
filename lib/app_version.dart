/// Versão do app, vinda do build do GitHub (`--dart-define=APP_VERSION=3.0.N`). Fora dele: a do pubspec.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '3.0.0');
