using System;
using System.Drawing;
using System.Threading;
using System.Windows;
using PingGlassWindows.Core;
using PingGlassWindows.Views;
using WinForms = System.Windows.Forms;

namespace PingGlassWindows;

public partial class App : System.Windows.Application
{
    private Mutex? _singleInstanceMutex;
    private WinForms.NotifyIcon? _trayIcon;
    private AppState? _appState;
    private TrayControlWindow? _trayWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstanceMutex = new Mutex(true, @"Local\PingGlassWindowsSingleInstance", out bool createdNew);
        if (!createdNew)
        {
            Shutdown();
            return;
        }

        _appState = new AppState();
        _trayWindow = new TrayControlWindow(_appState);
        MainWindow = _trayWindow;

        InitializeTrayIcon();
    }

    private void InitializeTrayIcon()
    {
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Open PingGlass Control", null, (_, _) => _trayWindow?.PositionNearTrayAndShow());
        menu.Items.Add("Send Test Notification", null, (_, _) => _appState?.SendTestNotification());
        menu.Items.Add("Clear All Notifications", null, (_, _) => _appState?.ClearAllNotifications());
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Pause 15 Minutes", null, (_, _) => _appState?.PauseNotificationsForMinutes(15));
        menu.Items.Add("Resume Notifications", null, (_, _) => _appState?.ResumeNotifications());
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Quit PingGlass", null, (_, _) => Shutdown());

        _trayIcon = new WinForms.NotifyIcon
        {
            Icon = CreateWhatsAppGreenTrayIcon(),
            Text = "PingGlass for Windows",
            Visible = true,
            ContextMenuStrip = menu
        };
        _trayIcon.MouseClick += (_, args) =>
        {
            if (args.Button == WinForms.MouseButtons.Left)
            {
                _trayWindow?.PositionNearTrayAndShow();
            }
        };
    }

    private static Icon CreateWhatsAppGreenTrayIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var brush = new SolidBrush(Color.FromArgb(37, 211, 102));
        g.FillEllipse(brush, 2, 2, 28, 28);
        using var white = new SolidBrush(Color.White);
        using var font = new Font("Segoe UI", 14, System.Drawing.FontStyle.Bold);
        g.DrawString("P", font, white, new PointF(7, 4));
        return Icon.FromHandle(bmp.GetHicon());
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
        }
        _appState?.Dispose();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }
}
