import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:feather_icons/feather_icons.dart';

import '../services/mesh_routing.dart';
import '../services/webrtc_service.dart';
import '../models/peer.dart';
import '../ai/speech_commands.dart';

class WalkieTalkieScreen extends StatefulWidget {
  final MeshRoutingService meshService;
  final List<Peer> peers;
  final String nodeId;

  const WalkieTalkieScreen({
    Key? key,
    required this.meshService,
    required this.peers,
    required this.nodeId,
  }) : super(key: key);

  @override
  _WalkieTalkieScreenState createState() => _WalkieTalkieScreenState();
}

class _WalkieTalkieScreenState extends State<WalkieTalkieScreen> with SingleTickerProviderStateMixin {
  // Audio recorder
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  bool _isRecorderInitialized = false;
  bool _isRecording = false;
  bool _isSending = false;
  
  // WebRTC service
  late WebRTCService _webRTCService;
  
  // Voice command processor
  final SpeechCommandProcessor _speechProcessor = SpeechCommandProcessor();
  
  // UI animation
  late AnimationController _animationController;
  
  // Currently selected peer for communication
  Peer? _selectedPeer;
  bool _isBroadcasting = true;
  
  // Voice activity visualization
  List<double> _audioLevels = List.filled(20, 0.1);
  Timer? _audioLevelTimer;
  
  // Status message
  String _statusMessage = '';
  Timer? _statusTimer;
  
  @override
  void initState() {
    super.initState();
    
    // Initialize the WebRTC service
    _webRTCService = WebRTCService(meshService: widget.meshService);
    
    // Initialize animation controller for the push-to-talk button
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    
    // Initialize the recorder
    _initRecorder();
    
    // Listen for incoming calls
    _webRTCService.onCallReceived = _handleIncomingCall;
  }
  
  @override
  void dispose() {
    // Release resources
    _animationController.dispose();
    _recorder.closeRecorder();
    _audioLevelTimer?.cancel();
    _statusTimer?.cancel();
    _webRTCService.dispose();
    super.dispose();
  }
  
