use crate::routing::{RoadRouteGraph, RouteEdge};

pub const ROUTE_PACK_MAGIC: [u8; 4] = *b"YMRG";
pub const ROUTE_PACK_VERSION: u16 = 1;
pub const ROUTE_PACK_HEADER_SIZE: usize = 32;
pub const ROUTE_PACK_NODE_SIZE: usize = 20;
pub const ROUTE_PACK_EDGE_SIZE: usize = 28;

#[derive(Clone, Debug, PartialEq)]
pub struct RoutePackNode {
    pub id: String,
    pub position: [f32; 3],
}

#[derive(Clone, Debug, PartialEq)]
pub struct RoutePackEdge {
    pub id: String,
    pub from: u32,
    pub to: u32,
    pub length_m: f32,
    pub class_id: u8,
    pub direction: i8,
    pub speed_limit_mps: Option<f32>,
    pub flags: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RoutePack {
    pub nodes: Vec<RoutePackNode>,
    pub edges: Vec<RoutePackEdge>,
}

impl RoutePack {
    pub fn parse(bytes: &[u8]) -> Result<Self, &'static str> {
        if bytes.len() < ROUTE_PACK_HEADER_SIZE {
            return Err("route pack header is truncated");
        }
        if bytes[0..4] != ROUTE_PACK_MAGIC {
            return Err("route pack magic mismatch");
        }
        if read_u16(bytes, 4)? != ROUTE_PACK_VERSION {
            return Err("unsupported route pack version");
        }
        if usize::from(read_u16(bytes, 6)?) != ROUTE_PACK_HEADER_SIZE
            || usize::from(read_u16(bytes, 8)?) != ROUTE_PACK_NODE_SIZE
            || usize::from(read_u16(bytes, 10)?) != ROUTE_PACK_EDGE_SIZE
        {
            return Err("route pack record size mismatch");
        }

        let node_count = usize::try_from(read_u32(bytes, 12)?).map_err(|_| "route node count overflow")?;
        let edge_count = usize::try_from(read_u32(bytes, 16)?).map_err(|_| "route edge count overflow")?;
        let string_bytes = usize::try_from(read_u32(bytes, 20)?).map_err(|_| "route string table overflow")?;
        if read_u64(bytes, 24)? != 0 {
            return Err("route pack reserved header bits must be zero");
        }
        if node_count == 0 {
            return Err("route pack requires at least one node");
        }
        if edge_count > i32::MAX as usize {
            return Err("route pack edge count exceeds routing ID range");
        }

        let nodes_bytes = node_count
            .checked_mul(ROUTE_PACK_NODE_SIZE)
            .ok_or("route node table overflow")?;
        let edges_bytes = edge_count
            .checked_mul(ROUTE_PACK_EDGE_SIZE)
            .ok_or("route edge table overflow")?;
        let edges_start = ROUTE_PACK_HEADER_SIZE
            .checked_add(nodes_bytes)
            .ok_or("route node table overflow")?;
        let strings_start = edges_start
            .checked_add(edges_bytes)
            .ok_or("route edge table overflow")?;
        let expected_len = strings_start
            .checked_add(string_bytes)
            .ok_or("route pack length overflow")?;
        if bytes.len() != expected_len {
            return Err("route pack length mismatch");
        }
        let strings = &bytes[strings_start..expected_len];

        let mut nodes = Vec::with_capacity(node_count);
        let mut previous_node_id: Option<String> = None;
        for index in 0..node_count {
            let base = ROUTE_PACK_HEADER_SIZE + index * ROUTE_PACK_NODE_SIZE;
            let id = read_id(strings, read_u32(bytes, base)?, read_u16(bytes, base + 4)?)?;
            if read_u16(bytes, base + 6)? != 0 {
                return Err("route node reserved bits must be zero");
            }
            if previous_node_id.as_deref().is_some_and(|previous| previous >= id.as_str()) {
                return Err("route node IDs must be strictly sorted");
            }
            let position = [
                read_f32(bytes, base + 8)?,
                read_f32(bytes, base + 12)?,
                read_f32(bytes, base + 16)?,
            ];
            if position.iter().any(|value| !value.is_finite()) {
                return Err("route node position must be finite");
            }
            previous_node_id = Some(id.clone());
            nodes.push(RoutePackNode { id, position });
        }

        let mut edges = Vec::with_capacity(edge_count);
        let mut previous_edge_id: Option<String> = None;
        for index in 0..edge_count {
            let base = edges_start + index * ROUTE_PACK_EDGE_SIZE;
            let id = read_id(strings, read_u32(bytes, base)?, read_u16(bytes, base + 4)?)?;
            if previous_edge_id.as_deref().is_some_and(|previous| previous >= id.as_str()) {
                return Err("route edge IDs must be strictly sorted");
            }
            let class_id = bytes[base + 6];
            let direction = bytes[base + 7] as i8;
            if !matches!(direction, -1..=1) {
                return Err("route edge direction must be -1, 0, or 1");
            }
            let from = read_u32(bytes, base + 8)?;
            let to = read_u32(bytes, base + 12)?;
            if from as usize >= node_count || to as usize >= node_count || from == to {
                return Err("route edge references an invalid node");
            }
            let length_m = read_f32(bytes, base + 16)?;
            if !length_m.is_finite() || length_m <= 0.0 {
                return Err("route edge length must be finite and positive");
            }
            let raw_speed = read_f32(bytes, base + 20)?;
            if !raw_speed.is_finite() || raw_speed < 0.0 {
                return Err("route edge speed must be finite and non-negative");
            }
            let speed_limit_mps = (raw_speed > 0.0).then_some(raw_speed);
            let flags = read_u32(bytes, base + 24)?;
            previous_edge_id = Some(id.clone());
            edges.push(RoutePackEdge {
                id,
                from,
                to,
                length_m,
                class_id,
                direction,
                speed_limit_mps,
                flags,
            });
        }

