extends "res://scripts/main.gd"

# Headless SceneTree tests can emit focus-loss notifications even though there
# is no real application window to background. Production platforms still use
# the base lifecycle behavior exactly as before.
func _notification(what: int) -> void:
    if DisplayServer.get_name() == "headless" and (what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED):
        _app_active = true
        return
    super._notification(what)
