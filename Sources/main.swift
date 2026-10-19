// Postcard — a new place on your desktop every day.
// Applies a daily photo of a place as the macOS desktop wallpaper.
//
// Runs as a launchd LaunchAgent in --watch mode: checks for a new photo at login, hourly and on wake,
// and re-applies the image whenever you switch to a Space or connect a display (e.g. Sidecar)
// that isn't showing it yet. Once today's image is applied, no network requests are made
// until the next day. Every update is idempotent.

import AppKit
import Foundation

// MARK: - Constants

let toolVersion = "1.4.0"
let defaultsDomain = "com.durgesh.postcard"
let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/Postcard", isDirectory: true)
let imagesDir = supportDir.appendingPathComponent("images", isDirectory: true)
let stateFile = supportDir.appendingPathComponent("state.json")
let infoFile = supportDir.appendingPathComponent("images.json")
let lockFile = supportDir.appendingPathComponent(".lock")
let logDir = home.appendingPathComponent("Library/Logs/Postcard", isDirectory: true)
let logFile = logDir.appendingPathComponent("postcard.log")
let maxLogBytes: UInt64 = 1_000_000
let feedHost = "https://www.bing.com"   // where the daily photo and its details come from

// MARK: - Logging (file with 1 MB rotation, mirrored to stderr when run from a terminal)

final class Logger {
    static let shared = Logger()
    let interactive = isatty(STDERR_FILENO) == 1
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f
    }()

    func log(_ message: String, _ level: String = "INFO") {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        if interactive { FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8)) }
        guard let data = line.data(using: .utf8) else { return }
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        rotateIfNeeded()
        if !fm.fileExists(atPath: logFile.path) { fm.createFile(atPath: logFile.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? fm.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? UInt64, size > maxLogBytes else { return }
        let old = logFile.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logFile, to: old)
    }
}

func log(_ m: String) { Logger.shared.log(m) }
func warn(_ m: String) { Logger.shared.log(m, "WARN") }
func fail(_ m: String) { Logger.shared.log(m, "ERROR") }

// MARK: - Models

struct FeedResponse: Decodable { let images: [DailyImage] }

struct DailyImage: Decodable {
    let startdate: String
    let url: String
    let urlbase: String
    let copyright: String?
    let copyrightlink: String?
    let title: String?
    let hsh: String?
}

/// What we know about a downloaded image, keyed by file name in images.json.
struct ImageInfo: Codable {
    var startdate: String
    var title: String?
    var copyright: String?
    var link: String?
    var about: String? = nil       // a paragraph about the photo
    var place: String? = nil       // e.g. "Grand Canal, Venice, Italy"
    var latitude: Double? = nil
    var longitude: Double? = nil
    var caption: String? = nil     // e.g. "Grand Canal in Venice, Italy"

