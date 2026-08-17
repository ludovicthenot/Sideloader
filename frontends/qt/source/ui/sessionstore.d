/++
    Persistence of the Apple developer session.

    Bridges DeveloperSession's snapshot to the platform secret store: JSON in,
    JSON out, with the storage details left to ui.credentials.
+/
module ui.sessionstore;

import std.json;

import slf4d;

import provision;

import server.developersession;

import ui.credentials;

/// Credential Manager entry name. Stable, since it is also what the user
/// sees if they go looking for it in Windows.
private enum credentialTarget = "Sideloader:AppleDeveloperSession";

/// Stores the session so the next launch does not ask for a password.
void rememberSession(DeveloperSession session) {
    auto saved = session.save();

    JSONValue urlBag = JSONValue(string[string].init);
    foreach (key, value; saved.urlBag)
        urlBag[key] = JSONValue(value);

    JSONValue document = [
        "appleId": JSONValue(saved.appleId),
        "adsid": JSONValue(saved.adsid),
        "token": JSONValue(saved.token),
        "urlBag": urlBag,
    ];

    if (storeSecret(credentialTarget, saved.appleId, document.toString()))
        getLogger().infoF!"Session saved for %s."(saved.appleId);
    else
        getLogger().warn("Could not save the session; sign-in will be asked again next time.");
}

/++
    Rebuilds the stored session, or returns null if there is none.

    A malformed entry is dropped rather than reported: the only sensible
    recovery is to sign in again, and a stale blob would otherwise fail on
    every launch.
+/
DeveloperSession recallSession(Device device, ADI adi) {
    string stored = loadSecret(credentialTarget);
    if (!stored)
        return null;

    try {
        auto document = parseJSON(stored);

        string[string] urlBag;
        foreach (key, value; document["urlBag"].object)
            urlBag[key] = value.str;

        auto saved = SavedDeveloperSession(
            document["appleId"].str,
            document["adsid"].str,
            document["token"].str,
            urlBag,
        );

        getLogger().infoF!"Restoring saved session for %s."(saved.appleId);
        return DeveloperSession.restore(device, adi, saved);
    } catch (Exception ex) {
        getLogger().warnF!"Stored session is unreadable, discarding it: %s"(ex.msg);
        forgetSession();
        return null;
    }
}

/// Drops the stored session, so the next install asks to sign in again.
void forgetSession() {
    forgetSecret(credentialTarget);
}
