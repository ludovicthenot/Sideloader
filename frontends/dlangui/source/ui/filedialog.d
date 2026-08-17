/++
    Selection de fichier.

    dlangui embarque son propre explorateur, dessine avec ses widgets : il
    ignore les emplacements du systeme, les lecteurs reseau et les habitudes
    de l'utilisateur. Sous Windows on passe donc par le dialogue natif.

    Les autres plateformes gardent le dialogue dlangui, faute d'equivalent
    portable ici.
+/
module ui.filedialog;

import dlangui;

version (Windows) {
    import core.sys.windows.windows;
    import core.sys.windows.commdlg;

    import std.conv : to;

    import dlangui.platforms.windows.winapp;

    pragma(lib, "comdlg32");
} else {
    import dlangui.dialogs.filedlg;
}

/++
    Ouvre un selecteur de fichier et appelle `onSelected` avec le chemin
    choisi. `onSelected` n'est pas appele si l'utilisateur annule.

    `filterPattern` suit la convention des dialogues Windows ("*.ipa").
+/
void openFile(Window owner, dstring title, dstring filterLabel, string filterPattern,
              void delegate(string path) onSelected) {
    version (Windows) {
        // Le filtre est une suite de paires libelle\0motif\0, close par un
        // \0 supplementaire.
        wstring filter =
            filterLabel.to!wstring ~ "\0"w ~ filterPattern.to!wstring ~ "\0"w ~
            "All files (*.*)"w ~ "\0"w ~ "*.*"w ~ "\0"w ~
            "\0"w;

        wstring titleZ = title.to!wstring ~ "\0"w;

        HWND ownerHandle;
        if (auto win32Owner = cast(Win32Window) owner)
            ownerHandle = win32Owner.windowHandle();

        wchar[4096] pathBuffer = 0;

        OPENFILENAMEW ofn;
        ofn.lStructSize = OPENFILENAMEW.sizeof;
        ofn.hwndOwner = ownerHandle;
        ofn.lpstrFilter = filter.ptr;
        ofn.nFilterIndex = 1;
        ofn.lpstrFile = pathBuffer.ptr;
        ofn.nMaxFile = cast(DWORD) pathBuffer.length;
        ofn.lpstrTitle = titleZ.ptr;
        // OFN_NOCHANGEDIR n'est pas optionnel : le repertoire courant est
        // bin/, d'ou sont chargees les DLL natives (imobiledevice, plist).
        // Sans lui, naviguer ailleurs les rendrait introuvables.
        ofn.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

        if (!GetOpenFileNameW(&ofn))
            return; // annule, ou erreur : dans les deux cas rien a faire

        size_t length = 0;
        while (length < pathBuffer.length && pathBuffer[length] != '\0')
            length++;

        onSelected(pathBuffer[0 .. length].to!string());
    } else {
        auto dialog = new FileDialog(UIString.fromRaw(title), owner);
        dialog.addFilter(FileFilterEntry(UIString.fromRaw(filterLabel), filterPattern));
        dialog.dialogResult = (Dialog _, const Action result) {
            if (result.id != ACTION_OPEN.id)
                return;
            onSelected(dialog.filename());
        };
        dialog.show();
    }
}
