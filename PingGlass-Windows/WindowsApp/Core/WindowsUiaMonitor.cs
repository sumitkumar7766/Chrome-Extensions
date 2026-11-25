using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using PingGlassWindows.Models;

namespace PingGlassWindows.Core;

public sealed record UiaObservationReport(
    bool ObserverAttached,
    bool FallbackPollingActive,
    int AccessibleWindowCount,
    string ExtractionMode,
    string? ErrorDescription);

/// <summary>
/// Real-time Windows UI Automation monitor combining UIA event hooks (StructureChanged & NameChanged)
/// with bounded fallback polling so messages trigger immediately even when Windows banners are OFF.
/// </summary>
public sealed class WindowsUiaMonitor : IDisposable
{
    private readonly WindowsUiaExtractor _extractor;
    private readonly MessageProcessor _processor;
    private Timer? _pollTimer;
    private Timer? _debounceTimer;
    private IntPtr _observedHwnd;
    private AutomationElement? _observedElement;
    private StructureChangedEventHandler? _structureHandler;
    private AutomationPropertyChangedEventHandler? _propHandler;
    private bool _isActive;
    private bool _needsBaselineSeed = true;
    private HelperConfiguration _lastConfig = new();
    private bool _observerAttached;

    public event Action<List<WhatsAppMessage>>? OnMessagesDetected;
    public event Action<UiaObservationReport>? OnObservationUpdated;

    public WindowsUiaMonitor(WindowsUiaExtractor extractor, MessageProcessor processor)
    {
        _extractor = extractor;
        _processor = processor;
    }

    public void Start(IntPtr hwnd, HelperConfiguration config)
    {
        _lastConfig = config.Clone();
        if (_isActive && _observedHwnd == hwnd)
        {
            RestartPollingTimer(config.FallbackPollingIntervalSeconds);
            return;
        }

        Stop(resetCache: true);
        _observedHwnd = hwnd;
        _needsBaselineSeed = true;
        _isActive = true;

        AttachHandlers(hwnd);
        RestartPollingTimer(config.FallbackPollingIntervalSeconds);
        ScheduleScan(immediate: true);
    }

    public void UpdateConfiguration(HelperConfiguration config)
    {
        _lastConfig = config.Clone();
        if (_isActive)
        {
            RestartPollingTimer(config.FallbackPollingIntervalSeconds);
        }
    }

    public void Stop(bool resetCache = true)
    {
        _isActive = false;
        _observedHwnd = IntPtr.Zero;
        _pollTimer?.Dispose();
        _pollTimer = null;
        _debounceTimer?.Dispose();
        _debounceTimer = null;
        DetachHandlers();
        if (resetCache)
        {
            _processor.ResetCache();
        }
    }

    private void AttachHandlers(IntPtr hwnd)
    {
        try
        {
            var element = AutomationElement.FromHandle(hwnd);
            if (element == null)
            {
                _observerAttached = false;
                return;
            }
            _observedElement = element;
            _structureHandler = (_, _) => HandleUiaSignal();
            _propHandler = (_, _) => HandleUiaSignal();
            Automation.AddStructureChangedEventHandler(element, TreeScope.Subtree, _structureHandler);
            Automation.AddAutomationPropertyChangedEventHandler(
                element,
                TreeScope.Subtree,
                _propHandler,
                AutomationElement.NameProperty);
            _observerAttached = true;
        }
        catch
        {
            _observerAttached = false;
        }
    }

    private void DetachHandlers()
    {
        if (_observedElement != null)
        {
            try
            {
                if (_structureHandler != null)
                    Automation.RemoveStructureChangedEventHandler(_observedElement, _structureHandler);
                if (_propHandler != null)
                    Automation.RemoveAutomationPropertyChangedEventHandler(_observedElement, _propHandler);
            }
            catch
            {
                // Ignore if target window already closed.
            }
        }
        _observedElement = null;
        _structureHandler = null;
        _propHandler = null;
        _observerAttached = false;
    }

    private void HandleUiaSignal()
    {
        if (!_isActive) return;
        ScheduleScan(immediate: false);
    }

    private void RestartPollingTimer(double intervalSeconds)
    {
        _pollTimer?.Dispose();
        int ms = (int)(Math.Clamp(intervalSeconds, 1.5, 15.0) * 1000);
        _pollTimer = new Timer(_ =>
        {
            if (_isActive) ScheduleScan(immediate: false);
        }, null, ms, ms);
    }

    private void ScheduleScan(bool immediate)
    {
        _debounceTimer?.Dispose();
        int delayMs = immediate ? 30 : 280;
        _debounceTimer = new Timer(_ => _ = Task.Run(ExecuteScan), null, delayMs, Timeout.Infinite);
    }

    private void ExecuteScan()
    {
        if (!_isActive || _observedHwnd == IntPtr.Zero) return;

        bool seedOnly = _needsBaselineSeed;
        var configSnapshot = _lastConfig.Clone();
        var result = _extractor.Extract(_observedHwnd);
        var messages = _processor.Process(result.Candidates, configSnapshot, seedOnly);

        if (seedOnly)
        {
            _needsBaselineSeed = false;
        }

        bool usableUi = result.AccessibleWindowCount > 0 && result.VisitedNodeCount > 4;
        string modeSummary = usableUi
            ? $"{result.ExtractionMode} ({result.VisitedNodeCount} nodes)"
            : "WhatsApp Minimized/Closed";

        OnObservationUpdated?.Invoke(new UiaObservationReport(
            ObserverAttached: _observerAttached,
            FallbackPollingActive: _pollTimer != null,
            AccessibleWindowCount: result.AccessibleWindowCount,
            ExtractionMode: modeSummary,
            ErrorDescription: usableUi ? null : "Keep WhatsApp Desktop window open behind apps for live UIA detection."));

        if (!seedOnly && messages.Count > 0)
        {
            OnMessagesDetected?.Invoke(messages);
        }
    }

    public void Dispose()
    {
        Stop(resetCache: true);
    }
}
