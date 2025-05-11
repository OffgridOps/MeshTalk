"""
MeshTalk Authentication Module
Handles JWT-based authentication and security for the MeshTalk application
"""

import os
import uuid
import datetime
import logging
from typing import Dict, Any, Optional, Tuple
from functools import wraps

import jwt
from flask import request, jsonify, current_app
from flask_jwt_extended import (
    JWTManager, create_access_token, create_refresh_token,
    get_jwt_identity, verify_jwt_in_request, get_jwt
)

from models import db, UserPreference
from database import save_preference, get_preference

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("auth")

# Initialize JWT Manager
jwt_manager = JWTManager()

# Token blacklist for logout/revocation
token_blacklist = set()

def init_auth(app):
    """Initialize authentication module with the Flask app"""
    # Configure JWT settings
    app.config["JWT_SECRET_KEY"] = os.environ.get("JWT_SECRET_KEY", app.config.get("SECRET_KEY", "meshtalk-dev-security-key"))
    app.config["JWT_ACCESS_TOKEN_EXPIRES"] = datetime.timedelta(hours=1)
    app.config["JWT_REFRESH_TOKEN_EXPIRES"] = datetime.timedelta(days=30)
    app.config["JWT_BLACKLIST_ENABLED"] = True
    
    # Log security configuration (without revealing keys)
    logger.info("JWT Authentication initialized")
    
    # Initialize JWT with the app
    jwt_manager.init_app(app)
    
    # Register JWT callbacks
    @jwt_manager.token_in_blocklist_loader
    def check_if_token_in_blacklist(jwt_header, jwt_payload):
        """Check if the token is in the blacklist (revoked)"""
        jti = jwt_payload["jti"]
        return jti in token_blacklist

    @jwt_manager.expired_token_loader
    def expired_token_callback(jwt_header, jwt_payload):
        """Handle expired token"""
        return jsonify({
            "status": "error",
            "error": "token_expired",
            "message": "The token has expired"
        }), 401

    @jwt_manager.invalid_token_loader
    def invalid_token_callback(error):
        """Handle invalid token"""
        return jsonify({
            "status": "error",
            "error": "invalid_token",
            "message": "Signature verification failed"
        }), 401

    @jwt_manager.unauthorized_loader
    def missing_token_callback(error):
        """Handle missing token"""
        return jsonify({
            "status": "error",
            "error": "authorization_required",
            "message": "Authorization is required to access this resource"
        }), 401

    @jwt_manager.needs_fresh_token_loader
    def token_not_fresh_callback(jwt_header, jwt_payload):
        """Handle non-fresh token when fresh is required"""
        return jsonify({
            "status": "error",
            "error": "fresh_token_required",
            "message": "Fresh token required"
        }), 401

    # Register API key management
    generate_api_key_if_needed(app)
    
    return jwt_manager
    
def generate_api_key_if_needed(app):
    """Generate an API key if one doesn't exist"""
    with app.app_context():
        api_key = get_preference("api_key")
        if not api_key:
            # Generate a new API key
            api_key = str(uuid.uuid4())
            save_preference("api_key", api_key)
            logger.info("Generated new API key")
            
        # Store in app config for easy access
        app.config["API_KEY"] = api_key

def require_auth(f):
    """Decorator to require JWT authentication for an endpoint"""
    @wraps(f)
    def decorated(*args, **kwargs):
        # First check if API key is provided
        api_key = request.headers.get("X-API-Key")
        if api_key and api_key == current_app.config.get("API_KEY"):
            # API key is valid
            return f(*args, **kwargs)
        
        # If no API key, check JWT token
        try:
            verify_jwt_in_request()
            return f(*args, **kwargs)
        except Exception as e:
            return jsonify({
                "status": "error",
                "error": "authentication_failed",
                "message": "Authentication required"
            }), 401
            
    return decorated

def require_api_key(f):
    """Decorator to require API key authentication for an endpoint"""
    @wraps(f)
    def decorated(*args, **kwargs):
        api_key = request.headers.get("X-API-Key")
        if not api_key or api_key != current_app.config.get("API_KEY"):
            return jsonify({
                "status": "error",
                "error": "invalid_api_key",
                "message": "Valid API key required"
            }), 401
        return f(*args, **kwargs)
    return decorated

