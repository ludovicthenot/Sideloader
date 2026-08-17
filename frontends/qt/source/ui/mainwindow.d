module ui.mainwindow;

import core.stdc.config : cpp_long;
import core.stdcpp.new_: cpp_new;
import core.thread;

import std.algorithm;
import std.conv;
import file = std.file;
import std.format;
import std.process;

import slf4d;

import plist;

import provision;

import server.developersession;

import qt.config;
import qt.core.bytearray;
import qt.core.coreapplication;
import qt.core.point;
import qt.core.coreevent;
import qt.core.namespace;
import qt.core.object;
import qt.core.objectdefs;
import qt.core.size;
import qt.core.string;
import qt.core.thread;
import qt.core.timer;
import qt.core.translator;
import qt.core.variant;
import qt.gui.cursor;
import qt.gui.event;
import qt.gui.icon;
import qt.gui.pixmap;
import qt.helpers;
import qt.widgets.action;
import qt.widgets.combobox;
import qt.widgets.filedialog;
import qt.widgets.label;
import qt.widgets.lineedit;
import qt.widgets.mainwindow;
import qt.widgets.menu;
import qt.widgets.messagebox;
import qt.widgets.progressbar;
import qt.widgets.pushbutton;
import qt.widgets.stackedwidget;
import qt.widgets.tabbar;
import qt.widgets.toolbutton;
import qt.widgets.ui;
import qt.widgets.widget;

import imobiledevice;

import constants;
import sideload;
import tools;
import utils;

import ui.chrome;
import ui.loginwindow;
import ui.sessionstore;
import ui.utils;

alias MainWindowUI = UIStruct!"mainwindow.ui";

class MainWindow: QMainWindow {
    mixin(Q_OBJECT_D);

    MainWindowUI* ui;

    iDevice selectedDevice;
    LockdowndClient lockdowndClient;

    Application selectedApplication;

    /// Kept for the install: sideloadFull needs all three, and the developer
    /// session is reused across installs so the user signs in once.
    private string configurationPath;
    private Device provisioningDevice;
    private ADI adi;
    private DeveloperSession developerSession;

    /// Install log, newest first, with the grey level each line is currently
    /// rendered at while it fades.
    private struct LogLine {
        QLabel label;
        int brightness;
    }

    private enum maxLogLines = 5;

    private LogLine[] logLines;
    private string lastLoggedStage;
    private QTimer logFadeTimer;


