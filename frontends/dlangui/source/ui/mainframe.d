module ui.mainframe;

import core.thread;

import std.algorithm;
import std.array;
import std.concurrency;
import std.conv;
import std.format;

import slf4d;

import dlangui;

import plist;

import imobiledevice;

import constants;
import sideload;
import tools;

import ui.filedialog;
import ui.loginframe;
import ui.tfaframe;
import ui.utils;
import ui.widgets;

class MainFrame: VerticalLayout/+, MenuItemClickHandler, MenuItemActionHandler+/ {
    string[] devices;
    ComboBox deviceBox;
    FrameLayout actionsFrame;
    VerticalLayout toolsFrame;
    TextWidget toolsEmptyLabel;

    TextWidget deviceNameLine;
    TextWidget modelLine;
    TextWidget versionLine;

    Application app;

    Observer!string path;

    this() {
        auto log = getLogger();

        layoutWidth = FILL_PARENT;
        layoutHeight = FILL_PARENT;

        MenuItem menuItems = new MenuItem();
        {
            MenuItem fileItem = new MenuItem(new Action(0, "Account"d));
            {
                auto logInAction = new Action(1, "Log-in"d);
                logInAction.state = ACTION_STATE_DISABLE;
                MenuItem logInItem = new MenuItem(logInAction);
                fileItem.add(logInItem);

                MenuItem sep1 = new MenuItem();
                sep1.type = MenuItemType.Separator;
                fileItem.add(sep1);

                MenuItem appIdsItem = new MenuItem(new Action(2, "Manage App IDs"d)); // TODO
                fileItem.add(appIdsItem);

                MenuItem certificatesItem = new MenuItem(new Action(3, "Manage certificates"d)); // TODO
                fileItem.add(certificatesItem);
            }
            menuItems.add(fileItem);

            MenuItem deviceItem = new MenuItem(new Action(10, "Devices"d));
            {
                MenuItem refreshItem = new MenuItem(new Action(11, "Refresh device list"d));
                refreshItem.menuItemAction.connect((_) {
                    refreshDeviceList();
                    return true;
                });
                deviceItem.add(refreshItem);
            }
            menuItems.add(deviceItem);

            MenuItem helpItem = new MenuItem(new Action(20, "Help"d));
            {
                MenuItem donateItem = new MenuItem(new Action(21, "Donate"d));
                donateItem.menuItemAction.connect((_) {
                    import std.process;
                    browse("https://github.com/sponsors/Dadoum");
                    return true;
                });
                helpItem.add(donateItem);

                MenuItem aboutItem = new MenuItem(new Action(22, "About"d));
                aboutItem.menuItemAction.connect((_) {
                    window.showMessageBox(
                        UIString.fromRaw("About Sideloader"d),
                        UIString.fromRaw(format!(rawAboutText.to!dstring())(versionStr, "dlangui"))
                    );
                    return true;
                });
                helpItem.add(aboutItem);
            }
            menuItems.add(helpItem);
        }
        addChild(new MainMenu(menuItems));

        auto page = new VerticalLayout();
        page.styleId = "SL_PAGE";
        {
            page.addChild(caption("DEVICE"d));

            deviceBox = new ComboBox();
            deviceBox.itemClick = (_, index) {
                string udid = devices[index];
                new Thread({
                    auto device = new iDevice(udid);
                    try {
                        auto lockdown = new LockdowndClient(device, "sideloader.trust-client");
                        setUpTools(device);
                        updateDeviceInfo(lockdown);
                        actionsFrame.showChild("ACTIONS");
                    } catch (iMobileDeviceException!lockdownd_error_t err) {
                        log.infoF!"Can't connect to the device: %s"(err.underlyingError);
                        actionsFrame.showChild("TRUST");
                    } catch (Exception ex) {
                        log.infoF!"Can't connect to the device: %s"(ex);
                    }
                    window().executeInUiThread(() => window().invalidate());
                }).start();
                return true;
            };
            deviceBox.layoutWidth = FILL_PARENT;
            page.addChild(deviceBox);

            actionsFrame = new FrameLayout();
            actionsFrame.layoutWidth = FILL_PARENT;
            actionsFrame.layoutHeight = FILL_PARENT;
            {
                // Les trois etats "rien a faire" sont des messages plein cadre
                // plutot qu'un panneau vide : l'utilisateur sait quoi faire.
                actionsFrame.addChild(emptyState("NODEVICE",
                    "No device detected.\n\nConnect your iPhone or iPad over USB, unlock it,\nthen use Devices ▸ Refresh device list."d));

                actionsFrame.addChild(emptyState("PICK",
                    "Select a device above to continue."d));

                actionsFrame.addChild(emptyState("TRUST",
                    "This device is locked.\n\nUnlock it and tap “Trust” on the prompt,\nthen select it again."d));

                auto actions = new TabWidget("ACTIONS");
                actions.layoutWidth = FILL_PARENT;
                actions.layoutHeight = FILL_PARENT;
                {
                    actions.addTab(buildInfoTab(), "Informations"d);
                    actions.addTab(buildSideloadTab(log), "Sideload"d);
                    actions.addTab(buildToolsTab(), "Additional tools"d);
                }
                actionsFrame.addChild(actions);
            }
            actionsFrame.showChild("NODEVICE");
            page.addChild(actionsFrame);
        }
        addChild(page);
    }

