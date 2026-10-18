extends RefCounted
class_name YardmanRoadGraph

# This database belongs to the world, not to tile Nodes. LRU eviction changes
# residency only; stable identities and adjacency remain in packaged shards.
const DEFAULT_ROUTE_SPEED_MPS := 13.888889
const COST_EPSILON := 0.000001

var data_root := "res://data/roads/graph"
var max_cached_partitions := 12
var node_count := 0
var edge_count := 0
var _cache: Dictionary = {}
var _lru: Array[String] = []
var _native_router = null
var _native_route_pack_ready := false
var _route_backend := "json-fallback"

func configure(root_path: String, metadata: Dictionary) -> void:
    data_root = root_path
    node_count = int(metadata.get("nodes", 0))
    edge_count = int(metadata.get("edges", 0))
    _native_router = null
    _native_route_pack_ready = false
    _route_backend = "json-fallback"
    _configure_native_route_pack(metadata)

func get_node_data(identifier: String) -> Dictionary:
    return _get_record("nodes", identifier)

func get_edge(identifier: String) -> Dictionary:
    return _get_record("edges", identifier)

func outgoing(identifier: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var node := get_node_data(identifier)
    for edge_id in node.get("edges", []):
        var edge := get_edge(str(edge_id))
        if edge.is_empty():
            continue
        var direction := int(edge.get("direction", 0))
        if (str(edge.get("from")) == identifier and direction >= 0) or (str(edge.get("to")) == identifier and direction <= 0):
            result.append(edge)
    result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return str(a.get("id", "")) < str(b.get("id", "")))
    return result

func route_backend() -> String:
    return _route_backend

func has_native_routing() -> bool:
    return _native_route_pack_ready and _native_router != null

# Stable road-edge IDs are returned regardless of backend. Native Rust is the
# preferred production path; the sharded JSON graph remains a source-readable,
# dependency-free fallback and parity oracle.
func route_edge_ids(start_node: String, goal_node: String, fastest := false) -> PackedStringArray:
    if start_node.is_empty() or goal_node.is_empty():
        return PackedStringArray()
    if has_native_routing():
        var native_result = _native_router.call("route_edge_ids", start_node, goal_node, fastest)
        if native_result is PackedStringArray:
            return native_result
    return _route_edge_ids_fallback(start_node, goal_node, fastest)

func clear_cache() -> void:
    _cache.clear()
    _lru.clear()

func _configure_native_route_pack(metadata: Dictionary) -> void:
    if not ClassDB.class_exists(&"YardmanRustKernels"):
        return
    var route_meta = metadata.get("route_pack", {})
    if not route_meta is Dictionary:
        return
    var filename := str(route_meta.get("file", ""))
    if filename.is_empty():
        return
    var path := "%s/%s" % [data_root, filename]
    if not FileAccess.file_exists(path):
        return
    var expected_sha := str(route_meta.get("sha256", ""))
    if not expected_sha.is_empty() and FileAccess.get_sha256(path) != expected_sha:
        push_error("National route pack SHA-256 mismatch: " + path)
        return
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.is_empty():
        return
    var kernel = ClassDB.instantiate(&"YardmanRustKernels")
    if kernel == null or not bool(kernel.call("configure_route_pack", bytes, DEFAULT_ROUTE_SPEED_MPS)):
        return
    if int(kernel.call("route_pack_node_count")) != node_count or int(kernel.call("route_pack_edge_count")) != edge_count:
        kernel.call("clear_route_pack")
        push_error("National route pack count mismatch: " + path)
        return
    _native_router = kernel
    _native_route_pack_ready = true
    _route_backend = "rust-route-pack"

func _route_edge_ids_fallback(start_node: String, goal_node: String, fastest: bool) -> PackedStringArray:
    var start_record := get_node_data(start_node)
    var goal_record := get_node_data(goal_node)
    if start_record.is_empty() or goal_record.is_empty():
        return PackedStringArray()
    if start_node == goal_node:
        return PackedStringArray()

    var best: Dictionary = {start_node: 0.0}
    var parent_node: Dictionary = {}
    var parent_edge: Dictionary = {}
    var frontier: Array[String] = [start_node]
    var settled: Dictionary = {}

    while not frontier.is_empty():
        var best_index := 0
        for index in range(1, frontier.size()):
            var candidate_id := frontier[index]
            var current_id := frontier[best_index]
            var candidate_cost := float(best.get(candidate_id, INF))
            var current_cost := float(best.get(current_id, INF))
            if candidate_cost < current_cost - COST_EPSILON or (is_equal_approx(candidate_cost, current_cost) and candidate_id < current_id):
                best_index = index
        var current: String = frontier.pop_at(best_index)
        if settled.has(current):
            continue
        settled[current] = true
        if current == goal_node:
            break

        for edge: Dictionary in outgoing(current):
            var next := _edge_destination(edge, current)
            if next.is_empty() or settled.has(next):
                continue
            var length_m := float(edge.get("length_m", 0.0))
            if not is_finite(length_m) or length_m <= 0.0:
                continue
            var weight := length_m
            if fastest:
                var raw_speed = edge.get("speed_limit_mps", null)
                var speed := DEFAULT_ROUTE_SPEED_MPS if raw_speed == null else float(raw_speed)
                if not is_finite(speed) or speed <= 0.0:
                    speed = DEFAULT_ROUTE_SPEED_MPS
                weight = length_m / speed
            var candidate := float(best.get(current, INF)) + weight
            var prior := float(best.get(next, INF))
            var edge_id := str(edge.get("id", ""))
            var tie_key := "%s\u0000%s" % [edge_id, current]
            var prior_key := "%s\u0000%s" % [str(parent_edge.get(next, "~")), str(parent_node.get(next, "~"))]
            if candidate < prior - COST_EPSILON or (is_equal_approx(candidate, prior) and tie_key < prior_key):
                best[next] = candidate
                parent_node[next] = current
                parent_edge[next] = edge_id
                if not frontier.has(next):
                    frontier.append(next)

    if not parent_node.has(goal_node):
        return PackedStringArray()
    var reversed: Array[String] = []
    var cursor := goal_node
    while cursor != start_node:
        if not parent_node.has(cursor) or not parent_edge.has(cursor):
            return PackedStringArray()
        reversed.append(str(parent_edge[cursor]))
        cursor = str(parent_node[cursor])
    reversed.reverse()
    var result := PackedStringArray()
    for edge_id in reversed:
        result.append(edge_id)
    return result

func _edge_destination(edge: Dictionary, current: String) -> String:
    var source := str(edge.get("from", ""))
    var target := str(edge.get("to", ""))
    var direction := int(edge.get("direction", 0))
    if current == source and direction >= 0:
        return target
    if current == target and direction <= 0:
        return source
    return ""

func _get_record(kind: String, identifier: String) -> Dictionary:
    var partition := kind + "_" + identifier.sha1_text().substr(0, 2)
    if not _cache.has(partition):
        var path := "%s/%s.json" % [data_root, partition]
        if not FileAccess.file_exists(path):
            return {}
        var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
        if not payload is Dictionary:
            push_error("Invalid national graph partition: " + path)
            return {}
        _cache[partition] = payload
    _lru.erase(partition)
    _lru.append(partition)
    while _lru.size() > max_cached_partitions:
        _cache.erase(_lru.pop_front())
    return _cache[partition].get(identifier, {})