def authenticate_user(username: str, password: str) -> Tuple[bool, Dict[str, Any]]:
    """
    Authenticate a user with username and password.
    Returns (success, data) tuple.
    """
    # For MeshTalk, we'll use a simple authentication mechanism
    # In production, this should use a proper user authentication system
    
    # Check if username and password combination is valid
    # For demo purposes, we'll allow the system-configured username/password
    # or the node_id as username with the API key as password
    if (username == os.environ.get("ADMIN_USERNAME", "admin") and 
        password == os.environ.get("ADMIN_PASSWORD", "meshtalk")):
        # Admin user
        user_data = {
            "user_id": "admin",
            "username": username,
            "role": "admin"
        }
        return True, user_data
    
    # Get the current node ID from the app config
    # We have to get this from the app config instead of importing directly
    # to avoid circular imports
    current_node_id = current_app.config.get("NODE_ID", "")
    if username == current_node_id and password == current_app.config.get("API_KEY"):
        # Self-node authentication
        user_data = {
            "user_id": current_node_id,
            "username": "node-" + current_node_id[:8] if current_node_id else "unknown",
            "role": "node"
        }
        return True, user_data
    
    return False, {"error": "Invalid credentials"}

def generate_tokens(user_data: Dict[str, Any]) -> Dict[str, str]:
    """Generate access and refresh tokens for a user"""
    # Create access token with user data
    access_token = create_access_token(
        identity=user_data.get("user_id"),
        additional_claims=user_data,
        fresh=True
    )
    
    # Create refresh token
    refresh_token = create_refresh_token(
        identity=user_data.get("user_id")
    )
    
    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "token_type": "bearer"
    }

def logout_user(token_jti: str) -> bool:
    """Logout a user by adding their token to the blacklist"""
    try:
        token_blacklist.add(token_jti)
        return True
    except Exception as e:
        logger.error(f"Error logging out user: {str(e)}")
        return False

def refresh_access_token(refresh_token: str) -> Tuple[bool, Dict[str, Any]]:
    """Refresh an access token using a refresh token"""
    try:
        # Verify the refresh token
        verify_jwt_in_request(refresh=True)
        
        # Get user identity from the refresh token
        current_user = get_jwt_identity()
        
        # Generate a new access token
        new_token = create_access_token(identity=current_user, fresh=False)
        
        return True, {"access_token": new_token}
    except Exception as e:
        logger.error(f"Error refreshing token: {str(e)}")
        return False, {"error": str(e)}

def is_token_valid(token: str) -> bool:
    """Check if a token is valid (not expired or blacklisted)"""
    try:
        # Decode the token
        decoded = jwt.decode(
            token, 
            current_app.config["JWT_SECRET_KEY"],
            algorithms=["HS256"]
        )
        
        # Check if token is in blacklist
        if decoded["jti"] in token_blacklist:
            return False
        
        # Check if token is expired
        exp_timestamp = decoded["exp"]
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        
        if now > exp_timestamp:
            return False
            
        return True
    except Exception as e:
        logger.error(f"Error validating token: {str(e)}")
        return False

def get_api_key() -> str:
    """Return the current API key"""
    return current_app.config.get("API_KEY", "")

def rotate_api_key() -> str:
    """Generate a new API key and invalidate the old one"""
    try:
        new_api_key = str(uuid.uuid4())
        save_preference("api_key", new_api_key)
        
        # Update in app config
        current_app.config["API_KEY"] = new_api_key
        
        logger.info("API key rotated successfully")
        return new_api_key
    except Exception as e:
        logger.error(f"Error rotating API key: {str(e)}")
        return ""

# Rate limiting for API endpoints
request_counters = {}
rate_limit_window = 60  # 1 minute window
rate_limit_max_requests = 100  # Max requests per window

def check_rate_limit(client_ip: str) -> bool:
    """
    Check if the client has exceeded rate limits
    Returns True if allowed, False if rate limited
    
    Args:
        client_ip: Client IP address, or "unknown" if not available
    """
    current_time = datetime.datetime.now().timestamp()
    
    # Clean up old entries to avoid memory growth
    for ip in list(request_counters.keys()):
        if current_time - request_counters[ip]["timestamp"] > rate_limit_window:
            del request_counters[ip]
    
    # Check or initialize counter for this IP
    if client_ip not in request_counters:
        request_counters[client_ip] = {
            "count": 1,
            "timestamp": current_time
        }
        return True
        
    counter = request_counters[client_ip]
    
    # Check if we're in a new window
    if current_time - counter["timestamp"] > rate_limit_window:
        counter["count"] = 1
        counter["timestamp"] = current_time
        return True
        
    # Increment counter and check limit
    counter["count"] += 1
    if counter["count"] > rate_limit_max_requests:
        logger.warning(f"Rate limit exceeded for {client_ip}")
        return False
        
    return True

def rate_limit(f):
    """Decorator to apply rate limiting to an endpoint"""
    @wraps(f)
    def decorated(*args, **kwargs):
        # Get client IP from request
        client_ip = request.remote_addr or "unknown"
        
        # Check rate limit
        if not check_rate_limit(client_ip):
            return jsonify({
                "status": "error",
                "error": "rate_limit_exceeded",
                "message": "Rate limit exceeded. Please try again later."
            }), 429
            
        return f(*args, **kwargs)
    return decorated