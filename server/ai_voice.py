"""
MeshTalk AI Voice Processing Module
Implements noise cancellation using RNNoise and voice detection.
"""

import os
import base64
import logging
import tempfile
import subprocess
import wave
import io
import struct
import numpy as np
from typing import Optional, Tuple, List, Dict, Any
import threading
import time

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("ai_voice")

# Try to import RNNoise Python bindings
try:
    import rnnoise
    RNNOISE_AVAILABLE = True
except ImportError:
    RNNOISE_AVAILABLE = False
    logger.warning("RNNoise not available. Falling back to basic filtering.")

# Try to import librosa for audio processing
try:
    import librosa
    LIBROSA_AVAILABLE = True
except ImportError:
    LIBROSA_AVAILABLE = False
    logger.warning("Librosa not available. Some audio processing features will be limited.")

# Try to import soundfile for audio file operations
try:
    import soundfile as sf
    SOUNDFILE_AVAILABLE = True
except ImportError:
    SOUNDFILE_AVAILABLE = False
    logger.warning("SoundFile not available. File-based audio processing will be limited.")

# Constants for audio processing
SAMPLE_RATE = 16000  # Hz
FRAME_SIZE = 480  # 30ms at 16kHz
DENOISE_BUFFER = 8  # Frames of context for denoising


class BasicVoiceDetector:
    """
    Simple energy-based voice activity detector.
    """
    def __init__(self, 
                 energy_threshold: float = 0.01,
                 min_duration: float = 0.3,
                 frame_duration: float = 0.03):
        """
        Initialize the voice detector.
        
        Args:
            energy_threshold: Minimum normalized energy to consider as speech
            min_duration: Minimum speech duration in seconds
            frame_duration: Duration of each frame in seconds
        """
        self.energy_threshold = energy_threshold
        self.min_frames = int(min_duration / frame_duration)
        self.speech_frames = 0
        self.is_speech = False
    
    def process_frame(self, frame_data: bytes) -> bool:
        """
        Process a single audio frame and determine if it contains speech.
        
        Args:
            frame_data: Raw audio frame data
            
        Returns:
            bool: True if speech is detected
        """
        # Convert bytes to float array
        try:
            # Assuming 16-bit PCM
            format_str = f"<{len(frame_data)//2}h"
            int_samples = struct.unpack(format_str, frame_data)
            float_samples = np.array(int_samples) / 32768.0
            
            # Calculate energy
            energy = np.mean(float_samples ** 2)
            
            # Update speech detection state
            if energy > self.energy_threshold:
                self.speech_frames += 1
                if self.speech_frames >= self.min_frames:
                    self.is_speech = True
            else:
                self.speech_frames = 0
                if self.speech_frames == 0:
                    self.is_speech = False
            
            return self.is_speech
        except Exception as e:
            logger.error(f"Error processing audio frame: {str(e)}")
            return False


