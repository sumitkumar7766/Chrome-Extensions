using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Threading;
using PingGlassWindows.Models;
using PingGlassWindows.Notifications;

namespace PingGlassWindows.Core;

/// <summary>
/// Central application coordinator on Windows: manages HelperConfiguration in %LOCALAPPDATA%\PingGlass\config.json,
/// WhatsAppDetector, WindowsUiaMonitor, GlobalNotificationWindowManager, LocalIpcServer, and Pause timers.
/// Never logs or persists WhatsApp message contents.
/// </summary>
public sealed class AppState : IDisposable
{
    private readonly string _configFilePath;
    private readonly MessageProcessor _processor = new();
    private readonly WindowsUiaExtractor _extractor = new();
    private DispatcherTimer? _pauseTimer;

    public HelperConfiguration Config { get; private set; }
    public WhatsAppDetector WhatsAppDetector { get; } = new();
    public WindowsUiaMonitor UiaMonitor { get; }
    public GlobalNotificationWindowManager NotificationManager { get; }
    public LocalIpcServer IpcServer { get; } = new();
    public LaunchAtLoginManager LaunchAtLogin { get; } = new();

    public MonitoringLifecycleState LifecycleState { get; private set; } = MonitoringLifecycleState.WhatsAppNotRunning;
    public string StatusDetail { get; private set; } = "Open WhatsApp Desktop to monitor incoming chats.";
    public string ExtractionMode { get; private set; } = "Idle";
    public bool ObserverAttached { get; private set; }
    public bool FallbackPollingActive { get; private set; }
    public int ConnectedBridgeClients { get; private set; }
    public int SessionMessagesForwarded { get; private set; }
    public int VisibleNotificationCount { get; private set; }
    public int QueuedNotificationCount { get; private set; }

    public int TotalActiveAndQueued => VisibleNotificationCount + QueuedNotificationCount;
    public bool IsNotificationsPaused => Config.IsNotificationsPaused();

    public string PauseStatusSummary
    {
        get
        {
            if (!Config.GlobalNotificationsEnabled) return "Disabled";
            if (Config.PausedIndefinitely) return "Paused until resumed";
            if (Config.PausedUntil.HasValue && Config.PausedUntil.Value > DateTimeOffset.UtcNow)
            {
                int mins = Math.Max(1, (int)Math.Ceiling((Config.PausedUntil.Value - DateTimeOffset.UtcNow).TotalMinutes));
                return $"Paused ({mins}m left)";
            }
            return "Active";
        }
    }

    public event Action? StateChanged;

    public AppState()
    {
        var appDataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PingGlass");
        Directory.CreateDirectory(appDataDir);
        _configFilePath = Path.Combine(appDataDir, "config.json");

        Config = LoadConfig();
        UiaMonitor = new WindowsUiaMonitor(_extractor, _processor);
        NotificationManager = new GlobalNotificationWindowManager(Config);

        WireCallbacks();
        try { IpcServer.Start(); } catch { }
        SchedulePauseExpirationTimerIfNeeded();
        EvaluateLifecycle();
    }

    public void UpdateConfiguration(Action<HelperConfiguration> mutator)
    {
        var next = Config.Clone();
        mutator(next);
        next.Clamp();
        Config = next;
        SaveConfig(Config);

        NotificationManager.UpdateConfiguration(Config);
        UiaMonitor.UpdateConfiguration(Config);
        SchedulePauseExpirationTimerIfNeeded();
        EvaluateLifecycle();
        BroadcastStatus();
    }

    public void ToggleMonitoring()
    {
        UpdateConfiguration(c => c.MonitoringEnabled = !c.MonitoringEnabled);
    }

    public void PauseNotificationsForMinutes(int minutes)
    {
        UpdateConfiguration(c =>
        {
            c.PausedIndefinitely = false;
            c.PausedUntil = DateTimeOffset.UtcNow.AddMinutes(Math.Max(1, minutes));
        });
    }

    public void PauseNotificationsIndefinitely()
    {
        UpdateConfiguration(c =>
        {
            c.PausedIndefinitely = true;
            c.PausedUntil = null;
        });
    }

    public void ResumeNotifications()
    {
        UpdateConfiguration(c =>
        {
            c.PausedIndefinitely = false;
            c.PausedUntil = null;
        });
    }

