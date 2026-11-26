//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer


struct ScenarioValueTests {
    @Test(arguments: [
        ("2024", [2024]), ("2024-02", [2024, 2]), ("2024-02-29", [2024, 2, 29]), ("2000-02-29", [2000, 2, 29])
    ])
    func validDates(_ text: String, _ components: [Int]) {
        #expect(ScenarioTemporal.date(text) == ScenarioTemporal(date: components, seconds: nil, fraction: ""))
    }

    @Test(arguments: ["", "24", "2024-2", "2024-13", "2023-02-29", "1900-02-29", "2024-04-31", "0000", "2024-01-01T", "２０２４"])
    func invalidDates(_ text: String) {
        #expect(ScenarioTemporal.date(text) == nil)
    }

    @Test
    func dateTimesNeedAFullDateAndAZoneWithATime() throws {
        #expect(ScenarioTemporal.dateTime("2024-03-01T12:00:00Z")?.seconds == 1_709_294_400)
        #expect(ScenarioTemporal.dateTime("2024-03-01T13:00:00+01:00")?.seconds == 1_709_294_400)
        #expect(ScenarioTemporal.dateTime("2024-03-01T07:00:00.5-05:00")?.fraction == "5")
        #expect(ScenarioTemporal.dateTime("1969-12-31T23:59:59Z")?.seconds == -1)
        #expect(ScenarioTemporal.dateTime("2024-03")?.date == [2024, 3])
        for invalid in ["2024-03-01T12:00:00", "2024-03T12:00:00Z", "2024-03-01T24:00:00Z", "2024-03-01T12:00Z", "2024-03-01T12:00:00+15:00"] {
            #expect(ScenarioTemporal.dateTime(invalid) == nil, "\(invalid)")
        }
    }

    @Test
    func exactInstantsAcrossOffsetBoundaries() throws {
        let first = try #require(ScenarioTemporal.dateTime("2024-03-02T00:00:00.000000001+14:00"))
        let equal = try #require(ScenarioTemporal.dateTime("2024-02-29T20:00:00.00000000100-14:00"))
        let later = try #require(ScenarioTemporal.dateTime("2024-03-01T10:00:00.00000000101Z"))
        #expect(first.compare(to: equal) == .orderedSame)
        #expect(first.compare(to: later) == .orderedAscending)
        #expect(later.compare(to: equal) == .orderedDescending)
        for zone in ["+14:01", "-14:59"] {
            #expect(ScenarioTemporal.dateTime("2024-03-01T12:00:00" + zone) == nil)
        }
    }

    @Test
    func timesAreFullClockTimes() {
        #expect(ScenarioTemporal.time("07:30:15.25")?.seconds == 27_015)
        #expect(ScenarioTemporal.time("23:59:60")?.seconds == 86_400)
        for invalid in ["7:30:00", "07:30", "24:00:00", "07:60:00", "07:30:61", "07:30:00.", "07:30:00Z"] {
            #expect(ScenarioTemporal.time(invalid) == nil, "\(invalid)")
        }
    }

    @Test
    func temporalOrderStopsAtTheCoarserPrecision() throws {
        let year = try #require(ScenarioTemporal.date("2019"))
        let day = try #require(ScenarioTemporal.date("2020-01-01"))
        let month = try #require(ScenarioTemporal.date("2020-01"))
        let instant = try #require(ScenarioTemporal.dateTime("2020-01-01T10:00:00Z"))
        #expect(year.compare(to: day) == .orderedAscending)
        #expect(month.compare(to: day) == nil)
        #expect(day.compare(to: instant) == nil)
        #expect(try #require(ScenarioTemporal.date("2020-01-02")).compare(to: instant) == .orderedDescending)
        #expect(day.compare(to: day) == .orderedSame)
    }

    @Test
    func codingsMatchOnlyWithEqualSystemAndCode() {
        let answer = ScenarioValue.coding(system: "http://example.org/a", code: "x")
        let systemless = ScenarioValue.coding(system: nil, code: "x")
        #expect(answer.equals(.coding(system: "http://example.org/a", code: "x")) == true)
        #expect(answer.equals(.coding(system: "http://example.org/b", code: "x")) == false)
        #expect(answer.equals(.coding(system: "http://example.org/a", code: "y")) == false)
        #expect(answer.equals(systemless) == false)
        #expect(systemless.equals(.coding(system: "http://example.org/a", code: "x")) == false)
        #expect(systemless.equals(.coding(system: nil, code: "x")) == true)
        #expect(ScenarioValue.coding(system: "http://example.org/a", code: nil).equals(.coding(system: nil, code: "x")) == false)
    }

