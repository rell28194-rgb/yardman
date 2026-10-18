#[path = "../src/routing.rs"]
mod routing;

use routing::{RoadRouteGraph, RouteEdge, RouteMetric};

fn edge(id: i32, from: i32, to: i32, length_m: f32, speed: f32, direction: i8) -> RouteEdge {
    RouteEdge {
        id,
        from,
        to,
        length_m,
        speed_limit_mps: Some(speed),
        direction,
    }
}

#[test]
fn yardman_road_direction_and_metric_contract() {
    let graph = RoadRouteGraph::from_edges(
        4,
        [
            edge(10, 0, 1, 50.0, 10.0, 1),
            edge(20, 1, 3, 50.0, 10.0, 1),
            edge(30, 0, 2, 70.0, 35.0, 1),
            edge(40, 2, 3, 70.0, 35.0, 1),
        ],
        13.888_889,
    )
    .unwrap();

    let distance = graph.shortest_path(0, 3, RouteMetric::Distance).unwrap();
    let time = graph.shortest_path(0, 3, RouteMetric::TravelTime).unwrap();
    assert_eq!(distance.edges, vec![10, 20]);
    assert_eq!(time.edges, vec![30, 40]);
    assert!(graph.shortest_path(3, 0, RouteMetric::Distance).is_none());
    assert_eq!(graph.node_count(), 4);
    assert_eq!(graph.edge_count(), 4);
}