    this(string configurationPath, Device device, ADI adi) {
        ui = cpp_new!MainWindowUI();
        ui.setupUi(this);

        this.configurationPath = configurationPath;
        this.provisioningDevice = device;
        this.adi = adi;

        // A stored token is not checked here: it is only exercised on the
        // first request, so an expired one surfaces as a failed install and
        // the user can sign out to clear it.
        this.developerSession = recallSession(device, adi);

        auto log = getLogger();

        setUpWindowChrome();
        setUpIcons();

        logFadeTimer = cpp_new!QTimer(this);
        QObject.connect(logFadeTimer.signal!"timeout", this.slot!"stepLogFade");
        QObject.connect(this.signal!"deviceAdded", this.slot!"addDevice");
        QObject.connect(this.signal!"deviceRemoved", this.slot!"removeDevice");
        QObject.connect(ui.deviceComboBox.signal!"currentIndexChanged", this.slot!"refreshView");
        QObject.connect(ui.actionRefresh_device_list.signal!"triggered", this.slot!"refreshDevices");
        QObject.connect(ui.actionDonate.signal!"triggered", delegate() => browse("https://github.com/sponsors/Dadoum"));
        QObject.connect(ui.ipaLine.signal!"editingFinished", this.slot!"checkApplication");
        QObject.connect(
            ui.actionAbout.signal!"triggered",
            delegate() =>
                QMessageBox.about(
                    this,
                    *cpp_new!QString("About Sideloader"),
                    *cpp_new!QString(format!rawAboutText(versionStr, "Qt"))
                )
        );
        QObject.connect(this.signal!"sideloadProcedureTriggered", this.slot!"setSideloadTabEnabled");
        QObject.connect(
            ui.selectIpaButton.signal!"clicked",
            delegate() {
                QString filename = QFileDialog.getOpenFileName(
                    this,
                    *cpp_new!QString("Open application"),
                    globalInitVar!QString,
                    *cpp_new!QString("iOS application bundle (*.ipa)")
                );

                if (!filename.isNull() && !filename.isEmpty()) {
                    ui.ipaLine.setText(filename);
                    checkApplication();
                }
            }
        );
        QObject.connect(ui.installButton.signal!"clicked", this.slot!"startInstall");
        QObject.connect(ui.actionSign_out.signal!"triggered", this.slot!"signOut");

        // Queued: the progress callback fires on the worker thread, and
        // widgets may only be touched from the UI thread.
        QObject.connect(
            this.signal!"installProgressed",
            this.slot!"onInstallProgressed",
            ConnectionType.QueuedConnection);
        QObject.connect(
            this.signal!"installFinished",
            this.slot!"onInstallFinished",
            ConnectionType.QueuedConnection);

        ui.bundleInfos.hide();
        iDevice.subscribeEvent((ref const(iDeviceEvent) event) {
            with (iDeviceEventType) switch (event.event) {
                case add:
                    deviceAdded(*cpp_new!QString(event.udid));
                    log.infoF!"Device with UDID %s has been added."(event.udid);
                    break;
                case remove:
                    deviceRemoved(*cpp_new!QString(event.udid));
                    log.infoF!"Device with UDID %s has been removed."(event.udid);
                    break;
                case paired:
                    log.infoF!"Device with UDID %s has been paired."(event.udid);
                    break;
                default:
                    log.infoF!"Device with UDID %s has been ???? (%s)."(event.udid, event.event);
                    break;
            }
        });
        // auto stackedWidget = new QStackedWidget();
        // ui.tabWidget.sizePolicy().setRetainSizeWhenHidden(true);
        // ui.tabWidget.setVisible(false);
    }

    /++
        Window chrome.

        The window keeps its native frame on purpose. Going frameless meant
        reimplementing dragging, resizing and the resize cursors by hand, and
        losing snapping and edge handling with them. The system already does
        all of that; only the title bar colour needs asking for.
    +/
    private void setUpWindowChrome() {
        applyDarkTitleBar(cast(size_t) this.winId());

        // Set here, not in the .ui: dqt's uic does not apply geometry or
        // minimumSize to the root widget, so the window opened far below
        // what the sideload tab needs and the rows overlapped.
        setMinimumSize(780, 745);
        resize(980, 790);

        // The menu bar still owns the QActions, but the hamburger button
        // republishes the same menus in a popup, which suits the layout.
        ui.menubar.hide();

        auto popupMenu = cpp_new!QMenu(this);
        popupMenu.addMenu(ui.menuFile);
        popupMenu.addMenu(ui.menuDevices);
        popupMenu.addMenu(ui.menuHelp);
        ui.menuButton.setMenu(popupMenu);

        // Member slots, not lambdas capturing `this`: dqt keeps the delegate
        // on the C++ side where the D GC cannot see its context, and the
        // closure gets collected out from under the signal.
        QObject.connect(ui.refreshButton.signal!"clicked", this.slot!"refreshDevices");
        QObject.connect(ui.minimizeButton.signal!"clicked", this.slot!"minimizeWindow");
        QObject.connect(ui.maximizeButton.signal!"clicked", this.slot!"toggleMaximized");
        QObject.connect(ui.closeButton.signal!"clicked", this.slot!"closeWindow");
    }

    /// Drops the session in memory and in the store, so the next install
    /// asks to sign in again. The way out of an expired or wrong token.
    @QSlot
    final void signOut() {
        developerSession = null;
        forgetSession();
        getLogger().info("Signed out; the saved session has been removed.");
    }

    @QSlot
    final void minimizeWindow() {
        showMinimized();
    }

    @QSlot
    final void toggleMaximized() {
        if (isMaximized())
            showNormal();
        else
            showMaximized();
    }

    @QSlot
    final void closeWindow() {
        close();
    }

    /++
        Whether a widget in the header row may act as a drag handle.

