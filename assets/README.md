# App icon

`lightray.icon` is the shared Icon Composer source for the Mac and iPad apps.
Open it in Xcode's Icon Composer to edit the artwork, positioning, or appearance settings.

The iPad target compiles this file as its `lightray` app icon. The Mac packaging script uses
Xcode's asset compiler to generate `Assets.car`, the fallback `.icns`, and the matching
Info.plist entries before signing the app. Rebuild each app after changing the icon.