    /// What's in the photo: the caption, or "Grand Canal in Venice, Italy (© …)" without the credit.
    var subject: String {
        if let c = caption, !c.isEmpty { return c }
        guard let c = copyright else { return title ?? startdate }
        if let r = c.range(of: " (©", options: .backwards) { return String(c[..<r.lowerBound]) }
        return c
    }
    /// "© Juan Romero/Cavan Images"
    var credit: String? {
        guard let c = copyright, let r = c.range(of: "(©", options: .backwards) else { return nil }
        return String(c[r.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    }
    /// The headline, e.g. "The road that runs on water" (some markets just send "Info").
    var headline: String? {
        guard let t = title, !t.isEmpty, t != "Info" else { return nil }
        return t
    }
}

struct State: Codable {
    var urlbase: String
    var startdate: String
    var file: String
    var title: String?
    var copyright: String?
    var market: String?
    var resolution: String
    var appliedAt: Date
    var selected: String? = nil    // image picked with --prev/--next; cleared by the next new photo

    /// The image that should be on the desktop.
    var shownFile: String { selected ?? file }
}

enum BWError: Error, CustomStringConvertible {
    case http(Int, URL)
    case badResponse(URL)
    case noImages
    case invalidImage
    case noScreens
    case locked

    var description: String {
        switch self {
        case .http(let code, let url): return "HTTP \(code) from \(url.absoluteString)"
        case .badResponse(let url): return "No usable response from \(url.absoluteString)"
        case .noImages: return "The photo feed returned no images"
        case .invalidImage: return "Downloaded data is not a valid image"
        case .noScreens: return "No screens available (display asleep or not logged in)"
        case .locked: return "Another postcard run is in progress"
        }
    }
}

// MARK: - Options (CLI flags override `defaults write com.durgesh.postcard ...`)

struct Options {
    var force = false
    var status = false
    var market: String? = nil      // nil = chosen by your location
    var resolution = "UHD"         // UHD (3840x2160) or e.g. 1920x1080
    var keep = 30                  // images kept on disk
    var watch = false              // stay resident (LaunchAgent mode)
    var step: Int? = nil           // --prev (-1), --next (+1), --today (0)
    var interval: TimeInterval = 3600
}

func usage() -> String {
    """
    Postcard \(toolVersion) — a new place on your desktop every day

    Usage: postcard [options]
      (no options)        Fetch today's image if new and apply it to all screens
      -f, --force         Re-download/re-apply even if already up to date
      -s, --status        Show current image, screens and paths
      -p, --prev          Show the previous day's image (up to the images kept on disk)
      -n, --next          Show the next day's image
      -t, --today         Go back to today's image
      -m, --mkt CODE      Region, e.g. en-GB, en-US, en-IN (default: auto by IP)
      -r, --resolution R  UHD (default) or 1920x1080
      -k, --keep N        Number of images to keep on disk (default 30)
      -w, --watch         Stay running: update hourly and on wake, and apply to new
                          Spaces and newly connected displays (used by the LaunchAgent)
      -i, --interval S    Seconds between checks in --watch mode (default 3600)
      -h, --help          Show this help
      -v, --version       Show version

    Persistent settings:
      defaults write \(defaultsDomain) market en-GB
      defaults write \(defaultsDomain) resolution 1920x1080
      defaults write \(defaultsDomain) keep -int 60
      defaults delete \(defaultsDomain) market
    """
}

func parseOptions() -> Options {
    var o = Options()
    if let d = UserDefaults(suiteName: defaultsDomain) {
        if let m = d.string(forKey: "market"), !m.isEmpty { o.market = m }
        if let r = d.string(forKey: "resolution"), !r.isEmpty { o.resolution = r }
        let k = d.integer(forKey: "keep"); if k > 0 { o.keep = k }
    }
    var args = Array(CommandLine.arguments.dropFirst())
    func value(_ flag: String) -> String {
        guard !args.isEmpty else { print("Missing value for \(flag)\n\n\(usage())"); exit(2) }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-f", "--force": o.force = true
        case "-s", "--status": o.status = true
        case "-p", "--prev", "--previous": o.step = -1
        case "-n", "--next": o.step = 1
        case "-t", "--today": o.step = 0
        case "-m", "--mkt", "--market": o.market = value(a)
        case "-r", "--resolution": o.resolution = value(a)
        case "-k", "--keep":
            guard let n = Int(value(a)), n > 0 else { print("--keep needs a positive integer"); exit(2) }
            o.keep = n
        case "-w", "--watch": o.watch = true
        case "-i", "--interval":
            guard let n = TimeInterval(value(a)), n >= 60 else { print("--interval needs at least 60 seconds"); exit(2) }
            o.interval = n
        case "-h", "--help": print(usage()); exit(0)
        case "-v", "--version": print(toolVersion); exit(0)
        default: print("Unknown option: \(a)\n\n\(usage())"); exit(2)
        }
    }
    return o
}

// MARK: - HTTP (synchronous; waits for connectivity after wake, retries transient failures)

final class Box<T> { var value: T?; init() {} }

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.waitsForConnectivity = true            // Wi-Fi is often not up yet right after wake
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 120
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.httpAdditionalHeaders = ["User-Agent": "Postcard/\(toolVersion) (macOS)"]
    return URLSession(configuration: c)
}()

