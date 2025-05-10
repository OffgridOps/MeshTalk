import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'ui/walkie_talkie.dart';
import 'ui/chat_screen.dart';
import 'ui/mesh_visualization.dart';
import 'services/mesh_routing.dart';
import 'models/peer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Force portrait orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  
  // Initialize services
  final meshService = MeshRoutingService();
  await meshService.initialize();
  
  runApp(MeshTalkApp(meshService: meshService));
}

class MeshTalkApp extends StatelessWidget {
  final MeshRoutingService meshService;
  
  const MeshTalkApp({Key? key, required this.meshService}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshTalk',
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF6200EA), // Deep purple
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF6200EA),
          secondary: const Color(0xFF00E676), // Bright green
          surface: const Color(0xFF121212),
          background: const Color(0xFF121212),
          onBackground: Colors.white,
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
        textTheme: const TextTheme(
          bodyText1: TextStyle(fontFamily: 'FiraCode'),
          bodyText2: TextStyle(fontFamily: 'FiraCode'),
          headline6: TextStyle(fontFamily: 'FiraCode'),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1F1F),
          elevation: 0,
        ),
      ),
      home: MeshTalkHomePage(meshService: meshService),
    );
  }
}

class MeshTalkHomePage extends StatefulWidget {
  final MeshRoutingService meshService;
  
  const MeshTalkHomePage({Key? key, required this.meshService}) : super(key: key);

  @override
  _MeshTalkHomePageState createState() => _MeshTalkHomePageState();
}

class _MeshTalkHomePageState extends State<MeshTalkHomePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Timer? _refreshTimer;
  List<Peer> _peers = [];
  bool _isLoading = true;
  String _nodeId = '';
  String _errorMessage = '';
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadNodeInfo();
    _startRefreshTimer();
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }
  
  void _startRefreshTimer() {
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _refreshPeers();
    });
  }
  
  Future<void> _loadNodeInfo() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    
    try {
      // Get node information
      final nodeInfo = await widget.meshService.getNodeInfo();
      
      setState(() {
        _nodeId = nodeInfo.id;
      });
      
      // Get network peers
      await _refreshPeers();
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to connect to mesh network: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  Future<void> _refreshPeers() async {
    try {
      final peers = await widget.meshService.getPeers();
      
      setState(() {
        _peers = peers;
      });
    } catch (e) {
      print('Error refreshing peers: $e');
      // Don't update error state here to avoid disrupting the UI
    }
  }
  
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting to mesh network...'),
            ],
          ),
        ),
      );
    }
    
    if (_errorMessage.isNotEmpty) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  _errorMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _loadNodeInfo,
                  child: const Text('Retry Connection'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshTalk'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Theme.of(context).colorScheme.secondary,
          tabs: const [
            Tab(icon: Icon(Icons.mic), text: 'Talk'),
            Tab(icon: Icon(Icons.message), text: 'Chat'),
            Tab(icon: Icon(Icons.network_cell), text: 'Network'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshPeers,
            tooltip: 'Refresh network',
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        physics: const NeverScrollableScrollPhysics(), // Prevent swipe between tabs
        children: [
          WalkieTalkieScreen(
            meshService: widget.meshService,
            peers: _peers,
            nodeId: _nodeId,
          ),
          ChatScreen(
            meshService: widget.meshService,
            peers: _peers, 
            nodeId: _nodeId,
          ),
          MeshVisualizationScreen(
            meshService: widget.meshService,
            peers: _peers,
            nodeId: _nodeId,
          ),
        ],
      ),
    );
  }
}
