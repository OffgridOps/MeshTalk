import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/peer.dart';
import '../models/message.dart';
import 'crypto_service.dart';

/// Service for mesh network routing and communication
class MeshRoutingService {
  // Server configuration
  static const String DEFAULT_SERVER_URL = 'http://localhost:8000';
  
  // API endpoints
  static const String API_NODE = '/api/node';
  static const String API_NETWORK = '/api/network';
  static const String API_MESSAGES = '/api/messages';
  static const String API_VOICE_PROCESS = '/api/voice/process';
  static const String API_VOICE_TRANSMIT = '/api/voice/transmit';
  static const String API_VOICE_COMMAND = '/api/voice/command';
  
  // Internal state
  String _serverUrl = DEFAULT_SERVER_URL;
  String _nodeId = '';
  String _publicKey = '';
  final CryptoService _cryptoService = CryptoService();
  final List<Peer> _knownPeers = [];
  Timer? _discoveryTimer;
  
  // Stream controllers for observing state changes
  final _peerStreamController = StreamController<List<Peer>>.broadcast();
  final _messageStreamController = StreamController<List<Message>>.broadcast();
  
  // Stream getters
  Stream<List<Peer>> get peerStream => _peerStreamController.stream;
  Stream<List<Message>> get messageStream => _messageStreamController.stream;
  
  /// Initialize the mesh routing service
  Future<void> initialize() async {
    // Load saved server URL
    await _loadSettings();
    
    // Start peer discovery process
    _startPeerDiscovery();
    
    // Initialize cryptography
    await _cryptoService.initialize();
  }
  
  /// Dispose and clean up resources
  void dispose() {
    _discoveryTimer?.cancel();
    _peerStreamController.close();
    _messageStreamController.close();
  }
  
