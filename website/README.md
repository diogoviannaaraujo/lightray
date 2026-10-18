# Lightray website

The one-page site at <https://diogoviannaaraujo.github.io/lightray/>. It uses plain
HTML, CSS, JavaScript, and local SVG assets, with no build step or dependencies.

## Preview

From the repository root:

```sh
python3 -m http.server 8000 --directory website
```

Open <http://localhost:8000>. The platform guides also work with JavaScript disabled.
Keep product claims and platform status aligned with the application READMEs.

## Deployment

The `Deploy website` workflow publishes `website/` to GitHub Pages when changes to
this directory or the workflow land on `main`. It can also be run manually from
GitHub Actions. The repository's Pages publishing source must be **GitHub Actions**.

All asset paths are relative so the page works under GitHub Pages' `/lightray/`
project path. Update the canonical and Open Graph URLs in `index.html` if the site
moves to a custom domain. Only this directory is uploaded to Pages.

The site has no analytics, cookies, remote fonts, or third-party scripts. The device
composition is an illustration, and its wallpaper and web icon are local SVGs.