func get(_ url: URL) throws -> (Data, HTTPURLResponse) {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<Result<(Data, HTTPURLResponse), Error>>()
    session.dataTask(with: url) { data, resp, err in
        if let err = err { box.value = .failure(err) }
        else if let http = resp as? HTTPURLResponse, let data = data { box.value = .success((data, http)) }
        else { box.value = .failure(BWError.badResponse(url)) }
        sem.signal()
    }.resume()
    sem.wait()
    return try box.value!.get()
}

/// Retries network errors, 429 and 5xx with exponential backoff + jitter. 4xx returns immediately.
func getWithRetry(_ url: URL, attempts: Int = 4) throws -> Data {
    var lastError: Error = BWError.badResponse(url)
    for attempt in 1...attempts {
        do {
            let (data, resp) = try get(url)
            if resp.statusCode == 200 { return data }
            lastError = BWError.http(resp.statusCode, url)
            if resp.statusCode != 429 && resp.statusCode < 500 { throw lastError }
        } catch let e as BWError {
            if case .http(let code, _) = e, code != 429, code < 500 { throw e }
            lastError = e
        } catch {
            lastError = error
        }
        if attempt < attempts {
            let delay = 5.0 * pow(3.0, Double(attempt - 1)) * Double.random(in: 0.8...1.2) // ~5s, 15s, 45s
            warn("Attempt \(attempt)/\(attempts) failed (\(lastError)); retrying in \(Int(delay))s")
            Thread.sleep(forTimeInterval: delay)
        }
    }
    throw lastError
}

func absoluteURL(_ s: String) -> URL? {
    s.hasPrefix("http") ? URL(string: s) : URL(string: feedHost + s)
}

// MARK: - Photo feed

/// Newest first. The feed serves at most the last 8 days.
func fetchMetadata(market: String?, count: Int = 8) throws -> [DailyImage] {
    var c = URLComponents(string: "\(feedHost)/HPImageArchive.aspx")!
    c.queryItems = [
        URLQueryItem(name: "format", value: "js"),
        URLQueryItem(name: "idx", value: "0"),
        URLQueryItem(name: "n", value: String(count)),
    ]
    if let m = market { c.queryItems?.append(URLQueryItem(name: "mkt", value: m)) }
    let data = try getWithRetry(c.url!)
    let resp = try JSONDecoder().decode(FeedResponse.self, from: data)
    guard !resp.images.isEmpty else { throw BWError.noImages }
    return resp.images
}

func looksLikeImage(_ data: Data) -> Bool {
    guard data.count > 20_000 else { return false }
    let b = [UInt8](data.prefix(4))
    let jpeg = b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF
    let png = b == [0x89, 0x50, 0x4E, 0x47]
    return (jpeg || png) && NSImage(data: data) != nil
}

/// Tries the requested resolution first, then the feed's default URL (1920x1080).
func downloadImage(_ img: DailyImage, resolution: String) throws -> Data {
    var candidates: [URL] = []
    if let u = absoluteURL("\(img.urlbase)_\(resolution).jpg") { candidates.append(u) }
    if let u = absoluteURL(img.url) { candidates.append(u) }
    for url in candidates {
        do {
            let data = try getWithRetry(url)
            if looksLikeImage(data) { return data }
            warn("Not a valid image: \(url.absoluteString)")
        } catch {
            warn("Download failed for \(url.absoluteString): \(error)")
        }
    }
    throw BWError.invalidImage
}

