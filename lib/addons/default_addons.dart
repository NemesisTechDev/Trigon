/// Addons installed automatically the first time the app runs, so nobody has
/// to type an address in Profile > Addons.
///
/// Put the full address of each addon here (the manifest address without the
/// trailing `/manifest.json`, or with it, either works), for example:
///
///   const List<String> kDefaultAddonUrls = [
///     'https://your-addon.example.com',
///   ];
///
/// Each address is installed once per device. If the person later removes the
/// addon it is NOT added back; a NEW address added here in a later app update
/// is installed on the next launch. If the device is offline on first launch,
/// it is simply tried again on the next one.
///
/// Note: anything in this list is inside the app and can be extracted by
/// anyone who unpacks it. Do not put a URL that contains a private key or
/// token you would not want shared.
const List<String> kDefaultAddonUrls = <String>[
  'https://torrentio.strem.fun/limit=5/manifest.json',
  'https://pengu.uk/%7B%22auth_token%22%3A%22875gejpiMXD-HaKLngvHqLqO23lQWk2-HOoKRyKdusc%22%7D/manifest.json',
  'https://hdhub.thevolecitor.qzz.io/eyJ0b3Jib3giOiJ1bnNldCIsInF1YWxpdGllcyI6IjIxNjBwLDEwODBwLDcyMHAsNDgwcCIsInNvcnQiOiJkZXNjIiwiY2F0YWxvZ3MiOiIifQ/manifest.json',
];