    public void ClearAllNotifications(bool fromRemote = false)
    {
        SessionMessagesForwarded = 0;
        NotificationManager.DismissAll(Config.AnimationEnabled);
        if (!fromRemote && ConnectedBridgeClients > 0)
        {
            IpcServer.Broadcast(new BridgeEnvelope { Type = "clear_all_notifications" });
        }
        BroadcastStatus();
        StateChanged?.Invoke();
    }

    public void RefreshAll()
    {
        WhatsAppDetector.RefreshNow();
        EvaluateLifecycle();
        BroadcastStatus();
        StateChanged?.Invoke();
    }

    public void SendTestNotification()
    {
        var nowStr = DateTimeOffset.UtcNow.ToString("o");
        var timeLabel = DateTime.Now.ToString("t");
        var testMsg = new WhatsAppMessage
        {
            Id = "test-" + Guid.NewGuid().ToString(),
            Sender = "PingGlass Test",
            ChatName = "Global Notification",
            Text = "Your Windows floating glass notification is working cleanly!",
            Timestamp = timeLabel,
            ReceivedAt = nowStr,
            Source = "pingglass-test",
            Confidence = 1.0,
            IsTest = true
        };

        NotificationManager.Enqueue(testMsg, Config);
        if (Config.ChromeForwardingEnabled && ConnectedBridgeClients > 0)
        {
            IpcServer.Broadcast(new BridgeEnvelope { Type = "incoming_message", Message = testMsg });
        }
        StateChanged?.Invoke();
    }

