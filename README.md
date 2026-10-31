# Universal Solar Monitoring System

An end-to-end, open-source solar monitoring and management solution for off-grid and hybrid solar installations. It connects directly to your **Solar Charge Controller** and **Smart BMS** via Bluetooth Low Energy (BLE) or wired RS485 Modbus, relaying real-time telemetry to your personal Firebase cloud, accessible anywhere via a cross-platform Flutter application.

---

## 🌟 Key Features

* **Multi-Protocol Controller Support:**
  * **SRNE Shiner Series** MPPT charge controllers (`Shiner2410`, `2420`, `2430`, `2440`, `2460`) via BLE or RS485 Modbus.
  * PIN-protected Bluetooth pairing support for newer SRNE BT modules.
* **Smart BMS Integration:**
  * **JK Smart BMS** (active cell voltages, balancing current, MOS temperatures, cycle counts, SOC).
  * **JBD / Xiaoxiang BMS** telemetry support.
* **100% Free Self-Hosted Backend:**
  * Uses your own **Firebase Realtime Database** (Spark Plan, 100% free forever, no credit card required).
  * Your data remains strictly private in your own Google Cloud account.
* **Reliable ESP32 Gateway Firmware:**
  * Built on ESP-IDF / Arduino framework with PlatformIO.
  * Supports **ESP32** and **ESP32-S3** (4MB flash minimum).
  * Native non-blocking Wi-Fi reconnect and OTA firmware update capabilities.
* **Modern Flutter Android & Web App:**
  * Real-time metrics: PV voltage/current/power, battery SOC, charging/discharging curves, and load status.
  * Soft-AP Wi-Fi provisioning for gateway setup directly from the phone.
  * Full energy statistics, lifetime production tracking, and fault diagnostics.
* **ESP Web Tools Flasher:**
  * Flash firmware straight from Google Chrome or Microsoft Edge via USB without installing PlatformIO or Arduino IDE.

---

## 🏗️ System Architecture

```
+-----------------------------------+        +-----------------------------------+
|      Solar Charge Controller      |        |             Smart BMS             |
|       (SRNE Shiner MPPT)          |        |        (JK BMS / JBD BMS)         |
+-----------------+-----------------+        +-----------------+-----------------+
                  | (BLE or RS485)                             | (BLE)
                  +-----------------------+--------------------+
                                          |
                                          v
                              +-----------------------+
                              |     ESP32 Gateway     |
                              |   (ESP32 / ESP32-S3)  |
                              +-----------+-----------+
                                          | (Wi-Fi HTTPS/WSS)
                                          v
                              +-----------------------+
                              | Firebase Realtime DB  |
                              |  (Your Free Account)  |
                              +-----------+-----------+
                                          |
                                          v
                              +-----------------------+
                              |   Flutter Mobile App  |
                              |    (Android / Web)    |
                              +-----------------------+
```

---

## 📂 Repository Structure

```
├── firmware/          # PlatformIO project for ESP32 and ESP32-S3 gateway
│   ├── src/           # Firmware source (main.cpp, universal_gateway.h)
│   ├── platformio.ini # PlatformIO environment configurations
│   └── partitions_4mb.csv
├── mobile_app/        # Flutter cross-platform application (Android / Web)
│   ├── lib/           # Flutter UI, state management, and services
│   ├── android/       # Native Android configuration
│   └── pubspec.yaml
├── firebase/          # Firebase setup guide & security rules
│   └── database.rules.json
├── web_flasher/       # In-browser web flashing interface (ESP Web Tools)
├── docs/              # Setup guides, wiring diagrams, and documentation
│   └── SETUP_GUIDE.html
├── tools/             # Build scripts and automation helpers
├── .gitignore
├── LICENSE            # MIT License
└── README.md
```

---

## 🚀 Getting Started

### 1. Set Up Your Free Firebase Backend
1. Follow the step-by-step instructions in [`firebase/README.md`](firebase/README.md).
2. Enable **Email/Password** authentication.
3. Create a **Realtime Database** and paste the security rules from [`firebase/database.rules.json`](firebase/database.rules.json).
4. Note your **Database URL** and **Web API Key** from Project Settings.

---

### 2. Flash the ESP32 Gateway Firmware

#### Option A: Using PlatformIO (Recommended for Developers)
1. Install [VS Code](https://code.visualstudio.com/) and the **PlatformIO IDE** extension.
2. Open the `firmware/` folder in VS Code.
3. Connect your ESP32 or ESP32-S3 board via USB.
4. Select your target environment in PlatformIO:
   * `esp32-s3-devkitc-1` for ESP32-S3 boards.
   * `esp32dev` for standard ESP32 boards.
5. Click **Build** and **Upload**.

#### Option B: Web Flasher (Easiest for End-Users)
1. Open [`web_flasher/index.html`](web_flasher/index.html) in Chrome or Edge over HTTPS (or host locally using `python -m http.server`).
2. Plug in your ESP32 board and click **Install**.

---

### 3. Run the Flutter Mobile App

#### Prerequisites:
* [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.x or higher)
* Android Studio / Android SDK (API 29+ for Wi-Fi provisioning)

#### Steps:
```bash
cd mobile_app
flutter pub get
flutter run
```

#### Android Release Build:
To build a signed release APK:
1. Copy `mobile_app/android/key.properties.example` to `mobile_app/android/key.properties` and add your keystore details.
2. Run:
   ```bash
   flutter build apk --release
   ```
   *(Or use `./tools/build_android.ps1 -Mode Release`)*

---

### 4. Gateway Provisioning & Setup

1. Power on the flashed ESP32 gateway.
2. On initial boot, the gateway broadcasts a setup Wi-Fi access point (e.g., `NoxBrain-XXXXXX`).
3. Open the **Solar Monitor App** on your Android phone and follow the **Setup Wizard**:
   * Enter your home 2.4 GHz Wi-Fi credentials.
   * Enter your Firebase Database URL and API Key.
   * Pair your SRNE Controller and JK/JBD BMS via Bluetooth or wired RS485.
4. The gateway will save credentials securely in encrypted NVS and start publishing telemetry every 2 seconds.

---

## 🔌 Hardware Compatibility & Pinout

### Required Components:
* **ESP32 or ESP32-S3 Development Board** (minimum 4MB Flash).
* **Power Supply:** 5V 1A DC step-down converter from the battery or USB power.
* **RS485 Transceiver (Optional for wired RS485):**
  * MAX485 or TTL-to-RS485 auto-flow module.
  * Connect `RO` to ESP32 RX, `DI` to ESP32 TX, `VCC` to 3.3V/5V, and `GND` to common ground.
  * Connect `A` and `B` to the controller's RS485 port.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE) — anyone is free to use, modify, and distribute this software for personal or commercial use.
