import XCTest
@testable import LorisListKit

final class OutboxTests: XCTestCase {
    private let eggs = ListItem(id: 3, name: "Eggs", count: 12, checked: false)
    private let cake = ListItem(id: 4, name: "Cake", count: nil, checked: false)

    private func add(_ name: String, temp: Int, list: Int = 1) -> PendingChange {
        .addItem(listID: list, tempID: temp, name: name, count: nil, key: "add-\(temp)")
    }

    func testNothingPendingLeavesTheListAlone() {
        XCTAssertEqual(Outbox.apply([], to: [eggs, cake], listID: 1), [eggs, cake])
    }

    func testPendingChangesShowOnTopOfTheServersCopy() {
        let queue: [PendingChange] = [
            add("Milk", temp: -1),
            .setChecked(listID: 1, itemID: 3, checked: true, key: "a"),
            .removeItem(listID: 1, itemID: 4, key: "b"),
        ]
        let shown = Outbox.apply(queue, to: [eggs, cake], listID: 1)
        XCTAssertEqual(shown.map { $0.name }, ["Eggs", "Milk"])
        XCTAssertTrue(shown[0].checked)
        XCTAssertEqual(shown[1].id, -1)
    }

    func testChangesToOtherListsAreIgnored() {
        let queue: [PendingChange] = [add("Milk", temp: -1, list: 2)]
        XCTAssertEqual(Outbox.apply(queue, to: [eggs], listID: 1), [eggs])
    }

    func testClearingRemovesWhatIsTickedAtThatPoint() {
        let queue: [PendingChange] = [
            .setChecked(listID: 1, itemID: 3, checked: true, key: "a"),
            .clearChecked(listID: 1, key: "b"),
            add("Milk", temp: -1),
        ]
        XCTAssertEqual(Outbox.apply(queue, to: [eggs, cake], listID: 1).map { $0.name }, ["Cake", "Milk"])
    }

    func testAnAddIsNotShownTwice() {
        let queue = [add("Milk", temp: -1)]
        let once = Outbox.apply(queue, to: [], listID: 1)
        XCTAssertEqual(Outbox.apply(queue, to: once, listID: 1).count, 1)
    }

    func testTickingAgainReplacesTheEarlierTick() {
        var queue: [PendingChange] = []
        queue = Outbox.enqueue(.setChecked(listID: 1, itemID: 3, checked: true, key: "a"), into: queue)
        queue = Outbox.enqueue(.setChecked(listID: 1, itemID: 4, checked: true, key: "b"), into: queue)
        queue = Outbox.enqueue(.setChecked(listID: 1, itemID: 3, checked: false, key: "c"), into: queue)
        XCTAssertEqual(queue.map { $0.key }, ["b", "c"])
    }

    func testRemovingAnItemDropsEarlierTicksOfIt() {
        var queue: [PendingChange] = []
        queue = Outbox.enqueue(.setChecked(listID: 1, itemID: 3, checked: true, key: "a"), into: queue)
        queue = Outbox.enqueue(.removeItem(listID: 1, itemID: 3, key: "b"), into: queue)
        XCTAssertEqual(queue.map { $0.key }, ["b"])
    }

    func testRemovingAnItemThatWasOnlyEverAddedHereCancelsEverything() {
        var queue: [PendingChange] = []
        queue = Outbox.enqueue(add("Milk", temp: -1), into: queue)
        queue = Outbox.enqueue(add("Bread", temp: -2), into: queue)
        queue = Outbox.enqueue(.setChecked(listID: 1, itemID: -1, checked: true, key: "t"), into: queue)
        queue = Outbox.enqueue(.removeItem(listID: 1, itemID: -1, key: "r"), into: queue)
        XCTAssertEqual(queue.map { $0.key }, ["add--2"])
    }

    func testOnceTheServerGivesAnIdLaterChangesUseIt() {
        let queue: [PendingChange] = [
            .setChecked(listID: 1, itemID: -1, checked: true, key: "t"),
            .removeItem(listID: 1, itemID: -2, key: "r"),
            .setChecked(listID: 1, itemID: 3, checked: true, key: "u"),
        ]
        let moved = Outbox.retarget(queue, tempID: -1, realID: 9)
        XCTAssertEqual(moved[0], .setChecked(listID: 1, itemID: 9, checked: true, key: "t"))
        XCTAssertEqual(moved[1], queue[1])
        XCTAssertEqual(moved[2], queue[2])
    }

    func testFindingTheServersIdForANewItem() {
        let before = [eggs, cake]
        let one = before + [ListItem(id: 5, name: "Milk", count: 2, checked: false)]
        XCTAssertEqual(Outbox.newItemID(before: before, after: one, name: "Milk", count: 2), 5)

        // Someone else added something at the same moment: prefer the one that matches.
        let two = one + [ListItem(id: 6, name: "Tea", count: nil, checked: false)]
        XCTAssertEqual(Outbox.newItemID(before: before, after: two, name: "Milk", count: 2), 5)
        XCTAssertEqual(Outbox.newItemID(before: before, after: two, name: "Other", count: nil), 6)
        XCTAssertNil(Outbox.newItemID(before: before, after: before, name: "Milk", count: 2))
    }

    func testTheQueueSurvivesBeingSavedAndLoaded() throws {
        let queue: [PendingChange] = [
            .addItem(listID: 1, tempID: -1, name: "Milk", count: 2, key: "k1"),
            .addItem(listID: 1, tempID: -2, name: "Bread", count: nil, key: "k2"),
            .setChecked(listID: 1, itemID: 3, checked: true, key: "k3"),
            .removeItem(listID: 2, itemID: 4, key: "k4"),
            .clearChecked(listID: 1, key: "k5"),
        ]
        let data = try JSONEncoder().encode(queue)
        XCTAssertEqual(try JSONDecoder().decode([PendingChange].self, from: data), queue)
    }
}
