import AppKit
import XCTest
@testable import i3wm_osx

final class BarTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let statusColor = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)

    func testPlainBlockPreservesDefaultsAndBlockColor() throws {
        let block = try XCTUnwrap(parseStatusBlocks("""
        [{"full_text":"plain &amp; text","color":"#112233"}]
        """)?.first)

        XCTAssertEqual(block.text, "plain &amp; text")
        XCTAssertNil(block.markup)
        XCTAssertTrue(block.separator)
        XCTAssertNil(block.separatorBlockWidth)
        XCTAssertEqual(block.boundaryWidth(separatorGlyphWidth: 7), 23)

        let attributed = block.attributedText(font: font, defaultColor: statusColor)
        XCTAssertEqual(attributed.string, "plain &amp; text")
        assertColor(attributed, at: 0, hex: 0x112233)
    }

    func testNoneMarkupRemainsPlainText() throws {
        let block = try XCTUnwrap(parseStatusBlocks("""
        [{"full_text":"<span color='#ff0000'>literal</span>","markup":"none"}]
        """)?.first)

        let attributed = block.attributedText(font: font, defaultColor: statusColor)
        XCTAssertEqual(attributed.string, "<span color='#ff0000'>literal</span>")
        assertColor(attributed, at: 0, color: statusColor)
    }

    func testAdjacentAndNestedColorSpans() throws {
        let block = try XCTUnwrap(parseStatusBlocks("""
        [{
          "full_text":"base <span color='#50fa7b'>green <span foreground='#ff555580'>red</span> green</span> base",
          "markup":"pango",
          "color":"#6272a4"
        }]
        """)?.first)
        let attributed = block.attributedText(font: font, defaultColor: statusColor)

        XCTAssertEqual(attributed.string, "base green red green base")
        assertColor(attributed, in: "base", occurrence: 1, hex: 0x6272a4)
        assertColor(attributed, in: "green", occurrence: 1, hex: 0x50fa7b)
        assertColor(attributed, in: "red", occurrence: 1, hex: 0xff5555, alpha: 0x80)
        assertColor(attributed, in: "green", occurrence: 2, hex: 0x50fa7b)
        assertColor(attributed, in: "base", occurrence: 2, hex: 0x6272a4)
    }

    func testSingleAndDoubleQuotedAttributes() throws {
        let block = try XCTUnwrap(parseStatusBlocks("""
        [{
          "full_text":"<span color='#50fa7b'>single</span><span foreground=\\\"#ff5555\\\">double</span>",
          "markup":"pango"
        }]
        """)?.first)
        let attributed = block.attributedText(font: font, defaultColor: statusColor)

        XCTAssertEqual(attributed.string, "singledouble")
        assertColor(attributed, in: "single", occurrence: 1, hex: 0x50fa7b)
        assertColor(attributed, in: "double", occurrence: 1, hex: 0xff5555)
    }

    func testPangoMarkupDecodesEntities() throws {
        let block = try XCTUnwrap(parseStatusBlocks("""
        [{
          "full_text":"Tom &amp; Jerry &lt;3 &quot;yes&quot; &apos;ok&apos; &#33;",
          "markup":"pango"
        }]
        """)?.first)

        XCTAssertEqual(
            block.attributedText(font: font, defaultColor: statusColor).string,
            "Tom & Jerry <3 \"yes\" 'ok' !"
        )
    }

    func testMalformedMarkupFallsBackToLiteralText() throws {
        let source = "<span color='#50fa7b'>broken"
        let block = try XCTUnwrap(parseStatusBlocks("""
        [{"full_text":"\(source)","markup":"pango","color":"#ff5555"}]
        """)?.first)
        let attributed = block.attributedText(font: font, defaultColor: statusColor)

        XCTAssertEqual(attributed.string, source)
        assertColor(attributed, at: 0, hex: 0xff5555)
    }

    func testDisabledSeparatorWithZeroWidthHasNoBoundaryGap() throws {
        let blocks = try XCTUnwrap(parseStatusBlocks("""
        [
          {
            "full_text": "✨7d 52%/",
            "color": "#50fa7b",
            "separator": false,
            "separator_block_width": 0
          },
          {
            "full_text": "+9%",
            "color": "#ff5555"
          }
        ]
        """))

        XCTAssertEqual(statusRenderOrder(blockCount: blocks.count), [
            StatusRenderItem(blockIndex: 1, boundaryOwnerIndex: 0),
            StatusRenderItem(blockIndex: 0, boundaryOwnerIndex: nil),
        ])
        XCTAssertFalse(blocks[0].separator)
        XCTAssertEqual(blocks[0].boundaryWidth(separatorGlyphWidth: 7), 0)

        let widths = blocks.map {
            $0.attributedText(font: font, defaultColor: statusColor).size().width
        }
        let layout = statusLayout(
            blocks: blocks,
            textWidths: widths,
            separatorGlyphWidth: 7,
            rightEdge: 100
        )
        let right = try XCTUnwrap(layout.first { $0.blockIndex == 1 })
        let left = try XCTUnwrap(layout.first { $0.blockIndex == 0 })
        XCTAssertEqual(left.textX + widths[0], right.textX, accuracy: 0.0001)
        XCTAssertNil(right.separatorX)
    }

    func testDefaultSeparatorPreservesLegacyWidth() throws {
        let blocks = try XCTUnwrap(parseStatusBlocks("""
        [{"full_text":"left"},{"full_text":"right"}]
        """))

        XCTAssertTrue(blocks[0].separator)
        XCTAssertEqual(blocks[0].boundaryWidth(separatorGlyphWidth: 7), 23)

        let layout = statusLayout(
            blocks: blocks,
            textWidths: [10, 20],
            separatorGlyphWidth: 7,
            rightEdge: 100
        )
        let right = try XCTUnwrap(layout.first { $0.blockIndex == 1 })
        let left = try XCTUnwrap(layout.first { $0.blockIndex == 0 })
        let separatorX = try XCTUnwrap(right.separatorX)
        XCTAssertEqual(left.textX, 47)
        XCTAssertEqual(separatorX - (left.textX + 10), 8)
        XCTAssertEqual(right.textX - (separatorX + 7), 8)
    }

    func testSeparatorOwnershipWhileRenderingRightToLeft() throws {
        let blocks = try XCTUnwrap(parseStatusBlocks("""
        [
          {"full_text":"A","separator":false,"separator_block_width":3},
          {"full_text":"B","separator":true,"separator_block_width":11},
          {"full_text":"C","separator":false,"separator_block_width":19}
        ]
        """))
        let order = statusRenderOrder(blockCount: blocks.count)

        XCTAssertEqual(order, [
            StatusRenderItem(blockIndex: 2, boundaryOwnerIndex: 1),
            StatusRenderItem(blockIndex: 1, boundaryOwnerIndex: 0),
            StatusRenderItem(blockIndex: 0, boundaryOwnerIndex: nil),
        ])
        XCTAssertEqual(order.compactMap(\.boundaryOwnerIndex).map { blocks[$0].separatorBlockWidth }, [11, 3])
        XCTAssertEqual(order.compactMap(\.boundaryOwnerIndex).map { blocks[$0].separator }, [true, false])
    }

    func testBooleanSeparatorWidthIsIgnored() throws {
        let blocks = try XCTUnwrap(parseStatusBlocks("""
        [
          {"full_text":"false","separator_block_width":false},
          {"full_text":"true","separator_block_width":true}
        ]
        """))

        XCTAssertNil(blocks[0].separatorBlockWidth)
        XCTAssertNil(blocks[1].separatorBlockWidth)
    }

    func testBothAcceptancePayloadsProduceSameAttributedStatus() throws {
        let twoBlocks = try XCTUnwrap(parseStatusBlocks("""
        [
          {
            "full_text": "✨7d 52%/",
            "color": "#50fa7b",
            "separator": false,
            "separator_block_width": 0
          },
          {
            "full_text": "+9%",
            "color": "#ff5555"
          }
        ]
        """))
        let oneBlock = try XCTUnwrap(parseStatusBlocks("""
        [{
          "full_text": "<span color='#50fa7b'>✨7d 52%/</span><span color='#ff5555'>+9%</span>",
          "markup": "pango"
        }]
        """)?.first)

        let combined = NSMutableAttributedString(string: "")
        for block in twoBlocks {
            combined.append(block.attributedText(font: font, defaultColor: statusColor))
        }
        let pango = oneBlock.attributedText(font: font, defaultColor: statusColor)

        XCTAssertEqual(combined.string, "✨7d 52%/+9%")
        XCTAssertEqual(pango.string, combined.string)
        assertColor(combined, in: "7d", occurrence: 1, hex: 0x50fa7b)
        assertColor(combined, in: "+9%", occurrence: 1, hex: 0xff5555)
        assertColor(pango, in: "7d", occurrence: 1, hex: 0x50fa7b)
        assertColor(pango, in: "+9%", occurrence: 1, hex: 0xff5555)
        XCTAssertEqual(twoBlocks[0].boundaryWidth(separatorGlyphWidth: 7), 0)
    }

    private func assertColor(
        _ attributed: NSAttributedString,
        in substring: String,
        occurrence: Int,
        hex: UInt32,
        alpha: UInt32 = 0xff,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let source = attributed.string as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            found = source.range(of: substring, options: [], range: searchRange)
            guard found.location != NSNotFound else {
                XCTFail("Missing substring \(substring)", file: file, line: line)
                return
            }
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: source.length - next)
        }
        assertColor(attributed, at: found.location, hex: hex, alpha: alpha, file: file, line: line)
    }

    private func assertColor(
        _ attributed: NSAttributedString,
        at index: Int,
        hex: UInt32,
        alpha: UInt32 = 0xff,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: CGFloat(alpha) / 255
        )
        assertColor(attributed, at: index, color: expected, file: file, line: line)
    }

    private func assertColor(
        _ attributed: NSAttributedString,
        at index: Int,
        color expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
              let actualRGB = actual.usingColorSpace(.sRGB),
              let expectedRGB = expected.usingColorSpace(.sRGB) else {
            XCTFail("Missing sRGB foreground color", file: file, line: line)
            return
        }

        XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualRGB.alphaComponent, expectedRGB.alphaComponent, accuracy: 0.0001, file: file, line: line)
    }
}
