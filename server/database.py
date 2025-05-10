"""
MeshTalk Database Module
Handles database connection and operations for the MeshTalk application
"""

import os
import logging
from typing import Dict, List, Any, Optional
import datetime
import uuid
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, scoped_session
from sqlalchemy.exc import SQLAlchemyError

from models import db, Node, Message, VoiceMessage, NetworkStat, UserPreference

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("database")

def init_db(app):
    """Initialize the database connection"""
    try:
        # Get database URL from environment variable
        database_url = os.environ.get('DATABASE_URL')
        if not database_url:
            logger.warning("DATABASE_URL not found, falling back to in-memory database")
            database_url = "sqlite:///:memory:"
        
        # Configure SQLAlchemy
        app.config['SQLALCHEMY_DATABASE_URI'] = database_url
        app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
        app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
            'pool_pre_ping': True,
            'pool_recycle': 300,
        }
        
        # Initialize database
        db.init_app(app)
        
        # Create all tables
        with app.app_context():
            db.create_all()
            logger.info("Database initialized successfully")
            
        return True
    except Exception as e:
        logger.error(f"Error initializing database: {str(e)}")
        return False

# Node operations
def save_node(node_data: Dict[str, Any]) -> Optional[Node]:
    """Save a node to the database"""
    try:
        # Check if node already exists
        existing_node = Node.query.filter_by(node_id=node_data['id']).first()
        
        if existing_node:
            # Update existing node
            existing_node.address = node_data.get('address', existing_node.address)
            existing_node.port = node_data.get('port', existing_node.port)
            existing_node.public_key = node_data.get('public_key', existing_node.public_key)
            existing_node.last_seen = node_data.get('last_seen', datetime.datetime.utcnow().timestamp())
            existing_node.is_active = node_data.get('is_active', True)
            
            db.session.commit()
            logger.debug(f"Updated node: {existing_node.node_id}")
            return existing_node
        else:
            # Create new node
            new_node = Node()
            new_node.id = str(uuid.uuid4())
            new_node.node_id = node_data['id']
            new_node.address = node_data['address']
            new_node.port = node_data.get('port', 8000)
            new_node.public_key = node_data.get('public_key', '')
            new_node.last_seen = node_data.get('last_seen', datetime.datetime.utcnow().timestamp())
            new_node.is_active = node_data.get('is_active', True)
            new_node.is_self = node_data.get('is_self', False)
            
            db.session.add(new_node)
            db.session.commit()
            logger.info(f"Added new node: {new_node.node_id}")
            return new_node
    except SQLAlchemyError as e:
        db.session.rollback()
        logger.error(f"Database error saving node: {str(e)}")
        return None
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error saving node: {str(e)}")
        return None

def get_nodes(active_only: bool = True) -> List[Node]:
    """Get all nodes from the database"""
    try:
        if active_only:
            nodes = Node.query.filter_by(is_active=True).all()
        else:
            nodes = Node.query.all()
        return nodes
    except Exception as e:
        logger.error(f"Error getting nodes: {str(e)}")
        return []

def update_node_status(node_id: str, is_active: bool) -> bool:
    """Update a node's active status"""
    try:
        node = Node.query.filter_by(node_id=node_id).first()
        if node:
            node.is_active = is_active
            node.last_seen = datetime.datetime.utcnow().timestamp() if is_active else node.last_seen
            db.session.commit()
            return True
        return False
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error updating node status: {str(e)}")
        return False

