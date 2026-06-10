// swiftlint:disable file_length missing_docs
import Foundation
#if (os(iOS) || os(tvOS)) && !SENTRY_NO_UI_FRAMEWORK
@_implementationOnly import _SentryPrivate
import UIKit

// swiftlint:disable type_body_length
@objcMembers
@_spi(Private) public class SentrySessionReplay: NSObject {
    public private(set) var isFullSession = false
    public private(set) var sessionReplayId: SentryId?

    private var urlToCache: URL?
    private var rootView: UIView?
    private var lastScreenshotAt: Date?
    private var nextScreenshotAt: Date?
    private var videoSegmentStart: Date?
    private var sessionStart: Date?
    private var imageCollection: [UIImage] = []
    private weak var delegate: SentrySessionReplayDelegate?
    private var currentSegmentId = 0
    private var processingScreenshot = false
    private var reachedMaximumDuration = false
    private var replayType = SentryReplayType.buffer
    private(set) var isSessionPaused = false
    
    private let replayOptions: SentryReplayOptions
    private let replayMaker: SentryReplayVideoMaker
    private let dateProvider: SentryCurrentDateProvider
    private let touchTracker: SentryTouchTracker?
    private let lock = NSLock()
    private let captureGuard = SentrySessionReplayCaptureGuard()
    private var adaptiveScreenshotInterval: TimeInterval = 0
    private var deferredScreenshotStart: Date?
    private let screenshotIntervalTolerance: TimeInterval = 0.001
    private var captureRunLoopObserver: CFRunLoopObserver?
    private var didProcessRunLoopWork = false
    private var isCaptureSchedulerRunning = false
    private var nextCaptureActivityCheckAt: Date?
    private var pendingSegmentEnd: Date?
    private var pendingPauseSegmentEnd: Date?
    public var replayTags: [String: Any]?

    var isRunning: Bool {
        isCaptureSchedulerRunning
    }
    
    public var screenshotProvider: SentryViewScreenshotProvider
    public var breadcrumbConverter: SentryReplayBreadcrumbConverter
    
    public init(
        replayOptions: SentryReplayOptions,
        replayFolderPath: URL,
        screenshotProvider: SentryViewScreenshotProvider,
        replayMaker: SentryReplayVideoMaker,
        breadcrumbConverter: SentryReplayBreadcrumbConverter,
        touchTracker: SentryTouchTracker?,
        dateProvider: SentryCurrentDateProvider,
        delegate: SentrySessionReplayDelegate
    ) {
        self.replayOptions = replayOptions
        self.dateProvider = dateProvider
        self.delegate = delegate
        self.screenshotProvider = screenshotProvider
        self.urlToCache = replayFolderPath
        self.replayMaker = replayMaker
        self.breadcrumbConverter = breadcrumbConverter
        self.touchTracker = touchTracker
    }
    
    deinit {
        stopCaptureScheduler()
    }
    
    public func start(rootView: UIView?, fullSession: Bool) {
        SentrySDKLog.debug("[Session Replay] Starting session replay with full session: \(fullSession)")
        guard !isRunning else {
            SentrySDKLog.debug("[Session Replay] Session replay is already running, not starting again")
            return
        }
        
        self.rootView = rootView
        let now = dateProvider.date()
        resetCapturePacing(at: now)
        startCaptureScheduler()
        lock.synchronized {
            videoSegmentStart = nil
            pendingSegmentEnd = nil
            pendingPauseSegmentEnd = nil
        }
        currentSegmentId = 0
        sessionReplayId = SentryId()
        imageCollection = []
        replayType = fullSession ? .session : .buffer

        if fullSession {
            startFullReplay(startedAt: lastScreenshotAt)
        }
    }

    private func startFullReplay(startedAt: Date?) {
        SentrySDKLog.debug("[Session Replay] Starting full session replay")
        sessionStart = startedAt
        lock.synchronized {
            videoSegmentStart = startedAt
        }
        isFullSession = true
        guard let sessionReplayId = sessionReplayId else { return }
        delegate?.sessionReplayStarted(replayId: sessionReplayId)
    }

    public func pauseSessionMode() {
        SentrySDKLog.debug("[Session Replay] Pausing session mode")
        lock.lock()
        defer { lock.unlock() }
        
        self.isSessionPaused = true
        self.videoSegmentStart = nil
    }
    
