/// Presented when a remote host's SSH key no longer matches the one this app
/// previously trusted for the same host:port — either a legitimate key
/// rotation (the server was reinstalled or its host key renewed) or, in the
/// worst case, a man-in-the-middle. The user must explicitly choose to trust
/// the new key (and forget the old one) or cancel the connection; there is no
/// silent fallback either way.
class HostKeyPrompt {
  final String host;
  final int port;
  final String previousKeyType;
  final String previousFingerprint;
  final String newKeyType;
  final String newFingerprint;

  const HostKeyPrompt({
    required this.host,
    required this.port,
    required this.previousKeyType,
    required this.previousFingerprint,
    required this.newKeyType,
    required this.newFingerprint,
  });
}
