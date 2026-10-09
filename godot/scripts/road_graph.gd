extends RefCounted
class_name YardmanRoadGraph

# This database belongs to the world, not to tile Nodes. LRU eviction changes
# residency only; stable identities and adjacency remain in packaged shards.
var data_root := "res://data/roads/graph"
var max_cached_partitions := 12
var node_count := 0
var edge_count := 0
var _cache: Dictionary = {}
var _lru: Array[String] = []

func configure(root_path: String, metadata: Dictionary) -> void:
    data_root = root_path
    node_count = int(metadata.get("nodes", 0))
    edge_count = int(metadata.get("edges", 0))

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
    return result

func clear_cache() -> void:
    _cache.clear()
    _lru.clear()

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
