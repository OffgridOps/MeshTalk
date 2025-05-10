# MeshTalk Protocol Specification

## Overview

MeshTalk is a decentralized, offline-capable communication protocol designed to enable secure messaging and voice communication over mesh networks. The protocol is designed to be resilient, privacy-focused, and resistant to quantum computing attacks.

This document outlines the technical specifications of the MeshTalk protocol, including networking, security, and data formats.

## Core Protocol Architecture

MeshTalk uses a hybrid network architecture:

1. **UDP** for voice transmission (low latency)
2. **TCP** for signaling and text messages (reliability)
3. **BATMAN-Adv** for mesh routing when available

### Network Topology

MeshTalk operates in a fully decentralized peer-to-peer mesh network without central servers. Each node can:

- Discover other nodes on the local network
- Relay messages to extend network reach
- Operate fully offline without internet access
- Connect directly to peers via WiFi Direct or Bluetooth

### Port Usage

- **8000/TCP**: API Server and signaling
- **8001/UDP**: Voice data transmission
- **4443/TCP**: WebRTC data channel (when available)

## Node Discovery and Routing

### Node Identification

Each node has a unique identifier generated using UUID v4, which is created at first launch and persisted. Nodes do not use phone numbers, email addresses, or persistent IP addresses for identification to enhance privacy.

### Discovery Protocol

1. When a node starts, it broadcasts a discovery message to the local network
2. The discovery message contains:
   - Node ID
   - Public key
   - Listening port
   - Capabilities (voice, text, relay)

3. Receiving nodes add the new node to their routing tables
4. Periodic announcements maintain network topology awareness

### Mesh Routing

MeshTalk uses BATMAN-Adv (Better Approach To Mobile Ad-hoc Networking) when available on Linux systems, falling back to application-layer routing when BATMAN-Adv is not available:

1. Each node maintains a routing table with:
   - Node IDs
   - Last known address
   - Last seen timestamp
   - Connection quality metrics

2. Messages include TTL (Time-to-Live) to limit propagation depth
3. Duplicate message detection prevents routing loops
4. Path optimization uses TinyML (when available) to predict optimal routes

## Message Format

### Common Header

All MeshTalk messages share a common header structure:

```json
{
  "id": "unique-message-id",
  "sender_id": "originating-node-id",
  "recipient_id": "destination-node-id-or-broadcast",
  "type": "message-type",
  "timestamp": 1636142730.45,
  "ttl": 3
}
