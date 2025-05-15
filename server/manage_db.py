#!/usr/bin/env python3
"""
MeshTalk Database Management Script
Provides utilities for managing the MeshTalk database.
"""

import os
import sys
import argparse
import logging
from flask import Flask

from models import db
import database

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("db_management")

def create_app():
    """Create a Flask app for database operations"""
    app = Flask(__name__)
    
    # Get database URL from environment variable
    database_url = os.environ.get('DATABASE_URL')
    if not database_url:
        logger.error("DATABASE_URL environment variable not set")
        sys.exit(1)
    
    # Configure SQLAlchemy
    app.config['SQLALCHEMY_DATABASE_URI'] = database_url
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
        'pool_pre_ping': True,
        'pool_recycle': 300,
    }
    
    # Initialize database
    db.init_app(app)
    
    return app

def init_db(app):
    """Initialize the database and create tables"""
    with app.app_context():
        db.create_all()
        logger.info("Database tables created")

def drop_tables(app, confirm=False):
    """Drop all database tables"""
    if not confirm:
        confirm_input = input("Are you sure you want to drop all tables? This will delete all data. (y/N): ")
        if confirm_input.lower() != 'y':
            logger.info("Operation cancelled")
            return
    
    with app.app_context():
        db.drop_all()
        logger.info("All tables dropped")

def show_tables(app):
    """Show information about the database tables"""
    with app.app_context():
        from sqlalchemy import inspect
        inspector = inspect(db.engine)
        
        # Get all table names
        tables = inspector.get_table_names()
        
        print(f"Database: {db.engine.url}")
        print(f"Tables found: {len(tables)}")
        
        for table in tables:
            columns = inspector.get_columns(table)
            print(f"\nTable: {table}")
            print(f"  Columns: {len(columns)}")
            for column in columns:
                print(f"    - {column['name']} ({column['type']})")

def add_test_data(app):
    """Add some test data to the database"""
    with app.app_context():
        # Add a self node
        from models import Node
        import uuid
        import datetime
        
        # Create self node
        self_node = Node()
        self_node.id = str(uuid.uuid4())
        self_node.node_id = "self-node-" + str(uuid.uuid4())[:8]
        self_node.address = "127.0.0.1"
        self_node.port = 8000
        self_node.public_key = "test-public-key"
        self_node.last_seen = datetime.datetime.utcnow().timestamp()
        self_node.is_active = True
        self_node.is_self = True
        
        # Add a peer node
        peer_node = Node()
        peer_node.id = str(uuid.uuid4())
        peer_node.node_id = "peer-node-" + str(uuid.uuid4())[:8]
        peer_node.address = "192.168.1.100"
        peer_node.port = 8000
        peer_node.public_key = "peer-public-key"
        peer_node.last_seen = datetime.datetime.utcnow().timestamp()
        peer_node.is_active = True
        
        # Add test preference
        from models import UserPreference
        pref = UserPreference()
        pref.id = str(uuid.uuid4())
        pref.key = "theme"
        pref.value = "dark"
        
        # Add test messages
        from models import Message
        
        # Text message
        text_msg = Message()
        text_msg.id = str(uuid.uuid4())
        text_msg.message_id = "msg-" + str(uuid.uuid4())[:8]
        text_msg.content = "Hello from database test!"
        text_msg.timestamp = datetime.datetime.utcnow().timestamp()
        text_msg.type = "text"
        
        # Add to database
        db.session.add(self_node)
        db.session.add(peer_node)
        db.session.add(pref)
        
        # Commit to save the objects and get their IDs
        db.session.commit()
        
        # Now that we have nodes saved, we can set up message relationships
        text_msg.sender_id = self_node.id
        text_msg.recipient_id = peer_node.id
        text_msg.is_broadcast = False
        
        db.session.add(text_msg)
        db.session.commit()
        
        logger.info("Test data added to database")
        
        # Show counts
        nodes_count = Node.query.count()
        messages_count = Message.query.count()
        prefs_count = UserPreference.query.count()
        
        print(f"Added {nodes_count} nodes, {messages_count} messages, and {prefs_count} preferences")

def main():
    """Main entry point for the script"""
    parser = argparse.ArgumentParser(description='MeshTalk Database Management Tool')
    
    # Define subparsers for different commands
    subparsers = parser.add_subparsers(dest='command', help='Command to execute')
    
    # init command
    init_parser = subparsers.add_parser('init', help='Initialize database tables')
    
    # drop command
    drop_parser = subparsers.add_parser('drop', help='Drop all database tables')
    drop_parser.add_argument('--force', action='store_true', help='Force drop without confirmation')
    
    # show command
    show_parser = subparsers.add_parser('show', help='Show information about database tables')
    
    # testdata command
    testdata_parser = subparsers.add_parser('testdata', help='Add test data to the database')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return
    
    app = create_app()
    
    if args.command == 'init':
        init_db(app)
    elif args.command == 'drop':
        drop_tables(app, args.force)
    elif args.command == 'show':
        show_tables(app)
    elif args.command == 'testdata':
        add_test_data(app)

if __name__ == '__main__':
    main()