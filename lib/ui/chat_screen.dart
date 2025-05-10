import 'dart:async';

import 'package:flutter/material.dart';
import 'package:feather_icons/feather_icons.dart';
import 'package:intl/intl.dart';

import '../services/mesh_routing.dart';
import '../models/peer.dart';
import '../models/message.dart';

class ChatScreen extends StatefulWidget {
  final MeshRoutingService meshService;
  final List<Peer> peers;
  final String nodeId;

  const ChatScreen({
    Key? key,
    required this.meshService,
    required this.peers,
    required this.nodeId,
  }) : super(key: key);

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // Chat state
  List<Message> _messages = [];
  Timer? _messageRefreshTimer;
  bool _isLoading = true;
  String? _errorMessage;
  
  // Message input
  final TextEditingController _messageController = TextEditingController();
  bool _isSending = false;
  
  // Chat preferences
  bool _isBroadcast = true;
  String? _selectedPeerId;
  
  @override
  void initState() {
    super.initState();
    _loadMessages();
    _startMessageRefreshTimer();
  }
  
  @override
  void dispose() {
    _messageController.dispose();
    _messageRefreshTimer?.cancel();
    super.dispose();
  }
  
  /// Load messages from the mesh network
  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    
    try {
      final messages = await widget.meshService.getMessages();
      
      setState(() {
        _messages = messages;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load messages: $e';
        _isLoading = false;
      });
    }
  }
  
  /// Start timer to periodically refresh messages
  void _startMessageRefreshTimer() {
    _messageRefreshTimer?.cancel();
    
    _messageRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        _refreshMessages();
      }
    });
  }
  
  /// Refresh messages without loading indicator
  Future<void> _refreshMessages() async {
    try {
      final messages = await widget.meshService.getMessages();
      
      if (mounted) {
        setState(() {
          _messages = messages;
        });
      }
    } catch (e) {
      print('Error refreshing messages: $e');
      // Don't show error on automatic refresh
    }
  }
  
  /// Send a new message
  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    
    final recipientId = _isBroadcast ? 'broadcast' : _selectedPeerId;
    if (!_isBroadcast && recipientId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a recipient')),
      );
      return;
    }
    
    setState(() {
      _isSending = true;
    });
    
    try {
      await widget.meshService.sendTextMessage(recipientId!, text);
      
      // Clear the message input
      _messageController.clear();
      
      // Refresh messages to see the new message
      await _refreshMessages();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }
  
  /// Toggle between broadcast and direct message modes
  void _toggleMessageMode() {
    setState(() {
      _isBroadcast = !_isBroadcast;
      
      // If switching to direct mode and no peer is selected,
      // select the first available peer
      if (!_isBroadcast && _selectedPeerId == null && widget.peers.isNotEmpty) {
        _selectedPeerId = widget.peers.first.id;
      }
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Chat mode selector
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _isBroadcast ? 'Broadcasting to all nodes' : 'Direct message',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Switch(
                  value: !_isBroadcast,
                  activeColor: Theme.of(context).colorScheme.secondary,
                  onChanged: (_) => _toggleMessageMode(),
                ),
              ],
            ),
          ),
          
          // Peer selector for direct messages
          if (!_isBroadcast)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Select Recipient',
                  border: OutlineInputBorder(),
                ),
                value: _selectedPeerId,
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
                  setState(() {
                    _selectedPeerId = peerId;
                  });
                },
              ),
            ),
          
          // Messages list
          Expanded(
            child: _buildMessagesList(),
          ),
          
          // Message input
          _buildMessageInput(),
        ],
      ),
    );
  }
  
  /// Build the messages list view
  Widget _buildMessagesList() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }
    
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              FeatherIcons.alertCircle,
              color: Colors.red,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadMessages,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              FeatherIcons.messageCircle,
              color: Colors.grey.shade700,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'No messages yet',
              style: TextStyle(
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Start a conversation',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }
    
    // Sort messages by timestamp (newest last)
    final sortedMessages = List<Message>.from(_messages)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: sortedMessages.length,
      itemBuilder: (context, index) {
        final message = sortedMessages[index];
        final isCurrentUser = message.senderId == widget.nodeId;
        
        return _buildMessageItem(message, isCurrentUser);
      },
    );
  }
  
  /// Build a message bubble
  Widget _buildMessageItem(Message message, bool isCurrentUser) {
    // Format timestamp
    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      (message.timestamp * 1000).toInt(),
    );
    final timeString = DateFormat.Hm().format(timestamp);
    final dateString = _isToday(timestamp)
        ? 'Today'
        : _isYesterday(timestamp)
            ? 'Yesterday'
            : DateFormat.yMMMd().format(timestamp);
    
    // Determine sender display name
    final senderName = isCurrentUser
        ? 'You'
        : message.senderId.substring(0, 8) + '...';
    
    return Align(
      alignment: isCurrentUser
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
        child: Column(
          crossAxisAlignment: isCurrentUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            // Message header with sender and timestamp
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    senderName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isCurrentUser
                          ? Theme.of(context).colorScheme.secondary
                          : Colors.grey.shade400,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$dateString, $timeString',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
            
            // Message bubble
            Container(
              margin: const EdgeInsets.only(top: 4.0),
              padding: const EdgeInsets.symmetric(
                vertical: 10.0,
                horizontal: 16.0,
              ),
              decoration: BoxDecoration(
                color: isCurrentUser
                    ? Theme.of(context).primaryColor
                    : Colors.grey.shade800,
                borderRadius: BorderRadius.circular(20.0),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    offset: const Offset(0, 1),
                    blurRadius: 3,
                  ),
                ],
              ),
              child: Text(
                message.content,
                style: TextStyle(
                  color: isCurrentUser
                      ? Colors.white
                      : Colors.white,
                ),
              ),
            ),
            
            // Broadcast indicator
            if (message.recipientId == 'broadcast')
              Padding(
                padding: const EdgeInsets.only(top: 4.0, left: 12.0, right: 12.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FeatherIcons.radio,
                      size: 10,
                      color: Colors.grey.shade500,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Broadcast',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
  
  /// Build the message input area
  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            offset: const Offset(0, -1),
            blurRadius: 3,
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            // Text input
            Expanded(
              child: TextField(
                controller: _messageController,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                decoration: InputDecoration(
                  hintText: _isBroadcast
                      ? 'Broadcast to everyone...'
                      : 'Message to ${_selectedPeerId?.substring(0, 8) ?? 'peer'}...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24.0),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade800,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 8.0,
                  ),
                ),
              ),
            ),
            
            // Send button
            const SizedBox(width: 8.0),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: _isSending
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Icon(FeatherIcons.send),
                color: Colors.white,
                onPressed: _isSending ? null : _sendMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  /// Check if the given date is today
  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }
  
  /// Check if the given date is yesterday
  bool _isYesterday(DateTime date) {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    return date.year == yesterday.year &&
        date.month == yesterday.month &&
        date.day == yesterday.day;
  }
}
