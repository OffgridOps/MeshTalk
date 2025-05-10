import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:convert/convert.dart';
import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/export.dart';

/// Service for cryptographic operations in MeshTalk
class CryptoService {
  // Keys storage
  late String _publicKey;
  late String _privateKey;
  bool _initialized = false;
  
  // Random number generator
  final _secureRandom = SecureRandom('Fortuna');
  
  // Initialize the crypto service
  Future<void> initialize() async {
    // Initialize secure random
    final random = Random.secure();
    final seed = List<int>.generate(32, (_) => random.nextInt(256));
    _secureRandom.seed(KeyParameter(Uint8List.fromList(seed)));
    
    // Load or generate keys
    await _loadOrGenerateKeys();
  }
  
  // Load existing keys or generate new ones
  Future<void> _loadOrGenerateKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final publicKey = prefs.getString('public_key');
      final privateKey = prefs.getString('private_key');
      
      if (publicKey != null && privateKey != null) {
        _publicKey = publicKey;
        _privateKey = privateKey;
      } else {
        // Generate new keypair
        await _generateAndSaveKeyPair();
      }
      
      _initialized = true;
    } catch (e) {
      print('Error loading crypto keys: $e');
      // Generate new keypair on error
      await _generateAndSaveKeyPair();
      _initialized = true;
    }
  }
  
  // Generate and save a new keypair
  Future<void> _generateAndSaveKeyPair() async {
    try {
      // Generate an RSA key pair for development
      // In a real implementation, we would use CRYSTALS-Kyber for PQ resistance
      final keyPair = await _generateRSAKeyPair();
      
      // Convert keys to PEM format
      final publicKey = keyPair.publicKey.toString();
      final privateKey = keyPair.privateKey.toString();
      
      // Store the keys
      _publicKey = publicKey;
      _privateKey = privateKey;
      
      // Save to preferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('public_key', publicKey);
      await prefs.setString('private_key', privateKey);
    } catch (e) {
      print('Error generating keypair: $e');
      throw Exception('Failed to generate cryptographic keys');
    }
  }
  
  // Generate an RSA key pair (for development)
  Future<AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>> _generateRSAKeyPair() async {
    final keyGen = KeyGenerator('RSA');
    
    // Configure for 2048-bit RSA
    final rsaParams = RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 12);
    
    // Initialize the generator
    final params = ParametersWithRandom(rsaParams, _secureRandom);
    keyGen.init(params);
    
    // Generate the keypair
    return keyGen.generateKeyPair() as AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>;
  }
  
  // Get public key as base64
  String getPublicKey() {
    _checkInitialized();
    return _publicKey;
  }
  
  // Encrypt data with XChaCha20-Poly1305 (simplified version for development)
  String encrypt(String data, String recipientPublicKey) {
    _checkInitialized();
    
    try {
      // Generate a random symmetric key
      final symmetricKey = _secureRandom.nextBytes(32);
      
      // Encrypt the data with the symmetric key
      final encryptedData = _encryptWithSymmetricKey(data, symmetricKey);
      
      // Encrypt the symmetric key with the recipient's public key
      // In a real implementation, this would use CRYSTALS-Kyber
      final encryptedKey = _encryptAsymmetric(symmetricKey, recipientPublicKey);
      
      // Combine encrypted key and data
      final result = {
        'encrypted_key': base64Encode(encryptedKey),
        'encrypted_data': base64Encode(encryptedData),
      };
      
      return json.encode(result);
    } catch (e) {
      print('Encryption error: $e');
      // Fallback to simple encryption for development
      return _simpleEncrypt(data, recipientPublicKey);
    }
  }
  
  // Decrypt data with XChaCha20-Poly1305 (simplified version for development)
  String decrypt(String encryptedData) {
    _checkInitialized();
    
    try {
      final data = json.decode(encryptedData);
      
      // Decrypt the symmetric key
      final encryptedKey = base64Decode(data['encrypted_key']);
      final symmetricKey = _decryptAsymmetric(encryptedKey);
      
      // Decrypt the data with the symmetric key
      final ciphertext = base64Decode(data['encrypted_data']);
      return _decryptWithSymmetricKey(ciphertext, symmetricKey);
    } catch (e) {
      print('Decryption error: $e');
      // Fallback to simple decryption for development
      return _simpleDecrypt(encryptedData);
    }
  }
  
  // Simple encrypt for development fallback
  String _simpleEncrypt(String data, String recipientPublicKey) {
    // Create a key from the public key
    final keyBytes = crypto.sha256.convert(utf8.encode(recipientPublicKey)).bytes;
    
    // Generate a random IV
    final iv = _secureRandom.nextBytes(16);
    
    // XOR the data with a keystream derived from the key and IV
    final dataBytes = utf8.encode(data);
    final encryptedBytes = List<int>.filled(dataBytes.length, 0);
    
    for (int i = 0; i < dataBytes.length; i++) {
      // Simple key derivation for each byte (not secure, just for development)
      final keyByte = keyBytes[i % keyBytes.length] ^ iv[i % iv.length];
      encryptedBytes[i] = dataBytes[i] ^ keyByte;
    }
    
    // Result format: base64(iv + encrypted)
    final result = Uint8List(iv.length + encryptedBytes.length);
    result.setRange(0, iv.length, iv);
    result.setRange(iv.length, result.length, encryptedBytes);
    
    return base64Encode(result);
  }
  
  // Simple decrypt for development fallback
  String _simpleDecrypt(String encryptedData) {
    try {
      // Decode the base64 data
      final allBytes = base64Decode(encryptedData);
      
      // Extract IV and ciphertext
      final iv = allBytes.sublist(0, 16);
      final ciphertext = allBytes.sublist(16);
      
      // Create a key from the private key
      final keyBytes = crypto.sha256.convert(utf8.encode(_privateKey)).bytes;
      
      // XOR the ciphertext with the keystream
      final decryptedBytes = List<int>.filled(ciphertext.length, 0);
      
      for (int i = 0; i < ciphertext.length; i++) {
        // Simple key derivation for each byte
        final keyByte = keyBytes[i % keyBytes.length] ^ iv[i % iv.length];
        decryptedBytes[i] = ciphertext[i] ^ keyByte;
      }
      
      return utf8.decode(decryptedBytes);
    } catch (e) {
      print('Simple decryption failed: $e');
      return '[Decryption failed]';
    }
  }
  
  // Encrypt with symmetric key (placeholder implementation)
  Uint8List _encryptWithSymmetricKey(String data, Uint8List key) {
    // In a real implementation, this would use XChaCha20-Poly1305
    
    // For development, we'll use a simple XOR cipher with SHA-256 key expansion
    final dataBytes = utf8.encode(data);
    final result = Uint8List(dataBytes.length + 16); // Space for nonce
    
    // Generate random nonce
    final nonce = _secureRandom.nextBytes(16);
    result.setRange(0, 16, nonce);
    
    // Expand key with HKDF-like construction
    final expandedKey = _expandKey(key, nonce, dataBytes.length);
    
    // XOR the data with the expanded key
    for (int i = 0; i < dataBytes.length; i++) {
      result[i + 16] = dataBytes[i] ^ expandedKey[i];
    }
    
    return result;
  }
  
  // Decrypt with symmetric key (placeholder implementation)
  String _decryptWithSymmetricKey(Uint8List data, Uint8List key) {
    // Extract nonce
    final nonce = data.sublist(0, 16);
    final ciphertext = data.sublist(16);
    
    // Expand key
    final expandedKey = _expandKey(key, nonce, ciphertext.length);
    
    // XOR to decrypt
    final decryptedBytes = Uint8List(ciphertext.length);
    for (int i = 0; i < ciphertext.length; i++) {
      decryptedBytes[i] = ciphertext[i] ^ expandedKey[i];
    }
    
    return utf8.decode(decryptedBytes);
  }
  
  // Expand a key using a HKDF-like construction (simplified)
  Uint8List _expandKey(Uint8List key, Uint8List nonce, int length) {
    final result = Uint8List(length);
    var prevHash = Uint8List(0);
    
    for (int i = 0; i < length; i += 32) {
      final hmac = crypto.Hmac(crypto.sha256, key);
      final input = Uint8List(prevHash.length + nonce.length + 1);
      input.setRange(0, prevHash.length, prevHash);
      input.setRange(prevHash.length, prevHash.length + nonce.length, nonce);
      input[prevHash.length + nonce.length] = (i / 32).floor();
      
      prevHash = Uint8List.fromList(hmac.convert(input).bytes);
      
      final bytesToCopy = min(32, length - i);
      result.setRange(i, i + bytesToCopy, prevHash.sublist(0, bytesToCopy));
    }
    
    return result;
  }
  
  // Encrypt data asymmetrically (placeholder implementation)
  Uint8List _encryptAsymmetric(Uint8List data, String publicKey) {
    // In a real implementation, this would use CRYSTALS-Kyber
    
    // For development, use a simple approach
    final keyHash = crypto.sha256.convert(utf8.encode(publicKey)).bytes;
    
    // XOR the data with key hash
    final result = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ keyHash[i % keyHash.length];
    }
    
    return result;
  }
  
  // Decrypt data asymmetrically (placeholder implementation)
  Uint8List _decryptAsymmetric(Uint8List data) {
    // In a real implementation, this would use CRYSTALS-Kyber
    
    // For development, use the corresponding decrypt operation
    final keyHash = crypto.sha256.convert(utf8.encode(_privateKey)).bytes;
    
    // XOR to decrypt
    final result = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ keyHash[i % keyHash.length];
    }
    
    return result;
  }
  
  // Generate a hash of the data
  String generateHash(String data) {
    final bytes = utf8.encode(data);
    final digest = crypto.sha256.convert(bytes);
    return digest.toString();
  }
  
  // Generate a message authentication code (MAC)
  String generateMAC(String data, String key) {
    final keyBytes = utf8.encode(key);
    final dataBytes = utf8.encode(data);
    final hmac = crypto.Hmac(crypto.sha256, keyBytes).convert(dataBytes);
    return hmac.toString();
  }
  
  // Verify a message authentication code (MAC)
  bool verifyMAC(String data, String key, String mac) {
    final expectedMac = generateMAC(data, key);
    return crypto.Hmac.constantTimeBytesEquality(
      hex.decode(expectedMac), 
      hex.decode(mac)
    );
  }
  
  // Check if the service is initialized
  void _checkInitialized() {
    if (!_initialized) {
      throw Exception('CryptoService not initialized');
    }
  }
}
