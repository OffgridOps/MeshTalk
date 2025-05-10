import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:feather_icons/feather_icons.dart';

import '../services/mesh_routing.dart';
import '../models/peer.dart';

class MeshVisualizationScreen extends StatefulWidget {
  final MeshRoutingService meshService;
  final List<Peer> peers;
  final String nodeId;

  const MeshVisualizationScreen({
    Key? key,
    required this.meshService,
    required this.peers,
    required this.nodeId,
  }) : super(key: key);

  @override
  _MeshVisualizationScreenState createState() => _MeshVisualizationScreenState();
}

class _MeshVisualizationScreenState extends State<MeshVisualizationScreen> with SingleTickerProviderStateMixin {
  // Animation controller for node pulsing effect
  late AnimationController _animationController;
  
  // Node positions for visualization
  Map<String, Offset> _nodePositions = {};
  
  // Canvas size
  Size _canvasSize = Size.zero;
  
  // Selected node for details
  String? _selectedNodeId;
  
  // Activity indicators
  Map<String, bool> _activeNodes = {};
  Timer? _activityTimer;

  @override
  void initState() {
    super.initState();
    
    // Initialize animation controller
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    
    // Initialize node positions
    _initializeNodePositions();
    
    // Simulate node activity
    _startActivitySimulation();
  }
  
  @override
  void didUpdateWidget(MeshVisualizationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Update node positions when peers change
    if (widget.peers.length != oldWidget.peers.length) {
      _initializeNodePositions();
    }
  }
  
  @override
  void dispose() {
    _animationController.dispose();
    _activityTimer?.cancel();
    super.dispose();
  }
  
  /// Initialize random positions for each node
  void _initializeNodePositions() {
    // Clear existing positions
    _nodePositions = {};
    
    // Ensure positions are updated after layout
    WidgetsBinding.instance?.addPostFrameCallback((_) {
      setState(() {
        // Add current node at center
        _nodePositions[widget.nodeId] = Offset(
          _canvasSize.width / 2,
          _canvasSize.height / 2,
        );
        
        // Add peers in a circular layout
        final radius = min(_canvasSize.width, _canvasSize.height) * 0.35;
        final centerX = _canvasSize.width / 2;
        final centerY = _canvasSize.height / 2;
        
        for (int i = 0; i < widget.peers.length; i++) {
          final peer = widget.peers[i];
          final angle = (2 * pi * i) / max(1, widget.peers.length);
          
          _nodePositions[peer.id] = Offset(
            centerX + radius * cos(angle),
            centerY + radius * sin(angle),
          );
        }
      });
    });
  }
  
  /// Start simulating node activity for visualization purposes
  void _startActivitySimulation() {
    _activityTimer?.cancel();
    
    _activityTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted) return;
      
