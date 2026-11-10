import BackgroundTasks

/// App 的后台刷新（苹果的 BGAppRefreshTask）：每 2 小时左右请系统在后台叫醒 App 取一次目录，有新课就更新小组件。
/// 什么时候真的叫醒由系统定（看用户用不用这个 App、电量、网络；“后台 App 刷新”关了就不叫）。
/// 和小组件自己取（WidgetCatalog）两条路一起用：系统分开给次数，用户很少打开 App 时小组件那条还在。
enum BackgroundRefresh {
    static let id = "com.zhibeifw.app.refresh"

    /// App 模型建好后接上：启动（如果还没启动）、取目录、给小组件写数据
    @MainActor static var handler: (() async -> Void)?

    /// 要在 App 启动完成前登记（application(_:didFinishLaunchingWithOptions:)）
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            run(task)
        }
    }

    /// 请系统 2 小时后叫醒（重复请求只保留最后一次）
    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    private static func run(_ task: BGAppRefreshTask) {
        schedule()  // 先约好下一次
        let work = Task { @MainActor in
            await handler?()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        // 系统给的时间用完：停下（setTaskCompleted 由上面的任务在取消后调用）
        task.expirationHandler = { work.cancel() }
    }
}
