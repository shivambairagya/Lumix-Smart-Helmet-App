import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';

class NavigationPage extends StatefulWidget {
  const NavigationPage({super.key});

  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage> {
  GoogleMapController? mapController;
  final TextEditingController destinationController = TextEditingController();

  final DatabaseReference _helmetRef =
  FirebaseDatabase.instance.ref('helmet/nav');

  static const String googleApiKey = "AIzaSyCJIVcJzMRzBcEBqIXQzdHN0TKJ9N3hKb8";

  LatLng? currentLocation;
  LatLng? destination;
  Set<Marker>   markers   = {};
  Set<Polyline> polylines = {};
  List<LatLng>  currentRoutePoints = [];
  static const double offRouteThreshold = 50.0;

  List<Map<String, dynamic>> navigationSteps = [];
  int  currentStepIndex     = 0;

  bool    isNavigating    = false;
  bool    showStartButton = false;
  bool    isSearching     = false;
  bool    isNightMode     = false;
  bool    isMuted         = false;
  String? legDistance;
  String? legDuration;
  int?    legDurationSeconds;
  String  currentInstruction = "";
  String  currentDistance    = "";
  String  currentSpeed       = "0";
  String  remainingDistance  = "";
  String  remainingTimeString = "";
  String  estimatedArrivalTime = "";

  double _lastHeading = 0.0;

  DateTime? _lastRecalcTime;
  static const Duration _recalcCooldown = Duration(seconds: 15);
  bool _isRecalculating = false;

  DateTime? _lastSyncTime;
  static const Duration _syncInterval = Duration(seconds: 3);

  FlutterTts flutterTts = FlutterTts();
  bool isSpeaking = false;
  StreamSubscription<Position>? positionStream;
  List<String> favoriteDestinations = [];

  // ── NEW: Custom Navigation Arrow Icon ────────────────
  BitmapDescriptor? _navArrowIcon;

  static const String nightMapStyle = '''[
    {"elementType":"geometry","stylers":[{"color":"#242f3e"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#746855"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#242f3e"}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#38414e"}]},
    {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#212a37"}]},
    {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#9ca5b3"}]},
    {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#746855"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#17263c"}]}
  ]''';

  @override
  void initState() {
    super.initState();
    _createNavArrowIcon(); // Generate the arrow icon
    _getUserLocation();
    _initTts();
    _loadFavorites();
  }

  // ═══════════════════════════════════════════════════
  //  NEW: GENERATE CUSTOM ROTATING ARROW MARKER
  // ═══════════════════════════════════════════════════
  Future<void> _createNavArrowIcon() async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 80.0;

    // Shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final shadowPath = Path()
      ..moveTo(size / 2, 6)
      ..lineTo(size + 2, size + 6)
      ..lineTo(size / 2, size * 0.75 + 6)
      ..lineTo(-2, size + 6)
      ..close();
    canvas.drawPath(shadowPath, shadowPaint);

    // Blue Arrow Body
    final arrowPaint = Paint()..color = const Color(0xFF4285F4); // Google Blue
    final arrowPath = Path()
      ..moveTo(size / 2, 0)         // Tip
      ..lineTo(size, size)          // Bottom Right
      ..lineTo(size / 2, size * 0.75) // Inner notch
      ..lineTo(0, size)            // Bottom Left
      ..close();
    canvas.drawPath(arrowPath, arrowPaint);

    // White Border
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawPath(arrowPath, borderPaint);

    // White center dot
    final dotPaint = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(size / 2, size / 2), 6, dotPaint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ImageByteFormat.png);

