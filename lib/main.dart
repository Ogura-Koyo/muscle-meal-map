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
  String? _errorMessage;
  CameraPosition? _initialCameraPosition;
  Set<Marker> _markers = {};

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
  Future<void> _fetchRestaurants(double lat, double lng) async {
    try {
      final response = await http.get(Uri.parse('$apiEndpoint?lat=$lat&lng=$lng'));

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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trainee Meal Finder'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Text('Error: $_errorMessage'))
              : _initialCameraPosition == null
                  ? const Center(child: Text('Could not determine location.'))
                  : GoogleMap(
                      mapType: MapType.normal,
                      initialCameraPosition: _initialCameraPosition!,
                      markers: _markers,
                      myLocationEnabled: true, // Shows the blue dot for user location
                      myLocationButtonEnabled: true,
                    ),
    );
  }
}