        Ok(Self { nodes, edges })
    }

    pub fn build_route_graph(&self, fallback_speed_mps: f32) -> Result<RoadRouteGraph, &'static str> {
        RoadRouteGraph::from_edges(
            self.nodes.len(),
            self.edges.iter().enumerate().map(|(index, edge)| RouteEdge {
                id: index as i32,
                from: edge.from as i32,
                to: edge.to as i32,
                length_m: edge.length_m,
                speed_limit_mps: edge.speed_limit_mps,
                direction: edge.direction,
            }),
            fallback_speed_mps,
        )
    }

    pub fn stable_edge_id(&self, route_edge_id: i32) -> Option<&str> {
        usize::try_from(route_edge_id)
            .ok()
            .and_then(|index| self.edges.get(index))
            .map(|edge| edge.id.as_str())
    }
}

fn read_id(strings: &[u8], offset: u32, length: u16) -> Result<String, &'static str> {
    if length == 0 {
        return Err("route stable ID cannot be empty");
    }
    let start = usize::try_from(offset).map_err(|_| "route string offset overflow")?;
    let end = start
        .checked_add(usize::from(length))
        .ok_or("route string range overflow")?;
    let slice = strings.get(start..end).ok_or("route string range is out of bounds")?;
    let value = std::str::from_utf8(slice).map_err(|_| "route stable ID must be UTF-8")?;
    Ok(value.to_owned())
}

fn read_u16(bytes: &[u8], offset: usize) -> Result<u16, &'static str> {
    let slice = bytes.get(offset..offset + 2).ok_or("route pack read out of bounds")?;
    Ok(u16::from_le_bytes([slice[0], slice[1]]))
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, &'static str> {
    let slice = bytes.get(offset..offset + 4).ok_or("route pack read out of bounds")?;
    Ok(u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn read_u64(bytes: &[u8], offset: usize) -> Result<u64, &'static str> {
    let slice = bytes.get(offset..offset + 8).ok_or("route pack read out of bounds")?;
    Ok(u64::from_le_bytes([
        slice[0], slice[1], slice[2], slice[3], slice[4], slice[5], slice[6], slice[7],
    ]))
}

fn read_f32(bytes: &[u8], offset: usize) -> Result<f32, &'static str> {
    Ok(f32::from_bits(read_u32(bytes, offset)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::routing::RouteMetric;

    fn golden_bytes() -> Vec<u8> {
        let text = include_str!("../../../Tests/Fixtures/route_pack_v1.hex");
        let clean: Vec<u8> = text.bytes().filter(|byte| !byte.is_ascii_whitespace()).collect();
        assert_eq!(clean.len() % 2, 0);
        clean.chunks_exact(2)
            .map(|pair| {
                let high = (pair[0] as char).to_digit(16).unwrap() as u8;
                let low = (pair[1] as char).to_digit(16).unwrap() as u8;
                (high << 4) | low
            })
            .collect()
    }

    #[test]
    fn parses_cross_language_golden_pack_and_routes() {
        let pack = RoutePack::parse(&golden_bytes()).unwrap();
        assert_eq!(pack.nodes.len(), 2);
        assert_eq!(pack.edges.len(), 1);
        assert_eq!(pack.nodes[0].id, "osm:1");
        assert_eq!(pack.nodes[1].position, [10.0, 1.0, 0.0]);
        assert_eq!(pack.edges[0].id, "w1:0:osm:1:osm:2");
        assert_eq!(pack.edges[0].class_id, 2);
        assert_eq!(pack.edges[0].direction, 1);
        assert_eq!(pack.edges[0].flags, 3);
        assert_eq!(pack.edges[0].speed_limit_mps, Some(13.5));

        let graph = pack.build_route_graph(13.888_889).unwrap();
        let route = graph.shortest_path(0, 1, RouteMetric::Distance).unwrap();
        assert_eq!(route.edges, vec![0]);
        assert_eq!(pack.stable_edge_id(route.edges[0]), Some("w1:0:osm:1:osm:2"));
        assert!(graph.shortest_path(1, 0, RouteMetric::Distance).is_none());
    }

    #[test]
    fn malformed_pack_fails_closed() {
        let golden = golden_bytes();
        assert!(RoutePack::parse(&golden[..20]).is_err());
        let mut bad_magic = golden.clone();
        bad_magic[0] = b'X';
        assert!(RoutePack::parse(&bad_magic).is_err());
        let mut trailing = golden.clone();
        trailing.push(0);
        assert!(RoutePack::parse(&trailing).is_err());
        let mut invalid_direction = golden.clone();
        let edge_base = ROUTE_PACK_HEADER_SIZE + 2 * ROUTE_PACK_NODE_SIZE;
        invalid_direction[edge_base + 7] = 2;
        assert!(RoutePack::parse(&invalid_direction).is_err());
    }
}
