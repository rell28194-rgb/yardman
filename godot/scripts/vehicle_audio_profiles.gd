extends RefCounted
class_name YardmanVehicleAudioProfiles

const DEFAULT_ID := "legacy_inline6"

# Acoustic tuning is intentionally decoupled from the physics catalog. These are
# game-audio signatures, not recordings or claims of exact production exhausts.
const PROFILES := {
    "legacy_inline6": {
        "id": "legacy_inline6", "label": "Legacy Inline Six",
        "idle_rpm": 900.0, "redline_rpm": 6900.0, "base_hz": 48.0,
        "pitch_bias": 1.00, "harmonic_2": 0.46, "harmonic_3": 0.24, "harmonic_4": 0.11,
        "rasp": 0.06, "exhaust_depth": 0.42,
        "idle_db": -23.0, "low_db": -26.0, "high_db": -29.0, "exhaust_db": -30.0, "transmission_db": -39.0,
    },
    "crown_v6": {
        "id": "crown_v6", "label": "Crown V6",
        "idle_rpm": 720.0, "redline_rpm": 6600.0, "base_hz": 42.0,
        "pitch_bias": 0.94, "harmonic_2": 0.39, "harmonic_3": 0.18, "harmonic_4": 0.075,
        "rasp": 0.035, "exhaust_depth": 0.53,
        "idle_db": -22.0, "low_db": -25.5, "high_db": -29.5, "exhaust_db": -29.0, "transmission_db": -40.0,
    },
    "mark_x_v6": {
        "id": "mark_x_v6", "label": "Mark X V6",
        "idle_rpm": 760.0, "redline_rpm": 7000.0, "base_hz": 47.0,
        "pitch_bias": 1.02, "harmonic_2": 0.48, "harmonic_3": 0.27, "harmonic_4": 0.13,
        "rasp": 0.075, "exhaust_depth": 0.47,
        "idle_db": -22.5, "low_db": -25.0, "high_db": -28.0, "exhaust_db": -28.5, "transmission_db": -38.0,
    },
    "port_royal_flat6": {
        "id": "port_royal_flat6", "label": "Port Royal Flat Six",
        "idle_rpm": 820.0, "redline_rpm": 7600.0, "base_hz": 56.0,
        "pitch_bias": 1.10, "harmonic_2": 0.55, "harmonic_3": 0.33, "harmonic_4": 0.18,
        "rasp": 0.11, "exhaust_depth": 0.36,
        "idle_db": -23.0, "low_db": -25.5, "high_db": -27.0, "exhaust_db": -27.5, "transmission_db": -37.0,
    },
}

static func has(profile_id: String) -> bool:
    return PROFILES.has(profile_id)

static func profile(profile_id: String) -> Dictionary:
    var key := profile_id if PROFILES.has(profile_id) else DEFAULT_ID
    return PROFILES[key].duplicate(true)

static func ids() -> Array:
    return PROFILES.keys()
