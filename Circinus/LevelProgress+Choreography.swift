import Foundation

// MARK: - LevelProgress + Choreography Persistence
//
// Adds per-level best-choreography storage alongside the existing move-star
// persistence in LevelProgress.  Keys are intentionally distinct so old saves
// with no choreography data decode cleanly (integer(forKey:) returns 0 when the
// key is absent, giving a safe "not yet recorded" default).
//
// Keys: "cho_pts_{levelID}"   → Int, raw choreography points (0–100)
//       "cho_stars_{levelID}" → Int, star rating (0 = unplayed, 1–3 = rated)

extension LevelProgress {

    /// Returns the best-recorded choreography result for a level.
    /// Returns `(points: 0, stars: 0)` when no result has been saved yet
    /// (backward-compatible with saves predating milestone 1.3).
    static func bestChoreography(levelID: Int) -> (points: Int, stars: Int) {
        let p = UserDefaults.standard.integer(forKey: "cho_pts_\(levelID)")
        let s = UserDefaults.standard.integer(forKey: "cho_stars_\(levelID)")
        return (p, s)
    }

    /// Persists a choreography score only if it equals or improves on the stored best.
    /// A score with equal stars is kept so that players can overwrite noise results
    /// with a cleaner solve at the same tier.
    static func saveChoreography(levelID: Int, score: ChoreographyScore) {
        let existing = bestChoreography(levelID: levelID)
        guard score.stars >= existing.stars else { return }
        UserDefaults.standard.set(score.points, forKey: "cho_pts_\(levelID)")
        UserDefaults.standard.set(score.stars,  forKey: "cho_stars_\(levelID)")
    }
}
