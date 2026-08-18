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
        var detectedKinds: Set<TerminalAgentKind> = []
        var cpuTimes: [Int32: UInt64] = [:]
        var submissionTime: UInt64?
        var lastEvidenceTime: UInt64?
        var lastImmediatePollTime: UInt64?
        var nextPollTime: UInt64
    }

    private struct Discovery {
        let sessionID: UUID
        let task: Task<Void, Never>
    }

    private let inspector: any AgentProcessInspecting
    private let activePollIntervalNanoseconds: UInt64
    private let presentAgentPollIntervalNanoseconds: UInt64
    private let idlePollIntervalNanoseconds: UInt64
    private let activityQuietPeriodNanoseconds: UInt64
    private let agentDiscoveryWindowNanoseconds: UInt64
    private let minimumCPUAdvanceNanoseconds: UInt64
    private let outputPollThrottleNanoseconds: UInt64
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
        presentAgentPollIntervalNanoseconds: UInt64 = 2_000_000_000,
        idlePollIntervalNanoseconds: UInt64 = 4_000_000_000,
        activityQuietPeriodNanoseconds: UInt64 = 3_000_000_000,
        agentDiscoveryWindowNanoseconds: UInt64 = 5_000_000_000,
        minimumCPUAdvanceNanoseconds: UInt64 = 10_000_000,
        outputPollThrottleNanoseconds: UInt64 = 100_000_000,
        automaticallyPolls: Bool = true,
        now: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        activitySink: @escaping ActivitySink
    ) {
        self.inspector = inspector
        self.activePollIntervalNanoseconds = activePollIntervalNanoseconds
        self.presentAgentPollIntervalNanoseconds = presentAgentPollIntervalNanoseconds
        self.idlePollIntervalNanoseconds = idlePollIntervalNanoseconds
        self.activityQuietPeriodNanoseconds = activityQuietPeriodNanoseconds
        self.agentDiscoveryWindowNanoseconds = agentDiscoveryWindowNanoseconds
        self.minimumCPUAdvanceNanoseconds = minimumCPUAdvanceNanoseconds
        self.outputPollThrottleNanoseconds = outputPollThrottleNanoseconds
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

    func recordSubmission(paneID: UUID, sessionID: UUID) async {
        guard var registration = registrations[paneID],
            registration.sessionID == sessionID
        else {
            return
        }
        let currentTime = now()
        registration.submissionTime = currentTime
        registration.lastEvidenceTime = currentTime
        registration.lastImmediatePollTime = currentTime
        registration.nextPollTime = currentTime
        registrations[paneID] = registration
        await poll(paneID: paneID)
        guard registrations[paneID]?.sessionID == sessionID,
            registrations[paneID]?.activity.phase == .absent
        else {
            return
        }
        scheduleDiscovery(paneID: paneID, sessionID: sessionID)
    }

    func recordOutput(paneID: UUID, sessionID: UUID) async {
        guard var registration = registrations[paneID],
            registration.sessionID == sessionID
        else {
            return
        }
        let currentTime = now()
        guard registration.submissionTime != nil,
            !registration.detectedKinds.isEmpty
                || hasRecentSubmission(registration, at: currentTime)
        else {
            return
        }

        registration.lastEvidenceTime = currentTime
        let shouldPollImmediately =
            registration.activity.phase == .absent
            && registration.lastImmediatePollTime.map {
                currentTime >= $0
                    && currentTime - $0 >= outputPollThrottleNanoseconds
            } ?? true
        if shouldPollImmediately {
            registration.lastImmediatePollTime = currentTime
            registration.nextPollTime = currentTime
        }
        registrations[paneID] = registration

        if shouldPollImmediately {
            await poll(paneID: paneID)
        }
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
        let currentTime = now()
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
            registration.nextPollTime = nextPollTime(
                for: registration,
                at: currentTime
            )
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
                if registration.consecutiveMisses >= 2 {
                    registration.detectedKinds = []
                    registration.cpuTimes = [:]
                    if !hasRecentSubmission(registration, at: currentTime) {
                        registration.submissionTime = nil
                        registration.lastEvidenceTime = nil
                    }
                }
                registration.nextPollTime = nextPollTime(
                    for: registration,
                    at: currentTime
                )
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
            if registration.submissionTime != nil,
                cpuDidAdvance(in: snapshot.processes, from: registration.cpuTimes)
            {
                registration.lastEvidenceTime = currentTime
            }
            registration.detectedKinds = Set(snapshot.processes.map(\.kind))
            registration.cpuTimes = Dictionary(
                uniqueKeysWithValues: snapshot.processes.map {
                    ($0.processID, $0.cpuTimeNanoseconds)
                }
            )
            registration.nextPollTime = nextPollTime(
                for: registration,
                at: currentTime
            )
            registrations[paneID] = registration
            cancelDiscovery(paneID: paneID, sessionID: registration.sessionID)
            await publish(
                hasRecentEvidence(registration, at: currentTime)
                    ? .active(registration.detectedKinds)
                    : .absent,
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
        registration.nextPollTime = nextPollTime(
            for: registration,
            at: now()
        )
        registrations[paneID] = registration
        await activitySink(paneID, sessionID, activity)
        wakeScheduler()
    }

    private func nextPollTime(
        for registration: Registration,
        at currentTime: UInt64
    ) -> UInt64 {
        let interval: UInt64
        if registration.activity.phase == .active
            || hasRecentSubmission(registration, at: currentTime)
        {
            interval = activePollIntervalNanoseconds
        } else if !registration.detectedKinds.isEmpty {
            interval = presentAgentPollIntervalNanoseconds
        } else {
            interval = idlePollIntervalNanoseconds
        }
        return currentTime + interval
    }

    private func hasRecentSubmission(
        _ registration: Registration,
        at currentTime: UInt64
    ) -> Bool {
        guard let submissionTime = registration.submissionTime,
            currentTime >= submissionTime
        else {
            return false
        }
        return currentTime - submissionTime <= agentDiscoveryWindowNanoseconds
    }

    private func hasRecentEvidence(
        _ registration: Registration,
        at currentTime: UInt64
    ) -> Bool {
        guard let evidenceTime = registration.lastEvidenceTime,
            currentTime >= evidenceTime
        else {
            return false
        }
        return currentTime - evidenceTime <= activityQuietPeriodNanoseconds
    }

    private func cpuDidAdvance(
        in processes: [AgentProcessSample],
        from previousTimes: [Int32: UInt64]
    ) -> Bool {
        processes.contains { process in
            guard process.cpuTimeNanoseconds > 0,
                let previousTime = previousTimes[process.processID],
                process.cpuTimeNanoseconds >= previousTime
            else {
                return false
            }
            return process.cpuTimeNanoseconds - previousTime
                >= minimumCPUAdvanceNanoseconds
        }
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
                    await self.isCurrentDiscoveringSession(
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

    private func isCurrentDiscoveringSession(
        paneID: UUID,
        sessionID: UUID
    ) -> Bool {
        guard let registration = registrations[paneID] else {
            return false
        }
        return registration.sessionID == sessionID
            && registration.activity.phase == .absent
            && hasRecentSubmission(registration, at: now())
    }
}
