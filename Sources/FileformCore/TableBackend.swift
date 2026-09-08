// SPDX-License-Identifier: Apache-2.0
import Foundation
import FileformDomain

struct TableData: Equatable, Sendable {
    let columns: [String]
    let rows: [[String]]
    var records: [[String: String]] { rows.map { Dictionary(uniqueKeysWithValues: zip(columns, $0)) } }
}

enum TableBackend {
    static let formats: [OutputFormat] = [.csv, .tsv, .json]
    static func recognizes(_ input: URL) -> Bool { ["csv", "tsv", "json"].contains(input.pathExtension.lowercased()) }
    static func read(_ input: URL, format: String? = nil) throws -> TableData {
        let identity = try FileSafety.identity(input)
        guard identity.bytes <= 8 * 1024 * 1024 else { throw FileformError(.resourceLimit, "The current table workflow accepts files up to 8 MB.") }
        let data = try Data(contentsOf: input)
        guard var text = String(data: data, encoding: .utf8) else { throw FileformError(.unsupported, "This table is not valid UTF-8 text. Save it as UTF-8 and try again.") }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let format = format ?? input.pathExtension.lowercased()
        if format == "json" { return try FlatJSONTableParser.parse(text) }
        guard format == "csv" || format == "tsv" else { throw FileformError(.unsupported, "Choose a CSV, TSV or flat JSON table.") }
        return try delimited(text, separator: format == "csv" ? "," : "\t")
    }

    static func inspect(_ input: URL, identity: FileIdentity) throws -> Inspection {
        let table = try read(input)
        return .init(input: input, identity: identity, family: .table, detectedType: input.pathExtension.lowercased(),
                     tableRows: table.rows.count, tableColumns: table.columns.count)
    }

    static func capabilities(for inspection: Inspection?) -> [Capability] {
        formats.filter { $0.rawValue != inspection?.detectedType }.map {
            .init(format: $0, goals: [.convert], engine: "tables", available: true,
                  limitation: "Flat tables only. CSV and TSV do not retain JSON value types.")
        }
    }

    static func delimited(_ text: String, separator: Unicode.Scalar) throws -> TableData {
        var records: [[String]] = [], row: [String] = [], cell = ""
        var quoted = false, closedQuote = false, skipLF = false, started = false
        func appendRow() throws {
            row.append(cell); cell = ""; records.append(row); row = []; started = false
            guard records.count <= 100_001 else { throw FileformError(.resourceLimit, "This table exceeds 100,000 data rows.") }
        }
        for character in text.unicodeScalars {
            try Task.checkCancellation()
            if skipLF { skipLF = false; if character == "\n" { continue } }
            if quoted {
                if character == "\"" { quoted = false; closedQuote = true }
                else { cell.unicodeScalars.append(character) }
                continue
            }
            if closedQuote {
                if character == "\"" { cell.append("\""); quoted = true; closedQuote = false; continue }
                guard character == separator || character == "\r" || character == "\n" else {
                    throw FileformError(.unsupported, "Unexpected text after a quoted table cell. Check the delimiter and quote characters.")
                }
                closedQuote = false
            }
            if character == "\"" {
                guard cell.isEmpty else { throw FileformError(.unsupported, "A quote inside an unquoted table cell is invalid. Quote the whole cell and double embedded quotes.") }
                quoted = true; started = true
            } else if character == separator {
                row.append(cell); cell = ""; started = true
                guard row.count < 1000 else { throw FileformError(.resourceLimit, "This table exceeds 1,000 columns.") }
            } else if character == "\n" || character == "\r" {
                try appendRow(); skipLF = character == "\r"
            } else { cell.unicodeScalars.append(character); started = true }
        }
        guard !quoted else { throw FileformError(.unsupported, "A quoted table cell was never closed.") }
        if started || !row.isEmpty || !cell.isEmpty { try appendRow() }
        guard let columns = records.first, !columns.isEmpty,
              columns.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(columns).count == columns.count else {
            throw FileformError(.unsupported, "The first row must contain a unique, non-empty name for each column.")
        }
        guard records.dropFirst().allSatisfy({ $0.count == columns.count }) else {
            throw FileformError(.unsupported, "Rows have different column counts. Check the table delimiter and quoted cells.")
        }
        return .init(columns: columns, rows: Array(records.dropFirst()))
    }

