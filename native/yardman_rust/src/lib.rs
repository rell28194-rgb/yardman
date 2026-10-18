use godot::prelude::*;
use yardman_core::{
    Point2, SpatialIndex2D, count_points_in_radius, filter_indices_in_radius,
    route_pack::RoutePack,
    routing::{RoadRouteGraph, RouteMetric},
};

#[derive(GodotClass)]
#[class(init)]
struct YardmanRustKernels {
    spatial_index: SpatialIndex2D,
    route_pack: Option<RoutePack>,
    route_graph: Option<RoadRouteGraph>,
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

    /// Parse and validate one complete deterministic route pack. A failed
    /// reconfiguration clears any previous graph so callers can never continue
    /// routing on stale topology after a corrupt or mismatched world update.
    #[func]
    fn configure_route_pack(
        &mut self,
        bytes: PackedByteArray,
        fallback_speed_mps: f64,
    ) -> bool {
        self.route_pack = None;
        self.route_graph = None;
        if !fallback_speed_mps.is_finite() || fallback_speed_mps <= 0.0 {
            return false;
        }
        let fallback_speed = fallback_speed_mps as f32;
        if !fallback_speed.is_finite() || fallback_speed <= 0.0 {
            return false;
        }
        let Ok(pack) = RoutePack::parse(bytes.as_slice()) else {
            return false;
        };
        let Ok(graph) = pack.build_route_graph(fallback_speed) else {
            return false;
        };
        self.route_pack = Some(pack);
        self.route_graph = Some(graph);
        true
    }

    #[func]
    fn clear_route_pack(&mut self) {
        self.route_graph = None;
        self.route_pack = None;
    }

    #[func]
    fn route_pack_node_count(&self) -> i64 {
        self.route_pack
            .as_ref()
            .map_or(0, |pack| pack.nodes.len() as i64)
    }

    #[func]
    fn route_pack_edge_count(&self) -> i64 {
        self.route_pack
            .as_ref()
            .map_or(0, |pack| pack.edges.len() as i64)
    }

    /// Return stable packaged road-edge IDs, never internal adjacency IDs.
    /// `fastest=false` minimizes metres; `fastest=true` minimizes travel time.
    #[func]
    fn route_edge_ids(
        &self,
        start_node: GString,
        goal_node: GString,
        fastest: bool,
    ) -> PackedStringArray {
        let mut output = PackedStringArray::new();
        let (Some(pack), Some(graph)) = (&self.route_pack, &self.route_graph) else {
            return output;
        };
        let start_text = start_node.to_string();
        let goal_text = goal_node.to_string();
        let (Some(start), Some(goal)) = (
            pack.node_index(&start_text),
            pack.node_index(&goal_text),
        ) else {
            return output;
        };
        let metric = if fastest {
            RouteMetric::TravelTime
        } else {
            RouteMetric::Distance
        };
        let Some(route) = graph.shortest_path(start, goal, metric) else {
            return output;
        };
        for edge_index in route.edges {
            let Some(stable_id) = pack.stable_edge_id(edge_index) else {
                return PackedStringArray::new();
            };
            output.push(stable_id);
        }
        output
    }

    #[func]
    fn build_id(&self) -> GString {
        "yardman-rust/api-4.7/core-v3-route-pack".into()
    }
}

struct YardmanRustExtension;

#[gdextension]
unsafe impl ExtensionLibrary for YardmanRustExtension {}
