#[path = "../src/routing.rs"]
mod routing;

use bitcode::{Decode, Encode};
use petgraph::{algo::dijkstra, graph::DiGraph};
use routing::{RoadRouteGraph, RouteEdge, RouteMetric};
use rstar::RTree;
use serde::{Deserialize, Serialize};
use std::hint::black_box;
use std::time::Instant;

const ENTITY_COUNT: usize = 8_192;
const SERIALIZE_LOOPS: usize = 48;
const POINT_COUNT: usize = 131_072;
const QUERY_COUNT: usize = 192;
const QUERY_RADIUS: f32 = 900.0;
const ROUTE_NODES: usize = 8_192;
const ROUTE_QUERIES: usize = 64;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, Encode, Decode)]
struct SnapshotEntity {
    id: u32,
    x_cm: i32,
    z_cm: i32,
    vx_cms: i16,
    vz_cms: i16,
    yaw_u16: u16,
    state_flags: u16,
}

fn elapsed_us<F, R>(loops: usize, mut work: F) -> u128
where
    F: FnMut() -> R,
{
    let start = Instant::now();
    for _ in 0..loops {
        black_box(work());
    }
    start.elapsed().as_micros()
}

fn main() {
    let entities: Vec<SnapshotEntity> = (0..ENTITY_COUNT)
        .map(|i| SnapshotEntity {
            id: i as u32,
            x_cm: ((i * 7_919) % 23_500_000) as i32,
            z_cm: ((i * 4_099) % 8_200_000) as i32,
            vx_cms: ((i * 37) % 4_001) as i16 - 2_000,
            vz_cms: ((i * 53) % 4_001) as i16 - 2_000,
            yaw_u16: ((i * 977) & 0xffff) as u16,
            state_flags: ((i * 13) & 0x03ff) as u16,
        })
        .collect();

    let postcard_bytes = postcard::to_stdvec(&entities).expect("postcard encode");
    let postcard_roundtrip: Vec<SnapshotEntity> =
        postcard::from_bytes(&postcard_bytes).expect("postcard decode");
    assert_eq!(postcard_roundtrip, entities, "postcard roundtrip changed state");

    let bitcode_bytes = bitcode::encode(&entities);
    let bitcode_roundtrip: Vec<SnapshotEntity> =
        bitcode::decode(&bitcode_bytes).expect("bitcode decode");
    assert_eq!(bitcode_roundtrip, entities, "bitcode roundtrip changed state");

    let lz4_bytes = lz4_flex::compress_prepend_size(&postcard_bytes);
    let lz4_roundtrip =
        lz4_flex::decompress_size_prepended(&lz4_bytes).expect("lz4 decode");
    assert_eq!(lz4_roundtrip, postcard_bytes, "lz4 roundtrip changed payload");

    let postcard_encode_us = elapsed_us(SERIALIZE_LOOPS, || {
        postcard::to_stdvec(black_box(&entities)).expect("postcard encode")
    });
    let postcard_decode_us = elapsed_us(SERIALIZE_LOOPS, || {
        postcard::from_bytes::<Vec<SnapshotEntity>>(black_box(&postcard_bytes))
            .expect("postcard decode")
    });
    let bitcode_encode_us = elapsed_us(SERIALIZE_LOOPS, || {
        bitcode::encode(black_box(&entities))
    });
    let bitcode_decode_us = elapsed_us(SERIALIZE_LOOPS, || {
        bitcode::decode::<Vec<SnapshotEntity>>(black_box(&bitcode_bytes))
            .expect("bitcode decode")
    });
    let lz4_compress_us = elapsed_us(SERIALIZE_LOOPS, || {
        lz4_flex::compress_prepend_size(black_box(&postcard_bytes))
    });
    let lz4_decompress_us = elapsed_us(SERIALIZE_LOOPS, || {
        lz4_flex::decompress_size_prepended(black_box(&lz4_bytes)).expect("lz4 decode")
    });

    let points: Vec<[f32; 2]> = (0..POINT_COUNT)
        .map(|i| {
            let x = ((i * 4_093) % 235_000) as f32;
            let z = ((i * 7_919) % 82_000) as f32;
            [x, z]
        })
        .collect();

    let tree_build_start = Instant::now();
    let tree = RTree::bulk_load(points.clone());
    let tree_build_us = tree_build_start.elapsed().as_micros();

    let queries: Vec<[f32; 2]> = (0..QUERY_COUNT)
        .map(|i| {
            [
                ((i * 11_113) % 235_000) as f32,
                ((i * 5_087) % 82_000) as f32,
            ]
        })
        .collect();
    let radius_sq = QUERY_RADIUS * QUERY_RADIUS;

    let linear_start = Instant::now();
    let linear_hits: usize = queries
        .iter()
        .map(|query| {
            points
                .iter()
                .filter(|point| {
                    let dx = point[0] - query[0];
                    let dz = point[1] - query[1];
                    dx * dx + dz * dz <= radius_sq
                })
                .count()
        })
        .sum();
    let linear_query_us = linear_start.elapsed().as_micros();

    let rtree_start = Instant::now();
    let rtree_hits: usize = queries
        .iter()
        .map(|query| tree.locate_within_distance(*query, radius_sq).count())
        .sum();
    let rtree_query_us = rtree_start.elapsed().as_micros();
    assert_eq!(rtree_hits, linear_hits, "R-tree relevance query changed results");

    // Routing candidate: use the same deterministic directed edge semantics as
    // the Jamaica graph, then compare the compact Yardman kernel with petgraph.
    let mut route_edges = Vec::with_capacity(ROUTE_NODES * 2);
    for node in 0..ROUTE_NODES - 1 {
        route_edges.push(RouteEdge {
            id: node as i32,
            from: node as i32,
            to: node as i32 + 1,
            length_m: 10.0,
            speed_limit_mps: Some(13.888_889),
            direction: 1,
        });
    }
    let shortcut_base = route_edges.len() as i32;
    for node in 0..ROUTE_NODES - 16 {
        route_edges.push(RouteEdge {
            id: shortcut_base + node as i32,
            from: node as i32,
            to: node as i32 + 16,
            length_m: 118.0,
            speed_limit_mps: Some(22.222_222),
            direction: 1,
        });
    }

    let custom_build_start = Instant::now();
    let custom_graph = RoadRouteGraph::from_edges(ROUTE_NODES, route_edges.clone(), 13.888_889)
        .expect("Yardman route graph build");
    let custom_build_us = custom_build_start.elapsed().as_micros();

    let petgraph_build_start = Instant::now();
    let mut petgraph_graph = DiGraph::<(), f32>::with_capacity(ROUTE_NODES, route_edges.len());
    let pet_nodes: Vec<_> = (0..ROUTE_NODES).map(|_| petgraph_graph.add_node(())).collect();
    for edge in &route_edges {
        petgraph_graph.add_edge(
            pet_nodes[edge.from as usize],
            pet_nodes[edge.to as usize],
            edge.length_m,
        );
    }
    let petgraph_build_us = petgraph_build_start.elapsed().as_micros();

    let route_queries: Vec<(usize, usize)> = (0..ROUTE_QUERIES)
        .map(|query| {
            let start = (query * 97) % (ROUTE_NODES / 2);
            let span = 2_048 + (query * 53) % 1_024;
            (start, (start + span).min(ROUTE_NODES - 1))
        })
        .collect();

    for &(start, goal) in &route_queries {
        let custom = custom_graph
            .shortest_path(start as i32, goal as i32, RouteMetric::Distance)
            .expect("Yardman route missing");
        let pet = dijkstra(
            &petgraph_graph,
            pet_nodes[start],
            Some(pet_nodes[goal]),
            |edge| *edge.weight(),
        );
        let pet_cost = pet.get(&pet_nodes[goal]).copied().expect("petgraph route missing");
        assert!(
            (custom.distance_m - pet_cost).abs() < 0.01,
            "route candidates disagree: {} vs {}",
            custom.distance_m,
            pet_cost
        );
    }

    let custom_route_start = Instant::now();
    let custom_checksum: f64 = route_queries
        .iter()
        .map(|&(start, goal)| {
            f64::from(
                custom_graph
                    .shortest_path(start as i32, goal as i32, RouteMetric::Distance)
                    .expect("Yardman route missing")
                    .distance_m,
            )
        })
        .sum();
    let custom_route_us = custom_route_start.elapsed().as_micros();

    let petgraph_route_start = Instant::now();
    let petgraph_checksum: f64 = route_queries
        .iter()
        .map(|&(start, goal)| {
            f64::from(
                *dijkstra(
                    &petgraph_graph,
                    pet_nodes[start],
                    Some(pet_nodes[goal]),
                    |edge| *edge.weight(),
                )
                .get(&pet_nodes[goal])
                .expect("petgraph route missing"),
            )
        })
        .sum();
    let petgraph_route_us = petgraph_route_start.elapsed().as_micros();
    assert!((custom_checksum - petgraph_checksum).abs() < 0.1);

    println!(
        "YARDMAN_ECOSYSTEM_BAKEOFF snapshot_entities={} loops={} postcard_bytes={} bitcode_bytes={} lz4_postcard_bytes={}",
        ENTITY_COUNT,
        SERIALIZE_LOOPS,
        postcard_bytes.len(),
        bitcode_bytes.len(),
        lz4_bytes.len()
    );
    println!(
        "YARDMAN_ECOSYSTEM_BAKEOFF_TIMING postcard_encode_us={} postcard_decode_us={} bitcode_encode_us={} bitcode_decode_us={} lz4_compress_us={} lz4_decompress_us={}",
        postcard_encode_us,
        postcard_decode_us,
        bitcode_encode_us,
        bitcode_decode_us,
        lz4_compress_us,
        lz4_decompress_us
    );
    println!(
        "YARDMAN_ECOSYSTEM_SPATIAL points={} queries={} radius_m={} rtree_build_us={} linear_query_us={} rtree_query_us={} hits={}",
        POINT_COUNT,
        QUERY_COUNT,
        QUERY_RADIUS,
        tree_build_us,
        linear_query_us,
        rtree_query_us,
        rtree_hits
    );
    println!(
        "YARDMAN_ECOSYSTEM_ROUTING nodes={} edges={} queries={} custom_build_us={} petgraph_build_us={} custom_query_us={} petgraph_query_us={} checksum={:.1}",
        ROUTE_NODES,
        route_edges.len(),
        ROUTE_QUERIES,
        custom_build_us,
        petgraph_build_us,
        custom_route_us,
        petgraph_route_us,
        custom_checksum
    );
    println!("YARDMAN_ECOSYSTEM_BAKEOFF PASS");
}