    @Test
    func stringsCompareByCodeUnits() {
        #expect(ScenarioValue.string("\u{E9}").equals(.string("e\u{301}")) == false)
        #expect(ScenarioValue.string("Alex").equals(.string("alex")) == false)
        #expect(ScenarioValue.string("Alex").order(comparedTo: .string("B")) == .incomparable)
    }

    @Test
    func numbersCompareAcrossIntegerAndDecimal() {
        #expect(ScenarioValue.integer(80).equals(.decimal(80)) == true)
        #expect(ScenarioValue.decimal(80.5).order(comparedTo: .integer(80)) == .ordered(.orderedDescending))
        #expect(ScenarioValue.decimal(80.5).equals(.integer(80)) == false)
        #expect(ScenarioValue.decimal(70.5).order(comparedTo: .integer(70)) == .ordered(.orderedDescending))
        #expect(ScenarioValue.integer(1).equals(.boolean(true)) == false)
        #expect(ScenarioValue.integer(1).order(comparedTo: .coding(system: nil, code: "1")) == .incomparable)
    }

    @Test
    func quantitiesCompareOnlyInTheSameUnit() {
        let celsius = ScenarioValue.quantity(.init(value: 38, comparator: nil, system: "http://unitsofmeasure.org", code: "Cel"))
        let answer = ScenarioValue.quantity(.init(value: 38.5, comparator: nil, system: "http://unitsofmeasure.org", code: "Cel"))
        #expect(answer.order(comparedTo: celsius) == .ordered(.orderedDescending))
        #expect(answer.order(comparedTo: .quantity(.init(value: 38, comparator: nil, system: nil, code: "Cel"))) == .ordered(.orderedDescending))
        #expect(answer.order(comparedTo: .quantity(.init(value: 38, comparator: nil, system: nil, code: nil))) == .unknown)
        let unitless = ScenarioValue.quantity(.init(value: 2, comparator: nil, system: nil, code: nil))
        #expect(unitless.order(comparedTo: .quantity(.init(value: 1, comparator: nil, system: nil, code: nil))) == .ordered(.orderedDescending))
        let fahrenheit = ScenarioValue.quantity(.init(value: 101, comparator: nil, system: "http://unitsofmeasure.org", code: "[degF]"))
        #expect(fahrenheit.order(comparedTo: celsius) == .unknown)
        #expect(fahrenheit.equals(celsius) == nil)
        let bounded = ScenarioValue.quantity(.init(value: 39, comparator: ">", system: "http://unitsofmeasure.org", code: "Cel"))
        #expect(bounded.order(comparedTo: celsius) == .unknown)
        #expect(ScenarioValue.quantity(.init(value: nil, comparator: nil, system: nil, code: "Cel")).order(comparedTo: celsius) == .unknown)
    }

    @Test(arguments: [("mg", false), ("g", true), (nil, false)] as [(String?, Bool)])
    func writtenQuantityUnitsGateTheScenario(unit: String?, comparable: Bool) throws {
        let questionnaire = Data("""
        {"resourceType":"Questionnaire","status":"active","item":[
            {"linkId":"dose","type":"quantity"},
            {"linkId":"follow-up","type":"string","enableWhen":[
                {"question":"dose","operator":">","answerQuantity":{"value":1,"unit":"g"}}
            ]}
        ]}
        """.utf8)
        let scenario = Components.Schemas.QuestionnaireScenario(name: "Dose", item: [
            .init(linkId: "dose", answer: [.init(valueQuantity: .init(value: 100, unit: unit))])
        ])
        let evaluation = try QuestionnaireScenarios.evaluate(questionnaire, scenarios: [scenario])
        let result = try #require(evaluation.results.first)
        let followUp = try #require(result.items.first { $0.linkId == "follow-up" })
        #expect(result.complete == comparable)
        #expect(followUp.state == (comparable ? .enabled : .notEvaluated))
        #expect(followUp.conditions.first?.outcome == (comparable ? .met : .notEvaluated))
    }