    public func pause() {
        SentrySDKLog.debug("[Session Replay] Pausing session")
        stopCaptureScheduler()

        let pauseDate = dateProvider.date()
        var shouldPreparePauseSegment = false
        lock.lock()
        if isFullSession {
            if pendingSegmentEnd == nil {
                shouldPreparePauseSegment = true
            } else {
                pendingPauseSegmentEnd = pauseDate
            }
        }
        isSessionPaused = false
        lock.unlock()

        if shouldPreparePauseSegment {
            prepareSegmentUntil(date: pauseDate)
        }
    }

    public func resume() {
        SentrySDKLog.debug("[Session Replay] Resuming session")
        lock.lock()
        defer { lock.unlock() }
        
        if isSessionPaused {
            isSessionPaused = false
            return
        }
        
        guard !reachedMaximumDuration else { 
            SentrySDKLog.warning("[Session Replay] Reached maximum duration, not resuming")
            return 
        }
        guard !isRunning else { 
            SentrySDKLog.debug("[Session Replay] Session is already running, not resuming")
            return 
        }
        
        videoSegmentStart = nil
        let now = dateProvider.date()
        resetCapturePacing(at: now)
        startCaptureScheduler()
    }

    public func captureReplayFor(event: Event) {
        SentrySDKLog.debug("[Session Replay] Capturing replay for event: \(event)")
        guard isRunning else { 
            SentrySDKLog.debug("[Session Replay] Session replay is not running, not capturing replay")
            return 
        }

        if isFullSession {
            SentrySDKLog.info("[Session Replay] Session replay is in full session mode, setting event context")
            setEventContext(event: event)
            return
        }

        guard (event.error != nil || event.exceptions?.isEmpty == false) && captureReplay(replayType: .buffer) else {
            SentrySDKLog.debug("[Session Replay] Not capturing replay, reason: event is not an error or exceptions are empty")
            return
        }
        
        setEventContext(event: event)
    }

    @discardableResult
    public func captureReplay() -> Bool {
        captureReplay(replayType: .buffer)
    }

    @discardableResult
    func captureReplay(replayType: SentryReplayType) -> Bool {
        guard isRunning else {
            SentrySDKLog.debug("[Session Replay] Session replay is not running, not capturing replay")
            return false
        }
        guard !isFullSession else {
            SentrySDKLog.debug("[Session Replay] Session replay is full, not capturing replay")
            return true
        }

        guard delegate?.sessionReplayShouldCaptureReplayForError() == true else {
            SentrySDKLog.debug("[Session Replay] Not capturing replay, reason: delegate should not capture replay")
            return false
        }

        self.replayType = replayType
        startFullReplay(startedAt: lastScreenshotAt)
        let replayStart = dateProvider.date().addingTimeInterval(-replayOptions.errorReplayDuration - (Double(replayOptions.frameRate) / 2.0))

        createAndCaptureInBackground(startedAt: replayStart, replayType: replayType)
        return true
    }

    private func setEventContext(event: Event) {
        SentrySDKLog.debug("[Session Replay] Setting event context")
        guard let sessionReplayId = sessionReplayId, event.type != "replay_video" else { 
            SentrySDKLog.debug("[Session Replay] Not setting event context, reason: session replay id is nil or event type is replay_video")
            return 
        }

        var context = event.context ?? [:]
        context["replay"] = ["replay_id": sessionReplayId.sentryIdString]
        event.context = context

        var tags = ["replayId": sessionReplayId.sentryIdString]
        if let eventTags = event.tags {
            tags.merge(eventTags) { (_, new) in new }
        }
        event.tags = tags
    }

    @objc
    private func newFrame(_ sender: Any?) {
        captureFrameIfNeeded()
    }

    #if SENTRY_TEST || SENTRY_TEST_CI || DEBUG
    func captureFrameForTesting(isInteractiveRunLoopMode: Bool = false) {
        captureFrameIfNeeded(isInteractiveRunLoopMode: isInteractiveRunLoopMode)
    }
    #endif

