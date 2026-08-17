module ui.dependenciesframe;

import file = std.file;
import std.path;

import slf4d;

import dlangui;

import app;

import ui.chrome;
import ui.widgets;

class DependenciesFrame: VerticalLayout {
    this(string configurationPath, void delegate() onCompletion) {
        auto log = getLogger();

        styleId = "SL_PAGE";
        minWidth = 420;

        addChild(caption("FIRST-TIME SETUP"d));

        addChild(bodyText("Sideloader needs Apple's authentication libraries."d));
        addChild(bodyText("They are extracted from a ~130 MB download,"d));
        addChild(bodyText("and take 5 MB on disk."d));

        addChild(separator());

        ProgressBarWidget progressBar = new ProgressBarWidget();
        progressBar.animationInterval = 50;
        Button button = primaryButton(null, "Download and continue"d);
        button.click = (_) {
            import core.thread;
            auto win = window();
            new Thread({
                log.info("Downloading Apple's APK.");
                // auto succeeded = downloadAndInstallDeps(configurationPath, (progress) {
                //     executeInUiThread({
                //         progressBar.progress(cast(int) (progress * 1000));
                //     });
                //     return win.windowState() == WindowState.hidden;
                // });
                auto succeeded = true;

                if (succeeded) {
                    log.info("Download successful.");
                    executeInUiThread({
                        onCompletion();
                        win.close();
                    });
                }
            }).start();
            return true;
        };

        button.layoutWidth = FILL_PARENT;
        progressBar.layoutWidth = FILL_PARENT;

        addChild(new VSpacer());
        addChild(button);
        addChild(progressBar);
    }

    static void ensureDeps(string configurationPath, void delegate() onCompletion) {
        if (!(file.exists(configurationPath.buildPath("lib/libstoreservicescore.so")) && file.exists(configurationPath.buildPath("lib/libCoreADI.so")))) {
            // Missing dependencies
            // Taille explicite : en 1x1 + ExpandSize, dlangui mesure le
            // contenu avant de connaitre la largeur de la fenetre et les
            // widgets se chevauchent.
            auto depWindow = Platform.instance.createWindow(
                "Download required.", null, WindowFlag.Resizable, 520, 300);
            depWindow.mainWidget = new DependenciesFrame(configurationPath, onCompletion);
            depWindow.windowOrContentResizeMode = WindowOrContentResizeMode.shrinkWidgets;
            applyDarkTitleBar(depWindow);
            depWindow.show();
        } else {
            onCompletion();
        }
    }
}
