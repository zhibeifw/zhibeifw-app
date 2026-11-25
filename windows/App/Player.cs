using System.Diagnostics;
using System.Windows.Threading;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace Zhibei.Desktop;

sealed class Player(Store store, ContentService network, Dispatcher ui, CancellationToken lifetime) : IDisposable
{
    MediaPlayer? media;
    MediaSource? source;
    readonly Stopwatch sinceSave = new();
    System.Threading.Timer? sleepTimer;
    bool opened, continuous, firstSave, ended;
    double resume;
    CancellationTokenSource? stall;
    Uri? audioUri;
    public Course? Course { get; private set; }
    public Episode? Episode { get; private set; }
    public double Position { get; private set; }
    public double Duration { get; private set; }
    public double Rate { get; private set; } = 1;
    public int Sleep { get; private set; }
    public string Error { get; private set; } = "";
    public bool Playing => media?.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;
    public bool Loading => media != null && (!opened || media.PlaybackSession.PlaybackState is MediaPlaybackState.Opening or MediaPlaybackState.Buffering);
    public bool CanSeek => opened && !ended && media?.PlaybackSession.CanSeek == true;
    public event Action? Changed;
    public event Action? ProgressChanged;
    public event Action<bool>? PlaybackFailed;

    // 每次换集都用该集独立的系统播放器，只接受当前实例的回调。
    void OnUi(MediaPlayer sender, Action work)
    {
        ui.InvokeAsync(() => { if (sender == media) work(); });
    }

    public async void Start(Course course, Episode episode, bool playCourse)
    {
        Save();
        Release();
        Course = course;
        Episode = episode;
        continuous = playCourse;
        ended = false;
        firstSave = true;
        Error = "";
        var old = store.ReadProgress(episode.Id);
        Position = resume = old is { Completed: false } ? old.Position : 0;
        Duration = episode.Duration > 0 ? episode.Duration : old?.Duration ?? 0;
        MediaPlayer? player = null;
        try
        {
            player = new MediaPlayer { AudioCategory = MediaPlayerAudioCategory.Media, AutoPlay = false };
            media = player;
            Changed?.Invoke();
            var origin = await network.EnsureOrigin(lifetime);
            if (media != player) return;
            audioUri = Catalog.MediaUri(origin, episode.Path);
            source = MediaSource.CreateFromUri(audioUri);
            var item = new MediaPlaybackItem(source);
            var info = item.GetDisplayProperties();
            info.Type = MediaPlaybackType.Music;
            info.MusicProperties.Title = episode.Title;
            info.MusicProperties.Artist = course.Title;
            item.ApplyDisplayProperties(info);
            player.MediaOpened += (s, _) => OnUi(s, () => {
                opened = true;
                var session = player.PlaybackSession;
                if (session.NaturalDuration.TotalSeconds > 0) Duration = session.NaturalDuration.TotalSeconds;
                if (resume > 0 && session.CanSeek) session.Position = TimeSpan.FromSeconds(resume);
                session.PlaybackRate = Rate;
                Changed?.Invoke();
            });
            player.PlaybackSession.PositionChanged += (_, _) => OnUi(player, () => {
                if (!opened || ended || !Playing) return;
                double current = player.PlaybackSession.Position.TotalSeconds;
                if (current <= 0 || resume > 0 && current + 1 < resume) return;
                resume = 0;
                Position = current;
                if (firstSave || sinceSave.Elapsed.TotalSeconds >= 5) Save();
                Changed?.Invoke();
            });
            player.PlaybackSession.PlaybackStateChanged += (_, _) => OnUi(player, () => {
                if (player.PlaybackSession.PlaybackState is MediaPlaybackState.Opening or MediaPlaybackState.Buffering) WatchStall(player);
                else StopWatchingStall();
                if (player.PlaybackSession.PlaybackState == MediaPlaybackState.Paused) Save();
                Changed?.Invoke();
            });
            player.MediaEnded += (s, _) => OnUi(s, End);
            player.MediaFailed += (s, _) => OnUi(s, () => ClassifyFailure(s));
            var commands = player.CommandManager;
            commands.NextBehavior.EnablingRule = MediaCommandEnablingRule.Never;
            commands.PreviousBehavior.EnablingRule = MediaCommandEnablingRule.Never;
            commands.RewindBehavior.EnablingRule = MediaCommandEnablingRule.Always;
            commands.FastForwardBehavior.EnablingRule = MediaCommandEnablingRule.Always;
            commands.RewindReceived += (_, args) => { args.Handled = true; OnUi(player, () => Seek(Position - 15)); };
            commands.FastForwardReceived += (_, args) => { args.Handled = true; OnUi(player, () => Seek(Position + 30)); };
            WatchStall(player);
            player.Source = item;
            player.Play();
            Changed?.Invoke();
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException or System.Net.Http.HttpRequestException or OperationCanceledException)
        { if (media == player && !lifetime.IsCancellationRequested) Fail(); }
    }

