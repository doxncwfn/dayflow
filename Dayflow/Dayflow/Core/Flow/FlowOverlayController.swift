//
//  FlowOverlayController.swift
//  Dayflow
//
//  Owns the transparent, non-activating panel that shows the Flow creature at
//  the bottom-right of the screen (toasts, distraction nudges, break state).
//  Presentation decisions live in FlowSessionMirror; this just shows/hides.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class FlowOverlayController {
  static let shared = FlowOverlayController()

  private var panel: NSPanel?
  private var cancellable: AnyCancellable?
  /// What the panel was showing before it hid, so we can pick the matching
  /// exit clip (wave goodbye, climb out of the tub, fly off on the plane).
  private var lastPresentation: FlowOverlayPresentation = .hidden
  private var backdrop: FlowDemoBackdrop?

  private init() {}

  /// Starts observing the mirror lazily when needed.
  func start() {
    guard cancellable == nil else { return }
    cancellable = FlowSessionMirror.shared.$overlay
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        // Act on what is showing now, not on the value this delivery carried:
        // a hide followed straight away by a show (the Flow page re-running a
        // step) would otherwise play the exit clip under a bubble that stays.
        let presentation = FlowSessionMirror.shared.overlay
        if presentation.isDemo {
          if self.backdrop == nil { self.backdrop = FlowDemoBackdrop() }
          self.backdrop?.setShown(true)
        } else {
          self.backdrop?.setShown(false)
        }
        if presentation == .hidden {
          self.hidePanel()
        } else {
          self.lastPresentation = presentation
          self.showPanel()
        }
      }
  }

  private func showPanel() {
    if panel == nil {
      panel = makePanel()
    }
    guard let panel else { return }
    position(panel)
    if !panel.isVisible {
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        panel.animator().alphaValue = 1
      }
    }
  }

  private func hidePanel() {
    guard let panel, panel.isVisible else { return }

    // Let the creature leave in character before the panel fades.
    let exit = exitClip(for: lastPresentation)
    lastPresentation = .hidden
    guard let exit else {
      fadeOut(panel)
      return
    }
    FlowCreaturePlayer.shared.playOnce(exit) { [weak self] in
      // The overlay may have come back mid-exit (a new nudge); leave it up.
      guard FlowSessionMirror.shared.overlay == .hidden else { return }
      self?.panel.map { self?.fadeOut($0) }
    }
  }

  private func exitClip(for presentation: FlowOverlayPresentation) -> FlowCreatureClip? {
    let mirror = FlowSessionMirror.shared
    switch presentation {
    case .hidden: return nil
    case .onBreak: return .bathEnd
    case .nudge(_, true), .demo(_, _, true): return .fireEnd
    case .sessionEnded, .toast, .nudge, .demo:
      switch mirror.overlayVariant {
      case .side:
        return presentation == .sessionEnded ? .exitPlane : .randomExit
      case .top:
        // Landed creature: flies off by copter when the user gets back to
        // work, folds a paper plane for everything else.
        return mirror.lastNudgeReply == .backToWork ? .exitCopter : .exitPlane
      case .peek:
        return .peekExit
      }
    }
  }

  private func fadeOut(_ panel: NSPanel) {
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.2
        panel.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        panel.orderOut(nil)
        Task { @MainActor in
          guard let self, FlowSessionMirror.shared.overlay == .hidden else { return }
          self.panel?.contentView = nil
          self.panel = nil
        }
      })
  }

  private func makePanel() -> NSPanel {
    let panel = FlowOverlayPanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
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

    let hostingView = NSHostingView(rootView: FlowOverlayView())
    hostingView.frame = panel.contentRect(forFrameRect: panel.frame)
    hostingView.autoresizingMask = [.width, .height]
    // Never let SwiftUI's ideal size drive the window frame — without this the
    // panel collapses to the text's intrinsic width (a tall sliver).
    hostingView.sizingOptions = []
    panel.contentView = hostingView
    return panel
  }

  private func position(_ panel: NSPanel) {
    guard let origin = defaultOrigin(for: panel) else { return }
    let variant = FlowSessionMirror.shared.overlayVariant
    let offset = FlowAgentSettings.shared.positionOffset(for: variant)
    let target =
      variant.anchorsToTop
      ? NSPoint(x: origin.x + offset, y: origin.y)
      : NSPoint(x: origin.x, y: origin.y + offset)
    panel.setFrameOrigin(clamp(target, panel: panel))
  }

  /// Where the panel sits with no user offset: flush right, at the bottom
  /// for the side layout or under the menu bar for the from-above ones.
  private func defaultOrigin(for panel: NSPanel) -> NSPoint? {
    guard let screen = NSScreen.main else { return nil }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    if FlowSessionMirror.shared.overlayVariant.anchorsToTop {
      // From-above variants: the panel's top edge sits at the very top of
      // the screen (under the menu bar) so the creature drops out of it.
      return NSPoint(x: visible.maxX - size.width, y: screen.frame.maxY - size.height)
    }
    // Bottom-right, flush with the screen edge so the creature art clips at
    // the edge exactly like the Figma mock (it "peeks in" from offscreen).
    return NSPoint(x: visible.maxX - size.width, y: visible.minY + 8)
  }

  /// Keep the creature on screen: the side layout may only slide along the
  /// right edge, the from-above layouts along the top edge.
  private func clamp(_ origin: NSPoint, panel: NSPanel) -> NSPoint {
    guard let screen = NSScreen.main, let base = defaultOrigin(for: panel) else { return origin }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    if FlowSessionMirror.shared.overlayVariant.anchorsToTop {
      let x = min(base.x, max(visible.minX, origin.x))
      return NSPoint(x: x, y: base.y)
    }
    let y = min(visible.maxY - size.height, max(visible.minY, origin.y))
    return NSPoint(x: base.x, y: y)
  }

  // MARK: - Dragging the creature

  private var dragOrigin: NSPoint?

  /// The creature hotspot calls these while the user drags: the panel follows
  /// along its allowed axis, and the final offset is saved for the layout.
  func beginDrag() {
    dragOrigin = panel?.frame.origin
  }

  func drag(by delta: NSPoint) {
    guard let panel, let dragOrigin else { return }
    let target = NSPoint(x: dragOrigin.x + delta.x, y: dragOrigin.y + delta.y)
    panel.setFrameOrigin(clamp(target, panel: panel))
  }

  func endDrag() {
    defer { dragOrigin = nil }
    guard let panel, dragOrigin != nil, let base = defaultOrigin(for: panel) else { return }
    let variant = FlowSessionMirror.shared.overlayVariant
    let offset =
      variant.anchorsToTop ? panel.frame.origin.x - base.x : panel.frame.origin.y - base.y
    FlowAgentSettings.shared.setPositionOffset(offset, for: variant)
  }

  /// Re-apply the saved position (debug panel "reset positions").
  func repositionIfVisible() {
    guard let panel, panel.isVisible else { return }
    position(panel)
  }
}