    private func captureFrameIfNeeded(isInteractiveRunLoopMode: Bool = false) {
        guard isRunning else { return }

        let now = dateProvider.date()

        if isFullSession && isSessionPaused {
            scheduleNextScreenshot(after: screenshotInterval, from: now)
            return
        }
        
        guard !pauseIfMaximumDurationReached(at: now) else { return }

        guard !isProcessingScreenshot else {
            prepareFullSessionSegmentsIfNeeded(until: now)
            return
        }

        guard shouldCheckCaptureActivity(at: now, isInteractiveRunLoopMode: isInteractiveRunLoopMode) else {
            prepareFullSessionSegmentsIfNeeded(until: now)
            return
        }

        let captureActivityReason = isInteractiveRunLoopMode
            ? nil
            : rootView.flatMap { captureGuard.captureActivityReason(rootView: $0) }
        let isInteractionCapture = isInteractiveRunLoopMode || captureActivityReason == .interaction

        guard shouldCaptureScreenshot(at: now, usesAdaptiveBackoff: !isInteractionCapture) else {
            scheduleNextCaptureActivityCheck(after: nextCaptureActivityCheckInterval(from: now), from: now)
            prepareFullSessionSegmentsIfNeeded(until: now)
            return
        }

        let deferralDecision = screenshotDeferralDecision(
            activityReason: isInteractionCapture ? nil : captureActivityReason,
            at: now
        )
        if deferralDecision == .defer {
            lastScreenshotAt = now
            scheduleNextScreenshot(after: SentrySessionReplayCaptureGuard.captureDeferralInterval, from: now)
            prepareFullSessionSegmentsIfNeeded(until: now)
            return
        }

        guard takeScreenshot(timestamp: now, completion: { [weak self] captureDuration in
            self?.completeScreenshotCapture(
                deferralDecision: deferralDecision,
                isInteractionCapture: isInteractionCapture,
                captureDuration: captureDuration
            )
        }) else {
            let finishedAt = dateProvider.date()
            lastScreenshotAt = finishedAt
            scheduleNextScreenshot(after: screenshotInterval(usesAdaptiveBackoff: !isInteractionCapture), from: finishedAt)
            prepareFullSessionSegmentsIfNeeded(until: finishedAt)
            return
        }
    }

    private var baseScreenshotInterval: TimeInterval {
        1.0 / Double(replayOptions.frameRate)
    }

    private var isProcessingScreenshot: Bool {
        lock.synchronized {
            processingScreenshot
        }
    }

    private func resetCapturePacing(at date: Date) {
        lastScreenshotAt = date
        adaptiveScreenshotInterval = 0
        deferredScreenshotStart = nil
        scheduleNextScreenshot(after: screenshotInterval, from: date)
    }

    private func completeScreenshotCapture(
        deferralDecision: ScreenshotDeferralDecision,
        isInteractionCapture: Bool,
        captureDuration: TimeInterval
    ) {
        runOnMainThread { [weak self] in
            guard let self = self else { return }

            if deferralDecision == .captureAfterDeferral {
                self.adaptiveScreenshotInterval = 0
            } else if !isInteractionCapture {
                self.updateAdaptiveScreenshotInterval(captureDuration)
            }

            let finishedAt = self.dateProvider.date()
            self.lastScreenshotAt = finishedAt
            self.scheduleNextScreenshot(after: self.screenshotInterval(usesAdaptiveBackoff: !isInteractionCapture), from: finishedAt)
            self.prepareFullSessionSegmentsIfNeeded(until: finishedAt)
        }
    }

    private var screenshotInterval: TimeInterval {
        screenshotInterval(usesAdaptiveBackoff: true)
    }

    private func screenshotInterval(usesAdaptiveBackoff: Bool) -> TimeInterval {
        usesAdaptiveBackoff ? max(baseScreenshotInterval, adaptiveScreenshotInterval) : baseScreenshotInterval
    }

    private func shouldCaptureScreenshot(at date: Date, usesAdaptiveBackoff: Bool = true) -> Bool {
        if !usesAdaptiveBackoff, let lastScreenshotAt = lastScreenshotAt {
            let nextScreenshotAt = lastScreenshotAt.addingTimeInterval(baseScreenshotInterval)
            return date.timeIntervalSince(nextScreenshotAt) >= -screenshotIntervalTolerance
        }

        guard let nextScreenshotAt = nextScreenshotAt else { return true }
        return date.timeIntervalSince(nextScreenshotAt) >= -screenshotIntervalTolerance
    }

    private func scheduleNextScreenshot(after interval: TimeInterval, from date: Date) {
        nextScreenshotAt = date.addingTimeInterval(interval)
        scheduleNextCaptureActivityCheck(after: min(interval, baseScreenshotInterval), from: date)
    }

