import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'dart:ui' show ImageByteFormat, PictureRecorder, Canvas, Paint, Offset, Rect;
import 'dart:async';

const String apiEndpoint = "https://asia-northeast1-muscle-meal.cloudfunctions.net/getRestaurants";

// Initialize the logger
final Logger logger = Logger();

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Trainee Meal Finder',
      home: MapScreen(),
    );
  }
}

// Data Model for our Restaurant object
class Restaurant {
  final String name;
  final String address;
  final LatLng location;

  Restaurant({required this.name, required this.address, required this.location});

  // Factory constructor to create a Restaurant from JSON
  factory Restaurant.fromJson(Map<String, dynamic> json) {
    return Restaurant(
      name: json['name'],
      address: json['address'],
      location: LatLng(
        json['location']['lat'],
        json['location']['lng'],
      ),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen> {
  // State variables
  StreamSubscription<Position>? _posSub;
  bool _isLoading = true;
  double _selectedProtein = 20.0;
  String? _errorMessage;
  CameraPosition? _initialCameraPosition;
  Set<Marker> _markers = {};
  Position? _currentPosition;
  GoogleMapController? _mapController;
  BitmapDescriptor? _myLocIcon;
  Set<Circle> _circles = {};
  static const MarkerId _myLocationMarkerId = MarkerId('me');
  // Unique ID for the user's radius circle
  static const CircleId _myLocationCircleId = CircleId('me_radius');

  Future<void> _startPositionStream() async {
  // Permissions (Web needs user gesture/https; this will request when allowed)
  LocationPermission perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
    perm = await Geolocator.requestPermission();
  }

  final enabled = await Geolocator.isLocationServiceEnabled();
  if (!enabled) {
    // TODO: show a snackbar/toast for location services off
    return;
  }

  const locationSettings = LocationSettings(
    accuracy: LocationAccuracy.best, // or high to save battery
    distanceFilter: 5,               // meters between updates
  );

  // Ensure only one stream is active
  await _posSub?.cancel();
  _posSub = Geolocator.getPositionStream(locationSettings: locationSettings)
      .listen((pos) {
        final p = LatLng(pos.latitude, pos.longitude);
        _updateMyLocationMarker(p);
        // Optional: follow the user
        // _mapController?.animateCamera(CameraUpdate.newLatLng(p));
      });
}

void _updateMyLocationMarker(LatLng latLng) {
  final meId = _myLocationMarkerId;

  // If you have a custom icon in _myLocIcon, use it; else default marker
  final meMarker = Marker(
    markerId: meId,
    position: latLng,
    zIndex: 9999,
    anchor: const Offset(0.5, 0.5),
    icon: _myLocIcon ?? BitmapDescriptor.defaultMarker,
    infoWindow: const InfoWindow(title: 'Your location'),
  );

  // 500-meter grey circle around the user
  final meCircle = Circle(
    circleId: _myLocationCircleId,
    center: latLng,
    radius: 250.0,                              // meters
    strokeWidth: 1,
    strokeColor: Colors.grey.withOpacity(0.7),
    fillColor: Colors.grey.withOpacity(0.18),   // subtle fill
    zIndex: 9998,
  );

  setState(() {
    // IMPORTANT: do not overwrite _markers; update/replace just the 'me' marker
    _markers
      ..removeWhere((m) => m.markerId == meId)
      ..add(meMarker);
    _circles = { meCircle };
  });
}

  @override
  void initState() {
    super.initState();
    _determinePositionAndFetchRestaurants();
    _createMyLocationIcon();
    _startPositionStream();
  }

  @override
  void dispose() {
    _posSub?.cancel();   // stop location updates when widget is destroyed
    super.dispose();
  }
  
  Future<void> _createMyLocationIcon() async {
    // logical size of the marker bitmap
    const double size = 30.0;

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final paintFill = Paint()..color = const Color(0xFF1E88E5); // blue 600-ish
    final paintWhite = Paint()..color = const Color(0xFFFFFFFF);

    final center = Offset(size / 2, size / 2);
    final outerR = size * 0.32;  // blue circle
    final strokeR = outerR + 2;  // white ring
    final innerR = outerR * 0.35; // small white center dot

    // Transparent background
    canvas.drawRect(Rect.fromLTWH(0, 0, size, size), Paint()..color = const Color(0x00000000));

    // white outer ring
    canvas.drawCircle(center, strokeR, paintWhite);
    // blue main dot
    canvas.drawCircle(center, outerR, paintFill);
    // small white center dot
    canvas.drawCircle(center, innerR, paintWhite);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ImageByteFormat.png);
    if (bytes == null) return;

    _myLocIcon = BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
  }

  /// 1. Main function to orchestrate location and data fetching.
  Future<void> _determinePositionAndFetchRestaurants() async {
    try {
      final position = await _getCurrentLocation();
      setState(() {
        _currentPosition = position;
        _initialCameraPosition = CameraPosition(
          target: LatLng(position.latitude, position.longitude),
          zoom: 17.0,
        );
      });
      _updateMyLocationMarker(LatLng(position.latitude, position.longitude));
      await _fetchRestaurants(position.latitude, position.longitude);
    } catch (e) {
      logger.e("Error in location/fetching orchestration: $e");
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// 2. Get user's current location after checking permissions.
  Future<Position> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }
    return await Geolocator.getCurrentPosition();
  }

  /// 3. Fetch data from your backend API.
  Future<void> _fetchRestaurants(double lat, double lng, {double minProtein = 0.0}) async {
    setState(() {
      _isLoading = true;
    });
    try {
      final url = '$apiEndpoint?lat=$lat&lng=$lng&minProtein=$minProtein';
      logger.i("Fetching from URL: $url");
      final response = await http.get(Uri.parse(url));

      logger.i('API Response Status Code: ${response.statusCode}'); // Info level
      logger.d('API Response Body: ${response.body}'); // Debug level (more verbose)

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);

        logger.i('Successfully parsed ${data.length} items.');

        final restaurants = data.map((json) => Restaurant.fromJson(json)).toList();

        setState(() {
          final restaurantMarkers = restaurants.map((restaurant) {
            return Marker(
              markerId: MarkerId(restaurant.name),
              position: restaurant.location,
              infoWindow: InfoWindow(
                title: restaurant.name,
                snippet: restaurant.address,
              ),
            );
          }).toSet();
          _markers = {
            ..._markers.where((m) => m.markerId == _myLocationMarkerId), // keep 'me' marker
            ...restaurantMarkers,
          };
          _circles = {
            ..._circles.where((c) => c.circleId == _myLocationCircleId), // keep 'me' circle
          };
        });
      } else {
        throw Exception('Failed to load restaurants');
      }
    } catch (e) {
      logger.e("Error fetching restaurants: $e");
      setState(() {
        _errorMessage = "Failed to fetch data. Please check your connection.";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trainee Meal Finder'),
      ),
      body: Stack(
        children: [
          // The Google Map is the base layer
          _initialCameraPosition == null
              ? const Center(child: Text('Determining location...'))
              : GoogleMap(
                  onMapCreated: (c) => _mapController = c,
                  mapType: MapType.normal,
                  initialCameraPosition: _initialCameraPosition!,
                  markers: _markers,
                  circles: _circles,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                  // Padding to prevent Google logo from being covered by our slider
                  padding: const EdgeInsets.only(bottom: 200.0),
                  cloudMapId: 'b41109ea305c43e77dcef765',
                ),
          
          Positioned(
            right: 16,
            bottom: 220, // keep it above your slider (adjust as you like)
            child: Material(
              elevation: 2,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                icon: const Icon(Icons.my_location),
                onPressed: () async {
                  try {
                    final pos = await _getCurrentLocation();
                    final me = LatLng(pos.latitude, pos.longitude); // TODO: replace with LatLng(pos.latitude, pos.longitude); to get actual location
                    _updateMyLocationMarker(me);
                    _mapController?.animateCamera(
                      CameraUpdate.newLatLng(me),
                    );
                  } catch (_) {
                    // no-op or show a SnackBar if you want
                  }
                },
              ),
            ),
          ),

          // The new, always-visible slider control is placed on top
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: PointerInterceptor( // Prevents map interactions when interacting with the slider
              child: Card(
                margin: const EdgeInsets.all(16.0),
                elevation: 8.0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'At least ${_selectedProtein.toStringAsFixed(0)}g of protein',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Slider(
                        value: _selectedProtein,
                        min: 0,
                        max: 100,
                        divisions: 20,
                        label: _selectedProtein.round().toString(),
                        // This now only updates the text label
                        onChanged: (double value) {
                          setState(() {
                            _selectedProtein = value;
                          });
                        },
                        // onChangeEnd is no longer used for fetching
                      ),
                      // The "Apply Filter" button is now here
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(40), // Make button wider
                        ),
                        child: const Text('Apply Filter'),
                        onPressed: () {
                          if (_currentPosition != null) {
                            _fetchRestaurants(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                              minProtein: _selectedProtein, // Use the current slider value
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Loading and error indicators remain on top of everything
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
          if (_errorMessage != null)
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.black.withOpacity(0.5),
                child: Text(
                  'Error: $_errorMessage',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