    void StopWatchingStall()
    {
        stall?.Cancel();
        stall = null;
    }

    async void WatchStall(MediaPlayer owner)
    {
        if (stall != null || audioUri == null) return;
        using var watch = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        stall = watch;
        var deadline = Task.Delay(TimeSpan.FromSeconds(30), watch.Token);
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(5), watch.Token);
            var removed = await network.AudioRemoved(audioUri, watch.Token);
            if (!removed) await deadline;
            if (!watch.IsCancellationRequested && media == owner) Fail(removed);
        }
        catch (OperationCanceledException) { }
        finally { if (stall == watch) stall = null; }
    }

    async void ClassifyFailure(MediaPlayer owner)
    {
        StopWatchingStall();
        bool removed = audioUri != null && await network.AudioRemoved(audioUri, lifetime);
        if (media == owner && !lifetime.IsCancellationRequested) Fail(removed);
    }

    void Fail(bool removed = false)
    {
        Save();
        Release();
        Error = removed ? "这一集已下架" : "网络异常，请检查网络后重试";
        Changed?.Invoke();
        PlaybackFailed?.Invoke(removed);
    }
    void End()
    {
        if (Episode == null || Course == null || ended) return;
        ended = true;
        Position = Duration;
        store.Save(Course, Episode, 0, Duration, true, firstSave);
        ProgressChanged?.Invoke();
        var next = Course.Episodes.IndexOf(Episode) + 1;
        if (Sleep == -1) SetSleep(0);
        else if (continuous && next > 0 && next < Course.Episodes.Count)
        {
            Start(Course, Course.Episodes[next], true);
            return;
        }
        Release();
        Changed?.Invoke();
    }
    public void Select(Course course, Episode episode, bool playCourse)
    {
        if (Episode?.Id != episode.Id) { Start(course, episode, playCourse); return; }
        continuous = playCourse;
        Toggle();
    }
    public void Toggle()
    {
        if (Episode == null || Course == null) return;
        if (media == null) Start(Course, Episode, continuous);
        else if (Loading && !opened) { Release(); Changed?.Invoke(); }
        else if (Playing || Loading) { media.Pause(); Save(); }
        else { firstSave = true; media.Play(); }
    }
    public void Seek(double target)
    {
        if (!CanSeek || media == null || Duration <= 0) return;
        Position = Math.Clamp(target, 0, Duration);
        resume = 0;
        media.PlaybackSession.Position = TimeSpan.FromSeconds(Position);
        Save();
        Changed?.Invoke();
    }
    public void SetRate(double rate)
    {
        Rate = rate;
        if (opened && media != null) media.PlaybackSession.PlaybackRate = Rate;
        Changed?.Invoke();
    }
    public void SetSleep(int minutes)
    {
        sleepTimer?.Dispose();
        sleepTimer = null;
        Sleep = minutes;
        if (minutes > 0)
        {
            System.Threading.Timer? current = null;
            current = new System.Threading.Timer(_ => ui.InvokeAsync(() => {
                if (sleepTimer != current) return;
                if (!opened && media != null) Release();
                else media?.Pause();
                Save();
                SetSleep(0);
            }), null, TimeSpan.FromMinutes(minutes), Timeout.InfiniteTimeSpan);
            sleepTimer = current;
        }
        Changed?.Invoke();
    }
    public void Mark(Course course, Episode episode, bool completed)
    {
        if (Episode?.Id == episode.Id && completed)
        {
            Release();
            ended = true;
            Position = Duration;
        }
        store.Mark(course, episode, completed);
        ProgressChanged?.Invoke();
        Changed?.Invoke();
    }
    public void Save()
    {
        if (!opened || ended || Episode == null || Course == null || firstSave && (Position <= 0 || resume > 0)) return;
        store.Save(Course, Episode, Position, Duration, Progress.Finished(Position, Duration), firstSave);
        firstSave = false;
        sinceSave.Restart();
        ProgressChanged?.Invoke();
    }
    void Release()
    {
        StopWatchingStall();
        audioUri = null;
        var previous = media;
        media = null;
        opened = false;
        previous?.Dispose();
        source?.Dispose();
        source = null;
    }
    public void Dispose()
    {
        sleepTimer?.Dispose();
        sleepTimer = null;
        Save();
        Release();
    }
}
