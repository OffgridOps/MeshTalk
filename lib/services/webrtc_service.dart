import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sdp_transform/sdp_transform.dart';

import 'mesh_routing.dart';
import '../models/peer.dart';

/// Service for WebRTC-based peer-to-peer communication
class WebRTCService {
  // Dependencies
  final MeshRoutingService meshService;
  
  // WebRTC objects
  Map<String, RTCPeerConnection> _peerConnections = {};
  Map<String, RTCDataChannel> _dataChannels = {};
  final Map<String, MediaStream> _remoteStreams = {};
  MediaStream? _localStream;
  
  // Call state
  bool _isCalling = false;
  String? _currentCallPeer;
  
  // WebRTC configuration
  final _iceServers = {
    'iceServers': [
      // Use local LAN ICE servers only - no STUN/TURN for offline mode
      {'urls': 'stun:stun.l.google.com:19302'}, // Fallback if available
    ]
  };
  
  final _sdpConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': false,
    },
    'optional': [],
  };
  
  final _mediaConstraints = {
    'audio': true,
    'video': false,
  };
  
  // Callback functions
  Function(Peer)? onCallReceived;
  Function(RTCPeerConnectionState)? onConnectionStateChange;
  Function(MediaStream)? onRemoteStreamAdded;
  Function(String)? onDataChannelMessage;

  WebRTCService({required this.meshService});

  /// Initialize WebRTC resources
  Future<void> initialize() async {
    await _initLocalStream();
  }
  
  /// Dispose of WebRTC resources
  void dispose() {
    _stopLocalStream();
    _disposeConnections();
  }
  
  /// Initialize the local audio stream
  Future<void> _initLocalStream() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia(_mediaConstraints);
    } catch (e) {
      print('Failed to get local stream: $e');
    }
  }
  
  /// Stop and dispose the local stream
  void _stopLocalStream() {
    _localStream?.getTracks().forEach((track) {
      track.stop();
    });
    _localStream?.dispose();
    _localStream = null;
  }
  
  /// Dispose of all peer connections
  void _disposeConnections() {
    _peerConnections.forEach((peerId, pc) {
      pc.close();
    });
    _peerConnections.clear();
    
    _dataChannels.forEach((peerId, dc) {
      dc.close();
    });
    _dataChannels.clear();
    
    _remoteStreams.forEach((peerId, stream) {
      stream.dispose();
    });
    _remoteStreams.clear();
  }
  
  /// Create a peer connection for the given peer
  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    RTCPeerConnection pc = await createPeerConnection(_iceServers, _sdpConstraints);
    
    // Add local stream tracks to the connection
    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
        pc.addTrack(track, _localStream!);
      });
    }
    
    // Listen for remote streams
    pc.onAddStream = (MediaStream stream) {
      _remoteStreams[peerId] = stream;
      if (onRemoteStreamAdded != null) {
        onRemoteStreamAdded!(stream);
      }
    };
    
    // Handle connection state changes
    pc.onConnectionState = (RTCPeerConnectionState state) {
      print('Connection state change: $state');
      if (onConnectionStateChange != null) {
        onConnectionStateChange!(state);
      }
      
      // Clean up when connection is closed or failed
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _cleanupPeerConnection(peerId);
      }
    };
    
    // Create data channel for messaging
    RTCDataChannelInit dataChannelInit = RTCDataChannelInit();
    dataChannelInit.ordered = true;
    
    RTCDataChannel dataChannel = await pc.createDataChannel('messaging', dataChannelInit);
    _setupDataChannel(peerId, dataChannel);
    
    // Handle ICE candidates
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      _sendIceCandidate(peerId, candidate);
    };
    
    return pc;
  }
  
  /// Set up data channel event handlers
  void _setupDataChannel(String peerId, RTCDataChannel dataChannel) {
    _dataChannels[peerId] = dataChannel;
    
    dataChannel.onMessage = (RTCDataChannelMessage message) {
      if (onDataChannelMessage != null) {
        onDataChannelMessage!(message.text);
      }
      
      // Process the message
      _processDataChannelMessage(peerId, message.text);
    };
    
    dataChannel.onDataChannelState = (RTCDataChannelState state) {
      print('Data channel state: $state');
    };
  }
  
  /// Process messages received via data channel
  void _processDataChannelMessage(String peerId, String message) {
    try {
      final data = json.decode(message);
      
      // Handle different message types
      switch (data['type']) {
        case 'chat':
          print('Received chat message: ${data['text']}');
          break;
        case 'signal':
          // Handle signaling messages for call setup
          break;
        default:
          print('Unknown message type: ${data['type']}');
      }
    } catch (e) {
      print('Error processing data channel message: $e');
    }
  }
  
  /// Send an ICE candidate to a peer via the mesh network
  Future<void> _sendIceCandidate(String peerId, RTCIceCandidate candidate) async {
    // In a real implementation, this would send the candidate via a signaling mechanism
    // For MeshTalk, we'll use our mesh network for signaling
    try {
      final iceCandidateJson = {
        'type': 'ice_candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      };
      
      // Send via mesh network message system
      await meshService.sendTextMessage(
        peerId,
        json.encode({
          'type': 'webrtc_signal',
          'data': iceCandidateJson,
        }),
      );
    } catch (e) {
      print('Error sending ICE candidate: $e');
    }
  }
  
  /// Process a received ICE candidate
  Future<void> _processIceCandidate(String peerId, Map<String, dynamic> candidateData) async {
    try {
      RTCIceCandidate candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );
      
      final pc = _peerConnections[peerId];
      if (pc != null) {
        await pc.addCandidate(candidate);
      }
    } catch (e) {
      print('Error processing ICE candidate: $e');
    }
  }
  
  /// Make a voice call to a peer
  Future<bool> callPeer(String peerId) async {
    if (_isCalling) {
      print('Already in a call');
      return false;
    }
    
    try {
      _isCalling = true;
      _currentCallPeer = peerId;
      
      // Create peer connection
      final pc = await _createPeerConnection(peerId);
      _peerConnections[peerId] = pc;
      
      // Create offer
      RTCSessionDescription offer = await pc.createOffer(_sdpConstraints);
      await pc.setLocalDescription(offer);
      
      // Send offer via mesh network
      final sdpJson = parse(offer.sdp!);
      final offerJson = {
        'type': 'offer',
        'sdp': sdpJson,
      };
      
      await meshService.sendTextMessage(
        peerId,
        json.encode({
          'type': 'webrtc_signal',
          'data': offerJson,
        }),
      );
      
      return true;
    } catch (e) {
      print('Error making call: $e');
      _isCalling = false;
      _currentCallPeer = null;
      return false;
    }
  }
  
  /// Answer an incoming call
  Future<bool> answerCall(String peerId, Map<String, dynamic> offerData) async {
    if (_isCalling) {
      print('Already in a call');
      return false;
    }
    
    try {
      _isCalling = true;
      _currentCallPeer = peerId;
      
      // Create peer connection
      final pc = await _createPeerConnection(peerId);
      _peerConnections[peerId] = pc;
      
      // Set remote description from offer
      final sdp = write(offerData['sdp'], null);
      await pc.setRemoteDescription(
        RTCSessionDescription(sdp, 'offer'),
      );
      
      // Create answer
      RTCSessionDescription answer = await pc.createAnswer(_sdpConstraints);
      await pc.setLocalDescription(answer);
      
      // Send answer via mesh network
      final sdpJson = parse(answer.sdp!);
      final answerJson = {
        'type': 'answer',
        'sdp': sdpJson,
      };
      
      await meshService.sendTextMessage(
        peerId,
        json.encode({
          'type': 'webrtc_signal',
          'data': answerJson,
        }),
      );
      
      return true;
    } catch (e) {
      print('Error answering call: $e');
      _isCalling = false;
      _currentCallPeer = null;
      return false;
    }
  }
  
  /// Process an answer to our call offer
  Future<void> processAnswer(String peerId, Map<String, dynamic> answerData) async {
    try {
      final pc = _peerConnections[peerId];
      if (pc != null) {
        final sdp = write(answerData['sdp'], null);
        await pc.setRemoteDescription(
          RTCSessionDescription(sdp, 'answer'),
        );
      }
    } catch (e) {
      print('Error processing answer: $e');
    }
  }
  
  /// End the current call
  Future<void> endCall() async {
    if (!_isCalling || _currentCallPeer == null) {
      return;
    }
    
    try {
      // Send end call signal
      await meshService.sendTextMessage(
        _currentCallPeer!,
        json.encode({
          'type': 'webrtc_signal',
          'data': {'type': 'end_call'},
        }),
      );
      
      // Clean up resources
      _cleanupPeerConnection(_currentCallPeer!);
      
      _isCalling = false;
      _currentCallPeer = null;
    } catch (e) {
      print('Error ending call: $e');
    }
  }
  
  /// Clean up a peer connection
  void _cleanupPeerConnection(String peerId) {
    final pc = _peerConnections[peerId];
    if (pc != null) {
      pc.close();
      _peerConnections.remove(peerId);
    }
    
    final dc = _dataChannels[peerId];
    if (dc != null) {
      dc.close();
      _dataChannels.remove(peerId);
    }
    
    final stream = _remoteStreams[peerId];
    if (stream != null) {
      stream.dispose();
      _remoteStreams.remove(peerId);
    }
  }
  
  /// Handle an incoming WebRTC signaling message
  Future<void> handleSignalingMessage(String peerId, Map<String, dynamic> message) async {
    try {
      final signalType = message['type'];
      final data = message['data'];
      
      switch (signalType) {
        case 'offer':
          // Handle incoming call offer
          final peer = Peer(
            id: peerId,
            address: 'unknown',
            lastSeen: DateTime.now().millisecondsSinceEpoch / 1000,
          );
          
          if (onCallReceived != null) {
            onCallReceived!(peer);
          }
          break;
          
        case 'answer':
          // Handle answer to our call
          await processAnswer(peerId, data);
          break;
          
        case 'ice_candidate':
          // Handle ICE candidate
          await _processIceCandidate(peerId, data);
          break;
          
        case 'end_call':
          // Handle call ended by peer
          _cleanupPeerConnection(peerId);
          _isCalling = false;
          _currentCallPeer = null;
          break;
          
        default:
          print('Unknown signaling message type: $signalType');
      }
    } catch (e) {
      print('Error handling signaling message: $e');
    }
  }
  
  /// Send a chat message via data channel
  Future<bool> sendDataChannelMessage(String peerId, String message) async {
    try {
      final dataChannel = _dataChannels[peerId];
      if (dataChannel != null && dataChannel.state == RTCDataChannelState.RTCDataChannelOpen) {
        final messageData = {
          'type': 'chat',
          'text': message,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };
        
        dataChannel.send(RTCDataChannelMessage(json.encode(messageData)));
        return true;
      } else {
        // No open data channel, fallback to mesh network
        return false;
      }
    } catch (e) {
      print('Error sending data channel message: $e');
      return false;
    }
  }
  
  /// Get call status information
  Map<String, dynamic> getCallStatus() {
    return {
      'isCalling': _isCalling,
      'currentPeer': _currentCallPeer,
      'hasLocalStream': _localStream != null,
      'activeConnections': _peerConnections.length,
    };
  }
}
