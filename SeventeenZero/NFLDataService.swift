import Foundation

final class NFLDataService: @unchecked Sendable {
    static let shared = NFLDataService()

    private let lock = NSLock()
    private var rosterMemory: [Int: [[String: String]]] = [:]
    private var statsMemory: [Int: [[String: String]]] = [:]
    private let session: URLSession
    private let rawDirectory: URL
    private let processedDirectory: URL

    private let positionGroups: [String: Set<String>] = [
        "QB": ["QB"],
        "RB": ["RB", "FB", "HB"],
        "WR": ["WR"],
        "TE": ["TE"],
        "OL": ["OL", "C", "G", "OG", "LG", "RG", "T", "OT", "LT", "RT"],
        "F7": ["DL", "DE", "DT", "NT", "EDGE", "ED", "LB", "ILB", "MLB", "OLB"],
        "SEC": ["DB", "CB", "S", "FS", "SS", "SAF"]
    ]

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeventeenZero", isDirectory: true)
        rawDirectory = base.appendingPathComponent("raw", isDirectory: true)
        processedDirectory = base.appendingPathComponent("processed_v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: processedDirectory, withIntermediateDirectories: true)
    }

    func playersJSON(franchise: String, start: Int, end: Int) async throws -> Data {
        let key = "\(franchise)_\(start)_\(end).json"
        let processed = processedDirectory.appendingPathComponent(key)
        if let data = try? Data(contentsOf: processed), data.count > 100 {
            return data
        }

        let result = try await buildPlayers(franchise: franchise, start: start, end: end)
        let data = try JSONSerialization.data(withJSONObject: ["ok": true].merging(result) { _, new in new })
        try? data.write(to: processed, options: .atomic)
        return data
    }

    func preload(_ rolls: [[String: Any]]) {
        for item in rolls.prefix(7) {
            guard let franchise = item["franchise"] as? String,
                  let start = item["start"] as? Int,
                  let end = item["end"] as? Int else { continue }
            Task.detached(priority: .utility) {
                _ = try? await self.playersJSON(franchise: franchise, start: start, end: end)
            }
        }
    }

