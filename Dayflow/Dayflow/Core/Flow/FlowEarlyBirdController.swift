//
//  FlowEarlyBirdController.swift
//  Dayflow
//
//  Shows the early-bird card for the first hour Dayflow is on each day. A day
//  runs 4am to 4am, the same as the timeline. The hour starts the first time
//  recording is seen on that day and is remembered across relaunches. The
//  "Schedule alerts" switch in Flow's settings turns it off.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class FlowEarlyBirdController {
  static let shared = FlowEarlyBirdController()

  private static let window: TimeInterval = 60 * 60
  private static let dayKey = "flowEarlyBirdDay"
  private static let startKey = "flowEarlyBirdStartedAt"
  private static let dismissedKey = "flowEarlyBirdDismissedDay"
  private static let enabledKey = "flowEarlyBirdAlerts"
  /// Room around the card for its shadow.
  private static let margin: CGFloat = 16

  private var panel: NSPanel?
  private var cancellables: Set<AnyCancellable> = []
  private var timer: Timer?
  private var shownDeadline: Date?
  private let defaults = UserDefaults.standard

  private init() {}

  /// Set from Flow's settings over the bridge; on until the user turns it off.
  var isEnabled: Bool {
    get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
    set {
      defaults.set(newValue, forKey: Self.enabledKey)
      evaluate()
    }
  }

  /// Starts observing once Flow is enabled.
  func start() {
    guard cancellables.isEmpty else { return }
    AppState.shared.$isRecording
      .map { _ in () }
      .merge(with: FlowSessionMirror.shared.$snapshot.map { _ in () })
      .merge(with: DayflowAuthManager.shared.$flowEnabled.map { _ in () })
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.evaluate() }
      .store(in: &cancellables)

    evaluate()
  }

  private func ensureTimerRunning() {
    guard timer == nil else { return }
    let newTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.evaluate() }
    }
    RunLoop.main.add(newTimer, forMode: .common)
    self.timer = newTimer
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func evaluate() {
    guard isEnabled, DayflowAuthManager.shared.flowEnabled, AppState.shared.isRecording else {
      hide()
      return
    }
    let now = Date()
    let day = now.getDayInfoFor4AMBoundary().dayString
    if defaults.string(forKey: Self.dayKey) != day {
      defaults.set(day, forKey: Self.dayKey)
      defaults.set(now.timeIntervalSince1970, forKey: Self.startKey)
    }
    let deadline = Date(timeIntervalSince1970: defaults.double(forKey: Self.startKey))
      .addingTimeInterval(Self.window)

    guard deadline > now,
      defaults.string(forKey: Self.dismissedKey) != day,
      !FlowSessionMirror.shared.isSessionOn
    else {
      hide()
      return
    }
    show(deadline: deadline)
  }

  /// Closed for the rest of the day, by the X or by starting a session.
  private func dismissForToday() {
    defaults.set(Date().getDayInfoFor4AMBoundary().dayString, forKey: Self.dismissedKey)
    hide()
  }

  private func show(deadline: Date) {
    ensureTimerRunning()
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if shownDeadline != deadline {
      shownDeadline = deadline
      (panel.contentView as? NSHostingView<AnyView>)?.rootView = AnyView(card(deadline: deadline))
    }
    position(panel)
    guard !panel.isVisible else { return }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      panel.animator().alphaValue = 1
    }
  }

  private func hide() {
    stopTimer()
    guard let panel, panel.isVisible else {
      self.panel?.contentView = nil
      self.panel = nil
      shownDeadline = nil
      return
    }
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.2
        panel.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        Task { @MainActor in
          if panel.alphaValue == 0 {
            panel.orderOut(nil)
            self?.panel?.contentView = nil
            self?.panel = nil
            self?.shownDeadline = nil
          }
        }
      })
  }

  private func card(deadline: Date) -> some View {
    FlowEarlyBirdCard(
      deadline: deadline,
      onStart: { [weak self] in
        AnalyticsService.shared.capture("flow_early_bird_card", ["action": "start"])
        self?.dismissForToday()
        FlowSessionMirror.shared.requestStartSession()
      },
      onClose: { [weak self] in
        AnalyticsService.shared.capture("flow_early_bird_card", ["action": "close"])
        self?.dismissForToday()
      }
    )
    .padding(Self.margin)
  }

  private func makePanel() -> NSPanel {
    let size = NSSize(
      width: FlowEarlyBirdCard.size.width + Self.margin * 2,
      height: FlowEarlyBirdCard.size.height + Self.margin * 2)
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false

    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    hostingView.sizingOptions = []
    panel.contentView = hostingView
    return panel
  }

  /// Top right, just under the menu bar, where the design puts it.
  private func position(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    panel.setFrameOrigin(
      NSPoint(
        x: visible.maxX - panel.frame.width - 150,
        y: visible.maxY - panel.frame.height + Self.margin - 6))
  }
}