class RNNoiseProcessor:
    """
    Handles noise reduction using RNNoise.
    """
    def __init__(self):
        """Initialize the RNNoise processor."""
        self.has_rnnoise = RNNOISE_AVAILABLE
        
        if self.has_rnnoise:
            self.denoiser = rnnoise.RNNoise()
            logger.info("Initialized RNNoise processor")
        else:
            self.denoiser = None
            logger.warning("RNNoise not available, using fallback noise reduction")
            
        # Initialize buffer for processing context
        self.buffer = []
    
    def process_frame(self, frame_data: bytes) -> Tuple[bytes, float]:
        """
        Process a single audio frame with RNNoise.
        
        Args:
            frame_data: Raw audio frame data (should be 16-bit PCM, mono, 16kHz)
            
        Returns:
            Tuple[bytes, float]: Processed audio frame and VAD probability
        """
        if not self.has_rnnoise:
            return self._process_frame_fallback(frame_data)
        
        try:
            # Convert bytes to float array
            format_str = f"<{len(frame_data)//2}h"
            int_samples = struct.unpack(format_str, frame_data)
            float_samples = np.array(int_samples) / 32768.0
            
            # Ensure we have the right number of samples
            if len(float_samples) != FRAME_SIZE:
                float_samples = self._pad_or_trim(float_samples, FRAME_SIZE)
            
            # Process with RNNoise
            denoised, vad_prob = self.denoiser.process_frame(float_samples)
            
            # Convert back to int16 PCM
            denoised_int = (denoised * 32768.0).astype(np.int16)
            denoised_bytes = struct.pack(f"<{len(denoised_int)}h", *denoised_int)
            
            return denoised_bytes, vad_prob
        except Exception as e:
            logger.error(f"Error processing with RNNoise: {str(e)}")
            return frame_data, 0.0
    
    def _process_frame_fallback(self, frame_data: bytes) -> Tuple[bytes, float]:
        """
        Simple noise reduction fallback when RNNoise is unavailable.
        
        Args:
            frame_data: Raw audio frame data
            
        Returns:
            Tuple[bytes, float]: Processed audio frame and VAD probability
        """
        try:
            # Convert bytes to float array
            format_str = f"<{len(frame_data)//2}h"
            int_samples = struct.unpack(format_str, frame_data)
            float_samples = np.array(int_samples) / 32768.0
            
            # Add to buffer for context
            self.buffer.append(float_samples)
            if len(self.buffer) > DENOISE_BUFFER:
                self.buffer.pop(0)
            
            # Very simple noise reduction: spectral subtraction
            if len(self.buffer) >= 2:
                # Simple noise estimate from the buffer
                noise_estimate = np.mean(np.vstack(self.buffer[:-1]), axis=0) * 0.1
                
                # Subtract noise floor
                denoised = float_samples - noise_estimate
                denoised = np.clip(denoised, -1.0, 1.0)
            else:
                denoised = float_samples
            
            # Simple energy-based VAD
            energy = np.mean(denoised ** 2)
            vad_prob = min(1.0, energy * 20)  # Scale energy to 0-1 range
            
            # Convert back to int16 PCM
            denoised_int = (denoised * 32768.0).astype(np.int16)
            denoised_bytes = struct.pack(f"<{len(denoised_int)}h", *denoised_int)
            
            return denoised_bytes, vad_prob
        except Exception as e:
            logger.error(f"Error in fallback noise reduction: {str(e)}")
            return frame_data, 0.0
    
    def _pad_or_trim(self, samples: np.ndarray, target_length: int) -> np.ndarray:
        """Pad or trim audio samples to the target length."""
        if len(samples) < target_length:
            # Pad with zeros
            return np.pad(samples, (0, target_length - len(samples)))
        elif len(samples) > target_length:
            # Trim
            return samples[:target_length]
        else:
            return samples


class AudioProcessor:
    """
    Main audio processing class that handles both noise reduction and
    voice activity detection.
    """
    def __init__(self, vad_threshold: float = 0.5):
        """
        Initialize the audio processor.
        
        Args:
            vad_threshold: Voice activity detection threshold (0.0-1.0)
        """
        self.noise_processor = RNNoiseProcessor()
        self.vad_threshold = vad_threshold
        
        # For tracking audio state
        self.is_speech = False
        self.speech_frames = 0
        self.silence_frames = 0
        
        # Minimum speech/silence frames
        self.min_speech_frames = 10  # About 300ms
        self.min_silence_frames = 20  # About 600ms
    
    def process_audio(self, audio_data: bytes) -> Tuple[bytes, bool]:
        """
        Process audio data for noise reduction and voice detection.
        
        Args:
            audio_data: Raw audio data (16-bit PCM, mono, 16kHz)
            
        Returns:
            Tuple[bytes, bool]: Processed audio data and speech flag
        """
        # Check if the audio data is a valid length
        frame_size_bytes = FRAME_SIZE * 2  # 16-bit = 2 bytes per sample
        if len(audio_data) != frame_size_bytes:
            logger.warning(f"Expected {frame_size_bytes} bytes, got {len(audio_data)}")
            if len(audio_data) < frame_size_bytes:
                # Pad with silence
                audio_data += b'\x00' * (frame_size_bytes - len(audio_data))
            else:
                # Truncate
                audio_data = audio_data[:frame_size_bytes]
        
        # Apply noise reduction
        denoised_audio, vad_prob = self.noise_processor.process_frame(audio_data)
        
        # Update speech state
        if vad_prob >= self.vad_threshold:
            self.speech_frames += 1
            self.silence_frames = 0
            if self.speech_frames >= self.min_speech_frames:
                self.is_speech = True
        else:
            self.silence_frames += 1
            self.speech_frames = 0
            if self.silence_frames >= self.min_silence_frames:
                self.is_speech = False
        
        return denoised_audio, self.is_speech
    
    def process_audio_base64(self, audio_base64: str) -> Dict[str, Any]:
        """
        Process base64-encoded audio data.
        
        Args:
            audio_base64: Base64-encoded audio data
            
        Returns:
            Dict with processed audio and speech detection results
        """
        try:
            audio_data = base64.b64decode(audio_base64)
            processed_audio, is_speech = self.process_audio(audio_data)
            
            return {
                "processed_audio": base64.b64encode(processed_audio).decode('utf-8'),
                "is_speech": is_speech,
                "vad_confidence": float(is_speech)  # Simple confidence value
            }
        except Exception as e:
            logger.error(f"Error processing base64 audio: {str(e)}")
            return {
                "processed_audio": audio_base64,  # Return original on error
                "is_speech": False,
                "error": str(e)
            }


