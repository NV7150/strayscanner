//
//  RecordSessionViewController.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import Foundation
import UIKit
import Metal
import ARKit
import CoreData
import CoreMotion

let FpsDividers: [Int] = [1, 2, 4, 12, 60]
let AvailableFpsSettings: [Int] = FpsDividers.map { Int(60 / $0) }
let FpsUserDefaultsKey: String = "FPS"

class MetalView : UIView {
    override class var layerClass: AnyClass {
        get {
            return CAMetalLayer.self
        }
    }
    override var layer: CAMetalLayer {
        return super.layer as! CAMetalLayer
    }
}

class RecordSessionViewController : UIViewController, ARSessionDelegate {
    private var unsupported: Bool = false
    private var arConfiguration: ARWorldTrackingConfiguration?
    private let session = ARSession()
    private let motionManager = CMMotionManager()
    private var renderer: CameraRenderer?
    private var updateLabelTimer: Timer?
    private var startedRecording: Date?
    private var dataContext: NSManagedObjectContext!
    private var datasetEncoder: DatasetEncoder?
    private let imuOperationQueue = OperationQueue()
    private var chosenFpsSetting: Int = 0
    @IBOutlet private var rgbView: MetalView!
    @IBOutlet private var depthView: MetalView!
    @IBOutlet private var recordButton: RecordButton!
    @IBOutlet private var timeLabel: UILabel!
    @IBOutlet weak var fpsButton: UIButton!
    @IBOutlet weak var recordButtonHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var recordButtonWidthConstraint: NSLayoutConstraint!
    @IBOutlet weak var timeLabelWidthConstraint: NSLayoutConstraint!
    private var folderNameField: UITextField!
    private var folderNameFieldHeightConstraint: NSLayoutConstraint?
    var dismissFunction: Optional<() -> Void> = Optional.none
    
    func setDismissFunction(_ fn: Optional<() -> Void>) {
        self.dismissFunction = fn
    }
    override func viewWillAppear(_ animated: Bool) {
        self.chosenFpsSetting = UserDefaults.standard.integer(forKey: FpsUserDefaultsKey)
        updateFpsSetting()
    }

    override func viewDidLoad() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        self.dataContext = appDelegate.persistentContainer.newBackgroundContext()
        self.renderer = CameraRenderer(rgbLayer: rgbView.layer, depthLayer: depthView.layer)

        depthView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
        rgbView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
        
        setViewProperties()
        session.delegate = self

        recordButton.setCallback { (recording: Bool) in
            self.toggleRecording(recording)
        }
        fpsButton.layer.masksToBounds = true
        
        imuOperationQueue.qualityOfService = .userInitiated

