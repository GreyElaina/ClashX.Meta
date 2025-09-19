//
//  GeneralSettingViewController.swift
//  ClashX Pro
//
//  Created by yicheng on 2022/11/20.
//  Copyright © 2022 west2online. All rights reserved.
//

import Cocoa
import RxSwift

class GeneralSettingViewController: NSViewController {
    @IBOutlet var ignoreListTextView: NSTextView!
    @IBOutlet var launchAtLoginButton: NSButton!

    @IBOutlet var reduceNotificationsButton: NSButton!
    @IBOutlet var useiCloudButton: NSButton!

    @IBOutlet var allowApiLanUsageSwitcher: NSButton!
    @IBOutlet var proxyPortTextField: NSTextField!
    @IBOutlet var apiPortTextField: NSTextField!
    @IBOutlet var ssidSuspendTextField: NSTextView!

    @IBOutlet var apiSecretTextField: NSTextField!

    @IBOutlet var ipv6Button: NSButton!
    @IBOutlet var speedTestUrlField: NSTextField!

    var disposeBag = DisposeBag()
    override func viewDidLoad() {
        super.viewDidLoad()
        speedTestUrlField.stringValue = Settings.benchMarkUrl
        speedTestUrlField.placeholderString = Settings.defaultBenchmarkUrl
        ignoreListTextView.string = Settings.proxyIgnoreList.joined(separator: ",")
        ignoreListTextView.rx
            .string.debounce(.milliseconds(500), scheduler: MainScheduler.instance)
            .map { $0.components(separatedBy: ",").filter { !$0.isEmpty } }
            .subscribe { arr in
                Settings.proxyIgnoreList = arr
            }.disposed(by: disposeBag)

        ssidSuspendTextField.string = Settings.disableSSIDList.joined(separator: ",")
        ssidSuspendTextField.rx
            .string.debounce(.milliseconds(500), scheduler: MainScheduler.instance)
            .map { $0.components(separatedBy: ",").filter { !$0.isEmpty } }
            .subscribe { arr in
                Settings.disableSSIDList = arr
                SSIDSuspendTool.shared.update()
            }.disposed(by: disposeBag)

        LaunchAtLogin.shared.isEnableVirable
            .map { $0 ? .on : .off }
            .bind(to: launchAtLoginButton.rx.state)
            .disposed(by: disposeBag)
        launchAtLoginButton.rx.state.map { $0 == .on }.subscribe {
            LaunchAtLogin.shared.isEnabled = $0
        }.disposed(by: disposeBag)

        ICloudManager.shared.useiCloud
            .map { $0 ? .on : .off }
            .bind(to: useiCloudButton.rx.state)
            .disposed(by: disposeBag)
        useiCloudButton.rx.state.map { $0 == .on }.subscribe {
            ICloudManager.shared.userEnableiCloud = $0
        }.disposed(by: disposeBag)
        reduceNotificationsButton.toolTip = NSLocalizedString(
            "Reduce alerts if notification permission is disabled", comment: "")
        reduceNotificationsButton.state = Settings.disableNoti ? .on : .off
        reduceNotificationsButton.rx.state.map { $0 == .on }.subscribe {
            Settings.disableNoti = $0
        }.disposed(by: disposeBag)

        ipv6Button.state = Settings.enableIPV6 ? .on : .off
        ipv6Button.rx.state.map { $0 == .on }.subscribe {
            Settings.enableIPV6 = $0
        }.disposed(by: disposeBag)

        if Settings.proxyPort > 0 {
            proxyPortTextField.stringValue = "\(Settings.proxyPort)"
        } else {
            proxyPortTextField.stringValue = "\(ConfigManager.shared.currentConfig?.mixedPort ?? 0)"
        }
        if Settings.apiPort > 0 {
            apiPortTextField.stringValue = "\(Settings.apiPort)"
        } else {
            // 如果没有设置 API 端口，使用 ConfigManager 中的端口
            apiPortTextField.stringValue = ConfigManager.shared.apiPort
        }

        apiSecretTextField.stringValue = Settings.apiSecret
        apiSecretTextField.rx.text.compactMap { $0 }.bind {
            Settings.apiSecret = $0
            // 清除任何远程覆盖，确保 UI 设置优先
            ConfigManager.shared.overrideSecret = nil
            // 重新加载配置以应用到后端
            AppDelegate.shared.updateConfig(showNotification: false)
        }.disposed(by: disposeBag)

        proxyPortTextField.rx.text
            .compactMap { $0 }
            .compactMap { Int($0) }
            .bind {
                Settings.proxyPort = $0
                // 清除任何远程覆盖，确保 UI 设置优先
                ConfigManager.shared.overrideApiURL = nil
                // 重新加载配置以应用到后端
                AppDelegate.shared.updateConfig(showNotification: false)
            }.disposed(by: disposeBag)

        apiPortTextField.rx.text
            .compactMap { $0 }
            .compactMap { Int($0) }
            .bind {
                Settings.apiPort = $0
                // 更新 ConfigManager 的 API 端口
                ConfigManager.shared.apiPort = "\($0)"
                // 清除任何远程覆盖，确保 UI 设置优先
                ConfigManager.shared.overrideApiURL = nil
                // 重新加载配置以应用到后端
                AppDelegate.shared.updateConfig(showNotification: false)
            }.disposed(by: disposeBag)
        allowApiLanUsageSwitcher.state = Settings.apiPortAllowLan ? .on : .off
        allowApiLanUsageSwitcher.rx.state.bind { [weak self] state in
            guard let self = self else { return }
            let enableLan = state == .on
            if enableLan {
                // 显示安全警告
                let alert = NSAlert()
                alert.messageText = "⚠️ 安全警告"
                alert.informativeText =
                    "启用局域网 API 访问将允许同一网络中的设备访问您的 ClashX 控制 API。\n\n这可能带来安全风险，请确保您在可信的网络环境中使用此功能。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "启用")
                alert.addButton(withTitle: "取消")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    Settings.apiPortAllowLan = true
                } else {
                    // 用户取消，恢复开关状态
                    self.allowApiLanUsageSwitcher.state = .off
                    return
                }
            } else {
                Settings.apiPortAllowLan = false
            }
        }.disposed(by: disposeBag)

        proxyPortTextField.isEnabled = true
        apiPortTextField.isEnabled = true
        apiSecretTextField.isEnabled = true

        allowApiLanUsageSwitcher.isEnabled = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        let url = speedTestUrlField.stringValue
        if url.isUrlVaild() || url.isEmpty {
            Settings.benchMarkUrl = url
        }
        SSIDSuspendTool.shared.showNoticeOnNotPermission = true
        SSIDSuspendTool.shared.requestPermissionIfNeed()
        SSIDSuspendTool.shared.update()
    }

    @IBAction func actionResetIgnoreList(_ sender: Any) {
        ignoreListTextView.string = Settings.proxyIgnoreListDefaultValue.joined(separator: ",")
        Settings.proxyIgnoreList = Settings.proxyIgnoreListDefaultValue
    }
}
