import CoreGraphics

/// KeyNav's geometry, on a front page shaped like the real one: a full-width
/// lead over three masonry columns whose cards do not line up row by row.
/// Frames are top-down in the paper's content, as KeyNav measures them.
enum KeyNavTests {

    private static let page: [String: CGRect] = [
        "lead": CGRect(x: 0,   y: 0,    width: 1200, height: 400),
        "L1":   CGRect(x: 0,   y: 420,  width: 380,  height: 300),   // 420-720
        "L2":   CGRect(x: 0,   y: 740,  width: 380,  height: 500),   // 740-1240
        "L3":   CGRect(x: 0,   y: 1260, width: 380,  height: 300),   // 1260-1560
        "M1":   CGRect(x: 410, y: 420,  width: 380,  height: 200),   // 420-620
        "M2":   CGRect(x: 410, y: 640,  width: 380,  height: 400),   // 640-1040
        "M3":   CGRect(x: 410, y: 1060, width: 380,  height: 600),   // 1060-1660
        "R1":   CGRect(x: 820, y: 420,  width: 380,  height: 450),   // 420-870
        "R2":   CGRect(x: 820, y: 890,  width: 380,  height: 300),   // 890-1190
        "R3":   CGRect(x: 820, y: 1210, width: 380,  height: 400),   // 1210-1610
    ]

    /// A window onto the page from `top` to `top + height`.
    private static func view(_ top: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: 0, y: top, width: 1200, height: height)
    }

    static func run() {
        T.suite("KeyNav: after paging, a highlight still wholly in view stays") {
            T.equal(KeyNav.afterPaging(from: "R2", in: page, visible: view(700, 600)), nil,
                    "R2 (890-1190) is inside 700-1300")
        }

        T.suite("KeyNav: after Page Down, the highlight moves to the first story starting in view") {
            // The lead has scrolled away. L2, at 740, is the topmost story whose
            // top is on screen.
            T.equal(KeyNav.afterPaging(from: "lead", in: page, visible: view(700, 600)), "L2",
                    "from the lead, scrolled off the top")
            // M2 is still partly on screen (640-1040 against 700-1300) but cut off
            // at the top, so it gives way too.
            T.equal(KeyNav.afterPaging(from: "M2", in: page, visible: view(700, 600)), "L2",
                    "from M2, cut off at the top")
            T.equal(KeyNav.afterPaging(from: nil, in: page, visible: view(700, 600)), "L2",
                    "with nothing highlighted yet")
        }

        T.suite("KeyNav: a story cut off at the top is passed over") {
            // L1 (420-720) and M2 (640-1040) both reach into 700-1300 and both
            // come before L2 in reading order, but neither starts in view.
            let chosen = KeyNav.afterPaging(from: "lead", in: page, visible: view(700, 600))
            T.expect(chosen != "L1" && chosen != "M2", "chose \(chosen ?? "nil"), which starts above the view")
        }

        T.suite("KeyNav: after Page Up, the highlight moves to the top of the new view") {
            T.equal(KeyNav.afterPaging(from: "L3", in: page, visible: view(0, 600)), "lead",
                    "from L3, scrolled off the bottom")
        }

        T.suite("KeyNav: stories starting level go left to right") {
            // L1, M1 and R1 all start at 420.
            T.equal(KeyNav.afterPaging(from: "lead", in: page, visible: view(410, 300)), "L1",
                    "the leftmost of three level tops")
        }

        T.suite("KeyNav: when no story starts in view, the one showing wins") {
            // 1300-1500 is inside L3, M3 and R3, and none of them starts there.
            T.equal(KeyNav.afterPaging(from: "lead", in: page, visible: view(1300, 200)), "M3",
                    "the first in reading order of the stories filling the view")
        }

        T.suite("KeyNav: arrows (existing rules)") {
            T.equal(KeyNav.next(from: "lead", .down, in: page), "L1",
                    "down from the full-width lead lands on the left column")
            T.equal(KeyNav.next(from: "L1", .right, in: page), "M1",
                    "right from L1 stays level, into the middle column")
            T.equal(KeyNav.next(from: "M2", .up, in: page), "M1",
                    "up stays in the same column")
        }
    }
}
