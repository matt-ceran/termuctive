import Foundation

actor TerminalAgentActivityMonitor {
    typealias ActivitySink =
        @MainActor (
            _ paneID: UUID,
            _ sessionID: UUID,
            _ activity: TerminalAgentActivity
        ) -> Void

    private struct Registration {
        let sessionID: UUID
        let shellPID: Int32
        let shellIdentity: AgentShellIdentity
        var consecutiveMisses = 0
        var activity = TerminalAgentActivity.absent
        var nextPollTime: UInt64
    }

    private struct Discovery {
        let sessionID: UUID
        let task: Task<Void, Never>
    }

    private let inspector: any AgentProcessInspecting
    private let activePollIntervalNanoseconds: UInt64
    private let idlePollIntervalNanoseconds: UInt64
    private let automaticallyPolls: Bool
    private let now: @Sendable () -> UInt64
    private let activitySink: ActivitySink
    private var acceptsRegistrations = true
    private var registrations: [UUID: Registration] = [:]
    private var discoveries: [UUID: Discovery] = [:]
    private var pollingTask: Task<Void, Never>?

    init(
        inspector: any AgentProcessInspecting = MacAgentProcessInspector(),
        activePollIntervalNanoseconds: UInt64 = 750_000_000,
        idlePollIntervalNanoseconds: UInt64 = 4_000_000_000,
        automaticallyPolls: Bool = true,
        now: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        activitySink: @escaping ActivitySink
    ) {
        self.inspector = inspector
        self.activePollIntervalNanoseconds = activePollIntervalNanoseconds
        self.idlePollIntervalNanoseconds = idlePollIntervalNanoseconds
        self.automaticallyPolls = automaticallyPolls
        self.now = now
        self.activitySink = activitySink
    }

    func register(
        paneID: UUID,
        shellPID: Int32,
        shellIdentity: AgentShellIdentity,
        sessionID: UUID
    ) {
        guard acceptsRegistrations else {
            return
        }
        discoveries.removeValue(forKey: paneID)?.task.cancel()
        registrations[paneID] = Registration(
            sessionID: sessionID,
            shellPID: shellPID,
            shellIdentity: shellIdentity,
            nextPollTime: now()
        )
        wakeScheduler()
    }

    func unregister(paneID: UUID, sessionID: UUID) {
        guard registrations[paneID]?.sessionID == sessionID else {
            return
        }
        cancelDiscovery(paneID: paneID, sessionID: sessionID)
        registrations.removeValue(forKey: paneID)
        wakeScheduler()
    }

    func requestImmediatePoll(paneID: UUID, sessionID: UUID) async {
        guard registrations[paneID]?.sessionID == sessionID else {
            return
        }
        await poll(paneID: paneID)
        guard registrations[paneID]?.sessionID == sessionID,
            registrations[paneID]?.activity.phase == .absent
        else {
            return
        }
        scheduleDiscovery(paneID: paneID, sessionID: sessionID)
    }

    func stopAll() {
        acceptsRegistrations = false
        for discovery in discoveries.values {
            discovery.task.cancel()
        }
        discoveries.removeAll()
        registrations.removeAll()
        pollingTask?.cancel()
        pollingTask = nil
    }

    func pollNow() async {
        for paneID in Array(registrations.keys) {
            await poll(paneID: paneID)
        }
    }

    private func runDuePolls() async {
        let currentTime = now()
        let paneIDs = registrations.compactMap { paneID, registration in
            registration.nextPollTime <= currentTime ? paneID : nil
        }
        for paneID in paneIDs {
            await poll(paneID: paneID)
        }
    }

    private func poll(paneID: UUID) async {
        guard var registration = registrations[paneID] else {
            return
        }
        let inspection = inspector.inspect(
            shellPID: registration.shellPID,
            expectedIdentity: registration.shellIdentity
        )
        guard registrations[paneID]?.sessionID == registration.sessionID else {
            return
        }

        switch inspection {
        case .shellTerminated:
            await publish(
                .absent,
                paneID: paneID,
                sessionID: registration.sessionID
            )
            guard registrations[paneID]?.sessionID == registration.sessionID else {
                return
            }
            cancelDiscovery(paneID: paneID, sessionID: registration.sessionID)
            registrations.removeValue(forKey: paneID)

        case .unavailable:
            registration.consecutiveMisses += 1
            registration.nextPollTime = nextPollTime(for: registration.activity)
            registrations[paneID] = registration
            if registration.consecutiveMisses >= 2 {
                await publish(
                    .absent,
                    paneID: paneID,
                    sessionID: registration.sessionID
                )
            }

        case .snapshot(let snapshot):
            guard snapshot.shellIdentity == registration.shellIdentity else {
                await publish(
                    .absent,
                    paneID: paneID,
                    sessionID: registration.sessionID
                )
                guard registrations[paneID]?.sessionID == registration.sessionID else {
                    return
                }
                cancelDiscovery(paneID: paneID, sessionID: registration.sessionID)
                registrations.removeValue(forKey: paneID)
                return
            }

            guard !snapshot.processes.isEmpty else {
                registration.consecutiveMisses += 1
                registration.nextPollTime = nextPollTime(for: registration.activity)
                registrations[paneID] = registration
                if registration.consecutiveMisses >= 2 {
                    await publish(
                        .absent,
                        paneID: paneID,
                        sessionID: registration.sessionID
                    )
                }
                return
            }

            registration.consecutiveMisses = 0
            registration.nextPollTime = now() + activePollIntervalNanoseconds
            registrations[paneID] = registration
            cancelDiscovery(paneID: paneID, sessionID: registration.sessionID)
            await publish(
                .active(Set(snapshot.processes.map(\.kind))),
                paneID: paneID,
                sessionID: registration.sessionID
            )
        }
    }

    private func publish(
        _ activity: TerminalAgentActivity,
        paneID: UUID,
        sessionID: UUID
    ) async {
        guard var registration = registrations[paneID],
            registration.sessionID == sessionID,
            registration.activity != activity
        else {
            return
        }
        registration.activity = activity
        registration.nextPollTime = nextPollTime(for: activity)
        registrations[paneID] = registration
        await activitySink(paneID, sessionID, activity)
        wakeScheduler()
    }

    private func nextPollTime(for activity: TerminalAgentActivity) -> UInt64 {
        now()
            + (activity.phase == .active
                ? activePollIntervalNanoseconds : idlePollIntervalNanoseconds)
    }

    private func wakeScheduler() {
        guard automaticallyPolls else {
            return
        }
        pollingTask?.cancel()
        pollingTask = nil
        guard !registrations.isEmpty else {
            return
        }
        pollingTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.schedulerLoop()
        }
    }

    private func schedulerLoop() async {
        while !Task.isCancelled {
            await runDuePolls()
            guard let dueTime = registrations.values.map(\.nextPollTime).min() else {
                pollingTask = nil
                return
            }
            let currentTime = now()
            let delay = dueTime > currentTime ? dueTime - currentTime : 0
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
        }
    }

    private func scheduleDiscovery(paneID: UUID, sessionID: UUID) {
        cancelDiscovery(paneID: paneID, sessionID: sessionID)
        let task = Task { [weak self] in
            for delay in [150_000_000, 450_000_000, 900_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                    await self.isCurrentAbsentSession(
                        paneID: paneID,
                        sessionID: sessionID
                    )
                else {
                    return
                }
                await self.poll(paneID: paneID)
            }
            await self?.finishDiscovery(paneID: paneID, sessionID: sessionID)
        }
        discoveries[paneID] = Discovery(sessionID: sessionID, task: task)
    }

    private func cancelDiscovery(paneID: UUID, sessionID: UUID) {
        guard discoveries[paneID]?.sessionID == sessionID else {
            return
        }
        discoveries.removeValue(forKey: paneID)?.task.cancel()
    }

    private func finishDiscovery(paneID: UUID, sessionID: UUID) {
        guard discoveries[paneID]?.sessionID == sessionID else {
            return
        }
        discoveries.removeValue(forKey: paneID)
    }

    private func isCurrentAbsentSession(paneID: UUID, sessionID: UUID) -> Bool {
        guard let registration = registrations[paneID] else {
            return false
        }
        return registration.sessionID == sessionID
            && registration.activity.phase == .absent
    }
}
