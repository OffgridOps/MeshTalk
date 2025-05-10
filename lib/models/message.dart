/// Represents a message in the mesh network
class Message {
  final String id;
  final String senderId;
  final String recipientId;
  final String content;
  final double timestamp;
  final String type;
  final int? ttl;
  
  Message({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.timestamp,
    required this.type,
    this.ttl,
  });
  
  /// Create a message from JSON
  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'],
      senderId: json['sender_id'],
      recipientId: json['recipient_id'],
      content: json['content'],
      timestamp: json['timestamp'],
      type: json['type'],
      ttl: json['ttl'],
    );
  }
  
  /// Convert message to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'content': content,
      'timestamp': timestamp,
      'type': type,
      if (ttl != null) 'ttl': ttl,
    };
  }
  
  /// Create a new text message
  static Message createText({
    required String id,
    required String senderId,
    required String recipientId,
    required String content,
  }) {
    return Message(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: 'text',
      ttl: 3,
    );
  }
  
  /// Create a new voice message
  static Message createVoice({
    required String id,
    required String senderId,
    required String recipientId,
    required String audioData,
  }) {
    return Message(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      content: audioData, // Base64 encoded audio
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: 'voice',
      ttl: 1, // Lower TTL for voice to reduce latency
    );
  }
  
  /// Create a new broadcast message
  static Message createBroadcast({
    required String id,
    required String senderId,
    required String content,
    required String type,
  }) {
    return Message(
      id: id,
      senderId: senderId,
      recipientId: 'broadcast',
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: type,
      ttl: 3,
    );
  }
  
  /// Create a new system message (for notifications)
  static Message createSystem({
    required String content,
  }) {
    return Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: 'system',
      recipientId: 'local',
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: 'system',
    );
  }
  
  /// Create an SOS emergency message
  static Message createSOS({
    required String id,
    required String senderId,
    required String content,
  }) {
    return Message(
      id: id,
      senderId: senderId,
      recipientId: 'broadcast',
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      type: 'sos',
      ttl: 5, // Higher TTL for emergency messages
    );
  }
  
  /// Check if this message is a broadcast
  bool get isBroadcast => recipientId == 'broadcast';
  
  /// Check if this message is a system message
  bool get isSystem => type == 'system';
  
  /// Check if this message is an SOS message
  bool get isEmergency => type == 'sos';
  
  /// Check if this message is a voice message
  bool get isVoice => type == 'voice';
  
  /// Check if this message is a text message
  bool get isText => type == 'text';
  
  /// Create a copy of this message with modified properties
  Message copyWith({
    String? id,
    String? senderId,
    String? recipientId,
    String? content,
    double? timestamp,
    String? type,
    int? ttl,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      type: type ?? this.type,
      ttl: ttl ?? this.ttl,
    );
  }
}
