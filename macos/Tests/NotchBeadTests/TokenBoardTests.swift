import Foundation
import Testing
@testable import NotchBead

@Suite struct TokenBoardTests {
    @Test func sumsEverySourceAndMarksPartialCost() throws {
        let json = """
        {"rows": [
          {"key": "pi", "value": 100400515, "cost": 2.238075, "cost_partial": false},
          {"key": "claude-code", "value": 76826241, "cost": 27.939595, "cost_partial": false},
          {"key": "codex", "value": 7128837, "cost": 0.0, "cost_partial": true}
        ]}
        """
        let total = try #require(TokenBoard.parse(Data(json.utf8)))
        #expect(total.tokens == 184_355_593)
        #expect(abs(total.cost - 30.17767) < 0.0001)
        #expect(total.costPartial)
        #expect(TokenText.yi(total.tokens) == "1.84亿")
    }

    @Test func tokensAreAlwaysYi() {
        #expect(TokenText.yi(201_000_000) == "2.01亿")
        #expect(TokenText.yi(1_903_000_000) == "19.03亿")
        #expect(TokenText.yi(0) == "0.00亿")
    }

    @Test func emptyDayAndBadAnswers() {
        #expect(TokenBoard.parse(Data(#"{"rows": []}"#.utf8)) == TokenTotal(tokens: 0, cost: 0, costPartial: false))
        #expect(TokenBoard.parse(Data("not json".utf8)) == nil)
    }

    @Test func dayIsLocal() {
        #expect(TokenBoard.dayString(Date(timeIntervalSince1970: 0)).count == 10)
    }
}

@Suite struct TokenPanelTests {
    @Test func readsBreakdownRowsAndDays() throws {
        let rows = try #require(TokenBoard.shares(Data(#"{"rows":[{"key":"pi","value":203000000,"cost":4.86,"cost_partial":false},{"key":"codex","value":2220650,"cost":0,"cost_partial":true}]}"#.utf8)))
        #expect(rows.map(\.key) == ["pi", "codex"])
        #expect(rows[1].costPartial)
        let days = try #require(TokenBoard.days(Data(#"{"days":["2026-11-05","2026-11-06"],"series":{"pi":[10,20],"codex":[1,2]}}"#.utf8)))
        #expect(days.map(\.total) == [11, 22])
        #expect(TokenBoard.days(Data("nope".utf8)) == nil)
    }

    @Test func compactAndCost() {
        #expect(TokenText.compact(196_000_000) == "1.96亿")
        #expect(TokenText.compact(2_220_650) == "222万")
        #expect(TokenText.compact(5_000) == "<1万")
        #expect(TokenText.compact(0) == "0")
        #expect(TokenText.cost(91.2249, partial: false) == "$91.22")
        #expect(TokenText.cost(0, partial: true) == "$0.00+")
    }
}
