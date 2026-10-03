# YPT Desktop Landing

Static Next.js landing page for the unofficial YPT Desktop Client.

The page automatically switches visible copy between English and Korean based
on the browser language list. Korean is used when any browser language starts
with `ko`; otherwise English is shown.

## Run

```bash
npm ci
npm run dev
```

## Build

```bash
npm run build
```

The build exports static files to `out/`.

The repository workflow (`.github/workflows/deploy-web.yml`) runs this build
and deploys `out/` to GitHub Pages. It no longer builds a Flutter web demo —
this is a desktop client, and `lib/tray_service.dart` / `lib/app_log.dart`
import `dart:io` directly, which the web compiler rejects. See
`lib/ca_setup.dart` for the conditional-import pattern the rest of the code
follows.

## Hero Asset

`public/hero-dashboard.png` is rendered from `tools/hero-render.html` so the
landing page shows an app-like screen that matches the Flutter desktop UI
instead of a generic generated dashboard.
