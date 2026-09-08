import Foundation
import Network
import UIKit

final class SharedFolderServer {
    static let guestURL = "http://10.0.2.2:8080/"

    var onStatusChanged: ((String) -> Void)?
    var onFilesChanged: (() -> Void)?

    private let directory: URL
    private let queue = DispatchQueue(label: "jp.example.win95.shared-files", qos: .utility)
    private var listener: NWListener?
    private var clients: [UUID: SharedHTTPConnection] = [:]

    init(directory: URL) { self.directory = directory }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.clients.values.forEach { $0.cancel() }
            self.clients.removeAll()
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let port = NWEndpoint.Port(rawValue: 8080)!
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // libslirp maps the guest-only 10.0.2.2 address to host loopback.
            // Binding here keeps the file page off the physical LAN.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let newListener = try NWListener(using: parameters)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.reportStatus("使用できます")
                case .failed(let error):
                    self.reportStatus("起動できません: \(error.localizedDescription)")
                    self.listener?.cancel()
                    self.listener = nil
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener = newListener
            newListener.start(queue: queue)
            reportStatus("起動中…")
        } catch {
            reportStatus("起動できません: \(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let client = SharedHTTPConnection(
            connection: connection,
            directory: directory,
            queue: queue,
            onUpload: { [weak self] in
                DispatchQueue.main.async { self?.onFilesChanged?() }
            },
            onFinish: { [weak self] in
                self?.queue.async { self?.clients.removeValue(forKey: id) }
            }
        )
        clients[id] = client
        client.start()
    }

    private func reportStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatusChanged?(text) }
    }
}

private final class SharedHTTPConnection {
    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumUploadBytes = 1024 * 1024 * 1024

    private let connection: NWConnection
    private let directory: URL
    private let queue: DispatchQueue
    private let onUpload: () -> Void
    private let onFinish: () -> Void
    private var requestBuffer = Data()
    private var expectedBodyBytes = 0
    private var receivedBodyBytes = 0
    private var boundary = Data()
    private var multipartHeader = Data()
    private var uploadTail = Data()
    private var uploadHandle: FileHandle?
    private var temporaryUploadURL: URL?
    private var destinationUploadURL: URL?
    private var responseStarted = false
    private var finished = false

