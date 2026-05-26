import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

class HelmetStatusPage extends StatefulWidget {
  const HelmetStatusPage({super.key});

  @override
  State<HelmetStatusPage> createState() => _HelmetStatusPageState();
}

class _HelmetStatusPageState extends State<HelmetStatusPage>
    with SingleTickerProviderStateMixin {
  // ── Firebase refs ──────────────────────────────────────────
  final DatabaseReference _sensorsRef = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL:
    'https://lumix-h1-default-rtdb.asia-southeast1.firebasedatabase.app',
  ).ref("helmet/sensors");

  final DatabaseReference _crashRef = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL:
    'https://lumix-h1-default-rtdb.asia-southeast1.firebasedatabase.app',
  ).ref("helmet/crash_alert");

  // ── Cloud SMS Configuration (FIXED: Real API key) ─────────
  final String _fast2smsApiKey = dotenv.env['FAST2SMS_API_KEY']!;

  // ── Sensor state ───────────────────────────────────────────
  double acceleration       = 0.0;
  double accelDelta         = 0.0;
  double gyroscope          = 0.0;
  double gyroDelta          = 0.0;
  double distanceCm         = 0.0;
  bool   vibrationRaw       = false;
  bool   vibrationTriggered = false;
  bool   imuTriggered       = false;
  bool   ultraTriggered     = false;
  bool   sensorsTriggered   = false;
  bool   crashBufferActive  = false;
  bool   helmetConnected    = false;

  // ── Phone GPS State ───────────────────────────────────────
  double _phoneLat = 0.0;
  double _phoneLon = 0.0;
  bool   _phoneGpsReady = false;
  StreamSubscription<Position>? _phoneGpsStream;

  // ── Crash alert state ──────────────────────────────────────
  bool   crashAlert       = false;
  String crashTimestamp   = "";
  String crashTriggerSrc  = "";
  String crashMapsUrl     = "";
  int    _lastAlertedUnixTime = 0;

  // ── SMS sending state ──────────────────────────────────────
  bool   _smsSending     = false;
  bool   _smsSent        = false;
  String _smsStatus      = "";

  // ── Connection tracking ────────────────────────────────────
  bool   isConnected = false;
  Timer? _disconnectTimer;

  // ── Animation ─────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;

  StreamSubscription? _sensorsSub;
  StreamSubscription? _crashSub;

  bool? _parseBool(dynamic v) {
    if (v == null)          return null;
    if (v is bool)          return v;
    if (v is int)           return v != 0;
    if (v is String) {
      final s = v.toLowerCase().trim();
      if (s == 'true'  || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _requestSmsPermissions();
    _startPhoneGpsStream();
    _listenSensors();
    _listenCrash();
  }

  // ══════════════════════════════════════════════════════════
  //  PHONE GPS STREAM
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
        if (mounted) {
          setState(() {
            _phoneLat = position.latitude;
            _phoneLon = position.longitude;
            _phoneGpsReady = true;
          });
        }
      } catch (_) {}

      _phoneGpsStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position position) {
        if (mounted) {
          setState(() {
            _phoneLat = position.latitude;
            _phoneLon = position.longitude;
            _phoneGpsReady = true;
          });
        }
      });
    } catch (e) {
      debugPrint("❌ Error starting Phone GPS stream: $e");
    }
  }

  Future<void> _requestSmsPermissions() async {
    try {
      var status = await Permission.sms.status;
      if (!status.isGranted) await Permission.sms.request();
    } catch (e) {
      debugPrint("❌ Error requesting SMS permissions: $e");
    }
  }

  // ── helmet/sensors listener ────────────────────────────────
  void _listenSensors() {
    _sensorsSub = _sensorsRef.onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw == null || !mounted) return;

      try {
        final d = Map<String, dynamic>.from(raw as Map);
        _resetDisconnectTimer();

        setState(() {
          acceleration  = (d['acceleration']   as num?)?.toDouble() ?? 0.0;
          accelDelta    = (d['accel_delta_max'] as num?)?.toDouble()
              ?? (d['accel_delta']     as num?)?.toDouble() ?? 0.0;
          gyroscope     = (d['gyroscope']       as num?)?.toDouble() ?? 0.0;
          gyroDelta     = (d['gyro_delta_max']  as num?)?.toDouble()
              ?? (d['gyro_delta']      as num?)?.toDouble() ?? 0.0;
          distanceCm    = (d['distance_cm']     as num?)?.toDouble() ?? 0.0;
          vibrationRaw       = _parseBool(d['vibration'])
              ?? _parseBool(d['vibration_raw']) ?? false;
          vibrationTriggered = _parseBool(d['vibration_triggered'])  ?? false;
          imuTriggered       = _parseBool(d['imu_triggered'])        ?? false;
          ultraTriggered     = _parseBool(d['ultrasonic_triggered']) ?? false;
          sensorsTriggered   = _parseBool(d['sensors_triggered'])    ?? false;
          crashBufferActive  = _parseBool(d['crash_buffer_active'])  ?? false;
          helmetConnected    = _parseBool(d['connected'])            ?? false;
          isConnected = true;
        });
      } catch (e) {
        debugPrint("❌ Sensors parse error: $e");
      }
    }, onError: (_) {
      if (mounted) setState(() => isConnected = false);
    });
  }

  // ── helmet/crash_alert listener ────────────────────────────
  void _listenCrash() {
    _crashSub = _crashRef.onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw == null || !mounted) return;

      try {
        final d = Map<String, dynamic>.from(raw as Map);
        final int currentUnixTime = (d['unix_time'] as num?)?.toInt() ?? 0;

        double crashLat = (d['latitude'] as num?)?.toDouble() ?? 0.0;
        double crashLon = (d['longitude'] as num?)?.toDouble() ?? 0.0;
        String crashGps = d['gps']?.toString() ?? "No GPS fix";

        // Patch GPS with phone GPS if Pi GPS failed
        if ((crashLat == 0.0 || crashGps.contains("No GPS")) && _phoneLat != 0.0) {
          d['latitude'] = _phoneLat;
          d['longitude'] = _phoneLon;
          d['gps'] = "Lat: ${_phoneLat.toStringAsFixed(6)}, Lon: ${_phoneLon.toStringAsFixed(6)}";
          d['maps_url'] = "https://www.google.com/maps?q=$_phoneLat,$_phoneLon";
        }

        setState(() {
          crashAlert      = _parseBool(d['alert'])       ?? false;
          crashTimestamp  = d['timestamp']?.toString()   ?? "";
          crashTriggerSrc = d['trigger_source']?.toString() ?? "";
          crashMapsUrl    = d['maps_url']?.toString()    ?? "";
        });

        if (crashAlert && currentUnixTime != _lastAlertedUnixTime && currentUnixTime > 0) {
          _lastAlertedUnixTime = currentUnixTime;
          _showCrashDialog(d);
          _sendCrashSms(d); // Send SMS automatically
        }
      } catch (e) {
        debugPrint("❌ Crash parse error: $e");
      }
    });
  }

  void _resetDisconnectTimer() {
    _disconnectTimer?.cancel();
    _disconnectTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => isConnected = false);
    });
  }

  // ══════════════════════════════════════════════════════════
  //  CLOUD SMS VIA FAST2SMS API (FIXED)
  // ══════════════════════════════════════════════════════════
  Future<bool> _sendCloudSms(String message, String phone) async {
    String cleanPhone = phone.replaceAll('+91', '').replaceAll(' ', '');

    debugPrint("📱 Cloud SMS: Sending to $cleanPhone...");
    debugPrint("📱 Message: $message");

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

      debugPrint("📱 Fast2SMS Response [${response.statusCode}]: ${response.body}");

      if (response.statusCode == 200) {
        debugPrint("✅ Cloud SMS sent successfully to $cleanPhone");
        return true;
      } else {
        debugPrint("❌ Fast2SMS Error [${response.statusCode}]: ${response.body}");
        return false;
      }
    } catch (e) {
      debugPrint("❌ Cloud SMS Exception: $e");
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════
  //  SEND CRASH SMS (FIXED with feedback)
  // ══════════════════════════════════════════════════════════
  Future<void> _sendCrashSms(Map<String, dynamic> crashData) async {
    if (_smsSending) return; // Prevent duplicate sends

    setState(() {
      _smsSending = true;
      _smsSent = false;
      _smsStatus = "Sending emergency SMS...";
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      String? emergencyNumber = prefs.getString('emergencyContact');

      if (emergencyNumber == null || emergencyNumber.isEmpty) {
        debugPrint("❌ No emergency contact set in SharedPreferences!");
        debugPrint("❌ Key 'emergencyContact' = ${prefs.getString('emergencyContact')}");
        if (mounted) {
          setState(() => _smsStatus = "❌ No emergency contact set!");
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("No emergency contact set! Go to profile to add one."),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
        }
        setState(() => _smsSending = false);
        return;
      }

      if (!emergencyNumber.startsWith('+')) {
        emergencyNumber = '+91$emergencyNumber';
      }

      debugPrint("📱 Emergency number: $emergencyNumber");

      final String timestamp = crashData['timestamp']?.toString() ?? "Unknown time";
      final String source = crashData['trigger_source']?.toString() ?? "Unknown";
      final String mapsUrl = crashData['maps_url']?.toString() ?? "";
      final String accel = crashData['acceleration']?.toString() ?? "N/A";

      String message = "CRASH DETECTED!\n"
          "Time: $timestamp\n"
          "Source: $source\n"
          "Impact: ${accel} m/s2\n"
          "Location: $mapsUrl";

      debugPrint("📱 Sending crash SMS...");

      // ── ATTEMPT 1: Cloud SMS (Fully Automatic) ─────────────
      bool cloudSuccess = await _sendCloudSms(message, emergencyNumber);

      if (cloudSuccess) {
        debugPrint("✅ Emergency SMS sent via cloud!");
        if (mounted) {
          setState(() {
            _smsSent = true;
            _smsStatus = "✅ Emergency SMS sent!";
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Emergency SMS sent to $emergencyNumber"),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } else {
        // ── ATTEMPT 2: Fallback to SMS App ───────────────────
        debugPrint("⚠️ Cloud SMS failed. Opening SMS app as fallback.");
        if (mounted) {
          setState(() => _smsStatus = "⚠️ Cloud failed. Opening SMS app...");
        }

        final Uri smsUri = Uri(
          scheme: 'sms',
          path: emergencyNumber,
          queryParameters: {'body': message},
        );

        bool canOpen = await canLaunchUrl(smsUri);
        debugPrint("📱 Can launch SMS app: $canOpen");

        if (canOpen) {
          await launchUrl(smsUri);
          if (mounted) {
            setState(() => _smsStatus = "📱 SMS app opened - Please press SEND");
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("SMS app opened. Please press SEND to deliver the message."),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 6),
              ),
            );
          }
        } else {
          debugPrint("❌ Cannot open SMS app either!");
          if (mounted) {
            setState(() => _smsStatus = "❌ Failed to send SMS");
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Could not send SMS. Check your SMS permissions."),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 5),
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint("❌ SMS Error: $e");
      if (mounted) {
        setState(() => _smsStatus = "❌ Error: $e");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("SMS Error: $e"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }

    setState(() => _smsSending = false);
  }

  // ── Crash dialog ───────────────────────────────────────────
  void _showCrashDialog(Map<String, dynamic> d) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Colors.red[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.white, size: 32),
                SizedBox(width: 8),
                Text("CRASH DETECTED",
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 20)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dialogRow("Time",      d['timestamp']?.toString()       ?? "—"),
                _dialogRow("Source",    d['trigger_source']?.toString()  ?? "—"),
                _dialogRow("Accel",     "${d['acceleration'] ?? '—'} m/s²"),
                _dialogRow("Gyro",      "${d['gyroscope'] ?? '—'} °/s"),
                _dialogRow("Vibration", (_parseBool(d['vibration']) == true) ? "YES" : "no"),
                _dialogRow("Location",  d['gps']?.toString() ?? "No GPS"),
                if ((d['maps_url']?.toString() ?? "").isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      d['maps_url'].toString(),
                      style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),

                // SMS Status indicator
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _smsSent
                        ? Colors.green.withOpacity(0.2)
                        : _smsSending
                        ? Colors.orange.withOpacity(0.2)
                        : Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _smsSent
                          ? Colors.green
                          : _smsSending
                          ? Colors.orange
                          : Colors.white24,
                    ),
                  ),
                  child: Row(
                    children: [
                      if (_smsSending && !_smsSent)
                        const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                            color: Colors.orange, strokeWidth: 2,
                          ),
                        )
                      else
                        Icon(
                          _smsSent ? Icons.check_circle : Icons.sms,
                          color: _smsSent ? Colors.green : Colors.orange,
                          size: 16,
                        ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _smsStatus.isEmpty
                              ? "Sending emergency SMS..."
                              : _smsStatus,
                          style: TextStyle(
                            color: _smsSent ? Colors.green : Colors.orange,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Manual retry button
                if (!_smsSending && !_smsSent)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton.icon(
                      onPressed: () => _sendCrashSms(d),
                      icon: const Icon(Icons.refresh, color: Colors.white70, size: 16),
                      label: const Text("Retry SMS",
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("DISMISS",
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _dialogRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Text("$label: ",
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
        Expanded(
          child: Text(value,
              style: const TextStyle(color: Colors.white),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _disconnectTimer?.cancel();
    _sensorsSub?.cancel();
    _crashSub?.cancel();
    _phoneGpsStream?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════
  //  BUILD
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
            AnimatedBuilder(
              animation: _pulseAnim,
              builder: (_, child) => Opacity(
                opacity: isConnected ? _pulseAnim.value : 1.0,
                child: child,
              ),
              child: Icon(Icons.sports_motorsports,
                  color: isConnected ? Colors.greenAccent : Colors.redAccent,
                  size: 26),
            ),
            const SizedBox(width: 10),
            const Text("Connection - ",
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          if (crashBufferActive)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text("BUFFERING",
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 10,
                      fontWeight: FontWeight.bold)),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Icon(isConnected ? Icons.wifi : Icons.wifi_off,
                    color: isConnected ? Colors.greenAccent : Colors.redAccent,
                    size: 20),
                const SizedBox(width: 4),
                Text(
                  isConnected ? "Live" : "Offline",
                  style: TextStyle(
                      color: isConnected ? Colors.greenAccent : Colors.redAccent,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildCrashCard(),
            const SizedBox(height: 12),
            _buildTriggerStatusRow(),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.1,
              children: [
                _buildSensorCard(
                  "Acceleration",
                  acceleration.toStringAsFixed(2),
                  "m/s²",
                  Icons.speed,
                  Colors.blueAccent,
                  sub: "Δ ${accelDelta.toStringAsFixed(2)}",
                ),
                _buildSensorCard(
                  "Gyroscope",
                  gyroscope.toStringAsFixed(2),
                  "°/s",
                  Icons.rotate_right,
                  Colors.purpleAccent,
                  sub: "Δ ${gyroDelta.toStringAsFixed(2)}",
                ),
                _buildSensorCard(
                  "Distance",
                  distanceCm.toStringAsFixed(1),
                  "cm",
                  Icons.straighten,
                  Colors.orangeAccent,
                ),
                _buildSensorCard(
                  "Vibration",
                  vibrationRaw ? "ACTIVE" : "None",
                  "",
                  Icons.vibration,
                  vibrationRaw ? Colors.redAccent : Colors.greenAccent,
                  sub: vibrationTriggered ? "⚠ Triggered" : "Normal",
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildGpsCard(),
          ],
        ),
      ),
    );
  }

  // ── Crash card ─────────────────────────────────────────────
  Widget _buildCrashCard() {
    final bool showCrash = crashAlert || sensorsTriggered;

    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, child) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: showCrash
              ? Colors.red.withOpacity(0.15 * _pulseAnim.value + 0.05)
              : Colors.green.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: showCrash
                  ? Colors.redAccent.withOpacity(0.6 + 0.4 * _pulseAnim.value)
                  : Colors.greenAccent.withOpacity(0.4),
              width: showCrash ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(
              showCrash ? Icons.warning_amber_rounded : Icons.check_circle_outline,
              color: showCrash ? Colors.redAccent : Colors.greenAccent,
              size: 44,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    showCrash ? "CRASH DETECTED!" : "All Clear",
                    style: TextStyle(
                        color: showCrash ? Colors.redAccent : Colors.greenAccent,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                  Text(
                    showCrash
                        ? (crashTriggerSrc.isNotEmpty
                        ? "Source: $crashTriggerSrc"
                        : "Emergency alert triggered")
                        : "No crash detected",
                    style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  ),
                  if (showCrash && crashTimestamp.isNotEmpty)
                    Text(crashTimestamp,
                        style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Trigger status row ─────────────────────────────────────
  Widget _buildTriggerStatusRow() {
    return Row(
      children: [
        _buildTriggerBadge("IMU",   imuTriggered,       Icons.sensors),
        const SizedBox(width: 8),
        _buildTriggerBadge("VIB",   vibrationTriggered, Icons.vibration),
        const SizedBox(width: 8),
        _buildTriggerBadge("ULTRA", ultraTriggered,     Icons.radar),
        const SizedBox(width: 8),
        _buildTriggerBadge("CRASH", sensorsTriggered,   Icons.crisis_alert),
      ],
    );
  }

  Widget _buildTriggerBadge(String label, bool active, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.redAccent.withOpacity(0.18) : const Color(0xFF141420),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: active ? Colors.redAccent.withOpacity(0.7) : Colors.white12),
        ),
        child: Column(
          children: [
            Icon(icon, color: active ? Colors.redAccent : Colors.grey[600], size: 18),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    color: active ? Colors.redAccent : Colors.grey[600],
                    fontSize: 10,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  // ── Sensor card ────────────────────────────────────────────
  Widget _buildSensorCard(String title, String value, String unit, IconData icon,
      Color color, {String? sub}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 6),
          Text(title,
              style: TextStyle(color: Colors.grey[400], fontSize: 11),
              textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
          if (unit.isNotEmpty)
            Text(unit, style: TextStyle(color: Colors.grey[600], fontSize: 10)),
          if (sub != null)
            Text(sub, style: TextStyle(color: Colors.grey[500], fontSize: 10)),
        ],
      ),
    );
  }

  // ── GPS card — phone GPS only ──────────────────────────────
  Widget _buildGpsCard() {
    final hasGps = _phoneGpsReady && _phoneLat != 0.0;
    final String displayCoords = hasGps
        ? "Lat: ${_phoneLat.toStringAsFixed(6)}, Lon: ${_phoneLon.toStringAsFixed(6)}"
        : "Acquiring GPS...";

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: hasGps ? Colors.tealAccent.withOpacity(0.3) : Colors.white12),
      ),
      child: Row(
        children: [
          Icon(Icons.location_on,
              color: hasGps ? Colors.tealAccent : Colors.grey, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("GPS Location",
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                Text(displayCoords,
                    style: TextStyle(
                        color: hasGps ? Colors.tealAccent : Colors.grey[600],
                        fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
