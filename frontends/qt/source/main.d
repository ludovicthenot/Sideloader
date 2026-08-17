module main;

import core.runtime;
import core.stdc.signal;
import core.stdcpp.new_: cpp_new;

import file = std.file;
import std.path;
import std.process;
import std.traits;

import std.conv : to;

import qt.core.coreapplication;
import qt.core.dir;
import qt.core.string;
import qt.core.stringlist;
import qt.gui.fontdatabase;
import qt.widgets.application;

import slf4d;
import slf4d.default_provider;
import slf4d.provider;

import constants;
import utils;

import ui.chrome;
import ui.dependencieswindow;
import ui.mainwindow;

int main(string[] args) {
    version (linux) {
        import core.stdc.locale;
        setlocale(LC_ALL, "");
    }

    debug {
        Level level = Levels.TRACE;
    } else {
        Level level = Levels.INFO;
    }

    signal(SIGSEGV, cast(Parameters!signal[1]) &SIGSEGV_trace);
    version(Windows) {
        import graphical_app;
        SetUnhandledExceptionFilter(&SIGSEGV_win);

        import logging;
        auto loggingProvider = new shared OutputDebugStringLoggingProvider(level);
    } else {
        auto loggingProvider = new shared DefaultProvider(true, level);
    }
    configureLoggingProvider(loggingProvider);

    version (Windows) {
        string configurationPath = environment["AppData"];
    } else version (OSX) {
        string configurationPath = "~/Library/Preferences/".expandTilde();
    } else {
        string configurationPath = environment.get("XDG_CONFIG_DIR")
        .orDefault("~/.config")
        .expandTilde();
    }
    configurationPath = configurationPath.buildPath(applicationName);

    auto log = getLogger();

    log.info(versionStr);
    log.infoF!"Configuration path: %s"(configurationPath);
    scope qtApp = new QApplication(Runtime.cArgs.argc, Runtime.cArgs.argv);

    // Fusion before the stylesheet: it is the only Qt style that applies QSS
    // throughout. The native Windows style ignores part of the rules and
    // leaves mismatched controls behind.
    QApplication.setStyle(*cpp_new!QString("Fusion"));

    // The wordmark uses Poppins, which is bundled rather than assumed: no
    // Windows install ships it. Registered before the stylesheet so the
    // font-family resolves on first layout.
    string fontDir = QCoreApplication.applicationDirPath().toConstWString().to!string() ~ "/fonts/";
    foreach (fontFile; ["Poppins-Bold.ttf", "Poppins-SemiBold.ttf"]) {
        if (QFontDatabase.addApplicationFont(*cpp_new!QString(fontDir ~ fontFile)) == -1)
            log.warnF!"Could not load bundled font %s"(fontFile);
    }

    qtApp.setStyleSheet(*cpp_new!QString(import("theme.qss")));

    DependenciesWindow.ensureDeps(configurationPath, (device, adi) {
        auto w = new MainWindow(configurationPath, device, adi);
        w.show();
        // Re-applied after show(): Qt can recreate the native window while
        // realising it, which discards the DWM attribute set in the
        // constructor and leaves a white title bar.
        applyDarkTitleBar(cast(size_t) w.winId());
    });
    return qtApp.exec();
}

private class SegmentationFault: Throwable /+ Throwable since it should not be caught +/ {
    this(string file = __FILE__, size_t line = __LINE__) {
        super("Segmentation fault.", file, line);
    }
}

extern(C) void SIGSEGV_trace(int) @system {
    throw new SegmentationFault();
}
