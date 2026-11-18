import 'dart:math';

/// Exponential backoff with jitter for retrying failed sync operations:
/// 5 s, 10 s, 20 s, … capped at 15 min, ±20 % jitter so many devices that
/// lost connectivity together do not all retry at the same instant.
Duration retryDelay(int attempts, {Random? random}) {
  final n = attempts.clamp(1, 20);
  final base = min(5 * pow(2, n - 1), 15 * 60).toDouble();
  final jitter = 0.8 + (random ?? Random()).nextDouble() * 0.4;
  return Duration(milliseconds: (base * jitter * 1000).round());
}
