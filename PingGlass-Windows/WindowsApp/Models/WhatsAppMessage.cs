using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace PingGlassWindows.Models;

public static class EnumWireNames
{
    public static string ToWire(this MonitoringLifecycleState state) => state switch
    {
        MonitoringLifecycleState.WhatsAppNotRunning => "whatsapp_not_running",
        MonitoringLifecycleState.WhatsAppDetected => "whatsapp_detected",
        MonitoringLifecycleState.AccessibilityRequired => "accessibility_required",
        MonitoringLifecycleState.MonitoringActive => "monitoring_active",
        MonitoringLifecycleState.MonitoringLimited => "monitoring_limited",
        MonitoringLifecycleState.Error => "error",
        _ => "whatsapp_not_running"
    };

    public static string DisplayTitle(this MonitoringLifecycleState state) => state switch
    {
        MonitoringLifecycleState.WhatsAppNotRunning => "WhatsApp Not Running",
        MonitoringLifecycleState.WhatsAppDetected => "WhatsApp Detected",
        MonitoringLifecycleState.AccessibilityRequired => "UI Automation Access Required",
        MonitoringLifecycleState.MonitoringActive => "Monitoring Active",
        MonitoringLifecycleState.MonitoringLimited => "Monitoring Limited",
        MonitoringLifecycleState.Error => "Error",
        _ => "Unknown"
    };

    public static string ToWire(this AmbiguousDirectionPolicy policy) => policy switch
    {
        AmbiguousDirectionPolicy.Ignore => "ignore",
        AmbiguousDirectionPolicy.ForwardLowConfidence => "forward_low_confidence",
        _ => "ignore"
    };

    public static AmbiguousDirectionPolicy ParseAmbiguousPolicy(string? raw) => raw switch
    {
        "forward_low_confidence" => AmbiguousDirectionPolicy.ForwardLowConfidence,
        _ => AmbiguousDirectionPolicy.Ignore
    };

    public static string ToWire(this NotificationPosition pos) => pos switch
    {
        NotificationPosition.BottomRight => "bottom_right",
        NotificationPosition.CenterRight => "center_right",
        NotificationPosition.TopRight => "top_right",
        NotificationPosition.BottomLeft => "bottom_left",
        NotificationPosition.TopLeft => "top_left",
        _ => "bottom_right"
    };

    public static NotificationPosition ParsePosition(string? raw) => raw switch
    {
        "center_right" => NotificationPosition.CenterRight,
        "top_right" => NotificationPosition.TopRight,
        "bottom_left" => NotificationPosition.BottomLeft,
        "top_left" => NotificationPosition.TopLeft,
        _ => NotificationPosition.BottomRight
    };

    public static bool IsRightAligned(this NotificationPosition pos) =>
        pos is NotificationPosition.BottomRight or NotificationPosition.CenterRight or NotificationPosition.TopRight;

    public static bool GrowsUpward(this NotificationPosition pos) =>
        pos is NotificationPosition.BottomRight or NotificationPosition.BottomLeft;

    public static string ToWire(this GlassAppearanceMode mode) => mode == GlassAppearanceMode.Light ? "light" : "dark";

    public static GlassAppearanceMode ParseAppearance(string? raw) =>
        string.Equals(raw, "light", StringComparison.OrdinalIgnoreCase) ? GlassAppearanceMode.Light : GlassAppearanceMode.Dark;

    public static string ToWire(this NotificationClickAction action) => action == NotificationClickAction.OpenWhatsAppDirectly
        ? "open_whatsapp_directly"
        : "open_glass_chat_popup";

    public static NotificationClickAction ParseClickAction(string? raw) =>
        string.Equals(raw, "open_whatsapp_directly", StringComparison.OrdinalIgnoreCase)
            ? NotificationClickAction.OpenWhatsAppDirectly
            : NotificationClickAction.OpenGlassChatPopup;