    static func encode(_ table: TableData, format: OutputFormat) throws -> Data {
        if format == .json {
            return try JSONSerialization.data(withJSONObject: table.records, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        let separator = format == .csv ? "," : "\t"
        func escaped(_ cell: String) -> String {
            if cell.contains(separator) || cell.contains("\"") || cell.contains("\r") || cell.contains("\n") {
                return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return cell
        }
        let lines = ([table.columns] + table.rows).map { $0.map(escaped).joined(separator: separator) }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

/// Preserves JSON numeric lexemes, including integers beyond Double's exact
/// range. Nested values are rejected rather than silently flattened or lost.
private struct FlatJSONTableParser {
    let bytes: [UInt8]
    var index = 0
    static func parse(_ text: String) throws -> TableData {
        var parser = Self(bytes: Array(text.utf8))
        return try parser.table()
    }
    mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) -> Bool {
        whitespace(); if index < bytes.count && bytes[index] == byte { index += 1; return true }; return false
    }
    mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw FileformError(.unsupported, "JSON tables must be an array of flat objects with matching columns.") }
    }
    mutating func string() throws -> String {
        whitespace(); let start = index; try require(34)
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 {
                index += 1
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                    throw FileformError(.unsupported, "Invalid JSON string escape or encoding.")
                }
                return value
            }
            index += 1
        }
        throw FileformError(.unsupported, "A JSON string was not closed.")
    }
    mutating func scalar() throws -> String {
        whitespace()
        if index < bytes.count && bytes[index] == 34 { return try string() }
        let start = index
        while index < bytes.count && ![9, 10, 13, 32, 44, 125, 93].contains(bytes[index]) { index += 1 }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        if token == "null" { return "" }
        if token == "true" || token == "false" { return token }
        if token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil { return token }
        throw FileformError(.unsupported, "JSON table cells must be strings, numbers, booleans or null. Nested objects and arrays need an explicit flattening workflow.")
    }
    mutating func object() throws -> (columns: [String], values: [String]) {
        try require(123)
        var columns: [String] = [], values: [String] = []
        if consume(125) { return (columns, values) }
        while true {
            let key = try string()
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !columns.contains(key), columns.count < 1000 else {
                throw FileformError(.unsupported, "JSON table column names must be unique and non-empty; at most 1,000 columns are supported.")
            }
            columns.append(key); try require(58); values.append(try scalar())
            if consume(125) { break }; try require(44)
        }
        return (columns, values)
    }
    mutating func table() throws -> TableData {
        try require(91)
        guard !consume(93) else { throw FileformError(.unsupported, "An empty JSON array has no column names to export.") }
        let first = try object()
        guard !first.columns.isEmpty else { throw FileformError(.unsupported, "JSON table objects need at least one column.") }
        var rows = [first.values]
        while !consume(93) {
            try Task.checkCancellation(); try require(44)
            let next = try object()
            guard Set(next.columns) == Set(first.columns) else { throw FileformError(.unsupported, "JSON objects have different columns. Use the same keys in every row.") }
            let mapping = Dictionary(uniqueKeysWithValues: zip(next.columns, next.values))
            rows.append(first.columns.map { mapping[$0]! })
            guard rows.count <= 100_000 else { throw FileformError(.resourceLimit, "This JSON table exceeds 100,000 rows.") }
        }
        whitespace()
        guard index == bytes.count else { throw FileformError(.unsupported, "Unexpected content after the JSON table.") }
        return .init(columns: first.columns, rows: rows)
    }
}
