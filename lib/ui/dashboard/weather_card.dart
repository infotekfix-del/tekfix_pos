import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../main.dart' show Db;
import 'dashboard_tokens.dart';

/// Pixel-faithful Weather Card for TekFix ERP.
/// Fetches live temperature, weather condition, and location using the Open-Meteo API,
/// and stores results in Hive Db.settings for instant offline use.
class TekWeatherCard extends StatefulWidget {
  final double latitude;
  final double longitude;
  final String locationName;

  const TekWeatherCard({
    super.key,
    this.latitude = 11.0728, // Irumbuzhi, Malappuram, Kerala
    this.longitude = 76.0837,
    this.locationName = 'Irumbuzhi, Kerala',
  });

  @override
  State<TekWeatherCard> createState() => _TekWeatherCardState();
}

class _TekWeatherCardState extends State<TekWeatherCard> {
  double _temperature = 28.0;
  String _condition = 'Partly Cloudy';
  int _humidity = 68;
  double _windSpeed = 9.5;
  int _weatherCode = 1;
  bool _isLoading = false;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _loadCachedWeather();
    _fetchLiveWeather();
  }

  void _loadCachedWeather() {
    try {
      final cachedJson = Db.settings.get('cached_weather_data');
      if (cachedJson is String && cachedJson.isNotEmpty) {
        final data = jsonDecode(cachedJson) as Map<String, dynamic>;
        setState(() {
          _temperature = (data['temperature'] as num?)?.toDouble() ?? 28.0;
          _condition = data['condition'] as String? ?? 'Partly Cloudy';
          _humidity = (data['humidity'] as num?)?.toInt() ?? 68;
          _windSpeed = (data['windSpeed'] as num?)?.toDouble() ?? 9.5;
          _weatherCode = (data['weatherCode'] as num?)?.toInt() ?? 1;
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchLiveWeather() async {
    setState(() => _isLoading = true);
    try {
      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${widget.latitude}&longitude=${widget.longitude}&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final current = decoded['current'] as Map<String, dynamic>?;
        if (current != null) {
          final temp = (current['temperature_2m'] as num?)?.toDouble() ?? _temperature;
          final humidity = (current['relative_humidity_2m'] as num?)?.toInt() ?? _humidity;
          final wind = (current['wind_speed_10m'] as num?)?.toDouble() ?? _windSpeed;
          final code = (current['weather_code'] as num?)?.toInt() ?? _weatherCode;
          final conditionText = _mapWeatherCode(code);

          if (mounted) {
            setState(() {
              _temperature = temp;
              _condition = conditionText;
              _humidity = humidity;
              _windSpeed = wind;
              _weatherCode = code;
              _isLoading = false;
              _isOffline = false;
            });
          }

          // Cache in Hive settings for offline use
          Db.settings.put(
            'cached_weather_data',
            jsonEncode({
              'temperature': temp,
              'condition': conditionText,
              'humidity': humidity,
              'windSpeed': wind,
              'weatherCode': code,
              'updatedAt': DateTime.now().toIso8601String(),
            }),
          );
          return;
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isOffline = true;
          _isLoading = false;
        });
      }
    }
  }

  String _mapWeatherCode(int code) {
    if (code == 0) return 'Clear Sky';
    if (code <= 3) return 'Partly Cloudy';
    if (code <= 48) return 'Foggy';
    if (code <= 67) return 'Rainy';
    if (code <= 77) return 'Snow';
    if (code <= 82) return 'Rain Showers';
    if (code <= 99) return 'Thunderstorm';
    return 'Clear';
  }

  IconData _mapWeatherIcon(int code) {
    if (code == 0) return Icons.wb_sunny_rounded;
    if (code <= 3) return Icons.wb_cloudy_rounded;
    if (code <= 48) return Icons.cloud_rounded;
    if (code <= 67) return Icons.water_drop_rounded;
    if (code <= 82) return Icons.grain_rounded;
    if (code <= 99) return Icons.flash_on_rounded;
    return Icons.wb_sunny_rounded;
  }

  Color _mapWeatherColor(int code) {
    if (code == 0) return DashboardColors.neonOrange;
    if (code <= 3) return DashboardColors.neonBlue;
    if (code <= 67) return const Color(0xFF38BDF8);
    return DashboardColors.neonPurple;
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = _mapWeatherColor(_weatherCode);
    final iconData = _mapWeatherIcon(_weatherCode);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x1F182652),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0x2BFFFFFF),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Row: Location & Refresh/Status
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.location_on_rounded,
                    size: 15,
                    color: DashboardColors.neonPink,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.locationName,
                    style: DashboardTypography.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: _fetchLiveWeather,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _isLoading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: DashboardColors.neonBlue,
                          ),
                        )
                      : Icon(
                          _isOffline ? Icons.cloud_off_rounded : Icons.refresh_rounded,
                          size: 16,
                          color: _isOffline ? DashboardColors.textMuted : DashboardColors.neonBlue,
                        ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Middle: Temp & Big Icon
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_temperature.toStringAsFixed(0)}°C',
                    style: DashboardTypography.poppins(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    _condition,
                    style: DashboardTypography.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: iconColor,
                    ),
                  ),
                ],
              ),

              // Glowing Weather Icon Badge
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: iconColor.withValues(alpha: 0.4),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: iconColor.withValues(alpha: 0.3),
                      blurRadius: 14,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    iconData,
                    color: iconColor,
                    size: 28,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Bottom Chips: Humidity & Wind Speed
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0x1F22325E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x1FFFFFFF)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.water_drop_rounded, size: 14, color: DashboardColors.neonBlue),
                      const SizedBox(width: 6),
                      Text(
                        '$_humidity% Humidity',
                        style: DashboardTypography.inter(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFFCBD5E1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0x1F22325E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x1FFFFFFF)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.air_rounded, size: 14, color: DashboardColors.neonGreen),
                      const SizedBox(width: 6),
                      Text(
                        '${_windSpeed.toStringAsFixed(1)} km/h',
                        style: DashboardTypography.inter(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFFCBD5E1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
