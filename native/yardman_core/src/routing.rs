use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RouteEdge {
    pub id: i32,
    pub from: i32,
    pub to: i32,
    pub length_m: f32,
    pub speed_limit_mps: Option<f32>,
    /// Matches the packaged Yardman road graph: 0 = both directions,
    /// 1 = from -> to only, -1 = to -> from only.
    pub direction: i8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RouteMetric {
    Distance,
    TravelTime,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RoutePath {
    pub nodes: Vec<i32>,
    pub edges: Vec<i32>,
    pub distance_m: f32,
    pub travel_time_s: f32,
}

#[derive(Clone, Copy, Debug)]
struct RouteArc {
    edge_id: i32,
    to: usize,
    length_m: f32,
    travel_time_s: f32,
}

/// Compact deterministic directed graph intended for the authoritative Jamaica
/// road topology. Geometry remains in the existing streamed road packs; this
/// graph owns route decisions only.
pub struct RoadRouteGraph {
    adjacency: Vec<Vec<RouteArc>>,
    source_edge_count: usize,
}

impl RoadRouteGraph {
    pub fn from_edges<I>(
        node_count: usize,
        edges: I,
        fallback_speed_mps: f32,
    ) -> Result<Self, &'static str>
    where
        I: IntoIterator<Item = RouteEdge>,
    {
        if node_count == 0 {
            return Err("route graph requires at least one node");
        }
        if !fallback_speed_mps.is_finite() || fallback_speed_mps <= 0.0 {
            return Err("fallback route speed must be finite and positive");
        }

        let mut adjacency = vec![Vec::new(); node_count];
        let mut edge_ids = HashSet::new();
        let mut source_edge_count = 0usize;

        for edge in edges {
            if edge.id < 0 || !edge_ids.insert(edge.id) {
                return Err("route edge IDs must be unique non-negative integers");
            }
            if edge.from < 0
                || edge.to < 0
                || edge.from as usize >= node_count
                || edge.to as usize >= node_count
                || edge.from == edge.to
            {
                return Err("route edge references an invalid node");
            }
            if !edge.length_m.is_finite() || edge.length_m <= 0.0 {
                return Err("route edge length must be finite and positive");
            }
            if !matches!(edge.direction, -1..=1) {
                return Err("route edge direction must be -1, 0, or 1");
            }
            let speed = match edge.speed_limit_mps {
                Some(value) if value.is_finite() && value > 0.0 => value,
                Some(_) => return Err("route edge speed must be finite and positive"),
                None => fallback_speed_mps,
            };
            let travel_time_s = edge.length_m / speed;
            let forward = RouteArc {
                edge_id: edge.id,
                to: edge.to as usize,
                length_m: edge.length_m,
                travel_time_s,
            };
            let reverse = RouteArc {
                edge_id: edge.id,
                to: edge.from as usize,
                length_m: edge.length_m,
                travel_time_s,
            };
            if edge.direction >= 0 {
                adjacency[edge.from as usize].push(forward);
            }
            if edge.direction <= 0 {
                adjacency[edge.to as usize].push(reverse);
            }
            source_edge_count += 1;
        }

        // Never inherit HashMap/source-file ordering. Stable adjacency order is
        // required for reproducible AI, jobs, replays, server tests and routes.
        for arcs in &mut adjacency {
            arcs.sort_by(|a, b| a.to.cmp(&b.to).then_with(|| a.edge_id.cmp(&b.edge_id)));
        }

        Ok(Self {
            adjacency,
            source_edge_count,
        })
    }

    pub fn node_count(&self) -> usize {
        self.adjacency.len()
    }

    pub fn edge_count(&self) -> usize {
        self.source_edge_count
    }

    pub fn shortest_path(
        &self,
        start: i32,
        goal: i32,
        metric: RouteMetric,
    ) -> Option<RoutePath> {
        if start < 0
            || goal < 0
            || start as usize >= self.adjacency.len()
            || goal as usize >= self.adjacency.len()
        {
            return None;
        }
        if start == goal {
            return Some(RoutePath {
                nodes: vec![start],
                edges: Vec::new(),
                distance_m: 0.0,
                travel_time_s: 0.0,
            });
        }

        let start = start as usize;
        let goal = goal as usize;
        let mut best = vec![f64::INFINITY; self.adjacency.len()];
        let mut parent: Vec<Option<(usize, RouteArc)>> = vec![None; self.adjacency.len()];
        let mut queue = BinaryHeap::new();
        best[start] = 0.0;
        queue.push(RouteState { cost: 0.0, node: start });

        while let Some(state) = queue.pop() {
            if state.cost > best[state.node] {
                continue;
            }
            if state.node == goal {
                break;
            }
            for arc in &self.adjacency[state.node] {
                let weight = match metric {
                    RouteMetric::Distance => f64::from(arc.length_m),
                    RouteMetric::TravelTime => f64::from(arc.travel_time_s),
                };
                let candidate = state.cost + weight;
                if candidate < best[arc.to] {
                    best[arc.to] = candidate;
                    parent[arc.to] = Some((state.node, *arc));
                    queue.push(RouteState {
                        cost: candidate,
                        node: arc.to,
                    });
                }
            }
        }

        if !best[goal].is_finite() {
            return None;
        }

        let mut nodes = vec![goal as i32];
        let mut edges = Vec::new();
        let mut distance_m = 0.0f32;
        let mut travel_time_s = 0.0f32;
        let mut cursor = goal;
        while cursor != start {
            let (previous, arc) = parent[cursor]?;
            edges.push(arc.edge_id);
            distance_m += arc.length_m;
            travel_time_s += arc.travel_time_s;
            cursor = previous;
            nodes.push(cursor as i32);
        }
        nodes.reverse();
        edges.reverse();

        Some(RoutePath {
            nodes,
            edges,
            distance_m,
            travel_time_s,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct RouteState {
    cost: f64,
    node: usize,
}

impl Eq for RouteState {}

impl Ord for RouteState {
    fn cmp(&self, other: &Self) -> Ordering {
        // BinaryHeap is max-first, so reverse cost and then node ordering. The
        // node tie-break guarantees identical paths for equal-cost alternatives.
        other
            .cost
            .total_cmp(&self.cost)
            .then_with(|| other.node.cmp(&self.node))
    }
}

impl PartialOrd for RouteState {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn one_way_semantics_match_packaged_road_graph() {
        let graph = RoadRouteGraph::from_edges(
            3,
            [edge(10, 0, 1, 10.0, 10.0, 1), edge(20, 1, 2, 20.0, 10.0, 0)],
            13.888_889,
        )
        .unwrap();
        assert_eq!(
            graph.shortest_path(0, 2, RouteMetric::Distance).unwrap().edges,
            vec![10, 20]
        );
        assert!(graph.shortest_path(2, 0, RouteMetric::Distance).is_none());
    }

    #[test]
    fn reverse_one_way_is_respected() {
        let graph = RoadRouteGraph::from_edges(
            2,
            [edge(7, 0, 1, 5.0, 5.0, -1)],
            13.888_889,
        )
        .unwrap();
        assert!(graph.shortest_path(0, 1, RouteMetric::Distance).is_none());
        assert_eq!(
            graph.shortest_path(1, 0, RouteMetric::Distance).unwrap().edges,
            vec![7]
        );
    }

    #[test]
    fn distance_and_travel_time_can_choose_different_routes() {
        let graph = RoadRouteGraph::from_edges(
            3,
            [
                edge(1, 0, 1, 10.0, 5.0, 1),
                edge(2, 1, 2, 10.0, 5.0, 1),
                edge(3, 0, 2, 30.0, 30.0, 1),
            ],
            13.888_889,
        )
        .unwrap();
        assert_eq!(
            graph.shortest_path(0, 2, RouteMetric::Distance).unwrap().edges,
            vec![1, 2]
        );
        assert_eq!(
            graph.shortest_path(0, 2, RouteMetric::TravelTime).unwrap().edges,
            vec![3]
        );
    }

    #[test]
    fn equal_cost_paths_are_deterministic() {
        let graph = RoadRouteGraph::from_edges(
            4,
            [
                edge(20, 0, 2, 10.0, 10.0, 1),
                edge(40, 2, 3, 10.0, 10.0, 1),
                edge(10, 0, 1, 10.0, 10.0, 1),
                edge(30, 1, 3, 10.0, 10.0, 1),
            ],
            13.888_889,
        )
        .unwrap();
        let route = graph.shortest_path(0, 3, RouteMetric::Distance).unwrap();
        assert_eq!(route.nodes, vec![0, 1, 3]);
        assert_eq!(route.edges, vec![10, 30]);
    }

    #[test]
    fn invalid_edges_fail_closed() {
        assert!(RoadRouteGraph::from_edges(0, [], 10.0).is_err());
        assert!(RoadRouteGraph::from_edges(2, [edge(1, 0, 2, 5.0, 5.0, 0)], 10.0).is_err());
        assert!(RoadRouteGraph::from_edges(2, [edge(1, 0, 1, -5.0, 5.0, 0)], 10.0).is_err());
        assert!(RoadRouteGraph::from_edges(2, [edge(1, 0, 1, 5.0, 5.0, 2)], 10.0).is_err());
    }
}