/// Borderless panels refuse key status by default; keep it that way so
/// clicking a pill never steals focus from the app the user is working in.
private final class FlowOverlayPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// While onboarding shows off the pop-in, everything on the desktop except
/// the app's own window and the creature is dimmed (50% black), so the
/// eye goes to the corner the creature leans in from.
@MainActor
private final class FlowDemoBackdrop {
  private var panels: [NSPanel] = []
  private var pendingHide: DispatchWorkItem?

  func setShown(_ shown: Bool) {
    pendingHide?.cancel()
    pendingHide = nil
    if shown {
      show()
    } else if !panels.isEmpty {
      // The two pop-ins hide the creature for a moment between them; stay up
      // across that gap instead of flashing the desktop back.
      let work = DispatchWorkItem { [weak self] in self?.hide() }
      pendingHide = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
  }

  private func show() {
    guard panels.isEmpty else { return }
    let appWindow =
      NSApp.mainWindow
      ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    for screen in NSScreen.screens {
      // Everything under the menu bar, the way the design dims the desktop.
      var frame = screen.frame
      frame.size.height = screen.visibleFrame.maxY - frame.minY
      let panel = FlowOverlayPanel(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.level = .normal
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]

      let dim = NSView(frame: NSRect(origin: .zero, size: frame.size))
      dim.wantsLayer = true
      dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
      dim.autoresizingMask = [.width, .height]
      panel.contentView = dim

      panel.alphaValue = 0
      if let appWindow {
        panel.order(.below, relativeTo: appWindow.windowNumber)
      } else {
        panel.orderFrontRegardless()
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.35
        panel.animator().alphaValue = 1
      }
      panels.append(panel)
    }
  }

  private func hide() {
    let leaving = panels
    panels = []
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.35
        leaving.forEach { $0.animator().alphaValue = 0 }
      },
      completionHandler: {
        leaving.forEach { $0.orderOut(nil) }
      })
  }
}
