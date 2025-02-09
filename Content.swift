import SwiftUI
import SQLite3
import AppKit  // Needed for NSAlert

// MARK: - Data Model

struct Configuration: Identifiable, Hashable {
    let id: UInt64
    let name: String
    let data: Data
}

// MARK: - Database Manager

class DatabaseManager: ObservableObject {
    @Published var configurations: [Configuration] = []
    var db: OpaquePointer?
    
    // The database file path; not opened automatically.
    var dbPath: String
    
    init(dbPath: String? = nil) {
        if let path = dbPath {
            self.dbPath = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.dbPath = home
                .appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Library/Application Support/config.sqlite3")
                .path
        }
        // Do not open the database here.
    }
    
    deinit {
        closeDatabase()
    }
    
    /// Call this function to open the database and fetch configurations.
    func connect(completion: @escaping () -> Void = {}) {
        openDatabase()
        fetchConfigurations(completion: completion)
    }
    
    /// Opens the SQLite database.
    func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database at \(dbPath)")
            db = nil
        }
    }
    
    /// Closes the database connection and clears configurations.
    func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
            DispatchQueue.main.async {
                self.configurations = []
            }
        }
    }
    
    /// Updates the database file used by the manager.
    func updateDatabaseFile(newPath: String) {
        closeDatabase()
        self.dbPath = newPath
        connect()  // Reconnect after updating the path.
    }
    
    /// Fetches all configurations (presets) from the database.
    /// The completion closure is called after the configurations are updated.
    func fetchConfigurations(completion: @escaping () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async {
            var tempConfigs: [Configuration] = []
            guard let db = self.db else {
                DispatchQueue.main.async { completion() }
                return
            }
            
            let query = """
            SELECT gc.__pk0 as id, gcf.f86 as name, gc.p as data
            FROM generationconfiguration gc
            LEFT JOIN generationconfiguration__f86 gcf ON gc.rowid = gcf.rowid
            WHERE gc.__pk0 != 0;
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    // Convert to an unsigned 64-bit value (ensuring no negative sign)
                    let id = UInt64(bitPattern: sqlite3_column_int64(statement, 0))
                    var name = "Unknown"
                    if let cString = sqlite3_column_text(statement, 1) {
                        name = String(cString: cString)
                    }
                    var data = Data()
                    if let blob = sqlite3_column_blob(statement, 2) {
                        let size = sqlite3_column_bytes(statement, 2)
                        data = Data(bytes: blob, count: Int(size))
                    }
                    let config = Configuration(id: id, name: name, data: data)
                    tempConfigs.append(config)
                }
                sqlite3_finalize(statement)
            } else {
                print("Error preparing statement.")
            }
            
            DispatchQueue.main.async {
                self.configurations = tempConfigs
                completion()
            }
        }
    }
    
    /// Exports the given configurations to the target directory.
    /// The ID is saved as a string in JSON so that it isn’t formatted as a floating point number.
    func exportConfigurations(_ configs: [Configuration], to directory: URL) {
        for config in configs {
            let baseName = "DTC_\(config.name.prefix(12))_\(config.id)"
            let binURL = directory.appendingPathComponent("\(baseName).bin")
            let jsonURL = directory.appendingPathComponent("\(baseName).json")
            
            // Check if the files already exist
            if FileManager.default.fileExists(atPath: binURL.path) || FileManager.default.fileExists(atPath: jsonURL.path) {
                let alert = NSAlert()
                alert.messageText = "Overwrite Existing File?"
                alert.informativeText = "The files for configuration '\(config.name)' (ID: \(config.id)) already exist. Do you want to overwrite them?"
                alert.addButton(withTitle: "Overwrite")
                alert.addButton(withTitle: "Skip")
                let result = alert.runModal()
                if result == .alertSecondButtonReturn {
                    // Skip export for this configuration.
                    print("Skipping configuration \(config.name)")
                    continue
                }
            }
            
            do {
                try config.data.write(to: binURL)
                // Save the ID as a string
                let metadata: [String: Any] = ["id": String(config.id), "name": config.name]
                let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
                try jsonData.write(to: jsonURL)
                print("Configuration '\(config.name)' exported.")
            } catch {
                print("Error exporting \(config.name): \(error)")
            }
        }
    }
    
    /// Scans the import folder and returns new and existing configurations.
    func scanImportFolder(_ directory: URL) -> (newConfigs: [Configuration], existingConfigs: [Configuration]) {
        let fileManager = FileManager.default
        var newConfigs: [Configuration] = []
        var existingConfigs: [Configuration] = []
        
        do {
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            print("Found files: \(files.map { $0.lastPathComponent })")
            let binFiles = files.filter { $0.pathExtension.lowercased() == "bin" }
            print("Filtered bin files: \(binFiles.map { $0.lastPathComponent })")
            for binFile in binFiles {
                let baseName = binFile.deletingPathExtension().lastPathComponent
                let jsonFile = directory.appendingPathComponent("\(baseName).json")
                print("Looking for JSON file: \(jsonFile.lastPathComponent)")
                if fileManager.fileExists(atPath: jsonFile.path) {
                    let jsonData = try Data(contentsOf: jsonFile)
                    if let dict = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
                       let idStr = dict["id"] as? String,
                       let id = UInt64(idStr),
                       let name = dict["name"] as? String {
                        let data = try Data(contentsOf: binFile)
                        let config = Configuration(id: id, name: name, data: data)
                        if self.configurations.contains(where: { $0.id == id }) {
                            existingConfigs.append(config)
                        } else {
                            newConfigs.append(config)
                        }
                    } else {
                        print("Could not parse JSON file: \(jsonFile.lastPathComponent)")
                    }
                } else {
                    print("JSON file does not exist for: \(baseName)")
                }
            }
        } catch {
            print("Error scanning import folder: \(error)")
        }
        return (newConfigs, existingConfigs)
    }
    
    /// Inserts the given configurations into the database.
    func insertConfigurations(_ configs: [Configuration]) {
        guard let db = self.db else { return }
        let insertQuery1 = "INSERT INTO generationconfiguration (__pk0, p) VALUES (?, ?)"
        let insertQuery2 = "INSERT INTO generationconfiguration__f86 (rowid, f86) VALUES (?, ?)"
        
        for config in configs {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, insertQuery1, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, Int64(bitPattern: config.id))
                config.data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    sqlite3_bind_blob(statement, 2, ptr.baseAddress, Int32(config.data.count), nil)
                }
                if sqlite3_step(statement) != SQLITE_DONE {
                    print("Error inserting configuration \(config.name)")
                }
                sqlite3_finalize(statement)
                
                let rowid = sqlite3_last_insert_rowid(db)
                if sqlite3_prepare_v2(db, insertQuery2, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_int64(statement, 1, rowid)
                    sqlite3_bind_text(statement, 2, (config.name as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Error inserting name for \(config.name)")
                    }
                    sqlite3_finalize(statement)
                }
            }
        }
        fetchConfigurations()
    }
    
    /// Deletes the given configurations from the database.
    func deleteConfigurations(_ configs: [Configuration]) {
        guard let db = self.db else { return }
        for config in configs {
            let deleteQuery1 = "DELETE FROM generationconfiguration WHERE __pk0 = ?"
            let deleteQuery2 = "DELETE FROM generationconfiguration__f86 WHERE rowid IN (SELECT rowid FROM generationconfiguration WHERE __pk0 = ?)"
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteQuery1, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, Int64(bitPattern: config.id))
                if sqlite3_step(statement) != SQLITE_DONE {
                    print("Error deleting configuration \(config.name)")
                }
                sqlite3_finalize(statement)
            }
            
            if sqlite3_prepare_v2(db, deleteQuery2, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, Int64(bitPattern: config.id))
                if sqlite3_step(statement) != SQLITE_DONE {
                    print("Error deleting name for \(config.name)")
                }
                sqlite3_finalize(statement)
            }
        }
        fetchConfigurations()
    }
}

// MARK: - Import Selection View

struct ImportSelectionView: View {
    let newConfigs: [Configuration]
    let existingConfigs: [Configuration]
    @Binding var importSelection: Set<UInt64>
    var onImport: ([Configuration]) -> Void
    var onCancel: () -> Void
    
    var body: some View {
        VStack {
            Text("Select Import Settings")
                .font(.headline)
                .padding()
            
            if newConfigs.isEmpty && existingConfigs.isEmpty {
                Text("No presets found in the folder.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List {
                    if !newConfigs.isEmpty {
                        Section(header: Text("New Configurations")) {
                            ForEach(newConfigs, id: \.id) { config in
                                HStack {
                                    Text(config.name)
                                    Spacer()
                                    Text("ID: \(String(format: "%llu", config.id))")
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if importSelection.contains(config.id) {
                                        importSelection.remove(config.id)
                                    } else {
                                        importSelection.insert(config.id)
                                    }
                                }
                                .background(importSelection.contains(config.id) ? Color.accentColor.opacity(0.2) : Color.clear)
                            }
                        }
                    }
                    if !existingConfigs.isEmpty {
                        Section(header: Text("Existing Configurations")) {
                            ForEach(existingConfigs, id: \.id) { config in
                                HStack {
                                    Text(config.name)
                                    Spacer()
                                    Text("ID: \(String(format: "%llu", config.id))")
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
                .listStyle(SidebarListStyle())
            }
            
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Import") {
                    let selected = newConfigs.filter { importSelection.contains($0.id) }
                    onImport(selected)
                }
                .disabled(importSelection.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @StateObject var dbManager = DatabaseManager()
    @State private var selection = Set<UInt64>()
    @State private var showingDeleteConfirmation = false
    
    // State for the import flow
    @State private var isShowingImportSheet = false
    @State private var importNewConfigs: [Configuration] = []
    @State private var importExistingConfigs: [Configuration] = []
    @State private var importSelection = Set<UInt64>()
    
    // State to track whether the database is open
    @State private var isDatabaseOpen = false
    
    var body: some View {
        VStack {
            if !isDatabaseOpen {
                // Header view prompting the user to open the database.
                VStack {
                    Text("Welcome to DT Preset Tool")
                        .font(.largeTitle)
                        .padding(.bottom, 10)
                    Text("WARNING: Please BACKUP your database before using this tool!")
                        .foregroundColor(.red)
                        .padding(.bottom, 5)
                    Text("Also, please ensure that DrawThings is closed before opening the database.")
                        .foregroundColor(.red)
                        .padding(.bottom, 20)
                    HStack {
                        Button("Open Default Database") {
                            // Open using the default file path.
                            dbManager.connect {
                                isDatabaseOpen = true
                            }
                        }
                        Button("Select Database File") {
                            selectDatabaseFile()
                        }
                    }
                }
                .padding()
            } else {
                // Main UI when the database is open.
                VStack {
                    HStack {
                        Text("Connected to: \(dbManager.dbPath)")
                            .font(.subheadline)
                        Spacer()
                        Button("Close Database") {
                            dbManager.closeDatabase()
                            isDatabaseOpen = false
                        }
                    }
                    .padding()
                    
                    List(selection: $selection) {
                        ForEach(dbManager.configurations) { config in
                            HStack {
                                Text(config.name)
                                    .font(.headline)
                                Spacer()
                                Text("ID: \(String(format: "%llu", config.id))")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(SidebarListStyle())
                    .frame(minWidth: 600, minHeight: 400)
                    .toolbar {
                        ToolbarItemGroup {
                            Button("Export") {
                                exportSelected()
                            }
                            Button("Import") {
                                selectImportFolder()
                            }
                            Button("Delete") {
                                showingDeleteConfirmation = true
                            }
                            Button("Refresh") {
                                dbManager.fetchConfigurations()
                            }
                            Button("Select Database") {
                                selectDatabaseFile()
                            }
                        }
                    }
                }
            }
        }
        .alert(isPresented: $showingDeleteConfirmation) {
            Alert(title: Text("Delete Configurations"),
                  message: Text("Do you really want to delete the selected configurations?"),
                  primaryButton: .destructive(Text("Delete")) {
                    let configsToDelete = dbManager.configurations.filter { selection.contains($0.id) }
                    dbManager.deleteConfigurations(configsToDelete)
                    selection.removeAll()
                  },
                  secondaryButton: .cancel())
        }
        .sheet(isPresented: $isShowingImportSheet) {
            ImportSelectionView(newConfigs: importNewConfigs,
                                existingConfigs: importExistingConfigs,
                                importSelection: $importSelection,
                                onImport: { selectedConfigs in
                                    dbManager.insertConfigurations(selectedConfigs)
                                    isShowingImportSheet = false
                                    importSelection.removeAll()
                                },
                                onCancel: {
                                    isShowingImportSheet = false
                                    importSelection.removeAll()
                                })
        }
    }
    
    /// Opens a dialog for selecting a new database file.
    func selectDatabaseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["sqlite3"]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Open in the folder of the default file.
        let defaultFolder = URL(fileURLWithPath: dbManager.dbPath).deletingLastPathComponent()
        panel.directoryURL = defaultFolder
        panel.prompt = "Select Database File"
        if panel.runModal() == .OK, let url = panel.url {
            dbManager.updateDatabaseFile(newPath: url.path)
            isDatabaseOpen = true
        }
    }
    
    /// Opens a dialog for exporting the selected configurations.
    func exportSelected() {
        guard !selection.isEmpty else { return }
        let selectedConfigs = dbManager.configurations.filter { selection.contains($0.id) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Export Folder"
        if panel.runModal() == .OK, let url = panel.url {
            dbManager.exportConfigurations(selectedConfigs, to: url)
        }
    }
    
    /// Opens a dialog for selecting an import folder and starts scanning.
    func selectImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Import Folder"
        if panel.runModal() == .OK, let url = panel.url {
            // Call fetchConfigurations with a completion handler so that scanning only happens after configurations are loaded.
            dbManager.fetchConfigurations() {
                let result = dbManager.scanImportFolder(url)
                importNewConfigs = result.newConfigs
                importExistingConfigs = result.existingConfigs
                // Pre-select all new configurations (if any)
                importSelection = Set(importNewConfigs.map { $0.id })
                isShowingImportSheet = true
            }
        }
    }
}

// MARK: - App Entry Point

@main
struct DTPresetToolApp: App {
    var body: some Scene {
        WindowGroup("DT Preset Tool") {
            ContentView()
        }
    }
}
