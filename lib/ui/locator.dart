import 'package:geolocator/geolocator.dart';

import '../core/geo.dart';

/// Текущее местоположение устройства; null — нет разрешения или сигнала.
Future<LatLon?> deviceLocation() async {
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 15));
    return LatLon(p.latitude, p.longitude);
  } catch (_) {
    return null;
  }
}