    private func shouldCheckCaptureActivity(at date: Date, isInteractiveRunLoopMode: Bool) -> Bool {
        if isInteractiveRunLoopMode {
            return shouldCaptureScreenshot(at: date, usesAdaptiveBackoff: false)
        }

        if shouldCaptureScreenshot(at: date) {
            return true
        }

        guard let nextCaptureActivityCheckAt = nextCaptureActivityCheckAt else { return true }
        return date.timeIntervalSince(nextCaptureActivityCheckAt) >= -screenshotIntervalTolerance
    }

    private func nextCaptureActivityCheckInterval(from date: Date) -> TimeInterval {
        guard let nextScreenshotAt = nextScreenshotAt else { return baseScreenshotInterval }
        return max(0, min(baseScreenshotInterval, nextScreenshotAt.timeIntervalSince(date)))
    }

    private func scheduleNextCaptureActivityCheck(after interval: TimeInterval, from date: Date) {
        nextCaptureActivityCheckAt = date.addingTimeInterval(interval)
    }

    private func pauseIfMaximumDurationReached(at date: Date) -> Bool {
        guard let sessionStart = sessionStart,
            isFullSession,
            date.timeIntervalSince(sessionStart) > replayOptions.maximumDuration
        else { return false }

        SentrySDKLog.debug("[Session Replay] Reached maximum duration, pausing session")
        reachedMaximumDuration = true
        pause()
        delegate?.sessionReplayEnded()
        return true
    }

    private func startCaptureScheduler() {
        guard !isCaptureSchedulerRunning else { return }

        isCaptureSchedulerRunning = true
        installCaptureRunLoopObserver()
    }