    private Widget buildInfoTab() {
        auto pane = new VerticalLayout("INFO");
        pane.layoutWidth = FILL_PARENT;
        pane.layoutHeight = FILL_PARENT;

        pane.addChild(caption("CONNECTED DEVICE"d));

        auto table = fieldTable();
        deviceNameLine = table.addField("Name"d);
        modelLine = table.addField("Model"d);
        versionLine = table.addField("iOS version"d);
        pane.addChild(table);

        pane.addChild(new VSpacer());
        return pane;
    }

    private Widget buildSideloadTab(Logger log) {
        auto pane = new VerticalLayout("INSTALL");
        pane.layoutWidth = FILL_PARENT;
        pane.layoutHeight = FILL_PARENT;

        Button installButton;

        pane.addChild(caption("APPLICATION"d));

        auto fileRow = new HorizontalLayout();
        fileRow.layoutWidth = FILL_PARENT;
        {
            auto pathLabel = fieldValue("IPA_PATH", "No package selected"d);
            fileRow.addChild(pathLabel);

            auto selectFileButton = new Button(null, "Choose IPA…"d);
            selectFileButton.click = (source) {
                openFile(window(), "Select IPA"d, "iOS application package (*.ipa)"d, "*.ipa",
                    (string selectedPath) {
                        pathLabel.text = selectedPath.to!dstring();
                        path = selectedPath;
                    });
                return true;
            };
            fileRow.addChild(selectFileButton);
        }
        pane.addChild(fileRow);

        auto errorLabel = errorText("IPA_ERROR");
        pane.addChild(errorLabel);

        auto appInfoTable = fieldTable();
        auto nameLine = appInfoTable.addField("Bundle name"d);
        auto identifierLine = appInfoTable.addField("Bundle identifier"d);
        pane.addChild(appInfoTable);

        path.connect((newPath) {
            try {
                app = new Application(newPath);
                nameLine.text = app.appInfo["CFBundleName"].str().native().to!dstring();
                identifierLine.text = app.appInfo["CFBundleIdentifier"].str().native().to!dstring();
                errorLabel.visibility = Visibility.Gone;
                installButton.enabled = true;
            } catch (Exception ex) {
                log.errorF!"Cannot load the app: %s"(ex);
                nameLine.text = ""d;
                identifierLine.text = ""d;
                errorLabel.text = format!"Invalid package: %s"d(ex.msg);
                errorLabel.visibility = Visibility.Visible;
                installButton.enabled = false;
            }
        });

        pane.addChild(new VSpacer());
        pane.addChild(separator());

        installButton = primaryButton(new Action(101, "Install"d));
        installButton.layoutWidth = FILL_PARENT;
        installButton.layoutHeight = WRAP_CONTENT;
        installButton.enabled = false;
        installButton.click = (_) {
            // TODO
            LoginFrame.login(null, null, window(), (_) {});
            return true;
        };
        pane.addChild(installButton);

        auto installProgressBar = new ProgressBarWidget();
        installProgressBar.layoutWidth = FILL_PARENT;
        installProgressBar.layoutHeight = WRAP_CONTENT;
        pane.addChild(installProgressBar);

        pane.addChild(hint("Idle"d));
        return pane;
    }

