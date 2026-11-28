using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Windows.UI.ViewManagement;
using WpfButton = System.Windows.Controls.Button;

namespace Zhibei.Desktop;

public partial class MainWindow : Window
{
    readonly Store store;
    readonly ListBoxItem courseHeader;
    readonly DispatcherTimer searchDelay = new() { Interval = TimeSpan.FromMilliseconds(300) };
    Window? aboutWindow;
    readonly HttpClient http = new(new HttpClientHandler { UseCookies = false });
    readonly ContentService network;
    readonly WindowsUpdateChecker updates;
    static readonly string Version = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0];
    readonly Covers covers;
    readonly Player player;
    readonly PlaybackSpectrum spectrum;
    readonly UISettings uiSettings = new();
    readonly CancellationTokenSource lifetime = new();
    readonly Stack<Location> history = new();
    readonly HashSet<CourseArtwork> waitingArtwork = [];
    bool checkingArtwork;
    internal event Action? RetryArtwork;
    readonly int[] minutes = [-1, 60, 45, 30, 15, 10, 5, 0];
    readonly double[] rates;
    Catalog catalog = new();
    Location location = new("主页");
    List<TrackRow> rows = [];
    TrackRow? activeRow;
    string tag = "";
    bool catalogRefreshFailed;
    WindowsUpgrade? outdatedUpgrade;
    bool outdatedDismissed, updateDialogOpen, backgroundUpdateInProgress;
    DateTimeOffset lastUpdateCheck;
    AppNotice? appNotice;
    Task? appNoticeRequest;
    readonly HashSet<string> dismissedAppNotices = new(StringComparer.Ordinal);
    readonly SemaphoreSlim refreshGate = new(1);
    bool ready, settingNav, settingPlayer, seeking, closed;
    DateTime lastSync;
    int renderNumber;
    record Location(string Page, string Key = "", bool Reverse = false, string Parent = "", string Query = "");
    Course? FindCourse(string id) => catalog.Courses.Find(c => c.Id == id);

    internal MainWindow(string directory)
    {
        InitializeComponent();
        BrowseArea.Children.Remove(Hero);
        courseHeader = new ListBoxItem { Content = Hero, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        searchDelay.Tick += (_, _) => { searchDelay.Stop(); if (location.Page == "搜索") Render(); };
        SourceInitialized += (_, _) => {
            var source = (HwndSource)PresentationSource.FromVisual(this);
            source.AddHook((nint hwnd, int message, nint wParam, nint lParam, ref bool handled) =>
                CourseShelf.HandleWindowMessage(this, message, wParam, lParam, ref handled));
        };
        store = new Store(Path.Combine(directory, "zhibeifw.db"), out var cached);
        network = new(store, http);
        updates = new(store, network, Version);
        covers = new(network, Path.Combine(directory, "covers"), lifetime.Token);
        player = new(store, network, Dispatcher, lifetime.Token);
        player.PlaybackFailed += ShowPlaybackFailure;
        spectrum = new(bands => activeRow?.SetLevels(bands));
        rates = (double[])FindResource("Rates");
        SizeChanged += (_, _) => {
            ResizeSidebar();
            // Scale the home shelves together, up to the Mac desktop card sizes.
            double large = (double)FindResource("LargeCardWidth");
            double scale = ActualWidth >= 820 ? 1 : Math.Clamp((ActualWidth - SideColumn.Width.Value) / 870, .65, 1);
            Resources["HomeLargeWidth"] = Math.Round(large * scale);
            Resources["HomeSmallWidth"] = Math.Round(220 * scale);
        };
        PlayerInfo.SizeChanged += (_, e) => {
            var minimum = PlayerCover.Width + PlayerCover.Margin.Right + (double)FindResource("Player.artworkMinTextWidth");
            PlayerCover.Visibility = e.NewSize.Width >= minimum ? Visibility.Visible : Visibility.Collapsed;
        };
        PlayerBar.SizeChanged += PlayerBarSizeChanged;
        BrowseBackdrop.SizeChanged += (_, _) => UpdatePlayerGlass();
        uiSettings.AdvancedEffectsEnabledChanged += TransparencyChanged;
        SystemParameters.StaticPropertyChanged += GlassSystemParametersChanged;
        Nav.PreviewMouseLeftButtonDown += (_, e) => {
            if (ItemsControl.ContainerFromElement(Nav, e.OriginalSource as DependencyObject) is ListBoxItem { IsSelected: true, Content: string section }
                && location.Page != section) { history.Clear(); Navigate(new(section), false); e.Handled = true; }
        };
        BrowseArea.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((_, _) => ScheduleArtwork()));
        BrowseArea.SizeChanged += (_, _) => ScheduleArtwork();
        Nav.SelectedIndex = 0;
        player.Changed += UpdatePlayer;
        player.ProgressChanged += UpdateProgress;
        ContentRendered += async (_, _) => {
            if (ready || closed) return;
            if (cached.Raw.Length > 0)
            {
                try { catalog = Catalog.Parse(cached.Raw); tag = cached.Tag; }
                catch (Exception e) when (e is InvalidDataException or JsonException or InvalidOperationException) { }
            }
            ready = true;
            LaunchScreen.Visibility = Visibility.Collapsed;
            Render();
            await Task.WhenAll(Refresh(), CheckForUpdatesInBackground());
        };
        Activated += async (_, _) => {
            if (!ready || closed) return;
            await Task.WhenAll(DateTime.UtcNow - lastSync >= TimeSpan.FromMinutes(1) ? Refresh() : Task.CompletedTask,
                CheckForUpdatesInBackground());
        };
        Deactivated += (_, _) => { if (ready) player.Save(); };
        PreviewKeyDown += (_, e) => {
            if (e.Key == Key.Left && Keyboard.Modifiers == ModifierKeys.Alt && history.Count > 0)
            { GoBack(this, new()); e.Handled = true; }
            else if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control)
            { Sidebar.Visibility = Visibility.Visible; ResizeSidebar(); SidebarSearch.Focus(); SidebarSearch.SelectAll(); e.Handled = true; }
            else if (player.Course is {} course && Keyboard.FocusedElement is not TextBox)
            {
                if (Keyboard.Modifiers == (ModifierKeys.Control | ModifierKeys.Shift) && e.Key == Key.P) CoursePage(course.Id);
                else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Left) player.Seek(player.Position - 15);
                else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Right) player.Seek(player.Position + 30);
                else if (Keyboard.Modifiers == ModifierKeys.None && e.Key == Key.Space &&
                    Keyboard.FocusedElement is not ButtonBase && Keyboard.FocusedElement is not Slider) player.Toggle();
                else return;
                e.Handled = true;
            }
        };
        Closed += (_, _) => {
            closed = true;
            uiSettings.AdvancedEffectsEnabledChanged -= TransparencyChanged;
            SystemParameters.StaticPropertyChanged -= GlassSystemParametersChanged;
            searchDelay.Stop();
            lifetime.Cancel();
            spectrum.SetActive(false);
            player.Dispose();
            http.Dispose();
            store.Dispose();
        };
    }

    void ResizeSidebar() => SideColumn.Width = new GridLength(Sidebar.Visibility == Visibility.Visible ? Math.Clamp(ActualWidth * .19, 138, 210) : 0);
    void ToggleSidebar(object sender, RoutedEventArgs e)
    {
        Sidebar.Visibility = Sidebar.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        ResizeSidebar();
    }
    async void StartRefreshRoute(object sender, RoutedEventArgs e)
    {
        StartActions.IsEnabled = false;
        StartRouteLabel.Text = "正在检测…";
        try { StartRouteLabel.Text = await RefreshRoutes(); }
        finally { StartActions.IsEnabled = true; }
    }

    async Task<string> RefreshRoutes()
    {
        await refreshGate.WaitAsync();
        try
        {
            if (closed) return "暂时无法连接";
            var route = await network.RefreshRoutes(lifetime.Token);
            if (route == RouteStatus.Unavailable) return "暂时无法连接";
            await RefreshCatalog(fromRouteCheck: true);
            return route == RouteStatus.Unchanged ? "线路正常" : "已切换到备用线路，连接正常";
        }
        catch (OperationCanceledException) when (closed) { return "暂时无法连接"; }
        finally { refreshGate.Release(); }
    }

    async Task Refresh(bool userInitiated = false)
    {
        if (!refreshGate.Wait(0)) return;
        try { if (!closed) await RefreshCatalog(userInitiated: userInitiated); }
        finally { refreshGate.Release(); }
    }

    async Task RefreshCatalog(bool fromRouteCheck = false, bool userInitiated = false)
    {
        bool initial = catalog.Categories.Count == 0;

        try
        {
            Catalog? result;
            for (int attempt = 1; ; attempt++)
            {
                if (initial && !fromRouteCheck)
                {
                    StartRouteLabel.Text = "刷新网络线路";
                    StartScreen.Visibility = StartProgress.Visibility = Visibility.Visible;
                    StartTitle.Text = "正在准备内容…";
                    StartMessage.Text = "第一次使用需要联网，请稍候";
                    StartAttempt.Text = $"正在重新连接（第 {attempt} 次）";
                    StartAttempt.Visibility = attempt > 1 ? Visibility.Visible : Visibility.Collapsed;
                    StartActions.Visibility = Visibility.Collapsed;
                }
                try { result = await network.RefreshCatalog(tag, lifetime.Token, RefreshAppNotice); break; }
                catch (Exception ex) when (initial && attempt < 3 && !lifetime.IsCancellationRequested &&
                    ex is HttpRequestException or IOException or OperationCanceledException or JsonException)
                { await Task.Delay(TimeSpan.FromSeconds(2 * attempt), lifetime.Token); }
            }
            if (closed) return;
            if (result != null)
            {
                catalog = result;
                tag = store.ReadCatalog().Tag;
            }
            catalogRefreshFailed = false;
            UpdateCatalogFailure();
            if (result != null) Render();
            if (fromRouteCheck) RetryArtwork?.Invoke();
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or IOException or
            InvalidDataException or JsonException or ArgumentException or InvalidOperationException)
        {
            if (closed || fromRouteCheck) return;
            if (initial)
            {
                StartTitle.Text = "暂时无法连接"; StartMessage.Text = "";
                StartAttempt.Visibility = Visibility.Collapsed;
                StartProgress.Visibility = Visibility.Collapsed; StartActions.Visibility = Visibility.Visible;

            }
            else
            {
                catalogRefreshFailed = ex is not (JsonException or InvalidDataException) &&
                    (userInitiated || System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable());
                UpdateCatalogFailure();
            }
        }
        finally { lastSync = DateTime.UtcNow; }
    }

    void NavChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || settingNav || Nav.SelectedItem is not ListBoxItem item) return;
        history.Clear();
        SetSearch("");
        Navigate(new((string)item.Content), false);
    }
    void Navigate(Location target, bool push = true)
    {
        if (push && target != location) history.Push(location);
        location = target;
        searchDelay.Stop();
        settingNav = true;
        SidebarSearch.Text = target.Page == "搜索" ? target.Key : target.Query;
        Nav.SelectedItem = Nav.Items.Cast<ListBoxItem>().FirstOrDefault(i => i.Content as string ==
            (target.Parent.Length == 0 ? target.Page : target.Parent));
        settingNav = false;
        Render();
        PageScroll.ScrollToTop();
        if (Tracks.Items.Count > 0) Tracks.ScrollIntoView(Tracks.Items[0]);
    }
    void GoBack(object sender, RoutedEventArgs e)
    {
        if (history.TryPop(out var previous)) Navigate(previous, false);
    }
    string ParentPage => location.Parent.Length > 0 ? location.Parent : location.Page;
    void CoursePage(string id, bool fromCard = false)
    {
        if (location.Page != "课程" || location.Key != id) Navigate(new("课程", id, Parent: ParentPage, Query: fromCard ? SidebarSearch.Text : ""));
    }
    void CategoryPage(string id)
    {
        history.Clear();
        history.Push(new("分类"));
        Navigate(new("分类课程", id, Parent: "分类"), false);
    }
    static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };
    static WpfButton Button(string label, Action click)
    {
        var b = new WpfButton { Content = label };
        b.Click += (_, _) => click();
        return b;
    }
    void UpdateCatalogFailure() =>
        CatalogFailure.Visibility = catalogRefreshFailed && location.Page == "主页" ? Visibility.Visible : Visibility.Collapsed;

    async Task CheckForUpdatesInBackground()
    {
        if (backgroundUpdateInProgress || DateTimeOffset.UtcNow - lastUpdateCheck < TimeSpan.FromHours(24)) return;
        backgroundUpdateInProgress = true;
        try { await CheckForUpdates(false); }
        finally { backgroundUpdateInProgress = false; }
    }

    async Task<string> CheckForUpdates(bool manual)
    {
        WindowsUpdateResult result;
        try { result = await updates.Check(manual, DateTimeOffset.UtcNow, lifetime.Token); }
        catch (OperationCanceledException) when (closed) { return "检查失败"; }
        if (closed || result.Status == WindowsUpdateStatus.Failed) return "检查失败";

        lastUpdateCheck = DateTimeOffset.UtcNow;
        outdatedUpgrade = result.Status == WindowsUpdateStatus.Outdated ? result.Release : null;
        UpdateOutdatedBanner();
        if (result.ShowDialog && result.Release is {} release)
            _ = Dispatcher.BeginInvoke(() => ShowUpdateDialog(release, result.Status == WindowsUpdateStatus.Outdated));

        return result.Status switch {
            WindowsUpdateStatus.Available => $"有新版本 {result.Release!.LatestVersion}",
            WindowsUpdateStatus.Outdated => "版本过旧，请更新",
            _ => "已是最新版本"
        };
    }

    void UpdateOutdatedBanner() => OutdatedBanner.Visibility =
        location.Page == "主页" && outdatedUpgrade != null && !outdatedDismissed ? Visibility.Visible : Visibility.Collapsed;

    void DismissOutdated(object sender, RoutedEventArgs e)
    {
        outdatedDismissed = true;
        UpdateOutdatedBanner();
    }

    void OpenOutdatedDownload(object sender, RoutedEventArgs e)
    {
        if (outdatedUpgrade is {} release) OpenUpdateDownload(release);
    }

    void OpenUpdateDownload(WindowsUpgrade release)
    {
        var url = network.UriFor(release.ExePath);
        new UpdateDownloadWindow(aboutWindow ?? this, network, url, lifetime.Token).ShowDialog();
    }

    void ShowUpdateDialog(WindowsUpgrade release, bool outdated)
    {
        if (closed || updateDialogOpen) return;
        updateDialogOpen = true;
        try
        {
            var dialog = new Window {
                Owner = aboutWindow ?? this, Title = $"发现新版本 {release.LatestVersion}",
                WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
                SizeToContent = SizeToContent.WidthAndHeight, ShowInTaskbar = false
            };
            var content = new StackPanel { Margin = new Thickness(20) };
            if (outdated) content.Children.Add(Label("此版本过旧，已无法获得最新的内容更新。"));
            content.Children.Add(Label("下载完成后，可以打开安装包更新。"));
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 16, 0, 0) };
            var later = Button(outdated ? "关闭" : "稍后提醒", () => dialog.DialogResult = false);
            later.IsCancel = true;
            buttons.Children.Add(later);
            var download = Button("立刻更新", () => dialog.DialogResult = true);
            download.Margin = new Thickness(8, 0, 0, 0);
            download.IsDefault = true;
            buttons.Children.Add(download);
            content.Children.Add(buttons);
            dialog.Content = content;
            if (dialog.ShowDialog() == true) OpenUpdateDownload(release);
            else if (!closed && !outdated)
            {
                try { updates.RemindLater(release.LatestVersion, DateTimeOffset.UtcNow); }
                catch (IOException error) { Trace.TraceWarning(error.Message); }
            }
        }
        finally { updateDialogOpen = false; }
    }

    void RefreshAppNotice(string origin)
    {
        if (appNoticeRequest is { IsCompleted: false }) return;
        appNoticeRequest = LoadAppNotice(origin);
    }

    async Task LoadAppNotice(string origin)
    {
        var value = await network.ReadAppNotice(origin, lifetime.Token);
        if (closed) return;
        try
        {
            if (value != null && (dismissedAppNotices.Contains(value.DismissalKey) ||
                store.Setting("appNotice.dismissed." + value.DismissalKey) == "1"))
                value = null;
        }
        catch (IOException error) { Trace.TraceWarning(error.Message); }
        appNotice = value;
        UpdateHomeNotice();
    }

    void UpdateHomeNotice()
    {
        HomeNotice.Visibility = location.Page == "主页" && appNotice != null ? Visibility.Visible : Visibility.Collapsed;
        HomeNoticeMessage.Text = appNotice?.Message;
        HomeNoticeLink.Content = appNotice?.Link?.Label;
        HomeNoticeLink.Visibility = appNotice?.Link == null ? Visibility.Collapsed : Visibility.Visible;
    }

    void OpenHomeNotice(object sender, RoutedEventArgs e)
    {
        if (appNotice?.Link is not { } link) return;
        try { Process.Start(new ProcessStartInfo(link.Url.AbsoluteUri) { UseShellExecute = true }); }
        catch (Win32Exception) { }
    }

    void DismissHomeNotice(object sender, RoutedEventArgs e)
    {
        if (appNotice is not { } notice) return;
        dismissedAppNotices.Add(notice.DismissalKey);
        try { store.Set("appNotice.dismissed." + notice.DismissalKey, "1"); }
        catch (IOException error) { Trace.TraceWarning(error.Message); }
        appNotice = null;
        UpdateHomeNotice();
    }

    void Render()
    {
        renderNumber++;
        StartScreen.Visibility = catalog.Categories.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Heading.Text = location.Page;
        Back.Visibility = history.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateCatalogFailure();
        UpdateOutdatedBanner();
        UpdateHomeNotice();
        EmptyState.Visibility = Visibility.Collapsed;
        ClearRecentButton.Visibility = location.Page == "最近播放" ? Visibility.Visible : Visibility.Collapsed;
        Hero.Visibility = Visibility.Collapsed;
        HeroCover.Content = null;
        CourseActions.Children.Clear();
        Actions.Children.Clear();
        Page.Children.Clear();
        Tracks.ItemsSource = null;
        Tracks.Visibility = Visibility.Collapsed;
        PageScroll.Visibility = Visibility.Visible;
        rows = [];
        activeRow = null;
        spectrum.SetActive(false);
        switch (location.Page)
        {
            case "主页":
                Cards("新课程", catalog.Courses.Where(c => c.Status == "ongoing").OrderByDescending(c => c.Updated)
                    .Take(10).Select(c => (c, c.Episodes.LastOrDefault()?.Title ?? "")));
                Cards("编辑精选", catalog.Featured.Select(f => (FindCourse(f.CourseId)!, f.Title)));
                foreach (var cat in catalog.Categories)
                    Cards(cat.Name, catalog.Courses.Where(c => c.Category == cat.Id).Take(10).Select(c => (c, "")), () => CategoryPage(cat.Id));
                break;
            case "分类":
                var categoryTiles = CardGrid(180, 280, 12);
                Page.Children.Add(categoryTiles);
                foreach (var cat in catalog.Categories.OrderBy(c => catalog.CategoryOrder.IndexOf(c.Id) is var i && i >= 0 ? i : int.MaxValue))
                    categoryTiles.Children.Add(CategoryTile(cat));
                break;
            case "分类课程":
                Heading.Text = catalog.Categories.Find(c => c.Id == location.Key)?.Name ?? "分类";
                CourseList(catalog.Courses.Where(c => c.Category == location.Key));
                break;
            case "课程":
                ShowCourse();
                break;
            case "搜索":
                ShowSearch();
                break;
            case "收藏":
                ShowFavorites();
                break;
            case "最近播放":
                ShowRecent();
                break;
        }
        if (location.Page != "搜索" && Page.Children.Count == 0 && rows.Count == 0 && catalog.Categories.Count > 0 && EmptyState.Visibility != Visibility.Visible) Empty("暂无内容");
    }

    WpfButton CategoryTile(Category category)
    {
        string[] names = ["orange", "blue", "purple", "pink", "teal", "olive", "green", "brown",
            "red", "amber", "magenta", "indigo", "slate", "forest", "cocoa", "cyan", "wine", "charcoal"];
        var colors = (string[])FindResource("CategoryColors");
        int index = Array.IndexOf(names, category.Color);
        var tile = Button(category.Name, () => CategoryPage(category.Id));
        tile.Height = 96;
        tile.Margin = new(0, 0, 12, 12); tile.Padding = new(14);
        tile.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        if (!SystemParameters.HighContrast)
        {
            tile.Style = (Style)FindResource("CategoryTileButton");
            tile.Background = (Brush)new BrushConverter().ConvertFromString(colors[index < 0 ? (int)(CatalogIcon.Hash(category.Id) % 8) : index])!;
            tile.Foreground = Brushes.White;
        }
        var label = new Grid();
        label.Children.Add(new CatalogIcon(CatalogIcon.CategoryName(category), 26) {
            Opacity = .6, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top });
        label.Children.Add(new TextBlock { Text = category.Name, FontWeight = FontWeights.SemiBold, FontSize = 17, VerticalAlignment = VerticalAlignment.Bottom });
        tile.Content = label;
        AutomationProperties.SetName(tile, category.Name);
        tile.VerticalContentAlignment = VerticalAlignment.Stretch;
        return tile;
    }

    static CourseArtwork Artwork(Course course, double width) => new() {
        CoverPath = course.Cover, CourseId = course.Id, Width = width, Height = width * 9 / 16, CornerRadius = new(8)
    };
    internal void QueueArtwork(CourseArtwork art)
    {
        waitingArtwork.Add(art);
        ScheduleArtwork();
    }
    internal void ForgetArtwork(CourseArtwork art) => waitingArtwork.Remove(art);

    void ScheduleArtwork()
    {
        if (closed || checkingArtwork || waitingArtwork.Count == 0) return;
        checkingArtwork = true;
        Dispatcher.InvokeAsync(() => {
            checkingArtwork = false;
            var viewport = new Rect(BrowseArea.RenderSize);
            viewport.Inflate(96, 96);
            foreach (var image in waitingArtwork.ToArray())
            {
                if (!image.IsVisible) continue;
                if (BrowseArea.IsAncestorOf(image) &&
                    !viewport.IntersectsWith(image.TransformToAncestor(BrowseArea).TransformBounds(new Rect(image.RenderSize)))) continue;
                waitingArtwork.Remove(image);
                _ = image.Load(covers);
            }
        }, DispatcherPriority.Loaded);
    }

    static WrapPanel CardGrid(double minimum, double maximum, double gap)
    {
        var grid = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Stretch };
        grid.SizeChanged += (_, e) => {
            double width = e.NewSize.Width;
            int count = Math.Max(1, (int)((width + gap) / (minimum + gap)));
            grid.ItemWidth = Math.Min(maximum + gap, Math.Floor(width / count));
        };
        return grid;
    }

    void Cards(string title, IEnumerable<(Course Course, string Subtitle)> items, Action? browse = null)
    {
        var list = items.Where(item => item.Course != null).DistinctBy(item => item.Course.Id).ToList();
        if (list.Count == 0) return;
        bool shelf = title.Length > 0;
        Panel panel = shelf ? new StackPanel { Orientation = Orientation.Horizontal } : CardGrid(220, 308, 20);
        if (shelf)
        {
            var group = new StackPanel { Margin = new(0, 0, 0, 32) };
            var viewport = new CourseShelf { Content = panel, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, PanningMode = PanningMode.HorizontalOnly, Focusable = false };
            var header = new DockPanel { Margin = new(0, 0, 0, 12) };
            var arrows = new StackPanel { Orientation = Orientation.Horizontal };
            DockPanel.SetDock(arrows, Dock.Right);
            header.Children.Add(arrows);
            WpfButton Arrow(string glyph, string label, int direction)
            {
                var arrow = Button(glyph, () => viewport.ScrollToHorizontalOffset(viewport.HorizontalOffset + direction * viewport.ViewportWidth));
                arrow.Style = (Style)FindResource("GlyphButton");
                arrow.MinWidth = 28; arrow.MinHeight = 24; arrow.FontSize = 12;
                arrow.ToolTip = label;
                AutomationProperties.SetName(arrow, title + "，" + label);
                arrows.Children.Add(arrow);
                return arrow;
            }
            var previous = Arrow("chevron-back", "向左浏览", -1);
            var next = Arrow("chevron-forward", "向右浏览", 1);
            void UpdateArrows()
            {
                previous.IsEnabled = viewport.HorizontalOffset > .5;
                next.IsEnabled = viewport.HorizontalOffset < viewport.ScrollableWidth - .5;
                arrows.Visibility = viewport.ScrollableWidth > .5 ? Visibility.Visible : Visibility.Hidden;
                arrows.Opacity = group.IsMouseOver || group.IsKeyboardFocusWithin ? 1 : 0;
            }
            viewport.ScrollChanged += (_, _) => UpdateArrows();
            group.MouseEnter += (_, _) => UpdateArrows();
            group.MouseLeave += (_, _) => UpdateArrows();
            group.IsKeyboardFocusWithinChanged += (_, _) => UpdateArrows();
            var heading = new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 18, VerticalAlignment = VerticalAlignment.Center };
            if (browse != null)
            {
                var headingLink = new StackPanel { Orientation = Orientation.Horizontal };
                headingLink.Children.Add(heading);
                headingLink.Children.Add(new CatalogIcon("chevron-forward", 14) { Margin = new(6, 0, 0, 0) });
                var link = Button(title, browse);
                link.Style = (Style)FindResource("Plain");
                link.HorizontalAlignment = HorizontalAlignment.Left;
                link.Padding = new(0); link.Content = headingLink;
                AutomationProperties.SetName(link, title);
                header.Children.Add(link);
            }
            else header.Children.Add(heading);
            group.Children.Add(header);
            group.Children.Add(viewport);
            Page.Children.Add(group);
        }
        else Page.Children.Add(panel);
        foreach (var (course, subtitle) in list)
        {
            var b = Button(course.Title, () => CoursePage(course.Id, true));
            b.Style = (Style)FindResource("Plain");
            b.Padding = new(0); b.Margin = new(0, 0, 20, shelf ? 0 : 28); b.VerticalAlignment = VerticalAlignment.Top;
            b.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            var content = new StackPanel();
            if (shelf) content.SetResourceReference(WidthProperty, title == "新课程" ? "HomeLargeWidth" : "HomeSmallWidth");
            content.Children.Add(new Viewbox { Stretch = Stretch.Uniform, Child = Artwork(course, 320) });
            string name = title == "编辑精选" && subtitle != "" ? subtitle : course.Title;
            content.Children.Add(new TextBlock { Text = name, FontWeight = FontWeights.Normal, Margin = new(0, 8, 0, 0), TextWrapping = TextWrapping.Wrap });
            if ((!shelf || title == "新课程") && subtitle != "")
            {
                var detail = Label(shelf ? "更新至 " + subtitle : subtitle);
                detail.FontSize = 12; detail.Margin = new(0, 2, 0, 0);
                detail.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
                content.Children.Add(detail);
            }
            b.Content = content;
            if (location.Page == "收藏")
            {
                var remove = new MenuItem { Header = "取消收藏", Icon = new CatalogIcon("bookmark-remove", 16) };
                remove.Click += (_, _) => { store.RemoveFavorite(course.Id); Render(); };
                b.ContextMenu = new ContextMenu();
                b.ContextMenu.Items.Add(remove);
            }
            AutomationProperties.SetName(b, title == "新课程" && subtitle.Length > 0 ? $"{name}，更新至 {subtitle}" :
                !shelf && subtitle.Length > 0 ? $"{name}，{subtitle}" : name);
            panel.Children.Add(b);
        }
    }
    void Empty(string message)
    {
        PageScroll.Visibility = Visibility.Collapsed;
        EmptyState.Text = message;
        EmptyState.Visibility = Visibility.Visible;
    }
    static string CourseStatus(Course course) => course.Status == "completed" ? "已完结" : "更新中";

    void CourseList(IEnumerable<Course> courses)
    {
        var list = courses.ToList();
        Cards("", list.Select(c => (c, CourseStatus(c))));
        if (list.Count == 0) Empty("暂无课程");
    }
    void SetSearch(string text)
    {
        settingNav = true;
        SidebarSearch.Text = text;
        settingNav = false;
    }
    Location searchReturn = new("主页");
    void ClearSearch(object sender, RoutedEventArgs e)
    {
        SidebarSearch.Clear();
        SidebarSearch.Focus();
    }
    void SearchChanged(object sender, TextChangedEventArgs e)
    {
        if (!ready || settingNav) return;
        searchDelay.Stop();
        var term = SidebarSearch.Text.Trim();
        if (term.Length == 0)
        {
            if (location.Page == "搜索") Navigate(searchReturn, false);
            else if (location.Query.Length > 0)
            {
                location = location with { Query = "" };
                if (history.TryPeek(out var last) && last.Page == "搜索") { history.Pop(); history.Push(searchReturn); }
            }
            return;
        }
        if (location.Page != "搜索") searchReturn = new(ParentPage == "搜索" ? "主页" : ParentPage);
        history.Clear();
        location = new("搜索", term, Parent: searchReturn.Page);
        searchDelay.Start();
    }
    async void ShowSearch()
    {
        int render = renderNumber;
        var current = catalog;
        string query = location.Key;
        var (matches, prefix) = await Task.Run(() => {
            var found = current.Search(query, out var fallback);
            return (found, fallback);
        });
        if (closed || render != renderNumber || location.Key != query) return;
        if (matches.Count == 0) { Page.Children.Add(Label("未找到相关内容")); return; }
        if (prefix.Length > 0) Page.Children.Add(Label($"已显示“{prefix}”的结果"));
        CourseList(matches);
    }
    async void RefreshClick(object sender, RoutedEventArgs e) => await Refresh(userInitiated: true);

    void HeroCategory(object sender, RoutedEventArgs e)
    {
        if (FindCourse(location.Key) is {} c) CategoryPage(c.Category);
    }
    void ShowCourse()
    {
        if (FindCourse(location.Key) is not {} c)
        {
            var id = location.Key;
            var title = store.SavedCourseTitle(id);
            var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            panel.Children.Add(new CatalogIcon("book-outline", 32) { HorizontalAlignment = HorizontalAlignment.Center });
            var name = Label(title ?? "这门课已下架");
            name.FontWeight = FontWeights.SemiBold;
            name.TextAlignment = TextAlignment.Center;
            panel.Children.Add(name);
            if (title != null)
            {
                var status = Label("已下架");
                status.TextAlignment = TextAlignment.Center;
                status.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
                panel.Children.Add(status);
            }
            if (store.IsFavorite(id))
            {
                var remove = Button("取消收藏", () => { store.RemoveFavorite(id); Render(); });
                remove.HorizontalAlignment = HorizontalAlignment.Center;
                panel.Children.Add(remove);
            }
            Page.Children.Add(panel);
            return;
        }
        CourseTitle.Text = Heading.Text = c.Title;
        Hero.Visibility = Visibility.Visible;
        HeroCover.Content = new Viewbox { Stretch = Stretch.Uniform, Child = Artwork(c, 300) };
        string categoryName = catalog.Categories.Find(cat => cat.Id == c.Category)?.Name ?? "分类";
        var categoryLink = new StackPanel { Orientation = Orientation.Horizontal };
        categoryLink.Children.Add(Label(categoryName));
        categoryLink.Children.Add(new CatalogIcon("chevron-forward", 12) { Margin = new(4, 0, 0, 0) });
        CourseCategory.Content = categoryLink;
        AutomationProperties.SetName(CourseCategory, categoryName);
        CourseSummary.Text = (c.Episodes.Count > 0 ? $" · 共 {c.Episodes.Count} 节课" : "") + (c.Status == "completed" ? " · 已完结" : " · 更新中");
        if (Synopsis.Tag as string != c.Id) SynopsisPanel.IsExpanded = false;
        Synopsis.Tag = c.Id;
        Synopsis.Text = c.Description;
        void AddAction(string text, string glyph, Action click)
        {
            var b = Button(text, click);
            b.Margin = (Thickness)FindResource("ControlGap");
            b.Style = (Style)FindResource("PillAction");
            var label = new StackPanel { Orientation = Orientation.Horizontal };
            label.Children.Add(new CatalogIcon(glyph, 16) { Margin = new(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
            label.Children.Add(new TextBlock { Text = text });
            AutomationProperties.SetName(b, text);
            b.Content = label;
            CourseActions.Children.Add(b);
        }
        AddAction(store.IsFavorite(c.Id) ? "已收藏" : "收藏", store.IsFavorite(c.Id) ? "bookmark" : "bookmark-outline", () => Favorite(c));
        AddAction(location.Reverse ? "从新到旧" : "从旧到新", "swap-vertical", () => { location = location with { Reverse = !location.Reverse }; Render(); });
        SynopsisPanel.Visibility = c.Description.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        var progress = store.CourseProgress(c.Id);
        foreach (var ep in location.Reverse ? c.Episodes.AsEnumerable().Reverse() : c.Episodes)
            rows.Add(new(c.Id, ep.Id, ep.Title, progress.GetValueOrDefault(ep.Id) ?? new(0, ep.Duration, false), false, ep.Duration));
        ShowRows("暂无单集");
    }
    void Favorite(Course c) { store.Favorite(c, !store.IsFavorite(c.Id)); Render(); }
    void ShowFavorites()
    {
        var saved = store.Favorites();
        if (saved.Count == 0) { Empty("暂无收藏"); return; }
        Actions.Children.Add(Label($"{saved.Count} 门课"));
        Cards("", saved.Select(f => FindCourse(f.Id) is { } course
            ? (course, CourseStatus(course))
            : (new Course(f.Id, f.Title, "", f.Cover, "", "", 0, []), "已下架")));
    }
    void ShowRecent()
    {
        foreach (var item in store.Recent())
        {
            var course = FindCourse(item.CourseId);
            var episode = course?.Episodes.Find(ep => ep.Id == item.Id);
            var row = new TrackRow(item.CourseId, item.Id, item.Title, item.Progress, true, episode?.Duration ?? 0) {
                SeriesTitle = course?.Title ?? item.CourseTitle, Gone = episode == null, CoverPath = course?.Cover ?? item.Cover
            };
            rows.Add(row);
        }
        ClearRecentButton.IsEnabled = rows.Count > 0;
        if (rows.Count > 0) Actions.Children.Add(Label($"{rows.Count} 条记录"));
        ShowRows("暂无收听记录");
    }
    void ShowPlaybackFailure(bool removed)
    {
        if (closed) return;
        var episode = player.Episode;
        var dialog = new Window {
            Owner = this, Title = "播放提示", WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize, SizeToContent = SizeToContent.WidthAndHeight,
            ShowInTaskbar = false
        };
        var content = new StackPanel { Margin = new Thickness(20) };
        content.Children.Add(Label(player.Error));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0) };
        if (!removed) buttons.Children.Add(Button("重试", () => dialog.DialogResult = true));
        var dismiss = Button(removed ? "好" : "关闭", () => dialog.DialogResult = false);
        dismiss.IsCancel = true;
        buttons.Children.Add(dismiss);
        content.Children.Add(buttons);
        dialog.Content = content;
        if (dialog.ShowDialog() == true && player.Episode == episode && player.Error.Length > 0) player.Toggle();
    }

    void ClearRecentClick(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "列表中的记录会被移除。各课程的收听进度、已听完标记不受影响。", "清空最近列表？",
            MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        store.ClearRecent();
        Render();
    }
    void RecentMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (sender is not WpfButton { DataContext: TrackRow row, ContextMenu: {} menu }) return;
        menu.Items.Clear();
        var course = FindCourse(row.CourseId);
        var episode = course?.Episodes.Find(x => x.Id == row.Id);
        if (course != null && episode != null)
        {
            var mark = new MenuItem { Header = row.ActionForMark, Icon = new CatalogIcon(row.MarkIcon, 16) };
            mark.Click += (_, _) => { player.Mark(course, episode, !row.Progress.Completed); row.Update(store.ReadProgress(row.Id)!); };
            menu.Items.Add(mark);
        }
        var go = new MenuItem { Header = "前往课程", Icon = new CatalogIcon("arrow-forward-circle-outline", 16) };
        go.Click += (_, _) => CoursePage(row.CourseId);
        menu.Items.Add(go);
    }
    void ShowRows(string empty)
    {
        bool course = location.Page == "课程";
        if (!course && rows.Count == 0) { Empty(empty); return; }
        Tracks.ItemTemplate = (DataTemplate)FindResource(course ? "EpisodeTemplate" : "RecentTemplate");
        Tracks.ItemsSource = course ? new object[] { courseHeader }.Concat(rows) : rows;
        PageScroll.Visibility = Visibility.Collapsed;
        Tracks.Visibility = Visibility.Visible;
        UpdateTrack();
    }
    void EpisodePlay(object sender, RoutedEventArgs e)
    {
        if (((WpfButton)sender).DataContext is not TrackRow r) return;
        var c = FindCourse(r.CourseId);
        if (c == null || c.Episodes.Find(item => item.Id == r.Id) is not {} ep)
        {
            MessageBox.Show(this, c == null ? "这门课已下架" : "这一集已下架", "播放提示", MessageBoxButton.OK);
            return;
        }
        player.Select(c, ep, !r.Recent);
    }
    void EpisodeAction(object sender, RoutedEventArgs e)
    {
        if (((WpfButton)sender).DataContext is not TrackRow r) return;
        if (r.Recent) { CoursePage(r.CourseId); return; }
        if (FindCourse(r.CourseId) is {} c && c.Episodes.Find(ep => ep.Id == r.Id) is {} ep)
        { player.Mark(c, ep, !r.Progress.Completed); r.Update(store.ReadProgress(ep.Id)!); }
    }
    void AboutClick(object sender, RoutedEventArgs e)
    {
        if (aboutWindow != null) { aboutWindow.Activate(); return; }
        var dialog = new Window { Title = "关于智悲佛网", Owner = this, Width = 468, Height = 560,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false };
        var body = new DockPanel { Margin = new(24) };
        var form = new StackPanel { Margin = new(14, 0, 14, 0) };
        StackPanel Group(string title)
        {
            form.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Margin = new(0, 8, 0, 6) });
            var group = new StackPanel();
            var box = new Border { CornerRadius = new(8), Padding = new(12, 4, 12, 4), Child = group, BorderThickness = new(1) };
            box.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
            box.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
            form.Children.Add(box);
            return group;
        }
        void Row(Panel group, string name, string action, string glyph, Func<Task<string>> perform, string? busyText = null)
        {
            var row = new DockPanel { Margin = new(0, 5, 0, 5) };
            var label = new TextBlock { Text = action, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetLiveSetting(label, System.Windows.Automation.AutomationLiveSetting.Polite);
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(new CatalogIcon(glyph, 16) { Margin = new(0, 0, 5, 0) });
            content.Children.Add(label);
            var button = new WpfButton { Content = content, MinWidth = 64, Padding = new(8, 2, 8, 2) };
            AutomationProperties.SetName(button, name);
            button.Click += async (_, _) => {
                button.IsEnabled = false;
                if (busyText != null) label.Text = busyText;
                try { label.Text = await perform(); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception) { label.Text = "操作失败"; }
                finally { button.IsEnabled = true; }
            };
            DockPanel.SetDock(button, Dock.Right);
            row.Children.Add(button);
            row.Children.Add(new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center });
            group.Children.Add(row);
        }
        var settings = Group("设置");
        Row(settings, "清除缓存", "清除", "drive", () => { covers.Clear(); return Task.FromResult("已清除"); });
        Row(settings, "刷新网络线路", "刷新", "refresh", RefreshRoutes, "正在检测…");
        Row(settings, "检查更新", "检查", "refresh", () => CheckForUpdates(true), "正在检查…");
        var links = Group("关于");
        foreach (var (name, caption, glyph, url) in new[] { ("联系", "hello@zhibeifw.com", "email", "mailto:hello@zhibeifw.com"),
            ("隐私政策", "打开", "privacy", "https://zhibeifw.com/privacy"), ("源代码", "打开", "code", "https://github.com/zhibeifw/zhibeifw-app") })
            Row(links, name, caption, glyph, () => { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); return Task.FromResult(caption); });
        var footer = new TextBlock { Text = $"智悲佛网\n版本 {Version}", FontSize = 12, TextAlignment = TextAlignment.Center, Margin = new(0, 16, 0, 0) };
        footer.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        DockPanel.SetDock(footer, Dock.Bottom);
        body.Children.Add(footer);
        body.Children.Add(new ScrollViewer { Content = form, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        dialog.Content = body;
        aboutWindow = dialog;
        dialog.Closed += (_, _) => aboutWindow = null;
        dialog.Show();
    }
    void UpdateProgress()
    {
        if (closed || player.Episode == null) return;
        var row = rows.Find(r => r.Id == player.Episode.Id);
        if (row != null && store.ReadProgress(row.Id) is {} p) row.Update(p);
        if (location.Page == "最近播放" && row == null && store.Recent().Any(r => r.Id == player.Episode.Id)) Render();
    }
    void UpdateTrack()
    {
        if (player.Episode == null || rows.Count == 0) return;
        if (activeRow?.Id != player.Episode.Id)
        {
            activeRow?.SetState("");
            activeRow = rows.Find(r => r.Id == player.Episode.Id);
        }
        spectrum.SetActive(player.Playing && activeRow != null);
        activeRow?.SetState(player.Loading ? "缓冲中" : player.Playing ? "播放中" : "");
        if (player.Playing && player.Duration > 0)
            activeRow?.Update(new(Math.Floor(player.Position), player.Duration, false));
    }
    bool compactPlayer;
    void PlayerBarSizeChanged(object sender, SizeChangedEventArgs e)
    {
        bool compact = e.NewSize.Width < (double)FindResource("Player.compactWidth");
        if (compact != compactPlayer)
        {
            compactPlayer = compact;
            var resources = PlayerBar.Resources;
            if (compact)
            {
                resources["Player.controlSize"] = FindResource("Player.compactControlSize");
                resources["Player.rateWidth"] = FindResource("Player.compactRateWidth");
                resources["PlayerPadding"] = FindResource("PlayerCompactPadding");
                resources["PlayerInfoMargin"] = FindResource("PlayerCompactInfoMargin");
                resources["PlayerControlMargin"] = new Thickness(0);
            }
            else
            {
                resources.Remove("Player.controlSize");
                resources.Remove("Player.rateWidth");
                resources.Remove("PlayerPadding");
                resources.Remove("PlayerInfoMargin");
                resources.Remove("PlayerControlMargin");
            }
        }
        if (e.HeightChanged) UpdatePlayerInset();
        UpdatePlayerGlass();
    }
    void PlayerInsetChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        UpdatePlayerInset();
        UpdatePlayerGlass();
    }
    void TransparencyChanged(UISettings sender, object args) => Dispatcher.BeginInvoke(UpdatePlayerGlass);
    void GlassSystemParametersChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SystemParameters.HighContrast))
            Dispatcher.BeginInvoke(UpdatePlayerGlass);
    }
    void UpdatePlayerGlass()
    {
        if (closed) return;
        bool enabled = PlayerBar.IsVisible && PlayerBar.ActualWidth > 0 && PlayerBar.ActualHeight > 0 &&
            uiSettings.AdvancedEffectsEnabled && !SystemParameters.HighContrast;
        PlayerGlassLayer.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        if (!enabled) return;

        // Sample only the page beneath the capsule. The extra area keeps the blur soft at its clipped edges.
        var size = PlayerBar.RenderSize;
        var bounds = new Rect(size);
        var radius = (double)FindResource("Player.glassRadius");
        PlayerGlassLayer.Clip = new RectangleGeometry(bounds, radius, radius);
        var sample = new Rect(PlayerBar.TranslatePoint(new Point(), BrowseBackdrop), size);
        var bleed = -PlayerGlassSample.Margin.Left;
        sample.Inflate(bleed, bleed);
        ((VisualBrush)PlayerGlassSample.Fill).Viewbox = sample;
    }
    void UpdatePlayerInset()
    {
        // Leave the last item reachable underneath the floating controls.
        var inset = new Thickness(0, 0, 0, PlayerBar.IsVisible ? PlayerBar.ActualHeight + PlayerBar.Margin.Bottom + 12 : 16);
        Page.Margin = inset;
        Tracks.Margin = inset;
        EmptyState.Margin = inset;
    }
    string? scrubEpisode;
    void PlayerHover(object sender, MouseEventArgs e) => ShowSeekTimes();
    void PlayerFocusChanged(object sender, DependencyPropertyChangedEventArgs e) => ShowSeekTimes();
    bool? seekExpanded;
    bool hoveringSeek;
    void AnimatePlayerValue(FrameworkElement target, DependencyProperty property, double value, bool animate)
    {
        double start = (double)target.GetValue(property);
        target.BeginAnimation(property, null);
        target.SetValue(property, value);
        if (!animate || !double.IsFinite(start)) return;
        var transition = new DoubleAnimation(start, value, (Duration)FindResource("FadeDuration")) {
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }, FillBehavior = FillBehavior.Stop
        };
        target.BeginAnimation(property, transition);
    }

    void ShowSeekTimes()
    {
        if (Timeline == null || BackButton == null || ForwardButton == null || PlayerText == null) return;
        bool keyboardFocus = Timeline.IsKeyboardFocusWithin || BackButton.IsKeyboardFocusWithin || ForwardButton.IsKeyboardFocusWithin;
        if (Timeline.IsMouseOver) hoveringSeek = true;
        else if (!PlayerInfo.IsMouseOver) hoveringSeek = false;
        bool expanded = seeking || hoveringSeek || BackButton.IsMouseOver || ForwardButton.IsMouseOver ||
            keyboardFocus && InputManager.Current.MostRecentInputDevice is KeyboardDevice;
        if (expanded != seekExpanded)
        {
            bool animate = seekExpanded.HasValue && PlayerBar.IsVisible && SystemParameters.ClientAreaAnimation;
            seekExpanded = expanded;
            AnimatePlayerValue(PlayerText, OpacityProperty, expanded ? 0 : 1, animate);
            AnimatePlayerValue(SeekTimes, OpacityProperty, expanded ? 1 : 0, animate);
            AnimatePlayerValue(SeekRail, HeightProperty, (double)FindResource(expanded ? "Player.activeTrackHeight" : "Player.idleTrackHeight"), animate);
        }
        ElapsedTime.Text = Progress.Clock(Timeline.Value);
        RemainingTime.Text = "−" + Progress.Clock(Math.Max(0, player.Duration - Timeline.Value));
    }
    void UpdatePlayer()
    {
        if (closed || player.Course == null || player.Episode == null) return;
        UpdateTrack();
        settingPlayer = true;
        PlayerBar.Visibility = Visibility.Visible;
        PlayerTitle.Text = player.Error != "" ? player.Error : player.Episode.Title;
        PlayerSeries.Text = player.Course.Title;
        AutomationProperties.SetName(PlayerMetadata, $"前往课程，{player.Course.Title}");
        PlayerCover.CourseId = player.Course.Id;
        PlayerCover.CoverPath = player.Course.Cover;
        string verb = player.Error != "" ? "重试" : player.Playing || player.Loading ? "暂停" : "播放";
        AutomationProperties.SetName(PlayButton, verb);
        PlayButton.ToolTip = verb;
        PlayIcon.Visibility = verb == "播放" ? Visibility.Visible : Visibility.Collapsed;
        PauseIcon.Visibility = player.Playing ? Visibility.Visible : Visibility.Collapsed;
        RetryIcon.Visibility = verb == "重试" ? Visibility.Visible : Visibility.Collapsed;
        Buffering.Visibility = player.Loading ? Visibility.Visible : Visibility.Collapsed;
        Timeline.IsEnabled = player.CanSeek;
        if (!seeking)
        {
            Timeline.Maximum = Math.Max(1, player.Duration);
            Timeline.Value = player.Position;
        }
        ShowSeekTimes();
        Speed.Content = $"{player.Rate:0.##}×";
        SleepChoice.ToolTip = SleepLabel(player.Sleep);
        SleepChoice.Tag = player.Sleep != 0;
        settingPlayer = false;
    }
    void Toggle(object sender, RoutedEventArgs e) => player.Toggle();
    void Back15(object sender, RoutedEventArgs e) => player.Seek(player.Position - 15);
    void Forward30(object sender, RoutedEventArgs e) => player.Seek(player.Position + 30);
    void PlayerCourse(object sender, RoutedEventArgs e)
    {
        if (player.Course is {} course) CoursePage(course.Id);
    }
    static string SleepLabel(int m) => m switch { -1 => "单集结束时", 0 => "睡眠定时：关闭", _ => $"{m} 分钟后暂停" };
    ContextMenu PlayerMenu(WpfButton button) => new()
    {
        PlacementTarget = button, Placement = PlacementMode.Top, FontFamily = FontFamily, Language = Language
    };
    void ChoiceMenu<T>(WpfButton button, IEnumerable<T> choices, T current, Func<T, string> label, Action<T> apply)
    {
        var menu = PlayerMenu(button);
        foreach (var value in choices)
        {
            var item = new MenuItem { Header = label(value), IsCheckable = true, IsChecked = EqualityComparer<T>.Default.Equals(current, value) };
            item.Click += (_, _) => apply(value);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }
    void SpeedMenu(object sender, RoutedEventArgs e) => ChoiceMenu(Speed, rates, player.Rate, r => r == 1 ? "1×（正常）" : $"{r:0.##}×", player.SetRate);
    void SleepMenu(object sender, RoutedEventArgs e) => ChoiceMenu(SleepChoice, minutes, player.Sleep, m => m switch { 0 => "关闭", -1 => "单集结束时", 60 => "1 小时", _ => $"{m} 分钟" }, player.SetSleep);
    void SeekStart(object sender, MouseButtonEventArgs e)
    {
        if (!player.CanSeek || !Timeline.CaptureMouse()) return;
        seeking = true;
        scrubEpisode = player.Episode?.Id;
        Timeline.Focus();
        PreviewPosition(e);
        e.Handled = true;
    }
    void PreviewPosition(MouseEventArgs e)
    {
        if (Timeline.Template.FindName("PART_Track", Timeline) is Track track)
            Timeline.Value = Math.Clamp(track.ValueFromPoint(e.GetPosition(track)), Timeline.Minimum, Timeline.Maximum);
    }
    void SeekMove(object sender, MouseEventArgs e)
    {
        if (seeking) PreviewPosition(e);
    }
    void SeekEnd(object sender, MouseButtonEventArgs e)
    {
        if (!seeking) return;
        PreviewPosition(e);
        var position = Timeline.Value;
        bool sameEpisode = scrubEpisode == player.Episode?.Id;
        Timeline.ReleaseMouseCapture();
        if (sameEpisode) player.Seek(position);
        e.Handled = true;
    }
    void SeekReleased(object sender, MouseEventArgs e)
    {
        seeking = false;
        scrubEpisode = null;
        UpdatePlayer();
    }
    void TimelineChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (seeking) ShowSeekTimes();
        if (ready && !settingPlayer && !seeking) player.Seek(e.NewValue);
    }
    void OpenPlayerMenu(object sender, RoutedEventArgs e)
    {
        if (player.Course is not {} c || player.Episode is not {} ep) return;
        var menu = PlayerMenu((WpfButton)sender);
        void Add(string label, string icon, Action a) { var item = new MenuItem { Header = label, Icon = new CatalogIcon(icon, 16) }; item.Click += (_, _) => a(); menu.Items.Add(item); }
        var done = store.ReadProgress(ep.Id)?.Completed == true;
        Add(done ? "标记为未听完" : "标记为已听完", done ? "lesson-unmark" : "lesson-mark", () => player.Mark(c, ep, !done));
        bool favorite = store.IsFavorite(c.Id);
        Add(favorite ? "取消收藏课程" : "收藏课程", favorite ? "bookmark" : "bookmark-outline", () => Favorite(c));
        Add("前往课程", "arrow-forward-circle-outline", () => CoursePage(c.Id));
        menu.IsOpen = true;
    }
}