    private func stopCaptureScheduler() {
        isCaptureSchedulerRunning = false
        didProcessRunLoopWork = false
        nextCaptureActivityCheckAt = nil

        if let captureRunLoopObserver = captureRunLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), captureRunLoopObserver, .commonModes)
            self.captureRunLoopObserver = nil
        }
    }

    private func installCaptureRunLoopObserver() {
        guard captureRunLoopObserver == nil else { return }

        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeTimers.rawValue
            | CFRunLoopActivity.beforeSources.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.exit.rawValue

        captureRunLoopObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,
            CFIndex.max
        ) { [weak self] observer, activity in
            guard let observer = observer,
                CFRunLoopObserverIsValid(observer)
            else { return }

            self?.captureOnRunLoopActivity(
                activity,
                in: CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent())
            )
        }

        if let captureRunLoopObserver = captureRunLoopObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), captureRunLoopObserver, .commonModes)
        }
    }

    private func captureOnRunLoopActivity(_ activity: CFRunLoopActivity, in currentMode: CFRunLoopMode?) {
        guard isCaptureSchedulerRunning else { return }
        let isInteractiveRunLoopMode = isInteractiveRunLoopMode(currentMode)

        if activity.contains(.afterWaiting)
            || activity.contains(.beforeTimers)
            || activity.contains(.beforeSources) {
            didProcessRunLoopWork = true
            return
        }

        guard activity.contains(.beforeWaiting) || activity.contains(.exit) else { return }
        guard didProcessRunLoopWork else { return }

        didProcessRunLoopWork = false
        captureFrameIfNeeded(isInteractiveRunLoopMode: isInteractiveRunLoopMode)
    }

    private func isInteractiveRunLoopMode(_ currentMode: CFRunLoopMode?) -> Bool {
        guard let currentMode = currentMode else { return false }
        return CFEqual(currentMode.rawValue, RunLoop.Mode.tracking.rawValue as CFString)
    }

    private enum ScreenshotDeferralDecision {
        case none
        case `defer`
        case captureAfterDeferral
    }

    private func screenshotDeferralDecision(
        activityReason: SentrySessionReplayCaptureGuard.CaptureActivityReason?,
        at date: Date
    ) -> ScreenshotDeferralDecision {
        guard let activityReason = activityReason else {
            deferredScreenshotStart = nil
            return .none
        }

        guard activityReason == .animation else {
            deferredScreenshotStart = nil
            return .none
        }

        guard let deferredScreenshotStart = deferredScreenshotStart else {
            self.deferredScreenshotStart = date
            return .defer
        }

        let deferralDuration = date.timeIntervalSince(deferredScreenshotStart)
        guard deferralDuration >= SentrySessionReplayCaptureGuard.maximumAnimationCaptureDeferralInterval else {
            return .defer
        }

        SentrySDKLog.debug("[Session Replay] Forcing screenshot after deferring for \(deferralDuration)s")
        self.deferredScreenshotStart = nil
        return .captureAfterDeferral
    }

    private func updateAdaptiveScreenshotInterval(_ captureDuration: TimeInterval) {
        guard captureDuration > 0 else { return }

        let baseInterval = 1.0 / Double(replayOptions.frameRate)
        guard captureDuration >= SentrySessionReplayCaptureGuard.slowCaptureThreshold else {
            guard adaptiveScreenshotInterval > 0 else { return }

            let nextInterval = adaptiveScreenshotInterval / 2
            adaptiveScreenshotInterval = nextInterval <= baseInterval ? 0 : nextInterval
            return
        }

        let nextInterval = adaptiveScreenshotInterval > 0 ? adaptiveScreenshotInterval * 2 : baseInterval * 2
        adaptiveScreenshotInterval = min(nextInterval, SentrySessionReplayCaptureGuard.maximumAdaptiveCaptureInterval)
        SentrySDKLog.debug("[Session Replay] Screenshot capture took \(captureDuration)s, backing off to \(adaptiveScreenshotInterval)s")
    }

    private func prepareFullSessionSegmentsIfNeeded(until date: Date) {
        guard isFullSession else { return }
        let sessionSegmentDuration = replayOptions.sessionSegmentDuration
        guard sessionSegmentDuration > 0 else {
            SentrySDKLog.debug("[Session Replay] Not preparing segment, reason: session segment duration is not positive")
            return
        }

        let segmentStart: Date
        let segmentEnd: Date
        lock.lock()
        guard pendingSegmentEnd == nil else {
            lock.unlock()
            return
        }
        if videoSegmentStart == nil {
            videoSegmentStart = sessionStart ?? date
        }

        guard let currentSegmentStart = videoSegmentStart else {
            lock.unlock()
            return
        }
        guard date.timeIntervalSince(currentSegmentStart) >= sessionSegmentDuration else {
            lock.unlock()
            return
        }

        segmentStart = currentSegmentStart
        segmentEnd = segmentStart.addingTimeInterval(sessionSegmentDuration)
        pendingSegmentEnd = segmentEnd
        lock.unlock()

        if !prepareSegment(from: segmentStart, until: segmentEnd, completion: { [weak self] in
            self?.completePendingSegment(until: segmentEnd)
        }) {
            lock.synchronized {
                if pendingSegmentEnd == segmentEnd {
                    pendingSegmentEnd = nil
                }
            }
        }
    }

    private func completePendingSegment(until segmentEnd: Date) {
        lock.lock()
        if pendingSegmentEnd == segmentEnd {
            pendingSegmentEnd = nil
        }
        let pauseSegmentEnd = pendingPauseSegmentEnd
        pendingPauseSegmentEnd = nil
        lock.unlock()

        if let pauseSegmentEnd = pauseSegmentEnd {
            prepareSegmentUntil(date: pauseSegmentEnd)
        }
    }

    private func prepareSegmentUntil(date: Date) {
        let segmentStart = lock.synchronized {
            videoSegmentStart ?? sessionStart ?? dateProvider.date().addingTimeInterval(-replayOptions.sessionSegmentDuration)
        }
        prepareSegment(from: segmentStart, until: date)
        lock.synchronized {
            guard let currentSegmentStart = videoSegmentStart else {
                videoSegmentStart = date
                return
            }
            if date > currentSegmentStart {
                videoSegmentStart = date
            }
        }
    }

    @discardableResult
    private func prepareSegment(
        from segmentStart: Date,
        until date: Date,
        completion: (() -> Void)? = nil
    ) -> Bool {
        SentrySDKLog.debug("[Session Replay] Preparing segment until date: \(date)")
        guard date > segmentStart else {
            SentrySDKLog.debug("[Session Replay] Not preparing segment, reason: segment duration is empty")
            return false
        }

        guard var pathToSegment = urlToCache?.appendingPathComponent("segments") else { 
            SentrySDKLog.debug("[Session Replay] Not preparing segment, reason: could not create path to segments folder")
            return false
        }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: pathToSegment.path) {
            do {
                try fileManager.createDirectory(atPath: pathToSegment.path, withIntermediateDirectories: true, attributes: nil)
                SentrySDKLog.debug("[Session Replay] Created segments folder at path: \(pathToSegment.path)")
            } catch {
                SentrySDKLog.debug("Can't create session replay segment folder. Error: \(error.localizedDescription)")
                return false
            }
        }

        pathToSegment = pathToSegment.appendingPathComponent("\(currentSegmentId).mp4")

        createAndCaptureInBackground(
            startedAt: segmentStart,
            endedAt: date,
            replayType: replayType,
            completion: completion
        )
        return true
    }

    private func createAndCaptureInBackground(startedAt: Date, replayType: SentryReplayType) {
        createAndCaptureInBackground(startedAt: startedAt, endedAt: dateProvider.date(), replayType: replayType)
    }

    private func createAndCaptureInBackground(
        startedAt: Date,
        endedAt: Date,
        replayType: SentryReplayType,
        completion: (() -> Void)? = nil
    ) {
        SentrySDKLog.debug("[Session Replay] Creating replay video started at date: \(startedAt), replayType: \(replayType)")
        // Creating a video is computationally expensive, therefore perform it on a background queue.
        self.replayMaker.createVideoInBackgroundWith(beginning: startedAt, end: endedAt) { videos in
            SentrySDKLog.debug("[Session Replay] Created replay video with \(videos.count) segments")
            for video in videos {
                self.processNewlyAvailableSegment(videoInfo: video, replayType: replayType)
            }
            completion?()
            SentrySDKLog.debug("[Session Replay] Finished processing replay video with \(videos.count) segments")
        }
    }

    private func processNewlyAvailableSegment(videoInfo: SentryVideoInfo, replayType: SentryReplayType) {
        SentrySDKLog.debug("[Session Replay] Processing new segment available for replayType: \(replayType), videoInfo: \(videoInfo)")
        guard let sessionReplayId = sessionReplayId else {
            SentrySDKLog.warning("[Session Replay] No session replay ID available, ignoring segment.")
            return
        }
        captureSegment(segment: currentSegmentId, video: videoInfo, replayId: sessionReplayId, replayType: replayType)
        replayMaker.releaseFramesUntil(videoInfo.end)
        lock.synchronized {
            if let segmentStart = videoSegmentStart {
                if videoInfo.end > segmentStart {
                    videoSegmentStart = videoInfo.end
                }
            } else {
                videoSegmentStart = videoInfo.end
            }
        }
        currentSegmentId++
        SentrySDKLog.debug("[Session Replay] Processed segment, incrementing currentSegmentId to: \(currentSegmentId)")
    }
    
    private func captureSegment(segment: Int, video: SentryVideoInfo, replayId: SentryId, replayType: SentryReplayType) {
        SentrySDKLog.debug("[Session Replay] Capturing segment: \(segment), replayId: \(replayId), replayType: \(replayType)")
        let replayEvent = SentryReplayEvent(eventId: replayId, replayStartTimestamp: video.start, replayType: replayType, segmentId: segment)
        
        replayEvent.sdk = self.replayOptions.sdkInfo
        replayEvent.timestamp = video.end
        replayEvent.urls = video.screens
        
        let breadcrumbs = delegate?.breadcrumbsForSessionReplay() ?? []

        var events = convertBreadcrumbs(breadcrumbs: breadcrumbs, from: video.start, until: video.end)
        if let touchTracker = touchTracker {
            SentrySDKLog.debug("[Session Replay] Adding touch tracker events")
            events.append(contentsOf: touchTracker.replayEvents(from: video.start, until: video.end))
            touchTracker.flushFinishedEvents()
        }
        
        if segment == 0 {
            SentrySDKLog.debug("[Session Replay] Adding options event to segment 0")
            if let customOptions = replayTags {
                events.append(SentryRRWebOptionsEvent(timestamp: video.start, customOptions: customOptions))
            } else {
                events.append(SentryRRWebOptionsEvent(timestamp: video.start, options: self.replayOptions))
            }
        }
        
        let recording = SentryReplayRecording(segmentId: segment, video: video, extraEvents: events)

        delegate?.sessionReplayNewSegment(replayEvent: replayEvent, replayRecording: recording, videoUrl: video.path)

        do {
            try FileManager.default.removeItem(at: video.path)
            SentrySDKLog.debug("[Session Replay] Deleted replay segment from disk")
        } catch {
            SentrySDKLog.debug("[Session Replay] Could not delete replay segment from disk: \(error)")
        }
    }
    
    private func convertBreadcrumbs(breadcrumbs: [Breadcrumb], from: Date, until: Date) -> [any SentryRRWebEventProtocol] {
        SentrySDKLog.debug("[Session Replay] Converting breadcrumbs from: \(from) until: \(until)")
        var filteredResult: [Breadcrumb] = []
        var lastNavigationTime: Date = from.addingTimeInterval(-1)
        
        for breadcrumb in breadcrumbs {
            guard let time = breadcrumb.timestamp, time >= from && time < until else { 
                continue
            }
            
            // If it's a "navigation" breadcrumb, check the timestamp difference from the previous breadcrumb.
            // Skip any breadcrumbs that have occurred within 50ms of the last one,
            // as these represent child view controllers that don’t need their own navigation breadcrumb.
            if breadcrumb.type == "navigation" {
                if time.timeIntervalSince(lastNavigationTime) < 0.05 { continue }
                lastNavigationTime = time
            }
            filteredResult.append(breadcrumb)
        }
        
        return filteredResult.compactMap(breadcrumbConverter.convert(from:))
    }
    
    private func takeScreenshot(timestamp: Date, completion: @escaping (TimeInterval) -> Void) -> Bool {
        guard let rootView = rootView else {
            SentrySDKLog.debug("[Session Replay] Not taking screenshot, reason: root view is nil")
            return false
        }
        SentrySDKLog.debug("[Session Replay] Taking screenshot of root view: \(rootView)")
        
        lock.lock()
        guard !processingScreenshot else {
            SentrySDKLog.debug("[Session Replay] Not taking screenshot, reason: processing screenshot")
            lock.unlock()
            return false
        }
        processingScreenshot = true
        lock.unlock()
        
        SentrySDKLog.debug("[Session Replay] Getting screenshot from screenshot provider")
        let screenName = delegate?.currentScreenNameForSessionReplay()
        let captureStart = dateProvider.systemTime()
        screenshotProvider.image(view: rootView) { [weak self] screenshot in
            guard let self = self else { return }

            let captureEnd = self.dateProvider.systemTime()
            let captureDuration = captureEnd >= captureStart
                ? TimeInterval(captureEnd - captureStart) / 1_000_000_000
                : 0
            self.newImage(timestamp: timestamp, maskedViewImage: screenshot, forScreen: screenName)
            completion(captureDuration)
        }
        return true
    }

    private func newImage(timestamp: Date, maskedViewImage: UIImage, forScreen screen: String?) {
        SentrySDKLog.debug("[Session Replay] New frame available, for screen: \(screen ?? "nil")")
        lock.synchronized {
            processingScreenshot = false
            replayMaker.addFrameAsync(timestamp: timestamp, maskedViewImage: maskedViewImage, forScreen: screen)
        }
    }

    private func runOnMainThread(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
// swiftlint:enable type_body_length

private final class SentrySessionReplayCaptureGuard {
    static let captureDeferralInterval: TimeInterval = 0.25
    static let slowCaptureThreshold: TimeInterval = 0.05
    static let maximumAdaptiveCaptureInterval: TimeInterval = 5

    private static let activeAnimationThreshold = 4
    static let maximumAnimationCaptureDeferralInterval: TimeInterval = 1

    enum CaptureActivityReason {
        case interaction
        case animation
    }

    func captureActivityReason(rootView: UIView) -> CaptureActivityReason? {
        if containsActiveInteraction(in: rootView) {
            return .interaction
        }

        if activeAnimationCount(in: rootView.layer, upTo: Self.activeAnimationThreshold) >= Self.activeAnimationThreshold {
            return .animation
        }

        return nil
    }

    private func containsActiveInteraction(in view: UIView) -> Bool {
        if let scrollView = view as? UIScrollView, scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking {
            return true
        }

        if let control = view as? UIControl, control.isTracking {
            return true
        }

        if view.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true {
            return true
        }

        return view.subviews.contains { containsActiveInteraction(in: $0) }
    }

    private func activeAnimationCount(in layer: CALayer, upTo limit: Int) -> Int {
        var count = layer.animationKeys()?.count ?? 0
        guard count < limit else { return count }

        for sublayer in layer.sublayers ?? [] {
            count += activeAnimationCount(in: sublayer, upTo: limit - count)
            if count >= limit {
                return count
            }
        }

        return count
    }
}

#endif
// swiftlint:enable file_length missing_docs
