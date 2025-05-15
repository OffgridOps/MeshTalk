# MeshTalk 🚀🔐📡

**Quantum-Resistant, AI-Powered Offline Mesh Communication System**

MeshTalk is a decentralized, offline-capable voice and text communication platform designed for mission-critical, internet-free environments. It operates over WiFi/Bluetooth mesh networks using military-grade encryption and cutting-edge AI for real-time noise reduction and command recognition.

---

## 🌟 Features

- 📶 Offline Mesh Networking (via BATMAN-Adv over WiFi/Bluetooth)
- 🔐 Post-Quantum Encryption (CRYSTALS-Kyber + XChaCha20)
- 🧠 AI-Powered Noise Cancellation (RNNoise)
- 🗣️ Offline Voice Commands (via Vosk)
- 🌍 Flutter Frontend with walkie-talkie UI and mesh visualization
- ⚡ <100ms Voice Latency, fully peer-to-peer
- 🧱 Zero Central Servers, ephemeral identity, no phone numbers/IP logging

---

## 🛠️ Tech Stack

| Layer         | Tech Used                            |
|--------------|---------------------------------------|
| Mesh Routing | BATMAN-Adv (Linux kernel module)      |
| Transport    | UDP (voice) + TCP (signaling)         |
| Security     | CRYSTALS-Kyber, XChaCha20             |
| AI Features  | RNNoise, Vosk, TinyML                 |
| Frontend     | Flutter (Android/iOS/Desktop)         |

---

## 🔧 Setup Instructions

### ⚙️ Python Backend

> Requires Linux (for BATMAN-Adv), Python 3.9+, libsodium, etc.

```bash
cd server/
pip install -r requirements.txt
sudo modprobe batman-adv
python mesh_relay.py
