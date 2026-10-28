# CarX Fusion Diagnostics

Standalone Android diagnostic companion for CarX Fusion Offline.

Checks device API/ABIs, storage, Wi-Fi/network state, the installed `com.CarXTech.CarXDriftRacingFull` package/signing identity, installed APK hash when readable, direct OBB visibility, and user-selected APK/OBB/XAPK hashes. XAPK/ZIP scans hash embedded APK/OBB members and compare them against both the authoritative Beta 0.15 identities and the separately recorded black-screen Beta-0.15-ARM identities.

The app is read-only and does not patch CarX or alter saves.