        Listing the controls that must stay clickable is shorter, and more
        robust, than listing every container that should drag.
    +/
    private bool isDragArea(QWidget child) {
        if (child is null)
            return true;

        return cast(QToolButton) child is null
            && cast(QPushButton) child is null
            && cast(QComboBox) child is null
            && cast(QLineEdit) child is null
            && cast(QTabBar) child is null
            && cast(QProgressBar) child is null;
    }

    /++
        Hands frame handling back to Windows.

        WM_NCCALCSIZE removes the system caption, so the app icon and title
        disappear and our header row takes their place. WM_NCHITTEST then
        reports the edges and the caption, which is what keeps native
        resizing, snapping and double-click-to-maximise working.
    +/
    override extern(C++) bool nativeEvent(ref const(QByteArray) eventType, void* message, cpp_long* result) {
        version (Windows) {
            if (handleFrameRemoval(message, result))
                return true;

            // The header row is the drag handle, minus its buttons. Decided
            // on the widget hierarchy rather than on coordinates: comparing
            // against titleBar's geometry meant guessing where it sits in the
            // window, and got it wrong.
            bool captionHit;
            int screenX, screenY;
            if (hitTestPoint(message, screenX, screenY)) {
                auto local = mapFromGlobal(*cpp_new!QPoint(screenX, screenY));
                auto child = childAt(local.x(), local.y());

                captionHit = child is ui.titleBar
                    || (child !is null && ui.titleBar.isAncestorOf(child) && isDragArea(child));
            }

            if (handleHitTest(message, result, captionHit))
                return true;
        }

        return super.nativeEvent(eventType, message, result);
    }

    /// Loads a Lucide icon deployed next to the executable.
    private QIcon loadIcon(string name) {
        string path = QCoreApplication.applicationDirPath().toConstWString().to!string()
            ~ "/icons/" ~ name ~ ".svg";
        return QIcon(*cpp_new!QString(path));
    }

    private void setUpIcons() {
        auto iconSize = cpp_new!QSize(17, 17);

        void setButtonIcon(T)(T button, string name, int size = 17) {
            auto icon = loadIcon(name);
            button.setIcon(icon);
            button.setIconSize(*cpp_new!QSize(size, size));
        }

        setButtonIcon(ui.refreshButton, "refresh-cw-dim", 21);
        setButtonIcon(ui.menuButton, "menu-dim", 21);
        setButtonIcon(ui.minimizeButton, "minus-dim", 19);
        setButtonIcon(ui.maximizeButton, "square-dim", 16);
        setButtonIcon(ui.closeButton, "x-dim", 19);
        setButtonIcon(ui.selectIpaButton, "folder-open-dim", 16);
        setButtonIcon(ui.installButton, "download-on", 17);

        ui.tabWidget.setIconSize(*iconSize);
        ui.tabWidget.setTabIcon(0, loadIcon("smartphone-dim"));
        ui.tabWidget.setTabIcon(1, loadIcon("package-dim"));
        ui.tabWidget.setTabIcon(2, loadIcon("wrench-dim"));

        // Illustrative icons for the empty states: a QPixmap rendered from
        // the SVG rather than a QIcon, since there are no states to handle.
        void setLabelIcon(QLabel label, string name, int size) {
            auto icon = loadIcon(name);
            auto pixmap = icon.pixmap(*cpp_new!QSize(size, size));
            label.setPixmap(pixmap);
        }

        setLabelIcon(ui.deviceCardIcon, "smartphone-dim", 22);
        setLabelIcon(ui.emptyStateIcon, "usb-off", 44);
        setLabelIcon(ui.errorStateIcon, "lock-off", 44);
    }

    @QSignal final void sideloadProcedureTriggered(bool isSideloadTabEnabled) { mixin(Q_SIGNAL_IMPL_D); }
    @QSignal final void installProgressed(double progress, ref const(QString) stage) { mixin(Q_SIGNAL_IMPL_D); }
    @QSignal final void installFinished(bool succeeded, ref const(QString) message) { mixin(Q_SIGNAL_IMPL_D); }
    @QSignal final void deviceAdded(ref const(QString) udid) { mixin(Q_SIGNAL_IMPL_D); }
    @QSignal final void deviceRemoved(ref const(QString) udid) { mixin(Q_SIGNAL_IMPL_D); }

