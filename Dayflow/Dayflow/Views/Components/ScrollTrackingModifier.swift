import AppKit
import SwiftUI

/// Observes the underlying NSScrollView's clip view bounds changes.
/// Unlike SwiftUI's PreferenceKey approach, this fires continuously during active scrolling.
private struct ScrollObserverView: NSViewRepresentable {
  let onScrollStart: ((_ direction: String) -> Void)?

  func makeNSView(context: Context) -> NSView {
    let view = ScrollObserverNSView()
    view.onScrollStart = onScrollStart
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let observer = nsView as? ScrollObserverNSView {
      observer.onScrollStart = onScrollStart
    }
  }

  private class ScrollObserverNSView: NSView {
    var onScrollStart: ((_ direction: String) -> Void)?
    private var lastOffset: CGFloat?
    private var scrollViewObservation: NSObjectProtocol?
    private var isReady = false
    private var isScrolling = false
    private var scrollResetWorkItem: DispatchWorkItem?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()

      // Reset state when view is (re-)added to window
      isReady = false
      lastOffset = nil
      guard window != nil else {
        scrollResetWorkItem?.cancel()
        scrollResetWorkItem = nil
        isScrolling = false
        if let observation = scrollViewObservation {
          NotificationCenter.default.removeObserver(observation)
          scrollViewObservation = nil
        }
        return
      }
      setupScrollObserver()

      // Ignore initial layout bounds changes
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.isReady = true
      }
    }

    private func setupScrollObserver() {
      // Clean up existing observation
      if let observation = scrollViewObservation {
        NotificationCenter.default.removeObserver(observation)
        scrollViewObservation = nil
      }

      // Find the parent NSScrollView (SwiftUI's ScrollView wraps an NSScrollView)
      guard let scrollView = findEnclosingScrollView() else { return }

      // Enable postsBoundsChangedNotifications on the clip view
      scrollView.contentView.postsBoundsChangedNotifications = true

      // Observe bounds changes - this fires during actual scrolling
      scrollViewObservation = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak self, weak scrollView] _ in
        guard let self, let scrollView else { return }
        self.handleBoundsChange(scrollView: scrollView)
      }
    }

    private func findEnclosingScrollView() -> NSScrollView? {
      var current: NSView? = superview
      while let view = current {
        if let scrollView = view as? NSScrollView {
          return scrollView
        }
        current = view.superview
      }
      return nil
    }

    private func handleBoundsChange(scrollView: NSScrollView) {
      let currentOffset = scrollView.contentView.bounds.origin.y

      if isReady, let last = lastOffset {
        let delta = currentOffset - last
        if abs(delta) > 0.5 {
          if !isScrolling {
            let direction = delta > 0 ? "down" : "up"
            onScrollStart?(direction)
            isScrolling = true
          }
          scrollResetWorkItem?.cancel()
          let resetWork = DispatchWorkItem { [weak self] in
            self?.isScrolling = false
          }
          scrollResetWorkItem = resetWork
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: resetWork)
        }
      }

      lastOffset = currentOffset
    }

    deinit {
      scrollResetWorkItem?.cancel()
      if let observation = scrollViewObservation {
        NotificationCenter.default.removeObserver(observation)
      }
    }
  }
}

/// View modifier that tracks scroll events with debouncing.
/// Fires a callback once per "scroll session" (not per frame).
private struct ScrollTrackingModifier: ViewModifier {
  let panelName: String
  let onScrollStart: ((_ direction: String) -> Void)?

  func body(content: Content) -> some View {
    content
      .background(
        ScrollObserverView(onScrollStart: onScrollStart)
          .allowsHitTesting(false)
      )
  }
}

extension View {
  /// Tracks scroll activity and fires a debounced callback when scrolling starts.
  /// The callback receives the scroll direction ("up" or "down").
  /// Events are debounced - only fires once per "scroll session" (resets after 0.6s of no activity).
  func onScrollStart(panelName: String = "", action: @escaping (_ direction: String) -> Void)
    -> some View
  {
    modifier(ScrollTrackingModifier(panelName: panelName, onScrollStart: action))
  }
}
