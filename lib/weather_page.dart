import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:convert';

class WeatherPage extends StatefulWidget {
  const WeatherPage({super.key});

  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  static const String apiKey = "5336132dedcd47cf80581928261204";

  Map<String, dynamic>? weatherData;
  bool  isLoading     = true;
  bool  isRefreshing  = false;
  String error        = "";
  String lastUpdated  = "";

  @override
  void initState() {
    super.initState();
    _fetchWeather();
  }

  Future<Position?> _getPosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        error = "Location services are disabled.\n"
            "Please enable GPS in device settings.";
        isLoading = false;
      });
      return null;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          error = "Location permission denied.\n"
              "Please grant location access.";
          isLoading = false;
        });
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        error = "Location permission permanently denied.\n"
            "Please enable in app settings.";
        isLoading = false;
      });
      return null;
    }

    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.low,
    );
  }

  Future<void> _fetchWeather() async {
    if (mounted) {
      setState(() {
        isLoading    = true;
        error        = "";
        isRefreshing = false;
      });
    }

    try {
      final position = await _getPosition();
      if (position == null) return;

      final url =
          "https://api.weatherapi.com/v1/forecast.json"
          "?key=$apiKey"
          "&q=${position.latitude},${position.longitude}"
          "&days=1"
          "&aqi=yes";

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            weatherData = jsonDecode(response.body);
            isLoading   = false;
            lastUpdated = TimeOfDay.now().format(context);
          });
        }
      } else {
        String errorMsg = "Failed to fetch weather (${response.statusCode})";
        try {
          final errBody = jsonDecode(response.body);
          if (errBody['error']?['message'] != null) {
            errorMsg = errBody['error']['message'];
          }
        } catch (_) {}

        if (mounted) {
          setState(() {
            error     = errorMsg;
            isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error     = "Error: ${e.toString()}";
          isLoading = false;
        });
      }
    }
  }

  Future<void> _refreshWeather() async {
    setState(() => isRefreshing = true);
    await _fetchWeather();
  }

  double _toDouble(dynamic v, [double fallback = 0.0]) {
    if (v == null) return fallback;
    if (v is double) return v;
    if (v is int)    return v.toDouble();
    if (v is num)    return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  int _toInt(dynamic v, [int fallback = 0]) {
    if (v == null) return fallback;
    if (v is int)    return v;
    if (v is double) return v.round();
    if (v is num)    return v.toInt();
    return int.tryParse(v.toString()) ?? fallback;
  }

  IconData _getWeatherIcon(String condition) {
    condition = condition.toLowerCase();
    if (condition.contains('thunder') || condition.contains('storm'))
      return Icons.thunderstorm;
    if (condition.contains('rain') || condition.contains('drizzle'))
      return Icons.water_drop;
    if (condition.contains('snow') || condition.contains('sleet'))
      return Icons.ac_unit;
    if (condition.contains('fog') || condition.contains('mist') ||
        condition.contains('haze'))
      return Icons.foggy;
    if (condition.contains('cloud') || condition.contains('overcast'))
      return Icons.cloud;
    if (condition.contains('sun') || condition.contains('clear'))
      return Icons.wb_sunny;
    if (condition.contains('partly'))
      return Icons.wb_cloudy;
    return Icons.wb_cloudy;
  }

  Color _getWeatherColor(String condition) {
    condition = condition.toLowerCase();
    if (condition.contains('thunder') || condition.contains('storm'))
      return Colors.deepPurple;
    if (condition.contains('rain') || condition.contains('drizzle'))
      return Colors.blue;
    if (condition.contains('snow') || condition.contains('sleet'))
      return Colors.lightBlue;
    if (condition.contains('fog') || condition.contains('mist') ||
        condition.contains('haze'))
      return Colors.blueGrey;
    if (condition.contains('cloud') || condition.contains('overcast'))
      return Colors.grey;
    if (condition.contains('sun') || condition.contains('clear'))
      return Colors.orange;
    return Colors.blueGrey;
  }

  String _getWindDirection(int degrees) {
    const dirs = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
      'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
    int index = ((degrees + 11.25) ~/ 22.5) % 16;
    return dirs[index];
  }

  String _getAqiCategory(int aqi) {
    switch (aqi) {
      case 1:  return "Good";
      case 2:  return "Moderate";
      case 3:  return "Unhealthy (Sensitive)";
      case 4:  return "Unhealthy";
      case 5:  return "Very Unhealthy";
      case 6:  return "Hazardous";
      default: return "Unknown";
    }
  }

  Color _getAqiColor(int aqi) {
    switch (aqi) {
      case 1:  return Colors.green;
      case 2:  return Colors.yellow;
      case 3:  return Colors.orange;
      case 4:  return Colors.red;
      case 5:  return Colors.purple;
      case 6:  return Colors.brown;
      default: return Colors.grey;
    }
  }

  // ═══════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    // Extract location info for AppBar when available
    String appBarTitle = "Weather";
    String appBarSubtitle = "";
    if (weatherData != null) {
      final location = weatherData!['location'];
      appBarTitle = "${location['name']}";
      appBarSubtitle = "${location['region'] ?? location['country']}";
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(appBarTitle,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
            if (appBarSubtitle.isNotEmpty)
              Text(appBarSubtitle,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 11)),
          ],
        ),
        actions: [
          if (lastUpdated.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text("Updated $lastUpdated",
                    style: const TextStyle(
                        color: Colors.grey, fontSize: 10)),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.blue),
            onPressed: _fetchWeather,
          ),
        ],
      ),
      body: isLoading
          ? const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.blueAccent),
            SizedBox(height: 16),
            Text("Fetching weather...",
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      )
          : error.isNotEmpty
          ? _buildErrorView()
          : RefreshIndicator(
        color: Colors.blueAccent,
        backgroundColor: const Color(0xFF141420),
        onRefresh: _refreshWeather,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: _buildWeatherContent(),
        ),
      ),
    );
  }

  // ── Error view ────────────────────────────────────────────
  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off,
                color: Colors.redAccent, size: 64),
            const SizedBox(height: 20),
            Text(error,
                style: const TextStyle(
                    color: Colors.redAccent, fontSize: 14),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _fetchWeather,
              icon: const Icon(Icons.refresh),
              label: const Text("Retry"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            if (error.contains("401") || error.contains("key"))
              const Text(
                "Tip: Check if your WeatherAPI key is valid\n"
                    "and the free tier hasn't expired.",
                style: TextStyle(color: Colors.grey, fontSize: 11),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }

  // ── Main weather content ──────────────────────────────────
  Widget _buildWeatherContent() {
    final current   = weatherData!['current'];
    final forecast  = weatherData!['forecast']['forecastday'][0];
    final condition = current['condition']['text'];
    final color     = _getWeatherColor(condition);
    final tempC     = _toDouble(current['temp_c']);
    final feelsC    = _toDouble(current['feelslike_c']);

    return Column(
      children: [
        // ── Main weather card (no location — it's in AppBar now) ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [color.withOpacity(0.7), const Color(0xFF0A0A0F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Column(
            children: [
              Icon(_getWeatherIcon(condition),
                  color: Colors.white, size: 80),
              const SizedBox(height: 8),
              Text(
                "${tempC.toStringAsFixed(0)}°C",
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 64,
                    fontWeight: FontWeight.bold),
              ),
              Text(
                condition,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.8), fontSize: 18),
              ),
              const SizedBox(height: 4),
              Text(
                "Feels like ${feelsC.toStringAsFixed(0)}°C",
                style: TextStyle(
                    color: Colors.white.withOpacity(0.6), fontSize: 14),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── Riding conditions card ─────────────────────────
        _buildRidingConditions(current),
        const SizedBox(height: 16),

        // ── Details grid ───────────────────────────────────
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.4,
          children: [
            _buildDetailCard("Humidity",
                "${_toInt(current['humidity'])}%",
                Icons.water_drop, Colors.blue),
            _buildDetailCard("Wind",
                "${_toDouble(current['wind_kph']).toStringAsFixed(0)} km/h ${_getWindDirection(_toInt(current['wind_degree']))}",
                Icons.air, Colors.teal),
            _buildDetailCard("Visibility",
                "${_toDouble(current['vis_km']).toStringAsFixed(1)} km",
                Icons.visibility, Colors.orange),
            _buildDetailCard("UV Index",
                "${_toDouble(current['uv']).toStringAsFixed(0)}",
                Icons.wb_sunny, Colors.yellow),
            _buildDetailCard("Pressure",
                "${_toInt(current['pressure_mb'])} hPa",
                Icons.speed, Colors.purpleAccent),
            _buildDetailCard("Cloud Cover",
                "${_toInt(current['cloud'])}%",
                Icons.cloud, Colors.blueGrey),
          ],
        ),
        const SizedBox(height: 16),

        // ── Air Quality Index card ─────────────────────────
        _buildAqiCard(current),
        const SizedBox(height: 16),

        // ── Sunrise / Sunset card ──────────────────────────
        _buildSunCard(forecast),
        const SizedBox(height: 16),

        // ── Today's Forecast ───────────────────────────────
        _buildForecastCard(forecast),
        const SizedBox(height: 16),

        // ── Hourly Forecast ────────────────────────────────
        _buildHourlyForecast(forecast),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Riding conditions ─────────────────────────────────────
  Widget _buildRidingConditions(Map<String, dynamic> current) {
    double windSpeed  = _toDouble(current['wind_kph']);
    double visibility = _toDouble(current['vis_km']);
    int    uvIndex    = _toInt(_toDouble(current['uv']));
    String condition  = current['condition']['text'].toLowerCase();

    String ridingStatus = "Good";
    Color  ridingColor  = Colors.green;
    String ridingAdvice = "Safe to ride! Clear conditions.";
    IconData ridingIcon = Icons.check_circle;

    if (windSpeed > 50 || visibility < 1 ||
        condition.contains('thunder') || condition.contains('storm')) {
      ridingStatus  = "Dangerous";
      ridingColor   = Colors.red;
      ridingAdvice  = "Avoid riding — dangerous conditions!";
      ridingIcon    = Icons.dangerous;
    } else if (windSpeed > 30 || visibility < 3 ||
        condition.contains('rain') || condition.contains('snow') ||
        uvIndex >= 8) {
      ridingStatus  = "Caution";
      ridingColor   = Colors.orange;
      ridingAdvice  = condition.contains('rain')
          ? "Rain detected — ride carefully, wet roads!"
          : condition.contains('snow')
          ? "Snow detected — slippery roads!"
          : uvIndex >= 8
          ? "Extreme UV — wear sun protection!"
          : "Ride carefully — reduced conditions";
      ridingIcon    = Icons.warning_amber_rounded;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ridingColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: ridingColor.withOpacity(0.6), width: 1.5),
      ),
      child: Row(
        children: [
          Icon(ridingIcon, color: ridingColor, size: 40),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Riding: $ridingStatus",
                  style: TextStyle(
                      color: ridingColor,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(ridingAdvice,
                    style: TextStyle(
                        color: Colors.grey[300], fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Detail card ───────────────────────────────────────────
  Widget _buildDetailCard(
      String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(title,
              style: TextStyle(color: Colors.grey[500], fontSize: 10)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  // ── Air Quality Index card ────────────────────────────────
  Widget _buildAqiCard(Map<String, dynamic> current) {
    final aqData = current['air_quality'];
    if (aqData == null) return const SizedBox.shrink();

    final aqi      = _toInt(aqData['us-epa-index']);
    final pm25     = _toDouble(aqData['pm2_5']);
    final pm10     = _toDouble(aqData['pm10']);
    final category = _getAqiCategory(aqi);
    final aqiColor = _getAqiColor(aqi);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: aqiColor.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.air, color: aqiColor, size: 20),
              const SizedBox(width: 8),
              const Text("Air Quality",
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: aqiColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: aqiColor.withOpacity(0.5)),
                ),
                child: Text(
                  category,
                  style: TextStyle(
                      color: aqiColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _aqiItem("PM2.5", "${pm25.toStringAsFixed(1)}", "µg/m³",
                  pm25 > 35 ? Colors.orange : Colors.green),
              _aqiItem("PM10", "${pm10.toStringAsFixed(1)}", "µg/m³",
                  pm10 > 50 ? Colors.orange : Colors.green),
              _aqiItem("AQI", "$aqi", "US EPA",
                  aqiColor),
            ],
          ),
        ],
      ),
    );
  }

  Widget _aqiItem(String label, String value, String unit, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(color: Colors.grey[500], fontSize: 10)),
        Text(unit,
            style: TextStyle(color: Colors.grey[600], fontSize: 9)),
      ],
    );
  }

  // ── Sunrise / Sunset card ─────────────────────────────────
  Widget _buildSunCard(Map<String, dynamic> forecast) {
    final astro = forecast['astro'];
    if (astro == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _sunItem(
            Icons.wb_sunny,
            "Sunrise",
            astro['sunrise']?.toString() ?? "--:--",
            Colors.orange,
          ),
          Container(
            width: 1, height: 40,
            color: Colors.white12,
          ),
          _sunItem(
            Icons.nightlight_round,
            "Sunset",
            astro['sunset']?.toString() ?? "--:--",
            Colors.indigoAccent,
          ),
          Container(
            width: 1, height: 40,
            color: Colors.white12,
          ),
          _sunItem(
            Icons.wb_twilight,
            "Moon",
            astro['moon_phase']?.toString() ?? "",
            Colors.blueGrey,
          ),
        ],
      ),
    );
  }

  Widget _sunItem(IconData icon, String label, String value, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 6),
        Text(label,
            style: TextStyle(color: Colors.grey[500], fontSize: 10)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold)),
      ],
    );
  }

  // ── Today's forecast summary ──────────────────────────────
  Widget _buildForecastCard(Map<String, dynamic> forecast) {
    final day = forecast['day'];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Today's Forecast",
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildForecastItem("Max",
                  "${_toDouble(day['maxtemp_c']).toStringAsFixed(0)}°C",
                  Colors.red),
              _buildForecastItem("Min",
                  "${_toDouble(day['mintemp_c']).toStringAsFixed(0)}°C",
                  Colors.blue),
              _buildForecastItem("Rain",
                  "${_toInt(day['daily_chance_of_rain'])}%",
                  Colors.lightBlue),
              _buildForecastItem("Snow",
                  "${_toInt(day['daily_chance_of_snow'])}%",
                  Colors.cyan),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildForecastItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                color: color,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(color: Colors.grey[500], fontSize: 10)),
      ],
    );
  }

  // ── Hourly Forecast ───────────────────────────────────────
  Widget _buildHourlyForecast(Map<String, dynamic> forecast) {
    final List hours = forecast['hour'] ?? [];
    if (hours.isEmpty) return const SizedBox.shrink();

    final now = DateTime.now();
    final currentHourIndex = hours.indexWhere((h) {
      final hTime = DateTime.tryParse(h['time'] ?? '');
      return hTime != null &&
          hTime.hour == now.hour &&
          hTime.day == now.day;
    });

    final startIndex = currentHourIndex >= 0 ? currentHourIndex : 0;
    final displayHours = hours.skip(startIndex).take(8).toList();

    if (displayHours.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Hourly Forecast",
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(
            height: 90,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: displayHours.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final hour = displayHours[index];
                final time = hour['time']?.toString() ?? '';
                final hourLabel = time.length >= 5
                    ? time.substring(time.length - 5)
                    : time;
                final temp = _toDouble(hour['temp_c']);
                final cond = hour['condition']?['text'] ?? '';
                final isNow = index == 0 && currentHourIndex >= 0;

                return Container(
                  width: 64,
                  padding: const EdgeInsets.symmetric(
                      vertical: 8, horizontal: 4),
                  decoration: BoxDecoration(
                    color: isNow
                        ? Colors.blue.withOpacity(0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: isNow
                        ? Border.all(color: Colors.blue.withOpacity(0.4))
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        isNow ? "Now" : hourLabel,
                        style: TextStyle(
                            color: isNow ? Colors.blue : Colors.grey[400],
                            fontSize: 10,
                            fontWeight: isNow ? FontWeight.bold : FontWeight.normal),
                      ),
                      const SizedBox(height: 4),
                      Icon(_getWeatherIcon(cond),
                          color: Colors.white70, size: 18),
                      const SizedBox(height: 4),
                      Text(
                        "${temp.toStringAsFixed(0)}°",
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}