    public static string ToWire(this PreferredDisplayMode mode) => mode switch
    {
        PreferredDisplayMode.PrimaryDisplay => "primary_display",
        PreferredDisplayMode.SecondaryDisplay => "secondary_display",
        _ => "active_display"
    };
}

public enum MonitoringLifecycleState
{
    WhatsAppNotRunning,
    WhatsAppDetected,
    AccessibilityRequired,
    MonitoringActive,
    MonitoringLimited,
    Error
}

public enum AmbiguousDirectionPolicy
{
    Ignore,
    ForwardLowConfidence
}

public enum NotificationPosition
{
    BottomRight,
    CenterRight,
    TopRight,
    BottomLeft,
    TopLeft
}

public enum PreferredDisplayMode
{
    ActiveDisplay,
    PrimaryDisplay,
    SecondaryDisplay
}

public enum GlassAppearanceMode
{
    Dark,
    Light
}

public enum NotificationClickAction
{
    OpenGlassChatPopup,
    OpenWhatsAppDirectly
}

public sealed class WhatsAppMessage
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString();

    [JsonPropertyName("sender")]
    public string? Sender { get; set; }

    [JsonPropertyName("chatName")]
    public string? ChatName { get; set; }

    [JsonPropertyName("text")]
    public string? Text { get; set; }

    [JsonPropertyName("timestamp")]
    public string? Timestamp { get; set; }

    [JsonPropertyName("avatar")]
    public string? Avatar { get; set; }

    [JsonPropertyName("receivedAt")]
    public string ReceivedAt { get; set; } = DateTimeOffset.UtcNow.ToString("o");

    [JsonPropertyName("source")]
    public string Source { get; set; } = "whatsapp-desktop";

    [JsonPropertyName("confidence")]
    public double Confidence { get; set; }

    [JsonPropertyName("isTest")]
    public bool IsTest { get; set; }

    [JsonPropertyName("isOutgoing")]
    public bool IsOutgoing { get; set; }
}

public sealed class ChatBubbleEntry
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string? Sender { get; set; }
    public string Text { get; set; } = string.Empty;
    public string? Timestamp { get; set; }
    public bool IsOutgoing { get; set; }
    public bool IsTest { get; set; }
}

public sealed class ReplyDispatchResult
{
    public bool Succeeded { get; init; }
    public string? ErrorMessage { get; init; }
}

public sealed class HelperConfiguration
{
    public bool MonitoringEnabled { get; set; } = true;
    public double FallbackPollingIntervalSeconds { get; set; } = 2.5;
    public AmbiguousDirectionPolicy AmbiguousDirectionPolicy { get; set; } = AmbiguousDirectionPolicy.Ignore;
    public int MaxPreviewLength { get; set; } = 280;

    public bool GlobalNotificationsEnabled { get; set; } = true;
    public bool ChromeForwardingEnabled { get; set; } = true;
    public bool AnimationEnabled { get; set; } = true;
    public bool NativeGlassBlurEnabled { get; set; } = true;
    public int NotificationDurationSeconds { get; set; } = 0; // 0 = Until closed (Never)
    public int MaxVisibleNotifications { get; set; } = 3;
    public NotificationPosition NotificationPosition { get; set; } = NotificationPosition.BottomRight;
    public double EdgeMargin { get; set; } = 28.0;
    public PreferredDisplayMode PreferredDisplayMode { get; set; } = PreferredDisplayMode.ActiveDisplay;
    public GlassAppearanceMode AppearanceMode { get; set; } = GlassAppearanceMode.Dark;
    public NotificationClickAction NotificationClickAction { get; set; } = NotificationClickAction.OpenGlassChatPopup;

    public bool ShowAvatar { get; set; } = true;
    public bool ShowSender { get; set; } = true;
    public bool ShowChatName { get; set; } = true;
    public bool ShowTimestamp { get; set; } = true;
    public bool ShowPreview { get; set; } = true;
    public bool ShowCopyButton { get; set; } = true;
    public bool SoundEnabled { get; set; } = false;