        // フォルダ名テキストフィールド
        let tf = UITextField()
        tf.placeholder = "フォルダ名"
        tf.borderStyle = .roundedRect
        tf.returnKeyType = .done
        tf.addTarget(self, action: #selector(dismissFolderNameKeyboard), for: .editingDidEndOnExit)
        tf.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tf)
        self.folderNameField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            tf.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            tf.bottomAnchor.constraint(equalTo: recordButton.topAnchor, constant: -12),
        ])
        let heightC = tf.heightAnchor.constraint(equalToConstant: 44)
        self.folderNameFieldHeightConstraint = heightC
        heightC.isActive = true

    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0 else { return }

        // カメラアスペクト比: 1440/1920 = 3/4（ポートレートbounds）
        // -90°回転後: visual_width = boundsH, visual_height = boundsW
        // セーフエリアにfitさせる（letterbox）
        let aspectW = CGFloat(1440.0 / 1920.0)
        let boundsH: CGFloat
        let boundsW: CGFloat

        if aspectW * safeFrame.width <= safeFrame.height {
            // 幅いっぱい（ポートレートiPad等）
            boundsH = safeFrame.width
            boundsW = safeFrame.width * aspectW
        } else {
            // 高さいっぱい（ランドスケープiPad等）
            boundsW = safeFrame.height
            boundsH = safeFrame.height / aspectW
        }

        // 回転後の上端をセーフエリア上端に揃える
        // visual_top = center_y - boundsW/2 = safeFrame.minY
        // → center_y = safeFrame.minY + boundsW/2
        let center = CGPoint(x: safeFrame.midX, y: safeFrame.minY + boundsW / 2)
        let rotation = CGAffineTransform(rotationAngle: -.pi / 2)

        depthView.bounds = CGRect(x: 0, y: 0, width: boundsW, height: boundsH)
        depthView.center = center
        depthView.transform = rotation

        rgbView.bounds = depthView.bounds
        rgbView.center = depthView.center
        rgbView.transform = depthView.transform

        // UIスケール（短辺基準、上限2倍）
        let shortSide = min(safeFrame.width, safeFrame.height)
        let scale = min(shortSide / 390.0, 2.0)

        let btnSize = (90.0 * scale).rounded()
        recordButtonHeightConstraint.constant = btnSize
        recordButtonWidthConstraint.constant  = btnSize

        timeLabelWidthConstraint.constant = (200.0 * scale).rounded()

        timeLabel.font = UIFont(name: "CourierNewPSMT", size: (24.0 * scale).rounded())
        fpsButton.titleLabel?.font = UIFont(name: "CourierNewPSMT", size: (19.0 * scale).rounded())
        fpsButton.layer.cornerRadius = (12.0 * scale).rounded()

        folderNameFieldHeightConstraint?.constant = (44.0 * scale).rounded()
        folderNameField?.font = UIFont.systemFont(ofSize: (17.0 * scale).rounded())
    }

    override func viewDidDisappear(_ animated: Bool) {
        session.pause();
    }

    override func viewWillDisappear(_ animated: Bool) {
        updateLabelTimer?.invalidate()
        datasetEncoder = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        startSession()
    }

    private func startSession() {
        let config = ARWorldTrackingConfiguration()
        arConfiguration = config
        if !ARWorldTrackingConfiguration.isSupported || !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            print("AR is not supported.")
            unsupported = true
        } else {
            config.frameSemantics.insert(.sceneDepth)
            session.run(config)
        }
    }
    
    private func startRawIMU() {
        if self.motionManager.isAccelerometerAvailable {
            self.motionManager.accelerometerUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startAccelerometerUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving accelerometer data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawAccelerometer(data: data)
            }
        } else {
            print("Accelerometer not available on this device.")
        }

        if self.motionManager.isGyroAvailable {
            self.motionManager.gyroUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startGyroUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving gyroscope data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawGyroscope(data: data)
            }
        } else {
            print("Gyroscope not available on this device.")
        }
    }

    private func stopRawIMU() {
        if self.motionManager.isAccelerometerActive {
            self.motionManager.stopAccelerometerUpdates()
            print("Stopped accelerometer updates.")
        }
        if self.motionManager.isGyroActive {
            self.motionManager.stopGyroUpdates()
            print("Stopped gyroscope updates.")
        }
    }
    
    private func toggleRecording(_ recording: Bool) {
        if unsupported {
            showUnsupportedAlert()
            return
        }
        if recording && self.startedRecording == nil {
            startRecording()
        } else if self.startedRecording != nil && !recording {
            stopRecording()
        } else {
            print("This should not happen. We are either not recording and want to stop, or we are recording and want to start.")
        }
    }

    private func startRecording() {
        self.startedRecording = Date()
        updateTime()
        updateLabelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.updateTime()
        }
        startRawIMU()
        datasetEncoder = DatasetEncoder(arConfiguration: arConfiguration!, fpsDivider: FpsDividers[chosenFpsSetting], folderName: folderNameField.text)
        startRawIMU()
    }

    private func stopRecording() {
        guard let started = self.startedRecording else {
            print("Hasn't started recording. Something is wrong.")
            return
        }
        startedRecording = nil
        updateLabelTimer?.invalidate()
        updateLabelTimer = nil
        // Stop IMU updates
        stopRawIMU()
        datasetEncoder?.wrapUp()
        if let encoder = datasetEncoder {
            switch encoder.status {
                case .allGood:
                    saveRecording(started, encoder)
                case .videoEncodingError:
                    showError()
                case .directoryCreationError:
                    showError()
            }
        } else {
            print("No dataset encoder. Something is wrong.")
        }
        self.dismissFunction?()
    }

    private func saveRecording(_ started: Date, _ encoder: DatasetEncoder) {
        let sessionCount = countSessions()

        let duration = Date().timeIntervalSince(started)
        let entity = NSEntityDescription.entity(forEntityName: "Recording", in: self.dataContext)!
        let recording: Recording = Recording(entity: entity, insertInto: self.dataContext)
        recording.setValue(datasetEncoder!.id, forKey: "id")
        recording.setValue(duration, forKey: "duration")
        recording.setValue(started, forKey: "createdAt")
        let customName = folderNameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        recording.setValue(customName.isEmpty ? "Recording \(sessionCount)" : customName, forKey: "name")
        recording.setValue(datasetEncoder!.rgbFilePath.relativeString, forKey: "rgbFilePath")
        recording.setValue(datasetEncoder!.depthFilePath.relativeString, forKey: "depthFilePath")
        do {
            try self.dataContext.save()
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
        }
    }

    private func showError() {
        let controller = UIAlertController(title: "Error",
            message: "Something went wrong when encoding video. This should not have happened. You might want to file a bug report.",
            preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Default Action"), style: .default, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        }))
        self.present(controller, animated: true, completion: nil)
    }

    private func updateTime() {
        guard let started = self.startedRecording else { return }
        let seconds = Date().timeIntervalSince(started)
        let minutes: Int = Int(floor(seconds / 60).truncatingRemainder(dividingBy: 60))
        let hours: Int = Int(floor(seconds / 3600))
        let roundSeconds: Int = Int(floor(seconds.truncatingRemainder(dividingBy: 60)))
        self.timeLabel.text = String(format: "%02d:%02d:%02d", hours, minutes, roundSeconds)
    }

    @objc private func dismissFolderNameKeyboard() {
        folderNameField.resignFirstResponder()
    }

    @objc func viewTapped() {
        switch renderer!.renderMode {
            case .depth:
                renderer!.renderMode = RenderMode.rgb
                rgbView.isHidden = false
                depthView.isHidden = true
            case .rgb:
                renderer!.renderMode = RenderMode.depth
                depthView.isHidden = false
                rgbView.isHidden = true
        }
    }
    
    @IBAction func fpsButtonTapped() {
        chosenFpsSetting = (chosenFpsSetting + 1) % AvailableFpsSettings.count
        updateFpsSetting()
        UserDefaults.standard.set(chosenFpsSetting, forKey: FpsUserDefaultsKey)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        self.renderer!.render(frame: frame, viewportSize: depthView.bounds.size)
        if startedRecording != nil {
            if let encoder = datasetEncoder {
                encoder.add(frame: frame)
            } else {
                print("There is no video encoder. That can't be good.")
            }
        }
    }

    private func setViewProperties() {
        self.view.backgroundColor = UIColor(named: "BackgroundColor")
    }
    
    private func updateFpsSetting() {
        let fps = AvailableFpsSettings[chosenFpsSetting]
        let buttonLabel: String = "\(fps) fps"
        fpsButton.setTitle(buttonLabel, for: UIControl.State.normal)
    }
    
    private func showUnsupportedAlert() {
        let alert = UIAlertController(title: "Unsupported device", message: "This device doesn't seem to have the required level of ARKit support.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            self.dismissFunction?()
        }))
        self.present(alert, animated: true)
    }
    
    private func countSessions() -> Int {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return 0 }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        do {
            let fetched: [NSManagedObject] = try appDelegate.persistentContainer.viewContext.fetch(request)
            return fetched.count
        } catch let error {
            print("Could not fetch sessions for counting. \(error.localizedDescription)")
        }
        return 0
    }
}
