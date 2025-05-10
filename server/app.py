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
import database
from models import db

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("api_server")

# Initialize Flask app
app = Flask(__name__)
CORS(app)  # Enable CORS for all routes

# Initialize the database
app.config['SECRET_KEY'] = os.environ.get('FLASK_SECRET_KEY', 'meshtalk-dev-secret-key')
database.init_db(app)

# Initialize MeshRelay
mesh_relay = MeshRelay()

# Function to start mesh_relay
def start_mesh_relay():
    mesh_relay.start()
    logger.info("Mesh relay started")
    
    # Register shutdown handler
    import atexit
    atexit.register(lambda: mesh_relay.stop())

# Create app context variable to track if mesh relay is started
mesh_relay_started = False

# Set up function to run before first request with modern Flask
@app.before_request
def before_first_request():
    global mesh_relay_started
    if not mesh_relay_started:
        start_mesh_relay()
        mesh_relay_started = True

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
        if not data:
            return jsonify({"error": "Invalid request data"}), 400
            
        recipient_id = data.get('recipient_id', 'broadcast')
        content = data.get('content', '')
        
        if not content:
            return jsonify({"error": "Empty message content"}), 400
        
        # Create message
        message_id = str(uuid.uuid4())
        timestamp = time.time()
        message = {
            "id": message_id,
            "sender_id": mesh_relay.node_id,
            "recipient_id": recipient_id,
            "content": content,
            "timestamp": timestamp,
            "type": "text"
        }
        
        # Store message in database
        from database import save_message
        save_message(message)
        
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
    try:
        # Optional filters
        since = float(request.args.get('since', 0) or 0)
        limit = int(request.args.get('limit', 100) or 100)
        message_type = request.args.get('type', None)
        
        # Get messages from database
        from database import get_messages as db_get_messages
        messages_list = db_get_messages(since, limit, message_type)
        
        return jsonify({
            "messages": messages_list,
            "total": len(messages_list)
        })
    except Exception as e:
        logger.error(f"Error retrieving messages: {str(e)}")
        return jsonify({"error": str(e), "messages": []}), 500

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
        if not data:
            return jsonify({"error": "Invalid request data"}), 400
            
        audio_base64 = data.get('audio')
        recipient_id = data.get('recipient_id', 'broadcast')
        
        if not audio_base64:
            return jsonify({"error": "No audio data provided"}), 400
        
        # Process audio with noise cancellation
        processed_result = process_audio_base64(audio_base64)
        
        # Only transmit if speech is detected
        if processed_result.get('is_speech', False):
            # Create message
            message_id = str(uuid.uuid4())
            timestamp = time.time()
            
            # Get audio data as bytes
            processed_audio = processed_result['processed_audio']
            audio_data = base64.b64decode(processed_audio)
            
            # Create message for database
            message = {
                "id": message_id,
                "sender_id": mesh_relay.node_id,
                "recipient_id": recipient_id,
                "content": f"Voice message ({len(audio_data) // 1024} KB)",
                "timestamp": timestamp,
                "type": "voice",
                "audio_data": audio_data,
                "is_noise_reduced": True
            }
            
            # Store message in database
            from database import save_message
            save_message(message)
            
            # Send processed audio over mesh network
            mesh_relay.send_voice_data(recipient_id, processed_audio)
            
            return jsonify({
                "success": True,
                "transmitted": True,
                "message_id": message_id,
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