class AudioBufferProcessor:
    """
    Processes larger audio buffers, splitting them into frames
    and applying processing to each frame.
    """
    def __init__(self):
        """Initialize the buffer processor."""
        self.processor = AudioProcessor()
    
    def process_buffer(self, audio_buffer: bytes) -> bytes:
        """
        Process a buffer of audio data.
        
        Args:
            audio_buffer: Raw audio buffer (16-bit PCM, mono, 16kHz)
            
        Returns:
            bytes: Processed audio buffer
        """
        # Split buffer into frames
        frame_size_bytes = FRAME_SIZE * 2
        num_frames = len(audio_buffer) // frame_size_bytes
        
        processed_buffer = bytearray()
        
        for i in range(num_frames):
            start = i * frame_size_bytes
            end = start + frame_size_bytes
            frame = audio_buffer[start:end]
            
            # Process frame
            processed_frame, _ = self.processor.process_audio(frame)
            processed_buffer.extend(processed_frame)
        
        # Handle remaining samples
        remaining_bytes = len(audio_buffer) % frame_size_bytes
        if remaining_bytes > 0:
            start = num_frames * frame_size_bytes
            frame = audio_buffer[start:]
            
            # Pad frame to required size
            padded_frame = frame + b'\x00' * (frame_size_bytes - len(frame))
            
            # Process padded frame
            processed_frame, _ = self.processor.process_audio(padded_frame)
            
            # Only add the valid part back
            processed_buffer.extend(processed_frame[:len(frame)])
        
        return bytes(processed_buffer)
    
    def process_wav_file(self, wav_data: bytes) -> bytes:
        """
        Process a WAV file in memory.
        
        Args:
            wav_data: WAV file data
            
        Returns:
            bytes: Processed WAV file data
        """
        try:
            # Parse WAV file
            with io.BytesIO(wav_data) as wav_io:
                with wave.open(wav_io, 'rb') as wav_file:
                    channels = wav_file.getnchannels()
                    sample_width = wav_file.getsampwidth()
                    rate = wav_file.getframerate()
                    frames = wav_file.readframes(wav_file.getnframes())
            
            # Convert to mono, 16kHz if needed
            if channels != 1 or rate != SAMPLE_RATE or sample_width != 2:
                if LIBROSA_AVAILABLE and SOUNDFILE_AVAILABLE:
                    # Use librosa for high-quality resampling
                    with tempfile.NamedTemporaryFile(suffix='.wav', delete=True) as temp_in:
                        temp_in.write(wav_data)
                        temp_in.flush()
                        
                        # Load with librosa
                        y, sr = librosa.load(temp_in.name, sr=SAMPLE_RATE, mono=True)
                        
                        # Convert to int16
                        y_int16 = (y * 32768.0).astype(np.int16)
                        
                        # Write to buffer
                        buffer = io.BytesIO()
                        with wave.open(buffer, 'wb') as out_wav:
                            out_wav.setnchannels(1)
                            out_wav.setsampwidth(2)
                            out_wav.setframerate(SAMPLE_RATE)
                            out_wav.writeframes(y_int16.tobytes())
                        
                        frames = buffer.getvalue()
                else:
                    # Manual simple conversion
                    logger.warning("Advanced audio conversion libraries not available")
                    logger.warning("Audio quality may be affected by format conversion")
                    
                    # Convert directly using wave module
                    buffer = io.BytesIO()
                    with wave.open(buffer, 'wb') as out_wav:
                        out_wav.setnchannels(1)
                        out_wav.setsampwidth(2)
                        out_wav.setframerate(SAMPLE_RATE)
                        
                        # Extract raw audio data
                        with io.BytesIO(wav_data) as in_wav_io:
                            with wave.open(in_wav_io, 'rb') as in_wav:
                                raw_data = in_wav.readframes(in_wav.getnframes())
                                
                                # Simple down-mixing to mono if needed
                                if channels > 1:
                                    # Unpack samples
                                    format_str = f"<{len(raw_data)//(sample_width*channels)}{'h' if sample_width == 2 else 'b'}"
                                    samples = struct.unpack(format_str, raw_data)
                                    
                                    # Reshape to (samples, channels)
                                    samples_array = np.array(samples).reshape(-1, channels)
                                    
                                    # Mix down to mono
                                    mono = np.mean(samples_array, axis=1).astype(np.int16)
                                    
                                    # Convert back to bytes
                                    raw_data = struct.pack(f"<{len(mono)}h", *mono)
                                
                                out_wav.writeframes(raw_data)
                        
                        frames = buffer.getvalue()
            
            # Process the audio frames
            audio_data = frames[44:]  # Skip WAV header
            processed_audio = self.process_buffer(audio_data)
            
            # Create a new WAV file with the processed audio
            buffer = io.BytesIO()
            with wave.open(buffer, 'wb') as out_wav:
                out_wav.setnchannels(1)
                out_wav.setsampwidth(2)
                out_wav.setframerate(SAMPLE_RATE)
                out_wav.writeframes(processed_audio)
            
            processed_wav = buffer.getvalue()
            return processed_wav
            
        except Exception as e:
            logger.error(f"Error processing WAV file: {str(e)}")
            return wav_data  # Return original on error


