/// Represents a peer node in the mesh network
class Peer {
  final String id;
  final String address;
  final double lastSeen;
  final String? publicKey;
  final int? port;
  final bool isActive;
  
  Peer({
    required this.id,
    required this.address,
    required this.lastSeen,
    this.publicKey,
    this.port,
    this.isActive = true,
  });
  
  /// Create a peer from JSON
  factory Peer.fromJson(Map<String, dynamic> json) {
    return Peer(
      id: json['id'],
      address: json['address'],
      lastSeen: json['last_seen'].toDouble(),
      publicKey: json['public_key'],
      port: json['port'],
      isActive: json['is_active'] ?? true,
    );
  }
  
  /// Convert peer to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'address': address,
      'last_seen': lastSeen,
      if (publicKey != null) 'public_key': publicKey,
      if (port != null) 'port': port,
      'is_active': isActive,
    };
  }
  
  /// Get a shortened ID for display
  String get shortId {
    if (id.length <= 8) return id;
    return '${id.substring(0, 8)}...';
  }
  
  /// Check if the peer was seen recently (last 2 minutes)
  bool get isRecent {
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    return now - lastSeen < 120; // 2 minutes
  }
  
  /// Check if this is a local peer (self)
  bool get isLocal => address == 'local' || address == 'localhost' || address == '127.0.0.1';
  
  /// Create a copy of this peer with modified properties
  Peer copyWith({
    String? id,
    String? address,
    double? lastSeen,
    String? publicKey,
    int? port,
    bool? isActive,
  }) {
    return Peer(
      id: id ?? this.id,
      address: address ?? this.address,
      lastSeen: lastSeen ?? this.lastSeen,
      publicKey: publicKey ?? this.publicKey,
      port: port ?? this.port,
      isActive: isActive ?? this.isActive,
    );
  }
  
  /// Create a local peer (self)
  static Peer createLocalPeer(String id, {String? publicKey}) {
    return Peer(
      id: id,
      address: 'local',
      lastSeen: DateTime.now().millisecondsSinceEpoch / 1000,
      publicKey: publicKey,
      isActive: true,
    );
  }
  
  /// Create an offline peer
  static Peer createOfflinePeer(String id, String address) {
    return Peer(
      id: id,
      address: address,
      lastSeen: 0,
      isActive: false,
    );
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Peer && other.id == id;
  }
  
  @override
  int get hashCode => id.hashCode;
}
