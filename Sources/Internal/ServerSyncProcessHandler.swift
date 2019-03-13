import Foundation

// Needs to be Codable
public enum ServerSyncJob {
    case StartJob(token: String)
    case RefreshTokenJob(newToken: String)
    case SubscribeJob(interest: String)
    case UnsubscribeJob(interest: String)
    case SetSubscriptions(interests: [String])
    case ApplicationStartJob(metadata: Metadata)
    case SetUserIdJob(userId: String)
    case StopJob
}

public class ServerSyncProcessHandler {
    private let queue: DispatchQueue
    private let networkService: NetworkService
    public var jobQueue: [ServerSyncJob] = [] // TODO: This will need to be a persistent queue.

    init(instanceId: String) {
        self.queue = DispatchQueue(label: "queue")
        let session = URLSession(configuration: .ephemeral)
        self.networkService = NetworkService(session: session, instanceId: instanceId)
    }

    public func sendMessage(serverSyncJob: ServerSyncJob) {
        self.queue.async {
            self.jobQueue.append(serverSyncJob)
            self.handleMessage(serverSyncJob: serverSyncJob)
        }
    }

    private func hasStarted() -> Bool {
        return DeviceStateStore.synchronize {
            return Device.idAlreadyPresent()
        }
    }

    private func processStartJob(token: String) {
        // Register device with Error
        let result = self.networkService.register(deviceToken: token, metadata: Metadata.get(), retryStrategy: WithInfiniteExpBackoff())

        switch result {
        case .error(let error):
            print("[PushNotifications]: Unrecoverable error when registering device with Pusher Beams (Reason - \(error.getErrorMessage()))")
            print("[PushNotifications]: SDK will not start.")
            return
        case .value(let device):
            var outstandingJobs: [ServerSyncJob] = []
            DeviceStateStore.synchronize {
                // Replay sub/unsub/setsub operations in job queue over initial interest set
                var interestsSet = device.initialInterestSet ?? Set<String>()

                for job in jobQueue {
                    switch job {
                    case .StartJob:
                        break
                    case .SubscribeJob(let interest):
                        interestsSet.insert(interest)
                    case .UnsubscribeJob(let interest):
                        interestsSet.remove(interest)
                    case .SetSubscriptions(let interests):
                        interestsSet = Set(interests)
                    case .StopJob:
                        outstandingJobs.removeAll()
                        // Any subscriptions changes done at this point are just discarded,
                        // and we need to assume the initial interest set as the starting point again
                        interestsSet = device.initialInterestSet ?? Set<String>()
                    case .SetUserIdJob:
                        outstandingJobs.append(job)
                    case .ApplicationStartJob:
                        // ignoring it as we are already going to sync the state anyway
                        continue
                    case .RefreshTokenJob:
                        outstandingJobs.append(job)
                    }
                }

                let localInterestsWillChange = Set(DeviceStateStore.interestsService.getSubscriptions() ?? []) != interestsSet
                if localInterestsWillChange {
                    // TODO: Notify interests changed event
                    DeviceStateStore.interestsService.persist(interests: Array(interestsSet))
                }

                Device.persistAPNsToken(token: token)
                Device.persist(device.id)
            }

            let localInterests = DeviceStateStore.interestsService.getSubscriptions() ?? []
            let remoteInterestsWillChange = Set(localInterests) != device.initialInterestSet ?? Set()
            if remoteInterestsWillChange {
                // We don't care about the result at this point.
                _ = self.networkService.setSubscriptions(deviceId: device.id, interests: localInterests, retryStrategy: WithInfiniteExpBackoff())
            }

            for job in outstandingJobs {
                processJob(job)
            }
        }
    }

    private func processStopJob() {
        _ = self.networkService.deleteDevice(deviceId: Device.getDeviceId()!, retryStrategy: WithInfiniteExpBackoff())
        Device.delete()
        Device.deleteAPNsToken()
    }

    private func processJob(_ job: ServerSyncJob) {
        let result: Result<Void, PushNotificationsAPIError> = {
            switch job {
            case .SubscribeJob(let interest):
                return self.networkService.subscribe(deviceId: Device.getDeviceId()!, interest: interest, retryStrategy: WithInfiniteExpBackoff())
            case .UnsubscribeJob(let interest):
                return self.networkService.unsubscribe(deviceId: Device.getDeviceId()!, interest: interest, retryStrategy: WithInfiniteExpBackoff())
            case .SetSubscriptions(let interests):
                return self.networkService.setSubscriptions(deviceId: Device.getDeviceId()!, interests: interests, retryStrategy: WithInfiniteExpBackoff())
            case .StartJob, .StopJob:
                return .value(()) // already handled in `handleMessage`
            default:
                return .value(()) // TODO: REMOVE THIS
            }
        }()

        switch result {
        case .value:
            return
        case .error(PushNotificationsAPIError.DeviceNotFound):
            if recreateDevice(token: Device.getAPNsToken()!) {
                processJob(job)
            } else {
                print("[PushNotifications]: Not retrying, skipping job: \(job).")
            }
        case .error(let error):
            // not really recoverable, so log it here and also monitor 400s closely on our backend
            // (this really shouldn't happen)
            print("[PushNotifications]: Fail to make a valid request to the server for job \(job), skipping it. Error: \(error)")
            return
        }
    }

    private func recreateDevice(token: String) -> Bool {
        // Register device with Error
        let result = self.networkService.register(deviceToken: token, metadata: Metadata.get(), retryStrategy: WithInfiniteExpBackoff())

        switch result {
        case .error(let error):
            print("[PushNotifications]: Unrecoverable error when registering device with Pusher Beams (Reason - \(error.getErrorMessage()))")
            return false
        case .value(let device):
            let localIntersets: [String] = DeviceStateStore.synchronize {
                Device.persist(device.id)
                Device.persistAPNsToken(token: token)
                return DeviceStateStore.interestsService.getSubscriptions() ?? []
            }

            if !localIntersets.isEmpty {
                _ = self.networkService.setSubscriptions(deviceId: device.id, interests: localIntersets, retryStrategy: WithInfiniteExpBackoff())
            }

            // TODO Handle UserId recreation

            return true
        }
    }

    func handleMessage(serverSyncJob: ServerSyncJob) {
        // If the SDK hasn't started yet we can't do anything, so skip
        var shouldSkip: Bool
        if case .StartJob(_) = serverSyncJob {
            shouldSkip = false
        } else {
            shouldSkip = !hasStarted()
        }

        if shouldSkip {
            return
        }

        switch serverSyncJob {
        case .StartJob(let token):
            processStartJob(token: token)

            // Clear up the queue up to the StartJob.
            while(!jobQueue.isEmpty) {
                switch jobQueue.first! {
                case .StartJob:
                    jobQueue.removeFirst()
                    return
                default:
                    jobQueue.removeFirst()
                }
            }

        case .StopJob:
            processStopJob()
            jobQueue.removeFirst()

        default:
            processJob(serverSyncJob)
            jobQueue.removeFirst()
        }
    }
}
