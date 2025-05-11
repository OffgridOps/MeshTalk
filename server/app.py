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
from flask_jwt_extended import get_jwt_identity, get_jwt, jwt_required

# Import MeshTalk modules
from mesh_relay import MeshRelay
from crypto import generate_keypair, encrypt_message, decrypt_message
from ai_voice import process_audio_base64, process_voice_command
import database
from models import db
import auth

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

# Store the node ID in the app config for authentication
app.config["NODE_ID"] = mesh_relay.node_id

# Initialize authentication
auth.init_auth(app)

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

# Authentication endpoints
@app.route('/api/auth/login', methods=['POST'])
@auth.rate_limit
def login():
    """Authenticate user and generate tokens"""
    try:
        data = request.json
        if not data:
            return jsonify({"error": "Invalid request data"}), 400
            
        username = data.get('username')
        password = data.get('password')
        
        if not username or not password:
            return jsonify({"error": "Username and password required"}), 400
        
        # Authenticate user
        success, user_data = auth.authenticate_user(username, password)
        
        if not success:
            return jsonify({
                "status": "error",
                "error": "invalid_credentials",
                "message": "Invalid username or password"
            }), 401
        
        # Generate tokens
        tokens = auth.generate_tokens(user_data)
        
        return jsonify({
            "status": "success",
            "user": {
                "username": user_data.get("username"),
                "role": user_data.get("role")
            },
            **tokens
        })
    except Exception as e:
        logger.error(f"Error in login: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/api/auth/refresh', methods=['POST'])
@auth.rate_limit
def refresh_token():
    """Refresh access token using refresh token"""
    try:
        data = request.json
        if not data:
            return jsonify({"error": "Invalid request data"}), 400
            
        refresh_token = data.get('refresh_token')
        
        if not refresh_token:
            return jsonify({"error": "Refresh token required"}), 400
        
        # Refresh token
        success, result = auth.refresh_access_token(refresh_token)
        
        if not success:
            return jsonify({
                "status": "error",
                "error": "invalid_token",
                "message": "Invalid or expired refresh token"
            }), 401
        
        return jsonify({
            "status": "success",
            **result
        })
    except Exception as e:
        logger.error(f"Error in refresh token: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/api/auth/logout', methods=['POST'])
@auth.require_auth
def logout():
    """Logout user by blacklisting current token"""
    try:
        # Get current token JTI (JWT ID)
        token_jti = get_jwt().get("jti")
        
        # Add token to blacklist
        success = auth.logout_user(token_jti)
        
        if success:
            return jsonify({
                "status": "success",
                "message": "Successfully logged out"
            })
        else:
            return jsonify({
                "status": "error",
                "error": "logout_failed",
                "message": "Failed to logout"
            }), 500
    except Exception as e:
        logger.error(f"Error in logout: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/api/auth/apikey', methods=['GET'])
@auth.require_auth
def get_api_key():
    """Get current API key"""
    try:
        # Only admin users or self-nodes can see the API key
        current_user = get_jwt_identity()
        user_role = get_jwt().get("role", "")
        
        if user_role != "admin" and current_user != mesh_relay.node_id:
            return jsonify({
                "status": "error",
                "error": "unauthorized",
                "message": "You are not authorized to view the API key"
            }), 403
        
        # Get API key
        api_key = auth.get_api_key()
        
        return jsonify({
            "status": "success",
            "api_key": api_key
        })
    except Exception as e:
        logger.error(f"Error getting API key: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/api/auth/apikey/rotate', methods=['POST'])
@auth.require_auth
def rotate_api_key():
    """Rotate API key"""
    try:
        # Only admin users can rotate the API key
        user_role = get_jwt().get("role", "")
        
        if user_role != "admin":
            return jsonify({
                "status": "error",
                "error": "unauthorized",
                "message": "You are not authorized to rotate the API key"
            }), 403
        
        # Rotate API key
        new_api_key = auth.rotate_api_key()
        
        if new_api_key:
            return jsonify({
                "status": "success",
                "message": "API key rotated successfully",
                "api_key": new_api_key
            })
        else:
            return jsonify({
                "status": "error",
                "error": "rotation_failed",
                "message": "Failed to rotate API key"
            }), 500
    except Exception as e:
        logger.error(f"Error rotating API key: {str(e)}")
        return jsonify({"error": str(e)}), 500

# Database status API endpoint
@app.route('/api/db/status', methods=['GET'])
@auth.require_auth
def db_status():
    try:
        from database import get_nodes, get_messages, get_network_stats, get_all_preferences
        
        # Get counts from database
        nodes = get_nodes(active_only=False)
        messages_list = get_messages(since=0, limit=1000)
        stats = get_network_stats(limit=10)
        preferences = get_all_preferences()
        
        return jsonify({
            "status": "connected",
            "tables": {
                "nodes": len(nodes),
                "messages": len(messages_list),
                "network_stats": len(stats),
                "preferences": len(preferences),
            },
            "database_url": os.environ.get("DATABASE_URL", "").split("@")[-1] if os.environ.get("DATABASE_URL") else "Not configured"
        })
    except Exception as e:
        logger.error(f"Error getting database status: {str(e)}")
        return jsonify({
            "status": "error",
            "error": str(e)
        }), 500

# Serve static frontend assets (for development/testing)
@app.route('/', defaults={'path': 'index.html'})
@app.route('/<path:path>')
def serve_static(path):
    # First check in server/static (our main static directory for the web UI)
    server_static_dir = os.path.join(os.path.dirname(__file__), 'static')
    if os.path.exists(os.path.join(server_static_dir, path)):
        return send_from_directory(server_static_dir, path)
    
    # Then check root static directory (might be used for other assets)
    root_static_dir = os.path.join(os.path.dirname(__file__), '../static')
    if os.path.exists(root_static_dir) and os.path.exists(os.path.join(root_static_dir, path)):
        return send_from_directory(root_static_dir, path)
    
    # If path doesn't exist but requesting index.html, return our main index
    if path == 'index.html' and os.path.exists(os.path.join(server_static_dir, 'index.html')):
        return send_from_directory(server_static_dir, 'index.html')
    
    # If no static directories or file not found, return API info
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
            "/api/db/status",
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
