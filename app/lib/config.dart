class AppConfig {
  static const serverUrl = String.fromEnvironment(
    'MEDIBRIDGE_SERVER_URL',
    defaultValue: 'http://10.0.2.2:3000',
  );

  static const autoStart = bool.fromEnvironment(
    'MEDIBRIDGE_AUTOSTART',
    defaultValue: false,
  );
}