    if (byteData != null && mounted) {
      setState(() {
        _navArrowIcon = BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
      });
    }
  }

  @override
  void dispose() {
    positionStream?.cancel();
    flutterTts.stop();
    destinationController.dispose();
    _helmetRef.update({'active': false});
    super.dispose();
  }

  // ═══════════════════════════════════════════════════
  //   HELMET SYNC
  // ═══════════════════════════════════════════════════
  Future<void> _syncToHelmet() async {
    final now = DateTime.now();
    if (_lastSyncTime != null &&
        now.difference(_lastSyncTime!) < _syncInterval) {
      return;
    }
    _lastSyncTime = now;

    try {
      List<Map<String, double>> routeCompact = [];
      if (currentRoutePoints.isNotEmpty) {
        int step = max(1, currentRoutePoints.length ~/ 200);
        for (int i = 0; i < currentRoutePoints.length; i += step) {
          routeCompact.add({
            'lat': currentRoutePoints[i].latitude,
            'lon': currentRoutePoints[i].longitude,
          });
        }
        routeCompact.add({
          'lat': currentRoutePoints.last.latitude,
          'lon': currentRoutePoints.last.longitude,
        });
      }

      String maneuver = 'straight';
      String nextManeuver = 'straight';
      String nextInstruction = '';
      String nextDistance = '';

      if (navigationSteps.isNotEmpty &&
          currentStepIndex < navigationSteps.length) {
        final step = navigationSteps[currentStepIndex];
        maneuver = step['maneuver'] ?? 'straight';
        if (currentStepIndex + 1 < navigationSteps.length) {
          final next = navigationSteps[currentStepIndex + 1];
          nextManeuver    = next['maneuver']    ?? 'straight';
          nextInstruction = next['instruction'] ?? '';
          nextDistance    = next['distance']    ?? '';
        }
      }

      await _helmetRef.set({
        'active': isNavigating,
        'ts':     ServerValue.timestamp,
        'lat':     currentLocation?.latitude  ?? 0,
        'lon':     currentLocation?.longitude ?? 0,
        'heading': _lastHeading,
        'speed':   double.tryParse(currentSpeed) ?? 0,
        'dest_lat':  destination?.latitude  ?? 0,
        'dest_lon':  destination?.longitude ?? 0,
        'dest_name': destinationController.text,
        'instruction':   currentInstruction,
        'step_distance': currentDistance,
        'remaining':     remainingDistance,
        'maneuver':      maneuver,
        'next_maneuver':    nextManeuver,
        'next_instruction': nextInstruction,
        'next_distance':    nextDistance,
        'leg_distance': legDistance ?? '',
        'leg_duration': legDuration ?? '',
        'route': routeCompact,
      });
    } catch (e) {
      debugPrint('Helmet sync error: $e');
    }
  }

  Future<void> _syncDestinationPreview() async {
    try {
      await _helmetRef.set({
        'active':    false,
        'dest_name': destinationController.text,
        'dest_lat':  destination?.latitude  ?? 0,
        'dest_lon':  destination?.longitude ?? 0,
        'lat':       currentLocation?.latitude  ?? 0,
        'lon':       currentLocation?.longitude ?? 0,
        'leg_distance': legDistance ?? '',
        'leg_duration': legDuration ?? '',
        'route': [],
      });
    } catch (e) {
      debugPrint('Helmet destination sync error: $e');
    }
  }

  // ═══════════════════════════════════════════════════
  //   LOCATION & TTS
  // ═══════════════════════════════════════════════════

  Future<void> _getUserLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) _showSnackBar("Location services are disabled.");
        return;
      }
      LocationPermission permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) _showSnackBar("Location permissions denied.");
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        forceAndroidLocationManager: true,
      );

      if (mounted) {
        setState(() {
          currentLocation = LatLng(position.latitude, position.longitude);
          markers.add(Marker(
            markerId:   const MarkerId('currentLocation'),
            position:   currentLocation!,
            // Use custom arrow icon, fallback to default if not loaded yet
            icon:       _navArrowIcon ?? BitmapDescriptor.defaultMarker,
            rotation:   position.heading, // Rotate to initial heading
            anchor:     const Offset(0.5, 0.5), // Anchor in center so it spins in place
            infoWindow: const InfoWindow(title: "You are here"),
          ));
        });
        mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(currentLocation!, 16),
        );
      }
    } catch (e) {
      if (mounted) _showSnackBar("Failed to get location: ${e.toString()}");
    }
  }

  Future<void> _initTts() async {
    try {
      await flutterTts.setLanguage("en-US");
      await flutterTts.setSpeechRate(0.5);
      await flutterTts.setVolume(1.0);
      flutterTts.setCompletionHandler(() {
        if (mounted) setState(() => isSpeaking = false);
      });
    } catch (e) {
      debugPrint("TTS init error: $e");
    }
  }

  Future<void> _toggleNightMode() async {
    setState(() => isNightMode = !isNightMode);
    if (isNightMode) {
      await mapController?.setMapStyle(nightMapStyle);
    } else {
      await mapController?.setMapStyle(null);
    }
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        favoriteDestinations = prefs.getStringList('favorites') ?? [];
      });
    }
  }

  Future<void> _addFavorite() async {
    if (destinationController.text.isEmpty) {
      _showSnackBar("Enter a destination to save.");
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!favoriteDestinations.contains(destinationController.text)) {
      favoriteDestinations.add(destinationController.text);
      await prefs.setStringList('favorites', favoriteDestinations);
      _showSnackBar("Saved to favorites!");
    } else {
      _showSnackBar("Already in favorites.");
    }
  }

  void _showFavorites() {
    if (favoriteDestinations.isEmpty) {
      _showSnackBar("No favorites saved.");
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text("Favourite Places",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: favoriteDestinations.length,
                itemBuilder: (context, index) {
                  final dest = favoriteDestinations[index];
                  return ListTile(
                    leading: const Icon(Icons.star, color: Colors.amber),
                    title: Text(dest,
                        style: const TextStyle(color: Colors.white)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                      onPressed: () async {
                        favoriteDestinations.removeAt(index);
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setStringList('favorites', favoriteDestinations);
                        if (mounted) setState(() {});
                      },
                    ),
                    onTap: () {
                      destinationController.text = dest;
                      Navigator.pop(context);
                      _setDestination();
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════
  //   DESTINATION & ROUTING
  // ═══════════════════════════════════════════════════

  Future<void> _setDestination() async {
    if (destinationController.text.isEmpty) {
      _showSnackBar("Please enter a destination.");
      return;
    }
    if (currentLocation == null) {
      _showSnackBar("Current location not yet available.");
      return;
    }
    _cancelNavigation();
    setState(() {
      isSearching     = true;
      showStartButton = false;
      polylines.clear();
      markers.removeWhere((m) => m.markerId.value == 'destination');
      legDistance = null;
      legDuration = null;
    });

    try {
      final geoUrl =
          "https://maps.googleapis.com/maps/api/geocode/json"
          "?address=${Uri.encodeComponent(destinationController.text)}"
          "&key=$googleApiKey";
      final geoResponse = await http.get(Uri.parse(geoUrl));
      final geoData     = jsonDecode(geoResponse.body);

      if (geoData['status'] == 'OK' && geoData['results'].isNotEmpty) {
        double lat = geoData['results'][0]['geometry']['location']['lat'];
        double lng = geoData['results'][0]['geometry']['location']['lng'];
        destination = LatLng(lat, lng);

        final directionsUrl =
            "https://maps.googleapis.com/maps/api/directions/json"
            "?origin=${currentLocation!.latitude},${currentLocation!.longitude}"
            "&destination=${destination!.latitude},${destination!.longitude}"
            "&key=$googleApiKey";
        final directionsResponse = await http.get(Uri.parse(directionsUrl));
        final directionsData     = jsonDecode(directionsResponse.body);

        if (directionsData['routes'].isNotEmpty) {
          final leg = directionsData['routes'][0]['legs'][0];
          if (mounted) {
            setState(() {
              legDistance         = leg['distance']['text'];
              legDuration         = leg['duration']['text'];
              legDurationSeconds  = leg['duration']['value'];
              showStartButton     = true;
              markers.add(Marker(
                markerId:   const MarkerId('destination'),
                position:   destination!,
                infoWindow: InfoWindow(title: destinationController.text),
              ));
            });
          }
          mapController?.animateCamera(CameraUpdate.newLatLngBounds(
              _bounds(currentLocation!, destination!), 80.0));

          await _syncDestinationPreview();
        } else {
          _showSnackBar("Could not calculate route.");
        }
      } else {
        _showSnackBar("Destination not found.");
      }
    } catch (e) {
      _showSnackBar("Error: ${e.toString()}");
    } finally {
      if (mounted) setState(() => isSearching = false);
    }
  }

  Future<void> _startNavigation({bool isRecalculation = false}) async {
    if (currentLocation == null || destination == null) return;
    if (_isRecalculating) return;

    setState(() {
      isNavigating         = true;
      showStartButton      = false;
      currentStepIndex     = 0;
      navigationSteps      = [];
      remainingDistance    = "";
      remainingTimeString  = "";
      estimatedArrivalTime = "";
      polylines.clear();
    });

    if (isRecalculation) {
      _isRecalculating = true;
      await _speak("Off route. Recalculating.");
    } else {
      await _speak("Starting navigation to ${destinationController.text}");
    }

    try {
      final polylinePoints = PolylinePoints(apiKey: googleApiKey);
      final result = await polylinePoints.getRouteBetweenCoordinates(
        request: PolylineRequest(
          origin: PointLatLng(
              currentLocation!.latitude, currentLocation!.longitude),
          destination: PointLatLng(
              destination!.latitude, destination!.longitude),
          mode: TravelMode.driving,
        ),
      );

      if (result.points.isNotEmpty) {
        currentRoutePoints = result.points
            .map((e) => LatLng(e.latitude, e.longitude))
            .toList();
        if (mounted) {
          setState(() {
            polylines.clear();
            polylines.add(Polyline(
              polylineId: const PolylineId('route'),
              points:     currentRoutePoints,
              color:      Colors.blue,
              width:      5,
            ));
          });
        }
      }

      await _fetchAndStoreSteps();
      _startLocationStream();

      _lastSyncTime = null;
      await _syncToHelmet();

    } catch (e) {
      _showSnackBar("Error getting route: ${e.toString()}");
      if (mounted) setState(() => isNavigating = false);
    } finally {
      _isRecalculating = false;
    }
  }

  Future<void> _fetchAndStoreSteps() async {
    try {
      final directionsUrl =
          "https://maps.googleapis.com/maps/api/directions/json"
          "?origin=${currentLocation!.latitude},${currentLocation!.longitude}"
          "&destination=${destination!.latitude},${destination!.longitude}"
          "&key=$googleApiKey";
      final response = await http.get(Uri.parse(directionsUrl));
      final data     = jsonDecode(response.body);

      if (data['routes'].isNotEmpty) {
        final steps = data['routes'][0]['legs'][0]['steps'];
        navigationSteps = steps.map<Map<String, dynamic>>((step) {
          return {
            'instruction': step['html_instructions']
                .replaceAll(RegExp(r'<[^>]*>'), ''),
            'distance': step['distance']['text'],
            'meters':   step['distance']['value'],
            'duration': step['duration']['text'],
            'duration_seconds': step['duration']['value'],
            'maneuver': step['maneuver'] ?? 'straight',
            'end_lat':  step['end_location']['lat'],
            'end_lng':  step['end_location']['lng'],
            'spoken':   false,
          };
        }).toList();

        _updateRemainingDistance();
        if (navigationSteps.isNotEmpty) _updateCurrentInstruction(0);
      }
    } catch (e) {
      debugPrint("Error fetching steps: $e");
    }
  }

  void _updateRemainingDistance() {
    if (navigationSteps.isEmpty) return;
    int totalMeters  = 0;
    int totalSeconds = 0;
    for (int i = currentStepIndex; i < navigationSteps.length; i++) {
      totalMeters  += (navigationSteps[i]['meters'] as int);
      totalSeconds += (navigationSteps[i]['duration_seconds'] as int);
    }

    String remaining = totalMeters >= 1000
        ? "${(totalMeters / 1000).toStringAsFixed(1)} km"
        : "$totalMeters m";

    int hours   = totalSeconds ~/ 3600;
    int minutes = (totalSeconds % 3600) ~/ 60;
    String timeStr = hours > 0 ? "${hours}h ${minutes}m" : "${minutes} min";

    final eta   = DateTime.now().add(Duration(seconds: totalSeconds));
    int hour12  = eta.hour % 12;
    if (hour12 == 0) hour12 = 12;
    String amPm = eta.hour >= 12 ? "PM" : "AM";
    String etaStr = "${hour12}:${eta.minute.toString().padLeft(2, '0')} $amPm";

    if (mounted) {
      setState(() {
        remainingDistance    = remaining;
        remainingTimeString  = timeStr;
        estimatedArrivalTime = etaStr;
      });
    }
  }

  void _updateCurrentInstruction(int stepIndex) {
    if (stepIndex >= navigationSteps.length) return;
    final step = navigationSteps[stepIndex];
    if (mounted) {
      setState(() {
        currentInstruction = step['instruction'];
        currentDistance    = step['distance'];
      });
    }
  }

  // ═══════════════════════════════════════════════════
  //   LIVE LOCATION STREAM
  // ═══════════════════════════════════════════════════

  void _startLocationStream() {
    positionStream?.cancel();
    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((Position position) {
      if (!isNavigating) return;

      currentLocation = LatLng(position.latitude, position.longitude);
      _lastHeading    = position.heading;

      double speedKmh = position.speed * 3.6;
      if (speedKmh < 0) speedKmh = 0;

      if (mounted) {
        setState(() {
          currentSpeed = speedKmh.toStringAsFixed(0);
          markers.removeWhere((m) => m.markerId.value == 'currentLocation');
          // ── NEW: Add marker with rotation based on phone heading ──
          markers.add(Marker(
            markerId:   const MarkerId('currentLocation'),
            position:   currentLocation!,
            icon:       _navArrowIcon ?? BitmapDescriptor.defaultMarker,
            rotation:   position.heading, // Rotates the arrow!
            anchor:     const Offset(0.5, 0.5), // Keeps arrow centered
            zIndex:     10, // Ensures it stays above the route line
            infoWindow: const InfoWindow(title: "You"),
          ));
        });

        mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target:  currentLocation!,
              zoom:    18,
              bearing: position.heading, // Map rotates so heading is UP
              tilt:    45,
            ),
          ),
        );
      }

      _checkArrival(currentLocation!);
      _checkStepProgress(currentLocation!);
      _checkIfOffRoute(currentLocation!);

      _syncToHelmet();
    });
  }

  void _checkArrival(LatLng userLocation) {
    if (destination == null) return;
    double distToDest = _distanceBetween(userLocation, destination!);
    if (distToDest < 20) {
      _speak("You have arrived at your destination!");
      _cancelNavigation();
    }
  }

  void _checkStepProgress(LatLng userLocation) {
    if (navigationSteps.isEmpty) return;
    if (currentStepIndex >= navigationSteps.length) return;

    final step    = navigationSteps[currentStepIndex];
    final stepEnd = LatLng(step['end_lat'], step['end_lng']);
    double distToStepEnd = _distanceBetween(userLocation, stepEnd);

    if (distToStepEnd < 30) {
      if (!step['spoken']) {
        navigationSteps[currentStepIndex]['spoken'] = true;
        int nextStep = currentStepIndex + 1;
        if (nextStep < navigationSteps.length) {
          final next = navigationSteps[nextStep];
          _speak("In ${next['distance']}, ${next['instruction']}");
          currentStepIndex = nextStep;
          _updateCurrentInstruction(nextStep);
          _updateRemainingDistance();
          _lastSyncTime = null;
          _syncToHelmet();
        }
      }
    } else if (distToStepEnd < 200 && !step['spoken']) {
      if (step['maneuver'] != 'straight' && step['maneuver'] != '') {
        _speak("In ${step['distance']}, ${step['instruction']}");
        navigationSteps[currentStepIndex]['spoken'] = true;
      }
    }
  }

  double _distanceBetween(LatLng a, LatLng b) {
    const R    = 6371000.0;
    final lat1 = a.latitude  * pi / 180;
    final lat2 = b.latitude  * pi / 180;
    final dLat = (b.latitude  - a.latitude)  * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final x    = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(x), sqrt(1 - x));
    return R * c;
  }

  void _checkIfOffRoute(LatLng userLocation) {
    if (currentRoutePoints.isEmpty) return;

    final now = DateTime.now();
    if (_lastRecalcTime != null &&
        now.difference(_lastRecalcTime!) < _recalcCooldown) {
      return;
    }
    if (_isRecalculating) return;

    double minDist = double.infinity;
    for (int i = 0; i < currentRoutePoints.length - 1; i++) {
      final a = currentRoutePoints[i];
      final b = currentRoutePoints[i + 1];
      final d = _distancePointToSegmentMeters(userLocation, a, b);
      if (d < minDist) minDist = d;
    }

    if (minDist > offRouteThreshold) {
      _lastRecalcTime = now;
      positionStream?.cancel();
      flutterTts.stop();
      if (mounted) setState(() => isNavigating = false);
      _startNavigation(isRecalculation: true);
    }
  }

  double _degToRad(double deg) => deg * pi / 180.0;

  Offset _latLngToXY(LatLng p, double refLatRad) {
    const R = 6371000.0;
    final x = R * _degToRad(p.longitude) * cos(refLatRad);
    final y = R * _degToRad(p.latitude);
    return Offset(x, y);
  }

  double _distancePointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    final refLatRad = _degToRad((a.latitude + b.latitude) / 2.0);
    final pXY  = _latLngToXY(p, refLatRad);
    final aXY  = _latLngToXY(a, refLatRad);
    final bXY  = _latLngToXY(b, refLatRad);
    final vx   = bXY.dx - aXY.dx;
    final vy   = bXY.dy - aXY.dy;
    final wx   = pXY.dx - aXY.dx;
    final wy   = pXY.dy - aXY.dy;
    final vLen2 = vx * vx + vy * vy;
    if (vLen2 == 0) return sqrt(wx * wx + wy * wy);
    double t = (wx * vx + wy * vy) / vLen2;
    t = t.clamp(0.0, 1.0);
    final closestX = aXY.dx + t * vx;
    final closestY = aXY.dy + t * vy;
    return sqrt(pow(pXY.dx - closestX, 2) + pow(pXY.dy - closestY, 2));
  }

  IconData _getArrowIcon(String maneuver) {
    if (maneuver.contains('right'))    return Icons.turn_right;
    if (maneuver.contains('left'))     return Icons.turn_left;
    if (maneuver.contains('uturn'))    return Icons.u_turn_left;
    if (maneuver.contains('straight')) return Icons.straight;
    return Icons.navigation;
  }

  void _cancelNavigation() {
    positionStream?.cancel();
    flutterTts.stop();
    if (mounted) {
      setState(() {
        isNavigating          = false;
        isSpeaking            = false;
        polylines.clear();
        currentRoutePoints    = [];
        navigationSteps       = [];
        currentStepIndex      = 0;
        currentInstruction    = "";
        currentDistance       = "";
        currentSpeed          = "0";
        remainingDistance     = "";
        remainingTimeString   = "";
        estimatedArrivalTime  = "";
        if (destination != null) showStartButton = true;
      });
    }
    _helmetRef.update({'active': false, 'instruction': '', 'remaining': ''});
  }

  Future<void> _speak(String text) async {
    if (isMuted) return;
    if (mounted) setState(() => isSpeaking = true);
    await flutterTts.speak(text);
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  LatLngBounds _bounds(LatLng s, LatLng d) {
    return LatLngBounds(
      southwest: LatLng(
          min(s.latitude, d.latitude), min(s.longitude, d.longitude)),
      northeast: LatLng(
          max(s.latitude, d.latitude), max(s.longitude, d.longitude)),
    );
  }

  // ═══════════════════════════════════════════════════
  //   UI
  // ═══════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: currentLocation == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
        children: [
          GoogleMap(
            onMapCreated: (controller) {
              mapController = controller;
              if (currentLocation != null) {
                mapController?.animateCamera(
                  CameraUpdate.newLatLngZoom(currentLocation!, 16),
                );
              }
            },
            initialCameraPosition: CameraPosition(
              target: currentLocation ?? const LatLng(0, 0),
              zoom:   16,
            ),
            markers:                 markers,
            polylines:               polylines,
            // ── DISABLE default blue dot so it doesn't overlap arrow ──
            myLocationEnabled:       false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled:     false,
          ),

          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            top: isNavigating ? -100 : 50,
            left: 16, right: 16,
            child: _buildSearchBar(),
          ),

          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            top: isNavigating ? -200 : 120,
            right: 16,
            child: _buildMapButtons(),
          ),

          if (isNavigating)
            Positioned(
              top: 50, left: 16, right: 16,
              child: _buildTopNavBanner(),
            ),

          if (isNavigating)
            Positioned(
              bottom: 130, left: 16,
              child: _buildSpeedWidget(),
            ),

          if (showStartButton && !isNavigating)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: _buildRouteInfoCard(),
            ),

          if (isNavigating)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: _buildBottomStatsBar(),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.95),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              const SizedBox(width: 16),
              const Icon(Icons.search, color: Colors.blue, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: destinationController,
                  decoration: const InputDecoration(
                    hintText: "Where to?",
                    hintStyle: TextStyle(color: Colors.grey, fontSize: 16),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 16),
                  ),
                  style: const TextStyle(fontSize: 16),
                  onSubmitted: (_) => _setDestination(),
                ),
              ),
              if (isSearching)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else ...[
                IconButton(
                  icon: const Icon(Icons.star_border,
                      color: Colors.amber, size: 22),
                  onPressed: _showFavorites,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios,
                      color: Colors.blue, size: 18),
                  onPressed: _setDestination,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapButtons() {
    return Column(
      children: [
        _mapButton(
          icon: isNightMode ? Icons.wb_sunny : Icons.nightlight_round,
          color: isNightMode ? Colors.orange : Colors.indigo,
          onTap: _toggleNightMode,
        ),
        const SizedBox(height: 8),
        _mapButton(
          icon: isMuted ? Icons.volume_off : Icons.volume_up,
          color: isMuted ? Colors.red : Colors.green,
          onTap: () {
            setState(() => isMuted = !isMuted);
            if (isMuted) {
              flutterTts.stop();
              _showSnackBar("Voice guidance muted");
            } else {
              _showSnackBar("Voice guidance enabled");
            }
          },
        ),
        const SizedBox(height: 8),
        _mapButton(
          icon: Icons.my_location,
          color: Colors.blue,
          onTap: () {
            if (currentLocation != null) {
              mapController?.animateCamera(
                CameraUpdate.newLatLngZoom(currentLocation!, 16),
              );
            }
          },
        ),
        const SizedBox(height: 8),
        _mapButton(
          icon: Icons.favorite_border,
          color: Colors.pink,
          onTap: _addFavorite,
        ),
      ],
    );
  }

  Widget _mapButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }

  Widget _buildSpeedWidget() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            currentSpeed,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Text("km/h",
              style: TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildRouteInfoCard() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 20,
            offset: Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.location_on, color: Colors.red, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  destinationController.text,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildInfoTile(
                  Icons.directions_car,
                  legDistance ?? "--",
                  "Distance",
                  Colors.blue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInfoTile(
                  Icons.access_time,
                  legDuration ?? "--",
                  "Duration",
                  Colors.orange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: () => _startNavigation(isRecalculation: false),
              icon:  const Icon(Icons.navigation, color: Colors.white),
              label: const Text(
                "Start Navigation",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTile(
      IconData icon, String value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: TextStyle(
                      color: color,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
              Text(label,
                  style: TextStyle(
                      color: Colors.grey[600], fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTopNavBanner() {
    String maneuver = '';
    if (navigationSteps.isNotEmpty &&
        currentStepIndex < navigationSteps.length) {
      maneuver = navigationSteps[currentStepIndex]['maneuver'] ?? '';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.blue[800],
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _getArrowIcon(maneuver),
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currentDistance.isNotEmpty ? currentDistance : "--",
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  currentInstruction.isEmpty
                      ? "Calculating..."
                      : currentInstruction,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomStatsBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 20,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navStatItem(Icons.straighten,
                  remainingDistance.isNotEmpty ? remainingDistance : "--",
                  "Remaining"),
              Container(width: 1, height: 30, color: Colors.grey[300]),
              _navStatItem(Icons.timer_outlined,
                  remainingTimeString.isNotEmpty ? remainingTimeString : "--",
                  "Time Left"),
              Container(width: 1, height: 30, color: Colors.grey[300]),
              _navStatItem(Icons.access_time,
                  estimatedArrivalTime.isNotEmpty ? estimatedArrivalTime : "--:--",
                  "Arrival"),
            ],
          ),

          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: () {
                  setState(() => isMuted = !isMuted);
                  if (isMuted) flutterTts.stop();
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isMuted
                        ? Colors.red.withOpacity(0.1)
                        : Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isMuted ? Icons.volume_off : Icons.volume_up,
                    color: isMuted ? Colors.red : Colors.green,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _cancelNavigation,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.close,
                      color: Colors.red, size: 22),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _navStatItem(IconData icon, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.blue),
            const SizedBox(width: 4),
            Text(value,
                style: const TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.bold,
                    fontSize: 15)),
          ],
        ),
        Text(label,
            style: TextStyle(color: Colors.grey[600], fontSize: 10)),
      ],
    );
  }
}