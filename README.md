# ADBX

Native iOS client for authorized Android TV ADB connections over TCP.
Enable network debugging on your TV, enter its IP and port (usually 5555), and approve the RSA authorization prompt.
Supports saved devices, individual shell commands, basic app management and guided shell shortcuts.
APK installation uses ADB SYNC upload and pm install -r, with progress and best-effort temporary-file cleanup. Modern TLS wireless pairing is not implemented. No public internet exposure is recommended; use a trusted LAN or VPN.
The previous Redx project is preserved in archive/redx.
The app icon is generated during CI from scripts/icon.swift.
