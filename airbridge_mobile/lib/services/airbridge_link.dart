/// Returns whether [uri] is addressed to an Airbridge pairing invitation.
bool isAirbridgePairingUri(Uri uri) =>
    uri.scheme.toLowerCase() == 'airbridge' && uri.host.toLowerCase() == 'pair';