      setState(() {
        // Reset all nodes to inactive
        _activeNodes = {};
        
        // Randomly activate some nodes
        final random = Random();
        for (final peer in widget.peers) {
          if (random.nextDouble() < 0.3) {
            _activeNodes[peer.id] = true;
          }
        }
        
        // Current node is always active
        _activeNodes[widget.nodeId] = true;
      });
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Mesh statistics
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mesh Network',
                  style: Theme.of(context).textTheme.headline6,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildStatCard(
                      title: 'Nodes',
                      value: (widget.peers.length + 1).toString(),
                      icon: FeatherIcons.users,
                    ),
                    _buildStatCard(
                      title: 'Active',
                      value: _activeNodes.length.toString(),
                      icon: FeatherIcons.activity,
                    ),
                    _buildStatCard(
                      title: 'Latency',
                      value: '~90ms',
                      icon: FeatherIcons.clock,
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // Mesh visualization
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Update canvas size for node positioning
                _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                
                return GestureDetector(
                  onTapDown: (details) => _handleTapOnCanvas(details.localPosition),
                  child: Container(
                    color: Colors.transparent,
                    child: Stack(
                      children: [
                        // Connection lines
                        CustomPaint(
                          size: Size.infinite,
                          painter: MeshConnectionPainter(
                            nodePositions: _nodePositions,
                            currentNodeId: widget.nodeId,
                            activeNodes: _activeNodes,
                            animationValue: _animationController.value,
                          ),
                        ),
                        
                        // Nodes
                        ...widget.peers.map((peer) => _buildNodeWidget(peer.id, false)),
                        
                        // Current node (self)
                        _buildNodeWidget(widget.nodeId, true),
                        
                        // Selected node details
                        if (_selectedNodeId != null)
                          _buildNodeDetails(_selectedNodeId!),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
  
  /// Build a statistics card
  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.secondary),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            title,
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
  
  /// Build a node widget at the specified position
  Widget _buildNodeWidget(String nodeId, bool isCurrentNode) {
    final position = _nodePositions[nodeId];
    if (position == null) return Container();
    
    final isActive = _activeNodes[nodeId] ?? false;
    
    return Positioned(
      left: position.dx - 25,
      top: position.dy - 25,
      child: GestureDetector(
        onTap: () => _selectNode(nodeId),
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isCurrentNode
                    ? Theme.of(context).primaryColor
                    : isActive
                        ? Theme.of(context).colorScheme.secondary
                        : Colors.grey.shade800,
                border: Border.all(
                  color: isCurrentNode
                      ? Theme.of(context).primaryColor.withOpacity(0.5 + 0.5 * _animationController.value)
                      : isActive
                          ? Theme.of(context).colorScheme.secondary.withOpacity(0.5 + 0.5 * _animationController.value)
                          : Colors.grey.shade700,
                  width: 3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isCurrentNode
                        ? Theme.of(context).primaryColor.withOpacity(0.3)
                        : isActive
                            ? Theme.of(context).colorScheme.secondary.withOpacity(0.3)
                            : Colors.transparent,
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  nodeId.substring(0, 2),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'FiraCode',
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
  
  /// Build node details widget
  Widget _buildNodeDetails(String nodeId) {
    final position = _nodePositions[nodeId];
    if (position == null) return Container();
    
    final isCurrentNode = nodeId == widget.nodeId;
    final peer = widget.peers.firstWhere(
      (p) => p.id == nodeId,
      orElse: () => Peer(
        id: nodeId,
        address: 'local',
        lastSeen: DateTime.now().millisecondsSinceEpoch / 1000,
      ),
    );
    
    // Position the details panel based on node position
    double left = position.dx + 30;
    if (left > _canvasSize.width - 220) {
      left = position.dx - 220;
    }
    
    double top = position.dy - 80;
    if (top < 10) {
      top = 10;
    } else if (top > _canvasSize.height - 150) {
      top = _canvasSize.height - 150;
    }
    
    return Positioned(
      left: left,
      top: top,
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCurrentNode
                ? Theme.of(context).primaryColor
                : Theme.of(context).colorScheme.secondary,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isCurrentNode ? 'Your Node' : 'Peer Node',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _selectedNodeId = null),
                  child: const Icon(
                    FeatherIcons.x,
                    size: 16,
                  ),
                ),
              ],
            ),
            const Divider(),
            Text(
              'ID: ${nodeId.substring(0, 16)}...',
              style: const TextStyle(
                fontFamily: 'FiraCode',
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Address: ${peer.address}',
              style: const TextStyle(
                fontFamily: 'FiraCode',
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Status: ${_activeNodes[nodeId] ?? false ? 'Active' : 'Idle'}',
              style: TextStyle(
                color: (_activeNodes[nodeId] ?? false)
                    ? Theme.of(context).colorScheme.secondary
                    : Colors.grey,
                fontSize: 12,
              ),
            ),
            if (!isCurrentNode) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildActionButton(
                    icon: FeatherIcons.messageCircle,
                    label: 'Message',
                    onTap: () => _messageNode(nodeId),
                  ),
                  _buildActionButton(
                    icon: FeatherIcons.phone,
                    label: 'Call',
                    onTap: () => _callNode(nodeId),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
  
  /// Build an action button for the node details panel
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 16,
              color: Theme.of(context).primaryColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey.shade300,
            ),
          ),
        ],
      ),
    );
  }
  
  /// Handle tap on the canvas, selecting nodes if tapped
  void _handleTapOnCanvas(Offset tapPosition) {
    // Check if a node was tapped
    for (final entry in _nodePositions.entries) {
      final nodeId = entry.key;
      final position = entry.value;
      
      // Calculate distance from tap to node center
      final distance = (tapPosition - position).distance;
      
      // If tap is within node radius, select the node
      if (distance <= 25) {
        _selectNode(nodeId);
        return;
      }
    }
    
    // If no node was tapped, clear selection
    setState(() {
      _selectedNodeId = null;
    });
  }
  
  /// Select a node to display its details
  void _selectNode(String nodeId) {
    setState(() {
      // Toggle selection
      _selectedNodeId = _selectedNodeId == nodeId ? null : nodeId;
    });
  }
  
  /// Message the selected node
  void _messageNode(String nodeId) {
    // Navigate to the chat tab with this peer selected
    // This is a placeholder for future implementation
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Messaging ${nodeId.substring(0, 8)}...'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
  
  /// Call the selected node
  void _callNode(String nodeId) {
    // Navigate to the walkie-talkie tab with this peer selected
    // This is a placeholder for future implementation
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Calling ${nodeId.substring(0, 8)}...'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// Custom painter for mesh connections
class MeshConnectionPainter extends CustomPainter {
  final Map<String, Offset> nodePositions;
  final String currentNodeId;
  final Map<String, bool> activeNodes;
  final double animationValue;
  
  MeshConnectionPainter({
    required this.nodePositions,
    required this.currentNodeId,
    required this.activeNodes,
    required this.animationValue,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    if (nodePositions.isEmpty) return;
    
    // Get current node position
    final currentPosition = nodePositions[currentNodeId];
    if (currentPosition == null) return;
    
    // Draw connections between nodes
    for (final entry in nodePositions.entries) {
      if (entry.key == currentNodeId) continue;
      
      final peerId = entry.key;
      final peerPosition = entry.value;
      final isActive = activeNodes[peerId] ?? false;
      
      // Draw connection from current node to peer
      final paint = Paint()
        ..color = isActive
            ? Color.lerp(
                Colors.grey.shade700,
                Theme.of(activeNodes[currentNodeId] != null
                    ? ThemeData.dark().colorScheme.secondary
                    : ThemeData.dark().primaryColor),
                0.3 + 0.7 * animationValue,
              ) ?? Colors.grey.shade700
            : Colors.grey.shade800
        ..strokeWidth = isActive ? 2 : 1
        ..style = PaintingStyle.stroke;
      
      // Draw dashed line
      final path = Path();
      path.moveTo(currentPosition.dx, currentPosition.dy);
      path.lineTo(peerPosition.dx, peerPosition.dy);
      
      if (isActive) {
        // Animated line for active connections
        canvas.drawPath(path, paint);
        
        // Draw animated data flowing from current node to peer
        _drawAnimatedData(canvas, currentPosition, peerPosition, animationValue);
      } else {
        // Dashed line for inactive connections
        _drawDashedPath(canvas, path, paint);
      }
    }
  }
  
  /// Draw a dashed path
  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    const dashWidth = 5;
    const dashSpace = 5;
    
    final metrics = path.computeMetrics().first;
    final length = metrics.length;
    
    double distance = 0;
    while (distance < length) {
      final start = distance;
      distance += dashWidth;
      if (distance > length) distance = length;
      
      final extractPath = metrics.extractPath(start, distance);
      canvas.drawPath(extractPath, paint);
      
      distance += dashSpace;
    }
  }
  
  /// Draw animated data flowing between nodes
  void _drawAnimatedData(Canvas canvas, Offset start, Offset end, double animation) {
    // Calculate direction vector
    final direction = end - start;
    final length = direction.distance;
    
    // Calculate position along the line based on animation value
    final position = start + direction * ((animation * 3) % 1.0);
    
    // Draw data packet
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    
    canvas.drawCircle(position, 3, paint);
  }
  
  @override
  bool shouldRepaint(covariant MeshConnectionPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
           oldDelegate.nodePositions != nodePositions ||
           oldDelegate.activeNodes != activeNodes;
  }
}
