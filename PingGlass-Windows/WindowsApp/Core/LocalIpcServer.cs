using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using PingGlassWindows.Models;

namespace PingGlassWindows.Core;

/// <summary>
/// User-authenticated loopback TCP server bridging PingGlassWindows.exe with Windows pingglass_native_host.py.
/// Writes port and a random 256-bit per-session auth token into %LOCALAPPDATA%\PingGlass\ with 4-byte LE JSON framing.
/// Zero external network exposure (127.0.0.1 only + constant-time token verification).
/// </summary>
public sealed class LocalIpcServer : IDisposable
{
    public const int MaxPayloadBytes = 1_048_576;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly string _appDataDir;
    private readonly string _portFilePath;
    private readonly string _tokenFilePath;
    private readonly string _authTokenHex;
    private readonly object _clientsLock = new();
    private readonly List<ClientSession> _clients = new();

    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    public event Action<BridgeEnvelope>? OnEnvelopeReceived;
    public event Action<int>? OnClientCountChanged;

    private sealed class ClientSession
    {
        public TcpClient Client { get; }
        public NetworkStream Stream { get; }
        public SemaphoreSlim WriteLock { get; } = new(1, 1);
        public bool Authenticated { get; set; }

        public ClientSession(TcpClient client)
        {
            Client = client;
            Stream = client.GetStream();
        }
    }

    public LocalIpcServer(string? customDirectory = null)
    {
        _appDataDir = customDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PingGlass");
        _portFilePath = Path.Combine(_appDataDir, "bridge.port");
        _tokenFilePath = Path.Combine(_appDataDir, "bridge.token");

        Span<byte> randomBytes = stackalloc byte[32];
        RandomNumberGenerator.Fill(randomBytes);
        _authTokenHex = Convert.ToHexString(randomBytes).ToLowerInvariant();
    }

    public int ConnectedClientCount
    {
        get
        {
            lock (_clientsLock)
            {
                return _clients.FindAll(c => c.Authenticated).Count;
            }
        }
    }

    public void Start()
    {
        Directory.CreateDirectory(_appDataDir);
        _cts = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();

        int boundPort = ((IPEndPoint)_listener.LocalEndpoint).Port;
        File.WriteAllText(_portFilePath, boundPort.ToString(), Encoding.UTF8);
        File.WriteAllText(_tokenFilePath, _authTokenHex, Encoding.UTF8);

        _ = AcceptLoopAsync(_cts.Token);
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _listener?.Stop(); } catch { }

        List<ClientSession> snapshot;
        lock (_clientsLock)
        {
            snapshot = new List<ClientSession>(_clients);
            _clients.Clear();
        }

        foreach (var session in snapshot)
        {
            try { session.Client.Close(); } catch { }
        }

        try { if (File.Exists(_portFilePath)) File.Delete(_portFilePath); } catch { }
        try { if (File.Exists(_tokenFilePath)) File.Delete(_tokenFilePath); } catch { }
        OnClientCountChanged?.Invoke(0);
    }

    public void Broadcast(BridgeEnvelope envelope)
    {
        var frame = EncodeFrame(envelope);
        if (frame == null) return;

        List<ClientSession> targets;
        lock (_clientsLock)
        {
            targets = _clients.FindAll(c => c.Authenticated);
        }

        foreach (var client in targets)
        {
            _ = SendFrameAsync(client, frame);
        }
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener != null)
        {
            try
            {
                var tcpClient = await _listener.AcceptTcpClientAsync(ct).ConfigureAwait(false);
                var session = new ClientSession(tcpClient);
                lock (_clientsLock)
                {
                    _clients.Add(session);
                }
                _ = HandleClientAsync(session, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                await Task.Delay(250, ct).ConfigureAwait(false);
            }
        }
    }

    private async Task HandleClientAsync(ClientSession session, CancellationToken ct)
    {
        var headerBuf = new byte[4];
        try
        {
            while (!ct.IsCancellationRequested && session.Client.Connected)
            {
                if (!await ReadExactAsync(session.Stream, headerBuf, ct).ConfigureAwait(false))
                {
                    break;
                }

                uint length = BinaryPrimitives.ReadUInt32LittleEndian(headerBuf);
                if (length == 0 || length > MaxPayloadBytes)
                {
                    break;
                }

                var bodyBuf = new byte[length];
                if (!await ReadExactAsync(session.Stream, bodyBuf, ct).ConfigureAwait(false))
                {
                    break;
                }

                BridgeEnvelope? envelope;
                try
                {
                    envelope = JsonSerializer.Deserialize<BridgeEnvelope>(bodyBuf, JsonOptions);
                }
                catch
                {
                    continue;
                }

                if (envelope == null) continue;

                if (!session.Authenticated)
                {
                    if (envelope.Type == "auth" && ConstantTimeEquals(envelope.Token, _authTokenHex))
                    {
                        session.Authenticated = true;
                        OnClientCountChanged?.Invoke(ConnectedClientCount);
                        continue;
                    }
                    // Reject unauthenticated messages immediately.
                    break;
                }

                OnEnvelopeReceived?.Invoke(envelope);
            }
        }
        catch
        {
            // Connection closed cleanly.
        }
        finally
        {
            bool wasAuthed = session.Authenticated;
            lock (_clientsLock)
            {
                _clients.Remove(session);
            }
            try { session.Client.Close(); } catch { }
            if (wasAuthed)
            {
                OnClientCountChanged?.Invoke(ConnectedClientCount);
            }
        }
    }

    private async Task SendFrameAsync(ClientSession session, byte[] frame)
    {
        try
        {
            await session.WriteLock.WaitAsync().ConfigureAwait(false);
            await session.Stream.WriteAsync(frame).ConfigureAwait(false);
            await session.Stream.FlushAsync().ConfigureAwait(false);
        }
        catch
        {
            try { session.Client.Close(); } catch { }
        }
        finally
        {
            session.WriteLock.Release();
        }
    }

    public static byte[]? EncodeFrame(BridgeEnvelope envelope)
    {
        var jsonBytes = JsonSerializer.SerializeToUtf8Bytes(envelope, JsonOptions);
        if (jsonBytes.Length == 0 || jsonBytes.Length > MaxPayloadBytes) return null;

        var frame = new byte[4 + jsonBytes.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(0, 4), (uint)jsonBytes.Length);
        Buffer.BlockCopy(jsonBytes, 0, frame, 4, jsonBytes.Length);
        return frame;
    }

    private static async Task<bool> ReadExactAsync(Stream stream, byte[] buffer, CancellationToken ct)
    {
        int offset = 0;
        while (offset < buffer.Length)
        {
            int read = await stream.ReadAsync(buffer.AsMemory(offset, buffer.Length - offset), ct).ConfigureAwait(false);
            if (read <= 0) return false;
            offset += read;
        }
        return true;
    }

    private static bool ConstantTimeEquals(string? a, string b)
    {
        if (a == null) return false;
        var aBytes = Encoding.UTF8.GetBytes(a);
        var bBytes = Encoding.UTF8.GetBytes(b);
        return CryptographicOperations.FixedTimeEquals(aBytes, bBytes);
    }

    public void Dispose()
    {
        Stop();
    }
}
