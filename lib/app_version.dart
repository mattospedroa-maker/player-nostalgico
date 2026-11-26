/// Versão do app, vinda do build do GitHub (`--dart-define=APP_VERSION=2.1.N`). Fora dele: a do pubspec.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '2.1.0');
