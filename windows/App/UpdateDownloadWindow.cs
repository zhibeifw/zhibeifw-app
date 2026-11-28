using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;

namespace Zhibei.Desktop;

internal sealed class UpdateDownloadWindow : Window
{
    readonly TextBlock message = new() { Text = "正在下载安装包…", TextWrapping = TextWrapping.Wrap };
    readonly ProgressBar bar = new() { Maximum = 100, IsIndeterminate = true, Height = 8 };
    readonly Button cancel = new() { Content = "取消", IsCancel = true };
    readonly Button open = new() { Content = "打开安装包", Visibility = Visibility.Collapsed, IsDefault = true };

    public UpdateDownloadWindow(Window owner, ContentService network, Uri url, CancellationToken lifetime)
    {
        Owner = owner;
        Title = "下载更新";
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.Height;
        Width = 380;
        ShowInTaskbar = false;
        AutomationProperties.SetName(bar, "下载进度");

        var content = new StackPanel { Margin = new Thickness(20) };
        var buttons = new StackPanel {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0)
        };
        bar.Margin = new Thickness(0, 8, 0, 0);
        open.Margin = new Thickness(8, 0, 0, 0);
        cancel.Click += (_, _) => Close();
        buttons.Children.Add(cancel);
        buttons.Children.Add(open);
        content.Children.Add(message);
        content.Children.Add(bar);
        content.Children.Add(buttons);
        Content = content;

        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        Closed += (_, _) => { cancellation.Cancel(); cancellation.Dispose(); };
        var token = cancellation.Token;
        Loaded += async (_, _) => await Download(network, url, token);
    }

    async Task Download(ContentService network, Uri source, CancellationToken token)
    {
        DirectoryInfo? folder = null;
        bool keepInstaller = false;
        try
        {
            folder = Directory.CreateTempSubdirectory("ZhibeiFWUpdate-");
            var installer = Path.Combine(folder.FullName, Path.GetFileName(source.LocalPath));
            var progress = new Progress<int?>(percent => {
                if (token.IsCancellationRequested || bar.Visibility != Visibility.Visible) return;
                bar.IsIndeterminate = !percent.HasValue;
                if (percent.HasValue) bar.Value = percent.Value;
                message.Text = percent.HasValue ? $"正在下载安装包… {percent}%" : "正在下载安装包…";
            });
            await using (var output = new FileStream(installer, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 65536, true))
            {
                await network.DownloadInstaller(source, output, progress, token);
                output.Position = 0;
                if (output.ReadByte() != 'M' || output.ReadByte() != 'Z')
                    throw new InvalidDataException("安装包格式无效");
            }
            token.ThrowIfCancellationRequested();
            bar.Visibility = Visibility.Collapsed;
            message.Text = "正在检查安装包…";
            await RecordInternetSourceAsync(installer, source);
            token.ThrowIfCancellationRequested();
            keepInstaller = true;
            message.Text = "安装包已下载。打开后按系统提示完成更新。";
            cancel.Content = "关闭";
            open.Visibility = Visibility.Visible;
            open.Click += (_, _) => OpenInstaller(installer);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or HttpRequestException or InvalidDataException or
            UnauthorizedAccessException or COMException or OperationCanceledException)
        {
            if (token.IsCancellationRequested) return;
            bar.Visibility = Visibility.Collapsed;
            message.Text = "无法下载安装包，请稍后重试。";
            cancel.Content = "关闭";
        }
        finally
        {
            if (!keepInstaller)
            {
                try { folder?.Delete(recursive: true); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Trace.TraceWarning(error.Message); }
            }
        }
    }

    void OpenInstaller(string installer)
    {
        try { Process.Start(new ProcessStartInfo(installer) { UseShellExecute = true }); Close(); }
        catch (Win32Exception) { message.Text = "无法打开安装包，请检查系统提示或稍后重试。"; }
    }

    static Task RecordInternetSourceAsync(string file, Uri source)
    {
        // Attachment Services requires an STA with a message loop. Its safety checks can take time.
        var result = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() => {
            var dispatcher = Dispatcher.CurrentDispatcher;
            dispatcher.BeginInvoke(() => {
                try
                {
                    RecordInternetSource(file, source);
                    result.SetResult();
                }
                catch (Exception error) { result.SetException(error); }
                finally { dispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
            });
            Dispatcher.Run();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return result.Task;
    }

    static void RecordInternetSource(string file, Uri source)
    {
        var attachment = (IAttachmentExecute)new AttachmentServices();
        try
        {
            var appId = new Guid("1E55D5B0-8BDE-45B7-BA0C-61D8372E0D2D");
            attachment.SetClientGuid(ref appId);
            attachment.SetLocalPath(file);
            attachment.SetSource(source.AbsoluteUri);
            attachment.Save();
        }
        finally { Marshal.ReleaseComObject(attachment); }
    }

    [ComImport, Guid("4125DD96-E03A-4103-8F70-E0597D803B9C")]
    class AttachmentServices { }

    [ComImport, Guid("73DB1241-1E85-4581-8E4F-A81E1D0F8C57"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAttachmentExecute
    {
        void SetClientTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetClientGuid(ref Guid guid);
        void SetLocalPath([MarshalAs(UnmanagedType.LPWStr)] string path);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void SetSource([MarshalAs(UnmanagedType.LPWStr)] string source);
        void SetReferrer([MarshalAs(UnmanagedType.LPWStr)] string referrer);
        void CheckPolicy();
        void Prompt(nint owner, int prompt, out int action);
        void Save();
    }
}
