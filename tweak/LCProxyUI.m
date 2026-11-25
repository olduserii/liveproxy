#import "LCProxyUI.h"
#import "LCProxyManager.h"
#import "LCWatchdog.h"

static NSString *const kFloatingBtnPosXKey = @"LCProxyFloatingBtnX";
static NSString *const kFloatingBtnPosYKey = @"LCProxyFloatingBtnY";
static NSString *const kFloatingBtnHiddenKey = @"LCProxyFloatingBtnHidden";

#pragma mark - Compact Modal Control Panel (Pure UIKit, iOS 15-26)

@interface LCProxyPanelViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISwitch *proxySwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *serverTitleLabel;
@property (nonatomic, strong) UILabel *serverMetaLabel;
@property (nonatomic, strong) UIButton *fastSelectButton;
@property (nonatomic, strong) UIButton *pasteButton;
@property (nonatomic, strong) UISegmentedControl *tabsControl;

@property (nonatomic, strong) UITableView *serversTable;
@property (nonatomic, strong) UIView *subsContainer;
@property (nonatomic, strong) UITableView *subsTable;
@property (nonatomic, strong) UISwitch *autoUpdateSwitch;
@property (nonatomic, strong) UIView *logsContainer;
@property (nonatomic, strong) UITextView *logsTextView;
@property (nonatomic, strong) UILabel *toastLabel;
@end