  /// Load saved settings
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('server_url');
      if (savedUrl != null && savedUrl.isNotEmpty) {
        _serverUrl = savedUrl;
      }
    } catch (e) {
      print('Error loading settings: $e');
    }
  }
  
  /// Set the server URL
  Future<void> setServerUrl(String url) async {
    _serverUrl = url;
    
    // Save to preferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_url', url);
    } catch (e) {
      print('Error saving server URL: $e');
    }
  }
  
  /// Start the peer discovery process
  void _startPeerDiscovery() {
    _discoveryTimer?.cancel();
    
    // Update peers every 10 seconds
    _discoveryTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _discoverPeers();
    });
    
    // Trigger immediate discovery
    _discoverPeers();
  }
  
  /// Discover peers in the mesh network
  Future<void> _discoverPeers() async {
    try {
      final networkInfo = await getNetworkInfo();
      
      // Update known peers list
      _knownPeers.clear();
      if (networkInfo['nodes'] != null) {
        for (final node in networkInfo['nodes']) {
          final peer = Peer.fromJson(node);
          _knownPeers.add(peer);
        }
      }
      
      // Notify listeners
      _peerStreamController.add(List.from(_knownPeers));
    } catch (e) {
      print('Error discovering peers: $e');
    }
  }
  
  /// Get information about the current node
  Future<Peer> getNodeInfo() async {
    try {
      final response = await http.get(Uri.parse('$_serverUrl$API_NODE'));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // Save node ID and public key
        _nodeId = data['node_id'];
        _publicKey = data['public_key'];
        
        return Peer(
          id: data['node_id'],
          address: data['address'],
          lastSeen: data['active_since'],
        );
      } else {
        throw Exception('Failed to get node info: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error connecting to mesh server: $e');
    }
  }
  
  /// Get information about the mesh network
  Future<Map<String, dynamic>> getNetworkInfo() async {
    try {
      final response = await http.get(Uri.parse('$_serverUrl$API_NETWORK'));
      
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to get network info: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error getting network info: $e');
    }
  }
  
  /// Get list of peers in the network
  Future<List<Peer>> getPeers() async {
    try {
      final networkInfo = await getNetworkInfo();
      
      List<Peer> peers = [];
      if (networkInfo['nodes'] != null) {
        for (final node in networkInfo['nodes']) {
          if (node['id'] != _nodeId) { // Exclude self
            peers.add(Peer.fromJson(node));
          }
        }
      }
      
      return peers;
    } catch (e) {
      throw Exception('Error getting peers: $e');
    }
  }
  
  /// Get messages from the network
  Future<List<Message>> getMessages({double? since, int limit = 100}) async {
    try {
      // Build query parameters
      Map<String, String> queryParams = {'limit': limit.toString()};
      if (since != null) {
        queryParams['since'] = since.toString();
      }
      
      // Make API request
      final uri = Uri.parse('$_serverUrl$API_MESSAGES')
          .replace(queryParameters: queryParams);
      final response = await http.get(uri);
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        List<Message> messages = [];
        
        if (data['messages'] != null) {
          for (final msg in data['messages']) {
            messages.add(Message.fromJson(msg));
          }
        }
        
        // Notify listeners
        _messageStreamController.add(messages);
        
        return messages;
      } else {
        throw Exception('Failed to get messages: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error getting messages: $e');
    }
  }
  
  /// Send a text message to a recipient or broadcast
  Future<void> sendTextMessage(String recipientId, String content) async {
    try {
      final message = {
        'recipient_id': recipientId,
        'content': content,
      };
      
      final response = await http.post(
        Uri.parse('$_serverUrl$API_MESSAGES'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(message),
      );
      
      if (response.statusCode != 200) {
        throw Exception('Failed to send message: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error sending message: $e');
    }
  }
  
  /// Process voice data with noise cancellation
  Future<Map<String, dynamic>> processVoiceData(String base64Audio) async {
    try {
      final data = {
        'audio': base64Audio,
      };
      
      final response = await http.post(
        Uri.parse('$_serverUrl$API_VOICE_PROCESS'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(data),
      );
      
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to process voice: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error processing voice: $e');
    }
  }
  
  /// Send voice data to a recipient or broadcast
  Future<Map<String, dynamic>> sendVoiceData(String recipientId, String base64Audio) async {
    try {
      final data = {
        'recipient_id': recipientId,
        'audio': base64Audio,
      };
      
      final response = await http.post(
        Uri.parse('$_serverUrl$API_VOICE_TRANSMIT'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(data),
      );
      
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to transmit voice: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error sending voice data: $e');
    }
  }
  
  /// Process a voice command
  Future<Map<String, dynamic>> processVoiceCommand(String commandText) async {
    try {
      final data = {
        'command': commandText,
      };
      
      final response = await http.post(
        Uri.parse('$_serverUrl$API_VOICE_COMMAND'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(data),
      );
      
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to process command: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error processing voice command: $e');
    }
  }
  
  /// Scan local network for mesh servers
  Future<List<String>> scanLocalNetwork() async {
    // Check connectivity
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity == ConnectivityResult.none) {
      throw Exception('No network connectivity');
    }
    
    List<String> foundServers = [];
    
    // Get local IP address
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    
    for (var interface in interfaces) {
      for (var addr in interface.addresses) {
        final parts = addr.address.split('.');
        if (parts.length == 4) {
          // Scan subnet
          final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
          
          // Create list of futures for parallel scanning
          List<Future<String?>> scanFutures = [];
          
          for (int i = 1; i <= 254; i++) {
            final ip = '$subnet.$i';
            scanFutures.add(_checkServer(ip));
          }
          
          // Wait for all scan operations to complete
          final results = await Future.wait(scanFutures);
          
          // Add valid servers to the list
          for (final server in results) {
            if (server != null) {
              foundServers.add(server);
            }
          }
        }
      }
    }
    
    return foundServers;
  }
  
  /// Check if a server is running on the given IP
  Future<String?> _checkServer(String ip) async {
    try {
      final client = http.Client();
      try {
        final response = await client.get(
          Uri.parse('http://$ip:8000/health'),
        ).timeout(const Duration(milliseconds: 300));
        
        if (response.statusCode == 200) {
          return 'http://$ip:8000';
        }
      } catch (_) {
        // Ignore connection errors
      } finally {
        client.close();
      }
    } catch (_) {
      // Ignore any errors
    }
    return null;
  }
}