    // @QSignal final bool showDialog(ref const(QMessageBox) udid) { mixin(Q_SIGNAL_IMPL_D); }

    @QSlot
    final void addDevice(ref const(QString) udid) {
        assert(QThread.currentThread() == this.thread());

        QComboBox deviceComboBox = ui.deviceComboBox;
        if (deviceComboBox.findData(QVariant(udid)) != -1) {
            return;
        }

        string udidStr = udid.toConstWString().to!string();
        scope device = new iDevice(udidStr);

        string deviceName = "???";
        try {
            scope lockdown = new LockdowndClient(device, "sideloader.name-fetcher");
            deviceName = lockdown.deviceName();
        } catch (iMobileDeviceException!lockdownd_error_t) { }

        // Name only: the UDID goes on the card's second line, in
        // refreshView. The item data still carries it for findData().
        deviceComboBox.addItem(*cpp_new!QString(deviceName), QVariant(udid));
    }

    @QSlot
    final void removeDevice(ref const(QString) udid) {
        assert(QThread.currentThread() == this.thread());
        if (iDevice.deviceList().canFind!(elem => elem.udid == udid.toConstWString().to!string())) {
            return;
        }

        QComboBox deviceComboBox = ui.deviceComboBox;
        auto deviceIndex = deviceComboBox.findData(QVariant(udid));
        assert(deviceIndex != -1);
        deviceComboBox.removeItem(deviceIndex);
    }

    @QSlot
    final void refreshDevices() {
        assert(QThread.currentThread() == this.thread());
        QComboBox deviceComboBox = ui.deviceComboBox;
        deviceComboBox.clear();
        foreach (deviceInfo; iDevice.deviceList()) {
            deviceAdded(*cpp_new!QString(deviceInfo.udid));
        }
    }

    @QSlot
    final void refreshView(int index) {
        if (index == -1) {
            ui.deviceSubtitle.setText(*cpp_new!QString(""));
            ui.stackedWidget.setCurrentIndex(0);
            return;
        }

        if (selectedDevice) {
            object.destroy(selectedDevice);
        }
        if (lockdowndClient) {
            object.destroy(lockdowndClient);
        }

        QComboBox deviceComboBox = ui.deviceComboBox;

        string deviceUdid =
            deviceComboBox
                .itemData(index)
                .toString()
                .toConstWString()
                .to!string();

        selectedDevice = new iDevice(deviceUdid);

        // ASCII only: dqt passes literals straight to QString without
        // decoding UTF-8, so anything else comes out as mojibake.
        ui.deviceSubtitle.setText(*cpp_new!QString(format!"%s (USB)"(deviceUdid)));

        try {
            lockdowndClient = new LockdowndClient(selectedDevice, "sideloader.device-info");
            Plist deviceInfo = lockdowndClient[null, null];

            string deviceName = deviceInfo["DeviceName"].str().native();
            string modelName = format!"%s (%s)"(
                deviceInfo["ProductType"].str().native(),
                deviceInfo["HardwareModel"].str().native()
            );
            string iosVersion = format!"%s (%s)"(
                deviceInfo["ProductVersion"].str().native(),
                deviceInfo["BuildVersion"].str().native()
            );

            ui.nameLine.setText(*cpp_new!QString(deviceName));
            ui.modelLine.setText(*cpp_new!QString(modelName));
            ui.versionLine.setText(*cpp_new!QString(iosVersion));

            ui.additionalToolsLayout.clearLayout();

            foreach (tool; toolList(selectedDevice)) {
                // The QString must be heap-allocated like everywhere else in
                // this file: a stack temporary is destroyed before QPushButton
                // has taken it, which crashes as soon as a device connects.
                auto button = cpp_new!QPushButton(*cpp_new!QString(tool.name));
                auto toolDiag = tool.diagnostic;
                button.setEnabled(tool.diagnostic == null);
                if (toolDiag) {
                    button.setToolTip(*cpp_new!QString(toolDiag));
                }

                QObject.connect(button.signal!"clicked", () => tool.run((message, canCancel) {
                    alias StandardButton = QMessageBox.StandardButton;
                    alias StandardButtons = QMessageBox.StandardButtons;

                    StandardButton button = QMessageBox.question(
                        this,
                        *cpp_new!QString(tool.name),
                        *cpp_new!QString(message),
                        StandardButtons(StandardButton.Ok | (canCancel ? StandardButton.Cancel : StandardButton.NoButton))
                    );

                    return button == StandardButton.Cancel;
                }));

                ui.additionalToolsLayout.addWidget(button);
            }

            // ui.tabWidget.setCurrentIndex(0);
            ui.stackedWidget.setCurrentIndex(1);
        } catch (iMobileDeviceException!lockdownd_error_t ex) {
            lockdowndClient = null;
            string message;
            with (lockdownd_error_t) switch (ex.underlyingError) {
                case LOCKDOWN_E_PASSWORD_PROTECTED:
                    message = "Please unlock your phone.";
                    break;
                case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING:
                    message = "Please trust the computer.";
                    break;
                case LOCKDOWN_E_USER_DENIED_PAIRING:
                    message = "The computer has not been trusted.";
                    break;
                default:
                    message = format!"Can't connect to the device (%d).\nTry to plug the device again, unlock it and refresh."(ex.underlyingError);
                    break;
            }

            ui.deviceConnectionErrorLabel.setText(*cpp_new!QString(format!"%s\n(refresh to try again)"(message)));
            ui.stackedWidget.setCurrentIndex(2);
        }
    }

