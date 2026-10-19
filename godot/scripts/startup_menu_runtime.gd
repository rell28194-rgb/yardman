extends "res://scripts/startup_menu.gd"

# Headless validation has no user who can dismiss the startup screen. Keep the
# production startup gate unchanged, but never let the overlay deactivate the
# game while an automated headless gameplay scene is exercising real controls.
func _set_open(open: bool) -> void:
    var effective_open := open and DisplayServer.get_name() != "headless"
    super._set_open(effective_open)
