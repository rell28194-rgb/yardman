use godot::prelude::*;

#[derive(GodotClass)]
#[class(init)]
struct YardmanRustKernels;

#[godot_api]
impl YardmanRustKernels {
    #[func]
    fn filter_points_in_radius(
        &self,
        points: PackedVector2Array,
        center: Vector2,
        radius: f64,
    ) -> PackedInt32Array {
        if radius < 0.0 || points.is_empty() {
            return PackedInt32Array::new();
        }

        let radius_sq = radius * radius;
        points
            .as_slice()
            .iter()
            .enumerate()
            .filter_map(|(index, point)| {
                let dx = f64::from(point.x - center.x);
                let dy = f64::from(point.y - center.y);
                (dx * dx + dy * dy <= radius_sq).then_some(index as i32)
            })
            .collect()
    }

    #[func]
    fn count_points_in_radius(
        &self,
        points: PackedVector2Array,
        center: Vector2,
        radius: f64,
    ) -> i64 {
        if radius < 0.0 || points.is_empty() {
            return 0;
        }

        let radius_sq = radius * radius;
        points
            .as_slice()
            .iter()
            .filter(|point| {
                let dx = f64::from(point.x - center.x);
                let dy = f64::from(point.y - center.y);
                dx * dx + dy * dy <= radius_sq
            })
            .count() as i64
    }

    #[func]
    fn build_id(&self) -> GString {
        "yardman-rust/api-4.7/kernel-v1".into()
    }
}

struct YardmanRustExtension;

#[gdextension]
unsafe impl ExtensionLibrary for YardmanRustExtension {}
