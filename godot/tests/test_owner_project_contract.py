from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "project.godot"
GARAGE = ROOT / "scripts" / "vehicle_garage.gd"
CATALOG = ROOT / "scripts" / "vehicle_catalog.gd"
AGENTS = ROOT.parent / "AGENTS.md"


class OwnerProjectContractTests(unittest.TestCase):
    def test_garage_has_no_job_or_economy_dependency(self):
        text = GARAGE.read_text(encoding="utf-8")
        forbidden = [
            'preload("res://scripts/job_persistence_runtime.gd")',
            '/root/JobRuntime',
            '/root/JobPersistenceRuntime',
            'VEHICLE_PRICES_JMD',
            '_spend_wallet',
            '_refund_wallet',
        ]
        present = [token for token in forbidden if token in text]
        self.assertFalse(present, f"garage re-coupled to jobs/economy: {present}")

    def test_mark_x_is_a_hard_runtime_ban(self):
        garage = GARAGE.read_text(encoding="utf-8")
        catalog = CATALOG.read_text(encoding="utf-8")
        for text in (garage, catalog):
            self.assertIn('const BANNED_IDS := {', text)
            self.assertIn('"toyota_mark_x": true', text)
            self.assertIn('"toyota_mark_x_2013": true', text)
            self.assertIn('"mark_x": true', text)
        self.assertIn('"VEHICLE BANNED"', garage)
        self.assertIn('if _is_banned(vehicle_id):', garage)
        self.assertIn('if not _is_blocked(saved) and _source_ready(saved):', garage)
        self.assertIn('const PRODUCTION_IDS := ["toyota_crown"]', catalog)
        self.assertIn('if is_blocked(vehicle_id):', catalog)
        self.assertIn('return false', catalog)
        self.assertNotIn('"toyota_mark_x": {', catalog)

    def test_992_path_is_excluded(self):
        garage = GARAGE.read_text(encoding="utf-8")
        catalog = CATALOG.read_text(encoding="utf-8")
        for text in (garage, catalog):
            self.assertIn('const EXCLUDED_IDS := {', text)
            self.assertIn('"port_royal_992": true', text)
            self.assertIn('"porsche_911_992": true', text)
            self.assertIn('"992": true', text)
        self.assertNotIn('"port_royal_992": {', catalog)

    def test_recovered_fleet_is_a_required_runtime_input(self):
        self.assertTrue((ROOT / "scripts" / "vehicle_fleet_registry.gd").is_file())
        self.assertTrue((ROOT / "data" / "vehicle_fleet_runtime.json").is_file())
        self.assertTrue((ROOT / "data" / "vehicle_fleet_supplemental.json").is_file())
        self.assertTrue((ROOT / "data" / "vehicle_fleet_calibration.json").is_file())
        catalog = CATALOG.read_text(encoding="utf-8")
        self.assertIn('preload("res://scripts/vehicle_fleet_registry.gd")', catalog)
        self.assertIn('for vehicle_id in FleetRegistry.ids():', catalog)
        self.assertIn('if is_blocked(str(vehicle_id)):', catalog)

    def test_validated_renderer_stack_is_active(self):
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn('RenderRuntime="*res://scripts/render_runtime.gd"', project)
        self.assertIn('renderer/rendering_method="gl_compatibility"', project)
        self.assertIn('renderer/rendering_method.mobile="mobile"', project)
        self.assertIn('textures/vram_compression/import_etc2_astc=true', project)

        for relative in [
            "scripts/render_runtime.gd",
            "scripts/render_quality_manager.gd",
            "scripts/render_material_registry.gd",
            "shaders/road_surface.gdshader",
            "shaders/road_surface_gles.gdshader",
            "shaders/water.gdshader",
            "shaders/water_gles.gdshader",
            "shaders/terrain_surface.gdshader",
            "shaders/terrain_surface_gles.gdshader",
            "tests/renderer_capability_matrix_test.gd",
            "tests/material_variants_test.gd",
            "tests/render_quality_test.gd",
        ]:
            self.assertTrue((ROOT / relative).is_file(), f"validated renderer asset missing: {relative}")

        runtime = (ROOT / "scripts" / "render_runtime.gd").read_text(encoding="utf-8")
        self.assertIn('render_quality_manager.gd', runtime)
        self.assertIn('render_material_registry.gd', runtime)
        self.assertIn('apply_streamer_material_policy', runtime)
        self.assertIn('stream_integration_budget_for', runtime)
        self.assertIn('apply_shadow_policy_to_light', runtime)

    def test_project_authority_records_owner_rules(self):
        text = AGENTS.read_text(encoding="utf-8")
        self.assertIn('Toyota Mark X is banned from Yardman production/runtime', text)
        self.assertIn('recovered fleet registry/data', text)
        self.assertIn('codex/validated-rdx-promotion-20261018', text)
        self.assertIn('RDX-003 conservative HZB', text)
        self.assertIn('RDX-004 cluster/meshlet', text)


if __name__ == "__main__":
    unittest.main()
