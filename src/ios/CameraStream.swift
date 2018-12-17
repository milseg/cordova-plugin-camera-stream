import Foundation
import AVFoundation

struct Log: TextOutputStream {

    func write(_ string: String) {
        let fm = FileManager.default
        //let log = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("log.txt")
        let paths = FileManager.default.urls(for: .documentDirectory, in: .allDomainsMask)
        let documentDirectoryPath = paths.first!
        let log = documentDirectoryPath.appendingPathComponent("log.txt")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(string.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? string.data(using: .utf8)?.write(to: log)
        }
    }
}

var logger = Log()

@objc(CameraStream)
class CameraStream: CDVPlugin, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var position = AVCaptureDevicePosition.front
    private let myPreset = AVCaptureSessionPresetMedium
    private let sessionQueue = DispatchQueue(label: "session queue")
    private let captureSession = AVCaptureSession()
    private let context = CIContext()

    private var permissionGranted = false
    private var mainCommand: CDVInvokedUrlCommand?
    private var isSendingFrames = false
    //let sessionQueue = DispatchQueue.main//(label: "camerabase64")
    func customlog(str: String) {
      print(str, Date(), to: &logger)
    }
    @objc(startCapture:)
    func startCapture(command: CDVInvokedUrlCommand) {
        customlog(str: "Start capture")
        //commandDelegate.evalJs("alert('Start capture')")
        checkPermission()
        sessionQueue.async { [unowned self] in
            self.configureSession(command: command)
            self.captureSession.startRunning()
        }
    }

    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo) {
        case .authorized:
            // The user has previously granted access to the camera.
            customlog(str: "Camera previously authorized")
            //commandDelegate.evalJs("alert('Camera authorized')")
            permissionGranted = true
            break
        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant
             video access. We suspend the session queue to delay session
             setup until the access request has completed.

             Note that audio access will be implicitly requested when we
             create an AVCaptureDeviceInput for audio during session setup.
             */
            sessionQueue.suspend()
            customlog(str: "Requesting camera access")
            //commandDelegate.evalJs("alert('Requesting camera access')")
            AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo, completionHandler: { [unowned self] granted in
                if !granted {
                    self.customlog(str: "Access not granted")
                    self.permissionGranted = false
                } else {
                    self.customlog(str: "Access granted")
                    self.permissionGranted = true
                }
                self.sessionQueue.resume()
            })
        default:
            // The user has previously denied access.
            customlog(str: "User denied camera access")
            //commandDelegate.evalJs("alert('User denied camera access')")
            permissionGranted = false
        }
    }

    func configureSession(command: CDVInvokedUrlCommand) {
        // Selecting the camera from the device
        guard permissionGranted else { customlog(str: "No permission to configure session"); return }
        captureSession.sessionPreset = myPreset
        let cameraString = command.arguments[0] as? String ?? "front"
        switch cameraString {
        case "back":
            position = AVCaptureDevicePosition.back
            break
        default:
            position = AVCaptureDevicePosition.front
        }
        let camera = selectCaptureDevice()
        guard let captureDeviceInput = try? AVCaptureDeviceInput(device: camera) else { customlog(str: "Nao foi possivel montar input"); return }
        guard captureSession.canAddInput(captureDeviceInput) else { customlog(str: "Input cant be added"); return }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sample buffer"))
        guard captureSession.canAddOutput(videoOutput) else { customlog(str: "Cant add video output"); return }
        captureSession.addOutput(videoOutput)
        guard let connection = videoOutput.connection(withMediaType: AVFoundation.AVMediaTypeVideo) else { customlog(str: "Couldnt make connection"); return }
        guard connection.isVideoOrientationSupported else { customlog(str: "Video orientation unsuportted"); return }
        guard connection.isVideoMirroringSupported else { customlog(str: "Video orientation unsuportted"); return }
        connection.videoOrientation = .portrait
        connection.isVideoMirrored = (position == AVCaptureDevicePosition.front)
    }

    private func selectCaptureDevice() -> AVCaptureDevice? {
        return AVCaptureDevice.devices().filter {
            ($0 as AnyObject).hasMediaType(AVMediaTypeVideo) &&
                ($0 as AnyObject).position == position
            }.first as? AVCaptureDevice
    }

    @objc(pause:)
    func pause(command: CDVInvokedUrlCommand){
        /*if (session?.isRunning)! {
         session?.stopRunning()
         }*/
        captureSession.stopRunning()
    }

    @objc(resume:)
    func resume(command: CDVInvokedUrlCommand){
        /*if (session?.isRunning)! {
         return
         }
         session?.startRunning()*/
        captureSession.startRunning()
    }

    // MARK: Sample buffer to UIImage conversion
    private func imageFromSampleBuffer(sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
      autoreleasepool{
        guard let uiImage = imageFromSampleBuffer(sampleBuffer: sampleBuffer) else { customlog(str: "Couldnt read sample buffer"); return }
        let imageData = UIImageJPEGRepresentation(uiImage, 0.3)
        // Generating a base64 string for cordova's consumption
        let base64 = imageData?.base64EncodedString(options: Data.Base64EncodingOptions.endLineWithLineFeed)
        // Describe the function that is going to be call by the webView frame
        let javascript = "window.cordova.plugins.CameraStream.capture('data:image/jpeg;base64,\(base64!)')"
        commandDelegate.evalJs(javascript)
        /*if let webView = webView {
            if let uiWebView = webView as? UIWebView {
                // Evaluating the function
                if !isSendingFrames {
                  isSendingFrames = true
                  customlog(str: "Sending frames started")
                  uiWebView.stringByEvaluatingJavaScript(from: "alert('Sending frames '+'\(base64!)'.substr(0,120))")
                }
                uiWebView.stringByEvaluatingJavaScript(from: javascript)
            } else {
              customlog(str: "Could not start webview")
              if !isSendingFrames {
                isSendingFrames = true
                customlog(str: "Sending frames started")
                commandDelegate.evalJs("alert('Sending frames '+'\(base64!)'.substr(0,120))")
              }
              commandDelegate.evalJs(javascript)
            }
        } else {
            customlog(str: "Webview is nil")
            //commandDelegate.evalJs(javascript)
        }*/
        //DispatchQueue.main.async { [unowned self] in
            //self.delegate?.captured(image: uiImage)
        //}
      }
    }
}
