using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Zhibei.Desktop;

// WASAPI process loopback analyses only this player's output, including child
// processes. It neither opens an input device nor stores the audio samples.
public sealed class PlaybackSpectrum(Action<double[]> deliver)
{
    CancellationTokenSource? current;

    bool requested;

    public void SetActive(bool active)
    {
        if (requested == active) return;
        requested = active;
        if (!active) { var capture = current; current = null; capture?.Cancel(); return; }
        var owner = new CancellationTokenSource();
        current = owner;
        _ = Run(owner);
    }

    async Task Run(CancellationTokenSource owner)
    {
        try { await Task.Run(() => Capture(owner.Token)); }
        catch (COMException) { } // Device removal must not interrupt the player.
        catch (OperationCanceledException) when (owner.IsCancellationRequested) { }
        finally { if (current == owner) current = null; owner.Dispose(); }
    }

    async Task Capture(CancellationToken token)
    {
        var activation = new Activation();
        var parameters = Marshal.AllocCoTaskMem(12);
        IActivationOperation? operation = null;
        try
        {
            Marshal.WriteInt32(parameters, 0, 1); // AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
            Marshal.WriteInt32(parameters, 4, Environment.ProcessId);
            Marshal.WriteInt32(parameters, 8, 0); // INCLUDE_TARGET_PROCESS_TREE
            var variant = new BlobVariant { Type = 65, Size = 12, Bytes = parameters };
            var iid = typeof(IAudioClient).GUID;
            Marshal.ThrowExceptionForHR(ActivateAudioInterfaceAsync(@"VAD\Process_Loopback", ref iid, ref variant, activation, out operation));
            var client = await activation.Ready.Task.ConfigureAwait(false);
            try { if (!token.IsCancellationRequested) Read(client, token); }
            finally { Marshal.ReleaseComObject(client); }
        }
        finally
        {
            if (operation != null) Marshal.ReleaseComObject(operation);
            Marshal.FreeCoTaskMem(parameters);
        }
    }

    void Read(IAudioClient client, CancellationToken token)
    {
        const int sampleRate = 44100;
        var format = new WaveFormat { Tag = 1, Channels = 2, Samples = sampleRate, BytesPerSecond = sampleRate * 4,
            BlockAlign = 4, Bits = 16 };
        // LOOPBACK | EVENTCALLBACK | AUTOCONVERTPCM, shared stereo PCM.
        client.Initialize(0, 0x80060000, 0, 0, ref format, IntPtr.Zero);
        using var ready = new AutoResetEvent(false);
        client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle());
        Guid iid = typeof(IPackets).GUID;
        client.GetService(ref iid, out var service);
        var packets = (IPackets)service;
        try
        {
            var spectrum = new AudioSpectrum();
            var sample = new short[2048];
            var handles = new[] { ready, token.WaitHandle };
            var elapsed = Stopwatch.StartNew();
            client.Start();
            try
            {
                while (!token.IsCancellationRequested && WaitHandle.WaitAny(handles) == 0)
                {
                    packets.GetNextPacketSize(out uint available);
                    while (available > 0 && !token.IsCancellationRequested)
                    {
                        packets.GetBuffer(out var data, out uint frames, out uint flags, IntPtr.Zero, IntPtr.Zero);
                        try
                        {
                            int count = checked((int)frames * 2);
                            if (count > sample.Length) Array.Resize(ref sample, count);
                            if ((flags & 2) != 0) Array.Clear(sample, 0, count);
                            else Marshal.Copy(data, sample, 0, count);
                            for (int i = 0; i < count; i += 2)
                            {
                                var bands = spectrum.Add((sample[i] + sample[i + 1]) / 65536d, sampleRate);
                                if (bands == null || elapsed.ElapsedMilliseconds < 45) continue;
                                _ = System.Windows.Application.Current.Dispatcher.InvokeAsync(() => { if (!token.IsCancellationRequested) deliver(bands); });
                                elapsed.Restart();
                            }
                        }
                        finally { packets.ReleaseBuffer(frames); }
                        packets.GetNextPacketSize(out available);
                    }
                }
            }
            finally { client.Stop(); }
        }
        finally { Marshal.ReleaseComObject(packets); }
    }

    [StructLayout(LayoutKind.Explicit)]
    struct BlobVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public int Size;
        [FieldOffset(16)] public IntPtr Bytes; // Both supported architectures are 64-bit.
    }
    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    struct WaveFormat { public ushort Tag, Channels; public int Samples, BytesPerSecond; public ushort BlockAlign, Bits, Extra; }

    [DllImport("Mmdevapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int ActivateAudioInterfaceAsync(string path, ref Guid iid, ref BlobVariant parameters,
        ICompleted callback, out IActivationOperation operation);

    [ComVisible(true), Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ICompleted { [PreserveSig] int ActivateCompleted(IActivationOperation operation); }
    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivationOperation { void GetActivateResult(out int hr, [MarshalAs(UnmanagedType.IUnknown)] out object client); }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    sealed class Activation : ICompleted
    {
        public TaskCompletionSource<IAudioClient> Ready { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int ActivateCompleted(IActivationOperation operation)
        {
            try { operation.GetActivateResult(out int hr, out var value); Marshal.ThrowExceptionForHR(hr); Ready.SetResult((IAudioClient)value); }
            catch (Exception ex) { Ready.TrySetException(ex); }
            return 0;
        }
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        void Initialize(int shareMode, uint flags, long duration, long period, ref WaveFormat format, IntPtr session);
        void GetBufferSize(out uint size);
        void GetStreamLatency(out long latency);
        void GetCurrentPadding(out uint padding);
        void IsFormatSupported(int mode, IntPtr format, IntPtr match);
        void GetMixFormat(out IntPtr format);
        void GetDevicePeriod(out long period, out long minimum);
        void Start();
        void Stop();
        void Reset();
        void SetEventHandle(IntPtr handle);
        void GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }
    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPackets
    {
        void GetBuffer(out IntPtr data, out uint frames, out uint flags, IntPtr deviceTime, IntPtr counter);
        void ReleaseBuffer(uint frames);
        void GetNextPacketSize(out uint frames);
    }
}