/// "/th?id=OHR.Foo_EN-GB123" -> "20261019_OHR.Foo_EN-GB123_UHD.jpg" (unique per image, never reused,
/// so macOS can't serve a cached wallpaper for an unchanged path).
func fileName(for img: DailyImage, resolution: String) -> String {
    var id = img.urlbase
    if let r = id.range(of: "id=") { id = String(id[r.upperBound...]) }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    id = String(String.UnicodeScalarView(id.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
    if id.isEmpty { id = img.hsh ?? "image" }
    let res = resolution.replacingOccurrences(of: "/", with: "_")
    return "\(img.startdate)_\(id.prefix(120))_\(res).jpg"
}

// MARK: - State

func loadState() -> State? {
    guard let data = try? Data(contentsOf: stateFile) else { return nil }
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    return try? d.decode(State.self, from: data)
}

func saveState(_ s: State) throws {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try e.encode(s).write(to: stateFile, options: .atomic)
}

/// The homepage feed (/hp/api/model): adds the description and the map location.
struct HomepageModel: Decodable {
    struct Media: Decodable { let Ssd: String?; let ImageContent: Content? }
    struct Content: Decodable {
        let Description: String?; let Headline: String?; let Title: String?
        let MapLink: Map?; let Image: Img?
    }
    struct Map: Decodable { let Url: String? }
    struct Img: Decodable { let Url: String? }
    let MediaContents: [Media]?
}

/// "/th?id=OHR.VeniceSunrise_ROW9643744702..." -> "OHR.VeniceSunrise" (same across markets).
func imageKey(_ url: String) -> String? {
    guard let r = url.range(of: "id=") else { return nil }
    return url[r.upperBound...].split(separator: "_").first.map(String.init)
}

/// The map URL carries "pp=45.435337,12.32783;S9;Grand Canal, Venice, Italy".
func parseLocation(_ mapURL: String) -> (lat: Double, lon: Double, name: String)? {
    guard let c = URLComponents(string: mapURL.hasPrefix("//") ? "https:" + mapURL : mapURL),
          let pp = c.queryItems?.first(where: { $0.name == "pp" })?.value else { return nil }
    let parts = pp.components(separatedBy: ";")
    let ll = parts[0].split(separator: ",").compactMap { Double($0) }
    guard ll.count == 2 else { return nil }
    return (ll[0], ll[1], parts.count >= 3 ? parts[2...].joined(separator: ";") : "")
}

/// Fills in description/location. Your market first; en-US as well, since some markets
/// (including auto) don't include a map location. Failures just leave the fields empty.
func enrich(_ info: inout [String: ImageInfo], images: [DailyImage], resolution: String, market: String?) {
    var feeds = [market]
    if market != "en-US" { feeds.append("en-US") }
    for mkt in feeds {
        var c = URLComponents(string: "\(feedHost)/hp/api/model")!
        if let m = mkt { c.queryItems = [URLQueryItem(name: "mkt", value: m)] }
        guard let data = try? getWithRetry(c.url!, attempts: 2),
              let model = try? JSONDecoder().decode(HomepageModel.self, from: data) else { continue }
        for media in model.MediaContents ?? [] {
            guard let content = media.ImageContent,
                  let key = content.Image?.Url.flatMap(imageKey),
                  let img = images.first(where: { imageKey($0.urlbase) == key }) else { continue }
            let file = fileName(for: img, resolution: resolution)
            guard var i = info[file] else { continue }
            if i.about == nil, let d = content.Description, !d.isEmpty { i.about = d }
            if i.caption == nil, let t = content.Title, !t.isEmpty { i.caption = t }
            if i.headline == nil, let h = content.Headline, !h.isEmpty, h != "Info" { i.title = h }
            if i.latitude == nil, let loc = content.MapLink?.Url.flatMap(parseLocation) {
                i.latitude = loc.lat; i.longitude = loc.lon
                i.place = loc.name.isEmpty ? nil : loc.name
            }
            info[file] = i
        }
    }
}

func loadInfo() -> [String: ImageInfo] {
    guard let data = try? Data(contentsOf: infoFile) else { return [:] }
    return (try? JSONDecoder().decode([String: ImageInfo].self, from: data)) ?? [:]
}

/// Records title/credit for every listed image that is on disk, and forgets pruned ones.
func saveInfo(for images: [DailyImage], resolution: String, market: String?) {
    var info = loadInfo()
    for img in images {
        let file = fileName(for: img, resolution: resolution)
        if info[file]?.about != nil { continue } // already complete
        info[file] = ImageInfo(startdate: img.startdate, title: img.title, copyright: img.copyright,
                               link: img.copyrightlink.flatMap { absoluteURL($0)?.absoluteString })
    }
    let onDisk = Set(localImages())
    info = info.filter { onDisk.contains($0.key) }
    if info.values.contains(where: { $0.about == nil }) {
        enrich(&info, images: images, resolution: resolution, market: market)
    }
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? e.encode(info).write(to: infoFile, options: .atomic)
}

func info(for file: String) -> ImageInfo {
    loadInfo()[file] ?? ImageInfo(startdate: String(file.prefix(8)), title: nil, copyright: nil, link: nil)
}

/// "20261019" -> "19 Oct 2026" in the user's locale.
func prettyDate(_ stamp: String) -> String {
    let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX"); p.dateFormat = "yyyyMMdd"
    guard let d = p.date(from: stamp) else { return stamp }
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
    return f.string(from: d)
}

// MARK: - Wallpaper

func samePath(_ a: URL, _ b: URL) -> Bool {
    a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
}

/// Applies to the given screens, preserving each screen's existing scaling/fill options.
func apply(_ file: URL, to screens: [NSScreen]) throws {
    guard !screens.isEmpty else { throw BWError.noScreens }
    for screen in screens {
        let opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: opts)
    }
    log("Applied \(file.lastPathComponent) to \(screens.count) screen(s)")
}

/// Stock macOS wallpapers (pictures and aerials) — what a new Space or a newly connected
/// display such as an iPad in Sidecar shows before postcard has touched it.
func isStockWallpaper(_ path: String) -> Bool {
    let prefixes = ["/System/", "/Library/Desktop Pictures/",
                    home.appendingPathComponent("Library/Application Support/com.apple.wallpaper").path + "/"]
    return prefixes.contains { path.hasPrefix($0) }
}

/// Screens (on their current Space) that should get the current image: those showing an older
/// postcard image or a stock wallpaper. Screens showing your own picture are left alone
/// (use --force to override them).
func staleScreens(current: URL) -> [NSScreen] {
    NSScreen.screens.filter { screen in
        guard let shown = NSWorkspace.shared.desktopImageURL(for: screen) else { return true }
        if samePath(shown, current) { return false }
        let path = shown.resolvingSymlinksInPath().path
        return path.hasPrefix(imagesDir.resolvingSymlinksInPath().path) || isStockWallpaper(path)
    }
}

/// Today's local date in the feed's startdate format (yyyyMMdd).
func todayStamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd"
    return f.string(from: Date())
}