# Voice command processor class placeholder
class VoiceCommandProcessor:
    """
    Basic voice command processor.
    In a full implementation, this would use Vosk for offline speech recognition.
    """
    def __init__(self):
        """Initialize the voice command processor."""
        self.commands = {
            "call": self._handle_call,
            "message": self._handle_message,
            "sos": self._handle_sos,
            "help": self._handle_help
        }
    
    def _handle_call(self, params: List[str]) -> Dict[str, Any]:
        """Handle 'call' command."""
        if not params:
            return {"success": False, "message": "No contact specified"}
        
        contact = " ".join(params)
        return {
            "success": True,
            "command": "call",
            "contact": contact,
            "action": "initiate_call"
        }
    
    def _handle_message(self, params: List[str]) -> Dict[str, Any]:
        """Handle 'message' command."""
        if len(params) < 2:
            return {"success": False, "message": "Requires contact and message"}
        
        contact = params[0]
        message = " ".join(params[1:])
        return {
            "success": True,
            "command": "message",
            "contact": contact,
            "text": message,
            "action": "send_message"
        }
    
    def _handle_sos(self, params: List[str]) -> Dict[str, Any]:
        """Handle 'sos' command."""
        message = " ".join(params) if params else "SOS alert!"
        return {
            "success": True,
            "command": "sos",
            "message": message,
            "action": "broadcast_sos"
        }
    
    def _handle_help(self, params: List[str]) -> Dict[str, Any]:
        """Handle 'help' command."""
        return {
            "success": True,
            "command": "help",
            "message": "Available commands: call, message, sos, help",
            "action": "show_help"
        }
    
    def process_command(self, text: str) -> Dict[str, Any]:
        """
        Process a text command.
        
        Args:
            text: Command text
            
        Returns:
            Dict with command processing results
        """
        parts = text.lower().split()
        if not parts:
            return {"success": False, "message": "Empty command"}
        
        command = parts[0]
        params = parts[1:]
        
        if command in self.commands:
            return self.commands[command](params)
        else:
            return {
                "success": False,
                "message": f"Unknown command: {command}",
                "available_commands": list(self.commands.keys())
            }


# Singleton instances for easy use
audio_processor = AudioProcessor()
buffer_processor = AudioBufferProcessor()
command_processor = VoiceCommandProcessor()

# Utility functions for easy API access
def process_audio_frame(audio_data: bytes) -> Tuple[bytes, bool]:
    """Process a single audio frame."""
    return audio_processor.process_audio(audio_data)

def process_audio_buffer(audio_buffer: bytes) -> bytes:
    """Process a buffer of audio data."""
    return buffer_processor.process_buffer(audio_buffer)

def process_audio_base64(audio_base64: str) -> Dict[str, Any]:
    """Process base64-encoded audio data."""
    return audio_processor.process_audio_base64(audio_base64)

def process_voice_command(command_text: str) -> Dict[str, Any]:
    """Process a voice command."""
    return command_processor.process_command(command_text)


# Test the module
if __name__ == "__main__":
    # Generate a test audio buffer (sine wave)
    def generate_test_audio():
        duration = 1.0  # seconds
        rate = SAMPLE_RATE
        t = np.linspace(0, duration, int(rate * duration), endpoint=False)
        
        # Generate a 440 Hz sine wave with some noise
        sine_wave = 0.5 * np.sin(2 * np.pi * 440 * t)
        noise = 0.1 * np.random.randn(len(sine_wave))
        signal = sine_wave + noise
        
        # Convert to int16
        signal_int16 = (signal * 32767).astype(np.int16)
        
        # Convert to bytes
        signal_bytes = signal_int16.tobytes()
        
        return signal_bytes
    
    # Test audio processing
    test_audio = generate_test_audio()
    print(f"Generated {len(test_audio)} bytes of test audio")
    
    # Process the audio
    processed_audio = process_audio_buffer(test_audio)
    print(f"Processed audio: {len(processed_audio)} bytes")
    
    # Test voice command processing
    test_commands = [
        "call John",
        "message Alice Hello there!",
        "sos Emergency in sector 7",
        "help",
        "unknown command"
    ]
    
    for cmd in test_commands:
        result = process_voice_command(cmd)
        print(f"Command: '{cmd}' -> Result: {result}")