@implementation LCProxyPanelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"LCProxy · xray-rust";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Проверить"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(didTapReviveCheck)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(didTapClose)];

    [self buildLayout];
    [self reloadAllViews];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleStateChanged)
                                                 name:LCProxyStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLogsChanged)
                                                 name:LCProxyLogsDidUpdateNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)buildLayout {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // --- Header Status Card ---
    UIView *headerCard = [[UIView alloc] init];
    headerCard.translatesAutoresizingMaskIntoConstraints = NO;
    headerCard.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    headerCard.layer.cornerRadius = 14;
    [self.view addSubview:headerCard];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [headerCard addSubview:self.statusLabel];

    self.proxySwitch = [[UISwitch alloc] init];
    self.proxySwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.proxySwitch addTarget:self action:@selector(didToggleProxySwitch:) forControlEvents:UIControlEventValueChanged];
    [headerCard addSubview:self.proxySwitch];

    self.serverTitleLabel = [[UILabel alloc] init];
    self.serverTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.serverTitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    self.serverTitleLabel.textColor = [UIColor labelColor];
    [headerCard addSubview:self.serverTitleLabel];

    self.serverMetaLabel = [[UILabel alloc] init];
    self.serverMetaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.serverMetaLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.serverMetaLabel.textColor = [UIColor secondaryLabelColor];
    [headerCard addSubview:self.serverMetaLabel];

    // Action row: "Автовыбор быстрого" + "Вставить ключ / JSON"
    UIStackView *actionRow = [[UIStackView alloc] init];
    actionRow.translatesAutoresizingMaskIntoConstraints = NO;
    actionRow.axis = UILayoutConstraintAxisHorizontal;
    actionRow.spacing = 8;
    actionRow.distribution = UIStackViewDistributionFillEqually;
    [headerCard addSubview:actionRow];

    self.fastSelectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.fastSelectButton.backgroundColor = [UIColor systemBlueColor];
    [self.fastSelectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.fastSelectButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.fastSelectButton.layer.cornerRadius = 9;
    [self.fastSelectButton setTitle:@"Автовыбор быстрого" forState:UIControlStateNormal];
    [self.fastSelectButton addTarget:self action:@selector(didTapFastSelect) forControlEvents:UIControlEventTouchUpInside];
    [actionRow addArrangedSubview:self.fastSelectButton];

    self.pasteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.pasteButton.backgroundColor = [UIColor tertiarySystemFillColor];
    [self.pasteButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.pasteButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.pasteButton.layer.cornerRadius = 9;
    [self.pasteButton setTitle:@"Вставить ключ / JSON" forState:UIControlStateNormal];
    [self.pasteButton addTarget:self action:@selector(didTapPasteKeyOrJSON) forControlEvents:UIControlEventTouchUpInside];
    [actionRow addArrangedSubview:self.pasteButton];

    // --- Segmented Tabs ---
    self.tabsControl = [[UISegmentedControl alloc] initWithItems:@[@"Серверы", @"Подписки", @"Логи"]];
    self.tabsControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabsControl.selectedSegmentIndex = 0;
    [self.tabsControl addTarget:self action:@selector(didChangeTab:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabsControl];

    // --- Tab 1: Servers List ---
    self.serversTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.serversTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.serversTable.dataSource = self;
    self.serversTable.delegate = self;
    [self.view addSubview:self.serversTable];

    // --- Tab 2: Subscriptions ---
    self.subsContainer = [[UIView alloc] init];
    self.subsContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.subsContainer.hidden = YES;
    [self.view addSubview:self.subsContainer];

    UIStackView *subToolbar = [[UIStackView alloc] init];
    subToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    subToolbar.axis = UILayoutConstraintAxisHorizontal;
    subToolbar.spacing = 8;
    [self.subsContainer addSubview:subToolbar];

    UIButton *addSubBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addSubBtn.backgroundColor = [UIColor systemBlueColor];
    [addSubBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    addSubBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    addSubBtn.layer.cornerRadius = 8;
    [addSubBtn setTitle:@"  + Добавить URL  " forState:UIControlStateNormal];
    [addSubBtn addTarget:self action:@selector(didTapAddSubscription) forControlEvents:UIControlEventTouchUpInside];
    [subToolbar addArrangedSubview:addSubBtn];

    UIButton *refreshAllBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    refreshAllBtn.backgroundColor = [UIColor tertiarySystemFillColor];
    [refreshAllBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    refreshAllBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    refreshAllBtn.layer.cornerRadius = 8;
    [refreshAllBtn setTitle:@"  Обновить все  " forState:UIControlStateNormal];
    [refreshAllBtn addTarget:self action:@selector(didTapRefreshAllSubs) forControlEvents:UIControlEventTouchUpInside];
    [subToolbar addArrangedSubview:refreshAllBtn];

    UILabel *autoLabel = [[UILabel alloc] init];
    autoLabel.text = @"Авто";
    autoLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    autoLabel.textColor = [UIColor secondaryLabelColor];
    [subToolbar addArrangedSubview:autoLabel];

    self.autoUpdateSwitch = [[UISwitch alloc] init];
    self.autoUpdateSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [self.autoUpdateSwitch addTarget:self action:@selector(didToggleAutoUpdate:) forControlEvents:UIControlEventValueChanged];
    [subToolbar addArrangedSubview:self.autoUpdateSwitch];

    self.subsTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.subsTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.subsTable.dataSource = self;
    self.subsTable.delegate = self;
    [self.subsContainer addSubview:self.subsTable];

    // --- Tab 3: Logs ---
    self.logsContainer = [[UIView alloc] init];
    self.logsContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.logsContainer.hidden = YES;
    [self.view addSubview:self.logsContainer];

    UIStackView *logToolbar = [[UIStackView alloc] init];
    logToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    logToolbar.axis = UILayoutConstraintAxisHorizontal;
    logToolbar.spacing = 8;
    logToolbar.distribution = UIStackViewDistributionFillEqually;
    [self.logsContainer addSubview:logToolbar];

    UIButton *copyLogBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyLogBtn.backgroundColor = [UIColor systemBlueColor];
    [copyLogBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyLogBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    copyLogBtn.layer.cornerRadius = 8;
    [copyLogBtn setTitle:@"Скопировать лог" forState:UIControlStateNormal];
    [copyLogBtn addTarget:self action:@selector(didTapCopyLog) forControlEvents:UIControlEventTouchUpInside];
    [logToolbar addArrangedSubview:copyLogBtn];

    UIButton *clearLogBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearLogBtn.backgroundColor = [UIColor tertiarySystemFillColor];
    [clearLogBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    clearLogBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    clearLogBtn.layer.cornerRadius = 8;
    [clearLogBtn setTitle:@"Очистить" forState:UIControlStateNormal];
    [clearLogBtn addTarget:self action:@selector(didTapClearLog) forControlEvents:UIControlEventTouchUpInside];
    [logToolbar addArrangedSubview:clearLogBtn];

    self.logsTextView = [[UITextView alloc] init];
    self.logsTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logsTextView.editable = NO;
    self.logsTextView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logsTextView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.logsTextView.textColor = [UIColor labelColor];
    self.logsTextView.layer.cornerRadius = 10;
    self.logsTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.logsContainer addSubview:self.logsTextView];

    // Toast feedback banner
    self.toastLabel = [[UILabel alloc] init];
    self.toastLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.toastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    self.toastLabel.textColor = [UIColor whiteColor];
    self.toastLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.layer.cornerRadius = 8;
    self.toastLabel.clipsToBounds = YES;
    self.toastLabel.alpha = 0;
    [self.view addSubview:self.toastLabel];

    [NSLayoutConstraint activateConstraints:@[
        [headerCard.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [headerCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
        [headerCard.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14],

        [self.statusLabel.topAnchor constraintEqualToAnchor:headerCard.topAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:headerCard.leadingAnchor constant:14],

        [self.proxySwitch.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor constant:6],
        [self.proxySwitch.trailingAnchor constraintEqualToAnchor:headerCard.trailingAnchor constant:-14],

        [self.serverTitleLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:4],
        [self.serverTitleLabel.leadingAnchor constraintEqualToAnchor:headerCard.leadingAnchor constant:14],
        [self.serverTitleLabel.trailingAnchor constraintEqualToAnchor:self.proxySwitch.leadingAnchor constant:-10],

        [self.serverMetaLabel.topAnchor constraintEqualToAnchor:self.serverTitleLabel.bottomAnchor constant:3],
        [self.serverMetaLabel.leadingAnchor constraintEqualToAnchor:headerCard.leadingAnchor constant:14],
        [self.serverMetaLabel.trailingAnchor constraintEqualToAnchor:headerCard.trailingAnchor constant:-14],

        [actionRow.topAnchor constraintEqualToAnchor:self.serverMetaLabel.bottomAnchor constant:12],
        [actionRow.leadingAnchor constraintEqualToAnchor:headerCard.leadingAnchor constant:14],
        [actionRow.trailingAnchor constraintEqualToAnchor:headerCard.trailingAnchor constant:-14],
        [actionRow.heightAnchor constraintEqualToConstant:36],
        [actionRow.bottomAnchor constraintEqualToAnchor:headerCard.bottomAnchor constant:-12],

        [self.tabsControl.topAnchor constraintEqualToAnchor:headerCard.bottomAnchor constant:12],
        [self.tabsControl.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
        [self.tabsControl.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14],

        [self.serversTable.topAnchor constraintEqualToAnchor:self.tabsControl.bottomAnchor constant:8],
        [self.serversTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.serversTable.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.serversTable.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.subsContainer.topAnchor constraintEqualToAnchor:self.tabsControl.bottomAnchor constant:10],
        [self.subsContainer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.subsContainer.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.subsContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [subToolbar.topAnchor constraintEqualToAnchor:self.subsContainer.topAnchor],
        [subToolbar.leadingAnchor constraintEqualToAnchor:self.subsContainer.leadingAnchor constant:14],
        [subToolbar.trailingAnchor constraintEqualToAnchor:self.subsContainer.trailingAnchor constant:-14],
        [subToolbar.heightAnchor constraintEqualToConstant:34],

        [self.subsTable.topAnchor constraintEqualToAnchor:subToolbar.bottomAnchor constant:8],
        [self.subsTable.leadingAnchor constraintEqualToAnchor:self.subsContainer.leadingAnchor],
        [self.subsTable.trailingAnchor constraintEqualToAnchor:self.subsContainer.trailingAnchor],
        [self.subsTable.bottomAnchor constraintEqualToAnchor:self.subsContainer.bottomAnchor],

        [self.logsContainer.topAnchor constraintEqualToAnchor:self.tabsControl.bottomAnchor constant:10],
        [self.logsContainer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
        [self.logsContainer.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14],
        [self.logsContainer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],

        [logToolbar.topAnchor constraintEqualToAnchor:self.logsContainer.topAnchor],
        [logToolbar.leadingAnchor constraintEqualToAnchor:self.logsContainer.leadingAnchor],
        [logToolbar.trailingAnchor constraintEqualToAnchor:self.logsContainer.trailingAnchor],
        [logToolbar.heightAnchor constraintEqualToConstant:34],

        [self.logsTextView.topAnchor constraintEqualToAnchor:logToolbar.bottomAnchor constant:8],
        [self.logsTextView.leadingAnchor constraintEqualToAnchor:self.logsContainer.leadingAnchor],
        [self.logsTextView.trailingAnchor constraintEqualToAnchor:self.logsContainer.trailingAnchor],
        [self.logsTextView.bottomAnchor constraintEqualToAnchor:self.logsContainer.bottomAnchor],

        [self.toastLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18],
        [self.toastLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.toastLabel.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-40],
        [self.toastLabel.heightAnchor constraintEqualToConstant:32]
    ]];
}

- (void)showToast:(NSString *)message {
    self.toastLabel.text = [NSString stringWithFormat:@"  %@  ", message];
    [UIView animateWithDuration:0.18 animations:^{ self.toastLabel.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{ self.toastLabel.alpha = 0.0; }];
    });
}

- (void)handleStateChanged {
    [self reloadAllViews];
}

- (void)handleLogsChanged {
    self.logsTextView.text = [[LCProxyManager sharedManager] joinedLogsText];
    if (self.logsTextView.text.length > 0) {
        NSRange end = NSMakeRange(self.logsTextView.text.length - 1, 1);
        [self.logsTextView scrollRangeToVisible:end];
    }
}

- (void)reloadAllViews {
    LCProxyManager *mgr = [LCProxyManager sharedManager];
    self.proxySwitch.on = mgr.proxyEnabled;
    self.autoUpdateSwitch.on = mgr.autoUpdateSubscriptions;

    UIColor *stColor = [UIColor secondaryLabelColor];
    if (mgr.status == LCProxyStatusAlive) stColor = [UIColor systemGreenColor];
    else if (mgr.status == LCProxyStatusWaking) stColor = [UIColor systemOrangeColor];
    else if (mgr.status == LCProxyStatusError) stColor = [UIColor systemRedColor];

    self.statusLabel.textColor = stColor;
    self.statusLabel.text = [NSString stringWithFormat:@"● %@", [mgr statusDisplayText]];

    LCProxyNode *active = mgr.activeNode;
    if (active) {
        self.serverTitleLabel.text = active.name;
        NSInteger ping = mgr.activePingMs;
        NSString *pingStr = ping > 0 ? [NSString stringWithFormat:@"%ld ms", (long)ping] : @"-- ms";
        self.serverMetaLabel.text = [NSString stringWithFormat:@"%@  ·  %@", [active protocolBadgeText], pingStr];
    } else {
        self.serverTitleLabel.text = @"Сервер не выбран";
        self.serverMetaLabel.text = @"Добавьте подписку или вставьте ключ / JSON";
    }

    [self.serversTable reloadData];
    [self.subsTable reloadData];
    [self handleLogsChanged];
}

#pragma mark - Actions

- (void)didTapClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)didTapReviveCheck {
    [[LCWatchdog sharedWatchdog] verifyAndReviveProxyWithReason:@"ManualCheck"];
    [self showToast:@"Запущена проверка Watchdog"];
}

- (void)didToggleProxySwitch:(UISwitch *)sw {
    [[LCProxyManager sharedManager] setProxyEnabled:sw.on completion:^(BOOL ok, NSError *error) {
        if (!ok && error) {
            [self showToast:error.localizedDescription];
        }
        [self reloadAllViews];
    }];
}

- (void)didTapFastSelect {
    self.fastSelectButton.enabled = NO;
    [self.fastSelectButton setTitle:@"Сканирование..." forState:UIControlStateNormal];

    [[LCProxyManager sharedManager] runAutoSelectFastestWithProgress:^(NSString *stageText, LCProxyNode *updatedNode) {
        self.serverMetaLabel.text = stageText;
        if (updatedNode) [self.serversTable reloadData];
    } completion:^(LCProxyNode *bestNode, NSError *error) {
        self.fastSelectButton.enabled = YES;
        [self.fastSelectButton setTitle:@"Автовыбор быстрого" forState:UIControlStateNormal];
        if (bestNode) {
            NSInteger ms = bestNode.realPingMs > 0 ? bestNode.realPingMs : bestNode.tcpPingMs;
            [self showToast:[NSString stringWithFormat:@"Выбран %@ (%ld ms)", bestNode.name, (long)ms]];
        } else if (error) {
            [self showToast:error.localizedDescription];
        }
        [self reloadAllViews];
    }];
}

- (void)didTapPasteKeyOrJSON {
    NSString *clip = [UIPasteboard generalPasteboard].string;
    if (clip.length == 0) {
        [self showToast:@"Буфер обмена пуст"];
        return;
    }
    NSError *err = nil;
    NSArray<LCProxyNode *> *added = [[LCProxyManager sharedManager] importFromClipboardOrText:clip error:&err];
    if (added.count > 0) {
        [self showToast:[NSString stringWithFormat:@"Импортировано узлов: %lu (URI готов)", (unsigned long)added.count]];
        [[LCProxyManager sharedManager] activateNode:added.firstObject completion:nil];
    } else {
        [self showToast:err.localizedDescription ?: @"Неверный формат ключа/JSON"];
    }
}

- (void)didChangeTab:(UISegmentedControl *)seg {
    self.serversTable.hidden = (seg.selectedSegmentIndex != 0);
    self.subsContainer.hidden = (seg.selectedSegmentIndex != 1);
    self.logsContainer.hidden = (seg.selectedSegmentIndex != 2);
}

- (void)didTapAddSubscription {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Новая подписка"
                                                                message:@"Поддерживаются обычные (Base64/URI) и JSON-подписки"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://example.com/sub";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Название (опционально)";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Загрузить" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *url = ac.textFields.firstObject.text;
        NSString *name = ac.textFields.count > 1 ? ac.textFields[1].text : nil;
        [self showToast:@"Загрузка подписки..."];
        [[LCProxyManager sharedManager] addSubscriptionURL:url name:name completion:^(BOOL ok, NSString *msg) {
            [self showToast:msg ?: (ok ? @"Готово" : @"Ошибка")];
            [self reloadAllViews];
        }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)didTapRefreshAllSubs {
    [self showToast:@"Обновление всех подписок..."];
    [[LCProxyManager sharedManager] refreshAllSubscriptionsWithCompletion:^(NSUInteger totalNodes, NSError *error) {
        if (error) [self showToast:error.localizedDescription];
        else [self showToast:[NSString stringWithFormat:@"Обновлено узлов: %lu", (unsigned long)totalNodes]];
        [self reloadAllViews];
    }];
}

- (void)didToggleAutoUpdate:(UISwitch *)sw {
    [LCProxyManager sharedManager].autoUpdateSubscriptions = sw.on;
}

- (void)didTapCopyLog {
    [UIPasteboard generalPasteboard].string = [[LCProxyManager sharedManager] joinedLogsText];
    [self showToast:@"Лог скопирован в буфер"];
}

- (void)didTapClearLog {
    [[LCProxyManager sharedManager] clearLogs];
    [self showToast:@"Логи очищены"];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.serversTable) return [LCProxyManager sharedManager].nodes.count;
    return [LCProxyManager sharedManager].subscriptions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.serversTable) {
        static NSString *cid = @"ServerCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        }
        LCProxyManager *mgr = [LCProxyManager sharedManager];
        NSArray<LCProxyNode *> *nodes = mgr.nodes;
        if (indexPath.row >= (NSInteger)nodes.count) return cell;
        LCProxyNode *node = nodes[indexPath.row];
        BOOL isActive = [mgr.activeNode.nodeID isEqualToString:node.nodeID];

        cell.textLabel.text = [NSString stringWithFormat:@"%@%@", isActive ? @"✓ " : @"", node.name];
        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:isActive ? UIFontWeightBold : UIFontWeightMedium];
        cell.textLabel.textColor = isActive ? [UIColor systemBlueColor] : [UIColor labelColor];

        NSString *pingText = @"--";
        if (node.realPingMs > 0) pingText = [NSString stringWithFormat:@"%ld ms", (long)node.realPingMs];
        else if (node.tcpPingMs > 0) pingText = [NSString stringWithFormat:@"TCP %ld ms", (long)node.tcpPingMs];

        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@:%u · %@",
                                     [node protocolBadgeText], node.host, node.port, pingText];
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        // Copy standard URI button
        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [copyBtn setTitle:@"URI" forState:UIControlStateNormal];
        copyBtn.titleLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
        copyBtn.frame = CGRectMake(0, 0, 44, 28);
        copyBtn.tag = indexPath.row;
        [copyBtn addTarget:self action:@selector(didTapCopyNodeURI:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = copyBtn;
        return cell;
    }

    static NSString *sid = @"SubCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:sid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:sid];
    }
    NSArray<LCSubscriptionItem *> *subs = [LCProxyManager sharedManager].subscriptions;
    if (indexPath.row >= (NSInteger)subs.count) return cell;
    LCSubscriptionItem *sub = subs[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ (%lu)", sub.name, (unsigned long)sub.nodeCount];
    cell.detailTextLabel.text = sub.usageSummary.length > 0 ? sub.usageSummary : sub.url;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)didTapCopyNodeURI:(UIButton *)sender {
    NSArray<LCProxyNode *> *nodes = [LCProxyManager sharedManager].nodes;
    if (sender.tag < 0 || sender.tag >= (NSInteger)nodes.count) return;
    LCProxyNode *node = nodes[sender.tag];
    [UIPasteboard generalPasteboard].string = [node toURIString];
    [self showToast:[NSString stringWithFormat:@"URI скопирован: %@", node.name]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (tableView == self.serversTable) {
        NSArray<LCProxyNode *> *nodes = [LCProxyManager sharedManager].nodes;
        if (indexPath.row >= (NSInteger)nodes.count) return;
        LCProxyNode *node = nodes[indexPath.row];
        [[LCProxyManager sharedManager] activateNode:node completion:^(BOOL ok, NSError *error) {
            if (!ok && error) [self showToast:error.localizedDescription];
            else [self showToast:[NSString stringWithFormat:@"Активирован: %@", node.name]];
            [self reloadAllViews];
        }];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"Удалить"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        if (tableView == self.serversTable) {
            NSArray<LCProxyNode *> *nodes = [LCProxyManager sharedManager].nodes;
            if (indexPath.row < (NSInteger)nodes.count) {
                [[LCProxyManager sharedManager] removeNodeWithID:nodes[indexPath.row].nodeID];
            }
        } else {
            NSArray<LCSubscriptionItem *> *subs = [LCProxyManager sharedManager].subscriptions;
            if (indexPath.row < (NSInteger)subs.count) {
                [[LCProxyManager sharedManager] removeSubscriptionWithID:subs[indexPath.row].subID];
            }
        }
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end

#pragma mark - Floating Draggable Button & 3-Finger Triple-Tap Controller

@interface LCProxyUI ()
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, assign) BOOL gestureAttached;
@end

@implementation LCProxyUI

+ (instancetype)sharedUI {
    static LCProxyUI *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LCProxyUI alloc] init];
    });
    return shared;
}

- (nullable UIWindow *)activeKeyWindow {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.firstObject) return ws.windows.firstObject;
        }
    }
    return nil;
}

- (void)installOverlayIfNeeded {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self activeKeyWindow];
        if (!win) return;

        if (!self.gestureAttached) {
            UITapGestureRecognizer *triple3 = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                      action:@selector(toggleFloatingButtonVisibility)];
            triple3.numberOfTouchesRequired = 3;
            triple3.numberOfTapsRequired = 3;
            triple3.cancelsTouchesInView = NO;
            [win addGestureRecognizer:triple3];
            self.gestureAttached = YES;
        }

        if (!self.floatingButton) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(win.bounds.size.width - 62, win.bounds.size.height * 0.45, 48, 48);
            btn.layer.cornerRadius = 24;
            btn.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.84];
            btn.layer.borderWidth = 1.5;
            btn.layer.borderColor = [UIColor systemBlueColor].CGColor;
            btn.layer.shadowColor = [UIColor blackColor].CGColor;
            btn.layer.shadowOpacity = 0.22;
            btn.layer.shadowOffset = CGSizeMake(0, 3);
            btn.layer.shadowRadius = 6;
            [btn setTitle:@"XR" forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];

            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            if ([ud objectForKey:kFloatingBtnPosXKey] && [ud objectForKey:kFloatingBtnPosYKey]) {
                CGFloat x = [ud doubleForKey:kFloatingBtnPosXKey];
                CGFloat y = [ud doubleForKey:kFloatingBtnPosYKey];
                btn.center = CGPointMake(MIN(MAX(28, x), win.bounds.size.width - 28),
                                         MIN(MAX(64, y), win.bounds.size.height - 64));
            }
            btn.hidden = [ud boolForKey:kFloatingBtnHiddenKey];

            [btn addTarget:self action:@selector(presentControlPanel) forControlEvents:UIControlEventTouchUpInside];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleButtonPan:)];
            [btn addGestureRecognizer:pan];

            self.floatingButton = btn;
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(updateFloatingButtonTint)
                                                         name:LCProxyStateDidChangeNotification
                                                       object:nil];
        }

        if (self.floatingButton.superview != win) {
            [win addSubview:self.floatingButton];
        }
        [win bringSubviewToFront:self.floatingButton];
        [self updateFloatingButtonTint];
    });
}

