#!/usr/bin/env python3
"""
MeshTalk Mesh Relay
Handles mesh network routing for the MeshTalk application.
"""

import socket
import threading
import time
import json
import logging
import os
import uuid
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Set
import subprocess

from crypto import encrypt_message, decrypt_message, generate_keypair

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("mesh_relay")

@dataclass
class Node:
    """Represents a node in the mesh network."""
    id: str
    address: str
    port: int
    last_seen: float
    public_key: str
    is_active: bool = True

@dataclass
class Message:
    """Message structure for the mesh network."""
    id: str
    sender_id: str
    recipient_id: str  # Can be "broadcast" for broadcast messages
    type: str  # "text", "voice", "discovery", "routing"
    content: str
    timestamp: float
    ttl: int = 3  # Time-to-live for message propagation

class MeshRelay:
    """
    Implements a mesh network relay using UDP for communication
    and integrates with BATMAN-Adv when available.
    """
    
    def __init__(self, host='0.0.0.0', port=8000):
        """Initialize the mesh relay."""
        self.host = host
        self.port = port
        self.node_id = str(uuid.uuid4())
        self.public_key, self.private_key = generate_keypair()
        
        # Store known nodes in the network
        self.nodes: Dict[str, Node] = {}
        
        # Store processed message IDs to avoid re-processing
        self.processed_messages: Set[str] = set()
        
        # UDP socket for communication
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((self.host, self.port))
        
        # Check if BATMAN-Adv is available
        self.batman_available = self._check_batman_adv()
        if self.batman_available:
            logger.info("BATMAN-Adv routing available")
            self._setup_batman_adv()
        else:
            logger.info("BATMAN-Adv not available, using basic mesh routing")
        
        # Start threads for receiving messages and node maintenance
        self.running = True
        self.receiver_thread = threading.Thread(target=self._receive_messages)
        self.maintenance_thread = threading.Thread(target=self._maintain_nodes)
        
    def start(self):
        """Start the mesh relay."""
        logger.info(f"Starting mesh relay on {self.host}:{self.port}, Node ID: {self.node_id}")
        self.receiver_thread.start()
        self.maintenance_thread.start()
        self._send_discovery()
    
    def stop(self):
        """Stop the mesh relay."""
        logger.info("Stopping mesh relay")
        self.running = False
        self.socket.close()
        self.receiver_thread.join()
        self.maintenance_thread.join()
    
    def _check_batman_adv(self) -> bool:
        """Check if BATMAN-Adv is available on the system."""
        try:
            result = subprocess.run(
                ["modprobe", "-n", "batman-adv"], 
                capture_output=True, 
                text=True
            )
            return result.returncode == 0
        except Exception:
            return False
    
    def _setup_batman_adv(self):
        """Setup BATMAN-Adv if available."""
        try:
            # This requires root privileges, might not work in all environments
            wlan_iface = os.environ.get("MESHTALK_IFACE", "wlan0")
            bat_iface = "bat0"
            
            # Load batman-adv module
            subprocess.run(["modprobe", "batman-adv"])
            
            # Configure interface for batman-adv
            subprocess.run(["ip", "link", "set", wlan_iface, "down"])
            subprocess.run(["ip", "link", "set", wlan_iface, "mtu", "1532"])
            subprocess.run(["ip", "link", "set", wlan_iface, "up"])
            subprocess.run(["iw", wlan_iface, "set", "type", "ibss"])
            subprocess.run(["iw", wlan_iface, "ibss", "join", "meshtalk", "2412"])
            
            # Activate batman-adv
            subprocess.run(["echo", "bat0"], stdout=open("/sys/class/net/wlan0/batman_adv/mesh_iface", "w"))
            subprocess.run(["ip", "link", "set", "up", "dev", bat_iface])
            
            logger.info(f"BATMAN-Adv configured on {wlan_iface}")
        except Exception as e:
            logger.error(f"Failed to setup BATMAN-Adv: {str(e)}")
            self.batman_available = False
    
    def _receive_messages(self):
        """Continuously receive and process incoming messages."""
        while self.running:
            try:
                data, addr = self.socket.recvfrom(65536)  # Large buffer for voice data
                self._handle_message(data, addr)
            except Exception as e:
                if self.running:  # Only log if not intentionally stopped
                    logger.error(f"Error receiving message: {str(e)}")
    
    def _handle_message(self, data, addr):
        """Handle an incoming message."""
        try:
            # Decrypt and parse the message
            decrypted_data = decrypt_message(data, self.private_key)
            message_dict = json.loads(decrypted_data)
            message = Message(**message_dict)
            
            # Skip if we've already processed this message
            if message.id in self.processed_messages:
                return
            
            self.processed_messages.add(message.id)
            
            # Process based on message type
            if message.type == "discovery":
                self._handle_discovery(message, addr)
            elif message.type == "routing":
                self._handle_routing(message)
            elif message.type == "text" or message.type == "voice":
                self._handle_data(message)
            
            # Relay message if TTL allows
            if message.ttl > 0:
                message.ttl -= 1
                self._relay_message(message)
                
        except Exception as e:
            logger.error(f"Error handling message: {str(e)}")
    
    def _handle_discovery(self, message, addr):
        """Handle a discovery message from a node."""
        content = json.loads(message.content)
        node = Node(
            id=message.sender_id,
            address=addr[0],
            port=content.get("port", self.port),
            last_seen=time.time(),
            public_key=content.get("public_key"),
        )
        self.nodes[node.id] = node
        logger.info(f"Discovered node: {node.id} at {node.address}:{node.port}")
        
        # Send our routing info back if this is a new node
        if message.sender_id != self.node_id:
            self._send_routing_info()
    
    def _handle_routing(self, message):
        """Handle a routing information message."""
        routing_info = json.loads(message.content)
        for node_dict in routing_info.get("nodes", []):
            node_id = node_dict.get("id")
            if node_id != self.node_id and node_id not in self.nodes:
                node = Node(**node_dict)
                node.last_seen = time.time()  # Update the last_seen time
                self.nodes[node_id] = node
    
    def _handle_data(self, message):
        """Handle data messages (text or voice)."""
        # If message is for us or broadcast, process it
        if message.recipient_id == self.node_id or message.recipient_id == "broadcast":
            logger.info(f"Received {message.type} message from {message.sender_id}")
            # Here we would forward to any connected clients or process locally
            # For now, just log it
            if message.type == "text":
                logger.info(f"Text content: {message.content}")
    
    def _relay_message(self, message):
        """Relay a message to other nodes in the network."""
        if message.ttl <= 0:
            return
            
        message_json = json.dumps(asdict(message))
        
        for node_id, node in self.nodes.items():
            if node_id != self.node_id and node_id != message.sender_id and node.is_active:
                try:
                    encrypted_data = encrypt_message(message_json, node.public_key)
                    self.socket.sendto(encrypted_data, (node.address, node.port))
                except Exception as e:
                    logger.error(f"Error relaying message to {node_id}: {str(e)}")
    
    def _send_discovery(self):
        """Send a discovery message to find other nodes in the network."""
        discovery_content = {
            "port": self.port,
            "public_key": self.public_key
        }
        
        message = Message(
            id=str(uuid.uuid4()),
            sender_id=self.node_id,
            recipient_id="broadcast",
            type="discovery",
            content=json.dumps(discovery_content),
            timestamp=time.time(),
            ttl=3
        )
        
        self._broadcast_message(message)
    
    def _send_routing_info(self):
        """Send information about known nodes to help with routing."""
        nodes_info = []
        for node in self.nodes.values():
            if node.is_active:
                nodes_info.append(asdict(node))
                
        routing_content = {
            "nodes": nodes_info
        }
        
        message = Message(
            id=str(uuid.uuid4()),
            sender_id=self.node_id,
            recipient_id="broadcast",
            type="routing",
            content=json.dumps(routing_content),
            timestamp=time.time(),
            ttl=2
        )
        
        self._broadcast_message(message)
    
    def _broadcast_message(self, message):
        """Broadcast a message to all known nodes."""
        message_json = json.dumps(asdict(message))
        self.processed_messages.add(message.id)
        
        # If we're using BATMAN-Adv, we can use broadcast address
        if self.batman_available:
            try:
                # BATMAN-Adv broadcast
                broadcast_addr = "192.168.199.255"  # Adjust to your BATMAN-Adv subnet
                encrypted_data = encrypt_message(message_json, self.public_key)  # Encrypt to ourselves for consistency
                self.socket.sendto(encrypted_data, (broadcast_addr, self.port))
            except Exception as e:
                logger.error(f"Error broadcasting with BATMAN-Adv: {str(e)}")
                # Fall back to individual node sending
                self._send_to_all_nodes(message_json)
        else:
            self._send_to_all_nodes(message_json)
    
    def _send_to_all_nodes(self, message_json):
        """Send a message individually to all known nodes."""
        for node_id, node in self.nodes.items():
            if node_id != self.node_id and node.is_active:
                try:
                    encrypted_data = encrypt_message(message_json, node.public_key)
                    self.socket.sendto(encrypted_data, (node.address, node.port))
                except Exception as e:
                    logger.error(f"Error sending to node {node_id}: {str(e)}")
    
    def _maintain_nodes(self):
        """Periodically check node status and send discovery messages."""
        while self.running:
            try:
                current_time = time.time()
                
                # Mark nodes as inactive if not seen for 60 seconds
                for node_id, node in self.nodes.items():
                    if current_time - node.last_seen > 60:
                        if node.is_active:
                            logger.info(f"Node {node_id} is now inactive")
                            node.is_active = False
                
                # Send discovery message every 30 seconds
                self._send_discovery()
                
                # Clean up processed messages cache (keep last 5 minutes)
                self.processed_messages = {
                    msg_id for msg_id in self.processed_messages 
                    if msg_id.split('-')[-1] > str(int(current_time - 300))
                }
                
                # Sleep for 30 seconds
                for _ in range(30):
                    if not self.running:
                        break
                    time.sleep(1)
                    
            except Exception as e:
                logger.error(f"Error in node maintenance: {str(e)}")
                time.sleep(5)  # Sleep briefly on error
    
    def send_text_message(self, recipient_id, text_content):
        """Send a text message to a specific recipient or broadcast."""
        message = Message(
            id=str(uuid.uuid4()),
            sender_id=self.node_id,
            recipient_id=recipient_id,
            type="text",
            content=text_content,
            timestamp=time.time(),
            ttl=3
        )
        
        if recipient_id == "broadcast":
            self._broadcast_message(message)
        elif recipient_id in self.nodes:
            message_json = json.dumps(asdict(message))
            node = self.nodes[recipient_id]
            try:
                encrypted_data = encrypt_message(message_json, node.public_key)
                self.socket.sendto(encrypted_data, (node.address, node.port))
                logger.info(f"Sent text message to {recipient_id}")
            except Exception as e:
                logger.error(f"Error sending text message to {recipient_id}: {str(e)}")
        else:
            logger.error(f"Unknown recipient: {recipient_id}")
    
    def send_voice_data(self, recipient_id, voice_data):
        """Send voice data to a specific recipient or broadcast."""
        message = Message(
            id=str(uuid.uuid4()),
            sender_id=self.node_id,
            recipient_id=recipient_id,
            type="voice",
            content=voice_data,  # Base64 encoded audio data
            timestamp=time.time(),
            ttl=1  # Lower TTL for voice to reduce latency
        )
        
        if recipient_id == "broadcast":
            self._broadcast_message(message)
        elif recipient_id in self.nodes:
            message_json = json.dumps(asdict(message))
            node = self.nodes[recipient_id]
            try:
                encrypted_data = encrypt_message(message_json, node.public_key)
                self.socket.sendto(encrypted_data, (node.address, node.port))
            except Exception as e:
                logger.error(f"Error sending voice data to {recipient_id}: {str(e)}")
        else:
            logger.error(f"Unknown recipient: {recipient_id}")
    
    def get_nodes(self):
        """Return a list of active nodes in the network."""
        return [asdict(node) for node in self.nodes.values() if node.is_active]

if __name__ == "__main__":
    # For testing purposes
    relay = MeshRelay()
    try:
        relay.start()
        
        # Keep running until interrupted
        while True:
            time.sleep(1)
            
    except KeyboardInterrupt:
        print("Shutting down mesh relay...")
    finally:
        relay.stop()
