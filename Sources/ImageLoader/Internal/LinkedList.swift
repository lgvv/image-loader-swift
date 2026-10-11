final class LinkedList<Element> {
    private(set) var first: Node?
    private(set) var last: Node?
    private(set) var count = 0

    deinit {
        removeAllElements()
    }

    var isEmpty: Bool {
        first == nil
    }

    @discardableResult
    func append(_ element: Element) -> Node {
        let node = Node(value: element)
        append(node)
        return node
    }

    func append(_ node: Node) {
        if let last {
            last.next = node
            node.previous = last
            self.last = node
        } else {
            first = node
            last = node
        }
        count += 1
    }

    @discardableResult
    func prepend(_ element: Element) -> Node {
        let node = Node(value: element)
        if let first {
            node.next = first
            first.previous = node
            self.first = node
        } else {
            first = node
            last = node
        }
        count += 1
        return node
    }

    func remove(_ node: Node) {
        node.next?.previous = node.previous
        node.previous?.next = node.next
        if node === first {
            first = node.next
        }
        if node === last {
            last = node.previous
        }
        node.next = nil
        node.previous = nil
        count -= 1
    }

    func moveToLast(_ node: Node) {
        guard node !== last else { return }
        remove(node)
        append(node)
    }

    func removeAllElements() {
        var node = first
        while let current = node {
            node = current.next
            current.next = nil
            current.previous = nil
        }
        first = nil
        last = nil
        count = 0
    }

    final class Node {
        let value: Element
        fileprivate(set) var next: Node?
        fileprivate(set) weak var previous: Node?

        init(value: Element) {
            self.value = value
        }
    }
}