    public DateTimeOffset? PausedUntil { get; set; }
    public bool PausedIndefinitely { get; set; }

    public bool IsNotificationsPaused(DateTimeOffset? now = null)
    {
        if (PausedIndefinitely) return true;
        if (PausedUntil.HasValue && PausedUntil.Value > (now ?? DateTimeOffset.UtcNow)) return true;
        return false;
    }

    public HelperConfiguration Clone() => (HelperConfiguration)MemberwiseClone();

    public void Clamp()
    {
        FallbackPollingIntervalSeconds = Math.Clamp(FallbackPollingIntervalSeconds, 1.5, 15.0);
        MaxPreviewLength = Math.Clamp(MaxPreviewLength, 80, 1000);
        NotificationDurationSeconds = Math.Clamp(NotificationDurationSeconds, 0, 60);
        MaxVisibleNotifications = Math.Clamp(MaxVisibleNotifications, 1, 6);
        EdgeMargin = Math.Clamp(EdgeMargin, 12.0, 64.0);
    }

    public BridgeSettingsPayload ToBridgePayload() => new()
    {
        MonitoringEnabled = MonitoringEnabled,
        AmbiguousDirectionPolicy = AmbiguousDirectionPolicy.ToWire(),
        MaxPreviewLength = MaxPreviewLength,
        FallbackPollingIntervalSeconds = FallbackPollingIntervalSeconds,
        GlobalNotificationsEnabled = GlobalNotificationsEnabled,
        ChromeForwardingEnabled = ChromeForwardingEnabled,
        NotificationsPaused = IsNotificationsPaused(),
        PausedIndefinitely = PausedIndefinitely,
        AnimationEnabled = AnimationEnabled,
        SoundEnabled = SoundEnabled,
        AutoDismissSeconds = NotificationDurationSeconds,
        MaxVisibleNotifications = MaxVisibleNotifications,
        NotificationPosition = NotificationPosition.ToWire(),
        EdgeMargin = EdgeMargin,
        AppearanceMode = AppearanceMode.ToWire(),
        NotificationClickAction = NotificationClickAction.ToWire(),
        ShowAvatar = ShowAvatar,
        ShowSender = ShowSender,
        ShowChatName = ShowChatName,
        ShowTimestamp = ShowTimestamp,
        ShowPreview = ShowPreview,
        ShowCopyButton = ShowCopyButton
    };
}

public sealed class HelperStatusSnapshot
{
    [JsonPropertyName("monitoringState")]
    public string MonitoringState { get; set; } = "whatsapp_not_running";

    [JsonPropertyName("monitoringEnabled")]
    public bool MonitoringEnabled { get; set; }

    [JsonPropertyName("whatsappRunning")]
    public bool WhatsAppRunning { get; set; }

    [JsonPropertyName("whatsappActive")]
    public bool WhatsAppActive { get; set; }

    [JsonPropertyName("whatsappBundleId")]
    public string? WhatsAppBundleId { get; set; }

    [JsonPropertyName("whatsappVersion")]
    public string? WhatsAppVersion { get; set; }

    [JsonPropertyName("accessibilityGranted")]
    public bool AccessibilityGranted { get; set; } = true;

    [JsonPropertyName("observerAttached")]
    public bool ObserverAttached { get; set; }

    [JsonPropertyName("fallbackPollingActive")]
    public bool FallbackPollingActive { get; set; }

    [JsonPropertyName("extractionMode")]
    public string ExtractionMode { get; set; } = "Idle";

    [JsonPropertyName("statusDetail")]
    public string StatusDetail { get; set; } = string.Empty;

    [JsonPropertyName("sessionMessagesForwarded")]
    public int SessionMessagesForwarded { get; set; }

    [JsonPropertyName("globalNotificationsEnabled")]
    public bool GlobalNotificationsEnabled { get; set; } = true;

