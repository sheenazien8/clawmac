# OpenClaw Menu Bar

AI Assistant macOS app yang menggantikan Siri - Chat langsung dengan OpenClaw dari status bar!

## Fitur

- ✅ **Menu Bar App** - Icon di status bar macOS, klik untuk buka chat
- ✅ **Popup chat window** - Ukuran 380x600, muncul dari status bar
- ✅ **Chat UI mirip Telegram** - Bubble chat dengan typing indicator animasi
- ✅ **Voice Commands** - Speech-to-text Bahasa Indonesia (id-ID)
- ✅ **Clear Chat** - Tombol hapus percakapan
- 🔄 **OpenClaw Integration** - Terhubung dengan OpenClaw API (perlu setup)

## Cara Build & Run

### Opsi 1: Via Swift Package Manager (Recommended)

```bash
cd /Users/sheenazien8/Documents/Code/my-project/OpenClawMenuBar
swift build

# Run (requires entitlements for mic/speech permissions)
swift run
```

### Opsi 2: Create Xcode Project

```bash
cd /Users/sheenazien8/Documents/Code/my-project/OpenClawMenuBar
swift package generate-xcodeproj
open OpenClawMenuBar.xcodeproj
```

Lalu **Cmd+R** di Xcode.

## Struktur Project

```
OpenClawMenuBar/
├── Package.swift                    # Swift Package manifest
├── OpenClawMenuBar.entitlements   # Sandbox capabilities (mic, speech)
├── Info.plist                     # App info + permissions
├── README.md                      # This file
└── Sources/
    └── main.swift                 # All code in single file
```

## Permission yang Diperlukan

Saat pertama kali run, macOS akan minta permission:
1. **Microphone** - Untuk voice input
2. **Speech Recognition** - Untuk convert suara ke teks

## Cara Penggunaan

1. **Chat**: Klik icon `message.fill` di status bar → ketik pesan → tekan Enter atau klik tombol kirim
2. **Voice**: Klik tombol mic (lingkaran) → bicara Bahasa Indonesia → otomatis kirim setelah berhenti ngomong
3. **Clear**: Klik icon trash di header untuk hapus semua chat

## Integrasi OpenClaw API

Edit `Sources/main.swift`, cari fungsi `sendMessage()` dan ganti bagian `simulateResponse` dengan API call ke OpenClaw:

```swift
// TODO: Replace with actual OpenClaw API call
let apiClient = OpenClawAPIClient()
apiClient.sendMessage(messageText) { response in
    // Handle response
}
```

## Requirements

- macOS 14.0+
- Swift 5.9+
- Xcode 15.0+ (jika pakai Xcode)

## Troubleshooting

**Error: "Speech recognizer tidak tersedia"**
- Pastikan macOS sudah di-set ke region yang support speech recognition
- Cek System Settings > Privacy & Security > Speech Recognition

**Error: "Izin mic diperlukan"**
- Buka System Settings > Privacy & Security > Microphone
- Pastikan OpenClawMenuBar di-allow

## TODO

- [ ] Connect to real OpenClaw API
- [ ] Support streaming responses
- [ ] Auto-save chat history
- [ ] Custom keyboard shortcuts
- [ ] Global hotkey to open chat
