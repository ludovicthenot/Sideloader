/++
    Habillage de la fenetre native.

    dlangui ne dessine que l'interieur de la fenetre : la barre de titre
    reste celle du systeme, donc blanche a cote d'une UI sombre. Sous
    Windows 10/11 on la teinte via DWM.

    dwmapi est charge dynamiquement : la fonctionnalite est cosmetique, elle
    ne doit pas devenir une dependance de link ni casser sur une machine ou
    l'API n'existe pas.
+/
module ui.chrome;

import dlangui;

version (Windows) {
    import core.sys.windows.windows;

    import dlangui.platforms.windows.winapp;

    private enum : DWORD {
        DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19,
        DWMWA_USE_IMMERSIVE_DARK_MODE = 20,
        DWMWA_BORDER_COLOR = 34,
        DWMWA_CAPTION_COLOR = 35,
        DWMWA_TEXT_COLOR = 36,
    }

    private alias DwmSetWindowAttributeFn =
        extern (Windows) HRESULT function(HWND, DWORD, const(void)*, DWORD) nothrow;

    private __gshared DwmSetWindowAttributeFn dwmSetWindowAttribute;
    private __gshared bool dwmResolved;

    /// COLORREF est 0x00BBGGRR, l'inverse d'un #RRGGBB.
    private DWORD colorRef(uint rgb) nothrow {
        return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
    }

    private void setAttribute(HWND hwnd, DWORD attribute, DWORD value) nothrow {
        if (dwmSetWindowAttribute)
            dwmSetWindowAttribute(hwnd, attribute, &value, DWORD.sizeof);
    }
}

/++
    Aligne la barre de titre sur le theme sombre.

    Sans effet hors Windows, et sans effet si DWM ne connait pas l'attribut
    (Windows 10 anterieur a 1809, ou 10 tout court pour la couleur exacte de
    la barre : le mode sombre generique prend alors le relais).
+/
void applyDarkTitleBar(Window window) {
    version (Windows) {
        auto win32Window = cast(Win32Window) window;
        if (!win32Window)
            return;

        HWND hwnd = win32Window.windowHandle();
        if (!hwnd)
            return;

        if (!dwmResolved) {
            dwmResolved = true;
            if (auto dwmapi = LoadLibraryA("dwmapi.dll"))
                dwmSetWindowAttribute =
                    cast(DwmSetWindowAttributeFn) GetProcAddress(dwmapi, "DwmSetWindowAttribute");
        }

        setAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, TRUE);
        setAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, TRUE);

        // Win11 uniquement : accorde exactement la barre au bandeau de menu.
        setAttribute(hwnd, DWMWA_CAPTION_COLOR, colorRef(0x232429));
        setAttribute(hwnd, DWMWA_TEXT_COLOR, colorRef(0xECECEF));
        setAttribute(hwnd, DWMWA_BORDER_COLOR, colorRef(0x2F3037));
    }
}
