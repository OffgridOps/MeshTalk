#!/usr/bin/env python3
"""
MeshTalk API Server
Flask-based API server for MeshTalk network
"""

import os
import sys
import json
import time
import uuid
import logging
import base64
from typing import Dict, Any, List, Optional
import threading

from flask import Flask, request, jsonify, Response, render_template, send_from_directory
from flask_cors import CORS

# Import MeshTalk modules
from mesh_relay import MeshRelay
from crypto import generate_keypair, encrypt_message, decrypt_message
from ai_voice import process_audio_base64, process_voice_command

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("api_server")

# Initialize Flask app
app = Flask(__name__)
CORS(app)  # Enable CORS for all routes

# Initialize MeshRelay
mesh_relay = MeshRelay()

# In-memory message store (in a production app, this would use a database)
messages: List[Dict[str, Any]] = []

# Function to start mesh_relay
def start_mesh_relay():
    mesh_relay.start()
    logger.info("Mesh relay started")
    
    # Register shutdown handler
    import atexit
    atexit.register(lambda: mesh_relay.stop())

# Set up function to run before first request with modern Flask
@app.before_request
def before_first_request():
    if not hasattr(app, 'mesh_relay_started'):
        start_mesh_relay()
        app.mesh_relay_started = True

# Health check endpoint
@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({
        "status": "ok",
        "timestamp": time.time(),
        "node_id": mesh_relay.node_id,
        "nodes_count": len(mesh_relay.nodes)
    })

# Get node information
@app.route('/api/node', methods=['GET'])
def get_node_info():
    return jsonify({
        "node_id": mesh_relay.node_id,
        "public_key": mesh_relay.public_key,
        "address": request.host,
        "active_since": time.time() - 600  # Placeholder for node uptime
    })

# Get network information
@app.route('/api/network', methods=['GET'])
def get_network_info():
    nodes = mesh_relay.get_nodes()
    return jsonify({
        "nodes": nodes,
        "count": len(nodes),
        "batman_available": mesh_relay.batman_available
    })

# Send a text message
@app.route('/api/messages', methods=['POST'])
def send_message():
    try:
        data = request.json
        recipient_id = data.get('recipient_id', 'broadcast')
        content = data.get('content', '')
        
        if not content:
            return jsonify({"error": "Empty message content"}), 400
        
        # Create message
        message_id = str(uuid.uuid4())
        message = {
            "id": message_id,
            "sender_id": mesh_relay.node_id,
            "recipient_id": recipient_id,
            "content": content,
            "timestamp": time.time(),
            "type": "text"
        }
        
        # Store message locally
        messages.append(message)
        
        # Send message over mesh network
        mesh_relay.send_text_message(recipient_id, content)
        
        return jsonify({
            "success": True,
            "message_id": message_id
        })
    except Exception as e:
        logger.error(f"Error sending message: {str(e)}")
        return jsonify({"error": str(e)}), 500

# Get received messages
@app.route('/api/messages', methods=['GET'])
def get_messages():
    # Optional filters
    since = float(request.args.get('since', 0))
    limit = int(request.args.get('limit', 100))
    
    # Filter messages
    filtered_messages = [
        msg for msg in messages 
        if msg['timestamp'] > since
    ]
    
    # Sort by timestamp (newest first) and apply limit
    sorted_messages = sorted(filtered_messages, key=lambda x: x['timestamp'], reverse=True)[:limit]
    
    return jsonify({
        "messages": sorted_messages,
        "total": len(sorted_messages)
    })

# Process voice data
@app.route('/api/voice/process', methods=['POST'])
def process_voice():
    try:
        data = request.json
        audio_base64 = data.get('audio')
        
        if not audio_base64:
            return jsonify({"error": "No audio data provided"}), 400
        
        # Process audio with noise cancellation
        result = process_audio_base64(audio_base64)
        
        return jsonify(result)
    except Exception as e:
        logger.error(f"Error processing voice: {str(e)}")
        return jsonify({"error": str(e)}), 500

# Transmit voice data
@app.route('/api/voice/transmit', methods=['POST'])
def transmit_voice():
    try:
        data = request.json
        audio_base64 = data.get('audio')
        recipient_id = data.get('recipient_id', 'broadcast')
        
        if not audio_base64:
            return jsonify({"error": "No audio data provided"}), 400
        
        # Process audio with noise cancellation
        processed_result = process_audio_base64(audio_base64)
        
        # Only transmit if speech is detected
        if processed_result.get('is_speech', False):
            # Send processed audio over mesh network
            mesh_relay.send_voice_data(recipient_id, processed_result['processed_audio'])
            
            return jsonify({
                "success": True,
                "transmitted": True,
                "vad_confidence": processed_result.get('vad_confidence', 0)
            })
        else:
            return jsonify({
                "success": True,
                "transmitted": False,
                "reason": "No speech detected"
            })
    except Exception as e:
        logger.error(f"Error transmitting voice: {str(e)}")
        return jsonify({"error": str(e)}), 500

# Process voice command
@app.route('/api/voice/command', methods=['POST'])
def handle_voice_command():
    try:
        data = request.json
        command_text = data.get('command')
        
        if not command_text:
            return jsonify({"error": "No command text provided"}), 400
        
        # Process command
        result = process_voice_command(command_text)
        
        return jsonify(result)
    except Exception as e:
        logger.error(f"Error processing command: {str(e)}")
        return jsonify({"error": str(e)}), 500

# Serve static frontend assets (for development/testing)
@app.route('/', defaults={'path': 'index.html'})
@app.route('/<path:path>')
def serve_static(path):
    static_dir = os.path.join(os.path.dirname(__file__), '../static')
    if os.path.exists(static_dir):
        return send_from_directory(static_dir, path)
    else:
        # If no static directory, return a simple info page
        return jsonify({
            "app": "MeshTalk Server",
            "node_id": mesh_relay.node_id,
            "endpoints": [
                "/api/node",
                "/api/network",
                "/api/messages",
                "/api/voice/process",
                "/api/voice/transmit",
                "/api/voice/command",
                "/health"
            ]
        })

if __name__ == '__main__':
    try:
        port = int(os.environ.get('PORT', 8000))
        app.run(host='0.0.0.0', port=port, debug=False)
    except Exception as e:
        logger.error(f"Error starting server: {str(e)}")
        sys.exit(1)
