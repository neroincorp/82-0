import Foundation

enum CSVParser {
    static func parse(_ text: String) -> [[String: String]] {
        let rows = parseRows(text)
        guard let header = rows.first, !header.isEmpty else { return [] }
        var output: [[String: String]] = []
        output.reserveCapacity(max(0, rows.count - 1))

        for row in rows.dropFirst() {
            if row.allSatisfy({ $0.isEmpty }) { continue }
            var item: [String: String] = [:]
            for i in 0..<min(header.count, row.count) {
                item[header[i]] = row[i]
            }
            output.append(item)
        }
        return output
    }

    private static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var i = text.startIndex

        func pushField() {
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }
        func pushRow() {
            pushField()
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        while i < text.endIndex {
            let ch = text[i]
            if quoted {
                if ch == "\"" {
                    let n = text.index(after: i)
                    if n < text.endIndex && text[n] == "\"" {
                        field.append("\"")
                        i = n
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                if ch == "\"" {
                    quoted = true
                } else if ch == "," {
                    pushField()
                } else if ch == "\n" {
                    pushRow()
                } else if ch != "\r" {
                    field.append(ch)
                }
            }
            i = text.index(after: i)
        }

        if !field.isEmpty || !row.isEmpty {
            pushRow()
        }
        return rows
    }
}