    @Test
    func parsingRejectsValuesOfAnotherType() {
        #expect(ScenarioValue.parse(kind: "Integer", json: .number(1.5)) == nil)
        #expect(ScenarioValue.parse(kind: "Integer", json: .number(3_000_000_000)) == nil)
        #expect(ScenarioValue.parse(kind: "Boolean", json: .number(1)) == nil)
        #expect(ScenarioValue.parse(kind: "Coding", json: .object(["code": .number(1)])) == nil)
        #expect(ScenarioValue.parse(kind: "Quantity", json: .object(["value": .string("1")])) == nil)
        #expect(ScenarioValue.parse(kind: "Uri", json: .string("https://example.org")) == .uri("https://example.org"))
        #expect(ScenarioValue.parse(kind: "Url", json: .string("https://example.org")) == nil)
    }

    @Test
    func operatorsHoldWhenAnyAnswerSatisfiesThem() throws {
        let answers: [ScenarioValue] = [.integer(3), .integer(9)]
        #expect(ScenarioEvaluation.test(">", expected: .integer(5), answers: answers) == .met)
        #expect(ScenarioEvaluation.test("<", expected: .integer(5), answers: answers) == .met)
        #expect(ScenarioEvaluation.test(">=", expected: .integer(10), answers: answers) == .notMet)
        #expect(ScenarioEvaluation.test("<=", expected: .integer(3), answers: answers) == .met)
        #expect(ScenarioEvaluation.test("=", expected: .integer(9), answers: answers) == .met)
        // `!=` holds when no answer is equal: not with one equal answer among several, and always without an answer.
        #expect(ScenarioEvaluation.test("!=", expected: .integer(3), answers: answers) == .notMet)
        #expect(ScenarioEvaluation.test("!=", expected: .integer(5), answers: answers) == .met)
        #expect(ScenarioEvaluation.test("!=", expected: .integer(3), answers: [.integer(3)]) == .notMet)
        #expect(ScenarioEvaluation.test("!=", expected: .integer(3), answers: []) == .met)
        // An equality of unknown outcome leaves `!=` unknown unless another answer is known to be equal.
        let day = ScenarioValue.date(try #require(ScenarioTemporal.date("2020-01-01")))
        let month = ScenarioValue.date(try #require(ScenarioTemporal.date("2020-01")))
        let other = ScenarioValue.date(try #require(ScenarioTemporal.date("2019-05-05")))
        #expect(ScenarioEvaluation.test("!=", expected: day, answers: [month]) == .unknown)
        #expect(ScenarioEvaluation.test("!=", expected: day, answers: [month, day]) == .notMet)
        #expect(ScenarioEvaluation.test("!=", expected: day, answers: [month, other]) == .unknown)
        #expect(ScenarioEvaluation.test("exists", expected: .boolean(true), answers: answers) == .met)
        #expect(ScenarioEvaluation.test("exists", expected: .boolean(false), answers: []) == .met)
        let fahrenheit = ScenarioValue.quantity(.init(value: 101, comparator: nil, system: nil, code: "[degF]"))
        let celsius = ScenarioValue.quantity(.init(value: 38, comparator: nil, system: nil, code: "Cel"))
        #expect(ScenarioEvaluation.test(">=", expected: celsius, answers: [fahrenheit]) == .unknown)
        let warmer = ScenarioValue.quantity(.init(value: 39, comparator: nil, system: nil, code: "Cel"))
        #expect(ScenarioEvaluation.test(">=", expected: celsius, answers: [fahrenheit, warmer]) == .met)
    }

    @Test
    func unknownTruthOnlyDecidesWhenNothingElseDoes() {
        typealias Truth = ScenarioEvaluation.Truth
        #expect(Truth.any([.unknown, .met]) == .met)
        #expect(Truth.any([.unknown, .notMet]) == .unknown)
        #expect(Truth.any([Truth]()) == .notMet)
        #expect(Truth.all([.unknown, .notMet]) == .notMet)
        #expect(Truth.all([.unknown, .met]) == .unknown)
        #expect(Truth.all([Truth]()) == .met)
        #expect(Truth.not(.met) == .notMet && Truth.not(.notMet) == .met && Truth.not(.unknown) == .unknown)
    }
}