    public void OpenWhatsAppDesktop(WhatsAppMessage? message = null)
    {
        var proc = WhatsAppDetector.CurrentProcess;
        if (proc == null || proc.MainWindowHandle == IntPtr.Zero)
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("whatsapp:")
                {
                    UseShellExecute = true
                });
            }
            catch { }
            return;
        }

        string? target = (message != null && !message.IsTest)
            ? (!string.IsNullOrWhiteSpace(message.ChatName) && message.ChatName != "Global Notification"
                ? message.ChatName
                : message.Sender)
            : null;

        if (!string.IsNullOrWhiteSpace(target))
        {
            _ = Task.Run(() => _extractor.SelectChat(target, proc.MainWindowHandle));
        }
        else
        {
            _ = Task.Run(() => _extractor.SelectChat("", proc.MainWindowHandle));
        }
    }

    public void SendReply(string replyText, WhatsAppMessage targetMessage, Action<ReplyDispatchResult> completion)
    {
        if (targetMessage.IsTest)
        {
            completion(new ReplyDispatchResult { Succeeded = true });
            return;
        }

        var proc = WhatsAppDetector.CurrentProcess;
        if (proc == null || proc.MainWindowHandle == IntPtr.Zero)
        {
            completion(new ReplyDispatchResult
            {
                Succeeded = false,
                ErrorMessage = "Open WhatsApp Desktop on Windows to send replies."
            });
            return;
        }

        string? expectedTitle = !string.IsNullOrWhiteSpace(targetMessage.ChatName) && targetMessage.ChatName != "Global Notification"
            ? targetMessage.ChatName
            : targetMessage.Sender;

        _ = Task.Run(() =>
        {
            var result = _extractor.SendReply(replyText, expectedTitle, proc.MainWindowHandle);
            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
            {
                if (result.Succeeded && ConnectedBridgeClients > 0)
                {
                    var mirror = new WhatsAppMessage
                    {
                        Id = "out-" + Guid.NewGuid().ToString(),
                        Sender = "You",
                        ChatName = targetMessage.ChatName ?? targetMessage.Sender,
                        Text = replyText.Trim(),
                        Timestamp = DateTime.Now.ToString("t"),
                        Source = "pingglass-reply",
                        Confidence = 1.0,
                        IsTest = false,
                        IsOutgoing = true
                    };
                    IpcServer.Broadcast(new BridgeEnvelope
                    {
                        Type = "reply_result",
                        Message = mirror,
                        HelperConnected = true
                    });
                }
                completion(result);
            });
        });
    }

    public HelperStatusSnapshot CurrentSnapshot()
    {
        var proc = WhatsAppDetector.CurrentProcess;
        return new HelperStatusSnapshot
        {
            MonitoringState = LifecycleState.ToWire(),
            MonitoringEnabled = Config.MonitoringEnabled,
            WhatsAppRunning = proc != null,
            WhatsAppActive = proc?.IsActive ?? false,
            WhatsAppBundleId = proc?.PackageId,
            WhatsAppVersion = proc?.Version,
            AccessibilityGranted = true,
            ObserverAttached = ObserverAttached,
            FallbackPollingActive = FallbackPollingActive,
            ExtractionMode = ExtractionMode,
            StatusDetail = StatusDetail,
            SessionMessagesForwarded = SessionMessagesForwarded,
            GlobalNotificationsEnabled = Config.GlobalNotificationsEnabled,
            NotificationsPaused = IsNotificationsPaused,
            ActiveNotificationCount = TotalActiveAndQueued,
            PauseSummary = PauseStatusSummary,
            Config = Config.ToBridgePayload()
        };
    }

    private void WireCallbacks()
    {
        NotificationManager.OnOpenWhatsAppRequested += msg => OpenWhatsAppDesktop(msg);
        NotificationManager.OnFetchLiveConversation = msg =>
        {
            var proc = WhatsAppDetector.CurrentProcess;
            string? target = msg.ChatName ?? msg.Sender;
            if (msg.IsTest || proc == null || proc.MainWindowHandle == IntPtr.Zero || string.IsNullOrWhiteSpace(target))
            {
                return new();
            }
            return _extractor.ExtractVisibleConversation(target, proc.MainWindowHandle);
        };
        NotificationManager.OnSendReplyRequested = (msg, text, cb) => SendReply(text, msg, cb);
        NotificationManager.OnCountsChanged += (active, queued) =>
        {
            VisibleNotificationCount = active;
            QueuedNotificationCount = queued;
            StateChanged?.Invoke();
        };
        NotificationManager.OnClearAllRequested += () => ClearAllNotifications();

        WhatsAppDetector.OnProcessChanged += _ =>
        {
            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
            {
                EvaluateLifecycle();
                BroadcastStatus();
            });
        };

        UiaMonitor.OnObservationUpdated += report =>
        {
            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
            {
                ObserverAttached = report.ObserverAttached;
                FallbackPollingActive = report.FallbackPollingActive;
                ExtractionMode = report.ExtractionMode;
                if (Config.MonitoringEnabled && WhatsAppDetector.CurrentProcess != null)
                {
                    if (!report.ObserverAttached && !report.FallbackPollingActive)
                    {
                        LifecycleState = MonitoringLifecycleState.Error;
                        StatusDetail = report.ErrorDescription ?? "Unable to observe WhatsApp UI.";
                    }
                    else if (!report.ObserverAttached || report.AccessibleWindowCount == 0)
                    {
                        LifecycleState = MonitoringLifecycleState.MonitoringLimited;
                        StatusDetail = report.ErrorDescription ?? "Fallback polling active; keep WhatsApp open behind apps.";
                    }
                    else
                    {
                        LifecycleState = MonitoringLifecycleState.MonitoringActive;
                        StatusDetail = "Observing WhatsApp Desktop via Windows UI Automation.";
                    }
                }
                BroadcastStatus();
                StateChanged?.Invoke();
            });
        };

        UiaMonitor.OnMessagesDetected += messages =>
        {
            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
            {
                if (!Config.MonitoringEnabled) return;
                foreach (var msg in messages)
                {
                    SessionMessagesForwarded++;
                    NotificationManager.Enqueue(msg, Config);
                    if (Config.ChromeForwardingEnabled && ConnectedBridgeClients > 0)
                    {
                        IpcServer.Broadcast(new BridgeEnvelope { Type = "incoming_message", Message = msg });
                    }
                }
                BroadcastStatus();
                StateChanged?.Invoke();
            });
        };

        IpcServer.OnClientCountChanged += count =>
        {
            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
            {
                ConnectedBridgeClients = count;
                if (count > 0)
                {
                    IpcServer.Broadcast(new BridgeEnvelope
                    {
                        Type = "connection_status",
                        Status = CurrentSnapshot(),
                        HelperConnected = true
                    });
                }
                StateChanged?.Invoke();
            });
        };

        IpcServer.OnEnvelopeReceived += envelope =>
        {
            System.Windows.Application.Current?.Dispatcher.Invoke(() => HandleIncomingBridgeEnvelope(envelope));
        };
    }

    private void HandleIncomingBridgeEnvelope(BridgeEnvelope envelope)
    {
        switch (envelope.Type)
        {
            case "ping":
                IpcServer.Broadcast(new BridgeEnvelope { Type = "pong", Status = CurrentSnapshot(), HelperConnected = true });
                break;
            case "request_status":
                BroadcastStatus();
                break;
            case "start_monitoring":
                UpdateConfiguration(c => c.MonitoringEnabled = true);
                break;
            case "pause_monitoring":
                UpdateConfiguration(c => c.MonitoringEnabled = false);
                break;
            case "test_notification":
                SendTestNotification();
                break;
            case "clear_all_notifications":
                ClearAllNotifications(fromRemote: true);
                break;
            case "dismiss_notification":
                if (envelope.Message != null && !string.IsNullOrEmpty(envelope.Message.Id))
                {
                    NotificationManager.Dismiss(envelope.Message.Id, Config.AnimationEnabled);
                }
                break;
            case "open_whatsapp":
                OpenWhatsAppDesktop(envelope.Message);
                break;
            case "send_reply":
                if (envelope.Message != null && !string.IsNullOrWhiteSpace(envelope.Message.Text))
                {
                    string reqId = envelope.Message.Id;
                    string replyText = envelope.Message.Text!;
                    SendReply(replyText, envelope.Message, result =>
                    {
                        if (result.Succeeded)
                        {
                            NotificationManager.RecordExternalOutgoingReply(replyText, envelope.Message);
                        }
                        var ack = new WhatsAppMessage
                        {
                            Id = reqId,
                            Sender = "You",
                            ChatName = envelope.Message.ChatName ?? envelope.Message.Sender,
                            Text = replyText,
                            Timestamp = DateTime.Now.ToString("t"),
                            Source = "pingglass-reply",
                            Confidence = 1.0,
                            IsTest = envelope.Message.IsTest,
                            IsOutgoing = true
                        };
                        IpcServer.Broadcast(new BridgeEnvelope
                        {
                            Type = "reply_result",
                            Message = ack,
                            HelperConnected = true,
                            Error = result.Succeeded ? null : result.ErrorMessage
                        });
                    });
                }
                break;
            case "pause_notifications":
                if (envelope.Settings?.PausedIndefinitely == true) PauseNotificationsIndefinitely();
                else if (envelope.Settings?.PauseMinutes is int m && m > 0) PauseNotificationsForMinutes(m);
                else ResumeNotifications();
                break;
            case "settings_update":
                if (envelope.Settings != null) ApplyBridgeSettings(envelope.Settings);
                break;
        }
    }

    private void ApplyBridgeSettings(BridgeSettingsPayload s)
    {
        UpdateConfiguration(c =>
        {
            if (s.MonitoringEnabled.HasValue) c.MonitoringEnabled = s.MonitoringEnabled.Value;
            if (s.AmbiguousDirectionPolicy != null) c.AmbiguousDirectionPolicy = EnumWireNames.ParseAmbiguousPolicy(s.AmbiguousDirectionPolicy);
            if (s.MaxPreviewLength.HasValue) c.MaxPreviewLength = s.MaxPreviewLength.Value;
            if (s.FallbackPollingIntervalSeconds.HasValue) c.FallbackPollingIntervalSeconds = s.FallbackPollingIntervalSeconds.Value;
            if (s.GlobalNotificationsEnabled.HasValue) c.GlobalNotificationsEnabled = s.GlobalNotificationsEnabled.Value;
            if (s.ChromeForwardingEnabled.HasValue) c.ChromeForwardingEnabled = s.ChromeForwardingEnabled.Value;
            if (s.AnimationEnabled.HasValue) c.AnimationEnabled = s.AnimationEnabled.Value;
            if (s.SoundEnabled.HasValue) c.SoundEnabled = s.SoundEnabled.Value;
            if (s.AutoDismissSeconds.HasValue) c.NotificationDurationSeconds = s.AutoDismissSeconds.Value;
            if (s.MaxVisibleNotifications.HasValue) c.MaxVisibleNotifications = s.MaxVisibleNotifications.Value;
            if (s.NotificationPosition != null) c.NotificationPosition = EnumWireNames.ParsePosition(s.NotificationPosition);
            if (s.EdgeMargin.HasValue) c.EdgeMargin = s.EdgeMargin.Value;
            if (s.AppearanceMode != null) c.AppearanceMode = EnumWireNames.ParseAppearance(s.AppearanceMode);
            if (s.NotificationClickAction != null) c.NotificationClickAction = EnumWireNames.ParseClickAction(s.NotificationClickAction);
            if (s.ShowAvatar.HasValue) c.ShowAvatar = s.ShowAvatar.Value;
            if (s.ShowSender.HasValue) c.ShowSender = s.ShowSender.Value;
            if (s.ShowChatName.HasValue) c.ShowChatName = s.ShowChatName.Value;
            if (s.ShowTimestamp.HasValue) c.ShowTimestamp = s.ShowTimestamp.Value;
            if (s.ShowPreview.HasValue) c.ShowPreview = s.ShowPreview.Value;
            if (s.ShowCopyButton.HasValue) c.ShowCopyButton = s.ShowCopyButton.Value;
        });
    }

    private void EvaluateLifecycle()
    {
        var proc = WhatsAppDetector.CurrentProcess;
        if (proc == null)
        {
            UiaMonitor.Stop(resetCache: true);
            ObserverAttached = false;
            FallbackPollingActive = false;
            ExtractionMode = "Idle";
            LifecycleState = MonitoringLifecycleState.WhatsAppNotRunning;
            StatusDetail = "Launch WhatsApp Desktop for Windows to detect new messages.";
            return;
        }

        if (!Config.MonitoringEnabled)
        {
            UiaMonitor.Stop(resetCache: false);
            ObserverAttached = false;
            FallbackPollingActive = false;
            ExtractionMode = "Monitoring Disabled";
            LifecycleState = MonitoringLifecycleState.WhatsAppDetected;
            StatusDetail = "WhatsApp detected. Click Start Monitoring to begin.";
            return;
        }

        if (proc.MainWindowHandle == IntPtr.Zero)
        {
            UiaMonitor.Stop(resetCache: false);
            LifecycleState = MonitoringLifecycleState.MonitoringLimited;
            ExtractionMode = "WhatsApp Minimized/Tray";
            StatusDetail = "Keep WhatsApp Desktop window open behind apps for live UIA capture.";
            return;
        }

        UiaMonitor.Start(proc.MainWindowHandle, Config);
    }

    private void BroadcastStatus()
    {
        if (ConnectedBridgeClients > 0)
        {
            IpcServer.Broadcast(new BridgeEnvelope
            {
                Type = "monitoring_status",
                Status = CurrentSnapshot(),
                HelperConnected = true
            });
        }
    }

    private void SchedulePauseExpirationTimerIfNeeded()
    {
        _pauseTimer?.Stop();
        _pauseTimer = null;
        if (Config.PausedIndefinitely || !Config.PausedUntil.HasValue) return;
        var remaining = Config.PausedUntil.Value - DateTimeOffset.UtcNow;
        if (remaining <= TimeSpan.Zero)
        {
            ResumeNotifications();
            return;
        }
        _pauseTimer = new DispatcherTimer { Interval = remaining + TimeSpan.FromMilliseconds(150) };
        _pauseTimer.Tick += (_, _) =>
        {
            _pauseTimer.Stop();
            ResumeNotifications();
        };
        _pauseTimer.Start();
    }

    private HelperConfiguration LoadConfig()
    {
        try
        {
            if (File.Exists(_configFilePath))
            {
                var json = File.ReadAllText(_configFilePath);
                var loaded = JsonSerializer.Deserialize<HelperConfiguration>(json);
                if (loaded != null)
                {
                    loaded.Clamp();
                    return loaded;
                }
            }
        }
        catch { }
        return new HelperConfiguration();
    }

    private void SaveConfig(HelperConfiguration config)
    {
        try
        {
            var json = JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_configFilePath, json);
        }
        catch { }
    }

    public void Dispose()
    {
        UiaMonitor.Dispose();
        WhatsAppDetector.Dispose();
        IpcServer.Dispose();
    }
}
