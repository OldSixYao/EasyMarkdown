import AppKit
import Observation

/// Background windows keep a small viewport snapshot, not a live web page.
@MainActor @Observable final class PreviewActivity {
    private(set) var isAwake = true
    private(set) var snapshot: NSImage?
    @ObservationIgnored var idleDelay: Duration = .seconds(30)
    @ObservationIgnored private var active = true
    @ObservationIgnored private var needed = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var bindingID: UUID?
    @ObservationIgnored private var prepareForSleep: ((@escaping (NSImage?) -> Void) -> Void)?

    func bind(id: UUID, prepare: @escaping (@escaping (NSImage?) -> Void) -> Void) {
        bindingID = id
        prepareForSleep = prepare
    }

    func unbind(id: UUID) {
        guard bindingID == id else { return }
        bindingID = nil
        prepareForSleep = nil
    }

    func update(active: Bool, needed: Bool) {
        if self.active == active && self.needed == needed && (timer != nil || !isAwake || active) { return }
        self.active = active
        self.needed = needed
        generation += 1
        timer?.cancel()
        timer = nil
        if active || !needed {
            isAwake = true
            if !needed { snapshot = nil }
            return
        }
        guard isAwake else { return }
        let generation = generation
        timer = Task { [weak self, idleDelay] in
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled, let self, !self.active, self.needed,
                  self.generation == generation else { return }
            var completed = false
            let finish: (NSImage?) -> Void = { [weak self] image in
                guard !completed, let self, !self.active, self.needed,
                      self.generation == generation else { return }
                completed = true
                self.snapshot = image
                self.isAwake = false
                self.timer = nil
            }
            self.prepareForSleep?(finish)
            // A suspended/crashed WebKit service must not prevent reclamation.
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { finish(nil) }
        }
    }

    func didRender() { snapshot = nil }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        prepareForSleep = nil
        bindingID = nil
        snapshot = nil
    }
}
