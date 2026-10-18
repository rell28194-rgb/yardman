#include "yardman_native_kernels.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void YardmanNativeKernels::_bind_methods() {
    ClassDB::bind_method(D_METHOD("filter_points_in_radius", "points", "center", "radius"), &YardmanNativeKernels::filter_points_in_radius);
    ClassDB::bind_method(D_METHOD("count_points_in_radius", "points", "center", "radius"), &YardmanNativeKernels::count_points_in_radius);
    ClassDB::bind_method(D_METHOD("build_id"), &YardmanNativeKernels::build_id);
}

PackedInt32Array YardmanNativeKernels::filter_points_in_radius(const PackedVector2Array &points, Vector2 center, double radius) const {
    PackedInt32Array result;
    if (radius < 0.0 || points.is_empty()) {
        return result;
    }

    const double radius_sq = radius * radius;
    const int64_t size = points.size();
    result.resize(size);
    int32_t *write = result.ptrw();
    const Vector2 *read = points.ptr();
    int64_t count = 0;

    for (int64_t i = 0; i < size; ++i) {
        const double dx = static_cast<double>(read[i].x - center.x);
        const double dy = static_cast<double>(read[i].y - center.y);
        if (dx * dx + dy * dy <= radius_sq) {
            write[count++] = static_cast<int32_t>(i);
        }
    }

    result.resize(count);
    return result;
}

int64_t YardmanNativeKernels::count_points_in_radius(const PackedVector2Array &points, Vector2 center, double radius) const {
    if (radius < 0.0 || points.is_empty()) {
        return 0;
    }

    const double radius_sq = radius * radius;
    const Vector2 *read = points.ptr();
    int64_t count = 0;
    for (int64_t i = 0; i < points.size(); ++i) {
        const double dx = static_cast<double>(read[i].x - center.x);
        const double dy = static_cast<double>(read[i].y - center.y);
        if (dx * dx + dy * dy <= radius_sq) {
            ++count;
        }
    }
    return count;
}

String YardmanNativeKernels::build_id() const {
    return "yardman-native/api-4.7/kernel-v1";
}

} // namespace godot
