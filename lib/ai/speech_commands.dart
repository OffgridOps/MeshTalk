import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// Class for processing speech commands in MeshTalk
class SpeechCommandProcessor {
  // Command types
  static const String CMD_CALL = 'call';
  static const String CMD_MESSAGE = 'message';
  static const String CMD_SOS = 'sos';
  static const String CMD_HELP = 'help';
  
  // Available commands mapping
  final Map<String, Function> _commandHandlers = {};
  
  // Command history
  final List<Map<String, dynamic>> _commandHistory = [];
  
  // Command callbacks
  Function(Map<String, dynamic>)? onCommandProcessed;
  
  /// Initialize the speech command processor
  SpeechCommandProcessor() {
    _registerCommands();
  }
  
  /// Register available commands and their handlers
  void _registerCommands() {
    _commandHandlers[CMD_CALL] = _handleCallCommand;
    _commandHandlers[CMD_MESSAGE] = _handleMessageCommand;
    _commandHandlers[CMD_SOS] = _handleSOSCommand;
    _commandHandlers[CMD_HELP] = _handleHelpCommand;
  }
  
  /// Process a speech command
  Future<Map<String, dynamic>> processCommand(String text) async {
    try {
      // Normalize text
      final normalizedText = text.trim().toLowerCase();
      
      // Check if empty
      if (normalizedText.isEmpty) {
        return _createErrorResponse('Empty command');
      }
      
      // Split into command and params
      final parts = normalizedText.split(' ');
      final command = parts[0];
      final params = parts.length > 1 ? parts.sublist(1) : [];
      
      // Look for command handler
      if (_commandHandlers.containsKey(command)) {
        final result = await _commandHandlers[command]!(params);
        
        // Store in history
        _commandHistory.add({
          'command': command,
          'params': params,
          'result': result,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        
        // Notify listeners
        if (onCommandProcessed != null) {
          onCommandProcessed!(result);
        }
        
        return result;
      } else {
        // Try to find a similar command
        final similarCommand = _findSimilarCommand(command);
        
        return _createErrorResponse(
          'Unknown command: $command',
          suggestions: similarCommand != null ? ['Did you mean "$similarCommand"?'] : null,
          availableCommands: _commandHandlers.keys.toList(),
        );
      }
    } catch (e) {
      return _createErrorResponse('Error processing command: $e');
    }
  }
  
  /// Find a similar command using Levenshtein distance
  String? _findSimilarCommand(String input) {
    if (input.isEmpty) return null;
    
    String? bestMatch;
    int bestDistance = 999;
    
    for (final cmd in _commandHandlers.keys) {
      final distance = _levenshteinDistance(input, cmd);
      if (distance < bestDistance && distance <= 2) { // Max 2 char difference
        bestDistance = distance;
        bestMatch = cmd;
      }
    }
    
    return bestMatch;
  }
  
  /// Calculate Levenshtein distance between two strings
  int _levenshteinDistance(String s1, String s2) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;
    
    List<int> v0 = List<int>.filled(s2.length + 1, 0);
    List<int> v1 = List<int>.filled(s2.length + 1, 0);
    
    for (int i = 0; i <= s2.length; i++) {
      v0[i] = i;
    }
    
    for (int i = 0; i < s1.length; i++) {
      v1[0] = i + 1;
      
      for (int j = 0; j < s2.length; j++) {
        int cost = (s1[i] == s2[j]) ? 0 : 1;
        v1[j + 1] = min(min(v1[j] + 1, v0[j + 1] + 1), v0[j] + cost);
      }
      
      for (int j = 0; j <= s2.length; j++) {
        v0[j] = v1[j];
      }
    }
    
    return v1[s2.length];
  }
  
  /// Handle "call" command
  Future<Map<String, dynamic>> _handleCallCommand(List<String> params) async {
    if (params.isEmpty) {
      return _createErrorResponse('No contact specified for call');
    }
    
    final contact = params.join(' ');
    
    return {
      'success': true,
      'command': CMD_CALL,
      'contact': contact,
      'action': 'initiate_call',
      'message': 'Calling $contact...',
    };
  }
  
  /// Handle "message" command
  Future<Map<String, dynamic>> _handleMessageCommand(List<String> params) async {
    if (params.length < 2) {
      return _createErrorResponse(
        'Message command requires contact and message text',
        examples: ['message John Hello there'],
      );
    }
    
    final contact = params[0];
    final message = params.sublist(1).join(' ');
    
    return {
      'success': true,
      'command': CMD_MESSAGE,
      'contact': contact,
      'text': message,
      'action': 'send_message',
      'message': 'Message sent to $contact',
    };
  }
  
  /// Handle "sos" command
  Future<Map<String, dynamic>> _handleSOSCommand(List<String> params) async {
    final message = params.isNotEmpty ? params.join(' ') : 'Emergency SOS alert!';
    
    return {
      'success': true,
      'command': CMD_SOS,
      'text': message,
      'action': 'broadcast_sos',
      'priority': 'high',
      'message': 'SOS alert broadcast to all nodes',
    };
  }
  
  /// Handle "help" command
  Future<Map<String, dynamic>> _handleHelpCommand(List<String> params) async {
    final specificCommand = params.isNotEmpty ? params[0] : null;
    
    if (specificCommand != null && _commandHandlers.containsKey(specificCommand)) {
      // Return help for specific command
      return _getCommandHelp(specificCommand);
    } else {
      // Return general help
      return {
        'success': true,
        'command': CMD_HELP,
        'action': 'show_help',
        'available_commands': _commandHandlers.keys.toList(),
        'message': 'Available commands: ${_commandHandlers.keys.join(', ')}',
      };
    }
  }
  
  /// Get detailed help for a specific command
  Map<String, dynamic> _getCommandHelp(String command) {
    Map<String, dynamic> helpInfo = {
      'success': true,
      'command': CMD_HELP,
      'for_command': command,
      'action': 'show_help',
    };
    
    switch (command) {
      case CMD_CALL:
        helpInfo['usage'] = 'call <contact>';
        helpInfo['description'] = 'Initiates a voice call to the specified contact';
        helpInfo['examples'] = ['call John', 'call Emergency Team'];
        break;
        
      case CMD_MESSAGE:
        helpInfo['usage'] = 'message <contact> <message text>';
        helpInfo['description'] = 'Sends a text message to the specified contact';
        helpInfo['examples'] = ['message John Hello there', 'message Team Meeting at 5pm'];
        break;
        
      case CMD_SOS:
        helpInfo['usage'] = 'sos [optional message]';
        helpInfo['description'] = 'Broadcasts an emergency SOS alert to all nodes';
        helpInfo['examples'] = ['sos', 'sos Need medical assistance'];
        break;
        
      case CMD_HELP:
        helpInfo['usage'] = 'help [command]';
        helpInfo['description'] = 'Shows help information for all commands or a specific command';
        helpInfo['examples'] = ['help', 'help call'];
        break;
        
      default:
        helpInfo['message'] = 'No help available for command: $command';
    }
    
    return helpInfo;
  }
  
  /// Create an error response
  Map<String, dynamic> _createErrorResponse(
    String message, {
    List<String>? suggestions,
    List<String>? examples,
    List<String>? availableCommands,
  }) {
    return {
      'success': false,
      'message': message,
      if (suggestions != null) 'suggestions': suggestions,
      if (examples != null) 'examples': examples,
      if (availableCommands != null) 'available_commands': availableCommands,
    };
  }
  
  /// Get command history
  List<Map<String, dynamic>> getCommandHistory() {
    return List.from(_commandHistory);
  }
  
  /// Clear command history
  void clearCommandHistory() {
    _commandHistory.clear();
  }
  
  /// Check if a command is supported
  bool isCommandSupported(String command) {
    return _commandHandlers.containsKey(command.toLowerCase());
  }
  
  /// Get a list of all supported commands
  List<String> getSupportedCommands() {
    return _commandHandlers.keys.toList();
  }
}