    [JsonPropertyName("notificationsPaused")]
    public bool NotificationsPaused { get; set; }

    [JsonPropertyName("activeNotificationCount")]
    public int ActiveNotificationCount { get; set; }

    [JsonPropertyName("pauseSummary")]
    public string? PauseSummary { get; set; }

    [JsonPropertyName("config")]
    public BridgeSettingsPayload? Config { get; set; }

    [JsonPropertyName("updatedAt")]
    public string UpdatedAt { get; set; } = DateTimeOffset.UtcNow.ToString("o");
}

public sealed class BridgeSettingsPayload
{
    [JsonPropertyName("monitoringEnabled")]
    public bool? MonitoringEnabled { get; set; }

    [JsonPropertyName("ambiguousDirectionPolicy")]
    public string? AmbiguousDirectionPolicy { get; set; }

    [JsonPropertyName("maxPreviewLength")]
    public int? MaxPreviewLength { get; set; }

    [JsonPropertyName("fallbackPollingIntervalSeconds")]
    public double? FallbackPollingIntervalSeconds { get; set; }

    [JsonPropertyName("globalNotificationsEnabled")]
    public bool? GlobalNotificationsEnabled { get; set; }

    [JsonPropertyName("chromeForwardingEnabled")]
    public bool? ChromeForwardingEnabled { get; set; }

    [JsonPropertyName("notificationsPaused")]
    public bool? NotificationsPaused { get; set; }

    [JsonPropertyName("pauseMinutes")]
    public int? PauseMinutes { get; set; }

    [JsonPropertyName("pausedIndefinitely")]
    public bool? PausedIndefinitely { get; set; }

    [JsonPropertyName("animationEnabled")]
    public bool? AnimationEnabled { get; set; }

    [JsonPropertyName("soundEnabled")]
    public bool? SoundEnabled { get; set; }

    [JsonPropertyName("autoDismissSeconds")]
    public int? AutoDismissSeconds { get; set; }

    [JsonPropertyName("maxVisibleNotifications")]
    public int? MaxVisibleNotifications { get; set; }

    [JsonPropertyName("notificationPosition")]
    public string? NotificationPosition { get; set; }

    [JsonPropertyName("edgeMargin")]
    public double? EdgeMargin { get; set; }

    [JsonPropertyName("appearanceMode")]
    public string? AppearanceMode { get; set; }

    [JsonPropertyName("notificationClickAction")]
    public string? NotificationClickAction { get; set; }

    [JsonPropertyName("showAvatar")]
    public bool? ShowAvatar { get; set; }

    [JsonPropertyName("showSender")]
    public bool? ShowSender { get; set; }

    [JsonPropertyName("showChatName")]
    public bool? ShowChatName { get; set; }

    [JsonPropertyName("showTimestamp")]
    public bool? ShowTimestamp { get; set; }

    [JsonPropertyName("showPreview")]
    public bool? ShowPreview { get; set; }

    [JsonPropertyName("showCopyButton")]
    public bool? ShowCopyButton { get; set; }
}

public sealed class BridgeEnvelope
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = string.Empty;

    [JsonPropertyName("token")]
    public string? Token { get; set; }

    [JsonPropertyName("message")]
    public WhatsAppMessage? Message { get; set; }

    [JsonPropertyName("status")]
    public HelperStatusSnapshot? Status { get; set; }

    [JsonPropertyName("settings")]
    public BridgeSettingsPayload? Settings { get; set; }

    [JsonPropertyName("helperConnected")]
    public bool? HelperConnected { get; set; }

    [JsonPropertyName("error")]
    public string? Error { get; set; }

    [JsonPropertyName("diagnostics")]
    public string? Diagnostics { get; set; }

    [JsonPropertyName("timestamp")]
    public string Timestamp { get; set; } = DateTimeOffset.UtcNow.ToString("o");
}