    private Widget buildToolsTab() {
        auto pane = new VerticalLayout("TOOLS_PAGE");
        pane.layoutWidth = FILL_PARENT;
        pane.layoutHeight = FILL_PARENT;

        pane.addChild(caption("TOOLS"d));

        toolsEmptyLabel = new TextWidget(null, "No tool available for this device."d);
        toolsEmptyLabel.styleId = "SL_HINT";
        toolsEmptyLabel.layoutWidth = FILL_PARENT;
        pane.addChild(toolsEmptyLabel);

        toolsFrame = new VerticalLayout("TOOLS");
        toolsFrame.layoutWidth = FILL_PARENT;
        toolsFrame.layoutHeight = WRAP_CONTENT;
        pane.addChild(toolsFrame);

        pane.addChild(new VSpacer());
        return pane;
    }

    void refreshDeviceList() {
        devices = iDevice.deviceList().map!((device) => device.udid).array();
        auto uiDevices = devices.map!((device) => device.to!dstring()).array();
        deviceBox.executeInUiThread({
            deviceBox.items = uiDevices;

            if (uiDevices.length == 0) {
                deviceBox.enabled = false;
                actionsFrame.showChild("NODEVICE");
            } else {
                deviceBox.enabled = true;
                actionsFrame.showChild("PICK");
            }
        });

        if (auto win = window())
            win.executeInUiThread(() => win.invalidate());
    }

    void updateDeviceInfo(scope LockdowndClient client) {
        Plist deviceInfo = client[null, null];

        deviceNameLine.executeInUiThread({
            deviceNameLine.text = deviceInfo["DeviceName"].str().native().to!dstring();
        });

        modelLine.executeInUiThread({
            modelLine.text = deviceInfo["HardwareModel"].str().native().to!dstring();
        });

        versionLine.executeInUiThread({
            versionLine.text = deviceInfo["ProductVersion"].str().native().to!dstring();

            // TFAFrame.tfa(window(), () => true, (_) { return AppleTFAResponse(Success()); });
        });
    }

    void setUpTools(iDevice device) {
        toolsFrame.executeInUiThread({
            toolsFrame.removeAllChildren();
            auto tools = toolList(device);
            toolsEmptyLabel.visibility = tools.length == 0 ? Visibility.Visible : Visibility.Gone;
            foreach (tool; tools) {
                auto toolButton = new Button(null, tool.name().to!dstring());
                toolButton.click = (source) {
                    new Thread({
                        auto window = window();
                        window.uiTry!({
                            tool.run((string message, bool canCancel = true) {
                                Tid parentTid = thisTid();
                                const(Action)[] actions = [ACTION_OK];
                                if (canCancel) {
                                    actions ~= ACTION_CANCEL;
                                }

                                window.executeInUiThread({
                                    window.showMessageBox(""d, message.to!dstring(), actions, 0, (res) {
                                        parentTid.send((res.id != StandardAction.Ok) || !canCancel);
                                        return true;
                                    });
                                });
                                return receiveOnly!bool();
                            });
                        });
                    }).start();
                    return true;
                };
                toolButton.layoutWidth = FILL_PARENT;
                string diag = tool.diagnostic();
                if (diag) {
                    toolButton.enabled = false;
                    toolButton.tooltipText = diag.to!dstring();
                }

                toolsFrame.addChild(toolButton);
            }
        });
    }
}
