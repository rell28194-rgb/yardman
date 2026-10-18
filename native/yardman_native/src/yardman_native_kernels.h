#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

class YardmanNativeKernels : public RefCounted {
    GDCLASS(YardmanNativeKernels, RefCounted)

protected:
    static void _bind_methods();

public:
    PackedInt32Array filter_points_in_radius(const PackedVector2Array &points, Vector2 center, double radius) const;
    int64_t count_points_in_radius(const PackedVector2Array &points, Vector2 center, double radius) const;
    String build_id() const;
};

} // namespace godot