sealed class TrackRow(string courseId, string id, string title, Progress progress, bool recent, double knownDuration = 0) : INotifyPropertyChanged
{
    public string CourseId => courseId;
    public string Id => id;
    public string Title => title;
    public bool Recent => recent;
    public Progress Progress { get; private set; } = progress;
    public string MarkIcon => Progress.Completed ? "lesson-unmark" : "lesson-mark";
    public string ActionLabel => Recent ? "前往课程" : ActionForMark;
    public string ActionForMark => Progress.Completed ? "标记为未听完" : "标记为已听完";
    public string SeriesTitle { get; init; } = "";
    public bool Gone { get; init; }
    public string CoverPath { get; init; } = "";
    public string PlaybackGlyph => Progress.Completed ? "refresh" : "play";
    string state = "";
    public bool Playing => state == "播放中";
    public double[]? Levels { get; private set; }
    public void SetLevels(double[] levels) { Levels = levels; PropertyChanged?.Invoke(this, new(nameof(Levels))); }
    public bool Buffering => state == "缓冲中";
    public bool PartiallyPlayed => !Progress.Completed && Progress.Position > 0 && Progress.Duration > 0;
    public double Fraction => Progress.Duration > 0 ? Math.Clamp(Progress.Position / Progress.Duration, 0, 1) : 0;
    public string Detail => Gone ? "已下架" : Progress.PillLabel(knownDuration);
    public string AccessibleTitle => (state.Length > 0 ? "暂停 " : Progress.Completed ? "重新播放 " : "播放 ") +
        (Recent ? SeriesTitle + " " : "") + Title + "，" + Detail;
    public event PropertyChangedEventHandler? PropertyChanged;
    public void SetState(string value)
    {
        if (state == value) return;
        state = value;
        Levels = null;
        PropertyChanged?.Invoke(this, new(null));
    }
    public void Update(Progress value)
    {
        if (Progress == value) return;
        Progress = value;
        PropertyChanged?.Invoke(this, new(null));
    }
}
