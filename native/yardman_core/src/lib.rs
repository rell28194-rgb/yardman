#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point2 {
    pub x: f32,
    pub y: f32,
}

impl Point2 {
    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    fn distance_squared(self, other: Self) -> f64 {
        let dx = f64::from(self.x - other.x);
        let dy = f64::from(self.y - other.y);
        dx * dx + dy * dy
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct CellCoord {
    pub x: i32,
    pub z: i32,
}

impl CellCoord {
    pub const fn new(x: i32, z: i32) -> Self {
        Self { x, z }
    }

    pub fn center(self, cell_size: f32) -> Point2 {
        Point2::new(
            (self.x as f32 + 0.5) * cell_size,
            (self.z as f32 + 0.5) * cell_size,
        )
    }
}

pub fn filter_indices_in_radius<I>(points: I, center: Point2, radius: f64) -> Vec<i32>
where
    I: IntoIterator<Item = Point2>,
{
    if radius < 0.0 || !radius.is_finite() {
        return Vec::new();
    }
    let radius_sq = radius * radius;
    points
        .into_iter()
        .enumerate()
        .filter_map(|(index, point)| {
            (point.distance_squared(center) <= radius_sq).then_some(index as i32)
        })
        .collect()
}

pub fn count_points_in_radius<I>(points: I, center: Point2, radius: f64) -> i64
where
    I: IntoIterator<Item = Point2>,
{
    if radius < 0.0 || !radius.is_finite() {
        return 0;
    }
    let radius_sq = radius * radius;
    points
        .into_iter()
        .filter(|point| point.distance_squared(center) <= radius_sq)
        .count() as i64
}

/// Deterministic cell-interest selection shared by streaming and future network
/// relevance. The core owns the spatial decision; Godot or a dedicated server
/// decides what to load, render, replicate, or simulate for the returned cells.
pub fn select_cells_in_annulus<I>(
    cells: I,
    world_position: Point2,
    cell_size: f32,
    min_distance: f32,
    max_distance: f32,
    max_cells: usize,
) -> Vec<CellCoord>
where
    I: IntoIterator<Item = CellCoord>,
{
    if cell_size <= 0.0
        || !cell_size.is_finite()
        || !min_distance.is_finite()
        || !max_distance.is_finite()
        || max_distance < min_distance.max(0.0)
        || max_cells == 0
    {
        return Vec::new();
    }

    let min_sq = f64::from(min_distance.max(0.0)).powi(2);
    let max_sq = f64::from(max_distance).powi(2);
    let mut selected: Vec<(f64, CellCoord)> = cells
        .into_iter()
        .filter_map(|cell| {
            let distance_sq = cell.center(cell_size).distance_squared(world_position);
            (distance_sq >= min_sq && distance_sq <= max_sq).then_some((distance_sq, cell))
        })
        .collect();

    selected.sort_by(|(distance_a, cell_a), (distance_b, cell_b)| {
        distance_a
            .total_cmp(distance_b)
            .then_with(|| cell_a.cmp(cell_b))
    });
    selected.truncate(max_cells);
    selected.into_iter().map(|(_, cell)| cell).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn radius_filter_and_count_match() {
        let points = [
            Point2::new(0.0, 0.0),
            Point2::new(3.0, 4.0),
            Point2::new(5.01, 0.0),
            Point2::new(-1.0, -1.0),
        ];
        assert_eq!(filter_indices_in_radius(points, Point2::default(), 5.0), vec![0, 1, 3]);
        assert_eq!(count_points_in_radius(points, Point2::default(), 5.0), 3);
        assert!(filter_indices_in_radius(points, Point2::default(), -1.0).is_empty());
    }

    #[test]
    fn interest_cells_are_nearest_first_and_deterministic() {
        let cells = [
            CellCoord::new(2, 0),
            CellCoord::new(0, 0),
            CellCoord::new(-1, 0),
            CellCoord::new(1, 0),
            CellCoord::new(0, 1),
            CellCoord::new(0, -1),
        ];
        let selected = select_cells_in_annulus(
            cells,
            Point2::new(128.0, 128.0),
            256.0,
            0.0,
            600.0,
            4,
        );
        assert_eq!(selected.len(), 4);
        assert_eq!(selected[0], CellCoord::new(0, 0));
        assert!(selected.contains(&CellCoord::new(-1, 0)));
        assert!(selected.contains(&CellCoord::new(0, -1)));
    }

    #[test]
    fn invalid_interest_envelope_fails_closed() {
        assert!(select_cells_in_annulus(
            [CellCoord::new(0, 0)],
            Point2::default(),
            0.0,
            0.0,
            100.0,
            8,
        )
        .is_empty());
        assert!(select_cells_in_annulus(
            [CellCoord::new(0, 0)],
            Point2::default(),
            256.0,
            500.0,
            100.0,
            8,
        )
        .is_empty());
    }
}