    @QSlot
    void checkApplication() {
        void setErrorLabel(string s) {
            ui.appParsingErrorLabel.setText(*cpp_new!QString(format!`<span style="color:#e01b24;">%s</span>`(s)));
        }

        string ipaFile =
            ui.ipaLine.text()
                .toConstWString()
                .to!string();

        ui.bundleInfos.setVisible(false);
        ui.installButton.setEnabled(false);
        selectedApplication = null;

        if (!file.exists(ipaFile)) {
            setErrorLabel("No such file or directory");
            return;
        }

        if (!file.isFile(ipaFile)) {
            setErrorLabel("Is not a file");
            return;
        }

        auto log = getLogger();

        try {
            Application app = new Application(ipaFile);
            ui.bundleNameLine.setText(*cpp_new!QString(app.appInfo["CFBundleName"].str().native()));
            ui.bundleIdentifierLine.setText(*cpp_new!QString(app.appInfo["CFBundleIdentifier"].str().native()));
            selectedApplication = app;
            setErrorLabel("");
            ui.bundleInfos.setVisible(true);
            ui.installButton.setEnabled(true);
        } catch (Exception ex) {
            log.infoF!"%s"(ex);
            setErrorLabel(ex.msg);
        }
    }

    /++
        Runs the whole install: sign in if needed, then sideload on a worker
        thread.

        Sign-in stays on the UI thread because it can raise a two-factor
        dialog. Only sideloadFull is threaded, and it only reports progress.
    +/
    @QSlot
    void startInstall() {
        auto log = getLogger();

        if (!selectedApplication || !selectedDevice) {
            log.error("Install requested without an application or a device.");
            return;
        }

        if (!developerSession) {
            developerSession = promptLogin(this, provisioningDevice, adi);
            if (!developerSession) {
                log.info("Install cancelled: no developer session.");
                return;
            }
            rememberSession(developerSession);
        }

        sideloadProcedureTriggered(false);
        clearLog();
        reportProgress(0.0, "Starting");

        auto app = selectedApplication;
        auto device = selectedDevice;
        auto session = developerSession;
        auto path = configurationPath;

        new Thread({
            try {
                sideloadFull(path, device, session, app,
                    (double progress, string action) {
                        installProgressed(progress, *cpp_new!QString(action));
                    });
                installFinished(true, *cpp_new!QString("Installed"));
            } catch (Exception ex) {
                getLogger().errorF!"Install failed: %s"(ex);
                installFinished(false, *cpp_new!QString(ex.msg));
            }
        }).start();
    }