# Message operations
def save_message(message_data: Dict[str, Any]) -> Optional[Message]:
    """Save a message to the database"""
    try:
        # Check if message already exists
        existing_message = Message.query.filter_by(message_id=message_data['id']).first()
        
        if existing_message:
            # Update the processed flag if necessary
            if 'is_processed' in message_data:
                existing_message.is_processed = message_data['is_processed']
                db.session.commit()
            return existing_message
        
        # Get sender node
        sender_node = Node.query.filter_by(node_id=message_data['sender_id']).first()
        if not sender_node:
            # Create a placeholder sender node if it doesn't exist
            sender_node = Node(
                id=str(uuid.uuid4()),
                node_id=message_data['sender_id'],
                address='unknown',
                port=8000,
                public_key='',
                last_seen=message_data.get('timestamp', datetime.datetime.utcnow().timestamp()),
                is_active=True
            )
            db.session.add(sender_node)
        
        # Get recipient node for direct messages
        recipient_node_id = None
        if message_data['recipient_id'] != 'broadcast':
            recipient_node = Node.query.filter_by(node_id=message_data['recipient_id']).first()
            if recipient_node:
                recipient_node_id = recipient_node.id
        
        # Create new message
        new_message = Message(
            id=str(uuid.uuid4()),
            message_id=message_data['id'],
            sender_id=sender_node.id,
            recipient_id=recipient_node_id,
            content=message_data['content'],
            timestamp=message_data['timestamp'],
            type=message_data['type'],
            ttl=message_data.get('ttl', 3),
            is_processed=message_data.get('is_processed', False),
            is_broadcast=message_data['recipient_id'] == 'broadcast'
        )
        
        db.session.add(new_message)
        
        # If it's a voice message, save the audio data
        if message_data['type'] == 'voice' and 'audio_data' in message_data:
            voice_message = VoiceMessage(
                id=str(uuid.uuid4()),
                message_id=new_message.id,
                audio_data=message_data['audio_data'],
                is_noise_reduced=message_data.get('is_noise_reduced', False)
            )
            db.session.add(voice_message)
        
        db.session.commit()
        return new_message
    except SQLAlchemyError as e:
        db.session.rollback()
        logger.error(f"Database error saving message: {str(e)}")
        return None
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error saving message: {str(e)}")
        return None

def get_messages(since: float = 0, limit: int = 100, message_type: str = None) -> List[Dict[str, Any]]:
    """Get messages from the database with optional filtering"""
    try:
        query = Message.query.filter(Message.timestamp > since)
        
        if message_type:
            query = query.filter_by(type=message_type)
        
        messages = query.order_by(Message.timestamp.desc()).limit(limit).all()
        
        # Format messages for API response
        result = []
        for msg in messages:
            sender = Node.query.get(msg.sender_id)
            
            message_data = {
                'id': msg.message_id,
                'sender_id': sender.node_id if sender else msg.sender_id,
                'recipient_id': 'broadcast' if msg.is_broadcast else (
                    Node.query.get(msg.recipient_id).node_id if msg.recipient_id else ''),
                'content': msg.content,
                'timestamp': msg.timestamp,
                'type': msg.type
            }
            
            # Attach voice message data if available
            if msg.type == 'voice':
                voice = VoiceMessage.query.filter_by(message_id=msg.id).first()
                if voice:
                    message_data['audio_data'] = voice.audio_data
            
            result.append(message_data)
        
        return result
    except Exception as e:
        logger.error(f"Error getting messages: {str(e)}")
        return []

# Network statistics operations
def save_network_stats(active_nodes: int, messages_transmitted: int, 
                      avg_latency: float = None, batman_active: bool = False) -> bool:
    """Save network statistics"""
    try:
        stats = NetworkStat(
            id=str(uuid.uuid4()),
            timestamp=datetime.datetime.utcnow().timestamp(),
            active_nodes=active_nodes,
            messages_transmitted=messages_transmitted,
            avg_latency=avg_latency,
            batman_active=batman_active
        )
        db.session.add(stats)
        db.session.commit()
        return True
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error saving network stats: {str(e)}")
        return False

def get_network_stats(limit: int = 24) -> List[Dict[str, Any]]:
    """Get recent network statistics"""
    try:
        stats = NetworkStat.query.order_by(NetworkStat.timestamp.desc()).limit(limit).all()
        return [stat.to_dict() for stat in stats]
    except Exception as e:
        logger.error(f"Error getting network stats: {str(e)}")
        return []

# User preferences operations
def save_preference(key: str, value: str) -> bool:
    """Save a user preference"""
    try:
        pref = UserPreference.query.filter_by(key=key).first()
        if pref:
            pref.value = value
        else:
            pref = UserPreference(id=str(uuid.uuid4()), key=key, value=value)
            db.session.add(pref)
        
        db.session.commit()
        return True
    except Exception as e:
        db.session.rollback()
        logger.error(f"Error saving preference: {str(e)}")
        return False

def get_preference(key: str, default: str = None) -> str:
    """Get a user preference"""
    try:
        pref = UserPreference.query.filter_by(key=key).first()
        if pref:
            return pref.value
        return default
    except Exception as e:
        logger.error(f"Error getting preference: {str(e)}")
        return default

def get_all_preferences() -> Dict[str, str]:
    """Get all user preferences"""
    try:
        prefs = UserPreference.query.all()
        return {pref.key: pref.value for pref in prefs}
    except Exception as e:
        logger.error(f"Error getting all preferences: {str(e)}")
        return {}