  /// Initialize the audio recorder
  Future<void> _initRecorder() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showStatus('Microphone permission denied');
      return;
    }
    
    try {
      await _recorder.openRecorder();
      await _recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
      _isRecorderInitialized = true;
    } catch (e) {
      print('Error initializing recorder: $e');
      _showStatus('Failed to initialize microphone');
    }
  }
  
  /// Start recording audio
  Future<void> _startRecording() async {
    if (!_isRecorderInitialized) {
      await _initRecorder();
    }
    
    try {
      // Configure recording settings for voice transmission
      await _recorder.startRecorder(
        toFile: 'temp_voice',
        codec: Codec.aacMP4,
        sampleRate: 16000,
        numChannels: 1,
      );
      
      setState(() {
        _isRecording = true;
      });
      
      // Start the voice activity animation
      _startAudioLevelVisualization();
      
      // Start the push-to-talk animation
      _animationController.forward();
      
      // Show appropriate status message
      if (_isBroadcasting) {
        _showStatus('Broadcasting to all nodes...');
      } else if (_selectedPeer != null) {
        _showStatus('Talking to ${_selectedPeer!.id.substring(0, 8)}...');
      }
    } catch (e) {
      print('Error starting recorder: $e');
      _showStatus('Failed to start recording');
    }
  }
  
  /// Stop recording and send the audio
  Future<void> _stopRecording() async {
    try {
      if (_isRecording) {
        final recordingPath = await _recorder.stopRecorder();
        
        setState(() {
          _isRecording = false;
          _isSending = true;
        });
        
        // Stop the audio level visualization
        _audioLevelTimer?.cancel();
        
        // Reverse the push-to-talk animation
        _animationController.reverse();
        
        if (recordingPath != null) {
          // Read the recorded file
          final file = await rootBundle.load(recordingPath);
          final bytes = file.buffer.asUint8List();
          
          // Encode as base64
          final base64Audio = base64Encode(bytes);
          
          // Send to selected peer or broadcast
          String? recipientId = _isBroadcasting ? 'broadcast' : _selectedPeer?.id;
          
          if (recipientId != null) {
            await widget.meshService.sendVoiceData(recipientId, base64Audio);
            _showStatus('Voice message sent');
          }
        }
        
        setState(() {
          _isSending = false;
        });
      }
    } catch (e) {
      print('Error stopping recorder: $e');
      _showStatus('Failed to send voice message');
      
      setState(() {
        _isRecording = false;
        _isSending = false;
      });
    }
  }
  
  /// Start visualizing audio levels
  void _startAudioLevelVisualization() {
    _audioLevelTimer?.cancel();
    
    // Reset levels
    setState(() {
      _audioLevels = List.filled(20, 0.1);
    });
    
    // Update audio levels based on recorder decibels
    _audioLevelTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (_recorder.isRecording && _recorder.recorderState == RecorderState.isRecording) {
        _recorder.getRecorderState().then((recorderState) {
          if (recorderState != null) {
            // Get the decibel level and normalize to 0.0-1.0 range
            final db = recorderState.decibels ?? -160.0;
            final normalizedDb = (db + 160.0) / 160.0; // Assuming -160dB as silence
            
            // Update the visualization array
            setState(() {
              _audioLevels.removeAt(0);
              _audioLevels.add(normalizedDb.clamp(0.1, 1.0));
            });
          }
        });
      }
    });
  }
  
  /// Handle incoming voice call
  void _handleIncomingCall(Peer caller) {
    // In this MVP, we just show a notification
    _showStatus('Incoming call from ${caller.id.substring(0, 8)}');
  }
  
  /// Show a temporary status message
  void _showStatus(String message) {
    setState(() {
      _statusMessage = message;
    });
    
    _statusTimer?.cancel();
    _statusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _statusMessage = '';
        });
      }
    });
  }
  
  /// Toggle between broadcast and direct communication
  void _toggleMode() {
    setState(() {
      _isBroadcasting = !_isBroadcasting;
      
      if (_isBroadcasting) {
        _selectedPeer = null;
        _showStatus('Switched to broadcast mode');
      } else if (widget.peers.isNotEmpty) {
        _selectedPeer = widget.peers.first;
        _showStatus('Switched to direct mode: ${_selectedPeer!.id.substring(0, 8)}');
      } else {
        // No peers available, stay in broadcast mode
        _isBroadcasting = true;
        _showStatus('No peers available for direct mode');
      }
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).scaffoldBackgroundColor,
              const Color(0xFF1A1A1A),
            ],
          ),
        ),
        child: Column(
          children: [
            // Mode indicator and selector
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _isBroadcasting 
                        ? 'BROADCAST MODE' 
                        : 'DIRECT MODE',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Switch(
                    value: !_isBroadcasting,
                    activeColor: Theme.of(context).colorScheme.secondary,
                    onChanged: (_) => _toggleMode(),
                  ),
                ],
              ),
            ),
            
            // Peer selector (only visible in direct mode)
            if (!_isBroadcasting)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: DropdownButtonFormField<String>(
                  decoration: const InputDecoration(
                    labelText: 'Select Peer',
                    border: OutlineInputBorder(),
                  ),
                  value: _selectedPeer?.id,
                  items: widget.peers.map((peer) {
                    return DropdownMenuItem(
                      value: peer.id,
                      child: Text(
                        peer.id.substring(0, 8) + '...',
                        style: const TextStyle(fontFamily: 'FiraCode'),
                      ),
                    );
                  }).toList(),
                  onChanged: (peerId) {
                    if (peerId != null) {
                      setState(() {
                        _selectedPeer = widget.peers.firstWhere((p) => p.id == peerId);
                      });
                    }
                  },
                ),
              ),
            
            // Status message display
            if (_statusMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8.0,
                    horizontal: 16.0,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            
            // Voice activity visualization
            Expanded(
              child: Center(
                child: SizedBox(
                  height: 120,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: List.generate(_audioLevels.length, (index) {
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        width: 8,
                        height: _isRecording 
                            ? 20 + (_audioLevels[index] * 100)
                            : 20,
                        decoration: BoxDecoration(
                          color: _isRecording
                              ? HSLColor.fromAHSL(
                                  1.0,
                                  130 - (_audioLevels[index] * 130),
                                  1.0,
                                  0.5,
                                ).toColor()
                              : Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
            
            // Node identifier
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Node ID: ${widget.nodeId.substring(0, 8)}...',
                style: TextStyle(
                  fontFamily: 'FiraCode',
                  color: Colors.grey.shade400,
                  fontSize: 12,
                ),
              ),
            ),
            
            // Push-to-talk button
            Container(
              padding: const EdgeInsets.only(bottom: 60.0),
              child: GestureDetector(
                onTapDown: (_) => _startRecording(),
                onTapUp: (_) => _stopRecording(),
                onTapCancel: () => _stopRecording(),
                child: AnimatedBuilder(
                  animation: _animationController,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: 1.0 - (0.2 * _animationController.value),
                      child: Container(
                        width: 150,
                        height: 150,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRecording 
                              ? Theme.of(context).colorScheme.secondary
                              : Theme.of(context).primaryColor,
                          boxShadow: [
                            BoxShadow(
                              color: _isRecording
                                  ? Theme.of(context).colorScheme.secondary.withOpacity(0.5)
                                  : Theme.of(context).primaryColor.withOpacity(0.3),
                              blurRadius: 20,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Icon(
                            _isRecording 
                                ? FeatherIcons.mic
                                : _isSending
                                    ? FeatherIcons.loader
                                    : FeatherIcons.mic,
                            size: 64,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
