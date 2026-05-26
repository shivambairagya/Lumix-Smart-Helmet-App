import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart'; // NEW: For Phone GPS

// ─────────────────────────────────────────────────────────────
//  CrashHistoryPage
// ─────────────────────────────────────────────────────────────

class CrashHistoryPage extends StatefulWidget {
  const CrashHistoryPage({super.key});

  @override
  State<CrashHistoryPage> createState() => _CrashHistoryPageState();
}

class _CrashHistoryPageState extends State<CrashHistoryPage> {
  final DatabaseReference _historyRef = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL:
    'https://lumix-h1-default-rtdb.asia-southeast1.firebasedatabase.app',
  ).ref("helmet/crash_history");

  List<CrashEntry> _entries   = [];
  bool             _loading   = true;
  String?          _error;
  StreamSubscription? _sub;

  final Set<String> _expanded = {};

  // ── Phone GPS State (Silent Fallback) ─────────────────────
  double _phoneLat = 0.0;
  double _phoneLon = 0.0;
  bool   _phoneGpsReady = false;
  StreamSubscription<Position>? _phoneGpsStream;

  // ── Cloud SMS Configuration ───────────────────────────────
  static const String _fast2smsApiKey = "JV3Xvaed1bSz0roA2fGPgRqHQWZDhO8iExCpnM5tmBUTLy4cIjfEar8lPcvOuHe50VQbXwpUYxAZzT7n";

  @override
  void initState() {
    super.initState();
    _startPhoneGpsStream();
    _listenHistory();
  }

  bool _parseBool(dynamic v) {
    if (v == null)   return false;
    if (v is bool)   return v;
    if (v is int)    return v != 0;
    if (v is String) return v.toLowerCase() == 'true' || v == '1';
    return false;
  }

  double _parseDouble(dynamic v, [double fallback = 0.0]) {
    if (v == null) return fallback;
    if (v is num)  return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  // ══════════════════════════════════════════════════════════
  //  PHONE GPS STREAM (Silent Fallback)
  // ══════════════════════════════════════════════════════════
  void _startPhoneGpsStream() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) return;

      try {
        Position position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
            timeLimit: const Duration(seconds: 5));
        _phoneLat = position.latitude;
        _phoneLon = position.longitude;
        _phoneGpsReady = true;
      } catch (_) {}

      _phoneGpsStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen((Position position) {
        _phoneLat = position.latitude;
        _phoneLon = position.longitude;
        _phoneGpsReady = true;
      });
    } catch (e) {
      debugPrint("❌ Error starting Phone GPS stream: $e");
    }
  }

  // ── Helper: Seamless GPS override ─────────────────────────
  // If Pi GPS is invalid (0,0 or "No GPS"), silently use Phone GPS.
  Map<String, dynamic> _getEffectiveLocation(CrashEntry e) {
    bool isPiGpsValid = e.latitude != 0.0 && !e.gps.contains("No GPS");

    double lat = isPiGpsValid ? e.latitude : (_phoneGpsReady ? _phoneLat : e.latitude);
    double lon = isPiGpsValid ? e.longitude : (_phoneGpsReady ? _phoneLon : e.longitude);

    bool hasGps = lat != 0.0;
    String mapsUrl = hasGps ? "https://www.google.com/maps?q=$lat,$lon" : "";
    String gpsStr = hasGps
        ? "Lat: ${lat.toStringAsFixed(6)}, Lon: ${lon.toStringAsFixed(6)}"
        : "No GPS fix";

    return {'lat': lat, 'lon': lon, 'url': mapsUrl, 'str': gpsStr, 'hasGps': hasGps};
  }

  void _listenHistory() {
    _sub = _historyRef.onValue.listen(
          (event) {
        final raw = event.snapshot.value;
        if (!mounted) return;

        if (raw == null) {
          setState(() { _entries = []; _loading = false; });
          return;
        }

        try {
          final map = Map<String, dynamic>.from(raw as Map);
          final List<CrashEntry> parsed = [];

          map.forEach((key, val) {
            try {
              final d = Map<String, dynamic>.from(val as Map);
              parsed.add(CrashEntry(
                id:            key,
                timestamp:     d['timestamp']?.toString()      ?? "Unknown time",
                unixTime:      (_parseDouble(d['unix_time'])).toInt(),
                triggerSource: d['trigger_source']?.toString() ?? "unknown",
                acceleration:  _parseDouble(d['acceleration']),
                accelDelta:    _parseDouble(d['accel_delta']),
                gyroscope:     _parseDouble(d['gyroscope']),
                gyroDelta:     _parseDouble(d['gyro_delta']),
                vibration:     _parseBool(d['vibration']),
                distanceCm:    _parseDouble(d['distance_cm']),
                gps:           d['gps']?.toString()            ?? "No GPS",
                latitude:      _parseDouble(d['latitude']),
                longitude:     _parseDouble(d['longitude']),
                mapsUrl:       d['maps_url']?.toString()       ?? "",
              ));
            } catch (e) {
              debugPrint("⚠️ Skipped entry $key: $e");
            }
          });

          parsed.sort((a, b) => b.unixTime.compareTo(a.unixTime));

          setState(() {
            _entries = parsed;
            _loading = false;
            _error   = null;
          });
        } catch (e) {
          setState(() {
            _error   = "Failed to parse crash history: $e";
            _loading = false;
          });
        }
      },
      onError: (e) {
        if (mounted) setState(() {
          _error   = "Firebase error: $e";
          _loading = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _phoneGpsStream?.cancel();
    super.dispose();
  }

  Future<void> _openMaps(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not open Maps")),
        );
      }
    }
  }

  // ══════════════════════════════════════════════════════════
  //  CLOUD SMS VIA FAST2SMS API
  // ══════════════════════════════════════════════════════════
  Future<bool> _sendCloudSms(String message, String phone) async {
    String cleanPhone = phone.replaceAll('+91', '');

    try {
      var response = await http.post(
        Uri.parse("https://www.fast2sms.com/dev/bulkV2"),
        headers: {
          'authorization': _fast2smsApiKey,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {
          'route': 'q',
          'message': message,
          'language': 'english',
          'flash': '0',
          'numbers': cleanPhone,
        },
      );

      if (response.statusCode == 200) {
        debugPrint("✅ Cloud SMS sent successfully via Fast2SMS to $cleanPhone");
        return true;
      } else {
        debugPrint("❌ Fast2SMS Error: ${response.body}");
        return false;
      }
    } catch (e) {
      debugPrint("❌ Cloud SMS Exception: $e");
      return false;
    }
  }

  // ── SMS for specific history item (Uses patched GPS silently) ──
  Future<void> _sendSmsForEntry(CrashEntry e) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? emergencyNumber = prefs.getString('emergencyContact');

      if (emergencyNumber == null || emergencyNumber.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No emergency contact set in profile!")),
          );
        }
        return;
      }

      if (!emergencyNumber.startsWith('+')) {
        emergencyNumber = '+91$emergencyNumber';
      }

      final locData = _getEffectiveLocation(e);
      final String mapsLink = locData['url'];

      String message = "🚨 CRASH ALERT HISTORY\n"
          "Time: ${e.timestamp}\n"
          "Source: ${e.triggerSource}\n"
          "Impact: ${e.acceleration} m/s²\n"
          "Location: ${mapsLink.isNotEmpty ? mapsLink : locData['str']}";

      bool cloudSuccess = await _sendCloudSms(message, emergencyNumber);

      if (mounted && cloudSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Emergency SMS sent to $emergencyNumber")),
        );
      }

      if (!cloudSuccess) {
        debugPrint("⚠️ Cloud SMS failed. Falling back to SMS App.");
        final Uri smsUri = Uri(
          scheme: 'sms',
          path: emergencyNumber,
          queryParameters: {'body': message},
        );
        if (await canLaunchUrl(smsUri)) {
          await launchUrl(smsUri);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Could not open SMS app")),
            );
          }
        }
      }

    } catch (err) {
      debugPrint("❌ SMS Error: $err");
    }
  }

  Future<void> _deleteEntry(String id) async {
    try {
      await _historyRef.child(id).remove();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Delete failed: $e")),
        );
      }
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text("Clear All History",
            style: TextStyle(color: Colors.white)),
        content: const Text(
            "This will permanently delete all crash records.",
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel",
                style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("DELETE ALL",
                style: TextStyle(color: Colors.redAccent,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await _historyRef.remove();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed: $e")),
          );
        }
      }
    }
  }

  // ══════════════════════════════════════════════════════════
  //  BUILD — Single header, no duplicate
  // ══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.history_rounded, color: Colors.redAccent, size: 26),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Report Logs",
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                if (_entries.isNotEmpty)
                  Text("${_entries.length} event${_entries.length == 1 ? '' : 's'}",
                      style: const TextStyle(color: Colors.grey, fontSize: 11)),
              ],
            ),
          ],
        ),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
              tooltip: "Clear all history",
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.redAccent),
            SizedBox(height: 16),
            Text("Loading crash history...",
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, color: Colors.redAccent, size: 48),
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                color: Colors.greenAccent, size: 64),
            SizedBox(height: 16),
            Text("No crashes recorded",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text("Ride safe — history will appear here if a crash is detected.",
                style: TextStyle(color: Colors.grey, fontSize: 13),
                textAlign: TextAlign.center),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _entries.length,
      itemBuilder: (_, i) => _buildCrashCard(_entries[i], i),
    );
  }

  Widget _buildCrashCard(CrashEntry e, int index) {
    final isExpanded = _expanded.contains(e.id);
    final isDemo     = e.triggerSource.contains("DEMO");

    final Color accentColor = isDemo
        ? Colors.amberAccent
        : (e.triggerSource.contains("camera")
        ? Colors.deepOrangeAccent
        : Colors.redAccent);

    // Seamless GPS fallback logic
    final locData = _getEffectiveLocation(e);
    final bool hasGps = locData['hasGps'];
    final String displayGpsStr = locData['str'];
    final String effectiveMapsUrl = locData['url'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() {
              if (isExpanded) _expanded.remove(e.id);
              else            _expanded.add(e.id);
            }),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: accentColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: accentColor.withOpacity(0.5)),
                    ),
                    child: Center(
                      child: Text(
                        "#${_entries.length - index}",
                        style: TextStyle(
                            color: accentColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.timestamp,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(
                              isDemo
                                  ? Icons.science
                                  : Icons.warning_amber_rounded,
                              color: accentColor,
                              size: 13,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _friendlySource(e.triggerSource),
                              style: TextStyle(
                                  color: accentColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text("${e.acceleration.toStringAsFixed(1)} m/s²",
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                      Text("${e.distanceCm.toStringAsFixed(0)} cm",
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),

          if (isExpanded) ...[
            const Divider(color: Colors.white12, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      _statTile("Acceleration", "${e.acceleration.toStringAsFixed(2)} m/s²",
                          Icons.speed, Colors.blueAccent),
                      const SizedBox(width: 8),
                      _statTile("Accel Δ", "${e.accelDelta.toStringAsFixed(2)} m/s²",
                          Icons.trending_up, Colors.cyanAccent),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _statTile("Gyroscope", "${e.gyroscope.toStringAsFixed(2)} °/s",
                          Icons.rotate_right, Colors.purpleAccent),
                      const SizedBox(width: 8),
                      _statTile("Distance", "${e.distanceCm.toStringAsFixed(1)} cm",
                          Icons.straighten, Colors.orangeAccent),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _statTile(
                        "Vibration",
                        e.vibration ? "ACTIVE" : "None",
                        Icons.vibration,
                        e.vibration ? Colors.redAccent : Colors.greenAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accentColor.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: accentColor.withOpacity(0.25)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Source",
                                  style: TextStyle(
                                      color: Colors.grey[500], fontSize: 10)),
                              const SizedBox(height: 4),
                              Text(
                                e.triggerSource,
                                style: TextStyle(
                                    color: accentColor,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // GPS Location Card (Silently uses Phone GPS if Pi failed)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.teal.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.tealAccent.withOpacity(0.2)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.location_on,
                            color: Colors.tealAccent, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            displayGpsStr, // Silently patched
                            style: const TextStyle(
                                color: Colors.tealAccent, fontSize: 11),
                          ),
                        ),
                        if (hasGps)
                          GestureDetector(
                            onTap: () => _openMaps(effectiveMapsUrl),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.tealAccent.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: Colors.tealAccent.withOpacity(0.4)),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.map, color: Colors.tealAccent, size: 13),
                                  SizedBox(width: 4),
                                  Text("Maps",
                                      style: TextStyle(
                                          color: Colors.tealAccent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Action buttons row
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          onPressed: () => _sendSmsForEntry(e),
                          icon: const Icon(Icons.cloud_upload,
                              color: Colors.tealAccent, size: 16),
                          label: const Text("Send SMS",
                              style: TextStyle(
                                  color: Colors.tealAccent, fontSize: 12)),
                        ),
                        TextButton.icon(
                          onPressed: () => _deleteEntry(e.id),
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.redAccent, size: 16),
                          label: const Text("Delete",
                              style: TextStyle(
                                  color: Colors.redAccent, fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statTile(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: Colors.grey[500], fontSize: 9)),
                  Text(value,
                      style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _friendlySource(String src) {
    switch (src) {
      case "imu_vibration_ultrasonic":              return "IMU + Vib + Ultra";
      case "imu_vibration_ultrasonic_and_camera":   return "All Sensors + Cam";
      case "camera_only":                           return "Camera Only";
      case "voice_manual_trigger":                  return "Voice SOS";
      case "sensors_only":                          return "IMU / Ultrasonic";
      case "sensors_and_camera":                    return "IMU + Camera";
      case "DEMO_TEST":                             return "Demo Test";
      default:                                      return src.replaceAll("_", " ");
    }
  }
}


// ═══════════════════════════════════════════════════════════════
//  DATA MODEL
// ═══════════════════════════════════════════════════════════════

class CrashEntry {
  final String id;
  final String timestamp;
  final int    unixTime;
  final String triggerSource;
  final double acceleration;
  final double accelDelta;
  final double gyroscope;
  final double gyroDelta;
  final bool   vibration;
  final double distanceCm;
  final String gps;
  final double latitude;
  final double longitude;
  final String mapsUrl;

  const CrashEntry({
    required this.id,
    required this.timestamp,
    required this.unixTime,
    required this.triggerSource,
    required this.acceleration,
    required this.accelDelta,
    required this.gyroscope,
    required this.gyroDelta,
    required this.vibration,
    required this.distanceCm,
    required this.gps,
    required this.latitude,
    required this.longitude,
    required this.mapsUrl,
  });
}
