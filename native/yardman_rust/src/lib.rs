use godot::prelude::*;
use yardman_core::{
    Point2, SpatialIndex2D, count_points_in_radius, filter_indices_in_radius,
};

#[derive(GodotClass)]
#[class(init)]
struct YardmanRustKernels {
    spatial_index: SpatialIndex2D,
}

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

    /// Bulk-load one persistent R-tree. Callers keep one kernel instance per
    /// independent index (buildings, traffic, replication interest, and so on).
    #[func]
    fn configure_spatial_index(
        &mut self,
        points: PackedVector2Array,
        ids: PackedInt32Array,
    ) -> bool {
        if points.len() != ids.len()
            || points
                .as_slice()
                .iter()
                .any(|point| !point.x.is_finite() || !point.y.is_finite())
        {
            self.spatial_index = SpatialIndex2D::new();
            return false;
        }

        self.spatial_index = SpatialIndex2D::bulk_load(
            points
                .as_slice()
                .iter()
                .zip(ids.as_slice().iter())
                .map(|(point, id)| (*id, Point2::new(point.x, point.y))),
        );
        self.spatial_index.len() == points.len()
    }

    #[func]
    fn clear_spatial_index(&mut self) {
        self.spatial_index = SpatialIndex2D::new();
    }

    #[func]
    fn spatial_index_len(&self) -> i64 {
        self.spatial_index.len() as i64
    }

    #[func]
    fn query_spatial_radius(
        &self,
        center: Vector2,
        radius: f64,
        max_results: i64,
    ) -> PackedInt32Array {
        if max_results <= 0 {
            return PackedInt32Array::new();
        }
        self.spatial_index
            .query_radius(
                Point2::new(center.x, center.y),
                radius as f32,
                max_results.min(i64::from(i32::MAX)) as usize,
            )
            .into_iter()
            .collect()
    }

    #[func]
    fn query_spatial_annulus(
        &self,
        center: Vector2,
        min_distance: f64,
        max_distance: f64,
        max_results: i64,
    ) -> PackedInt32Array {
        if max_results <= 0 {
            return PackedInt32Array::new();
        }
        self.spatial_index
            .query_annulus(
                Point2::new(center.x, center.y),
                min_distance as f32,
                max_distance as f32,
                max_results.min(i64::from(i32::MAX)) as usize,
            )
            .into_iter()
            .collect()
    }

    #[func]
    fn build_id(&self) -> GString {
        "yardman-rust/api-4.7/core-v2-spatial".into()
    }
}

struct YardmanRustExtension;

#[gdextension]
unsafe impl ExtensionLibrary for YardmanRustExtension {}