    private void reportProgress(double progress, string stage) {
        installProgressed(progress, *cpp_new!QString(stage));
    }

    @QSlot
    void onInstallProgressed(double progress, ref const(QString) stage) {
        int permille = cast(int) (progress * 1000);
        if (permille < 0)
            permille = 0;
        if (permille > 1000)
            permille = 1000;

        ui.progressBar_2.setValue(permille);
        ui.installStageLabel.setText(stage);
        ui.installPercentLabel.setText(*cpp_new!QString(format!"%d%%"(permille / 10)));

        // sideloadFull re-emits the same stage many times while a step makes
        // progress; only a change is worth a new log line.
        string stageText = stage.toConstWString().to!string();
        if (stageText != lastLoggedStage) {
            lastLoggedStage = stageText;
            pushLogLine(stageText);
        }
    }

    /++
        Adds a line on top of the install log and starts the others fading.

        dqt exposes no QPropertyAnimation, so the fade is driven by a timer
        that walks each line's colour towards its target a step at a time.
    +/
    private void pushLogLine(string text) {
        auto label = cpp_new!QLabel(*cpp_new!QString(text));
        label.setObjectName(*cpp_new!QString("installLogLine"));

        logLines = LogLine(label, 255) ~ logLines;
        ui.installLogLayout.insertWidget(0, label);

        // Past maxLogLines the oldest is fully faded anyway; drop it so the
        // layout does not keep growing during a long install.
        while (logLines.length > maxLogLines) {
            auto oldest = logLines[$ - 1];
            logLines = logLines[0 .. $ - 1];
            oldest.label.hide();
            oldest.label.setParent(null);
        }

        if (!logFadeTimer.isActive())
            logFadeTimer.start(40);
    }

    /// One fade step for every line. Stops itself once nothing moves.
    @QSlot
    void stepLogFade() {
        bool stillFading = false;

        foreach (index, ref line; logLines) {
            // Each line down the stack settles at a dimmer level.
            int target = 255 - cast(int) (index * (200.0 / maxLogLines));
            if (target < 40)
                target = 40;

            if (line.brightness > target) {
                line.brightness -= 6;
                if (line.brightness < target)
                    line.brightness = target;
                stillFading = true;
            }

            int value = line.brightness;
            line.label.setStyleSheet(*cpp_new!QString(
                format!"color: rgb(%d, %d, %d);"(value, value, cast(int) (value * 1.02) > 255 ? 255 : cast(int) (value * 1.02))));
        }

        if (!stillFading)
            logFadeTimer.stop();
    }

    private void clearLog() {
        foreach (line; logLines) {
            line.label.hide();
            line.label.setParent(null);
        }
        logLines = null;
        lastLoggedStage = null;
        logFadeTimer.stop();
    }

    @QSlot
    void onInstallFinished(bool succeeded, ref const(QString) message) {
        sideloadProcedureTriggered(true);

        if (succeeded) {
            ui.installStageLabel.setText(*cpp_new!QString("Done"));
            ui.installPercentLabel.setText(*cpp_new!QString("100%"));
            ui.progressBar_2.setValue(1000);
            return;
        }

        ui.installStageLabel.setText(*cpp_new!QString("Failed"));
        ui.installPercentLabel.setText(*cpp_new!QString(""));
        ui.progressBar_2.setValue(0);
        QMessageBox.critical(this, *cpp_new!QString("Install failed"), message);
    }

    @QSlot
    void setSideloadTabEnabled(bool enabled) {
        // Only the inputs are locked, not the whole tab: disabling the tab
        // would grey out the progress bar and the stage label too, which are
        // precisely what the user needs to read while it runs.
        ui.ipaLine.setEnabled(enabled);
        ui.selectIpaButton.setEnabled(enabled);
        ui.installButton.setEnabled(enabled);

        if (enabled) {
            ui.sideloadTab.unsetCursor();
        } else {
            ui.sideloadTab.setCursor(*cpp_new!QCursor(CursorShape.WaitCursor));
        }
    }
}
