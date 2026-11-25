using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows;
using System.Windows.Media;
using PingGlassWindows.Models;
using WinForms = System.Windows.Forms;

namespace PingGlassWindows.Notifications;

/// <summary>
/// Resolves DPI-aware WPF DIP working areas across single/multi-monitor Windows setups
/// and computes stacked frames without taskbar or offscreen overlap.
/// </summary>
public static class DisplayScreenLocator
{
    public static Rect GetTargetWorkingAreaDip(PreferredDisplayMode mode, Visual? dpiReference = null)
    {
        var screens = WinForms.Screen.AllScreens;
        if (screens.Length == 0)
        {
            return SystemParameters.WorkArea;
        }

        WinForms.Screen chosen = WinForms.Screen.PrimaryScreen ?? screens[0];

        switch (mode)
        {
            case PreferredDisplayMode.PrimaryDisplay:
                chosen = WinForms.Screen.PrimaryScreen ?? screens[0];
                break;

            case PreferredDisplayMode.SecondaryDisplay:
                chosen = Array.Find(screens, s => !s.Primary) ?? WinForms.Screen.PrimaryScreen ?? screens[0];
                break;

            case PreferredDisplayMode.ActiveDisplay:
            default:
                var cursor = WinForms.Cursor.Position;
                chosen = WinForms.Screen.FromPoint(cursor);
                break;
        }

        return ToDipRect(chosen.WorkingArea, dpiReference);
    }

    private static Rect ToDipRect(Rectangle pixelRect, Visual? reference)
    {
        double scaleX = 1.0;
        double scaleY = 1.0;
        var source = reference != null ? PresentationSource.FromVisual(reference) : null;
        if (source?.CompositionTarget != null)
        {
            scaleX = source.CompositionTarget.TransformFromDevice.M11;
            scaleY = source.CompositionTarget.TransformFromDevice.M22;
        }
        else if (System.Windows.Application.Current?.MainWindow != null)
        {
            var mainSrc = PresentationSource.FromVisual(System.Windows.Application.Current.MainWindow);
            if (mainSrc?.CompositionTarget != null)
            {
                scaleX = mainSrc.CompositionTarget.TransformFromDevice.M11;
                scaleY = mainSrc.CompositionTarget.TransformFromDevice.M22;
            }
        }

        return new Rect(
            pixelRect.Left * scaleX,
            pixelRect.Top * scaleY,
            pixelRect.Width * scaleX,
            pixelRect.Height * scaleY);
    }

    public static List<Rect> ComputeStackedFrames(
        IReadOnlyList<System.Windows.Size> cardSizes,
        Rect workArea,
        NotificationPosition position,
        double edgeMargin,
        double stackSpacing = 8.0)
    {
        var frames = new List<Rect>(cardSizes.Count);
        var margin = Math.Max(8.0, edgeMargin);
        var cursorY = position.GrowsUpward() ? (workArea.Bottom - margin) : (workArea.Top + margin);

        foreach (var size in cardSizes)
        {
            double x = position.IsRightAligned()
                ? workArea.Right - margin - size.Width
                : workArea.Left + margin;

            x = Math.Max(workArea.Left + 6.0, Math.Min(x, workArea.Right - size.Width - 6.0));

            double y;
            if (position == NotificationPosition.CenterRight && frames.Count == 0)
            {
                y = workArea.Top + Math.Max(margin, (workArea.Height - size.Height) / 2.0 - 90.0);
                cursorY = y + size.Height + stackSpacing;
            }
            else if (position.GrowsUpward())
            {
                y = cursorY - size.Height;
                cursorY = y - stackSpacing;
            }
            else
            {
                y = cursorY;
                cursorY += size.Height + stackSpacing;
            }

            y = Math.Max(workArea.Top + 6.0, Math.Min(y, workArea.Bottom - size.Height - 6.0));
            frames.Add(new Rect(x, y, size.Width, size.Height));
        }

        return frames;
    }

    public static Rect ComputeClearAllBarFrame(
        IReadOnlyList<Rect> cardFrames,
        System.Windows.Size barSize,
        Rect workArea,
        NotificationPosition position,
        double edgeMargin)
    {
        double margin = Math.Max(8.0, edgeMargin);
        double x = position.IsRightAligned()
            ? workArea.Right - margin - barSize.Width
            : workArea.Left + margin;

        double y;
        if (cardFrames.Count == 0)
        {
            y = position.GrowsUpward() ? (workArea.Bottom - margin - barSize.Height) : (workArea.Top + margin);
        }
        else if (position.GrowsUpward())
        {
            double minTop = cardFrames[0].Top;
            foreach (var r in cardFrames) minTop = Math.Min(minTop, r.Top);
            y = minTop - 8.0 - barSize.Height;
        }
        else
        {
            double maxBottom = cardFrames[0].Bottom;
            foreach (var r in cardFrames) maxBottom = Math.Max(maxBottom, r.Bottom);
            y = maxBottom + 8.0;
        }

        x = Math.Max(workArea.Left + 6.0, Math.Min(x, workArea.Right - barSize.Width - 6.0));
        y = Math.Max(workArea.Top + 6.0, Math.Min(y, workArea.Bottom - barSize.Height - 6.0));
        return new Rect(x, y, barSize.Width, barSize.Height);
    }

    public static Rect ComputeChatPopupFrame(
        System.Windows.Size popupSize,
        Rect workArea,
        NotificationPosition position,
        double edgeMargin,
        IReadOnlyList<Rect>? activeCardFrames = null)
    {
        double margin = Math.Max(8.0, edgeMargin);
        double x = position.IsRightAligned()
            ? workArea.Right - margin - popupSize.Width
            : workArea.Left + margin;

        if (activeCardFrames is { Count: > 0 })
        {
            double cardWidth = activeCardFrames[0].Width;
            double offsetShift = cardWidth + 14.0;
            if (position.IsRightAligned())
            {
                double shifted = x - offsetShift;
                if (shifted >= workArea.Left + 8.0) x = shifted;
            }
            else
            {
                double shifted = x + offsetShift;
                if (shifted + popupSize.Width <= workArea.Right - 8.0) x = shifted;
            }
        }

        double y = position switch
        {
            NotificationPosition.TopRight or NotificationPosition.TopLeft => workArea.Top + margin,
            NotificationPosition.CenterRight => workArea.Top + Math.Max(margin, (workArea.Height - popupSize.Height) / 2.0),
            _ => workArea.Bottom - margin - popupSize.Height
        };

        x = Math.Max(workArea.Left + 6.0, Math.Min(x, workArea.Right - popupSize.Width - 6.0));
        y = Math.Max(workArea.Top + 6.0, Math.Min(y, workArea.Bottom - popupSize.Height - 6.0));
        return new Rect(x, y, popupSize.Width, popupSize.Height);
    }
}