- (void)updateFloatingButtonTint {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.floatingButton) return;
        LCProxyStatus st = [LCProxyManager sharedManager].status;
        UIColor *border = [UIColor secondaryLabelColor];
        if (st == LCProxyStatusAlive) border = [UIColor systemGreenColor];
        else if (st == LCProxyStatusWaking) border = [UIColor systemOrangeColor];
        else if (st == LCProxyStatusError) border = [UIColor systemRedColor];
        self.floatingButton.layer.borderColor = border.CGColor;
    });
}

- (void)handleButtonPan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.floatingButton.superview;
    if (!superview) return;
    CGPoint trans = [pan translationInView:superview];
    CGPoint center = self.floatingButton.center;
    center.x = MIN(MAX(28, center.x + trans.x), superview.bounds.size.width - 28);
    center.y = MIN(MAX(64, center.y + trans.y), superview.bounds.size.height - 64);
    self.floatingButton.center = center;
    [pan setTranslation:CGPointZero inView:superview];

    if (pan.state == UIGestureRecognizerStateEnded) {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setDouble:center.x forKey:kFloatingBtnPosXKey];
        [ud setDouble:center.y forKey:kFloatingBtnPosYKey];
    }
}

- (void)toggleFloatingButtonVisibility {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installOverlayIfNeeded];
        self.floatingButton.hidden = !self.floatingButton.hidden;
        [[NSUserDefaults standardUserDefaults] setBool:self.floatingButton.hidden forKey:kFloatingBtnHiddenKey];
    });
}

- (void)presentControlPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self activeKeyWindow];
        UIViewController *topVC = win.rootViewController;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
        if (!topVC || [topVC isKindOfClass:[UINavigationController class]] &&
            [((UINavigationController *)topVC).topViewController isKindOfClass:[LCProxyPanelViewController class]]) {
            return;
        }

        LCProxyPanelViewController *panel = [[LCProxyPanelViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = nav.sheetPresentationController;
            if (sheet) {
                sheet.detents = @[
                    [UISheetPresentationControllerDetent mediumDetent],
                    [UISheetPresentationControllerDetent largeDetent]
                ];
                sheet.prefersGrabberVisible = YES;
            }
        }
        [topVC presentViewController:nav animated:YES completion:nil];
    });
}

@end