/// Downloaded images, oldest first (file names start with the startdate).
func localImages() -> [String] {
    ((try? fm.contentsOfDirectory(atPath: imagesDir.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
}

func prune(keep: Int, protecting current: String) {
    for name in localImages().reversed().dropFirst(keep) where name != current {
        try? fm.removeItem(at: imagesDir.appendingPathComponent(name))
    }
}

// MARK: - Lock (prevents a manual run racing the LaunchAgent)

func acquireLock() -> Int32? {
    let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
    return fd
}

// MARK: - Commands

func showStatus() -> Int32 {
    print("Postcard \(toolVersion)")
    if let s = loadState() {
        let today = info(for: s.file)
        print("Image:     \(today.subject)\(today.headline.map { " — “\($0)”" } ?? "")")
        print("Credit:    \(today.credit ?? s.copyright ?? "-")")
        print("Date:      \(s.startdate)   Market: \(s.market ?? "auto")   Resolution: \(s.resolution)")
        print("File:      \(imagesDir.appendingPathComponent(s.file).path)")
        if let sel = s.selected { print("Showing:   \(sel)  (postcard --today to go back)") }
        let i = info(for: s.shownFile)
        if let place = i.place, let lat = i.latitude, let lon = i.longitude {
            print("Location:  \(place)  (\(lat), \(lon))")
        }
        if let about = i.about { print("About:     \(about)") }
        print("Applied:   \(s.appliedAt)")
    } else {
        print("No image applied yet.")
    }
    for (i, screen) in NSScreen.screens.enumerated() {
        let shown = NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "-"
        print("Screen \(i + 1):  \(screen.localizedName) -> \(shown)")
    }
    print("Images:    \(localImages().count) in \(imagesDir.path)")
    print("Log:       \(logFile.path)")
    return 0
}

func update(_ o: Options) -> Int32 {
    do {
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    } catch {
        fail("Cannot create \(imagesDir.path): \(error)"); return 1
    }
    guard let lockFD = acquireLock() else { warn(BWError.locked.description); return 0 }
    defer { flock(lockFD, LOCK_UN); close(lockFD) }

    let state = loadState()

    // Today's image is already applied: no need to check again until tomorrow.
    if !o.force, let s = state, s.startdate >= todayStamp(), s.resolution == o.resolution, s.market == o.market {
        let current = imagesDir.appendingPathComponent(s.shownFile)
        if fm.fileExists(atPath: current.path) {
            let stale = staleScreens(current: current)
            if stale.isEmpty {
                if Logger.shared.interactive { log("Already applied today: \(s.title ?? s.file)") }
                return 0
            }
            do { try apply(current, to: stale) } catch { fail("Apply failed: \(error)"); return 1 }
            return 0
        }
    }

    let recent: [DailyImage]
    do {
        recent = try fetchMetadata(market: o.market)
    } catch {
        fail("Could not fetch today's photo details: \(error)"); return 1
    }
    let meta = recent[0]

    // Unchanged image: only refresh screens that still show an older postcard image
    // (e.g. a display that was asleep/disconnected during the last change).
    if !o.force, let s = state, s.urlbase == meta.urlbase, s.resolution == o.resolution {
        let current = imagesDir.appendingPathComponent(s.shownFile)
        if fm.fileExists(atPath: current.path) {
            let stale = staleScreens(current: current)
            if stale.isEmpty {
                log("Up to date: \(s.title ?? s.file)")
                return 0
            }
            do { try apply(current, to: stale) } catch { fail("Apply failed: \(error)"); return 1 }
            return 0
        }
    }

    let name = fileName(for: meta, resolution: o.resolution)
    let file = imagesDir.appendingPathComponent(name)
    if !fm.fileExists(atPath: file.path) {
        do {
            let data = try downloadImage(meta, resolution: o.resolution)
            try data.write(to: file, options: .atomic) // temp file + rename: never a half-written wallpaper
            log("Downloaded \(name) (\(data.count / 1024) KB)")
        } catch {
            fail("Download failed: \(error)"); return 1
        }
    }

    do {
        try apply(file, to: NSScreen.screens)
    } catch {
        // State is not saved, so the next run (hourly / on wake) retries the apply.
        fail("Apply failed: \(error)"); return 1
    }

    let newState = State(urlbase: meta.urlbase, startdate: meta.startdate, file: name,
                         title: meta.title, copyright: meta.copyright, market: o.market,
                         resolution: o.resolution, appliedAt: Date())
    do { try saveState(newState) } catch { warn("Could not save state: \(error)") }
    log("Today: \(meta.title ?? "-") — \(meta.copyright ?? "")")
    backfill(recent.dropFirst(), resolution: o.resolution)
    prune(keep: o.keep, protecting: name)
    saveInfo(for: recent, resolution: o.resolution, market: o.market)
    return 0
}

/// Downloads any of the last few days' photos that are missing, so --prev works right away.
/// Runs once per new image; failures are skipped and retried with the next new image.
func backfill(_ images: ArraySlice<DailyImage>, resolution: String) {
    for img in images {
        let name = fileName(for: img, resolution: resolution)
        let file = imagesDir.appendingPathComponent(name)
        if fm.fileExists(atPath: file.path) { continue }
        do {
            try downloadImage(img, resolution: resolution).write(to: file, options: .atomic)
            log("Downloaded earlier image \(name)")
        } catch {
            warn("Skipped earlier image \(name): \(error)")
        }
    }
}

/// Images you can step through, oldest first, ending at today's. Anything newer on disk is
/// from an old --resolution/--mkt, so it's left out.
func history(_ s: State) -> [String] {
    localImages().filter { $0 <= s.file && $0.hasSuffix("_\(s.resolution).jpg") }
}

/// --prev / --next / --today: steps through the downloaded images. No network.
func navigate(_ step: Int) -> Int32 {
    guard let lockFD = acquireLock() else { warn(BWError.locked.description); return 1 }
    defer { flock(lockFD, LOCK_UN); close(lockFD) }
    guard var s = loadState() else { fail("No image yet. Run postcard first."); return 1 }

    let images = history(s)
    var target = s.file
    if step != 0 {
        guard let i = images.firstIndex(of: s.shownFile) ?? images.firstIndex(of: s.file) else {
            fail("Today's image is missing; run postcard --force"); return 1
        }
        guard images.indices.contains(i + step) else {
            print(step < 0 ? "No earlier image on disk (only the last 8 days are available)." : "Already showing today's image.")
            return 0
        }
        target = images[i + step]
    }

    let file = imagesDir.appendingPathComponent(target)
    do { try apply(file, to: staleScreens(current: file)) } catch BWError.noScreens {
        // Every screen already shows it.
    } catch { fail("Apply failed: \(error)"); return 1 }

    s.selected = target == s.file ? nil : target
    do { try saveState(s) } catch { warn("Could not save state: \(error)") }
    let pos = (images.firstIndex(of: target) ?? 0) + 1
    let i = info(for: target)
    print("Showing \(prettyDate(i.startdate))\(target == s.file ? " (today)" : ""): \(i.subject)  [\(pos)/\(images.count)]")
    if let about = i.about { print("\n\(about)") }
    return 0
}

/// Applies the current image to screens whose current Space doesn't show it yet. No network.
func refreshScreens() {
    guard let s = loadState() else { return }
    let current = imagesDir.appendingPathComponent(s.shownFile)
    guard fm.fileExists(atPath: current.path) else { return }
    let stale = staleScreens(current: current)
    guard !stale.isEmpty else { return }
    do { try apply(current, to: stale) } catch { fail("Apply failed: \(error)") }
}

// MARK: - Menu bar (watch mode only)

final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let options: Options

    init(options: Options) {
        self.options = options
        super.init()
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                     accessibilityDescription: "Postcard")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.autoenablesItems = false // we decide what's enabled
        menu.delegate = self
        item.menu = menu
        updateTooltip()
    }

    func updateTooltip() {
        guard let s = loadState() else { return }
        item.button?.toolTip = info(for: s.shownFile).subject
    }

    /// Rebuilt every time it opens, so it always reflects the latest image and position.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let s = loadState() else {
            menu.addItem(label("Waiting for today's image…"))
            return
        }
        let shown = s.shownFile
        let i = info(for: shown)
        let images = history(s)
        let pos = images.firstIndex(of: shown)

        menu.addItem(label(i.subject, bold: true))
        if let h = i.headline { menu.addItem(label("“\(h)”")) }
        let todayTag = shown == s.file ? " · Today" : ""
        menu.addItem(label([prettyDate(i.startdate) + todayTag, i.credit].compactMap { $0 }.joined(separator: "  ·  "), small: true))
        if let about = i.about {
            menu.addItem(.separator())
            menu.addItem(paragraph(about))
        }
        menu.addItem(.separator())
        menu.addItem(controls(canGoBack: (pos ?? 0) > 0,
                              canGoForward: pos.map { $0 < images.count - 1 } ?? false,
                              onToday: shown == s.file,
                              place: i.latitude != nil ? (i.place ?? i.subject) : nil))
        menu.addItem(.separator())
        menu.addItem(label("Postcard \(toolVersion)", small: true))
    }

    /// One row of buttons:  [‹] [›] [Today]          [📍 Show in Maps]
    /// Buttons in a menu item don't close the menu, so you can flip through days with it open.
    private func controls(canGoBack: Bool, canGoForward: Bool, onToday: Bool, place: String?) -> NSMenuItem {
        func button(_ symbol: String?, _ title: String, tip: String, _ sel: Selector, enabled: Bool = true) -> NSButton {
            let b: NSButton
            if let symbol = symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
                b = title.isEmpty ? NSButton(image: img, target: self, action: sel)
                                  : NSButton(title: title, image: img, target: self, action: sel)
                b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            } else {
                b = NSButton(title: title, target: self, action: sel)
            }
            b.bezelStyle = .push
            b.toolTip = tip
            b.isEnabled = enabled
            return b
        }
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setViews([
            button("chevron.left", "", tip: "Previous day", #selector(previous), enabled: canGoBack),
            button("chevron.right", "", tip: "Next day", #selector(nextDay), enabled: canGoForward),
            button(nil, "Today", tip: "Back to today's image", #selector(today), enabled: !onToday),
        ], in: .leading)
        if let place = place {
            stack.setViews([button("mappin.and.ellipse", "Show in Maps", tip: place, #selector(showOnMap))], in: .trailing)
        }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 368, height: 36))
        stack.frame = view.bounds.insetBy(dx: 12, dy: 3)
        stack.autoresizingMask = [.width, .height]
        view.addSubview(stack)
        let m = NSMenuItem()
        m.view = view
        return m
    }

    /// A line of text drawn as a view rather than a disabled menu item, which macOS would dim.
    private func label(_ text: String, bold: Bool = false, small: Bool = false) -> NSMenuItem {
        let font = bold ? NSFont.boldSystemFont(ofSize: 14)
                        : NSFont.systemFont(ofSize: small ? 11.5 : 13)
        return textItem(text, font: font, color: small ? .secondaryLabelColor : .labelColor, gap: 2)
    }

    /// The description paragraph.
    private func paragraph(_ text: String) -> NSMenuItem {
        textItem(text, font: NSFont.systemFont(ofSize: 12.5), color: .labelColor, gap: 5)
    }

    /// Wrapped, full-contrast, non-clickable text.
    private func textItem(_ text: String, font: NSFont, color: NSColor, gap: CGFloat) -> NSMenuItem {
        let width: CGFloat = 340
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        let size = field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width + 28, height: size.height + gap * 2))
        field.frame = NSRect(x: 14, y: gap, width: width, height: size.height)
        view.addSubview(field)
        let m = NSMenuItem()
        m.view = view
        return m
    }

    /// Steps, then refreshes the open menu in place (deferred: the clicked button is being replaced).
    private func go(_ step: Int) {
        _ = navigate(step)
        updateTooltip()
        guard let menu = item.menu else { return }
        RunLoop.main.perform(inModes: [.common, .eventTracking]) { self.menuNeedsUpdate(menu) }
    }
    @objc func previous() { go(-1) }
    @objc func nextDay() { go(1) }
    @objc func today() { go(0) }

    /// Opens Apple Maps at the photo's location.
    @objc func showOnMap() {
        guard let s = loadState() else { return }
        let i = info(for: s.shownFile)
        guard let lat = i.latitude, let lon = i.longitude else { return }
        var c = URLComponents(string: "https://maps.apple.com/")!
        c.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lon)"),
                        URLQueryItem(name: "q", value: i.place ?? i.subject)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}