    private func buildPlayers(franchise: String, start: Int, end: Int) async throws -> [String: Any] {
        let years = Array(start...end).filter { !(franchise == "CLE" && (1996...1998).contains($0)) }

        var rosterByYear: [Int: [[String: String]]] = [:]
        var rosterFailed: [[String: Any]] = []

        await withTaskGroup(of: (Int, Result<[[String: String]], Error>).self) { group in
            for year in years {
                group.addTask {
                    do { return (year, .success(try await self.loadRoster(year))) }
                    catch { return (year, .failure(error)) }
                }
            }
            for await (year, result) in group {
                switch result {
                case .success(let rows): rosterByYear[year] = rows
                case .failure(let error): rosterFailed.append(["year": year, "error": error.localizedDescription])
                }
            }
        }

        guard !rosterByYear.isEmpty else {
            throw NSError(domain: "SeventeenZero", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Roster source is temporarily unavailable."])
        }

        var players: [String: PlayerAccumulator] = [:]
        for (year, rows) in rosterByYear {
            let codes = teamCodes(franchise, year: year)
            for row in rows {
                let team = (row["team"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard codes.contains(team) else { continue }
                let name = first(row, ["full_name", "football_name"])
                guard !name.isEmpty else { continue }

                var positions = Set<String>()
                var groups = Set<String>()
                for key in ["position", "depth_chart_position", "ngs_position"] {
                    let p = (row[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    guard !p.isEmpty else { continue }
                    positions.insert(p)
                    if let g = groupForPosition(p) { groups.insert(g) }
                }
                guard !groups.isEmpty else { continue }

                let id = first(row, ["gsis_id", "pfr_id", "espn_id"])
                let pid = id.isEmpty ? "\(name)|\(positions.sorted().joined(separator: "/"))" : id
                let player = players[pid] ?? PlayerAccumulator(id: pid, name: name)
                player.positions.formUnion(positions)
                player.groups.formUnion(groups)
                player.seasons.insert(year)
                if player.headshot.isEmpty {
                    player.headshot = first(row, ["headshot", "headshot_url", "player_headshot", "headshot_url_https", "player_image"])
                }
                players[pid] = player
            }
        }

        var statsByYear: [Int: [[String: String]]] = [:]
        var statsFailed: [[String: Any]] = []
        let statsYears = years.filter { $0 >= 1999 }

        await withTaskGroup(of: (Int, Result<[[String: String]], Error>).self) { group in
            for year in statsYears {
                group.addTask {
                    do { return (year, .success(try await self.loadStats(year))) }
                    catch { return (year, .failure(error)) }
                }
            }
            for await (year, result) in group {
                switch result {
                case .success(let rows): statsByYear[year] = rows
                case .failure(let error): statsFailed.append(["year": year, "error": error.localizedDescription])
                }
            }
        }

        var indexes: [Int: ([String: [String: String]], [String: [String: String]])] = [:]
        for (year, rows) in statsByYear {
            let codes = teamCodes(franchise, year: year)
            var ids: [String: [String: String]] = [:]
            var names: [String: [String: String]] = [:]
            for row in rows {
                let team = first(row, ["recent_team", "team"]).uppercased()
                if !team.isEmpty && !codes.contains(team) { continue }
                let pid = first(row, ["player_id", "gsis_id"])
                let name = first(row, ["player_display_name", "player_name", "full_name"])
                if !pid.isEmpty { ids[pid] = row }
                if !name.isEmpty { names[name.lowercased()] = row }
            }
            indexes[year] = (ids, names)
        }

        for player in players.values {
            for year in player.seasons.sorted() {
                guard let idx = indexes[year] else { continue }
                let row = idx.0[player.id] ?? idx.1[player.name.lowercased()]
                guard let row else { continue }
                for group in player.groups {
                    let score = seasonScore(group, row: row)
                    if let old = player.best[group], old.score >= score { continue }
                    player.best[group] = BestSeason(year: year, score: score, stats: statLine(group, row: row))
                }
            }
        }

        var output: [[String: Any]] = []
        for player in players.values {
            let groups = player.groups.sorted()
            let ranked = groups.compactMap { g -> (Double, String)? in
                guard let best = player.best[g] else { return nil }
                return (best.score, g)
            }
            let bestGroup = ranked.max(by: { $0.0 < $1.0 })?.1 ?? groups.first
            let best = bestGroup.flatMap { player.best[$0] }
            let sortScore = best?.score ?? (-100000.0 + Double(player.seasons.count))

            output.append([
                "id": player.id,
                "name": player.name,
                "positions": player.positions.sorted(),
                "groups": groups,
                "seasons": player.seasons.sorted(),
                "best_group": bestGroup as Any,
                "best_season": best?.year as Any,
                "stats": best?.stats ?? [],
                "has_stats": best != nil && !(best?.stats.isEmpty ?? true),
                "sort_score": sortScore,
                "headshot": player.headshot
            ])
        }

        output.sort {
            let ah = ($0["has_stats"] as? Bool) ?? false
            let bh = ($1["has_stats"] as? Bool) ?? false
            if ah != bh { return ah && !bh }
            let ascore = ($0["sort_score"] as? Double) ?? -999999
            let bscore = ($1["sort_score"] as? Double) ?? -999999
            if ascore != bscore { return ascore > bscore }
            return (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "")
        }

        return [
            "players": output,
            "loaded_years": rosterByYear.keys.sorted(),
            "roster_failed_years": rosterFailed.sorted { (($0["year"] as? Int) ?? 0) < (($1["year"] as? Int) ?? 0) },
            "stats_failed_years": statsFailed.sorted { (($0["year"] as? Int) ?? 0) < (($1["year"] as? Int) ?? 0) },
            "stats_start_year": 1999,
            "cache_hit": false
        ]
    }

    private func loadRoster(_ year: Int) async throws -> [[String: String]] {
        lock.lock()
        if let rows = rosterMemory[year] { lock.unlock(); return rows }
        lock.unlock()

        let url = "https://github.com/nflverse/nflverse-data/releases/download/rosters/roster_\(year).csv"
        let text = try await fetchText(url: url, filename: "roster_\(year).csv") { $0.prefix(3500).contains("full_name") }
        let rows = CSVParser.parse(text)
        lock.lock(); rosterMemory[year] = rows; lock.unlock()
        return rows
    }

    private func loadStats(_ year: Int) async throws -> [[String: String]] {
        if year < 1999 { return [] }
        lock.lock()
        if let rows = statsMemory[year] { lock.unlock(); return rows }
        lock.unlock()

        let url = "https://github.com/nflverse/nflverse-data/releases/download/stats_player/stats_player_reg_\(year).csv"
        let text = try await fetchText(url: url, filename: "stats_player_reg_\(year).csv") {
            let head = $0.prefix(3500)
            return head.contains("player_id") || head.contains("player_display_name")
        }
        let rows = CSVParser.parse(text)
        lock.lock(); statsMemory[year] = rows; lock.unlock()
        return rows
    }

    private func fetchText(url: String, filename: String, validator: (String) -> Bool) async throws -> String {
        let file = rawDirectory.appendingPathComponent(filename)
        if let text = try? String(contentsOf: file, encoding: .utf8), validator(text) { return text }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                guard let remote = URL(string: url) else { throw URLError(.badURL) }
                var request = URLRequest(url: remote)
                request.setValue("Mozilla/5.0 SeventeenZero-iOS", forHTTPHeaderField: "User-Agent")
                request.setValue("text/csv,text/plain,*/*", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard let text = String(data: data, encoding: .utf8), validator(text) else {
                    throw URLError(.cannotDecodeContentData)
                }
                try? text.write(to: file, atomically: true, encoding: .utf8)
                return text
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (1 << attempt)))
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func first(_ row: [String: String], _ keys: [String]) -> String {
        for key in keys {
            let value = (row[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private func groupForPosition(_ p: String) -> String? {
        positionGroups.first(where: { $0.value.contains(p) })?.key
    }

    private func teamCodes(_ franchise: String, year: Int) -> Set<String> {
        let base: [String: Set<String>] = [
            "ARI":["ARI","PHX"],"ATL":["ATL"],"BAL":["BAL"],"BUF":["BUF"],"CAR":["CAR"],
            "CHI":["CHI"],"CIN":["CIN"],"CLE":["CLE"],"DAL":["DAL"],"DEN":["DEN"],
            "DET":["DET"],"GB":["GB"],"HOU":["HOU"],"IND":["IND"],"JAX":["JAX","JAC"],
            "KC":["KC"],"LV":["LV","OAK"],"LAC":["LAC","SD"],"LAR":["LAR","LA"],
            "MIA":["MIA"],"MIN":["MIN"],"NE":["NE"],"NO":["NO"],"NYG":["NYG"],
            "NYJ":["NYJ"],"PHI":["PHI"],"PIT":["PIT"],"SF":["SF"],"SEA":["SEA"],
            "TB":["TB"],"TEN":["TEN"],"WAS":["WAS","WSH"]
        ]
        var codes = base[franchise] ?? [franchise]
        if franchise == "ARI" && year <= 1987 { codes.insert("STL") }
        if franchise == "IND" && year <= 1983 { codes.insert("BAL") }
        if franchise == "TEN" && year <= 1996 { codes.insert("HOU") }
        if franchise == "LAR" && (1995...2015).contains(year) { codes.insert("STL") }
        return codes
    }

    private func n(_ row: [String: String], _ keys: [String]) -> Double {
        for key in keys {
            if let value = row[key], let d = Double(value) { return d }
        }
        return 0
    }

    private func seasonScore(_ group: String, row: [String: String]) -> Double {
        let passYd=n(row,["passing_yards"]), passTD=n(row,["passing_tds","passing_touchdowns"])
        let ints=n(row,["interceptions","passing_interceptions"]), rushYd=n(row,["rushing_yards"])
        let rushTD=n(row,["rushing_tds","rushing_touchdowns"]), rec=n(row,["receptions"])
        let recYd=n(row,["receiving_yards"]), recTD=n(row,["receiving_tds","receiving_touchdowns"])
        let tackles=n(row,["tackles","tackles_defense","def_tackles"])
        let assists=n(row,["tackles_with_assists","tackle_assists","def_tackle_assists"])
        let sacks=n(row,["sacks","sacks_defense","def_sacks"])
        let dint=n(row,["interceptions_defense","def_interceptions"])
        let forced=n(row,["fumbles_forced","forced_fumbles","def_fumbles_forced"])
        let games=n(row,["games"])
        switch group {
        case "QB": return passYd + 24*passTD - 18*ints + 0.45*rushYd + 12*rushTD
        case "RB": return rushYd + 0.8*recYd + 3*rec + 18*(rushTD+recTD)
        case "WR", "TE": return recYd + 3*rec + 20*recTD + 0.25*rushYd + 10*rushTD
        case "F7": return tackles + 0.5*assists + 13*sacks + 15*dint + 10*forced
        case "SEC": return tackles + 0.4*assists + 22*dint + 8*sacks + 10*forced
        case "OL": return games
        default: return 0
        }
    }

    private func compact(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.0001 { return String(Int(value.rounded())) }
        return String(format: "%.1f", value)
    }

    private func statLine(_ group: String, row: [String: String]) -> [[String: String]] {
        var out: [[String: String]] = []
        func add(_ label: String, _ value: Double, zero: Bool = false) {
            if value != 0 || zero { out.append(["label": label, "value": compact(value)]) }
        }
        switch group {
        case "QB":
            add("PASS YDS",n(row,["passing_yards"])); add("PASS TD",n(row,["passing_tds","passing_touchdowns"])); add("INT",n(row,["interceptions","passing_interceptions"]),zero:true)
            let ry=n(row,["rushing_yards"]), rt=n(row,["rushing_tds","rushing_touchdowns"]); if ry != 0 || rt != 0 { add("RUSH YDS",ry); add("RUSH TD",rt) }
        case "RB":
            add("RUSH YDS",n(row,["rushing_yards"])); add("RUSH TD",n(row,["rushing_tds","rushing_touchdowns"])); let r=n(row,["receptions"]), y=n(row,["receiving_yards"]), t=n(row,["receiving_tds","receiving_touchdowns"]); if r != 0 || y != 0 || t != 0 { add("REC",r); add("REC YDS",y); add("REC TD",t) }
        case "WR", "TE":
            add("REC",n(row,["receptions"])); add("REC YDS",n(row,["receiving_yards"])); add("REC TD",n(row,["receiving_tds","receiving_touchdowns"]))
        case "F7":
            add("TACKLES",n(row,["tackles","tackles_defense","def_tackles"])); add("SACKS",n(row,["sacks","sacks_defense","def_sacks"])); let i=n(row,["interceptions_defense","def_interceptions"]), ff=n(row,["fumbles_forced","forced_fumbles","def_fumbles_forced"]); if i != 0 { add("INT",i) }; if ff != 0 { add("FF",ff) }
        case "SEC":
            add("TACKLES",n(row,["tackles","tackles_defense","def_tackles"])); add("INT",n(row,["interceptions_defense","def_interceptions"])); let sk=n(row,["sacks","sacks_defense","def_sacks"]), ff=n(row,["fumbles_forced","forced_fumbles","def_fumbles_forced"]); if sk != 0 { add("SACKS",sk) }; if ff != 0 { add("FF",ff) }
        case "OL": add("G",n(row,["games"]))
        default: break
        }
        if out.isEmpty { let games=n(row,["games"]); if games != 0 { add("G",games) } }
        return Array(out.prefix(5))
    }
}

private final class PlayerAccumulator {
    let id: String
    let name: String
    var positions = Set<String>()
    var groups = Set<String>()
    var seasons = Set<Int>()
    var headshot = ""
    var best: [String: BestSeason] = [:]
    init(id: String, name: String) { self.id=id; self.name=name }
}

private struct BestSeason {
    let year: Int
    let score: Double
    let stats: [[String: String]]
}
