"""
MeshTalk Database Models
SQLAlchemy models for the MeshTalk application
"""

import uuid
import datetime
from sqlalchemy import Column, String, Float, Boolean, Integer, Text, ForeignKey, DateTime, LargeBinary
from sqlalchemy.orm import relationship
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()

# Define base model class
class Base(db.Model):
    __abstract__ = True
    
    created_at = Column(DateTime, default=datetime.datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.datetime.utcnow, onupdate=datetime.datetime.utcnow)

    def to_dict(self):
        """Convert model to dictionary representation"""
        return {column.name: getattr(self, column.name) for column in self.__table__.columns}


class Node(Base):
    """Model representing a node in the mesh network"""
    __tablename__ = 'nodes'
    
    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    node_id = Column(String(36), unique=True, nullable=False)
    address = Column(String(50), nullable=False)
    port = Column(Integer, nullable=False, default=8000)
    public_key = Column(Text, nullable=False)
    last_seen = Column(Float, nullable=False, default=lambda: datetime.datetime.utcnow().timestamp())
    is_active = Column(Boolean, default=True)
    is_self = Column(Boolean, default=False)
    
    # Relationships
    messages_sent = relationship("Message", back_populates="sender", foreign_keys="Message.sender_id")
    messages_received = relationship("Message", back_populates="recipient", foreign_keys="Message.recipient_id")
    
    def __repr__(self):
        return f"<Node {self.node_id}>"


class Message(Base):
    """Model representing a message in the mesh network"""
    __tablename__ = 'messages'
    
    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    message_id = Column(String(36), unique=True, nullable=False)
    sender_id = Column(String(36), ForeignKey('nodes.id'), nullable=False)
    recipient_id = Column(String(36), ForeignKey('nodes.id'), nullable=True)  # Null for broadcast
    content = Column(Text, nullable=False)
    timestamp = Column(Float, nullable=False, default=lambda: datetime.datetime.utcnow().timestamp())
    type = Column(String(20), nullable=False)  # "text", "voice", "discovery", "routing"
    ttl = Column(Integer, default=3)
    is_processed = Column(Boolean, default=False)
    is_broadcast = Column(Boolean, default=False)
    
    # Relationships
    sender = relationship("Node", back_populates="messages_sent", foreign_keys=[sender_id])
    recipient = relationship("Node", back_populates="messages_received", foreign_keys=[recipient_id])
    
    def __repr__(self):
        return f"<Message {self.message_id}>"


class VoiceMessage(Base):
    """Model representing a voice message with audio data"""
    __tablename__ = 'voice_messages'
    
    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    message_id = Column(String(36), ForeignKey('messages.id'), nullable=False)
    audio_data = Column(LargeBinary, nullable=False)  # Raw audio data
    duration = Column(Float, nullable=True)  # Duration in seconds
    is_noise_reduced = Column(Boolean, default=False)
    
    # Relationship
    message = relationship("Message")
    
    def __repr__(self):
        return f"<VoiceMessage {self.id}>"


class NetworkStat(Base):
    """Model for storing network statistics"""
    __tablename__ = 'network_stats'
    
    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    timestamp = Column(Float, nullable=False, default=lambda: datetime.datetime.utcnow().timestamp())
    active_nodes = Column(Integer, default=0)
    messages_transmitted = Column(Integer, default=0)
    avg_latency = Column(Float, nullable=True)  # in milliseconds
    batman_active = Column(Boolean, default=False)
    
    def __repr__(self):
        return f"<NetworkStat {self.timestamp}>"


class UserPreference(Base):
    """Model for storing user preferences"""
    __tablename__ = 'user_preferences'
    
    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    key = Column(String(100), nullable=False, unique=True)
    value = Column(Text, nullable=True)
    
    def __repr__(self):
        return f"<UserPreference {self.key}>"