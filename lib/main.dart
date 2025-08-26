import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

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
  bool _isLoading = true;
  double _selectedProtein = 20.0;
  String? _errorMessage;
  CameraPosition? _initialCameraPosition;
  Set<Marker> _markers = {};
  Position? _currentPosition;

  @override
  void initState() {
    super.initState();
    _determinePositionAndFetchRestaurants();
  }

  /// 1. Main function to orchestrate location and data fetching.
  Future<void> _determinePositionAndFetchRestaurants() async {
    try {
      final position = await _getCurrentLocation();
      setState(() {
        _currentPosition = position;
        _initialCameraPosition = CameraPosition(
          target: LatLng(position.latitude, position.longitude),
          zoom: 15.0,
        );
      });
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
          _markers = restaurants.map((restaurant) {
            return Marker(
              markerId: MarkerId(restaurant.name),
              position: restaurant.location,
              infoWindow: InfoWindow(
                title: restaurant.name,
                snippet: restaurant.address,
              ),
            );
          }).toSet();
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
                  mapType: MapType.normal,
                  initialCameraPosition: _initialCameraPosition!,
                  markers: _markers,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                  // Padding to prevent Google logo from being covered by our slider
                  padding: const EdgeInsets.only(bottom: 150.0),
                ),

          // The new, always-visible slider control is placed on top
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GestureDetector(
              onVerticalDragStart: (_) {}, // Prevent map interaction when dragging
              onHorizontalDragStart: (_) {},
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