/// LaunchAgent mode. macOS only sets the wallpaper of each display's *current* Space, so we
/// follow Space switches and display changes (Sidecar, external monitors) and apply as needed.
func watch(_ initial: Options) -> Never {
    var o = initial
    _ = update(o)
    o.force = false

    var pending: DispatchWorkItem?
    func refreshSoon(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { refreshScreens() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
        refreshSoon(after: 0.5)
    }
    ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        _ = update(o)
    }
    // A display was added/removed/rearranged; give a new display a moment to get its Space.
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in
        refreshSoon(after: 2)
    }
    let timer = Timer(timeInterval: o.interval, repeats: true) { _ in _ = update(o) }
    timer.tolerance = 60
    RunLoop.main.add(timer, forMode: .common)

    NSApplication.shared.setActivationPolicy(.accessory) // menu bar icon, still no Dock icon
    let menuBar = MenuBar(options: o)
    ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
        menuBar.updateTooltip()
    }
    let tooltipTimer = Timer(timeInterval: 300, repeats: true) { _ in menuBar.updateTooltip() }
    RunLoop.main.add(tooltipTimer, forMode: .common)

    log("Watching (checks every \(Int(o.interval / 60)) min, plus wake, Space and display changes)")
    NSApplication.shared.run()
    exit(0)
}

// MARK: - Main

let options = parseOptions()
NSApplication.shared.setActivationPolicy(.prohibited) // window-server connection, no Dock icon
if options.status { exit(showStatus()) }
if let step = options.step { exit(navigate(step)) }
if options.watch { watch(options) }
exit(update(options))
