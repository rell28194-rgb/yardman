use godot::prelude::*;
use yardman_core::{Point2, count_points_in_radius, filter_indices_in_radius};

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
        filter_indices_in_radius(
            points
                .as_slice()
                .iter()
                .map(|point| Point2::new(point.x, point.y)),
            Point2::new(center.x, center.y),
            radius,
        )
        .into_iter()
        .collect()
    }

    #[func]
    fn count_points_in_radius(
        &self,
        points: PackedVector2Array,
        center: Vector2,
        radius: f64,
    ) -> i64 {
        count_points_in_radius(
            points
                .as_slice()
                .iter()
                .map(|point| Point2::new(point.x, point.y)),
            Point2::new(center.x, center.y),
            radius,
        )
    }

    #[func]
    fn build_id(&self) -> GString {
        "yardman-rust/api-4.7/core-v1".into()
    }
}

struct YardmanRustExtension;

#[gdextension]
unsafe impl ExtensionLibrary for YardmanRustExtension {}
