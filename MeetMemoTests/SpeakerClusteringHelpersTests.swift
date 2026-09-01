import XCTest
@testable import MeetMemo

final class SpeakerClusteringHelpersTests: XCTestCase {
    func testAssignOnlineRejectsUnusableEmbeddingWithoutCreatingSpeaker() {
        var centroids: [(centroid: [Float], count: Int)] = []

        XCTAssertNil(SpeakerClustering.assignOnline(embedding: [], centroids: &centroids))
        XCTAssertNil(SpeakerClustering.assignOnline(embedding: [0, 0], centroids: &centroids))
        XCTAssertNil(SpeakerClustering.assignOnline(embedding: [Float.nan, 1], centroids: &centroids))
        XCTAssertNil(SpeakerClustering.assignOnline(embedding: [Float.infinity, 1], centroids: &centroids))
        XCTAssertTrue(centroids.isEmpty)
    }

    func testAssignOnlineTreatsDifferentDimensionsAsDifferentSpeakers() {
        var centroids: [(centroid: [Float], count: Int)] = [
            (centroid: [1, 0], count: 1)
        ]

        let speakerID = SpeakerClustering.assignOnline(
            embedding: [1, 0, 0],
            centroids: &centroids
        )

        XCTAssertEqual(speakerID, 1)
        XCTAssertEqual(centroids.count, 2)
        XCTAssertEqual(centroids[0].centroid.count, 2)
        XCTAssertEqual(centroids[1].centroid.count, 3)
    }

    func testAssignOnlineStillUpdatesCompatibleCentroid() {
        var centroids: [(centroid: [Float], count: Int)] = []

        XCTAssertEqual(
            SpeakerClustering.assignOnline(embedding: [3, 0], centroids: &centroids),
            0
        )
        XCTAssertEqual(
            SpeakerClustering.assignOnline(embedding: [1, 0.01], centroids: &centroids),
            0
        )
        XCTAssertEqual(centroids.count, 1)
        XCTAssertEqual(centroids[0].count, 2)
    }

    func testOfflineRefinementHandlesInvalidAndMixedDimensions() {
        let assignments = SpeakerClustering.refineOffline(
            embeddings: [[1, 0], [], [1, 0, 0], [Float.nan, 1]]
        )

        XCTAssertEqual(assignments, [0, 1, 2, 3])
    }

    func testCosineSimilarityRejectsMismatchedDimensions() {
        XCTAssertEqual(
            SpeakerClustering.cosineSimilarity([1, 0], [1, 0, 0]),
            -Float.infinity
        )
    }
}