    init(
        connection: NWConnection,
        directory: URL,
        queue: DispatchQueue,
        onUpload: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.connection = connection
        self.directory = directory
        self.queue = queue
        self.onUpload = onUpload
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: queue)
        receiveRequest()
    }

    func cancel() { connection.cancel() }

    private func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let error {
                self.fail(status: "400 Bad Request", message: error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                if self.expectedBodyBytes > 0 {
                    self.consumeUploadBody(data)
                } else {
                    self.requestBuffer.append(data)
                    self.parseRequestIfPossible()
                }
            }
            if self.finished || self.responseStarted { return }
            if complete {
                self.fail(status: "400 Bad Request", message: "Incomplete request")
            } else {
                self.receiveRequest()
            }
        }
    }

    private func parseRequestIfPossible() {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = requestBuffer.range(of: separator) else {
            if requestBuffer.count > Self.maximumHeaderBytes {
                fail(status: "431 Request Header Fields Too Large", message: "Request header is too large")
            }
            return
        }
        let headerData = requestBuffer[..<headerEnd.lowerBound]
        let bodyStart = headerEnd.upperBound
        let initialBody = Data(requestBuffer[bodyStart...])
        requestBuffer.removeAll(keepingCapacity: false)
        guard let headerText = String(data: headerData, encoding: .utf8) ??
                String(data: headerData, encoding: .shiftJIS) ??
                String(data: headerData, encoding: .isoLatin1) else {
            fail(status: "400 Bad Request", message: "Invalid request header")
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            fail(status: "400 Bad Request", message: "Missing request line")
            return
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else {
            fail(status: "400 Bad Request", message: "Invalid request line")
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        switch (requestParts[0], requestParts[1]) {
        case ("GET", "/"), ("GET", "/index.html"):
            sendDirectoryPage()
        case ("GET", let path) where path.hasPrefix("/files/"):
            sendSharedFile(path: path)
        case ("POST", "/upload"):
            beginUpload(headers: headers, initialBody: initialBody)
        default:
            fail(status: "404 Not Found", message: "Not found")
        }
    }

    private func beginUpload(headers: [String: String], initialBody: Data) {
        guard let lengthText = headers["content-length"],
              let contentLength = Int(lengthText),
              contentLength > 0,
              contentLength <= Self.maximumUploadBytes else {
            fail(status: "413 Content Too Large", message: "Uploads must be 1 GB or smaller")
            return
        }
        guard let contentType = headers["content-type"],
              let boundaryValue = contentType.components(separatedBy: "boundary=").last,
              contentType.lowercased().contains("multipart/form-data") else {
            fail(status: "400 Bad Request", message: "Expected a multipart upload")
            return
        }
        let cleanBoundary = boundaryValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
        guard !cleanBoundary.isEmpty, cleanBoundary.count <= 200 else {
            fail(status: "400 Bad Request", message: "Invalid multipart boundary")
            return
        }
        boundary = Data(("\r\n--" + cleanBoundary).utf8)
        expectedBodyBytes = contentLength
        if headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), isComplete: false, completion: .idempotent)
        }
        consumeUploadBody(initialBody)
    }

    private func consumeUploadBody(_ incoming: Data) {
        guard !finished, receivedBodyBytes < expectedBodyBytes else { return }
        let remaining = expectedBodyBytes - receivedBodyBytes
        let data = Data(incoming.prefix(remaining))
        receivedBodyBytes += data.count

        if uploadHandle == nil {
            multipartHeader.append(contentsOf: data)
            let separator = Data("\r\n\r\n".utf8)
            guard let headerEnd = multipartHeader.range(of: separator) else {
                if multipartHeader.count > Self.maximumHeaderBytes {
                    fail(status: "400 Bad Request", message: "Multipart header is too large")
                }
                return
            }
            let partHeaderData = multipartHeader[..<headerEnd.lowerBound]
            guard let partHeader = String(data: partHeaderData, encoding: .utf8) ??
                    String(data: partHeaderData, encoding: .shiftJIS) ??
                    String(data: partHeaderData, encoding: .isoLatin1),
                  let filename = multipartFilename(in: partHeader) else {
                fail(status: "400 Bad Request", message: "No file was selected")
                return
            }
            do {
                try openUpload(named: filename)
            } catch {
                fail(status: "500 Internal Server Error", message: error.localizedDescription)
                return
            }
            let fileStart = headerEnd.upperBound
            let firstFileBytes = Data(multipartHeader[fileStart...])
            multipartHeader.removeAll(keepingCapacity: false)
            consumeFileBytes(firstFileBytes)
        } else {
            consumeFileBytes(Data(data))
        }

        guard !responseStarted else { return }
        if receivedBodyBytes == expectedBodyBytes { finishUpload() }
    }

    private func multipartFilename(in header: String) -> String? {
        if let extended = header.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            let value = header[extended.upperBound...].prefix { $0 != ";" && $0 != "\r" && $0 != "\n" }
            if let decoded = String(value).removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        guard let marker = header.range(of: "filename=\"", options: .caseInsensitive) else { return nil }
        let suffix = header[marker.upperBound...]
        guard let quote = suffix.firstIndex(of: "\"") else { return nil }
        return String(suffix[..<quote])
    }

    private func openUpload(named untrustedName: String) throws {
        let normalized = untrustedName.replacingOccurrences(of: "\\", with: "/")
        var filename = URL(fileURLWithPath: normalized).lastPathComponent
        filename = filename.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "_" : String($0) }.joined()
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            throw NSError(domain: "SharedFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid filename"])
        }
        destinationUploadURL = uniqueDestination(named: filename)
        let temporary = directory.appendingPathComponent(".upload-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw NSError(domain: "SharedFiles", code: 2, userInfo: [NSLocalizedDescriptionKey: "The upload file could not be created"])
        }
        temporaryUploadURL = temporary
        uploadHandle = try FileHandle(forWritingTo: temporary)
    }

    private func consumeFileBytes(_ data: Data) {
        uploadTail.append(data)
        let retainedBytes = boundary.count + 8
        guard uploadTail.count > retainedBytes else { return }
        let writableCount = uploadTail.count - retainedBytes
        do {
            try uploadHandle?.write(contentsOf: uploadTail.prefix(writableCount))
            uploadTail.removeFirst(writableCount)
        } catch {
            fail(status: "500 Internal Server Error", message: error.localizedDescription)
        }
    }

    private func finishUpload() {
        guard !finished, let temporaryUploadURL, let destinationUploadURL,
              let trailer = uploadTail.range(of: boundary, options: .backwards) else {
            fail(status: "400 Bad Request", message: "Incomplete multipart upload")
            return
        }
        do {
            try uploadHandle?.write(contentsOf: uploadTail[..<trailer.lowerBound])
            try uploadHandle?.synchronize()
            try uploadHandle?.close()
            uploadHandle = nil
            try FileManager.default.moveItem(at: temporaryUploadURL, to: destinationUploadURL)
            self.temporaryUploadURL = nil
            onUpload()
            sendRedirect()
        } catch {
            fail(status: "500 Internal Server Error", message: error.localizedDescription)
        }
    }

    private func uniqueDestination(named filename: String) -> URL {
        let fileManager = FileManager.default
        let original = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: original.path) else { return original }
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            var candidate = directory.appendingPathComponent("\(base)-\(suffix)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private func sendDirectoryPage() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let rows = files.map { file -> String in
            let name = htmlEscape(file.lastPathComponent)
            let link = percentEncodedPathComponent(file.lastPathComponent)
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return "<li><a href=\"/files/\(link)\">\(name)</a> <small>(\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))</small></li>"
        }.joined(separator: "\n")
        let fileList = rows.isEmpty ? "<p>No shared files.</p>" : "<ul>\(rows)</ul>"
        let html = """
        <!doctype html><html><head><meta http-equiv="Content-Type" content="text/html; charset=shift_jis">
        <title>Windows 9x Shared Files</title></head><body>
        <h2>Windows 9x Shared Files</h2>
        <p>Click a file to copy it from iPhone/iPad to Windows.</p>
        \(fileList)
        <hr><h3>Copy a file from Windows to iPhone/iPad</h3>
        <form method="POST" action="/upload" enctype="multipart/form-data">
        <input type="file" name="file"><input type="submit" value="Upload"></form>
        <p>Uploaded files appear in Files &gt; On My iPhone/iPad &gt; this app &gt; Win9x &gt; Shared.</p>
        </body></html>
        """
        let body = html.data(using: .shiftJIS, allowLossyConversion: true) ?? Data(html.utf8)
        send(status: "200 OK", contentType: "text/html; charset=shift_jis", body: body)
    }

    private func sendSharedFile(path: String) {
        let encodedName = String(path.dropFirst("/files/".count))
        guard let decodedName = encodedName.removingPercentEncoding,
              !decodedName.isEmpty,
              decodedName == URL(fileURLWithPath: decodedName).lastPathComponent,
              !decodedName.hasPrefix(".") else {
            fail(status: "400 Bad Request", message: "Invalid filename")
            return
        }
        let fileURL = directory.appendingPathComponent(decodedName)
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            fail(status: "404 Not Found", message: "File not found")
            return
        }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            responseStarted = true
            let header = responseHeader(
                status: "200 OK",
                contentType: "application/octet-stream",
                contentLength: size,
                extra: "Content-Disposition: attachment\r\n"
            )
            connection.send(content: header, isComplete: false, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    try? handle.close()
                    self.fail(status: "500 Internal Server Error", message: error.localizedDescription)
                } else {
                    self.sendNextFileChunk(handle)
                }
            })
        } catch {
            fail(status: "500 Internal Server Error", message: error.localizedDescription)
        }
    }

    private func sendNextFileChunk(_ handle: FileHandle) {
        do {
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty {
                try handle.close()
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish() })
                return
            }
            connection.send(content: data, isComplete: false, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    try? handle.close()
                    self.fail(status: "500 Internal Server Error", message: error.localizedDescription)
                } else {
                    self.sendNextFileChunk(handle)
                }
            })
        } catch {
            try? handle.close()
            fail(status: "500 Internal Server Error", message: error.localizedDescription)
        }
    }

    private func sendRedirect() {
        guard !finished, !responseStarted else { return }
        responseStarted = true
        let data = Data("HTTP/1.1 303 See Other\r\nLocation: /\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: data, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func fail(status: String, message: String) {
        if responseStarted {
            finish()
            return
        }
        send(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    private func send(status: String, contentType: String, body: Data) {
        guard !finished, !responseStarted else { return }
        responseStarted = true
        var response = responseHeader(status: status, contentType: contentType, contentLength: body.count)
        response.append(body)
        connection.send(content: response, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func responseHeader(status: String, contentType: String, contentLength: Int, extra: String = "") -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(contentLength)\r\n\(extra)Connection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
    }

    private func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func percentEncodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? UUID().uuidString
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        try? uploadHandle?.close()
        uploadHandle = nil
        if let temporaryUploadURL { try? FileManager.default.removeItem(at: temporaryUploadURL) }
        temporaryUploadURL = nil
        connection.cancel()
        onFinish()
    }
}

final class SharedFilesViewController: UITableViewController {
    var onAdd: (() -> Void)?
    var onOpenInWindows: (() -> Void)?
    var onShare: ((URL, UIView?) -> Void)?
    var onDelete: ((URL) -> Void)?
    var onExportMergedDisk: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var files: [URL]
    private var serverStatus: String
    private var busy = false
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(files: [URL], serverStatus: String) {
        self.files = files
        self.serverStatus = serverStatus
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ファイル共有・移行"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissSharedFiles)
        )
    }

    func reload(files: [URL], serverStatus: String, busy: Bool) {
        self.files = files
        self.serverStatus = serverStatus
        self.busy = busy
        tableView.isUserInteractionEnabled = !busy
        tableView.alpha = busy ? 0.6 : 1
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        if busy {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.titleView = spinner
        } else {
            navigationItem.titleView = nil
            title = "ファイル共有・移行"
        }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 4 : files.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "接続・追加・移行" : "Sharedフォルダ"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else {
            return files.isEmpty ? "共有ファイルはまだありません。" : "タップするとiOSの共有メニューを開きます。左スワイプで削除できます。"
        }
        return "Windows 95のInternet Explorerで上のアドレスを開きます。一覧からiOSのファイルを取得でき、ページ下部から1 GBまでのWindowsファイルをアップロードできます。NE2000とTCP/IPの設定が必要です。統合IMGはWin9x/Exportsにも保存されます。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0, indexPath.row == 0 {
            cell.textLabel?.text = SharedFolderServer.guestURL
            cell.detailTextLabel?.text = "状態: \(serverStatus) — タップしてコピー"
            cell.imageView?.image = UIImage(systemName: "network")
            cell.accessoryType = .none
        } else if indexPath.section == 0, indexPath.row == 1 {
            cell.textLabel?.text = "Windowsで共有ページを開く"
            cell.detailTextLabel?.text = "Win+Rへアドレスを自動入力します"
            cell.textLabel?.textColor = view.tintColor
            cell.imageView?.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
        } else if indexPath.section == 0, indexPath.row == 2 {
            cell.textLabel?.text = "Filesから共有フォルダへ追加…"
            cell.detailTextLabel?.text = "複数のファイルを選択できます"
            cell.textLabel?.textColor = view.tintColor
            cell.imageView?.image = UIImage(systemName: "doc.badge.plus")
        } else if indexPath.section == 0 {
            cell.textLabel?.text = "移行用の統合HDDを作成…"
            cell.detailTextLabel?.text = "ベースIMG/VHDとsavを単体のraw IMGへ統合"
            cell.textLabel?.textColor = view.tintColor
            cell.imageView?.image = UIImage(systemName: "externaldrive.badge.checkmark")
            cell.accessoryType = .disclosureIndicator
        } else {
            let file = files[indexPath.row]
            cell.textLabel?.text = file.lastPathComponent
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                cell.detailTextLabel?.text = byteFormatter.string(fromByteCount: Int64(size))
            }
            cell.imageView?.image = UIImage(systemName: "doc")
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        if indexPath.section == 0, indexPath.row == 0 {
            UIPasteboard.general.string = SharedFolderServer.guestURL
            let alert = UIAlertController(title: "アドレスをコピーしました", message: SharedFolderServer.guestURL, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        } else if indexPath.section == 0, indexPath.row == 1 {
            onOpenInWindows?()
        } else if indexPath.section == 0, indexPath.row == 2 {
            onAdd?()
        } else if indexPath.section == 0 {
            onExportMergedDisk?()
        } else {
            onShare?(files[indexPath.row], tableView.cellForRow(at: indexPath))
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !busy && indexPath.section == 1
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, files.indices.contains(indexPath.row) else { return }
        onDelete?(files[indexPath.row])
    }

    @objc private func dismissSharedFiles() { onDismiss?() }
}
