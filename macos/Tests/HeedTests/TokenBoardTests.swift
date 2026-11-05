import Foundation
import Testing
@testable import Heed

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
