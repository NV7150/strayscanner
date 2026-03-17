//
//  SessionDetailView.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 12/30/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI
import AVKit
import CoreData

class SessionDetailViewModel: ObservableObject {
    private var dataContext: NSManagedObjectContext?

    init() {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        self.dataContext = appDelegate?.persistentContainer.viewContext
    }

    func title(recording: Recording) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        if let created = recording.createdAt {
            return dateFormatter.string(from: created)
        } else {
            return recording.name ?? "Recording"
        }
    }

    func delete(recording: Recording) {
        recording.deleteFiles()
        self.dataContext?.delete(recording)
        do {
            try self.dataContext?.save()
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
        }
    }

    func rename(recording: Recording, to name: String, completion: @escaping (Bool) -> Void) {
        guard let oldDir = recording.directoryPath() else { completion(false); return }

        let sanitized = name.trimmingCharacters(in: .whitespaces)
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            .replacingOccurrences(of: " ", with: "_")
        guard !sanitized.isEmpty else { completion(false); return }

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = f.string(from: recording.createdAt ?? Date())
        let newDirName = "\(sanitized)_\(timestamp)"

        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let newDir = docsDir.appendingPathComponent(newDirName)

        do {
            try FileManager.default.moveItem(at: oldDir, to: newDir)
            let rgbFile = URL(fileURLWithPath: recording.rgbFilePath ?? "").lastPathComponent
            let depthDir = URL(fileURLWithPath: recording.depthFilePath ?? "").lastPathComponent
            recording.rgbFilePath = "\(newDirName)/\(rgbFile)"
            recording.depthFilePath = "\(newDirName)/\(depthDir)"
            recording.name = sanitized
            try dataContext?.save()
            completion(true)
        } catch {
            print("Rename failed: \(error)")
            completion(false)
        }
    }

    func createZip(recording: Recording, completion: @escaping (URL?) -> Void) {
        guard let dir = recording.directoryPath() else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // NSFileCoordinator with .forUploading causes the system to produce
            // a ZIP of the directory automatically — no third-party library needed.
            var coordError: NSError?
            var resultURL: URL?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: dir, options: .forUploading, error: &coordError) { zipURL in
                // zipURL is a temporary system-managed ZIP; copy it to our tmp dir
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd_HHmmss"
                let timestamp = f.string(from: Date())
                let safeName = (recording.name ?? "recording")
                    .replacingOccurrences(of: "/", with: "_")
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(safeName)_\(timestamp).zip")
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: zipURL, to: dest)
                    resultURL = dest
                } catch {
                    print("ZIP copy failed: \(error)")
                }
            }
            DispatchQueue.main.async {
                if let e = coordError { print("ZIP coordination failed: \(e)") }
                completion(resultURL)
            }
        }
    }
}

struct RenameSheet: View {
    @Binding var name: String
    @Binding var isPresented: Bool
    var onSave: (String) -> Void

    var body: some View {
        NavigationView {
            Form {
                TextField("スキャン名", text: $name)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            .navigationTitle("名前を変更")
            .navigationBarItems(
                leading: Button("キャンセル") { isPresented = false },
                trailing: Button("保存") { isPresented = false; onSave(name) }
            )
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SessionDetailView: View {
    @ObservedObject var viewModel = SessionDetailViewModel()
    var recording: Recording
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    @State private var isSharing = false
    @State private var shareURL: URL?
    @State private var isCreatingZip = false
    @State private var isRenaming = false
    @State private var renameText = ""

    let defaultUrl = URL(fileURLWithPath: "")

    var body: some View {
        let width = UIScreen.main.bounds.size.width
        let height = width * 0.75
        ZStack {
        Color("BackgroundColor")
            .edgesIgnoringSafeArea(.all)
        VStack {
            let player = AVPlayer(url: recording.absoluteRgbPath() ?? defaultUrl)
            VideoPlayer(player: player)
                .frame(width: width, height: height)
                .padding(.horizontal, 0.0)
            HStack(spacing: 24) {
                Button(action: { renameText = recording.name ?? ""; isRenaming = true }) {
                    Label("Rename", systemImage: "pencil")
                        .foregroundColor(Color("TextColor"))
                }
                Button(action: shareZip) {
                    if isCreatingZip {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color("TextColor")))
                    } else {
                        Label("Share ZIP", systemImage: "square.and.arrow.up")
                            .foregroundColor(Color("TextColor"))
                    }
                }
                .disabled(isCreatingZip)
                Button(action: deleteItem) {
                    Text("Delete").foregroundColor(Color("DangerColor"))
                }
            }
            .padding(.top, 8)
        }
        .navigationBarTitle(viewModel.title(recording: recording))
        .background(Color("BackgroundColor"))
        }
        .sheet(isPresented: $isSharing) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $isRenaming) {
            RenameSheet(name: $renameText, isPresented: $isRenaming) { name in
                viewModel.rename(recording: recording, to: name) { _ in }
            }
        }
    }

    func shareZip() {
        isCreatingZip = true
        viewModel.createZip(recording: recording) { url in
            isCreatingZip = false
            if let url = url {
                shareURL = url
                isSharing = true
            }
        }
    }

    func deleteItem() {
        viewModel.delete(recording: recording)
        self.presentationMode.wrappedValue.dismiss()
    }
}



struct SessionDetailView_Previews: PreviewProvider {
    static var recording: Recording = { () -> Recording in
        let rec = Recording()
        rec.id = UUID()
        rec.name = "Placeholder name"
        rec.createdAt = Date()
        rec.duration = 30.0
        return rec
    }()

    static var previews: some View {
        SessionDetailView(recording: recording)
    }
}
